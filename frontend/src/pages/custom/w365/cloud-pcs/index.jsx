import { Layout as DashboardLayout } from '../../../../layouts/index'
import { CippTablePage } from '../../../../components/CippComponents/CippTablePage.jsx'
import { useSettings } from '../../../../hooks/use-settings'
import { getCloudPcActions } from '../../../../custom/w365/cloud-pc-actions.jsx'

const Page = () => {
  const tenantFilter = useSettings().currentTenant
  const actions = getCloudPcActions(tenantFilter)

  const simpleColumns = [
    ...(tenantFilter === 'AllTenants' ? ['Tenant'] : []),
    'Name',
    'UserPrincipalName',
    'Health',
    'Status',
    'Connectivity',
    'ServicePlan',
    'ProvisioningPolicy',
    'ProductType',
    'LastLogin',
    'GracePeriodEnd',
    'Source',
  ]

  return (
    <CippTablePage
      title="Windows 365 Cloud PCs"
      apiUrl="/api/ListPiCloudPCs"
      queryKey={`PiCloudPCs-${tenantFilter}`}
      actions={actions}
      offCanvas={{
        extendedInfoFields: [
          'Name',
          'ManagedDeviceName',
          'UserPrincipalName',
          'Health',
          'Status',
          'Connectivity',
          'ConnectivityCheckedAt',
          'PowerState',
          'ServicePlan',
          'ServicePlanType',
          'ProductType',
          'ProvisioningPolicy',
          'ProvisioningType',
          'Image',
          'Connection',
          'OsVersion',
          'DiskEncryption',
          'ProvisionedAt',
          'GracePeriodEnd',
          'LastModified',
          'Source',
          'SourceError',
        ],
        actions,
      }}
      simpleColumns={simpleColumns}
    />
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
