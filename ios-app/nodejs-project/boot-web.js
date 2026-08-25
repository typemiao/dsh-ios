// nodejs-project/boot-web.js — boot the dsh web profile on iOS.
//
// Mirrors apps/cli/src/profile-boot.ts (runProfile) minus CLI-only machinery:
// signals, fail-loud, config HMR watchers. The web profile's rows are composed
// from the bundle layers (@deepseek-ai/dsh-base, @deepseek-ai/dsh-web-app), the
// profile's own cordis.patch.yml, and an iOS overlay that disables rows whose
// native dependencies cannot exist on iOS (node-pty, sharp, worker threads).

import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
import {
  boot,
  healProfilesModuleFallback,
  loadProfile,
} from '@deepseek-ai/dsh-app-boot'
import { provideCmdline } from '@deepseek-ai/dsh-cmdline'
import {
  DSH_LAUNCH_ENVIRONMENT_KEY,
  createLaunchEnvironmentSnapshot,
} from '@deepseek-ai/dsh-launch-environment'

/** The dsh installation root inside the app bundle (the deployed @deepseek-ai/dsh package). */
const DIST = dirname(fileURLToPath(import.meta.url))
/** The shipped agent-preset root beside the app's own config (assembly fact). */
const SHIPPED_PRESET_ROOT = join(DIST, 'config', 'agent-presets')

/** Web profile name and the launcher's diagnostic prefix. */
const PROFILE = 'web'
const BIN_NAME = 'dsh'

/**
 * iOS milestone overlay: rows that cannot work on the device get disabled
 * (keep the web UI surface complete; push these back to a later phase).
 *  - code-runtime            — worker_threads unsupported by nodejs-mobile.
 *  - llm-pi-ai               — its identifier regex uses \p{ID_Start} (the
 *    intl-less iOS V8 cannot compile Unicode property escapes).
 *
 * Both are NON-core rows: disabling them leaves the services the web UI needs
 * intact (the `llm` seam is still provided by dsh-llm-deepseek). The three
 * providers whose services are load-bearing for the web surface —
 * session-persistence-jsonl (sessionPersistence), attachment-local
 * (attachments), sandbox (sandbox / fs-sandbox) — MUST NOT be disabled: the
 * web API gateway (host-apiproxy) hard-injects `attachments` and `sessions`,
 * so disabling any of them leaves the whole web tree pending. Those three are
 * instead made import-safe on iOS by prepare-dsh-dist.sh (native addons
 * stubbed, zstd fallback). Only code-runtime and llm-pi-ai are disabled here.
 *
 * This overlay is only for the iOS runtime. The same boot-web.js drives the
 * Linux smoke test (payload step), on which these rows must stay enabled —
 * the desktop smoke asserts the exact cordis-import path, not an iOS tree.
 */
const IS_IOS = process.platform === 'ios'
/**
 * iOS overlay rows, built at boot time so `root` resolves against the launched
 * DSH_HOME (the base row's `dshHomePath('sessions')` is lazy; evaluating it at
 * module load would use an unset DSH_HOME and fall back to `~/.dsh`).
 */
function iosOverlay(dshHome) {
  if (!IS_IOS) return []
  return [
    { id: 'code-runtime', disabled: true },
    { id: 'llm-pi-ai', disabled: true },
    // Node 22.9 (nodejs-mobile) has no node:zlib zstd API. The backend is
    // made import-safe by prepare-dsh-dist.sh (zstd.js loads zlib lazily);
    // pinning compression to `none` here means the zstd path is never taken,
    // so session persistence runs on JSONL plaintext. A patch REPLACES the
    // row's whole config, so root is restated from the base row.
    {
      id: 'session-persistence-jsonl',
      config: { root: join(dshHome, 'sessions'), compression: 'none' },
    },
    // The preset roster. The web-app layer ships `default: standard` but no
    // roots; the CLI's composeProfile is what injects the shipped root (the
    // config/agent-presets beside the app's own config, an assembly fact). Our
    // manual boot skips composeProfile, so the roster resolves to no preset at
    // all (`available: none`) and the UI cannot create a session. Restate the
    // shipped system root here. A patch REPLACES the row's whole config, so
    // `default` is restated too; `includeUserRoot` (which appends
    // $DSH_HOME/.agent-presets as a user root) is a schema default and survives.
    {
      id: 'agent-presets',
      config: {
        default: 'standard',
        roots: [{ path: SHIPPED_PRESET_ROOT, trust: 'system' }],
      },
    },
  ]
}

export async function bootWeb(dshHome) {
  process.env.DSH_HOME = dshHome
  console.log('boot-web: DSH_HOME =', dshHome)
  console.log('boot-web: DIST =', DIST)

  if (!existsSync(join(DIST, 'package.json'))) {
    throw new Error(`dsh-dist missing at ${DIST}`)
  }

  // 1. Maintain the flat module fallback $DSH_HOME/profiles/node_modules so the
  //    loader can resolve every in-box plugin from the profile directory.
  const installAnchor = join(DIST, 'package.json')
  healProfilesModuleFallback(installAnchor)
  console.log('boot-web: module fallback healed')

  // 2. Load (auto-init) the web profile: bundles @deepseek-ai/dsh-base +
  //    @deepseek-ai/dsh-web-app, plus the profile's own cordis.patch.yml.
  const profile = loadProfile(BIN_NAME, PROFILE, installAnchor)
  console.log('boot-web: profile dir =', profile.dir)
  console.log('boot-web: bundles =', profile.layers.map((l) => l.packageName))

  // 3. The loader needs a real include root to anchor baseUrl: an empty entry
  //    list file inside the profile directory (same contract as the CLI).
  const rootConfig = join(profile.dir, 'cordis.yml')
  writeFileSync(rootConfig, '# dsh profile root — an empty entry list.\n[]\n')

  // 4. Patch stack in application order: bundle layers, the profile user layer,
  //    then the iOS overlay (which outranks both).
  const patches = [
    ...profile.layers.flatMap((layer) => layer.patches),
    ...profile.patches,
    ...iosOverlay(dshHome),
  ]
  console.log('boot-web: patch layers =', patches.length)

  // 5. Boot the tree. The host context provides the launch environment snapshot
  //    and the web app's command line (--host/--port), consumed by the
  //    web-startup provider (dsh-web-app/startup) and the webserver row.
  const portArg = process.env.DSH_IOS_PORT ?? '3080'
  let ctx
  try {
    ctx = await boot(BIN_NAME, rootConfig, patches, (hostCtx) => {
      hostCtx.provide(
        DSH_LAUNCH_ENVIRONMENT_KEY,
        createLaunchEnvironmentSnapshot([{ source: 'process', values: process.env }]),
      )
      provideCmdline(hostCtx, {
        args: ['--host', '127.0.0.1', '--port', portArg],
        exit: (code) => {
          console.log('boot-web: dsh requested exit', code)
        },
      })
    })
  } catch (err) {
    // dump the full error tree (the loader wraps per-entry failures in an
    // AggregateError whose individual reasons the default console print hides)
    const dump = (e, depth) => {
      const pad = '  '.repeat(depth)
      console.error(`${pad}> ${e && e.message ? e.message : String(e)}`)
      if (e && Array.isArray(e.errors)) e.errors.forEach((x) => dump(x, depth + 1))
      if (e && e.cause && e.cause !== e) dump(e.cause, depth + 1)
    }
    dump(err, 0)
    throw err
  }

  const webServer = ctx.get('webServer')
  const port = webServer?.port ?? 'unknown'
  console.log('boot-web: dsh web booted, listening on port', port)

  // Keep the process observable; the HTTP server keeps the loop alive anyway.
  setInterval(() => {
    console.log('boot-web: heartbeat (port', port + ')')
  }, 30_000)
  return ctx
}
