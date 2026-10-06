{ Reflection-only water film; deliberately not baked into the road atlas. }
    '// Stable road coordinates (metres), independent of camera, tile load and VT pages.' + #10 +
'float gpPuddleMask(vec4 c,vec4 style,float pixelMetres) {' + #10 +
    '    if(c.z<1.0 || c.w< -1.5)return 0.0;' + #10 +
    '    if(c.w<-.5){ // Unmarked baked roads and paved areas have world-space UVs.' + #10 +
    '        ivec2 cell=ivec2(floor(c.xy/32.0));vec3 g=rp_stoneKey(cell,173u);' + #10 +
    '        if(g.x>.32)return 0.0;' + #10 +
    '        vec2 p=mod(c.xy,32.0)-(vec2(9.0)+14.0*g.yz);float mask=0.0;' + #10 +
    '        if(dot(p,p)>100.0)return 0.0;' + #10 +
    '        for(int i=0;i<4;i++){vec3 h=rp_stoneKey(cell,uint(i+901));' + #10 +
    '            vec2 r=vec2(.4+1.2*h.x,.3+.6*h.y);vec2 q=(p-(h.yz-.5)*7.0)/r;' + #10 +
    '            if(dot(q,q)>2.0)continue;float shape=length(q)+.10*sin(q.x*4.7+h.z*6.0)*sin(q.y*3.9);' + #10 +
    '            float aa=max(.025,pixelMetres/min(r.x,r.y));mask=max(mask,1.0-smoothstep(1.0-aa,1.0+aa,shape));}' + #10 +
    '        return mask;' + #10 +
    '    }' + #10 +
    '    int block=int(floor(c.x/64.0));' + #10 +
    '    uint seed=uint(floor(style.w+.5));' + #10 +
    '    vec3 group=rp_stoneKey(ivec2(block,713),seed);' + #10 +
    '    if(group.x>.24)return 0.0; // roughly one group per 267 m of a road' + #10 +
    '    float along=mod(c.x,64.0)-(16.0+32.0*group.y);' + #10 +
    '    if(abs(along)>12.0)return 0.0;' + #10 +
    '    float side=group.z>.5?1.0:-1.0;' + #10 +
    '    bool gutter=group.y<.70;' + #10 +
    '    float across=gutter ? side*(c.z*.5-.48) : (group.z-.5)*c.z*.65;' + #10 +
    '    float mask=0.0;' + #10 +
    '    for(int i=0;i<5;i++) {' + #10 +
    '        vec3 h=rp_stoneKey(ivec2(block,i+901),seed);' + #10 +
    '        if(i>2 && h.z>.55)continue;' + #10 +
    '        vec2 radii=vec2(.32+1.10*h.x,.18+.48*h.y);' + #10 +
    '        if(i==0 && gutter)radii=vec2(2.0+3.5*h.x,.25+.22*h.y);' + #10 +
    '        vec2 d=vec2(along-(float(i)-2.0)*2.1, c.y-across-(h.z-.5)*.9);' + #10 +
    '        if(i==0 && gutter){d.x=along;d.y=c.y-side*(c.z*.5-.38);}' + #10 +
    '        vec2 q=d/radii;' + #10 +
    '        if(dot(q,q)>2.0)continue;' + #10 +
    '        float shape=length(q)+.10*sin(q.x*5.1+h.z*8.0)*sin(q.y*3.7+h.x*6.0);' + #10 +
    '        float aa=max(.025,pixelMetres/min(radii.x,radii.y));' + #10 +
    '        mask=max(mask,1.0-smoothstep(1.0-aa,1.0+aa,shape));' + #10 +
    '    }' + #10 +
    '    // Keep a small dry lip. The long puddle follows the road, beside its curb.' + #10 +
    '    return mask*smoothstep(.035,.13,c.z*.5-abs(c.y));' + #10 +
    '}' + #10
