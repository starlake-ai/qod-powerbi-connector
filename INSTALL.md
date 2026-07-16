# Installing the QoD (Quack on Demand) Power BI Connector

Three ways to get the connector into Power BI, depending on whether you want to
**build it yourself**, drop in a **pre-built unsigned** dev build, or deploy a
**signed** build for production.

- [Prerequisites](#prerequisites)
- [The artifacts (`.mez` vs `.pqx`)](#the-artifacts)
- [Option 1 - Build from source](#option-1--build-from-source)
- [Option 2 - Install a pre-built unsigned `.mez`](#option-2--install-a-pre-built-unsigned-mez-devtesting)
- [Option 3 - Install a signed `.pqx`](#option-3--install-a-signed-pqx-production)
- [Connecting](#connecting)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

- **Power BI Desktop** (and/or the on‑premises **data gateway** for refresh in the
  Power BI Service).
- The **Arrow Flight SQL ODBC driver** registered on the machine/gateway - the
  connector wraps it (`Driver = "Arrow Flight SQL ODBC Driver"`). Download and run
  the Windows installer (`.msi`) from
  [Dremio's Arrow Flight SQL ODBC driver page](https://docs.dremio.com/cloud/sonar/client-apps/drivers/arrow-flight-sql-odbc/).
  See the driver-maturity caveat in [docs/architecture.md](docs/architecture.md).
- **To build or sign:** the **Power Query SDK**. Easiest via the VS Code
  *“Power Query SDK”* extension, which provisions the MSBuild SDK and the
  `MakePQX` CLI used below.

## The artifacts

| File | What it is | Loads in PBI when… |
|------|------------|--------------------|
| `QoD.mez` | The connector package - a zip of `QoD.pq` + `resources.resx` + icon PNGs. **Unsigned.** | the “allow any extension” security setting is on (Option 2) |
| `QoD.pqx` | A **packed, signed** connector (signed with a code‑signing certificate). | the signing certificate is trusted (Option 3) |

---

## Option 1 - Build from source

Pick one of the three build paths. All produce `bin/Release/QoD.mez`.

### A. VS Code Power Query SDK (recommended)

1. Open this repo in VS Code with the **Power Query SDK** extension installed.
2. Run **“Build connector project.”**
3. Output: `bin/Release/QoD.mez` (includes the icons; this path can also sign).

### B. `dotnet` CLI

```sh
dotnet build src/QoD.proj -c Release        # -> bin/Release/QoD.mez
```

Uses the `Microsoft.PowerQuery.SdkTools.MSBuild` SDK, which the VS Code extension
provisions (it is **not** on public NuGet). If `dotnet build` can’t resolve the
SDK, use path A or C.

### C. `MakePQX` (validate + package), then add icons

`MakePQX compile` validates the M and packages `QoD.pq` + `resources.resx`, **but
not the icons**:

```sh
MakePQX compile src -d bin/Release -t QoD   # validates M, writes bin/Release/QoD.mez
```

A `.mez` is just a flat zip, so add the icons to get a complete package
(PowerShell):

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stage = Join-Path $env:TEMP "qodmez"
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item src\QoD.pq, src\resources.resx $stage
Copy-Item src\icons\QoD*.png $stage
$out = "bin\Release\QoD.mez"
if (Test-Path $out) { Remove-Item $out -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $out)
Remove-Item $stage -Recurse -Force
```

> `MakePQX` ships with the Power Query SDK (VS Code extension). For headless use,
> invoke it from the SDK tools folder directly.

---

## Option 2 - Install a pre-built unsigned `.mez` (dev/testing)

A pre-built unsigned package is committed in this repo: [bin/Release/QoD.mez](bin/Release/QoD.mez).

1. Copy [`QoD.mez`](bin/Release/QoD.mez) to the custom-connectors folder (create it if missing):

   ```
   %UserProfile%\Documents\Power BI Desktop\Custom Connectors\
   ```

2. In Power BI Desktop: **File → Options and settings → Options → Security →
   Data Extensions** → select **“(Not Recommended) Allow any extension to load
   without validation or warning.”**
3. **Restart** Power BI Desktop (connectors load at startup).
4. **Get Data → search “Quack” → QoD (Quack on Demand).**

**On-premises gateway:** copy `QoD.mez` into the gateway’s custom-connectors
folder and enable custom connectors in the gateway app, then restart the gateway
service.

> Unsigned is for development only - it requires the security downgrade above.
> For shared/production use, sign it (Option 3).

---

## Option 3 - Install a signed `.pqx` (production)

A signed connector loads **without** lowering the security setting - you keep the
**Recommended** setting and **trust the signing certificate's thumbprint** instead.
Power BI's custom-connector trust is thumbprint-allowlist based: a `.pqx` whose
signing certificate's thumbprint is in the trusted list loads with no downgrade;
otherwise it won't load under the Recommended setting.
You need a **code-signing certificate** (`.pfx`, with private key) - either issued
by your CA, or **self-signed** (below, fine for internal/enterprise distribution).

### Create a self-signed code-signing certificate (Windows / PowerShell)

Skip this if you already have a `.pfx` from your CA.

```powershell
# 1. Generate a self-signed CODE-SIGNING cert in the current user's store
$cert = New-SelfSignedCertificate -Type CodeSigningCert `
  -Subject "CN=QoD Connector (self-signed)" `
  -CertStoreLocation Cert:\CurrentUser\My `
  -KeyExportPolicy Exportable -KeyUsage DigitalSignature -KeySpec Signature

$cert.Thumbprint        # SHA-1 thumbprint - you'll trust this below

# 2. Export the private key (.pfx, for signing) and the public cert (.cer, for the trust store)
$pw = ConvertTo-SecureString "changeit" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath code-signing.pfx -Password $pw
Export-Certificate    -Cert $cert -FilePath qod-codesign.cer
```

A self-signed cert does not chain to a trusted root, so on every machine that
loads the connector you must also import the **public** cert into Trusted Root
(see the install step below). CA-issued certs skip that.

### Sign it (publisher)

1. Build `bin/Release/QoD.mez` (Option 1).
2. Pack + sign with a **code-signing certificate** (`.pfx`):

   ```sh
   MakePQX pack --mez bin/Release/QoD.mez --target bin/Release/QoD.pqx \
                --certificate code-signing.pfx --password <pfx-password>
   ```

   Re-sign / countersign an existing `.pqx`:

   ```sh
   MakePQX sign bin/Release/QoD.pqx --certificate code-signing.pfx --password <pw> [--replace]
   ```

3. Verify the signature:

   ```sh
   MakePQX verify bin/Release/QoD.pqx
   ```

### Install it (end user / admin)

1. Copy `QoD.pqx` to the **Custom Connectors** folder (same path as Option 2).
2. Keep the security setting at **“(Recommended) Only allow Microsoft Certified
   and other trusted extensions.”**
3. **Trust the signing certificate’s thumbprint** so PBI accepts it without the
   downgrade. Add the SHA‑1 thumbprint to the Power BI Desktop policy
   (Group Policy *“Trusted Certificate Thumbprints”*, or registry):

   ```powershell
   # Admin - add the thumbprint to Power BI Desktop's trusted list
   $thumb = "<CERT-THUMBPRINT>"
   $key   = "HKLM:\SOFTWARE\Policies\Microsoft\Power BI Desktop"
   New-Item -Path $key -Force | Out-Null
   New-ItemProperty -Path $key -Name "TrustedCertificateThumbprints" `
     -PropertyType MultiString -Value @($thumb) -Force
   ```

   (`TrustedCertificateThumbprints` is a `REG_MULTI_SZ` - one SHA‑1 thumbprint per
   line; deployable org‑wide via Group Policy *“Trusted Certificate Thumbprints”*.)
   The on-prem gateway has an equivalent trusted-thumbprint configuration - consult
   the current Microsoft docs for the exact gateway path on your version.
4. **Self-signed certs only:** import the public cert into Trusted Root so the
   signature chain validates (CA-issued certs skip this):

   ```powershell
   Import-Certificate -FilePath qod-codesign.cer -CertStoreLocation Cert:\LocalMachine\Root
   ```
5. **Restart** Power BI Desktop (or the gateway service).

> Microsoft **certification** is a separate, later step (the public marketplace
> listing). Self-signing + trusted thumbprint covers internal/enterprise
> distribution today. See [docs/certification.md](docs/certification.md).

---

## Releasing via GitHub Actions

Two workflows publish to GitHub Releases:

| Workflow | Trigger | Produces |
|----------|---------|----------|
| [`release-unsigned.yml`](.github/workflows/release-unsigned.yml) | push a `v*` tag, or manual dispatch | **unsigned** `QoD-<version>.mez` as a **pre-release** (Release Candidate) |
| [`release-signed.yml`](.github/workflows/release-signed.yml) | manual dispatch (`version` input) | **signed** `QoD-<version>.pqx` as a full release |

The signed workflow needs two repository **secrets**:

- `SIGNING_PFX_BASE64` - base64 of your code-signing `.pfx`
  (`[Convert]::ToBase64String([IO.File]::ReadAllBytes("code-signing.pfx"))`)
- `SIGNING_PFX_PASSWORD` - the `.pfx` password

It runs on Windows (MakePQX is a Windows executable) and acquires MakePQX from the
`Microsoft.PowerQuery.SdkTools` NuGet package.

---

## Connecting

**Get Data → QoD (Quack on Demand)**, then provide:

| Field | Example | Notes |
|-------|---------|-------|
| Server | `quack.example.com:31338` | `host:port` (defaults to port `31338`) |
| Tenant | `acme` | routed as a gRPC call header |
| Pool | `bi` | routed as a gRPC call header |
| Trust server certificate | `true` / `false` | **required** - `true` **only** for a self-signed dev endpoint; `false` (verify) for production |

Then pick a credential kind:

- **Username / password** → Quack Postgres/BCrypt
- **Key** (static JWT) → external JWT backend
- **OAuth 2.0 / OIDC** → Keycloak / Entra ID / Google / Cognito (configure
  `OAuthConfig` in `src/QoD.pq`)

In M, the equivalent call is:

```m
QoD.Database("quack.example.com:31338", "acme", "bi", true)
```

(`trustServerCertificate` is the required 4th argument; an optional 5th `options`
record takes `UseEncryption`, `ConnectionTimeout`, `CommandTimeout`.)

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Connector not listed in **Get Data** | `.mez`/`.pqx` not in the Custom Connectors folder, or Power BI Desktop not restarted. |
| *“… couldn’t load … not trusted”* | Unsigned `.mez` without the security downgrade (Option 2), or signed `.pqx` whose cert thumbprint isn’t trusted (Option 3). |
| *“We couldn’t convert a value of type Record to type Logical”* | The 4th arg is `trustServerCertificate` (a logical). Put the `options` **record** in the **5th** position. |
| Login fails / no credentials reach the server | Ensure you’re on a build where the credential rides `CredentialConnectionString` (current `QoD.pq`). Details: [docs/quack-server-spec.md](docs/quack-server-spec.md) R4a / §11. |
| Empty navigator / `Unknown GetInfo type: 17` | Known Dremio ODBC driver-maturity gap; the strategic path is ADBC. See [docs/architecture.md](docs/architecture.md) and `quack-server-spec.md` R13/R15. |
