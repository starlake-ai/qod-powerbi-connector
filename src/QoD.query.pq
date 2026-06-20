// Test queries for the QoD (Quack on Demand) connector.
// Run individually from the VS Code Power Query SDK ("Evaluate current file").
//
// Set credentials first via the SDK "Set credential" command for the chosen
// AuthenticationKind (UsernamePassword / Key / OAuth).
//
// Signature: QoD.Database(server, tenant, pool, trustServerCertificate, superuser, [options]).
// `trustServerCertificate` is REQUIRED (true = skip TLS cert check, for a
// self-signed dev endpoint; false = verify, for production).
// `superuser` is REQUIRED (true = request system-user/all-access mode, granted
// only if the server recognizes your account as a system user; false = normal).

let
    // 1. Smoke test: open the data source and list catalogs/schemas.
    Source = QoD.Database("quack.example.com:31338", "tpch", "sales", true, false)
in
    Source

// --- Additional checks (uncomment one at a time) --------------------------

// Navigate to a table and preview rows (validates Import mode):
// let
//     Source = QoD.Database("quack.example.com:31338", "tpch", "sales", true, false),
//     Table  = Source{[Name = "lineitem", Kind = "Table"]}[Data]
// in
//     Table.FirstN(Table, 100)

// Validate query folding (DirectQuery): a filtered + grouped query should
// fold to Flight SQL. Inspect with Value.Metadata / "View Native Query".
// let
//     Source   = QoD.Database("quack.example.com:31338", "tpch", "sales", true, false),
//     orders   = Source{[Name = "orders", Kind = "Table"]}[Data],
//     filtered = Table.SelectRows(orders, each [o_orderstatus] = "O"),
//     grouped  = Table.Group(filtered, {"o_orderpriority"}, {{"cnt", each Table.RowCount(_), Int64.Type}})
// in
//     grouped

// Advanced options (TLS off for local dev, custom timeout). NOTE the parameter
// order: (server, tenant, pool, trustServerCertificate as logical, superuser as
// logical, options as record). The options record is the 6th arg - passing it in
// a logical slot errors "convert Record to Logical".
// QoD.Database("localhost:31338", "tpch", "sales", true, false, [UseEncryption = false, CommandTimeout = 120])

// System-user mode: request all-access. The server grants it only if the
// authenticated account is a configured system user; otherwise normal RBAC.
// let
//     Source = QoD.Database("quack.example.com:31338", "tpch", "sales", true, true)
// in
//     Source
