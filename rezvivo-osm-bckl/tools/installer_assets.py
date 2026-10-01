"""Runtime asset selection. Keep editor/source assets in the working tree only."""
import json
import re
import struct
import shlex
import xml.etree.ElementTree as ET
from pathlib import Path

SURFACES = 'data/Osm3d/resources/textures/surfaces/'


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
    omit(root/'data/Osm3d/resources/models/shrubbery/normal_source.png',
         'Shrub normal-map source; runtime uses normal.png')
    omit(root/'data/Osm3d/resources/models/shrubbery/volume.png',
         'Unused shrub volume baking image')
    for name in ('bake-report.json', 'route-plan.json'):
        for path in (root/'data/dream-worlds').glob('*/'+name):
            omit(path, 'Dream World generator report/source plan')

    # TreeRenderer.PrepareLODAtlas reads the separate seasonal layers whenever
    # seasonal_version=1. Keep all layers and metadata; omit the merged preview.
    for meta in (root/'data/procedural-trees/lod-atlases').glob('*.json'):
        if json.loads(meta.read_text(encoding='utf-8')).get('seasonal_version') == 1:
            for part in ('wood', 'foliage'):
                if not meta.with_name(meta.stem+'-'+part+'.png').is_file():
                    raise ValueError('Missing seasonal tree layer: '+str(meta))
            omit(meta.with_suffix('.png'), 'Merged tree preview; seasonal layers are used')

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


def validate_asset_links(stage, paths):
    """Check explicit UI/world/model dependencies against the packaged files."""
    available = {Path(p).as_posix().lower() for p in paths}
    checked = 0

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
