import { describe, it, expect } from 'vitest'
import {
  applyCustomMenuItems,
  customMenuItems,
} from '../../src/custom/menu.jsx'
import { nativeMenuItems } from '../../src/layouts/config.jsx'

// Fork guard: if an upstream merge drops the two-line hook at the end of layouts/config.jsx,
// the AVD pages silently disappear from the navigation. This test fails instead.
describe('fork menu customisations', () => {
  it('are applied to the native menu by layouts/config.jsx', () => {
    const titles = nativeMenuItems.map((item) => item.title)
    for (const custom of customMenuItems) {
      expect(titles).toContain(custom.title)
    }
  })

  it('insert after the anchor item when it exists', () => {
    const menu = [
      { title: 'Dashboard' },
      { title: 'Intune' },
      { title: 'Tools' },
    ]
    applyCustomMenuItems(menu)
    expect(menu.map((item) => item.title)).toEqual([
      'Dashboard',
      'Intune',
      'Azure',
      'Tools',
    ])
  })

  it('fall back to before Tools, then to the end', () => {
    const withTools = [{ title: 'Dashboard' }, { title: 'Tools' }]
    applyCustomMenuItems(withTools)
    expect(withTools.map((item) => item.title)).toEqual([
      'Dashboard',
      'Azure',
      'Tools',
    ])

    const bare = [{ title: 'Dashboard' }]
    applyCustomMenuItems(bare)
    expect(bare.map((item) => item.title)).toEqual(['Dashboard', 'Azure'])
  })

  it('are idempotent and do not leak the insertAfter hint', () => {
    const menu = [{ title: 'Intune' }]
    applyCustomMenuItems(menu)
    applyCustomMenuItems(menu)
    expect(menu.filter((item) => item.title === 'Azure')).toHaveLength(1)
    expect(menu.find((item) => item.title === 'Azure')).not.toHaveProperty(
      'insertAfter'
    )
  })

  it('point every leaf at a page under /custom/', () => {
    const leaves = []
    const walk = (items) =>
      items.forEach((item) =>
        item.items ? walk(item.items) : item.path && leaves.push(item.path)
      )
    walk(customMenuItems)
    expect(leaves.length).toBeGreaterThan(0)
    leaves.forEach((path) => expect(path.startsWith('/custom/')).toBe(true))
  })
})
