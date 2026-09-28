unit Osm3dRockMaterial;
{$mode objfpc}{$H+}
interface
function RockMaterialGLSL: string;
implementation
function RockMaterialGLSL: string;
begin
  Result := {$I shaders/rock_material.glsl.inc};
end;
end.
