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

### R1 — Accept tenant/pool via `RPCCallHeaders` gRPC metadata **(confirm)**
Today Quack takes `tenant` and `pool` as JDBC URL parameters, delivered as gRPC
call headers. The connector sends the **same headers** over ODBC through the Arrow
Flight SQL ODBC driver's `RPCCallHeaders` property:

```
RPCCallHeaders = tenant=<tenant>;pool=<pool>
```

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

| # | Requirement | Type |
|---|-------------|------|
| R1 | tenant/pool via `RPCCallHeaders` gRPC metadata | confirm |
| R2 | Username/password (Basic) | confirm |
| R3 | JWT bearer token | confirm |
| R4 | OIDC access token + audience/issuer/scopes | confirm |
| R5 | Per-statement auth continuity + token lifetime | confirm |
| R6 | Catalog/schema/table discovery (RBAC-scoped) | confirm |
| R7 | Type metadata (`GetXdbcTypeInfo` catalog) | **done** |
| R8 | SQL pushdown / DirectQuery folding | confirm |
| R9 | No parameter binding → connector inlines literals | not supported / client-side |
| R10 | Result streaming without silent caps | confirm |
| R11 | TLS cert + SNI host | confirm |
| R12 | Distinct error status codes (`RouterFailure`) | **done** |
| R13 | Recommended ODBC driver + connection strings | confirm |
| R14 | Public test instance + per-auth credentials | provide |

**Smallest critical path to a working demo:** R1 (confirm `RPCCallHeaders` routing —
no server change) + one auth mode (R2 *or* R3) + R6 (discovery) + R11 (TLS) + R13
(driver/conn string). The rest hardens it for DirectQuery and certification.
