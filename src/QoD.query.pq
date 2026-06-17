// Test queries for the QoD (Quack on Demand) connector.
// Run individually from the VS Code Power Query SDK ("Evaluate current file").
//
// Set credentials first via the SDK "Set credential" command for the chosen
// AuthenticationKind (UsernamePassword / Key / OAuth).

let
    // 1. Smoke test: open the data source and list catalogs/schemas.
    Source = QoD.Database("quack.example.com:31338", "tpch", "sales")
in
    Source

// --- Additional checks (uncomment one at a time) --------------------------

// Navigate to a table and preview rows (validates Import mode):
// let
//     Source = QoD.Database("quack.example.com:31338", "tpch", "sales"),
//     Table  = Source{[Name = "lineitem", Kind = "Table"]}[Data]
// in
//     Table.FirstN(Table, 100)

// Validate query folding (DirectQuery): a filtered + grouped query should
// fold to Flight SQL. Inspect with Value.Metadata / "View Native Query".
// let
//     Source   = QoD.Database("quack.example.com:31338", "tpch", "sales"),
//     orders   = Source{[Name = "orders", Kind = "Table"]}[Data],
//     filtered = Table.SelectRows(orders, each [o_orderstatus] = "O"),
//     grouped  = Table.Group(filtered, {"o_orderpriority"}, {{"cnt", each Table.RowCount(_), Int64.Type}})
// in
//     grouped

// Advanced options (TLS off for local dev, custom timeout):
// QoD.Database("localhost:31338", "tpch", "sales", [UseEncryption = false, CommandTimeout = 120])
