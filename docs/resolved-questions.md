# Resolved and open questions

The implementation plan (qod-powerbi-connector-plan.md) listed three questions to settle
before the phases that depend on them. Status as of 2026-09-02.

## Q1: Does Power BI Service need an on-premises data gateway for this connector? (OPEN)

Not yet resolved. Gates Phase 6. Microsoft's certification guidance (ODBC-era) says custom
connectors require the gateway; the ADBC docs say FlightSQL needs no separate driver
install. Whether the in-box driver changes the Service/gateway requirement must be
verified against a real Power BI Service tenant before the Service story is documented.

## Q2: Minimum Power BI Desktop build exposing Adbc.Connection (VERIFIED against a real install)

The development machine runs Power BI Desktop **2.152.882.0 (26.03)**, well past the
2.145.1105.0 (July 2025) floor documented for the Databricks ADBC driver. The in-box
FlightSQL ADBC driver is present at:

    C:\Program Files\Microsoft Power BI Desktop\bin\ADBC Drivers\FlightSQL\libadbc_driver_flightsql.dll

No separate driver install is needed. A live `Adbc.Connection` evaluation through this
build is the remaining confirmation and happens as part of the Phase 1 acceptance test.

## Q3: Is `SHOW DATABASES` RBAC-filtered by QoD? (RESOLVED: NO, it is unfiltered)

Verified against `starlake-ai/quack-on-demand` at `3aa42c8b`:

- `SHOW DATABASES` parses as a ControlFlow statement (no table refs), so
  `PostgresAclValidator` admits it unconditionally
  (`src/main/scala/ai/starlake/acl/parser/StatementResult.scala:46`).
- `MetadataFilterRewriter.processOne` rewrites only SELECT and plain SHOW TABLES; every
  other statement falls to the `other` arm, which keeps the text unchanged as long as it
  contains no filterable `information_schema` reference
  (`src/main/scala/ai/starlake/quack/edge/meta/MetadataFilterRewriter.scala:137-165`).
- `SHOW DATABASES` therefore executes natively on the node and returns every database
  attached to that DuckDB instance, with no per-principal filtering.

Live verification against a running demo instance (2026-09-02) went further: as user
`alice`, `SHOW DATABASES` does not even execute. It fails with
`INTERNAL: [FlightSQL] internal error (Internal; Prepare)` because the edge's
Prepare-time `LIMIT 0` schema probe cannot wrap it. So the sample's top navigation level
is broken against QoD regardless of the RBAC question, and the collapse of the Databases
level to the session catalog (`SELECT current_database()`, verified to return the
session's tenant-db) is required for Phase 1, not just advisable for Phase 2. The
connector implements it. (`SHOW TABLES` by contrast IS handled by the edge: plain form
replaced by a filtered listing, variants refused fail-closed.)

Also verified live (Tests/Rbac/rbac_navigation_test.py): the sample's PK query against
`table_constraints` / `key_column_usage` is denied for a principal without a covering
grant (`access denied: user:alice lacks grants on
acme_tpch.information_schema.table_constraints:Read`; alice holds only the demo's
analyst role) and IS admitted for a principal holding `ALL` on `*.*.*` (acme-admin), so
the wildcard does cover the constraint relations. Either way the result is empty
against a DuckLake tenant-db: `information_schema.table_constraints` holds zero rows
because DuckLake does not record PK/FK constraints. Relationship detection therefore
takes the connector's `try` fallback (no keys) for everyone, for two independent
reasons. The connector's schema, table, and column navigation queries were all verified
to succeed and to return the RBAC-filtered listing.

## Auth-kind verification matrix (live, 2026-09-02, through adbc_driver_flightsql)

- **UsernamePassword**: verified (alice via Flight Basic handshake; RBAC, masking,
  row policies all bind). Superuser mode also verified: admin + the `superuser`
  call header reads tables no tenant grant covers.
- **Key (Access token)**: verified with an external HS256 JWT against an edge
  booted with `JWT_SECRET_KEY`. The identity binds to the matching qodstate user
  (masking and grants applied); a tampered signature is rejected UNAUTHENTICATED;
  an edge with no bearer providers configured answers "No bearer auth providers
  configured". QoD PATs are NOT accepted on the Flight edge (see limitations.md).
- **OAuth**: wire-identical to Key (the access token rides the same
  Authorization: Bearer property), so the transport is covered by the Key
  verification; the interactive PKCE flow and edge-side OIDC provider config
  still need an IdP-equipped environment to exercise.

## Phase 3 type reconciliation (live, 2026-09-02)

QoD's `GetXdbcTypeInfo` (`TypeInfoCatalog.scala`) reports 19 primitive rows. Notable
deltas against the vendored sample's map, all reconciled in QoD's favour:

- The server reports `REAL` (SQL_REAL); `information_schema.columns` canonicalizes it
  to `FLOAT` (likewise `CHAR` -> `VARCHAR`, `BINARY` -> `BLOB`), so both names are now
  in TypeInfo.pqm and TypeFacets.
- `TIMESTAMP_S` / `TIMESTAMP_MS` / `TIMESTAMP_NS` reach information_schema as distinct
  strings and arrive as `timestamp[s|ms|ns]` Arrow columns; they were missing from the
  sample's maps and degraded to `type any`. Now mapped to `DateTime.Type`.
- Composite types (LIST, STRUCT, MAP) are intentionally absent from the server's
  XdbcTypeInfo (not representable as SQL_TYPE_* codes); the connector types them from
  the information_schema strings instead, unchanged from the sample.
- A DuckLake tenant-db refuses `BIT`, `VARINT`, and fixed-size `INTEGER[N]` arrays
  ("Failed to convert DuckDB type to DuckLake"), so the connector never encounters
  them.

`Tests/Types/type_baseline_test.py` pins the full 30-type (data_type, Arrow) matrix
plus the three rejections against a live `qod demo` (34 assertions). The M-side
`.pqout` baseline still needs PQTest from the Power Query SDK on a Windows host.

Incidental edge observation: every DDL statement makes the ADBC driver log
"FlightSQL endpoint returned inconsistent schema" (the edge advertises a `Count`
int64 result schema but DDL answers `Success` bool). Cosmetic on the client, but it
is a Flight SQL conformance wart in the QoD edge worth a main-repo issue.

## Phase 4 folding verification (live, 2026-09-02) and an RLS bypass found

PQTest (SdkTools 2.155.2) ran the folding suite in `Tests/TestSuites/QodFolding/`
as the restricted principal alice. Filter, projection, aggregation, top-N, and
join all genuinely fold (see the committed `.adbc.diagnostics`: WHERE with cast,
GROUP BY + COUNT, ORDER BY + LIMIT, INNER JOIN with aliases).

Two QoD-side findings came out of the screen-survival check:

1. **PermissionDenied aborts the evaluation as a credential error.** A
   mid-evaluation RBAC denial through the ADBC channel is mapped by the mashup
   engine to "credentials are invalid" (AccessUnauthorized) and is NOT catchable
   by an M-level `try`. This killed the sample's PK-detection query for alice and
   with it the whole navigation; the connector no longer issues constraint
   queries at all (see limitations.md).
2. **Quoted identifiers bypassed row-level security (fail-open).** Folded SQL
   quotes every identifier; `RowPolicyRewriter.maybeWrap` matched policies
   against jsqlparser's raw `getName` values, which keep the quotes, so
   `"tpch1"."customer"` escaped its row policy while the column masker (which
   unquotes before matching) still applied. Verified live: alice's folded
   DISTINCT returned all five market segments where the unquoted form returns
   only BUILDING. Fixed in quack-on-demand on branch
   `fix/rls-quoted-identifiers` (unquote for the match, keep the caller's
   quoting in the rewritten SQL) with spec coverage.
   `Tests/TestSuites/QodFolding/FoldRlsCls.query.pqout` pins the CORRECT
   single-row (BUILDING, ***) expectation, so the suite fails against an
   unfixed edge by design.
