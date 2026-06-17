# Quack on Demand - Server Requirements for the Power BI Connector

**Audience:** Quack on Demand maintainers
**From:** QoD Power BI connector team
**Status:** Draft for review
**Related:** [architecture.md](architecture.md), [certification.md](certification.md)

## 1. Context

We are building a Microsoft-certifiable Power BI / Fabric **custom connector** for
Quack on Demand. Power BI's Power Query (M) engine speaks **ODBC**, so the connector
wraps the **Apache Arrow Flight SQL ODBC driver** (official Apache Arrow C++ build)
talking to Quack's Flight SQL endpoint (`:31338`, TLS).

```
Power BI ──M──▶ QoD.mez ──ODBC──▶ Arrow Flight SQL ODBC driver ──Flight SQL──▶ Quack
```

This document lists what **Quack must support or confirm** for the connector to
work and pass certification. Each requirement has acceptance criteria. Items
marked **(confirm)** may already work - we just need verification; items marked
**(change)** likely need server work.

> **Why ODBC, not the JDBC driver you document today:** the Flight SQL *JDBC*
> driver forwards arbitrary URL params (`tenant`, `pool`) as gRPC headers and
> supports user/password + token + OAuth. Power BI cannot load a Java/JDBC driver,
> so we must use an *ODBC* driver. The Arrow Flight SQL ODBC build **does** forward
> custom gRPC metadata via its `RPCCallHeaders` property, so tenant/pool routing
> reuses your existing header contract unchanged (see R1). The remaining
> requirements below are mostly confirmations.

---

## 2. Scope routing (tenant / pool)

### R1 - Accept tenant/pool via gRPC call-header metadata **(confirm)**
Today Quack takes `tenant` and `pool` as JDBC URL parameters, delivered as gRPC
call headers. The connector sends the **same headers** over ODBC. The exact
connection-string encoding is driver-specific but the wire result is identical: the
Dremio Arrow Flight SQL ODBC build (loaded by Power BI today) auto-forwards plain
`tenant`/`pool` connection properties as gRPC headers; the upstream Apache C++ build
uses an explicit `RPCCallHeaders` property.

These arrive as gRPC call metadata on the Flight SQL session - **identical to the
JDBC path** - so no server-side parsing or mapping is required.

**Acceptance criteria**
- An ODBC client connecting with `RPCCallHeaders=tenant=tpch;pool=sales` is routed
  to tenant `tpch`, pool `sales` - identical behavior to the JDBC
  `?tenant=tpch&pool=sales` form.
- If the `tenant`/`pool` headers are absent, Quack returns a clear error naming the
  missing scope (not a generic failure).
- **(confirm)** No change to the existing `tenant`/`pool` header handling is needed;
  the JDBC path is unaffected.

> This supersedes the earlier proposal to route via `database`/`schema` catalog
> properties (which would have needed a server-side parse rule). Using
> `RPCCallHeaders` reuses your existing contract and needs **no server change**. If
> the C++ ODBC build uses a different header-list delimiter than `;`, tell us - it's
> a one-line change in the connector (`EncodeScope`).

---

## 3. Authentication

The connector collapses all three Power BI credential kinds to a single per-call
credential header - it does **not** use the driver's native `UID`/`PWD`/`token`.
The header is sent under the custom name **`x-qod-authorization`** (an unknown key
the driver forwards verbatim); Quack validates it **per call** and also accepts
standard `Authorization`.

> **Contract:** header `x-qod-authorization` (fallback `Authorization`); values:
>
> | PBI credential kind | header value | Quack validator |
> |---|---|---|
> | `UsernamePassword` | `Basic base64(user:pass)` | `DatabaseAuthenticator` (BCrypt vs `qodstate_user.password_hash`) |
> | `Key` (static JWT) | `Bearer <jwt>` | `JwtBearerAuthenticator` (HS256 / RS256 / PEM) |
> | `OAuth` (OIDC) | `Bearer <access_token>` | `OidcBearerAuthenticator` (Keycloak / Google / Azure / Cognito JWKS) |
>
> All three are wired and covered by `FlightHandshakeSecuritySpec`. The connector
> injects the header via `CredentialConnectionString` so the Dremio driver skips its
> Flight Handshake (see R4a) and the secret stays out of the connection string.

### R2 - Username / password (Basic) **(done - padding-agnostic decode)**
- `x-qod-authorization: Basic base64(user:pass)` validated by `DatabaseAuthenticator`
  (BCrypt against `qodstate_user.password_hash`).
- **Decode Base64 padding-agnostically.** The ODBC connector emits the value
  **unpadded** (trailing `=` stripped, to avoid the `key=value` connection-string
  split); the ADBC path sends it **padded**. Use a lenient decoder that accepts both.
- **Acceptance:** authenticates with padded (ADBC) or unpadded (ODBC) Base64; a bad
  user/password yields `UNAUTHENTICATED`. ✅ verified in Power BI Desktop (`alice`).

### R3 - Static access token / JWT (Bearer) **(done - server side)**
- `Authorization: Bearer <jwt>` validated by `JwtBearerAuthenticator`
  (HS256 / RS256 / PEM key).
- **Acceptance:** a valid JWT authenticates; an expired/invalid token yields
  `UNAUTHENTICATED`. Validate the connector's `Key` path over ADBC (per §11).

### R4 - OAuth 2.0 / OIDC access token **(done - server side)**
- The connector runs the OIDC authorization-code + PKCE flow in Power BI, obtains
  an `access_token`, and presents it as `Authorization: Bearer <access_token>` —
  validated by `OidcBearerAuthenticator` against the per-tenant/global JWKS.
- **Acceptance:** a token issued by the configured OIDC provider (Keycloak / Entra
  ID / Google / Cognito) is accepted.
- **(confirm)** Required token **audience**, **issuer**, and **scopes** for Quack.
  Please provide these so we can configure the connector (`OAuthConfig`).

### R4a - Per-call credential header **(done)**
Quack reads the credential from a call header on **every RPC** (no Flight
Handshake). The connector routes it via `CredentialConnectionString`, which stops
Power BI auto-injecting `UID`/`PWD` - otherwise the Dremio driver runs a Handshake
*before* `tenant`/`pool` are attached and login fails. The server reads
**`x-qod-authorization`** first, falling back to **`Authorization`**.
- **Acceptance:** authenticates whether the credential arrives under
  `x-qod-authorization` or `Authorization`, for all three kinds. ✅ verified in
  Power BI Desktop (Dremio ODBC, `alice` Basic).

### R5 - Per-statement auth continuity **(confirm)**
Because auth is validated **per call** from the `Authorization` header, every RPC
carries its own credential - there is no handshake-issued session token the driver
must replay. The connector re-sends the header on each call.
- **Acceptance:** a multi-statement session (metadata browse → query → query)
  authenticates each call and does not re-prompt or fail mid-session. ✅ multi-
  statement session held (ADBC).
- **(confirm)** Whether Quack additionally issues a session/bearer token the client
  *may* cache to skip per-call re-validation (optimization only - not required by
  the per-call contract above).

---

## 4. Metadata & discovery (Power BI navigation)

Power BI builds its navigator from Flight SQL metadata calls. These must be
populated and scoped to the authenticated tenant/pool.

### R6 - Catalog/schema/table discovery **(confirm)**
- `GetCatalogs`, `GetDbSchemas`, `GetTables`, `GetTableTypes`, `GetPrimaryKeys`
  return the objects visible to the user under RBAC.
- **Acceptance:** the connector's navigation table lists exactly the catalogs/
  schemas/tables the user is authorized to see; hidden objects are absent.

### R7 - Type metadata **(done)**
- ✅ Implemented: `GetXdbcTypeInfo` is served from a static DuckDB type catalog
  (`TypeInfoCatalog`), with the canonical `GET_TYPE_INFO_SCHEMA` field set and ODBC
  `SQL_TYPE_*` codes. Covers BOOLEAN, the signed/unsigned integer family
  (TINYINT…BIGINT + Uxxx), HUGEINT (as DECIMAL/38), REAL/DOUBLE, DECIMAL(p,s),
  VARCHAR, BLOB, DATE/TIME/TIMESTAMP, and UUID. The request's `data_type` filter is
  honored.
- **Known limitation:** composite types (LIST, STRUCT, MAP, UNION) are intentionally
  absent - they have no `SQL_TYPE_*` code; the ODBC driver flattens them to strings.
- **Acceptance:** DECIMAL, DATE, TIMESTAMP, BOOLEAN, large strings, and 64-bit
  integers round-trip into Power BI with correct types (no silent truncation).
  *Validate end-to-end against a live instance during the folding pass (R8).*

---

## 5. Query execution & DirectQuery folding

For **DirectQuery**, Power BI generates SQL and pushes it down. Quack must execute
the SQL the M engine folds, in the DuckDB dialect.

### R8 - SQL dialect & pushdown **(confirm)**
Confirm Quack/DuckDB executes folded SQL for at least:
- projection, `WHERE` predicates (`=`,`<`,`>`,`BETWEEN`,`IN`,`LIKE`,`IS NULL`),
- `GROUP BY` + aggregates (`COUNT`,`SUM`,`MIN`,`MAX`,`AVG`),
- `INNER`/`LEFT`/`RIGHT` joins,
- `ORDER BY`,
- **`LIMIT … OFFSET …`** (the connector advertises `LimitClauseKind.LimitOffset`),
- `CAST`, and common string/date/numeric scalar functions.

**Acceptance:** each of the above, when authored in Power Query, shows a folded
**Native Query** and returns correct results from a live Quack instance. We will
use this to tune the driver's advertised `SQLGetFunctions`/`SqlCapabilities`.

### R9 - Prepared / parameterized statements **(not supported - handled client-side)**
Quack does **not** support Flight SQL parameter binding (`CreatePreparedStatement`
with bound parameters). The connector therefore makes the M engine **inline literal
values** directly into the folded SQL text instead of binding parameters - enabled
by the `Supports{Numeric,String,OdbcDate,OdbcTime,OdbcTimestamp}Literals = true`
flags in `SqlCapabilities` (see `QoD.pq`). No prepared-statement/parameter path is
exercised.
- **Acceptance:** a filtered DirectQuery (e.g. `WHERE o_orderstatus = 'O'`) folds to
  a **Native Query with the literal inlined** (`… = 'O'`, not `… = ?`) and returns
  correct results - no `CreatePreparedStatement` parameter-binding call is issued.
- **(confirm)** Quack executes such literal-inlined SQL via the ordinary statement
  path. If Quack later adds parameter binding, this requirement can be revisited to
  re-enable it for plan caching.

### R10 - Result streaming & limits **(confirm)**
- Large result sets stream via Arrow record batches without server-side row caps
  that would silently truncate Import refreshes.
- **Acceptance:** a 10M-row table imports completely (or documents the configured
  limit explicitly).

---

## 6. Transport & errors

### R11 - TLS **(confirm)**
- TLS on `:31338` by default. Provide the **CA certificate** (or confirm a public
  CA) so the connector can validate without `disableCertificateVerification`.
- Confirm the **SNI / expected hostname** on the server certificate.
- **Acceptance:** connecting with `useEncryption=1` and certificate verification
  **on** succeeds against the provided cert.

### R12 - Error semantics **(done)**
- ✅ Implemented: failures map to distinct Flight `CallStatus` codes via a
  classified `RouterFailure` enum (no string-prefix parsing). Mapping:

  | Failure shape | Flight `CallStatus` | gRPC code |
  |---------------|---------------------|-----------|
  | Bad credentials (handshake) | `UNAUTHENTICATED` | 16 |
  | RBAC / ACL / row-/column-policy denied | `UNAUTHORIZED` | `PERMISSION_DENIED` (7) |
  | Unknown pool / tenant-db / table | `NOT_FOUND` | 5 |
  | Parser / binder / constraint / conversion error | `INVALID_ARGUMENT` | 3 |
  | No compatible node / transient after retry | `UNAVAILABLE` | 14 |
  | "Shouldn't happen" paths | `INTERNAL` | 13 |

  > Naming note for the connector: Arrow Flight Java's `CallStatus.UNAUTHORIZED`
  > **is** the gRPC `PERMISSION_DENIED` code (7) that R12 asked for - same wire
  > status, different enum label. Map ODBC SQLSTATEs off the wire code, not the name.
- **Acceptance:** the connector can surface actionable errors (e.g. "wrong
  password" → `UNAUTHENTICATED` vs "no access to table X" → `PERMISSION_DENIED`)
  rather than a generic failure.

---

## 7. Driver standardization

### R13 - Recommended ODBC driver **(confirm)**
- We target the **official Apache Arrow C++ Flight SQL ODBC driver**. Please confirm
  Quack is tested against it, and provide:
  - the exact **registered ODBC driver name** (for `Driver={…}`),
  - the **auth property keys** that build uses (`UID`/`PWD` vs `user`/`password`,
    and the `token` key),
  - a known-good **connection string** for each auth mode.
- **Acceptance:** a documented connection string per auth mode that connects to
  your test instance.

### R15 - `SQLGetInfo(SQL_DBMS_NAME)` resolves **(driver gap → R13)**
On connect, Power Query calls `SQLGetInfo(SQL_DBMS_NAME)` (info 17) and the Dremio
ODBC build errors `Unknown GetInfo type: 17`. The data **is** present server-side —
an ADBC client reads `FLIGHT_SQL_SERVER_NAME` from `GetSqlInfo` as
`vendor_name="Quack on Demand"` - and the connector can't override identity strings.
So this is a **driver gap**, not a server gap. Resolution: a newer Arrow Flight SQL
ODBC build (R13). No further server change needed (`sqlInfoBuilder` is already
expanded - keep it, except the R15a regression below).

### R15a - Do NOT advertise transaction support that isn't implemented **(regression)**
The expansion added `withFlightSqlServerTransaction(SQL_SUPPORTED_TRANSACTION_TRANSACTION)`,
i.e. the server now claims transaction support it does not implement. Clients act on
it and fail: ADBC errors `IO: failed to update autocommit: rpc error: code =
Unimplemented` on connect (forcing `autocommit=true` works around it). **Fix:**
declare `SQL_SUPPORTED_TRANSACTION_NONE` (or actually implement Begin/Commit/Rollback).

**Acceptance:** (R15a) a default client connects without an autocommit/transaction
error. (R15 original symptom) resolved via the driver update under R13 - a direct
`SQLGetInfo(SQL_DBMS_NAME)` returns a value instead of erroring.

---

## 8. Certification test environment (Microsoft requirement)

### R14 - Public test instance + credentials **(change/provide)**
Microsoft certification requires a reachable environment they can validate against.
Please provide:
- a **publicly reachable** Quack endpoint (host:port, TLS),
- at least one **tenant/pool** with sample data (e.g. TPCH),
- **test credentials for each auth path**: a username/password, a static JWT, and
  an OIDC client (issuer/audience/scopes/test user),
- expected uptime / support contact for the certification period.

---

## 9. Summary checklist

| # | Requirement | Type | Status |
|---|-------------|------|--------|
| R1 | tenant/pool via gRPC call-header metadata | confirm | ✅ verified live (routed to `acme_tpch`) |
| R2 | Username/password (Basic) | done | ✅ verified in Power BI Desktop (`alice`); server decodes Base64 padding-agnostically |
| R3 | Static JWT → Bearer | done (server) | ✅ `JwtBearerAuthenticator` wired; exercise connector `Key` path over ADBC |
| R4 | OIDC token → Bearer (+ audience/issuer/scopes) | done (server) | ✅ `OidcBearerAuthenticator` wired; needs aud/iss/scopes to configure `OAuthConfig` |
| R4a | Per-call credential header (`x-qod-authorization`) | done | ✅ **verified in Power BI Desktop** - credential via `CredentialConnectionString`, no Handshake, creds on every call |
| R5 | Per-statement auth continuity (per-call header) | confirm | ✅ multi-statement session held (ADBC) |
| R6 | Catalog/schema/table discovery (RBAC-scoped) | confirm | ✅ verified live (`information_schema`) |
| R7 | Type metadata (`GetXdbcTypeInfo` catalog) | done | ✅ verified live (DECIMAL/BIGINT/DOUBLE round-trip) |
| R8 | SQL pushdown / DirectQuery folding | confirm | 🟡 server executes folded shapes; M-engine fold pending `.mez` |
| R9 | No parameter binding → connector inlines literals | not supported / client-side | handled in connector |
| R10 | Result streaming without silent caps | confirm | 🟡 58M-row table aggregated; full Import not yet run |
| R11 | TLS cert + SNI host | confirm | ⏳ infra - dev cert is self-signed `CN=localhost` |
| R12 | Distinct error status codes (`RouterFailure`) | done | ✅ verified live (UNAUTHENTICATED, NOT_FOUND observed) |
| R13 | Recommended ODBC driver + connection strings | confirm | 🔴 **driver too old** - needs a newer Arrow Flight SQL ODBC build (see R15) |
| R14 | Public test instance + per-auth credentials | provide | ⏳ infra - required for certification |
| R15 | Complete `GetSqlInfo` | done (driver gap) | ✅ server expanded; `SQLGetInfo(17)` proven a **driver** gap (ADBC reads the field; ODBC doesn't) → R13 |
| R15a | Don't advertise unimplemented transactions | regression | 🔴 new build claims txn support → clients fail `Unimplemented` on autocommit |

**Smallest critical path to a working demo:** R1 (confirm `RPCCallHeaders` routing —
no server change) + one auth mode (R2 *or* R3) + R6 (discovery) + R11 (TLS) + R13
(driver/conn string). The rest hardens it for DirectQuery and certification.

---

## 10. Outstanding items (infra, not server code)

The Quack server team has delivered the code-level requirements (R7 and R12
implemented; R1/R9 need no server change). Everything still open is
**infrastructure or a deploy decision**, not server code, and unblocks once a test
environment exists:

- **R14 - public test endpoint** *(the unblocker)*: a reachable Quack instance with
  a tenant/pool, sample data, and per-auth test credentials. Required for Microsoft
  certification and a prerequisite for R8/R13 below.
- **R8 - DirectQuery folding validation**: needs the live instance to inspect Power
  Query's folded **Native Query** and tune the connector's `SQLGetFunctions` /
  `SqlCapabilities` to DuckDB's real surface.
- **R11 - TLS certificate**: a production CA-signed cert (+ SNI hostname) so the
  connector validates without `disableCertificateVerification`. A deploy decision.
- **R13 - driver-build confirmations**: the live instance lets us lock the exact
  registered driver name, auth property keys, and connection-string shape per auth
  mode. Still needs the **C++ ODBC driver** specifically (the run below used the
  ADBC Flight SQL driver, which speaks the same protocol but isn't the ODBC build
  Power BI loads).

---

## 11. Live validation log

**ADBC Flight SQL client (dev instance, TLS)** - same Flight SQL protocol as the
ODBC path: TLS + Basic auth (`alice`) + `tenant=acme`/`pool=bi` as call headers.

- **R1/R2 routing + auth** - `tenant=acme` routed to catalog
  `__ducklake_metadata_acme_tpch`.
- **R6 discovery** - `information_schema.tables` enumerated; TPC-H under schema `tpch1`.
- **R7 types** - `GROUP BY` over `tpch1.lineitem` round-tripped `DECIMAL(38,2)`,
  `COUNT`→`int64`, `AVG`→`double`, `VARCHAR`→`string`; no truncation.
- **R8 (server half)** - projection + `WHERE` (DATE literal) + `GROUP BY` +
  `COUNT`/`SUM`/`AVG` + `ORDER BY` + `LIMIT` executed correctly in DuckDB.
- **R12 errors** - distinct `UNAUTHENTICATED` and `NOT_FOUND` observed.

**Power BI Desktop over the Dremio ODBC driver** - `UsernamePassword` (`alice`)
authenticates end-to-end. The credential rides `CredentialConnectionString`, so the
driver skips its Handshake and every RPC carries `tenant`/`pool`/`x-qod-authorization`
(R4a verified). Connector-side fixes that landed along the way: `Duration` timeouts
(`#duration`), separate `tenant`/`pool` props (not packed `RPCCallHeaders`), and the
required `trustServerCertificate` parameter.

**Open:** JWT (R3) / OAuth (R4) paths; full Import (R10); cert verification on (R11);
DirectQuery fold validation (R8); the `SQLGetInfo(17)` driver wall (R13/R15) and the
R15a transaction-declaration revert.
