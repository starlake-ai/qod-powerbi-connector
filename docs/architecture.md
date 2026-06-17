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
protocol Quack exposes. This path supports Import + DirectQuery and is, in
principle, certifiable.

### Reality check (2026-06-17): the ODBC driver is too immature

Loading the built `.mez` in Power BI Desktop against a live Quack instance proved
the connector M is correct but **the only existing Flight SQL ODBC driver can't
carry it**:

- The sole production driver is **Dremio's Arrow Flight SQL ODBC driver** (v0.9.7,
  Aug 2025 — latest; a 0.9.x **beta**). It is *not* part of Apache Arrow (licensing),
  so there is no alternative build.
- On connect, Power Query calls `SQLGetInfo(SQL_DBMS_NAME)`; the driver **errors
  `Unknown GetInfo type: 17`** (the string is in the driver DLL). Power Query won't
  let a connector override `SQL_DBMS_NAME`, and Quack already returns the data (an
  **ADBC** client reads `vendor_name="Quack on Demand"` from the same server). So
  it's a driver gap — unfixable from the connector or the server.

Net: the ODBC transport is blocked on driver maturity. The viable route is ADBC,
below. (Driver-build details and the full debugging log live in
[quack-server-spec.md](quack-server-spec.md) §11 and R13/R15.)

## The ADBC path (the "Dremio path") — now the primary route

Per Microsoft's [ODBC→ADBC transition doc](https://learn.microsoft.com/en-us/power-query/transition-to-adbc)
(updated 2026-05), Power BI/Fabric ADBC is enabled **only** for first-party
connectors via `Implementation="2.0"` — and **Dremio's replacement driver is
"FlightSQL ADBC"**. There is still no `Adbc.DataSource` M primitive and no way for a
custom `.mez` to opt into ADBC. So the route to native ADBC is *not* a connector
rewrite — it is to have Microsoft map QoD onto their product-side **FlightSQL ADBC
driver**, exactly as they did for Dremio. **Quack speaks the same Arrow Flight SQL
protocol as Dremio**, so the same driver applies unchanged.

That is a **certification-time enablement**, negotiated with Microsoft, not a code
change in `QoD.pq`. The connector is structured so the switch is isolated:

- the connection-string builder and credential→property mapping are centralized;
- capability shaping (`SqlCapabilities`, `SQLGetInfo`) is declarative;
- once enabled, the same `(server, tenant, pool, auth)` surface carries over.

### Why this is the right call (not just a fallback)

- **ADBC works against Quack today** — empirically. An ADBC Flight SQL client
  (same protocol Microsoft's FlightSQL ADBC driver uses) ran the full path against
  the live instance: TLS, Basic auth, tenant/pool routing, metadata discovery,
  typed results, and folded `GROUP BY`/aggregate queries. See
  [quack-server-spec.md](quack-server-spec.md) §11.
- **The ODBC alternative is blocked** on the immature driver (above).
- **ODBC is being removed anyway** — Microsoft starts pulling its embedded ODBC
  drivers **Sep 2026**, fully gone from Desktop/gateway **Mar 2027**. (QoD's bundled
  Flight SQL ODBC driver is a separate dependency and not directly removed, but the
  platform's direction of travel is unambiguous.)

### The ask to Microsoft (certification engagement)

Bring three points: (1) Quack is Arrow Flight SQL, **protocol-identical to Dremio**,
which Microsoft already maps to FlightSQL ADBC; (2) the ADBC path is **validated**
end-to-end against Quack; (3) request the same **FlightSQL ADBC enablement** for the
QoD connector. This sidesteps the ODBC driver entirely.

## Credential → transport mapping

| Power BI credential | Quack backend            | ODBC properties injected            |
|---------------------|--------------------------|-------------------------------------|
| UsernamePassword    | Postgres / BCrypt        | `UID`, `PWD`                        |
| Key (access token)  | External JWT (HS/RS256)  | `token` (bearer header)             |
| OAuth 2.0 / OIDC    | Keycloak/Entra/Google/…  | `token` = OAuth `access_token`      |

`tenant` and `pool` are always sent as Flight SQL gRPC call headers via the
driver's `RPCCallHeaders` passthrough — see "tenant/pool channel" below.

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
| `RPCCallHeaders` | extra gRPC call metadata, `key=val;key=val` — carries `tenant`/`pool` |
| `schema` | optional default schema |

Sample: `host=…;port=443;useEncryption=1;disableCertificateVerification=1;token=…`

## Driver selection (decision)

No single *ODBC* driver currently covers everything Quack needs. Capability matrix:

| Capability | JDBC | timvw ODBC | **Apache Arrow C++ ODBC** | Dremio ODBC |
|---|---|---|---|---|
| User/password | ✅ | ✅ | ⚠️ foundational | ❌ |
| Token / JWT | ✅ | ❌ | ⚠️ TBD | ✅ |
| OAuth | ✅ | ❌ | ❌ | ❌ |
| tenant/pool as headers | ✅ (unknown params → gRPC headers) | ❌ | ✅ via `RPCCallHeaders` | ✅ auto-forwards |
| Maintained | ✅ | ❌ archived Mar 2026 | ✅ new/official | ✅ |
| Usable from Power BI (ODBC) | ❌ Java-only | ✅ | ✅ | ✅ |

**Decision: target the official Apache Arrow C++ Flight SQL ODBC driver.** It is
vendor-neutral, actively developed, certifiable, and shares the lineage Microsoft
uses for the Dremio "FlightSQL ADBC" path. `timvw` is archived (dead); Dremio is
token-only; JDBC isn't usable from Power BI's M engine.

## tenant/pool channel (decision)

The connector sends scope as **native Flight SQL gRPC call headers**. This is the
**same contract Quack already honors for its JDBC driver** (where `?tenant=…&pool=…`
URL params become gRPC metadata), so it needs **no server-side change** — the
gateway routes on the `tenant`/`pool` headers it already understands.

The connection-string **encoding is driver-specific** (centralized in `EncodeScope`):

| Driver build | Encoding |
|---|---|
| **Dremio** Arrow Flight SQL ODBC (what Power BI loads today) | plain separate props `tenant=…;pool=…` — the driver auto-forwards unknown keys as gRPC headers |
| Upstream **Apache C++** build | explicit packed `RPCCallHeaders="tenant=…;pool=…"` |

> The connector uses the **separate-keys** form. The packed `RPCCallHeaders` form
> must **not** be used with the record Power Query passes to `Odbc.DataSource`: its
> embedded `;`/`=` corrupt the `;`-delimited ODBC connection string and the driver
> reports `Missing required properties: host, port`. (Caught loading the `.mez` in
> Desktop, 2026-06-17.)

> Earlier draft used the `database`→tenant / `schema`→pool catalog properties to
> avoid depending on ODBC header passthrough. That passthrough is now confirmed
> available, so we use it: it matches the existing JDBC routing contract, needs no
> server parse rule, and leaves the SQL-semantic `database`/`schema` keys free for
> their real catalog/schema meaning.

Implemented in `EncodeScope`; falling back to `database`/`schema` catalog
properties (if a future driver build lacks `RPCCallHeaders`) is a one-liner.

## Open items to verify against the shipped driver build
- Exact **registered driver name** of the official C++ build (for `Driver=…`).
- **Username/password** key names (`UID`/`PWD` vs `user`/`password`) and **token**
  property support in the C++ build as auth matures.
- Exact `RPCCallHeaders` list delimiter/escaping in the shipped C++ build (the
  connector sends `tenant=…;pool=…`). No Quack server change needed — it already
  routes on the `tenant`/`pool` gRPC headers (JDBC contract).
- Which scalar/aggregate functions DuckDB folds, to widen `SQLGetFunctions`.
- OIDC endpoints / `client_id` / scopes per deployment (see `OAuthConfig`).
