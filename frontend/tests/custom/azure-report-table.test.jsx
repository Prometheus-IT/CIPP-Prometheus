import React from 'react'
import { fireEvent, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { renderWithProviders, settingsWith } from '../test-utils'
import { AzureReportPage } from '../../src/custom/azure/azure-report-page'
import { api, getResult, paginatedResult } from '../mocks/api-call'

vi.mock('../../src/api/ApiCall', async () =>
  (await import('../mocks/api-call')).apiCallMock()
)

// jsdom has no layout measurements. Keep the real CIPP and MRT table logic,
// but render all columns/rows so assertions can inspect the visible cells.
vi.mock('material-react-table', async (importOriginal) => {
  const actual = await importOriginal()
  return {
    ...actual,
    useMaterialReactTable: (options) => actual.useMaterialReactTable({
      ...options,
      enableColumnVirtualization: false,
      enableRowVirtualization: false,
    }),
  }
})

const row = {
  id: 'report-1',
  Tenant: 'customer.example',
  Subscription: 'Production subscription',
  Resource: 'vm-report',
  ChangeTime: '2026-11-09T10:00:00Z',
  ChangeType: 'Update',
  ChangedBy: 'admin@customer.example',
  Client: 'Azure portal',
  Title: 'Upgrade VM feature',
  RetirementDate: '2026-12-01T00:00:00Z',
  Deadline: '0-30 days',
  RequiredAction: 'Migrate the feature',
  AdvisorState: 'Active',
}

beforeEach(() => {
  window.localStorage.clear()
  api.paginated = paginatedResult([], { isSuccess: false })
  const report = getResult({ data: { Items: [row], Coverage: [] } })
  const idle = getResult({ isSuccess: false })
  api.get = ({ url }) => url?.startsWith('/api/ListPiAzure') ? report : idle
})

describe.each(['customer.example', 'AllTenants'])('Azure report tables for %s', (tenant) => {
  it.each([
    ['Changes', ['Changed at', 'Change', 'Changed by', 'Client'],
      ['Update', 'admin@customer.example', 'Azure portal']],
    ['Retirements', ['Retirement / upgrade', 'Deadline', 'Due in', 'Required action', 'Advisor state'],
      ['Upgrade VM feature', '0-30 days', 'Migrate the feature', 'Active']],
  ])('renders %s data columns and opens details', async (kind, headers, values) => {
    renderWithProviders(<AzureReportPage kind={kind} />, {
      settings: settingsWith({ currentTenant: tenant }),
    })
    const table = within(await screen.findByRole('table'))
    // MRT includes sorting/action labels in each header's accessible name.
    const matchingHeaders = (label) => table.getAllByRole('columnheader')
      .filter((cell) => within(cell).queryByText(label, { exact: true }))
    await waitFor(() => {
      for (const header of ['Subscription', 'Resource', ...headers, 'Details']) {
        expect(matchingHeaders(header)).toHaveLength(1)
      }
    })
    for (const value of ['Production subscription', 'vm-report', ...values]) {
      expect(table.getByText(value, { exact: true })).toBeInTheDocument()
    }
    // The all-tenant column must be visible exactly once, without a duplicate
    // auto-generated Tenant column overriding the custom Customer header.
    if (tenant === 'AllTenants') {
      expect(matchingHeaders('Customer')).toHaveLength(1)
      expect(table.getByText('customer.example', { exact: true })).toBeInTheDocument()
    } else {
      expect(matchingHeaders('Customer')).toHaveLength(0)
    }
    fireEvent.click(table.getByRole('button', { name: 'View details' }))
    expect(await screen.findByRole('dialog')).toBeInTheDocument()
    expect(screen.getByRole('heading', {
      name: kind === 'Changes' ? 'Azure change details' : 'Azure retirement details',
    })).toBeInTheDocument()
  })
})
