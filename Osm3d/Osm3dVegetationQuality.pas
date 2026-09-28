unit Osm3dVegetationQuality;
{$mode objfpc}{$H+}
interface
uses GrassModel;
type
  TVegetationDetail = record
    TreeDistance,TreeFadeStart,TreePreloadDistance,TreeFadeSeconds:Single;
    TreeCacheRate,TreeDetailScale,TreeMinLeafFraction:Single;
    TreeCacheMiB:Integer;
    TreeStableRange,Adaptive:Boolean;
    Grass:TGrassLodSettings;
    GrassCacheRadius,GrassRefreshStep:Single;
    GrassUploadCount,GrassUploadMS:Integer;
  end;
var
  VegetationDetail:TVegetationDetail;
  VegetationQualityRevision:Cardinal=0;
function VegetationPreset(Level:Integer):TVegetationDetail;
function LegacyTreeQuality(Distance:Integer):Integer;
procedure SetVegetationQuality(Level,CacheRate:Integer;Adaptive:Boolean);
implementation
uses Math;
function LegacyTreeQuality(Distance:Integer):Integer;
begin
  if Distance<=0 then Result:=0
  else if Distance<=75 then Result:=1
  else if Distance<=100 then Result:=2
  else if Distance<300 then Result:=3 else Result:=4;
end;
function VegetationPreset(Level:Integer):TVegetationDetail;
begin
  Result:=Default(TVegetationDetail);
  Result.Adaptive:=True;Result.TreeCacheRate:=1;
  Result.Grass:=DefaultGrassLod;
  case EnsureRange(Level,0,4) of
    0,1:begin
      Result.TreeDistance:=70;Result.TreeFadeStart:=45;Result.TreePreloadDistance:=110;
      Result.TreeFadeSeconds:=0.65;Result.TreeCacheMiB:=128;
      Result.TreeDetailScale:=0.65;Result.TreeMinLeafFraction:=0.125;
      Result.Grass.BladeStart:=16;Result.Grass.BladeEnd:=30;
      Result.Grass.TopStart:=32;Result.Grass.TopEnd:=48;
      Result.Grass.ViewFade:=70;Result.Grass.ViewEnd:=90;
      Result.Grass.DensityStart:=6;Result.Grass.DensityEnd:=12;
      Result.GrassRefreshStep:=8;
    end;
    2:begin
      Result.TreeDistance:=120;Result.TreeFadeStart:=80;Result.TreePreloadDistance:=180;
      Result.TreeFadeSeconds:=1;Result.TreeCacheMiB:=256;
      Result.TreeDetailScale:=0.8;Result.TreeMinLeafFraction:=0.16;
      Result.Grass.BladeStart:=22;Result.Grass.BladeEnd:=44;
      Result.Grass.TopStart:=48;Result.Grass.TopEnd:=70;
      Result.Grass.ViewFade:=100;Result.Grass.ViewEnd:=130;
      Result.Grass.DensityStart:=10;Result.Grass.DensityEnd:=18;
      Result.GrassRefreshStep:=8;
    end;
    3:begin
      Result.TreeDistance:=180;Result.TreeFadeStart:=115;Result.TreePreloadDistance:=260;
      Result.TreeFadeSeconds:=1.3;Result.TreeCacheMiB:=384;
      Result.TreeDetailScale:=0.9;Result.TreeMinLeafFraction:=0.22;
      Result.Grass.DensityStart:=16;Result.Grass.DensityEnd:=30;
      Result.GrassRefreshStep:=8;
    end;
    4:begin
      Result.TreeDistance:=300;Result.TreeFadeStart:=190;Result.TreePreloadDistance:=420;
      Result.TreeFadeSeconds:=1.8;Result.TreeCacheMiB:=512;
      Result.TreeDetailScale:=1;Result.TreeMinLeafFraction:=0.4;Result.TreeStableRange:=True;
      Result.Grass.BladeStart:=46;Result.Grass.BladeEnd:=90;
      Result.Grass.TopStart:=96;Result.Grass.TopEnd:=130;
      Result.Grass.ViewFade:=180;Result.Grass.ViewEnd:=220;
      Result.Grass.DensityStart:=30;Result.Grass.DensityEnd:=60;
      Result.GrassRefreshStep:=6;
    end;
  end;
  Result.GrassCacheRadius:=Ceil((Result.Grass.ViewEnd+32)/GRASS_RENDER_CELL)*GRASS_RENDER_CELL;
  Result.GrassUploadCount:=2;Result.GrassUploadMS:=2;
end;
procedure SetVegetationQuality(Level,CacheRate:Integer;Adaptive:Boolean);
begin
  VegetationDetail:=VegetationPreset(Level);VegetationDetail.Adaptive:=Adaptive;
  case CacheRate of
    0:begin VegetationDetail.TreeCacheRate:=0.5;VegetationDetail.GrassUploadCount:=1;VegetationDetail.GrassUploadMS:=1 end;
    2:begin VegetationDetail.TreeCacheRate:=1.75;VegetationDetail.GrassUploadCount:=4;VegetationDetail.GrassUploadMS:=4 end;
  end;
  Inc(VegetationQualityRevision);
end;
initialization
  VegetationDetail:=VegetationPreset(2);
end.
