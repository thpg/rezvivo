{ Generated from building_material.glsl by tools/embed_building_shaders.py. }
  '// Shared surface evaluation for native CGE shadows and the composite sun path.' + #10 +
  '// All random coordinates are building local; no frame/time or world-position hash.' + #10 +
  '#define U_BLD_MAT_COUNT 16' + #10 +
  'uniform sampler2D u_bld_atlas;' + #10 +
  'uniform sampler2D u_bld_normal_atlas;' + #10 +
  'uniform sampler2D u_bld_mask_atlas;' + #10 +
  'uniform sampler2D u_bld_glow_atlas;' + #10 +
  'uniform int u_bld_grid_cols;' + #10 +
  'uniform int u_bld_grid_rows;' + #10 +
  'uniform float u_bld_cell_inset;' + #10 +
  'uniform vec3 u_bld_fallback_rgb[U_BLD_MAT_COUNT];' + #10 +
  'uniform float u_bld_metallic[U_BLD_MAT_COUNT];' + #10 +
  'uniform float u_bld_tint_amount[U_BLD_MAT_COUNT];' + #10 +
  'uniform vec3 u_bld_photo_tints[32];' + #10 +
  'uniform vec3 gc_SunDirToward;' + #10 +
  'uniform vec3 u_sky_zenith;' + #10 +
  'uniform vec3 u_sky_horizon;' + #10 +
  'uniform vec3 u_sky_ground;' + #10 +
  'uniform float u_bld_reflect_strength;' + #10 +
  'uniform float u_bld_window_tilt;' + #10 +
  'varying float vBldMatId;' + #10 +
  'varying vec2 vBldUV;' + #10 +
  'varying vec3 vBldNormalOS;' + #10 +
  'varying vec3 vBldShadowPosition;' + #10 +
  'varying vec2 vBldMetric;' + #10 +
  'flat varying vec2 vBldSeed;' + #10 +
  'vec4 position_eye_to_world_space(vec4 p);' + #10 +
  'vec3 direction_world_to_eye_space(vec3 d);' + #10 +
  'vec3 direction_eye_to_world_space(vec3 d);' + #10 +
  '' + #10 +
  'vec3 bldAlbedo, bldNormal, bldView, bldEnvironment;' + #10 +
  'float bldRoughness, bldMetallic, bldCavity;' + #10 +
  'vec4 rzBldRequest=vec4(0);' + #10 +
  '' + #10 +
  'float bldHash(vec2 p)' + #10 +
  '{' + #10 +
  '    vec3 h = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));' + #10 +
  '    h += dot(h, h.yzx + 33.33);' + #10 +
  '    return fract((h.x + h.y) * h.z);' + #10 +
  '}' + #10 +
  '' + #10 +
  'float bldNoise(vec2 p)' + #10 +
  '{' + #10 +
  '    vec2 i = floor(p), f = fract(p);' + #10 +
  '    f = f * f * (3.0 - 2.0 * f);' + #10 +
  '    return mix(mix(bldHash(i), bldHash(i + vec2(1,0)), f.x),' + #10 +
  '               mix(bldHash(i + vec2(0,1)), bldHash(i + vec2(1,1)), f.x), f.y);' + #10 +
  '}' + #10 +
  '' + #10 +
  'vec3 bldFrameColor(float seed)' + #10 +
  '{' + #10 +
  '    // Matches BuildingFrameColor; near geometry and painted atlas frames agree.' + #10 +
  '    float kind = mod(floor(seed + 0.5), 5.0);' + #10 +
  '    if (kind < 0.5) return vec3(0.22, 0.19, 0.16);' + #10 +
  '    if (kind < 1.5) return vec3(0.34, 0.36, 0.36);' + #10 +
  '    return vec3(0.76, 0.75, 0.70);' + #10 +
  '}' + #10 +
  '' + #10 +
  'float bldRectangle(vec2 p, vec2 lo, vec2 hi, vec2 aa)' + #10 +
  '{' + #10 +
  '    vec2 a = smoothstep(lo-aa, lo+aa, p) * (1.0-smoothstep(hi-aa, hi+aa, p));' + #10 +
  '    return a.x*a.y;' + #10 +
  '}' + #10 +
  '' + #10 +
  'vec3 bldRoom(vec2 p, vec3 ray, float roomSeed, float detail)' + #10 +
  '{' + #10 +
  '    float warm = bldHash(vec2(roomSeed, 13.7));' + #10 +
  '    vec3 wall = mix(vec3(0.025,0.033,0.040),vec3(0.055,0.040,0.027),warm);' + #10 +
  '    float curtainWidth = mix(0.07,0.39,bldHash(vec2(roomSeed,8.1)));' + #10 +
  '    float curtain = 1.0-smoothstep(curtainWidth-0.02,curtainWidth+0.02,' + #10 +
  '                                  min(p.x,1.0-p.x));' + #10 +
  '    float blind = step(0.72,bldHash(vec2(roomSeed,1.1)))*' + #10 +
  '                  smoothstep(mix(0.15,0.7,warm)-0.02,mix(0.15,0.7,warm)+0.02,p.y);' + #10 +
  '    vec3 fabric = mix(vec3(0.15,0.14,0.12),vec3(0.09,0.115,0.13),warm);' + #10 +
  '    vec3 average = mix(wall*0.75,fabric,max(curtainWidth*1.72,blind*0.7));' + #10 +
  '    // Do not intersect rooms once parallax is subpixel or beyond its distance LOD.' + #10 +
  '    if (detail<=0.001) return average;' + #10 +
  '    // Ray/box intersection behind the window. Distance is in window widths;' + #10 +
  '    // the ceiling, side walls and back wall therefore have real view parallax.' + #10 +
  '    vec3 origin = vec3(p, 0.0);' + #10 +
  '    ray.z = -max(0.08, abs(ray.z));' + #10 +
  '    vec3 safeRay = sign(ray + vec3(0.00001)) * max(abs(ray), vec3(0.00001));' + #10 +
  '    vec3 nearT = (vec3(0,0,-1.7)-origin)/safeRay;' + #10 +
  '    vec3 farT  = (vec3(1,1, 0.0)-origin)/safeRay;' + #10 +
  '    vec3 exitT = max(nearT, farT);' + #10 +
  '    float t = min(exitT.x, min(exitT.y, exitT.z));' + #10 +
  '    vec3 hit = origin + ray * max(0.0,t);' + #10 +
  '    float side = step(exitT.x, min(exitT.y,exitT.z));' + #10 +
  '    float horizontal = step(exitT.y, min(exitT.x,exitT.z));' + #10 +
  '    vec3 room = wall * mix(0.52,1.0,1.0-side*0.5-horizontal*0.3);' + #10 +
  '    room *= mix(0.55,1.0,smoothstep(-1.7,-0.05,hit.z));' + #10 +
  '    // A few broad shapes survive cycling-camera distance without tiny furniture.' + #10 +
  '    float furnishing = smoothstep(0.12,0.16,hit.x)*' + #10 +
  '        (1.0-smoothstep(0.69,0.75,hit.x))*(1.0-smoothstep(0.22,0.30,hit.y));' + #10 +
  '    room *= 1.0-furnishing*0.40;' + #10 +
  '    vec3 nearRoom = mix(room,fabric,max(curtain*0.86,blind));' + #10 +
  '    // Fade geometry perception, not the mean luminance of the whole window.' + #10 +
  '    return mix(average,nearRoom,detail);' + #10 +
  '}' + #10 +
  '' + #10 +
  'void bldEvaluate(const vec3 toCamera)' + #10 +
  '{' + #10 +
  '    if (vBldSeed.y <= -1000000.0) {' + #10 +
  '        // Authored components share this material and all its shadow/reflection' + #10 +
  '        // hooks. No atlas lookups and no procedural windows painted over them.' + #10 +
  '        float rgb=floor(vBldSeed.x+0.25);' + #10 +
  '        vec3 paint=vec3(floor(rgb/65536.0),mod(floor(rgb/256.0),256.0),mod(rgb,256.0))/255.0;' + #10 +
  '        float surfaceBits=floor(-vBldSeed.y-1000000.0+0.25);' + #10 +
  '        float surface=floor(surfaceBits/65536.0);' + #10 +
  '        bldRoughness=max(0.05,mod(surfaceBits,256.0)/255.0);' + #10 +
  '        bldMetallic=mod(floor(surfaceBits/256.0),256.0)/255.0;' + #10 +
  '        bldView=normalize(toCamera);' + #10 +
  '        vec3 N=normalize(vBldNormalOS);' + #10 +
  '        if (dot(N,bldView)<0.0) N=-N;' + #10 +
  '        bldNormal=N;bldCavity=1.0;bldEnvironment=vec3(0);' + #10 +
  '        if (surface<0.5) {' + #10 +
  '            // Metre-scale variation anchored to the house, not world hashes or' + #10 +
  '            // frame time. Keep trim paint consistent across adjacent pieces.' + #10 +
  '            float weather=bldNoise(vBldMetric*.31);' + #10 +
  '            paint*=0.97+0.05*weather;' + #10 +
  '        }' + #10 +
  '        if (surface>1.5 && surface<2.5) {' + #10 +
  '            // Horizontal timber siding for authored walls, with the same PBR,' + #10 +
  '            // shadow and reflection path as the other architectural surfaces.' + #10 +
  '            float row=vBldMetric.y/0.16;' + #10 +
  '            float aa=max(fwidth(row),0.002);' + #10 +
  '            float seam=1.0-smoothstep(0.015,0.045+aa,min(fract(row),1.0-fract(row)));' + #10 +
  '            seam*=1.0-smoothstep(0.35,1.0,aa);' + #10 +
  '            float grain=bldNoise(vBldMetric*vec2(.8,22.0));' + #10 +
  '            paint*=0.94+0.10*grain-0.24*seam;' + #10 +
  '            bldCavity=1.0-0.16*seam;' + #10 +
  '        }' + #10 +
  '        bldAlbedo=gc_SRGBtoLINEAR(paint);' + #10 +
  '        if (surface>0.5 && surface<1.5) {' + #10 +
  '            vec3 reflected=reflect(-bldView,N);' + #10 +
  '            vec3 sky=mix(u_sky_ground,u_sky_horizon,smoothstep(-.12,.10,reflected.y));' + #10 +
  '            sky=mix(sky,u_sky_zenith,smoothstep(.10,.70,reflected.y));' + #10 +
  '            float fresnel=.04+.96*pow(1.0-max(0.0,dot(bldView,N)),5.0);' + #10 +
  '            rzBldRequest=vec4(N*.5+.5,1.0);' + #10 +
  '            // Opaque recessed pane: no alpha sorting, no sky leaking through' + #10 +
  '            // the shell. Reflection uses the same RTX request as atlas glass.' + #10 +
  '            bldEnvironment=rzEnvironment(gc_SRGBtoLINEAR(sky))*fresnel*u_bld_reflect_strength+' + #10 +
  '                gc_SRGBtoLINEAR(paint)*(.20*(1.0-fresnel));' + #10 +
  '            bldAlbedo*=.035;bldMetallic=0.0;' + #10 +
  '        }' + #10 +
  '        return;' + #10 +
  '    }' + #10 +
  '    int matId = int(clamp(floor(vBldMatId+0.5),0.0,15.0));' + #10 +
  '    bool wall = matId < 6 || matId >= 12;' + #10 +
  '    float houseSeed = mod(vBldSeed.x,65536.0);' + #10 +
  '    int photoTint = int(clamp(floor(vBldSeed.x/65536.0),0.0,31.0));' + #10 +
  '    bool house = houseSeed > 0.5;' + #10 +
  '    bool facade = wall && vBldSeed.y >= 131072.0;' + #10 +
  '    bool entrance = facade && mod(floor(vBldSeed.y/65536.0),2.0)>0.5;' + #10 +
  '    bool authored = facade && vBldSeed.y >= 262144.0;' + #10 +
  '    vec2 paneLo = (matId==1 || matId==4) ? vec2(0.3203125,0.2109375) : vec2(0.30859375,0.224609375);' + #10 +
  '    vec2 paneHi = (matId==1 || matId==4) ? vec2(0.6796875,0.787109375) : vec2(0.693359375,0.77734375);' + #10 +
  '    vec2 baseUV = vBldUV;' + #10 +
  '    vec2 du1 = dFdx(baseUV), du2 = dFdy(baseUV);' + #10 +
  '    vec2 aa = max(abs(du1)+abs(du2),vec2(0.001));' + #10 +
  '    float windowPixels = 1.0/max(max(aa.x,aa.y),0.0001);' + #10 +
  '    float detail = smoothstep(6.0,26.0,windowPixels)*' + #10 +
  '                   (1.0-smoothstep(100.0,155.0,length(toCamera)));' + #10 +
  '    vec2 grid = vec2(float(u_bld_grid_cols),float(u_bld_grid_rows));' + #10 +
  '    vec2 cell = vec2(float(matId-matId/u_bld_grid_cols*u_bld_grid_cols),' + #10 +
  '                     float(matId/u_bld_grid_cols));' + #10 +
  '    vec2 uv = fract(baseUV);' + #10 +
  '    float inner = 1.0-2.0*u_bld_cell_inset;' + #10 +
  '    vec2 atlasUV = (cell+u_bld_cell_inset+uv*inner)/grid;' + #10 +
  '    vec2 dx = du1*inner/grid, dy = du2*inner/grid;' + #10 +
  '    vec3 color = textureGrad(u_bld_atlas,atlasUV,dx,dy).rgb;' + #10 +
  '    vec3 ns = textureGrad(u_bld_normal_atlas,atlasUV,dx,dy).rgb*2.0-1.0;' + #10 +
  '    float glass = textureGrad(u_bld_glow_atlas,atlasUV,dx,dy).r;' + #10 +
  '    if (!wall) glass = 0.0;' + #10 +
  '    bldRoughness = clamp(textureGrad(u_bld_mask_atlas,atlasUV,dx,dy).r,0.08,1.0);' + #10 +
  '    bldMetallic = clamp(u_bld_metallic[matId],0.0,1.0);' + #10 +
  '    bldCavity = 1.0;' + #10 +
  '    bldEnvironment = vec3(0);' + #10 +
  '' + #10 +
  '    vec3 dp1 = -dFdx(toCamera), dp2 = -dFdy(toCamera);' + #10 +
  '    vec3 N = normalize(vBldNormalOS);' + #10 +
  '    float determinant = du1.x*du2.y-du1.y*du2.x;' + #10 +
  '    float invDet = (determinant < 0.0 ? -1.0 : 1.0)/max(abs(determinant),1e-12);' + #10 +
  '    vec3 rawT = (dp1*du2.y-dp2*du1.y)*invDet;' + #10 +
  '    vec3 rawB = (dp2*du1.x-dp1*du2.x)*invDet;' + #10 +
  '    vec3 fallbackT = cross(abs(N.y)<0.9 ? vec3(0,1,0) : vec3(0,0,1),N);' + #10 +
  '    vec3 projectedT = rawT-N*dot(N,rawT);' + #10 +
  '    vec3 T = normalize(dot(projectedT,projectedT)>1e-12 ? projectedT : fallbackT);' + #10 +
  '    vec3 B = normalize(cross(N,T));' + #10 +
  '    if (dot(B,rawB)<0.0) B=-B;' + #10 +
  '    float moduleWidth = clamp(length(rawT),0.8,8.0);' + #10 +
  '    vec3 V = normalize(toCamera);' + #10 +
  '    bldView = V;' + #10 +
  '    if (dot(N,V)<0.0) { N=-N; B=-B; }' + #10 +
  '' + #10 +
  '    vec2 seed = vec2(mod(houseSeed,251.0),floor(houseSeed/251.0));' + #10 +
  '    float age = house ? mix(0.06,0.80,bldHash(seed+3.1)) : 0.0;' + #10 +
  '    float upkeep = bldHash(seed+7.3);' + #10 +
  '    age *= mix(0.45,1.0,smoothstep(0.18,0.65,upkeep));' + #10 +
  '    vec2 metric = wall ? vec2(baseUV.x*moduleWidth,vBldMetric.x) : vBldMetric;' + #10 +
  '    float facadeIdentity = mod(vBldSeed.y,65536.0);' + #10 +
  '    vec2 faceSeed = vec2(mod(facadeIdentity,251.0),floor(facadeIdentity/251.0));' + #10 +
  '    vec2 weatherUV = metric*0.21 + seed + faceSeed*0.11;' + #10 +
  '    float macro = bldNoise(weatherUV);' + #10 +
  '    float fine = bldNoise(weatherUV*3.2+6.7);' + #10 +
  '    if (wall) {' + #10 +
  '        // Skirts in existing caches have clamped/constant UVs. Bring the new' + #10 +
  '        // weather layer to the same value at the physical wall/skirt boundary,' + #10 +
  '        // without changing their atlas UVs or introducing a horizontal seam.' + #10 +
  '        float continuity = smoothstep(0.0,0.70,max(0.0,vBldMetric.x));' + #10 +
  '        macro = mix(0.5,macro,continuity);' + #10 +
  '        fine = mix(0.5,fine,continuity);' + #10 +
  '    }' + #10 +
  '    float nonGlass = 1.0-glass;' + #10 +
  '    color *= mix(vec3(1),u_bld_fallback_rgb[matId],u_bld_tint_amount[matId]);' + #10 +
  '    if (wall && photoTint>0) {' + #10 +
  '        // Colour and material are independent. Preserve the material''s relief' + #10 +
  '        // and tonal variation; leave glass and the window frames unchanged.' + #10 +
  '        vec2 inside = smoothstep(paneLo-0.035-aa,paneLo-0.035+aa,uv)*' + #10 +
  '                      (1.0-smoothstep(paneHi+0.035-aa,paneHi+0.035+aa,uv));' + #10 +
  '        float paint = nonGlass*(1.0-inside.x*inside.y);' + #10 +
  '        float tone = clamp(dot(color,vec3(0.2126,0.7152,0.0722))/0.72,0.35,1.3);' + #10 +
  '        color = mix(color,u_bld_photo_tints[photoTint]*tone,paint);' + #10 +
  '    }' + #10 +
  '    if (house) {' + #10 +
  '        // Paint batches differ subtly between houses. Never dirty every wall equally.' + #10 +
  '        vec3 tint = mix(vec3(0.91,0.94,0.98),vec3(1.02,0.99,0.94),bldHash(seed+1.7));' + #10 +
  '        color *= mix(vec3(1),tint,nonGlass);' + #10 +
  '        color *= 1.0+(macro-0.5)*0.16*age*nonGlass;' + #10 +
  '    }' + #10 +
  '    if (wall && house) {' + #10 +
  '        float footing = max(0.0,vBldMetric.x);' + #10 +
  '        float eave = max(0.0,vBldMetric.y);' + #10 +
  '        float buildingHeight = vBldMetric.x+vBldMetric.y;' + #10 +
  '        float family = mod(floor(houseSeed+0.5),4.0);' + #10 +
  '        if (facade && !authored) {' + #10 +
  '            // A house-wide construction system, rather than independent' + #10 +
  '            // random marks on each window. All lines filter in screen space.' + #10 +
  '            float rowEdge = min(uv.y,1.0-uv.y);' + #10 +
  '            float belt = 1.0-smoothstep(0.025,0.025+aa.y,rowEdge);' + #10 +
  '            float base = 1.0-smoothstep(0.65,0.78,footing);' + #10 +
  '            color *= 1.0-base*0.16*nonGlass;' + #10 +
  '            if (family<0.5 && buildingHeight>6.0) {' + #10 +
  '                float lowerStorey=1.0-smoothstep(length(rawB)-0.1,length(rawB)+0.1,footing);' + #10 +
  '                float joint=abs(fract(footing/0.42+0.5)-0.5)*0.42;' + #10 +
  '                float jointAA=max(fwidth(footing),0.004);' + #10 +
  '                float groove=1.0-smoothstep(0.012,0.012+jointAA,joint);' + #10 +
  '                color*=1.0-(0.10+groove*0.18)*lowerStorey*nonGlass;' + #10 +
  '                color=mix(color,color*0.8+vec3(0.13,0.12,0.10),belt*nonGlass*0.75);' + #10 +
  '            } else if (family<1.5 && buildingHeight>12.0) {' + #10 +
  '                float spandrel=1.0-smoothstep(0.13-aa.y,0.13+aa.y,rowEdge);' + #10 +
  '                color*=mix(vec3(1),vec3(0.75,0.80,0.85),spandrel*nonGlass);' + #10 +
  '            } else if (family<2.5 && buildingHeight>8.0) {' + #10 +
  '                float panelEdge=min(fract(baseUV.x*0.5),1.0-fract(baseUV.x*0.5))*2.0;' + #10 +
  '                float joint=1.0-smoothstep(0.008,0.008+aa.x,panelEdge);' + #10 +
  '                color*=1.0-(joint*0.18+belt*0.14)*nonGlass;' + #10 +
  '            } else if (buildingHeight>6.0) {' + #10 +
  '                color=mix(color,color*0.82+vec3(0.12,0.115,0.10),belt*nonGlass);' + #10 +
  '            }' + #10 +
  '        }' + #10 +
  '        float splash = (1.0-smoothstep(0.08,0.7+macro*0.65,footing));' + #10 +
  '        float damp = (1.0-smoothstep(0.12,1.6,footing))*smoothstep(0.33,0.77,macro);' + #10 +
  '        float underEave = 1.0-smoothstep(0.08,0.46,eave);' + #10 +
  '        float streak = 0.0;' + #10 +
  '        if (facade) {' + #10 +
  '            vec2 cellId = floor(baseUV);' + #10 +
  '            // The source sill can belong to the floor above this fragment.' + #10 +
  '            // Keep its random identity when a streak crosses a floor UV seam.' + #10 +
  '            vec2 runoffCell = cellId+vec2(0.0,uv.y>paneLo.y ? 1.0 : 0.0);' + #10 +
  '            float paneSeed = bldHash(runoffCell+faceSeed);' + #10 +
  '            // Runoff starts at sill corners and follows gravity across the floor seam.' + #10 +
  '            float below = fract(paneLo.y-uv.y);' + #10 +
  '            bool leftCorner = abs(uv.x-paneLo.x)<abs(uv.x-paneHi.x);' + #10 +
  '            float cornerSeed = bldHash(runoffCell+faceSeed+(leftCorner ? vec2(7.3,2.1) : vec2(3.7,9.4)));' + #10 +
  '            float cornerDistance = min(abs(uv.x-paneLo.x),abs(uv.x-paneHi.x))*moduleWidth;' + #10 +
  '            float streakWidth = 0.045+0.035*fine;' + #10 +
  '            streak = (1.0-smoothstep(streakWidth,streakWidth+max(aa.x*moduleWidth,0.06),cornerDistance))*' + #10 +
  '                     (1.0-smoothstep(0.02,mix(0.12,0.48,paneSeed),below))*' + #10 +
  '                     smoothstep(0.43,0.84,cornerSeed)*mix(0.45,1.0,fine)*smoothstep(0.02,0.25,footing);' + #10 +
  '            // Above the last sill there is no imaginary next floor to leak from.' + #10 +
  '            if (vBldMetric.y < length(rawB)*(1.0-paneLo.y) && uv.y>paneLo.y) streak=0.0;' + #10 +
  '            // The entrance replaces this window and has no sill to leak from.' + #10 +
  '            if (entrance && runoffCell.x==0.0 && runoffCell.y==0.0) streak=0.0;' + #10 +
  '            // Per-pane frame paint. Derivative smoothing avoids thin-line shimmer.' + #10 +
  '            float frame = bldRectangle(uv,paneLo-vec2(0.035,0.025),paneHi+vec2(0.035,0.025),aa)*nonGlass;' + #10 +
  '            color = mix(color,bldFrameColor(houseSeed),frame);' + #10 +
  '            float edge = min(min(uv.x-paneLo.x,paneHi.x-uv.x),' + #10 +
  '                             min(uv.y-paneLo.y,paneHi.y-uv.y));' + #10 +
  '            bldCavity *= 1.0-0.28*(1.0-smoothstep(0.0,0.055,edge))*glass;' + #10 +
  '        }' + #10 +
  '        float dirt = clamp((splash*0.22+damp*0.16+underEave*0.13+streak*0.26)*age,0.0,0.40)*nonGlass;' + #10 +
  '        color *= 1.0-dirt;' + #10 +
  '        color = mix(color,color*vec3(0.92,0.94,0.85),damp*age*0.26*nonGlass);' + #10 +
  '        // Old plaster fades and loses its coating locally, with a roughness change.' + #10 +
  '        bool plaster = matId==0 || matId==2 || matId>=12;' + #10 +
  '        float patch = smoothstep(0.64,0.82,macro)*age*nonGlass;' + #10 +
  '        if (plaster) color = mix(color,color*0.92+vec3(0.055,0.050,0.044),patch*0.38);' + #10 +
  '        float chip = smoothstep(0.66,0.78,fine)*smoothstep(0.50,0.75,macro)*age*nonGlass;' + #10 +
  '        if (!plaster) chip *= 0.25;' + #10 +
  '        bldRoughness = clamp(bldRoughness+dirt*0.5+patch*0.09-damp*age*0.09,0.18,1.0);' + #10 +
  '        // Height-gradient normal; derivatives evaluated for all wall fragments.' + #10 +
  '        // Fine wear fades by projected footprint, macro ageing keeps its mean tone.' + #10 +
  '        float wearHeight = -chip*0.012;' + #10 +
  '        vec3 dpdx = dp1, dpdy = dp2;' + #10 +
  '        vec3 r1 = cross(dpdy,N), r2 = cross(N,dpdx);' + #10 +
  '        float denom = dot(dpdx,r1);' + #10 +
  '        vec3 grad = (r1*dFdx(wearHeight)+r2*dFdy(wearHeight)) *' + #10 +
  '                    ((denom<0.0 ? -1.0 : 1.0)/max(abs(denom),1e-8));' + #10 +
  '        N = normalize(N-grad*detail);' + #10 +
  '        bldCavity *= 1.0-underEave*0.12-splash*0.07;' + #10 +
  '        if (entrance) {' + #10 +
  '            // Replace a complete ground-floor window, from footing to its lintel.' + #10 +
  '            // These physical bounds also drive DoorBounds and the near geometry.' + #10 +
  '            float doorCenter = (paneLo.x+paneHi.x)*0.5*moduleWidth;' + #10 +
  '            float halfWidth = max(1.10,(paneHi.x-paneLo.x+0.07)*moduleWidth)*0.5;' + #10 +
  '            float doorHeight = min(vBldMetric.x+vBldMetric.y-0.30,' + #10 +
  '                                   max(2.30,(paneHi.y+0.025)*length(rawB)));' + #10 +
  '            vec2 doorUV = vec2(metric.x-doorCenter,footing);' + #10 +
  '            vec2 doorAA = max(abs(dFdx(metric))+abs(dFdy(metric)),vec2(0.01));' + #10 +
  '            float door = bldRectangle(doorUV,vec2(-halfWidth,0),vec2(halfWidth,doorHeight),doorAA);' + #10 +
  '            float innerDoor = bldRectangle(doorUV,vec2(-halfWidth+0.065,0.045),' + #10 +
  '                                                vec2(halfWidth-0.065,doorHeight-0.065),doorAA);' + #10 +
  '            vec2 panelUV = vec2((doorUV.x+halfWidth)/(2.0*halfWidth),doorUV.y/doorHeight);' + #10 +
  '            vec2 panelAA = doorAA/vec2(2.0*halfWidth,doorHeight);' + #10 +
  '            float leaves = halfWidth>0.80 ? 2.0 : 1.0;' + #10 +
  '            panelUV.x = fract(panelUV.x*leaves);' + #10 +
  '            panelAA.x *= leaves;' + #10 +
  '            float panel = bldRectangle(panelUV,vec2(0.15,0.09),vec2(0.85,0.41),panelAA);' + #10 +
  '            panel += bldRectangle(panelUV,vec2(0.15,0.56),vec2(0.85,0.91),panelAA);' + #10 +
  '            vec3 paint = bldFrameColor(houseSeed)*vec3(0.57,0.60,0.61);' + #10 +
  '            paint *= 0.83+0.17*panel;' + #10 +
  '            float handle = bldRectangle(panelUV,vec2(0.74,0.465),vec2(0.87,0.485),panelAA);' + #10 +
  '            paint = mix(paint,vec3(0.60,0.61,0.58),handle*detail);' + #10 +
  '            color = mix(color,bldFrameColor(houseSeed),door);' + #10 +
  '            color = mix(color,paint,innerDoor);' + #10 +
  '            // Remove the old pane''s reflection and mullion normals as well as' + #10 +
  '            // its color; otherwise the window remains visible through the door.' + #10 +
  '            glass *= 1.0-door;' + #10 +
  '            ns = mix(ns,vec3(0,0,1),door);' + #10 +
  '            bldRoughness = mix(bldRoughness,0.63,door);' + #10 +
  '            bldMetallic *= 1.0-door;' + #10 +
  '            bldCavity = mix(bldCavity,0.90+0.08*panel,door);' + #10 +
  '        }' + #10 +
  '    } else if (!wall && house) {' + #10 +
  '        // The default roof atlas was almost white under noon exposure.' + #10 +
  '        // Keep authored coloured/white roofs; neutral roofs get realistic' + #10 +
  '        // mineral/metal reflectance with one stable finish per building.' + #10 +
  '        float finish=bldHash(seed+vec2(17.1,8.3));' + #10 +
  '        if (matId==6) color*=mix(vec3(0.31,0.35,0.39),vec3(0.52,0.49,0.44),finish);' + #10 +
  '        else if (matId==7 || matId==10) color*=mix(0.68,0.84,finish);' + #10 +
  '        else if (matId==11) color*=mix(vec3(0.39,0.40,0.42),vec3(0.57,0.52,0.45),finish);' + #10 +
  '        // Broad roof patina, aligned with the roof''s own planar coordinates.' + #10 +
  '        float patina = smoothstep(0.40,0.79,macro)*age;' + #10 +
  '        color *= 1.0-patina*0.17;' + #10 +
  '        if (matId==7) color = mix(color,vec3(0.31,0.25,0.20),patina*0.20);' + #10 +
  '        bldRoughness = clamp(bldRoughness+patina*0.13,0.1,1.0);' + #10 +
  '    }' + #10 +
  '' + #10 +
  '    bldAlbedo = gc_SRGBtoLINEAR(clamp(color,vec3(0.01),vec3(1)));' + #10 +
  '    bldNormal = normalize(T*ns.x+B*ns.y+N*max(0.1,ns.z));' + #10 +
  '    if (glass>0.01) {' + #10 +
  '        vec2 cellId = floor(baseUV)+faceSeed;' + #10 +
  '        float roomSeed = bldHash(cellId)*233.0;' + #10 +
  '        vec2 tilt = vec2(bldHash(cellId+5.3),bldHash(cellId+9.2))*2.0-1.0;' + #10 +
  '        vec3 glassN = normalize(N+(T*tilt.x+B*tilt.y)*u_bld_window_tilt);' + #10 +
  '        rzBldRequest=vec4(glassN*.5+.5,glass);' + #10 +
  '        bldNormal = normalize(mix(bldNormal,glassN,glass));' + #10 +
  '        vec3 reflected = reflect(-V,glassN);' + #10 +
  '        vec3 sky = mix(u_sky_ground,u_sky_horizon,smoothstep(-0.12,0.10,reflected.y));' + #10 +
  '        sky = mix(sky,u_sky_zenith,smoothstep(0.10,0.70,reflected.y));' + #10 +
  '        float fresnel = 0.04+0.96*pow(1.0-max(0.0,dot(V,glassN)),5.0);' + #10 +
  '        vec2 pane = clamp((uv-paneLo)/(paneHi-paneLo),vec2(0),vec2(1));' + #10 +
  '        vec3 ray = vec3(-dot(V,T),-dot(V,B),-dot(V,N));' + #10 +
  '        // Correct the ray for the non-square window (metres, not square UVs).' + #10 +
  '        ray.xy /= max(vec2(moduleWidth,length(rawB))*(paneHi-paneLo),vec2(0.1));' + #10 +
  '        vec3 room = bldRoom(pane,ray,roomSeed,detail);' + #10 +
  '        bldEnvironment = glass*(rzEnvironment(gc_SRGBtoLINEAR(sky))*fresnel*u_bld_reflect_strength +' + #10 +
  '                                      room*(1.0-fresnel)*bldCavity);' + #10 +
  '        bldAlbedo *= 1.0-glass*0.97;' + #10 +
  '        bldRoughness = mix(bldRoughness,0.16,glass);' + #10 +
  '        bldMetallic *= 1.0-glass;' + #10 +
  '    }' + #10 +
  '}' + #10 +
  '' + #10 +
  'void PLUG_fragment_end(inout vec4 color) {' + #10 +
  '    if(rz_capture>.5) color=rzBldRequest;' + #10 +
  '}' + #10 +
  '' + #10 +
  'void PLUG_fragment_eye_space(const vec4 vertex_eye, inout vec3 normal_eye)' + #10 +
  '{' + #10 +
  '    vec3 toCamera = position_eye_to_world_space(vec4(-vertex_eye.xyz,0.0)).xyz;' + #10 +
  '    bldEvaluate(toCamera);' + #10 +
  '#ifndef BLD_NATIVE_LIGHTING' + #10 +
  '    gc_riderPosition = position_eye_to_world_space(vertex_eye).xyz;' + #10 +
  '    gc_riderRelativePosition = vBldShadowPosition + normalize(vBldNormalOS)*0.025;' + #10 +
  '#endif' + #10 +
  '    normal_eye = normalize(direction_world_to_eye_space(bldNormal));' + #10 +
  '}' + #10 +
  '' + #10 +
  '' + #10 +
  'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + #10 +
  '{' + #10 +
  '#ifdef BLD_NATIVE_LIGHTING' + #10 +
  '    fragment_color.rgb *= bldAlbedo;' + #10 +
  '#else' + #10 +
  '    vec3 N = bldNormal, V = bldView, L = normalize(gc_SunDirToward);' + #10 +
  '    vec3 H = normalize(L+V);' + #10 +
  '    float nl = max(dot(N,L),0.0), nv = max(dot(N,V),0.001);' + #10 +
  '    float nh = max(dot(N,H),0.0), vh = max(dot(V,H),0.0);' + #10 +
  '    float alpha = bldRoughness*bldRoughness;' + #10 +
  '    vec3 f0 = mix(vec3(0.04),bldAlbedo,bldMetallic);' + #10 +
  '    vec3 F = specularReflection(f0,vec3(1.0),vh);' + #10 +
  '    vec3 diffuse = bldAlbedo*(1.0-bldMetallic)/3.141592653589793;' + #10 +
  '    vec3 specular = F*visibilityOcclusion(alpha,nl,nv)*microfacetDistribution(alpha,nh);' + #10 +
  '    vec3 sun = ((vec3(1)-F)*diffuse+specular)*nl*vec3(1.0,0.97,0.92)*8.0;' + #10 +
  '    // The shared world atlas blocks sunlight, not skylight or room emission.' + #10 +
  '    sun *= 1.0-clamp(gc_sampleRiderShadow(),0.0,1.0);' + #10 +
  '    vec3 hemi = mix(vec3(0.31,0.29,0.25),vec3(0.49,0.55,0.63),N.y*0.5+0.5);' + #10 +
  '    vec3 indirect = bldAlbedo*(1.0-bldMetallic)*hemi*bldCavity;' + #10 +
  '    vec3 linearColor = (sun+indirect+bldEnvironment)*2.0;' + #10 +
  '    fragment_color.rgb = gc_LINEARtoSRGB(linearColor/(linearColor+vec3(1)));' + #10 +
  '#endif' + #10 +
  '    fragment_color.a = 1.0;' + #10 +
  '}' + #10
