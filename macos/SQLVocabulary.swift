import Foundation

/// Static PostgreSQL vocabulary used by highlighting and autocomplete.
enum SQLVocabulary {
    /// Reserved words: identifiers that collide with these must be quoted.
    static let reserved: Set<String> = [
        "ALL", "ANALYSE", "ANALYZE", "AND", "ANY", "ARRAY", "AS", "ASC", "ASYMMETRIC", "AUTHORIZATION", "BINARY", "BOTH",
        "CASE", "CAST", "CHECK", "COLLATE", "COLLATION", "COLUMN", "CONCURRENTLY", "CONSTRAINT", "CREATE", "CROSS",
        "CURRENT_CATALOG", "CURRENT_DATE", "CURRENT_ROLE", "CURRENT_SCHEMA", "CURRENT_TIME", "CURRENT_TIMESTAMP",
        "CURRENT_USER", "DEFAULT", "DEFERRABLE", "DESC", "DISTINCT", "DO", "ELSE", "END", "EXCEPT", "FALSE", "FETCH",
        "FOR", "FOREIGN", "FREEZE", "FROM", "FULL", "GRANT", "GROUP", "HAVING", "ILIKE", "IN", "INITIALLY", "INNER",
        "INTERSECT", "INTO", "IS", "ISNULL", "JOIN", "LATERAL", "LEADING", "LEFT", "LIKE", "LIMIT", "LOCALTIME",
        "LOCALTIMESTAMP", "NATURAL", "NOT", "NOTNULL", "NULL", "OFFSET", "ON", "ONLY", "OR", "ORDER", "OUTER",
        "OVERLAPS", "PLACING", "PRIMARY", "REFERENCES", "RETURNING", "RIGHT", "SELECT", "SESSION_USER", "SIMILAR",
        "SOME", "SYMMETRIC", "TABLE", "TABLESAMPLE", "THEN", "TO", "TRAILING", "TRUE", "UNION", "UNIQUE", "USER",
        "USING", "VARIADIC", "VERBOSE", "WHEN", "WHERE", "WINDOW", "WITH",
    ]

    /// Every word highlighted as a keyword.
    static let keywords: Set<String> = reserved.union([
        "ABORT", "ACTION", "ADD", "ADMIN", "AFTER", "AGGREGATE", "ALSO", "ALTER", "ALWAYS", "ATTACH", "BEFORE", "BEGIN",
        "BETWEEN", "BY", "CACHE", "CALL", "CALLED", "CASCADE", "CASCADED", "CHAIN", "CHECKPOINT", "CLOSE", "CLUSTER",
        "COMMENT", "COMMENTS", "COMMIT", "COMMITTED", "CONFLICT", "CONNECTION", "CONSTRAINTS", "CONTINUE", "COPY",
        "COST", "CSV", "CUBE", "CURSOR", "CYCLE", "DATA", "DATABASE", "DEALLOCATE", "DECLARE", "DEFAULTS", "DEFERRED",
        "DEFINER", "DELETE", "DELIMITER", "DEPENDS", "DETACH", "DISABLE", "DISCARD", "DOMAIN", "DROP", "EACH", "ENABLE",
        "ENCODING", "ENUM", "ESCAPE", "EVENT", "EXCLUDE", "EXCLUDING", "EXCLUSIVE", "EXECUTE", "EXISTS", "EXPLAIN",
        "EXTENSION", "EXTERNAL", "FILTER", "FIRST", "FOLLOWING", "FORCE", "FUNCTION", "FUNCTIONS", "GENERATED",
        "GLOBAL", "GRANTED", "GROUPING", "HANDLER", "HOLD", "IDENTITY", "IF", "IMMEDIATE", "IMMUTABLE", "IMPORT",
        "INCLUDE", "INCLUDING", "INCREMENT", "INDEX", "INDEXES", "INHERIT", "INHERITS", "INPUT", "INSERT", "INSTEAD",
        "INVOKER", "ISOLATION", "KEY", "LANGUAGE", "LARGE", "LAST", "LEVEL", "LISTEN", "LOAD", "LOCAL", "LOCK", "LOCKED",
        "LOGGED", "MATCH", "MATCHED", "MATERIALIZED", "MAXVALUE", "MERGE", "METHOD", "MINVALUE", "MODE", "MOVE", "NAMES",
        "NEW", "NEXT", "NO", "NOTHING", "NOTIFY", "NOWAIT", "NULLS", "OBJECT", "OF", "OFF", "OIDS", "OLD", "OPERATOR",
        "OPTION", "OPTIONS", "ORDINALITY", "OTHERS", "OVER", "OVERRIDING", "OWNED", "OWNER", "PARALLEL", "PARTITION",
        "PARTITIONED", "PASSWORD", "PLANS", "POLICY", "PRECEDING", "PREPARE", "PREPARED", "PRESERVE", "PRIOR",
        "PRIVILEGES", "PROCEDURAL", "PROCEDURE", "PROCEDURES", "PUBLICATION", "RANGE", "READ", "REASSIGN", "RECURSIVE",
        "REFERENCING", "REFRESH", "REINDEX", "RELEASE", "RENAME", "REPEATABLE", "REPLACE", "REPLICA", "RESET",
        "RESTART", "RESTRICT", "RETURN", "RETURNS", "REVOKE", "ROLE", "ROLLBACK", "ROLLUP", "ROUTINE", "ROUTINES",
        "ROW", "ROWS", "RULE", "SAVEPOINT", "SCHEMA", "SCHEMAS", "SCROLL", "SEARCH", "SECURITY", "SEQUENCE", "SEQUENCES",
        "SERIALIZABLE", "SERVER", "SESSION", "SET", "SETS", "SHARE", "SHOW", "SIMPLE", "SKIP", "SNAPSHOT", "STABLE",
        "STANDALONE", "START", "STATEMENT", "STATISTICS", "STDIN", "STDOUT", "STORAGE", "STORED", "STRICT",
        "SUBSCRIPTION", "SYSTEM", "TABLES", "TABLESPACE", "TEMP", "TEMPLATE", "TEMPORARY", "TIES", "TRANSACTION",
        "TRIGGER", "TRUNCATE", "TRUSTED", "TYPE", "TYPES", "UNBOUNDED", "UNCOMMITTED", "UNLISTEN", "UNLOGGED", "UNTIL",
        "UPDATE", "VACUUM", "VALID", "VALIDATE", "VALUE", "VALUES", "VERSION", "VIEW", "VIEWS", "VOLATILE", "WITHIN",
        "WITHOUT", "WORK", "WRAPPER", "WRITE", "ZONE",
    ])

    static let types: Set<String> = [
        "BIGINT", "BIGSERIAL", "BIT", "BOOL", "BOOLEAN", "BOX", "BYTEA", "CHAR", "CHARACTER", "CIDR", "CIRCLE", "DATE",
        "DATERANGE", "DECIMAL", "DOUBLE", "FLOAT", "FLOAT4", "FLOAT8", "INET", "INT", "INT2", "INT4", "INT4RANGE", "INT8",
        "INT8RANGE", "INTEGER", "INTERVAL", "JSON", "JSONB", "JSONPATH", "LINE", "LSEG", "MACADDR", "MONEY", "NUMERIC",
        "NUMRANGE", "OID", "PATH", "POINT", "POLYGON", "PRECISION", "REAL", "REGCLASS", "SERIAL", "SERIAL4", "SERIAL8",
        "SMALLINT", "SMALLSERIAL", "TEXT", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "TIMETZ", "TSQUERY", "TSRANGE",
        "TSTZRANGE", "TSVECTOR", "UUID", "VARBIT", "VARCHAR", "VARYING", "XML",
    ]

    /// Built-in functions offered by autocomplete (name, short signature).
    static let functions: [(name: String, signature: String)] = [
        ("count", "count(*)"), ("sum", "sum(expr)"), ("avg", "avg(expr)"), ("min", "min(expr)"), ("max", "max(expr)"),
        ("coalesce", "coalesce(a, b, …)"), ("nullif", "nullif(a, b)"), ("greatest", "greatest(a, …)"), ("least", "least(a, …)"),
        ("now", "now() → timestamptz"), ("current_date", "date"), ("current_timestamp", "timestamptz"),
        ("date_trunc", "date_trunc(field, ts)"), ("date_part", "date_part(field, ts)"), ("extract", "extract(field FROM ts)"),
        ("age", "age(ts, ts)"), ("to_char", "to_char(value, format)"), ("to_date", "to_date(text, format)"),
        ("to_timestamp", "to_timestamp(text, format)"), ("make_date", "make_date(y, m, d)"), ("make_interval", "make_interval(…)"),
        ("lower", "lower(text)"), ("upper", "upper(text)"), ("length", "length(text)"), ("trim", "trim(text)"),
        ("btrim", "btrim(text, chars)"), ("ltrim", "ltrim(text)"), ("rtrim", "rtrim(text)"), ("substring", "substring(text FROM …)"),
        ("replace", "replace(text, from, to)"), ("concat", "concat(a, …)"), ("concat_ws", "concat_ws(sep, a, …)"),
        ("split_part", "split_part(text, sep, n)"), ("position", "position(sub IN text)"), ("left", "left(text, n)"),
        ("right", "right(text, n)"), ("initcap", "initcap(text)"), ("format", "format(fmt, …)"), ("md5", "md5(text)"),
        ("regexp_replace", "regexp_replace(text, re, repl)"), ("regexp_match", "regexp_match(text, re)"),
        ("string_agg", "string_agg(expr, sep)"), ("array_agg", "array_agg(expr)"), ("array_length", "array_length(arr, dim)"),
        ("unnest", "unnest(array)"), ("array_to_string", "array_to_string(arr, sep)"), ("cardinality", "cardinality(arr)"),
        ("json_agg", "json_agg(expr)"), ("jsonb_agg", "jsonb_agg(expr)"), ("json_build_object", "json_build_object(k, v, …)"),
        ("jsonb_build_object", "jsonb_build_object(k, v, …)"), ("jsonb_set", "jsonb_set(target, path, value)"),
        ("jsonb_array_elements", "jsonb_array_elements(jsonb)"), ("jsonb_each", "jsonb_each(jsonb)"),
        ("jsonb_object_keys", "jsonb_object_keys(jsonb)"), ("jsonb_pretty", "jsonb_pretty(jsonb)"), ("to_jsonb", "to_jsonb(value)"),
        ("row_number", "row_number() OVER (…)"), ("rank", "rank() OVER (…)"), ("dense_rank", "dense_rank() OVER (…)"),
        ("lag", "lag(expr) OVER (…)"), ("lead", "lead(expr) OVER (…)"), ("first_value", "first_value(expr) OVER (…)"),
        ("last_value", "last_value(expr) OVER (…)"), ("ntile", "ntile(n) OVER (…)"),
        ("abs", "abs(n)"), ("round", "round(n, digits)"), ("ceil", "ceil(n)"), ("floor", "floor(n)"), ("mod", "mod(a, b)"),
        ("power", "power(a, b)"), ("sqrt", "sqrt(n)"), ("random", "random()"), ("gen_random_uuid", "gen_random_uuid() → uuid"),
        ("generate_series", "generate_series(start, stop, step)"), ("pg_size_pretty", "pg_size_pretty(bigint)"),
        ("pg_total_relation_size", "pg_total_relation_size(regclass)"), ("current_setting", "current_setting(name)"),
        ("bool_and", "bool_and(expr)"), ("bool_or", "bool_or(expr)"), ("percentile_cont", "percentile_cont(f) WITHIN GROUP (…)"),
    ]

    /// Keywords offered at the start of a statement.
    static let statementStarters = [
        "SELECT", "WITH", "INSERT INTO", "UPDATE", "DELETE FROM", "CREATE TABLE", "CREATE INDEX", "CREATE VIEW",
        "ALTER TABLE", "DROP TABLE", "TRUNCATE", "EXPLAIN", "EXPLAIN ANALYZE", "BEGIN", "COMMIT", "ROLLBACK", "SHOW",
        "SET", "VALUES", "GRANT", "REVOKE", "VACUUM", "ANALYZE", "COPY", "CALL",
    ]

    /// Keywords that typically follow a relation in FROM / JOIN / UPDATE.
    static let afterRelation = [
        "WHERE", "JOIN", "LEFT JOIN", "INNER JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN", "ON", "USING", "AS",
        "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "SET", "UNION", "UNION ALL", "RETURNING", "VALUES",
        "WINDOW", "FOR UPDATE",
    ]

    /// Keywords that commonly follow an expression in a column clause.
    static let afterExpression = [
        "AND", "OR", "AS", "FROM", "WHERE", "IS NULL", "IS NOT NULL", "IN", "NOT IN", "LIKE", "ILIKE", "BETWEEN",
        "ASC", "DESC", "NULLS FIRST", "NULLS LAST", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "JOIN",
        "LEFT JOIN", "UNION", "THEN", "ELSE", "END", "WHEN", "RETURNING", "DISTINCT", "OVER",
    ]

    /// Keywords offered inside expressions (select list, WHERE, ON …).
    static let expressionKeywords = [
        "DISTINCT", "CASE", "WHEN", "THEN", "ELSE", "END", "NOT", "NULL", "TRUE", "FALSE", "EXISTS", "CAST", "INTERVAL",
        "AND", "OR", "IN", "IS", "LIKE", "ILIKE", "BETWEEN", "AS", "FROM", "WHERE", "ASC", "DESC",
    ]

    static var allCompletionKeywords: [String] {
        var seen = Set<String>()
        return (statementStarters + afterRelation + afterExpression + expressionKeywords + keywords.sorted())
            .filter { seen.insert($0).inserted }
    }
}
