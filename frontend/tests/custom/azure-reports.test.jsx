import React from 'react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { AzureReportPage } from '../../src/custom/azure/azure-report-page'
import {
  displayValue,
  guidanceUrl,
  reportQueryKey,
  resourceUrl,
} from '../../src/custom/azure/report-utils'

const state = vi.hoisted(() => ({
  tenant: 'a.example',
  query: {},
  response: {},
  calls: [],
}))
vi.mock('../../src/hooks/use-settings', () => ({
  useSettings: () => ({ currentTenant: state.tenant }),
}))
vi.mock('next/router', () => ({
  useRouter: () => ({ query: state.query, isReady: true }),
}))
vi.mock('../../src/api/ApiCall', () => ({
  ApiGetCall: (options) => {
    state.calls.push(options)
    return state.response
  },
}))
vi.mock('../../src/utils/get-cipp-error', () => ({
  getCippError: () => 'Access denied',
}))
vi.mock('../../src/components/CippComponents/CippTablePage', () => ({
  CippTablePage: ({ data, columns, tableFilter, queryKey }) => (
    <>
      {tableFilter}
      <div data-testid="table-key">{queryKey}</div>
      {data.map((row) => (
        <div key={row.id}>
          <span>{row.Title || row.Resource}</span>
          {columns
            .find((column) => column.id === 'details')
            .Cell({ row: { original: row } })}
        </div>
      ))}
    </>
  ),
}))

const retirement = {
  id: 'r1',
  Tenant: 'a.example',
  TenantId: 'tenant-a',
  Resource: 'vm-a',
  ResourceId:
    '/subscriptions/sub-a/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-a',
  Title: 'Retirement A',
  RequiredAction: 'Upgrade feature',
  Deadline: '0-30 days',
  RetirementDate: '2026-12-01T00:00:00Z',
  GuidanceUrl: 'https://learn.microsoft.com/azure/',
}

beforeEach(() => {
  state.tenant = 'a.example'
  state.query = {}
  state.calls = []
  state.response = {
    isError: false,
    isFetching: false,
    refetch: vi.fn(),
    data: {
      Items: [retirement],
      Coverage: [],
      RetrievedAt: '2026-11-09T12:00:00Z',
    },
  }
})

describe('Azure reports', () => {
  it('shows retirement guidance and links to the affected resources change history', () => {
    render(<AzureReportPage kind="Retirements" />)
    fireEvent.click(screen.getByRole('button', { name: 'View details' }))
    expect(screen.getByText('Upgrade feature')).toBeInTheDocument()
    expect(
      screen.getByRole('link', { name: 'View changes to this resource' })
    ).toHaveAttribute(
      'href',
      `/custom/azure/changes?resourceId=${encodeURIComponent(retirement.ResourceId)}`
    )
    expect(
      screen.getByRole('link', { name: 'Microsoft remediation guidance' })
    ).toHaveAttribute('rel', 'noopener noreferrer')
  })
  it('filters deadlines without hiding unknown records by default', async () => {
    state.response.data.Items.push({
      ...retirement,
      id: 'r2',
      Title: 'Unknown date',
      Deadline: 'Unknown',
      RetirementDate: null,
    })
    render(<AzureReportPage kind="Retirements" />)
    expect(screen.getByText('Unknown date')).toBeInTheDocument()
    fireEvent.mouseDown(screen.getByRole('combobox', { name: 'Deadline' }))
    fireEvent.click(screen.getByRole('option', { name: '0-30 days' }))
    await waitFor(() =>
      expect(screen.queryByText('Unknown date')).not.toBeInTheDocument()
    )
    expect(screen.getByText('Retirement A')).toBeInTheDocument()
  })
  it('warns about partial results and exposes source coverage', () => {
    state.response.data.Coverage = [
      {
        Tenant: 'b.example',
        Source: 'Retirements',
        Status: 'Unavailable',
        Detail: 'Query failed',
      },
    ]
    render(<AzureReportPage kind="Retirements" />)
    expect(screen.getByText(/findings are incomplete/)).toBeInTheDocument()
    fireEvent.click(screen.getByText('Source coverage (1)'))
    expect(
      screen.getByText('b.example · Retirements · Unavailable')
    ).toBeInTheDocument()
  })
  it('does not show stale findings when a refresh fails', () => {
    state.response.isError = true
    render(<AzureReportPage kind="Retirements" />)
    expect(screen.getByText('Access denied')).toBeInTheDocument()
    expect(screen.queryByText('Retirement A')).not.toBeInTheDocument()
  })
  it('keeps a separate table cache key and closes details on tenant changes', () => {
    const { rerender } = render(<AzureReportPage kind="Retirements" />)
    const originalKey = state.calls.at(-1).queryKey
    expect(screen.getByTestId('table-key').textContent).not.toBe(originalKey)
    fireEvent.click(screen.getByRole('button', { name: 'View details' }))
    state.tenant = 'b.example'
    state.response.data = undefined
    rerender(<AzureReportPage kind="Retirements" />)
    expect(state.calls.at(-1).queryKey).not.toBe(originalKey)
    expect(state.calls.at(-1).keepPreviousData).toBe(false)
    expect(screen.queryByText('Upgrade feature')).not.toBeInTheDocument()
  })
  it('passes the resource filter and selected window in both the request and cache identity', async () => {
    state.query = { resourceId: retirement.ResourceId }
    state.response.data.Items = []
    render(<AzureReportPage kind="Changes" />)
    const previousKey = state.calls.at(-1).queryKey
    fireEvent.mouseDown(screen.getByRole('combobox', { name: 'Change window' }))
    fireEvent.click(screen.getByRole('option', { name: 'Last 14 days' }))
    await waitFor(() => expect(state.calls.at(-1).data.days).toBe(14))
    expect(state.calls.at(-1).data.resourceId).toBe(retirement.ResourceId)
    expect(state.calls.at(-1).queryKey).not.toBe(previousKey)
  })
  it('shows before/after values and truncation without rendering Azure text as HTML', () => {
    state.response.data.Items = [
      {
        ...retirement,
        Title: undefined,
        ChangeType: 'Update',
        ChangedBy: 'user',
        Changes: [
          {
            Property: 'tags.owner',
            Before: '<img src=x>',
            After: false,
            Truncated: true,
          },
        ],
      },
    ]
    render(<AzureReportPage kind="Changes" />)
    fireEvent.click(screen.getByRole('button', { name: 'View details' }))
    expect(screen.getByText('<img src=x>')).toBeInTheDocument()
    expect(screen.getByText('false')).toBeInTheDocument()
    expect(screen.getByText('Values truncated by Azure')).toBeInTheDocument()
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
  })
  it('disables the request and refresh when no tenant is selected', () => {
    state.tenant = null
    render(<AzureReportPage kind="Changes" />)
    expect(state.calls.at(-1).waiting).toBe(false)
    expect(screen.getByRole('button', { name: 'Refresh' })).toBeDisabled()
    expect(screen.queryByText('Retirement A')).not.toBeInTheDocument()
  })
})

describe('Azure report presentation helpers', () => {
  it('accepts only HTTPS Microsoft guidance and rejects lookalike hosts and credentials', () => {
    expect(guidanceUrl('https://learn.microsoft.com/azure/')).toBeTruthy()
    for (const url of [
      'javascript:alert(1)',
      'http://learn.microsoft.com/',
      'https://learn.microsoft.com.evil.test/',
      'https://user:pass@learn.microsoft.com/',
    ])
      expect(guidanceUrl(url)).toBeNull()
  })
  it('preserves missing, null, false, zero and structured values', () => {
    expect(displayValue(undefined)).toBe('Not provided')
    expect(displayValue(null)).toBe('null')
    expect(displayValue(false)).toBe('false')
    expect(displayValue(0)).toBe('0')
    expect(displayValue({ a: 1 })).toContain('"a": 1')
  })
  it('encodes resource links and separates tenant/window/resource cache identities', () => {
    expect(
      resourceUrl({
        TenantId: 'a',
        ResourceId: '/subscriptions/s/resourceGroups/rg #1',
      })
    ).toContain('rg%20%231')
    expect(
      new Set([
        reportQueryKey('Changes', 'a', 7, 'one'),
        reportQueryKey('Changes', 'b', 7, 'one'),
        reportQueryKey('Changes', 'a', 14, 'one'),
        reportQueryKey('Changes', 'a', 7, 'two'),
      ]).size
    ).toBe(4)
  })
})
