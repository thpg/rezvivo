#!/usr/bin/env python3
"""Inspect REZVIVO O3DTBIN1 tiles. Python 3.9+, standard library only.

The runtime installs this file and TILE_CACHE_FORMAT.md into the cache root.
Examples:
  python tile_cache.py info path/to/tile.o3dt
  python tile_cache.py verify path/to/tile.o3dt
  python tile_cache.py dump path/to/tile.o3dt --layer TREE --limit 20
  python tile_cache.py extract path/to/tile.o3dt --index 1 --output mesh.bin
  python tile_cache.py format x3d
"""
import argparse
from array import array
import json
import math
from pathlib import Path
import struct
import sys
import zlib

HEADER = struct.Struct('<8sIIIIQ')
ENTRY = struct.Struct('<4sIQQQII')
MAX_CHUNK = 512 * 1024 * 1024
REQUIRED = {'META', 'TREE', 'POIS', 'ROAD', 'BULD', 'MODL', 'MHOL'}
TREE = struct.Struct('<6fIIii')
POI = struct.Struct('<I4f')
ROAD = struct.Struct('<IIfqIii3fiiiiifII')
BUILDING = struct.Struct('<ffII')
MODEL = struct.Struct('<I10f')
MANHOLE = struct.Struct('<7fi')
TREE_FIELDS = ('x y z scale rotation seed flags type_plus_one lat_e7 lon_e7').split()
ROAD_FIELDS = ('p0 p1 width way_id flags forward_lanes backward_lanes uv_min '
               'uv_max uv_scale marked surface condition both_ways custom edge '
               'lane_offset lane_count').split()


def require(ok, message):
    if not ok:
        raise ValueError(message)


class Payload:
    def __init__(self, data):
        self.data = memoryview(data)
        self.offset = 0

    def take(self, size):
        require(0 <= size <= len(self.data) - self.offset, 'truncated payload')
        result = self.data[self.offset:self.offset + size]
        self.offset += size
        return result

    def values(self, fmt):
        schema = struct.Struct('<' + fmt)
        return schema.unpack(self.take(schema.size))

    def u32(self):
        return self.values('I')[0]

    def string(self):
        size = self.u32()
        require(size <= 1024 * 1024, 'string exceeds limit')
        return bytes(self.take(size)).decode('utf-8')

    def strings(self):
        count = self.u32()
        require(count * 4 <= len(self.data) - self.offset, 'invalid string table')
        return [self.string() for _ in range(count)]

    def scalars(self, code, count):
        result = array(code)
        result.frombytes(self.take(count * result.itemsize))
        if sys.byteorder != 'little':
            result.byteswap()
        if code in ('f', 'd'):
            require(all(math.isfinite(v) for v in result), 'non-finite float')
        return result

    def records(self, schema, count):
        return list(schema.iter_unpack(self.take(schema.size * count)))

    def finish(self):
        require(self.offset == len(self.data), 'trailing payload data')


class Tile:
    def __init__(self, path):
        self.path = Path(path)
        self.entries = []
        with self.path.open('rb') as f:
            raw = f.read(HEADER.size)
            require(len(raw) == HEADER.size, 'truncated header')
            magic, version, endian, count, reserved, directory = HEADER.unpack(raw)
            require((magic, version, endian, reserved, directory) ==
                    (b'O3DTBIN1', 1, 0x01020304, 0, 32), 'unsupported header/version')
            size = self.path.stat().st_size
            require(7 <= count <= 65536 and 32 + count * 40 <= size, 'invalid directory')
            previous = 32 + count * 40
            total = 0
            seen = set()
            for i in range(count):
                kind, flags, offset, packed, unpacked, crc, reserved = ENTRY.unpack(f.read(40))
                kind = kind.decode('ascii')
                require(flags in (0, 1) and reserved == 0 and offset == previous and
                        4 <= unpacked <= MAX_CHUNK and 0 < packed <= MAX_CHUNK and
                        offset + packed <= size, f'invalid chunk {i}')
                require(flags != 0 or packed == unpacked, 'invalid raw chunk size')
                require(kind == 'MESH' or kind not in seen, f'duplicate layer {kind}')
                seen.add(kind)
                total += unpacked
                require(total <= 4 * 1024 ** 3, 'tile exceeds size limit')
                self.entries.append(dict(index=i, kind=kind, flags=flags, offset=offset,
                                         packed_bytes=packed, raw_bytes=unpacked, crc32=crc))
                previous = offset + packed
            require(previous == size and REQUIRED <= seen, 'incomplete tile')

    def raw(self, entry):
        with self.path.open('rb') as f:
            f.seek(entry['offset'])
            data = f.read(entry['packed_bytes'])
        require(len(data) == entry['packed_bytes'], 'truncated chunk')
        if entry['flags']:
            decoder = zlib.decompressobj()
            data = decoder.decompress(data, entry['raw_bytes'] + 1)
            require(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail,
                    'invalid/oversized zlib stream')
        require(len(data) == entry['raw_bytes'], 'uncompressed size mismatch')
        require(zlib.crc32(data) == entry['crc32'], 'CRC32 mismatch')
        return data


def finite_records(records):
    require(all(not isinstance(v, float) or math.isfinite(v)
                for record in records for v in record), 'non-finite record value')


def decode(kind, data):
    p = Payload(data)
    result = {}
    if kind == 'META':
        zone, north, tx, ty = p.values('4I')
        geo = p.values('6d')
        require(zone <= 60 and north <= 1 and all(math.isfinite(x) for x in geo), 'bad metadata')
        require(abs(geo[0]) <= 90 and abs(geo[1]) <= 180 and
                (geo[2:] == (1e9, 1e9, -1e9, -1e9) or
                 all(abs(x) <= (90 if i % 2 == 0 else 180) for i, x in enumerate(geo[2:]))),
                'geographic bounds out of range')
        result = dict(zone=zone, north=bool(north), tx=tx, ty=ty,
                      origin=list(geo[:2]), bbox=list(geo[2:]), gen=p.string())
    elif kind == 'MESH':
        name, material = p.string(), p.string()
        flags, vc, pc, ic, mc, wc, oc, bc = p.values('8I')
        require(flags <= 3 and pc <= vc and ic % 3 == 0 and
                all(n in (0, vc) for n in (mc, wc, oc)) and (flags & 2 or pc == vc),
                'invalid mesh counts')
        pn = p.scalars('f', pc * 6)
        pool = p.scalars('I', vc if flags & 2 else 0)
        uv = p.scalars('f', vc * 2)
        indices = p.scalars('I', ic)
        materials = p.scalars('i', mc)
        water = p.scalars('f', wc)
        osm = p.scalars('q', oc)
        border = p.scalars('I', bc)
        require(all(i < pc for i in pool), 'pool index out of range')
        require(all(i < vc for i in indices) and all(i < vc for i in border), 'vertex index out of range')
        result = dict(name=name, material=material, solid=bool(flags & 1),
                      vertex_count=vc, pool_count=pc, triangles=ic // 3,
                      position_normal=pn, pool_indices=pool, uv=uv, indices=indices,
                      material_ids=materials, water_scale=water, osm_ids=osm, border_indices=border)
    elif kind == 'TREE':
        records = p.records(TREE, p.u32())
        finite_records(records)
        require(all(r[6] <= 1 for r in records), 'invalid tree flags')
        result = dict(fields=TREE_FIELDS, records=records)
    elif kind == 'POIS':
        names = p.strings()
        records = p.records(POI, p.u32())
        finite_records(records)
        require(all(r[0] < len(names) for r in records), 'POI kind index')
        heights = p.scalars('f', len(records)) if p.offset < len(p.data) else [0.0] * len(records)
        require(all(math.isfinite(h) and 0 <= h <= 20 for h in heights), 'POI height range')
        result = dict(kinds=names, fields=['kind_index', 'x', 'y', 'z', 'rotation'], records=records, heights=heights)
    elif kind == 'ROAD':
        n, np, nl = p.values('3I')
        records = p.records(ROAD, n)
        points = p.scalars('f', np * 2)
        widths = p.scalars('f', nl)
        finite_records(records)
        require(all(r[0] < np and r[1] < np and r[4] <= 1 and
                    r[17] <= 32 and r[16] + r[17] <= nl for r in records), 'invalid road offsets')
        result = dict(fields=ROAD_FIELDS, records=records, points_xz=points, lane_widths=widths)
    elif kind == 'RWID':
        n = p.u32()
        widths = p.records(struct.Struct('<2f'), n)
        finite_records(widths)
        require(all((a == 0 and b == 0) or (.5 <= a <= 60 and .5 <= b <= 60)
                    for a, b in widths), 'invalid road endpoint widths')
        result = dict(fields=['width_start_m', 'width_end_m'], records=widths)
    elif kind == 'BULD':
        n, np = p.values('2I')
        records = p.records(BUILDING, n)
        points = p.scalars('f', np * 2)
        finite_records(records)
        require(all(r[2] + r[3] <= np for r in records), 'invalid building offsets')
        result = dict(fields=['base_y', 'max_y', 'first_point', 'point_count'],
                      records=records, points_xz=points)
    elif kind == 'MODL':
        names = p.strings()
        records = p.records(MODEL, p.u32())
        finite_records(records)
        require(all(r[0] < len(names) for r in records), 'model filename index')
        result = dict(files=names, fields=['file_index', 'x', 'y', 'z', 'rx', 'ry', 'rz',
                                         'angle', 'sx', 'sy', 'sz'], records=records)
    elif kind == 'MHOL':
        records = p.records(MANHOLE, p.u32())
        finite_records(records)
        require(all(0 <= r[7] < 9 for r in records), 'invalid manhole kind')
        result = dict(fields=['x', 'y', 'z', 'nx', 'ny', 'nz', 'rotation', 'kind'], records=records)
    elif kind == 'BCOL':
        version, count = p.values('2I')
        require(version == 1 and count <= 8192, 'invalid building tint header')
        records = p.records(struct.Struct('<qI'), count)
        require(all(r[0] != 0 and r[1] <= 0xffffff for r in records), 'invalid building tint')
        require(len({r[0] for r in records}) == count, 'duplicate building tint')
        result = dict(version=version, buildings=[dict(osm_id=str(i), color=f'#{c:06X}') for i, c in records])
    elif kind == 'FACA':
        version, count = p.values('2I')
        require(version == 1 and 0 < count <= 4096, 'invalid facade layout header')
        facades = []
        for _ in range(count):
            r = p.values('q4d6f2I')
            finite_records([r])
            osm_id, la, lo, lb, lob, ax, az, bx, bz, depth, width, nb, nc = r
            require(osm_id != 0 and 1 <= nb <= 32 and nc <= 32, 'invalid facade arrays')
            require(-85 <= la <= 85 and -85 <= lb <= 85 and -180 <= lo <= 180 and -180 <= lob <= 180,
                    'invalid facade coordinates')
            require(1 <= math.hypot(bx-ax, bz-az) <= 2000 and .25 <= depth <= 1.5 and .4 <= width <= .951,
                    'invalid facade dimensions')
            bays = p.records(struct.Struct('<ffI'), nb)
            cornices = p.scalars('f', nc)
            finite_records(bays)
            require(all(1 <= b[0] <= 7 and -.451 <= b[1] <= .451 and b[2] < 1 << 24 and not b[2] & 1
                        for b in bays), 'invalid facade bays')
            require(all(math.isfinite(c) and 0 <= c <= 64 for c in cornices) and
                    all(a < b for a, b in zip(cornices, cornices[1:])), 'invalid cornices')
            facades.append(dict(osm_id=str(osm_id), start=[lo, la], end=[lob, lb], local_a=[ax, az],
                                local_b=[bx, bz], balcony_depth_m=depth, balcony_width=width,
                                bays=[dict(width_m=b[0], floor_shift=b[1],
                                           balcony_floors=[i for i in range(1, 24) if b[2] & (1 << i)]) for b in bays],
                                cornice_floors=list(cornices)))
        result = dict(version=version, facades=facades)
    else:
        return dict(unknown_layer=kind, bytes=len(data))
    p.finish()
    return result


def limited(value, limit):
    if isinstance(value, dict):
        return {k: (v if k == 'fields' else limited(v, limit)) for k, v in value.items()}
    if isinstance(value, (array, list, tuple)):
        if limit and len(value) > limit:
            return dict(count=len(value), first=[limited(v, 0) for v in value[:limit]])
        return [limited(v, 0) for v in value]
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('info', 'verify', 'dump', 'extract'):
        item = sub.add_parser(name)
        item.add_argument('tile', type=Path)
        if name == 'dump':
            item.add_argument('--layer', choices=sorted(REQUIRED | {'MESH', 'FACA', 'BCOL', 'RWID'}))
            item.add_argument('--index', type=int, help='directory index of one chunk')
            item.add_argument('--limit', type=int, default=20, help='items per array; 0 means all')
        if name == 'extract':
            item.add_argument('--index', type=int, required=True)
            item.add_argument('--output', type=Path, required=True)
    item = sub.add_parser('format', help='choose runtime writes; takes effect on next map load')
    item.add_argument('value', choices=['binary', 'x3d'])
    item.add_argument('--root', type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    if args.command == 'format':
        args.root.mkdir(parents=True, exist_ok=True)
        path = args.root / 'tile-cache-format.cfg'
        path.write_text(args.value + '\n', encoding='utf-8')
        print(f'{path}: {args.value}')
        return
    tile = Tile(args.tile)
    if args.command == 'extract':
        require(0 <= args.index < len(tile.entries), 'chunk index out of range')
        args.output.write_bytes(tile.raw(tile.entries[args.index]))
        return
    output = []
    for entry in tile.entries:
        if args.command == 'dump':
            if args.layer and entry['kind'] != args.layer:
                continue
            if args.index is not None and entry['index'] != args.index:
                continue
            require(args.limit >= 0, 'limit must be nonnegative')
        decoded = decode(entry['kind'], tile.raw(entry))
        if args.command == 'dump':
            output.append(dict(entry=entry, data=limited(decoded, args.limit)))
        elif args.command == 'info':
            summary = dict(entry)
            if entry['kind'] == 'MESH':
                summary.update({k: decoded[k] for k in ('name', 'material', 'solid',
                                                       'vertex_count', 'pool_count', 'triangles')})
            elif entry['kind'] == 'META':
                summary['metadata'] = decoded
            else:
                summary['count'] = len(decoded.get('records', []))
            output.append(summary)
    if args.command == 'verify':
        print(f'OK: {args.tile}, {len(tile.entries)} chunks, all CRC32/payloads checked')
    else:
        print(json.dumps(output, ensure_ascii=False, indent=2, allow_nan=False))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, struct.error, zlib.error) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
