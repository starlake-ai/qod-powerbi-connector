# QoD — Quack on Demand Power BI Connector

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
`Adbc.DataSource` for custom connectors yet. Native ADBC in Power BI exists today
only through Microsoft's first-party connectors. The route to ADBC for QoD is the
**"Dremio path"** — a certification-time enablement onto Microsoft's FlightSQL
ADBC driver. See [docs/architecture.md](docs/architecture.md).

## Authentication (all three supported)

| Credential in Power BI | Maps to Quack backend           |
|------------------------|---------------------------------|
| Username / password    | Postgres / BCrypt               |
| Access token (JWT)     | External JWT (HS256/RS256)      |
| OAuth 2.0 / OIDC       | Keycloak / Entra ID / Google / Cognito |

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
  certification.md     Microsoft certification checklist & process
  quack-server-spec.md server-side requirements to hand to the Quack team
CHANGELOG.md           versioned change history
```

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
- **tenant/pool:** conveyed as native Flight SQL gRPC call headers via the driver's
  `RPCCallHeaders` property (`RPCCallHeaders=tenant=…;pool=…`). This reuses the same
  routing contract Quack already honors for JDBC, so it needs **no server change**.
  Centralized in `EncodeScope`; falling back to `database`/`schema` is a one-liner.

## Status / TODO before certification

- [x] Verified Flight SQL ODBC property keys (`host`/`port`/`useEncryption=1|0`/
      `token`); scope conveyed via `RPCCallHeaders` (no server change needed).
- [ ] Confirm the official C++ driver's registered name + auth key names as it matures.
- [ ] Confirm the C++ build's exact `RPCCallHeaders` list delimiter/escaping.
- [ ] Validate DirectQuery folding against a live Quack instance; widen
      `SQLGetFunctions` to match DuckDB.
- [ ] Fill in real OIDC endpoints / `client_id` / scopes in `OAuthConfig`.
- [x] Connector icons sourced from the official Quack on Demand brand mark.
- [ ] Run through [docs/certification.md](docs/certification.md) and submit.

## Notes

- The repo directory is named `pbi-adbc-driver`; the connector identifier and
  display name are **QoD** / **Quack on Demand**.
- Icons are downscaled from the official brand mark
  (`src/icons/source/qod-mark-512.png`) by `src/icons/generate-icons.ps1`.
