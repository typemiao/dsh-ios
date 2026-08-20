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

# -- 0. pnpm 11 deploy compatibility -----------------------------------------
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
    if os.path.exists(dst) or os.path.islink(dst):
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

SHARP=$(find "$STAGE/node_modules/.pnpm" -maxdepth 1 -type d -name 'sharp@*' | head -1)
if [ -n "$SHARP" ]; then
  SHARP="$SHARP/node_modules/sharp"
  cat > "$SHARP/index.js" <<'SHARP'
// Pure-JS iOS shim for sharp (native addon unavailable on iOS).
'use strict'
function sharp() {
  throw new Error('sharp is not available on iOS (native addon)')
}
sharp.format = {}
sharp.versions = {}
sharp.available = {}
module.exports = sharp
module.exports.default = sharp
SHARP
fi

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
