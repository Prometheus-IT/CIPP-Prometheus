// Fork addition (Prometheus Informatik): the onboarding instructions above the Lighthouse
// status table. Everything shown comes from ListPiAzureLighthouseTemplate; nothing here
// deploys or grants anything - a customer administrator runs the template.
import { Alert, Button, Chip, Divider, Stack, Typography } from '@mui/material'
import CippButtonCard from '../../components/CippCards/CippButtonCard'
import { CippCopyToClipBoard } from '../../components/CippComponents/CippCopyToClipboard'
import { ApiGetCall } from '../../api/ApiCall'
import { getCippError } from '../../utils/get-cipp-error'
import { CippIcons } from '../../utils/icon-registry'

export const downloadTemplate = (fileName, json) => {
  const blob = new Blob([json], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = fileName
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(url)
}

const Value = ({ label, value }) => (
  <Stack direction="row" spacing={1} sx={{ alignItems: 'center', minWidth: 0 }}>
    <Typography variant="body2" color="text.secondary" sx={{ minWidth: 170 }}>
      {label}
    </Typography>
    <Typography variant="body2" sx={{ fontFamily: 'monospace', overflowWrap: 'anywhere' }}>
      {value}
    </Typography>
    {value && <CippCopyToClipBoard text={value} />}
  </Stack>
)

export const LighthouseOnboardingCard = () => {
  const template = ApiGetCall({
    url: '/api/ListPiAzureLighthouseTemplate',
    queryKey: 'PiAzureLighthouseTemplate',
  })
  const info = template.data

  return (
    <CippButtonCard
      title="Onboard a customer subscription"
      isFetching={template.isFetching}
      component="accordion"
      accordionExpanded={true}
    >
      {template.isError ? (
        <Alert severity="error">{getCippError(template.error)}</Alert>
      ) : (
        info && (
          <Stack spacing={1.5}>
            <Alert severity={info.AuthMode === 'Lighthouse' ? 'info' : 'warning'}>
              {info.Note} CIPP never deploys this template or grants access itself.
            </Alert>
            <Value label="Managing tenant" value={info.ManagedByTenantId} />
            <Value label={`Delegated principal (${info.PrincipalName})`} value={info.PrincipalId} />
            <Stack direction="row" spacing={1} sx={{ flexWrap: 'wrap', gap: 1 }}>
              {(info.Roles ?? []).map((role) => (
                <Chip key={role.Id} size="small" label={role.Name} title={role.Purpose} />
              ))}
            </Stack>
            <Divider />
            <Typography variant="body2">
              1. Download the template. 2. In the customer tenant, open Custom deployment and
              load it, or run one of the commands below. 3. Pick the subscription with AVD and
              deploy. 4. Refresh this table.
            </Typography>
            <Stack direction="row" spacing={1} sx={{ flexWrap: 'wrap', gap: 1 }}>
              <Button
                variant="contained"
                size="small"
                startIcon={<CippIcons.Download />}
                onClick={() => downloadTemplate(info.FileName, info.TemplateJson)}
              >
                Download template
              </Button>
              <Button
                variant="outlined"
                size="small"
                startIcon={<CippIcons.OpenInNew />}
                href={info.PortalUrl}
                target="_blank"
                rel="noopener noreferrer"
              >
                Open Custom deployment
              </Button>
            </Stack>
            <Value label="Azure CLI" value={info.AzCli} />
            <Value label="Azure PowerShell" value={info.AzPowerShell} />
          </Stack>
        )
      )}
    </CippButtonCard>
  )
}

export default LighthouseOnboardingCard
