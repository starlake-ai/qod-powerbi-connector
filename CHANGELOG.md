# Changelog

All notable changes to the QoD (Quack on Demand) Power BI connector are recorded
here. This project adheres to [Semantic Versioning](https://semver.org/).

The connector version is the `[Version = "x.y.z"]` attribute at the top of
[src/QoD.pq](src/QoD.pq); keep the two in sync.

## [Unreleased]

## [2.0.0] - 2026-09-02 (Beta)

The ADBC transport, verified end-to-end in Power BI Desktop against a live
`qod demo` instance. Same data source kind, parameter surface, and auth kinds
as 1.0.0; the wire underneath changes completely.

### Changed
- **Transport: `Odbc.DataSource` replaced by `Adbc.Connection`** over the
  FlightSQL ADBC driver that ships in-box with Power BI Desktop (2.145.1105.0+)
  and the Power Query SDK. No driver install on client or gateway; the ODBC
  route (blocked on Flight SQL ODBC driver maturity) is retired to git history.
- Navigation is connector-driven (Database > Schemas > Tables via
  `information_schema`, folded through `Table.View`/`OnSelectRows`), inheriting
  QoD's RBAC-filtered metadata. The top level derives from
  `SELECT current_database()`; `SHOW DATABASES` is never issued (the edge
  admits it unfiltered and its Prepare probe cannot wrap it).
- Username/password now rides the Flight Basic handshake as driver
  `username`/`password` properties; Key (PAT/JWT) and OAuth ride
  `Authorization: Bearer` via `adbc.flight.sql.authorization_header`.
- tenant/pool/superuser ride as `adbc.flight.sql.rpc.call_header.*` entries;
  `trustServerCertificate` maps to the driver's `tls_skip_verify`;
  `options[UseEncryption]` switches grpc+tls/grpc.

### Added
- Query folding machinery (`SqlGenerator.pqm`, `SqlGeneratorCommon.pqm`) and
  DuckDB type map (`TypeInfo.pqm`) adapted from Microsoft's MIT-licensed
  DuckDbFlightSQL sample (vendored at `c7b9d81d`; attribution in `NOTICE`).
- `Tests/Rbac/rbac_navigation_test.py`: repeatable two-user acceptance test
  proving the navigator inherits QoD's RBAC (demo alice sees 4 tables,
  acme-admin 8), plus the SDK test framework tree from the sample.
- `docs/connecting.md`, `docs/limitations.md`, `docs/resolved-questions.md`
  (live-verified findings, including why relationship detection is a no-op
  against DuckLake tenant-dbs).

### Removed
- ODBC capability shaping (`SqlCapabilities`, `SQLGetInfo`/`SQLGetFunctions`
  overrides) and the `x-qod-authorization` header path; both were
  ODBC-transport artifacts. `options[ConnectionTimeout]`/`[CommandTimeout]`
  are not supported by the ADBC path.

## [1.0.0] - 2026-06-17 (Beta)

Initial Beta of the QoD custom connector, targeting Microsoft certification.

### Added
- `Odbc.DataSource`-based connector over the Apache Arrow Flight SQL ODBC driver,
  supporting both **Import** and **DirectQuery**.
- Three authentication kinds: **Username/password**, **Access token (JWT)**, and
  **OAuth 2.0 / OIDC** (authorization-code + PKCE).
- `TestConnection` handler for the on-premises data gateway and Service refresh.
- Tenant/pool scope conveyed as native Flight SQL gRPC call headers via the
  driver's `RPCCallHeaders` property (reuses Quack's existing JDBC header contract;
  no server change).
- DirectQuery capability shaping (`SqlCapabilities`, `SQLGetInfo`,
  `SQLGetFunctions`) and full icon set (16/20/24/32/40/48/64/80).
- All user-facing UI strings localized through `resources.resx`
  (`Extension.LoadString`) - field captions/descriptions and auth labels.

### Known limitations
- Quack does not support Flight SQL parameter binding; the connector inlines
  literals into folded SQL via the `Supports*Literals` capabilities instead. No
  prepared-statement parameter path is used (see server spec R9).
- Query folding not yet validated against a live Quack instance;
  `SQLGetFunctions` is set conservatively and will be widened to DuckDB's surface.
- OIDC endpoints/`client_id`/scopes in `OAuthConfig` are placeholders pending
  real provider values.
- The official C++ Flight SQL ODBC driver's registered name and auth key names
  are pending confirmation for the build Quack ships.

[Unreleased]: https://github.com/starlake-ai/quack-on-demand
[1.0.0]: https://github.com/starlake-ai/quack-on-demand
