import hashlib
import json
import pathlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

tools = pathlib.Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(tools))
from installer_update import select_delta, components, installer_guards, validate_manifest

def item(path, value):
    return dict(path=path, bytes=len(value), sha256=hashlib.sha256(value).hexdigest())

class InstallerUpdateTests(unittest.TestCase):
    def test_unchanged_resources_and_owned_deletions(self):
        old = [item('REZVIVO.exe', b'old'), item('data/world.glb', b'unchanged'), item('data/obsolete.png', b'old')]
        new = [item('REZVIVO.exe', b'new-exe'), item('data/world.glb', b'unchanged'), item('data/new.png', b'new')]
        changed, removed = select_delta(new, old)
        self.assertEqual([v['path'] for v in changed], ['REZVIVO.exe', 'data/new.png'])
        self.assertEqual(removed, ['data/obsolete.png'])
        self.assertEqual(components(changed)['resource_bytes'], 3)

    def test_never_update_profiles_or_escape_directory(self):
        for path in ['../users/profile.json', 'users/profile.json', 'sessions/ride.csv', '/REZVIVO.exe', 'C:/REZVIVO.exe', 'data/../users/a', 'data\\..\\users\\a', 'data//a',
                     'data/*', 'data/a?.png', 'data/mesh. ', 'data/nul.bin', 'data/COM1/foo', 'data/line\nbreak', 'data']:
            with self.assertRaises(ValueError, msg=path):
                select_delta([], [item(path, b'user data')])
        with self.assertRaises(ValueError):
            validate_manifest([item('REZVIVO.exe', b'a'), item('rezvivo.exe', b'b')])

    def test_case_only_rename_does_not_delete_new_file(self):
        changed, removed = select_delta([item('data/tree.glb', b'new')], [item('data/Tree.glb', b'old')])
        self.assertEqual([v['path'] for v in changed], ['data/tree.glb'])
        self.assertEqual(removed, [])

    def test_encoder_is_installer_owned_but_recordings_are_not(self):
        files = [item('tools/video/'+name, b'encoder dependency')
                 for name in ('ffmpeg.exe', 'LICENSE.txt', 'NOTICE.txt')]
        changed, removed = select_delta(files, [])
        self.assertEqual(changed, files)
        self.assertEqual(removed, [])
        self.assertEqual(components(files)['program_files'], 3)
        self.assertEqual(select_delta([], files)[1], [f['path'] for f in files])
        for path in ('videos/ride.mp4', 'tools/video/ride.mp4', 'tools/video/config.json',
                     'tools/video/other.exe', 'tools/video/subdir/ffmpeg.exe'):
            with self.assertRaises(ValueError, msg=path):
                validate_manifest([item(path, b'not a runtime dependency')])

def compile_installer_guard(nsis):
    with tempfile.TemporaryDirectory(prefix='rezvivo-installer-guard-') as td:
        root = pathlib.Path(td)
        baseline = root / 'installed-files.json'
        baseline.write_text(json.dumps([item('REZVIVO.exe', b'x')], indent=2), encoding='utf-8')
        source = root / 'guard.nsi'
        lines = ['Unicode true', '!include "LogicLib.nsh"', 'Name "Update guard test"', f'OutFile "{root / "guard.exe"}"', 'RequestExecutionLevel user']
        lines += installer_guards(baseline)
        lines += ['Section', 'Call CheckInstallation', 'FileOpen $0 "$INSTDIR\\guard-passed.txt" w', 'FileWrite $0 "passed"', 'FileClose $0', 'SectionEnd']
        source.write_text('\n'.join(lines), encoding='utf-8-sig')
        subprocess.run([nsis, '/V2', str(source)], check=True)
        assert (root / 'guard.exe').is_file()
        installed = root / 'installed'
        installed.mkdir()
        (installed/'installed-files.json').write_bytes(baseline.read_bytes())
        exe = root/'guard.exe'
        subprocess.run([str(exe), '/S', '/D='+str(installed)], check=True, timeout=20)
        assert (installed/'guard-passed.txt').read_text() == 'passed'
        (installed/'guard-passed.txt').unlink()
        (installed/'installed-files.json').write_text('wrong baseline', encoding='utf-8')
        failed = subprocess.run([str(exe), '/S', '/D='+str(installed)], timeout=20)
        assert failed.returncode != 0 and not (installed/'guard-passed.txt').exists()
        print('NSIS exact-baseline guards PASS in isolated TEMP directory')

def compile_full_and_delta(nsis):
    with tempfile.TemporaryDirectory(prefix='rezvivo-installer-packets-') as td:
        root=pathlib.Path(td); stage=root/'stage'; out=root/'out'; stage.mkdir(); out.mkdir()
        (stage/'data/branding').mkdir(parents=True)
        shutil.copy2(tools.parent/'data/branding/rezvivo.ico',stage/'data/branding/rezvivo.ico')
        (stage/'data/world.bin').write_bytes(os.urandom(65536))
        (stage/'REZVIVO.exe').write_bytes(b'new-test-executable')
        (stage/'release.json').write_text(json.dumps(dict(build=2,version='0.0.0-test',file_version='0.0.0.2')),encoding='utf-8')
        manifest=[item(p.relative_to(stage).as_posix(),p.read_bytes()) for p in sorted(stage.rglob('*')) if p.is_file()]
        (stage/'installed-files.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
        old=[item('REZVIVO.exe',b'old')] + [v for v in manifest if v['path']!='REZVIVO.exe']
        baseline=root/'baseline.json';baseline.write_text(json.dumps(old,indent=2),encoding='utf-8')
        command=[sys.executable,str(tools/'build-installer.py'),'--stage',str(stage),'--out',str(out),'--nsis',nsis]
        subprocess.run(command,check=True,stdout=subprocess.DEVNULL)
        subprocess.run(command+['--baseline',str(baseline)],check=True,stdout=subprocess.DEVNULL)
        sidecar=json.loads(next(out.glob('*.packages.json')).read_text(encoding='utf-8'))
        full=next(p for p in sidecar['packages'] if p['kind']=='full')
        delta=next(p for p in sidecar['packages'] if p['kind']=='delta')
        assert delta['size_bytes'] < full['size_bytes']
        assert delta['resource_bytes']==0 and delta['program_files']==1
        script=(out/'client-update.nsi').read_text(encoding='utf-8-sig')
        assert 'File "'+str(stage/'data/world.bin')+'"' not in script
        assert 'Delete "$INSTDIR\\data\\world.bin"' in script  # complete future uninstall
        assert not json.loads((out/'release-publication.json').read_text())['published']
        print('Full/delta real NSIS packages PASS; unchanged resource omitted; publication stays disabled')

if __name__ == '__main__':
    nsis = sys.argv.pop() if len(sys.argv) > 1 and sys.argv[-1].lower().endswith('.exe') else None
    result = unittest.main(exit=False)
    if not result.result.wasSuccessful():
        raise SystemExit(1)
    if nsis:
        compile_installer_guard(nsis)
        compile_full_and_delta(nsis)
