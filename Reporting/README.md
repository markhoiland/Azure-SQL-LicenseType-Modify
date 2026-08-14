# SQL PAYG and AHUB Reporting

This folder documents how to obtain quick, repeatable visibility into Azure SQL licensing, Arc-enabled SQL Server inventory, vCPU capacity, usage quantities, and monthly billing after an AHUB-to-PAYG conversion.

The reporting design deliberately separates inventory from billing:

| Need | Best source | Why |
|---|---|---|
| Current resource and license inventory | Azure Resource Graph (ARG) | Fast, cross-subscription metadata query |
| Quick operational view | Azure Monitor Workbook | Interactive Azure portal view with ARG, Log Analytics, and parameters |
| Invoice-aligned cost and quantity | Cost Management exports | Authoritative detailed usage and charge records |
| Long-term monthly dashboard | Fabric Lakehouse/Warehouse or ADX plus Power BI | Durable model, history, joins, refresh, and sharing |
| Observed online/heartbeat time | Log Analytics Heartbeat | Useful operational signal, not billable usage |

## Start here

1. Run the relevant query block(s) from [`KQL/arc-sql-inventory.kql`](./KQL/arc-sql-inventory.kql) in Resource Graph Explorer, one block at a time (Azure SQL Database, Managed Instance, SQL VM, and Arc SQL Server are covered separately).
2. Review current license states and identify resources affected by the license-change scripts.
3. Use the script `-ReportOnly`/`--report-only` CSV as an execution-specific change list.
4. For quick recurring portal access, follow [`AzureMonitor-Workbook.md`](./AzureMonitor-Workbook.md).
5. For monthly billing, history, and reconciliation, follow [`PowerBI-Fabric.md`](./PowerBI-Fabric.md).

## Resource Graph quick access

1. Open Resource Graph Explorer in the Azure portal.
2. Select the subscriptions or management group containing the SQL resources.
3. Paste the query block for the resource type in scope from `KQL/arc-sql-inventory.kql`.
4. Select Run query.
5. Confirm subscription, resource group, server name, edition, version, license type, vCPUs, and provisioning state.
6. Select Download as CSV for a point-in-time inventory.
7. Save the export with a date-based name such as `arc-sql-inventory-2026-08-14.csv`.

ARG answers “what exists now?” It is not a billing system and does not expose authoritative billable hours, invoice cost, late adjustments, reservations, savings-plan allocation, or every meter-level quantity.

Run the query before and after a license conversion. Compare `ResourceId`, `LicenseType`, `vCPUs`, and provisioning state, and retain both snapshots. A current query cannot explain a historical charge for a resource that was later deleted or moved.

## Cost Management quick access

Use Cost Analysis for interactive investigation and saved views:

1. Open Cost Management + Billing.
2. Select the subscription, management group, billing profile, or invoice section.
3. Open Cost analysis.
4. Set the period to Last billing month or a custom month.
5. Choose Cost by resource when resource attribution is available.
6. Filter by service, product, resource type, meter category, meter subcategory, or charge type.
7. Group by Resource, then inspect Meter and Product.
8. Add usage quantity where the view exposes it.
9. Select Save and name the view, for example `SQL PAYG Monthly Billing`.
10. Pin the view to an Azure dashboard or bookmark it.

Cost Analysis is ideal for fast investigation. A charge may be posted against a licensing, extension, or parent resource rather than the SQL server name. Use the detailed export for reconciliation.

## Cost Management exports

1. Open Cost Management + Billing and select Exports.
2. Select the broadest billing scope available to the reporting owner.
3. Select Create and choose Cost and usage details (actual).
4. Schedule a daily export for month-to-date reporting.
5. Optionally create a separate amortized cost export for reservation or savings-plan allocation.
6. Select an Azure Storage account and container.
7. Prefer Parquet with compression and partitioning when available.
8. Grant the ingestion identity access to the container.
9. Test the export and confirm files arrive.
10. Preserve the completed prior-month files rather than overwriting them.
11. Refresh the dashboard after ingestion.

Common model fields include `ResourceId`, `Date`, `Quantity`, `UnitOfMeasure`, `MeterId`, `MeterName`, `MeterCategory`, `MeterSubCategory`, `ProductName`, `CostInBillingCurrency` or `PreTaxCost`, `EffectivePrice`, `ChargeType`, and `PricingModel`.

Use actual cost for invoice reconciliation. Use amortized cost only when shared reservation or savings-plan benefits need allocation. Keep the two totals separate.

## Hours and vCPU-hours

Do not assume `Quantity` means server-hours. For SQL meters it may represent vCore-hours:

```text
VCoreHours = SUM(Quantity)
EquivalentServerHours = VCoreHours / InventoryVCPUs
```

Validate the meter and unit before applying this calculation. If vCPU capacity changes during the month, use dated inventory snapshots. Heartbeat duration is an observed operational signal, not billable usage; label it `ObservedHours`.

## Monthly operating cycle

| Timing | Activity |
|---|---|
| Daily | Refresh current-month billing export and current ARG inventory |
| After licensing changes | Capture before/after ARG snapshots and retain the script CSV |
| Month end | Preserve inventory and continue collecting late billing updates |
| Around days 4–5 | Finalize the prior month after late charges and adjustments |
| Monthly review | Reconcile cost, quantity, meter, license state, and resource identity |

## Choosing a dashboard

Choose an Azure Monitor Workbook when the audience works primarily in Azure and current ARG/Log Analytics data is sufficient.

Choose Power BI/Fabric when the audience needs durable monthly history, invoice-aligned cost, cross-subscription joins, scheduled refresh, sharing, semantic measures, or finance reconciliation. This is the recommended complete dashboard path.

See [AzureMonitor-Workbook.md](./AzureMonitor-Workbook.md) and [PowerBI-Fabric.md](./PowerBI-Fabric.md).

## Data-quality rules

- Lowercase and trim `ResourceId` before joins.
- Retain subscription and resource-group columns in every dataset.
- Preserve monthly inventory snapshots.
- Separate actual and amortized cost.
- Track indirect or missing resource attribution instead of guessing.
- Record export period, source file, and refresh timestamp.
- Reconcile dashboard totals with Cost Analysis before publishing.
