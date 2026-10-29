"""Apply the production road-junction footprints to an authored binary tile.

Usage: python PatchBakedRoadJunctions.py old.o3dt probe.json new.o3dt
Requires numpy, shapely and mapbox-earcut (offline maintenance only).
The probe is RoadJunctionTileProbe.pas. OSM/photo recipes remain read-only.
Every non-ground chunk is copied verbatim, including its compressed bytes.
Outside the footprints, all vertex attributes and triangles are retained.
Inside, subdivide the EXISTING terrain triangles: heights are interpolated,
never resampled from a different elevation source. Writes a new file only.
"""
from pathlib import Path
import hashlib
import json
import struct
import sys
import zlib

import numpy as np
import shapely
from shapely.geometry import Polygon, box
import mapbox_earcut

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Osm3d/cache-tools'))
from tile_cache import Tile, decode, HEADER, ENTRY


def string(value):
    value = value.encode('utf8')
    return struct.pack('<I', len(value)) + value


def polygons(geometry):
    if geometry.is_empty:
        return
    if geometry.geom_type == 'Polygon':
        yield geometry
    elif geometry.geom_type in ('MultiPolygon', 'GeometryCollection'):
        for item in geometry.geoms:
            yield from polygons(item)


def triangulate(poly):
    rings = [np.asarray(poly.exterior.coords)[:-1]]
    rings += [np.asarray(h.coords)[:-1] for h in poly.interiors]
    coords = np.concatenate(rings)
    ends = np.cumsum([len(r) for r in rings], dtype=np.uint32)
    indices = mapbox_earcut.triangulate_float64(coords, ends).reshape(-1, 3)
    return coords, indices


def patch_uv(points, patch):
    v = patch['vertices']
    answer = np.full((len(points), 2), np.nan)
    for i in range(1, len(v)):
        t = v[[0, i, (i % (len(v)-1))+1]]
        matrix = np.column_stack((t[:, :2], np.ones(3)))
        if abs(np.linalg.det(matrix)) < 1e-8:
            continue
        bary = np.column_stack((points, np.ones(len(points)))) @ np.linalg.inv(matrix)
        inside = np.all(bary >= -1e-3, axis=1)
        answer[inside] = bary[inside] @ t[:, 2:4]
    assert np.isfinite(answer).all(), 'Patch UV outside its source fan'
    return answer


def patch_mesh(m, raw_patches, bridge_ids):
    pn = np.asarray(m['position_normal'], dtype=np.float32).reshape(-1, 6)
    pool = np.asarray(m['pool_indices'], dtype=np.uint32)
    if not len(pool):
        pool = np.arange(m['vertex_count'], dtype=np.uint32)
    vertices = pn[pool]
    uv = np.asarray(m['uv'], dtype=np.float32).reshape(-1, 2)
    ix = np.asarray(m['indices'], dtype=np.uint32).reshape(-1, 3)
    mat = np.asarray(m['material_ids'], dtype=np.int32)
    osm = np.asarray(m['osm_ids'], dtype=np.int64)
    water = np.asarray(m['water_scale'], dtype=np.float32)
    assert len(mat) == len(osm) == len(vertices)
    xyz = vertices[ix, :3]
    xz = xyz[:, :, [0, 2]].astype(np.float64)
    lower, upper = xz.min(axis=1), xz.max(axis=1)
    bbox = box(*np.r_[lower.min(axis=0), upper.max(axis=0)])
    patches, shapes = [], []
    for p in raw_patches:
        p = dict(p, vertices=np.array(p['vertices'], dtype=np.float64))
        shape = Polygon(p['vertices'][1:, :2])
        assert shape.is_valid, 'Invalid production junction polygon'
        if shape.intersects(bbox):
            patches.append(p)
            shapes.append(shape)
    if not patches:
        return None, dict(junctions=0, affected_triangles=0)

    eligible = ~np.isin(osm[ix[:, 0]], list(bridge_ids))
    eligible &= np.all(mat[ix] == mat[ix[:, :1]], axis=1)
    # Keep walls, stairs and nearly vertical faces intact.
    ab, ac = xz[:, 1]-xz[:, 0], xz[:, 2]-xz[:, 0]
    determinants = ab[:, 0]*ac[:, 1]-ab[:, 1]*ac[:, 0]
    eligible &= abs(determinants) > 1e-7
    candidates = np.zeros(len(ix), bool)
    for shape in shapes:
        a, b, c, d = shape.bounds
        candidates |= (upper[:, 0] >= a) & (lower[:, 0] <= c) & (upper[:, 1] >= b) & (lower[:, 1] <= d)
    candidates &= eligible
    tree = shapely.STRtree(shapes)
    remove = np.zeros(len(ix), bool)
    new_pn, new_uv, new_mat, new_osm, new_water, new_ix, new_border = [], [], [], [], [], [], []
    affected_area = 0.0
    used = set()
    old_vc = len(vertices)
    bounds_min, bounds_max = lower.min(axis=0), upper.max(axis=0)

    for index in np.flatnonzero(candidates):
        tri = Polygon(xz[index])
        hits = tree.query(tri, predicate='intersects')
        pieces = [(tri, None)]
        changed = False
        for hit in sorted(hits):
            clipped = []
            for shape, owner in pieces:
                inside = shape.intersection(shapes[hit])
                if inside.area <= 1e-9:
                    clipped.append((shape, owner))
                    continue
                changed = True
                used.add(int(hit))
                clipped.extend((poly, owner) for poly in polygons(shape.difference(shapes[hit])) if poly.area > 1e-10)
                clipped.extend((poly, int(hit)) for poly in polygons(inside) if poly.area > 1e-10)
            pieces = clipped
        if not changed:
            continue
        remove[index] = True
        affected_area += tri.area
        original = ix[index]
        inverse = np.linalg.inv(np.column_stack((xz[index], np.ones(3))))
        area_check = 0.0
        for poly, owner in pieces:
            coords, tris = triangulate(poly)
            bary = np.column_stack((coords, np.ones(len(coords)))) @ inverse
            assert (bary >= -1e-3).all() and (bary <= 1.001).all()
            out_pn = bary @ vertices[original]
            out_pn[:, 0], out_pn[:, 2] = coords[:, 0], coords[:, 1]
            norm = np.linalg.norm(out_pn[:, 3:], axis=1)
            out_pn[:, 3:] /= np.maximum(norm[:, None], 1e-8)
            out_uv = bary @ uv[original] if owner is None else patch_uv(coords, patches[owner])
            out_mat = int(mat[original[0]]) if owner is None else patches[owner]['material']
            out_osm = int(osm[original[0]]) if owner is None else int(patches[owner]['way_id'])
            offset = old_vc + len(new_pn)
            new_pn.extend(out_pn)
            new_uv.extend(out_uv)
            new_mat.extend([out_mat] * len(coords))
            new_osm.extend([out_osm] * len(coords))
            if len(water):
                new_water.extend(bary @ water[original])
            near_border = np.any((abs(coords-bounds_min) < 1) | (abs(coords-bounds_max) < 1), axis=1)
            new_border.extend(offset+np.flatnonzero(near_border))
            for t in tris:
                a, b, c = coords[t]
                ab, ac = b-a, c-a
                area = ab[0]*ac[1]-ab[1]*ac[0]
                if abs(area) < 1e-12:
                    continue
                area_check += abs(area)*.5
                if area * determinants[index] < 0:
                    t = t[[0, 2, 1]]
                new_ix.append(t + offset)
        assert abs(area_check-tri.area) <= max(1e-7, tri.area*1e-7), ('Lost terrain area', index, area_check, tri.area)

    if not new_pn:
        return None, dict(junctions=0, affected_triangles=0)
    added = len(new_pn)
    pool = np.r_[pool, np.arange(len(pn), len(pn)+added, dtype=np.uint32)]
    pn = np.concatenate([pn, np.array(new_pn, dtype=np.float32)])
    uv = np.concatenate([uv, np.array(new_uv, dtype=np.float32)])
    ix = np.concatenate([ix[~remove], np.array(new_ix, dtype=np.uint32)])
    mat = np.r_[mat, np.array(new_mat, dtype=np.int32)]
    osm = np.r_[osm, np.array(new_osm, dtype=np.int64)]
    if len(water):
        water = np.r_[water, np.array(new_water, dtype=np.float32)]
    border = np.r_[np.asarray(m['border_indices'], dtype=np.uint32), np.array(new_border, dtype=np.uint32)]
    # Original arrays remain in place; new vertices occupy the tail only.
    raw = string(m['name']) + string(m['material'])
    raw += struct.pack('<8I', int(m['solid']) | 2, len(uv), len(pn), ix.size, len(mat), len(water), len(osm), len(border))
    raw += b''.join(a.tobytes() for a in [pn, pool, uv, ix, mat, water, osm, border])
    decode('MESH', raw)  # same format/integrity checks as the cache inspector
    return raw, dict(junctions=len(used), affected_triangles=int(remove.sum()),
                     added_vertices=added, triangles_before=m['triangles'], triangles_after=len(ix),
                     terrain_area_preserved=True, changed_area_m2=affected_area)


def patch_tile(source, probe, target):
    source, target = Path(source), Path(target)
    assert source.resolve() != target.resolve() and not target.exists(), 'New destination required'
    tile = Tile(source)
    recipe = json.loads(Path(probe).read_text(encoding='utf-8-sig'))
    meta = decode('META', tile.raw(next(e for e in tile.entries if e['kind'] == 'META')))
    suffix = '-k'+recipe['recipe_hash'] if recipe['recipe_hash'] else ''
    assert meta['gen'].endswith(suffix), 'Active photo recipe differs from baked tile'
    assert np.allclose(meta['origin'], recipe['origin'], atol=1e-10, rtol=0)
    roads = decode('ROAD', tile.raw(next(e for e in tile.entries if e['kind'] == 'ROAD')))
    bridges = {r[3] for r in roads['records'] if r[4]}
    chunks, results, unchanged = [], [], []
    source_bytes = source.read_bytes()
    for e in tile.entries:
        raw = None
        if e['kind'] == 'META':
            raw = tile.raw(e)[:64] + string(recipe['generator_hash'] + suffix)
        elif e['kind'] == 'MESH':
            m = decode('MESH', tile.raw(e))
            if m['name'].startswith('composite_') and m['material'] == 'smkSurface':
                raw, result = patch_mesh(m, recipe['patches'], bridges)
                results.append(result)
        if raw is None:
            packed = source_bytes[e['offset']:e['offset']+e['packed_bytes']]
            chunks.append((e['kind'], e['flags'], packed, e['raw_bytes'], e['crc32']))
            unchanged.append((e['index'], hashlib.sha256(packed).hexdigest()))
        else:
            chunks.append((e['kind'], 1, zlib.compress(raw, 6), len(raw), zlib.crc32(raw)))
    assert results, 'No ground mesh'
    offset = HEADER.size + len(chunks)*ENTRY.size
    directory, payload = bytearray(), bytearray()
    for kind, flags, packed, size, crc in chunks:
        directory.extend(ENTRY.pack(kind.encode(), flags, offset, len(packed), size, crc, 0))
        payload.extend(packed)
        offset += len(packed)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(HEADER.pack(b'O3DTBIN1', 1, 0x01020304, len(chunks), 0, 32)+directory+payload)
    checked = Tile(target)
    output = target.read_bytes()
    for i, expected in unchanged:
        e = checked.entries[i]
        assert hashlib.sha256(output[e['offset']:e['offset']+e['packed_bytes']]).hexdigest() == expected
    for e in checked.entries:
        checked.raw(e)
    return dict(source=str(source), target=str(target), runtime_target=recipe['target'],
                preserved_chunks=len(unchanged), details=results,
                sha256=hashlib.sha256(output).hexdigest())


if __name__ == '__main__':
    result = patch_tile(*sys.argv[1:4])
    Path(sys.argv[3]+'.report.json').write_text(json.dumps(result, indent=2), encoding='utf8')
    print(json.dumps(result))
