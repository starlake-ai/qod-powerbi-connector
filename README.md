# QoD - Quack on Demand Power BI Connector

A Power BI / Microsoft Fabric **custom connector** for
[Quack on Demand](https://github.com/starlake-ai/quack-on-demand), connecting over
**Apache Arrow Flight SQL** and targeting Microsoft **certification**.

## What this is

Quack on Demand exposes a multi-tenant DuckDB gateway over **Arrow Flight SQL**
(`:31338`, TLS). This connector lets Power BI **Get Data → Quack on Demand**,
pick a tenant/pool, authenticate, and query in **Import or DirectQuery** mode.

## How it connects

```
Power BI ──M──▶ QoD.mez ──Adbc.Connection──▶ FlightSQL ADBC driver (in-box) ──Flight SQL──▶ Quack gateway ──▶ DuckDB
```

The connector wraps **`Adbc.Connection`**, the M engine's ADBC entry point, over
the **FlightSQL ADBC driver that ships in-box** with Power BI Desktop and the
Power Query SDK - no driver installation on the client or gateway. The ADBC core
is adapted from Microsoft's MIT-licensed
[DuckDbFlightSQL sample](https://github.com/microsoft/DataConnectors/tree/master/samples/DuckDbFlightSQL)
(see [NOTICE](NOTICE)); QoD serves DuckDB over Flight SQL, so the sample's SQL
generator and type map carry over unchanged, giving **query folding** (filters,
projections, aggregations, top-N, joins pushed down as SQL) for free.

The previous transport, `Odbc.DataSource` over the Arrow Flight SQL ODBC driver,
was blocked on driver maturity (Dremio's v0.9.7 beta errors on Power BI's
`SQLGetInfo(SQL_DBMS_NAME)` probe). It lives in this repo's git history; the
analysis survives in [docs/architecture.md](docs/architecture.md).

## Authentication (all three supported)

| Credential in Power BI | Maps to Quack backend           |
|------------------------|---------------------------------|
| Username / password    | Postgres / BCrypt               |
| Access token (JWT)     | External JWT (HS256/RS256)      |
| OAuth 2.0 / OIDC       | Keycloak / Entra ID / Google / Cognito |

Per-method setup (including the customer-side Keycloak/OAuth client) is in
**[docs/authentication.md](docs/authentication.md)**.

Sessions are scoped by the `tenant` and `pool` gRPC call headers on every RPC.
All enforcement (table ACLs, column masking, row policies, metadata filtering)
happens server-side at the QoD edge; the connector is a plain ADBC client and
holds no privileged access.

## Layout

```
src/
  QoD.pq                connector logic (Adbc.Connection, navigation, auth)
  QoDAdbcConfig.pqm     ADBC driver configuration (in-box FlightSQL driver)
  TypeInfo.pqm          DuckDB native type -> M type map
  SqlGenerator.pqm      DuckDB dialect SQL generation (query folding)
  SqlGeneratorCommon.pqm shared folding machinery
  QoD.query.pq          test queries (smoke / navigation / folding)
  QoD.proj              MSBuild project -> QoD.mez
  resources.resx        localized UI strings
  icons/                connector icons + generator script
Tests/
  Rbac/                 two-user RBAC navigation acceptance test (Python/ADBC)
  ...                   SDK test framework assets (settings, baselines)
docs/
  connecting.md         installation and connection guide (ADBC path)
  limitations.md        known limitations
  resolved-questions.md verified facts from live testing against QoD
  architecture.md       data path history + the ODBC-era analysis
  authentication.md     auth methods + IdP (Keycloak/OAuth) setup for customers
  certification.md      Microsoft certification checklist & process
  quack-server-spec.md  server-side requirements to hand to the Quack team
CHANGELOG.md            versioned change history
NOTICE                  MIT attribution for the vendored Microsoft sample
```

## Install

See **[INSTALL.md](INSTALL.md)** for full install instructions - building from
source, dropping in a pre-built **unsigned** `.mez` (dev), or deploying a
**signed** `.pqx` (production). No ODBC/ADBC driver install is needed: the
FlightSQL ADBC driver ships with Power BI Desktop (verified against
2.152.882.0; documented minimum for `Adbc.Connection` is 2.145.1105.0).

## Build

The `.mez` is a flat zip of `QoD.pq`, the four `.pqm` modules,
`resources.resx`, and the icon PNGs (this is exactly what the release
workflows do):

```sh
cd src && zip -X ../bin/Release/QoD.mez QoD.pq *.pqm resources.resx icons/QoD*.png -j
```

Or use the **VS Code "Power Query SDK"** extension → *Build connector project*
(`dotnet build src/QoD.proj -c Release`), which also validates the M.

## Develop / test

1. Build `QoD.mez`.
2. In VS Code SDK: *Set credential* for the auth kind you're testing.
3. *Evaluate* `src/QoD.query.pq` (defaults target a local `qod demo`:
   tenant `acme`, pool `bi`, credential alice / demo-alice).
4. To test in Desktop: copy `QoD.mez` to
   `Documents\Power BI Desktop\Custom Connectors\` and enable
   *Allow any extension* (File → Options → Security) for unsigned dev builds.
5. RBAC acceptance: `python3 Tests/Rbac/rbac_navigation_test.py` against a
   running `qod demo` proves the navigator inherits QoD's RBAC (alice sees 4
   tables, acme-admin sees 8).

## Decisions

- **Transport:** `Adbc.Connection` over the in-box **FlightSQL ADBC** driver.
  The ODBC route is retired (driver immaturity; see *How it connects*).
- **tenant/pool:** conveyed as native Flight SQL gRPC call headers
  (`adbc.flight.sql.rpc.call_header.*`), reusing the same routing contract
  Quack already honors for JDBC and Python ADBC - so **no server change**.
- **Navigation top level:** `SELECT current_database()`, never `SHOW DATABASES`
  - the edge admits the latter unfiltered and its Prepare-time probe cannot
  wrap it. See [docs/resolved-questions.md](docs/resolved-questions.md).
- **Relationships:** PK/FK detection degrades to "no keys" against QoD
  DuckLake tenant-dbs (RBAC-denied without a covering grant, and DuckLake
  records no constraints). See [docs/limitations.md](docs/limitations.md).

## Status / path to certification

**2026-09-02: the ADBC transport is implemented and verified end-to-end** in
Power BI Desktop against a live `qod demo` instance (TLS, Basic auth,
tenant/pool routing, RBAC-filtered navigation, column masking, row policies).

- [x] ADBC connector core (`Adbc.Connection`, in-box driver, query folding
      machinery from the Microsoft sample).
- [x] Verified in Power BI Desktop 2.152.882.0: connect, navigate, preview,
      masked/filtered data as a restricted principal.
- [x] RBAC navigation acceptance test (two-user diff), repeatable against
      `qod demo`.
- [ ] Type map reconciliation against QoD's `GetXdbcTypeInfo` (plan Phase 3).
- [ ] Folding diagnostics baselines via the SDK test framework (plan Phase 4).
- [ ] DirectQuery validation pass + Service/gateway story (plan Phase 6;
      docs/resolved-questions.md Q1).
- [ ] Fill in real OIDC endpoints / `client_id` / scopes in `OAuthConfig`.
- [ ] Provide a public test instance + per-auth credentials for certification.
- [x] Connector icons sourced from the official Quack on Demand brand mark.

## Notes

- The repo directory is named `qod-powerbi-connector`; the connector identifier
  and display name are **QoD** / **Quack on Demand**.
- Icons are downscaled from the official brand mark
  (`src/icons/source/qod-mark-512.png`) by `src/icons/generate-icons.ps1`.
