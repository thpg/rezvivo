"""Local allowlist/privacy/secret checks. No uploads and no automatic publishing."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BLOCKED_SUFFIXES = {'.exe', '.dll', '.dbg', '.ppu', '.o', '.a', '.res', '.rsp',
                    '.fit', '.gpx', '.tcx', '.db', '.sqlite', '.sqlite3', '.log',
                    '.pem', '.key', '.p12', '.pfx', '.blend', '.bak', '.zip', '.7z', '.apk', '.aab', '.keystore', '.jks'}
BLOCKED_PARTS = {'users', 'profiles', 'cache', 'logs', 'crash-reports', '.ssh',
                 'node_modules', 'castle-engine-output', '__pycache__'}
TEXT_SUFFIXES = {'.pas', '.inc', '.dpr', '.py', '.ps1', '.json', '.xml', '.x3d', '.ini', '.cfg', '.toml', '.sh', '.bat',
                 '.txt', '.md', '.patch', '.yml', '.glsl', '.vert', '.frag', '.zwo',
                 '.castle-user-interface', '.cpp', '.c', '.h', '.hpp', '.comp', '.java', '.gradle'}
# Matches identify locations only. Never print matched values.
RULES = {
    'private-key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    'user-home-path': re.compile(r'(?i)(?:[a-z]:[\\/]+Users[\\/]+(?![<%$])[^\\/\s"<>]+|/ho' r'me/(?![<%$])[^/\s"<>]+)'),
    'developer-project-path': re.compile(r'(?i)[a-z]:[\\/]+(?:Projects|CGE|lazarus\d*)[\\/]'),
    'url-password': re.compile(r'''https?://[^/\s"'<>:@]+:[^/\s"'<>@]+@'''),
    'cloud-access-key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'github-token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b'),
}


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def tracked_files():
    git = shutil.which('git')
    if not git or not (ROOT/'.git').exists():
        raise SystemExit('Run git init first; checks inspect tracked and nonignored untracked files')
    raw = subprocess.check_output([git, '-C', str(ROOT), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'])
    return sorted(set(p.decode('utf-8') for p in raw.split(b'\0') if p))


def metadata_parts(path):
    """Extract GLB JSON and image ancillary metadata without scanning pixel bytes."""
    raw = path.read_bytes()
    if path.suffix.lower() == '.glb':
        if len(raw) < 20 or raw[:4] != b'glTF' or struct.unpack_from('<I', raw, 8)[0] != len(raw):
            raise ValueError('Invalid GLB')
        pos = 12; doc = None; binary = b''
        while pos+8 <= len(raw):
            size, kind = struct.unpack_from('<II', raw, pos); pos += 8
            data = raw[pos:pos+size]; pos += size
            if len(data) != size: raise ValueError('Truncated GLB chunk')
            if kind == 0x4e4f534a:
                yield 'glb-json', data
                doc = json.loads(data)
            elif kind == 0x004e4942: binary = data
        if doc:
            for i, img in enumerate(doc.get('images', [])):
                data = b''
                if 'bufferView' in img:
                    view = doc['bufferViews'][img['bufferView']]
                    start = view.get('byteOffset', 0)
                    data = binary[start:start+view['byteLength']]
                elif img.get('uri', '').startswith('data:'):
                    data = base64.b64decode(img['uri'].split(',', 1)[1])
                yield from image_metadata(data, 'glb-image-'+str(i))
    else:
        yield from image_metadata(raw, 'image')


def image_metadata(raw, label):
    if raw.startswith(b'\x89PNG\r\n\x1a\n'):
        pos = 8
        while pos+12 <= len(raw):
            size = struct.unpack_from('>I', raw, pos)[0]; kind = raw[pos+4:pos+8]
            data = raw[pos+8:pos+8+size]; pos += size+12
            if kind in (b'tEXt', b'zTXt', b'iTXt', b'eXIf'):
                if kind == b'zTXt':
                    import zlib
                    data = zlib.decompress(data.split(b'\0', 1)[1][1:])
                elif kind == b'iTXt':
                    keyword, rest = data.split(b'\0', 1)
                    flag, method = rest[:2]; language, translated, payload = rest[2:].split(b'\0', 2)
                    if flag:
                        import zlib
                        payload = zlib.decompress(payload)
                    data = keyword+b'\0'+payload
                yield label+'-'+kind.decode(), data
            if kind == b'IEND': break
    elif raw.startswith(b'\xff\xd8'):
        pos = 2
        while pos+4 <= len(raw) and raw[pos] == 255:
            kind = raw[pos+1]; pos += 2
            if kind in (0xda, 0xd9): break
            if kind in (0x00, 0x01) or 0xd0 <= kind <= 0xd7: continue
            size = struct.unpack_from('>H', raw, pos)[0]
            if size < 2: raise ValueError('Invalid JPEG metadata')
            if kind in (0xe1, 0xec, 0xed, 0xfe): yield label+'-jpeg-metadata', raw[pos+2:pos+size]
            pos += size


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--gitleaks', default=os.environ.get('GITLEAKS', 'gitleaks'))
    ap.add_argument('--release', action='store_true', help='Also require resolved redistribution/provenance issues')
    args = ap.parse_args()
    allowed = set(json.loads((ROOT/'dependencies/files.json').read_text()))
    files = tracked_files(); errors = []; metadata = []; text_bytes = 0
    assets = json.loads((ROOT/'dependencies/assets.json').read_text())
    asset_paths = {row['path'] for row in assets}

    def check_text(rel, label, raw):
        nonlocal text_bytes
        text_bytes += len(raw)
        text = raw.decode('utf-8', errors='replace')
        for rule, regex in RULES.items():
            for match in regex.finditer(text):
                errors.append(f'{rel}:{text[:match.start()].count(chr(10))+1}: {label}/{rule}')

    for rel in files:
        p = ROOT/rel; lower = {s.lower() for s in p.relative_to(ROOT).parts}
        if rel not in allowed: errors.append(rel+': not in reviewed file allowlist')
        if p.is_symlink() or ROOT not in p.resolve().parents: errors.append(rel+': symlink/outside repository'); continue
        if p.suffix.lower() in BLOCKED_SUFFIXES or lower & BLOCKED_PARTS or p.name.startswith('.env'):
            errors.append(rel+': private/build file type')
        if rel.startswith('rezvivo-osm-bckl/data/') and rel not in asset_paths:
            errors.append(rel+': not in installer runtime manifest')
        if p.suffix.lower() in TEXT_SUFFIXES or p.name in ('LICENSE', '.gitignore', '.gitattributes'):
            check_text(rel, 'text', p.read_bytes())
        if p.suffix.lower() in ('.png', '.jpg', '.jpeg', '.glb'):
            try:
                for label, raw in metadata_parts(p):
                    check_text(rel, label, raw); metadata.append((rel, label, raw))
            except (ValueError, KeyError, IndexError, struct.error) as exc:
                errors.append(rel+': metadata parse failed ('+type(exc).__name__+')')
        if p.suffix == '.zwo' and ET.parse(p).findtext('author') != 'REZVIVO':
            errors.append(rel+': non-original workout')
    for rel in sorted(allowed-set(files)): errors.append(rel+': reviewed file missing or ignored')
    for row in assets:
        p = ROOT/row['path']
        if not p.is_file() or p.stat().st_size != row['bytes'] or sha(p) != row['sha256']:
            errors.append(row['path']+': runtime asset changed; review and update asset manifest')

    scanner = shutil.which(args.gitleaks) or (args.gitleaks if Path(args.gitleaks).is_file() else None)
    if not scanner: errors.append('Gitleaks is required; no complete secret scan was performed')
    else:
        scanner = str(Path(scanner).resolve())
        # Materialize only the reviewed publication inputs. Never scan or upload
        # private worktree caches, downloaded engines or compiler diagnostics.
        with tempfile.TemporaryDirectory(prefix='rezvivo-publication-') as tmp:
            tree = Path(tmp)/'input'; tree.mkdir()
            for rel in files:
                p = ROOT/rel
                if p.is_symlink() or not p.is_file(): continue
                dst = tree/rel; dst.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(p, dst)
            for i, (rel, label, raw) in enumerate(metadata):
                dst = tree/'.decoded-metadata'/f'{i:04d}.txt'
                dst.parent.mkdir(exist_ok=True); dst.write_bytes(raw)
            report = Path(tmp)/'findings.json'
            result = subprocess.run([scanner, 'dir', str(tree), '--redact=100', '--no-banner',
                                     '--report-format=json', '--report-path='+str(report)], capture_output=True)
            if result.returncode:
                if report.exists():
                    for finding in json.loads(report.read_text()):
                        # Only paths and rule IDs; do not print scanner source snippets.
                        errors.append(str(finding.get('File', '')).replace(str(tree), '<candidate>')+': gitleaks/'+finding.get('RuleID','unknown'))
                else: errors.append('Gitleaks failed; scan did not complete')
    if args.release:
        status = json.loads((ROOT/'dependencies/publication-status.json').read_text())
        errors += ['release: '+item['id'] for item in status['unresolved']]
        errors += [row['path']+': unresolved asset provenance' for row in assets if row['license']=='REVIEW']
    if errors:
        print('\n'.join(errors)); raise SystemExit(1)
    print(f'PASS: {len(files)} publication files; {len(assets)} runtime assets; {len(metadata)} decoded metadata blocks; {text_bytes} text bytes; Gitleaks clean.')
    if not args.release: print('Privacy check only. License/release readiness requires --release.')


if __name__ == '__main__':
    main()
