// bootstrap.js — install the signed single-file dsh payload into the writable
// app container, then boot it in-process. Uses Node builtins only.

import {
  chmodSync,
  closeSync,
  createReadStream,
  existsSync,
  linkSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readlinkSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
  writeSync,
  appendFileSync,
} from 'node:fs'
import { basename, dirname, isAbsolute, join, normalize, relative, resolve, sep } from 'node:path'
import { pathToFileURL } from 'node:url'
import { createGunzip } from 'node:zlib'

// Unconditional diagnostic probe: writes argv and the DSH_* env to DSH_PROBE so
// a device run that silently produces no node-console.log still tells us what
// node actually saw (which channel — argv or env — carried the config).
try {
  const probe = process.env.DSH_PROBE || join(process.env.HOME || '/tmp', 'dsh-bootstrap-probe.txt')
  appendFileSync(probe, 'argv=' + JSON.stringify(process.argv) + '\n')
  appendFileSync(probe, 'env=' + JSON.stringify({
    DSH_ARCHIVE: process.env.DSH_ARCHIVE, DSH_RUNTIME: process.env.DSH_RUNTIME,
    DSH_VERSION: process.env.DSH_VERSION, DSH_HOME: process.env.DSH_HOME,
    DSH_CONSOLE_LOG: process.env.DSH_CONSOLE_LOG, DSH_PHASE: process.env.DSH_PHASE,
    DSH_PROBE: process.env.DSH_PROBE, HOME: process.env.HOME,
  }) + '\n')
} catch (_) {}

// Config arrives via env vars (see NodeRunner.swift): position-independent, and
// avoids relying on process.argv[0] being "node" (nodejs-mobile makes it the
// script path). Legacy argv fallback kept for the Linux smoke test, which passes
// the same values as positional args.
const env = process.env
const ARCHIVE = env.DSH_ARCHIVE || process.argv[2] || ''
const RUNTIME = env.DSH_RUNTIME || process.argv[3] || ''
const VERSION = env.DSH_VERSION || process.argv[4] || ''
const DSH_HOME = env.DSH_HOME || process.argv[5] || ''
const CONSOLE_LOG = env.DSH_CONSOLE_LOG || process.argv[6] || ''
const PHASE = env.DSH_PHASE || process.argv[7] || '1'

function mirror(level, ...args) {
  const line = `[${new Date().toISOString()}] ${level} ${args.map(String).join(' ')}`
  try { if (CONSOLE_LOG) writeFileSync(CONSOLE_LOG, line + '\n', { flag: 'a' }) } catch {}
}

function fail(message) {
  throw new Error(`payload install: ${message}`)
}

function field(buffer, offset, length) {
  const end = buffer.indexOf(0, offset)
  return buffer.subarray(offset, end >= offset && end < offset + length ? end : offset + length).toString('utf8').trim()
}

function octal(buffer, offset, length) {
  const bytes = buffer.subarray(offset, offset + length)
  if ((bytes[0] & 0x80) !== 0) {
    let value = BigInt(bytes[0] & 0x7f)
    for (let i = 1; i < bytes.length; i++) value = (value << 8n) | BigInt(bytes[i])
    return Number(value)
  }
  const value = field(buffer, offset, length).replace(/\0.*$/, '').trim()
  return value ? Number.parseInt(value, 8) : 0
}

function safeRelative(raw) {
  const clean = raw.replaceAll('\\', '/').replace(/^\.\//, '').replace(/\/$/, '')
  if (!clean || isAbsolute(clean)) return clean
  const normalized = normalize(clean).replaceAll('\\', '/')
  if (normalized === '..' || normalized.startsWith('../') || normalized.includes('/../')) {
    fail(`unsafe archive path: ${raw}`)
  }
  return normalized
}

function destination(root, raw) {
  const rel = safeRelative(raw)
  const path = resolve(root, rel)
  if (path !== root && !path.startsWith(root + sep)) fail(`archive path escapes runtime: ${raw}`)
  return path
}

function parsePax(buffer) {
  const values = {}
  let offset = 0
  while (offset < buffer.length) {
    const space = buffer.indexOf(0x20, offset)
    if (space < 0) break
    const length = Number.parseInt(buffer.subarray(offset, space).toString('ascii'), 10)
    if (!Number.isFinite(length) || length <= 0 || offset + length > buffer.length) break
    const record = buffer.subarray(space + 1, offset + length - 1).toString('utf8')
    const equals = record.indexOf('=')
    if (equals > 0) values[record.slice(0, equals)] = record.slice(equals + 1)
    offset += length
  }
  return values
}

function removeIfPresent(path) {
  try { rmSync(path, { recursive: true, force: true }) } catch {}
}

async function extractTarGz(archive, root) {
  mkdirSync(root, { recursive: true })
  const stream = createReadStream(archive).pipe(createGunzip())
  let buffer = Buffer.alloc(0)
  let current = null
  let pax = {}
  let longPath = ''
  let longLink = ''
  const pendingHardlinks = []
  const pendingSymlinks = []

  function finish(entry) {
    if (entry.fd !== undefined) closeSync(entry.fd)
    if (entry.kind === 'pax') pax = { ...pax, ...parsePax(Buffer.concat(entry.parts)) }
    if (entry.kind === 'long-path') longPath = Buffer.concat(entry.parts).toString('utf8').replace(/\0.*$/, '')
    if (entry.kind === 'long-link') longLink = Buffer.concat(entry.parts).toString('utf8').replace(/\0.*$/, '')
    if (entry.path && entry.mode && entry.kind === 'file') chmodSync(entry.path, entry.mode & 0o777)
  }

  for await (const chunk of stream) {
    buffer = buffer.length ? Buffer.concat([buffer, chunk]) : chunk
    while (true) {
      if (current) {
        if (current.remaining > 0) {
          if (buffer.length === 0) break
          const count = Math.min(current.remaining, buffer.length)
          const slice = buffer.subarray(0, count)
          if (current.fd !== undefined) writeSync(current.fd, slice)
          if (current.parts) current.parts.push(Buffer.from(slice))
          buffer = buffer.subarray(count)
          current.remaining -= count
          if (current.remaining > 0) break
        }
        if (current.padding > 0) {
          if (buffer.length < current.padding) break
          buffer = buffer.subarray(current.padding)
          current.padding = 0
        }
        finish(current)
        current = null
        continue
      }

      if (buffer.length < 512) break
      const header = buffer.subarray(0, 512)
      buffer = buffer.subarray(512)
      if (header.every(byte => byte === 0)) {
        resolveHardlinks(root, pendingHardlinks)
        return resolveSymlinks(pendingSymlinks)
      }

      const prefix = field(header, 345, 155)
      const headerPath = [prefix, field(header, 0, 100)].filter(Boolean).join('/')
      const type = String.fromCharCode(header[156] || 0)
      const headerLink = field(header, 157, 100)
      const mode = octal(header, 100, 8)
      const headerSize = octal(header, 124, 12)
      const pathName = safeRelative(pax.path || longPath || headerPath)
      const linkName = pax.linkpath || longLink || headerLink
      const size = pax.size !== undefined ? Number.parseInt(pax.size, 10) : headerSize
      const padding = (512 - (size % 512)) % 512
      pax = {}
      longPath = ''
      longLink = ''

      if (type === 'x' || type === 'g' || type === 'L' || type === 'K') {
        current = {
          kind: type === 'L' ? 'long-path' : type === 'K' ? 'long-link' : 'pax',
          remaining: size,
          padding,
          parts: [],
        }
        continue
      }

      if (!pathName) continue
      const path = destination(root, pathName)
      mkdirSync(dirname(path), { recursive: true })
      if (type === '5') {
        mkdirSync(path, { recursive: true })
        if (mode) chmodSync(path, mode & 0o777)
        current = { kind: 'skip', remaining: size, padding }
      } else if (type === '2') {
        // Create symlinks only after all ordinary paths are written. That keeps
        // an archive symlink from redirecting a later write outside `root`.
        pendingSymlinks.push({ path, target: linkName })
        current = { kind: 'skip', remaining: size, padding }
      } else if (type === '1') {
        // Keep the raw linkname; resolveHardlinks re-anchors it to root and
        // retries until the target exists (it may appear later in the archive).
        pendingHardlinks.push({ path, target: linkName })
        current = { kind: 'skip', remaining: size, padding }
      } else if (type === '0' || type === '\0' || type === '7') {
        removeIfPresent(path)
        current = { kind: 'file', path, mode, remaining: size, padding, fd: openSync(path, 'w', mode & 0o777) }
      } else {
        current = { kind: 'skip', remaining: size, padding }
      }
    }
  }
  if (current) fail('truncated archive')
  // Order matters: create symlinks first so a later hardlink whose target is a
  // symlink resolves, then hardlinks (which may point at those symlinks).
  resolveSymlinks(pendingSymlinks)
  resolveHardlinks(root, pendingHardlinks)
}

function resolveHardlinks(root, pending) {
  // pnpm records a hardlink entry whose target may appear later in the archive,
  // and the linkname uses './'-relative or absolute-to-root form. Loop until no
  // progress. A hardlink whose TARGET is itself a symlink must NOT be created
  // with linkSync (Linux forbids hard-linking a symlink: EPERM) — recreate it
  // as an identical symlink instead, preserving the pnpm topology.
  let remaining = pending
  for (let pass = 0; pass < 10 && remaining.length > 0; pass++) {
    const deferred = []
    let progressed = false
    for (const { path, target } of remaining) {
      mkdirSync(dirname(path), { recursive: true })
      const resolved = destination(root, target)
      let stat
      try { stat = lstatSync(resolved) } catch { stat = null }
      if (stat) {
        removeIfPresent(path)
        if (stat.isSymbolicLink()) {
          symlinkSync(readlinkSync(resolved), path)
        } else if (stat.isDirectory()) {
          // A directory hardlink: copy the tree (no inode link on a dir).
          mkdirSync(path, { recursive: true })
        } else {
          linkSync(resolved, path)
        }
        progressed = true
      } else {
        deferred.push({ path, target })
      }
    }
    remaining = deferred
    if (!progressed) break
  }
  if (remaining.length > 0) {
    const { path, target } = remaining[0]
    fail(`hardlink target missing: ${relative(root, destination(root, target))} (for ${relative(root, path)})`)
  }
}

function resolveSymlinks(pending) {
  for (const { path, target } of pending) {
    mkdirSync(dirname(path), { recursive: true })
    removeIfPresent(path)
    symlinkSync(target, path)
  }
}

async function install() {
  if (!ARCHIVE || !RUNTIME || !VERSION) fail('missing archive/runtime/version argv')
  const marker = join(RUNTIME, '.complete')
  if (existsSync(marker) && readFileSync(marker, 'utf8').trim() === VERSION) return

  const parent = dirname(RUNTIME)
  const stage = `${RUNTIME}.stage-${process.pid}`
  mkdirSync(parent, { recursive: true })
  removeIfPresent(stage)
  removeIfPresent(RUNTIME)
  mirror('LOG', 'payload install: extracting', basename(ARCHIVE), 'to', stage)
  try {
    await extractTarGz(ARCHIVE, stage)
    for (const required of ['main.js', 'boot-web.js', 'package.json', 'node_modules']) {
      if (!existsSync(join(stage, required))) fail(`missing ${required} after extraction`)
    }
    writeFileSync(join(stage, '.complete'), VERSION + '\n')
    renameSync(stage, RUNTIME)
  } catch (error) {
    removeIfPresent(stage)
    throw error
  }
  mirror('LOG', 'payload install: complete', VERSION)
}

try {
  if (CONSOLE_LOG) writeFileSync(CONSOLE_LOG, '')
  await install()
  await import(pathToFileURL(join(RUNTIME, 'main.js')).href)
} catch (error) {
  mirror('FATAL', error?.stack ?? error)
  process.exit(1)
}
