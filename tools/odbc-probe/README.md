# QoD ODBC probe

A tiny x64 .NET console app that connects to a Quack on Demand server through the
**Arrow Flight SQL ODBC driver** the same way the QoD connector does — but outside
Power BI. Use it to reproduce/diagnose driver-level behavior with clear SQLSTATE
output, without the Power BI round-trip.

It mirrors `QoD.pq`'s connection string: TLS on, skip cert verification (dev
self-signed), Basic auth via `UID`/`PWD`, and `tenant`/`pool` as plain connection
properties (the Dremio build auto-forwards unknown keys as gRPC call headers).

## Why x64 (and why error 193 otherwise)

The driver (`arrow-flight-sql-odbc.dll`) is an **x64** DLL. A process must be x64
to load it. On **Windows ARM64**, a native ARM64 process — including the built-in
"ODBC Data Sources (64-bit)" admin — fails with **system error 193** ("not a valid
Win32 application"). This project targets `win-x64` (+ self-contained) so it builds
an x64 exe that runs under emulation and *can* load the driver.

## Build & run

```sh
# from the repo root (needs the .NET SDK)
dotnet publish tools/odbc-probe -c Release

# run the produced x64 exe (defaults: 192.0.0.2:31338 acme/bi alice/demo-alice)
tools/odbc-probe/bin/Release/net8.0/win-x64/publish/OdbcProbe.exe

# or override target:
tools/odbc-probe/bin/Release/net8.0/win-x64/publish/OdbcProbe.exe <host> <port> <tenant> <pool>
```

Credentials come from env vars so they stay out of shell history:

```sh
QOD_USER=alice QOD_PASS=demo-alice \
  tools/odbc-probe/bin/Release/net8.0/win-x64/publish/OdbcProbe.exe
```

Other env overrides: `QOD_HOST`, `QOD_PORT`, `QOD_TENANT`, `QOD_POOL`, `QOD_DRIVER`.

## What it checks

1. **Connect + auth** — TLS handshake, Basic auth, tenant/pool routing.
2. **Literal SELECT** — basic execute path.
3. **Table query** — `SELECT COUNT(*) FROM tpch1.lineitem`, which goes through the
   driver's `CreatePreparedStatement` path. If the server omits `parameter_schema`
   you'll see `Tried reading schema message, was null or length 0` here.

Exit code `0` = pass, `1` = ODBC error (SQLSTATE dumped), `2` = other error.
