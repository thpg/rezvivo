"""Compile the real Pascal GLSL fragment and game skin compilation units.

The negative control recreates the reserved identifier reported by Intel.
No game, account, network or graphics context is required for this test.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    text = path.read_text(encoding='utf-8-sig')
    text = text.split('const RiderLimbReliefGLSL=', 1)[1].split('\nimplementation', 1)[0]
    text = re.sub(r'//[^\n]*', '', text)
    return ''.join(s[1:-1].replace("''", "'") if s.startswith("'") else '\n'
                   for s in re.findall(r"'(?:[^']|'')*'|#10", text))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--validator', type=Path)
    parser.add_argument('--before', type=Path)
    parser.add_argument('--dump-dir', type=Path)
    parser.add_argument('--engine-root', type=Path,
                        help='CGE used to build the game; supplies its actual GL fragment header')
    args = parser.parse_args()
    validator = args.validator or shutil.which('glslangValidator') or shutil.which('glslang')
    if not validator:
        validator = ROOT/'Osm3d/rtx/.tools/glslang/bin/glslang.exe'
    if not Path(validator).is_file():
        parser.error('Provide --validator pointing to glslang or glslangValidator')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    body = source(ROOT/'Bikeparametric/RiderLimbRelief.pas')
    assert not re.search(r'\bfilter\b', body)
    if args.before:
        assert body == re.sub(r'\bfilter\b', 'limbDetailFade', source(args.before)), \
            'The fix must not change the skin relief formula'
    rows = []

    def compile_shader(name, shader, expected=True):
        path = out/(name+'.frag')
        path.write_text(shader, encoding='utf-8')
        result = subprocess.run([str(validator), '-S', 'frag', str(path)],
                                capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        (out/(name+'.txt')).write_text(output, encoding='utf-8')
        rows.append(dict(name=name, returncode=result.returncode,
                         sha256=hashlib.sha256(shader.encode()).hexdigest()))
        (out/'result.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
        assert (result.returncode == 0) == expected, (name, output)
        return output

    band = ('float rsBand(float x,float a,float b,float c,float d){'
            'return smoothstep(a,b,x)*(1.0-smoothstep(c,d,x));}\n')
    for version in ['120', '130', '330 core', '100', '300 es']:
        modern = version in ['330 core', '300 es']
        header = '#version '+version+'\n'
        if version == '100':
            header += '#extension GL_OES_standard_derivatives : require\n'
        if version in ['100', '300 es']:
            header += 'precision highp float;\n'
        if modern:
            header += '#define texture2D texture\nin vec3 bindPosition;\nout vec4 outColor;\n'
        else:
            header += 'varying vec3 bindPosition;\n'
        target = 'outColor' if modern else 'gl_FragColor'
        tail = 'void main(){'+target+'=vec4(rsLimbHeight(bindPosition)+rsLimbPigment);}\n'
        code = header+band+body+tail
        name = 'glsl-'+version.replace(' ', '-')
        compile_shader(name, code)
        negative = compile_shader(name+'-reserved-control',
                                  code.replace('limbDetailFade', 'filter'), False)
        assert 'reserved word' in negative.lower(), negative

    if args.dump_dir:
        if not args.engine_root:
            parser.error('--dump-dir requires --engine-root')
        # REZVIVO_SHADER_DUMP is taken before AttachShader adds the runtime
        # version/compatibility header. Reuse that header from the same engine.
        engine = (args.engine_root/'src/base_rendering/castleglshaders.pas').read_text(
            encoding='utf-8-sig')
        header = engine.split('GL31CoreHeader: array', 1)[1].split('// fragment', 1)[1]
        header = header.split(');', 1)[0]
        header = ''.join(s[1:-1].replace("''", "'") if s.startswith("'") else '\n'
                         for s in re.findall(r"'(?:[^']|'')*'|\bNL\b", header))
        assert header.startswith('#version') and 'castle_FragColor' in header
        found = 0
        for path in sorted(args.dump_dir.glob('*.glsl')):
            shader = path.read_text(encoding='utf-8-sig')
            if 'float rsLimbHeight(' not in shader:
                continue
            assert 'limbDetailFade' in shader and not re.search(r'\bfilter\b', shader)
            # Desktop CGE attaches separate fragment objects. Its dump joins
            # these objects (including repeated struct declarations), which
            # is not itself one compilable translation unit. Recover the full
            # skin object between the repeated per-object color-space prefix.
            prelude = re.search(
                r'(?:^#define CASTLE_(?:TONE_MAPPING(?:_\w+)?|GAMMA_CORRECTION)[^\n]*\n)+'
                r'(?=varying vec3 rsPosition;)', shader, re.M)
            assert prelude, ('Skin compilation-unit boundary changed', path)
            end = shader.find(prelude.group(), prelude.end())
            shader = shader[prelude.start():end if end >= 0 else len(shader)]
            assert body in shader, ('Game did not use the current relief source', path)
            if not re.search(r'^\s*#version\b', shader, re.M):
                shader = header + shader
            compile_shader('game-'+path.stem, shader)
            found += 1
        assert found, 'No actual skin shader in game dump'
        print('Complete game skin compilation units:', found, flush=True)
    print('LIMB_RELIEF_GLSL_OK', len(rows), 'compiler checks', flush=True)


if __name__ == '__main__':
    main()
