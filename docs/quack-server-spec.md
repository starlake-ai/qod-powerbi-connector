# Quack on Demand — Server Requirements for the Power BI Connector

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
marked **(confirm)** may already work — we just need verification; items marked
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

### R1 — Accept tenant/pool via gRPC call-header metadata **(confirm)**
Today Quack takes `tenant` and `pool` as JDBC URL parameters, delivered as gRPC
call headers. The connector sends the **same headers** over ODBC. The exact
connection-string encoding is driver-specific but the wire result is identical: the
Dremio Arrow Flight SQL ODBC build (loaded by Power BI today) auto-forwards plain
`tenant`/`pool` connection properties as gRPC headers; the upstream Apache C++ build
uses an explicit `RPCCallHeaders` property.

These arrive as gRPC call metadata on the Flight SQL session — **identical to the
JDBC path** — so no server-side parsing or mapping is required.

**Acceptance criteria**
- An ODBC client connecting with `RPCCallHeaders=tenant=tpch;pool=sales` is routed
  to tenant `tpch`, pool `sales` — identical behavior to the JDBC
  `?tenant=tpch&pool=sales` form.
- If the `tenant`/`pool` headers are absent, Quack returns a clear error naming the
  missing scope (not a generic failure).
- **(confirm)** No change to the existing `tenant`/`pool` header handling is needed;
  the JDBC path is unaffected.

> This supersedes the earlier proposal to route via `database`/`schema` catalog
> properties (which would have needed a server-side parse rule). Using
> `RPCCallHeaders` reuses your existing contract and needs **no server change**. If
> the C++ ODBC build uses a different header-list delimiter than `;`, tell us — it's
> a one-line change in the connector (`EncodeScope`).

---

## 3. Authentication

The connector exposes three Power BI credential kinds. Each maps to a Flight SQL
auth mechanism that Quack must accept over the **ODBC** driver's handshake.

### R2 — Username / password (Basic auth) **(confirm)**
- Flight SQL handshake with `Basic` credentials (username + password), validated
  against Quack's Postgres/BCrypt backend.
- **Acceptance:** ODBC connection with `UID`/`PWD` (or `user`/`password`,
  whichever the chosen driver build uses) authenticates and returns a session
  token/cookie for subsequent statements.

### R3 — Static access token / JWT (Bearer) **(confirm)**
- Flight SQL handshake / per-call `authorization: Bearer <jwt>`, validated against
  Quack's external JWT backend (HS256/RS256).
- **Acceptance:** ODBC connection with the driver's `token` property authenticates;
  an expired/invalid token yields an `UNAUTHENTICATED` error the connector can show.

### R4 — OAuth 2.0 / OIDC access token **(confirm)**
- The connector runs the OIDC authorization-code + PKCE flow in Power BI, obtains
  an `access_token`, and presents it as a Bearer token exactly as R3.
- **Acceptance:** a token issued by the configured OIDC provider (Keycloak / Entra
  ID / Google / Cognito) is accepted by Quack's OIDC validation.
- **(confirm)** Required token **audience**, **issuer**, and **scopes** for Quack.
  Please provide these so we can configure the connector (`OAuthConfig`).

### R5 — Per-statement auth continuity **(confirm)**
Quack authenticates at handshake **and per statement**. The ODBC driver must be
able to carry the session forward (auth token / cookie) across `Execute` calls.
- **Acceptance:** a multi-statement session (metadata browse → query → query) does
  not re-prompt or fail mid-session due to lost auth context.
- Please confirm whether Quack issues a **session/bearer token at handshake** that
  the driver should replay, and its **lifetime** (so refresh can be scheduled).

---

## 4. Metadata & discovery (Power BI navigation)

Power BI builds its navigator from Flight SQL metadata calls. These must be
populated and scoped to the authenticated tenant/pool.

### R6 — Catalog/schema/table discovery **(confirm)**
- `GetCatalogs`, `GetDbSchemas`, `GetTables`, `GetTableTypes`, `GetPrimaryKeys`
  return the objects visible to the user under RBAC.
- **Acceptance:** the connector's navigation table lists exactly the catalogs/
  schemas/tables the user is authorized to see; hidden objects are absent.

### R7 — Type metadata **(done)**
- ✅ Implemented: `GetXdbcTypeInfo` is served from a static DuckDB type catalog
  (`TypeInfoCatalog`), with the canonical `GET_TYPE_INFO_SCHEMA` field set and ODBC
  `SQL_TYPE_*` codes. Covers BOOLEAN, the signed/unsigned integer family
  (TINYINT…BIGINT + Uxxx), HUGEINT (as DECIMAL/38), REAL/DOUBLE, DECIMAL(p,s),
  VARCHAR, BLOB, DATE/TIME/TIMESTAMP, and UUID. The request's `data_type` filter is
  honored.
- **Known limitation:** composite types (LIST, STRUCT, MAP, UNION) are intentionally
  absent — they have no `SQL_TYPE_*` code; the ODBC driver flattens them to strings.
- **Acceptance:** DECIMAL, DATE, TIMESTAMP, BOOLEAN, large strings, and 64-bit
  integers round-trip into Power BI with correct types (no silent truncation).
  *Validate end-to-end against a live instance during the folding pass (R8).*

---

## 5. Query execution & DirectQuery folding

For **DirectQuery**, Power BI generates SQL and pushes it down. Quack must execute
the SQL the M engine folds, in the DuckDB dialect.

### R8 — SQL dialect & pushdown **(confirm)**
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

### R9 — Prepared / parameterized statements **(not supported — handled client-side)**
Quack does **not** support Flight SQL parameter binding (`CreatePreparedStatement`
with bound parameters). The connector therefore makes the M engine **inline literal
values** directly into the folded SQL text instead of binding parameters — enabled
by the `Supports{Numeric,String,OdbcDate,OdbcTime,OdbcTimestamp}Literals = true`
flags in `SqlCapabilities` (see `QoD.pq`). No prepared-statement/parameter path is
exercised.
- **Acceptance:** a filtered DirectQuery (e.g. `WHERE o_orderstatus = 'O'`) folds to
  a **Native Query with the literal inlined** (`… = 'O'`, not `… = ?`) and returns
  correct results — no `CreatePreparedStatement` parameter-binding call is issued.
- **(confirm)** Quack executes such literal-inlined SQL via the ordinary statement
  path. If Quack later adds parameter binding, this requirement can be revisited to
  re-enable it for plan caching.

### R10 — Result streaming & limits **(confirm)**
- Large result sets stream via Arrow record batches without server-side row caps
  that would silently truncate Import refreshes.
- **Acceptance:** a 10M-row table imports completely (or documents the configured
  limit explicitly).

---

## 6. Transport & errors

### R11 — TLS **(confirm)**
- TLS on `:31338` by default. Provide the **CA certificate** (or confirm a public
  CA) so the connector can validate without `disableCertificateVerification`.
- Confirm the **SNI / expected hostname** on the server certificate.
- **Acceptance:** connecting with `useEncryption=1` and certificate verification
  **on** succeeds against the provided cert.

### R12 — Error semantics **(done)**
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
  > **is** the gRPC `PERMISSION_DENIED` code (7) that R12 asked for — same wire
  > status, different enum label. Map ODBC SQLSTATEs off the wire code, not the name.
- **Acceptance:** the connector can surface actionable errors (e.g. "wrong
  password" → `UNAUTHENTICATED` vs "no access to table X" → `PERMISSION_DENIED`)
  rather than a generic failure.

---

## 7. Driver standardization

### R13 — Recommended ODBC driver **(confirm)**
- We target the **official Apache Arrow C++ Flight SQL ODBC driver**. Please confirm
  Quack is tested against it, and provide:
  - the exact **registered ODBC driver name** (for `Driver={…}`),
  - the **auth property keys** that build uses (`UID`/`PWD` vs `user`/`password`,
    and the `token` key),
  - a known-good **connection string** for each auth mode.
- **Acceptance:** a documented connection string per auth mode that connects to
  your test instance.

### R15 — Complete `GetSqlInfo` response so ODBC `SQLGetInfo` resolves **(change)**
**Blocking — found loading the connector in Power BI Desktop (2026-06-17).** As soon
as Power Query connects, it calls `SQLGetInfo(SQL_DBMS_NAME)` (ODBC info type 17).
The Arrow Flight SQL ODBC driver answers ODBC `SQLGetInfo` from the server's Flight
SQL **`GetSqlInfo`** response, and it returned:

```
ERROR [HY000] [Apache Arrow][Flight SQL] (100) Unknown GetInfo type: 17
```

Power Query **cannot** override `SQL_DBMS_NAME` from the connector (its `SQLGetInfo`
override allows only capability flags, not identity strings), so this must be fixed
server-side (or by a newer driver build — see note).

Today `FlightProducerImpl.sqlInfoBuilder` populates only ~13 `SqlInfo` codes
(server name/version/arrow-version, read-only/sql/substrait, identifier quote char,
3 DDL flags, empty keywords). The driver builds its `SQLGetInfo` cache from this
response; codes Quack omits surface as `Unknown GetInfo type: N` for the mapped ODBC
types.

**Ask:** expand `sqlInfoBuilder` to return the **full standard set** the Arrow Flight
SQL ODBC driver consumes. At minimum, beyond what's already set:

| Flight `SqlInfo` | `SqlInfoBuilder` setter | Suggested value (DuckDB) |
|---|---|---|
| `SQL_IDENTIFIER_CASE` | `withSqlIdentifierCase` | case-insensitive / lower |
| `SQL_QUOTED_IDENTIFIER_CASE` | `withSqlQuotedIdentifierCase` | case-sensitive |
| `SQL_SEARCH_STRING_ESCAPE` | `withSqlSearchStringEscape` | `\` |
| `SQL_NULL_ORDERING` | `withSqlNullOrdering` | nulls high/low per DuckDB |
| `SQL_KEYWORDS` | `withSqlKeywords` | DuckDB non-SQL92 keywords |
| `SQL_NUMERIC_FUNCTIONS` / `SQL_STRING_FUNCTIONS` / `SQL_SYSTEM_FUNCTIONS` / `SQL_DATETIME_FUNCTIONS` | `withSql*Functions` | bitmasks for supported scalar fns |
| `SQL_SUPPORTS_CONVERT` | `withSqlSupportsConvert` | supported CAST conversions |
| `SQL_MAX_*` (column/table name length, columns in select, etc.) | `withSqlMax*` | DuckDB limits (0 = no limit) |
| `SQL_TRANSACTIONS_SUPPORTED` / isolation | `withSqlTransactions*` | per DuckDB |
| `SQL_SUPPORTED_GROUP_BY` / `SQL_SUPPORTED_UNIONS` / `SQL_OUTER_JOINS_SUPPORT_LEVEL` | `withSql*` | per DuckDB |

**UPDATE 2026-06-17 — Quack expanded `sqlInfoBuilder` to the full set; this did NOT
fix the ODBC probe. Root cause is now proven to be the DRIVER, not the server:**

- Against the **same redeployed instance**, an ADBC Flight SQL client read
  `FLIGHT_SQL_SERVER_NAME` out of `GetSqlInfo` and surfaced it as
  `vendor_name = "Quack on Demand"`. So the data backing `SQL_DBMS_NAME` **is present
  in the server response**.
- The Dremio Arrow Flight SQL **ODBC** driver, given that same response, still errors
  `Unknown GetInfo type: 17`. Same server, same `GetSqlInfo`: ADBC resolves it, ODBC
  does not → the installed (old) Dremio ODBC build simply doesn't map ODBC info type
  17 to the server name.

**Resolution moves to the driver (see R13): use a newer Arrow Flight SQL ODBC driver
build.** No further server change is needed for this symptom. The `sqlInfoBuilder`
expansion is good to keep — *except* the regression below.

### R15a — Do NOT advertise transaction support that isn't implemented **(regression)**
The expansion added `withFlightSqlServerTransaction(SQL_SUPPORTED_TRANSACTION_TRANSACTION)`,
i.e. the server now claims transaction support it does not implement. Clients act on
it and fail: ADBC errors `IO: failed to update autocommit: rpc error: code =
Unimplemented` on connect (forcing `autocommit=true` works around it). **Fix:**
declare `SQL_SUPPORTED_TRANSACTION_NONE` (or actually implement Begin/Commit/Rollback).

**Acceptance:** (R15a) a default client connects without an autocommit/transaction
error. (R15 original symptom) resolved via the driver update under R13 — a direct
`SQLGetInfo(SQL_DBMS_NAME)` returns a value instead of erroring.

---

## 8. Certification test environment (Microsoft requirement)

### R14 — Public test instance + credentials **(change/provide)**
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
| R2 | Username/password (Basic) | confirm | ✅ verified live (`alice` Basic handshake) |
| R3 | JWT bearer token | confirm | server-side — not yet exercised |
| R4 | OIDC access token + audience/issuer/scopes | confirm | server-side — not yet exercised |
| R5 | Per-statement auth continuity + token lifetime | confirm | ✅ multi-statement session held |
| R6 | Catalog/schema/table discovery (RBAC-scoped) | confirm | ✅ verified live (`information_schema`) |
| R7 | Type metadata (`GetXdbcTypeInfo` catalog) | done | ✅ verified live (DECIMAL/BIGINT/DOUBLE round-trip) |
| R8 | SQL pushdown / DirectQuery folding | confirm | 🟡 server executes folded shapes; M-engine fold pending `.mez` |
| R9 | No parameter binding → connector inlines literals | not supported / client-side | handled in connector |
| R10 | Result streaming without silent caps | confirm | 🟡 58M-row table aggregated; full Import not yet run |
| R11 | TLS cert + SNI host | confirm | ⏳ infra — dev cert is self-signed `CN=localhost` |
| R12 | Distinct error status codes (`RouterFailure`) | done | ✅ verified live (UNAUTHENTICATED, NOT_FOUND observed) |
| R13 | Recommended ODBC driver + connection strings | confirm | 🔴 **driver too old** — needs a newer Arrow Flight SQL ODBC build (see R15) |
| R14 | Public test instance + per-auth credentials | provide | ⏳ infra — required for certification |
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

- **R14 — public test endpoint** *(the unblocker)*: a reachable Quack instance with
  a tenant/pool, sample data, and per-auth test credentials. Required for Microsoft
  certification and a prerequisite for R8/R13 below.
- **R8 — DirectQuery folding validation**: needs the live instance to inspect Power
  Query's folded **Native Query** and tune the connector's `SQLGetFunctions` /
  `SqlCapabilities` to DuckDB's real surface.
- **R11 — TLS certificate**: a production CA-signed cert (+ SNI hostname) so the
  connector validates without `disableCertificateVerification`. A deploy decision.
- **R13 — driver-build confirmations**: the live instance lets us lock the exact
  registered driver name, auth property keys, and connection-string shape per auth
  mode. Still needs the **C++ ODBC driver** specifically (the run below used the
  ADBC Flight SQL driver, which speaks the same protocol but isn't the ODBC build
  Power BI loads).

---

## 11. Live validation log

**2026-06-17 — dev instance (`:31338`, TLS).** Exercised the connector's exact wire
contract with an ADBC Flight SQL client (same Flight SQL protocol as the ODBC path):
TLS + Basic auth (`alice`) + `tenant=acme`/`pool=bi` as RPC call headers.

- **R1/R2 routing + auth** — handshake succeeded; `information_schema` resolved to
  catalog `__ducklake_metadata_acme_tpch`, confirming `tenant=acme` routed to the
  correct DuckLake. This is the empirical confirmation that tenant/pool-as-gRPC-
  headers (not `database`/`schema`) is the right contract.
- **R6 discovery** — `information_schema.tables` enumerated; TPC-H data under schema
  `tpch1`.
- **R7 types** — a `GROUP BY` aggregate over `tpch1.lineitem` round-tripped
  `DECIMAL(38,2)` → `decimal128(38,2)`, `COUNT` → `int64`, `AVG` → `double`,
  `VARCHAR` → `string`. No truncation.
- **R8 (server half)** — the folded **shape** the connector emits (projection +
  `WHERE` on a `DATE` literal + `GROUP BY` + `COUNT`/`SUM`/`AVG` + `ORDER BY` +
  `LIMIT`) executed correctly in DuckDB. The remaining R8 work is confirming Power
  Query's M engine *produces* this SQL, which needs the built `.mez` in Desktop.
- **R12 errors** — observed distinct `UNAUTHENTICATED` (unknown user) and
  `NOT_FOUND` (unqualified table, with a "did you mean `tpch1.lineitem`?" hint),
  matching the documented `RouterFailure` → `CallStatus` mapping.

**Not yet exercised:** JWT (R3) / OAuth (R4) auth paths; full-table Import (R10);
certificate verification on (R11, dev cert is self-signed `CN=localhost`).

**2026-06-17 — Power BI Desktop, real `.mez` over the Dremio Arrow Flight SQL ODBC
driver.** Built `QoD.mez` (MakePQX), loaded it in Desktop against the dev instance.
Peeled through several layers; each connector-side bug was fixed and is now in the
code:

1. `ConnectionTimeout`/`CommandTimeout` must be `Duration`, not Int → wrapped in
   `#duration`.
2. tenant/pool as a packed `RPCCallHeaders="…;…"` value corrupted the connection
   string (`Missing required properties: host, port`) → switched to separate
   `tenant`/`pool` props (Dremio build auto-forwards unknown keys as gRPC headers).
3. TLS: `disableCertificateVerification` honored with `TrustServerCertificate = true`
   against the self-signed dev cert.
4. **Blocked at R15:** the driver then errored `Unknown GetInfo type: 17`
   (`SQL_DBMS_NAME`) — not connector-fixable (Power Query won't override identity
   `SQLGetInfo` values). Handed to the Quack team as **R15**.

**2026-06-17 (later) — R15 server fix shipped; root cause proven to be the driver.**
Quack expanded `sqlInfoBuilder` to the full `SqlInfo` set and redeployed. Power BI
**still** errored `Unknown GetInfo type: 17`. Decisive check: against the same
redeployed instance, the ADBC client read `vendor_name = "Quack on Demand"` (i.e.
`FLIGHT_SQL_SERVER_NAME` from `GetSqlInfo`). So the `SQL_DBMS_NAME` source is in the
server response — the **ODBC driver** just doesn't map it. Conclusion: the installed
(old) Dremio Arrow Flight SQL ODBC build is the blocker → needs a newer driver (R13).
The redeploy also surfaced **R15a**: the new build advertises transaction support it
doesn't implement, so ADBC fails on autocommit unless `autocommit=true` is forced.

Net: connector M is validated up to the driver's `SQLGetInfo` probe. The two
remaining gates are **a newer ODBC driver build** (R13/R15) and the **R15a**
transaction-declaration revert — both outside the connector.




let
    Source = QoD.Database("192.0.0.2:31338", "acme", "bi", [TrustServerCertificate = true])
in
    Source
