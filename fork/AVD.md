# Azure Virtual Desktop additions

Source: the Azure/AVD package prepared in Claude on 27 October 2026.

These files add AVD helpers, API endpoints, portal pages, tests and an optional Lighthouse template. The existing Prometheus branch model, publisher and update workflows remain in place.

The production publisher builds an upstream release and applies only the files copied by `prometheus/pipeline.py`. AVD build-overlay integration and live Azure validation are separate follow-up work; publishing this source branch does not deploy it or grant Azure permissions.

## AVD module

Pages: **Azure > Azure Virtual Desktop** (Host Pools, Session Hosts, User Sessions).

| Endpoint | Role | Does |
| --- | --- | --- |
| `ListPiAvdHostPools` | `Endpoint.AVD.Read` | Host pools via Resource Graph |
| `ListPiAvdSessionHosts` | `Endpoint.AVD.Read` | Session hosts, drain state, sessions, VM power state |
| `ListPiAvdUserSessions` | `Endpoint.AVD.Read` | User sessions per host pool |
| `ExecPiAvdUserSession` | `Endpoint.AVD.ReadWrite` | `logoff`, `disconnect`, `sendMessage` |
| `ExecPiAvdSessionHost` | `Endpoint.AVD.ReadWrite` | `drainOn`, `drainOff`, `start`, `restart` (refuses while sessions exist unless `Force`) |

### Azure access

GDAP grants no Azure RBAC, so the SAM app needs ARM access by one of two routes, set with the
`PiAvdArmAuthMode` app setting:

* **`Lighthouse`** (default, recommended). Create a security group in the partner tenant, add
  the CIPP SAM app's service principal to it, and deploy `fork/lighthouse/cipp-avd-lighthouse.bicep`
  to each customer subscription with AVD resources. The roles granted are Reader, Desktop
  Virtualization Session Host Operator and Desktop Virtualization Power On Off Contributor. A
  single partner-tenant token then covers every customer, and AllTenants views need one
  Resource Graph query.
* **`Tenant`**. Assign the same three roles to the SAM app's service principal *inside* each
  customer tenant. CIPP requests a token per customer. Use this where a customer refuses
  Lighthouse.

Tenant isolation: list results are filtered to tenants that are in CIPP **and** that the
signed-in CIPP user is scoped to. Every action checks, through Resource Graph, that the target
resource's subscription belongs to the tenant in the request before calling ARM.

ARM api-versions live in one place: `Get-PiAvdApiVersion.ps1`.
