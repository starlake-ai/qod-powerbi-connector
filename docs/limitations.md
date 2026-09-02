# Known limitations

## No automatic relationship (PK/FK) detection for normal principals

The vendored sample detects primary and foreign keys through
`information_schema.table_constraints`, `key_column_usage`, and
`constraint_column_usage`. Two independent reasons make this a no-op against QoD:

1. QoD's edge RBAC-filters only `{schemata, tables, columns, views}`; the constraint
   relations require a covering grant, so a normal principal's lookups are denied
   fail-closed (a wildcard `ALL` on `*.*.*` does cover them).
2. Even when admitted, the result is empty: DuckLake tenant-dbs record no PK/FK
   constraints, so `table_constraints` holds zero rows.

The connector silently falls back to "no keys" (the lookups are wrapped in `try`).
Model relationships must be defined manually in Power BI. See Phase 5 of the
implementation plan for the options; note that option 2 (Flight SQL metadata commands)
would inherit the same empty DuckLake catalog.

## Import mode copies data to the client

Power BI Import mode materializes the full dataset on the client machine by design. Only
DirectQuery keeps data server-side and therefore preserves QoD's residency story. Import
works but is not the recommended mode and is not tuned.

## Nested and exotic types degrade to text

`JSON`, `INTERVAL`, `MAP`, `UUID` map to `Text.Type`. `STRUCT` and `ARRAY` columns are
delivered as native Arrow struct/list values and surfaced as `type any` columns. The
Phase 3 reconciliation against QoD's `GetXdbcTypeInfo` will extend this list with
whatever else QoD reports that has no native M representation.

## Power BI Service support is unverified

Whether the Service can refresh through this connector without an on-premises data
gateway is open question 1 in docs/resolved-questions.md. Until it is resolved, treat
the connector as Power BI Desktop-only.

## Statements per session

The QoD edge runs each statement standalone; transaction toggling (autocommit off) is
not supported. This matches how the M engine drives ADBC, so it is not user-visible in
normal use.
