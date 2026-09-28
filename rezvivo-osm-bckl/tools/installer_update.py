"""Manifest-only update selection; profiles, journals and caches are never payload."""
from pathlib import PurePosixPath

def safe_runtime_path(value):
    path = PurePosixPath(value)
    if not value or any(c in value for c in '\\:*?"<>|') or any(ord(c) < 32 for c in value) or path.is_absolute() or any(p in ('', '.', '..') for p in path.parts):
        raise ValueError('Unsafe runtime path: ' + value)
    # NSIS Delete supports wildcards; Windows also aliases trailing dots/spaces
    # and device names. A manifest entry must identify exactly one normal file.
    reserved = {'con', 'prn', 'aux', 'nul', 'conin$', 'conout$'} | {f'{p}{n}' for p in ('com', 'lpt') for n in '123456789¹²³'}
    if any(p.endswith((' ', '.')) or p.split('.')[0].lower() in reserved for p in path.parts):
        raise ValueError('Noncanonical Windows runtime path: ' + value)
    if str(path) != value:
        raise ValueError('Noncanonical runtime path: ' + value)
    if not (path.parts[0] == 'data' and len(path.parts) > 1) and not (len(path.parts) == 1 and (value in ('REZVIVO.exe', 'release.json') or path.suffix.lower() == '.dll')):
        raise ValueError('Not an installation-owned file: ' + value)
    return value

def validate_manifest(manifest):
    paths = set()
    for item in manifest:
        name = safe_runtime_path(item['path'])
        if name.lower() in paths:
            raise ValueError('Duplicate runtime path: ' + name)
        paths.add(name.lower())
        if not isinstance(item['bytes'], int) or item['bytes'] < 0 or len(item['sha256']) != 64 or any(c not in '0123456789abcdef' for c in item['sha256']):
            raise ValueError('Invalid runtime file metadata: ' + name)

def components(manifest):
    result = dict(program_bytes=0, resource_bytes=0, program_files=0, resource_files=0)
    for item in manifest:
        group = 'resource' if item['path'].startswith('data/') else 'program'
        result[group + '_bytes'] += item['bytes']
        result[group + '_files'] += 1
    return result

def select_delta(current, baseline):
    validate_manifest(current)
    validate_manifest(baseline)
    # The target is Windows: a case-only rename must never become a Delete
    # after the replacement was installed under its new spelling.
    previous = {v['path'].lower(): v for v in baseline}
    present = {v['path'].lower() for v in current}
    changed = [v for v in current if previous.get(v['path'].lower()) != v]
    removed = [v['path'] for v in baseline if v['path'].lower() not in present]
    return changed, removed

def installer_guards(baseline=None):
    lines = [
        '!include "FileFunc.nsh"',
        'LangString UpdateCloseGame 1033 "Close REZVIVO before installing the update."',
        'LangString UpdateCloseGame 1049 "Закройте REZVIVO перед установкой обновления."',
        'LangString UpdateWrongBase 1033 "This update requires a different installed version. Download the full installer."',
        'LangString UpdateWrongBase 1049 "Обновление предназначено для другой установленной версии. Загрузите полный установщик."',
        'Function .onInit',
        '${GetParameters} $0', '${GetOptions} $0 "/WAITPID=" $1',
        '${If} $1 != ""',
        'System::Call "kernel32::OpenProcess(i 0x00100000, i 0, i r1) p.r2"',
        '${If} $2 != 0',
        'System::Call "kernel32::WaitForSingleObject(p r2, i 120000) i.r3"',
        'System::Call "kernel32::CloseHandle(p r2)"',
        '${If} $3 != 0', 'MessageBox MB_ICONSTOP "$(UpdateCloseGame)" /SD IDOK', 'SetErrorLevel 2', 'Abort', '${EndIf}',
        '${EndIf}', '${EndIf}', 'FunctionEnd',
        'Function CheckInstallation',
        'IfFileExists "$INSTDIR\\REZVIVO.exe" 0 executable_closed',
        'System::Call \'kernel32::CreateFileW(w "$INSTDIR\\REZVIVO.exe", i 0x40000000, i 0, p 0, i 3, i 0, p 0) p.r0\'',
        '${If} $0 == -1', 'MessageBox MB_ICONSTOP "$(UpdateCloseGame)" /SD IDOK', 'SetErrorLevel 2', 'Abort', '${EndIf}',
        'System::Call "kernel32::CloseHandle(p r0)"', 'executable_closed:',
    ]
    if baseline:
        escaped = str(baseline).replace('$', '$$').replace('"', '$\\"')
        lines += [
            'InitPluginsDir', f'File /oname=$PLUGINSDIR\\expected-base.json "{escaped}"',
            'ClearErrors', 'FileOpen $1 "$INSTDIR\\installed-files.json" r',
            'IfErrors baseline_bad', 'FileOpen $2 "$PLUGINSDIR\\expected-base.json" r',
            'baseline_loop:', 'ClearErrors', 'FileRead $2 $3', 'IfErrors baseline_end',
            'ClearErrors', 'FileRead $1 $4', 'IfErrors baseline_mismatch',
            'StrCmp $3 $4 baseline_loop baseline_mismatch',
            'baseline_end:', 'ClearErrors', 'FileRead $1 $4', 'IfErrors baseline_ok baseline_mismatch',
            'baseline_mismatch:', 'FileClose $1', 'FileClose $2', 'Goto baseline_bad',
            'baseline_ok:', 'FileClose $1', 'FileClose $2', 'Goto baseline_done',
            'baseline_bad:', 'MessageBox MB_ICONSTOP "$(UpdateWrongBase)" /SD IDOK', 'SetErrorLevel 2', 'Abort',
            'baseline_done:',
        ]
    return lines + ['FunctionEnd']
