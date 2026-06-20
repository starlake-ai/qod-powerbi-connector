# System-user ("superuser") mode - design

**Date:** 2026-06-20
**Status:** Approved (design); implementation pending
**Affects:** `src/QoD.pq`, `src/resources.resx`, `src/QoD.query.pq`, `docs/quack-server-spec.md`

## Problem

Operators need a way to connect through the QoD Power BI connector as a
**system user** that can see every object in the connected tenant/pool, instead
of being limited to the normal per-identity RBAC scope. Today every connection is
identity-scoped and the server enforces object/row RBAC; there is no path to an
elevated, all-access view for an administrator or service principal.

## Trust model (the core constraint)

The connector flag is a **request**, never a grant. Authorization stays entirely
server-side:

- The connector sends a per-call header signalling "system-user mode requested".
- The Quack server checks whether the **per-call authenticated principal**
  (Basic / static JWT / OIDC token) is on its configured system-user list.
- Only if that identity qualifies does the server bypass normal object/row RBAC.
- A non-system principal that sets the flag gets normal RBAC, or
  `UNAUTHENTICATED` - the flag itself confers nothing.

This is the only safe shape: a client-set boolean cannot be the privilege, or any
user could self-elevate. The design is acceptable for Microsoft certification and
security review **because** the server re-authorizes against the authenticated
identity on every call.

## Scope of elevation

System-user mode is **scoped to the connected tenant/pool** - it does not span
tenants. `tenant` and `pool` remain required connect parameters and routing is
unchanged; the server simply grants the qualifying identity full object access
*within* that tenant/pool instead of filtered RBAC.

Explicitly out of scope (deferred, YAGNI):

- Cross-tenant / all-tenant access.
- A tenant-spanning navigator (extra navigation level).
- A separate "admin" authentication kind / credential.

## Wire format

A dedicated forwarded property `superuser`, carried the same way as `tenant` /
`pool`: an unknown key on the ODBC connection string that the Arrow Flight SQL
driver auto-forwards as a gRPC call header (surfaced server-side as
`x-qod-superuser`). It rides **every** RPC, consistent with the per-call
credential model (`x-qod-authorization`) and per-call routing headers.

- Attached **only when `true`**. Absence is interpreted by the server as `false`.
  This keeps the connection string clean and means the server only ever parses a
  truthy value.

## Connector changes (`src/QoD.pq`, `src/resources.resx`)

1. **New required parameter** in the data-source function record, placed next to
   `trustServerCertificate`:

   ```
   superuser as (
       type logical meta [
           Documentation.FieldCaption     = Extension.LoadString("SuperuserFieldCaption"),
           Documentation.FieldDescription = Extension.LoadString("SuperuserFieldDescription"),
           Documentation.AllowedValues    = {true, false}
       ]
   ),
   ```

   Renders as a True/False dropdown (required logical), normal/expected value
   `false`. Required - not an optional Advanced-options checkbox - so it is
   replayed on gateway/Service refresh (same rationale that made
   `trustServerCertificate` required: PBI drops optional options on reconnect).

2. **New resx strings** in `src/resources.resx`:
   - `SuperuserFieldCaption` = e.g. "System user (all access)"
   - `SuperuserFieldDescription` = e.g. "Request system-user mode. The server
     grants full access only if your account is a configured system user;
     otherwise normal permissions apply. Use only for administrative accounts."

3. **`QoDImpl` signature** gains `superuser as logical`, threaded through to the
   connection-property builder.

4. **Connection props:** `superuser` is added to the forwarded scope props (via
   `EncodeScope` / `BuildConnectionString`) **only when `true`**, so it travels as
   a gRPC call header on every RPC.

5. **`TestConnection` replay** adds `json[superuser]` to the replayed argument
   list, so the required parameter check passes on gateway/Service refresh.

## Server-side contract (documentation only, in this repo)

Add a requirement to `docs/quack-server-spec.md` §3 (Authentication):

- The server reads the `superuser` / `x-qod-superuser` call header on every RPC.
- It elevates to all-object access within the routed tenant/pool **only** if the
  per-call authenticated principal is a configured system user.
- The flag never bypasses authentication, and never widens scope beyond the
  routed tenant/pool.
- Absent / `false` = normal RBAC.
- Acceptance: a configured system user with `superuser=true` sees every object in
  the tenant/pool; the same user with the flag off sees normal RBAC; a
  non-system user with `superuser=true` is unaffected or denied (server's
  documented choice).

Implementing the server behaviour is the Quack team's responsibility; this repo
only specifies the contract.

## Testing

- Add a smoke entry to `src/QoD.query.pq` exercising a connection with
  `superuser=true`.
- Document manual Power BI Desktop verification following the existing validation
  log pattern in `docs/quack-server-spec.md`:
  - system user + `superuser=true` -> all objects in the tenant/pool visible;
  - system user + `superuser=false` -> normal RBAC;
  - non-system user + `superuser=true` -> unaffected or `UNAUTHENTICATED`.

## Risks / notes

- **Security perception:** a client-set "all access" boolean will draw scrutiny in
  review and certification. Mitigated by the server-authorizes trust model, made
  explicit in both the field description and the server spec.
- **Required-vs-checkbox UX:** the option is a dropdown, not a checkbox, a
  deliberate trade to survive gateway refresh (consistent with
  `trustServerCertificate`).
