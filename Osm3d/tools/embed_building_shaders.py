"""Regenerate Pascal source constants; shader files are not runtime resources."""
from pathlib import Path
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
folder = Path(__file__).resolve().parents[1] / 'shaders'
for name in ('building_material.vs.glsl', 'building_material.glsl',
             'building_detail.vs.glsl', 'building_detail.glsl',
             'building_material.native.glsl', 'building_detail.native.glsl'):
    source = folder / name
    lines = source.read_text(encoding='utf-8').splitlines()
    text = '{ Generated from ' + name + ' by tools/embed_building_shaders.py. }\n'
    text += ' +\n'.join("  '" + line.replace("'", "''") + "' + #10" for line in lines) + '\n'
    target = source.with_name(name + '.inc')
    if args.check:
        if not target.exists() or target.read_text(encoding='utf-8') != text:
            raise SystemExit(f'Stale shader include: {target}')
    else:
        target.write_text(text, encoding='utf-8')
print('Building shader includes are current.')
