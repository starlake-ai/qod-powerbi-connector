# Power BI Service, gateway, and DirectQuery

Status of the deployment surfaces beyond Power BI Desktop, as of 2026-09-02.
Sources: Microsoft's [custom connectors + gateway doc](https://learn.microsoft.com/en-us/power-bi/connect-data/service-gateway-custom-connectors),
[ADBC connector doc](https://learn.microsoft.com/en-us/power-query/adbc), and
[ODBC-to-ADBC transition doc](https://learn.microsoft.com/en-us/power-query/transition-to-adbc).

## Power BI Desktop: standalone, verified

Desktop 2.145.1105.0+ runs the connector with zero extra installs (driver is
in-box). Verified end to end on 2.152.882.0 including query folding and
server-side RLS/CLS.

## Power BI Service: an on-premises data gateway is REQUIRED

The Service never executes custom connectors itself. Scheduled refresh or
DirectQuery from the Service routes through an **on-premises data gateway**
that has:

1. `QoD.mez` (or the signed `QoD.pqx`) in the gateway's custom-connectors
   folder, and
2. the gateway cluster's "allow custom connectors" option enabled.

This is the standing rule for every custom connector; the in-box ADBC driver
removes the *driver* install, not the *connector* hosting requirement. The only
path to gateway-free Service refresh is Microsoft connector certification plus
Microsoft enabling the connector cloud-side, which is out of scope for v2
(tracked in docs/certification.md).

## Gateway ADBC readiness: verify against your gateway build

Whether a given gateway build can run this connector depends on its bundled
mashup engine exposing `Adbc.Connection` and carrying the FlightSQL ADBC
driver. Microsoft's transition doc states gateway-routed queries "continue to
use the driver bundled with the gateway installation, which today is ODBC" for
the transitioning first-party connectors, with ODBC planned to leave gateway
installations by Spring 2027 - i.e. gateway-side ADBC enablement is in
progress, not guaranteed on current builds.

Before relying on Service refresh, check on the gateway machine:

1. The gateway release is recent (its mashup engine tracks Power BI Desktop
   with a lag; anything older than late 2025 is unlikely to expose
   `Adbc.Connection`).
2. An `ADBC Drivers\FlightSQL\libadbc_driver_flightsql.dll` exists under the
   gateway's installation directory (mirroring Desktop's `bin` layout).
3. A test refresh of a QoD dataset through the gateway succeeds. If the engine
   lacks ADBC, the connector fails cleanly with "The Adbc.Connection function
   is not available in this environment".

## DirectQuery

`QoD.Publish` declares `SupportsDirectQuery = true`; every navigation level and
table is a `Table.View`, so DirectQuery interactions issue folded SQL per
visual. Two QoD-side properties matter:

- **No parameter binding.** QoD's Flight SQL edge does not implement bound
  parameters; the SQL generator inlines literals (the sample's
  `GetLiteral` machinery), so folded predicates arrive as literal SQL. This is
  the correct shape for QoD.
- **Residency.** DirectQuery is the mode that keeps data server-side; Import
  copies the dataset to the client by design. See docs/limitations.md.

Validated in Power BI Desktop 2.152.882.0 on 2026-09-02 against a `qod demo`
instance: DirectQuery connect (the "Data Connectivity mode" radio on the
connector's parameter dialog), per-interaction folded SQL, refresh, and
server-side policies as a restricted principal. Checklist for re-validation:

1. Get Data > Quack on Demand > select **DirectQuery** in the "Data
   Connectivity mode" radio group on the connector's parameter dialog, then
   pick `acme_tpch.tpch1.orders` in the navigator.
2. Build a visual (for example count of orders by `o_orderpriority`), add a
   slicer or filter, and interact.
3. Performance Analyzer (or Query Diagnostics) shows a folded SQL query per
   interaction on the Adbc channel; row counts match the demo's policies for
   the signed-in principal.
