void PLUG_material_metallic_roughness(inout float metallic, inout float perceptualRoughness)
{
    metallic = bldMetallic;
    perceptualRoughness = bldRoughness;
}
void PLUG_material_emissive(inout vec3 emissive)
{
    emissive += bldEnvironment;
}
void PLUG_light_scale(inout float scale, const in vec3 normal_eye, const in vec3 light_dir)
{
    // Only attenuate the ambient fill. Leave the sun and its native shadow alone.
    vec3 L = normalize(direction_eye_to_world_space(light_dir));
    float isSun = smoothstep(0.985,0.998,dot(L,normalize(gc_SunDirToward)));
    scale *= mix(bldCavity,1.0,isSun);
}
