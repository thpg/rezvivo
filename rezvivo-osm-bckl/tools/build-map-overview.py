"""Bake the public-domain Natural Earth overview once, never on the player's PC.

Source cache is outside runtime data. Output is an indexed, seekable pyramid:
RZWMAP1\0, uint32 max_zoom/side/count, then count * <QIQI> (JPEG offset/size,
land-mask PNG offset/size). Tile index = (4**z-1)//3 + y*2**z+x.
All integers are little endian. Identical payloads are stored only once.
"""
import argparse
import hashlib
import io
import json
import math
import struct
import urllib.request
import zipfile
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
from shapely.geometry import shape

RASTER = 'NE1_LR_LC_SR_W_DR'
VECTOR = 'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/'
LAYERS = ['ne_110m_admin_0_countries', 'ne_50m_populated_places',
          'ne_50m_geography_regions_points', 'ne_50m_geography_regions_polys',
          'ne_50m_geography_marine_polys', 'ne_50m_land', 'ne_50m_lakes',
          'ne_50m_rivers_lake_centerlines']


def main():
    ap = argparse.ArgumentParser(__doc__)
    ap.add_argument('--sources', type=Path, required=True)
    ap.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1]/'data/map-overview')
    args = ap.parse_args()
    args.sources.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)
    urls = {RASTER+'.zip': 'https://naciscdn.org/naturalearth/10m/raster/'+RASTER+'.zip'}
    urls.update({name+'.geojson': VECTOR+name+'.geojson' for name in LAYERS})
    for name, url in urls.items():
        path = args.sources/name
        if not path.exists():
            tmp = path.with_suffix(path.suffix+'.part')
            urllib.request.urlretrieve(url, tmp)
            tmp.replace(path)
    tif = args.sources/(RASTER+'.tif')
    if not tif.exists():
        with zipfile.ZipFile(args.sources/(RASTER+'.zip')) as z:
            with z.open(RASTER+'.tif') as src, tif.open('wb') as dst:
                import shutil
                shutil.copyfileobj(src, dst)
    layers = {name: json.loads((args.sources/(name+'.geojson')).read_text(encoding='utf-8'))['features'] for name in LAYERS}
    Image.MAX_IMAGE_PIXELS = 150_000_000
    raster = Image.open(tif).convert('RGB')
    max_zoom = 6
    width = 256 << max_zoom
    mask = Image.new('L', (width, width//2), 0)
    draw = ImageDraw.Draw(mask)
    def polygon(coords, fill):
        for ring_i, ring in enumerate(coords):
            points = [((lon+180)/360*width, (90-lat)/360*width) for lon, lat, *_ in ring]
            draw.polygon(points, fill=fill if ring_i == 0 else 255-fill)
    for layer, fill in [('ne_50m_land', 255), ('ne_50m_lakes', 0)]:
        for f in layers[layer]:
            g = f['geometry']
            for poly in g['coordinates'] if g['type']=='MultiPolygon' else [g['coordinates']]:
                polygon(poly, fill)
    # A compact bilingual gazetteer; runtime does not parse polygon GeoJSON.
    labels = []
    for layer in LAYERS:
        if layer == 'ne_50m_land':
            continue
        for f in layers[layer]:
            p = {k.lower(): v for k, v in f['properties'].items()}
            name = p.get('name_en') or p.get('name')
            if not name or not f.get('geometry'):
                continue
            g = shape(f['geometry'])
            if g.is_empty:
                continue
            if layer.endswith('countries'):
                x, y = p['label_x'], p['label_y']; z = 2 if p['labelrank']<=3 else 3
                kind, priority = 'place', 140
            elif layer.endswith('populated_places'):
                x, y = p['longitude'], p['latitude']; z = min(7, max(3, p['scalerank']+2))
                if p['adm0cap'] == 1: z = min(z, 4)
                kind, priority = 'place', 120
            else:
                if 'lat_y' in p and 'long_x' in p:
                    x, y = p['long_x'], p['lat_y']
                else:
                    pt = g.representative_point(); x, y = pt.x, pt.y
                z = min(8, max(1, math.ceil(p.get('min_label') or p.get('min_zoom') or 5)))
                kind, priority = 'region', 100
                if 'marine' in layer or layer.endswith('lakes') or layer.endswith('centerlines'):
                    kind, priority = 'water', 95
                    if layer.endswith('lakes') or layer.endswith('centerlines'): z = max(4, z)
                if p.get('featurecla', '').lower() == 'continent':
                    priority, z = 150, 1
            if z>7: continue
            labels.append(dict(name=name, ru=p.get('name_ru') or name, lon=round(x, 6), lat=round(y, 6),
                               zoom=z, kind=kind, priority=priority,
                               population=min(2_000_000_000, int(p.get('pop_max') or p.get('pop_est') or 0))))
    (args.output/'labels.json').write_text(json.dumps(dict(schema=1, labels=labels), ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    count = (4**(max_zoom+1)-1)//3
    entries = []
    dedup = {}
    with (args.output/'world.rzmap').open('wb') as out:
        out.write(struct.pack('<8sIII', b'RZWMAP1\0', max_zoom, 256, count))
        out.write(bytes(count*24))
        def payload(data):
            key = hashlib.sha256(data).digest()
            if key not in dedup:
                dedup[key] = (out.tell(), len(data)); out.write(data)
            return dedup[key]
        for z in range(max_zoom+1):
            side = 256 << z
            src = np.asarray(raster.resize((side, side//2), Image.Resampling.LANCZOS))
            land = np.asarray(mask.resize((side, side//2), Image.Resampling.LANCZOS))
            for ty in range(1 << z):
                yy = np.arange(ty*256, (ty+1)*256)+.5
                latitude = np.arctan(np.sinh(np.pi*(1-2*yy/side)))
                sy = (np.pi/2-latitude)*side/(2*np.pi)-.5
                a = np.maximum(0, np.minimum(src.shape[0]-1, np.floor(sy).astype(int)))
                b = np.minimum(src.shape[0]-1, a+1)
                w = (sy-a)[:, None, None]
                row = np.clip(src[a]*(1-w)+src[b]*w, 0, 255).astype('uint8')
                mrow = land[np.clip(np.rint(sy).astype(int), 0, land.shape[0]-1)]
                for tx in range(1 << z):
                    buf = io.BytesIO()
                    Image.fromarray(row[:, tx*256:(tx+1)*256]).save(buf, 'JPEG', quality=88, subsampling=0, optimize=True)
                    color = payload(buf.getvalue())
                    buf = io.BytesIO()
                    Image.fromarray(mrow[:, tx*256:(tx+1)*256]).save(buf, 'PNG', optimize=True)
                    entries.append((*color, *payload(buf.getvalue())))
            print('Baked zoom', z, 'bytes', out.tell(), flush=True)
        out.seek(20)
        for entry in entries: out.write(struct.pack('<QIQI', *entry))
    files = {}
    for name in ['world.rzmap', 'labels.json']:
        raw = (args.output/name).read_bytes()
        files[name] = dict(size_bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())
    manifest = dict(schema=1, max_zoom=max_zoom, tile_size=256, tiles=count, labels=len(labels),
                    license='Public domain - Natural Earth', sources=urls, files=files)
    (args.output/'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps(dict(files=files, labels=len(labels)), indent=2))


if __name__ == '__main__': main()
