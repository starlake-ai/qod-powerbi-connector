// Folding: column projection (SELECT list).
let
    Source = QoD.Database("localhost:31338", "acme", "bi", true, false),
    db = Source{[Name = "acme_tpch", Kind = "Database"]}[Data],
    schema = db{[Name = "tpch1", Kind = "Schema"]}[Data],
    region = schema{[Name = "region", Kind = "Table"]}[Data],
    projected = Table.SelectColumns(region, {"r_regionkey", "r_name"}),
    sorted = Table.Sort(projected, {{"r_regionkey", Order.Ascending}})
in
    sorted
