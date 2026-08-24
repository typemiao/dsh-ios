#!/usr/bin/env python3
"""pack-payload.py — package a dsh payload dir into a single PAX-formatted tar.gz.

PAX_FORMAT writes every long pathname/linkname as a PAX 'x' record (path=/linkpath=),
which ios-app/bootstrap.js parses, so the whole pnpm tree (long store paths, symlinks,
hardlinks) survives inside one signed resource. GNU tar's L/K records are not emitted.

Usage: pack-payload.py <payload-dir> <out.tar.gz> <version-file>
"""
import tarfile, hashlib, sys, os

def main() -> int:
    if len(sys.argv) != 4:
        print('usage: pack-payload.py <payload-dir> <out.tar.gz> <version-file>', file=sys.stderr)
        return 2
    src, out, ver = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(os.path.dirname(os.path.abspath(out)) or '.', exist_ok=True)
    with tarfile.open(out, 'w:gz', format=tarfile.PAX_FORMAT, dereference=False) as tf:
        tf.add(src, arcname='.')
    digest = hashlib.sha256(open(out, 'rb').read()).hexdigest()[:16]
    with open(ver, 'w') as f:
        f.write(digest + '\n')
    print(f'packed {src} -> {out} ({os.path.getsize(out)} bytes), version {digest}')
    return 0

if __name__ == '__main__':
    sys.exit(main())
