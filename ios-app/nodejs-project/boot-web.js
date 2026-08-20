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
 * iOS milestone overlay: rows that cannot work on the device get disabled.
 *  - code-runtime (dsh-code-runtime-worker-thread) — relies on worker_threads,
 *    which nodejs-mobile does not support; keep the web UI surface complete
 *    while leaving code execution for a later phase.
 */
const IOS_OVERLAY = [
  { id: 'code-runtime', disabled: true },
]

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
    ...IOS_OVERLAY,
  ]
  console.log('boot-web: patch layers =', patches.length)

  // 5. Boot the tree. The host context provides the launch environment snapshot
  //    and the web app's command line (--host/--port), consumed by the
  //    web-startup provider (dsh-web-app/startup) and the webserver row.
  const portArg = process.env.DSH_IOS_PORT ?? '3080'
  const ctx = await boot(BIN_NAME, rootConfig, patches, (hostCtx) => {
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

  const webServer = ctx.get('webServer')
  const port = webServer?.port ?? 'unknown'
  console.log('boot-web: dsh web booted, listening on port', port)

  // Keep the process observable; the HTTP server keeps the loop alive anyway.
  setInterval(() => {
    console.log('boot-web: heartbeat (port', port + ')')
  }, 30_000)
  return ctx
}
