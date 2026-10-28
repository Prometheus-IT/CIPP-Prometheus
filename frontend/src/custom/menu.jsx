// Fork customisations for the side navigation.
//
// Upstream's layouts/config.jsx only gets two lines appended (see FORK-PATCHES.md):
//   import { applyCustomMenuItems } from '../custom/menu'
//   applyCustomMenuItems(nativeMenuItems)
// Everything else lives here, so upstream edits to the menu never conflict with ours.
import { SvgIcon } from '@mui/material'
import { CippIcons } from '../utils/icon-registry'

export const customMenuItems = [
  {
    title: 'Azure',
    type: 'header',
    icon: (
      <SvgIcon>
        <CippIcons.Cloud />
      </SvgIcon>
    ),
    permissions: ['Endpoint.AVD.*', 'Endpoint.CloudPC.*'],
    // Insert after this upstream top-level item; falls back to before 'Tools', then the end.
    insertAfter: 'Intune',
    items: [
      {
        title: 'Azure Virtual Desktop',
        permissions: ['Endpoint.AVD.*'],
        items: [
          {
            title: 'Host Pools',
            path: '/custom/avd/host-pools',
            permissions: ['Endpoint.AVD.*'],
          },
          {
            title: 'Session Hosts',
            path: '/custom/avd/session-hosts',
            permissions: ['Endpoint.AVD.*'],
          },
          {
            title: 'User Sessions',
            path: '/custom/avd/sessions',
            permissions: ['Endpoint.AVD.*'],
          },
        ],
      },
      {
        title: 'Windows 365',
        permissions: ['Endpoint.CloudPC.*'],
        items: [
          {
            title: 'Cloud PCs',
            path: '/custom/w365/cloud-pcs',
            permissions: ['Endpoint.CloudPC.*'],
          },
        ],
      },
      {
        title: 'Azure Lighthouse',
        permissions: ['Endpoint.AVD.*'],
        items: [
          {
            title: 'Onboarding',
            path: '/custom/azure/lighthouse',
            permissions: ['Endpoint.AVD.*'],
          },
        ],
      },
    ],
  },
]

export const applyCustomMenuItems = (menuItems) => {
  if (!Array.isArray(menuItems)) return menuItems

  customMenuItems.forEach((customItem) => {
    // Idempotent: hot reload or a second import must not add the section twice
    if (menuItems.some((item) => item.title === customItem.title)) return

    const { insertAfter, ...item } = customItem
    let index = menuItems.findIndex(
      (existing) => existing.title === insertAfter
    )
    if (index !== -1) {
      menuItems.splice(index + 1, 0, item)
      return
    }
    index = menuItems.findIndex((existing) => existing.title === 'Tools')
    if (index !== -1) {
      menuItems.splice(index, 0, item)
      return
    }
    menuItems.push(item)
  })

  return menuItems
}
