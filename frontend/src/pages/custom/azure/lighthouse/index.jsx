import { Layout as DashboardLayout } from '../../../../layouts/index'
import { CippTablePage } from '../../../../components/CippComponents/CippTablePage.jsx'
import { useSettings } from '../../../../hooks/use-settings'
import { LighthouseOnboardingCard } from '../../../../custom/azure/lighthouse-onboarding-card.jsx'
import { getLighthouseStatusActions } from '../../../../custom/azure/lighthouse-actions.jsx'

const Page = () => {
  const tenantFilter = useSettings().currentTenant
  const actions = getLighthouseStatusActions()

  const simpleColumns = [
    ...(tenantFilter === 'AllTenants' ? ['Tenant'] : []),
    'Status',
    'Detail',
    'Access',
    'Subscriptions',
    'SubscriptionsWithAvd',
    'HostPools',
    'Roles',
    'MissingRoles',
  ]

  return (
    <CippTablePage
      title="Azure Lighthouse Onboarding"
      apiUrl="/api/ListPiAzureLighthouseStatus"
      queryKey={`PiAzureLighthouseStatus-${tenantFilter}`}
      tableFilter={<LighthouseOnboardingCard />}
      actions={actions}
      offCanvas={{
        extendedInfoFields: [
          'TenantName',
          'TenantId',
          'AuthMode',
          'Status',
          'Detail',
          'Access',
          'Roles',
          'MissingRoles',
          'SubscriptionDetails',
        ],
        actions,
      }}
      simpleColumns={simpleColumns}
    />
  )
}

Page.getLayout = (page) => <DashboardLayout>{page}</DashboardLayout>

export default Page
