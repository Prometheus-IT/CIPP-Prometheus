# Azure Virtual Desktop additions

Source: the Azure/AVD package prepared in Claude on 27 October 2026.

These files add AVD helpers, API endpoints, portal pages, tests and an optional Lighthouse template. The existing Prometheus branch model, publisher and update workflows remain in place.

The production publisher builds an exact upstream release and copies these AVD sources through `prometheus/pipeline.py`, then appends the navigation hook to that release's menu. AVD source and test changes contribute to the image version hash and trigger a build. The publisher runs the backend and frontend AVD tests and checks the compiled exports, three portal routes and action endpoints before promoting the image. Publishing the software does not deploy the optional Lighthouse template or grant Azure permissions. Live customer access still depends on existing Azure permissions.

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

## Azure Lighthouse onboarding page

Page: **Azure > Azure Lighthouse > Onboarding**. Read-only; CIPP never deploys the template or
grants access.

| Endpoint | Role | Does |
| --- | --- | --- |
| `ListPiAzureLighthouseStatus` | `Endpoint.AVD.Read` | Per tenant: visible subscriptions, delegated AVD roles, host pool count |
| `ListPiAzureLighthouseTemplate` | `Endpoint.AVD.Read` | The onboarding ARM template with this instance's partner tenant and principal filled in |

Status values: **Full** (all three roles on every visible subscription), **ReadOnly** (Reader
only), **Partial**, **OtherPrincipal** (our Lighthouse offer authorizes a different principal),
**NotOnboarded** (no visible subscription - CIPP cannot tell this apart from "no Azure") and
**Unknown** (a role lookup failed; never shown as healthy).

The delegated principal is the CIPP SAM service principal's object id, looked up by
`ApplicationID` in the partner tenant. To delegate to a group that contains it instead (the
design suggested above), set the App Service setting `PiAvdLighthousePrincipalId` to the
group's object id. The generated template is the JSON equivalent of
`fork/lighthouse/cipp-avd-lighthouse.bicep`; both use the same resource names, so either one
can update an existing offer. `Get-PiLighthouseRoles.ps1` is the PowerShell source of the
roles and the pipeline tests fail when it and the Bicep file disagree.

## Windows 365 Cloud PCs

Page: **Azure > Windows 365 > Cloud PCs**. Read-only.

| Endpoint | Role | Does |
| --- | --- | --- |
| `ListPiCloudPCs` | `Endpoint.CloudPC.Read` | Cloud PCs with status, connectivity health, plan, policy and grace period |

It reads Graph beta `deviceManagement/virtualEndpoint/cloudPCs`, which needs the delegated
`CloudPC.Read.All` permission. **The upstream SAM manifest does not request it**, and this
fork deliberately does not add it: CIPP's permission update timer would then consent it in
every customer tenant. Until it is added, the page falls back to the Cloud PC devices Intune
knows about (existing `DeviceManagementManagedDevices` permission) and labels those rows
`Intune (limited)`. A tenant that neither source can read is an error, never an empty list.
`Endpoint.CloudPC.Read` is covered by CIPP's built-in readonly and higher roles; custom
roles need it added.

## AVD standards

Category **Azure Virtual Desktop Standards** in the standards templates. They run in CIPP's
background workers, which do not load CIPPHTTP, so they carry their own small ARM helpers in
`backend/Modules/CIPPStandards/Public/Custom/AVD` and honour the same `PiAvdArmAuthMode`.
A tenant without a visible subscription is reported **non-compliant** with a pointer to the
onboarding page.

| Standard | Remediate | Checks |
| --- | --- | --- |
| `PiAvdScalingPowerManage` | No | No scaling plan schedule uses `CreateDeletePowerManage`; optionally every pooled host pool has an enabled plan |
| `PiAvdStartVMOnConnect` | Yes (host pool setting only) | Start VM on Connect on every host pool; optionally the Azure Virtual Desktop service has a power-on role on those subscriptions |
| `PiAvdFslogixStorage` | No | FSLogix storage: secure transfer, TLS 1.2, no anonymous blob access, optionally approved private endpoint and closed public access |
| `PiAvdRdpProperties` | Yes (listed properties only) | Required `name:type:value` RDP properties on host pools |

Remediation sends only the one property it manages and reads the host pool back before
reporting success. Both writes need `Microsoft.DesktopVirtualization/hostpools/write`, which
is part of the Desktop Virtualization Power On Off Contributor role already in the Lighthouse
template. Report mode needs only Reader.
