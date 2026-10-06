void PLUG_material_metallic_roughness(inout float metallic, inout float perceptualRoughness)
{
    metallic=0.0; perceptualRoughness=vBldDetailColor.a;
}
