import { CippIcons } from '../../utils/icon-registry'

// Read-only for now: Cloud PC actions (reboot, restore, resize) need CloudPC.ReadWrite.All,
// which the CIPP SAM app does not request.
export const getCloudPcActions = (tenantFilter) => [
  {
    label: 'View Intune Device',
    link: '/endpoint/MEM/devices/device?deviceId=[ManagedDeviceId]&tenantFilter=[Tenant]',
    color: 'info',
    icon: <CippIcons.LaptopWindows />,
    condition: (row) => Boolean(row.ManagedDeviceId),
    multiPost: false,
  },
  {
    label: 'Open in Intune',
    link: `https://intune.microsoft.com/${tenantFilter}/#view/Microsoft_Intune_Devices/DeviceSettingsMenuBlade/~/overview/mdmDeviceId/[ManagedDeviceId]`,
    color: 'info',
    icon: <CippIcons.OpenInNew />,
    target: '_blank',
    external: true,
    condition: (row) => Boolean(row.ManagedDeviceId) && tenantFilter !== 'AllTenants',
    multiPost: false,
  },
]
