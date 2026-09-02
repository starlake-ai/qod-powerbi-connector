// Folding: inner join nation x region, projected and sorted; 25-row result.
let
    Source = QoD.Database("localhost:31338", "acme", "bi", true, false),
    db = Source{[Name = "acme_tpch", Kind = "Database"]}[Data],
    schema = db{[Name = "tpch1", Kind = "Schema"]}[Data],
    nation = schema{[Name = "nation", Kind = "Table"]}[Data],
    region = schema{[Name = "region", Kind = "Table"]}[Data],
    joined = Table.NestedJoin(nation, {"n_regionkey"}, region, {"r_regionkey"}, "r", JoinKind.Inner),
    expanded = Table.ExpandTableColumn(joined, "r", {"r_name"}),
    projected = Table.SelectColumns(expanded, {"n_name", "r_name"}),
    sorted = Table.Sort(projected, {{"n_name", Order.Ascending}})
in
    sorted
