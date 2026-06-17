# QoD Connector — Architecture

## Data path

```
Power BI Desktop / Service / Fabric
        │  (M / Power Query)
        ▼
   QoD.mez  (this connector — Odbc.DataSource)
        │  ODBC
        ▼
 Arrow Flight SQL ODBC driver        ← machine/gateway dependency you ship
        │  Arrow Flight SQL (gRPC, TLS :31338)
        ▼
 Quack on Demand gateway
        │  routes by tenant / pool, enforces RBAC
        ▼
   DuckDB / DuckLake catalogs
```

## Why ODBC today (not ADBC directly)

Power BI/Fabric now support **ADBC**, but only through Microsoft's own
first-party connectors (Databricks, Snowflake, BigQuery, **Dremio**), opted into
per-connection with the `Implementation="2.0"` parameter. That parameter lives on
those Microsoft-maintained connector functions — **it is not an option a custom
`.mez` can pass to `Odbc.DataSource`**, and there is no public `Adbc.DataSource`
M primitive in the Power Query SDK (as of June 2026).

So a third-party connector built with the SDK uses `Odbc.DataSource`. The QoD
connector wraps the **Arrow Flight SQL ODBC driver**, which speaks the exact
protocol Quack exposes. This path:

- works today in Desktop, Service, and the on-premises data gateway;
- supports **Import and DirectQuery** with query folding;
- is **certifiable** under Microsoft's connector program.

## The ADBC upgrade path (the "Dremio path")

Dremio's certified connector now uses **"FlightSQL ADBC"**. Because Quack speaks
the **same protocol** (Arrow Flight SQL), the route to native ADBC is *not* to
write our own `Adbc.DataSource` — it is to have Microsoft map the QoD connector
onto their product-side **FlightSQL ADBC driver**, exactly as they did for Dremio.

That is a **certification-time enablement**, negotiated with Microsoft, not a code
change in `QoD.pq`. The connector is structured so the switch is isolated:

- the connection-string builder and credential→property mapping are centralized;
- capability shaping (`SqlCapabilities`, `SQLGetInfo`) is declarative;
- once enabled, the same `(server, tenant, pool, auth)` surface carries over.

### Timeline drivers
- **Sep 2026** — Microsoft begins removing the *legacy embedded* ODBC drivers
  from the service. The Flight SQL ODBC driver QoD bundles is **your own
  dependency** and is unaffected.
- **Mar 2027** — those legacy drivers stop shipping with Desktop/gateway.

## Credential → transport mapping

| Power BI credential | Quack backend            | ODBC properties injected            |
|---------------------|--------------------------|-------------------------------------|
| UsernamePassword    | Postgres / BCrypt        | `UID`, `PWD`                        |
| Key (access token)  | External JWT (HS/RS256)  | `token` (bearer header)             |
| OAuth 2.0 / OIDC    | Keycloak/Entra/Google/…  | `token` = OAuth `access_token`      |

`tenant` and `pool` are always sent as Flight SQL gRPC call headers via the
driver's header passthrough.

## Driver connection properties

Verified from the Arrow Flight SQL ODBC driver docs
([Dremio build](https://docs.dremio.com/cloud/sonar/client-apps/drivers/arrow-flight-sql-odbc/)):

| Property | Notes |
|----------|-------|
| `host`, `port` | Flight SQL endpoint |
| `useEncryption` | **`1`/`0`** (not `true`/`false`) — TLS on by default |
| `disableCertificateVerification` | `1`/`0` |
| `useSystemTrustStore`, `trustedCerts` | optional cert config |
| `token` | personal access token / JWT (bearer) |
| `schema` | optional default schema |

Sample: `host=…;port=443;useEncryption=1;disableCertificateVerification=1;token=…`

## Driver selection (decision)

No single *ODBC* driver currently covers everything Quack needs. Capability matrix:

| Capability | JDBC | timvw ODBC | **Apache Arrow C++ ODBC** | Dremio ODBC |
|---|---|---|---|---|
| User/password | ✅ | ✅ | ⚠️ foundational | ❌ |
| Token / JWT | ✅ | ❌ | ⚠️ TBD | ✅ |
| OAuth | ✅ | ❌ | ❌ | ❌ |
| tenant/pool as headers | ✅ (unknown params → gRPC headers) | ❌ | ⚠️ TBD | ❌ |
| Maintained | ✅ | ❌ archived Mar 2026 | ✅ new/official | ✅ |
| Usable from Power BI (ODBC) | ❌ Java-only | ✅ | ✅ | ✅ |

**Decision: target the official Apache Arrow C++ Flight SQL ODBC driver.** It is
vendor-neutral, actively developed, certifiable, and shares the lineage Microsoft
uses for the Dremio "FlightSQL ADBC" path. `timvw` is archived (dead); Dremio is
token-only; JDBC isn't usable from Power BI's M engine.

## tenant/pool channel (decision)

The only driver that forwards arbitrary properties as gRPC headers is **JDBC**
(which Power BI can't use). Rather than depend on an undocumented ODBC header
passthrough, the connector conveys scope through the **standard catalog/schema
properties** every Flight SQL ODBC build honors:

```
database -> tenant
schema   -> pool
```

Quack maps these back to its tenant/pool routing server-side. Implemented in
`EncodeScope`; swapping to a dotted `schema=tenant.pool` encoding is a one-liner.

## Open items to verify against the shipped driver build
- Exact **registered driver name** of the official C++ build (for `Driver=…`).
- **Username/password** key names (`UID`/`PWD` vs `user`/`password`) and **token**
  property support in the C++ build as auth matures.
- Server-side parse rule in Quack for `database`→tenant / `schema`→pool.
- Which scalar/aggregate functions DuckDB folds, to widen `SQLGetFunctions`.
- OIDC endpoints / `client_id` / scopes per deployment (see `OAuthConfig`).
