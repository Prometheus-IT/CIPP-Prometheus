export const deadlineOptions = [
  'All',
  'Overdue',
  '0-30 days',
  '31-60 days',
  '61-90 days',
  'Later',
  'Unknown',
]

export const reportQueryKey = (kind, tenant, days, resourceId) =>
  `PiAzureReport-${JSON.stringify([kind, tenant, days, resourceId])}`

export const guidanceUrl = (value) => {
  try {
    const url = new URL(value)
    return url.protocol === 'https:' &&
      !url.username &&
      !url.password &&
      ['learn.microsoft.com', 'azure.microsoft.com'].includes(url.hostname)
      ? url.href
      : null
  } catch {
    return null
  }
}

export const resourceUrl = (row) =>
  row.ResourceId && row.TenantId
    ? `https://portal.azure.com/#@${encodeURIComponent(row.TenantId)}/resource${row.ResourceId.split('/').map(encodeURIComponent).join('/')}`
    : null

export const displayValue = (value) => {
  if (value === undefined) return 'Not provided'
  if (typeof value === 'string') return value
  return JSON.stringify(value, null, 2)
}

export const formatDate = (value) => {
  if (!value) return 'Unknown'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? 'Unknown' : date.toLocaleString()
}
