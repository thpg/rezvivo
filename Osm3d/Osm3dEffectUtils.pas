unit Osm3dEffectUtils;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  X3DNodes;

{ Shared tail for the counter effects: append (not replace) Effect onto
  App's effect list, preserving any existing LOD/atlas/glass effect.

  CRITICAL: TAppearanceNode.SetEffects internally clears FdEffects via
  TMFNode.AssignItems before re-adding. During the clear, each existing
  effect's parent-field count drops to zero, which (KeepExisting=0
  default) triggers destruction. By the time SetEffects re-adds them,
  our array holds dangling pointers → CGE crashes in AddParentField
  with "Self = nil".

  Fix: bump KeepExisting on each existing effect before SetEffects,
  decrement after. KeepExisting > 0 makes RemoveParentField a no-op
  for destruction. }
procedure ChainEffectApp(App: TAppearanceNode; Effect: TEffectNode);
{ Блендинг цвета по расстоянию от камеры: near -> цвет травы, far -> цвет дальней
  земли. Общий для тайлов-заглушек и дальней земли. }
function BuildGroundBlendEffect(GR, GG, GB, FR, FG, FB, NearM, FarM: Single): TEffectNode;

implementation

uses
  SysUtils, CastleRenderOptions;

{$IFDEF IAM_LIVE}
uses
  Osm3dIamLive;
{$ENDIF}

procedure ChainEffectApp(App: TAppearanceNode; Effect: TEffectNode);
var
  Existing: array of TEffectNode;
  OldCount, I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1668);{$ENDIF}
  OldCount := App.FdEffects.Count;
  SetLength(Existing, OldCount + 1);
  for I := 0 to OldCount - 1 do
  begin
    Existing[I] := App.FdEffects[I] as TEffectNode;
    if Existing[I] <> nil then
      Existing[I].KeepExistingBegin;
  end;
  Existing[OldCount] := Effect;
  try
    App.SetEffects(Existing);
  finally
    for I := 0 to OldCount - 1 do
      if Existing[I] <> nil then
        Existing[I].KeepExistingEnd;
  end;
end;


function BuildGroundBlendEffect(GR, GG, GB, FR, FG, FB, NearM, FarM: Single): TEffectNode;
var Eff: TEffectNode; PV, PF: TEffectPartNode; FS: TFormatSettings; VS, FSrc: string;
begin
  FS := DefaultFormatSettings; FS.DecimalSeparator := '.';
  VS := 'varying vec3 osm3dBlendEye;' + LineEnding +
    'void PLUG_vertex_eye_space(const in vec4 vertex_eye, const in vec3 normal_eye)' + LineEnding +
    '{ osm3dBlendEye = vertex_eye.xyz; }' + LineEnding;
  FSrc := 'varying vec3 osm3dBlendEye;' + LineEnding +
    'void PLUG_fragment_modify(inout vec4 fragment_color)' + LineEnding +
    '{' + LineEnding +
    Format('  float t = clamp((length(osm3dBlendEye) - %.1f) / (%.1f - %.1f), 0.0, 1.0);',
      [NearM, FarM, NearM], FS) + LineEnding +
    Format('  fragment_color.rgb = mix(vec3(%.4f, %.4f, %.4f), vec3(%.4f, %.4f, %.4f), t);',
      [GR, GG, GB, FR, FG, FB], FS) + LineEnding +
    '  fragment_color.a = 1.0;' + LineEnding +
    '}' + LineEnding;
  PV := TEffectPartNode.Create; PV.ShaderType := stVertex;   PV.Contents := VS;
  PF := TEffectPartNode.Create; PF.ShaderType := stFragment; PF.Contents := FSrc;
  Eff := TEffectNode.Create; Eff.SetParts([PV, PF]);
  Result := Eff;
end;

end.
