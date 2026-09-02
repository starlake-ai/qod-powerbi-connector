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
