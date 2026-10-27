import { describe, it, expect } from 'vitest'

// Fork guard: the pages import upstream components by path (CippTablePage, layouts, hooks).
// If upstream moves or renames one of them, this fails in the sync PR instead of at build time.
const pages = {
  'host-pools': () => import('../../src/pages/custom/avd/host-pools/index.jsx'),
  'session-hosts': () =>
    import('../../src/pages/custom/avd/session-hosts/index.jsx'),
  sessions: () => import('../../src/pages/custom/avd/sessions/index.jsx'),
}

describe('fork AVD pages', () => {
  for (const [name, load] of Object.entries(pages)) {
    it(`${name} resolves its imports and exports a page with a layout`, async () => {
      const mod = await load()
      expect(typeof mod.default).toBe('function')
      expect(typeof mod.default.getLayout).toBe('function')
    })
  }

  it('wire every action to a fork endpoint or a fork/portal link', async () => {
    const {
      getAvdHostPoolActions,
      getAvdSessionHostActions,
      getAvdUserSessionActions,
    } = await import('../../src/custom/avd/avd-actions.jsx')
    const all = [
      ...getAvdHostPoolActions(),
      ...getAvdSessionHostActions(),
      ...getAvdUserSessionActions(),
    ]
    for (const action of all) {
      if (action.url) expect(action.url).toMatch(/^\/api\/(Exec|List)PiAvd/)
      else
        expect(action.link).toMatch(
          /^(\/custom\/avd\/|https:\/\/portal\.azure\.com\/)/
        )
    }
  })
})
