#!/bin/bash
# prepare-dsh-dist.sh -- assemble the dsh runnable payload for iOS.
#
#  1. In the dsh repo: pnpm install + pnpm run build (lib/ for every package,
#     dist/ for the web frontend). All dependency installation and building
#     happens HERE on the Mac -- nothing ever installs on the device.
#  2. pnpm deploy --prod pulls a self-contained node_modules for the dsh CLI
#     package. Workspace packages are physically INJECTED (no links back into
#     the checkout), so the payload is self-contained; internal store links are
#     relative and survive any location.
#  3. Layout repairs (all validated by the desktop smoke test):
#     a. peer-only workspace packages that pnpm deploy drops are copied into
#        the .pnpm/node_modules/@deepseek-ai peer area (cordis-plugin-group,
#        dsh-fs, dsh-sandbox, dsh-shell, ... -- 19 packages).
#     b. the top-level node_modules/@deepseek-ai is rebuilt with one link per
#        @deepseek-ai package, mirroring a pnpm workspace root -- required for
#        healProfilesModuleFallback's closure walk (createRequire.resolve.paths
#        does not realpath symlinks).
#     c. native addons that cannot exist on iOS are replaced by pure-JS stubs:
#        node-addon-require-builtin (shim), node-pty (used by dsh-subprocess-local),
#        sharp (used by dsh-attachment-local). All three are only called lazily.
#  4. The tree is copied with symlinks preserved (cp -a) -- the standard layout
#     nodejs-mobile apps ship (Xcode folder references preserve symlinks).
#
# Usage:
#   scripts/prepare-dsh-dist.sh [dsh-repo] [out-dir]
#     dsh-repo : path to the deepseek-harness checkout (default ~/deepseek-harness)
#     out-dir  : where nodejs-project/ is written (default ios-app/nodejs-project)

set -euo pipefail

# Resolve the script's own directory ONCE, before any cd, so later relative
# lookups (TPL_DIR below runs after `cd "$STAGE"`) cannot break.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REPO="${1:-$HOME/deepseek-harness}"
OUT="${2:-$SCRIPT_DIR/../ios-app/nodejs-project}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dsh-dist.XXXXXX")"

echo "==> dsh repo : $REPO"
echo "==> out dir  : $OUT"

[ -f "$REPO/package.json" ] || { echo "no dsh repo at $REPO" >&2; exit 1; }

cd "$REPO"

# -- 0. patch Unicode XID regexes for the iOS V8 ------------------------------
# The ios nodejs-mobile runtime is built with --with-intl=none, so V8 does not
# support \p{XID_Start}/\p{XID_Continue}: compiling them throws
# "Invalid property name in character class" when the web bundle imports
# packages/core/tools (py-types.ts), which fails every cordis loader entry.
# dsh only uses ASCII identifiers, so an ASCII-safe equivalent is equivalent.
python3 - <<'PY'
import os
p = 'packages/core/tools/src/py-types.ts'
if os.path.exists(p):
    s = open(p, encoding='utf-8').read()
    s = s.replace(r'/^[\p{XID_Start}_]\p{XID_Continue}*$/u', r'/^[A-Za-z_][A-Za-z0-9_]*$/u')
    s = s.replace(r'/[^\p{XID_Continue}]+|_+/u', r'/[^A-Za-z0-9_]+|_+/u')
    s = s.replace(r'/^\p{XID_Start}/u', r'/^[A-Za-z_]/u')
    open(p, 'w', encoding='utf-8').write(s)
    print('patched py-types.ts XID regexes (ASCII-safe)')
PY

# -- 0b. pnpm 11 deploy compatibility ----------------------------------------
# pnpm >=11 ships a new deploy engine that fails on this workspace
# ("Deployment with a shared lockfile has failed") unless the legacy deploy
# path is forced. Add the flag if the workspace does not set it yet. (The Mac
# session's pnpm 11.7.0 used the legacy path, so this preserves that behavior.)
WS_YAML="$REPO/pnpm-workspace.yaml"
if [ -f "$WS_YAML" ] && ! grep -q '^forceLegacyDeploy:' "$WS_YAML"; then
  printf 'forceLegacyDeploy: true\n' >> "$WS_YAML"
  echo "==> added forceLegacyDeploy: true to pnpm-workspace.yaml"
fi

# -- 1. install + build (Mac only) ------------------------------------------
if [ ! -d node_modules ]; then
  echo "==> pnpm install"
  pnpm install --frozen-lockfile
fi
echo "==> pnpm run build (lib/ for all packages, dist/ for the web frontend)"
pnpm run build

# -- 2. self-contained production node_modules ------------------------------
# --config.inject-workspace-packages=true makes pnpm physically copy the
# workspace packages into the deploy instead of leaving links to the checkout.
echo "==> pnpm deploy --prod @deepseek-ai/dsh -> $STAGE"
rm -rf "$STAGE"
pnpm --filter @deepseek-ai/dsh deploy --prod --config.inject-workspace-packages=true "$STAGE"

# sanity checks moved BELOW the layout repairs: pnpm 11's legacy deploy (forced
# via forceLegacyDeploy) drops some transitive workspace packages (e.g.
# @deepseek-ai/dsh-web-frontend) that step 3 restores from the checkout.

# -- 3. layout repairs ------------------------------------------------------
cd "$STAGE"
export DSH_REPO="$REPO"
python3 - <<'PYEOF'
import os, glob, json, shutil, subprocess

REPO = os.environ['DSH_REPO']
NM = 'node_modules'

# 3a. peer-only workspace packages dropped by deploy -> copy into the peer area
peer_area = os.path.join(NM, '.pnpm', 'node_modules', '@deepseek-ai')
name2dir = {}
for pj in glob.glob(os.path.join(REPO, 'packages/*/*/package.json')) + \
          glob.glob(os.path.join(REPO, 'vendor/*/package.json')) + \
          glob.glob(os.path.join(REPO, 'apps/*/package.json')) + \
          glob.glob(os.path.join(REPO, 'native/*/package.json')):
    try:
        p = json.load(open(pj))
    except Exception:
        continue
    if p.get('name', '').startswith('@deepseek-ai/'):
        name2dir[p['name']] = os.path.dirname(pj)

# every @deepseek-ai name referenced anywhere in the deployed tree
referenced = set()
for root, dirs, files in os.walk(NM):
    if 'package.json' not in files:
        continue
    try:
        p = json.load(open(os.path.join(root, 'package.json')))
    except Exception:
        continue
    for key in ('dependencies', 'peerDependencies', 'optionalDependencies'):
        for dep in (p.get(key) or {}):
            if dep.startswith('@deepseek-ai/'):
                referenced.add(dep)

# authority scan: pnpm's legacy deploy STRIPS workspace deps from deployed
# manifests (e.g. vendored cordis loses @deepseek-ai/cosmokit), so the walk
# above misses them. BFS over the SOURCE manifests starting from every
# @deepseek-ai package present in the deployed tree, unioning their deps.
present = set()
for root, dirs, files in os.walk(NM):
    if 'package.json' not in files:
        continue
    try:
        p = json.load(open(os.path.join(root, 'package.json')))
    except Exception:
        continue
    name = p.get('name')
    if name and name.startswith('@deepseek-ai/'):
        present.add(name)

queue = sorted(present)
seen = set(present)
while queue:
    name = queue.pop(0)
    src = name2dir.get(name)
    if not src:
        continue
    try:
        p = json.load(open(os.path.join(src, 'package.json')))
    except Exception:
        continue
    for key in ('dependencies', 'peerDependencies', 'optionalDependencies'):
        for dep in (p.get(key) or {}):
            if not dep.startswith('@deepseek-ai/') or dep in seen:
                continue
            seen.add(dep)
            referenced.add(dep)
            queue.append(dep)

for name in sorted(referenced):
    short = name.split('/')[1]
    dst = os.path.join(peer_area, short)
    if os.path.islink(dst):
        # deploy links peer entries into the checkout with relative targets
        # (e.g. ../../../../../../home/runner/deepseek-harness/...). Those are
        # valid at the stage path but DANGLE after `cp -a` moves the payload to
        # a different depth — replace every peer-area symlink with a real copy.
        print("replace peer symlink:", name)
        os.unlink(dst)
    if os.path.exists(dst):
        continue
    src = name2dir.get(name)
    if not src:
        print("WARN: missing from repo:", name)
        continue
    os.makedirs(dst, exist_ok=True)
    for item in ('lib', 'dist', 'package.json', 'cordis.patch.yml', 'config'):
        s = os.path.join(src, item)
        if os.path.exists(s):
            d = os.path.join(dst, item)
            if os.path.isdir(s):
                shutil.copytree(s, d, symlinks=True)
            else:
                shutil.copy2(s, d)
    print("peer copy:", name)

# 3b. rebuild top-level node_modules/@deepseek-ai: one link per real package
real = {}
for pj in glob.glob(os.path.join(NM, '.pnpm', '@deepseek-ai+*', 'node_modules', '@deepseek-ai', '*', 'package.json')):
    name = json.load(open(pj)).get('name')
    if name:
        real[name] = os.path.dirname(pj)
for pj in glob.glob(os.path.join(peer_area, '*', 'package.json')):
    name = json.load(open(pj)).get('name')
    if name and name not in real:
        real[name] = os.path.dirname(pj)

top = os.path.join(NM, '@deepseek-ai')
os.makedirs(top, exist_ok=True)
for entry in os.listdir(top):
    p = os.path.join(top, entry)
    if os.path.islink(p):
        os.unlink(p)
    else:
        shutil.rmtree(p, ignore_errors=True)
for name, target in real.items():
    os.symlink(os.path.relpath(target, top), os.path.join(top, name.split('/')[1]))
print("top-level @deepseek-ai links:", len(real))

# 3c. dereference symlinks that ESCAPE the payload. pnpm links workspace deps
# (schemastery, cosmokit, ...) into the store with absolute/relative chains
# into the checkout. They are valid while the checkout exists (the Linux smoke
# test), but iOS installd rejects them when they are inside the app bundle.
# Replace every symlink whose resolved target leaves the payload with a real
# copy of its target.
stage_real = os.path.realpath('.')
deref = 0
for root, dirs, files in os.walk('.'):
    for name in list(dirs) + list(files):
        p = os.path.join(root, name)
        if not os.path.islink(p):
            continue
        target = os.path.realpath(p)
        if target.startswith(stage_real):
            continue
        print("deref escapee:", p)
        os.unlink(p)
        if os.path.isdir(target):
            shutil.copytree(target, p, symlinks=True)
        elif os.path.isfile(target):
            shutil.copy2(target, p)
        deref += 1
print("deref escapee links:", deref)
PYEOF

# sanity (post-repair): the bundle/profile packages and the web UI must be present
for pkg in @deepseek-ai/dsh-base @deepseek-ai/dsh-web-app \
           @deepseek-ai/dsh-web-frontend @deepseek-ai/dsh-app-boot \
           @deepseek-ai/cordis-plugin-loader @deepseek-ai/dsh-cmdline; do
  if [ ! -f "$STAGE/node_modules/$pkg/package.json" ]; then
    echo "missing $pkg in payload after repairs" >&2
    exit 1
  fi
done
find "$STAGE" -name index.html -path "*dsh-web-frontend*" | grep -q . \
  || { echo "web frontend dist missing after repairs" >&2; exit 1; }

# 3c. native-addon stubs
echo "==> installing pure-JS stubs (node-addon-require-builtin, node-pty, sharp)"
rm -rf "$STAGE/node_modules/node-addon-require-builtin"
mkdir -p "$STAGE/node_modules/node-addon-require-builtin"
cat > "$STAGE/node_modules/node-addon-require-builtin/package.json" <<'PKG'
{
  "name": "node-addon-require-builtin",
  "version": "0.0.0-ios-shim",
  "description": "Pure-JS iOS shim: load Node internal modules via getBuiltinModule/createRequire",
  "main": "index.js",
  "type": "commonjs",
  "license": "MIT"
}
PKG
cat > "$STAGE/node_modules/node-addon-require-builtin/index.js" <<'SHIM'
exports.requireBuiltin = (id) =>
  process.getBuiltinModule?.(id) ?? require('node:module').createRequire(__filename)(id.startsWith('node:') ? id : 'node:' + id)
SHIM

NPTY=$(find "$STAGE/node_modules/.pnpm" -maxdepth 1 -type d -name 'node-pty*' | head -1)
if [ -n "$NPTY" ]; then
  NPTY="$NPTY/node_modules/node-pty"
  cat > "$NPTY/index.js" <<'PTY'
// Pure-JS iOS shim for node-pty (native addon unavailable on iOS).
'use strict'
const e = () => { throw new Error('node-pty is not available on iOS (native addon)') }
exports.spawn = e
exports.fork = e
exports.open = e
exports.IPty = class {}
exports.IWindowsPty = class {}
PTY
  cat > "$NPTY/package.json" <<'PTY'
{"name":"node-pty","version":"1.1.0-ios-shim","main":"index.js","license":"MIT"}
PTY
fi

# sharp: rewrite package.json main/exports to a platform-gated stub. The shipped
# sharp has main->./dist/index.cjs and exports->./dist/index.mjs: writing a
# bare index.js (the old approach) never redirected the loader. Rewriting the
# package.json so both import and require hit the stub makes `import sharp
# from 'sharp'` (attachment-local/image.ts) resolve without touching libvips.
# The same payload ships to Linux (smoke) and iOS, so on non-iOS the stub
# delegates to the REAL sharp; only on iOS does it return the inert stub.
SHARP=$(find "$STAGE/node_modules/.pnpm" -maxdepth 1 -type d -name 'sharp@*' | head -1)
if [ -n "$SHARP" ]; then
  SHARP="$SHARP/node_modules/sharp"
  cat > "$SHARP/ios-shim.cjs" <<'SHARP'
// Platform-gated iOS shim for sharp (native addon unavailable on iOS).
'use strict'
const { createRequire } = require('node:module')
function die() { throw new Error('sharp is not available on iOS (native addon)') }
const isIOS = process.platform === 'ios'
const real = isIOS ? null : createRequire(__filename)('./dist/index.cjs')
const sharp = isIOS
  ? (function () { const f = die; f.format = {}; f.versions = {}; f.available = {}; f.cache = () => f; return f })()
  : real
module.exports = sharp
module.exports.default = sharp
module.exports.format = sharp.format
module.exports.versions = sharp.versions
module.exports.available = sharp.available
module.exports.cache = sharp.cache
SHARP
  cat > "$SHARP/ios-shim.mjs" <<'SHARP'
// Platform-gated iOS shim for sharp (native addon unavailable on iOS).
import { createRequire } from 'node:module'
function die() { throw new Error('sharp is not available on iOS (native addon)') }
const isIOS = process.platform === 'ios'
const real = isIOS ? null : createRequire(import.meta.url)('./dist/index.cjs')
const sharp = isIOS
  ? (function () { const f = die; f.format = {}; f.versions = {}; f.available = {}; f.cache = () => f; return f })()
  : real
export default sharp
export const format = sharp.format
export const versions = sharp.versions
export const available = sharp.available
export const cache = sharp.cache
SHARP
  python3 - "$SHARP/package.json" <<'PYJSON'
import json, sys
p = sys.argv[1]
j = json.load(open(p, encoding='utf-8'))
j['main'] = './ios-shim.cjs'
j['module'] = './ios-shim.mjs'
j['exports'] = {
  '.': {
    'import': { 'types': './ios-shim.mjs', 'default': './ios-shim.mjs' },
    'require': { 'types': './ios-shim.cjs', 'default': './ios-shim.cjs' },
  },
}
json.dump(j, open(p, 'w', encoding='utf-8'), indent=2)
PYJSON
  echo "==> sharp gated stub (returns real sharp off-iOS, inert on iOS)"
fi

# koffi: native FFI module (used by dsh-sandbox-windows-acl). sandbox-local
# imports @deepseek-ai/dsh-sandbox-windows-acl, whose ffi.js runs
# koffi.pointer()/koffi.struct() AND asserts struct sizes at module top-level
# STARTUPINFOW must be 104, PROCESS_INFORMATION 24. On iOS the win32 runner is
# never invoked, so the stub only needs import-time descriptor calls.
#
# The same payload ships to Linux (smoke) and iOS, so the stub must NOT degrade
# Linux: on non-iOS it delegates to the REAL koffi; only on iOS does it return
# the inert FFI stub (with the exact asserted sizes so the import assertions,
# which run unconditionally, pass).
KOFFI=$(find "$STAGE/node_modules/.pnpm" -maxdepth 1 -type d -name 'koffi@*' | head -1)
if [ -n "$KOFFI" ]; then
  KOFFI="$KOFFI/node_modules/koffi"
  cat > "$KOFFI/ios-shim.js" <<'KOFFI'
// Platform-gated iOS shim for koffi (native FFI addon unavailable on iOS).
import { createRequire } from 'node:module'
// dsh-sandbox-windows-acl asserts these sizes at import; on iOS the inert stub
// must still satisfy them so the module imports (the win32 runner is never
// reached on darwin's seatbelt chain).
function _pointer(type) { return { type } }
function _struct(name, fields) {
  const size = name === 'STARTUPINFOW' ? 104 : name === 'PROCESS_INFORMATION' ? 24 : 8
  return { name, fields, size, pointer: () => _pointer(this) }
}
function die() { throw new Error('koffi is not available on iOS (native FFI addon)') }
const IOS_STUB = {
  pointer: _pointer,
  struct: _struct,
  load: die, call: die, decode: die, encode: die, alloc: die, address: die,
  proto: die, register: die, unregister: die, sizeof: () => 8, view: die, free: die,
}
const IS_IOS = process.platform === 'ios'
const koffi = IS_IOS ? IOS_STUB : createRequire(import.meta.url)('./src/koffi/index.cjs')
export default koffi
export const pointer = koffi.pointer
export const struct = koffi.struct
export const load = koffi.load
export const call = koffi.call
export const decode = koffi.decode
export const encode = koffi.encode
export const alloc = koffi.alloc
export const address = koffi.address
export const proto = koffi.proto
export const register = koffi.register
export const unregister = koffi.unregister
export const sizeof = koffi.sizeof
export const view = koffi.view
export const free = koffi.free
KOFFI
  python3 - "$KOFFI/package.json" <<'PYJSON'
import json, sys
p = sys.argv[1]
j = json.load(open(p, encoding='utf-8'))
j['main'] = './ios-shim.js'
j['exports'] = { '.': { 'types': './ios-shim.js', 'default': './ios-shim.js' } }
json.dump(j, open(p, 'w', encoding='utf-8'), indent=2)
PYJSON
  echo "==> koffi gated stub (returns real koffi off-iOS, inert FFI on iOS)"
fi

# zstd: Node 22.9 (nodejs-mobile) builds node:zlib WITHOUT the zstd family
# (zstdCompress/zstdDecompress/createZstdDecompress/... were added later).
# session-persistence-jsonl's bundled lib/index.js imports them at top level,
# which throws at import time -> the whole cordis include apply fails. Make
# the zlib access lazy so the module imports cleanly and only the zstd path
# (never taken on iOS, where compression is 'none') resolves zlib.
#
# The .pnpm store may hold multiple hardlinked copies of the package (the peer
# layout plus the store), and the loader resolves whichever path the app uses.
# Walk the WHOLE staging tree and patch EVERY session-persistence-jsonl
# lib/index.js so no unpatched copy survives. Fail loud if none is found —
# a silent no-op is why the iOS import regressed.
python3 - "$STAGE" <<'PYZSTD'
import os, sys, re
stage = sys.argv[1]
# Match BOTH layouts the deployed payload can hold:
#   (.pnpm store)   node_modules/.pnpm/@deepseek-ai+dsh-session-persistence-jsonl@.../node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js
#   (peer area)     node_modules/.pnpm/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js
# The loader resolves the package through its node_modules path, which is the
# peer-area copy for the repaired layout (prepare-dsh-dist.sh step 3a) — the
# .pnpm store copy is a different hardlink. Patch EVERY copy.
patched = []
for root, dirs, files in os.walk(stage, followlinks=False):
    # Match the PACKAGE directory (basename), not its lib/ subdir (which would
    # double the 'lib' segment in the join below).
    if os.path.basename(root) != 'dsh-session-persistence-jsonl':
        continue
    idx = os.path.join(root, 'lib', 'index.js')
    if not os.path.exists(idx):
        continue
    s = open(idx, encoding='utf-8').read()
    # Replace the top-level named zlib zstd import with a lazily-resolved holder.
    #
    # Original (bundled):
    #   import { constants, createZstdDecompress, zstdCompress, zstdDecompress, zstdDecompressSync } from "node:zlib";
    # The loader evaluates ESM top-level imports eagerly, so a missing named
    # export from a builtin fails immediately. Replace with a guarded getter.
    pat = re.compile(
        r'import\s*\{\s*constants\s*,\s*createZstdDecompress\s*,\s*zstdCompress\s*,\s*zstdDecompress\s*,\s*zstdDecompressSync\s*\}\s*from\s*["\']node:zlib["\'];',
        re.S,
    )
    repl = (
        '// iOS shim: node:zlib on Node 22.9 has no zstd family; resolve lazily.\n'
        'const __zlib = (() => { try { return process.getBuiltinModule?.("node:zlib") ?? null } catch { return null } })();\n'
        'const constants = __zlib?.constants ?? {};\n'
        'const createZstdDecompress = __zlib?.createZstdDecompress;\n'
        'const zstdCompress = __zlib?.zstdCompress;\n'
        'const zstdDecompress = __zlib?.zstdDecompress;\n'
        'const zstdDecompressSync = __zlib?.zstdDecompressSync;\n'
    )
    new_s, n = pat.subn(repl, s, count=1)
    if n == 1:
        s = new_s
    # Guard the top-level promisify/constants block. On Node 22.9 zstdCompress
    # / zstdDecompress are undefined and constants.ZSTD_* are undefined, so
    # `promisify(undefined)` and `constants.ZSTD_c_checksumFlag` would throw at
    # module load. Make them lazy: the async lambdas resolve on first use (the
    # zstd path is never taken on iOS, where compression is 'none').
    lazy_block = re.compile(
        r'const zstdCompressAsync = promisify\(zstdCompress\);\s*\n\s*const zstdDecompressAsync = promisify\(zstdDecompress\);\s*\n\s*const CHECKSUM_OPTIONS = \{ params: \{ \[constants\.ZSTD_c_checksumFlag\]: 1 \} \};\s*\n\s*const INCOMPLETE_FRAME_OPTIONS = \{ finishFlush: constants\.ZSTD_e_flush \};',
        re.S,
    )
    lazy_repl = (
        'const zstdCompressAsync = (input, opts) => (zstdCompress ? promisify(zstdCompress)(input, opts) : Promise.reject(new Error("zstd unavailable on iOS")));\n'
        'const zstdDecompressAsync = (input, opts) => (zstdDecompress ? promisify(zstdDecompress)(input, opts) : Promise.reject(new Error("zstd unavailable on iOS")));\n'
        'const CHECKSUM_OPTIONS = { params: { [constants?.ZSTD_c_checksumFlag ?? 1]: 1 } };\n'
        'const INCOMPLETE_FRAME_OPTIONS = { finishFlush: constants?.ZSTD_e_flush ?? 0 };\n'
    )
    new_s, n2 = lazy_block.subn(lazy_repl, s, count=1)
    if n2 == 1:
        s = new_s
    if n == 1 or n2 == 1:
        open(idx, 'w', encoding='utf-8').write(s)
        patched.append(idx)
        print(f'patched zstd import/init: {idx}')
if not patched:
    print('FATAL: no session-persistence-jsonl lib/index.js patched (layout changed?)', file=sys.stderr)
    sys.exit(1)
print(f'patched {len(patched)} session-persistence-jsonl copy(ies)')
PYZSTD

# 3e. shorten OVER-LONG `.pnpm/<store>` directory names. This runs AFTER the
# native-addon stubs (node-pty/sharp/koffi) and the zstd patch so those find
# their packages by their original store names first. installd on iOS caps
# path length (~255 chars); pnpm stores carry the full package identity in the
# store dir name (e.g. `@deepseek-ai+dsh-client-ui-trajectory@file+packages+...`
# can reach 120 chars), so a deep bundled path exceeds the cap and installd
# rejects the bundle with 0xe8008017 ("A signed resource has been added,
# modified, or deleted"). Shorten any store basename longer than LIMIT to a
# short `p-<sha1-12>` and rewrite every symlink target + `.modules.yaml` key
# that references the old name. Package contents and the store -> node_modules
# -> pkg structure are untouched; Node resolves symlinks at runtime, so the
# rename never changes what a package resolves to.
python3 - "$STAGE" <<'PYREPATH'
import os, hashlib, sys
stage = sys.argv[1]
# Shorten every .pnpm store basename longer than 40 chars. A store as short as
# 52 chars (e.g. '@mistralai+mistralai@2.2.6_@opentelemetry+api@1.9.0') is still
# enough, combined with the package's deep lib/ path, to push a bundled path to
# 267 chars — over installd's ~255 cap (which yields 0xe8008017). LIMIT=40
# shortens the 29 longest stores and brings the worst path to 232, safely under.
LIMIT = 40
_pnpm = os.path.join(stage, 'node_modules', '.pnpm')
_old_to_new = {}
for _name in os.listdir(_pnpm):
    if _name == 'node_modules':
        continue
    if len(_name) > LIMIT:
        _h = hashlib.sha1(_name.encode('utf-8')).hexdigest()[:12]
        _new = 'p-' + _h
        _old_to_new[_name] = _new
if not _old_to_new:
    print("no over-long .pnpm store names (all <= %d)" % LIMIT)
    sys.exit(0)
for _old, _new in _old_to_new.items():
    _src = os.path.join(_pnpm, _old)
    _dst = os.path.join(_pnpm, _new)
    if os.path.exists(_dst):
        continue
    os.rename(_src, _dst)
# rewrite symlink targets (relative targets carry the store basename)
_links = 0
for _root, _dirs, _files in os.walk(stage, followlinks=False):
    for _n in _dirs + _files:
        _p = os.path.join(_root, _n)
        if not os.path.islink(_p):
            continue
        _t = os.readlink(_p)
        _nt = _t
        for _old, _new in _old_to_new.items():
            if _old in _nt:
                _nt = _nt.replace(_old, _new)
        if _nt != _t:
            os.unlink(_p)
            os.symlink(_nt, _p)
            _links += 1
print("shortened .pnpm store names:", len(_old_to_new), "links rewritten:", _links)
# rewrite .modules.yaml hoistedDependencies keys (they embed the long names)
_my = os.path.join(stage, 'node_modules', '.modules.yaml')
if os.path.exists(_my):
    _s = open(_my, encoding='utf-8').read()
    _o = _s
    for _old, _new in _old_to_new.items():
        _s = _s.replace(_old, _new)
    if _s != _o:
        open(_my, 'w', encoding='utf-8').write(_s)
PYREPATH

# -- 4. copy into the app (symlinks preserved) ------------------------------
TPL_DIR="$SCRIPT_DIR/../ios-app/nodejs-project"
cp "$TPL_DIR/main.js" "$TPL_DIR/boot-web.js" "$STAGE/"
cd /
echo "==> copying to $OUT"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -a "$STAGE" "$OUT"

echo "==> nodejs-project ready: $OUT"
du -sh "$OUT"
