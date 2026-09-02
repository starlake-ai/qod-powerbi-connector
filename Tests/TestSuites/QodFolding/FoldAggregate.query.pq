// Folding: GROUP BY + COUNT over the 150k-row orders table; 5-row result.
let
    Source = QoD.Database("localhost:31338", "acme", "bi", true, false),
    db = Source{[Name = "acme_tpch", Kind = "Database"]}[Data],
    schema = db{[Name = "tpch1", Kind = "Schema"]}[Data],
    orders = schema{[Name = "orders", Kind = "Table"]}[Data],
    grouped = Table.Group(orders, {"o_orderpriority"}, {{"cnt", each Table.RowCount(_), Int64.Type}}),
    sorted = Table.Sort(grouped, {{"o_orderpriority", Order.Ascending}})
in
    sorted
