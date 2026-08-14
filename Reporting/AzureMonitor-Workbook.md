# Azure Monitor Workbook Build Guide

Use an Azure Monitor Workbook for a quick-access operational view in the Azure portal. This option is lighter than Power BI/Fabric and is best when the primary data is current Azure Resource Graph inventory plus optional Log Analytics telemetry.

## What it can and cannot do

It can query Azure SQL Database, Managed Instance, SQL VM, and Arc SQL inventory across selected subscriptions, filter by license and location, show current metadata, and show Log Analytics heartbeat observations.

It should not be treated as the authoritative monthly billing model. Cost Management exports are not automatically a native Workbook billing table. To show billing in a Workbook, first ingest exports into Log Analytics, ADX, or another queryable store, or link users to a saved Cost Analysis view.

## Prerequisites

- Reader access to the target subscriptions or management group.
- Permission to create or edit an Azure Monitor Workbook.
- Resource Graph access for inventory.
- Optional Log Analytics Reader access for heartbeat data.
- Optional access to an ingested billing dataset.

## Create the workbook

1. Open Monitor in the Azure portal.
2. Select Workbooks, then New.
3. Select Edit and add a text item titled `SQL PAYG and AHUB Inventory`.
4. Add a Parameters item.
5. Create a subscription parameter using the Azure resource picker.
6. Add optional text parameters for resource group and license type.
7. Add a Query item.
8. Select Azure Resource Graph as the data source.
9. Set the scope to the selected subscriptions or management group.
10. Paste the query block for the resource type in scope from `KQL/arc-sql-inventory.kql`.
11. Bind the subscription parameter to the query scope or filter.
12. Set visualization to Grid.
13. Add a second query using the license-summary query and visualize it as a chart.
14. Add a third query for counts by subscription or location.
15. Optionally add the heartbeat query below using Log Analytics.
16. Add text explaining that heartbeat hours are observed, not billable.
17. Add a link to the saved Cost Analysis view or Power BI report.
18. Select Done Editing.
19. Select Save As, choose a shared resource group, and grant readers access.

## Suggested layout

1. Header and parameters.
2. License summary.
3. Inventory grid with server, subscription, resource group, edition, version, vCPUs, and license type.
4. Capacity chart by subscription or location.
5. Observed activity section.
6. Billing link and source notes.

## Optional heartbeat query

Run this against the Log Analytics workspace receiving heartbeat data:

```kql
let monthStart = startofmonth(now());
Heartbeat
| where TimeGenerated >= monthStart
| summarize FirstSeen=min(TimeGenerated), LastSeen=max(TimeGenerated),
    ObservedHours=datetime_diff('hour', max(TimeGenerated), min(TimeGenerated))
    by Computer, ResourceId=tostring(_ResourceId)
| project Computer, ResourceId, FirstSeen, LastSeen, ObservedHours
| order by Computer asc
```

This measures the span between first and last observed heartbeat. It does not measure billable SQL usage.

## Maintenance

- Review the ARG query when the Arc resource schema changes.
- Review permissions when subscriptions are added.
- Keep a visible last-refreshed value.
- Link to Cost Analysis rather than duplicating unsupported billing logic.
- Move to the Power BI/Fabric design when monthly history or finance-grade reconciliation is required.
