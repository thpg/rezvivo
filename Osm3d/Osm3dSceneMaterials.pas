unit Osm3dSceneMaterials;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  CastleVectors,
  X3DNodes,
  Math,
  CastleImages,
  Osm3dGeoMath
  {$IFDEF TEX_SIZE_PROFILE}, Osm3dTexProfile{$ENDIF}
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  { Базовые цвета палитр стен. 0..5 — OSM material/colour (нейтрали).
    6..9 — архитектурные тона для домов без тегов (голубой/зелёный/
    розовый/жёлтый). ЕДИНСТВЕННЫЙ источник: CreateMaterialNode,
    PaletteBaseColor, BuildingMaterialDesc. }
  BUILDING_WALL_BASE: array[0..9] of TVector3 = (
    (X:0.92; Y:0.90; Z:0.86),    { 0 almost white }
    (X:0.88; Y:0.85; Z:0.78),    { 1 light cream / wood }
    (X:0.82; Y:0.78; Z:0.72),    { 2 beige / concrete }
    (X:0.85; Y:0.85; Z:0.83),    { 3 light grey / block }
    (X:0.78; Y:0.65; Z:0.58),    { 4 brick accent }
    (X:0.95; Y:0.93; Z:0.90),    { 5 white }
    (X:0.30; Y:0.40; Z:0.52),    { 6 dusty steel-blue }
    (X:0.34; Y:0.44; Z:0.32),    { 7 muted sage }
    (X:0.50; Y:0.34; Z:0.36),    { 8 muted dusty rose }
    (X:0.52; Y:0.40; Z:0.20));   { 9 muted ochre }
  BUILDING_ROOF_BASE: array[0..5] of TVector3 = (
    (X:0.78; Y:0.75; Z:0.70),    { light grey concrete }
    (X:0.65; Y:0.62; Z:0.60),    { grey slate }
    (X:0.55; Y:0.30; Z:0.25),    { terracotta accent }
    (X:0.85; Y:0.82; Z:0.78),    { almost white }
    (X:0.72; Y:0.70; Z:0.68),    { neutral grey }
    (X:0.60; Y:0.55; Z:0.50));   { grey-brown }

type
  TSceneMaterialKind = (
    smkTerrain,
    { Wall palette: 0..5 OSM material/colour, 6..9 architectural hash tints. }
    smkBuildingWall0, smkBuildingWall1, smkBuildingWall2,
    smkBuildingWall3, smkBuildingWall4, smkBuildingWall5,
    smkBuildingWall6, smkBuildingWall7, smkBuildingWall8, smkBuildingWall9,
    { Roof palette: 6 variants of terracotta / grey / copper. }
    smkBuildingRoof0, smkBuildingRoof1, smkBuildingRoof2,
    smkBuildingRoof3, smkBuildingRoof4, smkBuildingRoof5,
    { Legacy single-entry fallbacks. }
    smkBuildingWall, smkBuildingRoof,
    smkRoad,
    smkRoadMajor, smkRoadSecondary, smkRoadMinor, smkRoadService,
    smkRoadFootway, smkRoadCycleway, smkRoadRailway,
    smkTree,
    smkWater, smkGrass, smkForest,
    smkSand, smkParking, smkConstruction, smkFarmland,
    smkIndustrial, smkCemetery, smkScrub,
    smkPOI,
    smkFarTerrain,
    smkSurface,             { neutral white for textured ground —
                              colour comes entirely from the texture }
    { Fence/barrier palette — 6 materials, Ord parallel to TFenceMaterial
      (Osm3dGeomFences) and FENCE_MAT_* (Osm3dFenceComposite). }
    smkFence0, smkFence1, smkFence2,
    smkFence3, smkFence4, smkFence5,
    { House-number plate (facade sign). Own glyph atlas + unlit shader; the
      colour comes from the plate shader, this entry is the legacy fallback. }
    smkPlate,
    { Труба туннеля (стены/торцы/потолок): геометрия как у стен зданий
      (бетон, палитра 2), но ОТДЕЛЬНЫЙ вид материала — собирается в свой
      шейп с ShadowCaster=False, чтобы подземная труба не отбрасывала
      тень на композит земли. }
    smkTunnelWall,
    smkRoadFurniture { signs, zebra stripes and bump paint; one atlas batch }
  );

  { Backend-independent material. Colours in [0..1] sRGB. }
  TSceneMaterial = record
    Name:          string;
    DiffuseColor:  TVector3;
    SpecularColor: TVector3;
    EmissiveColor: TVector3;
    Shininess:     Single;     { 0..1 }
    Transparency:  Single;     { 0=opaque }
  end;

  TSceneMaterials = class
  public
    class function Get(Kind: TSceneMaterialKind): TSceneMaterial;

    { Caller owns the result; typical use adds it to an Appearance which
      then owns it. }
    class function CreateMaterialNode(Kind: TSceneMaterialKind): TMaterialNode;
  end;

type
  TTextureKind = (txWall, txWallSolid, txRoofTile, txRoad);

  TSceneTextures = class
  public
    class function Create(Kind: TTextureKind;
      LogProc: TLogProc = nil): TPixelTextureNode;
  end;

implementation

class function TSceneMaterials.Get(Kind: TSceneMaterialKind): TSceneMaterial;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1260);{$ENDIF}
  Result.EmissiveColor := Vector3(0, 0, 0);
  Result.SpecularColor := Vector3(0, 0, 0);
  Result.Shininess     := 0;
  Result.Transparency  := 0;

  case Kind of
    smkTerrain:
      begin
        Result.Name         := 'terrain';
        { Vivid lawn — streets.gl aesthetic choice. }
        Result.DiffuseColor := Vector3(0.50, 0.65, 0.35);
      end;
    smkBuildingWall, smkBuildingWall0, smkBuildingWall1, smkBuildingWall2,
    smkBuildingWall3, smkBuildingWall4, smkBuildingWall5,
    smkBuildingWall6, smkBuildingWall7, smkBuildingWall8, smkBuildingWall9,
    smkTunnelWall:
      begin
        Result.SpecularColor := Vector3(0.10, 0.10, 0.10);
        Result.Shininess     := 0.10;
        case Kind of
          smkBuildingWall0: begin Result.Name := 'wall_p0';
            Result.DiffuseColor := BUILDING_WALL_BASE[0]; end;
          smkBuildingWall1: begin Result.Name := 'wall_p1';
            Result.DiffuseColor := BUILDING_WALL_BASE[1]; end;
          smkBuildingWall2: begin Result.Name := 'wall_p2';
            Result.DiffuseColor := BUILDING_WALL_BASE[2]; end;
          smkBuildingWall3: begin Result.Name := 'wall_p3';
            Result.DiffuseColor := BUILDING_WALL_BASE[3]; end;
          smkBuildingWall4: begin Result.Name := 'wall_p4';
            Result.DiffuseColor := BUILDING_WALL_BASE[4]; end;
          smkBuildingWall5: begin Result.Name := 'wall_p5';
            Result.DiffuseColor := BUILDING_WALL_BASE[5]; end;
          smkBuildingWall6: begin Result.Name := 'wall_p6';
            Result.DiffuseColor := BUILDING_WALL_BASE[6]; end;
          smkBuildingWall7: begin Result.Name := 'wall_p7';
            Result.DiffuseColor := BUILDING_WALL_BASE[7]; end;
          smkBuildingWall8: begin Result.Name := 'wall_p8';
            Result.DiffuseColor := BUILDING_WALL_BASE[8]; end;
          smkBuildingWall9: begin Result.Name := 'wall_p9';
            Result.DiffuseColor := BUILDING_WALL_BASE[9]; end;
        else                begin Result.Name := 'wall';
            Result.DiffuseColor := Vector3(0.85, 0.82, 0.78); end;
        end;
      end;
    smkBuildingRoof, smkBuildingRoof0, smkBuildingRoof1, smkBuildingRoof2,
    smkBuildingRoof3, smkBuildingRoof4, smkBuildingRoof5:
      begin
        Result.SpecularColor := Vector3(0.10, 0.10, 0.10);
        Result.Shininess     := 0.10;
        case Kind of
          smkBuildingRoof0: begin Result.Name := 'roof_p0';
            Result.DiffuseColor := BUILDING_ROOF_BASE[0]; end;     { light grey concrete }
          smkBuildingRoof1: begin Result.Name := 'roof_p1';
            Result.DiffuseColor := BUILDING_ROOF_BASE[1]; end;     { grey slate }
          smkBuildingRoof2: begin Result.Name := 'roof_p2';
            Result.DiffuseColor := BUILDING_ROOF_BASE[2]; end;     { terracotta accent }
          smkBuildingRoof3: begin Result.Name := 'roof_p3';
            Result.DiffuseColor := BUILDING_ROOF_BASE[3]; end;     { almost white }
          smkBuildingRoof4: begin Result.Name := 'roof_p4';
            Result.DiffuseColor := BUILDING_ROOF_BASE[4]; end;     { neutral grey }
          smkBuildingRoof5: begin Result.Name := 'roof_p5';
            Result.DiffuseColor := BUILDING_ROOF_BASE[5]; end;     { grey-brown }
        else                begin Result.Name := 'roof';
            Result.DiffuseColor := Vector3(0.72, 0.68, 0.65); end;
        end;
      end;
    smkRoad:
      begin
        Result.Name          := 'road';
        Result.DiffuseColor  := Vector3(0.20, 0.20, 0.22);
        Result.SpecularColor := Vector3(0.05, 0.05, 0.05);
        Result.Shininess     := 0.05;
      end;
    smkRoadMajor:
      begin
        Result.Name          := 'road_major';
        Result.DiffuseColor  := Vector3(0.16, 0.16, 0.18);    { ~black asphalt }
        Result.SpecularColor := Vector3(0.08, 0.08, 0.08);
        Result.Shininess     := 0.08;
      end;
    smkRoadSecondary:
      begin
        Result.Name          := 'road_secondary';
        Result.DiffuseColor  := Vector3(0.22, 0.22, 0.24);
        Result.SpecularColor := Vector3(0.06, 0.06, 0.06);
        Result.Shininess     := 0.06;
      end;
    smkRoadMinor:
      begin
        Result.Name          := 'road_minor';
        Result.DiffuseColor  := Vector3(0.28, 0.28, 0.30);
      end;
    smkRoadService:
      begin
        Result.Name          := 'road_service';
        Result.DiffuseColor  := Vector3(0.45, 0.43, 0.40);    { gravel-grey concrete }
      end;
    smkRoadFootway:
      begin
        Result.Name          := 'road_footway';
        Result.DiffuseColor  := Vector3(0.62, 0.60, 0.58);
      end;
    smkRoadCycleway:
      begin
        Result.Name          := 'road_cycleway';
        Result.DiffuseColor  := Vector3(0.55, 0.30, 0.18);    { red brick / paint }
      end;
    smkRoadRailway:
      begin
        Result.Name          := 'road_railway';
        Result.DiffuseColor  := Vector3(0.28, 0.24, 0.22);    { dark brown ballast }
      end;
    smkSand:
      begin
        Result.Name          := 'sand';
        Result.DiffuseColor  := Vector3(0.85, 0.80, 0.55);
      end;
    smkParking:
      begin
        Result.Name          := 'parking';
        Result.DiffuseColor  := Vector3(0.32, 0.30, 0.30);
      end;
    smkConstruction:
      begin
        Result.Name          := 'construction';
        Result.DiffuseColor  := Vector3(0.55, 0.50, 0.42);
      end;
    smkFarmland:
      begin
        Result.Name          := 'farmland';
        Result.DiffuseColor  := Vector3(0.72, 0.65, 0.45);    { harvested wheat }
      end;
    smkIndustrial:
      begin
        Result.Name          := 'industrial';
        Result.DiffuseColor  := Vector3(0.50, 0.48, 0.45);
      end;
    smkCemetery:
      begin
        Result.Name          := 'cemetery';
        Result.DiffuseColor  := Vector3(0.45, 0.50, 0.35);    { darker grass }
      end;
    smkScrub:
      begin
        Result.Name          := 'scrub';
        Result.DiffuseColor  := Vector3(0.55, 0.58, 0.35);    { dry yellow-green }
      end;
    smkPOI:
      begin
        Result.Name          := 'poi';
        Result.DiffuseColor  := Vector3(0.40, 0.40, 0.45);
        Result.SpecularColor := Vector3(0.15, 0.15, 0.15);
        Result.Shininess     := 0.20;
      end;
    smkFarTerrain:
      begin
        { Hazy grey-blue: aerial-perspective stand-in for fog. Slightly
          green so distant forest conifers still read. }
        Result.Name          := 'far_terrain';
        Result.DiffuseColor  := Vector3(0.50, 0.55, 0.62);
      end;
    smkSurface:
      begin
        { Neutral white (1,1,1) so the surface texture renders unmodulated.
          Used with all Osm3dSurfaceTextures (grass/farmland/soil/asphalt). }
        Result.Name          := 'surface';
        Result.DiffuseColor  := Vector3(1.00, 1.00, 1.00);
        Result.SpecularColor := Vector3(0.00, 0.00, 0.00);
        Result.Shininess     := 0;
      end;
    smkTree:
      begin
        Result.Name          := 'tree';
        Result.DiffuseColor  := Vector3(0.30, 0.45, 0.25);
      end;
    smkWater:
      begin
        Result.Name          := 'water';
        { Тело воды тёмное — вода почти не рассеивает свет, светлой её
          делает отражение неба, а не собственный diffuse. Прежний
          (0.20,0.40,0.65) давал блёклую светлую заливку, забивавшую
          блики. Тёмный сине-зелёный diffuse + сильный specular: цвет
          воды задаёт отражение, шейдерные нормали играют бликами. }
        Result.DiffuseColor  := Vector3(0.02, 0.05, 0.07);
        Result.SpecularColor := Vector3(0.85, 0.90, 0.95);
        Result.Shininess     := 0.92;
        { Слабый холодный emissive — дешёвая имитация отражённого света
          неба: даёт воде узнаваемый сине-стальной тон в тени, не давая
          почти-чёрному diffuse превратить её в чёрную дыру. }
        Result.EmissiveColor := Vector3(0.04, 0.07, 0.10);
      end;
    smkGrass:
      begin
        Result.Name          := 'grass';
        Result.DiffuseColor  := Vector3(0.40, 0.55, 0.30);
      end;
    smkForest:
      begin
        Result.Name          := 'forest';
        Result.DiffuseColor  := Vector3(0.25, 0.40, 0.20);
      end;
    smkFence0, smkFence1, smkFence2,
    smkFence3, smkFence4, smkFence5:
      begin
        { Used only on the legacy (no-atlas) path; with the atlas ready the
          colour comes from the fence texture. }
        Result.SpecularColor := Vector3(0.06, 0.06, 0.06);
        Result.Shininess     := 0.05;
        case Kind of
          smkFence0: begin Result.Name := 'fence_p0';
            Result.DiffuseColor := Vector3(0.55, 0.40, 0.25); end;   { wood }
          smkFence1: begin Result.Name := 'fence_p1';
            Result.DiffuseColor := Vector3(0.55, 0.57, 0.60); end;   { chain-link }
          smkFence2: begin Result.Name := 'fence_p2';
            Result.DiffuseColor := Vector3(0.45, 0.47, 0.50); end;   { metal }
          smkFence3: begin Result.Name := 'fence_p3';
            Result.DiffuseColor := Vector3(0.70, 0.70, 0.68); end;   { concrete }
          smkFence4: begin Result.Name := 'fence_p4';
            Result.DiffuseColor := Vector3(0.30, 0.42, 0.24); end;   { hedge }
          smkFence5: begin Result.Name := 'fence_p5';
            Result.DiffuseColor := Vector3(0.58, 0.55, 0.50); end;   { stone }
        else            begin Result.Name := 'fence';
            Result.DiffuseColor := Vector3(0.55, 0.52, 0.48); end;
        end;
      end;
    smkPlate:
      begin
        { Legacy/no-shader fallback colour; the plate shader normally drives
          the colour (dark-blue plate + light text). }
        Result.Name          := 'plate';
        Result.DiffuseColor  := Vector3(0.09, 0.17, 0.42);
        Result.EmissiveColor := Vector3(0.09, 0.17, 0.42);
      end;
  else
    Result.Name          := 'default';
    Result.DiffuseColor  := Vector3(0.5, 0.5, 0.5);
  end;
end;

class function TSceneMaterials.CreateMaterialNode(Kind: TSceneMaterialKind): TMaterialNode;
var
  M: TSceneMaterial;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1261);{$ENDIF}
  M := Get(Kind);
  Result := TMaterialNode.Create;
  Result.DiffuseColor  := M.DiffuseColor;
  Result.SpecularColor := M.SpecularColor;
  Result.EmissiveColor := M.EmissiveColor;
  Result.Shininess     := M.Shininess;
  Result.Transparency  := M.Transparency;
  { X3D default AmbientIntensity 0.2 leaves shaded walls nearly black
    under a single solar light + headlight. 0.4 simulates skylight fill. }
  Result.AmbientIntensity := 0.4;
end;

function Hash2(X, Y: Integer): Single;
var
  H: LongWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(821);{$ENDIF}
  H := LongWord(X) * 374761393 + LongWord(Y) * 668265263;
  H := (H xor (H shr 13)) * 1274126177;
  H := H xor (H shr 16);
  Result := (H and $FFFFFF) / $FFFFFF;
end;

{ Brickwork pixel: shared between FillWall (window present) and
  FillWallSolid (gable / building:window=no). One course is 8 px tall,
  half-offset on alternate rows for running bond. }
procedure ComputeBrickPixel(X, Y: Integer; out R, G, B: Integer);
const
  BR_R = 200; BR_G = 192; BR_B = 175;
  BR_DK_R = 175; BR_DK_G = 168; BR_DK_B = 152;
var
  BrickX, BrickY: Integer;
  IsBrickRow, IsMortar: Boolean;
  N: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(822);{$ENDIF}
  IsBrickRow := (Y div 8) mod 2 = 0;
  if IsBrickRow then BrickX := X mod 16
  else               BrickX := (X + 8) mod 16;
  BrickY := Y mod 8;
  IsMortar := (BrickX = 0) or (BrickY = 0);
  if IsMortar then
  begin
    R := BR_DK_R; G := BR_DK_G; B := BR_DK_B;
  end
  else
  begin
    N := Hash2(X div 16, Y div 8) * 0.15 - 0.075;
    R := Round(BR_R * (1 + N));
    G := Round(BR_G * (1 + N));
    B := Round(BR_B * (1 + N));
  end;
end;

procedure FillWall(Img: TRGBImage);
{ Residential wall: one window centred in the 128² tile (60% × 60%),
  brickwork around it, frame 2 px wide along the inner edge.
  UV: 1 unit = 1 tile = 1 window × 1 floor. }
const
  WIN_BG_R = 70;  WIN_BG_G = 90;  WIN_BG_B = 130;     { sky-blue reflection }
  FRAME_R  = 50;  FRAME_G  = 50;  FRAME_B  = 60;
  WIN_LEFT_FRAC  = 0.20;
  WIN_RIGHT_FRAC = 0.80;
  WIN_TOP_FRAC   = 0.15;
  WIN_BOT_FRAC   = 0.85;
  FRAME_PX = 3;
var
  X, Y: Integer;
  W, H: Integer;
  WinL, WinR, WinT, WinB: Integer;
  R, G, B: Integer;
  N: Single;
  IsWindow, IsFrame: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(823);{$ENDIF}
  W := Img.Width;
  H := Img.Height;
  WinL := Round(W * WIN_LEFT_FRAC);
  WinR := Round(W * WIN_RIGHT_FRAC);
  WinT := Round(H * WIN_TOP_FRAC);
  WinB := Round(H * WIN_BOT_FRAC);

  for Y := 0 to H - 1 do
  begin
    for X := 0 to W - 1 do
    begin
      IsWindow := (X >= WinL) and (X < WinR) and (Y >= WinT) and (Y < WinB);
      IsFrame := IsWindow and
                 ((X < WinL + FRAME_PX) or (X >= WinR - FRAME_PX) or
                  (Y < WinT + FRAME_PX) or (Y >= WinB - FRAME_PX));

      if IsFrame then
      begin
        R := FRAME_R; G := FRAME_G; B := FRAME_B;
      end
      else if IsWindow then
      begin
        R := WIN_BG_R; G := WIN_BG_G; B := WIN_BG_B;
        { Impost (horizontal) and mullion (vertical) bars. }
        if (Y = (WinT + WinB) div 2) then
        begin
          R := FRAME_R; G := FRAME_G; B := FRAME_B;
        end;
        if (X = (WinL + WinR) div 2) then
        begin
          R := FRAME_R; G := FRAME_G; B := FRAME_B;
        end;
        { Top-to-bottom sky reflection gradient. }
        N := (Y - WinT) / (WinB - WinT);
        R := Round(R + 30 * (1 - N));
        G := Round(G + 25 * (1 - N));
        B := Round(B + 15 * (1 - N));
      end
      else
        ComputeBrickPixel(X, Y, R, G, B);

      Img.PixelPtr(X, Y)^.X := EnsureRange(R, 0, 255);
      Img.PixelPtr(X, Y)^.Y := EnsureRange(G, 0, 255);
      Img.PixelPtr(X, Y)^.Z := EnsureRange(B, 0, 255);
    end;
  end;
end;

procedure FillWallSolid(Img: TRGBImage);
{ Blank wall — brickwork only, no window. Used for pitched-roof gable
  ends and walls tagged building:window=no. }
var
  X, Y: Integer;
  R, G, B: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(824);{$ENDIF}
  for Y := 0 to Img.Height - 1 do
    for X := 0 to Img.Width - 1 do
    begin
      ComputeBrickPixel(X, Y, R, G, B);
      Img.PixelPtr(X, Y)^.X := EnsureRange(R, 0, 255);
      Img.PixelPtr(X, Y)^.Y := EnsureRange(G, 0, 255);
      Img.PixelPtr(X, Y)^.Z := EnsureRange(B, 0, 255);
    end;
end;

procedure FillRoofTile(Img: TRGBImage);
{ Dark grey slate, slight per-tile variation. }
const
  BASE_R = 95;  BASE_G = 92;  BASE_B = 88;
  EDGE_R = 60;  EDGE_G = 58;  EDGE_B = 55;
var
  X, Y: Integer;
  R, G, B: Integer;
  N: Single;
  TileX, TileY: Integer;
  InTileX, InTileY: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(825);{$ENDIF}
  for Y := 0 to Img.Height - 1 do
    for X := 0 to Img.Width - 1 do
    begin
      TileX := X div 16;       { 16×8 px tile, half-offset on even rows }
      TileY := Y div 8;
      if TileY mod 2 = 1 then
        InTileX := (X + 8) mod 16
      else
        InTileX := X mod 16;
      InTileY := Y mod 8;

      if (InTileX = 0) or (InTileX = 15) or (InTileY = 0) or (InTileY = 7) then
      begin
        R := EDGE_R; G := EDGE_G; B := EDGE_B;
      end
      else
      begin
        N := Hash2(TileX * 7, TileY) * 0.2 - 0.1;
        R := Round(BASE_R * (1 + N));
        G := Round(BASE_G * (1 + N));
        B := Round(BASE_B * (1 + N));
      end;
      Img.PixelPtr(X, Y)^.X := EnsureRange(R, 0, 255);
      Img.PixelPtr(X, Y)^.Y := EnsureRange(G, 0, 255);
      Img.PixelPtr(X, Y)^.Z := EnsureRange(B, 0, 255);
    end;
end;

procedure FillRoad(Img: TRGBImage);
{ Grey asphalt + dashed white centre line + per-texel noise. }
const
  ASPH_R = 70; ASPH_G = 70; ASPH_B = 75;
  LANE_R = 220; LANE_G = 220; LANE_B = 200;
var
  X, Y: Integer;
  R, G, B: Integer;
  N: Single;
  IsLane: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(826);{$ENDIF}
  for Y := 0 to Img.Height - 1 do
    for X := 0 to Img.Width - 1 do
    begin
      IsLane := (Y = Img.Height div 2) and ((X div 16) mod 2 = 0);
      if IsLane then
      begin
        R := LANE_R; G := LANE_G; B := LANE_B;
      end
      else
      begin
        N := Hash2(X, Y) * 0.10 - 0.05;
        R := Round(ASPH_R * (1 + N));
        G := Round(ASPH_G * (1 + N));
        B := Round(ASPH_B * (1 + N));
      end;
      Img.PixelPtr(X, Y)^.X := EnsureRange(R, 0, 255);
      Img.PixelPtr(X, Y)^.Y := EnsureRange(G, 0, 255);
      Img.PixelPtr(X, Y)^.Z := EnsureRange(B, 0, 255);
    end;
end;

class function TSceneTextures.Create(Kind: TTextureKind;
  LogProc: TLogProc): TPixelTextureNode;
{$PUSH}{$WARN 5024 OFF}  // unused LogProc kept for back-compat
var
  Img: TRGBImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1262);{$ENDIF}
  Img := TRGBImage.Create(128, 128);
  try
    case Kind of
      txWall:      FillWall(Img);
      txWallSolid: FillWallSolid(Img);
      txRoofTile:  FillRoofTile(Img);
      txRoad:      FillRoad(Img);
    end;

    Result := TPixelTextureNode.Create;
    { TSFImage.Value := Img transfers OWNERSHIP — do NOT Free Img after. }
    Result.FdImage.Value := Img;
    {$IFDEF TEX_SIZE_PROFILE}ProfileTexNode(Result, 'mtl');{$ENDIF}
    Result.RepeatS := True;
    Result.RepeatT := True;
    Img := nil;
  finally
    Img.Free;
  end;
end;
{$POP}

end.
