// QoD — Quack on Demand Power BI Custom Connector
// ================================================
// Connects Power BI / Microsoft Fabric to a Quack on Demand gateway
// (github.com/starlake-ai/quack-on-demand) over Apache Arrow Flight SQL.
//
// Transport today:  Arrow Flight SQL ODBC driver, wrapped by Odbc.DataSource.
//                   This is the certifiable path and supports DirectQuery + Import.
// Transport later:  Microsoft's product-side FlightSQL ADBC driver (the "Dremio path").
//                   See docs/architecture.md — that switch is a certification-time
//                   enablement, not a change you make in this file.
//
[Version = "1.0.0"]
section QoD;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// Name of the ODBC driver exactly as registered on the machine / gateway.
// Target: the official Apache Arrow C++ Flight SQL ODBC driver (vendor-neutral,
// actively developed, certifiable). Confirm the exact registered driver name
// for the build Quack ships, then set it here. (The Dremio build registers as
// "Arrow Flight SQL ODBC Driver"; the upstream C++ build's name may differ.)
DriverName = "Arrow Flight SQL ODBC Driver";

// Default Flight SQL port for Quack on Demand.
DefaultPort = 31338;

// Set to true while developing to surface ODBC connection-string / fold traces.
EnableTraceOutput = false;

// ---------------------------------------------------------------------------
// Data source function (public surface)
// ---------------------------------------------------------------------------

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
    optional options as (
        type record meta [
            Documentation.FieldCaption = Extension.LoadString("AdvancedOptionsCaption")
        ]
    )
) as table meta [
    Documentation.Name = Extension.LoadString("DataSourceName")
];

QoDImpl = (server as text, tenant as text, pool as text, optional options as record) as table =>
    let
        // --- normalize host / port ---------------------------------------
        Address     = Uri.Parts("flight://" & server),
        Host        = Address[Host],
        Port        = if Address[Port] = null or Address[Port] = "" or Address[Port] = 0
                      then DefaultPort
                      else Address[Port],

        // --- advanced options (all optional) -----------------------------
        opts            = options ?? [],
        UseEncryption   = opts[UseEncryption]? ?? true,
        TrustServerCert = opts[TrustServerCertificate]? ?? false,
        ConnectTimeout  = opts[ConnectionTimeout]? ?? 30,
        QueryTimeout    = opts[CommandTimeout]? ?? 600,

        // --- build the ODBC connection string ----------------------------
        ConnectionString = BuildConnectionString(Host, Port, tenant, pool, UseEncryption, TrustServerCert),

        // --- credential-derived ODBC properties --------------------------
        // Username/Password -> UID/PWD ; Key/OAuth -> bearer token header.
        // Odbc.DataSource reads the selected credential via the engine; we
        // supply the token-bearing properties through CredentialConnectionString.
        Credential       = Extension.CurrentCredential(),
        CredProperties   = CredentialToOdbcProperties(Credential),

        OdbcOptions = [
            // Report driver capabilities so the M engine can fold filters,
            // projections, joins, aggregations into Flight SQL.
            HierarchicalNavigation = true,
            HideNativeQuery        = false,
            ConnectionTimeout      = ConnectTimeout,
            CommandTimeout         = QueryTimeout,

            // Token / password injected out-of-band from the connection string
            // so credentials never appear in a saved M query.
            CredentialConnectionString = CredProperties,

            // SQL dialect / capability shaping (see helpers below).
            SqlCapabilities = SqlCaps,
            SQLGetInfo      = SqlGetInfoOverrides,
            SQLGetFunctions = SqlGetFunctionsOverrides,
            SQLGetTypeInfo  = SqlGetTypeInfoOverrides,

            // Surface ODBC errors with the original SQLSTATE for support.
            ClientConnectionPooling = true,

            OnError = OnOdbcError,

            // Trace hook (no-op unless EnableTraceOutput).
            SoftNumbers = true,
            TolerateConcatOverflow = true
        ],

        Source = Odbc.DataSource(ConnectionString, OdbcOptions)
    in
        Source;

// ---------------------------------------------------------------------------
// Connection string builder
// ---------------------------------------------------------------------------
// Property keys below are taken from the Arrow Flight SQL ODBC driver
// documentation (Dremio build):
//   host=...;port=...;useEncryption=1;disableCertificateVerification=1;token=...
// Booleans are the literals "1"/"0" (NOT "true"/"false"). Verify against the
// exact driver build Quack ships; the rest of the connector is key-agnostic.
//   ref: https://docs.dremio.com/cloud/sonar/client-apps/drivers/arrow-flight-sql-odbc/

BuildConnectionString = (host as text, port as any, tenant as text, pool as text, useEncryption as logical, trustCert as logical) as record =>
    [
        Driver = DriverName,
        host   = host,
        port   = Text.From(port),

        // TLS — Quack is TLS-enabled by default. Driver expects 1/0.
        useEncryption                  = if useEncryption then "1" else "0",
        disableCertificateVerification = if trustCert then "1" else "0"
    ] & EncodeScope(tenant, pool);

// Quack scope (tenant / pool) is conveyed as native Flight SQL gRPC call headers
// via the Arrow Flight SQL ODBC driver's `RPCCallHeaders` passthrough. This is the
// SAME contract Quack already honors for its JDBC driver (`?tenant=…&pool=…` →
// gRPC metadata), so it needs NO server-side change — the gateway routes on the
// `tenant`/`pool` headers it already understands. (Confirmed by the Quack team:
// the Apache Arrow Flight SQL ODBC build forwards DSN props through
// `RPCCallHeaders=key=val;key=val`.)
// Centralized so an alternate encoding (e.g. fall back to `database`/`schema`
// catalog properties) is a one-line change. See docs/architecture.md
// ("tenant/pool channel"). The exact header-list delimiter/escaping is confirmed
// against the shipped driver build at certification.
EncodeScope = (tenant as text, pool as text) as record =>
    [
        RPCCallHeaders = "tenant=" & tenant & ";pool=" & pool
    ];

// Maps the Power BI credential the user selected to ODBC properties.
//   UsernamePassword -> UID / PWD
//   Key (access token / JWT) -> bearer token header
//   OAuth (OIDC) -> bearer access_token header
CredentialToOdbcProperties = (cred as record) as record =>
    let
        kind = cred[AuthenticationKind]
    in
        if kind = "UsernamePassword" then
            [ UID = cred[Username], PWD = cred[Password] ]
        else if kind = "Key" then
            // JWT / static access token supplied in the single Key field.
            [ token = cred[Key] ]
        else if kind = "OAuth" then
            // OAuth flow stored the bearer token in access_token.
            [ token = cred[access_token] ]
        else
            error Error.Record(
                "QoD.UnsupportedAuth",
                "Unsupported authentication kind: " & kind
            );

// ---------------------------------------------------------------------------
// ODBC capability shaping (DirectQuery folding)
// ---------------------------------------------------------------------------

// IMPORTANT: Quack does NOT support Flight SQL parameter binding
// (CreatePreparedStatement with bound parameters). The Supports*Literals flags
// below MUST stay true so the M engine inlines literal values directly into the
// folded SQL (`… = 'O'`) instead of emitting bound parameters (`… = ?`). Turning
// any of them off would push the engine onto a parameter-binding path Quack can't
// execute. See docs/quack-server-spec.md (R9).
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
    SQL_SQL92_PREDICATES    = 0x0000FFFF,
    SQL_AGGREGATE_FUNCTIONS = 0x0000007F,
    SQL_SQL_CONFORMANCE     = 4 /* SQL_SC_SQL92_FULL */,
    SQL_GROUP_BY            = 2 /* SQL_GB_GROUP_BY_CONTAINS_SELECT */
];

// Advertise the scalar/aggregate functions the Flight SQL backend (DuckDB)
// can fold. Conservative defaults; widen after validating against Quack.
SqlGetFunctionsOverrides = [
    SQL_CONVERT_FUNCTIONS  = 0x00000002 /* SQL_FN_CVT_CAST */,
    SQL_STRING_FUNCTIONS   = 0x0017FFFF,
    SQL_NUMERIC_FUNCTIONS  = 0x00FFFFFF,
    SQL_TIMEDATE_FUNCTIONS = 0x0003FFFF
];

SqlGetTypeInfoOverrides = (types as table) as table => types;

OnOdbcError = (errorRecord as record) =>
    error errorRecord;

// ---------------------------------------------------------------------------
// Data Source Kind — authentication & test connection
// ---------------------------------------------------------------------------

QoD = [
    // TestConnection enables the connector on the on-premises data gateway
    // and powers refresh in the Power BI service. The returned list is the
    // data-source function name followed by its required parameters.
    TestConnection = (dataSourcePath) =>
        let
            json = Json.Document(dataSourcePath)
        in
            { "QoD.Database", json[server], json[tenant], json[pool] },

    Authentication = [
        // 1. Username / password  -> Quack Postgres/BCrypt backend
        UsernamePassword = [
            Label = Extension.LoadString("AuthUsernamePasswordLabel")
        ],
        // 2. Access token / JWT   -> Quack external JWT backend
        Key = [
            Label    = Extension.LoadString("AuthKeyLabel"),
            KeyLabel = Extension.LoadString("AuthKeyKeyLabel")
        ],
        // 3. OAuth 2.0 / OIDC     -> Keycloak / Entra ID / Google / Cognito
        OAuth = [
            StartLogin  = StartLogin,
            FinishLogin = FinishLogin,
            Refresh     = Refresh,
            Logout      = Logout
        ]
    ],

    // The connector caches credentials per (server, tenant, pool) tuple.
    Label = Extension.LoadString("DataSourceLabel")
];

// ---------------------------------------------------------------------------
// OAuth 2.0 / OIDC handlers
// ---------------------------------------------------------------------------
// Defaults target a generic OIDC provider via the standard authorization-code
// + PKCE flow. Endpoints, client_id and scopes are read from a bundled config
// so the same .mez works against Keycloak, Entra ID, Google, or Cognito by
// editing OAuthConfig (or, post-certification, a provider-discovery call).

OAuthConfig = [
    AuthorizeUrl = "https://login.example-oidc.com/authorize",
    TokenUrl     = "https://login.example-oidc.com/oauth/token",
    LogoutUrl    = "https://login.example-oidc.com/logout",
    ClientId     = "quack-powerbi",
    Scope        = "openid profile email offline_access",
    RedirectUri  = "https://oauth.powerbi.com/views/oauthredirect.html"
];

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

// ---------------------------------------------------------------------------
// UI publish metadata
// ---------------------------------------------------------------------------

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
