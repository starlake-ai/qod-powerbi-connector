// QoD - Quack on Demand Power BI Custom Connector
// Connects Power BI / Fabric to a Quack on Demand gateway over Apache Arrow
// Flight SQL via Adbc.Connection and the FlightSQL ADBC driver that ships
// in-box with Power BI Desktop and the Power Query SDK (no driver install).
//
// The ADBC core is adapted from Microsoft's MIT-licensed DuckDbFlightSQL
// sample (see NOTICE); QoD serves DuckDB over Flight SQL, so the sample's
// SQL generator and type map carry over unchanged. The previous
// Odbc.DataSource transport (blocked on Flight SQL ODBC driver maturity)
// lives in this repo's history on main; see docs/architecture.md.
//
// Credentials (Username/Password, JWT bearer, OAuth) are handled via
// Extension.CurrentCredential() only - never as function parameters, because
// dialog parameter values are persisted into the user's query.
[Version = "2.0.0"]
section QoD;

DefaultPort = 31338;

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

QoDSqlGenerator = Extension.LoadExpression("SqlGenerator.pqm");
QoDAdbcConfig = Extension.LoadExpression("QoDAdbcConfig.pqm");

Adbc.Connection = try #shared[Adbc.Connection] otherwise (driver, databaseProperties, connectionProperties, options) =>
    error Error.Record("Expression.Error", "The Adbc.Connection function is not available in this environment");
Tables.NavigationPropertyGenerator = try #shared[Tables.NavigationPropertyGenerator] otherwise null;

ModuleIdentifier = () => ...;
MakeUniqueIdentifier = (connectionString as record) as record => [Module = ModuleIdentifier, Signature = connectionString];

QoDImpl = (server as text, tenant as text, pool as text, trustServerCertificate as logical, superuser as logical, optional options as record) as table =>
    let
        Address = ParseServerAddress(server),
        opts = options ?? [],
        UseEncryption = opts[UseEncryption]? ?? true,
        UriSchema = if UseEncryption then "grpc+tls" else "grpc",
        Uri = UriSchema & "://" & Address[Host] & ":" & Text.From(Address[Port]),

        // Build the connection string from user-friendly parameters. All
        // ADBC-level properties are mapped here; the user never sees them.
        // The QoD edge authenticates every RPC from the `tenant` and `pool`
        // gRPC call headers plus the credential, so both ride on every
        // request. The system-user request rides as the `superuser` header,
        // sent only when true; the server is the sole authority.
        SessionHeaders = RecordToHeaders(
            [tenant = tenant, pool = pool]
            & (if superuser then [superuser = "true"] else [])
        ),
        TlsProperties = if UseEncryption and trustServerCertificate then
            [#"adbc.flight.sql.client_option.tls_skip_verify" = "true"]
        else [],
        CredentialProperties = GetCredentialConnectionProperties(),

        ConnectionString = [uri = Uri] & SessionHeaders & TlsProperties & CredentialProperties,

        Connection = Adbc.Connection(QoDAdbcConfig, ConnectionString, [], [ConnectionPoolType = 2]),
        ExecuteQueryCtor = (cxn as record) => (sql as text, optional queryOpts as record) =>
            let execOptions = [IsMetadata = queryOpts[IsMetadata]?]
            in cxn[ExecuteQuery](sql, null, execOptions),
        GetData = (query as text, resultType as type, ctx as record) =>
            CreateDataTable(query, resultType, ctx, context[ExecuteQuery]),
        UniqueIdentifier = MakeUniqueIdentifier(ConnectionString),
        SqlGen = SqlView.Generator(UniqueIdentifier, QoDSqlGenerator[SqlGenerator], GetData),
        NavPropGenerator = if Tables.NavigationPropertyGenerator = null then null else
            Tables.NavigationPropertyGenerator(null, (path) =>
                AdbcDatabases{[Name = path{0}]}[Data]{[Name = path{1}]}[Data]{[Name = path{2}]}[Data]),
        context = [
            Connection = Connection, ExecuteQuery = ExecuteQueryCtor(Connection),
            ExecuteQueryCtor = ExecuteQueryCtor, SqlGenerator = SqlGen, NavPropGenerator = NavPropGenerator
        ],
        AdbcDatabases = GetDatabases(context, null)
    in AdbcDatabases;

// ============================================================================
// CREDENTIAL HANDLING
// Maps the selected Power BI credential to ADBC connection properties:
//   UsernamePassword -> driver username/password (Flight Basic handshake)
//   Key (JWT bearer) -> Authorization: Bearer <key>
//   OAuth            -> Authorization: Bearer <access_token>
// ============================================================================
GetCredentialConnectionProperties = () =>
    let
        Credential = Extension.CurrentCredential(),
        kind = Credential[AuthenticationKind]?
    in
        if kind = "UsernamePassword" then
            [username = Credential[Username], password = Credential[Password]]
        else if kind = "Key" then
            [#"adbc.flight.sql.authorization_header" = "Bearer " & Credential[Key]]
        else if kind = "OAuth" then
            [#"adbc.flight.sql.authorization_header" = "Bearer " & Credential[access_token]]
        else
            error Error.Record("QoD.UnsupportedAuth", "Unsupported authentication kind: " & (kind ?? "null"));

// ============================================================================
// HEADER HELPERS
// Converts a record of user-friendly key/value pairs into ADBC Flight RPC
// call headers. [tenant = "acme", pool = "bi"] maps to
// "adbc.flight.sql.rpc.call_header.tenant" = "acme" etc., which the driver
// sends as the gRPC headers `tenant` / `pool` that the QoD edge authenticates
// (the same routing contract as JDBC and ODBC).
// ============================================================================
RecordToHeaders = (input as record) as record =>
    let
        NonNullFields = List.Select(Record.FieldNames(input), each Record.Field(input, _) <> null)
    in
        Record.FromList(
            List.Transform(NonNullFields, each Record.Field(input, _)),
            List.Transform(NonNullFields, each "adbc.flight.sql.rpc.call_header." & _)
        );

// ============================================================================
// SERVER ADDRESS PARSING
// Accepts a plain hostname or hostname:port. The user does NOT specify the
// gRPC scheme (grpc:// or grpc+tls://); that is determined by UseEncryption.
// Default port is 31338, QoD's Flight SQL edge default.
// ============================================================================
ParseServerAddress = (server as text) as record =>
    let
        trimmed = Text.Trim(server),
        // Strip any scheme prefix if the user accidentally included one
        withoutScheme =
            if Text.StartsWith(trimmed, "grpc+tls://") then Text.AfterDelimiter(trimmed, "grpc+tls://")
            else if Text.StartsWith(trimmed, "grpc+tcp://") then Text.AfterDelimiter(trimmed, "grpc+tcp://")
            else if Text.StartsWith(trimmed, "grpc://") then Text.AfterDelimiter(trimmed, "grpc://")
            else trimmed,
        hostParts = Text.Split(withoutScheme, ":"),
        host = hostParts{0},
        port = if List.Count(hostParts) = 2 then Number.FromText(hostParts{1}) else DefaultPort
    in
        [Host = host, Port = port];

// ============================================================================
// DATA TABLE CREATION (with Table.View for query folding)
// ============================================================================
CreateDataTable = (query as text, resultType as type, context as record, executeQuery as function) =>
    Table.View(null, [
        GetType = () => resultType,
        GetRows = () =>
            let
                data = executeQuery(query, context),
                oldNames = Table.ColumnNames(data),
                newNames = Table.ColumnNames(#table(resultType, {})),
                pairs = List.Zip({oldNames, newNames}),
                renamed = try Table.RenameColumns(data, pairs, MissingField.Ignore) otherwise data,
                projected = Table.SelectColumns(renamed, newNames, MissingField.Ignore)
            in projected,
        ThrowFoldingFailures = false
    ]);

// ============================================================================
// NAVIGATION: Database > Schemas > Tables
// ============================================================================
MakeNavTableType = (isLeaf as logical) as type =>
    let
        dataType = type table meta [
            NavigationTable.ItemKind = "Table", Preview.Delay = "Table",
            NavigationTable.RowConfigurationColumn = "Kind"
        ],
        tableType = type table [Name = text, Description = nullable text, Data = dataType, Kind = text],
        withKeys = Type.ReplaceTableKeys(tableType, {[Columns = {"Name", "Kind"}, Primary = true]}) meta [
            NavigationTable.NameColumn = "Name", NavigationTable.DataColumn = "Data", NavigationTable.KindColumn = "Kind"
        ]
    in withKeys;

GetDatabases = (context as record, optional filterDatabase as text) =>
    let
        isLeaf = false, kind = "Database",
        // Not SHOW DATABASES: the QoD edge admits it unfiltered (catalog-name leak)
        // and its Prepare-time LIMIT 0 probe cannot wrap it, so it errors anyway.
        // The session's tenant and pool already determine the catalog, so the top
        // level collapses to the single session catalog.
        command = "SELECT current_database() AS Name",
        tables = context[ExecuteQuery](command, [IsMetadata = true]),
        filtered = if filterDatabase <> null then Table.SelectRows(tables, each [Name] = filterDatabase) else tables,
        getSchemas = (name) => GetSchemas(context, name),
        withDescription = Table.AddColumn(filtered, "Description", each null, type nullable text),
        withData = Table.AddColumn(withDescription, "Data", each getSchemas([Name]), type table),
        withKind = Table.AddColumn(withData, "Kind", each kind meta [NavigationTable.IsLeaf = isLeaf], type text),
        withFolding = Table.View(null, [
            GetType = () => MakeNavTableType(isLeaf), GetRows = () => withKind,
            OnSelectRows = (selector) => FoldNavigationStep(withKind, selector, getSchemas, kind),
            ThrowFoldingFailures = false
        ])
    in withFolding;

GetSchemas = (context as record, catalog as text) =>
    let
        isLeaf = false, kind = "Schema",
        command = "SELECT schema_name AS Name FROM information_schema.schemata WHERE catalog_name = "
            & EscapeString(catalog) & " AND schema_name <> 'information_schema'",
        schemas = context[ExecuteQuery](command, [IsMetadata = true]),
        getTables = (name) => GetTables(context, catalog, name),
        withDescription = Table.AddColumn(schemas, "Description", each null, type nullable text),
        withData = Table.AddColumn(withDescription, "Data", each getTables([Name]), type table),
        withKind = Table.AddColumn(withData, "Kind", each kind meta [NavigationTable.IsLeaf = isLeaf], type text),
        withFolding = Table.View(null, [
            GetType = () => MakeNavTableType(isLeaf), GetRows = () => withKind,
            OnSelectRows = (selector) => FoldNavigationStep(withKind, selector, getTables, kind),
            OnNativeQuery = (cmd, params, nqOpts) => try NativeQuery(context, catalog, cmd) catch (e) => error Table.ViewError(e),
            ThrowFoldingFailures = false
        ])
    in withFolding;

GetTables = (context as record, catalog as text, schema as text) =>
    let
        isLeaf = true, kind = {"Table", "View"},
        command = Text.Combine({
            "SELECT table_name AS Name, table_type FROM information_schema.tables WHERE table_catalog = ",
            EscapeString(catalog), " AND table_schema = ", EscapeString(schema)
        }),
        tables = context[ExecuteQuery](command, [IsMetadata = true]),
        getTable = (name) => GetTable(context, catalog, schema, name),
        withDescription = Table.AddColumn(tables, "Description", each null, type nullable text),
        withData = Table.AddColumn(withDescription, "Data", each getTable([Name]), type table),
        withKind = Table.AddColumn(withData, "Kind",
            each (if [table_type] = "VIEW" then "View" else "Table") meta [NavigationTable.IsLeaf = isLeaf], type text),
        removeType = Table.RemoveColumns(withKind, {"table_type"}),
        withFolding = Table.View(null, [
            GetType = () => MakeNavTableType(isLeaf), GetRows = () => removeType,
            OnSelectRows = (selector) => FoldNavigationStep(removeType, selector, getTable, "Table"),
            ThrowFoldingFailures = false
        ])
    in withFolding;

GetTable = (context as record, catalog as text, schema as text, table as text) =>
    let
        tableType = GetTableType(context, catalog, schema, table),
        tableReference = [Kind = "FromTable", Table = [Schema = schema, Name = table]],
        withSqlView = context[SqlGenerator](tableReference, tableType, []),
        // Transform nested columns (STRUCT, ARRAY) from text to native M types.
        // DuckDB's ADBC driver delivers these as native Arrow list/struct, so values
        // are already M list/record; we just re-type the columns to `type any`.
        rowFields = Type.RecordFields(Type.TableRow(tableType)),
        columnNames = Record.FieldNames(rowFields),
        nestedColumns = List.Select(columnNames, (col) =>
            let
                colType = Record.Field(rowFields, col)[Type],
                nativeName = Record.FieldOrDefault(Type.Facets(colType), "NativeTypeName", null)
            in
                nativeName = "STRUCT" or nativeName = "ARRAY"
        ),
        withNestedTypes = if List.Count(nestedColumns) > 0
            then Table.TransformColumnTypes(withSqlView, List.Transform(nestedColumns, each {_, type any}))
            else withSqlView
    in withNestedTypes;

GetTableType = (context as record, catalog as text, schema as text, table as text) =>
    let
        command = Text.Combine({
            "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_catalog = ",
            EscapeString(catalog), " AND table_schema = ", EscapeString(schema),
            " AND table_name = ", EscapeString(table), " ORDER BY ordinal_position"
        }),
        columns = Table.Buffer(context[ExecuteQuery](command, [IsMetadata = true])),
        withType = Table.AddColumn(columns, "Type",
            each [Type = GetColumnType([data_type], [is_nullable]), Optional = false]),
        rowType = Type.ForRecord(Record.FromList(withType[Type], withType[column_name]), false),
        tableType = type table rowType,
        withPrimaryKeys = ApplyPrimaryKeys(context, catalog, schema, table, tableType)
    in withPrimaryKeys;

GetColumnType = (typeName as text, isNullable as text) =>
    let
        baseType = if Text.EndsWith(typeName, "[]") then "ARRAY"
            else if Text.Contains(typeName, "(") then Text.BeforeDelimiter(typeName, "(")
            else typeName,
        normalized = Text.Upper(Text.Trim(baseType)),
        matchedType = Record.FieldOrDefault(QoDSqlGenerator[TypeFacets], normalized, null),
        mtype = if matchedType <> null then matchedType else type any
    in if isNullable = "YES" then type nullable mtype else mtype;

// ============================================================================
// PRIMARY & FOREIGN KEY RELATIONSHIPS
// A no-op against QoD DuckLake tenant-dbs, for two independent reasons: the
// constraint relations are RBAC-denied without a covering grant, and DuckLake
// records no PK/FK constraints anyway. The `try` degrades to "no keys".
// See docs/limitations.md.
// ============================================================================
ApplyPrimaryKeys = (context as record, catalog as text, schema as text, table as text, tableType as type) as type =>
    let
        pkCommand = Text.Combine({
            "SELECT kcu.column_name ",
            "FROM information_schema.table_constraints tc ",
            "JOIN information_schema.key_column_usage kcu ",
            "  ON tc.constraint_name = kcu.constraint_name ",
            "  AND tc.table_catalog = kcu.table_catalog ",
            "  AND tc.table_schema = kcu.table_schema ",
            "  AND tc.table_name = kcu.table_name ",
            "WHERE tc.constraint_type = 'PRIMARY KEY' ",
            "  AND tc.table_catalog = ", EscapeString(catalog),
            "  AND tc.table_schema = ", EscapeString(schema),
            "  AND tc.table_name = ", EscapeString(table),
            " ORDER BY kcu.ordinal_position"
        }),
        pkResult = try context[ExecuteQuery](pkCommand, [IsMetadata = true]) otherwise #table({"column_name"}, {}),
        pkColumns = pkResult[column_name],
        hasPK = List.Count(pkColumns) > 0,
        withPK = if hasPK then Type.ReplaceTableKeys(tableType, {[Columns = pkColumns, Primary = true]}) else tableType
    in withPK;

GetForeignKeys = (context as record, catalog as text, schema as text, table as text) as table =>
    let
        fkCommand = Text.Combine({
            "SELECT kcu.column_name AS from_column, ccu.table_schema AS to_schema, ",
            "  ccu.table_name AS to_table, ccu.column_name AS to_column ",
            "FROM information_schema.table_constraints tc ",
            "JOIN information_schema.key_column_usage kcu ",
            "  ON tc.constraint_name = kcu.constraint_name AND tc.table_catalog = kcu.table_catalog ",
            "  AND tc.table_schema = kcu.table_schema AND tc.table_name = kcu.table_name ",
            "JOIN information_schema.constraint_column_usage ccu ",
            "  ON tc.constraint_name = ccu.constraint_name AND tc.table_catalog = ccu.table_catalog ",
            "WHERE tc.constraint_type = 'FOREIGN KEY' ",
            "  AND tc.table_catalog = ", EscapeString(catalog),
            "  AND tc.table_schema = ", EscapeString(schema),
            "  AND tc.table_name = ", EscapeString(table)
        }),
        fkResult = try context[ExecuteQuery](fkCommand, [IsMetadata = true])
            otherwise #table({"from_column", "to_schema", "to_table", "to_column"}, {})
    in fkResult;

// ============================================================================
// NATIVE QUERY SUPPORT
// ============================================================================
NativeQuery = (context as record, catalog as text, cmd as text) =>
    let
        typeQuery = "SELECT * FROM (" & cmd & ") AS ""_"" WHERE 0 = 1",
        typeResult = context[ExecuteQuery](typeQuery, []),
        tableType = Value.Type(Table.Buffer(typeResult)),
        reference = [Kind = "FromQuery", Query = [Kind = "Verbatim", Query = cmd], Alias = "_"],
        result = context[SqlGenerator](reference, tableType, [])
    in result;

// ============================================================================
// HELPERS
// ============================================================================
EscapeIdentifier = (identifier as text) as text => """" & Text.Replace(identifier, """", """""") & """";
EscapeString = (string as text) as text => "'" & Text.Replace(string, "'", "''") & "'";

FoldNavigationStep = (base as table, selector as function, loader as function, kind as any) =>
    let
        reduceAnd = (ast) => if ast[Kind] = "Binary" and ast[Operator] = "And" then List.Combine({@reduceAnd(ast[Left]), @reduceAnd(ast[Right])}) else {ast},
        matchFieldAccess = (ast) => if ast[Kind] = "FieldAccess" and ast[Expression] = RowExpression.Row then ast[MemberName] else ...,
        matchConstant = (ast) => if ast[Kind] = "Constant" then ast[Value] else ...,
        matchIndex = (ast) => if ast[Kind] = "Binary" and ast[Operator] = "Equals" then
            if ast[Left][Kind] = "FieldAccess" then Record.AddField([], matchFieldAccess(ast[Left]), matchConstant(ast[Right]))
            else Record.AddField([], matchFieldAccess(ast[Right]), matchConstant(ast[Left]))
        else ...,
        predicate1 = Record.Combine(List.Transform(reduceAnd(RowExpression.From(selector)), matchIndex)),
        isKindList = kind is list,
        kindMatch = if isKindList then List.Contains(kind, predicate1[Kind]?) else predicate1[Kind]? = kind,
        predicate2 = if kindMatch then Record.RemoveFields(predicate1, {"Kind"}) else predicate1,
        name = if Record.FieldCount(predicate2) = 1 and predicate2[Name]? <> null then predicate2[Name] else ...,
        success = not (try name)[HasError]
    in
        if success then Table.FromRecords({[Name = name, Description = "", Data = loader(name), Kind = kind]})
        else Table.SelectRows(base, selector);

// ============================================================================
// EXTENSION LOADERS
// ============================================================================
Extension.LoadExpression = (name as text) =>
    let binary = Extension.Contents(name), asText = Text.FromBinary(binary)
    in Expression.Evaluate(asText, #shared);

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
    SupportsDirectQuery = true,
    NativeQueryProperties = [navigationSteps = {[]}, nativeQueryOptions = [EnableFolding = true]]
];

QoD.Icons = [
    Icon16 = { Extension.Contents("QoD16.png"), Extension.Contents("QoD20.png"), Extension.Contents("QoD24.png"), Extension.Contents("QoD32.png") },
    Icon32 = { Extension.Contents("QoD32.png"), Extension.Contents("QoD40.png"), Extension.Contents("QoD48.png"), Extension.Contents("QoD64.png") }
];
