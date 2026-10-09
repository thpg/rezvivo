"""Fetch and verify the pinned commit from REZVIVO's CGE fork."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--destination', type=Path, default=ROOT.parent/'rezvivo-dependencies/cge',
                    help='CGE checkout outside the publication repository by default')
    ap.add_argument('--verify-only', action='store_true')
    args = ap.parse_args()
    lock = json.loads((ROOT/'dependencies/engine.json').read_text())
    dest = args.destination.resolve()
    git = shutil.which('git')
    if not git:
        raise SystemExit('Git is required')

    def run(*parts):
        subprocess.run([git, '-C', str(dest), *parts], check=True)

    if not args.verify_only:
        if dest.exists():
            raise SystemExit('Destination already exists; use --verify-only or a new directory')
        dest.mkdir(parents=True)
        run('init')
        run('config', 'core.autocrlf', 'false')
        run('remote', 'add', 'origin', lock['repository'])
        run('sparse-checkout', 'init', '--cone')
        run('sparse-checkout', 'set', 'src', 'doc/licenses', 'tools', 'packages')
        run('fetch', '--depth=1', '--filter=blob:none', 'origin', lock['commit'])
        run('checkout', '--detach', 'FETCH_HEAD')
    head = subprocess.check_output([git, '-C', str(dest), 'rev-parse', 'HEAD'], text=True).strip()
    if head != lock['commit']:
        raise SystemExit('Engine commit does not match the lock file')
    for item in lock['modified_files']:
        data = (dest/item['path']).read_bytes().replace(b'\r\n', b'\n')
        if hashlib.sha256(data).hexdigest() != item['sha256_lf']:
            raise SystemExit('Engine source verification failed: '+item['path'])
    dirty = subprocess.check_output([git, '-C', str(dest), 'status', '--porcelain',
                                    '--untracked-files=no'], text=True).strip()
    if dirty:
        raise SystemExit('Engine checkout has local modifications')
    print('Verified CGE fork commit and', len(lock['modified_files']), 'modified sources')


if __name__ == '__main__':
    main()
