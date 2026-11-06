"""Krylatskoye Island: retain the shipped circuit, author a sparse coastal world.

Only the baker needs Python/Shapely/NumPy. The game uses the ordinary baked
Dream World tile, shared vegetation, ground and water shaders. No runtime GPX
download, generated texture pack, or world-specific rendering path is needed.
"""
from pathlib import Path
from functools import lru_cache
from collections import Counter
import argparse
import hashlib
import json
import math
import random
import xml.etree.ElementTree as ET
import numpy as np
from shapely.geometry import Point, Polygon, LineString, box
from shapely.prepared import prep
from shapely.ops import unary_union
import bake_castle as b

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'rezvivo-osm-bckl/data/ready-routes/krylatskoye-small-circuit.gpx'
DESTINATION = ROOT / 'rezvivo-osm-bckl/data/dream-worlds/krylatskoye-island'
WIDTH = 5.5
SEED = 6112026
RNG = random.Random(SEED)


def smooth(a, c, x):
    t = max(0., min(1., (x-a)/(c-a)))
    return t*t*(3-2*t)


def mesh(name, material, ground=-1, grass=-1, water=False, walkable=True):
    result = b.mesh(name, material, walkable, water, ground, -1)
    result['deform_island'] = False
    if grass >= 0:
        result['grass_kind'] = grass
    return result


def spline_course(points, spacing=1.25):
    """Periodic cubic Hermite centreline, sampled in metres, including heights.

    Plan tangents use neighbouring chord lengths. Height tangents use the
    shape-preserving PCHIP harmonic mean, so a crest cannot overshoot its FIT
    heights. Both sides of the closing seam share exactly the same tangent.
    """
    p = np.asarray(points[:-1], dtype=float)
    delta = np.roll(p, -1, axis=0)-p
    step = np.linalg.norm(delta[:, (0, 2)], axis=1)
    assert np.all(step > .01), 'duplicate source stations'
    secant = delta/step[:, None]
    previous_step = np.roll(step, 1)
    previous = np.roll(secant, 1, axis=0)
    tangent = (previous*step[:, None]+secant*previous_step[:, None])/(step+previous_step)[:, None]
    for i in range(len(p)):
        left, right = previous[i, 1], secant[i, 1]
        if left*right <= 0:
            tangent[i, 1] = 0
        else:
            w1, w2 = 2*step[i]+previous_step[i], step[i]+2*previous_step[i]
            tangent[i, 1] = (w1+w2)/(w1/left+w2/right)
    result = []
    for i, start in enumerate(p):
        end, m0, m1 = p[(i+1) % len(p)], tangent[i]*step[i], tangent[(i+1) % len(p)]*step[i]
        n = max(2, math.ceil(step[i]/spacing))
        for t in np.linspace(0, 1, n, endpoint=False):
            result.append(tuple((2*t**3-3*t*t+1)*start+(t**3-2*t*t+t)*m0+
                                (-2*t**3+3*t*t)*end+(t**3-t*t)*m1))
    result.append(result[0])
    curve = LineString([(p[0], p[2]) for p in result])
    original = LineString([(p[0], p[2]) for p in points])
    assert curve.is_simple, 'spline introduced a crossing'
    deviation = max(original.distance(Point(q[0], q[2])) for q in result)
    assert deviation < 1.0, ('spline departed from reference', deviation)
    assert min(q[1] for q in result) >= p[:, 1].min()-1e-7
    assert max(q[1] for q in result) <= p[:, 1].max()+1e-7
    return result, deviation


def read_course(source):
    original = np.array([(float(p.attrib['lat']), float(p.attrib['lon']),
                          float(p.find('{*}ele').text))
                         for p in ET.parse(source).iter('{http://www.topografix.com/GPX/1/1}trkpt')])
    assert len(original) >= 4 and np.isfinite(original).all()
    lat, lon = original[:-1, :2].mean(axis=0)
    factor = math.pi/180*6371008.8
    points = np.column_stack(((original[:, 1]-lon)*factor*math.cos(math.radians(lat)),
                              original[:, 2]-original[:, 2].min()+8.,
                              -(original[:, 0]-lat)*factor))
    assert np.linalg.norm(points[0]-points[-1]) < .05, 'source must already be a loop'
    points[-1] = points[0]
    # GPX sample density varies abruptly. Uniform stations prevent a tiny
    # recording segment from imposing a sharp kink on an otherwise wide bend.
    stations = np.r_[0., np.cumsum(np.linalg.norm(np.diff(points[:, (0, 2)], axis=0), axis=1))]
    regular = np.linspace(0., stations[-1], round(stations[-1]/6.)+1)
    controls = np.column_stack([np.interp(regular, stations, points[:, j]) for j in range(3)])
    controls[-1] = controls[0]
    route, _ = spline_course(controls)
    original_line = LineString(points[:, (0, 2)])
    deviation = max(original_line.distance(Point(q[0], q[2])) for q in route)
    assert deviation < 1., ('spline departed from source', deviation)
    return route, points, dict(source_filename=source.name, sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
        latitude=float(lat), longitude=float(lon), source_points=len(original),
        original_elevation_min_m=float(original[:, 2].min()),
        original_elevation_max_m=float(original[:, 2].max()),
        elevation_offset_m=float(8-original[:, 2].min()),
        interpolation='periodic-hermite-xz-pchip-height', max_sample_spacing_m=1.25,
        control_spacing_m=6., max_plan_deviation_m=deviation)


def organic_patch(x, z, rx, rz, phase):
    return Polygon([(x+rx*math.cos(t)*(1+.12*math.sin(3*t+phase)+.065*math.cos(5*t-phase)),
                     z+rz*math.sin(t)*(1+.10*math.cos(4*t+phase)))
                    for t in np.linspace(0, math.tau, 64, endpoint=False)])


def build_road(route):
    road = mesh('island_circuit', 'asphalt', ground=13)
    road['road_id'] = 71001
    sections = []
    n = len(route)-1
    for i, p in enumerate(route[:-1]):
        a, c = route[(i-1) % n], route[(i+1) % n]
        dx, dz = c[0]-a[0], c[2]-a[2]
        length = math.hypot(dx, dz)
        sections.append([(p[0]-side*dz/length*WIDTH/2, p[1],
                          p[2]+side*dx/length*WIDTH/2) for side in (-1, 0, 1)])
    for i in range(n):
        a, c = sections[i], sections[(i+1) % n]
        for j in range(2):
            b.face(road, [a[j], a[j+1], c[j+1], c[j]])
    footprint = b.road_footprint(['island_circuit'])
    assert footprint.is_valid
    assert footprint.geom_type == 'Polygon', 'disconnected track surface'
    return footprint


class Island:
    def __init__(self, route, original, pavement):
        self.route = route
        self.pavement = pavement
        self.line = LineString([(p[0], p[2]) for p in route])
        assert self.line.is_simple, 'source loop self-intersects'
        # Close the small internal hairpin inlets, retain the broad outer shape.
        # The shore is an offset of the real course, not an unrelated circle.
        outer = Polygon(self.line).buffer(145, quad_segs=20).buffer(-55, quad_segs=20)
        self.land = Polygon(outer.exterior).simplify(.6, preserve_topology=True)
        self.inside = prep(self.land)
        self.coast = self.land.boundary
        self.points = original[:-1, (0, 2)]
        self.heights = original[:-1, 1]
        self.road_surface = b.GroundSampler(['island_circuit'])
        self.edge = b.SurfaceBoundary(pavement, self.road_surface)
        self.grade_area = prep(pavement.buffer(28))
        self.groves = [(-355, -130, 42, 55, (0, 1)),
                       (-245, -270, 56, 34, (1, 8)),
                       (-25, -255, 53, 40, (2, 12)),
                       (250, -170, 43, 50, (2, 5)),
                       (310, 15, 35, 45, (3, 1)),
                       (100, 150, 44, 32, (0, 13)),
                       (-195, 75, 36, 36, (1, 0))]

    @lru_cache(maxsize=None)
    def height(self, x, z):
        depth = self.coast.distance(Point(x, z))
        delta = self.points-(x, z)
        weights = 1./(np.sum(delta*delta, axis=1)+30.**2)**1.5
        interior = float(np.dot(weights, self.heights)/weights.sum())
        interior += 1.4*math.sin(x*.014+z*.006)*math.cos(z*.011)
        y = -.35+2.*smooth(0, 22, depth)
        y += (interior-1.65)*smooth(20, 100, depth)
        if self.grade_area.covers(Point(x, z)):
            road_y, distance = self.edge(x, z)
            y += (road_y-y)*(1-smooth(0, 28, distance))
        return y

    def habitats(self):
        # Partition whole organic regions before triangulation. Choosing a
        # material per grid cell produces the conspicuous checkerboard we avoid.
        remaining = self.land.difference(self.pavement)
        regions = []

        def take(name, area, material, ground, grass=-1):
            nonlocal remaining
            area = area.intersection(remaining)
            if area.is_empty:
                return
            remaining = remaining.difference(area)
            regions.append((mesh(name, material, ground, grass), area))

        coast_band = self.land.difference(self.land.buffer(-33))
        rocks = unary_union([organic_patch(-465, -120, 105, 125, .8),
                             organic_patch(425, -210, 100, 110, 1.4),
                             organic_patch(-150, 315, 80, 50, 2.2)])
        take('rocky_headlands', coast_band.intersection(rocks), 'rock', 10)
        take('sand_beaches', self.land.difference(self.land.buffer(-20)), 'sand', 3)
        take('dune_grass', self.land.difference(self.land.buffer(-43)), 'sandy_soil', 22, 2)
        take('gravel_shoulders', self.pavement.buffer(.5), 'gravel', 11)
        take('short_verges', self.pavement.buffer(2.8), 'meadow', 0, 6)
        groves = unary_union([organic_patch(x, z, rx, rz, i*.7)
                              for i, (x, z, rx, rz, _) in enumerate(self.groves)])
        take('woodland_undergrowth', groves, 'woodland', 2, 1)
        flowers = unary_union([organic_patch(x, z, rx, rz, i*.8)
                               for i, (x, z, rx, rz) in enumerate([
                                   (-225, -88, 70, 28), (42, -200, 65, 22),
                                   (175, -80, 40, 60), (-75, 210, 36, 28)])])
        take('blue_wildflower_meadows', flowers, 'flowers', 9, 3)
        pink = unary_union([organic_patch(-270, 50, 38, 55, 1.5),
                            organic_patch(255, 120, 55, 32, 2.5),
                            organic_patch(-60, -100, 44, 30, .4)])
        take('pink_wildflower_meadows', pink, 'flowers', 9, 7)
        dry = unary_union([organic_patch(-100, -10, 65, 85, 1.),
                           organic_patch(-420, 45, 80, 48, 2.),
                           organic_patch(140, 215, 95, 45, 3.)])
        take('tall_dry_grass', dry, 'dry_meadow', 1, 5)
        soil = unary_union([organic_patch(-115, 265, 24, 22, .4),
                            organic_patch(220, -250, 32, 18, .9)])
        take('exposed_earth', soil, 'soil', 4)
        take('open_meadows', remaining, 'meadow', 1, 0)
        return regions


def build_terrain(island, habitats):
    counts = {}
    # Every region uses the same six-metre lattice. Shared edge coordinates
    # evaluate the same height; the road is cut out, never painted over a hill.
    for target, region in habitats:
        prepared = prep(region)
        min_x, min_z, max_x, max_z = region.bounds
        cells = 0
        for x in range(math.floor(min_x/6)*6, math.ceil(max_x/6)*6, 6):
            for z in range(math.floor(min_z/6)*6, math.ceil(max_z/6)*6, 6):
                cell = box(x, z, x+6, z+6)
                if not prepared.intersects(cell):
                    continue
                part = cell if prepared.covers(cell) else region.intersection(cell)
                for triangle in b.triangles_inside(part):
                    b.face(target, [(px, island.height(round(px, 8), round(pz, 8)), pz)
                                    for px, pz in reversed(triangle)])
                cells += 1
        counts[next(name for name, m in b.MESHES.items() if m is target)] = cells
    return counts


def vegetation(island, ground):
    occupied = []
    types = Counter()

    def place(x, z, species, size, shrub=False):
        p = Point(x, z)
        if not island.inside.covers(p) or island.coast.distance(p)<37:
            return False
        radius = size*(4.7 if shrub else .75)
        if island.pavement.distance(p)<radius+1. or any(
                (x-a)**2+(z-c)**2 < (radius*.55+r*.55+1.2)**2 for a, c, r in occupied):
            return False
        try:
            y = ground(x, z)
            if max(abs(ground(x+dx, z+dz)-y) for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)))>1:
                return False
        except ValueError:
            return False
        b.TREES.append(dict(kind='shrub' if shrub else 'tree', gpu_type=species,
                            v=[x, y, z, size, RNG.random()*math.tau, 0]))
        occupied.append((x, z, radius))
        types[species] += 1
        return True

    for x, z, rx, rz, species in island.groves:
        count = 0
        for _ in range(500):
            angle = RNG.random()*math.tau
            r = math.sqrt(RNG.random())
            if place(x+math.cos(angle)*rx*r, z+math.sin(angle)*rz*r,
                     RNG.choice(species), RNG.uniform(7., 12.5)):
                count += 1
                if count == 20:
                    break
    # Solitary trees mark a few turns, without creating an unbroken wall.
    for distance in np.arange(75, island.line.length, 300):
        p = island.line.interpolate(float(distance))
        x, z = p.x, p.y
        place(x+RNG.uniform(-22, 22), z+RNG.uniform(-22, 22),
              RNG.choice((0, 1, 12, 13)), RNG.uniform(6.5, 10.))
    min_x, min_z, max_x, max_z = island.land.bounds
    shrubs = 0
    for _ in range(3000):
        if place(RNG.uniform(min_x, max_x), RNG.uniform(min_z, max_z),
                 RNG.choice((6, 7)), RNG.uniform(.65, 1.15), shrub=True):
            shrubs += 1
            if shrubs == 85:
                break
    return dict(sorted(types.items()))


def coastal_stones(island, ground):
    rocks = mesh('shore_boulders', 'rock', ground=10, walkable=False)
    rocks['cast_shadow'] = True
    count = 0
    for _ in range(170):
        p = island.coast.interpolate(RNG.random()*island.coast.length)
        nearest = island.land.representative_point()
        dx, dz = nearest.x-p.x, nearest.y-p.y
        length = math.hypot(dx, dz)
        inset = RNG.uniform(4, 26)
        x, z = p.x+inset*dx/length, p.y+inset*dz/length
        if not island.inside.covers(Point(x, z)) or island.pavement.distance(Point(x, z))<8:
            continue
        try:
            y = ground(x, z)
        except ValueError:
            continue
        radius = RNG.uniform(.45, 1.8)
        yaw = RNG.random()*math.tau
        rings = []
        for scale, h in ((.8, -.3), (1., .15), (.48, .8)):
            rings.append([(x+math.cos(yaw+i*math.tau/7)*radius*scale*RNG.uniform(.85, 1.15),
                           y+radius*h, z+math.sin(yaw+i*math.tau/7)*radius*scale*RNG.uniform(.85, 1.15))
                          for i in range(7)])
        for low, high in zip(rings, rings[1:]):
            for j in range(7):
                b.face(rocks, [low[j], high[j], high[(j+1)%7], low[(j+1)%7]])
        b.face(rocks, list(reversed(rings[-1])))
        count += 1
    return count


def weld(terrain_names):
    sums = {}
    for name in terrain_names:
        for p, n in zip(b.MESHES[name]['vertices'], b.MESHES[name]['normals']):
            key = tuple(round(v, 5) for v in p)
            total = sums.setdefault(key, [0., 0., 0.])
            for k in range(3):
                total[k] += n[k]
    for name, m in b.MESHES.items():
        table, vertices, normals, uv, remap = {}, [], [], [], []
        for p, n, t in zip(m['vertices'], m['normals'], m['uv']):
            if name in terrain_names:
                normal = sums[tuple(round(v, 5) for v in p)]
                length = math.sqrt(sum(v*v for v in normal))
                n = tuple(v/max(length, 1e-9) for v in normal)
            key = tuple(round(v, 6) for v in (*p, *n, *t))
            index = table.get(key)
            if index is None:
                index = len(vertices)
                table[key] = index
                vertices.append(p); normals.append(n); uv.append(t)
            remap.append(index)
        m.update(vertices=vertices, normals=normals, uv=uv,
                 indices=[remap[i] for i in m['indices']])


def validate(route, island, habitats):
    surface = b.GroundSampler([n for n, m in b.MESHES.items() if m['walkable']])
    errors = []
    for i, a in enumerate(route[:-1]):
        c = route[i+1]
        dx, dz = c[0]-a[0], c[2]-a[2]
        length = math.hypot(dx, dz)
        for t in (.0, .5):
            for offset in (-2.45, -1.2, 0, 1.2, 2.45):
                x = a[0]+dx*t-dz/length*offset
                z = a[2]+dz*t+dx/length*offset
                error = abs(surface(x, z)-(a[1]+(c[1]-a[1])*t))
                assert error < .12, ('course contact', i, offset, error)
                errors.append(error)
    covered = unary_union([region for _, region in habitats]+[island.pavement])
    assert island.land.symmetric_difference(covered).area < .01, 'uncovered or overlapping land'
    assert island.land.covers(island.pavement), 'road extends beyond shore'
    assert len(b.TREES)<260, 'sparse vegetation budget exceeded'
    for t in b.TREES:
        x, y, z = t['v'][:3]
        assert abs(surface(x, z)-y)<.002, 'floating vegetation'
    return dict(contact_samples=len(errors), max_contact_error_m=max(errors),
                coast_clearance_m=island.pavement.distance(island.coast),
                land_area_m2=island.land.area, land_bounds=island.land.bounds,
                habitat_area_m2={next(n for n, v in b.MESHES.items() if v is m): region.area
                                  for m, region in habitats})


def build(destination, source, report_dir):
    b.MESHES.clear(); b.TREES.clear(); RNG.seed(SEED)
    b.PALETTE.clear()
    b.PALETTE.update(meadow=([.34, .46, .23], .98), woodland=([.27, .36, .20], .98),
                     flowers=([.40, .50, .28], .97), dry_meadow=([.49, .46, .28], .98),
                     sandy_soil=([.58, .53, .37], .98), sand=([.75, .69, .53], .98),
                     rock=([.43, .43, .38], .96), soil=([.40, .32, .23], .98),
                     gravel=([.48, .46, .40], .95), asphalt=([.35, .36, .37], .90),
                     water=([.06, .30, .35], .20))
    route, original, source_info = read_course(source)
    pavement = build_road(route)
    island = Island(route, original, pavement)
    habitats = island.habitats()
    print('Course and habitat regions ready', flush=True)
    cell_counts = build_terrain(island, habitats)
    print('Terrain ready', sum(cell_counts.values()), 'cells', flush=True)
    terrain_names = set(b.MESHES)-{'island_circuit'}
    ground = b.GroundSampler(list(terrain_names))
    species = vegetation(island, ground)
    stones = coastal_stones(island, ground)
    ocean = mesh('ocean', 'water', water=True, walkable=False)
    ocean['water_scale'] = 1.
    b.face(ocean, [(-6000, 0, -6000), (-6000, 0, 6000), (6000, 0, 6000), (6000, 0, -6000)])
    weld(terrain_names | {'island_circuit'})
    validation = validate(route, island, habitats)
    length = sum(math.dist(a, c) for a, c in zip(route, route[1:]))
    ascent = sum(max(0, c[1]-a[1]) for a, c in zip(route, route[1:]))
    manifest = dict(id='krylatskoye-island', revision=2, coastal=True, road_condition=2,
        title='Крылатский остров',
        title_en='Krylatskoye Island',
        description='4,3 км: повороты и перепады высот малого кольца Крылатского на морском острове. Открытые луга, редкие рощи, цветы, сухие травы и песчано-каменистый берег.',
        description_en='4.3 km: the turns and elevation profile of the Krylatskoye small circuit on a sea island. Open meadows, sparse groves, wildflowers, dry grasses and sandy, rocky shores.',
        sun=[-.55, .75, -.35], preview=dict(position=[-860, 840, 910], target=[0, 15, 0]),
        route=dict(id='krylatskoye-island-circuit', title='Кольцо Крылатского на острове',
                   closed=True, width=WIDTH, points=route, length_m=length, ascent_m=ascent),
        road_profiles=[dict(id=71001, width=WIDTH, surface=[1, 1, 0, 1, 4, 0, 1, 2],
                            points=[(p[0], p[2]) for p in route])],
        source_route=source_info,
        coastal_audio=dict(shoreline=[(x, 0., z) for x, z in island.land.exterior.coords],
                           full_distance_m=25, fade_distance_m=110, height_fade_m=70),
        landscape=dict(seed=SEED, tree_budget=165, shrub_budget=85,
                       species_counts=species, habitat_cells=cell_counts))
    report = b.write_package(destination, manifest, 'island.x3d', placements=[])
    report.update(validation, source=source_info, ascent_m=ascent, species=species,
                  boulders=stones, min_height_m=min(p[1] for p in route),
                  max_height_m=max(p[1] for p in route),
                  max_grade=max(abs(c[1]-a[1])/math.hypot(c[0]-a[0], c[2]-a[2])
                                for a, c in zip(route, route[1:])))
    report_dir.mkdir(parents=True, exist_ok=True)
    (report_dir/'bake-report.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    (report_dir/'coast.json').write_text(json.dumps(list(island.land.exterior.coords)), encoding='utf-8')
    print(json.dumps(report, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', type=Path, default=DESTINATION)
    parser.add_argument('--source', type=Path, default=SOURCE)
    parser.add_argument('--report-dir', type=Path,
                        default=ROOT/'rezvivo-osm-bckl/tests/artifacts/krylatskoye-island-20261106')
    args = parser.parse_args()
    build(args.destination, args.source, args.report_dir)
