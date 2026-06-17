# Changelog

All notable changes to the QoD (Quack on Demand) Power BI connector are recorded
here. This project adheres to [Semantic Versioning](https://semver.org/).

The connector version is the `[Version = "x.y.z"]` attribute at the top of
[src/QoD.pq](src/QoD.pq); keep the two in sync.

## [Unreleased]

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
  (`Extension.LoadString`) — field captions/descriptions and auth labels.

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
