"""Bake the first Dream World into the existing O3D tile-cache format.

Offline authoring tool: the game only reads the resulting geometry.
All coordinates and routes are local metres; no geographic data is used.
"""
from pathlib import Path
import argparse, hashlib, json, math, random
from xml.sax.saxutils import escape
from shapely.geometry import MultiPoint, Point, Polygon, LineString, box as rectangle
from shapely.ops import unary_union, triangulate
from shapely.prepared import prep
from shapely.strtree import STRtree
from shapely import set_precision

TAU = math.tau
RNG = random.Random(70319)
N = 720
RADIUS = 1000 / (2 * N * math.sin(math.pi / N))
COAST_LENGTH = 1300
CASTLE_CENTER = (-44.0, 34.0)
SEA_EXITS = (28, 42, 34, 50, 31, 39)
ACTIVE_SPOKES = (0, 2, 4)
DIRT_SPOKE = 2
PIER_EXIT = 0
EXIT_HALF_ANGLE = 2 * TAU / N
MESHES = {}
TREES = []
ARCHES = []
ROUTE_SECTIONS = []
GROUND = None
PAVEMENT = None
PALETTE = {
    'grass': ([.34,.46,.21], .96), 'grass_light': ([.43,.54,.27], .98),
    'sand': ([.66,.61,.45], .94), 'rock': ([.38,.42,.40], .9),
    'stone': ([.65,.63,.53], .86), 'stone_light': ([.75,.72,.61], .8),
    'stone_dark': ([.48,.49,.45], .92), 'paving': ([.62,.61,.55], .8),
    'water': ([.06,.29,.35], .2), 'dirt': ([.45,.35,.25], .95),
    'pier_frame': ([.19,.13,.075], .92), 'mooring_rope': ([.52,.44,.29], .95),
    'old_oak': ([.26,.19,.11], .94), 'iron': ([.12,.14,.13], .8),
    'mortar': ([.36,.355,.315], 1.0),
}
for i in range(7):
    PALETTE['pier_board'+str(i)] = ([.33+i*.012,.245+i*.010,.16+i*.008], .9)
for i, color in enumerate(((.43,.42,.37),(.47,.46,.41),(.50,.48,.43),
                           (.45,.45,.41),(.52,.50,.45),(.46,.43,.37))):
    PALETTE['masonry'+str(i)] = (color, .97)

def coast_outline(t):
    """Broad headlands and bays, without repeated small scallops."""
    r=1+.15*math.sin(2*t+.4)+.10*math.cos(3*t-.8)+.045*math.sin(5*t+1.1)
    return (1.12*r*math.cos(t), .90*r*math.sin(t))

_outline=[coast_outline(TAU*i/N) for i in range(N+1)]
COAST_SCALE=COAST_LENGTH/sum(math.dist(a,b) for a,b in zip(_outline,_outline[1:]))

def island_point(p):
    """Offline map of the old authoring coordinates onto the new island.

    The entire fortress stays rigid. The hillside fans out from its displaced
    plateau to the shore. The promenade uses true normal offsets, so it stays
    seven metres wide instead of stretching with the coastline.
    """
    x,y,z=p;r=math.hypot(x,z);cx,cz=CASTLE_CENTER
    if r<=50:return (x+cx,y,z+cz)
    a=math.atan2(z,x);co,si=x/r,z/r
    qx,qz=coast_outline(a);qx*=COAST_SCALE;qz*=COAST_SCALE
    lo=coast_outline(a-.00001);hi=coast_outline(a+.00001)
    dx,dz=hi[0]-lo[0],hi[1]-lo[1];d=math.hypot(dx,dz)
    nx,nz=dz/d,-dx/d
    if r>=RADIUS-3.5:return (qx+(r-RADIUS)*nx,y,qz+(r-RADIUS)*nz)
    # Linear interpolation keeps the annular strips ordered even on the short
    # side of the hill; a smoothstep here can fold the terrain back on itself.
    u=(r-50)/(RADIUS-3.5-50)
    return ((1-u)*(cx+50*co)+u*(qx-3.5*nx),y,
            (1-u)*(cz+50*si)+u*(qz-3.5*nz))

def mesh(name, material, walkable=False, water=False, ground=-1, grass=-1):
    if name not in MESHES:
        MESHES[name] = dict(vertices=[], normals=[], uv=[], indices=[], material=material,
                            walkable=walkable, water=water, ground_material=ground, grass_material=grass)
    return MESHES[name]

def face(m, points, texcoords=None):
    if not m['water'] and m.get('deform_island',True):points=[island_point(p) for p in points]
    a,b,c = points[:3]
    u=[b[i]-a[i] for i in range(3)];v=[c[i]-a[i] for i in range(3)]
    n=[u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]]
    length=math.sqrt(sum(x*x for x in n))
    if length < 1e-9:return
    n=[x/length for x in n];start=len(m['vertices'])
    m['vertices'].extend(points);m['normals'].extend([n]*len(points))
    m['uv'].extend(texcoords if texcoords is not None else [(p[0]/3,p[2]/3) for p in points])
    for i in range(1,len(points)-1):m['indices'].extend((start,start+i,start+i+1))

def box(m,x,y,z,sx,sy,sz,yaw=0):
    co,si=math.cos(yaw),math.sin(yaw)
    p=[(x+dx*co-dz*si,y+dy,z+dx*si+dz*co)
       for dx,dy,dz in [(-sx/2,0,-sz/2),(-sx/2,0,sz/2),(sx/2,0,sz/2),(sx/2,0,-sz/2),
                        (-sx/2,sy,-sz/2),(-sx/2,sy,sz/2),(sx/2,sy,sz/2),(sx/2,sy,-sz/2)]]
    if blocks_road(m,p):return
    for f in [(0,3,2,1),(4,5,6,7),(0,1,5,4),(3,7,6,2),(0,4,7,3),(1,2,6,5)]:face(m,[p[i] for i in f])

def blocks_road(m, points):
    """Reject a whole stone, including chipped corners/caps, after deformation."""
    keepout=m.get('road_keepout')
    if keepout is None:return False
    if m.get('deform_island',True):points=[island_point(p) for p in points]
    return keepout.intersects(MultiPoint([(p[0],p[2]) for p in points]).convex_hull)

def road_footprint(names):
    """Actual baked pavement in metres, including skewed junctions and piers."""
    triangles=[]
    for name in names:
        m=MESHES[name];vertices=m['vertices'];indices=m['indices']
        for i in range(0,len(indices),3):
            p=Polygon([(vertices[j][0],vertices[j][2]) for j in indices[i:i+3]])
            if p.area>1e-10:triangles.append(p)
    return unary_union(triangles)

def vegetation_radius(instance):
    # Runtime shrub cards are 5 m wide and offset from the instance centre.
    # Their full near-LOD rotation envelope is 4.67505 m at scale=1 (not 2.5).
    # Tree cards are 1 m wide. Keep the entire canopy off the pavement.
    return instance['v'][3]*(4.7 if instance['kind']=='shrub' else .75)

def cylinder(m,x,y,z,r0,r1,height,segments=24,top=True):
    for i in range(segments):
        a,b=TAU*i/segments,TAU*(i+1)/segments
        p=lambda r,h,t:(x+r*math.cos(t),y+h,z+r*math.sin(t))
        face(m,[p(r0,0,a),p(r1,height,a),p(r1,height,b),p(r0,0,b)])
        if top and r1>0:face(m,[(x,y+height,z),p(r1,height,b),p(r1,height,a)])

def stone(name='stone'):return mesh(name,name)

def height(r):
    if r<=48:return 12.0
    if r<144:
        u=(r-48)/96;return 12-11.04*u*u*(3-2*u)
    return .96

def ribbon(m,points,width):
    sections=[]
    for i,p in enumerate(points):
        a,b=points[max(0,i-1)],points[min(len(points)-1,i+1)]
        dx,dz=b[0]-a[0],b[2]-a[2];d=math.hypot(dx,dz)
        nx,nz=-dz/d*width/2,dx/d*width/2
        # Shared cross-sections close the outside of bends. Both shoulders use
        # the centreline height, never the ungraded hillside under each edge.
        sections.append([(p[0]+side*nx,p[1],p[2]+side*nz) for side in (-1,0,1)])
    along=0.0
    for i,(a,b) in enumerate(zip(sections,sections[1:])):
        end=along+math.dist(points[i],points[i+1])
        # Oriented road materials clamp U across the road and repeat V along it.
        # World-XZ UVs sample only the green feathered edge of the dirt atlas.
        for j in range(2):
            uv=[(j/2,along/4),((j+1)/2,along/4),((j+1)/2,end/4),(j/2,end/4)] if m['ground_material']==31 else None
            face(m,[a[j],a[j+1],b[j+1],b[j]],uv)
        along=end

def masonry(rng, name='ruins'):
    material='masonry'+str(rng.randrange(6))
    return mesh(name+'_'+material,material)


def triangles_inside(region):
    """Keep polygon edges intact; split holes before ear-clipping their pieces."""
    def cross(a,b,c):return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
    def parts(g):
        if g.geom_type=='Polygon':
            if g.area<1e-9:return
            if not g.interiors:yield g
            else:
                for candidate in triangulate(g):
                    yield from parts(candidate.intersection(g))
        else:
            for part in getattr(g,'geoms',[]):
                if part.geom_type in ('Polygon','MultiPolygon','GeometryCollection'):yield from parts(part)
    for part in parts(region):
        q=list(part.exterior.coords)[:-1]
        if sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(q,q[1:]+q[:1]))<0:q.reverse()
        while len(q)>3:
            for i in range(len(q)):
                a,b,c=q[i-1],q[i],q[(i+1)%len(q)]
                if cross(a,b,c)<=1e-10:continue
                # Boundary points are height constraints too. An ear diagonal
                # must not skip a collinear point with its own road elevation.
                if any(cross(a,b,p)>=-1e-10 and cross(b,c,p)>=-1e-10 and cross(c,a,p)>=-1e-10
                       for j,p in enumerate(q) if j not in ((i-1)%len(q),i,(i+1)%len(q))):continue
                yield [a,b,c];q.pop(i);break
            else:
                # GEOS can return redundant collinear boundary points.
                i=min(range(len(q)),key=lambda j:abs(cross(q[j-1],q[j],q[(j+1)%len(q)])))
                assert abs(cross(q[i-1],q[i],q[(i+1)%len(q)]))<1e-7
                q.pop(i)
        if abs(cross(*q))>1e-10:yield q


def mortar_wall(region,cx,cy,cz,yaw,depth):
    """A continuous recessed wall core, including the sides of real openings."""
    m=mesh('fortress_mortar','mortar');co,si=math.cos(yaw),math.sin(yaw)
    def p(x,y,z):return (cx+x*co-z*si,cy+y,cz+x*si+z*co)
    for tri in triangles_inside(region):
        face(m,[p(x,y,-depth/2) for x,y in reversed(tri)])
        face(m,[p(x,y,depth/2) for x,y in tri])
    for part in ([region] if region.geom_type=='Polygon' else getattr(region,'geoms',[])):
        if part.geom_type!='Polygon':continue
        for ring in [part.exterior]+list(part.interiors):
            q=list(ring.coords)[:-1]
            # Exterior CCW, holes CW, so normals face away from the solid.
            ccw=sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(q,q[1:]+q[:1]))>0
            if ccw!=(ring==part.exterior):q.reverse()
            for a,b in zip(q,q[1:]+q[:1]):
                face(m,[p(*a,-depth/2),p(*b,-depth/2),p(*b,depth/2),p(*a,depth/2)])


def mortar_shell(cells,x,z,r,thick,base=12,wrap=False,openings=()):
    """Tessellate a joined annular core, without closing slits or ruined tops."""
    region=unary_union([set_precision(cell,1e-8) for cell in cells])
    if openings:region=region.difference(unary_union([set_precision(hole,1e-8) for hole in openings]))
    if wrap:
        from shapely.affinity import translate
        region=unary_union([region,set_precision(translate(region,xoff=-TAU),1e-8)]).intersection(rectangle(0,0,TAU,100))
    m=mesh('fortress_mortar','mortar')
    def p(a,h,rad):return (x+rad*math.cos(a),base+h,z+rad*math.sin(a))
    # Long triangles must not cut through the inside of a round tower.
    lo,_,hi,_=region.bounds;n=max(1,math.ceil((hi-lo)*r/.7))
    for i in range(n):
        part=region.intersection(rectangle(lo+(hi-lo)*i/n,-1,lo+(hi-lo)*(i+1)/n,100))
        for tri in triangles_inside(part):
            face(m,[p(a,h,r) for a,h in reversed(tri)])
            face(m,[p(a,h,r-thick) for a,h in tri])
    for part in ([region] if region.geom_type=='Polygon' else getattr(region,'geoms',[])):
        if part.geom_type!='Polygon':continue
        for ring in [part.exterior]+list(part.interiors):
            q=list(ring.coords)[:-1]
            ccw=sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(q,q[1:]+q[:1]))>0
            if ccw!=(ring==part.exterior):q.reverse()
            for a,b in zip(q,q[1:]+q[:1]):
                ts=[0,1]
                if abs(b[0]-a[0])>1e-9:
                    ts+= [(lo+(hi-lo)*i/n-a[0])/(b[0]-a[0]) for i in range(1,n)
                           if min(a[0],b[0])<lo+(hi-lo)*i/n<max(a[0],b[0])]
                ts.sort()
                for t0,t1 in zip(ts,ts[1:]):
                    c=tuple(a[k]+(b[k]-a[k])*t0 for k in range(2))
                    d=tuple(a[k]+(b[k]-a[k])*t1 for k in range(2))
                    face(m,[p(*c,r),p(*d,r),p(*d,r-thick),p(*c,r-thick)])


def chipped_block(m,x,y,z,sx,sy,sz,yaw,rng,broken=False):
    """Solid stone, with a clipped corner and an uneven fracture on top."""
    if not broken:
        box(m,x,y,z,sx,sy,sz,yaw)
        return
    cut=rng.uniform(.18,.45)
    outline=[(-.5,-.5),(-.5,.5),(.5,.5),(.5,-.5+cut),(.5-cut,-.5)]
    co,si=math.cos(yaw),math.sin(yaw)
    bottom=[(x+u*sx*co-v*sz*si,y,z+u*sx*si+v*sz*co) for u,v in outline]
    top=[(p[0]+rng.uniform(-.025,.025),y+sy*rng.uniform(.48,1),p[2]+rng.uniform(-.025,.025)) for p in bottom]
    if blocks_road(m,bottom+top):return
    face(m,list(reversed(bottom)))
    face(m,top)
    for i in range(len(top)):
        j=(i+1)%len(top);face(m,[bottom[i],bottom[j],top[j],top[i]])


def extrude_xy(m, outline, cx, cy, cz, yaw, depth):
    """Outward faces of a stone extruded along the passage, including reveals."""
    if sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(outline,outline[1:]+outline[:1]))<0:
        outline=list(reversed(outline))
    co,si=math.cos(yaw),math.sin(yaw)
    def p(x,y,z):return(cx+x*co-z*si,cy+y,cz+x*si+z*co)
    polygon=Polygon(outline)
    for q in triangles_inside(polygon):
        face(m,[p(x,y,-depth/2) for x,y in reversed(q)])
        face(m,[p(x,y,depth/2) for x,y in q])
    for a,b in zip(outline,outline[1:]+outline[:1]):
        face(m,[p(*a,-depth/2),p(*b,-depth/2),p(*b,depth/2),p(*a,depth/2)])


def arch(cx,cy,cz,yaw,width=6,height_top=6,depth=3,broken=False):
    rng=random.Random(int(cx*131+cz*761)+9201)
    co,si=math.cos(yaw),math.sin(yaw)
    # Local x is across the passage, z along it. Actual opening under the arch.
    r=width/2;s=height_top-r
    name='arch_'+str(len(ARCHES))
    ARCHES.append(dict(center=list(island_point((cx,cy,cz))),yaw=yaw,width=width,
                       spring=s,crown=height_top,depth=depth,broken=broken,name=name))
    core=[]
    for side in (-1,1):
        px,pz=side*(r+.7)*co,side*(r+.7)*si
        rows=math.ceil(s/.65)
        for row in range(rows):
            box(masonry(rng,'arches'),cx+px,cy+row*s/rows,cz+pz,1.4,s/rows-.018,depth,yaw)
        center=side*(r+.7)
        core.append(rectangle(center-.7,0,center+.7,s+.002))
    # Odd count gives a real central keystone. Joints radiate from the spring,
    # and the front/underside normals point OUT of each wedge, not into it.
    for i in range(19):
        a,b=math.pi*i/19+.003,math.pi*(i+1)/19-.003
        ring=[(r*math.cos(a),s+r*math.sin(a)),((r+1.4)*math.cos(a),s+(r+1.4)*math.sin(a)),
              ((r+1.4)*math.cos(b),s+(r+1.4)*math.sin(b)),(r*math.cos(b),s+r*math.sin(b))]
        if broken and 4<=i<=14:continue
        m=mesh('arch_keystones','stone_light') if i==9 else masonry(rng,'arches')
        extrude_xy(m,ring,cx,cy,cz,yaw,depth+(.14 if i==9 else 0))
        a,b=math.pi*i/19,math.pi*(i+1)/19
        core.append(Polygon([(rad*math.cos(t),s+rad*math.sin(t))
                             for rad,t in ((r,a),(r+1.4,a),(r+1.4,b),(r,b))]))
    mortar_wall(unary_union(core),cx,cy,cz,yaw,depth-.14)

def angular_distance(a,b):
    return abs((a-b+math.pi)%TAU-math.pi)

def spoke_angle_distance(a):
    return min(angular_distance(a,k*TAU/6) for k in ACTIVE_SPOKES)

def connection_mesh_names():
    return [name for name in MESHES if name in
            ('spoke_roads','spoke_dirt','sea_roads','sea_dirt') or name.startswith('pier_board')]


def arc_stone(m,x,z,r,thick,a,b,y,h0,h1):
    """One closed annular block: exterior, visible interior and broken top."""
    def p(rad,t,h):return(x+rad*math.cos(t),h,z+rad*math.sin(t))
    outer=[p(r,a,y),p(r,b,y),p(r,b,y+h1),p(r,a,y+h0)]
    inner=[p(r-thick,a,y),p(r-thick,b,y),p(r-thick,b,y+h1),p(r-thick,a,y+h0)]
    for pts in ([outer[i] for i in (0,3,2,1)],inner,
                [inner[0],inner[3],outer[3],outer[0]],
                [outer[1],outer[2],inner[2],inner[1]],
                [outer[3],inner[3],inner[2],outer[2]],
                [inner[0],outer[0],outer[1],inner[1]]):face(m,pts)


def ruined_tower(x,z,r,h,seed,breach):
    rng=random.Random(seed);segments=math.ceil(TAU*r/1.5);course=.65;core=[];openings=[]
    # Broad collapsed wedge plus smaller scars make a recognizable ruined shell.
    def top(t):
        d=angular_distance(t,breach)
        scar=max(0,1-d/.85)
        return h-(h-2.0)*scar+1.0*math.sin(t*5+seed)+.45*math.cos(t*11)
    for row in range(math.ceil((h+2)/course)):
        for i in range(segments):
            a=TAU*(i+(row%2)*.5)/segments;b=a+TAU/segments
            level=row*course;limit=min(top(a),top(b))
            if level>=limit:continue
            # A narrow arrow slit is an actual opening in the shell.
            pieces=[(a,b)]
            if row in (8,9,10,18,19) and i%7==2:
                mid=(a+b)/2;pieces=[(a,mid-.025),(mid+.025,b)]
                openings.append(rectangle(mid-.025,level,mid+.025,level+course))
            for lo,hi in pieces:
                ht=min(course-.025,limit-level)
                top1=ht*rng.uniform(.65,1) if ht<.6 else ht
                arc_stone(masonry(rng),x,z,r+max(0,1-level)*.3,1.45,
                          lo+.002,hi-.002,12+level,ht,top1)
                core_height=course if limit-level>=course else max(.005,min(ht,top1)-.035)
                core.append(rectangle(lo,0,hi,level+core_height))
    # Inset enough to stay inside the battered bottom courses as well.
    mortar_shell(core,x,z,r-.07,1.02,wrap=True,openings=openings)
    # Surviving battlements only on the intact parts; no cone roofs or spires.
    for i in range(segments):
        t=TAU*(i+.5)/segments
        if i%2 or top(t)<h-.5 or rng.random()<.28:continue
        base=min(top(t-TAU/segments/2),top(t+TAU/segments/2))-.65
        chipped_block(masonry(rng),x+(r-.6)*math.cos(t),12+base,
                      z+(r-.6)*math.sin(t),1.05,.85,1.2,t+math.pi/2,rng,True)


def ruined_wall(x,z,length,thick,h,yaw,seed,breaches=(),door=False):
    rng=random.Random(seed);co,si=math.cos(yaw),math.sin(yaw);course=.65;block=1.55;core=[];openings=[]
    def top(u):
        limit=h+.45*math.sin(u*1.3)+.35*math.sin(u*3.1+seed)
        for center,width,depth in breaches:limit-=depth*max(0,1-abs(u-center)/width)
        return max(.35,limit)
    for row in range(math.ceil((h+1)/course)):
        start=-length/2-(row%2)*block/2
        while start<length/2:
            lo=max(start,-length/2);hi=min(start+block,length/2);u=(lo+hi)/2;level=row*course
            start+=block
            limit=top(u)
            if hi-lo<.1 or level>=limit:continue
            if row in (9,10,11,19,20) and int((u+length/2)/block)%5==2:
                openings.append(rectangle(lo,level,hi,level+course));continue
            ht=min(course-.025,limit-level)
            core_height=course if limit-level>=course*1.4 else max(.005,ht*.44)
            core.append(rectangle(lo,0,hi,level+core_height))
            if door and abs(u)<5 and level<7.4:
                # The surrounding courses meet the OUTER arch, not a rectangular
                # hole cutting into the opening or covering its voussoirs.
                r=3.1+1.4+.012;s=5.9-3.1
                envelope=Polygon([(-r,-.1),(r,-.1)]+[(r*math.cos(math.pi*j/96),s+r*math.sin(math.pi*j/96)) for j in range(97)])
                brick=Polygon([(lo+.012,level),(hi-.012,level),(hi-.012,level+ht),(lo+.012,level+ht)]).difference(envelope)
                for part in ([brick] if brick.geom_type=='Polygon' else getattr(brick,'geoms',[])):
                    if part.geom_type=='Polygon' and part.area>1e-6:
                        extrude_xy(masonry(rng),list(part.exterior.coords)[:-1],x,12,z,yaw,thick)
                continue
            chipped_block(masonry(rng),x+u*co,12+level,z+u*si,hi-lo-.025,ht,thick,
                          yaw,rng,limit-level<course*1.4)
    region=unary_union([set_precision(cell,1e-8) for cell in core])
    if openings:region=region.difference(unary_union([set_precision(hole,1e-8) for hole in openings]))
    if door:
        # Back the joint between the arch and surrounding courses as well;
        # only the actual passage is open through the structural core.
        r=3.1+.035;s=5.9-3.1
        opening=Polygon([(-r,-.1),(r,-.1)]+[(r*math.cos(math.pi*j/96),s+r*math.sin(math.pi*j/96)) for j in range(97)])
        region=region.difference(opening)
    mortar_wall(region,x,12,z,yaw,thick-.14)


def fortress():
    # A squat, roofless enclosure with four unequal, hollow defensive towers.
    # The six radial passages remain open through surviving gates or breaches.
    rng=random.Random(54031)
    for k in range(6):
        a=k*TAU/6;b=(k+1)*TAU/6;core=[]
        if k in (0,2,4):
            arch(43*math.cos(a),12,43*math.sin(a),a+math.pi/2,7.2,6.8,2.6,broken=k==4)
            for side in (-1,1):
                for row in range(6 if k==4 else 12):
                    chipped_block(masonry(rng),43*math.cos(a)-side*5.35*math.sin(a),12+row*.6,
                                  43*math.sin(a)+side*5.35*math.cos(a),.72,.575,2.8,a+math.pi/2,rng,row==11)
                box(mesh('fortress_mortar','mortar'),43*math.cos(a)-side*5.35*math.sin(a),12,
                    43*math.sin(a)+side*5.35*math.cos(a),.72,3.56 if k==4 else 6.82,2.66,a+math.pi/2)
        count=25
        for row in range(15):
            for j in range(count+1):
                start=a+.13+(b-a-.26)*(j-(row%2)*.5)/count
                lo=max(a+.13,start);hi=min(b-.13,start+(b-a-.26)/count)
                if hi<=lo:continue
                u=(lo+hi)/2
                damage=5.8*max(0,1-abs((u-a)/(b-a)-.58)/.17) if k in (1,3,5) else 0
                limit=8.0+1.1*math.sin(u*13)+.4*math.sin(u*31)-damage
                if row*.6>=limit:continue
                ht=min(.575,limit-row*.6)
                top1=ht*rng.uniform(.6,1) if ht<.55 else ht
                arc_stone(masonry(rng),0,0,44,2.2,lo+.0004,hi-.0004,12+row*.6,
                          ht,top1)
                core_height=.6 if limit-row*.6>=.6 else max(.005,min(ht,top1)-.035)
                core.append(rectangle(lo,0,hi,row*.6+core_height))
        mortar_shell(core,0,0,43.92,2.04)
    for t,r,h,seed in ((.47,6.2,16,80),(1.68,5.5,11,81),(3.55,7,18,82),(4.86,5.8,13,83)):
        ruined_tower(40*math.cos(t),40*math.sin(t),r,h,seed,t+.5)
    # Main keep: tall surviving west wall, collapsed east corner, open interior.
    ruined_wall(-13,-1,28,2.3,21,math.pi/2,901,((7,5,9),))
    ruined_wall(-1,-15,26,2.3,18,0,902,((5,6,13),),door=True)
    arch(-1,12,-15,0,6.2,5.9,2.5)
    ruined_wall(12,-1,28,2.3,13,math.pi/2,903,((-4,9,11),))
    ruined_wall(-1,13,26,2.3,15,0,904,((7,4,8),),door=True)
    arch(-1,12,13,0,6.2,5.9,2.5)
    # Roofless hall and remnants of an arcade in the inner ward.
    ruined_wall(20,-9,20,1.5,7,math.pi/2,910,((3,7,6),))
    ruined_wall(24,-19,9,1.5,6,0,911,((2,4,4),))
    for j in range(4):arch(-22,12,-9+j*6,math.pi/2,3.8,5.2,1.1,broken=j in (1,3))
    # Buttresses remain low and massive, with missing top stones.
    for z in (-11,-4,4,11):
        for row in range(12):
            chipped_block(masonry(rng),-15.0-row*.035,12+row*.65,z,
                          max(.7,2.1-row*.10),.62,1.6,0,rng,row==11)
    # Fallen masonry inside the enclosure, never across the six road corridors.
    route_line=LineString(island_course()[0])
    for i in range(210):
        x,z=rng.uniform(-38,38),rng.uniform(-38,38);r=math.hypot(x,z)
        if r>40 or r<19:continue
        if Point(*world_xz(x,z)).distance(route_line)<4.6:continue
        delta=(math.atan2(z,x)+TAU/12)%(TAU/6)-TAU/12
        if r>27 and abs(math.sin(delta))*r<4.8:continue
        chipped_block(masonry(rng),x,12,z,rng.uniform(.5,1.8),rng.uniform(.25,.9),
                      rng.uniform(.4,1.1),rng.uniform(0,TAU),rng,True)
    cylinder(mesh('courtyard','paving',True,ground=13),25,12.025,24,7,7,.01,48)
    for row in range(2):
        for j in range(12):
            arc_stone(masonry(rng),25,24,2.0,.6,j*TAU/12+.008,(j+1)*TAU/12-.008,
                      12.05+row*.45,.43,.31 if j==3 else .43)
    mortar_shell([rectangle(0,0,TAU,1.06)],25,24,1.94,.48,base=12.05,wrap=True)


def pier_frame():
    """World-space pier centreline; shared with offline model placements."""
    a=PIER_EXIT*TAU/6;co,si=math.cos(a),math.sin(a);r=RADIUS+3.5
    start=island_point((r*co,1,r*si))
    end=island_point(((r+SEA_EXITS[PIER_EXIT])*co,1,(r+SEA_EXITS[PIER_EXIT])*si))
    length=math.dist(start,end);direction=((end[0]-start[0])/length,0,(end[2]-start[2])/length)
    return start,direction,(-direction[2],0,direction[0])


def fortress_details():
    rng=random.Random(91341);oak=mesh('fortress_timber','old_oak');iron=mesh('fortress_iron','iron')
    # Raised portcullis, hinge straps and pins on both usable keep entrances.
    for z in (-15,13):
        for x in (-4.7,2.7):
            for y in (13.0,14.7):
                box(iron,x,y,z-1.29,.48,.16,.055)
                for dx in (-.16,.16):box(iron,x+dx,y+.035,z-1.34,.055,.08,.08)
        for x in (-2.8,-1.9,-1,-.1,.8):box(iron,x,18.1,z-.3,.065,1.5,.065)
        for y in (18.15,18.8,19.5):box(iron,-1,y,z-.3,3.9,.075,.075)
    # Broken stair up to a surviving gallery; this is away from the ride corridor.
    for i in range(19):
        chipped_block(masonry(rng),-31.5,12,-15+i*.66,2.8,(i+1)*.25,.65,0,rng,i in (3,14,18))
    for x in (-33,-30):
        for z in (-14,-9,-4):box(oak,x,12+max(0,z+15)*.25/.66,z,.16,1.0,.16)
    # Roofless gallery still has joist sockets and a short supported timber deck.
    for z in (-10,-7,-4,0,4,8):box(oak,-10.8,18.7,z,4.2,.22,.22)
    for i in range(13):box(oak,-10.8,18.92,-10+i*.25,4.4,.12,.23)
    for x in (-12.8,-8.8):
        for z in (-10,-7):box(oak,x,19.03,z,.14,.9,.14)
        box(oak,x,19.83,-8.5,.12,.12,3.1)
    # The courtyard well gains a windlass, uprights, coping and a hanging rope.
    for x in (22.9,27.1):box(oak,x,12.05,24,.24,3.3,.24)
    box(oak,25,15.3,24,4.6,.25,.25)
    box(oak,25,14.1,24,4.4,.15,.15)
    box(iron,27.45,13.6,24,.1,.8,.1);box(oak,27.6,13.6,24,.38,.12,.12)
    box(mesh('well_rope','mooring_rope'),25,12.35,24,.035,1.85,.035)
    for j in range(16):
        arc_stone(masonry(rng),25,24,2.1,.78,j*TAU/16+.008,(j+1)*TAU/16-.008,12.93,.22,.22)
    # Benches, a stone trough and roof beams make the wards inhabited ruins.
    for x,z,yaw in ((27,15,0),(-28,22,math.pi/2),(9,-28,0)):
        for side in (-1,1):box(stone('stone_dark'),x+side*.95,12,z,.36,.55,.55,yaw)
        box(oak,x,12.55,z,2.6,.13,.62,yaw)
    box(stone('stone_dark'),29,12,-25,3.5,.65,1.3)
    box(stone('stone_light'),29,12.65,-25,3.7,.15,1.4)
    for z in (-15,-10,-5):
        box(oak,23,12.15,z,4.1,.22,.22,.22)
    # Quoin stones at the keep corners are visibly larger than the wall courses.
    for x,z in ((-13,-15),(12,-15),(-13,13),(12,13)):
        for row in range(7):
            box(stone('stone_light'),x,12+row*.68,z,1.1,.63,1.1)


def relocate_models():
    source=json.loads(Path(__file__).with_name('castle_models.json').read_text(encoding='utf-8'))
    placed=[];dx=coast_outline(0)[0]*COAST_SCALE*(1-1000/COAST_LENGTH)
    for item in source:
        name=Path(item['file']).stem
        if name=='trail-marker':continue
        if name in ('moored-yacht','mooring-bollard'):
            item['position'][0]+=dx
            for line in item.get('mooring_lines',[]):
                for point in line:point[0]+=dx
            placed.append(item);continue
        radius=item['clear_radius'];found=False
        for k in range(240):
            a=.25+(k//8)*.025+(0 if name=='ruined-watchtower' else .4)
            r=146-(k%8)*1.25;x,z=polar_xz(r,a)
            if Point(x,z).distance(PAVEMENT)<radius+.75:continue
            if any(math.hypot(x-p['position'][0],z-p['position'][2])<radius+p.get('clear_radius',0)+4 for p in placed):continue
            pad=item['foundation'];sx,_,sz=pad['size'];yaw=pad['yaw'];co,si=math.cos(yaw),math.sin(yaw)
            corners=[(x+u*co-v*si,z+u*si+v*co) for u in (-sx/2,sx/2) for v in (-sz/2,sz/2)]
            heights=[GROUND(*p) for p in corners]
            if max(heights)-min(heights)>.85:continue
            y=max(heights)+.08;item['position']=[x,y,z]
            pad['position']=[x,min(heights)-.12,z];pad['size'][1]=y-min(heights)+.12
            found=True;break
        if not found:raise ValueError('No clear model site: '+name)
        placed.append(item)
    route=island_course()[0]
    for index in range(0,len(route)-1,180):
        for shift in range(40):
            i=min(index+shift,len(route)-2);x,z=route[i];a,b=route[max(0,i-1)],route[i+1]
            d=math.dist(a,b);nx,nz=-(b[1]-a[1])/d,(b[0]-a[0])/d
            px,pz=x+nx*4.4,z+nz*4.4
            if math.hypot(px-CASTLE_CENTER[0],pz-CASTLE_CENTER[1])<54:continue
            if Point(px,pz).distance(PAVEMENT)<.7:continue
            try:y=GROUND(px,pz)
            except ValueError:continue
            placed.append(dict(file='models/trail-marker.x3d',position=[px,y,pz],rotation=[0,1,0,0],scale=[1,1,1]))
            break
    return placed


def pier_point(along,side=0,y=1):
    start,d,n=pier_frame()
    return (start[0]+d[0]*along+n[0]*side,y,start[2]+d[2]*along+n[2]*side)


def wooden_pier(near,far,length):
    """Same rideable footprint and elevation as the old sea exit, timber deck."""
    near=[island_point(p) for p in near];far=[island_point(p) for p in far]
    def at(j,t):return tuple(a+(b-a)*t for a,b in zip(near[j],far[j]))
    rng=random.Random(70320);rows=math.ceil(length/.22)
    for row in range(rows):
        name='pier_board'+str(rng.randrange(7));m=mesh(name,name,True);m['deform_island']=False
        for j in range(4):
            face(m,[at(j,row/rows),at(j+1,row/rows),at(j+1,(row+1)/rows),at(j,(row+1)/rows)])
    frame=mesh('pier_frame','pier_frame');frame['deform_island']=False
    # Narrow seams are visual; the continuous deck keeps wheel contacts reliable.
    for row in range(1,rows):
        for j in range(4):
            pts=[at(j,row/rows-.0003),at(j+1,row/rows-.0003),at(j+1,row/rows+.0003),at(j,row/rows+.0003)]
            face(frame,[(x,y+.002,z) for x,y,z in pts])
    start,d,n=pier_frame();yaw=math.atan2(d[2],d[0])
    for side in (-2.48,2.48):
        box(frame,*pier_point(length/2,side,.58),length,.28,.25,yaw)
        for along in range(1,math.floor(length),4):
            box(frame,*pier_point(along,side,-2.5),.34,3.35,.34,yaw)
    for along in range(1,math.floor(length),4):
        box(frame,*pier_point(along,0,.62),.24,.28,5.2,yaw)


def mooring_line(start,end):
    m=mesh('mooring_lines','mooring_rope');m['deform_island']=False
    points=[]
    for i in range(13):
        t=i/12;p=[a+(b-a)*t for a,b in zip(start,end)];p[1]-=.16*4*t*(1-t);points.append(p)
    for a,b in zip(points,points[1:]):
        d=[b[i]-a[i] for i in range(3)];length=math.sqrt(sum(v*v for v in d));d=[v/length for v in d]
        n=[-d[2],0,d[0]];length=math.hypot(n[0],n[2]);n=[v/length for v in n]
        v=[d[1]*n[2],d[2]*n[0]-d[0]*n[2],-d[1]*n[0]]
        def ring(p,t):return [p[i]+.025*(math.cos(t)*n[i]+math.sin(t)*v[i]) for i in range(3)]
        for j in range(6):face(m,[ring(a,j*TAU/6),ring(b,j*TAU/6),ring(b,(j+1)*TAU/6),ring(a,(j+1)*TAU/6)])


def sea_exits():
    r=RADIUS+3.5;quay=mesh('quay','stone_dark')
    for k in ACTIVE_SPOKES:
        length=SEA_EXITS[k]
        a=k*TAU/6;co,si=math.cos(a),math.sin(a)
        def p(u,v,y=1):return(u*co-v*si,y,u*si+v*co)
        # Start exactly at the ring's existing vertices: no coplanar overlays
        # or cracks at the curved shoreline, including either shoulder.
        near=[p(r*math.cos(j*TAU/N),r*math.sin(j*TAU/N)) for j in range(-2,3)]
        far=[p(r+length,r*math.sin(j*TAU/N)) for j in range(-2,3)]
        if k==PIER_EXIT:
            wooden_pier(near,far,length)
            continue
        road=mesh('sea_dirt','dirt',True,ground=31) if k==DIRT_SPOKE else mesh('sea_roads','paving',True,ground=13)
        repeats=math.dist(island_point(near[2]),island_point(far[2]))/4
        for j in range(4):
            uv=[(j/4,0),((j+1)/4,0),((j+1)/4,repeats),(j/4,repeats)] if k==DIRT_SPOKE else None
            face(road,[near[j],near[j+1],far[j+1],far[j]],uv)
        for u,v in ((near[0],far[0]),(far[0],far[-1]),(far[-1],near[-1])):
            face(quay,[(u[0],-4,u[2]),u,v,(v[0],-4,v[2])])


def waterfront_parapet(keepout):
    rng=random.Random(30148);count=600;r=RADIUS+3.14;step=TAU/count
    for i in range(6):mesh('parapet_masonry'+str(i),'masonry'+str(i))['road_keepout']=keepout
    section_heights=[rng.choice((1,2,2,3)) for _ in range(count//15)]
    for i in range(count):
        a=(i+.5)*step;delta=spoke_angle_distance(a)
        # Wide breaks at the three surviving intersections.
        if abs(math.sin(delta))*r<4.7:continue
        section=i//15;within=i%15
        if within in (11,12) and section%3!=0:continue
        if rng.random()<.035:continue
        rows=section_heights[section]
        if within in (0,10,13):rows=max(1,rows-1)
        for row in range(rows):
            broken=row==rows-1 and (within in (0,9,10,13) or rng.random()<.32)
            chipped_block(masonry(rng,'parapet'),r*math.cos(a),1+row*.27,r*math.sin(a),
                          r*step-.025,.245,.58,a+math.pi/2,rng,broken)
        if rows>1 and within in (4,5,6) and rng.random()<.75:
            chipped_block(masonry(rng,'parapet'),r*math.cos(a),1+rows*.27-.02,r*math.sin(a),
                          r*step-.03,.13,.67,a+math.pi/2,rng,False)

def tree(x,z,scale,kind):
    p=island_point((x,height(math.hypot(x,z)),z))
    TREES.append(dict(kind='tree',v=[*p,8*scale,RNG.uniform(0,TAU),kind%5]))

class GroundSampler:
    """Interpolate baked heights (or source UVs when transferring a material)."""
    def __init__(self,names=('terrain','meadows','flowerbeds','road_verges'),texture=False):
        self.bins={};self.texture=texture
        for name in names:
            m=MESHES.get(name)
            if not m:continue
            for i in range(0,len(m['indices']),3):
                ids=m['indices'][i:i+3]
                tri=[(m['vertices'][j][0],m['uv'][j],m['vertices'][j][2]) if texture else m['vertices'][j] for j in ids]
                for x in range(math.floor(min(p[0] for p in tri)/8),math.floor(max(p[0] for p in tri)/8)+1):
                    for z in range(math.floor(min(p[2] for p in tri)/8),math.floor(max(p[2] for p in tri)/8)+1):
                        self.bins.setdefault((x,z),[]).append(tri)

    def __call__(self,x,z):
        for a,b,c in self.bins.get((math.floor(x/8),math.floor(z/8)),[]):
            d=(b[2]-c[2])*(a[0]-c[0])+(c[0]-b[0])*(a[2]-c[2])
            if abs(d)<1e-10:continue
            u=((b[2]-c[2])*(x-c[0])+(c[0]-b[0])*(z-c[2]))/d
            v=((c[2]-a[2])*(x-c[0])+(a[0]-c[0])*(z-c[2]))/d
            if u>=-1e-7 and v>=-1e-7 and u+v<=1+1e-7:
                if self.texture:return tuple(u*a[1][k]+v*b[1][k]+(1-u-v)*c[1][k] for k in range(2))
                return u*a[1]+v*b[1]+(1-u-v)*c[1]
        raise ValueError(f'Point outside island: {x:.3f}, {z:.3f}')


class SurfaceBoundary:
    """Nearest real pavement edge and its elevation, indexed only while baking."""
    def __init__(self,footprint,surface):
        boundary=footprint.boundary
        self.lines=[];self.heights=[]
        for ring in ([boundary] if boundary.geom_type=='LineString' else boundary.geoms):
            for a,b in zip(ring.coords, list(ring.coords)[1:]):
                if math.dist(a,b)<1e-8:continue
                self.lines.append(LineString([a,b]))
                self.heights.append((surface(*a),surface(*b)))
        self.tree=STRtree(self.lines);self.cache={}

    def __call__(self,x,z):
        key=(round(x,8),round(z,8))
        if key not in self.cache:
            point=Point(x,z);i=int(self.tree.nearest(point));line=self.lines[i]
            a,b=line.coords;dx,dz=b[0]-a[0],b[1]-a[1]
            t=max(0,min(1,((x-a[0])*dx+(z-a[1])*dz)/(dx*dx+dz*dz)))
            ya,yb=self.heights[i]
            self.cache[key]=(ya+(yb-ya)*t,math.hypot(x-a[0]-dx*t,z-a[1]-dz*t))
        return self.cache[key]


def smooth_weight(distance,width):
    t=max(0,min(1,distance/width))
    return 1-t*t*(3-2*t)


def level_path_crossings(points,width,ground):
    """Give both visits to a self-intersection the same flat junction surface."""
    from collections import Counter
    line=LineString([(x,z) for x,y,z in points])
    if line.is_simple:return points
    parts=unary_union(line)
    ends=Counter(tuple(round(v,7) for v in p) for part in parts.geoms for p in (part.coords[0],part.coords[-1]))
    segments=[LineString([a,c]) for a,c in zip(line.coords,list(line.coords)[1:])]
    tree=STRtree(segments);junctions=[]
    for p,count in ends.items():
        if count<3:continue
        point=Point(p);directions=[]
        for i in tree.query(point.buffer(.00001)):
            segment=segments[i]
            if segment.distance(point)>.00001:continue
            a,c=segment.coords;directions.append(((c[0]-a[0])/segment.length,(c[1]-a[1])/segment.length))
        sine=max(abs(a[0]*c[1]-a[1]*c[0]) for a in directions for c in directions)
        # Cover the whole overlap, including the outside corner of each ribbon.
        radius=width/max(.2,sine)+2
        junctions.append((p,radius,ground(*p)+.04))
    result=[]
    for x,y,z in points:
        for p,radius,level in junctions:
            w=smooth_weight(math.hypot(x-p[0],z-p[1])-radius,12)
            if w:y+=(level-y)*w
        result.append((x,y,z))
    return result


def stitch_junctions(m,boundary):
    """Meet the existing road exactly; blend only inside the junction approach."""
    old=m['vertices'];indices=m['indices'];uv=m['uv'];adjusted=[]
    for x,y,z in old:
        edge,d=boundary(x,z);w=smooth_weight(d,4)
        adjusted.append((x,y+(edge-y)*w,z))
    m.update(vertices=[],normals=[],uv=[],indices=[],deform_island=False)
    for i in range(0,len(indices),3):
        ids=indices[i:i+3];face(m,[adjusted[j] for j in ids],[uv[j] for j in ids])


def grade_terrain(pavement,roads):
    """Cut and fill the hillside against the final road edge, without holes.

    The clipped grass margin becomes bare earth, not empty space. New vertices
    on the road boundary use its exact linear height; a four-metre shoulder
    blends back into the original hill. No runtime terrain modifier is needed.
    """
    boundary=SurfaceBoundary(pavement,roads)
    margin=pavement.buffer(.20);near=prep(pavement.buffer(4.01))
    verges=mesh('road_verges','dirt',True,ground=1);verges['deform_island']=False
    for name in ('terrain','meadows','flowerbeds'):
        m=MESHES.get(name)
        if not m:continue
        old=m['vertices'];indices=m['indices']
        m.update(vertices=[],normals=[],uv=[],indices=[],deform_island=False)
        for i in range(0,len(indices),3):
            a,b,c=[old[j] for j in indices[i:i+3]]
            polygon=Polygon([(p[0],p[2]) for p in (a,b,c)])
            if not near.intersects(polygon):face(m,[a,b,c]);continue
            outside=polygon.difference(pavement)
            if outside.is_empty:continue
            d=(b[2]-c[2])*(a[0]-c[0])+(c[0]-b[0])*(a[2]-c[2])
            if abs(d)<1e-10:continue
            def lift(x,z):
                u=((b[2]-c[2])*(x-c[0])+(c[0]-b[0])*(z-c[2]))/d
                v=((c[2]-a[2])*(x-c[0])+(a[0]-c[0])*(z-c[2]))/d
                y=u*a[1]+v*b[1]+(1-u-v)*c[1]
                edge,distance=boundary(x,z);w=smooth_weight(distance,4)
                return (x,y+(edge-y)*w,z)
            regions=[(m,outside)] if m['grass_material']<0 else [(m,outside.difference(margin)),(verges,outside.intersection(margin))]
            for target,region in regions:
                for tri in triangles_inside(region):face(target,[lift(x,z) for x,z in reversed(tri)])


def world_xz(x,z):
    p=island_point((x,0,z));return (p[0],p[2])


def polar_xz(r,a):return world_xz(r*math.cos(a),r*math.sin(a))


def bezier_path(a,b,first,last,h0,h1):
    n=max(4,math.ceil(math.dist(a,b)/.65))
    d0,d1=math.hypot(*first),math.hypot(*last)
    c=tuple(a[k]+first[k]*h0/d0 for k in range(2))
    e=tuple(b[k]-last[k]*h1/d1 for k in range(2))
    return [tuple((1-t)**3*a[k]+3*(1-t)**2*t*c[k]+3*(1-t)*t*t*e[k]+t**3*b[k]
                  for k in range(2)) for t in (i/n for i in range(n+1))]


def smooth_path(points, first=None, last=None):
    """Cubic segments with bounded handles: no overshoot at the gate throats."""
    def unit(v):
        d=math.hypot(*v);return (v[0]/d,v[1]/d)
    tangents=[]
    for i,p in enumerate(points):
        a=points[max(0,i-1)];b=points[min(len(points)-1,i+1)]
        tangents.append(unit((b[0]-a[0],b[1]-a[1])))
    if first:tangents[0]=unit(first)
    if last:tangents[-1]=unit(last)
    result=[points[0]]
    for i,(a,b) in enumerate(zip(points,points[1:])):
        d=math.dist(a,b);n=max(2,math.ceil(d/.8));h=d*.32
        if i>0:h=min(h,math.dist(points[i-1],a)*.45)
        if i+2<len(points):h=min(h,math.dist(b,points[i+2])*.45)
        c=(a[0]+tangents[i][0]*h,a[1]+tangents[i][1]*h)
        e=(b[0]-tangents[i+1][0]*h,b[1]-tangents[i+1][1]*h)
        for j in range(1,n+1):
            t=j/n;s=1-t
            result.append(tuple(s*s*s*a[k]+3*s*s*t*c[k]+3*s*t*t*e[k]+t*t*t*b[k] for k in range(2)))
    return result


def island_course():
    """Nearly the entire coast, winding garden terraces, and both keep gates."""
    ROUTE_SECTIONS.clear()
    coast=[polar_xz(RADIUS,.10+(TAU-.26)*i/760) for i in range(761)]
    garden=[]
    for i in range(1751):
        s=i/1750;t=.16+(2*TAU+1.78-.16)*s
        r=138-72*s+(10*math.sin(4*t+.4)+6*math.sin(7*t-.8))*math.sin(math.pi*s)
        garden.append(polar_xz(r,t))
    def delta(a,b):return (a[0]-b[0],a[1]-b[1])
    approach=smooth_path([coast[-1],garden[0]],delta(coast[-1],coast[-2]),delta(garden[1],garden[0]))
    gate_in=world_xz(-21.5,37.24);keep_in=world_xz(-1,18)
    keep_out=world_xz(-1,-20);gate_out=world_xz(-21.5,-37.24)
    passage=bezier_path(garden[-1],gate_in,delta(garden[-1],garden[-2]),(.5,-.866),14,12)
    passage+=bezier_path(gate_in,keep_in,(.5,-.866),(0,-1),10,12)[1:]
    passage+=bezier_path(keep_in,keep_out,(0,-1),(0,-1),12,12)[1:]
    passage+=bezier_path(keep_out,gate_out,(0,-1),(-.5,-.866),10,10)[1:]
    return_bend=[polar_xz(60+3*math.sin(i/120*math.pi),4*math.pi/3+.30+(TAU-4*math.pi/3-.60)*i/120) for i in range(121)]
    link=smooth_path([passage[-1],return_bend[0]],delta(passage[-1],passage[-2]),delta(return_bend[1],return_bend[0]))
    exit_points=[return_bend[-1]]+[world_xz(x,z) for x,z in [(82,-1),(108,-2),(140,1)]]+[coast[0]]
    leave=smooth_path(exit_points,delta(return_bend[-1],return_bend[-2]),delta(coast[1],coast[0]))
    route=[]
    for name,points in [('coast',coast),('garden_approach',approach),('garden_trails',garden),
                        ('fortress_passage',passage),('southern_garden',link+return_bend[1:]),('harbor_return',leave)]:
        start=len(route)-1 if route else 0
        route.extend(points[1:] if route else points)
        ROUTE_SECTIONS.append(dict(name=name,first=start,last=len(route)-1))
    assert math.dist(route[0],route[-1])<1e-8
    return route,approach+garden[1:]+passage[1:]+link[1:]+return_bend[1:]+leave[1:]


def clip_surface(m, exclusion, keep_inside=False):
    """Cut intersecting surfaces while preserving heights and oriented UVs."""
    old_vertices=m['vertices'];old_indices=m['indices'];old_uv=m['uv'];prepared=prep(exclusion)
    m.update(vertices=[],normals=[],uv=[],indices=[],deform_island=False)
    for i in range(0,len(old_indices),3):
        ids=old_indices[i:i+3];a,b,c=[old_vertices[j] for j in ids]
        tex=[old_uv[j] for j in ids]
        polygon=Polygon([(p[0],p[2]) for p in (a,b,c)])
        if not prepared.intersects(polygon):
            if not keep_inside:face(m,[a,b,c],tex)
            continue
        difference=polygon.intersection(exclusion) if keep_inside else polygon.difference(exclusion)
        if difference.is_empty:continue
        d=(b[2]-c[2])*(a[0]-c[0])+(c[0]-b[0])*(a[2]-c[2])
        if abs(d)<1e-10:continue
        def lift(x,z):
            u=((b[2]-c[2])*(x-c[0])+(c[0]-b[0])*(z-c[2]))/d
            v=((c[2]-a[2])*(x-c[0])+(a[0]-c[0])*(z-c[2]))/d
            return ((x,u*a[1]+v*b[1]+(1-u-v)*c[1],z),
                    tuple(u*tex[0][k]+v*tex[1][k]+(1-u-v)*tex[2][k] for k in range(2)))
        for tri in triangles_inside(difference):
            lifted=[lift(x,z) for x,z in reversed(tri)]
            face(m,[p for p,uv in lifted],[uv for p,uv in lifted])


def garden_roads(ground,existing):
    route,path=island_course()
    m=mesh('garden_roads','paving',True,ground=13);m['deform_island']=False
    points=level_path_crossings([(x,ground(x,z)+.04,z) for x,z in path],5.5,ground)
    ribbon(m,points,5.5)
    clip_surface(m,existing)
    junctions=SurfaceBoundary(existing,GroundSampler(['roads']))
    stitch_junctions(m,junctions)
    return route


def build():
    global GROUND,PAVEMENT
    MESHES.clear();TREES.clear();ARCHES.clear();RNG.seed(70319)
    # The outer ocean belongs to this world too; it is never an OSM tile.
    water=mesh('ocean','water',water=True)
    face(water,[(-5000,0,-5000),(-5000,0,5000),(5000,0,5000),(5000,0,-5000)])
    # Raised castle hill ends at a waterfront quay. Outside the 1 m road
    # elevation is immediately open sea, with no beach or offshore verge.
    rings=[0,12,24,40,48]+list(range(50,155,2))+[RADIUS-3.5,RADIUS+3.5]
    sectors=360
    for r0,r1 in zip(rings,rings[1:]):
        for j in range(sectors):
            a,b=TAU*j/sectors,TAU*(j+1)/sectors
            mid=(a+b)/2;rad=(r0+r1)/2;delta=spoke_angle_distance(mid)
            planted=rad>53 and rad<RADIUS-4.3 and abs(math.sin(delta))*rad>5.3
            flower=planted and (68<=rad<75 or 127<=rad<133) and abs(delta-TAU/6)<.17
            if flower:m=mesh('flowerbeds','grass_light',True,ground=9,grass=9)
            elif planted:m=mesh('meadows','grass',True,ground=8,grass=8)
            else:m=mesh('terrain','grass',True,ground=8)
            def p(r,t):
                return(r*math.cos(t),height(r),r*math.sin(t))
            if r0==0:face(m,[(0,12,0),p(r1,b),p(r1,a)])
            else:face(m,[p(r0,a),p(r0,b),p(r1,b),p(r1,a)])
    road=mesh('roads','paving',True,ground=13)
    ring=[(RADIUS*math.cos(TAU*i/N),1.0,RADIUS*math.sin(TAU*i/N)) for i in range(N+1)]
    for i in range(N):
        a,b=TAU*i/N,TAU*(i+1)/N
        p=lambda r,t:(r*math.cos(t),1.0,r*math.sin(t))
        face(road,[p(RADIUS-3.5,a),p(RADIUS-3.5,b),p(RADIUS+3.5,b),p(RADIUS+3.5,a)])
        r=RADIUS+3.5
        delta=spoke_angle_distance((a+b)/2)
        if abs(delta)>EXIT_HALF_ANGLE:
            face(mesh('quay','stone_dark'),[(r*math.cos(a),-4,r*math.sin(a)),p(r,a),p(r,b),(r*math.cos(b),-4,r*math.sin(b))])
    spoke_paths=[]
    for spoke in ACTIVE_SPOKES:
        a=TAU*spoke/6;co,si=math.cos(a),math.sin(a)
        radii=list(range(28,155,2))+[math.sqrt((RADIUS-3.5)**2-3**2)]
        points=[island_point((r*co,height(r)+.04,r*si)) for r in radii]
        spoke_paths.append(points)
    ground=GroundSampler()
    for spoke,points in zip(ACTIVE_SPOKES,spoke_paths):
        spokes=mesh('spoke_dirt','dirt',True,ground=31) if spoke==DIRT_SPOKE else mesh('spoke_roads','paving',True,ground=13)
        spokes['deform_island']=False
        ribbon(spokes,points,6)
    sea_exits()
    promenade=road_footprint(['roads'])
    route_xz=garden_roads(ground,promenade)
    garden=road_footprint(['garden_roads'])
    # The continuous ride course owns each junction's surface and crossfall.
    # Grade the connecting radial roads into it, so a steep radial descent
    # cannot tilt the main course sideways or pull it below a fortress gate.
    priority=unary_union([promenade,garden])
    junctions=SurfaceBoundary(priority,GroundSampler(['roads','garden_roads']))
    # Elevation priority must not resurface the deliberately unpaved spoke.
    # Transfer its oriented atlas coordinates onto the level junction geometry.
    dirt=road_footprint(['spoke_dirt']);dirt_uv=GroundSampler(['spoke_dirt'],texture=True)
    dirt_junction=dict(MESHES['garden_roads'])
    clip_surface(dirt_junction,dirt,keep_inside=True)
    dirt_junction['uv']=[dirt_uv(x,z) for x,y,z in dirt_junction['vertices']]
    clip_surface(MESHES['garden_roads'],dirt)
    for name in ('spoke_roads','spoke_dirt'):
        m=MESHES[name];clip_surface(m,priority);stitch_junctions(m,junctions)
    m=MESHES['spoke_dirt'];start=len(m['vertices'])
    for key in ('vertices','normals','uv'):m[key].extend(dirt_junction[key])
    m['indices'].extend(i+start for i in dirt_junction['indices'])
    connections=road_footprint(connection_mesh_names())
    pavement=unary_union([promenade,connections,garden])
    roads=GroundSampler(['roads','garden_roads']+connection_mesh_names())
    grade_terrain(pavement,roads)
    GROUND=GroundSampler();PAVEMENT=pavement
    route=[(x,roads(x,z),z) for x,z in route_xz]
    wall_keepout=prep(pavement.buffer(.15))
    # The waterfront parapet occupies the existing outer 0.75 m stone shoulder.
    # At road/sea-exit junctions protect the FULL surface, including dirt/pier.
    parapet_keepout=prep(unary_union([promenade.buffer(-.9),connections]).buffer(.15))
    for points in spoke_paths:
        # Both stone walls stop before the loop, leaving clear junctions.
        walls=mesh('spoke_walls','stone_dark');walls['deform_island']=False
        caps=mesh('spoke_caps','stone_light');caps['deform_island']=False
        walls['road_keepout']=wall_keepout;caps['road_keepout']=wall_keepout
        for u,v in zip(points,points[1:]):
            if math.hypot(u[0]-CASTLE_CENTER[0],u[2]-CASTLE_CENTER[1])<55:continue
            dx,dz=v[0]-u[0],v[2]-u[2];length=math.hypot(dx,dz);yaw=math.atan2(dz,dx)
            n=max(1,math.ceil(length/3));step=length/n
            for j in range(n):
                t=(j+.5)/n;y=u[1]+(v[1]-u[1])*t-.04
                for side in (-1,1):
                    x=u[0]+dx*t-side*3.8*dz/length;z=u[2]+dz*t+side*3.8*dx/length
                    box(walls,x,y,z,step-.025,.90,.62,yaw)
                    box(caps,x,y+.90,z,step,.15,.80,yaw)
    fortress()
    fortress_details()
    waterfront_parapet(parapet_keepout)
    # Gardens fill the removed spokes and stay clear of the surviving roads.
    for i in range(450):
        a=RNG.uniform(0,TAU);r=RNG.uniform(83,146)
        if math.sin(spoke_angle_distance(a))*r<10:continue
        tree(r*math.cos(a),r*math.sin(a),RNG.uniform(.75,1.55),i%3)
    for i in range(380):
        a=RNG.uniform(0,TAU);r=RNG.uniform(58,150)
        if math.sin(spoke_angle_distance(a))*r<6:continue
        x,z=r*math.cos(a),r*math.sin(a)
        p=island_point((x,height(r),z))
        TREES.append(dict(kind='shrub',v=[*p,RNG.uniform(.9,1.7),RNG.uniform(0,TAU),i%4]))
    # The old angular prefilter is only an authoring hint. On the displaced,
    # irregular island it is not a metric distance to the real six-metre road.
    TREES[:]=[t for t in TREES if Point(t['v'][0],t['v'][2]).distance(pavement)>=vegetation_radius(t)+.35]
    for t in TREES:t['v'][1]=GROUND(t['v'][0],t['v'][2])
    route[-1]=route[0]
    return route

def write_package(destination, manifest, tile_name='world.x3d', placements=None):
    """Shared O3D writer; builders provide local meshes, vegetation and a route."""
    destination.mkdir(parents=True,exist_ok=True)
    if placements is None:placements=relocate_models()
    for instance in placements:
        for line in instance.get('mooring_lines',[]):mooring_line(*line)
        pad=instance.get('foundation')
        if pad:
            m=mesh('model_foundations','stone_dark');m['deform_island']=False
            box(m,*pad['position'],*pad['size'],pad['yaw'])
    # Preserve clear space around the full footprint, including near-LOD crowns.
    for instance in placements:
        if instance.get('clear_radius',0)<=0:continue
        x,y,z=instance['position'];radius=instance['clear_radius']
        TREES[:]=[t for t in TREES if math.hypot(t['v'][0]-x,t['v'][2]-z)>radius+t['v'][3]*.25]
    lines=['<?xml version="1.0" encoding="UTF-8"?>','<X3D profile="Interchange" version="3.3">','<head>',
           '<meta name="generator" content="REZVIVO Dream World offline baker"/>',
           '<meta name="o3d:format" content="1"/>','<meta name="o3d:tile" content="31 N 0 0"/>',
           '<meta name="o3d:origin" content="0 0"/>','<meta name="o3d:bbox" content="-1 -1 1 1"/>',
           f'<meta name="o3d:gen" content="dream-{manifest["id"]}-v{manifest["revision"]}"/>','</head>','<Scene>']
    num=lambda a:' '.join(format(v,'.6f').rstrip('0').rstrip('.') if abs(v)>1e-8 else '0' for p in a for v in p)
    for name,m in MESHES.items():
        idx=m['indices'];kind='smkWater' if m['water'] else 'smkRoad' if m['walkable'] else 'smkBuildingWall'
        lines += [f'<Shape o3dName="{escape(name)}" o3dMaterial="{kind}">',
                  '<IndexedFaceSet solid="true" normalPerVertex="true" coordIndex="'+' '.join(f'{idx[i]} {idx[i+1]} {idx[i+2]} -1' for i in range(0,len(idx),3))+'">',
                  '<Coordinate point="'+num(m['vertices'])+'"/>','<Normal vector="'+num(m['normals'])+'"/>',
                  '<TextureCoordinate point="'+num(m['uv'])+'"/>']
        if 'road_id' in m:
            lines.append('<O3DOsmId values="'+' '.join([str(m['road_id'])]*len(m['vertices']))+'"/>')
        lines += ['</IndexedFaceSet>','</Shape>']
    for road in manifest.get('road_profiles', []):
        lines.append(f'<O3DRoad id="{road["id"]}" w="{road["width"]}" surface="{num([road["surface"]])}" v="{num(road["points"])}"/>')
    for t in TREES:
        tag=f' tree_version="2" gpu_type="{t["gpu_type"]}" lat_e7="0" lon_e7="0"' if 'gpu_type' in t else ''
        lines.append(f'<O3DTree kind="{t["kind"]}" v="{num([t["v"]])}"{tag}/>')
    for instance in placements:
        transform=instance['position']+instance['rotation']+instance['scale']
        lines.append(f'<O3DModel file="{escape(instance["file"])}" v="{num([transform])}"/>')
    lines += ['</Scene>','</X3D>']
    tile=destination/tile_name;tile.write_text('\n'.join(lines)+'\n',encoding='utf-8')
    manifest.update(format='rezvivo-dream-world',version=1,coordinates='local-metres-y-up',
      tiles=[dict(file=tile_name,sha256=hashlib.sha256(tile.read_bytes()).hexdigest(),offset=[0,0,0])],
      materials={k:dict(color=v[0],roughness=v[1],metallic=v[2] if len(v)>2 else .0) for k,v in PALETTE.items()},
      meshes={k:{v:m[v] for v in ('material','walkable','water','ground_material','grass_material')} for k,m in MESHES.items()})
    for name,m in MESHES.items():
        if 'cast_shadow' in m:manifest['meshes'][name]['cast_shadow']=m['cast_shadow']
        for field in ('building_material','fence_material','grass_kind','water_scale'):
            if field in m:manifest['meshes'][name][field]=m[field]
    (destination/'world.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    return dict(id=manifest['id'],tile_bytes=tile.stat().st_size,meshes=len(MESHES),
      vertices=sum(len(m['vertices']) for m in MESHES.values()),triangles=sum(len(m['indices'])//3 for m in MESHES.values()),
      trees=sum(t['kind']=='tree' for t in TREES),shrubs=sum(t['kind']=='shrub' for t in TREES),models=len(placements),
      route_length_m=sum(math.dist(a,b) for a,b in zip(manifest['route']['points'],manifest['route']['points'][1:])))

def save(destination):
    route=build()
    length=sum(math.dist(a,b) for a,b in zip(route,route[1:]))
    assert length>3000
    manifest=dict(format='rezvivo-dream-world',version=1,id='castle-island',revision=12,road_condition=4,
      title='Остров с замком',description=f'{length/1000:.1f} км: набережная у моря, извилистые садовые дорожки и сквозной проезд через средневековую крепость. Пирс с яхтой и полуразрушенные галереи.',
      title_en='Castle Island',description_en=f'{length/1000:.1f} km: a seaside promenade, winding garden paths and a ride through a medieval fortress. A yacht pier and ruined galleries.',
      route=dict(id='island-ring',title='Берег, сады и крепость',closed=True,width=5.5,points=route,length_m=length,sections=ROUTE_SECTIONS),
      sun=[-.55,.75,-.35],preview=dict(position=[-395,290,-425],target=[0,9,0]),arches=ARCHES)
    print(json.dumps(write_package(destination,manifest,'island.x3d'),indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('destination',type=Path);args=parser.parse_args();save(args.destination)
