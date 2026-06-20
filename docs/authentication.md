# QoD Connector - Authentication & Identity Provider Setup

How to authenticate the QoD (Quack on Demand) Power BI connector, and what an end
customer has to configure on their side for each method.

The connector supports three credential kinds. All three collapse to a single
`x-qod-authorization` gRPC call header that the Quack server validates per call
(see [architecture.md](architecture.md) "Credential -> transport mapping").

| Method in Power BI       | Quack backend                          | Refreshes? | Best for |
|--------------------------|----------------------------------------|------------|----------|
| Username / password      | Postgres / BCrypt                      | n/a        | dev, internal users with DB accounts |
| Access token (JWT)       | External JWT (HS256/RS256)             | no         | service tokens, quick tests |
| OAuth 2.0 / OIDC         | Keycloak / Entra ID / Google / Cognito | yes        | production, end users, scheduled refresh |

- [Choosing a method](#choosing-a-method)
- [Method 1 - Username / password](#method-1---username--password)
- [Method 2 - Access token (JWT)](#method-2---access-token-jwt)
- [Method 3 - OAuth 2.0 / OIDC](#method-3---oauth-20--oidc)
- [The per-customer build constraint](#the-per-customer-build-constraint)
- [Troubleshooting](#troubleshooting)

---

## Choosing a method

- **Just testing, or users already have Quack DB logins?** Use **Username / password**.
- **Need a token but no interactive login (CI, service account)?** Use **Access
  token (JWT)** with a long-lived or service token.
- **Production, real end users, and/or scheduled refresh in the Power BI Service?**
  Use **OAuth 2.0 / OIDC** - it is the only path that refreshes automatically.

In Power BI Desktop the method is picked in the credential dialog that appears
after **Get Data -> Quack on Demand** and filling Server / Tenant / Pool / Trust
cert / System user.

---

## Method 1 - Username / password

The simplest path. In the credential dialog choose **Username / password** and
enter the Quack DB user and password. The connector sends
`Basic base64(user:pass)`; Quack verifies it against its Postgres / BCrypt store.

Nothing to configure on the IdP side - this is Quack-native auth.

---

## Method 2 - Access token (JWT)

Choose **Access token (JWT)** in the credential dialog and paste a JWT into the
single **Access token** field. The connector sends it as `Bearer <token>`.

> Paste the **raw token only** - no `Bearer ` prefix. The connector adds it. A
> pasted `Bearer eyJ...` becomes `Bearer Bearer eyJ...` and is rejected.

### Getting a token from Keycloak

Token endpoint: `https://<host>/realms/<realm>/protocol/openid-connect/token`
(legacy Keycloak: `https://<host>/auth/realms/<realm>/...`).

**Password grant** (client must have *Direct access grants* enabled), PowerShell:

```powershell
$resp = Invoke-RestMethod -Method Post `
  -Uri "https://<host>/realms/<realm>/protocol/openid-connect/token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{
    grant_type = "password"
    client_id  = "quack-powerbi"
    username   = "<user>"
    password   = "<pass>"
    scope      = "openid"
    # client_secret = "<secret>"   # only if the client is confidential
  }
$resp.access_token | Set-Clipboard      # paste this into Power BI
```

**Client credentials grant** (confidential client with *Service accounts* enabled),
for an unattended/service token:

```powershell
$resp = Invoke-RestMethod -Method Post `
  -Uri "https://<host>/realms/<realm>/protocol/openid-connect/token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{ grant_type="client_credentials"; client_id="quack-powerbi"; client_secret="<secret>" }
$resp.access_token
```

### Expiry - the catch

A static JWT does **not** refresh. Keycloak's default access-token lifespan is
**5 minutes**, so a pasted token dies quickly.

- **Testing:** re-run the command and re-paste when it expires (Power BI: *File ->
  Options and settings -> Data source settings -> Edit Permissions -> Edit
  credentials*).
- **Longer-lived token:** raise the lifespan in Keycloak (*Realm settings ->
  Tokens -> Access Token Lifespan*, or per-client *Advanced -> Access Token
  Lifespan*).
- **Scheduled refresh in the Service:** static tokens break on expiry - use OAuth
  instead.

### Verify the token before pasting

Confirm it is a JWT and that `iss`/`aud` match what Quack validates:

```powershell
$payload = $resp.access_token.Split('.')[1].Replace('-','+').Replace('_','/')
while ($payload.Length % 4) { $payload += '=' }
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
```

---

## Method 3 - OAuth 2.0 / OIDC

The production path. In Power BI this shows as **Organizational account** - the
user clicks *Sign in*, authenticates in a browser, and Power BI stores the tokens
(refreshing automatically via `offline_access`).

OAuth involves **three** configuration points. The customer owns steps 1 and 3
(their IdP and their Quack); the connector publisher owns step 2 (it is compiled
into the `.mez`).

### Step 1 (customer) - register a Power BI client in the IdP

Power BI custom connectors require a **public client with PKCE** and Power BI's
fixed redirect URI.

#### Keycloak (Admin Console)

**Clients -> Create client** in your realm:

1. **General:** Client type = `OpenID Connect`; Client ID = **`quack-powerbi`**
   (must match `OAuthConfig.ClientId` in the `.mez`).
2. **Capability config:**
   - Client authentication = **Off** (public client - the connector holds no secret)
   - Standard flow = **On**
   - Direct access grants = **On** *(only if you also want the Method 2 password grant)*
3. **Login settings:**
   - Valid redirect URIs = `https://oauth.powerbi.com/views/oauthredirect.html`
   - Web origins = `https://oauth.powerbi.com`
4. Save, then **Advanced -> Proof Key for Code Exchange Code Challenge Method** = **S256**.

`offline_access` is a realm default scope, so refresh tokens work out of the box.

#### Keycloak (Admin REST API, PowerShell)

```powershell
$kc = "https://<host>/realms"        # legacy: "https://<host>/auth/realms"
$adminBase = "https://<host>/admin/realms"   # legacy: "https://<host>/auth/admin/realms"

$admin = Invoke-RestMethod -Method Post -Uri "$kc/master/protocol/openid-connect/token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{ grant_type="password"; client_id="admin-cli"; username="<admin>"; password="<adminpass>" }
$h = @{ Authorization = "Bearer $($admin.access_token)" }

$body = @{
  clientId                  = "quack-powerbi"
  protocol                  = "openid-connect"
  publicClient              = $true
  standardFlowEnabled       = $true
  directAccessGrantsEnabled = $true
  redirectUris              = @("https://oauth.powerbi.com/views/oauthredirect.html")
  webOrigins                = @("https://oauth.powerbi.com")
  attributes                = @{ "pkce.code.challenge.method" = "S256" }
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Method Post -Uri "$adminBase/<realm>/clients" -Headers $h -ContentType "application/json" -Body $body
```

#### Audience (`aud`) mapper - common gotcha

A Keycloak public-client access token often carries `aud: account`, not your API.
If Quack validates audience, add an **Audience mapper** on the client (*Client
scopes -> quack-powerbi-dedicated -> Add mapper -> Audience*) so `aud` includes
what Quack expects. Otherwise sign-in succeeds in Power BI but Quack rejects the
query. Decode the token (snippet above) to confirm.

#### Other IdPs - endpoint shapes

| IdP        | Authorize / Token / Logout base |
|------------|---------------------------------|
| Keycloak   | `https://<host>/realms/<realm>/protocol/openid-connect/{auth,token,logout}` |
| Entra ID   | `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/{authorize,token,logout}` |
| Google     | `https://accounts.google.com/o/oauth2/v2/auth`, `https://oauth2.googleapis.com/token` |
| Cognito    | `https://<domain>.auth.<region>.amazoncognito.com/oauth2/{authorize,token,logout}` |

All use the same redirect URI `https://oauth.powerbi.com/views/oauthredirect.html`
and a public + PKCE client.

### Step 2 (publisher) - point `OAuthConfig` at the realm, rebuild

`OAuthConfig` in [../src/QoD.pq](../src/QoD.pq) is **compiled into the `.mez`**, so
this is done per customer at build time. Example for realm `qod` on a legacy-path
Keycloak:

```m
OAuthConfig = [
    AuthorizeUrl = "http://localhost:20900/auth/realms/qod/protocol/openid-connect/auth",
    TokenUrl     = "http://localhost:20900/auth/realms/qod/protocol/openid-connect/token",
    LogoutUrl    = "http://localhost:20900/auth/realms/qod/protocol/openid-connect/logout",
    ClientId     = "quack-powerbi",
    Scope        = "openid profile email offline_access",
    RedirectUri  = "https://oauth.powerbi.com/views/oauthredirect.html"
];
```

Then rebuild and (for distribution) sign - see [../INSTALL.md](../INSTALL.md).

> Keycloak uses `/auth` for the authorize endpoint (not `/authorize`). Legacy
> Keycloak (<= 16) also prefixes every path with `/auth`.

### Step 3 (customer) - trust the IdP's tokens in Quack

Quack validates the bearer token itself, so the customer's Quack deployment must
trust their IdP:

- **Issuer** (`iss`): e.g. `https://<host>/realms/<realm>`
- **JWKS URI** (RS256): `https://<host>/realms/<realm>/protocol/openid-connect/certs`
- **Audience** (`aud`) it requires (see the audience-mapper note above)
- Mapping from token claims -> Quack tenant / pool authorization

This layer decides whether a successful Power BI sign-in is then accepted or
rejected by Quack at query time.

---

## The per-customer build constraint

A Power BI custom connector cannot accept OAuth endpoints as a runtime parameter -
`OAuthConfig` is static M baked into the `.mez`. Practical consequences:

- **One signed `.mez` / `.pqx` per IdP realm**, with that customer's
  `AuthorizeUrl` / `TokenUrl` / `LogoutUrl` / `ClientId` / `Scope` compiled in; or
- standardize on one corporate IdP for all customers; or
- if the connector is refactored to **OIDC discovery** (hardcode only the issuer
  and derive endpoints from `<issuer>/.well-known/openid-configuration`),
  per-customer changes shrink to a single issuer line - but `ClientId` and `Scope`
  still ship per build.

The **Username / password** and **Access token (JWT)** methods have no baked-in
config, so a single `.mez` serves all customers for those.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Sign-in window fails to load / hangs | `OAuthConfig` still points at a placeholder or wrong host; rebuild with the real endpoints. |
| `redirect_uri` mismatch error from the IdP | The client's Valid redirect URIs must contain exactly `https://oauth.powerbi.com/views/oauthredirect.html`. |
| PKCE / `code_challenge` error | Set the client's PKCE method to **S256** (the connector sends S256). |
| Sign-in succeeds but every query is rejected by Quack | Token `aud`/`iss` not trusted by Quack - add an audience mapper and configure Quack's issuer/JWKS (Step 3). |
| Token works then stops after minutes (Method 2) | Static JWT expired; raise the access-token lifespan or switch to OAuth. |
| Scheduled refresh fails in the Service | Static-JWT path can't refresh; use OAuth with `offline_access`. |
| `Bearer Bearer ...` / 401 with a pasted token | A `Bearer ` prefix was included; paste the raw token only. |
