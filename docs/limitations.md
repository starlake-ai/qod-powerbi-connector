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

## PATs do not work on the Flight SQL edge

QoD personal access tokens (`qod_pat_...`) are REST-plane credentials: the
manager API accepts them, but the Flight SQL edge's bearer chain validates only
external JWTs (`JWT_SECRET_KEY` / `JWT_PUBLIC_KEY_PATH`) and OIDC provider
tokens. A PAT entered in the connector's Access token credential is rejected
with UNAUTHENTICATED. Verified live 2026-09-02. Making the edge accept PATs
would be a QoD-side change with its own review, not a connector change.

## Types a DuckLake tenant-db cannot hold

`BIT`, `VARINT`, and fixed-size arrays (`INTEGER[3]`) are refused by DuckLake at DDL
time ("Failed to convert DuckDB type to DuckLake"), so they cannot occur in QoD
tenant-db tables and the connector defines no mapping for them. `TIMESTAMP_NS`
values lose sub-100ns precision in M (M datetimes tick at 100ns).

## An RBAC denial mid-query surfaces as a credential error

When the edge denies a statement (ACL) after the connection is established, the
mashup engine reports "The credentials provided for the QoD source are invalid"
(AccessUnauthorized) rather than a permission message, and the evaluation
aborts; an M-level `try` cannot intercept it. In practice this appears when a
native query touches an ungranted table. Navigation never triggers it because
every metadata query the connector issues is RBAC-filtered rather than denied.
