using System.Data.Odbc;
using System.Runtime.InteropServices;

// QoD ODBC probe
// ==============
// Connects to a Quack on Demand server through the Arrow Flight SQL ODBC driver
// using the same connection-string shape the QoD connector builds (see
// QoD.pq -> BuildConnectionString / EncodeScope / CredentialToOdbcProperties),
// then runs a couple of queries and prints clear PASS/FAIL with full ODBC errors.
//
// Usage:
//   OdbcProbe.exe [host] [port] [tenant] [pool]
// Env overrides (handy for secrets):
//   QOD_HOST QOD_PORT QOD_TENANT QOD_POOL QOD_USER QOD_PASS QOD_DRIVER
//
// Defaults match the dev instance (192.0.0.2:31338, acme/bi, alice/demo-alice).

static string Env(string name, string dflt) =>
    Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : dflt;

string host   = args.Length > 0 ? args[0] : Env("QOD_HOST", "192.0.0.2");
string port   = args.Length > 1 ? args[1] : Env("QOD_PORT", "31338");
string tenant = args.Length > 2 ? args[2] : Env("QOD_TENANT", "acme");
string pool   = args.Length > 3 ? args[3] : Env("QOD_POOL", "bi");
string user   = Env("QOD_USER", "alice");
string pass   = Env("QOD_PASS", "demo-alice");
string driver = Env("QOD_DRIVER", "Arrow Flight SQL ODBC Driver");

// Mirrors the connector: TLS on, skip cert verify (dev self-signed), Basic auth
// via UID/PWD, and tenant/pool as plain props (the Dremio build auto-forwards
// unknown connection keys as gRPC call headers).
string cs =
    $"Driver={{{driver}}};host={host};port={port};" +
    "useEncryption=1;disableCertificateVerification=1;" +
    $"UID={user};PWD={pass};tenant={tenant};pool={pool}";

Console.WriteLine($"Process arch : {RuntimeInformation.ProcessArchitecture}  (must be X64 to load the driver)");
Console.WriteLine($"Driver       : {driver}");
Console.WriteLine($"Endpoint     : {host}:{port}  tenant={tenant} pool={pool}  user={user}");
Console.WriteLine();

try
{
    using var conn = new OdbcConnection(cs);
    conn.Open();
    Console.WriteLine("[1] Connect + auth      : OK");
    // conn.Driver = driver DLL name; ServerVersion comes from SQLGetInfo(SQL_DBMS_VER).
    Console.WriteLine($"    driver dll          : {conn.Driver}");
    TryServerVersion(conn);

    // [2] literal-only SELECT (no table) — basic execute path.
    RunQuery(conn, "SELECT 42 AS answer, 'acme' AS who", "[2] Literal SELECT      ");

    // [3] real table query — goes through CreatePreparedStatement, which needs the
    //     server to return parameter_schema (empty IPC schema). If Quack omits it
    //     you get: "Tried reading schema message, was null or length 0".
    RunQuery(conn, "SELECT COUNT(*) AS n FROM tpch1.lineitem", "[3] Table query (prep)  ");

    Console.WriteLine("\n==> PROBE PASSED");
}
catch (OdbcException ex)
{
    Console.WriteLine("\n==> PROBE FAILED (ODBC)");
    DumpOdbc(ex);
    Environment.ExitCode = 1;
}
catch (Exception ex)
{
    Console.WriteLine($"\n==> PROBE FAILED: {ex.GetType().Name}: {ex.Message}");
    Environment.ExitCode = 2;
}

static void TryServerVersion(OdbcConnection conn)
{
    try { Console.WriteLine($"    server version      : {conn.ServerVersion}"); }
    catch (Exception ex) { Console.WriteLine($"    server version      : (unavailable: {ex.Message})"); }
}

static void RunQuery(OdbcConnection conn, string sql, string label)
{
    using var cmd = new OdbcCommand(sql, conn) { CommandTimeout = 60 };
    using var rdr = cmd.ExecuteReader();
    string[] cols = Enumerable.Range(0, rdr.FieldCount).Select(rdr.GetName).ToArray();
    int rows = 0;
    string first = "";
    while (rdr.Read())
    {
        if (rows == 0)
            first = string.Join(", ",
                Enumerable.Range(0, rdr.FieldCount).Select(i => $"{cols[i]}={Val(rdr, i)}"));
        rows++;
    }
    Console.WriteLine($"{label}: OK  ({rows} row(s){(first.Length > 0 ? $"; first: {first}" : "")})");
}

static string Val(OdbcDataReader rdr, int i) => rdr.IsDBNull(i) ? "NULL" : rdr.GetValue(i)?.ToString() ?? "";

static void DumpOdbc(OdbcException ex)
{
    foreach (OdbcError e in ex.Errors)
        Console.WriteLine($"    SQLSTATE {e.SQLState}  native {e.NativeError}: {e.Message}");
}
