import { useRouter } from 'next/router'
import { Layout as DashboardLayout } from '../../../../layouts/index'
import { CippTablePage } from '../../../../components/CippComponents/CippTablePage.jsx'
import { useSettings } from '../../../../hooks/use-settings'
import { getAvdUserSessionActions } from '../../../../custom/avd/avd-actions.jsx'

const Page = () => {
  const router = useRouter()
  const tenantFilter = useSettings().currentTenant
  const hostPoolId =
    typeof router.query.HostPoolId === 'string'
      ? router.query.HostPoolId
      : undefined
  const hostPoolName = hostPoolId ? hostPoolId.split('/').pop() : null
  const actions = getAvdUserSessionActions()

  const simpleColumns = [
    ...(tenantFilter === 'AllTenants' ? ['Tenant'] : []),
    'UserPrincipalName',
    'SessionState',
    'SessionHost',
    'HostPool',
    'ApplicationType',
    'CreateTime',
  ]

  return (
    <CippTablePage
      title={
        hostPoolName
          ? `AVD User Sessions - ${hostPoolName}`
          : 'AVD User Sessions'
      }
      apiUrl="/api/ListPiAvdUserSessions"
      apiData={hostPoolId ? { HostPoolId: hostPoolId } : {}}
      queryKey={`PiAvdUserSessions-${tenantFilter}-${hostPoolId ?? 'all'}`}
      actions={actions}
      offCanvas={{
        extendedInfoFields: [
          'UserPrincipalName',
          'ActiveDirectoryUserName',
          'SessionState',
          'SessionHost',
          'HostPool',
          'SessionId',
          'ApplicationType',
          'CreateTime',
        ],
        actions,
      }}
      simpleColumns={simpleColumns}
    />
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
