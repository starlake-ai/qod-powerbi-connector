// Folding + policy screen: DISTINCT over the masked c_phone and RLS-filtered
// c_mktsegment as the restricted principal alice. Expected single row:
// (BUILDING, ***) - the row policy admits only BUILDING customers and the
// column policy masks the phone, both applied server-side inside folded SQL.
let
    Source = QoD.Database("localhost:31338", "acme", "bi", true, false),
    db = Source{[Name = "acme_tpch", Kind = "Database"]}[Data],
    schema = db{[Name = "tpch1", Kind = "Schema"]}[Data],
    customer = schema{[Name = "customer", Kind = "Table"]}[Data],
    projected = Table.SelectColumns(customer, {"c_mktsegment", "c_phone"}),
    distinctRows = Table.Distinct(projected)
in
    distinctRows
