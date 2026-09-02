// Folding: row filter (WHERE). Small deterministic result via tiny nation table.
let
    Source = QoD.Database("localhost:31338", "acme", "bi", true, false),
    db = Source{[Name = "acme_tpch", Kind = "Database"]}[Data],
    schema = db{[Name = "tpch1", Kind = "Schema"]}[Data],
    nation = schema{[Name = "nation", Kind = "Table"]}[Data],
    filtered = Table.SelectRows(nation, each [n_regionkey] = 0),
    sorted = Table.Sort(filtered, {{"n_name", Order.Ascending}})
in
    sorted
