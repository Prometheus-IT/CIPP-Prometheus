import { CippIcons } from '../../utils/icon-registry'

// Read-only navigation; onboarding itself happens in the customer tenant.
export const getLighthouseStatusActions = () => [
  {
    label: 'View AVD Host Pools',
    link: '/custom/avd/host-pools?tenantFilter=[Tenant]',
    color: 'info',
    icon: <CippIcons.Computer />,
    condition: (row) => row.HostPools > 0,
    multiPost: false,
  },
]
