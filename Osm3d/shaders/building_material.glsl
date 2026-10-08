// Shared surface evaluation for native CGE shadows and the composite sun path.
// All random coordinates are building local; no frame/time or world-position hash.
#define U_BLD_MAT_COUNT 16
uniform sampler2D u_bld_atlas;
uniform sampler2D u_bld_normal_atlas;
uniform sampler2D u_bld_mask_atlas;
uniform sampler2D u_bld_glow_atlas;
uniform int u_bld_grid_cols;
uniform int u_bld_grid_rows;
uniform float u_bld_cell_inset;
uniform vec3 u_bld_fallback_rgb[U_BLD_MAT_COUNT];
uniform float u_bld_metallic[U_BLD_MAT_COUNT];
uniform float u_bld_tint_amount[U_BLD_MAT_COUNT];
uniform vec3 u_bld_photo_tints[32];
uniform vec3 gc_SunDirToward;
uniform vec3 u_sky_zenith;
uniform vec3 u_sky_horizon;
uniform vec3 u_sky_ground;
uniform float u_bld_reflect_strength;
uniform float u_bld_window_tilt;
varying float vBldMatId;
varying vec2 vBldUV;
varying vec3 vBldNormalOS;
varying vec3 vBldShadowPosition;
varying vec2 vBldMetric;
flat varying vec2 vBldSeed;
vec4 position_eye_to_world_space(vec4 p);
vec3 direction_world_to_eye_space(vec3 d);
vec3 direction_eye_to_world_space(vec3 d);

vec3 bldAlbedo, bldNormal, bldView, bldEnvironment;
float bldRoughness, bldMetallic, bldCavity;
vec4 rzBldRequest=vec4(0);

float bldHash(vec2 p)
{
    vec3 h = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    h += dot(h, h.yzx + 33.33);
    return fract((h.x + h.y) * h.z);
}

float bldNoise(vec2 p)
{
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(bldHash(i), bldHash(i + vec2(1,0)), f.x),
               mix(bldHash(i + vec2(0,1)), bldHash(i + vec2(1,1)), f.x), f.y);
}

vec3 bldFrameColor(float seed)
{
    // Matches BuildingFrameColor; near geometry and painted atlas frames agree.
    float kind = mod(floor(seed + 0.5), 5.0);
    if (kind < 0.5) return vec3(0.22, 0.19, 0.16);
    if (kind < 1.5) return vec3(0.34, 0.36, 0.36);
    return vec3(0.76, 0.75, 0.70);
}

float bldRectangle(vec2 p, vec2 lo, vec2 hi, vec2 aa)
{
    vec2 a = smoothstep(lo-aa, lo+aa, p) * (1.0-smoothstep(hi-aa, hi+aa, p));
    return a.x*a.y;
}

vec3 bldRoom(vec2 p, vec3 ray, float roomSeed, float detail)
{
    float warm = bldHash(vec2(roomSeed, 13.7));
    vec3 wall = mix(vec3(0.025,0.033,0.040),vec3(0.055,0.040,0.027),warm);
    float curtainWidth = mix(0.07,0.39,bldHash(vec2(roomSeed,8.1)));
    float curtain = 1.0-smoothstep(curtainWidth-0.02,curtainWidth+0.02,
                                  min(p.x,1.0-p.x));
    float blind = step(0.72,bldHash(vec2(roomSeed,1.1)))*
                  smoothstep(mix(0.15,0.7,warm)-0.02,mix(0.15,0.7,warm)+0.02,p.y);
    vec3 fabric = mix(vec3(0.15,0.14,0.12),vec3(0.09,0.115,0.13),warm);
    vec3 average = mix(wall*0.75,fabric,max(curtainWidth*1.72,blind*0.7));
    // Do not intersect rooms once parallax is subpixel or beyond its distance LOD.
    if (detail<=0.001) return average;
    // Ray/box intersection behind the window. Distance is in window widths;
    // the ceiling, side walls and back wall therefore have real view parallax.
    vec3 origin = vec3(p, 0.0);
    ray.z = -max(0.08, abs(ray.z));
    vec3 safeRay = sign(ray + vec3(0.00001)) * max(abs(ray), vec3(0.00001));
    vec3 nearT = (vec3(0,0,-1.7)-origin)/safeRay;
    vec3 farT  = (vec3(1,1, 0.0)-origin)/safeRay;
    vec3 exitT = max(nearT, farT);
    float t = min(exitT.x, min(exitT.y, exitT.z));
    vec3 hit = origin + ray * max(0.0,t);
    float side = step(exitT.x, min(exitT.y,exitT.z));
    float horizontal = step(exitT.y, min(exitT.x,exitT.z));
    vec3 room = wall * mix(0.52,1.0,1.0-side*0.5-horizontal*0.3);
    room *= mix(0.55,1.0,smoothstep(-1.7,-0.05,hit.z));
    // A few broad shapes survive cycling-camera distance without tiny furniture.
    float furnishing = smoothstep(0.12,0.16,hit.x)*
        (1.0-smoothstep(0.69,0.75,hit.x))*(1.0-smoothstep(0.22,0.30,hit.y));
    room *= 1.0-furnishing*0.40;
    vec3 nearRoom = mix(room,fabric,max(curtain*0.86,blind));
    // Fade geometry perception, not the mean luminance of the whole window.
    return mix(average,nearRoom,detail);
}

void bldEvaluate(const vec3 toCamera)
{
    if (vBldSeed.y <= -1000000.0) {
        // Authored components share this material and all its shadow/reflection
        // hooks. No atlas lookups and no procedural windows painted over them.
        float rgb=floor(vBldSeed.x+0.25);
        vec3 paint=vec3(floor(rgb/65536.0),mod(floor(rgb/256.0),256.0),mod(rgb,256.0))/255.0;
        float surfaceBits=floor(-vBldSeed.y-1000000.0+0.25);
        float surface=floor(surfaceBits/65536.0);
        bldRoughness=max(0.05,mod(surfaceBits,256.0)/255.0);
        bldMetallic=mod(floor(surfaceBits/256.0),256.0)/255.0;
        bldView=normalize(toCamera);
        vec3 N=normalize(vBldNormalOS);
        if (dot(N,bldView)<0.0) N=-N;
        bldNormal=N;bldCavity=1.0;bldEnvironment=vec3(0);
        if (surface<0.5) {
            // Metre-scale variation anchored to the house, not world hashes or
            // frame time. Keep trim paint consistent across adjacent pieces.
            float weather=bldNoise(vBldMetric*.31);
            paint*=0.97+0.05*weather;
        }
        if (surface>1.5 && surface<2.5) {
            // Horizontal timber siding for authored walls, with the same PBR,
            // shadow and reflection path as the other architectural surfaces.
            float row=vBldMetric.y/0.16;
            float aa=max(fwidth(row),0.002);
            float seam=1.0-smoothstep(0.015,0.045+aa,min(fract(row),1.0-fract(row)));
            seam*=1.0-smoothstep(0.35,1.0,aa);
            float grain=bldNoise(vBldMetric*vec2(.8,22.0));
            paint*=0.94+0.10*grain-0.24*seam;
            bldCavity=1.0-0.16*seam;
        }
        bldAlbedo=gc_SRGBtoLINEAR(paint);
        if (surface>0.5 && surface<1.5) {
            vec3 reflected=reflect(-bldView,N);
            vec3 sky=mix(u_sky_ground,u_sky_horizon,smoothstep(-.12,.10,reflected.y));
            sky=mix(sky,u_sky_zenith,smoothstep(.10,.70,reflected.y));
            float fresnel=.04+.96*pow(1.0-max(0.0,dot(bldView,N)),5.0);
            rzBldRequest=vec4(N*.5+.5,1.0);
            // Opaque recessed pane: no alpha sorting, no sky leaking through
            // the shell. Reflection uses the same RTX request as atlas glass.
            bldEnvironment=rzEnvironment(gc_SRGBtoLINEAR(sky))*fresnel*u_bld_reflect_strength+
                gc_SRGBtoLINEAR(paint)*(.20*(1.0-fresnel));
            bldAlbedo*=.035;bldMetallic=0.0;
        }
        return;
    }
    int matId = int(clamp(floor(vBldMatId+0.5),0.0,15.0));
    bool wall = matId < 6 || matId >= 12;
    float houseSeed = mod(vBldSeed.x,65536.0);
    int photoTint = int(clamp(floor(vBldSeed.x/65536.0),0.0,31.0));
    bool house = houseSeed > 0.5;
    bool facade = wall && vBldSeed.y >= 131072.0;
    bool entrance = facade && mod(floor(vBldSeed.y/65536.0),2.0)>0.5;
    bool authored = facade && vBldSeed.y >= 262144.0;
    vec2 paneLo = (matId==1 || matId==4) ? vec2(0.3203125,0.2109375) : vec2(0.30859375,0.224609375);
    vec2 paneHi = (matId==1 || matId==4) ? vec2(0.6796875,0.787109375) : vec2(0.693359375,0.77734375);
    vec2 baseUV = vBldUV;
    vec2 du1 = dFdx(baseUV), du2 = dFdy(baseUV);
    vec2 aa = max(abs(du1)+abs(du2),vec2(0.001));
    float windowPixels = 1.0/max(max(aa.x,aa.y),0.0001);
    float detail = smoothstep(6.0,26.0,windowPixels)*
                   (1.0-smoothstep(100.0,155.0,length(toCamera)));
    vec2 grid = vec2(float(u_bld_grid_cols),float(u_bld_grid_rows));
    vec2 cell = vec2(float(matId-matId/u_bld_grid_cols*u_bld_grid_cols),
                     float(matId/u_bld_grid_cols));
    vec2 uv = fract(baseUV);
    float inner = 1.0-2.0*u_bld_cell_inset;
    vec2 atlasUV = (cell+u_bld_cell_inset+uv*inner)/grid;
    vec2 dx = du1*inner/grid, dy = du2*inner/grid;
    vec3 color = textureGrad(u_bld_atlas,atlasUV,dx,dy).rgb;
    vec3 ns = textureGrad(u_bld_normal_atlas,atlasUV,dx,dy).rgb*2.0-1.0;
    float glass = textureGrad(u_bld_glow_atlas,atlasUV,dx,dy).r;
    if (!wall) glass = 0.0;
    bldRoughness = clamp(textureGrad(u_bld_mask_atlas,atlasUV,dx,dy).r,0.08,1.0);
    bldMetallic = clamp(u_bld_metallic[matId],0.0,1.0);
    bldCavity = 1.0;
    bldEnvironment = vec3(0);

    vec3 dp1 = -dFdx(toCamera), dp2 = -dFdy(toCamera);
    vec3 N = normalize(vBldNormalOS);
    float determinant = du1.x*du2.y-du1.y*du2.x;
    float invDet = (determinant < 0.0 ? -1.0 : 1.0)/max(abs(determinant),1e-12);
    vec3 rawT = (dp1*du2.y-dp2*du1.y)*invDet;
    vec3 rawB = (dp2*du1.x-dp1*du2.x)*invDet;
    vec3 fallbackT = cross(abs(N.y)<0.9 ? vec3(0,1,0) : vec3(0,0,1),N);
    vec3 projectedT = rawT-N*dot(N,rawT);
    vec3 T = normalize(dot(projectedT,projectedT)>1e-12 ? projectedT : fallbackT);
    vec3 B = normalize(cross(N,T));
    if (dot(B,rawB)<0.0) B=-B;
    float moduleWidth = clamp(length(rawT),0.8,8.0);
    vec3 V = normalize(toCamera);
    bldView = V;
    if (dot(N,V)<0.0) { N=-N; B=-B; }

    vec2 seed = vec2(mod(houseSeed,251.0),floor(houseSeed/251.0));
    float age = house ? mix(0.06,0.80,bldHash(seed+3.1)) : 0.0;
    float upkeep = bldHash(seed+7.3);
    age *= mix(0.45,1.0,smoothstep(0.18,0.65,upkeep));
    vec2 metric = wall ? vec2(baseUV.x*moduleWidth,vBldMetric.x) : vBldMetric;
    float facadeIdentity = mod(vBldSeed.y,65536.0);
    vec2 faceSeed = vec2(mod(facadeIdentity,251.0),floor(facadeIdentity/251.0));
    vec2 weatherUV = metric*0.21 + seed + faceSeed*0.11;
    float macro = bldNoise(weatherUV);
    float fine = bldNoise(weatherUV*3.2+6.7);
    if (wall) {
        // Skirts in existing caches have clamped/constant UVs. Bring the new
        // weather layer to the same value at the physical wall/skirt boundary,
        // without changing their atlas UVs or introducing a horizontal seam.
        float continuity = smoothstep(0.0,0.70,max(0.0,vBldMetric.x));
        macro = mix(0.5,macro,continuity);
        fine = mix(0.5,fine,continuity);
    }
    float nonGlass = 1.0-glass;
    color *= mix(vec3(1),u_bld_fallback_rgb[matId],u_bld_tint_amount[matId]);
    if (wall && photoTint>0) {
        // Colour and material are independent. Preserve the material's relief
        // and tonal variation; leave glass and the window frames unchanged.
        vec2 inside = smoothstep(paneLo-0.035-aa,paneLo-0.035+aa,uv)*
                      (1.0-smoothstep(paneHi+0.035-aa,paneHi+0.035+aa,uv));
        float paint = nonGlass*(1.0-inside.x*inside.y);
        float tone = clamp(dot(color,vec3(0.2126,0.7152,0.0722))/0.72,0.35,1.3);
        color = mix(color,u_bld_photo_tints[photoTint]*tone,paint);
    }
    if (house) {
        // Paint batches differ subtly between houses. Never dirty every wall equally.
        vec3 tint = mix(vec3(0.91,0.94,0.98),vec3(1.02,0.99,0.94),bldHash(seed+1.7));
        color *= mix(vec3(1),tint,nonGlass);
        color *= 1.0+(macro-0.5)*0.16*age*nonGlass;
    }
    if (wall && house) {
        float footing = max(0.0,vBldMetric.x);
        float eave = max(0.0,vBldMetric.y);
        float buildingHeight = vBldMetric.x+vBldMetric.y;
        float family = mod(floor(houseSeed+0.5),4.0);
        if (facade && !authored) {
            // A house-wide construction system, rather than independent
            // random marks on each window. All lines filter in screen space.
            float rowEdge = min(uv.y,1.0-uv.y);
            float belt = 1.0-smoothstep(0.025,0.025+aa.y,rowEdge);
            float base = 1.0-smoothstep(0.65,0.78,footing);
            color *= 1.0-base*0.16*nonGlass;
            if (family<0.5 && buildingHeight>6.0) {
                float lowerStorey=1.0-smoothstep(length(rawB)-0.1,length(rawB)+0.1,footing);
                float joint=abs(fract(footing/0.42+0.5)-0.5)*0.42;
                float jointAA=max(fwidth(footing),0.004);
                float groove=1.0-smoothstep(0.012,0.012+jointAA,joint);
                color*=1.0-(0.10+groove*0.18)*lowerStorey*nonGlass;
                color=mix(color,color*0.8+vec3(0.13,0.12,0.10),belt*nonGlass*0.75);
            } else if (family<1.5 && buildingHeight>12.0) {
                float spandrel=1.0-smoothstep(0.13-aa.y,0.13+aa.y,rowEdge);
                color*=mix(vec3(1),vec3(0.75,0.80,0.85),spandrel*nonGlass);
            } else if (family<2.5 && buildingHeight>8.0) {
                float panelEdge=min(fract(baseUV.x*0.5),1.0-fract(baseUV.x*0.5))*2.0;
                float joint=1.0-smoothstep(0.008,0.008+aa.x,panelEdge);
                color*=1.0-(joint*0.18+belt*0.14)*nonGlass;
            } else if (buildingHeight>6.0) {
                color=mix(color,color*0.82+vec3(0.12,0.115,0.10),belt*nonGlass);
            }
        }
        float splash = (1.0-smoothstep(0.08,0.7+macro*0.65,footing));
        float damp = (1.0-smoothstep(0.12,1.6,footing))*smoothstep(0.33,0.77,macro);
        float underEave = 1.0-smoothstep(0.08,0.46,eave);
        float streak = 0.0;
        if (facade) {
            vec2 cellId = floor(baseUV);
            // The source sill can belong to the floor above this fragment.
            // Keep its random identity when a streak crosses a floor UV seam.
            vec2 runoffCell = cellId+vec2(0.0,uv.y>paneLo.y ? 1.0 : 0.0);
            float paneSeed = bldHash(runoffCell+faceSeed);
            // Runoff starts at sill corners and follows gravity across the floor seam.
            float below = fract(paneLo.y-uv.y);
            bool leftCorner = abs(uv.x-paneLo.x)<abs(uv.x-paneHi.x);
            float cornerSeed = bldHash(runoffCell+faceSeed+(leftCorner ? vec2(7.3,2.1) : vec2(3.7,9.4)));
            float cornerDistance = min(abs(uv.x-paneLo.x),abs(uv.x-paneHi.x))*moduleWidth;
            float streakWidth = 0.045+0.035*fine;
            streak = (1.0-smoothstep(streakWidth,streakWidth+max(aa.x*moduleWidth,0.06),cornerDistance))*
                     (1.0-smoothstep(0.02,mix(0.12,0.48,paneSeed),below))*
                     smoothstep(0.43,0.84,cornerSeed)*mix(0.45,1.0,fine)*smoothstep(0.02,0.25,footing);
            // Above the last sill there is no imaginary next floor to leak from.
            if (vBldMetric.y < length(rawB)*(1.0-paneLo.y) && uv.y>paneLo.y) streak=0.0;
            // The entrance replaces this window and has no sill to leak from.
            if (entrance && runoffCell.x==0.0 && runoffCell.y==0.0) streak=0.0;
            // Per-pane frame paint. Derivative smoothing avoids thin-line shimmer.
            float frame = bldRectangle(uv,paneLo-vec2(0.035,0.025),paneHi+vec2(0.035,0.025),aa)*nonGlass;
            color = mix(color,bldFrameColor(houseSeed),frame);
            float edge = min(min(uv.x-paneLo.x,paneHi.x-uv.x),
                             min(uv.y-paneLo.y,paneHi.y-uv.y));
            bldCavity *= 1.0-0.28*(1.0-smoothstep(0.0,0.055,edge))*glass;
        }
        float dirt = clamp((splash*0.22+damp*0.16+underEave*0.13+streak*0.26)*age,0.0,0.40)*nonGlass;
        color *= 1.0-dirt;
        color = mix(color,color*vec3(0.92,0.94,0.85),damp*age*0.26*nonGlass);
        // Old plaster fades and loses its coating locally, with a roughness change.
        bool plaster = matId==0 || matId==2 || matId>=12;
        float patch = smoothstep(0.64,0.82,macro)*age*nonGlass;
        if (plaster) color = mix(color,color*0.92+vec3(0.055,0.050,0.044),patch*0.38);
        float chip = smoothstep(0.66,0.78,fine)*smoothstep(0.50,0.75,macro)*age*nonGlass;
        if (!plaster) chip *= 0.25;
        bldRoughness = clamp(bldRoughness+dirt*0.5+patch*0.09-damp*age*0.09,0.18,1.0);
        // Height-gradient normal; derivatives evaluated for all wall fragments.
        // Fine wear fades by projected footprint, macro ageing keeps its mean tone.
        float wearHeight = -chip*0.012;
        vec3 dpdx = dp1, dpdy = dp2;
        vec3 r1 = cross(dpdy,N), r2 = cross(N,dpdx);
        float denom = dot(dpdx,r1);
        vec3 grad = (r1*dFdx(wearHeight)+r2*dFdy(wearHeight)) *
                    ((denom<0.0 ? -1.0 : 1.0)/max(abs(denom),1e-8));
        N = normalize(N-grad*detail);
        bldCavity *= 1.0-underEave*0.12-splash*0.07;
        if (entrance) {
            // Replace a complete ground-floor window, from footing to its lintel.
            // These physical bounds also drive DoorBounds and the near geometry.
            float doorCenter = (paneLo.x+paneHi.x)*0.5*moduleWidth;
            float halfWidth = max(1.10,(paneHi.x-paneLo.x+0.07)*moduleWidth)*0.5;
            float doorHeight = min(vBldMetric.x+vBldMetric.y-0.30,
                                   max(2.30,(paneHi.y+0.025)*length(rawB)));
            vec2 doorUV = vec2(metric.x-doorCenter,footing);
            vec2 doorAA = max(abs(dFdx(metric))+abs(dFdy(metric)),vec2(0.01));
            float door = bldRectangle(doorUV,vec2(-halfWidth,0),vec2(halfWidth,doorHeight),doorAA);
            float innerDoor = bldRectangle(doorUV,vec2(-halfWidth+0.065,0.045),
                                                vec2(halfWidth-0.065,doorHeight-0.065),doorAA);
            vec2 panelUV = vec2((doorUV.x+halfWidth)/(2.0*halfWidth),doorUV.y/doorHeight);
            vec2 panelAA = doorAA/vec2(2.0*halfWidth,doorHeight);
            float leaves = halfWidth>0.80 ? 2.0 : 1.0;
            panelUV.x = fract(panelUV.x*leaves);
            panelAA.x *= leaves;
            float panel = bldRectangle(panelUV,vec2(0.15,0.09),vec2(0.85,0.41),panelAA);
            panel += bldRectangle(panelUV,vec2(0.15,0.56),vec2(0.85,0.91),panelAA);
            vec3 paint = bldFrameColor(houseSeed)*vec3(0.57,0.60,0.61);
            paint *= 0.83+0.17*panel;
            float handle = bldRectangle(panelUV,vec2(0.74,0.465),vec2(0.87,0.485),panelAA);
            paint = mix(paint,vec3(0.60,0.61,0.58),handle*detail);
            color = mix(color,bldFrameColor(houseSeed),door);
            color = mix(color,paint,innerDoor);
            // Remove the old pane's reflection and mullion normals as well as
            // its color; otherwise the window remains visible through the door.
            glass *= 1.0-door;
            ns = mix(ns,vec3(0,0,1),door);
            bldRoughness = mix(bldRoughness,0.63,door);
            bldMetallic *= 1.0-door;
            bldCavity = mix(bldCavity,0.90+0.08*panel,door);
        }
    } else if (!wall && house) {
        // The default roof atlas was almost white under noon exposure.
        // Keep authored coloured/white roofs; neutral roofs get realistic
        // mineral/metal reflectance with one stable finish per building.
        float finish=bldHash(seed+vec2(17.1,8.3));
        if (matId==6) color*=mix(vec3(0.31,0.35,0.39),vec3(0.52,0.49,0.44),finish);
        else if (matId==7 || matId==10) color*=mix(0.68,0.84,finish);
        else if (matId==11) color*=mix(vec3(0.39,0.40,0.42),vec3(0.57,0.52,0.45),finish);
        // Broad roof patina, aligned with the roof's own planar coordinates.
        float patina = smoothstep(0.40,0.79,macro)*age;
        color *= 1.0-patina*0.17;
        if (matId==7) color = mix(color,vec3(0.31,0.25,0.20),patina*0.20);
        bldRoughness = clamp(bldRoughness+patina*0.13,0.1,1.0);
    }

    bldAlbedo = gc_SRGBtoLINEAR(clamp(color,vec3(0.01),vec3(1)));
    bldNormal = normalize(T*ns.x+B*ns.y+N*max(0.1,ns.z));
    if (glass>0.01) {
        vec2 cellId = floor(baseUV)+faceSeed;
        float roomSeed = bldHash(cellId)*233.0;
        vec2 tilt = vec2(bldHash(cellId+5.3),bldHash(cellId+9.2))*2.0-1.0;
        vec3 glassN = normalize(N+(T*tilt.x+B*tilt.y)*u_bld_window_tilt);
        rzBldRequest=vec4(glassN*.5+.5,glass);
        bldNormal = normalize(mix(bldNormal,glassN,glass));
        vec3 reflected = reflect(-V,glassN);
        vec3 sky = mix(u_sky_ground,u_sky_horizon,smoothstep(-0.12,0.10,reflected.y));
        sky = mix(sky,u_sky_zenith,smoothstep(0.10,0.70,reflected.y));
        float fresnel = 0.04+0.96*pow(1.0-max(0.0,dot(V,glassN)),5.0);
        vec2 pane = clamp((uv-paneLo)/(paneHi-paneLo),vec2(0),vec2(1));
        vec3 ray = vec3(-dot(V,T),-dot(V,B),-dot(V,N));
        // Correct the ray for the non-square window (metres, not square UVs).
        ray.xy /= max(vec2(moduleWidth,length(rawB))*(paneHi-paneLo),vec2(0.1));
        vec3 room = bldRoom(pane,ray,roomSeed,detail);
        bldEnvironment = glass*(rzEnvironment(gc_SRGBtoLINEAR(sky))*fresnel*u_bld_reflect_strength +
                                      room*(1.0-fresnel)*bldCavity);
        bldAlbedo *= 1.0-glass*0.97;
        bldRoughness = mix(bldRoughness,0.16,glass);
        bldMetallic *= 1.0-glass;
    }
}

void PLUG_fragment_end(inout vec4 color) {
    if(rz_capture>.5) color=rzBldRequest;
}

void PLUG_fragment_eye_space(const vec4 vertex_eye, inout vec3 normal_eye)
{
    vec3 toCamera = position_eye_to_world_space(vec4(-vertex_eye.xyz,0.0)).xyz;
    bldEvaluate(toCamera);
#ifndef BLD_NATIVE_LIGHTING
    gc_riderPosition = position_eye_to_world_space(vertex_eye).xyz;
    gc_riderRelativePosition = vBldShadowPosition + normalize(vBldNormalOS)*0.025;
#endif
    normal_eye = normalize(direction_world_to_eye_space(bldNormal));
}


void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)
{
#ifdef BLD_NATIVE_LIGHTING
    fragment_color.rgb *= bldAlbedo;
#else
    vec3 N = bldNormal, V = bldView, L = normalize(gc_SunDirToward);
    vec3 H = normalize(L+V);
    float nl = max(dot(N,L),0.0), nv = max(dot(N,V),0.001);
    float nh = max(dot(N,H),0.0), vh = max(dot(V,H),0.0);
    float alpha = bldRoughness*bldRoughness;
    vec3 f0 = mix(vec3(0.04),bldAlbedo,bldMetallic);
    vec3 F = specularReflection(f0,vec3(1.0),vh);
    vec3 diffuse = bldAlbedo*(1.0-bldMetallic)/3.141592653589793;
    vec3 specular = F*visibilityOcclusion(alpha,nl,nv)*microfacetDistribution(alpha,nh);
    vec3 sun = ((vec3(1)-F)*diffuse+specular)*nl*vec3(1.0,0.97,0.92)*8.0;
    // The shared world atlas blocks sunlight, not skylight or room emission.
    sun *= 1.0-clamp(gc_sampleRiderShadow(),0.0,1.0);
    vec3 hemi = mix(vec3(0.31,0.29,0.25),vec3(0.49,0.55,0.63),N.y*0.5+0.5);
    vec3 indirect = bldAlbedo*(1.0-bldMetallic)*hemi*bldCavity;
    vec3 linearColor = (sun+indirect+bldEnvironment)*2.0;
    fragment_color.rgb = gc_LINEARtoSRGB(linearColor/(linearColor+vec3(1)));
#endif
    fragment_color.a = 1.0;
}
