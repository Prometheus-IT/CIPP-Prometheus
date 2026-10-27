import { Layout as DashboardLayout } from '../../../../layouts/index'
import { CippTablePage } from '../../../../components/CippComponents/CippTablePage.jsx'
import { useSettings } from '../../../../hooks/use-settings'
import { getAvdHostPoolActions } from '../../../../custom/avd/avd-actions.jsx'

const Page = () => {
  const tenantFilter = useSettings().currentTenant
  const actions = getAvdHostPoolActions()

  const simpleColumns = [
    ...(tenantFilter === 'AllTenants' ? ['Tenant'] : []),
    'name',
    'friendlyName',
    'hostPoolType',
    'loadBalancerType',
    'maxSessionLimit',
    'startVMOnConnect',
    'validationEnvironment',
    'location',
    'resourceGroup',
  ]

  return (
    <CippTablePage
      title="AVD Host Pools"
      apiUrl="/api/ListPiAvdHostPools"
      queryKey={`PiAvdHostPools-${tenantFilter}`}
      actions={actions}
      offCanvas={{
        extendedInfoFields: [
          'name',
          'friendlyName',
          'hostPoolType',
          'personalDesktopAssignmentType',
          'preferredAppGroupType',
          'publicNetworkAccess',
          'subscriptionId',
          'id',
        ],
        actions,
      }}
      simpleColumns={simpleColumns}
    />
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
