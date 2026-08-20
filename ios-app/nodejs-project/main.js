// nodejs-project/main.js — DSH Mobile bootstrap.
//
// argv from the native shell (positions shift if --expose-internals is on):
//   [..., DSH_HOME, CONSOLE_LOG, PHASE]
//     DSH_HOME    -> writable sandbox directory (Application Support/dsh)
//     CONSOLE_LOG -> mirror file for console output (the shell tails it to NSLog)
//     PHASE       -> 1: engine only · 2: dsh core import · 3: dsh web boot
//
// Phase 1 milestone: print "node up" (visible in the Xcode console via the
// mirror log). Phases 2/3 build on it.

import { appendFileSync, writeFileSync } from 'node:fs'

const [, , ...rest] = process.argv
const [DSH_HOME = '', CONSOLE_LOG = '', PHASE = '1'] = rest.slice(-3)

// ── console mirror (iOS has no attached stdout; the shell tails this file) ──
if (CONSOLE_LOG) {
  writeFileSync(CONSOLE_LOG, '')
  const log = (level, args) => {
    const line = `[${new Date().toISOString()}] ${level} ${args.map(String).join(' ')}`
    try { appendFileSync(CONSOLE_LOG, line + '\n') } catch {}
  }
  console.log = (...a) => log('LOG', a)
  console.info = (...a) => log('INFO', a)
  console.warn = (...a) => log('WARN', a)
  console.error = (...a) => log('ERROR', a)
  process.on('uncaughtException', (err) => {
    log('FATAL', [err?.stack ?? err])
    process.exit(1)
  })
  process.on('unhandledRejection', (reason) => {
    log('REJECT', [reason])
  })
}

console.log('node up', process.version, process.platform, process.arch)
console.log('DSH_HOME =', DSH_HOME)
console.log('phase =', PHASE)
console.log('execArgv =', JSON.stringify(process.execArgv))

if (PHASE === '1') {
  // Engine milestone reached; keep the process alive so the shell can observe it.
  setInterval(() => {}, 1 << 30)
} else if (PHASE === '2') {
  // Import a real dsh core package through the bundled node_modules.
  try {
    const { resolveDshHome } = await import('@deepseek-ai/dsh-home-paths')
    console.log('dsh core import OK — resolveDshHome =', resolveDshHome)
  } catch (err) {
    console.error('dsh core import FAILED:', err?.stack ?? err)
    process.exit(1)
  }
  setInterval(() => {}, 1 << 30)
} else if (PHASE === '3') {
  const { bootWeb } = await import('./boot-web.js')
  await bootWeb(DSH_HOME)
}
