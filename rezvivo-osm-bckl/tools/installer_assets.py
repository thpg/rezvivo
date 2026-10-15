"""Runtime asset selection. Keep editor/source assets in the working tree only."""
import json
import hashlib
import re
import struct
import shlex
import xml.etree.ElementTree as ET
from pathlib import Path

SURFACES = 'data/Osm3d/resources/textures/surfaces/'


def overview_assets(root):
    """The empty-cache globe must work immediately after a fresh installation."""
    folder = Path(root)/'data/map-overview'
    manifest = folder/'manifest.json'
    doc = json.loads(manifest.read_text(encoding='utf-8-sig'))
    if doc.get('schema') != 1 or set(doc.get('files', {})) != {'world.rzmap', 'labels.json'}:
        raise ValueError('Invalid bundled globe manifest')
    result = [manifest]
    for name, info in doc['files'].items():
        path = folder/name
        raw = path.read_bytes()
        if len(raw) != info['size_bytes'] or hashlib.sha256(raw).hexdigest() != info['sha256']:
            raise ValueError('Bundled globe checksum mismatch: '+str(path))
        if name == 'world.rzmap':
            magic, zoom, side, count = struct.unpack('<8sIII', raw[:20])
            if (magic, zoom, side, count) != (b'RZWMAP1\0', doc['max_zoom'], 256, doc['tiles']):
                raise ValueError('Invalid bundled globe index')
        result.append(path)
    return result


def ready_route_assets(root):
    """Public seed only; never include a user's imported FIT/GPX library."""
    root = Path(root)
    catalog = root/'data/ready-routes/catalog.json'
    if not catalog.is_file():
        raise ValueError('Missing required ready-route seed: '+str(catalog))
    doc = json.loads(catalog.read_text(encoding='utf-8-sig'))
    if doc.get('schema') != 1 or not isinstance(doc.get('items'), list):
        raise ValueError('Invalid ready-route seed schema')
    result = [catalog]
    seen = set()
    for item in doc['items']:
        route_id = item.get('id', '')
        if not re.fullmatch(r'[a-z0-9-]{1,80}', route_id) or route_id in seen:
            raise ValueError('Invalid/duplicate ready-route seed identity')
        seen.add(route_id)
        path = catalog.with_name(route_id+'.gpx')
        if not path.is_file():
            raise ValueError('Missing ready-route seed GPX: '+str(path))
        raw = path.read_bytes()
        if len(raw) != item.get('size_bytes') or hashlib.sha256(raw).hexdigest() != item.get('sha256'):
            raise ValueError('Ready-route seed size/checksum mismatch: '+str(path))
        result.append(path)
    return result


def redundant_assets(root):
    excluded = {}

    def omit(path, reason):
        if path.is_file():
            excluded[path.relative_to(root).as_posix()] = reason

    for name in ('MEN.glb', 'FEM.glb', 'MEN.pose.bin', 'MEN.pose.json', 'FEM.pose.bin', 'FEM.pose.json'):
        omit(root/'data/avatars'/name, 'Retired separate body; shared RIDER.glb contains shape fields and pose atlas')

    for path in (root/'data/road').rglob('*'):
        omit(path, 'Legacy photographic asphalt; roads use procedural materials')
    surfaces = root/SURFACES
    for folder in surfaces.glob('*LaneRoad*'):
        for path in folder.rglob('*'):
            omit(path, 'Legacy photographic asphalt in ground atlas')
    for path in surfaces.glob('asphalt*.png'):
        omit(path, 'Legacy photographic asphalt in ground atlas')
    # These were intermediate baking outputs, never sampled by the renderer.
    for folder in (surfaces/'procedural-grass', root/'data/procedural-trees/grass-atlases'):
        for path in folder.glob('*-ground.png'):
            omit(path, 'Unused grass baking intermediate')
    for name in ('common_mask.png', 'common_normal.png', 'forest_floor_mask.png',
                 'rail_diffuse.png', 'sandy_soil_height.png', 'water_normal.png'):
        omit(surfaces/name, 'Unused surface map')
    for kind in ('tree', 'shrubbery'):
        for path in (root/'data/Osm3d/resources/models'/kind).rglob('*'):
            omit(path, 'Retired vegetation atlas; all modes use generated species LOD atlases')
    for name in ('bake-report.json', 'route-plan.json'):
        for path in (root/'data/dream-worlds').glob('*/'+name):
            omit(path, 'Dream World generator report/source plan')

    # TreeRenderer.PrepareLODAtlas reads the separate seasonal layers whenever
    # seasonal_version=1. Keep all layers and metadata; omit the merged preview.
    for meta in (root/'data/procedural-trees/lod-atlases').glob('*.json'):
        atlas = json.loads(meta.read_text(encoding='utf-8'))
        if atlas.get('seasonal_version') == 1:
            parts = ['wood', 'foliage'] + (['fruit'] if atlas.get('fruit_layer') else [])
            for part in parts:
                if not meta.with_name(meta.stem+'-'+part+'.png').is_file():
                    raise ValueError('Missing seasonal tree layer: '+str(meta))
                if atlas.get('relight_version') == 1 and not meta.with_name(meta.stem+'-'+part+'-normal.png').is_file():
                    raise ValueError('Missing relightable tree normal layer: '+str(meta))
            omit(meta.with_suffix('.png'), 'Merged tree preview; seasonal layers are used')
            omit(meta.with_name(meta.stem+'-normal.png'), 'Merged normal preview; seasonal normal layers are used')
            if not atlas.get('fruit_layer'):
                omit(meta.with_name(meta.stem+'-fruit.png'), 'Empty fruit layer for non-fruiting species')

    # GrassRenderer.LoadAtlas prefers this ready-to-upload cache. Do not silently
    # strip the PNG fallback if its layout/version no longer matches the engine.
    folder = root/'data/procedural-trees/grass-atlases'
    model = (root.parent/'tree-editor/core/GrassModel.pas').read_text(encoding='utf-8-sig')
    def constant(name):
        return int(re.search(r'\b'+name+r'\s*=\s*(\d+)\s*;', model)[1])
    size = constant('GRASS_BAKE_SIZE')
    layers = constant('GRASS_SPECIES_COUNT') * constant('GRASS_ATLAS_VIEWS')
    cache = folder/'grass.rgba'
    with cache.open('rb') as stream:
        header = struct.unpack('<5I', stream.read(20))
    if header != (0x47535A52, constant('GRASS_MODEL_VERSION'), size, layers, 2):
        raise ValueError('Rebake the grass atlas before packaging: obsolete grass.rgba')
    if cache.stat().st_size != 20+size*size*layers*4:
        raise ValueError('Truncated grass.rgba')
    for path in folder.glob('*.png'):
        omit(path, 'Grass PNG source; validated binary atlas is used')
    return excluded


def runtime_assets(root, excluded=None):
    """One resource selection shared by desktop and Android installers."""
    import xml.etree.ElementTree as ET
    root = Path(root)
    seed_files = {p.resolve() for p in ready_route_assets(root)}
    overview_files = {p.resolve() for p in overview_assets(root)}
    if excluded is None:
        excluded = redundant_assets(root)
    for path in sorted((root/'data').rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if relative.as_posix() in excluded:
            continue
        if any(part.lower() in ('backup', '__pycache__', '.git') for part in relative.parts):
            continue
        if path.suffix.lower() in ('.py', '.pyc', '.md', '.log', '.bak', '.dbg', '.blend'):
            continue
        if relative.parts[1] == 'workouts':
            if len(relative.parts) < 5 or relative.parts[2] != 'rezvivo' or path.suffix != '.zwo':
                continue
            if ET.parse(path).findtext('author') != 'REZVIVO':
                raise ValueError(f'Non-original workout: {path}')
        if relative.parts[1] == 'ready-routes' and path.resolve() not in seed_files:
            continue
        if relative.parts[1] == 'map-overview' and path.resolve() not in overview_files:
            continue
        if path.is_symlink():
            raise ValueError(f'Unexpected asset symlink: {path}')
        yield path, relative


def validate_asset_links(stage, paths):
    """Check explicit UI/world/model dependencies against the packaged files."""
    available = {Path(p).as_posix().lower() for p in paths}
    checked = 0
    for path in ready_route_assets(stage) + overview_assets(stage):
        if path.relative_to(stage).as_posix().lower() not in available:
            raise ValueError('Ready-route seed missing from installer manifest: '+str(path))
        checked += 1

    def reference(source, value):
        nonlocal checked
        if not value or value.startswith(('data:', 'http:', 'https:', 'castle-engine:', '#')):
            return
        if value.startswith('castle-data:/'):
            target = stage/'data'/value[len('castle-data:/'):]
        else:
            target = source.parent/value
        target = target.resolve()
        if stage.resolve() not in target.parents:
            raise ValueError('Resource outside installer: '+str(source)+' -> '+value)
        relative = target.relative_to(stage.resolve()).as_posix()
        if relative.lower() not in available:
            raise ValueError('Missing packaged dependency: '+str(source)+' -> '+relative)
        checked += 1

    def walk_json(source, node):
        if isinstance(node, str) and node.startswith('castle-data:/'):
            reference(source, node)
        elif isinstance(node, dict):
            for key, value in node.items():
                if key == 'file' and isinstance(value, str):
                    reference(source, value)
                else:
                    walk_json(source, value)
        elif isinstance(node, list):
            for value in node:
                walk_json(source, value)

    for rel in paths:
        source = stage/rel
        if source.suffix == '.castle-user-interface' or source.name == 'world.json':
            walk_json(source, json.loads(source.read_text(encoding='utf-8-sig')))
        elif source.suffix == '.x3d':
            for _, node in ET.iterparse(source):
                if node.tag == 'O3DModel':
                    reference(source, node.attrib['file'])
                elif node.tag in ('ImageTexture', 'Inline'):
                    for value in shlex.split(node.get('url', '')):
                        reference(source, value)
                node.clear()
    return checked
