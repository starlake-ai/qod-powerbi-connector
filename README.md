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
Power BI ──M──▶ QoD.mez ──ODBC──▶ Arrow Flight SQL ODBC driver ──Flight SQL──▶ Quack gateway ──▶ DuckDB
```

Power BI's M engine consumes **ODBC** (via `Odbc.DataSource`); it has no public
`Adbc.DataSource` for custom connectors. The connector M is complete and validated,
**but the only Flight SQL ODBC driver (Dremio's v0.9.7 beta) is too immature** - it
errors on Power BI's `SQLGetInfo(SQL_DBMS_NAME)` probe, which is unfixable from the
connector or server. So the chosen route is the **"Dremio path"**: a
certification-time enablement onto Microsoft's **FlightSQL ADBC** driver (Dremio's
replacement driver - and Quack speaks the same protocol). **ADBC is proven working
against Quack end-to-end.** See [docs/architecture.md](docs/architecture.md).

## Authentication (all three supported)

| Credential in Power BI | Maps to Quack backend           |
|------------------------|---------------------------------|
| Username / password    | Postgres / BCrypt               |
| Access token (JWT)     | External JWT (HS256/RS256)      |
| OAuth 2.0 / OIDC       | Keycloak / Entra ID / Google / Cognito |

Per-method setup (including the customer-side Keycloak/OAuth client) is in
**[docs/authentication.md](docs/authentication.md)**.

## Layout

```
src/
  QoD.pq            connector logic (Odbc.DataSource, auth, capabilities)
  QoD.query.pq      test queries (smoke / navigation / folding)
  QoD.proj          MSBuild project -> QoD.mez
  resources.resx    localized UI strings
  icons/            connector icons + generator script
docs/
  architecture.md      data path + the ADBC upgrade path
  authentication.md    auth methods + IdP (Keycloak/OAuth) setup for customers
  certification.md     Microsoft certification checklist & process
  quack-server-spec.md server-side requirements to hand to the Quack team
CHANGELOG.md           versioned change history
```

## Install

See **[INSTALL.md](INSTALL.md)** for full install instructions - building from
source, dropping in a pre-built **unsigned** `.mez` (dev), or deploying a
**signed** `.pqx` (production).

## Build

Use the **VS Code "Power Query SDK"** extension → *Build connector project*, or:

```sh
dotnet build src/QoD.proj -c Release   # -> bin/Release/QoD.mez
```

Both routes use the `Microsoft.PowerQuery.SdkTools.MSBuild` SDK, which the VS Code
extension provisions (it isn't on public NuGet). For a **headless / CI** build with
just the `Microsoft.PowerQuery.SdkTools` NuGet package, invoke its `MakePQX` directly:

```sh
MakePQX compile src -d bin/Release -t QoD.mez   # validates the M + packages
```

`MakePQX compile` packages the root `.pq` + `resources.resx`; add the `icons/*.png`
to the resulting `.mez` (a zip) so `Extension.Contents` can resolve them.
*Verified 2026-06-17: `QoD.pq` compiles clean (no M syntax errors).*

## Develop / test

1. Build `QoD.mez`.
2. In VS Code SDK: *Set credential* for the auth kind you're testing.
3. *Evaluate* `src/QoD.query.pq` (edit the host/tenant/pool first).
4. To test in Desktop: copy `QoD.mez` to
   `Documents\Power BI Desktop\Custom Connectors\` and enable
   *Allow any extension* (File → Options → Security) for unsigned dev builds.

## Decisions

- **Driver:** official **Apache Arrow C++ Flight SQL ODBC** driver (vendor-neutral,
  maintained, certifiable). See the capability matrix in
  [docs/architecture.md](docs/architecture.md).
- **tenant/pool:** conveyed as native Flight SQL gRPC call headers, reusing the same
  routing contract Quack already honors for JDBC - so **no server change**. Encoding
  is driver-specific (centralized in `EncodeScope`): the Dremio ODBC build auto-
  forwards plain `tenant`/`pool` props as headers (used today); the upstream C++
  build uses an explicit `RPCCallHeaders` property. See [docs/architecture.md](docs/architecture.md).

## Status / path to certification

**Decision (2026-06-17): pivot to the ADBC "Dremio path".** The ODBC transport is
blocked on driver immaturity (see *How it connects*), so certification goes via
Microsoft's FlightSQL ADBC enablement rather than the bundled ODBC driver.

- [x] Connector M built (`QoD.mez` via MakePQX) and validated in Desktop up to the
      driver's `SQLGetInfo` probe - five real bugs found & fixed in the process.
- [x] **ADBC path proven** end-to-end against a live Quack instance (TLS, Basic auth,
      tenant/pool routing, discovery, typed + folded queries). See
      [docs/quack-server-spec.md](docs/quack-server-spec.md) §11.
- [ ] **Engage Microsoft** for FlightSQL ADBC enablement (the Dremio path), bringing
      the ADBC validation evidence + "same protocol as Dremio" argument.
- [ ] Fill in real OIDC endpoints / `client_id` / scopes in `OAuthConfig`.
- [ ] Provide a public test instance + per-auth credentials for certification.
- [x] Connector icons sourced from the official Quack on Demand brand mark.

## Notes

- The repo directory is named `qod-powerbi-connector`; the connector identifier and
  display name are **QoD** / **Quack on Demand**.
- Icons are downscaled from the official brand mark
  (`src/icons/source/qod-mark-512.png`) by `src/icons/generate-icons.ps1`.
