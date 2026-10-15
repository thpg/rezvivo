'// Scene-linear lighting. All custom world surfaces share these parameters.' + #10 +
'uniform vec4 rz_scene; // enabled, display transform, exposure, reserved' + #10 +
'uniform vec4 rz_light; // sunlight, sky irradiance/pi, ground irradiance/pi' + #10 +
'vec3 rzSceneSky(vec3 n) {' + #10 +
'    return mix(vec3(.96,.91,.83)*rz_light.z,' + #10 +
'               vec3(.85,.92,1.0)*rz_light.y, clamp(n.y*.5+.5,0.,1.));' + #10 +
'}' + #10 +
'vec3 rzSceneSun() { return vec3(1.0,.975,.94)*rz_light.x; }' + #10 +
'vec3 rzSceneTone(vec3 c) {' + #10 +
'    c=max(c*rz_scene.z,vec3(0));' + #10 +
'    if(rz_scene.y<.5) return c/(1.+c);' + #10 +
'    if(rz_scene.y<1.5) return clamp((c*(2.51*c+.03))/(c*(2.43*c+.59)+.14),0.,1.);' + #10 +
'    // Khronos PBR Neutral: https://github.com/KhronosGroup/ToneMapping' + #10 +
'    // Analytical implementation of the published offset and peak compression.' + #10 +
'    float low=min(c.r,min(c.g,c.b));' + #10 +
'    c-=low<.08 ? low-6.25*low*low : .04;' + #10 +
'    float peak=max(c.r,max(c.g,c.b));' + #10 +
'    if(peak<.76) return c;' + #10 +
'    float compressed=1.-.0576/(peak-.52);' + #10 +
'    c*=compressed/peak;' + #10 +
'    return mix(c,vec3(compressed),1.-1./(.15*(peak-compressed)+1.));' + #10 +
'}' + #10 +
'vec3 rzSceneDisplay(vec3 c) {' + #10 +
'    return pow(max(rzSceneTone(c),vec3(0)),vec3(1./2.2));' + #10 +
'}' + #10 +
''
