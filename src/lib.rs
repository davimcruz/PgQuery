use futures_util::{pin_mut, StreamExt};
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, ServerName, UnixTime},
    DigitallySignedStruct, Error as TlsError, SignatureScheme,
};
use std::{
    collections::HashMap,
    ffi::{CStr, CString},
    os::raw::c_char,
    sync::{mpsc::{self, Receiver, Sender}, Arc, Mutex, OnceLock},
    thread,
};
use tokio_postgres::SimpleQueryMessage;

const MAX_ROWS: usize = 500;
const MAX_RESULT_BYTES: usize = 2 * 1024 * 1024;

#[derive(Debug)]
struct EncryptionOnlyVerifier {
    provider: Arc<rustls::crypto::CryptoProvider>,
}

impl ServerCertVerifier for EncryptionOnlyVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

enum Request { Connect(String), Query { sql: String, preview: bool } }
enum Event { Status(String), Tables(Vec<String>), Schema(Vec<Vec<String>>), TableStats(Vec<Vec<String>>), Results { preview: bool, headers: Vec<String>, types: Vec<String>, foreign_keys: Vec<Vec<String>>, rows: Vec<Vec<String>>, note: String }, Error(String), QueryError(String) }

fn json_quote(value: &str) -> String {
    let mut output = String::with_capacity(value.len() + 2);
    output.push('"');
    for ch in value.chars() {
        match ch {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            ch if ch.is_control() => output.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => output.push(ch),
        }
    }
    output.push('"');
    output
}

fn json_strings(values: &[String]) -> String {
    format!("[{}]", values.iter().map(|value| json_quote(value)).collect::<Vec<_>>().join(","))
}

fn error_chain(error: &dyn std::error::Error) -> String {
    let mut parts = Vec::new();
    let mut current = Some(error);
    while let Some(item) = current {
        parts.push(item.to_string());
        current = item.source();
    }
    parts.join(": ")
}

fn postgres_error(error: &tokio_postgres::Error) -> String {
    if let Some(db) = error.as_db_error() {
        let mut message = format!("{} (SQLSTATE {})", db.message(), db.code().code());
        if let Some(detail) = db.detail() { message.push_str(&format!("\nDETALHE: {detail}")); }
        if let Some(hint) = db.hint() { message.push_str(&format!("\nDICA: {hint}")); }
        if let Some(position) = db.position() {
            match position {
                tokio_postgres::error::ErrorPosition::Original(position) => message.push_str(&format!("\nPosição na consulta: {position}")),
                tokio_postgres::error::ErrorPosition::Internal { position, .. } => message.push_str(&format!("\nPosição na consulta interna: {position}")),
            }
        }
        if let Some(context) = db.where_() { message.push_str(&format!("\nCONTEXTO: {context}")); }
        message
    } else {
        error_chain(error)
    }
}

/// Called from the worker thread after each event is queued, so the UI can
/// drain `pg_poll` right away instead of polling on a timer.
static NOTIFY: OnceLock<extern "C" fn()> = OnceLock::new();

fn emit(events: &Sender<Event>, event: Event) {
    let _ = events.send(event);
    if let Some(callback) = NOTIFY.get() { callback(); }
}

struct Backend { tx: Sender<Request>, rx: Mutex<Receiver<Event>> }
static BACKEND: OnceLock<Backend> = OnceLock::new();

fn backend() -> &'static Backend {
    BACKEND.get_or_init(|| {
        let (tx, requests) = mpsc::channel();
        let (events, rx) = mpsc::channel();
        thread::Builder::new().name("postgres-worker".into()).spawn(move || worker(requests, events)).expect("worker thread");
        Backend { tx, rx: Mutex::new(rx) }
    })
}

fn worker(requests: Receiver<Request>, events: Sender<Event>) {
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => { emit(&events, Event::Error(format!("Falha ao iniciar runtime: {error}"))); return; }
    };
    let mut client: Option<tokio_postgres::Client> = None;
    // (table oid, column number) → [schema, table, column] it references.
    let mut foreign_keys: ForeignKeys = HashMap::new();
    while let Ok(request) = requests.recv() {
        match request {
            Request::Connect(connection_string) => {
                let result = runtime.block_on(async {
                    let _ = rustls::crypto::ring::default_provider().install_default();
                    let provider = Arc::new(rustls::crypto::ring::default_provider());
                    let config: tokio_postgres::Config = connection_string.parse()?;
                    let encryption_only = matches!(config.get_ssl_mode(), tokio_postgres::config::SslMode::Require);
                    // Root certificates are only needed when the server
                    // certificate is validated (sslmode=prefer); `require`
                    // skips validation and `disable` never uses TLS.
                    let validates = matches!(config.get_ssl_mode(), tokio_postgres::config::SslMode::Prefer);
                    let mut roots = rustls::RootCertStore { roots: if validates { webpki_roots::TLS_SERVER_ROOTS.to_vec() } else { Vec::new() } };
                    if validates {
                        let native_roots = rustls_native_certs::load_native_certs();
                        let _ = roots.add_parsable_certificates(native_roots.certs);
                    }
                    let mut tls_config = rustls::ClientConfig::builder()
                        .with_root_certificates(roots)
                        .with_no_client_auth();
                    if encryption_only {
                        tls_config.dangerous().set_certificate_verifier(Arc::new(EncryptionOnlyVerifier { provider }));
                    }
                    let connector = tokio_postgres_rustls::MakeRustlsConnect::new(tls_config);
                    let (client, connection) = config.connect(connector).await?;
                    tokio::spawn(async move { if let Err(error) = connection.await { eprintln!("Postgres connection: {error}"); } });
                    Ok::<_, Box<dyn std::error::Error + Send + Sync>>((client, encryption_only))
                });
                match result {
                    Ok((connected, encryption_only)) => {
                        client = Some(connected);
                        let status = if encryption_only {
                            "Conectado (TLS ativo; certificado do servidor não verificado). Carregando tabelas…"
                        } else {
                            "Conectado. Carregando tabelas…"
                        };
                        emit(&events, Event::Status(status.into()));
                        match load_catalog(&runtime, client.as_ref().unwrap(), &events) {
                            Ok(keys) => {
                                foreign_keys = keys;
                                let connected_status = if encryption_only {
                                    "Conectado · TLS ativo; certificado do servidor não verificado"
                                } else {
                                    "Conectado"
                                };
                                emit(&events, Event::Status(connected_status.into()));
                            }
                            Err(error) => { emit(&events, Event::QueryError(error)); }
                        }
                    }
                    Err(error) => {
                        client = None;
                        let details = error.downcast_ref::<tokio_postgres::Error>()
                            .map(postgres_error)
                            .unwrap_or_else(|| error_chain(error.as_ref()));
                        let lower_details = details.to_lowercase();
                        let network_hint = if connection_string.contains(".supabase.co")
                            && ["network is unreachable", "no route to host", "connection timed out", "failed to lookup address"]
                                .iter().any(|marker| lower_details.contains(marker)) {
                            "\n\nDica: no Supabase, se a sua rede não tiver IPv6, use no painel Connect a URL do Session Pooler (porta 5432). O endereço direto db.<ref>.supabase.co é IPv6 na maioria dos projetos." 
                        } else { "" };
                        emit(&events, Event::Error(format!("Conexão falhou: {details}{network_hint}")));
                    }
                }
            }
            Request::Query { sql, preview } => {
                let Some(client) = client.as_ref() else { emit(&events, Event::Error("Conecte-se a um banco primeiro.".into())); continue; };
                // The describe round trip is pipelined with the query itself.
                let (outcome, statement) = runtime.block_on(futures_util::future::join(run_query(client, &sql), describe(client, &sql)));
                match outcome {
                    Ok((headers, rows, note)) => {
                        let (types, fks) = column_metadata(statement, headers.len(), &foreign_keys);
                        emit(&events, Event::Results { preview, headers, types, foreign_keys: fks, rows, note });
                        // Keep the sidebar and autocomplete in sync after DDL.
                        if !preview && changes_schema(&sql) {
                            match load_catalog(&runtime, client, &events) {
                                Ok(keys) => foreign_keys = keys,
                                Err(error) => eprintln!("Catalog reload: {error}"),
                            }
                        }
                    }
                    Err(error) => { emit(&events, Event::QueryError(error)); }
                }
            }
        }
    }
}

type QueryOutput = (Vec<String>, Vec<Vec<String>>, String);

/// Runs a statement with the simple protocol (so every value arrives as
/// text), keeping at most MAX_ROWS rows / MAX_RESULT_BYTES in memory while
/// still counting the rest.
async fn run_query(client: &tokio_postgres::Client, sql: &str) -> Result<QueryOutput, String> {
    let stream = client.simple_query_raw(sql).await.map_err(|e| postgres_error(&e))?;
    pin_mut!(stream);
    let mut headers = Vec::new();
    let mut rows = Vec::new();
    let mut bytes = 0usize;
    let mut total = 0usize;
    let mut command = String::new();
    while let Some(message) = stream.next().await {
        match message.map_err(|e| postgres_error(&e))? {
            SimpleQueryMessage::Row(row) => {
                if headers.is_empty() { headers = row.columns().iter().map(|column| column.name().to_owned()).collect(); }
                total += 1;
                if rows.len() < MAX_ROWS && bytes < MAX_RESULT_BYTES {
                    let values: Vec<String> = (0..row.len()).map(|i| row.get(i).unwrap_or("NULL").to_owned()).collect();
                    bytes += values.iter().map(String::len).sum::<usize>();
                    if bytes <= MAX_RESULT_BYTES { rows.push(values); }
                }
            }
            SimpleQueryMessage::CommandComplete(count) => command = format!("{count} linha(s) afetada(s)"),
            SimpleQueryMessage::RowDescription(columns) if headers.is_empty() => headers = columns.iter().map(|column| column.name().to_owned()).collect(),
            _ => {}
        }
    }
    let note = if total > rows.len() { format!("Mostrando {} de {total} linhas (limite de memória atingido).", rows.len()) }
        else if headers.is_empty() && !command.is_empty() { command } else { format!("{} linha(s)", rows.len()) };
    Ok((headers, rows, note))
}

/// Loads tables for the sidebar and the full column catalog (schema, relation,
/// column, type, relkind) used by the SQL editor's autocomplete.
fn load_catalog(runtime: &tokio::runtime::Runtime, client: &tokio_postgres::Client, events: &Sender<Event>) -> Result<ForeignKeys, String> {
    const TABLES: &str = "SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema') ORDER BY table_schema, table_name";
    // Approximate row counts from planner statistics: instant even on huge
    // tables. reltuples is -1 before the first VACUUM/ANALYZE (PG 14+), so
    // fall back to the live-tuple counter.
    const ESTIMATES: &str = "SELECT n.nspname || '.' || c.relname, \
        (CASE WHEN c.reltuples >= 0 THEN c.reltuples::bigint ELSE coalesce(s.n_live_tup, -1) END)::text \
        FROM pg_catalog.pg_class c \
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
        LEFT JOIN pg_catalog.pg_stat_user_tables s ON s.relid = c.oid \
        WHERE c.relkind IN ('r', 'p', 'm', 'f') AND n.nspname NOT IN ('pg_catalog', 'information_schema')";
    const COLUMNS: &str = "SELECT n.nspname, c.relname, a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), c.relkind::text \
        FROM pg_catalog.pg_attribute a \
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid \
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
        WHERE c.relkind IN ('r', 'v', 'm', 'f', 'p') AND a.attnum > 0 AND NOT a.attisdropped \
          AND n.nspname NOT IN ('pg_catalog', 'information_schema') \
          AND n.nspname NOT LIKE 'pg\\_toast%' AND n.nspname NOT LIKE 'pg\\_temp%' \
        ORDER BY n.nspname, c.relname, a.attnum";
    // Single-column foreign keys, used to jump from a value to the row it
    // references. Composite keys are skipped.
    const FOREIGN_KEYS: &str = "SELECT k.conrelid::oid::text, k.conkey[1]::text, n.nspname, c.relname, a.attname \
        FROM pg_catalog.pg_constraint k \
        JOIN pg_catalog.pg_class c ON c.oid = k.confrelid \
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
        JOIN pg_catalog.pg_attribute a ON a.attrelid = k.confrelid AND a.attnum = k.confkey[1] \
        WHERE k.contype = 'f' AND array_length(k.conkey, 1) = 1";

    // Pipelined on the one connection: one round trip instead of four,
    // which matters on remote databases.
    let (tables, estimates, columns, foreign_keys) = runtime.block_on(futures_util::future::join4(
        run_query(client, TABLES), run_query(client, ESTIMATES), run_query(client, COLUMNS), run_query(client, FOREIGN_KEYS),
    ));
    let (_, rows, _) = tables?;
    emit(events, Event::Tables(rows.into_iter().filter_map(|mut row| row.pop()).collect()));
    if let Ok((_, rows, _)) = estimates { emit(events, Event::TableStats(rows)); }
    let (_, rows, _) = columns?;
    emit(events, Event::Schema(rows));

    let mut keys = ForeignKeys::new();
    if let Ok((_, rows, _)) = foreign_keys {
        for row in rows {
            if let [relid, attnum, schema, table, column] = row.as_slice() {
                if let (Ok(relid), Ok(attnum)) = (relid.parse::<u32>(), attnum.parse::<i16>()) {
                    keys.insert((relid, attnum), vec![schema.clone(), table.clone(), column.clone()]);
                }
            }
        }
    }
    Ok(keys)
}

type ForeignKeys = HashMap<(u32, i16), Vec<String>>;

/// Whether a statement is worth describing (it can return rows). Writes and
/// DDL are not parsed a second time.
fn returns_rows(sql: &str) -> bool {
    let mut rest = sql.trim_start();
    loop {
        if let Some(after) = rest.strip_prefix("--") { rest = after.split_once('\n').map_or("", |(_, tail)| tail).trim_start(); }
        else if let Some(after) = rest.strip_prefix("/*") { rest = after.split_once("*/").map_or("", |(_, tail)| tail).trim_start(); }
        else { break; }
    }
    let word: String = rest.chars().take_while(|c| c.is_ascii_alphabetic()).collect::<String>().to_ascii_uppercase();
    matches!(word.as_str(), "SELECT" | "WITH" | "TABLE" | "VALUES" | "SHOW" | "EXPLAIN" | "FETCH")
}

/// Prepares the statement (parse only, nothing runs) to learn each result
/// column's type and source column. Multi-statement scripts cannot be
/// prepared; they simply get no metadata.
async fn describe(client: &tokio_postgres::Client, sql: &str) -> Option<tokio_postgres::Statement> {
    if !returns_rows(sql) { return None; }
    client.prepare(sql).await.ok()
}

fn column_metadata(statement: Option<tokio_postgres::Statement>, count: usize, keys: &ForeignKeys) -> (Vec<String>, Vec<Vec<String>>) {
    let Some(statement) = statement else { return (Vec::new(), Vec::new()); };
    let columns = statement.columns();
    if count == 0 || columns.len() != count { return (Vec::new(), Vec::new()); }
    let types = columns.iter().map(|column| column.type_().name().to_owned()).collect();
    let fks = columns.iter().map(|column| match (column.table_oid(), column.column_id()) {
        (Some(table), Some(id)) => keys.get(&(table, id)).cloned().unwrap_or_default(),
        _ => Vec::new(),
    }).collect();
    (types, fks)
}

fn changes_schema(sql: &str) -> bool {
    let upper = sql.to_ascii_uppercase();
    ["CREATE ", "ALTER ", "DROP ", "RENAME ", "TRUNCATE ", "COMMENT "].iter().any(|word| upper.contains(word))
}

unsafe fn read_string(value: *const c_char) -> Option<String> {
    if value.is_null() { None } else { CStr::from_ptr(value).to_str().ok().map(str::to_owned) }
}

/// Registers a callback invoked (on the worker thread) whenever an event is
/// ready to be read with `pg_poll`. Only the first registration is kept.
#[no_mangle]
pub extern "C" fn pg_set_notify(callback: Option<extern "C" fn()>) {
    if let Some(callback) = callback { let _ = NOTIFY.set(callback); }
}

#[no_mangle]
pub extern "C" fn pg_connect(value: *const c_char) {
    let Some(value) = (unsafe { read_string(value) }) else { return; };
    let _ = backend().tx.send(Request::Connect(value));
}

#[no_mangle]
pub extern "C" fn pg_query(value: *const c_char) {
    let Some(value) = (unsafe { read_string(value) }) else { return; };
    let _ = backend().tx.send(Request::Query { sql: value, preview: false });
}

#[no_mangle]
pub extern "C" fn pg_select_table(value: *const c_char) {
    let Some(table) = (unsafe { read_string(value) }) else { return; };
    let (schema, name) = table.split_once('.').unwrap_or(("public", &table));
    let quote = |part: &str| format!("\"{}\"", part.replace('"', "\"\""));
    let sql = format!("SELECT * FROM {}.{} LIMIT {MAX_ROWS}", quote(schema), quote(name));
    let _ = backend().tx.send(Request::Query { sql, preview: true });
}

#[no_mangle]
pub extern "C" fn pg_poll() -> *mut c_char {
    let Ok(receiver) = backend().rx.lock() else { return std::ptr::null_mut(); };
    let Ok(event) = receiver.try_recv() else { return std::ptr::null_mut(); };
    let message = match event {
        Event::Status(text) => format!("{{\"kind\":\"status\",\"text\":{}}}", json_quote(&text)),
        Event::Tables(items) => format!("{{\"kind\":\"tables\",\"items\":{}}}", json_strings(&items)),
        Event::TableStats(rows) => {
            let items = rows.iter().map(|row| json_strings(row)).collect::<Vec<_>>().join(",");
            format!("{{\"kind\":\"table_stats\",\"items\":[{}]}}", items)
        }
        Event::Schema(rows) => {
            let items = rows.iter().map(|row| json_strings(row)).collect::<Vec<_>>().join(",");
            format!("{{\"kind\":\"schema\",\"items\":[{}]}}", items)
        }
        Event::Error(text) => format!("{{\"kind\":\"error\",\"text\":{}}}", json_quote(&text)),
        Event::QueryError(text) => format!("{{\"kind\":\"query_error\",\"text\":{}}}", json_quote(&text)),
        Event::Results { preview, headers, types, foreign_keys, rows, note } => {
            let json_rows = rows.iter().map(|row| json_strings(row)).collect::<Vec<_>>().join(",");
            let json_keys = foreign_keys.iter().map(|key| json_strings(key)).collect::<Vec<_>>().join(",");
            let kind = if preview { "table_preview" } else { "results" };
            format!("{{\"kind\":\"{kind}\",\"headers\":{},\"types\":{},\"foreign_keys\":[{}],\"rows\":[{}],\"note\":{}}}", json_strings(&headers), json_strings(&types), json_keys, json_rows, json_quote(&note))
        }
    };
    CString::new(message).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn pg_string_free(value: *mut c_char) {
    if !value.is_null() { drop(CString::from_raw(value)); }
}
