unit GrassModel;
{$mode objfpc}{$H+}{$Q-}{$R-}
interface
uses Math, TreeMath;
const
  GRASS_SPECIES_COUNT = 8;
  GRASS_RENDER_CELL = 4;
  GRASS_LOD_START = 21.0;
  GRASS_LOD_END = 42.0; { maximum; lawn fades from 21 to 30 m }
  GRASS_TOP_START = 36.0;
  GRASS_TOP_END = 56.0;
  GRASS_VIEW_FADE = 106.0;
  GRASS_VIEW_END = 130.0;
  GRASS_BAKE_SIZE = 512;
  GRASS_ATLAS_VIEWS = 4; { three side slices and one top view }
  GRASS_CARDS = 4; { scattered volume cards, plus the continuous ground carpet }
  GRASS_ATLAS_LAYERS = GRASS_SPECIES_COUNT * GRASS_ATLAS_VIEWS;
  GRASS_BLADES = 256;
  GRASS_MODEL_VERSION = 8;
  GRASS_VIEW_ELEVATIONS:array[0..3]of Single=(0.125,0.25,0.5,0.98);
type
  TGrassLodSettings = record
    BladeStart,BladeEnd,TopStart,TopEnd,ViewFade,ViewEnd:Single;
    DensityStart,DensityEnd:Single;
  end;
  { One square metre, clipped to its source triangle. No per-blade CPU data. }
  TGrassPatch = packed record
    Base: TTreeVec3; Kind: Single;
    { Reserved/Pad0/Pad1 hold the affine interpolated normal Y in live patches.
      The atlas baker reuses Reserved for its canopy layer. Keep 64 bytes. }
    SlopeX,SlopeZ,Seed,Reserved: Single;
    AX,AZ,BX,BZ,CX,CZ,Pad0,Pad1: Single;
  end;
  TGrassPatches = array of TGrassPatch;
  TGrassProfile = packed record
    Height,Width,Density,Flowers: Single;
    { A habitat contains several growth forms. Shared by live geometry and
      every atlas view; no additional per-plant CPU/GPU descriptors. }
    Broadleaf,Rosettes,SeedHeads,Dryness,Variation: Single;
    { Expected weed pairs per square metre and maximum stalk height. The
      ordinary grass stays low; these are independent, sparse plants. }
    Weeds,WeedHeight: Single;
    Color: TTreeVec3;
    BladeViewGain:array[0..3]of TTreeVec3;
  end;
  TGrassProfiles = array[0..GRASS_SPECIES_COUNT-1] of TGrassProfile;
function GrassName(Kind: Integer): string;
function GrassDescription(Kind: Integer): string;
function DefaultGrassProfile(Kind: Integer): TGrassProfile;
function GrassBladeDistance(Height:Single):Single;
function GrassLodHeightScale(Height:Single):Single;
function DefaultGrassLod:TGrassLodSettings;
function GrassHash(N: LongWord): LongWord;
function GrassCellSeed(X,Z: Integer): LongWord;
function GrassHabitatAt(X,Z: Integer): Single;
function WholeGrassPatch(X,Z,Kind: Integer): TGrassPatch;
function GrassPointInside(const P: TGrassPatch; X,Z: Single): Boolean;
function GrassSurfaceGLSL: string;
implementation
function GrassLodHeightScale(Height:Single):Single;
begin Result:=0.8+0.2*EnsureRange((Height-0.09)/0.53,0.0,1.0);end;
function DefaultGrassLod:TGrassLodSettings;
begin
  Result.BladeStart:=28;Result.BladeEnd:=60;
  Result.TopStart:=64;Result.TopEnd:=90;
  Result.ViewFade:=140;Result.ViewEnd:=180;
  Result.DensityStart:=22;Result.DensityEnd:=40;
end;
function GrassBladeDistance(Height:Single):Single;
begin Result:=EnsureRange(26+Height*26,30.0,GRASS_LOD_END);end;
function GrassSurfaceGLSL: string;
begin
  { Shared by blades, their atlas and the terrain beyond the grass renderer.
    Bounded coordinates and integer hashes stay stable far from route start. }
  Result:=
    'float gcGrassHash(uvec2 p,uint mask){'+#10+
    ' p &= uvec2(mask); uint n=p.x*0x9e3779b9u ^ p.y*0x85ebca6bu;'+#10+
    ' n^=n>>16u; n*=0x7feb352du; n^=n>>15u; n*=0x846ca68bu; n^=n>>16u;'+#10+
    ' return float(n&65535u)/65535.0; }'+#10+
    'float gcGrassNoise(vec2 p,uint mask){'+#10+
    ' uvec2 c=uvec2(ivec2(floor(p))); vec2 f=fract(p); f=f*f*(3.0-2.0*f);'+#10+
    ' return mix(mix(gcGrassHash(c,mask),gcGrassHash(c+uvec2(1,0),mask),f.x),'+#10+
    ' mix(gcGrassHash(c+uvec2(0,1),mask),gcGrassHash(c+uvec2(1,1),mask),f.x),f.y); }'+#10+
    'float gcGrassSurface(vec2 p,float footprint){'+#10+
    ' float fine=1.0-smoothstep(0.10,0.4,footprint);'+#10+
    ' float coarse=1.0-smoothstep(1.0,4.0,footprint);'+#10+
    ' float result=1.0;'+#10+
    ' if(fine>0.0)result+=0.30*(gcGrassNoise(p*4.0,1023u)-0.5)*fine;'+#10+
    ' if(coarse>0.0)result+=0.15*(gcGrassNoise(p*0.5,127u)-0.5)*coarse;'+#10+
    ' return result+0.16*(gcGrassNoise(p*0.0625,15u)-0.5); }'+#10+
    'float gcSlopeRockMask(vec2 p,float normalUp){'+#10+
    ' float up=clamp(abs(normalUp),0.0,1.0);'+#10+
    ' if(up>=0.88)return 0.0; if(up<=0.44)return 1.0;'+#10+
    ' float edge=0.085*(gcGrassNoise(p*0.25,63u)-0.5)'+#10+
    '           +0.035*(gcGrassNoise(p,255u)-0.5);'+#10+
    ' return 1.0-smoothstep(0.5,0.819152,up+edge); }'+#10;
end;
function GrassName(Kind: Integer): string;
const Names: array[0..7] of string = ('meadow','broadleaf','dry','blue-flowers','lawn','dry-tall','short','pink-flowers');
begin Result:=Names[EnsureRange(Kind,0,7)]; end;
function GrassDescription(Kind: Integer): string;
const Descriptions:array[0..7]of string=(
  'Meadow: grasses, broad leaves, clover and seed heads',
  'Woodland: ferns, broad leaves and low rosettes',
  'Dry meadow: curled blades and straw seed heads',
  'Wildflowers: blue, white and yellow flowers',
  'Lawn: short blades with a little clover',
  'Tall dry grass: tussocks and oat-like seed heads',
  'Low ground cover: fine grass, burdock leaves and scattered thistles',
  'Flower garden: pink flowers and leafy rosettes');
begin Result:=Descriptions[EnsureRange(Kind,0,7)];end;
function DefaultGrassProfile(Kind: Integer): TGrassProfile;
var I:Integer;
begin
  Result:=Default(TGrassProfile);Result.Height:=0.34;Result.Width:=0.012;
  Result.Density:=1;Result.Color:=Vec(0.09,0.22,0.028);
  Result.Broadleaf:=0.17;Result.Rosettes:=0.12;Result.SeedHeads:=0.12;
  Result.Dryness:=0.14;Result.Variation:=0.72;Result.Flowers:=0.012;
  Result.Weeds:=0.12;Result.WeedHeight:=0.95;
  for I:=0 to 3 do Result.BladeViewGain[I]:=Vec(1,1,1);
  case Kind of
    1:begin Result.Height:=0.45;Result.Width:=0.020;Result.Color:=Vec(0.065,0.18,0.024);
      Result.Broadleaf:=0.48;Result.Rosettes:=0.23;Result.SeedHeads:=0.015;Result.Dryness:=0.035;Result.Flowers:=0;Result.Weeds:=0.08;Result.WeedHeight:=0.78;end;
    2:begin Result.Height:=0.38;Result.Color:=Vec(0.23,0.20,0.060);
      Result.Broadleaf:=0.06;Result.Rosettes:=0.09;Result.SeedHeads:=0.25;Result.Dryness:=0.65;Result.Flowers:=0;Result.Weeds:=0.04;end;
    3:begin Result.Height:=0.39;Result.Flowers:=0.075;Result.Broadleaf:=0.24;Result.Rosettes:=0.17;Result.Dryness:=0.06;end;
    4:begin Result.Height:=0.09;Result.Width:=0.009;Result.Color:=Vec(0.080,0.205,0.030);
      Result.Broadleaf:=0.015;Result.Rosettes:=0.055;Result.SeedHeads:=0;Result.Dryness:=0.025;Result.Variation:=0.25;Result.Flowers:=0;Result.Weeds:=0;end;
    5:begin Result.Height:=0.62;Result.Width:=0.014;Result.Color:=Vec(0.24,0.19,0.050);
      Result.Broadleaf:=0.035;Result.Rosettes:=0.045;Result.SeedHeads:=0.42;Result.Dryness:=0.78;Result.Variation:=0.9;Result.Flowers:=0;Result.Weeds:=0.04;end;
    6:begin Result.Height:=0.12;Result.Width:=0.009;Result.Color:=Vec(0.07,0.20,0.025);
      Result.Broadleaf:=0.16;Result.Rosettes:=0.38;Result.SeedHeads:=0;Result.Dryness:=0.04;Result.Variation:=0.5;Result.Flowers:=0;Result.Weeds:=0.09;Result.WeedHeight:=0.85;end;
    7:begin Result.Height:=0.37;Result.Flowers:=0.10;Result.Broadleaf:=0.30;Result.Rosettes:=0.22;Result.Dryness:=0.06;Result.Weeds:=0.025;Result.WeedHeight:=0.70;end;
  end;
end;
function GrassHash(N: LongWord): LongWord;
begin N:=N xor (N shr 16);N:=N*$7feb352d;N:=N xor (N shr 15);N:=N*$846ca68b;Result:=N xor (N shr 16);end;
function GrassCellSeed(X,Z: Integer): LongWord;
begin Result:=GrassHash(LongWord(X) xor GrassHash(LongWord(Z)+$9e3779b9)) and $ffffff;end;
function GrassHabitatAt(X,Z: Integer): Single;
var CX,CZ:Integer;FX,FZ,A,B:Double;
  function Value(DX,DZ:Integer):Double;
  begin Result:=(GrassCellSeed(CX+DX,CZ+DZ)and $ffff)/65535;end;
begin
  { Twelve-metre communities, continuous across tiles and camera rebuilds.
    Evaluate once per compact patch instead of noise for every blade vertex. }
  CX:=Floor((X+0.5)/12);CZ:=Floor((Z+0.5)/12);
  FX:=(X+0.5)/12-CX;FZ:=(Z+0.5)/12-CZ;
  FX:=FX*FX*(3-2*FX);FZ:=FZ*FZ*(3-2*FZ);
  A:=Value(0,0)*(1-FX)+Value(1,0)*FX;B:=Value(0,1)*(1-FX)+Value(1,1)*FX;
  Result:=A*(1-FZ)+B*FZ;
end;
function WholeGrassPatch(X,Z,Kind: Integer): TGrassPatch;
begin
  Result:=Default(TGrassPatch);Result.Base:=Vec(X+0.5,0,Z+0.5);
  { Fractional kind carries habitat variation; rounding still yields the
    atlas family. Preserve the 64-byte descriptor and draw batching. }
  Result.Kind:=Kind+0.4*GrassHabitatAt(X,Z);
  Result.Seed:=GrassCellSeed(X,Z);
  Result.AX:=-4;Result.AZ:=-4;Result.BX:=8;Result.BZ:=-4;Result.CX:=-4;Result.CZ:=8;
end;
function GrassPointInside(const P: TGrassPatch; X,Z: Single): Boolean;
var A,B,C: Single;
begin
  A:=(P.BX-P.AX)*(Z-P.AZ)-(P.BZ-P.AZ)*(X-P.AX);
  B:=(P.CX-P.BX)*(Z-P.BZ)-(P.CZ-P.BZ)*(X-P.BX);
  C:=(P.AX-P.CX)*(Z-P.CZ)-(P.AZ-P.CZ)*(X-P.CX);
  Result:=((A>=0)and(B>=0)and(C>=0))or((A<=0)and(B<=0)and(C<=0));
end;
end.
