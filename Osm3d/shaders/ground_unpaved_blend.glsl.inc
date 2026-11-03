{ Uses the same atlas, world phase, filtering and optional block randomization
  as adjacent ground. Only evaluated inside an unpaved road's narrow shoulder. }
'vec4 gc_road_land_display=vec4(0.);' + #10 +
'void gcLandTap(int mat,vec2 uv,vec2 dx,vec2 dy,float weight,bool grass,' + #10 +
'    inout vec3 albedo,inout vec3 normal,inout vec4 mask) {' + #10 +
'    vec2 cell=vec2(float(mat%u_ground_grid_cols),float(mat/u_ground_grid_cols));' + #10 +
'    vec2 span=1./vec2(float(u_ground_grid_cols),float(u_ground_grid_rows));' + #10 +
'    float inset=u_ground_cell_inset,inside=1.-2.*inset;' + #10 +
'    vec2 at=(cell+inset+clamp(fract(uv),vec2(.001),vec2(.999))*inside)*span;' + #10 +
'    vec2 gx=dx*span*inside,gy=dy*span*inside;' + #10 +
'    albedo+=textureGrad(u_ground_atlas,at,gx,gy).rgb*weight;' + #10 +
'    if(!grass){normal+=textureGrad(u_ground_normal_atlas,at,gx,gy).rgb*weight;' + #10 +
'      mask+=textureGrad(u_ground_mask_atlas,at,gx,gy)*weight;}' + #10 +
'}' + #10 +
'void gcRoadLand(int mat,vec2 local,vec2 dx,vec2 dy,out vec3 albedo,out vec3 normal,out vec4 mask) {' + #10 +
'    bool grass=mat==0 || mat==1 || mat==2 || mat==8 || mat==9;' + #10 +
'    float scale=grass ? 4. : max(.001,u_ground_uv_scale[mat]);' + #10 +
'    vec2 phase=mod(mod(gc_ground_origin.xz,scale)+gc_ground_origin_low.xz,scale);' + #10 +
'    vec2 uv=(local+phase)/scale,gx=dx/scale,gy=dy/scale;' + #10 +
'    albedo=vec3(0);normal=vec3(0);mask=vec4(0);' + #10 +
'    if(grass){uv.y=-uv.y;gx.y=-gx.y;gy.y=-gy.y;}' + #10 +
'    vec3 rnd=u_ground_rnd[mat];' + #10 +
'    if(rnd.x>.0001 && !grass){' + #10 +
'      vec4 origin=gc_ground_grid_origin[mat];' + #10 +
'      vec2 gp=local/rnd.x+origin.zw-.5,cell=floor(gp),f=gp-cell;' + #10 +
'      vec2 t=clamp((f-.5)*3.+.5,0.,1.);t=t*t*(3.-2.*t);' + #10 +
'      float repeat=rnd.x/scale;' + #10 +
'      for(int j=0;j<2;j++)for(int i=0;i<2;i++){' + #10 +
'        vec2 corner=vec2(float(i),float(j));' + #10 +
'        float weight=(i==0 ? 1.-t.x : t.x)*(j==0 ? 1.-t.y : t.y);' + #10 +
'        if(weight>0.){mat2 rot;vec2 offset;gc_rndBlockTap(cell+origin.xy+corner,rnd.yz,rot,offset);' + #10 +
'          gcLandTap(mat,rot*((f+.5-corner)*repeat)+offset,rot*gx,rot*gy,weight,false,albedo,normal,mask);}' + #10 +
'      }' + #10 +
'    }else gcLandTap(mat,uv,gx,gy,1.,grass,albedo,normal,mask);' + #10 +
'    float farFade=smoothstep(.12,.50,max(length(gx),length(gy)));' + #10 +
'    albedo=mix(albedo,u_ground_fallback_rgb[mat],farFade);' + #10 +
'    mask=mix(mask,vec4(u_ground_roughness[mat],u_ground_metallic[mat],1,1),farFade);' + #10 +
'    if(grass){normal=vec3(.5,.5,1);mask=vec4(.97,0,1,1);}' + #10 +
'}' + #10
