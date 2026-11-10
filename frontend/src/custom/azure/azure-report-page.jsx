import { useState } from 'react'
import { useRouter } from 'next/router'
import {
  Accordion,
  AccordionDetails,
  AccordionSummary,
  Alert,
  Box,
  Button,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  LinearProgress,
  Link,
  MenuItem,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@mui/material'
import { CippTablePage } from '../../components/CippComponents/CippTablePage'
import { ApiGetCall } from '../../api/ApiCall'
import { useSettings } from '../../hooks/use-settings'
import { getCippError } from '../../utils/get-cipp-error'
import {
  deadlineOptions,
  displayValue,
  formatDate,
  guidanceUrl,
  reportQueryKey,
  resourceUrl,
} from './report-utils'

const ExternalLink = ({ href, children }) =>
  href && (
    <Link href={href} target="_blank" rel="noopener noreferrer">
      {children}
    </Link>
  )

export const AzureReportPage = ({ kind }) => {
  const tenant = useSettings().currentTenant
  const router = useRouter()
  const changes = kind === 'Changes'
  const resourceId =
    changes && typeof router.query.resourceId === 'string'
      ? router.query.resourceId
      : ''
  const [days, setDays] = useState(7)
  const [deadline, setDeadline] = useState('All')
  const [selected, setSelected] = useState(null)
  const queryKey = reportQueryKey(kind, tenant, days, resourceId)
  const report = ApiGetCall({
    url: changes ? '/api/ListPiAzureChanges' : '/api/ListPiAzureRetirements',
    queryKey,
    data: { tenantFilter: tenant, ...(changes ? { days, resourceId } : {}) },
    waiting: Boolean(tenant) && router.isReady,
    staleTime: 60000,
    keepPreviousData: false,
  })
  const data = tenant && !report.isError ? report.data : null
  const coverage = data?.Coverage ?? []
  const rows = (data?.Items ?? []).filter(
    (row) => changes || deadline === 'All' || row.Deadline === deadline
  )
  // A detail dialog must never retain a row from another tenant/window after navigation.
  const detail = selected?.queryKey === queryKey && data ? selected.row : null
  // CippDataTable uses explicit IDs to select visible custom columns and to
  // replace auto-generated columns; accessorKey alone is not sufficient.
  const columns = [
    ...(tenant === 'AllTenants'
      ? [{ id: 'Tenant', accessorKey: 'Tenant', header: 'Customer' }]
      : []),
    { id: 'Subscription', accessorKey: 'Subscription', header: 'Subscription' },
    { id: 'Resource', accessorKey: 'Resource', header: 'Resource' },
    ...(changes
      ? [
          {
            id: 'ChangeTime',
            accessorKey: 'ChangeTime',
            header: 'Changed at',
            Cell: ({ cell }) => formatDate(cell.getValue()),
          },
          { id: 'ChangeType', accessorKey: 'ChangeType', header: 'Change' },
          { id: 'ChangedBy', accessorKey: 'ChangedBy', header: 'Changed by' },
          { id: 'Client', accessorKey: 'Client', header: 'Client' },
        ]
      : [
          { id: 'Title', accessorKey: 'Title', header: 'Retirement / upgrade' },
          {
            id: 'RetirementDate',
            accessorKey: 'RetirementDate',
            header: 'Deadline',
            Cell: ({ cell }) => formatDate(cell.getValue()),
          },
          { id: 'Deadline', accessorKey: 'Deadline', header: 'Due in' },
          { id: 'RequiredAction', accessorKey: 'RequiredAction', header: 'Required action' },
          { id: 'AdvisorState', accessorKey: 'AdvisorState', header: 'Advisor state' },
        ]),
    {
      id: 'details',
      header: 'Details',
      enableSorting: false,
      enableColumnFilter: false,
      Cell: ({ row }) => (
        <Button onClick={() => setSelected({ queryKey, row: row.original })}>
          View details
        </Button>
      ),
    },
  ]

  return (
    <>
      <CippTablePage
        key={queryKey}
        title={changes ? 'Azure Change Tracker' : 'Azure Retirements'}
        queryKey={`${queryKey}-table`}
        data={rows}
        columns={columns}
        isFetching={report.isFetching}
        tableFilter={
          <Stack spacing={2}>
            <Alert severity="info">
              {changes
                ? 'Azure records resource control-plane changes for up to 14 days. Data-plane activity and changes inside the guest OS are not included. Actor and property details may be unavailable or delayed.'
                : 'Retirement and upgrade recommendations from Azure Advisor for visible subscriptions. Azure does not provide complete impact coverage; no recommendations does not prove that nothing is affected. Unknown deadlines remain visible.'}
            </Alert>
            <Stack
              direction="row"
              spacing={2}
              useFlexGap
              sx={{ flexWrap: 'wrap', alignItems: 'center' }}
            >
              {changes ? (
                <TextField
                  select
                  label="Change window"
                  value={days}
                  onChange={(event) => setDays(Number(event.target.value))}
                  sx={{ minWidth: 180 }}
                >
                  {[1, 7, 14].map((value) => (
                    <MenuItem key={value} value={value}>
                      Last {value} {value === 1 ? 'day' : 'days'}
                    </MenuItem>
                  ))}
                </TextField>
              ) : (
                <TextField
                  select
                  label="Deadline"
                  value={deadline}
                  onChange={(event) => setDeadline(event.target.value)}
                  sx={{ minWidth: 180 }}
                >
                  {deadlineOptions.map((value) => (
                    <MenuItem key={value} value={value}>
                      {value}
                    </MenuItem>
                  ))}
                </TextField>
              )}
              <Button
                onClick={() => report.refetch()}
                disabled={!tenant || report.isFetching || !router.isReady}
              >
                Refresh
              </Button>
              <Link
                href={
                  changes
                    ? '/custom/azure/retirements'
                    : '/custom/azure/changes'
                }
              >
                {changes ? 'Open retirement tracker' : 'Open change tracker'}
              </Link>
              {data && (
                <Typography variant="body2">
                  Retrieved: {formatDate(data.RetrievedAt)}
                </Typography>
              )}
            </Stack>
            {resourceId && (
              <Alert severity="info">
                Changes for:{' '}
                <Box component="span" sx={{ overflowWrap: 'anywhere' }}>
                  {resourceId}
                </Box>{' '}
                <Link href="/custom/azure/changes">Show all resources</Link>
              </Alert>
            )}
            {report.isFetching && (
              <LinearProgress aria-label="Loading Azure report" />
            )}
            {report.isError && (
              <Alert severity="error">{getCippError(report.error)}</Alert>
            )}
            {coverage.some((source) =>
              ['Unavailable', 'Unknown'].includes(source.Status)
            ) && (
              <Alert severity="warning">
                Some customer data is unavailable or access is unknown. Review
                source coverage below; the findings are incomplete.
              </Alert>
            )}
            {data && (
              <Accordion>
                <AccordionSummary>
                  <Typography>Source coverage ({coverage.length})</Typography>
                </AccordionSummary>
                <AccordionDetails>
                  <Stack spacing={1}>
                    {coverage.map((source, index) => (
                      <Typography
                        key={`${source.Tenant}-${source.Source}-${index}`}
                        variant="body2"
                      >
                        <strong>
                          {source.Tenant} · {source.Source} · {source.Status}
                        </strong>{' '}
                        — {source.Detail}
                      </Typography>
                    ))}
                  </Stack>
                </AccordionDetails>
              </Accordion>
            )}
          </Stack>
        }
      />
      <Dialog
        open={Boolean(detail)}
        onClose={() => setSelected(null)}
        maxWidth="lg"
        fullWidth
      >
        <DialogTitle>
          {changes ? 'Azure change details' : 'Azure retirement details'}
        </DialogTitle>
        <DialogContent>
          {detail && (
            <Stack spacing={2} sx={{ overflowWrap: 'anywhere' }}>
              <Typography>
                {detail.Tenant} · {detail.Subscription}
              </Typography>
              <Typography variant="body2">
                {detail.ResourceId || 'Resource not supplied by Azure'}
              </Typography>
              <ExternalLink href={resourceUrl(detail)}>
                Open resource in Azure
              </ExternalLink>
              {changes ? (
                <>
                  <Typography>
                    {detail.ChangeType} · {formatDate(detail.ChangeTime)} ·{' '}
                    {detail.ChangedBy} ({detail.ActorType || 'Unspecified'})
                  </Typography>
                  <Typography variant="body2">
                    Client: {detail.Client} · Authorization operation:{' '}
                    {detail.Operation || 'Unspecified'}
                  </Typography>
                  <Typography variant="body2">
                    Correlation ID: {detail.CorrelationId || 'Not provided'}
                  </Typography>
                  {detail.Changes?.length ? (
                    <Box sx={{ overflowX: 'auto' }}>
                      <Table size="small">
                        <TableHead>
                          <TableRow>
                            <TableCell>Property</TableCell>
                            <TableCell>Before</TableCell>
                            <TableCell>After</TableCell>
                          </TableRow>
                        </TableHead>
                        <TableBody>
                          {detail.Changes.map((change) => (
                            <TableRow key={change.Property}>
                              <TableCell>
                                {change.Property}
                                {change.Truncated && (
                                  <Typography color="warning.main">
                                    Values truncated by Azure
                                  </Typography>
                                )}
                              </TableCell>
                              <TableCell
                                sx={{ whiteSpace: 'pre-wrap', minWidth: 180 }}
                              >
                                {displayValue(
                                  change.BeforeProvided === false
                                    ? undefined
                                    : change.Before
                                )}
                              </TableCell>
                              <TableCell
                                sx={{ whiteSpace: 'pre-wrap', minWidth: 180 }}
                              >
                                {displayValue(
                                  change.AfterProvided === false
                                    ? undefined
                                    : change.After
                                )}
                              </TableCell>
                            </TableRow>
                          ))}
                        </TableBody>
                      </Table>
                    </Box>
                  ) : (
                    <Alert severity="info">
                      No property differences supplied. Create and delete events
                      normally have no before/after values.
                    </Alert>
                  )}
                </>
              ) : (
                <>
                  <Typography variant="h6">{detail.Title}</Typography>
                  <Typography>
                    {detail.RequiredAction ||
                      'Open Azure Advisor to review the recommended action.'}
                  </Typography>
                  <Typography>
                    Deadline: {formatDate(detail.RetirementDate)} ·{' '}
                    {detail.Deadline}
                  </Typography>
                  <Typography variant="body2">
                    Feature: {detail.Feature || 'Not provided'} · Tracking IDs:{' '}
                    {detail.TrackingIds || 'Not provided'}
                  </Typography>
                  <Typography variant="body2">
                    Advisor state: {detail.AdvisorState} · Updated:{' '}
                    {formatDate(detail.LastUpdated)}
                  </Typography>
                  <ExternalLink href={guidanceUrl(detail.GuidanceUrl)}>
                    Microsoft remediation guidance
                  </ExternalLink>
                  <ExternalLink
                    href={`https://portal.azure.com/#@${encodeURIComponent(detail.TenantId)}/blade/Microsoft_Azure_Expert/AdvisorMenuBlade/recommendations`}
                  >
                    Open Azure Advisor
                  </ExternalLink>
                  {detail.ResourceId && (
                    <Link
                      href={`/custom/azure/changes?resourceId=${encodeURIComponent(detail.ResourceId)}`}
                    >
                      View changes to this resource
                    </Link>
                  )}
                </>
              )}
            </Stack>
          )}
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setSelected(null)}>Close</Button>
        </DialogActions>
      </Dialog>
    </>
  )
}
