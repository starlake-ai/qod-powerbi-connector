// QoD - Quack on Demand Power BI Custom Connector
// Connects Power BI / Fabric to a Quack on Demand gateway over Apache Arrow
// Flight SQL via the Arrow Flight SQL ODBC driver. ADBC (the "Dremio path") is
// the later certification-time transport - see docs/architecture.md.
[Version = "1.0.0"]
section QoD;

// Configuration -------------------------------------------------------------

// ODBC driver name as registered on the machine/gateway (Dremio build shown;
// confirm for the build Quack ships).
DriverName = "Arrow Flight SQL ODBC Driver";

DefaultPort = 31338;

// Custom header carrying the credential on every call. The server accepts this
// and standard `Authorization`; an unknown name avoids the driver reserving it.
AuthHeaderName = "x-qod-authorization";

// Data source function ------------------------------------------------------

[DataSource.Kind = "QoD", Publish = "QoD.Publish"]
shared QoD.Database = Value.ReplaceType(QoDImpl, QoDType);

QoDType = type function (
    server as (
        type text meta [
            Documentation.FieldCaption = Extension.LoadString("ServerFieldCaption"),
            Documentation.FieldDescription = Extension.LoadString("ServerFieldDescription"),
            Documentation.SampleValues = {"quack.example.com:31338"}
        ]
    ),
    tenant as (
        type text meta [
            Documentation.FieldCaption = Extension.LoadString("TenantFieldCaption"),
            Documentation.FieldDescription = Extension.LoadString("TenantFieldDescription"),
            Documentation.SampleValues = {"tpch"}
        ]
    ),
    pool as (
        type text meta [
            Documentation.FieldCaption = Extension.LoadString("PoolFieldCaption"),
            Documentation.FieldDescription = Extension.LoadString("PoolFieldDescription"),
            Documentation.SampleValues = {"sales"}
        ]
    ),
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
        type record meta [
            Documentation.FieldCaption = Extension.LoadString("AdvancedOptionsCaption")
        ]
    )
) as table meta [
    Documentation.Name = Extension.LoadString("DataSourceName")
];

QoDImpl = (server as text, tenant as text, pool as text, trustServerCertificate as logical, superuser as logical, optional options as record) as table =>
    let
        Address     = Uri.Parts("flight://" & server),
        Host        = Address[Host],
        Port        = if Address[Port] = null or Address[Port] = "" or Address[Port] = 0
                      then DefaultPort
                      else Address[Port],

        opts            = options ?? [],
        UseEncryption   = opts[UseEncryption]? ?? true,
        TrustServerCert = trustServerCertificate,
        Superuser       = superuser,
        ConnectTimeout  = opts[ConnectionTimeout]? ?? 30,   // seconds
        QueryTimeout    = opts[CommandTimeout]? ?? 600,     // seconds

        // tenant/pool ride here; the credential rides CredentialConnectionString.
        ConnectionString = BuildConnectionString(Host, Port, tenant, pool, UseEncryption, TrustServerCert, Superuser),

        Credential       = Extension.CurrentCredential(),
        CredProperties   = CredentialToOdbcProperties(Credential),

        OdbcOptions = [
            HierarchicalNavigation = true,
            HideNativeQuery        = false,
            ConnectionTimeout      = #duration(0, 0, 0, ConnectTimeout),
            CommandTimeout         = #duration(0, 0, 0, QueryTimeout),

            SqlCapabilities = SqlCaps,
            SQLGetInfo      = SqlGetInfoOverrides,
            SQLGetFunctions = SqlGetFunctionsOverrides,
            SQLGetTypeInfo  = SqlGetTypeInfoOverrides,

            ClientConnectionPooling = true,
            OnError = OnOdbcError,
            SoftNumbers = true,
            TolerateConcatOverflow = true,

            // MUST use CredentialConnectionString: it stops Power BI auto-injecting
            // UID/PWD, which would trigger a Flight Handshake before tenant/pool are
            // attached and fail login. See docs/architecture.md + spec R4a / §11.
            CredentialConnectionString = CredProperties
        ],

        Source = Odbc.DataSource(ConnectionString, OdbcOptions)
    in
        Source;

// Connection string builder -------------------------------------------------
// Dremio ODBC property keys; booleans are the literals "1"/"0".
//   ref: https://docs.dremio.com/cloud/sonar/client-apps/drivers/arrow-flight-sql-odbc/

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

// tenant/pool as separate plain props: the driver auto-forwards unknown keys as
// gRPC call headers (same routing contract as JDBC). NOT a packed RPCCallHeaders
// value - its embedded ;/= corrupts the ODBC connection string.
EncodeScope = (tenant as text, pool as text) as record =>
    [
        tenant = tenant,
        pool   = pool
    ];

// Maps the selected PBI credential to one auth header (no native UID/PWD/token):
//   UsernamePassword -> Basic base64(user:pass) ; Key/OAuth -> Bearer <token>
CredentialToOdbcProperties = (cred as record) as record =>
    let
        kind = cred[AuthenticationKind],
        authValue =
            if kind = "UsernamePassword" then
                // Strip trailing `=` padding: the driver splits connstring props on
                // `=`. Server re-pads before BCrypt-decoding (spec R2). Standard
                // alphabet (not URL-safe - cf. Base64UrlNoPadding for OAuth PKCE).
                "Basic " & Text.TrimEnd(
                    Binary.ToText(
                        Text.ToBinary(cred[Username] & ":" & cred[Password], TextEncoding.Utf8),
                        BinaryEncoding.Base64),
                    "=")
            else if kind = "Key" then
                "Bearer " & cred[Key]
            else if kind = "OAuth" then
                "Bearer " & cred[access_token]
            else
                error Error.Record(
                    "QoD.UnsupportedAuth",
                    "Unsupported authentication kind: " & kind
                )
    in
        Record.AddField([], AuthHeaderName, authValue);

// ODBC capability shaping (DirectQuery folding) -----------------------------

// Supports*Literals MUST stay true: Quack has no parameter binding, so the M
// engine must inline literals instead of emitting `?` params (spec R9).
SqlCaps = [
    SupportsTop                   = false,
    LimitClauseKind               = LimitClauseKind.LimitOffset,
    Sql92Conformance              = 8 /* SQL_SC_SQL92_FULL */,
    SupportsNumericLiterals       = true,
    SupportsStringLiterals        = true,
    SupportsOdbcDateLiterals      = true,
    SupportsOdbcTimeLiterals      = true,
    SupportsOdbcTimestampLiterals = true,
    GroupByCapabilities           = 4 /* SQL_GB_GROUP_BY_CONTAINS_SELECT */,
    FractionalSecondsScale        = 6
];

SqlGetInfoOverrides = [
    // SQL_DBMS_NAME (info 17) can't be set here (PBI allows only capability flags);
    // the Dremio build erroring on it is a driver gap.
    SQL_SQL92_PREDICATES    = 0x0000FFFF,
    SQL_AGGREGATE_FUNCTIONS = 0x0000007F,
    SQL_SQL_CONFORMANCE     = 4 /* SQL_SC_SQL92_FULL */,
    SQL_GROUP_BY            = 2 /* SQL_GB_GROUP_BY_CONTAINS_SELECT */,

    // Force catalog navigation: the Dremio build pre-seeds SQL_CATALOG_NAME="N"
    // before reading the server, so we override it at the M layer or PBI shows no
    // catalogs (empty tree).
    SQL_CATALOG_NAME           = "Y",
    SQL_CATALOG_TERM           = "database",
    SQL_CATALOG_NAME_SEPARATOR = ".",
    SQL_CATALOG_LOCATION       = 1           /* SQL_CL_START */
];

// Scalar/aggregate functions DuckDB can fold (conservative; widen after validation).
SqlGetFunctionsOverrides = [
    SQL_CONVERT_FUNCTIONS  = 0x00000002 /* SQL_FN_CVT_CAST */,
    SQL_STRING_FUNCTIONS   = 0x0017FFFF,
    SQL_NUMERIC_FUNCTIONS  = 0x00FFFFFF,
    SQL_TIMEDATE_FUNCTIONS = 0x0003FFFF
];

SqlGetTypeInfoOverrides = (types as table) as table => types;

OnOdbcError = (errorRecord as record) =>
    error errorRecord;

// Data Source Kind - authentication & test connection -----------------------

QoD = [
    // Powers gateway/service refresh; must replay all required params, including
    // trustServerCertificate and superuser, or the parameter check fails.
    TestConnection = (dataSourcePath) =>
        let
            json = Json.Document(dataSourcePath)
        in
            { "QoD.Database", json[server], json[tenant], json[pool], json[trustServerCertificate], json[superuser] },

    Authentication = [
        UsernamePassword = [
            Label = Extension.LoadString("AuthUsernamePasswordLabel")
        ],
        Key = [
            Label    = Extension.LoadString("AuthKeyLabel"),
            KeyLabel = Extension.LoadString("AuthKeyKeyLabel")
        ],
        OAuth = [
            StartLogin  = StartLogin,
            FinishLogin = FinishLogin,
            Refresh     = Refresh,
            Logout      = Logout
        ]
    ],

    Label = Extension.LoadString("DataSourceLabel")
];

// OAuth 2.0 / OIDC - authorization-code + PKCE.
//
// ===========================================================================
//  EDIT YOUR IDENTITY PROVIDER HERE - this is the ONLY block you change to
//  point the connector at a different IdP. Replace the six values below, then
//  rebuild the .mez. Ready-to-paste examples for Azure / AWS / GCP follow.
//
//  In every provider, register `RedirectUri` (kept constant below) as an
//  allowed redirect/callback URL on the OAuth client, or login fails.
// ===========================================================================

OAuthConfig = [
    AuthorizeUrl = "http://192.168.1.113:20900/auth/realms/qod/protocol/openid-connect/auth",
    TokenUrl     = "http://192.168.1.113:20900/auth/realms/qod/protocol/openid-connect/token",
    LogoutUrl    = "http://192.168.1.113:20900/auth/realms/qod/protocol/openid-connect/logout",
    ClientId     = "quack-powerbi",
    Scope        = "openid profile email offline_access",

    // Fixed by Power BI - do NOT change. Register this exact value on the IdP.
    RedirectUri  = "https://oauth.powerbi.com/views/oauthredirect.html"
];

// ---------------------------------------------------------------------------
//  PROVIDER EXAMPLES - copy one over the OAuthConfig values above and fill in
//  the {placeholders}. Each was verified against the provider's OIDC metadata
//  ({issuer}/.well-known/openid-configuration); confirm yours still matches.
// ---------------------------------------------------------------------------
//
// AZURE - Microsoft Entra ID (v2.0 endpoints)
//   Register an app; {tenant} = directory (tenant) GUID or "organizations".
//   {client-id} = Application (client) ID. PKCE-only (no secret) works for a
//   public client. Scope MUST include offline_access for refresh tokens.
//     AuthorizeUrl = "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize",
//     TokenUrl     = "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
//     LogoutUrl    = "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/logout",
//     ClientId     = "{client-id}",
//     Scope        = "openid profile email offline_access",
//
// AWS - Cognito (Hosted UI; needs an App client + a Cognito domain)
//   {domain} = your prefix or custom domain, {region} = e.g. eu-west-1.
//   {client-id} = the App client ID. Cognito issues a refresh token for the
//   auth-code grant automatically; offline_access is accepted but not required.
//     AuthorizeUrl = "https://{domain}.auth.{region}.amazoncognito.com/oauth2/authorize",
//     TokenUrl     = "https://{domain}.auth.{region}.amazoncognito.com/oauth2/token",
//     LogoutUrl    = "https://{domain}.auth.{region}.amazoncognito.com/logout",
//     ClientId     = "{client-id}",
//     Scope        = "openid profile email",
//
// GCP - Google Identity (OAuth client of type "Web application")
//   {client-id} = "....apps.googleusercontent.com". NOTE: Google does NOT use
//   the offline_access scope - it returns a refresh token only when the auth
//   request carries access_type=offline (and prompt=consent on re-consent).
//   Add those to the StartLogin query string for Google; the "logout" endpoint
//   below is actually token revocation (POST token), so Logout is best-effort.
//     AuthorizeUrl = "https://accounts.google.com/o/oauth2/v2/auth",
//     TokenUrl     = "https://oauth2.googleapis.com/token",
//     LogoutUrl    = "https://oauth2.googleapis.com/revoke",
//     ClientId     = "{client-id}.apps.googleusercontent.com",
//     Scope        = "openid profile email",
// ---------------------------------------------------------------------------

StartLogin = (resourceUrl, state, display) =>
    let
        codeVerifier  = Text.NewGuid() & Text.NewGuid(),
        codeChallenge = Base64UrlNoPadding(Crypto.CreateHash(CryptoAlgorithm.SHA256, Text.ToBinary(codeVerifier))),
        authorizeUrl  = OAuthConfig[AuthorizeUrl] & "?" & Uri.BuildQueryString([
            client_id             = OAuthConfig[ClientId],
            response_type         = "code",
            code_challenge        = codeChallenge,
            code_challenge_method = "S256",
            scope                 = OAuthConfig[Scope],
            state                 = state,
            redirect_uri          = OAuthConfig[RedirectUri]
        ])
    in
        [
            LoginUri     = authorizeUrl,
            CallbackUri  = OAuthConfig[RedirectUri],
            WindowHeight = 720,
            WindowWidth  = 1024,
            Context      = codeVerifier
        ];

FinishLogin = (context, callbackUri, state) =>
    let
        parts = Uri.Parts(callbackUri)[Query],
        code  = parts[code]
    in
        TokenExchange([
            grant_type    = "authorization_code",
            code          = code,
            code_verifier = context,
            client_id     = OAuthConfig[ClientId],
            redirect_uri  = OAuthConfig[RedirectUri]
        ]);

Refresh = (resourceUrl, refresh_token) =>
    TokenExchange([
        grant_type    = "refresh_token",
        refresh_token = refresh_token,
        client_id     = OAuthConfig[ClientId]
    ]);

Logout = (token) => OAuthConfig[LogoutUrl];

TokenExchange = (body as record) as record =>
    let
        response = Web.Contents(OAuthConfig[TokenUrl], [
            Content = Text.ToBinary(Uri.BuildQueryString(body)),
            Headers = [
                #"Content-Type" = "application/x-www-form-urlencoded",
                #"Accept"       = "application/json"
            ],
            ManualStatusHandling = {400, 401, 403}
        ]),
        body0 = Json.Document(response)
    in
        body0;

Base64UrlNoPadding = (data as binary) as text =>
    let
        b64 = Binary.ToText(data, BinaryEncoding.Base64),
        url = Text.Replace(Text.Replace(b64, "+", "-"), "/", "_")
    in
        Text.TrimEnd(url, "=");

// UI publish metadata -------------------------------------------------------

QoD.Publish = [
    Beta                = true,
    Category            = "Database",
    ButtonText          = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl        = "https://github.com/starlake-ai/quack-on-demand",
    SourceImage         = QoD.Icons,
    SourceTypeImage     = QoD.Icons,
    SupportsDirectQuery = true
];

QoD.Icons = [
    Icon16 = { Extension.Contents("QoD16.png"), Extension.Contents("QoD20.png"), Extension.Contents("QoD24.png"), Extension.Contents("QoD32.png") },
    Icon32 = { Extension.Contents("QoD32.png"), Extension.Contents("QoD40.png"), Extension.Contents("QoD48.png"), Extension.Contents("QoD64.png") }
];
