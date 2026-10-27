// Azure Lighthouse delegation for the CIPP fork's AVD module.
//
// Deploy ONCE PER CUSTOMER SUBSCRIPTION that holds AVD host pools or session host VMs,
// signed in to the CUSTOMER tenant with Owner on that subscription:
//
//   az deployment sub create \
//     --location switzerlandnorth \
//     --template-file cipp-avd-lighthouse.bicep \
//     --parameters managedByTenantId=<partner tenant id> cippPrincipalId=<group object id>
//
// cippPrincipalId: object id (in the PARTNER tenant) of a security group that contains the
// CIPP SAM app's service principal. A group means you can rotate or add principals later
// without redeploying to every customer.
//
// Least privilege for what the AVD pages do. All three are built-in roles without
// dataActions, so Lighthouse accepts them.
targetScope = 'subscription'

@description('Partner (managing) tenant id - the tenant CIPP runs in.')
param managedByTenantId string

@description('Object id in the partner tenant of the group containing the CIPP SAM service principal.')
param cippPrincipalId string

@description('Display name shown to the customer for the delegated principal.')
param cippPrincipalDisplayName string = 'CIPP AVD Management'

@description('Offer name shown in the customer\'s Service providers blade.')
param offerName string = 'Prometheus Informatik - CIPP AVD Management'

@description('Offer description shown to the customer.')
param offerDescription string = 'Read access plus AVD session host, user session and VM power operations for managed Azure Virtual Desktop.'

var roles = [
  {
    // Resource Graph visibility of host pools, VMs and the subscription itself
    name: 'Reader'
    id: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  }
  {
    // Drain mode (sessionhosts/write) and log off / disconnect / send message (usersessions/*)
    name: 'Desktop Virtualization Session Host Operator'
    id: '2ad6aaab-ead9-4eaa-8ac5-da422f562408'
  }
  {
    // Start and restart session host VMs
    name: 'Desktop Virtualization Power On Off Contributor'
    id: '40c5ff49-9181-41f8-ae61-143b0e78555e'
  }
]

// Deterministic names: redeploying updates the same offer instead of adding a second one.
var definitionName = guid(offerName, managedByTenantId)
var assignmentName = guid(offerName, managedByTenantId, subscription().subscriptionId)

resource definition 'Microsoft.ManagedServices/registrationDefinitions@2022-10-01' = {
  name: definitionName
  properties: {
    registrationDefinitionName: offerName
    description: offerDescription
    managedByTenantId: managedByTenantId
    authorizations: [
      for role in roles: {
        principalId: cippPrincipalId
        principalIdDisplayName: cippPrincipalDisplayName
        roleDefinitionId: role.id
      }
    ]
  }
}

resource assignment 'Microsoft.ManagedServices/registrationAssignments@2022-10-01' = {
  name: assignmentName
  properties: {
    registrationDefinitionId: definition.id
  }
}

output registrationDefinitionId string = definition.id
output registrationAssignmentId string = assignment.id
