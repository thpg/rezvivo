unit VegetationRenderOptions;
{$mode objfpc}{$H+}
interface
{ Internal, process-lifetime A/B controls. No user-facing quality setting:
  each option preserves the requested population, distances and materials. }
var
  VegetationCheapRejects, VegetationDepthOrder, VegetationProfileCache: Boolean;
  VegetationAcceptedRoots, VegetationStableFarBuffers: Boolean;
  VegetationAtlasBudget, VegetationCardEnvelopes: Boolean;
  { Main/render-thread cumulative diagnostics; take differences between MCP
    snapshots. They never participate in cache keys or quality decisions. }
  VegetationGrassProfileUploads,VegetationGrassProfileHits:QWord;
  VegetationTreeSeasonBuilds,VegetationTreeSeasonHits:QWord;
  VegetationRootUploads,VegetationRootUploadBytes:QWord;
  VegetationArenaHits,VegetationAtlasUploadBytes,VegetationAtlasPublished:QWord;
implementation
uses SysUtils;
function Enabled(const Name: string): Boolean;
begin Result := GetEnvironmentVariable(Name) <> '0'; end;
initialization
  VegetationCheapRejects := Enabled('REZVIVO_VEG_CHEAP_REJECTS');
  VegetationDepthOrder := Enabled('REZVIVO_VEG_DEPTH_ORDER');
  VegetationProfileCache := Enabled('REZVIVO_VEG_PROFILE_CACHE');
  { Matched road/aerial/moving screening: accepted roots saved vertex work,
    but worsened moving frame tails; stable far buffers had no repeatable
    whole-frame benefit. Retain explicit opt-ins for future driver tests. }
  VegetationAcceptedRoots := GetEnvironmentVariable('REZVIVO_VEG_ACCEPTED_ROOTS') = '1';
  VegetationStableFarBuffers := GetEnvironmentVariable('REZVIVO_VEG_STABLE_FAR') = '1';
  { Gated fresh-process ABBA: no repeatable whole-frame tail improvement,
    while ten atlases become ready later. Keep staging opt-in for driver
    compatibility/experiments; ordinary uploads remain the measured default. }
  VegetationAtlasBudget := GetEnvironmentVariable('REZVIVO_VEG_ATLAS_BUDGET') = '1';
  { The conservative fan passed coverage checks, but its extra vertices and
    footprint calculation outweighed saved overdraw in the measured views. }
  VegetationCardEnvelopes := GetEnvironmentVariable('REZVIVO_VEG_CARD_ENVELOPES') = '1';
end.
