use futures_util::{pin_mut, StreamExt};
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, ServerName, UnixTime},
    DigitallySignedStruct, Error as TlsError, SignatureScheme,
};
use std::{
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

enum Request { Connect(String), Query(String) }
enum Event { Status(String), Tables(Vec<String>), Results { headers: Vec<String>, rows: Vec<Vec<String>>, note: String }, Error(String), QueryError(String) }

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
        Err(error) => { let _ = events.send(Event::Error(format!("Falha ao iniciar runtime: {error}"))); return; }
    };
    let mut client: Option<tokio_postgres::Client> = None;
    while let Ok(request) = requests.recv() {
        match request {
            Request::Connect(connection_string) => {
                let result = runtime.block_on(async {
                    let _ = rustls::crypto::ring::default_provider().install_default();
                    let provider = Arc::new(rustls::crypto::ring::default_provider());
                    let config: tokio_postgres::Config = connection_string.parse()?;
                    let encryption_only = matches!(config.get_ssl_mode(), tokio_postgres::config::SslMode::Require);
                    let mut roots = rustls::RootCertStore {
                        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
                    };
                    let native_roots = rustls_native_certs::load_native_certs();
                    let _ = roots.add_parsable_certificates(native_roots.certs);
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
                        let _ = events.send(Event::Status(status.into()));
                        let query = "SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema') ORDER BY table_schema, table_name";
                        match query_rows(&runtime, client.as_ref().unwrap(), query) {
                            Ok((_, rows, _)) => {
                                let tables = rows.into_iter().filter_map(|mut row| row.pop()).collect();
                                let _ = events.send(Event::Tables(tables));
                                let connected_status = if encryption_only {
                                    "Conectado · TLS ativo; certificado do servidor não verificado"
                                } else {
                                    "Conectado"
                                };
                                let _ = events.send(Event::Status(connected_status.into()));
                            }
                            Err(error) => { let _ = events.send(Event::QueryError(error)); }
                        }
                    }
                    Err(error) => {
                        client = None;
                        let details = error_chain(error.as_ref());
                        let lower_details = details.to_lowercase();
                        let network_hint = if connection_string.contains(".supabase.co")
                            && ["network is unreachable", "no route to host", "connection timed out", "failed to lookup address"]
                                .iter().any(|marker| lower_details.contains(marker)) {
                            "\n\nDica: no Supabase, se a sua rede não tiver IPv6, use no painel Connect a URL do Session Pooler (porta 5432). O endereço direto db.<ref>.supabase.co é IPv6 na maioria dos projetos." 
                        } else { "" };
                        let _ = events.send(Event::Error(format!("Conexão falhou: {details}{network_hint}")));
                    }
                }
            }
            Request::Query(sql) => {
                let Some(client) = client.as_ref() else { let _ = events.send(Event::Error("Conecte-se a um banco primeiro.".into())); continue; };
                match query_rows(&runtime, client, &sql) {
                    Ok((headers, rows, note)) => { let _ = events.send(Event::Results { headers, rows, note }); }
                    Err(error) => { let _ = events.send(Event::QueryError(error)); }
                }
            }
        }
    }
}

fn query_rows(runtime: &tokio::runtime::Runtime, client: &tokio_postgres::Client, sql: &str) -> Result<(Vec<String>, Vec<Vec<String>>, String), String> {
    runtime.block_on(async {
        let stream = client.simple_query_raw(sql).await.map_err(|e| e.to_string())?;
        pin_mut!(stream);
        let mut headers = Vec::new();
        let mut rows = Vec::new();
        let mut bytes = 0usize;
        let mut total = 0usize;
        let mut command = String::new();
        while let Some(message) = stream.next().await {
            match message.map_err(|e| e.to_string())? {
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
            else if !command.is_empty() { command } else { format!("{} linha(s)", rows.len()) };
        Ok((headers, rows, note))
    })
}

unsafe fn read_string(value: *const c_char) -> Option<String> {
    if value.is_null() { None } else { CStr::from_ptr(value).to_str().ok().map(str::to_owned) }
}

#[no_mangle]
pub extern "C" fn pg_connect(value: *const c_char) {
    let Some(value) = (unsafe { read_string(value) }) else { return; };
    let _ = backend().tx.send(Request::Connect(value));
}

#[no_mangle]
pub extern "C" fn pg_query(value: *const c_char) {
    let Some(value) = (unsafe { read_string(value) }) else { return; };
    let _ = backend().tx.send(Request::Query(value));
}

#[no_mangle]
pub extern "C" fn pg_select_table(value: *const c_char) {
    let Some(table) = (unsafe { read_string(value) }) else { return; };
    let (schema, name) = table.split_once('.').unwrap_or(("public", &table));
    let quote = |part: &str| format!("\"{}\"", part.replace('"', "\"\""));
    let sql = format!("SELECT * FROM {}.{} LIMIT {MAX_ROWS}", quote(schema), quote(name));
    let _ = backend().tx.send(Request::Query(sql));
}

#[no_mangle]
pub extern "C" fn pg_poll() -> *mut c_char {
    let Ok(receiver) = backend().rx.lock() else { return std::ptr::null_mut(); };
    let Ok(event) = receiver.try_recv() else { return std::ptr::null_mut(); };
    let message = match event {
        Event::Status(text) => format!("{{\"kind\":\"status\",\"text\":{}}}", json_quote(&text)),
        Event::Tables(items) => format!("{{\"kind\":\"tables\",\"items\":{}}}", json_strings(&items)),
        Event::Error(text) => format!("{{\"kind\":\"error\",\"text\":{}}}", json_quote(&text)),
        Event::QueryError(text) => format!("{{\"kind\":\"query_error\",\"text\":{}}}", json_quote(&text)),
        Event::Results { headers, rows, note } => {
            let json_rows = rows.iter().map(|row| json_strings(row)).collect::<Vec<_>>().join(",");
            format!("{{\"kind\":\"results\",\"headers\":{},\"rows\":[{}],\"note\":{}}}", json_strings(&headers), json_rows, json_quote(&note))
        }
    };
    CString::new(message).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn pg_string_free(value: *mut c_char) {
    if !value.is_null() { drop(CString::from_raw(value)); }
}
