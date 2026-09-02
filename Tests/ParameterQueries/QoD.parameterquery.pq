// Parameter query for the SDK test framework. The table fixtures (NycTaxiData
// etc.) come from the sample's Tests/TestSuites/Setup/load_test_data.ps1 and
// must be loaded into the QoD demo tenant-db before the Standard/Sanity suites
// run; that dataset load is Phase 4 work. Until then only the connect line is
// adapted to QoD (tenant acme, pool bi, self-signed demo cert).
let
    Source = QoD.Database("localhost:31338", "acme", "bi", true, false),
    database = Source{[Name = "acme_tpch", Kind = "Database"]}[Data],
    main_Schema = database{[Name = "tpch1", Kind = "Schema"]}[Data],
    misc_table = main_Schema{[Name = "misc_table", Kind = "Table"]}[Data],
    nyctaxidata_Table = main_Schema{[Name = "NycTaxiData", Kind = "Table"]}[Data],
    taxizonelookup_Table = main_Schema{[Name = "TaxiZoneLookup", Kind = "Table"]}[Data],
    taxidate_Table = main_Schema{[Name = "NycTaxiDateData", Kind = "Table"]}[Data],
    textSamples_Table = main_Schema{[Name = "TEXT_SAMPLES", Kind = "Table"]}[Data],
    extendedTypes_Table = main_Schema{[Name = "ExtendedTypes", Kind = "Table"]}[Data],
    nestedTypes_Table = main_Schema{[Name = "NestedTypes", Kind = "Table"]}[Data],
    nycTaxiSummary_View = main_Schema{[Name = "NycTaxiSummary", Kind = "View"]}[Data]
in
    [zone_table = taxizonelookup_Table, taxi_table = nyctaxidata_Table, taxi_date_table = taxidate_Table, text_samples_table = textSamples_Table, misc_table = misc_table, extended_types_table = extendedTypes_Table, nested_types_table = nestedTypes_Table, taxi_summary_view = nycTaxiSummary_View]
