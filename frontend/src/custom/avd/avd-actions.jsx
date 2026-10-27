import { CippIcons } from '../../utils/icon-registry'

const portalLink = (idField) =>
  `https://portal.azure.com/#resource[${idField}]/overview`

export const getAvdHostPoolActions = () => [
  {
    label: 'View Session Hosts',
    link: '/custom/avd/session-hosts?HostPoolId=[id]',
    pinned: true,
    color: 'info',
    icon: <CippIcons.Computer />,
    multiPost: false,
  },
  {
    label: 'View User Sessions',
    link: '/custom/avd/sessions?HostPoolId=[id]',
    color: 'info',
    icon: <CippIcons.EyeIcon />,
    multiPost: false,
  },
  {
    label: 'Open in Azure Portal',
    link: portalLink('id'),
    color: 'info',
    icon: <CippIcons.Cloud />,
    target: '_blank',
    external: true,
    multiPost: false,
  },
]

export const getAvdSessionHostActions = () => [
  {
    label: 'Turn On Drain Mode',
    type: 'POST',
    icon: <CippIcons.Lock />,
    url: '/api/ExecPiAvdSessionHost',
    data: { ID: 'id', Action: '!drainOn' },
    confirmText: 'Stop new sessions on [Name]? Existing sessions keep running.',
    condition: (row) => row.AllowNewSession === true,
    multiPost: false,
  },
  {
    label: 'Turn Off Drain Mode',
    type: 'POST',
    icon: <CippIcons.LockOpen />,
    url: '/api/ExecPiAvdSessionHost',
    data: { ID: 'id', Action: '!drainOff' },
    confirmText: 'Allow new sessions on [Name] again?',
    condition: (row) => row.AllowNewSession === false,
    multiPost: false,
  },
  {
    label: 'Start VM',
    type: 'POST',
    icon: <CippIcons.PlayArrow />,
    url: '/api/ExecPiAvdSessionHost',
    data: { ID: 'id', Action: '!start' },
    confirmText: 'Start the virtual machine behind [Name]?',
    condition: (row) => row.PowerState !== 'VM running',
    multiPost: false,
  },
  {
    label: 'Restart VM',
    type: 'POST',
    icon: <CippIcons.RestartAlt />,
    url: '/api/ExecPiAvdSessionHost',
    data: { ID: 'id', Action: '!restart' },
    fields: [
      {
        type: 'switch',
        name: 'Force',
        label: 'Restart even if users are signed in',
      },
    ],
    confirmText:
      'Restart [Name]? It currently has [Sessions] session(s). Without Force, the restart is refused while sessions exist.',
    color: 'danger',
    multiPost: false,
  },
  {
    label: 'View User Sessions',
    link: '/custom/avd/sessions?HostPoolId=[HostPoolId]',
    color: 'info',
    icon: <CippIcons.EyeIcon />,
    multiPost: false,
  },
  {
    label: 'Open VM in Azure Portal',
    link: portalLink('VmResourceId'),
    color: 'info',
    icon: <CippIcons.Cloud />,
    target: '_blank',
    external: true,
    condition: (row) => Boolean(row.VmResourceId),
    multiPost: false,
  },
]

export const getAvdUserSessionActions = () => [
  {
    label: 'Send Message',
    type: 'POST',
    icon: <CippIcons.Send />,
    url: '/api/ExecPiAvdUserSession',
    data: {
      ID: 'id',
      Action: '!sendMessage',
      UserPrincipalName: 'UserPrincipalName',
    },
    fields: [
      {
        type: 'textField',
        name: 'MessageTitle',
        label: 'Title',
        disableVariables: true,
        validators: {
          required: { value: true, message: 'A title is required' },
        },
      },
      {
        type: 'textField',
        name: 'MessageBody',
        label: 'Message',
        multiline: true,
        rows: 3,
        disableVariables: true,
        validators: {
          required: { value: true, message: 'A message is required' },
        },
      },
    ],
    confirmText:
      'Send a pop-up message to [UserPrincipalName] on [SessionHost].',
    multiPost: false,
  },
  {
    label: 'Disconnect',
    type: 'POST',
    icon: <CippIcons.LinkOff />,
    url: '/api/ExecPiAvdUserSession',
    data: {
      ID: 'id',
      Action: '!disconnect',
      UserPrincipalName: 'UserPrincipalName',
    },
    confirmText:
      'Disconnect [UserPrincipalName] from [SessionHost]? Apps keep running and the user can reconnect.',
    condition: (row) => row.SessionState === 'Active',
    multiPost: false,
  },
  {
    label: 'Log Off',
    type: 'POST',
    icon: <CippIcons.Logout />,
    url: '/api/ExecPiAvdUserSession',
    data: {
      ID: 'id',
      Action: '!logoff',
      UserPrincipalName: 'UserPrincipalName',
    },
    confirmText:
      'Force log off [UserPrincipalName] from [SessionHost]? Unsaved work in the session will be lost.',
    color: 'danger',
    multiPost: false,
  },
]
