// Test queries for the QoD (Quack on Demand) connector.
// Run individually from the VS Code Power Query SDK ("Evaluate current file").
//
// Set credentials first via the SDK "Set credential" command for the chosen
// AuthenticationKind (UsernamePassword / Key / OAuth).
//
// Signature: QoD.Database(server, tenant, pool, trustServerCertificate, [options]).
// `trustServerCertificate` is REQUIRED (true = skip TLS cert check, for a
// self-signed dev endpoint; false = verify, for production).

let
    // 1. Smoke test: open the data source and list catalogs/schemas.
    Source = QoD.Database("quack.example.com:31338", "tpch", "sales", true)
in
    Source

// --- Additional checks (uncomment one at a time) --------------------------

// Navigate to a table and preview rows (validates Import mode):
// let
//     Source = QoD.Database("quack.example.com:31338", "tpch", "sales", true),
//     Table  = Source{[Name = "lineitem", Kind = "Table"]}[Data]
// in
//     Table.FirstN(Table, 100)

// Validate query folding (DirectQuery): a filtered + grouped query should
// fold to Flight SQL. Inspect with Value.Metadata / "View Native Query".
// let
//     Source   = QoD.Database("quack.example.com:31338", "tpch", "sales", true),
//     orders   = Source{[Name = "orders", Kind = "Table"]}[Data],
//     filtered = Table.SelectRows(orders, each [o_orderstatus] = "O"),
//     grouped  = Table.Group(filtered, {"o_orderpriority"}, {{"cnt", each Table.RowCount(_), Int64.Type}})
// in
//     grouped

// Advanced options (TLS off for local dev, custom timeout). NOTE the parameter
// order: (server, tenant, pool, trustServerCertificate as logical, options as
// record). The options record is the 5th arg — passing it as the 4th hits the
// logical `trustServerCertificate` slot and errors "convert Record to Logical".
// QoD.Database("localhost:31338", "tpch", "sales", true, [UseEncryption = false, CommandTimeout = 120])
