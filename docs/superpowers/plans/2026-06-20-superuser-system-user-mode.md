# System-user ("superuser") Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a required `superuser` connector parameter that requests system-user mode; the connector forwards it as a per-call header only when true, and the Quack server (per the documented contract) elevates access only for an authenticated principal that is a configured system user.

**Architecture:** Pure Power Query (M) custom-connector change in `src/QoD.pq`, with user-facing strings in `src/resources.resx`. The flag travels as an unknown ODBC connection-string key (`superuser`) that the Arrow Flight SQL driver auto-forwards as a gRPC call header (surfaced server-side as `x-qod-superuser`), exactly like `tenant`/`pool`. Authorization is entirely server-side; the connector only sends a request. The server behaviour is specified (not implemented) in `docs/quack-server-spec.md`.

**Tech Stack:** Power Query M, Power Query SDK / `MakePQX` (M validation, Windows/CI), Arrow Flight SQL ODBC driver.

## Global Constraints

- **No automated M unit tests exist.** The authoritative validation is `MakePQX compile src -d bin/Release -t QoD` (Windows / Power Query SDK / CI). It is **not** runnable on macOS. Each task therefore gates locally on greppable structural assertions; the compile + manual Power BI evaluation is the final gate, run where the SDK exists.
- **The flag is a request, never a grant.** The connector must not imply client-side authority. Authorization is server-side against the authenticated principal.
- **Send `superuser` only when `true`.** Absence = false. Never emit `superuser=false` on the wire.
- **`superuser` is a required `type logical` parameter** with `Documentation.AllowedValues = {true, false}` — renders as a True/False dropdown, replayed by `TestConnection` so it survives gateway/Service refresh. Mirror the existing `trustServerCertificate` pattern exactly.
- **Parameter order is fixed:** `(server, tenant, pool, trustServerCertificate, superuser, optional options)`. The new required param goes after `trustServerCertificate` and before `optional options`. `TestConnection`'s positional replay array must match this order.
- **Em dash (`—`) is banned** in all files (repo convention). Use `-`.

---

### Task 1: Add user-facing strings for the superuser field

**Files:**
- Modify: `src/resources.resx` (after the `TrustCertFieldDescription` block, currently ending at line 62)

**Interfaces:**
- Consumes: nothing.
- Produces: two resource keys loaded by M in Task 2 via `Extension.LoadString`: `SuperuserFieldCaption`, `SuperuserFieldDescription`.

- [ ] **Step 1: Add the two `<data>` entries**

Insert immediately after the closing `</data>` of the `TrustCertFieldDescription` entry (after line 62 in `src/resources.resx`):

```xml
  <data name="SuperuserFieldCaption" xml:space="preserve">
    <value>System user (all access)</value>
  </data>
  <data name="SuperuserFieldDescription" xml:space="preserve">
    <value>Request system-user mode. The server grants full access only if your account is a configured system user; otherwise your normal permissions apply. Use only for administrative accounts.</value>
  </data>
```

- [ ] **Step 2: Verify both keys are present and the file has no em dash**

Run:
```bash
cd /Users/hayssams/git/public/qod-powerbi-connector
grep -c -e 'SuperuserFieldCaption' -e 'SuperuserFieldDescription' src/resources.resx
grep -c '—' src/resources.resx
```
Expected: first command prints `2`; second prints `0`.

- [ ] **Step 3: Verify the resx is still well-formed XML**

Run:
```bash
python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('src/resources.resx'); print('well-formed')"
```
Expected: `well-formed`

- [ ] **Step 4: Commit**

```bash
git add src/resources.resx
git commit -m "Add resx strings for superuser (system-user) connector field"
```

---

### Task 2: Wire the superuser parameter through the connector

**Files:**
- Modify: `src/QoD.pq`
  - `QoDType` function type (lines 25-62) - add the `superuser` field after `trustServerCertificate`
  - `QoDImpl` signature (line 64) - add `superuser as logical`
  - `QoDImpl` body (lines 72-79) - bind and pass `superuser`
  - `BuildConnectionString` (lines 114-121) - accept `superuser`, add it only when true
  - `TestConnection` replay array (line 215) - add `json[superuser]`

**Interfaces:**
- Consumes: `SuperuserFieldCaption`, `SuperuserFieldDescription` (Task 1).
- Produces: the `QoD.Database` function now has arity `(server as text, tenant as text, pool as text, trustServerCertificate as logical, superuser as logical, optional options as record)`. Task 3's query calls rely on this exact order.

- [ ] **Step 1: Add the `superuser` field to `QoDType`**

In `src/QoD.pq`, replace the `trustServerCertificate` field block plus the start of the `optional options` block (lines 47-55):

```
    // Required, no default — true only for a self-signed dev endpoint.
    trustServerCertificate as (
        type logical meta [
            Documentation.FieldCaption = Extension.LoadString("TrustCertFieldCaption"),
            Documentation.FieldDescription = Extension.LoadString("TrustCertFieldDescription"),
            Documentation.AllowedValues = {true, false}
        ]
    ),
    optional options as (
```

with (note: replace the banned em dash in the existing comment with `-`):

```
    // Required, no default - true only for a self-signed dev endpoint.
    trustServerCertificate as (
        type logical meta [
            Documentation.FieldCaption = Extension.LoadString("TrustCertFieldCaption"),
            Documentation.FieldDescription = Extension.LoadString("TrustCertFieldDescription"),
            Documentation.AllowedValues = {true, false}
        ]
    ),
    // Required. A request for system-user mode; the server authorizes it against
    // the authenticated principal. Normal value is false.
    superuser as (
        type logical meta [
            Documentation.FieldCaption = Extension.LoadString("SuperuserFieldCaption"),
            Documentation.FieldDescription = Extension.LoadString("SuperuserFieldDescription"),
            Documentation.AllowedValues = {true, false}
        ]
    ),
    optional options as (
```

- [ ] **Step 2: Update the `QoDImpl` signature**

Replace line 64:

```
QoDImpl = (server as text, tenant as text, pool as text, trustServerCertificate as logical, optional options as record) as table =>
```

with:

```
QoDImpl = (server as text, tenant as text, pool as text, trustServerCertificate as logical, superuser as logical, optional options as record) as table =>
```

- [ ] **Step 3: Bind `superuser` and pass it to the connection-string builder**

Replace the `QoDImpl` body lines 72-79:

```
        opts            = options ?? [],
        UseEncryption   = opts[UseEncryption]? ?? true,
        TrustServerCert = trustServerCertificate,
        ConnectTimeout  = opts[ConnectionTimeout]? ?? 30,   // seconds
        QueryTimeout    = opts[CommandTimeout]? ?? 600,     // seconds

        // tenant/pool only — the credential rides CredentialConnectionString, not this.
        ConnectionString = BuildConnectionString(Host, Port, tenant, pool, UseEncryption, TrustServerCert),
```

with (also de-em-dashes the existing comment):

```
        opts            = options ?? [],
        UseEncryption   = opts[UseEncryption]? ?? true,
        TrustServerCert = trustServerCertificate,
        Superuser       = superuser,
        ConnectTimeout  = opts[ConnectionTimeout]? ?? 30,   // seconds
        QueryTimeout    = opts[CommandTimeout]? ?? 600,     // seconds

        // tenant/pool ride here; the credential rides CredentialConnectionString.
        ConnectionString = BuildConnectionString(Host, Port, tenant, pool, UseEncryption, TrustServerCert, Superuser),
```

- [ ] **Step 4: Extend `BuildConnectionString` to add `superuser` only when true**

Replace `BuildConnectionString` (lines 114-121):

```
BuildConnectionString = (host as text, port as any, tenant as text, pool as text, useEncryption as logical, trustCert as logical) as record =>
    [
        Driver = DriverName,
        host   = host,
        port   = Text.From(port),
        useEncryption                  = if useEncryption then "1" else "0",
        disableCertificateVerification = if trustCert then "1" else "0"
    ] & EncodeScope(tenant, pool);
```

with:

```
BuildConnectionString = (host as text, port as any, tenant as text, pool as text, useEncryption as logical, trustCert as logical, superuser as logical) as record =>
    [
        Driver = DriverName,
        host   = host,
        port   = Text.From(port),
        useEncryption                  = if useEncryption then "1" else "0",
        disableCertificateVerification = if trustCert then "1" else "0"
    ]
    & EncodeScope(tenant, pool)
    // System-user request rides as an unknown key (gRPC header `x-qod-superuser`),
    // sent only when true. Absence = false; the server is the sole authority.
    & (if superuser then [ superuser = "true" ] else []);
```

- [ ] **Step 5: Add `superuser` to the `TestConnection` positional replay**

Replace line 215 and tidy the preceding comment (lines 209-215):

```
    // Powers gateway/service refresh; must replay all required params, including
    // trustServerCertificate, or the parameter check fails.
    TestConnection = (dataSourcePath) =>
        let
            json = Json.Document(dataSourcePath)
        in
            { "QoD.Database", json[server], json[tenant], json[pool], json[trustServerCertificate] },
```

with:

```
    // Powers gateway/service refresh; must replay all required params, including
    // trustServerCertificate and superuser, or the parameter check fails.
    TestConnection = (dataSourcePath) =>
        let
            json = Json.Document(dataSourcePath)
        in
            { "QoD.Database", json[server], json[tenant], json[pool], json[trustServerCertificate], json[superuser] },
```

- [ ] **Step 6: Verify the wiring structurally (runnable on macOS)**

Run:
```bash
cd /Users/hayssams/git/public/qod-powerbi-connector
echo "1 superuser field in type:";        grep -c 'SuperuserFieldCaption' src/QoD.pq
echo "2 QoDImpl arity:";                   grep -c 'superuser as logical, optional options as record' src/QoD.pq
echo "3 builder sends only-when-true:";    grep -c 'if superuser then \[ superuser = "true" \] else \[\]' src/QoD.pq
echo "4 builder arity:";                   grep -c 'useEncryption as logical, trustCert as logical, superuser as logical' src/QoD.pq
echo "5 TestConnection replays it:";       grep -c 'json\[superuser\]' src/QoD.pq
echo "6 never sends false:";               grep -c 'superuser = "false"' src/QoD.pq
echo "7 no em dash:";                      grep -c '—' src/QoD.pq
```
Expected: lines 1-5 each print `1`; line 6 prints `0` (we never emit false); line 7 prints `0`.

- [ ] **Step 7: Validate the M compiles (Windows / Power Query SDK / CI)**

Run (on a machine with the Power Query SDK; **not** macOS):
```
MakePQX compile src -d bin/Release -t QoD
```
Expected: exits 0, writes `bin/Release/QoD.mez`, no parameter/type errors.

> If you are on macOS and cannot run `MakePQX`, mark this step as deferred-to-CI and rely on Step 6 plus the Task 3 evaluation; do not claim it passed without output.

- [ ] **Step 8: Commit**

```bash
git add src/QoD.pq
git commit -m "Add superuser parameter: forward as per-call header only when true"
```

---

### Task 3: Update the test/sample query for the new arity

**Files:**
- Modify: `src/QoD.query.pq` (header comment lines 7-9, and every `QoD.Database(...)` call - lines 13, 21, 29, 40)

**Interfaces:**
- Consumes: `QoD.Database(server, tenant, pool, trustServerCertificate, superuser, [options])` (Task 2). Every existing 4-arg call is now invalid and must gain the `superuser` argument.

- [ ] **Step 1: Update the signature note in the header comment**

Replace lines 7-9:

```
// Signature: QoD.Database(server, tenant, pool, trustServerCertificate, [options]).
// `trustServerCertificate` is REQUIRED (true = skip TLS cert check, for a
// self-signed dev endpoint; false = verify, for production).
```

with:

```
// Signature: QoD.Database(server, tenant, pool, trustServerCertificate, superuser, [options]).
// `trustServerCertificate` is REQUIRED (true = skip TLS cert check, for a
// self-signed dev endpoint; false = verify, for production).
// `superuser` is REQUIRED (true = request system-user/all-access mode, granted
// only if the server recognizes your account as a system user; false = normal).
```

- [ ] **Step 2: Add the `superuser` argument to the smoke test (false = normal)**

Replace line 13:

```
    Source = QoD.Database("quack.example.com:31338", "tpch", "sales", true)
```

with:

```
    Source = QoD.Database("quack.example.com:31338", "tpch", "sales", true, false)
```

- [ ] **Step 3: Add `superuser` to the commented navigation and folding checks**

Replace line 21:

```
//     Source = QoD.Database("quack.example.com:31338", "tpch", "sales", true),
```
with:
```
//     Source = QoD.Database("quack.example.com:31338", "tpch", "sales", true, false),
```

Replace line 29:

```
//     Source   = QoD.Database("quack.example.com:31338", "tpch", "sales", true),
```
with:
```
//     Source   = QoD.Database("quack.example.com:31338", "tpch", "sales", true, false),
```

- [ ] **Step 4: Update the Advanced-options example and its parameter-order note**

Replace lines 36-40:

```
// Advanced options (TLS off for local dev, custom timeout). NOTE the parameter
// order: (server, tenant, pool, trustServerCertificate as logical, options as
// record). The options record is the 5th arg — passing it as the 4th hits the
// logical `trustServerCertificate` slot and errors "convert Record to Logical".
// QoD.Database("localhost:31338", "tpch", "sales", true, [UseEncryption = false, CommandTimeout = 120])
```

with (de-em-dashed, corrected arg position, options now 6th):

```
// Advanced options (TLS off for local dev, custom timeout). NOTE the parameter
// order: (server, tenant, pool, trustServerCertificate as logical, superuser as
// logical, options as record). The options record is the 6th arg - passing it in
// a logical slot errors "convert Record to Logical".
// QoD.Database("localhost:31338", "tpch", "sales", true, false, [UseEncryption = false, CommandTimeout = 120])
```

- [ ] **Step 5: Add a dedicated superuser smoke block**

Append at the end of `src/QoD.query.pq`:

```
// System-user mode: request all-access. The server grants it only if the
// authenticated account is a configured system user; otherwise normal RBAC.
// let
//     Source = QoD.Database("quack.example.com:31338", "tpch", "sales", true, true)
// in
//     Source
```

- [ ] **Step 6: Verify every call now passes five-or-more args and no stale 4-arg call remains**

Run:
```bash
cd /Users/hayssams/git/public/qod-powerbi-connector
echo "stale 4-arg calls (expect 0):"
grep -nE 'QoD\.Database\("[^"]*", *"[^"]*", *"[^"]*", *(true|false)\)' src/QoD.query.pq | wc -l
echo "no em dash (expect 0):"
grep -c '—' src/QoD.query.pq
```
Expected: both print `0`.

- [ ] **Step 7: (Where the SDK exists) evaluate the smoke query against a live Quack**

In the Power Query SDK: set a credential, then "Evaluate current file". Expected: the source opens and lists catalogs/schemas (same as before the change). This confirms the new required arg did not break the normal path. Behavioural superuser verification is covered by Task 4's manual checklist.

- [ ] **Step 8: Commit**

```bash
git add src/QoD.query.pq
git commit -m "Update sample queries for new required superuser argument"
```

---

### Task 4: Specify the server-side contract and validation

**Files:**
- Modify: `docs/quack-server-spec.md` (§3 Authentication - add a new requirement after R4a, currently ending ~line 116; the requirements checklist table ~lines 277-288; the validation log §11 open-items note ~line 347)

**Interfaces:**
- Consumes: the wire contract from Task 2 (header key `superuser` / `x-qod-superuser`, sent only when true).
- Produces: documentation only - no code depends on this task.

- [ ] **Step 1: Add the requirement under §3, after the R4a block**

Insert after the R4a "Acceptance" bullet (after line 116) in `docs/quack-server-spec.md`:

```markdown

### R4b - System-user ("superuser") mode **(spec - server work pending)**
The connector sends an optional per-call header **`x-qod-superuser: true`** (ODBC
key `superuser`, forwarded by the driver; sent **only when requested**, absent =
false). It is a **request**, not a grant.
- Quack reads the header on every RPC and elevates the connection to **full object
  access within the routed tenant/pool** (bypassing normal object/row RBAC) **only
  if** the per-call authenticated principal is a **configured system user**.
- The flag never bypasses authentication and never widens scope beyond the routed
  `tenant`/`pool`. Cross-tenant access is out of scope.
- A non-system principal that sets the flag gets normal RBAC, or `UNAUTHENTICATED`
  - server's documented choice.
- **Acceptance:** a configured system user with `superuser=true` sees every object
  in the tenant/pool; the same user with the flag off sees normal RBAC; a
  non-system user with `superuser=true` is unaffected or denied.
- **(confirm)** The mechanism Quack uses to designate system users (a role/claim,
  a `qodstate_user` flag, or a config allowlist) - needed to finalize the server
  side.
```

- [ ] **Step 2: Add a checklist row for R4b**

In the requirements table (after the R4a row, ~line 283), add:

```markdown
| R4b | System-user mode (`x-qod-superuser`, server-authorized) | spec | 🟡 connector sends header (only when true); server elevation + system-user designation pending |
```

- [ ] **Step 3: Note R4b in the validation-log open items**

In §11, append `R4b superuser elevation` to the **Open:** list (~line 347), e.g. change the trailing open-items sentence to include `; R4b superuser elevation (server)`.

- [ ] **Step 4: Verify the edits landed and no em dash was introduced**

Run:
```bash
cd /Users/hayssams/git/public/qod-powerbi-connector
echo "R4b present (expect >=2):"; grep -c 'R4b' docs/quack-server-spec.md
echo "header documented (expect >=1):"; grep -c 'x-qod-superuser' docs/quack-server-spec.md
echo "no em dash (expect 0):"; grep -c '—' docs/quack-server-spec.md
```
Expected: R4b count `>= 2`, header count `>= 1`, em dash `0`.

- [ ] **Step 5: Commit**

```bash
git add docs/quack-server-spec.md
git commit -m "Spec R4b: server-authorized system-user (superuser) mode contract"
```

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-06-20-superuser-system-user-mode-design.md`):
- Trust model (hint, server authorizes) -> Task 1 field description + Task 4 R4b. ✅
- Scope = within tenant/pool, tenant/pool stay required -> Task 2 (params unchanged) + Task 4. ✅
- Wire format `superuser` header, only when true -> Task 2 Step 4. ✅
- Required logical dropdown, AllowedValues -> Task 2 Step 1. ✅
- `QoDImpl` signature + thread-through -> Task 2 Steps 2-3. ✅
- `TestConnection` replay -> Task 2 Step 5. ✅
- New resx strings -> Task 1. ✅
- Smoke query for superuser=true -> Task 3 Step 5. ✅
- Server contract in spec doc -> Task 4. ✅
- Out-of-scope items (cross-tenant, separate admin cred) -> not implemented. ✅

**Placeholder scan:** No TBD/TODO; all code shown literally; the only `(confirm)` is an intentional server-side open question mirroring the existing spec style. ✅

**Type consistency:** `superuser as logical` is consistent across `QoDType`, `QoDImpl`, and `BuildConnectionString`; wire value is the literal text `"true"`; `TestConnection` reads `json[superuser]`; parameter order `(…, trustServerCertificate, superuser, optional options)` is identical in the type, the impl, the replay array, and the query calls. ✅

**Note on TDD:** M custom connectors have no runnable unit-test framework; the "test-first" loop is replaced by structural grep assertions (runnable now) + `MakePQX compile` + manual SDK/PBI evaluation. This is the honest verification path for this toolchain, not an omission.
