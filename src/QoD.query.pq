// Test queries for the QoD (Quack on Demand) connector.
// Run individually from the VS Code Power Query SDK ("Evaluate current file").
//
// Set credentials first via the SDK "Set credential" command for the chosen
// AuthenticationKind (UsernamePassword / Key / OAuth).
//
// Signature: QoD.Database(server, tenant, pool, trustServerCertificate, superuser, [options]).
// `trustServerCertificate` is REQUIRED (true = skip TLS cert check, for a
// self-signed dev endpoint such as `qod demo`; false = verify, for production).
// `superuser` is REQUIRED (true = request system-user/all-access mode, granted
// only if the server recognizes your account as a system user; false = normal).

let
    // 1. Smoke test against a local `qod demo` instance (credential: alice /
    // demo-alice): open the data source and list the catalog/schemas.
    Source = QoD.Database("localhost:31338", "acme", "bi", true, false)
in
    Source

// --- Additional checks (uncomment one at a time) --------------------------

// Navigate to a table and preview rows (validates Import mode):
// let
//     Source = QoD.Database("localhost:31338", "acme", "bi", true, false),
//     db     = Source{[Name = "acme_tpch", Kind = "Database"]}[Data],
//     schema = db{[Name = "tpch1", Kind = "Schema"]}[Data],
//     Table  = schema{[Name = "orders", Kind = "Table"]}[Data]
// in
//     Table.FirstN(Table, 100)

// Validate query folding (DirectQuery): a filtered + grouped query should
// fold to Flight SQL. Inspect with Value.Metadata / "View Native Query".
// let
//     Source   = QoD.Database("localhost:31338", "acme", "bi", true, false),
//     db       = Source{[Name = "acme_tpch", Kind = "Database"]}[Data],
//     schema   = db{[Name = "tpch1", Kind = "Schema"]}[Data],
//     orders   = schema{[Name = "orders", Kind = "Table"]}[Data],
//     filtered = Table.SelectRows(orders, each [o_orderstatus] = "O"),
//     grouped  = Table.Group(filtered, {"o_orderpriority"}, {{"cnt", each Table.RowCount(_), Int64.Type}})
// in
//     grouped

// Advanced options (TLS off entirely, for a plain-gRPC dev edge). NOTE the
// parameter order: the options record is the 6th arg - passing it in a
// logical slot errors "convert Record to Logical".
// QoD.Database("localhost:31338", "acme", "bi", false, false, [UseEncryption = false])

// System-user mode: request all-access. The server grants it only if the
// authenticated account is a configured system user; otherwise the handshake
// is refused. (Demo: admin / admin with superuser = true.)
// let
//     Source = QoD.Database("localhost:31338", "acme", "bi", true, true)
// in
//     Source
