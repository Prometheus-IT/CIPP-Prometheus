import { useRouter } from 'next/router'
import { Layout as DashboardLayout } from '../../../../layouts/index'
import { CippTablePage } from '../../../../components/CippComponents/CippTablePage.jsx'
import { useSettings } from '../../../../hooks/use-settings'
import { getAvdSessionHostActions } from '../../../../custom/avd/avd-actions.jsx'

const Page = () => {
  const router = useRouter()
  const tenantFilter = useSettings().currentTenant
  const hostPoolId =
    typeof router.query.HostPoolId === 'string'
      ? router.query.HostPoolId
      : undefined
  const hostPoolName = hostPoolId ? hostPoolId.split('/').pop() : null
  const actions = getAvdSessionHostActions()

  const simpleColumns = [
    ...(tenantFilter === 'AllTenants' ? ['Tenant'] : []),
    'Name',
    'HostPool',
    'Status',
    'PowerState',
    'AllowNewSession',
    'Sessions',
    'AssignedUser',
    'UpdateState',
    'AgentVersion',
    'LastHeartBeat',
  ]

  return (
    <CippTablePage
      title={
        hostPoolName
          ? `AVD Session Hosts - ${hostPoolName}`
          : 'AVD Session Hosts'
      }
      apiUrl="/api/ListPiAvdSessionHosts"
      apiData={hostPoolId ? { HostPoolId: hostPoolId } : {}}
      queryKey={`PiAvdSessionHosts-${tenantFilter}-${hostPoolId ?? 'all'}`}
      actions={actions}
      offCanvas={{
        extendedInfoFields: [
          'Name',
          'HostPool',
          'Status',
          'PowerState',
          'AllowNewSession',
          'Sessions',
          'AssignedUser',
          'OsVersion',
          'AgentVersion',
          'UpdateState',
          'LastHeartBeat',
          'VmResourceId',
        ],
        actions,
      }}
      simpleColumns={simpleColumns}
    />
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
