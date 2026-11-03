{ Meter-space soil and aggregate, shared by the page baker and live fallback. }
'void rp_unpavedGradient(vec2 p,float seed,float pixel,vec3 road,float condition,float kind,' + #10 +
'    out vec4 color,out vec3 relief,out vec2 gradient) {' + #10 +
'    uint key=uint(seed); bool soil=kind<1.5,sand=kind>4.5,loose=kind>1.5 && kind<2.5;' + #10 +
'    vec3 broad=rp_gritGradient(p*vec2(.11,.29),key^0x487ab391u);' + #10 +
'    vec3 patches=rp_gritGradient(p*vec2(.47,1.15),key^0xa9d63e27u);' + #10 +
'    float wander=(rp_gritGradient(vec2(p.x*.08,0),key).x-.5)*.12;' + #10 +
'    float axle=min(.78,road.x*.23),td=abs(abs(p.y-wander)-axle);' + #10 +
'    float tw=min(.36,road.x*.12),u=clamp((td-tw*.30)/max(.07,tw*.90),0.,1.);' + #10 +
'    float track=(1.-u*u*(3.-2.*u))*smoothstep(1.8,2.7,road.x);' + #10 +
'    float dtrack=-6.*u*(1.-u)/max(.07,tw*.90)*sign(p.y-wander)*sign(abs(p.y-wander)-axle);' + #10 +
'    dtrack*=smoothstep(1.8,2.7,road.x);' + #10 +
'    vec3 base=soil ? vec3(.33,.275,.205) : (sand ? vec3(.51,.46,.35) : vec3(.41,.39,.345));' + #10 +
'    if(loose)base=vec3(.395,.39,.365);' + #10 +
'    float baseVariation=1.+(broad.x-.5)*.36+(patches.x-.5)*.20;' + #10 +
'    float polished=track*(soil ? .035 : .045);' + #10 +
'    color=vec4(base*(baseVariation+polished),.96-track*.035);' + #10 +
'    float rut=(soil ? .016 : .007)*(1.+.25*max(condition-2.,0.));' + #10 +
'    relief=vec3(-rut*track,.018*track,0.);' + #10 +
'    gradient=vec2(0.,-rut*dtrack);' + #10 +
'    float size=soil ? .055 : (loose ? .038 : (kind>3.5 ? .014 : .024));' + #10 +
'    if(sand)size=.009;' + #10 +
'    float detail=1.-smoothstep(size*.30,size*1.40,pixel);' + #10 +
'    float stones=soil ? smoothstep(.48,.73,patches.x)*.30 : mix(.75,1.,patches.x);' + #10 +
'    stones*=1.-track*(loose ? .42 : .67);' + #10 +
'    if(sand)stones=.12;' + #10 +
'    // Decimetre piles of loose fines remain in the page mip even when an' + #10 +
'    // individual stone is subpixel. Wheel-worn strips have fewer piles.' + #10 +
'    float coarse=rp_gritGradient(p*vec2(6.,8.),key^0xe2761d45u).x-.5;' + #10 +
'    color.rgb*=1.+coarse*(soil ? .18 : .30)*(1.-track*.55);' + #10 +
'    // Preserve aggregate mean albedo when mip filtering hides the chips.' + #10 +
'    // Fading relief to zero must not turn the distant road into white dust.' + #10 +
'    const float grainMean=-.17;' + #10 +
'    vec3 matrix=color.rgb;color.rgb+=matrix*grainMean*(.72*stones);' + #10 +
'    if(detail>0.) {' + #10 +
'      vec3 tint; vec3 fine=rp_gritGradient(p/(size*.35),key^0x68bc21ebu);' + #10 +
'      vec4 rock=rp_aggregate(p/size,key,pixel/size,fine,-2.,tint);' + #10 +
'      float height=(loose ? .0026 : .0013)*stones*detail;' + #10 +
'      relief.x+=rock.x*height; gradient+=rock.yz*(height/size);' + #10 +
'      relief.y+=max(0.,.6-rock.x)*.065*stones*detail;' + #10 +
'      color.rgb+=matrix*(rock.w-grainMean)*(.72*stones*detail)+tint*stones*detail;' + #10 +
'    }' + #10 +
'    color.rgb=clamp(color.rgb,vec3(.08),vec3(.85));' + #10 +
'}' + #10 +
'void rp_surfaceGradient(vec2 p,float seed,float pixel,vec3 road,float condition,float material,' + #10 +
'    out vec4 color,out vec3 relief,out vec2 gradient) {' + #10 +
'    if(material>1.5)rp_unpavedGradient(p,seed,pixel,road,condition,material-1.,color,relief,gradient);' + #10 +
'    else rp_roadGradient(p,seed,pixel,road,condition,material,color,relief,gradient);' + #10 +
'}' + #10 +
'// Continuous coverage, opaque ground: no alpha test, extra pass or screen blur.' + #10 +
'// Noise changes the INSIDE of the shoulder; coverage is exactly zero at its edge.' + #10 +
'float rp_unpavedCoverage(vec4 coord,vec4 style,vec2 world,float pixel) {' + #10 +
'    if(mod(floor(style.z/512.),2.)>.5)return 1.;' + #10 +
'    float edge=max(0.,coord.z*.5-abs(coord.y));' + #10 +
'    float band=min(coord.z*.27,.70);' + #10 +
'    if(edge>band*1.1)return 1.;' + #10 +
'    float broad=rp_gritGradient(world*1.9,19u).x;' + #10 +
'    float small=rp_gritGradient(world*11.,71u).x;' + #10 +
'    small=mix(small,.5,smoothstep(.025,.15,pixel));' + #10 +
'    float ragged=band*(.32+.48*broad+.30*small);' + #10 +
'    return smoothstep(.012+ragged*.15,max(.035,ragged),edge);' + #10 +
'}' + #10
