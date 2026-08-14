# Custom RBAC Role – Arc SQL Server License Operator (Physical Core)

This folder contains a least-privilege custom Azure RBAC role definition for
users who only need to:

1. **View** Azure Arc-enabled SQL Server objects (Arc SQL Server instances and
   the Arc data controller they're associated with), and
2. **Create and modify** Azure Arc SQL Server **physical-core** licenses
   (`Microsoft.AzureArcData/sqlServerLicenses`, `licenseCategory: Core`).

It deliberately does **not** grant delete rights on licenses, and does **not**
grant write access to any other Arc SQL resource type (instances, data
controllers, extensions, etc.). This makes it a much narrower alternative to
assigning the built-in **Azure Connected Machine Resource Administrator**
role (which grants broad control over the underlying Arc-enabled server,
extensions, and identity — far more than is needed just to manage licensing).

> Use this role for licensing/FinOps administrators, SQL PAYG conversion
> operators, or automation service principals that only need to read Arc SQL
> inventory and manage the license resource itself.

## Why a custom role is needed

As of this writing, there is no built-in Azure role scoped narrowly to
`Microsoft.AzureArcData/sqlServerLicenses`. The closest built-in role,
**Azure Connected SQL Server Onboarding**, only grants
`sqlServerInstances/read` and `sqlServerInstances/write` — it has no
knowledge of the license resource type at all. Built-in roles like
**Contributor** or **Azure Connected Machine Resource Administrator** work,
but both grant far more than license management (including the ability to
delete Arc-enabled servers, install/remove extensions, or modify the
underlying `Microsoft.HybridCompute` machine resource). This custom role
closes that gap.

## What the role grants

| Action | Purpose |
| --- | --- |
| `Microsoft.AzureArcData/sqlServerInstances/read` | View Arc SQL Server instance resources (the "Arc SQL objects" the user needs visibility into). |
| `Microsoft.AzureArcData/sqlServerInstances/*/read` | View child/sub-resources of an Arc SQL Server instance (for example, databases, availability groups) exposed under the instance. |
| `Microsoft.AzureArcData/dataControllers/read` | View the Arc data controller resource associated with the environment. |
| `Microsoft.AzureArcData/dataControllers/*/read` | View child/sub-resources of the data controller. |
| `Microsoft.AzureArcData/sqlServerLicenses/read` | View existing Arc SQL Server license resources (billing plan, physical core count, activation state, scope). |
| `Microsoft.AzureArcData/sqlServerLicenses/write` | Create new license resources and modify existing ones (change `billingPlan` between `PAYG`/`Paid`, update `physicalCores`, change `activationState`, etc.). |
| `Microsoft.AzureArcData/locations/*/read` | Read long-running operation status/results for asynchronous `Microsoft.AzureArcData` operations (needed so portal/CLI/PowerShell operations don't hang or error on status polling). |
| `Microsoft.AzureArcData/operations/read` | List the operations supported by the `Microsoft.AzureArcData` resource provider (required for the Azure portal IAM/RBAC experience and CLI/PowerShell provider discovery). |
| `Microsoft.AzureArcData/register/action` | Register the `Microsoft.AzureArcData` resource provider on a subscription if it isn't already registered (harmless no-op if already registered; needed the first time a subscription is used). |
| `Microsoft.Resources/subscriptions/resourceGroups/read` | Browse resource groups in the Azure portal so the user can navigate to Arc SQL resources. |
| `Microsoft.Resources/subscriptions/read` | List/read subscription metadata so the Azure portal subscription picker works correctly. |

`DataActions` are intentionally empty — Arc SQL license management is a
control-plane-only (ARM) operation; no data-plane access to the SQL Server
instance itself is required or granted.

## Deploying the role

### Option 1 – Azure CLI

```bash
# Edit AssignableScopes in Arc-SQL-License-Operator.json first (see below),
# then create the role definition:
az role definition create --role-definition ./RBAC/Arc-SQL-License-Operator.json

# Assign the role to a user, group, or service principal:
az role assignment create \
  --assignee "<user-or-sp-object-id>" \
  --role "Arc SQL Server License Operator (Physical Core)" \
  --scope "/subscriptions/<subscription-id>"
```

### Option 2 – Azure PowerShell

```powershell
# Edit AssignableScopes in Arc-SQL-License-Operator.json first (see below),
# then create the role definition:
New-AzRoleDefinition -InputFile ".\RBAC\Arc-SQL-License-Operator.json"

# Assign the role to a user, group, or service principal:
New-AzRoleAssignment `
    -ObjectId "<user-or-sp-object-id>" `
    -RoleDefinitionName "Arc SQL Server License Operator (Physical Core)" `
    -Scope "/subscriptions/<subscription-id>"
```

### Option 3 – Azure portal

1. Sign in to the Azure portal and browse to the subscription or resource
   group where the role should be assignable.
2. Select **Access control (IAM)** → **Add** → **Add custom role**.
3. Choose **Start from JSON**, and upload `Arc-SQL-License-Operator.json`
   (after editing `AssignableScopes` — see below).
4. Review + create the role.
5. Go back to **Access control (IAM)** → **Add** → **Add role assignment**,
   select the new custom role, and assign it to the desired user, group, or
   service principal.

## Before you deploy: update `AssignableScopes`

The shipped JSON uses a placeholder assignable scope:

```json
"AssignableScopes": [
  "/subscriptions/<subscription-id>"
]
```

Replace `<subscription-id>` with the actual subscription GUID, or use a
narrower/broader scope as appropriate for your environment:

| Scope | Example |
| --- | --- |
| Subscription | `/subscriptions/00000000-0000-0000-0000-000000000000` |
| Resource group | `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-arc-sql` |
| Management group | `/providers/Microsoft.Management/managementGroups/<mg-id>` |

You can list multiple scopes in the array if the role needs to be assignable
across several subscriptions or resource groups.

## Optional: allow delete on licenses

If the license-owning team also needs to remove Arc SQL license resources
(for example, when decommissioning a server or consolidating licenses),
add the delete action to `Actions` in the JSON file:

```json
"Microsoft.AzureArcData/sqlServerLicenses/delete"
```

This is deliberately **not** included by default, matching the scope of the
original request (create and modify only).

## Validating the role after assignment

```bash
# Confirm the custom role exists
az role definition list --custom-role-only true --query "[?roleName=='Arc SQL Server License Operator (Physical Core)']" -o table

# Confirm the assignment
az role assignment list --assignee "<user-or-sp-object-id>" --scope "/subscriptions/<subscription-id>" -o table
```

```powershell
Get-AzRoleDefinition -Name "Arc SQL Server License Operator (Physical Core)"
Get-AzRoleAssignment -ObjectId "<user-or-sp-object-id>" -Scope "/subscriptions/<subscription-id>"
```

Then, as the assigned user, run the repo's report-only mode to confirm read
access works end to end without requiring elevated permissions:

```powershell
.\PowerShell\Set-ArcSqlLicenseType.ps1 -TenantId "<tenant_id>" -ReportOnly
```

```bash
./AzureCLI/set-arc-sql-license-type.sh --tenant-id "<tenant_id>" --report-only
```

If report-only mode succeeds but a write operation (for example,
`-DisableAHUB` without `-ReportOnly`) fails with an authorization error,
double-check the assignment scope covers the resource group containing the
target Arc SQL Server license resources.

## Files in this folder

| File | Purpose |
| --- | --- |
| `Arc-SQL-License-Operator.json` | The custom role definition, ready to deploy via Azure CLI, Azure PowerShell, or the Azure portal. |
| `README.md` | This file — deployment and validation guidance. |
