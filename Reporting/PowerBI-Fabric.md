# Power BI and Fabric Dashboard Build Guide

Power BI/Fabric is the recommended option for a durable monthly dashboard combining Azure Resource Graph inventory snapshots with Cost Management billing exports.

## Target architecture

```text
Azure Resource Graph snapshots ─┐
                                ├─> Fabric Lakehouse/Warehouse ─> Power BI semantic model ─> Dashboard
Cost Management exports ────────┘
```

Use a Fabric Lakehouse or Warehouse for centralized history. ADX is also suitable when an Azure Data Explorer platform already exists.

## Prerequisites

- Permission to create Cost Management exports at the selected billing scope.
- An Azure Storage account and container.
- Fabric capacity or a Power BI workspace with appropriate licensing.
- A pipeline, notebook, Data Factory, or Fabric Dataflow Gen2.
- ARG access for inventory snapshots.
- A managed identity or service principal with least-privilege storage access.

## Step 1: Create Cost Management exports

1. Open Cost Management + Billing.
2. Select the billing profile, enrollment, management group, or subscription scope.
3. Open Exports and select Create.
4. Choose Cost and usage details (actual).
5. Select daily recurrence for month-to-date reporting.
6. Choose Parquet when available and enable partitioning.
7. Select the reporting storage account and container.
8. Create a second amortized export only when reservation or savings-plan allocation is required.
9. Test both exports.
10. Record scope, format, schedule, and path in the dashboard documentation.

Actual and amortized costs answer different questions. Do not combine them into one total.

## Step 2: Capture inventory snapshots

Run [`KQL/arc-sql-inventory.kql`](./KQL/arc-sql-inventory.kql) daily or monthly through Resource Graph Explorer, an Automation/Function job, or a Fabric notebook/Data Factory pipeline.

Store at least:

`SnapshotDate`, `ResourceId`, `SubscriptionId`, `ResourceGroup`, `Location`, `ServerName`, `SqlEdition`, `SqlVersion`, `LicenseType`, `vCPUs`, `ProvisioningState`, and `Tags`.

Retain snapshots so historical charges remain attributable after resources are deleted, renamed, or moved.

## Step 3: Ingest and normalize

1. Land Cost Management files in a raw container.
2. Preserve the original file and export period.
3. Load files into a bronze/raw table.
4. Normalize names and types into a silver billing table.
5. Lowercase and trim `ResourceId` in billing and inventory.
6. Parse `Date` into a billing date and month key.
7. Preserve `Quantity`, `UnitOfMeasure`, `MeterId`, `MeterName`, `MeterCategory`, `MeterSubCategory`, `ProductName`, `ChargeType`, `PricingModel`, `CostInBillingCurrency`, `PreTaxCost`, and `EffectivePrice`.
8. Create a mapping table for charges posted to licensing or extension resources.
9. Create a monthly inventory snapshot table.
10. Record ingestion time, source file, export scope, and refresh status.

## Recommended model

Fact tables:

- `FactCostActual`
- `FactCostAmortized`
- `FactInventorySnapshot`

Dimensions:

- `DimDate`
- `DimResource`
- `DimSubscription`
- `DimMeter`
- `DimLicenseState`

Join cost to inventory by normalized `ResourceId` and billing month. Use an explicit mapping table for indirect attribution and expose `AttributionStatus` instead of guessing.

## Measures

Use quantity only after validating the meter unit:

```text
BillableQuantity = SUM(FactCostActual[Quantity])
ActualCost = SUM(FactCostActual[CostInBillingCurrency])
AmortizedCost = SUM(FactCostAmortized[CostInBillingCurrency])
```

For SQL meters explicitly measured in vCore-hours:

```text
VCoreHours = SUM(FactCostActual[Quantity])
EquivalentServerHours = DIVIDE([VCoreHours], MAX(FactInventorySnapshot[vCPUs]))
```

Do not use one month-end vCPU value when capacity changed during the month. Do not label heartbeat spans as billable hours.

## Step 4: Build report pages

1. Executive summary: actual cost, vCore-hours, resource count, PAYG/AHUB counts, and month-over-month change.
2. SQL inventory: server, subscription, resource group, edition, version, license state, vCPUs, location, and status.
3. Monthly billing: cost and quantity by month, product, meter, and resource.
4. PAYG conversion impact: before/after license state and post-change trend.
5. Unattributed charges: rows without a direct inventory join or resolved mapping.
6. Data quality: missing vCPUs, unknown meters, stale snapshots, failed ingestion, and refresh dates.

Add slicers for month, subscription, resource group, location, edition, license type, meter, and attribution status.

## Step 5: Refresh and month end

1. Refresh current-month billing daily.
2. Refresh inventory daily or after license changes.
3. Keep the prior month open for late charges.
4. Around days 4–5, finalize the prior month after reconciliation.
5. Compare dashboard totals with Cost Analysis at the same scope and date range.
6. Preserve the source export and inventory snapshot used for the published result.
7. Publish through a controlled Power BI workspace or Fabric app.

## Security and governance

- Use least-privilege access to export storage.
- Separate raw billing data from curated reporting tables.
- Apply row-level security when consumers should see only selected subscriptions.
- Document whether each page uses actual or amortized cost.
- Display source scope and last successful refresh on every report.
