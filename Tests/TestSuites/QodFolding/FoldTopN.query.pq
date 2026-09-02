// Folding: ORDER BY + LIMIT (top-N) over orders.
let
    Source = QoD.Database("localhost:31338", "acme", "bi", true, false),
    db = Source{[Name = "acme_tpch", Kind = "Database"]}[Data],
    schema = db{[Name = "tpch1", Kind = "Schema"]}[Data],
    orders = schema{[Name = "orders", Kind = "Table"]}[Data],
    sorted = Table.Sort(orders, {{"o_totalprice", Order.Descending}}),
    top = Table.FirstN(sorted, 5),
    projected = Table.SelectColumns(top, {"o_orderkey", "o_totalprice"})
in
    projected
