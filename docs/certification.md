# Certifying the QoD Connector with Microsoft

Microsoft "certified connectors" ship inside Power BI Desktop's **Get Data** list
and are maintained through a partnership + submission process. This is the
checklist and process to get QoD there.

## Eligibility & prerequisites
- A Microsoft Partner relationship and a signed **Connector Certification
  Agreement** (NDA + partnership agreement).
- A **publicly reachable** Quack on Demand environment Microsoft can test against,
  with documented test credentials for **each** auth method.
- Committed ownership for ongoing maintenance and support SLAs.

## Technical requirements (what the code must satisfy)
- [x] Built with the **Power Query SDK** (this repo) → produces `QoD.mez`.
- [x] Single `[DataSource.Kind]` with a clear `Publish` record and **all icon
      sizes** (16/20/24/32/40/48/64/80).
- [x] **`TestConnection`** handler (required for the on-premises data gateway and
      scheduled refresh in the Service).
- [x] **DirectQuery** support via `Odbc.DataSource` capability shaping
      (`SupportsDirectQuery = true`).
- [x] All three authentication kinds declared (`UsernamePassword`, `Key`, `OAuth`).
- [ ] **Query folding validated** — filters, projections, joins, group-by fold to
      Flight SQL (use "View Native Query" + driver logs). Widen
      `SQLGetFunctions` only for functions DuckDB actually supports.
- [ ] No credentials persisted in the M document; secrets only via
      `Extension.CurrentCredential()` / `CredentialConnectionString`.
- [ ] Localized strings in `resources.resx`; no hard-coded UI text.
- [x] Final **brand icons** (downscaled from the official Quack on Demand mark).
- [ ] Connector **versioned** and changelog maintained.

## Submission artifacts
1. The compiled **`.mez`**.
2. **Test/demo environment** + credentials for each auth path.
3. **Documentation** page draft (becomes the Microsoft Learn connector article):
   prerequisites, supported capabilities, connection parameters, known limits.
4. A short **demo** (PBIX + walkthrough) showing Import and DirectQuery.
5. Signed legal agreements.

## Process (high level)
1. **Develop & self-test** (Desktop with the extension, gateway with TestConnection).
2. **Engage Microsoft** via the Connector Certification program; request, in the
   same conversation, **FlightSQL ADBC enablement** citing the Dremio precedent
   (same Arrow Flight SQL protocol). See `architecture.md`.
3. **Submit** the `.mez` + artifacts to Microsoft's private connector repo
   (Microsoft validates, security-reviews, and folds it into the product).
4. **Iterate** on Microsoft's review feedback.
5. **Release** — ships first as **Beta** (`Beta = true` in `Publish`), graduating
   to certified/GA after the bake period. Remove `Beta` when GA.

## Local validation before submitting
```text
# In VS Code with the "Power Query SDK" extension:
1. Build connector project        -> bin/Release/QoD.mez
2. Set credential (per auth kind)
3. Evaluate src/QoD.query.pq       -> smoke test, navigation, folding
4. Copy QoD.mez to:
   %USERPROFILE%\Documents\Power BI Desktop\Custom Connectors\
   enable "Allow any extension" (dev) or sign the .mez (distribution)
5. Test gateway: install on the on-prem data gateway, confirm TestConnection.
```

## Signing
For distribution outside certification, sign the `.mez` with a code-signing cert
(`MakePQX pack` + `sign`) so users don't need the "allow any extension" setting.
Certified connectors are signed by Microsoft as part of folding them into the
product.

## References
- Transition from ODBC to ADBC: https://learn.microsoft.com/en-us/power-query/transition-to-adbc
- Power Query SDK: https://learn.microsoft.com/en-us/power-query/install-sdk
- ODBC-based connectors: https://learn.microsoft.com/en-us/power-query/odbc
- Connector certification: https://learn.microsoft.com/en-us/power-query/connector-certification
- Dremio FlightSQL ADBC: https://www.dremio.com/blog/announcing-arrow-database-connectivity-adbc-in-microsoft-power-bis-connector-for-dremio/
