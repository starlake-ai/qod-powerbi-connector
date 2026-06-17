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
> so we must use an *ODBC* driver — and no ODBC build reliably forwards arbitrary
> headers. Several requirements below exist to bridge that gap.

---

## 2. Scope routing (tenant / pool)

### R1 — Accept tenant/pool via standard catalog/schema properties **(change)**
Today Quack takes `tenant` and `pool` as JDBC URL parameters (delivered as gRPC
call headers). The ODBC path cannot rely on custom headers, so the connector sends
scope through the **standard Flight SQL catalog/schema connection properties**:

| Connection property | Quack meaning |
|---------------------|---------------|
| `database` (catalog) | `tenant`     |
| `schema`             | `pool`       |

These arrive on the Flight SQL session at connect time (and on `GetFlightInfo` /
statement requests as the catalog/schema context).

**Acceptance criteria**
- A Flight SQL client connecting with catalog=`tpch`, schema=`sales` is routed to
  tenant `tpch`, pool `sales` — identical behavior to the JDBC
  `?tenant=tpch&pool=sales` form.
- If catalog/schema are omitted, Quack returns a clear error naming the missing
  scope (not a generic failure).
- **(confirm)** Quack still also honors the existing `tenant`/`pool` gRPC headers,
  so the JDBC path is unaffected.

> If a single-property encoding is preferred on your side, we can instead send a
> dotted `schema=tenant.pool` — tell us which you want; it's a one-line change in
> the connector. Catalog+schema (above) is our default as it needs no parsing.

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

### R7 — Type metadata **(confirm)**
- `GetXdbcTypeInfo` (or `GetSqlInfo` type metadata) exposes the DuckDB type system
  so the ODBC driver can map types to Power BI types correctly.
- **Acceptance:** DECIMAL, DATE, TIMESTAMP, BOOLEAN, large strings, and 64-bit
  integers round-trip into Power BI with correct types (no silent truncation).

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

### R9 — Prepared / parameterized statements **(confirm)**
- Flight SQL `CreatePreparedStatement` / parameter binding works for DirectQuery
  parameterized execution.
- **Acceptance:** a parameterized predicate executes without error and binds
  correctly.

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

### R12 — Error semantics **(confirm)**
- Auth, authorization (RBAC denied), not-found, and SQL errors return distinct
  Flight SQL status codes (`UNAUTHENTICATED`, `PERMISSION_DENIED`, `NOT_FOUND`,
  `INVALID_ARGUMENT`) with human-readable messages.
- **Acceptance:** the connector can surface actionable errors (e.g. "wrong
  password" vs "no access to table X") rather than a generic failure.

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
| R1 | tenant/pool via `database`/`schema` | change |
| R2 | Username/password (Basic) | confirm |
| R3 | JWT bearer token | confirm |
| R4 | OIDC access token + audience/issuer/scopes | confirm |
| R5 | Per-statement auth continuity + token lifetime | confirm |
| R6 | Catalog/schema/table discovery (RBAC-scoped) | confirm |
| R7 | Type metadata | confirm |
| R8 | SQL pushdown / DirectQuery folding | confirm |
| R9 | Prepared/parameterized statements | confirm |
| R10 | Result streaming without silent caps | confirm |
| R11 | TLS cert + SNI host | confirm |
| R12 | Distinct error status codes | confirm |
| R13 | Recommended ODBC driver + connection strings | confirm |
| R14 | Public test instance + per-auth credentials | provide |

**Smallest critical path to a working demo:** R1 (scope mapping) + one auth mode
(R2 *or* R3) + R6 (discovery) + R11 (TLS) + R13 (driver/conn string). The rest
hardens it for DirectQuery and certification.
