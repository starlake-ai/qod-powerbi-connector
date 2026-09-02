# Connecting Power BI Desktop to Quack-on-Demand

## Prerequisites

- Power BI Desktop 2.145.1105.0 (July 2025) or later. Verified against 2.152.882.0.
- No driver install: the FlightSQL ADBC driver ships in-box with Power BI Desktop at
  `C:\Program Files\Microsoft Power BI Desktop\bin\ADBC Drivers\FlightSQL\libadbc_driver_flightsql.dll`
  (the Power Query SDK's test tools bundle the same driver).
- A reachable QoD Flight SQL edge (default port 31338, TLS on by default).

## Installing the connector

See [INSTALL.md](../INSTALL.md). Short version for dev builds:

1. Copy `QoD.mez` into `Documents\Power BI Desktop\Custom Connectors` (create the
   folder if it does not exist).
2. In Power BI Desktop: File > Options and settings > Options > Security > Data
   Extensions, select "(Not Recommended) Allow any extension to load without
   validation or warning", then restart Power BI Desktop. For a warning-free
   setup, deploy the signed `.pqx` instead.

## Connecting

Get Data > search for "Quack on Demand". The dialog asks for:

| Parameter | Meaning |
|---|---|
| Server | Edge `host` or `host:port`. Port defaults to 31338. No `grpc://` scheme needed. |
| Tenant | The QoD tenant this session is scoped to. |
| Pool | The QoD pool that executes the session's statements. |
| Trust server certificate | `true` skips TLS certificate verification, for a self-signed dev cert such as the QoD demo's. `false` (production) verifies. |
| Superuser | A request for system-user mode; the server authorizes it against the authenticated principal. Normal value is `false`. |
| Advanced options | Optional record. `UseEncryption = false` switches to plain gRPC for an edge running without TLS. |

Then pick a credential kind:

- **Username & Password**: a QoD user of that tenant (Flight Basic handshake).
- **Access token**: a QoD PAT or external JWT, sent as `Authorization: Bearer <token>`.
- **OAuth 2.0**: sign in through the IdP configured in `OAuthConfig`
  (see [authentication.md](authentication.md)); the access token rides as a
  Bearer credential.

Credentials are entered in Power BI's credential dialog and stored in its
credential manager. They are never connector function parameters, because dialog
parameter values are persisted into the user's query.

## Demo walkthrough

With a local demo instance (`qod demo`): Server `localhost:31338`, Tenant `acme`,
Pool `bi`, Trust server certificate `true`, Superuser `false`, then
Username & Password `alice` / `demo-alice`. Browse to `acme_tpch` > `tpch1` and
pick a TPC-H table. Access control, column masking (alice's analyst role masks
`customer.c_phone`), and row policies (BUILDING-segment customers only) are
applied by the QoD edge, not by the connector. To see RBAC shape the navigator
itself, reconnect as `acme-admin` / `demo-acme-admin`: the navigator then lists
all 8 TPC-H tables where alice sees only her 4 granted ones.
