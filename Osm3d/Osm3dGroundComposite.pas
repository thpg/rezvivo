unit Osm3dGroundComposite;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses Osm3dStaticGeometry,
  Classes,
  SysUtils,
  CastleImages,
  CastleVectors,
  CastleColors,              { TCastleColor — used by the PBR-set channel combiners }
  CastleRenderOptions,
  X3DNodes,
  Osm3dCompositeAtlas,   { TCompositeAtlasBase / TAtlasLayout / ATLAS_CELL_GUTTER }
  Osm3dImageCodecLock,   { EnterImageCodec/Leave — Vampyre не потокобезопасен }
  Osm3dGeoMath,
  Osm3dGeomSurface,
  Osm3dGeomRoads,
  Osm3dGeomMesh,
  Osm3dCompositeShader,      { TCompositeShader / TCompositeShaderClass — «шейдер композита» }
  Osm3dWaterShader,          { TWaterCompositeShader — первый шейдер композита (вода) }
  PBRTextureUnit             { TPBRTextureProcessor.FindTextures — cgbookcase set autodetect }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { 0..255 (uint8 per-vertex would fit; we currently use ~32 entries).
    MaterialId 0 is the "no texture" sentinel — the shader skips the
    atlas sample and uses the flat fallback colour. }
  TGroundMaterialId = Integer;

const
  { Slot 0 has two names: GROUND_MAT_NONE is the "skip this kind"
    sentinel in the lookup tables; GROUND_MAT_TERRAIN tags the
    heightmap terrain mesh (grass diffuse, UV 25 m, ZIndex 0). }
  GROUND_MAT_NONE          = 0;
  GROUND_MAT_TERRAIN       = 0;

  { Landuse slots 1..22. }
  GROUND_MAT_GRASS         = 1;
  GROUND_MAT_FOREST_FLOOR  = 2;
  GROUND_MAT_SAND          = 3;
  GROUND_MAT_SOIL          = 4;
  GROUND_MAT_FARMLAND0     = 5;
  GROUND_MAT_FARMLAND1     = 6;
  GROUND_MAT_FARMLAND2     = 7;
  GROUND_MAT_MANIC_GRASS   = 8;
  GROUND_MAT_GARDEN        = 9;
  GROUND_MAT_ROCK          = 10;
  GROUND_MAT_GRAVEL        = 11;
  GROUND_MAT_PAVEMENT      = 12;
  GROUND_MAT_ASPHALT       = 13;
  GROUND_MAT_COBBLESTONE   = 14;
  GROUND_MAT_PITCH_GENERIC = 15;
  GROUND_MAT_PITCH_FOOT    = 16;
  GROUND_MAT_PITCH_BASKET  = 17;
  GROUND_MAT_PITCH_TENNIS  = 18;
  GROUND_MAT_HELIPAD       = 19;
  GROUND_MAT_WATER         = 20;
  GROUND_MAT_CONSTRUCTION  = 21;
  GROUND_MAT_SANDY_SOIL    = 22;   { streets-gl ShrubberySoil — sandy/dry around shrubs }
  GROUND_MAT_ROAD_SAND     = 23;   { streets-gl SandRoadway — sand_road with alpha edges }

  { Asphalt block 24..30 — contiguous so the shader's "matId >= 24"
    fast-path recognises any road material.
    Unpaved block 31 — dirt + sand paths, 1.7× wider than nominal
    (streets-gl widthScale trick) with alpha-edged textures. }
  GROUND_MAT_ROAD_MAJOR    = 24;
  GROUND_MAT_ROAD_SECOND   = 25;
  GROUND_MAT_ROAD_MINOR    = 26;
  GROUND_MAT_ROAD_SERVICE  = 27;
  GROUND_MAT_ROAD_FOOTWAY  = 28;
  GROUND_MAT_ROAD_CYCLEWAY = 29;
  GROUND_MAT_ROAD_RAILWAY  = 30;
  GROUND_MAT_ROAD_DIRT     = 31;

  GROUND_MAT_COUNT         = 32;

  { Shader uses fract() U tiling for landuse, clamp() U tiling for road
    (U spans [0,1] across road width). }
  GROUND_MAT_ROAD_FIRST    = GROUND_MAT_ROAD_MAJOR;

  { Atlas cell apron (gutter), px/side. Each cell's texture fills the interior
    [G..TilePixels-G); the G-px ring is filled with the cell's OWN wrapped content so mip averaging
    at the boundary stays seamless instead of bleeding the neighbour cell. The shader samples only
    the interior via u_ground_cell_inset (= G/TilePixels), which MUST match this gutter. Alias of the
    atlas-base constant. }
  GROUND_CELL_GUTTER       = ATLAS_CELL_GUTTER;

  { Procedural species IDs keep the previous material mixtures. Shared grass editor atlases: 0 meadow, 1 broadleaf, 2 dry, 3 blue flowers,
    4 lawn, 5 tall dry grass, 6 short grass, 7 pink flowers. }
  GRASS_KIND_COUNT = 8;

type
  { Species and tuft density per square metre. Each GPU tuft produces its
    own blades; Frequency is independent of the geometry LOD. }
  TGrassKind = record
    Kind: Integer;
    Frequency: Single;
  end;

  { Хэш-рандомизация выборки текстуры в FS — прячет видимую периодичность
    тайлинга. Поверхность делится на блоки BlockTiles×BlockTiles тайлов
    (тайл = один повтор UVScale). Для каждого блока по ХЭШУ его индекса
    берётся ПОСТОЯННЫЙ на весь блок сдвиг+поворот UV (не пошумовой
    пиксельный рандом — двигается блок целиком). BlockTiles<=0 = выкл.
    Только landuse/terrain (дороги пропускаются: их UV ориентированный).
    На запечённый атлас НЕ влияет — это только трансформация сэмплинга. }
  TGroundTexRandom = record
    BlockTiles: Single;   { размер блока в МИРОВЫХ единицах (метры): сетка привязана
                          к vGroundObjPos.xz, не к UV. <=0 = выкл }
    Shift:      Single;   { амплитуда случайного сдвига UV, в долях тайла (0..~1) }
    Rotate:     Single;   { амплитуда случайного поворота, радианы (макс |угол|) }
  end;

  TGroundMaterialDesc = record
    Name:         string;
    TexturePath:  string;       { '' = fall back to FallbackColor }
    NormalPath:   string;       { '' = neutral (128,128,255) cell }
    MaskPath:     string;       { '' = no mask. When set, the PNG's R channel
                                  is baked into the mask atlas as per-texel
                                  roughness (G/B unused in these assets).
                                  Maskless cells are solid-filled with the
                                  constant Roughness below, so the shader can
                                  always read roughness from the mask atlas. }
    UVScale:      Single;       { metres per atlas-tile repeat }
    FallbackColor: TVector3;
    { Multiplicative tint baked into this material's DIFFUSE cell at build time; (1,1,1) =
      unchanged. Lets two materials share one diffuse PNG at different brightness (e.g. landuse grass
      darker than base terrain). Diffuse only — the normal atlas is never tinted. }
    BlendColor:   TVector3;
    { PBR LUTs. Roughness=1 perfectly diffuse, 0 mirror. Metallic=1 metal. }
    Roughness:    Single;
    Metallic:     Single;
    { Layer order — mirror of streets-gl ZIndexMap
      (Tile3DProjectedGeometry.ts). Vertex Y is biased by
      ZIndex×Z_BIAS_PER_LEVEL (default 2 mm) inside the composite shape
      so higher-zIndex sits on top — fixes z-fighting between pitches
      and the grass they're inside, between asphalt areas and parking, etc. }
    ZIndex:       Integer;
    { Optional cgbookcase-style PBR set folder, relative to SURFACES_TEX_DIR
      (e.g. 'FourLaneRoadWet02_MR_4K'). When non-empty, the three Build*Image
      passes auto-detect BaseColor / Normal(DirectX) / Roughness / Height / AO
      in that folder via TPBRTextureProcessor.FindTextures and OVERRIDE
      TexturePath/NormalPath/MaskPath. Channels are normalised into the fixed
      atlas layout at bake time: Normal flipped DirectX->OpenGL, Height packed
      into normal.alpha, Roughness->mask.R, Metallic(const)->mask.G,
      AO->mask.B. '' = classic 3-map path (TexturePath/NormalPath/MaskPath). }
    SetFolder:     string;
    { Анимированный «шейдер композита» для этого материала
      (Osm3dCompositeShader). nil = статичная поверхность: материал
      запекается в общий ground-композит и рисуется его обычным выводом.
      Иначе материал ВЫНИМАЕТСЯ в отдельный shape и рисуется эффектом этого
      класса (как вода); класс задаёт и вертикальный подъём вынутого меша
      (MeshLift). Внимание: при инициализации этого поля в GROUND_MATERIALS
      строка ОБЯЗАНА перечислить и все предыдущие поля (SetFolder) —
      FPC требует инициализировать все поля до последнего
      заданного. }
    ShaderClass: TCompositeShaderClass;
    { Виды травы для процедурной шейдерной травы (Osm3dRenderGrass). Пусто =
      трава на этом материале не сажается. Несколько видов с разной частотой:
      травинки распределяются по ячейкам атласа пропорционально Frequency, а
      сумма Frequency задаёт плотность (травинок/м^2) травы на материале.
      ВНИМАНИЕ (FPC): чтобы задать это поле в GROUND_MATERIALS, строка обязана
      перечислить и все предыдущие поля — включая SetFolder/ShaderClass. }
    Grasses: array of TGrassKind;
    { Хэш-рандомизация выборки текстуры (см. TGroundTexRandom). Трейлинг-поле:
      строки, где оно не задано, получают нули => BlockTiles=0 => выключено.
      Чтобы задать его в GROUND_MATERIALS, строка обязана перечислить и все
      предыдущие поля (SetFolder/ShaderClass/Grasses) — требование FPC. }
    TexRandom: TGroundTexRandom;
  end;

const
  { ZIndex mirrors streets-gl Tile3DProjectedGeometry.ZIndexMap
    (Water=0, Grass=1, Sand=2, Rock=3, ManicuredGrass=4, Garden=5,
     Construction=6, Farmland=7, Waterway=8, Pitch=9, ShrubberySoil=10,
     Railway=11, RailwayOverlay=12, DirtRoadway=13, SandRoadway=14,
     RoadwayArea=15, Footway=16, AsphaltFootway=17, FootwayArea=18,
     Cycleway=19, AsphaltRoadway=20, ConcreteRoadway=21, WoodRoadway=22,
     CobblestoneRoadway=23, AsphaltArea=24, ConcreteArea=25,
     CobblestoneArea=26, Runway=27, Rail=28, Helipad=29). }
  {$WARN 3177 OFF}  { у большинства строк ShaderClass намеренно оставлен по умолчанию (nil) }
  GROUND_MATERIALS: array[0..GROUND_MAT_COUNT - 1] of TGroundMaterialDesc = (
  { 0 terrain: low natural cover with scattered tall herbs }
    (Name:'terrain'; TexturePath:'procedural-grass/short-top.png';
      NormalPath:'';MaskPath:'';UVScale:4;FallbackColor:(X:0.30;Y:0.45;Z:0.20);
      BlendColor:(X:1;Y:1;Z:1);Roughness:0.97;Metallic:0;ZIndex:0;
      SetFolder:'';ShaderClass:nil;Grasses:((Kind:6;Frequency:1.0))),
    { 1 meadow } (Name:'grass';TexturePath:'procedural-grass/meadow-top.png';
      NormalPath:'';MaskPath:'';UVScale:4;FallbackColor:(X:0.30;Y:0.45;Z:0.20);
      BlendColor:(X:1;Y:1;Z:1);Roughness:0.97;Metallic:0;ZIndex:1;
      SetFolder:'';ShaderClass:nil;Grasses:((Kind:0;Frequency:1.0))),
    { 2 woodland and scrub undergrowth }
                         (Name:'forest_floor'; TexturePath:'procedural-grass/broadleaf-top.png';
                          NormalPath:''; MaskPath:'';
                          UVScale:4; FallbackColor:(X:0.25; Y:0.38; Z:0.18);
                          BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.98; Metallic:0.0; ZIndex:10;
                          SetFolder:''; ShaderClass:nil;
                          Grasses:((Kind:1;Frequency:1.0))),
    { 3  sand           } (Name:'sand';            TexturePath:'sand_diffuse.png';
                            NormalPath:'sand_normal.png';
                            MaskPath:'sand_mask.png';
                            UVScale:12; FallbackColor:(X:0.85; Y:0.80; Z:0.60);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.98; Metallic:0.0; ZIndex: 2),
    { 4  soil           } (Name:'soil';            TexturePath:'soil_diffuse.png';
                            NormalPath:'soil_normal.png';
                            MaskPath:'soil_mask.png';
                            UVScale:25; FallbackColor:(X:0.45; Y:0.32; Z:0.22);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.97; Metallic:0.0; ZIndex: 6;
                            SetFolder:''; ShaderClass:nil; Grasses:nil;
                            TexRandom:(BlockTiles:4.0; Shift:0.5; Rotate:0.5)),
    { 5  farmland0      } (Name:'farmland0';       TexturePath:'farmland0_diffuse.png';
                            NormalPath:'farmland0_normal.png';
                            MaskPath:'farmland_mask.png';
                            UVScale:50; FallbackColor:(X:0.65; Y:0.58; Z:0.35);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.96; Metallic:0.0; ZIndex: 7),
    { 6  farmland1      } (Name:'farmland1';       TexturePath:'farmland1_diffuse.png';
                            NormalPath:'farmland1_normal.png';
                            MaskPath:'farmland_mask.png';
                            UVScale:50; FallbackColor:(X:0.60; Y:0.50; Z:0.30);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.96; Metallic:0.0; ZIndex: 7),
    { 7  farmland2      } (Name:'farmland2';       TexturePath:'farmland2_diffuse.png';
                            NormalPath:'farmland2_normal.png';
                            MaskPath:'farmland_mask.png';
                            UVScale:50; FallbackColor:(X:0.55; Y:0.45; Z:0.25);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.96; Metallic:0.0; ZIndex: 7),
    { 8  manicured grass} (Name:'manic_grass';     TexturePath:'procedural-grass/lawn-top.png';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:4; FallbackColor:(X:0.45; Y:0.65; Z:0.35);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.97; Metallic:0.0; ZIndex: 4;
                            SetFolder:''; ShaderClass:nil;
                            Grasses:((Kind:4;Frequency:1.0))),
    { 9  garden         } (Name:'garden';          TexturePath:'procedural-grass/pink-flowers-top.png';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:4; FallbackColor:(X:0.40; Y:0.60; Z:0.30);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.97; Metallic:0.0; ZIndex: 5;
                            SetFolder:''; ShaderClass:nil;
                            Grasses:((Kind:7;Frequency:1.0))),
    {10  rock           } (Name:'rock';            TexturePath:'rock_diffuse.png';
                            NormalPath:'rock_normal.png';
                            MaskPath:'rock_mask.png';
                            UVScale:32; FallbackColor:(X:0.55; Y:0.52; Z:0.48);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.85; Metallic:0.0; ZIndex: 3),
    {11  gravel         } (Name:'gravel';          TexturePath:'gravel_diffuse.png';
                            NormalPath:'gravel_normal.png';
                            MaskPath:'gravel_mask.png';
                            UVScale:8;  FallbackColor:(X:0.60; Y:0.58; Z:0.55);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.90; Metallic:0.0; ZIndex: 15),
    {12  pavement_area  } (Name:'pavement_area';   TexturePath:'pavement_diffuse.png';
                            NormalPath:'pavement_normal.png';
                            MaskPath:'pavement_mask.png';
                            UVScale:10; FallbackColor:(X:0.70; Y:0.70; Z:0.70);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.88; Metallic:0.0; ZIndex: 18),
    {13  asphalt_area   } (Name:'asphalt_area';    TexturePath:'';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:20; FallbackColor:(X:0.25; Y:0.25; Z:0.25);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.85; Metallic:0.0; ZIndex: 24),
    {14  cobblestone    } (Name:'cobblestone';     TexturePath:'cobblestone_diffuse.png';
                            NormalPath:'cobblestone_normal.png';
                            MaskPath:'';
                            UVScale:6;  FallbackColor:(X:0.50; Y:0.48; Z:0.45);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.87; Metallic:0.0; ZIndex: 26),
    {15  pitch_generic  } (Name:'pitch_generic';   TexturePath:'pitch_generic_diffuse.png';
                            NormalPath:'pitch_generic_normal.png';
                            MaskPath:'';
                            UVScale:30; FallbackColor:(X:0.55; Y:0.50; Z:0.40);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.92; Metallic:0.0; ZIndex: 9;
                            SetFolder:''; ShaderClass:nil;
                            Grasses:((Kind:6;Frequency:1.0))),
    {16  pitch_football } (Name:'pitch_football';  TexturePath:'football_pitch_diffuse.png';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:1;  FallbackColor:(X:0.30; Y:0.55; Z:0.30);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.95; Metallic:0.0; ZIndex: 9;
                            SetFolder:''; ShaderClass:nil;
                            Grasses:((Kind:6;Frequency:1.0))),
    {17  pitch_basket   } (Name:'pitch_basket';    TexturePath:'basketball_pitch_diffuse.png';
                            NormalPath:'basketball_pitch_normal.png';
                            MaskPath:'';
                            UVScale:1;  FallbackColor:(X:0.70; Y:0.50; Z:0.30);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.90; Metallic:0.0; ZIndex: 9),
    {18  pitch_tennis   } (Name:'pitch_tennis';    TexturePath:'tennis_pitch_diffuse.png';
                            NormalPath:'tennis_pitch_normal.png';
                            MaskPath:'';
                            UVScale:1;  FallbackColor:(X:0.40; Y:0.60; Z:0.40);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.92; Metallic:0.0; ZIndex: 9),
    {19  helipad        } (Name:'helipad';         TexturePath:'helipad_diffuse.png';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:1;  FallbackColor:(X:0.40; Y:0.40; Z:0.40);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.75; Metallic:0.1; ZIndex: 29),
    {20  water          } (Name:'water';           TexturePath:'';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:1;  FallbackColor:(X:0.15; Y:0.30; Z:0.45);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.05; Metallic:0.0; ZIndex: 8;
                            SetFolder:'';
                            ShaderClass: TWaterCompositeShader),
    {21  construction   } (Name:'construction';    TexturePath:'soil_diffuse.png';
                            NormalPath:'soil_normal.png';
                            MaskPath:'soil_mask.png';
                            UVScale:25; FallbackColor:(X:0.55; Y:0.50; Z:0.45);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.97; Metallic:0.0; ZIndex: 6),
    {22  sandy_soil     } (Name:'sandy_soil';      TexturePath:'sandy_soil_diffuse.png';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:15; FallbackColor:(X:0.62; Y:0.55; Z:0.38);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.95; Metallic:0.0; ZIndex: 10),
    {23  road sand      } (Name:'road_sand';       TexturePath:'sand_road_diffuse.png';
                            NormalPath:'sand_road_normal.png';
                            MaskPath:'sand_road_mask.png';
                            UVScale:4;  FallbackColor:(X:0.85; Y:0.75; Z:0.55);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.97; Metallic:0.0; ZIndex: 14),

    {24  road major     } (Name:'road_major';      TexturePath:'';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:8;  FallbackColor:(X:0.20; Y:0.20; Z:0.22);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.78; Metallic:0.0; ZIndex: 20;
                            SetFolder:''),
    {25  road secondary } (Name:'road_secondary';  TexturePath:'';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:8;  FallbackColor:(X:0.22; Y:0.22; Z:0.24);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.80; Metallic:0.0; ZIndex: 20;
                            SetFolder:''),
    {26  road minor     } (Name:'road_minor';      TexturePath:'';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:1;  FallbackColor:(X:0.25; Y:0.25; Z:0.27);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.83; Metallic:0.0; ZIndex: 20;
                            SetFolder:''),
    {27  road service   } (Name:'road_service';    TexturePath:'';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:1;  FallbackColor:(X:0.28; Y:0.28; Z:0.30);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.85; Metallic:0.0; ZIndex: 20;
                            SetFolder:''),
    {28  road footway   } (Name:'road_footway';    TexturePath:'pavement_diffuse.png';
                            NormalPath:'pavement_normal.png';
                            MaskPath:'pavement_mask.png';
                            UVScale:4;  FallbackColor:(X:0.65; Y:0.65; Z:0.65);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.88; Metallic:0.0; ZIndex: 17; SetFolder:''),
    {29  road cycleway  } (Name:'road_cycleway';   TexturePath:'cycleway_diffuse.png';
                            NormalPath:'';
                            MaskPath:'';
                            UVScale:4;  FallbackColor:(X:0.30; Y:0.30; Z:0.40);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.84; Metallic:0.0; ZIndex: 19),
    {30  road railway   } (Name:'road_railway';    TexturePath:'railway_diffuse.png';
                            NormalPath:'railway_normal.png';
                            MaskPath:'railway_mask.png';
                            UVScale:4;  FallbackColor:(X:0.30; Y:0.25; Z:0.20);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.65; Metallic:0.5; ZIndex: 11),
    {31  road dirt      } (Name:'road_dirt';       TexturePath:'dirt_road_diffuse.png';
                            NormalPath:'dirt_road_normal.png';
                            MaskPath:'dirt_road_mask.png';
                            UVScale:4;  FallbackColor:(X:0.45; Y:0.35; Z:0.25);
                            BlendColor:(X:1.0; Y:1.0; Z:1.0); Roughness:0.95; Metallic:0.0; ZIndex: 13)
  );
  {$WARN 3177 ON}

  { TLanduseKind → MaterialId. Mirrors the AddSurfaceShape calls in
    Osm3dSceneAssembler.Assemble. }
  GROUND_MAT_FOR_LANDUSE: array[TLanduseKind] of TGroundMaterialId = (
    { lkNone            } GROUND_MAT_NONE,
    { lkForest          } GROUND_MAT_FOREST_FLOOR,
    { lkGrass           } GROUND_MAT_GRASS,
    { lkWater           } GROUND_MAT_WATER,
    { lkSand            } GROUND_MAT_SAND,
    { lkParking         } GROUND_MAT_ASPHALT,
    { lkConstruction    } GROUND_MAT_CONSTRUCTION,
    { lkFarmland0       } GROUND_MAT_FARMLAND0,
    { lkFarmland1       } GROUND_MAT_FARMLAND1,
    { lkFarmland2       } GROUND_MAT_FARMLAND2,
    { lkIndustrial      } GROUND_MAT_GRAVEL,
    { lkCemetery        } GROUND_MAT_MANIC_GRASS,
    { lkScrub           } GROUND_MAT_FOREST_FLOOR,
    { lkManicuredGrass  } GROUND_MAT_MANIC_GRASS,
    { lkGarden          } GROUND_MAT_GARDEN,
    { lkRock            } GROUND_MAT_ROCK,
    { lkGravel          } GROUND_MAT_GRAVEL,
    { lkPavementArea    } GROUND_MAT_PAVEMENT,
    { lkAsphaltArea     } GROUND_MAT_ASPHALT,
    { lkCobblestone     } GROUND_MAT_COBBLESTONE,
    { lkPitchGeneric    } GROUND_MAT_PITCH_GENERIC,
    { lkPitchFootball   } GROUND_MAT_PITCH_FOOT,
    { lkPitchBasketball } GROUND_MAT_PITCH_BASKET,
    { lkPitchTennis     } GROUND_MAT_PITCH_TENNIS,
    { lkHelipad         } GROUND_MAT_HELIPAD
  );

  { TRoadKind → MaterialId. Both rkDirtPath and rkSandPath use the dirt
    atlas slot for now — sand_road slot exists for future split. }
  GROUND_MAT_FOR_ROAD: array[TRoadKind] of TGroundMaterialId = (
    { rkNone      } GROUND_MAT_NONE,
    { rkMajor     } GROUND_MAT_ROAD_MAJOR,
    { rkSecondary } GROUND_MAT_ROAD_SECOND,
    { rkMinor     } GROUND_MAT_ROAD_MINOR,
    { rkService   } GROUND_MAT_ROAD_SERVICE,
    { rkFootway   } GROUND_MAT_ROAD_FOOTWAY,
    { rkCycleway  } GROUND_MAT_ROAD_CYCLEWAY,
    { rkRailway   } GROUND_MAT_ROAD_RAILWAY,
    { rkDirtPath  } GROUND_MAT_ROAD_DIRT,
    { rkSandPath  } GROUND_MAT_ROAD_SAND
  );

type
  { Atlas image is GridCols × TilePixels wide and GridRows × TilePixels
    tall. Material N → cell (col = N mod GridCols, row = N div GridCols).
    Shader receives GridCols/GridRows as uniforms.
    Псевдоним общего layout-записи базы атласов — состав полей прежний. }
  TGroundAtlasLayout = TAtlasLayout;

  { Texture node uses RepeatS/T = False — the shader tiles via fract(uv) within one cell.
    Subclass of TCompositeAtlasBase (cells/gutter/nodes/SaveToCache live in the base). Ground
    specifics here: UVScale/Roughness/Metallic/ZIndex LUTs from GROUND_MATERIALS, BlendColor baked
    into the diffuse cell (TintCellDiffuseRGB), and normal/mask auto-built before cache write. }
  TGroundAtlas = class(TCompositeAtlasBase)
  private
    FUVScales:   array[0..GROUND_MAT_COUNT - 1] of Single;
    FFillColors: array[0..GROUND_MAT_COUNT - 1] of TVector3;
    FRoughness:  array[0..GROUND_MAT_COUNT - 1] of Single;
    FMetallic:   array[0..GROUND_MAT_COUNT - 1] of Single;
    FZIndex:     array[0..GROUND_MAT_COUNT - 1] of Integer;
    FTexRandom:  array[0..GROUND_MAT_COUNT - 1] of TVector3;   { x=block y=shift z=rot }

    procedure FillCellSolid(MatId: TGroundMaterialId; const Color: TVector3);

    { Neutral tangent-space normal (128,128,255) → (0,0,1). }
    procedure FillNormalCellNeutral(MatId: TGroundMaterialId);

    { Multiply the RGB of one DIFFUSE atlas cell by C in place (alpha kept).
      No-op when C is (1,1,1). Diffuse atlas only — never the normal atlas. }
    procedure TintCellDiffuseRGB(MatId: TGroundMaterialId; const C: TVector3);

    { cgbookcase-set channel combiners (in-memory, no temp PNG). LoadSetRGBA: load as RGBA (nil if
      missing). BuildNormalHeightImage: flip DirectX->OpenGL green, pack Height into alpha (1.0 if
      none); nil if normal missing. BuildMaskSetImage: R=Roughness, G=const metallic, B=AO (1.0 if
      none), A=255; nil if both roughness and AO missing. Callers own and free the result. }
    function LoadSetRGBA(const APath: string): TRGBAlphaImage;
    { Flatten the same overhead bake used by the distant grass renderer onto
      its dark grass background in linear color. Ground must stay opaque. }
    function FillGrassTopCell(MatId: Integer; const APath: string): Boolean;
    { Return a NEW image rotated 90 deg clockwise (dims swapped); frees Src.
      On failure returns Src unchanged. }
    function Rotated90CW(Src: TRGBAlphaImage): TRGBAlphaImage;
    function BuildNormalHeightImage(const ANormalPath, AHeightPath: string): TRGBAlphaImage;
    function BuildMaskSetImage(const ARoughPath, AAOPath: string;
      AMetalByte: Byte): TRGBAlphaImage;
    { Dump a cgbookcase set's FindTextures resolution to the log: folder path,
      whether the folder exists, and each map path with file-exists status.
      Reveals naming/path mismatches and which maps (Height/AO) are absent. }
    procedure LogSetReport(AMatId: Integer; const AMatName, ASetFolder: string;
      const ASet: TPBRTextureSet; LogProc: TLogProc);
  protected
    function LogPrefix: string; override;
    function CacheFileName(Ch: TAtlasChannel): string; override;
    { Ground строит атлас сам (не через MaterialCount/MaterialInfo), поэтому
      и сигнатуру кэша считает по GROUND_MATERIALS. }
    function BuildSignature: string; override;
  public
    constructor Create(const ALayout: TGroundAtlasLayout); reintroduce;

    procedure BuildImage(LogProc: TLogProc = nil); override;
    procedure BuildNormalImage(LogProc: TLogProc = nil); override;
    procedure BuildMaskImage(LogProc: TLogProc = nil); override;

    { Write the built diffuse/normal/mask images to PNGs in ACacheDir, remember their file:// URLs,
      then FREE the in-memory images. Call after BuildImage; missing normal/mask channels are
      auto-built first. The PNGs become the source of truth (CGE's URL texture cache dedups nodes
      built from them) so compositing is amortised and ~64 MB RAM is reclaimed. Returns False on save
      failure (URLs stay empty, in-memory images kept, so the CreateTextureNode fallback still works). }
    function SaveToCache(const ACacheDir: string;
      LogProc: TLogProc = nil): Boolean; override;

    function UVScale(MatId: TGroundMaterialId): Single; inline;
    function FallbackColor(MatId: TGroundMaterialId): TVector3; inline;
    function Roughness(MatId: TGroundMaterialId): Single; inline;
    function Metallic(MatId: TGroundMaterialId): Single; inline;
    function ZIndex(MatId: TGroundMaterialId): Integer; inline;
    function TexRandom(MatId: TGroundMaterialId): TVector3; inline;
  end;

{ 8 cols × 4 rows × 512 px = 4096×2048 atlas. 8 cols matches
  GROUND_MAT_COUNT=32 so ids land predictably (row 0 base landuse,
  row 1 farmland/pavement, row 2 pitches/extras, row 3 roads). }
function DefaultGroundAtlasLayout: TGroundAtlasLayout;

type
  TMaterialIdArray   = array of TGroundMaterialId;

  { Shared (position+normal) vertex pool with INEXACT (proximity) welding
    via a spatial hash grid. Add() returns the index of an existing entry
    within tolerance, else appends a new one. Position and normal are
    material-independent, so a road-edge and a ground-edge vertex at the
    same point collapse to ONE pool entry — moving that entry moves both,
    which is what makes road leveling auto-follow with no seam. Plain
    integer arrays only (no generics). }
  TPoolVertex = record
    Position: TVector3;
    Normal:   TVector3;
  end;
  TPoolVertexArray = array of TPoolVertex;

  TVertexPool = class
  private
    FEntries:   TPoolVertexArray;
    FCount:     Integer;
    FPosEpsSq:  Single;
    FPosEps:    Single;          { weld radius (cell is a multiple of this) }
    FNrmMinDot: Single;
    FInvCell:   Single;          { 1/cell; cell = PosEps * POOL_CELL_MULT (>= eps),
                                   so the eps-box usually lands in one cell and the
                                   neighbour search shrinks from 27 to ~1-3 cells }
    { int-путь: точная карта решётки key=(latX<<32|latZ) -> индекс пула.
      Позиции int-карва канонические (кратные 1/64 м, Y=0 до drape) —
      целочисленный probe вместо eps-бокса с дистанциями. Ленивая
      инициализация первым AddLat; обычный Add продолжает работать. }
    FLatHead:   array of Integer;
    FLatNext:   array of Integer;
    FLatKey:    array of Int64;
    FLatMask:   Integer;
    FLatCount:  Integer;         { only AddLat entries, not ordinary Add vertices }
    FMask:      Integer;         { FBuckets-1, FBuckets — power of two }
    FHashHead:  array of Integer;
    FChainNext: array of Integer;
    FSpatialDirty: Boolean;
    function BucketOf(cx, cy, cz: Integer): Integer;
    procedure RebuildSpatialHash(ABuckets: Integer);
    procedure EnsureSpatialHash;
    procedure Rehash;   { double bucket count + re-link when load high }
  public
    constructor Create(APosEps: Single = 1e-3; ANrmMinDot: Single = 0.999;
                       AExpectedCount: Integer = 1 shl 16);
    function Add(const Pos, Nrm: TVector3): Integer;
    function AddLat(const Pos, Nrm: TVector3; AKey: Int64): Integer;
    property Count: Integer read FCount;
    { Direct access to the entry array for hot read loops (node build);
      valid for indices [0..Count-1]. }
    property Entries: TPoolVertexArray read FEntries;
    { Raw bulk-append of Other's entries (no hashing/dedup) — used to concat
      independently-welded sub-pools. Returns the index offset (old Count) to
      add to Other's pool indices. Spatial hashing is rebuilt lazily if a
      later geometry stage calls Add/AddLat after concatenation or leveling. }
    function AbsorbRaw(Other: TVertexPool): Integer;
    function PositionOf(I: Integer): TVector3; inline;
    function NormalOf(I: Integer): TVector3; inline;
    procedure SetPosition(I: Integer; const P: TVector3); inline;  { for leveling }
    procedure SetNormal(I: Integer; const N: TVector3); inline;
  end;

  { A composite vertex: an index into the shared pool plus the
    material-dependent attributes (UV, OsmId). matId rides the parallel
    FMaterialIds. No position/normal here — they live in the pool. }
  TCompositeVertex = record
    PoolIdx: Integer;
    UV:      TVector2;
    OsmId:   Int64;
  end;
  TCompositeVertexArray = array of TCompositeVertex;
  TTriTileKeyArray = array of Int64;

  { Merged pooled mesh + parallel materialId array.
    All 3 vertices of any triangle share the same matId (never mixed
    inside a triangle), so the FS recovers the exact int via
    floor(materialId + 0.5). Position/normal are shared through FPool;
    use the accessors (PositionOf/NormalOf) — there is no inline vertex. }
  TGroundCompositeMesh = class
  private
    FPool:        TVertexPool;            { shared (position, normal) }
    FVerts:       TCompositeVertexArray;  { (PoolIdx, UV, OsmId) }
    FVertCount:   Integer;
    FMaterialIds: TMaterialIdArray;       { parallel to FVerts }
    FIndices:     TMeshIndexArray;        { -> FVerts }
    FIndexCount:  Integer;
    FTriTileKeys: TTriTileKeyArray;        { per-triangle packed tile key (TX<<32|TY) }
  public
    { ANrmMinDot controls vertex welding: -1.0 = position-only (default;
      ground height-field — coincident road/terrain verts share one entry).
      Pass a value near 1.0 (e.g. 0.999) for hard-surface meshes like
      buildings so coincident verts with DIFFERENT normals (perpendicular
      walls at a corner, wall/roof at the eaves) stay separate and keep
      their hard edges. }
    constructor Create(const AName: string = 'ground_composite';
                       ANrmMinDot: Single = -1.0);
    destructor Destroy; override;

    { Pool + per-composite-vertex streams. After Finalize the arrays are
      trimmed to exact length, so consumers iterate [0..VertexCount-1] /
      [0..TriangleCount*3-1]. }
    property Pool:        TVertexPool          read FPool;
    { точная int-склейка пула после конката параллельных полос weld:
      дубли позиций решётки (вершины на стыках полос, попавшие в оба
      пер-полосных пула) сводятся к первому вхождению переписыванием
      PoolIdx у композитных вершин. Осиротевшие записи пула остаются
      (безвредны: далее индексируются только живые). O(pool + verts). }
    procedure WeldPoolExactLat;
    property Verts:       TCompositeVertexArray read FVerts;
    property MaterialIds: TMaterialIdArray      read FMaterialIds;
    property Indices:     TMeshIndexArray       read FIndices;
    { Per-triangle tile key (TX high 32, TY low), parallel to the triangles.
      Filled by the carve via the builder's Append; preserved by SetTriangle
      (in-place re-fan) and inherited by the T-junction AppendTriangle pieces.
      -1 = untagged. The scene tiler bins by this — no re-projection. }
    property TriTileKeys: TTriTileKeyArray       read FTriTileKeys;
    function TriTileKeyOf(ATri: Integer): Int64; inline;

    function VertexCount:   Integer; inline;
    function TriangleCount: Integer; inline;

    { Per-composite-vertex accessors (resolve position/normal via the pool). }
    function PositionOf(I: Integer): TVector3; inline;
    function NormalOf(I: Integer): TVector3; inline;
    function UVOf(I: Integer): TVector2; inline;
    function OsmIdOf(I: Integer): Int64; inline;
    function MatIdOf(I: Integer): TGroundMaterialId; inline;

    { Low-level append for TSceneTiler when slicing into spatial tiles.
      AppendVertex pools (pos,normal) then appends a composite vertex.
      Sequence: ReserveForSlice -> AppendVertex/AppendTriangle -> TrimArrays. }
    procedure ReserveForSlice(AVertCount, ATriCount: Integer);
    function  AddCompVert(APoolIdx: Integer; const AUV: TVector2;
                AOsmId: Int64; AMatId: TGroundMaterialId): Integer;
    function  AppendVertex(const V: TMeshVertex;
                AMatId: TGroundMaterialId): Integer;
    procedure AppendTriangle(I0, I1, I2: Integer; ATileKey: Int64 = -1); inline;
    { Удалить треугольники по маске (False = выкинуть): уплотняет индексы
      и per-triangle ключи; вершины не трогает (осиротевшие безвредны).
      Хирургия порталов туннелей (Osm3dGeomTunnels). }
    procedure KeepTriangles(const AKeep: array of Boolean);
    { Overwrite an existing triangle's three vertex indices (T-junction fix
      re-triangulates a triangle in place, then appends the extra pieces). }
    procedure SetTriangle(ATri, I0, I1, I2: Integer); inline;
    { Fold pool indices together (boundary stitch): every compVert's PoolIdx is
      replaced by ARemap[PoolIdx]. ARemap must be one-level (ARemap[ARemap[i]] =
      ARemap[i]) and must never map the two verts of any triangle to the same
      index (else that triangle degenerates). }
    procedure RemapPoolIndices(const ARemap: array of Integer);

    { Raw concat: append Src's pool entries, composite verts and triangles
      into self with the proper index offsets, WITHOUT re-welding. Used to
      merge per-strip sub-composites built in parallel. Cross-strip coincident
      positions stay unwelded here and are closed later by StitchBoundaryGaps. }
    procedure AppendRawComposite(Src: TGroundCompositeMesh);
    { Empty destination, known totals of the parallel build strips.
      Reserve only raw storage, without a redundant weld hash table. }
    procedure ReserveForRawMerge(AVertCount,ATriCount,APoolCount:Integer);

    procedure TrimArrays;
  end;

  { Builder collects (mesh, matId) and finalises a composite.
    Usage:
      B := TGroundCompositeBuilder.Create;
      B.LogProc := MyLogger;  // optional, per-Append diagnostic
      try
        B.Append(LanduseMesh, GROUND_MAT_GRASS, []);
        B.Append(RoadMajorMesh, GROUND_MAT_ROAD_MAJOR, []);
        Composite := B.Finalize;
      finally
        B.Free;
      end; }
  TGroundCompositeBuilder = class
  private
    FComposite: TGroundCompositeMesh;
    FFinalized: Boolean;
    FLogProc:   TLogProc;

    FAppendedMeshes: Integer;
    FAppendedVerts:  Integer;
    FAppendedTris:   Integer;

    { compVert dedup: merges verts identical in (poolIdx, uv, osmid, matId)
      so within-material coincidence collapses; cross-material verts share a
      pool position but stay separate compVerts (different matId/uv). }
    FVHashHead:  array of Integer;
    FVChainNext: array of Integer;   { parallel to FComposite.FVerts }
    FVMask:      Integer;
    function VertDedup(APoolIdx: Integer; const AUV: TVector2;
               AOsmId: Int64; AMatId: TGroundMaterialId): Integer;
  public
    { ANrmMinDot forwarded to the composite mesh's vertex pool (see
      TGroundCompositeMesh.Create). -1.0 = position-only weld (ground);
      ~0.999 for hard-surface meshes (buildings). }
    constructor Create(const AName: string = 'ground_composite';
                       ANrmMinDot: Single = -1.0);
    destructor Destroy; override;

    { Per-Append diagnostic. Default nil = no per-Append log; the
      Finalize summary is independent (one-shot LogProc parameter). }
    property LogProc: TLogProc read FLogProc write FLogProc;

    { Source is not modified or freed. No-op on nil / empty. }
    { 2-arg: untagged append (buildings/fences — no per-triangle tile key). }
    procedure Append(Source: TMesh; MaterialId: TGroundMaterialId); overload;
    { 3-arg: carve append — ASrcTriKeys[i] is triangle i's packed tile key
      (len must equal Source.TriangleCount, else treated as untagged). }
    procedure Append(Source: TMesh; MaterialId: TGroundMaterialId;
                     const ASrcTriKeys: array of Int64); overload;

    { Strip-filtered append for the parallel weld: welds only the triangles
      whose centroid Z falls in [zLo, zHi), lazily welding just the vertices
      those triangles use. Each strip gets its own builder (own pool), so this
      runs on a worker thread with no shared mutable state. }
    procedure AppendStrip(Source: TMesh; MaterialId: TGroundMaterialId;
                          const ASrcTriKeys: array of Int64;
                          zLo, zHi: Single);
    { int-путь: пул через точную int-карту решётки (AddLat) вместо
      eps-бокса — позиции карва канонические. Остальная механика
      (VertDedup, ключи тайлов) прежняя. }
    procedure AppendStripInt(Source: TMesh;
      MaterialId: TGroundMaterialId; const ASrcTriKeys: array of Int64;
      zLo, zHi: Single);

    { Transfers composite ownership to caller. After this the builder
      is exhausted — further Append raises. ALogProc is one-shot summary,
      independent of the LogProc property. }
    function Finalize(ALogProc: TLogProc = nil): TGroundCompositeMesh;

    property AppendedMeshes: Integer read FAppendedMeshes;
    property AppendedVerts:  Integer read FAppendedVerts;
    property AppendedTris:   Integer read FAppendedTris;
  end;


{ Vertex/fragment effect — port of streets-gl. Тела в implementation:
  генерируются в рантайме, т.к. U_GROUND_MAT_COUNT подставляется из
  константы GROUND_MAT_COUNT через IntToStr (не может остаться const-строкой). }
function GROUND_COMPOSITE_VS: string;
function GROUND_COMPOSITE_FS: string;

const


  { Shadow-mask overlay
 A lightweight SECOND effect layered on the composite appearance (the
 shared ground effect renders the lit material first, untouched). Its
 plug darkens the already-lit colour where the top-down coverage mask
 says shadow — transparent (operates on the real material), single
 (mask is a union), terrain-following (sampled at the fragment XZ). }
  SHADOW_MASK_VS =
    'uniform vec3 gc_ground_origin;' + #10 +
    'varying vec3 vSMPos;' + #10 +
    'void PLUG_vertex_object_space(' + #10 +
    '  const in vec4 vertex_object, const in vec3 normal_object)' + #10 +
    '{' + #10 +
    '    vSMPos = vertex_object.xyz + gc_ground_origin;' + #10 +
    '}' + #10;

  { TREE mask unpack -- injected into SHADOW_MASK_FS at @TREE_UNPACK@ by
    BuildShadowMaskEffect per ShadowMaskBitsTree. Returns the DARKNESS channel;
    the sway-weight channel is baked in the mask and read by the wind pass. }
  TREE_UNPACK_R4x2 =
    '/* R4x2: 1 byte/texel, darkness = low nibble, sway = high nibble. */' + #10 +
    'float gc_unpackMaskTree(ivec2 L) {' + #10 +
    '    int lr = int(gc_shadow_texels);' + #10 +
    '    ivec2 c = clamp(L, ivec2(0), ivec2(lr - 1));' + #10 +
    '    int li = c.y * lr + c.x;' + #10 +
    '    int td = int(gc_shadow_texdim_tree);' + #10 +
    '    ivec2 bc = ivec2(li - (li / td) * td, li / td);' + #10 +
    '    int b = int(texelFetch(gc_shadow_mask_tree, bc, 0).r * 255.0 + 0.5);' + #10 +
    '    int dark = b - (b / 16) * 16;' + #10 +
    '    return float(dark) / 15.0;' + #10 +
    '}' + #10 +
    '/* sway-weight = high nibble */' + #10 +
    'float gc_unpackTreeMoti(ivec2 L) {' + #10 +
    '    int lr = int(gc_shadow_texels);' + #10 +
    '    ivec2 c = clamp(L, ivec2(0), ivec2(lr - 1));' + #10 +
    '    int li = c.y * lr + c.x;' + #10 +
    '    int td = int(gc_shadow_texdim_tree);' + #10 +
    '    ivec2 bc = ivec2(li - (li / td) * td, li / td);' + #10 +
    '    int b = int(texelFetch(gc_shadow_mask_tree, bc, 0).r * 255.0 + 0.5);' + #10 +
    '    return float(b / 16) / 15.0;' + #10 +
    '}';
  TREE_UNPACK_R8x2 =
    '/* R8x2: 2 bytes/texel, darkness byte at 2*li, sway byte at 2*li+1. */' + #10 +
    'float gc_unpackMaskTree(ivec2 L) {' + #10 +
    '    int lr = int(gc_shadow_texels);' + #10 +
    '    ivec2 c = clamp(L, ivec2(0), ivec2(lr - 1));' + #10 +
    '    int li = c.y * lr + c.x;' + #10 +
    '    int td = int(gc_shadow_texdim_tree);' + #10 +
    '    ivec2 bc = ivec2(li - (li / td) * td, li / td);' + #10 +
    '    return texelFetch(gc_shadow_mask_tree, bc, 0).r;' + #10 +
    '}' + #10 +
    '/* sway-weight = byte at 2*li+1 */' + #10 +
    'float gc_unpackTreeMoti(ivec2 L) {' + #10 +
    '    int lr = int(gc_shadow_texels);' + #10 +
    '    ivec2 c = clamp(L, ivec2(0), ivec2(lr - 1));' + #10 +
    '    int li = c.y * lr + c.x;' + #10 +
    '    int td = int(gc_shadow_texdim_tree);' + #10 +
    '    ivec2 bc = ivec2(li - (li / td) * td, li / td);' + #10 +
    '    return texelFetch(gc_shadow_mask_tree, bc, 0).a;' + #10 +
    '}';

  SHADOW_MASK_FS =
    'void gc_setStaticShadow(float coverage);' + #10 +
    'float gc_staticShadowWeight();' + #10 +
    'uniform sampler2D gc_shadow_mask;' + #10 +
    'uniform vec2      gc_shadow_origin;' + #10 +
    'uniform vec2      gc_shadow_size;' + #10 +
    'uniform float     gc_shadow_texels;' + #10 +
    'uniform float     gc_shadow_texdim;' + #10 +
    'uniform sampler2D gc_shadow_mask_tree;' + #10 +
    'uniform float     gc_shadow_texdim_tree;' + #10 +
    'varying vec3      vSMPos;' + #10 +
    { WIND_GLSL functions (windSpeedAt/windBend), uniform-decl lines stripped
      by BuildShadowMaskEffect (the 7 uniforms come from CGE custom fields). }
    '@WIND_FUNCS@' + #10 +
    '/* leaf-flutter noise -- same n2 as the canopy shader */' + #10 +
    'float n2w(vec2 p) { return 0.5*sin(p.x*1.7 + p.y*2.3) + 0.5*sin(p.x*3.1 - p.y*1.3); }' + #10 +
    '/* shadow-wind tunables in world metres (mirror canopy BOIL/LEAN, m-scaled) */' + #10 +
    'const float WIND_SH_BOIL = 0.6;' + #10 +
    'const float WIND_SH_LEAN = 1.5;' + #10 +
    'const float WIND_SH_FREQ = 0.3;' + #10 +
    '/* Unpack one LOGICAL texel of the packed coverage mask. Row-packed:' + #10 +
    '   @N@ texels/byte along X, @BITS@ bits each; @LEVELS@ levels, max @MAXVAL@.' + #10 +
    '   Constants baked at build time (BuildShadowMaskEffect) -> no branches.' + #10 +
    '   texelFetch reads the raw byte (needs a LINEAR R8 mask, not sRGB). */' + #10 +
    'float gc_unpackMask(ivec2 L) {' + #10 +
    '    int lr = int(gc_shadow_texels);' + #10 +
    '    ivec2 c = clamp(L, ivec2(0), ivec2(lr - 1));' + #10 +
    '    int li = c.y * lr + c.x;' + #10 +
    '    int bi = li / @N@;' + #10 +
    '    int sub = li - bi * @N@;' + #10 +
    '    int td = int(gc_shadow_texdim);' + #10 +
    '    ivec2 bc = ivec2(bi - (bi / td) * td, bi / td);' + #10 +
    '    int pmByte = int(texelFetch(gc_shadow_mask, bc, 0).r * 255.0 + 0.5);' + #10 +
    '    int divisor = int(pow(2.0, float(sub * @BITS@)) + 0.5);' + #10 +
    '    int shifted = pmByte / divisor;' + #10 +
    '    int val = shifted - (shifted / @LEVELS@) * @LEVELS@;' + #10 +
    '    return float(val) / @MAXVAL@.0;' + #10 +
    '}' + #10 +
    '@TREE_UNPACK@' + #10 +
    'void PLUG_main_texture_apply(' + #10 +
    '  inout vec4 fragment_color, const in vec3 normal)' + #10 +
    '{' + #10 +
    '    if (gc_staticShadowWeight() <= 0.0) return;' + #10 +
    '    vec2 uv = (vSMPos.xz - gc_shadow_origin) / gc_shadow_size;' + #10 +
    '    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return;' + #10 +
    '    /* TWO masks: buildings (crisp straight AA) + trees (soft rounded AA),' + #10 +
    '       unioned. Each samples its own texture via its own unpack. */' + #10 +
    '    float _ts = max(gc_shadow_texels, 1.0);' + #10 +
    '    /* ---- BUILDINGS: 3x3 Sobel plane fit -> straight edges ---- */' + #10 +
    '    vec2  _t  = uv * _ts;' + #10 +
    '    ivec2 _c  = ivec2(floor(_t));' + #10 +
    '    float _n0 = gc_unpackMask(_c + ivec2(-1,-1));' + #10 +
    '    float _n1 = gc_unpackMask(_c + ivec2( 0,-1));' + #10 +
    '    float _n2 = gc_unpackMask(_c + ivec2( 1,-1));' + #10 +
    '    float _n3 = gc_unpackMask(_c + ivec2(-1, 0));' + #10 +
    '    float _n4 = gc_unpackMask(_c + ivec2( 0, 0));' + #10 +
    '    float _n5 = gc_unpackMask(_c + ivec2( 1, 0));' + #10 +
    '    float _n6 = gc_unpackMask(_c + ivec2(-1, 1));' + #10 +
    '    float _n7 = gc_unpackMask(_c + ivec2( 0, 1));' + #10 +
    '    float _n8 = gc_unpackMask(_c + ivec2( 1, 1));' + #10 +
    '    float _gx = ((_n2 + 2.0*_n5 + _n8) - (_n0 + 2.0*_n3 + _n6)) * 0.125;' + #10 +
    '    float _gy = ((_n6 + 2.0*_n7 + _n8) - (_n0 + 2.0*_n1 + _n2)) * 0.125;' + #10 +
    '    vec2  _o  = _t - (vec2(_c) + 0.5);' + #10 +
    '    float _vp = _n4 + _gx * _o.x + _gy * _o.y;' + #10 +
    '    float _gm  = max(length(vec2(_gx, _gy)), 1e-5);' + #10 +
    '    float _tpp = max(length(fwidth(_t)), 1e-5);' + #10 +
    '    /* soft plane-fit coverage keeps the length gradient (255->102 -> not a solid' + #10 +
    '       block); crisp silhouette via analytic AA on the LOW outer contour (0.12) only,' + #10 +
    '       so the gentle interior fade is preserved, not thresholded. */' + #10 +
    '    float sB = clamp(_vp, 0.0, 1.0) * smoothstep(-0.7, 0.7, ((_vp - 0.12) / _gm) / _tpp);' + #10 +
    '    /* ---- TREES: wind-warped soft coverage (mirrors the canopy UV sway) ---- */' + #10 +
    '    float _moti = clamp(gc_unpackTreeMoti(ivec2(floor(uv * _ts))), 0.0, 1.0);' + #10 +
    '    _moti = sqrt(_moti);   /* medium strength = geometric mean of swayW..1 */' + #10 +
    '    float _resp = windBend(vSMPos.xz);' + #10 +
    '    vec2  _flow = vec2(n2w(vSMPos.xz * WIND_SH_FREQ + vec2( uWindTime*1.7,  uWindTime*1.1)),' + #10 +
    '                       n2w(vSMPos.xz * WIND_SH_FREQ + vec2(-uWindTime*1.3,  uWindTime*1.9)));' + #10 +
    '    /* per-fragment flutter (high-freq -> trees decorrelate, no giant-shadow sync)' + #10 +
    '       + small directional lean. Metres, scaled by resp*sway. */' + #10 +
    '    vec2  _shiftM = (_flow * WIND_SH_BOIL + uWindDir * WIND_SH_LEAN) * (_resp * _moti);' + #10 +
    '    vec2  _wuv = uv + _shiftM / gc_shadow_size;' + #10 +
    '    vec2  _tt = _wuv * _ts - 0.5;' + #10 +
    '    vec2  _fl = floor(_tt);' + #10 +
    '    vec2  _fr = _tt - _fl;' + #10 +
    '    _fr = _fr * _fr * (3.0 - 2.0 * _fr);' + #10 +
    '    ivec2 _tb = ivec2(_fl);' + #10 +
    '    float _r00 = gc_unpackMaskTree(_tb);' + #10 +
    '    float _r10 = gc_unpackMaskTree(_tb + ivec2(1, 0));' + #10 +
    '    float _r01 = gc_unpackMaskTree(_tb + ivec2(0, 1));' + #10 +
    '    float _r11 = gc_unpackMaskTree(_tb + ivec2(1, 1));' + #10 +
    '    float _vt = clamp(mix(mix(_r00, _r10, _fr.x), mix(_r01, _r11, _fr.x), _fr.y), 0.0, 1.0);' + #10 +
    '    /* SOFT coverage direct -> full gradient kept. Darkness now = leaf alpha, so the' + #10 +
    '       interior is itself dappled/gradual (not a flat blob); edge fades via the blur.' + #10 +
    '       Rounded from the bilinear contours. */' + #10 +
    '    float sT = _vt;' + #10 +
    '    /* union of the two shadow contributions */' + #10 +
    '    float s = max(sB, sT);' + #10 +
    '    if (s <= 0.001) return;' + #10 +
    '    gc_setStaticShadow(s);' + #10 +
    '}' + #10;

{ Общий построитель merged-IFS с тремя кастомными per-vertex атрибутами
  (materialId / UV / Normal), которые читает соответствующий composite-VS.
  Раньше дословно копировался в BuildBuildingIFS и BuildFenceIFS —
  различались только имена UV/Normal-атрибутов и флаг Solid. nil для
  пустого композита. }
function BuildCompositeIFS(Composite: TGroundCompositeMesh;
  const AUVAttrName, ANormalAttrName: string;
  ASolid: Boolean; AKeepStandardUV: Boolean = True): TIndexedFaceSetNode;

{ Пер-вид масштабы UV ландюза из GROUND_MATERIALS через GROUND_MAT_FOR_LANDUSE —
  ЕДИНЫЙ источник истины: тот же UVScale видит терраин-карв (usmPlanar), так
  что виды на одном материале (например terrain и grass на одной текстуре)
  тайлятся одинаково по построению. Слот 0 (GROUND_MAT_NONE) и выход за
  диапазон дают 0 — UV не строится. Замечание: прежняя локальная таблица в
  Osm3dGeomSurface глушила нулём UV у water/industrial/cemetery — теперь и
  они берут материальный масштаб (при шейдерной воде бассейн всё равно
  накрыт анимированной водой). Вытянутые площадки (Stretch) форсируются в 1
  на стороне GeomSurface — инвариант OMBB-развёртки живёт там. }
function LanduseUVScalesFromMaterials: TLanduseUVScales;

implementation

uses Osm3dRtxMaterials, Osm3dRiderShadow, Osm3dRoadMaterial, Osm3dRockMaterial, Math, GrassModel;

{ Vertex effect — port of streets-gl. U_GROUND_MAT_COUNT генерируется
  из константы GROUND_MAT_COUNT (была зашита строкой — расходилась бы
  при смене размера таблицы материалов). }
function GROUND_COMPOSITE_VS: string;
begin
  Result :=
    '#define U_GROUND_MAT_COUNT ' + IntToStr(GROUND_MAT_COUNT) + #10 +
    '' + #10 +
    'attribute vec4 roadCoord, roadStyle;' + #10 +
    'varying vec4 vRoadCoord, vRoadStyle;' + #10 +
    'attribute float materialId;' + #10 +
    { Custom vertex attribute for ground UV. We do NOT use the standard
      castle_MultiTexCoord0 channel here, because CGE does not auto-bind
      it when the appearance carries TUnlitMaterialNode with no texture
      — the per-vertex TexCoord then arrives at the shader as (0,0) for
      every fragment regardless of what TTextureCoordinateNode holds.
      Routing UV through a TFloatVertexAttributeNode (NumComponents=2,
      NameField='groundUV') in BuildIndexedFaceSet sidesteps CGE's
      texcoord generation entirely. }
    'attribute vec2  groundUV;' + #10 +
    { Custom vertex attribute for the per-vertex normal, for the SAME
      reason as groundUV: with TUnlitMaterialNode CGE does no lighting, so
      it does not upload the geometry normal stream — normal_object then
      arrives constant and every fragment gets the same N·L, leaving slopes
      unshaded (flat ground colour). Routing the mesh normal through a
      TFloatVertexAttributeNode (NumComponents=3, NameField='groundNormal')
      in BuildIndexedFaceSet delivers it reliably. }
    'uniform vec3 gc_ground_origin;' + #10 +
    'attribute vec3  groundNormal;' + #10 +
    'uniform vec4 gc_ground_origin_low; /* XYZ: Double-origin residual, W: tile-local placement enabled */' + #10 +
    'vec4 position_eye_to_world_space(vec4 position_eye);' + #10 +
    'vec3 direction_world_to_eye_space(vec3 direction_world);' + #10 +
    '' + #10 +
    'varying float vGroundMaterialId;' + #10 +
    'varying vec2  vGroundUV;' + #10 +
    'varying vec3  vGroundObjPos;' + #10 +
    'varying vec3  vGroundLocalPos;' + #10 +
    'varying vec3  vGroundNormalOS;' + #10 +
    '' + #10 +
    'void PLUG_vertex_object_space(' + #10 +
    '  inout vec4 vertex_object,' + #10 +
    '  const in vec3 normal_object)' + #10 +
    '{' + #10 +
    '    vRoadCoord = roadCoord; vRoadStyle = roadStyle;' + #10 +
    '    vGroundMaterialId = materialId;' + #10 +
    '    vGroundObjPos     = vertex_object.xyz + gc_ground_origin;' + #10 +
    '    vGroundLocalPos   = vertex_object.xyz;' + #10 +
    '    vGroundNormalOS   = groundNormal;' + #10 +
    '    vGroundUV         = groundUV;' + #10 +
    '}' + #10 +
    'void PLUG_vertex_eye_space(inout vec4 vertex_eye, const in vec3 normal_eye)' + #10 +
    '{' + #10 +
    '    if (gc_ground_origin_low.w > 0.5) {' + #10 +
    '        /* Subtract the camera BEFORE rotation: composing Single model/view' + #10 +
    '           matrices at 300 km otherwise opens a different gap at each tile. */' + #10 +
    '        vec3 cameraWorld = position_eye_to_world_space(vec4(0.0,0.0,0.0,1.0)).xyz;' + #10 +
    '        vec3 relative = (gc_ground_origin - cameraWorld) +' + #10 +
    '                        (vGroundLocalPos + gc_ground_origin_low.xyz);' + #10 +
    '        vertex_eye = vec4(direction_world_to_eye_space(relative), 1.0);' + #10 +
    '    }' + #10 +
    '}' + #10;
end;

{ Fragment effect — port of streets-gl shading.frag }
function GROUND_COMPOSITE_FS: string;
begin
  Result :=
    'bool gc_grass_display_active=false; vec3 gc_grass_display;' + #10 +
    StringReplace(RIDER_SHADOW_GLSL,'PLUG_fragment_modify','gc_grass_applyShadow',[rfReplaceAll]) +
    StringReplace(StringReplace(RTX_MATERIAL_GLSL,'rz','gp',[rfReplaceAll]),'gp_capture','rz_ground_capture',[rfReplaceAll]) +
    RoadMaterialSamplingGLSL + ({$I shaders/road_puddles.glsl.inc}) + WaterFilmGLSL + GrassSurfaceGLSL +
    'float gp_mask=0.0;vec3 gp_normal=vec3(0,1,0);vec4 gp_request=vec4(0);' + #10 +
    '#define U_GROUND_MAT_COUNT ' + IntToStr(GROUND_MAT_COUNT) + #10 +
    '#define MAT_TERRAIN        0' + #10 +
    '#define MAT_SANDY_SOIL    22' + #10 +
    '#define MAT_ROAD_SAND     23' + #10 +
    '#define MAT_ROAD_MAJOR    24' + #10 +
    '#define MAT_ROAD_DIRT     31' + #10 +
    '#define PI                3.141592653589793' + #10 +
    '/* Scene exposure applied before Reinhard. The base SUN_INTENSITY=8 +' + #10 +
    '   Reinhard combo under-exposes real-photo ground albedos (grass/asphalt' + #10 +
    '   read as dark midtones), so the composite looked far darker than the' + #10 +
    '   instanced vegetation even though both share the same lighting model.' + #10 +
    '   This is the single brightness knob for ALL ground materials: raise to' + #10 +
    '   brighten grass/roads, lower if highlights clip. ~1.6 dim .. ~2.6 bright. */' + #10 +
    'uniform float u_ground_exposure;        /* was #define 2.0; tune in AttachLUTUniforms */' + #10 +
    '' + #10 +
    'varying float vGroundMaterialId;' + #10 +
    'varying vec2  vGroundUV;' + #10 +
    'varying vec3  vGroundObjPos;' + #10 +
    'varying vec3  vGroundLocalPos;' + #10 +
    'varying vec3  vGroundNormalOS;' + #10 +
    '' + #10 +
    '/* LOD parameters. Values come from Pascal TSFFloat on the effect,' + #10 +
    '   populated from GlobalLODConfig. Distance-based discard + normal-map' + #10 +
    '   cutoff. Terrain (matId=0) and water (matId=20) are NEVER culled —' + #10 +
    '   gaps would show sky underneath. */' + #10 +
    'uniform float u_lod_near_base;' + #10 +
    'uniform float u_lod_height_ref;' + #10 +
    'uniform float u_lod_ground_ref_y;' + #10 +
    '' + #10 +
    '/* From castle-shader:/EyeWorldSpace.glsl, attached via' + #10 +
    '   TEffectNode.SetShaderLibraries. Engine passes the view-inverse' + #10 +
    '   uniforms automatically. */' + #10 +
    'vec4 position_eye_to_world_space(vec4 position_eye);' + #10 +
    '' + #10 +
    '/* Saved in PLUG_fragment_eye_space, used in PLUG_main_texture_apply. */' + #10 +
    'vec3 gLodVertexWorld;' + #10 +
    'vec3 gLodCamWorld;' + #10 +
    'vec3 gLodToCamera;' + #10 +
    '' + #10 +
    'void PLUG_fragment_eye_space(const vec4 vertex_eye, inout vec3 normal_eye)' + #10 +
    '{' + #10 +
    '    gLodVertexWorld = position_eye_to_world_space(vertex_eye).xyz;' + #10 +
    '    gc_riderPosition = gLodVertexWorld;' + #10 +
    '    /* Camera sits at the origin in eye space, so (0,0,0,1) back to' + #10 +
    '       world space yields the camera world position. */' + #10 +
    '    gLodCamWorld = position_eye_to_world_space(vec4(0.0, 0.0, 0.0, 1.0)).xyz;' + #10 +
    '    gLodToCamera = position_eye_to_world_space(vec4(-vertex_eye.xyz,0.0)).xyz;' + #10 +
    '    gc_riderRelativePosition = -gLodToCamera;' + #10 +
    '}' + #10 +
    '' + #10 +
    'uniform sampler2D u_ground_atlas;' + #10 +
    'uniform sampler2D u_ground_normal_atlas;' + #10 +
    'uniform sampler2D u_ground_mask_atlas;' + #10 +
    'uniform int       u_ground_grid_cols;' + #10 +
    'uniform int       u_ground_grid_rows;' + #10 +
    { Cell apron inset (gutter_px / tile_px). The tiled UV is mapped into
      [ins, 1-ins] of each cell so sampling never reaches the outer gutter
      ring (which exists only to keep mip averaging tile-correct at the cell
      border). Must match GROUND_CELL_GUTTER. }
    'uniform float     u_ground_cell_inset;' + #10 +
    'uniform float     u_ground_uv_scale[U_GROUND_MAT_COUNT];' + #10 +
    'uniform vec3      u_ground_fallback_rgb[U_GROUND_MAT_COUNT];' + #10 +
    'uniform float     u_ground_roughness[U_GROUND_MAT_COUNT];' + #10 +
    'uniform float     u_ground_metallic[U_GROUND_MAT_COUNT];' + #10 +
    'uniform vec3      u_ground_rnd[U_GROUND_MAT_COUNT]; /* per-mat: x=block size(world units) y=shift(tile-frac) z=rot(rad); x<=0 off */' + #10 +
    'uniform vec4      gc_ground_grid_origin[U_GROUND_MAT_COUNT]; /* integer cell XY + fractional cell ZW, split on CPU in double precision */' + #10 +
    'uniform vec3 gc_ground_origin;' + #10 +
    'uniform vec4 gc_ground_origin_low;' + #10 +
    'uniform float     u_ground_tint_amount;' + #10 +
    '' + #10 +
    '/* Road-halo uniforms — streets-gl sandy edge along roads. Port of' + #10 +
    '   TerrainUsage + terrain.frag heightblend.' + #10 +
    '   u_road_dist_field   : R-channel grayscale, 1.0 inside road, fading' + #10 +
    '                         to 0 over halo radius beyond.' + #10 +
    '   u_road_field_origin : world XZ of texel (0,0).' + #10 +
    '   u_road_field_size   : world XZ extent the raster covers.' + #10 +
    '   u_road_halo_strength: max heightblend opacity at peak (1.0 = fully' + #10 +
    '                         replace grass with sandy_soil).' + #10 +
    '   u_road_field_present: 0/1 — 0 when no roads (1×1 zero texture). */' + #10 +
    'uniform sampler2D u_road_dist_field;' + #10 +
    'uniform vec2      u_road_field_origin;' + #10 +
    'uniform vec2      u_road_field_size;' + #10 +
    'uniform float     u_road_halo_strength;' + #10 +
    'uniform int       u_road_field_present;' + #10 +
    '' + #10 +
    '/* Sun parameters. Streets-gl reads these from a uniform block built' + #10 +
    '   in the engine; we hard-code noon-with-warm-tint values close to' + #10 +
    '   streets-gl''s "Noon" preset.' + #10 +
    '   SUN_INTENSITY=8: Cook-Torrance + /π division needs roughly 8×' + #10 +
    '   albedo to lift dark asphalt into visible mid-grey. Streets-gl gets' + #10 +
    '   this implicitly via HDR sunColor from atmosphere LUT (typical' + #10 +
    '   noon 5-10 linear) × CSM intensity (≈3) = 15-30 total. Our 8.0 hits' + #10 +
    '   asphalt at sRGB ≈ 0.47 (#777) and grass at sRGB ≈ 0.49 (G channel).' + #10 +
    '   Reinhard tone map before sRGB so bright specular compresses. */' + #10 +
    'const vec3  SUN_COLOR      = vec3(1.000, 0.970, 0.920);' + #10 +
    'const float SUN_INTENSITY  = 8.0;' + #10 +
    'uniform float u_ground_ambient;         /* was const 0.45; flat fill, normal-independent */' + #10 +
    'uniform float u_ground_normal_strength; /* normal-map relief multiplier (1=raw) */' + #10 +
    'uniform float u_ground_spec_boost;      /* specular strength multiplier (1=physical, >1 = wetter/shinier) */' + #10 +
    '/* Direction TOWARD the sun in world space. Default used only when' + #10 +
    '   the application has not set the uniform. */' + #10 +
    'uniform vec3 gc_SunDirToward;' + #10 +
    RockMaterialGLSL +
    '' + #10 +
    '/* gc_ prefix avoids collision with CGE''s built-in LINEARtoSRGB /' + #10 +
    '   SRGBtoLINEAR injected when gamma correction is on. */' + #10 +
    'vec3 gc_SRGBtoLINEAR(vec3 srgbIn) { return pow(srgbIn, vec3(2.2)); }' + #10 +
    'vec3 gc_LINEARtoSRGB(vec3 linIn)  { return pow(linIn, vec3(1.0/2.2)); }' + #10 +
    '/* The same canopy display color for flat ground and rock transitions.' + #10 +
    '   Albedo already includes atlas variation, tint and the road halo.' + #10 +
    '   Footprint is supplied from unconditional derivatives in the caller. */' + #10 +
    'vec3 gcGrassDisplayColor(vec3 albedoLin,vec2 localXZ,float footprint) {' + #10 +
    '    vec3 lit=albedoLin*(vec3(0.55,0.64,0.50)' + #10 +
    '        +vec3(1.0,0.96,0.9)*(2.55*0.68))*0.55;' + #10 +
    '    vec2 phase=mod(mod(gc_ground_origin.xz,256.0)+gc_ground_origin_low.xz,256.0);' + #10 +
    '    return gc_LINEARtoSRGB(lit/(lit+vec3(1.0)))*gcGrassSurface(localXZ+phase,footprint);' + #10 +
    '}' + #10 +
    '' + #10 +
    '/* streets-gl/shading.frag:99 — Fresnel-Schlick. */' + #10 +
    'vec3 specularReflection(vec3 F0, vec3 F90, float VdotH) {' + #10 +
    '    return F0 + (F90 - F0) * pow(clamp(1.0 - VdotH, 0.0, 1.0), 5.0);' + #10 +
    '}' + #10 +
    '' + #10 +
    '/* streets-gl/shading.frag:102 — GGX visibility (Smith G/4NdotLNdotV). */' + #10 +
    'float visibilityOcclusion(float alphaRoughness, float NdotL, float NdotV) {' + #10 +
    '    float alpha2 = alphaRoughness * alphaRoughness;' + #10 +
    '    float GGXV = NdotL * sqrt(NdotV * NdotV * (1.0 - alpha2) + alpha2);' + #10 +
    '    float GGXL = NdotV * sqrt(NdotL * NdotL * (1.0 - alpha2) + alpha2);' + #10 +
    '    float GGX  = GGXV + GGXL;' + #10 +
    '    if (GGX > 0.0) return 0.5 / GGX;' + #10 +
    '    return 0.0;' + #10 +
    '}' + #10 +
    '' + #10 +
    '/* streets-gl/shading.frag:118 — GGX microfacet distribution D. */' + #10 +
    'float microfacetDistribution(float alphaRoughness, float NdotH) {' + #10 +
    '    float alpha2 = alphaRoughness * alphaRoughness;' + #10 +
    '    float f = (NdotH * alpha2 - NdotH) * NdotH + 1.0;' + #10 +
    '    return alpha2 / (PI * f * f);' + #10 +
    '}' + #10 +
    '' + #10 +
    '/* Хэш индекса блока для рандомизации выборки грунта. Без sin (устойчивее' + #10 +
    '   к средним координатам): Dave Hoskins hash13/hash23. Вход — целый bidx. */' + #10 +
    'float gc_hash13(vec2 p) {' + #10 +
    '    vec3 p3 = fract(vec3(p.xyx) * 0.1031);' + #10 +
    '    p3 += dot(p3, p3.yzx + 33.33);' + #10 +
    '    return fract((p3.x + p3.y) * p3.z);' + #10 +
    '}' + #10 +
    'vec2 gc_hash23(vec2 p) {' + #10 +
    '    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));' + #10 +
    '    p3 += dot(p3, p3.yzx + 33.33);' + #10 +
    '    return fract((p3.xx + p3.yz) * p3.zy);' + #10 +
    '}' + #10 +
    '' + #10 +
    '/* Один угловой тап рандомизации: хэш индекса блока -> поворот R и сдвиг' + #10 +
    '   off в UV. Главный путь вызывает его 4 раза для углов дуальной сетки' + #10 +
    '   2x2 и блендит выборки (бесшовность, iq-стиль). amp = (сдвиг, поворот). */' + #10 +
    'void gc_rndBlockTap(vec2 bidx, vec2 amp, out mat2 R, out vec2 off)' + #10 +
    '{' + #10 +
    '    vec2 hsh  = gc_hash23(bidx);' + #10 +
    '    float ha  = gc_hash13(bidx + vec2(19.19, 7.77));' + #10 +
    '    float ang = (ha * 2.0 - 1.0) * amp.y;' + #10 +
    '    float cs = cos(ang);' + #10 +
    '    float sn = sin(ang);' + #10 +
    '    R = mat2(cs, sn, -sn, cs);' + #10 +
    '    off = (hsh * 2.0 - 1.0) * amp.x;' + #10 +
    '}' + #10 +
    '' + #10 +

    '/* Sample sandy_soil atlas cell at current world-XZ tiling. Port of' + #10 +
    '   terrain.frag:172 — used to blend grass/terrain with sandy-soil' + #10 +
    '   on road halo. */' + #10 +
    'vec3 sampleSandySoilAlbedoLinear(vec3 worldPos)' + #10 +
    '{' + #10 +
    '    int sandyMat = MAT_SANDY_SOIL;' + #10 +
    '    float colsF = float(u_ground_grid_cols);' + #10 +
    '    float rowsF = float(u_ground_grid_rows);' + #10 +
    '    int col = sandyMat - (sandyMat/u_ground_grid_cols)*u_ground_grid_cols;' + #10 +
    '    int row = sandyMat / u_ground_grid_cols;' + #10 +
    '    vec2 cellOrigin = vec2(float(col)/colsF, float(row)/rowsF);' + #10 +
    '    vec2 cellSpan   = vec2(1.0/colsF, 1.0/rowsF);' + #10 +
    '' + #10 +
    '    float scl = u_ground_uv_scale[sandyMat];' + #10 +
    '    vec2 baseUV = worldPos.xz / max(scl, 0.001);' + #10 +
    '    vec2 tiledUV = clamp(fract(baseUV), vec2(0.001), vec2(0.999));' + #10 +
    '    float gins = u_ground_cell_inset;' + #10 +
    '    float gspan = 1.0 - 2.0 * gins;' + #10 +
    '    vec2 atlasUV = cellOrigin + (vec2(gins) + tiledUV * gspan) * cellSpan;' + #10 +
    '' + #10 +
    '    /* Same textureGrad trick as the main path so mip selection does' + #10 +
    '       not collapse at fract() integer crossings (grads scaled by the' + #10 +
    '       interior span to match the apron inset). */' + #10 +
    '    vec2 gradX = dFdx(baseUV) * cellSpan * gspan;' + #10 +
    '    vec2 gradY = dFdy(baseUV) * cellSpan * gspan;' + #10 +
    '    vec3 srgb  = textureGrad(u_ground_atlas, atlasUV, gradX, gradY).rgb;' + #10 +
    '    return gc_SRGBtoLINEAR(srgb);' + #10 +
    '}' + #10 +
    '' + #10 +
    '/* Road-halo heightblend opacity for sandy_soil over base albedo.' + #10 +
    '   Port of terrain.frag:122-148, collapsed to a single R8 texture' + #10 +
    '   instead of the per-tile JFA usage map streets-gl maintains. */' + #10 +
    'float sampleRoadHaloFactor(vec3 worldPos)' + #10 +
    '{' + #10 +
    '    if (u_road_field_present == 0) return 0.0;' + #10 +
    '    vec2 sz = max(u_road_field_size, vec2(1.0));' + #10 +
    '    vec2 uv = (worldPos.xz - u_road_field_origin) / sz;' + #10 +
    '    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)' + #10 +
    '        return 0.0;' + #10 +
    '    float v = texture2D(u_road_dist_field, uv).r;' + #10 +
    '    return clamp(v * u_road_halo_strength, 0.0, 1.0);' + #10 +
    '}' + #10 +
    '' + #10 +
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + #10 +
    '{' + #10 +
    '    float gp_pixel=max(length(dFdx(vRoadCoord.xy)),length(dFdy(vRoadCoord.xy)));' + #10 +
    '    gp_pixel*=rz_ground_capture>.5 ? .5 : 1.0;' + #10 +
    '    if(gp_available>.5 || rz_ground_capture>.5){' + #10 +
    '        gp_mask=gpPuddleMask(vRoadCoord,vRoadStyle,gp_pixel)*(smoothstep(.985,.998,normalize(vGroundNormalOS).y));' + #10 +
    '        if(gp_mask>.001){gp_normal=gpWaterFilmNormal(vRoadCoord.xy,gp_pixel,normalize(vGroundNormalOS));gp_request=vec4(gp_normal*.5+.5,1);}' + #10 +
    '    }' + #10 +
    '    if(rz_ground_capture>.5){fragment_color=gp_request;return;}' + #10 +
    '    int matId = int(floor(vGroundMaterialId + 0.5));' + #10 +
    '    if (matId < 0) matId = 0;' + #10 +
    '    if (matId >= U_GROUND_MAT_COUNT) matId = 0;' + #10 +
    '    bool isTerrain      = (matId == MAT_TERRAIN);' + #10 +
    '    bool isGrassBase    = isTerrain || matId==1 || matId==2 || matId==8 || matId==9;' + #10 +
    '#ifndef GC_GRASS_NATIVE_LIGHTING' + #10 +
    '    gc_grass_display_active=isGrassBase || matId==10;' + #10 +
    '#endif' + #10 +
    '    bool isRoadOriented = (matId >= 24) || (matId == MAT_ROAD_SAND);' + #10 +
    '' + #10 +
    '    /* ── LOD distance gate. Horizontal distance only — Y ignored.' + #10 +
    '       hScale grows the cutoff with camera altitude above local ground' + #10 +
    '       so flyovers keep distant features visible. ALL composite' + #10 +
    '       materials are culled past farDist (including terrain and water);' + #10 +
    '       the huge far-terrain mesh (rendered separately, flat-colour)' + #10 +
    '       fills the gap on the horizon. */' + #10 +
    '    float lodDist  = length(gLodToCamera.xz);' + #10 +
    '    float camAboveGround = max(0.0, gLodCamWorld.y - u_lod_ground_ref_y);' + #10 +
    '    float hScale   = 1.0 + camAboveGround / u_lod_height_ref;' + #10 +
    '    float nearDist = u_lod_near_base * hScale;' + #10 +
    '    /* discard-LOD удалён: дальний срез — TLODNode уровня D */' + #10 +
    '    bool useNormalMap = lodDist < nearDist;' + #10 +
    '#ifdef DIAG_LODGATE' + #10 +
    '    fragment_color = vec4(useNormalMap ? vec3(0.0,1.0,0.0) : vec3(1.0,0.0,0.0), 1.0); return;' + #10 +
    '#endif' + #10 +
    '' + #10 +
    '/* ── Diagnostic modes ──' + #10 +
    '   Uncomment ONE to visualise what the GPU receives per fragment:' + #10 +
    '     DIAG_SHOW_UV          R=fract(baseUV.x), G=fract(baseUV.y)' + #10 +
    '                           Roads: R varies smoothly across width,' + #10 +
    '                           G cycles 0..1 along length.' + #10 +
    '     DIAG_SHOW_MATID       R=matId/31' + #10 +
    '     DIAG_SHOW_ATLASUV     RG=atlasUV (which atlas pixel is sampled)' + #10 +
    '     DIAG_RAW_ALBEDO       Raw atlas RGB (skip PBR + tone mapping)' + #10 +
    '     DIAG_LODGATE          green = normal ON here, red = OFF' + #10 +
    '     DIAG_NRMSAMPLE        raw NORMAL atlas RGB (uniform grey-blue = no map)' + #10 +
    '     DIAG_HEIGHT           NORMAL atlas alpha = packed Height (flat = none)' + #10 +
    '     DIAG_AO               MASK atlas blue = packed AO (all white = none)' + #10 +
    '     DIAG_WORLDN           final world normal (uniform colour = no relief)' + #10 +
    '     DIAG_SUN              N.L term — BLACK everywhere = sun not lighting ground' + #10 +
    '     DIAG_SUNDIR           sun dir L as RGB (grey~0.5 = zero/unset, green = up/OK)' + #10 +
    '     DIAG_ROUGH            roughness (mask.r): BLACK=shiny/low, WHITE=matte (no shine)' + #10 +
    '     DIAG_RND              R=1 где рандомизация активна (rndOn), G=matId/31' + #10 +
    '                           (трава~0.03, terrain=0, питчи 15..18 ~0.48..0.58) */' + #10 +
    '// #define DIAG_SHOW_UV       1' + #10 +
    '// #define DIAG_SHOW_MATID    1' + #10 +
    '// #define DIAG_SHOW_ATLASUV  1' + #10 +
    '// #define DIAG_RAW_ALBEDO    1' + #10 +
    '// #define DIAG_LODGATE       1' + #10 +
    '// #define DIAG_NRMSAMPLE     1' + #10 +
    '// #define DIAG_HEIGHT        1' + #10 +
    '// #define DIAG_AO            1' + #10 +
    '// #define DIAG_WORLDN        1' + #10 +
    '// #define DIAG_SUN           1' + #10 +
    '// #define DIAG_SUNDIR        1' + #10 +
    '// #define DIAG_ROUGH         1' + #10 +
    '// #define DIAG_RND           1' + #10 +
    '' + #10 +
    '    /* Atlas cell coords for this matId. */' + #10 +
    '    float colsF = float(u_ground_grid_cols);' + #10 +
    '    float rowsF = float(u_ground_grid_rows);' + #10 +
    '    int col = matId - (matId/u_ground_grid_cols)*u_ground_grid_cols;' + #10 +
    '    int row = matId / u_ground_grid_cols;' + #10 +
    '    vec2 cellOrigin = vec2(float(col)/colsF, float(row)/rowsF);' + #10 +
    '    vec2 cellSpan   = vec2(1.0/colsF, 1.0/rowsF);' + #10 +
    '' + #10 +
    '#ifdef DIAG_SHOW_MATID' + #10 +
    '    fragment_color.rgb = vec3(float(matId)/31.0, 0.0, 0.0);' + #10 +
    '    fragment_color.a   = 1.0;' + #10 +
    '    return;' + #10 +
    '#endif' + #10 +
    '' + #10 +
    '    /* Unified base UV — SINGLE source of truth for ALL fragments' + #10 +
    '       (regular AND shadow). Branch on matId only:' + #10 +
    '         terrain (matId==0): derive from world XZ.' + #10 +
    '         everything else   : vGroundUV, pre-baked on CPU.' + #10 +
    '       Roads: vGroundUV holds (UVMinX..UVMaxX, V/UVScale) from GetRoadUV.' + #10 +
    '       Landuse: worldXZ / UVScale.' + #10 +
    '       Shadow vertices: barycentric-interpolated UV inherited from the' + #10 +
    '       ground triangle under each shadow vertex (Osm3dGeomShadows) —' + #10 +
    '       a shadow on a road carries the same lane-slice UV the road' + #10 +
    '       there carries. Shadowing applied below by reducing direct sun' + #10 +
    '       sharply while keeping most ambient, avoiding the flat-grey-' + #10 +
    '       overlay look of final-colour multiply. */' + #10 +
    '    vec2 baseUV;' + #10 +
    '    if (isGrassBase) {' + #10 +
    '        /* Match the four-metre overhead bake, including its north/south' + #10 +
    '           orientation. Existing tiles may still carry the old forest UV.' + #10 +
    '           Interpolate local metres; keep the large origin out of UVs. */' + #10 +
    '        vec2 phase=mod(mod(gc_ground_origin.xz,4.0)+gc_ground_origin_low.xz,4.0);' + #10 +
    '        baseUV=(vGroundLocalPos.xz+phase)*vec2(0.25,-0.25);' + #10 +
    '    } else {' + #10 +
    '        baseUV = vGroundUV;' + #10 +
    '    }' + #10 +
    '' + #10 +
    '    /* Хэш-рандомизация блока (см. TGroundTexRandom) с БЛЕНДОМ ШВОВ' + #10 +
    '       (iq-стиль). Сетка блоков привязана к МИРОВОЙ координате' + #10 +
    '       vGroundObjPos.xz, НЕ к UV (хэш от UV проявлял геометрию landuse).' + #10 +
    '       Фрагмент лежит между 4 ЦЕНТРАМИ блоков (дуальная сетка со сдвигом' + #10 +
    '       0.5); каждый угол даёт свой поворот+сдвиг UV, выборки блендятся' + #10 +
    '       билинейными весами, заострёнными так, что бленд живёт только в' + #10 +
    '       полосе ~1/3 блока вокруг шва, а в центре блока выборка чистая' + #10 +
    '       (вес угла ровно 1). Сумма весов = 1 по построению. Двигается блок' + #10 +
    '       целиком, не пиксельный шум. Дороги пропускаем (rndOn=0, 1 тап).' + #10 +
    '       Производные берём от ИСХОДНОГО (гладкого) baseUV и поворачиваем' + #10 +
    '       матрицей соответствующего угла — |grad| сохраняется, mip стабилен' + #10 +
    '       (та же дисциплина pre-fract производных). fract() ниже держит' + #10 +
    '       выборку внутри ячейки атласа при любом сдвиге. */' + #10 +
    '    vec2 rnd_dUVdx = dFdx(baseUV);' + #10 +
    '    vec2 rnd_dUVdy = dFdy(baseUV);' + #10 +
    '    vec2 rndLocalDx = dFdx(vGroundLocalPos.xz);' + #10 +
    '    vec2 rndLocalDy = dFdy(vGroundLocalPos.xz);' + #10 +
    '    mat2 rndR  = mat2(1.0, 0.0, 0.0, 1.0);' + #10 +
    '    mat2 rndR1 = rndR;' + #10 +
    '    mat2 rndR2 = rndR;' + #10 +
    '    mat2 rndR3 = rndR;' + #10 +
    '    vec2 rndUV1 = baseUV;' + #10 +
    '    vec2 rndUV2 = baseUV;' + #10 +
    '    vec2 rndUV3 = baseUV;' + #10 +
    '    vec4 rndW = vec4(1.0, 0.0, 0.0, 0.0);' + #10 +
    '    bool proceduralRoad=vRoadCoord.w < -1.5 || (rp_mode>0.5 && vRoadCoord.z>0.05);' + #10 +
    '    float rndOn = 0.0;' + #10 +
    '    if (!isRoadOriented && !proceduralRoad) {' + #10 +
    '        vec3 rp = u_ground_rnd[matId];' + #10 +
    '        if (rp.x > 0.0001) {' + #10 +
    '            rndOn = 1.0;' + #10 +
    '            /* Interpolate only tile-local metres. Rotating absolute UV at' + #10 +
    '               hundreds of km loses texels and exposes triangle/tile edges.' + #10 +
    '               Hash the global integer cell, sample around its centre. */' + #10 +
    '            vec4 gridOrigin = gc_ground_grid_origin[matId];' + #10 +
    '            vec2 rndGP = vGroundLocalPos.xz / rp.x + gridOrigin.zw - 0.5;' + #10 +
    '            vec2 rndCell = floor(rndGP);' + #10 +
    '            vec2 rndFC = rndCell + gridOrigin.xy;' + #10 +
    '            vec2 rndFR = rndGP - rndCell;' + #10 +
    '            float rndScale = max(u_ground_uv_scale[matId], 0.001);' + #10 +
    '            float rndRepeat = rp.x / rndScale;' + #10 +
    '            vec2 rndLocalUV = (rndFR + 0.5) * rndRepeat;' + #10 +
    '            rnd_dUVdx = rndLocalDx / rndScale;' + #10 +
    '            rnd_dUVdy = rndLocalDy / rndScale;' + #10 +
    '            /* заострение: полоса бленда ~1/3 блока вокруг шва */' + #10 +
    '            vec2 rndS = clamp((rndFR - 0.5) * 3.0 + 0.5, 0.0, 1.0);' + #10 +
    '            rndS = rndS * rndS * (3.0 - 2.0 * rndS);' + #10 +
    '            mat2 rndTR;' + #10 +
    '            vec2 rndTO;' + #10 +
    '            gc_rndBlockTap(rndFC,                  rp.yz, rndTR, rndTO);' + #10 +
    '            rndR = rndTR;' + #10 +
    '            vec2 rndUV0 = rndTR * rndLocalUV + rndTO;' + #10 +
    '            gc_rndBlockTap(rndFC + vec2(1.0, 0.0), rp.yz, rndTR, rndTO);' + #10 +
    '            rndR1 = rndTR;' + #10 +
    '            rndUV1 = rndTR * (rndLocalUV - vec2(rndRepeat, 0.0)) + rndTO;' + #10 +
    '            gc_rndBlockTap(rndFC + vec2(0.0, 1.0), rp.yz, rndTR, rndTO);' + #10 +
    '            rndR2 = rndTR;' + #10 +
    '            rndUV2 = rndTR * (rndLocalUV - vec2(0.0, rndRepeat)) + rndTO;' + #10 +
    '            gc_rndBlockTap(rndFC + vec2(1.0, 1.0), rp.yz, rndTR, rndTO);' + #10 +
    '            rndR3 = rndTR;' + #10 +
    '            rndUV3 = rndTR * (rndLocalUV - vec2(rndRepeat)) + rndTO;' + #10 +
    '            rndW = vec4((1.0 - rndS.x) * (1.0 - rndS.y),' + #10 +
    '                        rndS.x * (1.0 - rndS.y),' + #10 +
    '                        (1.0 - rndS.x) * rndS.y,' + #10 +
    '                        rndS.x * rndS.y);' + #10 +
    '            baseUV = rndUV0;' + #10 +
    '        }' + #10 +
    '    }' + #10 +
    '' + #10 +
    '    /* Tiled UV inside the cell. Roads: U already in [UVMinX..UVMaxX]' + #10 +
    '       so no fract on x. The clamp keeps us 1 sub-cell-pixel inside the' + #10 +
    '       cell at mip 0 so linear filter never taps outside; combined with' + #10 +
    '       internal cell padding from the atlas baker this also handles' + #10 +
    '       mip levels ≥1 with negligible cross-cell bleed. */' + #10 +
    '    vec2 tiledUV;' + #10 +
    '    if (isRoadOriented) {' + #10 +
    '        tiledUV.x = clamp(baseUV.x, 0.001, 0.999);' + #10 +
    '        tiledUV.y = clamp(fract(baseUV.y), 0.001, 0.999);' + #10 +
    '    } else {' + #10 +
    '        tiledUV = clamp(fract(baseUV), vec2(0.001), vec2(0.999));' + #10 +
    '    }' + #10 +
    '    float gins = u_ground_cell_inset;' + #10 +
    '    float gspan = 1.0 - 2.0 * gins;' + #10 +
    '' + #10 +
    '    /* Pre-fract derivatives in atlas-UV space. Computed up here (not at' + #10 +
    '       the diffuse tap) so the textureGrad taps below pick the right mip.' + #10 +
    '       dFdy(baseUV) is smooth across fract() integer crossings, so the GPU' + #10 +
    '       picks the correct mip via textureGrad instead of collapsing the' + #10 +
    '       cell to its mean colour. Scaled by gspan to match the apron inset. */' + #10 +
    '    /* rndR-повёрнутые производные исходного baseUV: ортонормированный' + #10 +
    '       поворот сохраняет |grad| => выбор mip не меняется, а разрыв поля' + #10 +
    '       baseUV на границе блока в dFdx не попадает (нет спайка mip). */' + #10 +
    '    vec2 gradX = (rndR * rnd_dUVdx) * cellSpan * gspan;' + #10 +
    '    vec2 gradY = (rndR * rnd_dUVdy) * cellSpan * gspan;' + #10 +
    '' + #10 +
    '    /* Geometric TBN, built above the texture taps. Same cotangent construction as' + #10 +
    '       the former post-tap block; reused for normal mapping below so it is' + #10 +
    '       built exactly once. Derivatives are unconditional (uniform control' + #10 +
    '       flow) to stay well-defined across the LOD boundary. */' + #10 +
    '    vec3 dp1  = -dFdx(gLodToCamera);' + #10 +
    '    vec3 dp2  = -dFdy(gLodToCamera);' + #10 +
    '    vec2 tangentUV = vRoadCoord.w < -1.5 ? vRoadCoord.xy : (isTerrain ? vGroundLocalPos.xz : vGroundUV);' + #10 +
    '    vec2 duv1 = dFdx(tangentUV);' + #10 +
    '    vec2 duv2 = dFdy(tangentUV);' + #10 +
    '    vec3 Ngeo = normalize(vGroundNormalOS);' + #10 +
    '    if (vRoadCoord.w < -1.5) Ngeo=normalize(cross(dp1,dp2));' + #10 +
    '    vec3 rockPhase=mod(mod(gc_ground_origin,4096.0)+gc_ground_origin_low.xyz,4096.0);' + #10 +
    '    vec3 rockPosition=vGroundLocalPos+rockPhase;' + #10 +
    '    float rockFootprint=max(length(dp1),length(dp2));' + #10 +
    '    float rockWeight=0.0;' + #10 +
    '    if (matId==10) rockWeight=1.0;' + #10 +
    '    else if (isGrassBase || matId==3 || matId==4 || matId==22)' + #10 +
    '        rockWeight=gcSlopeRockMask(rockPosition.xz,vGroundNormalOS.y);' + #10 +
    '    // The normal/mask/PBR result contributes nothing to purely grassy ground.' + #10 +
    '    // Keep every nonzero rock blend on the full path, including its fringe.' + #10 +
    '    bool flatGrass=isGrassBase && !proceduralRoad && rockWeight==0.0;' + #10 +
    '#if defined(DIAG_WORLDN) || defined(DIAG_SUN) || defined(DIAG_SUNDIR) || defined(DIAG_ROUGH)' + #10 +
    '    flatGrass=false;' + #10 +
    '#endif' + #10 +
    '    vec3 Tgeo=vec3(0.0), Bgeo=vec3(0.0);' + #10 +
    '    float tbnDet=0.0;' + #10 +
    '    if (!flatGrass) {' + #10 +
    '        tbnDet=duv1.x*duv2.y-duv1.y*duv2.x;' + #10 +
    '        // Test UV rank relative to the gradients, not their pixel size.' + #10 +
    '        // An absolute determinant cutoff rotated normal maps near the' + #10 +
    '        // rear camera and drew a moving line across the ground.' + #10 +
    '        float uvLengthProduct=dot(duv1,duv1)*dot(duv2,duv2);' + #10 +
    '        if (uvLengthProduct>0.0 && tbnDet*tbnDet>1e-12*uvLengthProduct) {' + #10 +
    '            float invDet = 1.0/tbnDet;' + #10 +
    '            Tgeo = (dp1*duv2.y - dp2*duv1.y)*invDet;' + #10 +
    '            Bgeo = (dp2*duv1.x - dp1*duv2.x)*invDet;' + #10 +
    '        } else {' + #10 +
    '            Tgeo = dp1 - dot(dp1,Ngeo)*Ngeo;' + #10 +
    '            Bgeo = cross(Ngeo, Tgeo);' + #10 +
    '        }' + #10 +
    '        Tgeo = normalize(Tgeo - dot(Tgeo,Ngeo)*Ngeo);' + #10 +
    '        float roadHandedness=proceduralRoad && dot(cross(Ngeo,Tgeo),Bgeo)<0.0 ? -1.0 : 1.0;' + #10 +
    '        Bgeo = normalize(cross(Ngeo, Tgeo))*roadHandedness;' + #10 +
    '    }' + #10 +
    '    // Footway U spans its width; use the existing metric tangent before normalization.' + #10 +
    '    vec3 sidewalkCurb=vec3(0.0,0.0,1.0), sidewalkConcrete=vec3(0.0);' + #10 +
    '    if (matId==28 && rp_mode>0.5 && abs(tbnDet)>1e-12) {' + #10 +
    '    float sidewalkWidth=length(dp1*duv2.y-dp2*duv1.y)/max(abs(tbnDet),1e-12);' + #10 +
    '    vec2 sidewalkFootprint=vec2(max(abs(duv1.y),abs(duv2.y))*10.0,' + #10 +
    '      max(abs(duv1.x),abs(duv2.x))*sidewalkWidth)*0.5;' + #10 +
    '      float edge=max(0.0,min(vGroundUV.x,1.0-vGroundUV.x))*sidewalkWidth;' + #10 +
    '      sidewalkCurb=rp_sidewalkCurb(vGroundUV.y*10.0,edge,sidewalkFootprint,sidewalkConcrete);' + #10 +
    '    }' + #10 +
    '' + #10 +
    '    vec2 atlasUV = cellOrigin + (vec2(gins) + tiledUV * gspan) * cellSpan;' + #10 +
    '' + #10 +
    '    /* Атлас-UV и производные угловых тапов 1..3 (бленд швов): тот же' + #10 +
    '       fract+clamp+cell-mapping, что у главного (tap0) пути выше. Дороги' + #10 +
    '       сюда не попадают (rndOn=0). Поворот производных матрицей своего' + #10 +
    '       угла: |grad| сохраняется, mip у всех тапов одинаковый. */' + #10 +
    '    vec2 rndAUV1 = atlasUV;' + #10 +
    '    vec2 rndGX1 = gradX;' + #10 +
    '    vec2 rndGY1 = gradY;' + #10 +
    '    vec2 rndAUV2 = atlasUV;' + #10 +
    '    vec2 rndGX2 = gradX;' + #10 +
    '    vec2 rndGY2 = gradY;' + #10 +
    '    vec2 rndAUV3 = atlasUV;' + #10 +
    '    vec2 rndGX3 = gradX;' + #10 +
    '    vec2 rndGY3 = gradY;' + #10 +
    '    if (rndOn > 0.5) {' + #10 +
    '        vec2 rndT = clamp(fract(rndUV1), vec2(0.001), vec2(0.999));' + #10 +
    '        rndAUV1 = cellOrigin + (vec2(gins) + rndT * gspan) * cellSpan;' + #10 +
    '        rndGX1 = (rndR1 * rnd_dUVdx) * cellSpan * gspan;' + #10 +
    '        rndGY1 = (rndR1 * rnd_dUVdy) * cellSpan * gspan;' + #10 +
    '        rndT = clamp(fract(rndUV2), vec2(0.001), vec2(0.999));' + #10 +
    '        rndAUV2 = cellOrigin + (vec2(gins) + rndT * gspan) * cellSpan;' + #10 +
    '        rndGX2 = (rndR2 * rnd_dUVdx) * cellSpan * gspan;' + #10 +
    '        rndGY2 = (rndR2 * rnd_dUVdy) * cellSpan * gspan;' + #10 +
    '        rndT = clamp(fract(rndUV3), vec2(0.001), vec2(0.999));' + #10 +
    '        rndAUV3 = cellOrigin + (vec2(gins) + rndT * gspan) * cellSpan;' + #10 +
    '        rndGX3 = (rndR3 * rnd_dUVdx) * cellSpan * gspan;' + #10 +
    '        rndGY3 = (rndR3 * rnd_dUVdy) * cellSpan * gspan;' + #10 +
    '    }' + #10 +
    '' + #10 +
    '#ifdef DIAG_RND' + #10 +
    '    fragment_color = vec4(rndOn, float(matId)/31.0, 0.0, 1.0); return;' + #10 +
    '#endif' + #10 +
    '' + #10 +
    '#ifdef DIAG_SHOW_UV' + #10 +
    '    fragment_color.rgb = vec3(fract(baseUV.x), fract(baseUV.y), 0.0);' + #10 +
    '    fragment_color.a   = 1.0;' + #10 +
    '    return;' + #10 +
    '#endif' + #10 +
    '#ifdef DIAG_SHOW_ATLASUV' + #10 +
    '    fragment_color.rgb = vec3(atlasUV.x, atlasUV.y, 0.0);' + #10 +
    '    fragment_color.a   = 1.0;' + #10 +
    '    return;' + #10 +
    '#endif' + #10 +
    '' + #10 +
    '    /* Explicit LOD via pre-fract derivatives. textureGrad(...dPdx,dPdy)' + #10 +
    '       tells the GPU to pick mip from the gradients we hand it, NOT' + #10 +
    '       from atlasUV auto-derivatives. The latter would be wrong:' + #10 +
    '       fract(baseUV) flips ~1→0 at integer crossings, producing a -1' + #10 +
    '       spike in dFdy(tiledUV.y); GPU takes max(|dFdx|,|dFdy|) → picks' + #10 +
    '       an aggressive mip → cell averages to mean colour, lane markings' + #10 +
    '       vanish. Pre-fract dFdy(baseUV) is smooth (per-pixel UV change' + #10 +
    '       in tile units), × cellSpan converts to atlas-UV-space.' + #10 +
    '       Scaled by gspan to match the apron inset (interior span). */' + #10 +
    '    /* gradX/gradY computed above (hoisted for the textureGrad taps). */' + #10 +
    '    vec2 roadDx=dFdx(vRoadCoord.xy), roadDy=dFdy(vRoadCoord.xy);' + #10 +
    '    vec4 roadColor=vec4(0.0), roadNormal=vec4(0.5,0.5,1.0,0.0);' + #10 +
    '    vec4 diffSample;' + #10 +
    '    if (proceduralRoad) {' + #10 +
    '      vec3 roadView=normalize(gLodToCamera);' + #10 +
    '      vec3 roadViewTS=vec3(dot(roadView,Tgeo),dot(roadView,Bgeo),dot(roadView,Ngeo));' + #10 +
    '      rp_sample(vRoadCoord,vRoadStyle,roadDx,roadDy,roadViewTS,roadColor,roadNormal);' + #10 +
    '      diffSample=vec4(roadColor.rgb,1.0);' + #10 +
    '    } else diffSample = textureGrad(u_ground_atlas,atlasUV,gradX,gradY);' + #10 +
    '    if (rndOn > 0.5) {' + #10 +
    '        diffSample = diffSample * rndW.x' + #10 +
    '            + textureGrad(u_ground_atlas, rndAUV1, rndGX1, rndGY1) * rndW.y' + #10 +
    '            + textureGrad(u_ground_atlas, rndAUV2, rndGX2, rndGY2) * rndW.z' + #10 +
    '            + textureGrad(u_ground_atlas, rndAUV3, rndGX3, rndGY3) * rndW.w;' + #10 +
    '    }' + #10 +
    '    // At world overview scale, a pixel covers a whole repeated cell.' + #10 +
    '    // Global atlas mips then mix neighbouring MATERIALS and make bands.' + #10 +
    '    // Converge to this cell average before reaching those mip levels.' + #10 +
    '    float atlasFar=proceduralRoad ? 0.0 : smoothstep(0.12,0.50,max(length(rnd_dUVdx),length(rnd_dUVdy)));' + #10 +
    '    diffSample.rgb=mix(diffSample.rgb,u_ground_fallback_rgb[matId],atlasFar);' + #10 +
    '    /* LOD-1: skip normal atlas tap beyond near threshold. Flat normal' + #10 +
    '       (0.5,0.5,1) unpacks to (0,0,0); useNormalMap branch uses' + #10 +
    '       vGroundNormalOS instead. */' + #10 +
    '    vec3 nrmSample = vec3(0.5, 0.5, 1.0);' + #10 +
    '    if (useNormalMap && !flatGrass) {' + #10 +
    '        if (proceduralRoad) {' + #10 +
    '          vec2 n=roadNormal.xy*2.0-1.0;' + #10 +
    '          nrmSample=vec3(roadNormal.xy,sqrt(max(0.0,1.0-dot(n,n)))*0.5+0.5);' + #10 +
    '        } else nrmSample = textureGrad(u_ground_normal_atlas, atlasUV, gradX, gradY).rgb;' + #10 +
    '        if (rndOn > 0.5) {' + #10 +
    '            nrmSample = nrmSample * rndW.x' + #10 +
    '                + textureGrad(u_ground_normal_atlas, rndAUV1, rndGX1, rndGY1).rgb * rndW.y' + #10 +
    '                + textureGrad(u_ground_normal_atlas, rndAUV2, rndGX2, rndGY2).rgb * rndW.z' + #10 +
    '                + textureGrad(u_ground_normal_atlas, rndAUV3, rndGX3, rndGY3).rgb * rndW.w;' + #10 +
    '        }' + #10 +
    '    }' + #10 +
    '    diffSample.rgb=mix(diffSample.rgb,sidewalkConcrete,sidewalkCurb.x);' + #10 +
    '    if (useNormalMap && sidewalkCurb.x>0.0) {' + #10 +
    '      float slope=sidewalkCurb.y*(1.0-2.0*step(0.5,vGroundUV.x));' + #10 +
    '      vec3 curbNormal=normalize(vec3(slope,0.0,1.0))*0.5+0.5;' + #10 +
    '      nrmSample=mix(nrmSample,curbNormal,sidewalkCurb.x);' + #10 +
    '    }' + #10 +
    '    vec3 albedoLin  = gc_SRGBtoLINEAR(diffSample.rgb);' + #10 +
    '#ifdef DIAG_NRMSAMPLE' + #10 +
    '    fragment_color = vec4(textureGrad(u_ground_normal_atlas, atlasUV, gradX, gradY).rgb, 1.0); return;' + #10 +
    '#endif' + #10 +
    '#ifdef DIAG_HEIGHT' + #10 +
    '    fragment_color = vec4(vec3(textureGrad(u_ground_normal_atlas, atlasUV, gradX, gradY).a), 1.0); return;' + #10 +
    '#endif' + #10 +
    '#ifdef DIAG_AO' + #10 +
    '    fragment_color = vec4(vec3(textureGrad(u_ground_mask_atlas, atlasUV, gradX, gradY).b), 1.0); return;' + #10 +
    '#endif' + #10 +
    '' + #10 +
    '// #define DIAG_RAW_ALBEDO 1' + #10 +
    '#ifdef DIAG_RAW_ALBEDO' + #10 +
    '    fragment_color.rgb = diffSample.rgb;' + #10 +
    '    fragment_color.a   = 1.0;' + #10 +
    '    return;' + #10 +
    '#endif' + #10 +
    '' + #10 +
    '    /* Sand/dirt road alpha cutout removed: the ground diffuse atlas is now' + #10 +
    '       fully opaque (grass is baked under the feathered road borders at' + #10 +
    '       atlas-build time), so the old screen-door / hard-alpha discards never' + #10 +
    '       fired. Dropping the discard keeps the ground shader early-Z friendly. */' + #10 +
    '' + #10 +
    '    /* Per-material tinting (linear; fallbacks are authored in sRGB-ish' + #10 +
    '       space — small approximation). */' + #10 +
    '    vec3 fallbackLin = gc_SRGBtoLINEAR(u_ground_fallback_rgb[matId]);' + #10 +
    '    albedoLin = mix(albedoLin, fallbackLin,' + #10 +
    '                    clamp(u_ground_tint_amount, 0.0, 1.0));' + #10 +
    '' + #10 +
    '' + #10 +
    '    /* Streets-gl road halo (terrain.frag:170-175). Applied ONLY to' + #10 +
    '       non-road ground so the road itself is never tinted (sits on top' + #10 +
    '       via ZIndex), water/pitches are preserved. Eligible: 0 (terrain)' + #10 +
    '       and 1..22 (landuse) except water (20), helipad (19),' + #10 +
    '       pitches (15..18). */' + #10 +
    '    bool haloEligible = (!isRoadOriented) &&' + #10 +
    '                        (matId < MAT_ROAD_SAND) &&' + #10 +
    '                        (matId != 20) && (matId != 19) &&' + #10 +
    '                        (matId < 15 || matId > 18);' + #10 +
    '    if (haloEligible) {' + #10 +
    '        float halo = sampleRoadHaloFactor(vGroundObjPos);' + #10 +
    '        if (halo > 0.001) {' + #10 +
    '            vec3 sandyLin = sampleSandySoilAlbedoLinear(vGroundObjPos);' + #10 +
    '            albedoLin = mix(albedoLin, sandyLin, halo);' + #10 +
    '        }' + #10 +
    '    }' + #10 +
    '    float grassFootprint=max(length(rndLocalDx),length(rndLocalDy));' + #10 +
    '    if (flatGrass) {' + #10 +
    '        fragment_color=vec4(gcGrassDisplayColor(albedoLin,vGroundLocalPos.xz,grassFootprint),1.0);' + #10 +
    '        gc_grass_display=fragment_color.rgb;' + #10 +
    '        // Shadow collection and display-space output still use the usual hooks.' + #10 +
    '        return;' + #10 +
    '    }' + #10 +
    '' + #10 +
    '    /* TBN from screen-space derivatives. Skipped in far LOD' + #10 +
    '       (useNormalMap=false) since nrmSample is flat default and result' + #10 +
    '       simplifies to worldN = vGroundNormalOS. Saves 4 derivatives +' + #10 +
    '       3×3 mul per far fragment.' + #10 +
    '' + #10 +
    '       CRITICAL: dFdx/dFdy calls are hoisted OUT of the useNormalMap' + #10 +
    '       branch. Otherwise, fragments straddling the nearDist boundary' + #10 +
    '       within a single 2×2 quad take different branches → the' + #10 +
    '       derivative ops execute under non-uniform control flow → GLSL' + #10 +
    '       leaves the result undefined (NVIDIA returns NaN/junk in' + #10 +
    '       practice). NaN T/B → corrupt worldN → dot(N,L)<0 → black' + #10 +
    '       fragments. Exactly the symptom of a black ring along the' + #10 +
    '       LOD boundary around the camera. Computing derivatives' + #10 +
    '       unconditionally is well-defined and costs ~nothing on far' + #10 +
    '       fragments (results are simply discarded). */' + #10 +
    '    /* worldN reuses the geometric TBN built above the texture taps;' + #10 +
    '       nrmSample was read at atlasUV. */' + #10 +
    '    vec3 worldN;' + #10 +
    '    if (useNormalMap) {' + #10 +
    '        vec3 nrmTS = nrmSample * 2.0 - 1.0;' + #10 +
    '        /* НОРМАЛЬ ЗА блочным поворотом НЕ вращаем (было transpose(rndR)):' + #10 +
    '           матрица применялась ПОСЛЕ выборки и переживала любой mip; DC-смещение' + #10 +
    '           среднего xy карты нормалей наклонялось у каждого блока по-своему =>' + #10 +
    '           разный средний N·L => блоки темнее/светлее с любого ракурса.' + #10 +
    '           Цена отказа — направления бампов не следуют за поворотом diffuse —' + #10 +
    '           для изотропных материалов неразличима и усредняется на mip-уровнях. */' + #10 +
    '        nrmTS.xy *= u_ground_normal_strength;' + #10 +
    '        mat3 TBN = mat3(Tgeo, Bgeo, Ngeo);' + #10 +
    '        worldN = normalize(TBN * nrmTS);' + #10 +
    '    } else {' + #10 +
    '        worldN = normalize(Ngeo);' + #10 +
    '    }' + #10 +
    '#ifdef DIAG_WORLDN' + #10 +
    '    fragment_color = vec4(worldN * 0.5 + 0.5, 1.0); return;' + #10 +
    '#endif' + #10 +
    '' + #10 +
    '    /* PBR setup (streets-gl shading.frag:337-355). */' + #10 +
    '    /* Roughness from the mask atlas R channel (textureGrad: same atlas' + #10 +
    '       UV + gradients as diffuse/normal). Maskless materials carry their' + #10 +
    '       constant Roughness baked into the cell, so this is uniform-free.' + #10 +
    '       u_ground_roughness[] is left attached but no longer read here. */' + #10 +
    '    vec4 maskSample;' + #10 +
    '    if (proceduralRoad) maskSample=vec4(roadColor.a,0.0,roadNormal.z,1.0);' + #10 +
    '    else maskSample=textureGrad(u_ground_mask_atlas,atlasUV,gradX,gradY);' + #10 +
    '    if (rndOn > 0.5) {' + #10 +
    '        maskSample = maskSample * rndW.x' + #10 +
    '            + textureGrad(u_ground_mask_atlas, rndAUV1, rndGX1, rndGY1) * rndW.y' + #10 +
    '            + textureGrad(u_ground_mask_atlas, rndAUV2, rndGX2, rndGY2) * rndW.z' + #10 +
    '            + textureGrad(u_ground_mask_atlas, rndAUV3, rndGX3, rndGY3) * rndW.w;' + #10 +
    '    }' + #10 +
    '    maskSample=mix(maskSample,vec4(u_ground_roughness[matId],u_ground_metallic[matId],1.0,1.0),atlasFar);' + #10 +
    '    maskSample.r=mix(maskSample.r,0.9,sidewalkCurb.x);' + #10 +
    '    maskSample.b=mix(maskSample.b,sidewalkCurb.z,sidewalkCurb.x);' + #10 +
    '    vec3 grassAlbedoLin=albedoLin;' + #10 +
    '    if (rockWeight>0.001) {' + #10 +
    '        vec3 rockAlbedo,rockNormal; vec2 rockSurface;' + #10 +
    '        gcRockMaterial(rockPosition,Ngeo,normalize(gLodToCamera),rockFootprint,' + #10 +
    '            length(gLodToCamera),dp1,dp2,rockAlbedo,rockNormal,rockSurface);' + #10 +
    '        float blendRock=isGrassBase ? 1.0 : rockWeight;' + #10 +
    '        albedoLin=mix(albedoLin,gc_SRGBtoLINEAR(rockAlbedo),blendRock);' + #10 +
    '        worldN=normalize(mix(worldN,rockNormal,blendRock));' + #10 +
    '        maskSample=mix(maskSample,vec4(rockSurface.x,0.0,rockSurface.y,1.0),blendRock);' + #10 +
    '    }' + #10 +
    '    float perceptualRoughness = clamp(maskSample.r, 0.04, 1.0);' + #10 +
    '#ifdef DIAG_ROUGH' + #10 +
    '    fragment_color = vec4(vec3(perceptualRoughness), 1.0); return;' + #10 +
    '#endif' + #10 +
    '    /* Ambient occlusion baked into mask.b (1.0 = none, so legacy mats are' + #10 +
    '       unaffected — their cells carry B=255). */' + #10 +
    '    float ao                  = maskSample.b;' + #10 +
    '    float metallic            = clamp(u_ground_metallic [matId], 0.0,  1.0);' + #10 +
    '    float reflectanceF0       = 0.04;  /* dielectric default */' + #10 +
    '    vec3  F0           = mix(vec3(reflectanceF0), albedoLin, metallic);' + #10 +
    '    vec3  diffuseColor = albedoLin * (vec3(1.0) - F0) * (1.0 - metallic);' + #10 +
    '    float alphaRough   = perceptualRoughness * perceptualRoughness;' + #10 +
    '    float reflMax      = max(max(F0.r, F0.g), F0.b);' + #10 +
    '    vec3  F90          = vec3(clamp(reflMax * 50.0, 0.0, 1.0));' + #10 +
    '' + #10 +
    '    /* Directional sun via Cook-Torrance GGX (shading.frag:130). */' + #10 +
    '    vec3  L = normalize(gc_SunDirToward);' + #10 +
    '    vec3  V = normalize(gLodToCamera); /* real view (was const VIEW_DIR) */' + #10 +
    '    vec3  H = normalize(L + V);' + #10 +
    '    float NdotL = clamp(dot(worldN, L), 0.0, 1.0);' + #10 +
    '    float NdotV = clamp(dot(worldN, V), 0.0, 1.0);' + #10 +
    '    float NdotH = clamp(dot(worldN, H), 0.0, 1.0);' + #10 +
    '    float VdotH = clamp(dot(V,      H), 0.0, 1.0);' + #10 +
    '#ifdef DIAG_SUN' + #10 +
    '    fragment_color = vec4(vec3(NdotL), 1.0); return;' + #10 +
    '#endif' + #10 +
    '#ifdef DIAG_SUNDIR' + #10 +
    '    fragment_color = vec4(L * 0.5 + 0.5, 1.0); return;' + #10 +
    '#endif' + #10 +
    '' + #10 +
    '    vec3 directLight = vec3(0.0);' + #10 +
    '    if (NdotL > 0.0 || NdotV > 0.0) {' + #10 +
    '        vec3  F   = specularReflection(F0, F90, VdotH);' + #10 +
    '        float Vis = visibilityOcclusion(alphaRough, NdotL, NdotV);' + #10 +
    '        float D   = microfacetDistribution(alphaRough, NdotH);' + #10 +
    '        vec3  diffuseContrib = (vec3(1.0) - F) * diffuseColor / PI;' + #10 +
    '        vec3  specContrib    = F * Vis * D * u_ground_spec_boost;' + #10 +
    '        directLight = NdotL * (diffuseContrib + specContrib)' + #10 +
    '                    * SUN_COLOR * SUN_INTENSITY;' + #10 +
    '    }' + #10 +
    '' + #10 +
    '    /* Ambient (streets-gl shading.frag:407 — 0.3 × diffuse). */' + #10 +
    '    vec3 ambient = diffuseColor * u_ground_ambient * ao;' + #10 +
    '' + #10 +
    '    /* Ground fragments are not darkened here — building shadows are' + #10 +
    '       applied by the separate per-chunk shadow-mask overlay effect' + #10 +
    '       (SHADOW_MASK_FS), which samples the top-down coverage mask. */' + #10 +
    '    vec3 colorLin = directLight + ambient;' + #10 +
    '' + #10 +
    '    /* Scene exposure — lifts the whole composite uniformly (preserves' + #10 +
    '       material contrast) so grass/roads sit at a daylight level matching' + #10 +
    '       the instanced vegetation; Reinhard below still tames the bright end. */' + #10 +
    '    colorLin *= u_ground_exposure;' + #10 +
    '' + #10 +
    '    /* Reinhard tone map. */' + #10 +
    '    vec3 colorTM = colorLin / (colorLin + vec3(1.0));' + #10 +
    '' + #10 +
    '    /* Linear → sRGB. */' + #10 +
    '    fragment_color.rgb = gc_LINEARtoSRGB(colorTM);' + #10 +
    '    if (isGrassBase) {' + #10 +
    '        vec3 grassRGB=gcGrassDisplayColor(grassAlbedoLin,vGroundLocalPos.xz,grassFootprint);' + #10 +
    '        fragment_color.rgb=mix(grassRGB,fragment_color.rgb,rockWeight);' + #10 +
    '    }' + #10 +
    '    if (isGrassBase || matId==10) gc_grass_display=fragment_color.rgb;' + #10 +
    '    fragment_color.a   = 1.0;' + #10 +
    '}' + #10 +
    'void PLUG_fragment_modify(inout vec4 color) {' + #10 +
    '    if (!gc_grass_display_active) gc_grass_applyShadow(color);' + #10 +
    '}' + #10 +
    'void PLUG_fragment_end(inout vec4 color) {' + #10 +
    '    if(rz_ground_capture>.5){color=gp_request;return;}' + #10 +
    '    /* The instanced canopy writes display RGB directly. Keep its base' + #10 +
    '       in that space too: viewport ACES must not tone-map it a second time.' + #10 +
    '       Apply the shared shadow here, after static coverage is collected. */' + #10 +
    '    if (gc_grass_display_active) {' + #10 +
    '        color.rgb=gc_grass_display; gc_grass_applyShadow(color);' + #10 +
    '    }' + #10 +
    '    if(gp_mask>.001)color.rgb=mix(color.rgb,gpWaterFilm(color.rgb,gp_normal,normalize(gLodToCamera),normalize(gc_SunDirToward)),gp_mask);' + #10 +
    '}' + #10;
end;


{ PNG loading helpers (shared by diffuse + normal atlas paths) }

{ Per-pixel copy from any TCastleImage descendant into a fresh
  TRGBAlphaImage. Fallback for sources that TRGBAlphaImage.Assign
  rejects (e.g. 16-bit PNGs decoded as TRGBAlphaFloatImage). About
  200 ns per pixel — fine for ~32 startup tiles. }

{ PNG-лоадер ячейки: общий AtlasLoadPngForTile из Osm3dCompositeAtlas
  (бывшие CopyViaColors / LoadPngForTile перенесены туда). }

function DefaultGroundAtlasLayout: TGroundAtlasLayout;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(478);{$ENDIF}
  Result.GridCols   := 8;
  Result.GridRows   := 4;
  Result.TilePixels := 1024;
end;

function BuildCompositeIFS(Composite: TGroundCompositeMesh;
  const AUVAttrName, ANormalAttrName: string;
  ASolid, AKeepStandardUV: Boolean): TIndexedFaceSetNode;
var
  EntRef: TPoolVertexArray;
  VtRef:  TCompositeVertexArray;
  IRef:   TMeshIndexArray;
  MRef:   TMaterialIdArray;
  VC, TriCount, I, TriIdx: Integer;
  Positions: array of TVector3;
  Normals:   array of TVector3;
  UVs:       array of TVector2;
  CoordIdx:  array of LongInt;
  MatIdValues:  array of Single;
  UVValues:     array of Single;
  NormalValues: array of Single;
  PE: ^TPoolVertex;
  UVI: TVector2;
  CoordNode: TCoordinateNode;
  NormalNode: TNormalNode;
  TexCoordNode: TTextureCoordinateNode;
  MatIdAttr, UVAttr, NormalAttr: TFloatVertexAttributeNode;
begin
  Result := nil;
  if (Composite = nil) or (Composite.VertexCount = 0) or
     (Composite.TriangleCount = 0) then Exit;

  EntRef   := Composite.Pool.Entries;
  VtRef    := Composite.Verts;
  IRef     := Composite.Indices;
  MRef     := Composite.MaterialIds;
  VC       := Composite.VertexCount;
  TriCount := Composite.TriangleCount;

  Positions := nil; Normals := nil; UVs := nil; CoordIdx := nil;
  MatIdValues := nil; UVValues := nil; NormalValues := nil;
  SetLength(Positions,    VC);
  SetLength(Normals,      VC);
  if AKeepStandardUV then SetLength(UVs, VC);
  SetLength(MatIdValues,  VC);
  SetLength(UVValues,     VC * 2);
  SetLength(NormalValues, VC * 3);
  SetLength(CoordIdx,     TriCount * 4);

  for I := 0 to VC - 1 do
  begin
    PE  := @EntRef[VtRef[I].PoolIdx];
    UVI := VtRef[I].UV;
    Positions[I]   := PE^.Position;
    Normals[I]     := PE^.Normal;
    if AKeepStandardUV then UVs[I] := UVI;
    MatIdValues[I] := MRef[I];
    UVValues[I * 2]     := UVI.X;
    UVValues[I * 2 + 1] := UVI.Y;
    NormalValues[I * 3]     := PE^.Normal.X;
    NormalValues[I * 3 + 1] := PE^.Normal.Y;
    NormalValues[I * 3 + 2] := PE^.Normal.Z;
  end;

  for TriIdx := 0 to TriCount - 1 do
  begin
    CoordIdx[TriIdx * 4    ] := LongInt(IRef[TriIdx * 3    ]);
    CoordIdx[TriIdx * 4 + 1] := LongInt(IRef[TriIdx * 3 + 1]);
    CoordIdx[TriIdx * 4 + 2] := LongInt(IRef[TriIdx * 3 + 2]);
    CoordIdx[TriIdx * 4 + 3] := -1;
  end;

  CoordNode := TCoordinateNode.Create;
  AssignStaticField(CoordNode.FdPoint, Positions);
  NormalNode := TNormalNode.Create;
  AssignStaticField(NormalNode.FdVector, Normals);
  TexCoordNode := nil;
  if AKeepStandardUV then
  begin
    TexCoordNode := TTextureCoordinateNode.Create;
    AssignStaticField(TexCoordNode.FdPoint, UVs);
  end;

  Result := TIndexedFaceSetNode.Create;
  Result.Coord           := CoordNode;
  Result.Normal          := NormalNode;
  Result.NormalPerVertex := True;
  Result.Solid           := ASolid;
  Result.TexCoord        := TexCoordNode;
  AssignStaticField(Result.FdCoordIndex, CoordIdx);

  MatIdAttr := TFloatVertexAttributeNode.Create;
  MatIdAttr.NameField     := 'materialId';
  MatIdAttr.NumComponents := 1;
  AssignStaticField(MatIdAttr.FdValue, MatIdValues);

  UVAttr := TFloatVertexAttributeNode.Create;
  UVAttr.NameField     := AUVAttrName;
  UVAttr.NumComponents := 2;
  AssignStaticField(UVAttr.FdValue, UVValues);

  NormalAttr := TFloatVertexAttributeNode.Create;
  NormalAttr.NameField     := ANormalAttrName;
  NormalAttr.NumComponents := 3;
  AssignStaticField(NormalAttr.FdValue, NormalValues);

  Result.SetAttrib([MatIdAttr, UVAttr, NormalAttr]);
end;

constructor TGroundAtlas.Create(const ALayout: TGroundAtlasLayout);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1162);{$ENDIF}
  inherited Create(ALayout, [acDiffuse, acNormal, acMask]);
  for I := 0 to GROUND_MAT_COUNT - 1 do
  begin
    FUVScales[I]   := GROUND_MATERIALS[I].UVScale;
    FFillColors[I] := GROUND_MATERIALS[I].FallbackColor;
    FRoughness[I]  := GROUND_MATERIALS[I].Roughness;
    FMetallic[I]   := GROUND_MATERIALS[I].Metallic;
    FZIndex[I]     := GROUND_MATERIALS[I].ZIndex;
    FTexRandom[I].X := GROUND_MATERIALS[I].TexRandom.BlockTiles;
    FTexRandom[I].Y := GROUND_MATERIALS[I].TexRandom.Shift;
    FTexRandom[I].Z := GROUND_MATERIALS[I].TexRandom.Rotate;
  end;
end;

function TGroundAtlas.LogPrefix: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1499);{$ENDIF}
  Result := 'GroundAtlas';
end;

function TGroundAtlas.CacheFileName(Ch: TAtlasChannel): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1500);{$ENDIF}
  { Имена прежнего SaveToCache — существующие дисковые кэши валидны. }
  case Ch of
    acDiffuse: Result := 'ground_atlas.png';
    acNormal:  Result := 'ground_atlas_n.png';
    acMask:    Result := 'ground_atlas_m.png';
  else
    Result := 'ground_atlas_unknown.png';
  end;
end;

function TGroundAtlas.BuildSignature: string;
var i: Integer;
begin
  Result := Format('GROUND;GRASS_TOP=5;L=%dx%dx%d;N=%d',
    [Layout.GridCols, Layout.GridRows, Layout.TilePixels, GROUND_MAT_COUNT]);
  for i := 0 to GROUND_MAT_COUNT - 1 do
    with GROUND_MATERIALS[i] do
      Result := Result + Format('|%s,%s,%s,%s,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f',
        [Name, TexturePath, NormalPath, MaskPath, SetFolder,
         BlendColor.X, BlendColor.Y, BlendColor.Z,
         UVScale, Roughness, Metallic]);
end;

procedure TGroundAtlas.FillCellSolid(MatId: TGroundMaterialId;
  const Color: TVector3);
var
  C: TVector4Byte;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(481);{$ENDIF}
  C.X := Round(Color.X * 255);
  C.Y := Round(Color.Y * 255);
  C.Z := Round(Color.Z * 255);
  C.W := 255;
  inherited FillCellSolid(acDiffuse, MatId, C);
end;

{ Neutral cell on the normal channel: (R=128, G=128, B=255) → (0,0,1). }
procedure TGroundAtlas.FillNormalCellNeutral(MatId: TGroundMaterialId);
var
  C: TVector4Byte;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(482);{$ENDIF}
  C.X := 128; C.Y := 128; C.Z := 255; C.W := 255;
  inherited FillCellSolid(acNormal, MatId, C);
end;

procedure TGroundAtlas.TintCellDiffuseRGB(MatId: TGroundMaterialId;
  const C: TVector3);
var
  Img: TRGBAlphaImage;
  X0, Y0, x, y, TP, r, g, b: Integer;
  P: PVector4Byte;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1501);{$ENDIF}
  Img := ChannelImage(acDiffuse);
  if Img = nil then Exit;
  { (1,1,1) → no tint, skip the per-texel loop entirely. }
  if (Abs(C.X - 1.0) < 1e-4) and (Abs(C.Y - 1.0) < 1e-4)
     and (Abs(C.Z - 1.0) < 1e-4) then Exit;

  TP := Layout.TilePixels;
  X0 := CellRectX(MatId);
  Y0 := CellRectY(MatId);
  for y := Y0 to Y0 + TP - 1 do
    for x := X0 to X0 + TP - 1 do
    begin
      P := PVector4Byte(Img.PixelPtr(x, y));
      r := Round(P^.X * C.X);  if r > 255 then r := 255 else if r < 0 then r := 0;
      g := Round(P^.Y * C.Y);  if g > 255 then g := 255 else if g < 0 then g := 0;
      b := Round(P^.Z * C.Z);  if b > 255 then b := 255 else if b < 0 then b := 0;
      P^.X := Byte(r);  P^.Y := Byte(g);  P^.Z := Byte(b);
      { P^.W (alpha) left as-is }
    end;
end;

function TGroundAtlas.LoadSetRGBA(const APath: string): TRGBAlphaImage;
var
  Img: TCastleImage;
begin
  Result := nil;
  if (APath = '') or (not FileExists(APath)) then Exit;
  Img := nil;
  try
    { Декод под общим замком: проходы грунтового атласа идут в параллельных
      воркерах BuildChannelsParallel (см. Osm3dImageCodecLock). }
    EnterImageCodec;
    try
      Img := LoadImage(APath);
    finally
      LeaveImageCodec;
    end;
  except
    Img := nil;
  end;
  if Img = nil then Exit;
  if Img is TRGBAlphaImage then
    Result := TRGBAlphaImage(Img)
  else
  begin
    { Быстрый Assign умеет не всё: 16-битные grayscale PNG (Roughness /
      Height / AO из PBR-наборов вроде Grass_2k) грузятся как
      TGrayscaleFloatImage и дают EImageAssignmentError. Неподдерживаемые
      классы уходят СРАЗУ во всеядный попиксельный AtlasCopyViaColors —
      без выброса исключения (отладчик не останавливается на first-chance);
      поддерживаемые — быстрым путём, с тем же фолбэком на всякий случай.
      Серые карты промоутятся репликацией (v,v,v,1) — маскостроителю,
      читающему R-канал, этого ровно достаточно. }
    if (Img is TRGBImage) or (Img is TGrayscaleImage) or
       (Img is TGrayscaleAlphaImage) or (Img is TRGBFloatImage) then
    begin
      Result := TRGBAlphaImage.Create(Img.Width, Img.Height);
      try
        Result.Assign(Img);
      except
        FreeAndNil(Result);
      end;
    end;
    if Result = nil then
      try
        Result := AtlasCopyViaColors(Img);
      except
        Result := nil;                 { совсем экзотика — канал пропустим }
      end;
    Img.Free;
  end;

  { Horizontal (landscape) source (Height < Width) -> rotate 90 deg so the
    texture runs along the road / tiles square in the atlas cell. Done once
    here so every channel of the set (BaseColor / Normal / Height / Roughness /
    AO) is turned the same way and stays aligned. 90 deg CW:
    dst(dx,dy) = src(dy, Hs-1-dx); to flip to CCW use src(Ws-1-dy, dx). }
  if (Result <> nil) and (Result.Height < Result.Width) then
    Result := Rotated90CW(Result);
end;

function TGroundAtlas.Rotated90CW(Src: TRGBAlphaImage): TRGBAlphaImage;
var
  Ws, Hs, dx, dy: Integer;
begin
  Result := Src;
  if Src = nil then Exit;
  Ws := Integer(Src.Width);
  Hs := Integer(Src.Height);
  Result := TRGBAlphaImage.Create(Hs, Ws);   { dims swapped }
  try
    for dy := 0 to Ws - 1 do
      for dx := 0 to Hs - 1 do
        Result.Colors[dx, dy, 0] := Src.Colors[dy, Hs - 1 - dx, 0];
  except
    FreeAndNil(Result);
    Result := Src;                            { rotation failed -> keep original }
    Exit;
  end;
  Src.Free;                                   { rotated copy replaces the source }
end;

function TGroundAtlas.BuildNormalHeightImage(
  const ANormalPath, AHeightPath: string): TRGBAlphaImage;
var
  N, Hh: TRGBAlphaImage;
  X, Y:  Integer;
  NC, HC: TCastleColor;
  hv:    Single;
begin
  Result := nil;
  N := LoadSetRGBA(ANormalPath);
  if N = nil then Exit;
  Hh := LoadSetRGBA(AHeightPath);     { may be nil — then alpha stays neutral }
  try
    for Y := 0 to Integer(N.Height) - 1 do
      for X := 0 to Integer(N.Width) - 1 do
      begin
        NC := N.Colors[X, Y, 0];
        NC.Y := 1.0 - NC.Y;           { DirectX -> OpenGL green flip }
        if Hh <> nil then
        begin
          HC := Hh.Colors[
            Trunc(X / Integer(N.Width)  * Integer(Hh.Width  - 1)),
            Trunc(Y / Integer(N.Height) * Integer(Hh.Height - 1)), 0];
          hv := (HC.X + HC.Y + HC.Z) / 3.0;
        end
        else
          hv := 0.5;                  { no height -> NEUTRAL: packed Height alpha
                                        defaults to 0.5 (mid-grey) when a set
                                        has no Height map. }
        N.Colors[X, Y, 0] := Vector4(NC.X, NC.Y, NC.Z, hv);
      end;
    Result := N;
    N := nil;                         { ownership handed to caller }
  finally
    if Hh <> nil then Hh.Free;
    if N <> nil then N.Free;          { only reached on an exception path }
  end;
end;

function TGroundAtlas.BuildMaskSetImage(const ARoughPath, AAOPath: string;
  AMetalByte: Byte): TRGBAlphaImage;
var
  R, A, Base: TRGBAlphaImage;
  X, Y, BW, BH: Integer;
  RC, AC: TCastleColor;
  rv, av, mv: Single;
begin
  Result := nil;
  R := LoadSetRGBA(ARoughPath);       { may be nil }
  A := LoadSetRGBA(AAOPath);          { may be nil }
  try
    if R <> nil then
    begin
      BW := Integer(R.Width); BH := Integer(R.Height);
    end
    else if A <> nil then
    begin
      BW := Integer(A.Width); BH := Integer(A.Height);
    end
    else
      Exit;                           { nothing to pack }

    Base := TRGBAlphaImage.Create(BW, BH);
    mv := AMetalByte / 255.0;
    for Y := 0 to BH - 1 do
      for X := 0 to BW - 1 do
      begin
        if R <> nil then
        begin
          RC := R.Colors[X, Y, 0];
          rv := RC.X;                 { roughness is grayscale — R channel }
        end
        else
          rv := 1.0;
        if A <> nil then
        begin
          AC := A.Colors[
            Trunc(X / BW * Integer(A.Width  - 1)),
            Trunc(Y / BH * Integer(A.Height - 1)), 0];
          av := (AC.X + AC.Y + AC.Z) / 3.0;
        end
        else
          av := 1.0;                  { no AO -> 1.0 (no occlusion) }
        Base.Colors[X, Y, 0] := Vector4(rv, mv, av, 1.0);
      end;
    Result := Base;
  finally
    if R <> nil then R.Free;
    if A <> nil then A.Free;
  end;
end;

procedure TGroundAtlas.LogSetReport(AMatId: Integer;
  const AMatName, ASetFolder: string; const ASet: TPBRTextureSet;
  LogProc: TLogProc);

  function Line(const ALabel, APath: string): string;
  var W, H: Integer; Img: TCastleImage; Dim: string;
  begin
    if APath = '' then
    begin
      Result := Format('      %-10s = (none)', [ALabel]);
      Exit;
    end;
    if not FileExists(APath) then
    begin
      Result := Format('      %-10s = %s  [MISSING FILE]', [ALabel, APath]);
      Exit;
    end;
    { probe dimensions (cheap enough at startup) + portrait/landscape flag }
    Dim := '';
    Img := nil;
    try
      EnterImageCodec;
      try
        Img := LoadImage(APath);
      finally
        LeaveImageCodec;
      end;
      if Img <> nil then
      begin
        W := Integer(Img.Width); H := Integer(Img.Height);
        if H < W then
          Dim := Format(' %dx%d (landscape->ROTATED 90)', [W, H])
        else if H > W then
          Dim := Format(' %dx%d (portrait)', [W, H])
        else
          Dim := Format(' %dx%d', [W, H]);
      end;
    except
      Dim := ' [LOAD FAILED]';
    end;
    if Img <> nil then Img.Free;
    Result := Format('      %-10s = %s  [exists]%s', [ALabel, APath, Dim]);
  end;

var
  Folder: string;
  SR:     TSearchRec;
  AnyFile: Boolean;
begin
  if not Assigned(LogProc) then Exit;
  Folder := SURFACES_TEX_DIR + ASetFolder;
  LogProc(Format('  GroundAtlas SET mat %d "%s": folder="%s" dirExists=%s',
    [AMatId, AMatName, Folder, BoolToStr(DirectoryExists(Folder), True)]));

  { Raw directory listing — the actual filenames on disk, so naming/extension
    mismatches against FindTextures are visible right here in the log. }
  LogProc('      RAW files on disk:');
  AnyFile := False;
  if FindFirst(IncludeTrailingPathDelimiter(Folder) + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) = 0 then
      begin
        LogProc(Format('        %s  (%d bytes)', [SR.Name, SR.Size]));
        AnyFile := True;
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  if not AnyFile then
    LogProc('        <no files — folder empty or path wrong>');

  LogProc('      FindTextures matched:');
  LogProc(Line('BaseColor', ASet.BaseColor));
  LogProc(Line('Normal',    ASet.Normal));
  LogProc(Line('Roughness', ASet.Roughness));
  LogProc(Line('Height',    ASet.Height));
  LogProc(Line('AO',        ASet.AO));
  LogProc(Line('Mask',      ASet.Mask));
  if (ASet.Height = '') then
    LogProc('      -> Height NOT matched: normal.alpha=0.5 (neutral).');
  if (ASet.AO = '') then
    LogProc('      -> AO NOT matched: mask.b=255 (no ambient occlusion).');
  if (ASet.Normal = '') then
    LogProc('      -> Normal NOT matched: cell stays flat (no normal mapping).');
  if (ASet.Roughness = '') then
    LogProc('      -> Roughness NOT matched: mask.R=const (no per-texel gloss).');
end;

function TGroundAtlas.FillGrassTopCell(MatId: Integer; const APath: string): Boolean;
var
  Img: TRGBAlphaImage;
  P: PVector4Byte;
  I, Kind: Integer;
  Alpha: Single;
  Background: TVector3;
  Red, Green, Blue, Weight: Double;
  Linear: array[0..255] of Single;
begin
  Result := False;
  if Pos('procedural-grass/', APath) = 0 then Exit;
  Kind := -1;
  for I := 0 to GRASS_SPECIES_COUNT-1 do
    if ExtractFileName(APath) = GrassName(I)+'-top.png' then begin Kind := I; Break; end;
  if Kind < 0 then Exit;
  Img := LoadSetRGBA(APath);
  if Img = nil then Exit;
  try
    for I := 0 to 255 do Linear[I] := Power(I/255.0, 2.2);
    { Derive the background from this bake, so editor color changes also
      affect the base. Alpha-weighted linear color excludes transparent black. }
    Red := 0; Green := 0; Blue := 0; Weight := 0;
    P := PVector4Byte(Img.RawPixels);
    for I := 0 to Img.Width*Img.Height-1 do
    begin
      Alpha := P^.W/255.0;
      Red := Red+Linear[P^.X]*Alpha;
      Green := Green+Linear[P^.Y]*Alpha;
      Blue := Blue+Linear[P^.Z]*Alpha;
      Weight := Weight+Alpha;
      Inc(P);
    end;
    if Weight <= 0.0001 then Exit;
    Background := Vector3(Red/Weight*0.5, Green/Weight*0.5, Blue/Weight*0.5);
    P := PVector4Byte(Img.RawPixels);
    for I := 0 to Img.Width*Img.Height-1 do
    begin
      Alpha := P^.W/255.0;
      P^.X := Round(255*Power(Linear[P^.X]*Alpha+Background.X*(1-Alpha),1/2.2));
      P^.Y := Round(255*Power(Linear[P^.Y]*Alpha+Background.Y*(1-Alpha),1/2.2));
      P^.Z := Round(255*Power(Linear[P^.Z]*Alpha+Background.Z*(1-Alpha),1/2.2));
      P^.W := 255;
      Inc(P);
    end;
    Result := FillCellFromImage(acDiffuse, MatId, Img);
  finally Img.Free; end;
end;

procedure TGroundAtlas.BuildImage(LogProc: TLogProc);
var
  MatId:   TGroundMaterialId;
  Desc:    TGroundMaterialDesc;
  PNGPath: string;
  Loaded:  Boolean;
  Loadeds: Integer;
  Img:     TRGBAlphaImage;
  P:       PVector4Byte;
  pxi:     Integer;
  PbrSet:  TPBRTextureSet;
  DiffImg: TRGBAlphaImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(484);{$ENDIF}
  Loadeds := 0;
  for MatId := 0 to GROUND_MAT_COUNT - 1 do
  begin
    Desc := GROUND_MATERIALS[MatId];

    { Solid-fill first so empty/missing slots still have valid pixels. }
    FillCellSolid(MatId, Desc.FallbackColor);

    { cgbookcase set folder: load BaseColor through LoadSetRGBA so the same
      portrait->90deg rotation as the other channels is applied, then blit it.
      Falls back to the legacy TexturePath if the set has no BaseColor. }
    if Desc.SetFolder <> '' then
    begin
      PbrSet := TPBRTextureProcessor.FindTextures(SURFACES_TEX_DIR + Desc.SetFolder);
      LogSetReport(MatId, Desc.Name, Desc.SetFolder, PbrSet, LogProc);
      if PbrSet.BaseColor <> '' then
      begin
        DiffImg := LoadSetRGBA(PbrSet.BaseColor);
        if DiffImg <> nil then
        begin
          Loaded := FillCellFromImage(acDiffuse, MatId, DiffImg);
          DiffImg.Free;
        end
        else
          Loaded := False;
        if Loaded then
        begin
          TintCellDiffuseRGB(MatId, Desc.BlendColor);
          Inc(Loadeds);
        end
        else if Assigned(LogProc) then
          LogProc(Format('  GroundAtlas: set %s BaseColor unreadable (mat %d "%s") -> fallback colour',
            [Desc.SetFolder, MatId, Desc.Name]));
        Continue;
      end;
    end;

    if Desc.TexturePath = '' then Continue;
    PNGPath := SURFACES_TEX_DIR + Desc.TexturePath;

    { Sand/dirt road diffuse PNGs have alpha-feathered cutout borders. Lay an
      opaque grass base into the cell first, then alpha-blend the road over it,
      so the feathered edges fade into grass instead of showing through (the
      diffuse atlas is forced fully opaque after the loop). }
    if (MatId = GROUND_MAT_ROAD_SAND) or (MatId = GROUND_MAT_ROAD_DIRT) then
    begin
      FillGrassTopCell(MatId, SURFACES_TEX_DIR + GROUND_MATERIALS[GROUND_MAT_TERRAIN].TexturePath);
      Loaded := BlendCellInteriorFromPNG(acDiffuse, MatId, PNGPath);
    end
    else if Pos('procedural-grass/', Desc.TexturePath) = 1 then
      Loaded := FillGrassTopCell(MatId, PNGPath)
    else
      Loaded := FillCellFromPNG(acDiffuse, MatId, PNGPath);

    if Loaded then
    begin
      { bake the material's blend tint into its diffuse cell }
      TintCellDiffuseRGB(MatId, Desc.BlendColor);
      Inc(Loadeds);
    end
    else if Assigned(LogProc) then
      LogProc(Format('  GroundAtlas: missing %s (mat %d "%s") -> fallback colour',
        [PNGPath, MatId, Desc.Name]));
  end;

  { Ground is fully opaque. The sand/dirt road PNGs were the only source of
    sub-255 alpha (their feathered cutout borders); with grass now backing
    them, clear the whole diffuse alpha to 255 so nothing shows through and the
    renderer can treat the atlas as opaque — no per-fragment alpha test/blend. }
  Img := ChannelImage(acDiffuse);
  if Img <> nil then
  begin
    P := PVector4Byte(Img.RawPixels);
    for pxi := 0 to Img.Width * Img.Height - 1 do
    begin
      P^.W := 255;
      Inc(P);
    end;
  end;

  if Assigned(LogProc) and (Img <> nil) then
    LogProc(Format('  GroundAtlas: %dx%d cells (%dx%d px), %d PNG loaded',
      [Layout.GridCols, Layout.GridRows,
       Img.Width, Img.Height, Loadeds]));
end;

procedure TGroundAtlas.BuildNormalImage(LogProc: TLogProc);
var
  MatId:   TGroundMaterialId;
  Desc:    TGroundMaterialDesc;
  PNGPath: string;
  Loaded:  Boolean;
  Loadeds: Integer;
  PbrSet:  TPBRTextureSet;
  NHImg:   TRGBAlphaImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(485);{$ENDIF}
  EnsureChannelImage(acNormal);

  Loadeds := 0;
  for MatId := 0 to GROUND_MAT_COUNT - 1 do
  begin
    Desc := GROUND_MATERIALS[MatId];

    { Neutral fill first so every cell has valid data even on missing PNG. }
    FillNormalCellNeutral(MatId);

    { cgbookcase set: build a DirectX->OpenGL normal with Height packed into
      alpha, in memory, and blit it into the cell. }
    if Desc.SetFolder <> '' then
    begin
      PbrSet := TPBRTextureProcessor.FindTextures(SURFACES_TEX_DIR + Desc.SetFolder);
      NHImg  := BuildNormalHeightImage(PbrSet.Normal, PbrSet.Height);
      if NHImg <> nil then
      begin
        Loaded := FillCellFromImage(acNormal, MatId, NHImg);
        if Assigned(LogProc) then
          LogProc(Format('  GroundAtlas normal mat %d "%s": normal=%s height=%s -> %dx%d packed',
            [MatId, Desc.Name,
             BoolToStr(PbrSet.Normal <> '', 'yes', 'NO'),
             BoolToStr(PbrSet.Height <> '', 'yes(alpha)', 'NO(alpha=0.5)'),
             NHImg.Width, NHImg.Height]));
        NHImg.Free;
      end
      else
        Loaded := False;
      if Loaded then
        Inc(Loadeds)
      else if Assigned(LogProc) then
        LogProc(Format('  GroundAtlas normal: set %s has no usable normal (mat %d "%s") -> neutral flat',
          [Desc.SetFolder, MatId, Desc.Name]));
      Continue;
    end;

    if Desc.NormalPath = '' then Continue;

    PNGPath := SURFACES_TEX_DIR + Desc.NormalPath;
    Loaded  := FillCellFromPNG(acNormal, MatId, PNGPath);
    if Loaded then
      Inc(Loadeds)
    else if Assigned(LogProc) then
      LogProc(Format('  GroundAtlas normal: missing %s (mat %d "%s") -> neutral flat',
        [PNGPath, MatId, Desc.Name]));
  end;

  if Assigned(LogProc) then
    LogProc(Format('  GroundAtlas normal: %dx%d cells, %d normal PNG loaded',
      [Layout.GridCols, Layout.GridRows, Loadeds]));
end;

{ Mask atlas. R = per-texel ROUGHNESS, G = metallic (documentation; the
  shader reads metallic from u_ground_metallic[]), B = AMBIENT OCCLUSION
  (1.0/255 = no occlusion, so legacy maskless materials are unaffected).
  Classic materials: cells WITH a MaskPath take roughness from the PNG R;
  maskless cells are solid-filled with the constant Roughness. cgbookcase
  set materials: Roughness->R, constant metallic->G, AO->B are repacked into
  one in-memory image and blitted. Built like the normal atlas (same node
  types) so CGE samples it raw (no sRGB decode). }
procedure TGroundAtlas.BuildMaskImage(LogProc: TLogProc);
var
  MatId:   TGroundMaterialId;
  Desc:    TGroundMaterialDesc;
  PNGPath: string;
  Loaded:  Boolean;
  Loadeds: Integer;
  RI, MI: Integer;
  C: TVector4Byte;
  PbrSet:  TPBRTextureSet;
  MImg:    TRGBAlphaImage;
  MaskImg: TRGBAlphaImage;
  PP:      PVector4Byte;
  X0, Y0, TP, xx, yy: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1325);{$ENDIF}
  EnsureChannelImage(acMask);

  Loadeds := 0;
  for MatId := 0 to GROUND_MAT_COUNT - 1 do
  begin
    Desc := GROUND_MATERIALS[MatId];

    { Constant fill first (R=roughness, G=metallic, B=255=no AO). Guarantees
      valid roughness/AO for maskless materials and on a missing-map fallback. }
    RI := Round(Desc.Roughness * 255.0);
    if RI < 0 then RI := 0 else if RI > 255 then RI := 255;
    MI := Round(Desc.Metallic * 255.0);
    if MI < 0 then MI := 0 else if MI > 255 then MI := 255;
    C.X := RI; C.Y := MI; C.Z := 255; C.W := 255;
    inherited FillCellSolid(acMask, MatId, C);

    { cgbookcase set: repack Roughness/Metallic/AO into one cell. }
    if Desc.SetFolder <> '' then
    begin
      PbrSet := TPBRTextureProcessor.FindTextures(SURFACES_TEX_DIR + Desc.SetFolder);
      MImg   := BuildMaskSetImage(PbrSet.Roughness, PbrSet.AO, Byte(MI));
      if MImg <> nil then
      begin
        if FillCellFromImage(acMask, MatId, MImg) then Inc(Loadeds);
        if Assigned(LogProc) then
          LogProc(Format('  GroundAtlas mask  mat %d "%s": roughness=%s AO=%s -> %dx%d packed (R=rough,G=metal,B=AO)',
            [MatId, Desc.Name,
             BoolToStr(PbrSet.Roughness <> '', 'yes', 'NO(R=const)'),
             BoolToStr(PbrSet.AO <> '', 'yes(B)', 'NO(B=255,no AO)'),
             MImg.Width, MImg.Height]));
        MImg.Free;
      end
      else if Assigned(LogProc) then
        LogProc(Format('  GroundAtlas mask: set %s has no roughness/AO (mat %d "%s") -> constant',
          [Desc.SetFolder, MatId, Desc.Name]));
      Continue;
    end;

    if Desc.MaskPath = '' then Continue;

    PNGPath := SURFACES_TEX_DIR + Desc.MaskPath;
    Loaded  := FillCellFromPNG(acMask, MatId, PNGPath);
    if Loaded then
    begin
      { Classic mask PNGs authored only R (roughness); their B is 0. The PNG
        blit overwrote the whole cell, so restore B=255 (= no AO) — otherwise
        the shader's ambient *= mask.b would zero ambient and render these
        materials almost black. R (roughness) from the PNG is kept. }
      MaskImg := ChannelImage(acMask);
      if MaskImg <> nil then
      begin
        X0 := CellRectX(MatId);
        Y0 := CellRectY(MatId);
        TP := Layout.TilePixels;
        for yy := 0 to TP - 1 do
        begin
          PP := PVector4Byte(MaskImg.PixelPtr(X0, Y0 + yy));
          for xx := 0 to TP - 1 do
          begin
            PP^.Z := 255;
            Inc(PP);
          end;
        end;
      end;
      Inc(Loadeds);
    end
    else if Assigned(LogProc) then
      LogProc(Format('  GroundAtlas mask: missing %s (mat %d "%s") -> constant roughness',
        [PNGPath, MatId, Desc.Name]));
  end;

  if Assigned(LogProc) then
    LogProc(Format('  GroundAtlas mask: %dx%d cells, %d mask PNG loaded',
      [Layout.GridCols, Layout.GridRows, Loadeds]));
end;

function TGroundAtlas.SaveToCache(const ACacheDir: string;
  LogProc: TLogProc): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(486);{$ENDIF}
  { Legacy-контракт этого атласа: достроить недостающие normal/mask
    перед записью (база требует, чтобы все заявленные каналы были
    построены). Diffuse база проверит сама. }
  if Image <> nil then
  begin
    if ChannelImage(acNormal) = nil then
      BuildNormalImage(LogProc);   { ensure both channels exist before write }
    if ChannelImage(acMask) = nil then
      BuildMaskImage(LogProc);     { ensure the mask/roughness atlas too }
  end;
  Result := inherited SaveToCache(ACacheDir, LogProc);
end;

function TGroundAtlas.UVScale(MatId: TGroundMaterialId): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(488);{$ENDIF}
  if (MatId < 0) or (MatId >= GROUND_MAT_COUNT) then
    Result := 1
  else
    Result := FUVScales[MatId];
end;

function TGroundAtlas.FallbackColor(MatId: TGroundMaterialId): TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(489);{$ENDIF}
  if (MatId < 0) or (MatId >= GROUND_MAT_COUNT) then
  begin
    Result.X := 0.5; Result.Y := 0.5; Result.Z := 0.5;
  end
  else
    Result := FFillColors[MatId];
end;

function TGroundAtlas.Roughness(MatId: TGroundMaterialId): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(490);{$ENDIF}
  if (MatId < 0) or (MatId >= GROUND_MAT_COUNT) then
    Result := 0.90
  else
    Result := FRoughness[MatId];
end;

function TGroundAtlas.Metallic(MatId: TGroundMaterialId): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(491);{$ENDIF}
  if (MatId < 0) or (MatId >= GROUND_MAT_COUNT) then
    Result := 0.0
  else
    Result := FMetallic[MatId];
end;

function TGroundAtlas.ZIndex(MatId: TGroundMaterialId): Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(492);{$ENDIF}
  if (MatId < 0) or (MatId >= GROUND_MAT_COUNT) then
    Result := 0
  else
    Result := FZIndex[MatId];
end;

function TGroundAtlas.TexRandom(MatId: TGroundMaterialId): TVector3;
begin
  if (MatId < 0) or (MatId >= GROUND_MAT_COUNT) then
  begin
    Result.X := 0.0; Result.Y := 0.0; Result.Z := 0.0;
  end
  else
    Result := FTexRandom[MatId];
end;

constructor TGroundCompositeMesh.Create(const AName: string;
  ANrmMinDot: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1502);{$ENDIF}
  inherited Create;
  { NrmMinDot = -1.0 => position-only weld: any two coincident verts merge
    regardless of normal. That is what guarantees leveling auto-follow — a
    road-edge and the ground-edge at the same point become ONE pool entry,
    so moving it moves both. Safe here because the ground composite is a
    height field (no opposed/back-facing coincidences); shading normals are
    recomputed in the leveling pass. }
  { 1 mm weld tolerance — position-only. INTENTIONALLY fine: a coarse 0.1 m
    weld collapses every finely-tessellated triangle whose two close verts fall
    within it (road ribbons, InsertCollinearNodes noding), turning them into
    zero-area = invisible see-through holes (this is NOT visible in the topology
    audit, since a collapsed tri is not an "open edge"). At 1 mm only truly
    coincident verts merge, so the ribbon stays connected (its shared verts are
    at distance 0) while thin triangles keep their area. The cross-layer
    boundary verts the carve emits up to ~0.1 m apart are deliberately left
    UN-welded here and closed afterwards by StitchBoundaryGaps, a second weld
    restricted to open-edge endpoints (which a coarse base weld cannot be). }
  FPool := TVertexPool.Create(1e-3, ANrmMinDot, 1 shl 16);
  FVertCount  := 0;
  FIndexCount := 0;
  SetLength(FVerts,        0);
  SetLength(FMaterialIds,  0);
  SetLength(FIndices,      0);
end;

destructor TGroundCompositeMesh.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1503);{$ENDIF}
  FPool.Free;
  SetLength(FVerts,        0);
  SetLength(FMaterialIds,  0);
  SetLength(FIndices,      0);
  inherited Destroy;
end;

function TGroundCompositeMesh.VertexCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1504);{$ENDIF}
  Result := FVertCount;
end;

function TGroundCompositeMesh.TriangleCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1505);{$ENDIF}
  Result := FIndexCount div 3;
end;

function TGroundCompositeMesh.PositionOf(I: Integer): TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1506);{$ENDIF}
  Result := FPool.PositionOf(FVerts[I].PoolIdx);
end;

function TGroundCompositeMesh.NormalOf(I: Integer): TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1507);{$ENDIF}
  Result := FPool.NormalOf(FVerts[I].PoolIdx);
end;

function TGroundCompositeMesh.UVOf(I: Integer): TVector2;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1508);{$ENDIF}
  Result := FVerts[I].UV;
end;

function TGroundCompositeMesh.OsmIdOf(I: Integer): Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1509);{$ENDIF}
  Result := FVerts[I].OsmId;
end;

function TGroundCompositeMesh.MatIdOf(I: Integer): TGroundMaterialId;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1510);{$ENDIF}
  Result := FMaterialIds[I];
end;

procedure TGroundCompositeMesh.ReserveForSlice(AVertCount, ATriCount: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1511);{$ENDIF}
  { Always precedes any append (per the call sequence), so the pool is
    empty here — recreate sized to this slice's upper bound. Position-only
    weld at 1 mm (see Create — fine on purpose; boundaries are closed later
    by StitchBoundaryGaps). }
  FPool.Free;
  FPool := TVertexPool.Create(1e-3, -1.0, AVertCount);
  if Length(FVerts)       < AVertCount     then SetLength(FVerts,       AVertCount);
  if Length(FMaterialIds) < AVertCount     then SetLength(FMaterialIds, AVertCount);
  if Length(FIndices)     < ATriCount * 3  then SetLength(FIndices,     ATriCount * 3);
  if Length(FTriTileKeys) < ATriCount      then SetLength(FTriTileKeys, ATriCount);
end;

function TGroundCompositeMesh.AddCompVert(APoolIdx: Integer; const AUV: TVector2;
  AOsmId: Int64; AMatId: TGroundMaterialId): Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1512);{$ENDIF}
  if FVertCount >= Length(FVerts) then
  begin
    SetLength(FVerts,       (FVertCount + 1) * 2);
    SetLength(FMaterialIds, Length(FVerts));
  end;
  Result := FVertCount;
  FVerts[Result].PoolIdx := APoolIdx;
  FVerts[Result].UV      := AUV;
  FVerts[Result].OsmId   := AOsmId;
  FMaterialIds[Result]   := AMatId;
  Inc(FVertCount);
end;

function TGroundCompositeMesh.AppendVertex(const V: TMeshVertex;
  AMatId: TGroundMaterialId): Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1513);{$ENDIF}
  { Tiler path: pool (pos,normal), then append a composite vertex. No
    compVert dedup here — the tiler maps each source compVert to one tile
    compVert exactly once; the pool still re-welds coincident positions. }
  Result := AddCompVert(FPool.Add(V.Position, V.Normal), V.UV, V.OsmId, AMatId);
end;

procedure TGroundCompositeMesh.AppendTriangle(I0, I1, I2: Integer; ATileKey: Int64);
var ti: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1514);{$ENDIF}
  if FIndexCount + 3 > Length(FIndices) then
    SetLength(FIndices, (FIndexCount + 3) * 2);
  FIndices[FIndexCount]     := Cardinal(I0);
  FIndices[FIndexCount + 1] := Cardinal(I1);
  FIndices[FIndexCount + 2] := Cardinal(I2);
  Inc(FIndexCount, 3);
  ti := (FIndexCount div 3) - 1;          { 0-based index of the triangle just added }
  if ti >= Length(FTriTileKeys) then
    SetLength(FTriTileKeys, (ti + 1) * 2 + 16);
  FTriTileKeys[ti] := ATileKey;
end;

procedure TGroundCompositeMesh.SetTriangle(ATri, I0, I1, I2: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1515);{$ENDIF}
  FIndices[ATri * 3]     := Cardinal(I0);
  FIndices[ATri * 3 + 1] := Cardinal(I1);
  FIndices[ATri * 3 + 2] := Cardinal(I2);
end;

function TGroundCompositeMesh.TriTileKeyOf(ATri: Integer): Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1516);{$ENDIF}
  if (ATri >= 0) and (ATri * 3 + 2 < FIndexCount)
     and (ATri < Length(FTriTileKeys)) then
    Result := FTriTileKeys[ATri]
  else
    Result := -1;
end;

procedure TGroundCompositeMesh.RemapPoolIndices(const ARemap: array of Integer);
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1517);{$ENDIF}
  for I := 0 to FVertCount - 1 do
    FVerts[I].PoolIdx := ARemap[FVerts[I].PoolIdx];
end;

procedure TGroundCompositeMesh.ReserveForRawMerge(AVertCount,ATriCount,APoolCount:Integer);
begin
  if (FVertCount<>0) or (FIndexCount<>0) or (FPool.Count<>0) then
    raise Exception.Create('Raw merge reservation requires an empty composite');
  SetLength(FVerts,AVertCount);SetLength(FMaterialIds,AVertCount);
  SetLength(FIndices,ATriCount*3);SetLength(FTriTileKeys,ATriCount);
  SetLength(FPool.FEntries,APoolCount);
end;

procedure TGroundCompositeMesh.AppendRawComposite(Src: TGroundCompositeMesh);
var
  poolOff, vOff, i, nTri: Integer;
begin
  if (Src = nil) or (Src.FVertCount = 0) then Exit;
  poolOff := FPool.AbsorbRaw(Src.FPool);
  vOff    := FVertCount;

  { composite verts (+ parallel material ids) }
  if Length(FVerts) < FVertCount + Src.FVertCount then
  begin
    SetLength(FVerts,       Max(FVertCount + Src.FVertCount, Length(FVerts)*2));
    SetLength(FMaterialIds, Length(FVerts));
  end;
  { composite verts: bulk-copy whole records, then offset PoolIdx only if the
    pool actually shifted (poolOff = 0 for the first sub-composite). }
  Move(Src.FVerts[0], FVerts[FVertCount], Src.FVertCount * SizeOf(FVerts[0]));
  Move(Src.FMaterialIds[0], FMaterialIds[FVertCount], Src.FVertCount * SizeOf(FMaterialIds[0]));
  if poolOff <> 0 then
    for i := 0 to Src.FVertCount - 1 do
      Inc(FVerts[FVertCount + i].PoolIdx, poolOff);
  Inc(FVertCount, Src.FVertCount);

  { triangles: bulk-copy indices, then offset to the new vert range; tile keys
    are a plain copy. }
  if Length(FIndices) < FIndexCount + Src.FIndexCount then
    SetLength(FIndices, Max(FIndexCount + Src.FIndexCount, Length(FIndices)*2));
  nTri := Src.FIndexCount div 3;
  if Length(FTriTileKeys) < (FIndexCount div 3) + nTri then
    SetLength(FTriTileKeys, Max((FIndexCount div 3) + nTri, Length(FTriTileKeys)*2));
  if Src.FIndexCount > 0 then
  begin
    Move(Src.FIndices[0], FIndices[FIndexCount], Src.FIndexCount * SizeOf(FIndices[0]));
    if vOff <> 0 then
      for i := 0 to Src.FIndexCount - 1 do
        FIndices[FIndexCount + i] := Cardinal(Integer(FIndices[FIndexCount + i]) + vOff);
  end;
  if nTri > 0 then
    Move(Src.FTriTileKeys[0], FTriTileKeys[FIndexCount div 3], nTri * SizeOf(FTriTileKeys[0]));
  Inc(FIndexCount, Src.FIndexCount);
end;

procedure TGroundCompositeMesh.TrimArrays;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1518);{$ENDIF}
  SetLength(FVerts,       FVertCount);
  SetLength(FMaterialIds, FVertCount);
  SetLength(FIndices,     FIndexCount);
  SetLength(FTriTileKeys, FIndexCount div 3);
end;

procedure TGroundCompositeMesh.KeepTriangles(const AKeep: array of Boolean);
var
  T, W: Integer;
begin
  { Уплотнение индексов и per-triangle ключей по маске (False = удалить).
    Вершины не трогаем — осиротевшие записи безвредны (индексируются только
    живые). Используется хирургией порталов туннелей: вырезает крутые
    треугольники подъёма композита, закрывающие устье. }
  W := 0;
  for T := 0 to (FIndexCount div 3) - 1 do
    if (T > High(AKeep)) or AKeep[T] then
    begin
      if W <> T then
      begin
        FIndices[W*3]   := FIndices[T*3];
        FIndices[W*3+1] := FIndices[T*3+1];
        FIndices[W*3+2] := FIndices[T*3+2];
        if T < Length(FTriTileKeys) then
          FTriTileKeys[W] := FTriTileKeys[T];
      end;
      Inc(W);
    end;
  FIndexCount := W * 3;
  SetLength(FIndices,     FIndexCount);
  SetLength(FTriTileKeys, W);
end;

constructor TGroundCompositeBuilder.Create(const AName: string;
  ANrmMinDot: Single);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1519);{$ENDIF}
  inherited Create;
  FComposite := TGroundCompositeMesh.Create(AName, ANrmMinDot);
  FFinalized := False;
  FLogProc   := nil;
  FAppendedMeshes := 0;
  FAppendedVerts  := 0;
  FAppendedTris   := 0;

  { 1<<20 buckets (~4 MB of Int32) — short chains even at several million
    compVerts. FVChainNext grows lazily with the composite vertex count. }
  FVMask := (1 shl 20) - 1;
  SetLength(FVHashHead, 1 shl 20);
  for I := 0 to High(FVHashHead) do FVHashHead[I] := -1;
  SetLength(FVChainNext, 0);
end;

destructor TGroundCompositeBuilder.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1167);{$ENDIF}
  { After Finalize ownership is with the caller and FComposite is nil. }
  if not FFinalized then
    FComposite.Free;
  inherited Destroy;
end;

{ Compact per-source log line. The previous version walked every vertex
  to compute a UV bbox + zero-UV count — for a 17M-vertex composite that
  cost ~2 s of repeated reads. UV diagnosis lives in the final composite
  summary; per-mesh name annotation here is enough for the timeline. }
procedure LogSourceMeshUVStats(Source: TMesh;
  MaterialId: TGroundMaterialId; LogProc: TLogProc);
var
  N: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(501);{$ENDIF}
  if (Source = nil) or not Assigned(LogProc) then Exit;
  N := Source.VertexCount;
  if N = 0 then
  begin
    LogProc(Format('  composite Append: name=%-22s matId=%2d (EMPTY mesh)',
      [Source.Name, MaterialId]));
    Exit;
  end;

  LogProc(Format('  composite Append: name=%-22s matId=%2d  verts=%6d tris=%6d',
    [Source.Name, MaterialId, N, Source.TriangleCount]));
end;

{$push}{$Q-}{$R-}
procedure TGroundCompositeMesh.WeldPoolExactLat;
var
  Map: array of Integer;      { хэш: слот -> индекс пула-канона }
  Keys: array of Int64;
  Remap: array of Integer;
  mask, slot, i, n: Integer;
  k: Int64;
  h: QWord;
  changed: Boolean;
begin
  n := FPool.Count;
  if n = 0 then Exit;
  mask := 1;
  while mask < n * 2 do mask := mask * 2;
  Dec(mask);
  SetLength(Map, mask + 1);
  SetLength(Keys, mask + 1);
  for slot := 0 to mask do Map[slot] := -1;
  SetLength(Remap, n);
  changed := False;
  for i := 0 to n - 1 do
  begin
    k := (Int64(Round(FPool.FEntries[i].Position.X * 64.0)) shl 32)
      or Int64(Cardinal(Round(FPool.FEntries[i].Position.Z * 64.0)));
    {$push}{$Q-}{$R-}
    h := QWord(k) * QWord($9E3779B97F4A7C15);
    {$pop}
    slot := Integer(LongWord(h shr 40)) and mask;
    while (Map[slot] >= 0) and (Keys[slot] <> k) do
      slot := (slot + 1) and mask;
    if Map[slot] < 0 then
    begin
      Map[slot] := i;
      Keys[slot] := k;
      Remap[i] := i;
    end
    else
    begin
      Remap[i] := Map[slot];
      changed := True;
    end;
  end;
  if not changed then Exit;
  for i := 0 to FVertCount - 1 do
    FVerts[i].PoolIdx := Remap[FVerts[i].PoolIdx];
end;

function TGroundCompositeBuilder.VertDedup(APoolIdx: Integer; const AUV: TVector2;
  AOsmId: Int64; AMatId: TGroundMaterialId): Integer;
var
  qu, qv: Int64;
  h:      QWord;
  bkt, j: Integer;
  LV: TCompositeVertexArray;
  LM: TMaterialIdArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1520);{$ENDIF}
  qu := Round(AUV.X * 1000000.0);
  qv := Round(AUV.Y * 1000000.0);

  { hash on (poolIdx, uv); matId excluded from the hash (verts differing
    only in matId — the cross-material boundary case — collide into one
    bucket and are separated by the equality test below; correct, just a
    couple extra chain steps there). }
  h := QWord($cbf29ce484222325);
  h := (h xor QWord(LongWord(APoolIdx))) * QWord($100000001b3);
  h := (h xor QWord(qu))                 * QWord($100000001b3);
  h := (h xor QWord(qv))                 * QWord($100000001b3);
  h := (h xor QWord(AOsmId))             * QWord($100000001b3);
  bkt := Integer(LongWord(h xor (h shr 32)) and LongWord(FVMask));

  { хойст ссылок: FComposite.FVerts/FMaterialIds в цикле цепочки — две
    косвенности и refcount на обращение; локальные ссылки берутся один раз }
  LV := FComposite.FVerts;
  LM := FComposite.FMaterialIds;
  j := FVHashHead[bkt];
  while j <> -1 do
  begin
    if (LV[j].PoolIdx = APoolIdx)
       and (Round(LV[j].UV.X * 1000000.0) = qu)
       and (Round(LV[j].UV.Y * 1000000.0) = qv)
       and (LV[j].OsmId = AOsmId)
       and (LM[j] = AMatId) then
      Exit(j);
    j := FVChainNext[j];
  end;

  Result := FComposite.AddCompVert(APoolIdx, AUV, AOsmId, AMatId);
  if Result >= Length(FVChainNext) then
    SetLength(FVChainNext, (Result + 1) * 2);
  FVChainNext[Result] := FVHashHead[bkt];
  FVHashHead[bkt]     := Result;
end;
{$pop}

procedure TGroundCompositeBuilder.Append(Source: TMesh;
  MaterialId: TGroundMaterialId);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1521);{$ENDIF}
  Append(Source, MaterialId, []);
end;

procedure TGroundCompositeBuilder.Append(Source: TMesh;
  MaterialId: TGroundMaterialId; const ASrcTriKeys: array of Int64);
var
  Remap: array of Integer;
  SrcV:  TMeshVertexArray;
  SrcI:  TMeshIndexArray;
  I, SV, ST: Integer;
  HasKeys: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1522);{$ENDIF}
  if FFinalized then
    raise EInvalidOperation.Create('TGroundCompositeBuilder.Append: already finalised');
  if (Source = nil) or (Source.VertexCount = 0) or
     (Source.TriangleCount = 0) then
  begin
    if Assigned(FLogProc) and (Source <> nil) then
      LogSourceMeshUVStats(Source, MaterialId, FLogProc);
    Exit;
  end;

  if Assigned(FLogProc) then
    LogSourceMeshUVStats(Source, MaterialId, FLogProc);

  SV := Source.VertexCount;
  ST := Source.TriangleCount;
  SrcV := Source.Vertices;     { trimmed snapshots — index locally, no getter churn }
  SrcI := Source.Indices;

  { Two-level dedup. Level 1: pool (pos+normal, proximity) -> poolIdx,
    welding coincident positions ACROSS materials. Level 2: VertDedup
    (poolIdx+uv+osmid+matId, exact) -> compVert. Together this subsumes the
    old per-mesh TMesh.Deduplicate weld and adds cross-material position
    sharing in one pass. }
  SetLength(Remap, SV);
  for I := 0 to SV - 1 do
    Remap[I] := VertDedup(FComposite.FPool.Add(SrcV[I].Position, SrcV[I].Normal),
                          SrcV[I].UV, SrcV[I].OsmId, MaterialId);

  HasKeys := Length(ASrcTriKeys) = ST;
  for I := 0 to ST - 1 do
    if HasKeys then
      FComposite.AppendTriangle(Remap[SrcI[I * 3]], Remap[SrcI[I * 3 + 1]],
                                Remap[SrcI[I * 3 + 2]], ASrcTriKeys[I])
    else
      FComposite.AppendTriangle(Remap[SrcI[I * 3]], Remap[SrcI[I * 3 + 1]],
                                Remap[SrcI[I * 3 + 2]]);

  Inc(FAppendedMeshes);
  Inc(FAppendedVerts, SV);   { input verts (pre-dedup); stored count is FVertCount }
  Inc(FAppendedTris,  ST);
end;

procedure TGroundCompositeBuilder.AppendStripInt(Source: TMesh;
  MaterialId: TGroundMaterialId; const ASrcTriKeys: array of Int64;
  zLo, zHi: Single);
var
  Remap:   array of Integer;
  SrcV:    TMeshVertexArray;
  SrcI:    TMeshIndexArray;
  I, SV, ST, a, b, c: Integer;
  cz:      Single;
  HasKeys: Boolean;

  function LatIdx(const V: TMeshVertex): Integer;
  var
    kx, kz: Int64;
  begin
    kx := Round(V.Position.X * 64.0);
    kz := Round(V.Position.Z * 64.0);
    Result := FComposite.FPool.AddLat(V.Position, V.Normal,
      (kx shl 32) or Int64(Cardinal(kz)));
  end;

begin
  if FFinalized then
    raise EInvalidOperation.Create('TGroundCompositeBuilder.AppendStripInt: already finalised');
  if (Source = nil) or (Source.VertexCount = 0) or
     (Source.TriangleCount = 0) then Exit;
  SV := Source.VertexCount;
  ST := Source.TriangleCount;
  SrcV := Source.Vertices;
  SrcI := Source.Indices;
  HasKeys := Length(ASrcTriKeys) = ST;
  SetLength(Remap, SV);
  for I := 0 to SV - 1 do Remap[I] := -1;
  for I := 0 to ST - 1 do
  begin
    a := Integer(SrcI[I * 3]);
    b := Integer(SrcI[I * 3 + 1]);
    c := Integer(SrcI[I * 3 + 2]);
    cz := (SrcV[a].Position.Z + SrcV[b].Position.Z + SrcV[c].Position.Z) * Single(1.0 / 3.0);
    if (cz < zLo) or (cz >= zHi) then Continue;
    if Remap[a] < 0 then
      Remap[a] := VertDedup(LatIdx(SrcV[a]), SrcV[a].UV, SrcV[a].OsmId, MaterialId);
    if Remap[b] < 0 then
      Remap[b] := VertDedup(LatIdx(SrcV[b]), SrcV[b].UV, SrcV[b].OsmId, MaterialId);
    if Remap[c] < 0 then
      Remap[c] := VertDedup(LatIdx(SrcV[c]), SrcV[c].UV, SrcV[c].OsmId, MaterialId);
    if HasKeys then
      FComposite.AppendTriangle(Remap[a], Remap[b], Remap[c], ASrcTriKeys[I])
    else
      FComposite.AppendTriangle(Remap[a], Remap[b], Remap[c]);
  end;
  Inc(FAppendedMeshes);
end;

procedure TGroundCompositeBuilder.AppendStrip(Source: TMesh;
  MaterialId: TGroundMaterialId; const ASrcTriKeys: array of Int64;
  zLo, zHi: Single);
var
  Remap:   array of Integer;
  SrcV:    TMeshVertexArray;
  SrcI:    TMeshIndexArray;
  I, SV, ST, a, b, c: Integer;
  cz:      Single;
  HasKeys: Boolean;
begin
  if FFinalized then
    raise EInvalidOperation.Create('TGroundCompositeBuilder.AppendStrip: already finalised');
  if (Source = nil) or (Source.VertexCount = 0) or
     (Source.TriangleCount = 0) then Exit;

  SV := Source.VertexCount;
  ST := Source.TriangleCount;
  SrcV := Source.Vertices;
  SrcI := Source.Indices;
  HasKeys := Length(ASrcTriKeys) = ST;

  { Lazy per-vertex weld: only vertices used by an in-strip triangle are
    pooled, so a vertex shared with a neighbouring strip is welded once per
    strip (the unwelded twin pair is the seam StitchBoundaryGaps closes). }
  SetLength(Remap, SV);
  for I := 0 to SV - 1 do Remap[I] := -1;

  for I := 0 to ST - 1 do
  begin
    a := Integer(SrcI[I * 3]);
    b := Integer(SrcI[I * 3 + 1]);
    c := Integer(SrcI[I * 3 + 2]);
    cz := (SrcV[a].Position.Z + SrcV[b].Position.Z + SrcV[c].Position.Z) * Single(1.0 / 3.0);
    if (cz < zLo) or (cz >= zHi) then Continue;

    if Remap[a] < 0 then
      Remap[a] := VertDedup(FComposite.FPool.Add(SrcV[a].Position, SrcV[a].Normal),
                            SrcV[a].UV, SrcV[a].OsmId, MaterialId);
    if Remap[b] < 0 then
      Remap[b] := VertDedup(FComposite.FPool.Add(SrcV[b].Position, SrcV[b].Normal),
                            SrcV[b].UV, SrcV[b].OsmId, MaterialId);
    if Remap[c] < 0 then
      Remap[c] := VertDedup(FComposite.FPool.Add(SrcV[c].Position, SrcV[c].Normal),
                            SrcV[c].UV, SrcV[c].OsmId, MaterialId);

    if HasKeys then
      FComposite.AppendTriangle(Remap[a], Remap[b], Remap[c], ASrcTriKeys[I])
    else
      FComposite.AppendTriangle(Remap[a], Remap[b], Remap[c]);
  end;

  Inc(FAppendedMeshes);
end;

function TGroundCompositeBuilder.Finalize(
  ALogProc: TLogProc): TGroundCompositeMesh;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1523);{$ENDIF}
  if FFinalized then
    raise EInvalidOperation.Create('TGroundCompositeBuilder.Finalize: already finalised');

  FComposite.TrimArrays;

  { Sanity: parallel matId array must equal compVert count — explicit assert
    so a caller bug can't turn into silent shader corruption. }
  Assert(Length(FComposite.FMaterialIds) = FComposite.FVertCount,
    Format('GroundComposite: materialIds (%d) != compVerts (%d)',
      [Length(FComposite.FMaterialIds), FComposite.FVertCount]));

  if Assigned(ALogProc) then
    ALogProc(Format('  GroundComposite: merged %d meshes -> %d compVerts, %d pool entries, %d tris',
      [FAppendedMeshes, FComposite.FVertCount, FComposite.FPool.Count,
       FComposite.TriangleCount]));

  Result := FComposite;
  FComposite := nil;
  FFinalized := True;
end;

constructor TVertexPool.Create(APosEps, ANrmMinDot: Single; AExpectedCount: Integer);
const
  POOL_CELL_MULT = 16.0;   { grid cell = 16 * weld radius }
var
  Buckets, I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1524);{$ENDIF}
  inherited Create;
  FCount     := 0;
  FPosEpsSq  := APosEps * APosEps;
  FPosEps    := APosEps;
  FNrmMinDot := ANrmMinDot;
  { Grid cell = POOL_CELL_MULT * weld radius. Larger cells make the 2*eps weld
    box land in a single cell almost always, so Add searches ~1 cell instead of
    a fixed 3x3x3 (27). The weld test still uses FPosEpsSq, so the welded result
    is identical — only the spatial-hash bucketing changes. 16x keeps cells far
    below the composite's non-coincident vertex spacing, so chains stay short. }
  FInvCell   := 1.0 / (APosEps * POOL_CELL_MULT);

  { buckets = next power of two >= 2*expected, clamped [4K .. 16M] }
  Buckets := 1 shl 12;
  while (Int64(Buckets) < Int64(AExpectedCount) * 2) and (Buckets < (1 shl 24)) do
    Buckets := Buckets shl 1;
  FMask := Buckets - 1;

  SetLength(FHashHead, Buckets);
  for I := 0 to Buckets - 1 do FHashHead[I] := -1;
  SetLength(FEntries,   0);
  SetLength(FChainNext, 0);
end;

{$push}{$Q-}{$R-}
function TVertexPool.BucketOf(cx, cy, cz: Integer): Integer;
var
  h: QWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1525);{$ENDIF}
  h := QWord($cbf29ce484222325);
  h := (h xor QWord(LongWord(cx))) * QWord($100000001b3);
  h := (h xor QWord(LongWord(cy))) * QWord($100000001b3);
  h := (h xor QWord(LongWord(cz))) * QWord($100000001b3);
  Result := Integer(LongWord(h xor (h shr 32)) and LongWord(FMask));
end;
{$pop}

procedure TVertexPool.RebuildSpatialHash(ABuckets: Integer);
var
  I, bkt, cx, cy, cz: Integer;
begin
  SetLength(FHashHead, ABuckets);
  SetLength(FChainNext, Length(FEntries));
  FMask := ABuckets - 1;
  for I := 0 to ABuckets - 1 do FHashHead[I] := -1;
  for I := 0 to FCount - 1 do
  begin
    cx := Trunc(FEntries[I].Position.X * FInvCell);
    cy := Trunc(FEntries[I].Position.Y * FInvCell);
    cz := Trunc(FEntries[I].Position.Z * FInvCell);
    bkt := BucketOf(cx, cy, cz);
    FChainNext[I] := FHashHead[bkt];
    FHashHead[bkt] := I;
  end;
  FSpatialDirty := False;
end;

procedure TVertexPool.EnsureSpatialHash;
var Buckets: Integer;
begin
  if not FSpatialDirty then Exit;
  Buckets := FMask + 1;
  while Int64(FCount) * 4 > Int64(Buckets) * 3 do
  begin
    if Buckets > MaxInt div 2 then
      raise EOutOfMemory.Create('Vertex pool hash capacity exceeded');
    Buckets := Buckets * 2;
  end;
  RebuildSpatialHash(Buckets);
end;

procedure TVertexPool.Rehash;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1526);{$ENDIF}
  if FMask + 1 > MaxInt div 2 then
    raise EOutOfMemory.Create('Vertex pool hash capacity exceeded');
  RebuildSpatialHash((FMask + 1) * 2);
end;

function TVertexPool.Add(const Pos, Nrm: TVector3): Integer;
var
  cx, cy, cz, qx, qy, qz, bkt, j: Integer;
  cxLo, cxHi, cyLo, cyHi, czLo, czHi: Integer;
  homeBkt: Integer;
  ddx, ddy, ddz, distSq, ndot: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1527);{$ENDIF}
  EnsureSpatialHash;
  { Home cell (for insertion) and the exact range of cells the weld box
    [Pos-eps, Pos+eps] touches (for the match search). Trunc is monotonic, so a
    vertex within eps of Pos — hence inside that box, and hashed into its own
    home cell — necessarily falls inside this range; no match is missed. With a
    cell >> eps the range is a single cell almost always, replacing the fixed
    3x3x3 (27-cell) scan. }
  cx := Trunc(Pos.X * FInvCell);
  cy := Trunc(Pos.Y * FInvCell);
  cz := Trunc(Pos.Z * FInvCell);
  cxLo := Trunc((Pos.X - FPosEps) * FInvCell);  cxHi := Trunc((Pos.X + FPosEps) * FInvCell);
  cyLo := Trunc((Pos.Y - FPosEps) * FInvCell);  cyHi := Trunc((Pos.Y + FPosEps) * FInvCell);
  czLo := Trunc((Pos.Z - FPosEps) * FInvCell);  czHi := Trunc((Pos.Z + FPosEps) * FInvCell);

  { home-cell bucket computed once, reused for the search of the home cell and
    for the final insert (recomputed only if Rehash below changes FMask) }
  homeBkt := BucketOf(cx, cy, cz);

  for qx := cxLo to cxHi do
    for qy := cyLo to cyHi do
      for qz := czLo to czHi do
      begin
        if (qx = cx) and (qy = cy) and (qz = cz) then bkt := homeBkt
        else bkt := BucketOf(qx, qy, qz);
        j := FHashHead[bkt];
        while j <> -1 do
        begin
          ddx := FEntries[j].Position.X - Pos.X;
          ddy := FEntries[j].Position.Y - Pos.Y;
          ddz := FEntries[j].Position.Z - Pos.Z;
          distSq := ddx*ddx + ddy*ddy + ddz*ddz;
          if distSq <= FPosEpsSq then
          begin
            if FNrmMinDot <= -1.0 then
              Exit(j)                 { position-only mode }
            else
            begin
              ndot := FEntries[j].Normal.X * Nrm.X +
                      FEntries[j].Normal.Y * Nrm.Y +
                      FEntries[j].Normal.Z * Nrm.Z;
              if ndot >= FNrmMinDot then Exit(j);
            end;
          end;
          j := FChainNext[j];
        end;
      end;

  { no match -> append, link into home bucket }
  if FCount >= Length(FEntries) then
  begin
    SetLength(FEntries,   (FCount + 1) * 2);
    SetLength(FChainNext, Length(FEntries));
  end;
  { keep load factor < 0.75 — double buckets + re-link before inserting,
    so a composite that outgrows its initial estimate stays fast. }
  if Int64(FCount) + 1 > (Int64(FMask + 1) * 3) div 4 then
  begin
    Rehash;
    homeBkt := BucketOf(cx, cy, cz);   { FMask changed -> recompute home bucket }
  end;
  Result := FCount;
  FEntries[Result].Position := Pos;
  FEntries[Result].Normal   := Nrm;
  bkt := homeBkt;
  FChainNext[Result] := FHashHead[bkt];
  FHashHead[bkt]     := Result;
  Inc(FCount);
end;

function TVertexPool.AddLat(const Pos, Nrm: TVector3; AKey: Int64): Integer;
var
  h: QWord;
  bkt, j, q, NextJ, cx, cy, cz, hb: Integer;
  OldHeads: array of Integer;
begin
  EnsureSpatialHash;
  if FLatHead = nil then
  begin
    FLatMask := 1023;
    SetLength(FLatHead, FLatMask + 1);
    for q := 0 to FLatMask do FLatHead[q] := -1;
    SetLength(FLatNext, Length(FEntries));
    SetLength(FLatKey,  Length(FEntries));
  end;
  {$push}{$Q-}{$R-}
  h := QWord(AKey) * QWord($9E3779B97F4A7C15);
  {$pop}
  bkt := Integer(LongWord(h shr 40) and LongWord(FLatMask));
  j := FLatHead[bkt];
  while j <> -1 do
  begin
    if FLatKey[j] = AKey then Exit(j);
    j := FLatNext[j];
  end;
  { промах: вставка в записи + ОБА хэша (пространственный остаётся живым
    для стежка и прочих потребителей пула) }
  if FCount >= Length(FEntries) then
  begin
    SetLength(FEntries,   (FCount + 1) * 2);
    SetLength(FChainNext, Length(FEntries));
  end;
  { Ordinary Add may have grown FEntries since the previous AddLat. }
  if Length(FLatNext) < Length(FEntries) then
  begin
    SetLength(FLatNext,   Length(FEntries));
    SetLength(FLatKey,    Length(FEntries));
  end;
  if Int64(FLatCount) + 1 > (Int64(FLatMask + 1) * 3) div 4 then
  begin
    if FLatMask + 1 > MaxInt div 2 then
      raise EOutOfMemory.Create('Vertex pool lattice hash capacity exceeded');
    { Only members of the old lattice chains have keys. Ordinary vertices
      must never be reinserted with the default zero in FLatKey. }
    OldHeads := FLatHead;
    FLatHead := nil;
    FLatMask := (FLatMask + 1) * 2 - 1;
    SetLength(FLatHead, FLatMask + 1);
    for q := 0 to FLatMask do FLatHead[q] := -1;
    for q := 0 to High(OldHeads) do
    begin
      j := OldHeads[q];
      while j <> -1 do
      begin
        NextJ := FLatNext[j];
        {$push}{$Q-}{$R-}
        h := QWord(FLatKey[j]) * QWord($9E3779B97F4A7C15);
        {$pop}
        hb := Integer(LongWord(h shr 40) and LongWord(FLatMask));
        FLatNext[j] := FLatHead[hb];
        FLatHead[hb] := j;
        j := NextJ;
      end;
    end;
    {$push}{$Q-}{$R-}
  h := QWord(AKey) * QWord($9E3779B97F4A7C15);
  {$pop}
    bkt := Integer(LongWord(h shr 40) and LongWord(FLatMask));
  end;
  if Int64(FCount) + 1 > (Int64(FMask + 1) * 3) div 4 then
    Rehash;
  Result := FCount;
  FEntries[Result].Position := Pos;
  FEntries[Result].Normal   := Nrm;
  FLatKey[Result] := AKey;
  FLatNext[Result] := FLatHead[bkt];
  FLatHead[bkt] := Result;
  cx := Trunc(Pos.X * FInvCell);
  cy := Trunc(Pos.Y * FInvCell);
  cz := Trunc(Pos.Z * FInvCell);
  hb := BucketOf(cx, cy, cz);
  FChainNext[Result] := FHashHead[hb];
  FHashHead[hb] := Result;
  Inc(FLatCount);
  Inc(FCount);
end;

function TVertexPool.AbsorbRaw(Other: TVertexPool): Integer;
var
  off: Integer;
begin
  Result := FCount;
  if (Other = nil) or (Other.FCount = 0) then Exit;
  off := FCount;
  if Length(FEntries) < off + Other.FCount then
    SetLength(FEntries, Max(off + Other.FCount, Length(FEntries)*2));
  Move(Other.FEntries[0], FEntries[off], Other.FCount * SizeOf(FEntries[0]));
  Inc(FCount, Other.FCount);
  FSpatialDirty := True;
end;

function TVertexPool.PositionOf(I: Integer): TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1528);{$ENDIF}
  Result := FEntries[I].Position;
end;

function TVertexPool.NormalOf(I: Integer): TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1529);{$ENDIF}
  Result := FEntries[I].Normal;
end;

procedure TVertexPool.SetPosition(I: Integer; const P: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1530);{$ENDIF}
  FEntries[I].Position := P;
  FSpatialDirty := True;
end;

procedure TVertexPool.SetNormal(I: Integer; const N: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1531);{$ENDIF}
  FEntries[I].Normal := N;
end;


function LanduseUVScalesFromMaterials: TLanduseUVScales;
var
  K:     TLanduseMeshKind;
  MatId: TGroundMaterialId;
begin
  for K := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
  begin
    MatId := GROUND_MAT_FOR_LANDUSE[K];
    if (MatId <= GROUND_MAT_NONE) or (MatId >= GROUND_MAT_COUNT) then
      Result[K] := 0
    else
      Result[K] := GROUND_MATERIALS[MatId].UVScale;
  end;
end;

end.
