unit Osm3dGeomPlates;

{ overflow/range-проверки выключены намеренно (как в остальных geom-юнитах) }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

{$WARN 5024 OFF}   { не-используемые параметры (SunDirToward — unlit) }
{$WARN 5091 OFF}

{ House-number plates: separate geometry with its own glyph atlas.
  Content = street + housenumber (addr:* on the building). Attached to a facade edge — the side
  whose outward normal best faces the nearest road (else the longest edge), at the right end, at
  first-floor window-top height. Each glyph is a quad whose UV is baked per-vertex from the CGE
  glyph atlas, laid out 1:1 with TCastleFont.Print (size from GlyphDrawImageRect). The backplate is
  a quad marked with sentinel UV: the FS picks a solid colour when u<0, else mixes bg/text by
  atlas coverage. All opaque, so no transparency sorting. The mesh is a plain TMesh: feed to
  BuildPlateShape or tile it like fence meshes. }

interface

uses Osm3dStaticGeometry,
  Classes,
  SysUtils,
  Math,
  CastleVectors,
  CastleStringUtils,        { TCastleStringIterator }
  CastleUnicode,            { TUnicodeChar }
  CastleRenderOptions,
  CastleRectangles,         { TRectangle (GlyphDrawImageRect) }
  CastleTextureFontData,    { TTextureFontData.TGlyph }
  X3DNodes,
  X3DFields,
  Osm3dGeoMath,             { TLatLon / TLocalProjection / TLogProc }
  Osm3dGeomMesh,            { TMesh / VecCross / VecNormalize / MakeUV }
  Osm3dHeightmap,
  Osm3dGeomTerrain,         { TTerrainSampler }
  Osm3dOsmData,
  Osm3dOsmTagUtils,         { HashInt64 — псевдослучайный цвет POI-таблички по id узла }
  Osm3dGeomBuildings,       { TBuildingBuilder / PolygonCentroidXZ / WALL_LEVEL_HEIGHT_M }
  Osm3dGeomFences,          { TFenceBuilder.ParseFenceParams — "is this a (named) fence?" + height }
  Osm3dGeomPOI,             { TPOIBuilderExt.ClassifyNode / ComputeStopPlacement (stop plates) }
  Osm3dGroundComposite,     { TGroundComposite* / BuildCompositeIFS }
  Osm3dPlateAtlas
,
  Osm3dOsmIndex;     { TOsmRoadIndex — единый пер-блочный индекс дорог }

const
  { Backplate sentinel: FS gives a solid colour when u<0; -1 blue, -2 white, -3 red. }
  PLATE_UV_SENTINEL = -1.0;   { = PLATE_SENT_BLUE (для старого кода) }
  PLATE_SENT_BLUE   = -1.0;
  PLATE_SENT_WHITE  = -2.0;
  PLATE_SENT_RED    = -3.0;

  { Стиль глифов кодируется смещением V: дом — текст белый на синем (bias 0),
    place — текст синий на белом (bias 4). FS: style=step(2,v), atlasV=v-4*style. }
  STYLE_HOUSE_VBIAS = 0.0;
  STYLE_PLACE_VBIAS = 4.0;

  { POI plates encode a colour index idx=0..PLATE_POI_COLOR_COUNT-1:
      bg   : u = -(PLATE_SENT_POI_BASE + idx)   -> -4..-11
      glyph: V-bias = (PLATE_STYLE_POI_BASE + idx)*PLATE_STYLE_VSTEP -> 8..36
    FS: style=floor(v/4) (house=0, place=1, poi=2+idx), atlasV=v-4*style. }
  PLATE_SENT_POI_BASE  = 4.0;  { первый POI-фон: u = -4 }
  PLATE_STYLE_POI_BASE = 2;    { первый POI-стиль: индекс 2 }
  PLATE_STYLE_VSTEP    = 4.0;  { шаг V между стилями (= высота атласа стиля) }
  { Stop/platform plates: one fixed slot just past the POI range (bg -4..-11,
    styles 2..9) so it never collides with the hashed POI colours. Grey
    background, white text — the FS forces white here (not luma auto-contrast). }
  PLATE_SENT_GRAY  = -12.0;    { серый фон остановки (u = -12) }
  PLATE_STYLE_STOP = 10;       { стиль глифов остановки: серый фон, белый текст }
  PLATE_POI_EM         = 0.36; { кегль строки name POI в мире }
  PLATE_FENCE_EM       = 0.45; { кегль имени забора/тюрьмы на панели (крупнее POI) }
  STOP_PLATE_BASE_H    = 2.20; { высота крепления таблички остановки над землёй, м }

  { Палитра (sRGB → FS как emissive). Меняется здесь. }
  PLATE_BG_COLOR:   TVector3 = (X: 0.09; Y: 0.17; Z: 0.42);   { синий }
  PLATE_TEXT_COLOR: TVector3 = (X: 0.96; Y: 0.97; Z: 1.00);   { белый }
  PLATE_RED_COLOR:  TVector3 = (X: 0.82; Y: 0.10; Z: 0.12);   { красный (диагональ) }
  PLATE_GRAY_COLOR: TVector3 = (X: 0.44; Y: 0.44; Z: 0.46);   { серый фон таблички остановки }

  { POI plate palette: colour picked by HashInt64(nodeId) mod count; text auto-contrasts in the FS.
    IMPORTANT: changing the length means syncing pltPoiColor() + the u_plt_poiN uniforms in
    PLATE_COMPOSITE_FS and the registration loop in BuildPlateCompositeShape. }
  PLATE_POI_COLOR_COUNT = 8;
  PLATE_POI_COLORS: array[0..7] of TVector3 = (
    (X: 0.13; Y: 0.45; Z: 0.36),   { тёмно-зелёный }
    (X: 0.80; Y: 0.42; Z: 0.10),   { оранжевый }
    (X: 0.40; Y: 0.18; Z: 0.52),   { фиолетовый }
    (X: 0.70; Y: 0.15; Z: 0.40),   { малиновый }
    (X: 0.45; Y: 0.30; Z: 0.16),   { коричневый }
    (X: 0.10; Y: 0.40; Z: 0.55),   { бирюзовый }
    (X: 0.42; Y: 0.46; Z: 0.12),   { оливковый }
    (X: 0.65; Y: 0.20; Z: 0.18)    { терракотовый }
  );

  { --- геометрические настройки (метры / доли) --- }
  PLATE_NUMBER_EM   = 0.42;   { «кегль» строки номера в мире (для Font.Size px) }
  PLATE_STREET_EM   = 0.20;   { кегль строки улицы }
  PLATE_LINE_GAP    = 0.06;   { зазор между строками }
  PLATE_PAD_X       = 0.10;   { горизонтальные поля фона }
  PLATE_PAD_Y       = 0.07;   { вертикальные поля фона }
  PLATE_BACK_OFFSET   = 0.05; { вынос фона от стены по нормали (анти-z-fight) }
  PLATE_GLYPH_OFFSET  = 0.07; { вынос глифов (чуть ближе фона) }
  PLATE_STRIPE_W      = 0.18; { толщина красной диагонали выездной таблички }
  PLATE_STRIPE_OFFSET = 0.09; { вынос диагонали (перед текстом) }
  PLATE_LOD_MAX_M     = 100.0;{ дальше этого расстояния от камеры таблички не видны }


  { Plate top is pinned to the first-floor window top (V≈0.19..0.81 of a floor in brick_window_*);
    floor in world = WallH/Levels (or WALL_LEVEL_HEIGHT_M), measured from the real wall base. }
  PLATE_WINDOW_TOP_V   = 0.81; { доля этажа: верх окна 1-го этажа (фасадная текстура) }
  PLATE_ABOVE_WINDOW_M = 0.08; { зазор между верхом окна и низом таблички (вешаем НАД окном) }
  PLATE_ROOF_MARGIN    = 0.40; { не подниматься ближе этого к карнизу }
  PLATE_MIN_SIGN_TOP   = 1.40; { минимальный низ номера над базой стены }

  { Размещение по горизонтали — на РЕАЛЬНОМ ребре контура (не на угле OMBB). }
  PLATE_EDGE_MARGIN   = 0.50; { отступ от концов ребра }
  PLATE_MIN_EDGE_LEN  = 2.00; { ребро короче — не лицевое (если есть длиннее) }
  PLATE_MIN_FONT_SCALE = 0.45;{ предел уменьшения шрифта, если шире стены }

  PLATE_MAX           = 6000; { страховочный лимит числа табличек }

  { --- Въездные таблички place (название НП на въезде дороги в его границу) --- }
  PLACE_SIGN_EM       = 0.70; { кегль названия НП в мире }
  PLACE_SIGN_HEIGHT_M = 2.40; { высота низа панели над землёй }
  PLACE_SIGN_SIDE_M   = 3.00; { сдвиг панели вправо от оси дороги }
  PLACE_POST_W        = 0.16; { ширина «столба» (полоса фона до земли) }
  PLACE_SIGN_MAX      = 2000; { лимит въездных табличек }

  { Радиус подавления дублей табличек (въездных и речных): в этом радиусе остаётся
    только одна табличка — на более крупной дороге (или более широком мосту).
    Сравнение по квадрату расстояния, чтобы не извлекать корень. }
  SIGN_DEDUP_RADIUS_M = 30.0;
  SIGN_DEDUP_R2       = SIGN_DEDUP_RADIUS_M * SIGN_DEDUP_RADIUS_M;

  { River-plate prefix by script: Cyrillic gets "р. "; Latin gets the name alone (blue panel
    already signals water). IMPORTANT: the UTF8String type is required — an inline Cyrillic string
    constant gets mangled to CP_ACP under this FPC, and the glyph renderer needs valid UTF-8. }
  RIVER_PREFIX_CYRILLIC: UTF8String = 'р. ';
  RIVER_PREFIX_LATIN:    UTF8String = '';

var
  { Debug one plate: building way-id for a detailed log dump; set from OSM3D_PLATE_DEBUG_WAYID. 0 = off. }
  PlateDebugWayId: Int64;

  { Full dump (OSM3D_PLATE_DEBUG_ALL=1): logs every building and every successful plate. Very verbose. }
  PlateDebugAll: Boolean;

type
  { Tile anchor: a whole plate rides into one tile (like fences/buildings, no glyph slicing).
    The half-open ranges point at its verts/tris in the mesh BuildAll returned. }
  TPlateTileAnchor = record
    AnchorX, AnchorZ:   Single;
    VertStart, VertEnd: Integer;
    TriStart,  TriEnd:  Integer;
  end;
  TPlateTileAnchorArray = array of TPlateTileAnchor;

  { River-sign input: river name + both bridge ends (world XZ + deck Y) and the road direction
    INTO the bridge at each end (to face the panel toward the driver). Filled from TBridgeSpec. }
  TRiverSign = record
    WayId:      Int64;
    Num:        Integer;  { сквозной номер моста для отладки; <0 — не показывать }
    Name:       string;
    Prio:       Single;   { приоритет при дедупе — ширина моста (шире мост = крупнее дорога) }
    Ax, Ay, Az: Single;   { конец A (Center[0]) }
    Adx, Adz:   Single;   { направление внутрь моста на конце A (норм.) }
    Bx, By, Bz: Single;   { конец B (Center[High]) }
    Bdx, Bdz:   Single;
  end;
  TRiverSignArray = array of TRiverSign;

  TPlateBuilder = class
  public
    { One shared TMesh with all plates (world coords, real terrain Y). Material isn't stored;
      the caller marks it smkPlate when tiling, or builds a shape via BuildPlateShape. Also fills
      Anchors (one per building) for whole-plate tiling. Caller frees the result. Atlas is only
      needed for font metrics. }
    class function BuildAll(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection; Atlas: TPlateGlyphAtlas;
      out Anchors: TPlateTileAnchorArray;
      Terrain: TTerrainSampler = nil; Log: TLogProc = nil;
      ARoadIdx: TOsmRoadIndex = nil): TMesh;

    { Append river signs to an ALREADY-built plate mesh + its anchors: one panel at each bridge
      end, facing the driver. Anchors/AnchorCount/Made are those BuildAll returned (the array
      grows; trim to AnchorCount on return). Atlas = font metrics only. }
    class procedure AppendRiverSigns(Mesh: TMesh; const Signs: TRiverSignArray;
      Atlas: TPlateGlyphAtlas; var Anchors: TPlateTileAnchorArray;
      var AnchorCount, Made: Integer; Log: TLogProc = nil); static;
  end;

{ Build one shape (one draw call) from a plate mesh, sampling the glyph atlas. Needs Atlas.Url
  (after SaveToCache); nil if empty or no URL. SunDirToward ignored (unlit). Caller owns the shape. }
function BuildPlateShape(PlateMesh: TMesh; Atlas: TPlateGlyphAtlas;
  const SunDirToward: TVector3; LogProc: TLogProc = nil): TShapeNode;

{ Low-level analogue of BuildFenceCompositeShape: a shape from an already-built composite mesh
  (the tiled path, where quads accumulate in a TGroundCompositeBuilder like fences). }
function BuildPlateCompositeShape(Composite: TGroundCompositeMesh;
  Atlas: TPlateGlyphAtlas; const SunDirToward: TVector3;
  LogProc: TLogProc = nil): TShapeNode;

const
  { Vertex effect: маршрутизирует pltUV/pltNormal как кастом-атрибуты (TUnlit-
    Material заставляет CGE пропустить свою загрузку texcoord/normal). }
  PLATE_COMPOSITE_VS =
    'attribute vec2  pltUV;'                                              + #10 +
    'attribute vec3  pltNormal;'                                          + #10 +
    'varying   vec2  vPltUV;'                                             + #10 +
    'varying   vec3  vPltNormalOS;'                                       + #10 +
    'varying   float vPltDist;'                                           + #10 +
    'void PLUG_vertex_eye_space('                                         + #10 +
    '  const in vec4 vertex_eye,'                                         + #10 +
    '  const in vec3 normal_eye)'                                         + #10 +
    '{'                                                                   + #10 +
    '    vPltUV       = pltUV;'                                           + #10 +
    '    vPltNormalOS = pltNormal;'                                       + #10 +
    '    vPltDist     = length(vertex_eye.xyz);'  { камера в начале eye-space } + #10 +
    '}'                                                                   + #10;

  { Fragment effect: при u<0 — сплошной цвет палитры по значению k=-u
    (1 синий, 2 белый, 3 красный, 4..11 POI-палитра); иначе глиф — стиль по
    style=floor(v/4) (0 дом: белый/синий; 1 place: синий/белый; 2+idx POI:
    авто-контрастный текст на цвете палитры), atlasV = v - 4*style.
    Unlit/emissive. }
  PLATE_COMPOSITE_FS =
    'varying vec2 vPltUV;'                                                + #10 +
    'varying vec3 vPltNormalOS;'                                          + #10 +
    'varying float vPltDist;'                                             + #10 +
    'uniform sampler2D u_plt_atlas;'                                      + #10 +
    'uniform vec3 u_plt_blue;'                                            + #10 +
    'uniform vec3 u_plt_white;'                                           + #10 +
    'uniform vec3 u_plt_red;'                                             + #10 +
    'uniform vec3 u_plt_poi0;'                                            + #10 +
    'uniform vec3 u_plt_poi1;'                                            + #10 +
    'uniform vec3 u_plt_poi2;'                                            + #10 +
    'uniform vec3 u_plt_poi3;'                                            + #10 +
    'uniform vec3 u_plt_poi4;'                                            + #10 +
    'uniform vec3 u_plt_poi5;'                                            + #10 +
    'uniform vec3 u_plt_poi6;'                                            + #10 +
    'uniform vec3 u_plt_poi7;'                                            + #10 +
    'uniform vec3 u_plt_gray;'                                            + #10 +
    'uniform float u_plt_lodmax;'                                         + #10 +
    'vec3 pltPoiColor(int idx) {'                                         + #10 +
    '    if (idx <= 0)      return u_plt_poi0;'                           + #10 +
    '    else if (idx == 1) return u_plt_poi1;'                           + #10 +
    '    else if (idx == 2) return u_plt_poi2;'                           + #10 +
    '    else if (idx == 3) return u_plt_poi3;'                           + #10 +
    '    else if (idx == 4) return u_plt_poi4;'                           + #10 +
    '    else if (idx == 5) return u_plt_poi5;'                           + #10 +
    '    else if (idx == 6) return u_plt_poi6;'                           + #10 +
    '    return u_plt_poi7;'                                              + #10 +
    '}'                                                                   + #10 +
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + #10 +
    '{'                                                                   + #10 +
    '    if (vPltDist > u_plt_lodmax) discard;'                           + #10 +
    '    float u = vPltUV.x;'                                             + #10 +
    '    float v = vPltUV.y;'                                             + #10 +
    '    vec3 col;'                                                       + #10 +
    '    if (u < 0.0) {'                                                  + #10 +
    '        float k = -u;'                                               + #10 +
    '        if (k < 1.5)      col = u_plt_blue;'                         + #10 +
    '        else if (k < 2.5) col = u_plt_white;'                        + #10 +
    '        else if (k < 3.5) col = u_plt_red;'                          + #10 +
    '        else if (k < 11.5) col = pltPoiColor(int(k + 0.5) - 4);'     + #10 +
    '        else               col = u_plt_gray;'                        + #10 +
    '    } else {'                                                        + #10 +
    '        float style = floor(v * 0.25);'                              + #10 +
    '        float av    = v - style * 4.0;'                              + #10 +
    '        float cov   = texture2D(u_plt_atlas, vec2(u, av)).r;'        + #10 +
    '        if (style < 0.5) {'                                          + #10 +
    '            col = mix(u_plt_blue, u_plt_white, cov);'                + #10 +
    '        } else if (style < 1.5) {'                                   + #10 +
    '            col = mix(u_plt_white, u_plt_blue, cov);'                + #10 +
    '        } else if (style < 9.5) {'                                   + #10 +
    '            vec3 bg = pltPoiColor(int(style + 0.5) - 2);'            + #10 +
    '            float L = dot(bg, vec3(0.299, 0.587, 0.114));'           + #10 +
    '            vec3 ink = (L > 0.55) ? vec3(0.05) : vec3(0.98);'        + #10 +
    '            col = mix(bg, ink, cov);'                                + #10 +
    '        } else {'                                                    + #10 +
    '            col = mix(u_plt_gray, u_plt_white, cov);'                + #10 +
    '        }'                                                           + #10 +
    '    }'                                                               + #10 +
    '    fragment_color = vec4(col, 1.0);'                                + #10 +
    '}'                                                                   + #10;

implementation

uses
  Osm3dGeomRoads;           { TRoadBuilder.ClassifyHighway / TRoadKind — приоритет дорог при дедупе табличек }

type
  TV3Array = array of TVector3;
  TV2Array = array of TVector2;

const
  { меньше точек — полный перебор дешевле построения индекса }
  PTGRID_MIN_PTS  = 64;
  PTGRID_MIN_CELL = 8.0;
  PTGRID_MAX_CELL = 256.0;

type
  { Uniform grid по точкам XZ (задача «ближайшая точка» / «точки в bbox» в
    горячих циклах здания×точки). Ячейки хранят индексы точек в порядке
    обхода исходного массива (возрастающем), поэтому ответы детерминированы
    и совпадают с полным перебором. Cols=0 — индекс не построен (мало
    точек), вызывающий падает на перебор. }
  TPtGrid = record
    MinX, MinZ, Cell: Single;
    Cols, Rows: Integer;
    Offs:  array of Integer;   { Cols*Rows+1: диапазон ячейки в Items }
    Items: array of Integer;   { индексы точек, сгруппированные по ячейкам }
  end;

  { Ключ дедупликации таблички: позиция (X,Z), приоритет (крупнее=больше) и группа
    (кандидаты одной группы между собой не конфликтуют). }
  TDedupKey = record
    X, Z, Prio: Single;
    Grp:        Int64;
  end;
  TDedupKeyArray = array of TDedupKey;

  { Габариты уже выложенного текста в локальных осях таблички:
    U — вдоль rightDir (правый край строк = 0, текст растёт в минус),
    Y — мировая высота. }
  TPlateBounds = record
    HasAny:           Boolean;
    MinU, MaxU:       Single;
    MinY, MaxY:       Single;
  end;

{ Общий аппендер якоря таблички в растущий массив (grow 256/×2 + 6 полей).
  Раньше блок дублировался в пяти местах Osm3dGeomPlates. }
procedure AppendPlateAnchor(var Anchors: TPlateTileAnchorArray;
  var AnchorCount: Integer; Qx, Qz: Single;
  VStart, VEnd, TStart, TEnd: Integer);
begin
  if AnchorCount >= Length(Anchors) then
  begin
    if Length(Anchors) = 0 then SetLength(Anchors, 256)
    else SetLength(Anchors, Length(Anchors) * 2);
  end;
  Anchors[AnchorCount].AnchorX   := Qx;
  Anchors[AnchorCount].AnchorZ   := Qz;
  Anchors[AnchorCount].VertStart := VStart;
  Anchors[AnchorCount].VertEnd   := VEnd;
  Anchors[AnchorCount].TriStart  := TStart;
  Anchors[AnchorCount].TriEnd    := TEnd;
  Inc(AnchorCount);
end;

{ Высота земли — общий SampleTerrainYGeo в Osm3dGeomTerrain
  (тот же источник, что у POI/меток). }

{ Кольцо фасада: спроецированные XZ-узлы (Y=0), без дублирующего замыкающего.
  False — меньше 3 различимых вершин. }
function BuildRing(Way: TOSMWay; Dataset: TOSMDataset;
  Projection: TLocalProjection; out Ring: TV3Array): Boolean;
var
  N, I, Cnt: Integer;
  Node: TOSMNode;
  P: TVector3;
begin
  Result := False;
  Ring := nil;
  N := Length(Way.NodeRefs);
  if N < 4 then Exit;
  { закрытое кольцо: последний узел == первый → пропустить дубликат }
  if Way.NodeRefs[0] = Way.NodeRefs[N - 1] then Dec(N);
  if N < 3 then Exit;

  SetLength(Ring, N);
  Cnt := 0;
  for I := 0 to N - 1 do
  begin
    Node := Dataset.FindNode(Way.NodeRefs[I]);
    if Node = nil then Continue;
    if Dataset.LatticeReady then
    begin
      { int-first: точные решёточные координаты узла (мировая решётка 1/64 м
        минус целый сдвиг блока) — побитно одинаковы во всех блоках halo,
        см. Osm3dOsmData.PrecomputeLattice }
      P.X := Node.LatticeX * (1.0 / 64.0);
      P.Y := 0;
      P.Z := Node.LatticeZ * (1.0 / 64.0);
    end
    else
    begin
      P := Projection.Project(Node.Position, 0);
      P.X := Round(P.X * 64.0) * (1.0 / 64.0);
      P.Z := Round(P.Z * 64.0) * (1.0 / 64.0);
    end;
    Ring[Cnt] := P;
    Inc(Cnt);
  end;
  SetLength(Ring, Cnt);
  Result := Cnt >= 3;
end;

{ Все XZ-точки highway-вэев (для выбора лицевого фасада). }
function CollectHighwayPts(Dataset: TOSMDataset;
  Projection: TLocalProjection): TV2Array;
var
  Way:  TOSMWay;
  Node: TOSMNode;
  I, Cnt, Cap: Integer;
  P: TVector3;
begin
  Cnt := 0; Cap := 0;
  Result := nil;
  for Way in Dataset.Ways.Values do
  begin
    if not Way.Tags.HasKey('highway') then Continue;
    for I := 0 to High(Way.NodeRefs) do
    begin
      Node := Dataset.FindNode(Way.NodeRefs[I]);
      if Node = nil then Continue;
      if Cnt >= Cap then
      begin
        if Cap = 0 then Cap := 1024 else Cap := Cap * 2;
        SetLength(Result, Cap);
      end;
      if Dataset.LatticeReady then
      begin
        { int-first: решётка узла (Osm3dOsmData.PrecomputeLattice) }
        P.X := Node.LatticeX * (1.0 / 64.0);
        P.Y := 0;
        P.Z := Node.LatticeZ * (1.0 / 64.0);
      end
      else
      begin
        P := Projection.Project(Node.Position, 0);
        P.X := Round(P.X * 64.0) * (1.0 / 64.0);
        P.Z := Round(P.Z * 64.0) * (1.0 / 64.0);
      end;
      Result[Cnt].X := P.X;
      Result[Cnt].Y := P.Z;
      Inc(Cnt);
    end;
  end;
  SetLength(Result, Cnt);
end;

type
  { Точки одной улицы (XZ), копятся при построении индекса. }
  TStreetPts = class
    Pts: TV2Array;
    Cnt: Integer;
    procedure Add(X, Z: Single);
    procedure Shrink;
  end;

procedure TStreetPts.Add(X, Z: Single);
begin
  if Cnt >= Length(Pts) then
  begin
    if Length(Pts) = 0 then SetLength(Pts, 32)
    else SetLength(Pts, Length(Pts) * 2);
  end;
  Pts[Cnt].X := X;
  Pts[Cnt].Y := Z;
  Inc(Cnt);
end;

procedure TStreetPts.Shrink;
begin
  SetLength(Pts, Cnt);
end;

{ Индекс «имя улицы → её XZ-точки» из именованных highway-вэев. Sorted +
  CaseSensitive=False (ASCII-регистр сворачивается; кириллица сравнивается
  точно — addr:street и name обычно из одного OSM и совпадают по регистру).
  Несколько сегментов одной улицы сливаются. Объекты списка — TStreetPts
  (освобождаются в FreeStreetIndex). }
function BuildStreetIndex(Dataset: TOSMDataset;
  Projection: TLocalProjection): TStringList;
var
  Way:  TOSMWay;
  Node: TOSMNode;
  I, K: Integer;
  Nm:   string;
  H:    TStreetPts;
  P:    TVector3;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.CaseSensitive := False;
  Result.Duplicates := dupAccept;        { дубли гасим сами через IndexOf }
  for Way in Dataset.Ways.Values do
  begin
    if not Way.Tags.HasKey('highway') then Continue;
    Nm := Trim(Way.Tags.Get('name'));
    if Nm = '' then Continue;
    K := Result.IndexOf(Nm);
    if K < 0 then
    begin
      H := TStreetPts.Create;
      Result.AddObject(Nm, H);
    end
    else
      H := TStreetPts(Result.Objects[K]);
    for I := 0 to High(Way.NodeRefs) do
    begin
      Node := Dataset.FindNode(Way.NodeRefs[I]);
      if Node = nil then Continue;
      if Dataset.LatticeReady then
      begin
        { int-first: решётка узла (Osm3dOsmData.PrecomputeLattice) }
        P.X := Node.LatticeX * (1.0 / 64.0);
        P.Y := 0;
        P.Z := Node.LatticeZ * (1.0 / 64.0);
      end
      else
      begin
        P := Projection.Project(Node.Position, 0);
        P.X := Round(P.X * 64.0) * (1.0 / 64.0);
        P.Z := Round(P.Z * 64.0) * (1.0 / 64.0);
      end;
      H.Add(P.X, P.Z);
    end;
  end;
  for K := 0 to Result.Count - 1 do
    TStreetPts(Result.Objects[K]).Shrink;
end;

procedure FreeStreetIndex(var Idx: TStringList);
var K: Integer;
begin
  if Idx = nil then Exit;
  for K := 0 to Idx.Count - 1 do
    Idx.Objects[K].Free;
  FreeAndNil(Idx);
end;

{ Макс. высота земли под контуром — как у стен зданий (BaseY = max + lift). }
function FootprintMaxGroundY(Way: TOSMWay; Dataset: TOSMDataset;
  Terrain: TTerrainSampler; HM: THeightmap): Single;
var
  I: Integer;
  Node: TOSMNode;
  H: Single;
  Got: Boolean;
begin
  Result := 0; Got := False;
  for I := 0 to High(Way.NodeRefs) do
  begin
    Node := Dataset.FindNode(Way.NodeRefs[I]);
    if Node = nil then Continue;
    H := SampleTerrainYGeo(Terrain, HM, Node.Position);
    if (not Got) or (H > Result) then begin Result := H; Got := True; end;
  end;
end;

{ building:levels → целое (только тег; 0 — нет тега). }
function ParsePlateLevels(const Tags: TOSMTags): Integer;
var
  S: string; V: Double;
begin
  Result := 0;
  S := Trim(Tags.Get('building:levels'));
  if S = '' then Exit;
  S := StringReplace(S, ',', '.', []);
  if TryStrToFloat(S, V) and (V >= 1) then Result := Trunc(V + 0.001);
end;

{ Построить uniform grid по точкам (двухпроходный: подсчёт → префиксные
  смещения → заполнение). ~8 точек на ячейку, кламп размера ячейки. При
  N < PTGRID_MIN_PTS возвращает пустой grid (Cols=0) — перебор дешевле. }
function BuildV2Grid(const Pts: TV2Array): TPtGrid;
var
  N, I, Cx, Cz, CI, Total: Integer;
  Counts: array of Integer;
  MaxX, MaxZ, Area: Single;
begin
  Result.Cols := 0; Result.Rows := 0;
  Result.Offs := nil; Result.Items := nil;
  N := Length(Pts);
  if N < PTGRID_MIN_PTS then Exit;
  Result.MinX := Pts[0].X; MaxX := Pts[0].X;
  Result.MinZ := Pts[0].Y; MaxZ := Pts[0].Y;
  for I := 1 to N - 1 do
  begin
    if Pts[I].X < Result.MinX then Result.MinX := Pts[I].X;
    if Pts[I].X > MaxX then MaxX := Pts[I].X;
    if Pts[I].Y < Result.MinZ then Result.MinZ := Pts[I].Y;
    if Pts[I].Y > MaxZ then MaxZ := Pts[I].Y;
  end;
  Area := (MaxX - Result.MinX + 1.0) * (MaxZ - Result.MinZ + 1.0);
  Result.Cell := Sqrt(Area * 8.0 / N);
  if Result.Cell < PTGRID_MIN_CELL then Result.Cell := PTGRID_MIN_CELL;
  if Result.Cell > PTGRID_MAX_CELL then Result.Cell := PTGRID_MAX_CELL;
  Result.Cols := Floor((MaxX - Result.MinX) / Result.Cell) + 1;
  Result.Rows := Floor((MaxZ - Result.MinZ) / Result.Cell) + 1;
  SetLength(Counts, Result.Cols * Result.Rows);
  for I := 0 to N - 1 do
  begin
    Cx := Floor((Pts[I].X - Result.MinX) / Result.Cell);
    Cz := Floor((Pts[I].Y - Result.MinZ) / Result.Cell);
    if Cx < 0 then Cx := 0 else if Cx >= Result.Cols then Cx := Result.Cols - 1;
    if Cz < 0 then Cz := 0 else if Cz >= Result.Rows then Cz := Result.Rows - 1;
    Inc(Counts[Cz * Result.Cols + Cx]);
  end;
  SetLength(Result.Offs, Result.Cols * Result.Rows + 1);
  Total := 0;
  for I := 0 to Result.Cols * Result.Rows - 1 do
  begin
    Result.Offs[I] := Total;
    Inc(Total, Counts[I]);
  end;
  Result.Offs[Result.Cols * Result.Rows] := Total;
  SetLength(Result.Items, Total);
  for I := 0 to High(Counts) do Counts[I] := 0;   { курсоры заполнения }
  for I := 0 to N - 1 do
  begin
    Cx := Floor((Pts[I].X - Result.MinX) / Result.Cell);
    Cz := Floor((Pts[I].Y - Result.MinZ) / Result.Cell);
    if Cx < 0 then Cx := 0 else if Cx >= Result.Cols then Cx := Result.Cols - 1;
    if Cz < 0 then Cz := 0 else if Cz >= Result.Rows then Cz := Result.Rows - 1;
    CI := Cz * Result.Cols + Cx;
    Result.Items[Result.Offs[CI] + Counts[CI]] := I;
    Inc(Counts[CI]);
  end;
end;

{ Ближайшая к (Qx,Qz) точка grid'а; при равных d² — меньший индекс (как у
  полного перебора с '<'). Кольца ячеек Chebyshev вокруг ячейки запроса;
  выход, когда аналитическая нижняя граница d² следующего кольца > best2
  (при равенстве сканируем — вдруг tie с меньшим индексом). }
function GridNearest(const G: TPtGrid; const Pts: TV2Array;
  Qx, Qz: Single): Integer;
var
  Cx0, Cz0, R, Cx, Cz: Integer;
  Best2, MinOutside, D: Single;
  LoCx, HiCx, LoCz, HiCz: Integer;

  procedure VisitCell(AX, AZ: Integer);
  var
    CI, K, Idx: Integer;
    Dx, Dz, D2: Single;
  begin
    CI := AZ * G.Cols + AX;
    for K := G.Offs[CI] to G.Offs[CI + 1] - 1 do
    begin
      Idx := G.Items[K];
      Dx := Pts[Idx].X - Qx; Dz := Pts[Idx].Y - Qz;
      D2 := Dx * Dx + Dz * Dz;
      if (D2 < Best2) or ((D2 = Best2) and ((Result < 0) or (Idx < Result))) then
      begin
        Best2 := D2;
        Result := Idx;
      end;
    end;
  end;

begin
  Result := -1;
  if (G.Cols <= 0) or (G.Rows <= 0) or (Length(Pts) = 0) then Exit;
  Best2 := MaxSingle;
  Cx0 := Floor((Qx - G.MinX) / G.Cell);
  Cz0 := Floor((Qz - G.MinZ) / G.Cell);
  if Cx0 < 0 then Cx0 := 0 else if Cx0 >= G.Cols then Cx0 := G.Cols - 1;
  if Cz0 < 0 then Cz0 := 0 else if Cz0 >= G.Rows then Cz0 := G.Rows - 1;
  R := 0;
  repeat
  begin
    LoCx := Max(0, Cx0 - R); HiCx := Min(G.Cols - 1, Cx0 + R);
    LoCz := Max(0, Cz0 - R); HiCz := Min(G.Rows - 1, Cz0 + R);
    { Visit only the perimeter, clipped to the grid. Iterating the whole
      square and skipping its interior made sparse searches cubic in R. }
    if Cz0 - R >= 0 then
      for Cx := LoCx to HiCx do
        VisitCell(Cx, Cz0 - R);
    if R > 0 then
    begin
      if Cz0 + R < G.Rows then
        for Cx := LoCx to HiCx do
          VisitCell(Cx, Cz0 + R);
      for Cz := Max(0, Cz0 - R + 1) to Min(G.Rows - 1, Cz0 + R - 1) do
      begin
        if Cx0 - R >= 0 then VisitCell(Cx0 - R, Cz);
        if Cx0 + R < G.Cols then VisitCell(Cx0 + R, Cz);
      end;
    end;

    if (LoCx = 0) and (HiCx = G.Cols - 1) and
       (LoCz = 0) and (HiCz = G.Rows - 1) then Break;

    { Lower bound to UNVISITED cells: distance to each remaining side of
      the scanned rectangle. Distance TO that rectangle is zero for an
      inside query and never stopped the old search (Sadovoe: 8745x1060
      cells, still scanning at R=2830 with a road already 9 metres away).
      Ignore sides at the grid boundary; clamp negative distances for
      queries outside the grid. Equality must keep searching for ties. }
    MinOutside := MaxSingle;
    if LoCx > 0 then
      MinOutside := Max(0.0, Qx - (G.MinX + LoCx * G.Cell));
    if HiCx < G.Cols - 1 then
    begin
      D := Max(0.0, G.MinX + (HiCx + 1) * G.Cell - Qx);
      MinOutside := Min(MinOutside, D);
    end;
    if LoCz > 0 then
    begin
      D := Max(0.0, Qz - (G.MinZ + LoCz * G.Cell));
      MinOutside := Min(MinOutside, D);
    end;
    if HiCz < G.Rows - 1 then
    begin
      D := Max(0.0, G.MinZ + (HiCz + 1) * G.Cell - Qz);
      MinOutside := Min(MinOutside, D);
    end;
    if (Result >= 0) and (MinOutside * MinOutside > Best2) then Break;
    Inc(R);
  end
  until False;
end;

{ Quicksort по возрастанию для массива индексов-кандидатов (итеративный
  хвост, как SortDoubles в RideParamEstimator). }
procedure SortInts(var A: array of Integer; Lo, Hi: Integer);
var
  I, J, Pivot, Tmp: Integer;
begin
  while Lo < Hi do
  begin
    I := Lo; J := Hi;
    Pivot := A[(Lo + Hi) div 2];
    repeat
      while A[I] < Pivot do Inc(I);
      while A[J] > Pivot do Dec(J);
      if I <= J then
      begin
        Tmp := A[I]; A[I] := A[J]; A[J] := Tmp;
        Inc(I); Dec(J);
      end;
    until I > J;
    if J - Lo < Hi - I then
    begin
      SortInts(A, Lo, J);
      Lo := I;
    end
    else
    begin
      SortInts(A, I, Hi);
      Hi := J;
    end;
  end;
end;

{ Выбрать лицевое РЕБРО контура (а не сторону OMBB — у непрямоугольных домов её
  угол висит в воздухе за стеной). Контур уже CCW, наружная нормаль ребра =
  cross(edgeDir, Up) = (-dz, dx)/len — то же соглашение, что у стен зданий, так
  что табличка точно ложится на плоскость стены. Если есть дороги — ребро, чья
  нормаль лучше смотрит на ближайшую дорожную точку (среди рёбер длиной ≥
  PLATE_MIN_EDGE_LEN); иначе самое длинное ребро. Возвращает мировые XZ концов
  (V0→V1), единичную наружную нормаль (Nx,Nz) и длину ELen. False — нет ребра. }
function PickFacadeEdge(const Ring: TV3Array; const RoadPts: TV2Array;
  const RoadGrid: TPtGrid;
  out V0x, V0z, V1x, V1z, Nx, Nz, ELen: Single): Boolean;
var
  N, I, J, BestI, LongI, NearIdx, K: Integer;
  ex, ez, len, nx_, nz_, mx, mz, dirx, dirz, dl, score: Single;
  bestScore, longLen, dx, dz, d2, best2: Single;
begin
  Result := False;
  N := Length(Ring);
  if N < 3 then Exit;
  BestI := -1; bestScore := -1.0e30;
  LongI := -1; longLen := -1.0;
  for I := 0 to N - 1 do
  begin
    J := (I + 1) mod N;
    ex := Ring[J].X - Ring[I].X;
    ez := Ring[J].Z - Ring[I].Z;
    len := Sqrt(ex * ex + ez * ez);
    if len < 1.0e-3 then Continue;
    if len > longLen then begin longLen := len; LongI := I; end;
    if len < PLATE_MIN_EDGE_LEN then Continue;
    nx_ := -ez / len; nz_ := ex / len;          { наружная нормаль }
    if Length(RoadPts) > 0 then
    begin
      mx := (Ring[I].X + Ring[J].X) * 0.5;
      mz := (Ring[I].Z + Ring[J].Z) * 0.5;
      if RoadGrid.Cols > 0 then
        NearIdx := GridNearest(RoadGrid, RoadPts, mx, mz)
      else
      begin
        NearIdx := -1; best2 := MaxSingle;
        for K := 0 to High(RoadPts) do
        begin
          dx := RoadPts[K].X - mx; dz := RoadPts[K].Y - mz;
          d2 := dx * dx + dz * dz;
          if d2 < best2 then begin best2 := d2; NearIdx := K; end;
        end;
      end;
      dirx := RoadPts[NearIdx].X - mx; dirz := RoadPts[NearIdx].Y - mz;
      dl := Sqrt(dirx * dirx + dirz * dirz);
      if dl > 1.0e-6 then score := (nx_ * dirx + nz_ * dirz) / dl
      else score := 0.0;
    end
    else
      score := len;                              { нет дорог — длинное ребро }
    if score > bestScore then begin bestScore := score; BestI := I; end;
  end;
  if BestI < 0 then BestI := LongI;              { ни одного длинного → длиннейшее }
  if BestI < 0 then Exit;
  J := (BestI + 1) mod N;
  ex := Ring[J].X - Ring[BestI].X;
  ez := Ring[J].Z - Ring[BestI].Z;
  ELen := Sqrt(ex * ex + ez * ez);
  if ELen < 1.0e-3 then Exit;
  V0x := Ring[BestI].X; V0z := Ring[BestI].Z;
  V1x := Ring[J].X;     V1z := Ring[J].Z;
  Nx := -ez / ELen;     Nz := ex / ELen;
  Result := True;
end;

{ Мировая точка стены из локальных (U вдоль rightDir, Y мировая высота). }
function WallPt(const PRx, PRz, RX, RZ: Single; const N3: TVector3;
  U, Y, Off: Single): TVector3;
begin
  Result.X := PRx + RX * U + N3.X * Off;
  Result.Y := Y + N3.Y * Off;           { N3.Y = 0 → Off не трогает высоту }
  Result.Z := PRz + RZ * U + N3.Z * Off;
end;

{ Выложить одну строку текста, обновить габариты B. Правый край строки = U=0. }
procedure AppendLine(Mesh: TMesh; Atlas: TPlateGlyphAtlas; const S: string;
  SScale, BaselineY, PRx, PRz, RX, RZ: Single; const N3: TVector3;
  GlyphOff, VBias: Single; var B: TPlateBounds);
var
  Iter: TCastleStringIterator;
  G:    TTextureFontData.TGlyph;
  R:    TRectangle;
  PenLx, LineW, GlLeft, GlBottom, GW, GH: Single;
  UL, UR, YB, YT, U0, U1, V0, V1: Single;
  IW, IH: Single;
  i0, i1, i2, i3: Integer;
  P00, P10, P11, P01: TVector3;

  procedure Bump(AUl, AUr, AYb, AYt: Single);
  begin
    if not B.HasAny then
    begin
      B.HasAny := True;
      B.MinU := AUl; B.MaxU := AUr; B.MinY := AYb; B.MaxY := AYt;
    end
    else
    begin
      if AUl < B.MinU then B.MinU := AUl;
      if AUr > B.MaxU then B.MaxU := AUr;
      if AYb < B.MinY then B.MinY := AYb;
      if AYt > B.MaxY then B.MaxY := AYt;
    end;
  end;

begin
  if S = '' then Exit;
  IW := Atlas.ImageWidth;
  IH := Atlas.ImageHeight;
  LineW := Atlas.Font.TextWidth(S) * SScale;

  PenLx := 0;
  Iter.Start(S);
  while Iter.GetNext do
  begin
    G := Atlas.Font.Glyph(Iter.Current, True);
    if G = nil then Continue;

    { Layout 1:1 with TCastleFont.Print (left = pen - G.X*scale, bottom = baseline - G.Y*scale).
      Both the atlas rect and the quad size come from GlyphDrawImageRect (it subtracts the bilinear
      padding; raw ImageX/Width must not be used). }
    R := Atlas.Font.GlyphDrawImageRect(G);
    GlLeft   := PenLx - G.X * SScale;
    GlBottom := -G.Y * SScale;                 { относительно baseline }
    GW := R.Width  * SScale;
    GH := R.Height * SScale;

    if (GW > 0) and (GH > 0) then
    begin
      { локальный lx∈[GlLeft, GlLeft+GW] → U = lx - LineW (правый край = 0) }
      UL := GlLeft - LineW;
      UR := GlLeft + GW - LineW;
      YB := BaselineY + GlBottom;
      YT := BaselineY + GlBottom + GH;

      { UV: image и X3D-текстура обе bottom-up → без переворота V }
      U0 := R.Left / IW;
      U1 := (R.Left + R.Width) / IW;
      V0 := R.Bottom / IH;
      V1 := (R.Bottom + R.Height) / IH;

      P00 := WallPt(PRx, PRz, RX, RZ, N3, UL, YB, GlyphOff);
      P10 := WallPt(PRx, PRz, RX, RZ, N3, UR, YB, GlyphOff);
      P11 := WallPt(PRx, PRz, RX, RZ, N3, UR, YT, GlyphOff);
      P01 := WallPt(PRx, PRz, RX, RZ, N3, UL, YT, GlyphOff);

      { CCW со стороны наблюдателя снаружи (front смотрит по +N3).
        V += VBias кодирует стиль (0 дом / 4 place) для палитры в FS. }
      i0 := Mesh.AddVertex(P00, N3, MakeUV(U0, V0 + VBias));
      i1 := Mesh.AddVertex(P10, N3, MakeUV(U1, V0 + VBias));
      i2 := Mesh.AddVertex(P11, N3, MakeUV(U1, V1 + VBias));
      i3 := Mesh.AddVertex(P01, N3, MakeUV(U0, V1 + VBias));
      Mesh.AddQuad(i0, i1, i2, i3);

      Bump(UL, UR, YB, YT);
    end;

    PenLx := PenLx + G.AdvanceX * SScale;
  end;
end;

{ Фоновый квад под выложенным текстом (sentinel-UV). }
procedure AppendBackplate(Mesh: TMesh; const PRx, PRz, RX, RZ: Single;
  const N3: TVector3; const B: TPlateBounds; BackOff, SentU: Single);
var
  UL, UR, YB, YT: Single;
  i0, i1, i2, i3: Integer;
  P00, P10, P11, P01: TVector3;
  Sent: TVector2;
begin
  if not B.HasAny then Exit;
  UL := B.MinU - PLATE_PAD_X;
  UR := B.MaxU + PLATE_PAD_X;
  YB := B.MinY - PLATE_PAD_Y;
  YT := B.MaxY + PLATE_PAD_Y;
  Sent := MakeUV(SentU, SentU);

  P00 := WallPt(PRx, PRz, RX, RZ, N3, UL, YB, BackOff);
  P10 := WallPt(PRx, PRz, RX, RZ, N3, UR, YB, BackOff);
  P11 := WallPt(PRx, PRz, RX, RZ, N3, UR, YT, BackOff);
  P01 := WallPt(PRx, PRz, RX, RZ, N3, UL, YT, BackOff);

  i0 := Mesh.AddVertex(P00, N3, Sent);
  i1 := Mesh.AddVertex(P10, N3, Sent);
  i2 := Mesh.AddVertex(P11, N3, Sent);
  i3 := Mesh.AddVertex(P01, N3, Sent);
  Mesh.AddQuad(i0, i1, i2, i3);
end;

type
  { Высотный контекст фасада дома — единый источник для адресной и POI-табличек
    (та же математика, что у фасада Osm3dGeomBuildings: база цоколя, карниз,
    высота стены, высота этажа, верх окна 1-го этажа, число этажей). EaveY —
    по НЕзажатой WallH; FloorH — по зажатой (как в исходном расчёте). }
  TPlateHeightCtx = record
    MaxGY, BaseY, EaveY, WallH, FloorH, WinTopY: Single;
    Levels: Integer;
  end;

{ Height/levels/roof EXACTLY as the facade Build (Osm3dGeomBuildings), or the floor tile and the
  inter-tile seam won't match. Facade wall: V linear 0..Levels from BaseY to EaveY, so tile size =
  WallH/Levels for any level source. Ring is already CCW from the caller. }
function ComputeBuildingHeightCtx(Way: TOSMWay; Dataset: TOSMDataset;
  Terrain: TTerrainSampler; HM: THeightmap; const Ring: TV3Array): TPlateHeightCtx;
var
  MinH, RoofH, TotalH, Area: Single;
  RShape: TRoofShape;
  OnlyRoof: Boolean;
  Levels: Integer;
begin
  Result.MaxGY := FootprintMaxGroundY(Way, Dataset, Terrain, HM);
  RShape   := ParseRoofShape(Way.Tags);
  Levels   := ParseLevels(Way.Tags);
  MinH     := TBuildingBuilder.ParseMinHeight(Way.Tags);
  OnlyRoof := LowerCase(Trim(Way.Tags.Get('building'))) = 'roof';

  { явная высота (тег); -1 → «нет тега» }
  TotalH := TBuildingBuilder.ParseHeight(Way.Tags, Way.Id, -1.0);
  if TotalH <= 0 then TotalH := 0;

  { нет ни высоты, ни этажей → оценка по площади контура (как фасад) }
  if (TotalH <= 0) and (Levels <= 0) then
  begin
    Area   := Abs(PolygonSignedAreaXZ(Ring));            { real area — roof shape }
    { same normal-proportion levels rule as Build, or the plate height would
      no longer match the facade for long narrow buildings. }
    Levels := EstimateLevelsFromArea(EffectiveAreaForLevels(Ring));
    if not RoofShapeIsTagged(Way.Tags) then
      RShape := EstimateRoofShapeFromArea(Area);
  end;

  { крыша: плоская → 0; купол/лук/полуцилиндр → ≥8 м }
  if RShape = rsFlat then
    RoofH := 0
  else
  begin
    RoofH := TBuildingBuilder.ParseRoofHeight(Way.Tags);
    if (RShape = rsDome) or (RShape = rsOnion) or (RShape = rsRound) then
      if RoofH < 6.0 then RoofH := 8.0;
  end;

  { достроить недостающее как фасад }
  if (TotalH <= 0) and (Levels > 0) then
    TotalH := Levels * WALL_LEVEL_HEIGHT_M + RoofH
  else if Levels <= 0 then
    Levels := Round(Max(1.0, (TotalH - RoofH) / WALL_LEVEL_HEIGHT_M));

  if OnlyRoof then MinH := Max(0.0, TotalH - RoofH);            { building=roof }
  if RoofH > TotalH - MinH then RoofH := Max(0.0, TotalH - MinH);  { кап крыши }

  Result.BaseY := Result.MaxGY + BUILDING_FOUNDATION_LIFT_M + MinH; { = GroundY + MinH }
  Result.WallH := TotalH - MinH - RoofH;
  Result.EaveY := Result.BaseY + Result.WallH;        { по НЕзажатой WallH }
  if Levels < 1 then Levels := 1;
  if Result.WallH < 1.0 then Result.WallH := 1.0;     { страховка от вырожденных }
  Result.FloorH := Result.WallH / Levels;  { = размер плитки фасада (шаг швов V=1) }
  Result.WinTopY := Result.BaseY + PLATE_WINDOW_TOP_V * Result.FloorH; { верх окна 1 эт }
  Result.Levels := Levels;
end;

{ Y базовой линии ОДНОЙ строки таблички, привязанной к высоте адресного номера
  (правило «нет улицы»: многоэтажка — центр простенка 1↔2 этажа; 1 этаж — над
  окном с прижимом под карниз; затем нижний клэмп над базой). LineEM — кегль
  строки в мире. При LineEM=PLATE_NUMBER_EM совпадает с базовой линией номера. }
function PlateSignBaselineY(const Ctx: TPlateHeightCtx; LineEM: Single): Single;
var
  Y, TopY, OverY: Single;
begin
  if Ctx.Levels >= 2 then
    { центр блока (одной строки) = центр простенка = BaseY + FloorH }
    Y := (Ctx.BaseY + Ctx.FloorH) - LineEM * 0.5
  else
  begin
    { 1 этаж: над окном, рост вверх }
    Y := Ctx.WinTopY + PLATE_ABOVE_WINDOW_M + PLATE_PAD_Y;
    TopY := Y + LineEM + PLATE_PAD_Y;
    { не выше карниза, но и не в окно }
    OverY := TopY - (Ctx.EaveY - PLATE_ROOF_MARGIN);
    if OverY > 0 then
    begin
      if OverY > (Y - Ctx.WinTopY) then OverY := Y - Ctx.WinTopY;
      if OverY < 0 then OverY := 0;
      Y := Y - OverY;
    end;
  end;
  { не ниже минимума над базой }
  if Y < Ctx.BaseY + PLATE_MIN_SIGN_TOP then
    Y := Ctx.BaseY + PLATE_MIN_SIGN_TOP;
  Result := Y;
end;

{ Одна табличка на фасаде здания. True — геометрия выложена; CenX/CenZ —
  центроид (мировой XZ) для тайл-якоря. }
function AppendBuildingPlate(Mesh: TMesh; Way: TOSMWay; Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection; Terrain: TTerrainSampler;
  const RoadPts: TV2Array; const RoadGrid: TPtGrid; Atlas: TPlateGlyphAtlas;
  const Street, Number: string; out CenX, CenZ: Single;
  out Reason: string; Log: TLogProc): Boolean;
var
  Ring: TV3Array;
  Cen:  TVector2;
  N3:   TVector3;
  V0x, V0z, V1x, V1z, Nx, Nz, ELen: Single;
  ERx, ERz, PRx, PRz: Single;          { rightDir(XZ)=ребро V0→V1; PR=правый край }
  BaseY, EaveY, FloorH: Single;
  WinTopY, TopY, OverY, PlateTextH: Single;
  NumScale, StrScale, NumW, StrW, PlateW, AvailW, Sc, RightU, LeftU: Single;
  Levels: Integer;
  Ctx: TPlateHeightCtx;
  StrBaselineY, NumBaselineY: Single;
  HasStreet: Boolean;
  B: TPlateBounds;
  NumS, StrS: string;
  Dbg: Boolean;
  LLd: TLatLon;
begin
  Result := False;
  Reason := '';
  CenX := 0; CenZ := 0;
  Dbg := Assigned(Log) and (PlateDebugWayId <> 0) and (Way.Id = PlateDebugWayId);
  if Dbg then Log(Format('plate[%d] ENTER street="%s" num="%s"',
    [Way.Id, Street, Number]));
  if not BuildRing(Way, Dataset, Projection, Ring) then
  begin
    Reason := 'ring';
    if Dbg then Log(Format('plate[%d] FAIL ring (nodes=%d)',
      [Way.Id, Length(Way.NodeRefs)]));
    Exit;
  end;

  { Контур → CCW (как у стен), тогда наружная нормаль ребра = cross(edgeDir,Up). }
  EnsureCCWXZ(Ring);
  Cen := PolygonCentroidXZ(Ring);
  CenX := Cen.X; CenZ := Cen.Y;

  { Высота / этажи / крыша — единый расчёт (тот же, что у POI-табличек). }
  Ctx := ComputeBuildingHeightCtx(Way, Dataset, Terrain, HM, Ring);
  BaseY   := Ctx.BaseY;
  EaveY   := Ctx.EaveY;
  FloorH  := Ctx.FloorH;
  WinTopY := Ctx.WinTopY;
  Levels  := Ctx.Levels;

  if Dbg then
  begin
    LLd := Projection.Unproject(CenX, CenZ);
    Log(Format('plate[%d] cenXZ=%.1f %.1f  lat=%.6f lon=%.6f',
      [Way.Id, CenX, CenZ, LLd.Lat, LLd.Lon]));
    Log(Format('plate[%d] maxGround=%.2f base=%.2f eave=%.2f wallH=%.2f levels=%d floorH=%.2f winTop=%.2f',
      [Way.Id, Ctx.MaxGY, BaseY, EaveY, Ctx.WallH, Levels, FloorH, WinTopY]));
  end;

  { --- Лицевое ребро (реальная стена, не угол OMBB) --- }
  if not PickFacadeEdge(Ring, RoadPts, RoadGrid, V0x, V0z, V1x, V1z, Nx, Nz, ELen) then
  begin
    Reason := 'facade';
    if Dbg then Log(Format('plate[%d] FAIL facade (ringN=%d roadPts=%d)',
      [Way.Id, Length(Ring), Length(RoadPts)]));
    Exit;
  end;
  N3 := Vector3(Nx, 0, Nz);
  { rightDir наблюдателя вдоль стены = направление ребра V0→V1 (для наружной
    нормали cross(edgeDir,Up)); правый конец фасада — у V1. }
  ERx := (V1x - V0x) / ELen;
  ERz := (V1z - V0z) / ELen;
  if Dbg then
    Log(Format('plate[%d] facade V0=(%.1f %.1f) V1=(%.1f %.1f) N=(%.2f %.2f) len=%.2f',
      [Way.Id, V0x, V0z, V1x, V1z, Nx, Nz, ELen]));

  { --- Текст + ширина таблички (вписать в стену) --- }
  NumS := Trim(Number);
  StrS := Trim(Street);
  HasStreet := StrS <> '';
  NumScale := PLATE_NUMBER_EM / Atlas.FontSizePx;
  StrScale := PLATE_STREET_EM / Atlas.FontSizePx;
  NumW := Atlas.Font.TextWidth(NumS) * NumScale;
  if HasStreet then StrW := Atlas.Font.TextWidth(StrS) * StrScale else StrW := 0;
  PlateW := Max(NumW, StrW) + 2 * PLATE_PAD_X;

  { Шире стены — уменьшить шрифт (до предела) и пересчитать. }
  AvailW := ELen - 2 * PLATE_EDGE_MARGIN;
  if (AvailW > 0.5) and (PlateW > AvailW) then
  begin
    Sc := AvailW / PlateW;
    if Sc < PLATE_MIN_FONT_SCALE then Sc := PLATE_MIN_FONT_SCALE;
    NumScale := NumScale * Sc;
    StrScale := StrScale * Sc;
    NumW := Atlas.Font.TextWidth(NumS) * NumScale;
    if HasStreet then StrW := Atlas.Font.TextWidth(StrS) * StrScale else StrW := 0;
    PlateW := Max(NumW, StrW) + 2 * PLATE_PAD_X;
  end;

  { Правый край у конца V1 (с отступом), но не вылезать за начало ребра. }
  RightU := ELen - PLATE_EDGE_MARGIN;
  LeftU  := RightU - PlateW;
  if LeftU < PLATE_EDGE_MARGIN then
    RightU := PLATE_EDGE_MARGIN + PlateW;          { сдвинуть вправо, чтобы влезло }
  if RightU > ELen - 0.01 then RightU := ELen - 0.01;
  PRx := V0x + ERx * RightU;
  PRz := V0z + ERz * RightU;

  { --- Базовые линии по высоте ---
    Многоэтажка (Levels>=2): ЦЕНТРИРУЕМ табличку в простенке между окнами 1-го и
    2-го этажей (центр простенка = BaseY + FloorH) — максимальный зазор от обоих
    окон. Раньше низ ставился вплотную над окном 1-го этажа (+~0.15 м), и на части
    домов табличка липла к верхней кромке окна («низко/на окне»). 1 этаж: над
    окном с прижимом под карниз (не опускаясь в окно). Номер — нижняя строка,
    улица — верхняя; PlateTextH — высота блока текста. }
  if HasStreet then
    PlateTextH := PLATE_NUMBER_EM + PLATE_LINE_GAP + PLATE_STREET_EM
  else
    PlateTextH := PLATE_NUMBER_EM;

  if Levels >= 2 then
  begin
    { центр блока текста (и фона) = центр простенка = BaseY + FloorH }
    NumBaselineY := (BaseY + FloorH) - PlateTextH * 0.5;
    if HasStreet then
      StrBaselineY := NumBaselineY + PLATE_NUMBER_EM + PLATE_LINE_GAP
    else
      StrBaselineY := 0;
  end
  else
  begin
    { 1 этаж: над окном, рост вверх }
    NumBaselineY := WinTopY + PLATE_ABOVE_WINDOW_M + PLATE_PAD_Y;
    if HasStreet then
    begin
      StrBaselineY := NumBaselineY + PLATE_NUMBER_EM + PLATE_LINE_GAP;
      TopY := StrBaselineY + PLATE_STREET_EM + PLATE_PAD_Y;
    end
    else
    begin
      StrBaselineY := 0;
      TopY := NumBaselineY + PLATE_NUMBER_EM + PLATE_PAD_Y;
    end;
    { не выше карниза, но и не в окно: сдвиг вниз не ниже верха окна }
    OverY := TopY - (EaveY - PLATE_ROOF_MARGIN);
    if OverY > 0 then
    begin
      if OverY > (NumBaselineY - WinTopY) then OverY := NumBaselineY - WinTopY;
      if OverY < 0 then OverY := 0;
      NumBaselineY := NumBaselineY - OverY;
      if HasStreet then StrBaselineY := StrBaselineY - OverY;
    end;
  end;
  { Не ниже минимума над базой (защита от абсурдно низкого этажа). }
  if NumBaselineY < BaseY + PLATE_MIN_SIGN_TOP then
  begin
    OverY := (BaseY + PLATE_MIN_SIGN_TOP) - NumBaselineY;
    NumBaselineY := NumBaselineY + OverY;
    if HasStreet then StrBaselineY := StrBaselineY + OverY;
  end;

  B.HasAny := False;
  { глифы — на волосок ближе фона (выигрывают глубину); оба непрозрачны.
    Стиль дома: белый текст на синем (VBias=0). }
  AppendLine(Mesh, Atlas, NumS, NumScale, NumBaselineY,
             PRx, PRz, ERx, ERz, N3, PLATE_GLYPH_OFFSET, STYLE_HOUSE_VBIAS, B);
  if HasStreet then
    AppendLine(Mesh, Atlas, StrS, StrScale, StrBaselineY,
               PRx, PRz, ERx, ERz, N3, PLATE_GLYPH_OFFSET, STYLE_HOUSE_VBIAS, B);

  AppendBackplate(Mesh, PRx, PRz, ERx, ERz, N3, B, PLATE_BACK_OFFSET, PLATE_SENT_BLUE);
  Result := B.HasAny;
  if not Result then Reason := 'glyph';

  { Лог по КАЖДОЙ успешной домовой табличке: адрес + все величины расчёта высоты
    (вход: totalH/minH/roofH/wallH/levels/floorH/maxGround/base/eave/winTop;
    выход: базовые линии номера/улицы и итоговый размах spanY). }
  if Result and Assigned(Log) then
  begin
    LLd := Projection.Unproject(CenX, CenZ);
    //Log(Format('plate OK way=%d street="%s" num="%s" @%.6f,%.6f | totalH=%.2f minH=%.2f roofH=%.2f wallH=%.2f levels=%d floorH=%.2f maxGround=%.2f base=%.2f eave=%.2f winTop=%.2f numBase=%.2f strBase=%.2f spanY=%.2f..%.2f',
    //  [Way.Id, Street, Number, LLd.Lat, LLd.Lon,
    //   TotalH, MinH, RoofH, WallH, Levels, FloorH,
    //   MaxGY, BaseY, EaveY, WinTopY, NumBaselineY, StrBaselineY, B.MinY, B.MaxY]));
  end;

  if Dbg then
  begin
    if Result then
      Log(Format('plate[%d] OK glyphs spanY=%.2f..%.2f PRxz=%.1f %.1f plateW=%.2f',
        [Way.Id, B.MinY, B.MaxY, PRx, PRz, PlateW]))
    else
      Log(Format('plate[%d] FAIL glyph (empty/unrenderable num="%s")',
        [Way.Id, NumS]));
  end;
end;

type
  TBoolArray = array of Boolean;
  { POI с именем (узел shop/amenity/... + name), спроецированный в мир (XZ). }
  TNamedPOI = record
    Id:   Int64;
    Name: string;
    X, Z: Single;
  end;
  TNamedPOIArray = array of TNamedPOI;

{ Узел — именованный POI: есть непустой name И один из «точечных» тегов. }
function IsNamedPOINode(Node: TOSMNode): Boolean;
begin
  Result := (Trim(Node.Tags.Get('name')) <> '')
        and ( (Trim(Node.Tags.Get('shop'))       <> '')
           or (Trim(Node.Tags.Get('amenity'))    <> '')
           or (Trim(Node.Tags.Get('office'))     <> '')
           or (Trim(Node.Tags.Get('tourism'))    <> '')
           or (Trim(Node.Tags.Get('leisure'))    <> '')
           or (Trim(Node.Tags.Get('craft'))      <> '')
           or (Trim(Node.Tags.Get('healthcare')) <> '') );
end;

{ Все именованные POI-узлы датасета → мировые XZ (один раз на сцену). }
function CollectNamedPOIs(Dataset: TOSMDataset;
  Projection: TLocalProjection): TNamedPOIArray;
var
  Node: TOSMNode;
  Cnt:  Integer;
  P:    TVector3;
begin
  Result := nil;
  Cnt := 0;
  for Node in Dataset.Nodes.Values do
  begin
    if not IsNamedPOINode(Node) then Continue;
    if Cnt >= Length(Result) then
    begin
      if Length(Result) = 0 then SetLength(Result, 64)
      else SetLength(Result, Length(Result) * 2);
    end;
    if Dataset.LatticeReady then
    begin
      { int-first: точные решёточные координаты узла (мировая решётка 1/64 м
        минус целый сдвиг блока) — побитно одинаковы во всех блоках halo,
        см. Osm3dOsmData.PrecomputeLattice }
      P.X := Node.LatticeX * (1.0 / 64.0);
      P.Y := 0;
      P.Z := Node.LatticeZ * (1.0 / 64.0);
    end
    else
    begin
      P := Projection.Project(Node.Position, 0);
      P.X := Round(P.X * 64.0) * (1.0 / 64.0);
      P.Z := Round(P.Z * 64.0) * (1.0 / 64.0);
    end;
    Result[Cnt].Id   := Node.Id;
    Result[Cnt].Name := Trim(Node.Tags.Get('name'));
    Result[Cnt].X    := P.X;
    Result[Cnt].Z    := P.Z;
    Inc(Cnt);
  end;
  SetLength(Result, Cnt);
end;

{ Uniform grid по POI (разделяет BuildAll между всеми зданиями тайла).
  Координаты копируются во временный TV2Array — построение общее с дорожными
  точками. }
function BuildPOIGrid(const POIs: TNamedPOIArray): TPtGrid;
var
  Pts: TV2Array;
  I: Integer;
begin
  SetLength(Pts, Length(POIs));
  for I := 0 to High(POIs) do
  begin
    Pts[I].X := POIs[I].X;
    Pts[I].Y := POIs[I].Z;
  end;
  Result := BuildV2Grid(Pts);
end;

{ Ближайшее РЕБРО контура к точке (PX,PZ) и ближайшая точка Q на нём. Возвращает
  начало ребра A (Ax,Az), точку Q (Qx,Qz), единичное направление ребра (EDx,EDz),
  наружную нормаль (Nx,Nz = cross(edgeDir,Up), как у стен — контур CCW), длину
  ребра EdgeLen и параметр Uq точки Q вдоль ребра (0..EdgeLen). False — вырожден. }
function NearestRingEdge(const Ring: TV3Array; PX, PZ: Single;
  out Ax, Az, Qx, Qz, EDx, EDz, Nx, Nz, EdgeLen, Uq: Single): Boolean;
var
  N, I, J, BestI: Integer;
  ex, ez, len, t, qx_, qz_, dx, dz, d2, best2, bestT: Single;
begin
  Result := False;
  N := Length(Ring);
  if N < 3 then Exit;
  BestI := -1; best2 := MaxSingle; bestT := 0;
  for I := 0 to N - 1 do
  begin
    J := (I + 1) mod N;
    ex := Ring[J].X - Ring[I].X;
    ez := Ring[J].Z - Ring[I].Z;
    len := Sqrt(ex * ex + ez * ez);
    if len < 1.0e-3 then Continue;
    { параметр проекции вдоль единичного направления, зажатый в отрезок }
    t := ((PX - Ring[I].X) * ex + (PZ - Ring[I].Z) * ez) / len;
    if t < 0 then t := 0 else if t > len then t := len;
    qx_ := Ring[I].X + (ex / len) * t;
    qz_ := Ring[I].Z + (ez / len) * t;
    dx := PX - qx_; dz := PZ - qz_;
    d2 := dx * dx + dz * dz;
    if d2 < best2 then begin best2 := d2; BestI := I; bestT := t; end;
  end;
  if BestI < 0 then Exit;
  J := (BestI + 1) mod N;
  ex := Ring[J].X - Ring[BestI].X;
  ez := Ring[J].Z - Ring[BestI].Z;
  EdgeLen := Sqrt(ex * ex + ez * ez);
  if EdgeLen < 1.0e-3 then Exit;
  EDx := ex / EdgeLen; EDz := ez / EdgeLen;
  Nx  := -ez / EdgeLen; Nz := ex / EdgeLen;     { наружная нормаль (CCW) }
  Ax  := Ring[BestI].X; Az := Ring[BestI].Z;
  Uq  := bestT;
  Qx  := Ax + EDx * Uq; Qz := Az + EDz * Uq;
  Result := True;
end;

{ POI-таблички для одного здания: каждый именованный POI, попадающий В контур,
  вешается на ближайшую точку ближайшей стены на высоте адреса. Цвет — псевдо-
  случайный по id узла. Consumed[] помечает уже использованные POI (чтобы
  пересекающиеся building/building:part не дублировали). Anchors/AnchorCount/Made
  — общие с домовыми табличками (тайлинг и лимит PLATE_MAX). Возвращает число
  выложенных табличек. }
function AppendBuildingPOIPlates(Mesh: TMesh; Way: TOSMWay; Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection; Terrain: TTerrainSampler;
  Atlas: TPlateGlyphAtlas; const POIs: TNamedPOIArray; const POIGrid: TPtGrid;
  var Consumed: TBoolArray; var Anchors: TPlateTileAnchorArray;
  var AnchorCount, Made: Integer): Integer;
var
  Ring: TV3Array;
  Ctx:  TPlateHeightCtx;
  BaselineY: Single;
  MinX, MinZ, MaxX, MaxZ: Single;
  Pix, ColorIdx, VStart, TStart: Integer;
  Cand: array of Integer;
  NCand, Ci2, Cx, Cz, CI, K2, LoCx, HiCx, LoCz, HiCz: Integer;
  PX, PZ: Single;
  Ax, Az, Qx, Qz, EDx, EDz, Nx, Nz, EdgeLen, Uq: Single;
  Name: string;
  Scale, LineW, PlateW, AvailW, Sc, HalfW, Lo, Hi, Uc, PRu, PRx, PRz: Single;
  SentU, VBias: Single;
  N3: TVector3;
  B: TPlateBounds;
begin
  Result := 0;
  if Length(POIs) = 0 then Exit;
  if not BuildRing(Way, Dataset, Projection, Ring) then Exit;
  EnsureCCWXZ(Ring);

  { bbox контура для быстрого отсева }
  MinX := Ring[0].X; MaxX := MinX; MinZ := Ring[0].Z; MaxZ := MinZ;
  for Pix := 1 to High(Ring) do
  begin
    if Ring[Pix].X < MinX then MinX := Ring[Pix].X;
    if Ring[Pix].X > MaxX then MaxX := Ring[Pix].X;
    if Ring[Pix].Z < MinZ then MinZ := Ring[Pix].Z;
    if Ring[Pix].Z > MaxZ then MaxZ := Ring[Pix].Z;
  end;

  Ctx := ComputeBuildingHeightCtx(Way, Dataset, Terrain, HM, Ring);
  BaselineY := PlateSignBaselineY(Ctx, PLATE_POI_EM);

  { Кандидаты: при построенном индексе — только POI из ячеек bbox контура
    (надмножество старого полного перебора: внутренняя bbox-проверка ниже
    оставлена и отсекает лишних точно так же). Обработка строго в исходном
    порядке индексов — набор пар, порядок вершин и PLATE_MAX-Break
    неизменны. }
  if POIGrid.Cols > 0 then
  begin
    LoCx := Floor((MinX - POIGrid.MinX) / POIGrid.Cell);
    HiCx := Floor((MaxX - POIGrid.MinX) / POIGrid.Cell);
    LoCz := Floor((MinZ - POIGrid.MinZ) / POIGrid.Cell);
    HiCz := Floor((MaxZ - POIGrid.MinZ) / POIGrid.Cell);
    if LoCx < 0 then LoCx := 0;
    if HiCx >= POIGrid.Cols then HiCx := POIGrid.Cols - 1;
    if LoCz < 0 then LoCz := 0;
    if HiCz >= POIGrid.Rows then HiCz := POIGrid.Rows - 1;
    NCand := 0; Cand := nil;
    for Cz := LoCz to HiCz do
      for Cx := LoCx to HiCx do
      begin
        CI := Cz * POIGrid.Cols + Cx;
        for K2 := POIGrid.Offs[CI] to POIGrid.Offs[CI + 1] - 1 do
        begin
          if NCand >= Length(Cand) then
          begin
            if Length(Cand) = 0 then SetLength(Cand, 64)
            else SetLength(Cand, Length(Cand) * 2);
          end;
          Cand[NCand] := POIGrid.Items[K2];
          Inc(NCand);
        end;
      end;
    if NCand > 1 then SortInts(Cand, 0, NCand - 1);
  end
  else
  begin
    NCand := Length(POIs);
    SetLength(Cand, NCand);
    for Pix := 0 to NCand - 1 do Cand[Pix] := Pix;
  end;

  for Ci2 := 0 to NCand - 1 do
  begin
    Pix := Cand[Ci2];
    if Consumed[Pix] then Continue;
    if Made >= PLATE_MAX then Break;
    PX := POIs[Pix].X; PZ := POIs[Pix].Z;
    if (PX < MinX) or (PX > MaxX) or (PZ < MinZ) or (PZ > MaxZ) then Continue;
    if not PointInPolygonXZ(Vector3(PX, 0, PZ), Ring) then Continue;

    { POI принадлежит этому контуру — больше не отдаём его другим зданиям }
    Consumed[Pix] := True;

    if not NearestRingEdge(Ring, PX, PZ,
         Ax, Az, Qx, Qz, EDx, EDz, Nx, Nz, EdgeLen, Uq) then Continue;

    Name  := POIs[Pix].Name;
    Scale := PLATE_POI_EM / Atlas.FontSizePx;
    LineW := Atlas.Font.TextWidth(Name) * Scale;
    PlateW := LineW + 2 * PLATE_PAD_X;

    { шире стены — уменьшить шрифт (до предела) }
    AvailW := EdgeLen - 2 * PLATE_EDGE_MARGIN;
    if (AvailW > 0.5) and (PlateW > AvailW) then
    begin
      Sc := AvailW / PlateW;
      if Sc < PLATE_MIN_FONT_SCALE then Sc := PLATE_MIN_FONT_SCALE;
      Scale := Scale * Sc;
      LineW := Atlas.Font.TextWidth(Name) * Scale;
      PlateW := LineW + 2 * PLATE_PAD_X;
    end;

    { центрируем фон (ширины PlateW) на Q вдоль стены, не вылезая за концы }
    HalfW := PlateW * 0.5;
    Lo := PLATE_EDGE_MARGIN + HalfW;
    Hi := EdgeLen - PLATE_EDGE_MARGIN - HalfW;
    Uc := Uq;
    if Lo <= Hi then
    begin
      if Uc < Lo then Uc := Lo;
      if Uc > Hi then Uc := Hi;
    end
    else
      Uc := EdgeLen * 0.5;            { стена уже PlateW даже после ужатия — центр }

    { правый край текста (U=0) — на полстроки правее центра }
    PRu := Uc + LineW * 0.5;
    PRx := Ax + EDx * PRu;
    PRz := Az + EDz * PRu;
    N3  := Vector3(Nx, 0, Nz);

    ColorIdx := Integer(HashInt64(POIs[Pix].Id) mod LongWord(PLATE_POI_COLOR_COUNT));
    SentU := -(PLATE_SENT_POI_BASE + ColorIdx);
    VBias := (PLATE_STYLE_POI_BASE + ColorIdx) * PLATE_STYLE_VSTEP;

    B.HasAny := False;
    Mesh.CurrentOsmId := POIs[Pix].Id;
    VStart := Mesh.VertexCount;
    TStart := Mesh.TriangleCount;
    AppendLine(Mesh, Atlas, Name, Scale, BaselineY,
               PRx, PRz, EDx, EDz, N3, PLATE_GLYPH_OFFSET, VBias, B);
    AppendBackplate(Mesh, PRx, PRz, EDx, EDz, N3, B, PLATE_BACK_OFFSET, SentU);
    Mesh.CurrentOsmId := 0;
    if not B.HasAny then Continue;   { имя нерисуемо — ничего не выложено }

    { якорь тайлинга: вся табличка едет в тайл точки крепления Q }
    AppendPlateAnchor(Anchors, AnchorCount, Qx, Qz,
      VStart, Mesh.VertexCount, TStart, Mesh.TriangleCount);
    Inc(Made);
    Inc(Result);
  end;
end;

type
  { Полигон НП (place) — для въездных табличек. }
  TPlaceArea = record
    Id:   Int64;
    Name: string;
    Ring: TV3Array;                 { замкнутый контур CCW, Y=0 }
    MinX, MinZ, MaxX, MaxZ: Single; { bbox для быстрого отсева }
  end;
  TPlaceAreaArray = array of TPlaceArea;

{ Пересечение отрезка A→B с отрезком C→D в плоскости XZ. True + точка P и
  параметр T (доля вдоль A→B), если пересекаются строго внутри обоих. }
function SegSegXZ(const A, B, C, D: TVector3; out P: TVector3; out T: Single): Boolean;
var
  r1, r2, s1, s2, denom, u: Single;
begin
  Result := False; T := 0;
  r1 := B.X - A.X; r2 := B.Z - A.Z;
  s1 := D.X - C.X; s2 := D.Z - C.Z;
  denom := r1 * s2 - r2 * s1;
  if Abs(denom) < 1e-9 then Exit;                 { параллельны }
  T := ((C.X - A.X) * s2 - (C.Z - A.Z) * s1) / denom;
  u := ((C.X - A.X) * r2 - (C.Z - A.Z) * r1) / denom;
  if (T < 0) or (T > 1) or (u < 0) or (u > 1) then Exit;
  P.X := A.X + T * r1; P.Y := 0; P.Z := A.Z + T * r2;
  Result := True;
end;

{ Квад фона (sentinel-UV) по произвольному прямоугольнику в плоскости таблички. }
procedure AppendSentinelQuad(Mesh: TMesh; const PRx, PRz, RX, RZ: Single;
  const N3: TVector3; UL, UR, YB, YT, Off, SentU: Single);
var
  i0, i1, i2, i3: Integer;
  P00, P10, P11, P01: TVector3;
  Sent: TVector2;
begin
  Sent := MakeUV(SentU, SentU);
  P00 := WallPt(PRx, PRz, RX, RZ, N3, UL, YB, Off);
  P10 := WallPt(PRx, PRz, RX, RZ, N3, UR, YB, Off);
  P11 := WallPt(PRx, PRz, RX, RZ, N3, UR, YT, Off);
  P01 := WallPt(PRx, PRz, RX, RZ, N3, UL, YT, Off);
  i0 := Mesh.AddVertex(P00, N3, Sent);
  i1 := Mesh.AddVertex(P10, N3, Sent);
  i2 := Mesh.AddVertex(P11, N3, Sent);
  i3 := Mesh.AddVertex(P01, N3, Sent);
  Mesh.AddQuad(i0, i1, i2, i3);
end;

{ Красная диагональ (выездная табличка): тонкая повёрнутая лента из угла (UL,YB)
  в угол (UR,YT) в плоскости таблички, полутолщина HalfW. SentU = PLATE_SENT_RED. }
procedure AppendDiagStripe(Mesh: TMesh; const PRx, PRz, RX, RZ: Single;
  const N3: TVector3; UL, UR, YB, YT, Off, HalfW, SentU: Single);
var
  du, dy, len, pu, py: Single;
  i0, i1, i2, i3: Integer;
  P0, P1, P2, P3: TVector3;
  Sent: TVector2;
begin
  du := UR - UL; dy := YT - YB;
  len := Sqrt(du * du + dy * dy);
  if len < 1e-6 then Exit;
  du := du / len; dy := dy / len;        { орт диагонали в (U,Y) }
  pu := -dy * HalfW; py := du * HalfW;   { перпендикуляр · полутолщину }
  Sent := MakeUV(SentU, SentU);
  { CCW в (U,Y): A−perp, B−perp, B+perp, A+perp (A=(UL,YB), B=(UR,YT)) }
  P0 := WallPt(PRx, PRz, RX, RZ, N3, UL - pu, YB - py, Off);
  P1 := WallPt(PRx, PRz, RX, RZ, N3, UR - pu, YT - py, Off);
  P2 := WallPt(PRx, PRz, RX, RZ, N3, UR + pu, YT + py, Off);
  P3 := WallPt(PRx, PRz, RX, RZ, N3, UL + pu, YB + py, Off);
  i0 := Mesh.AddVertex(P0, N3, Sent);
  i1 := Mesh.AddVertex(P1, N3, Sent);
  i2 := Mesh.AddVertex(P2, N3, Sent);
  i3 := Mesh.AddVertex(P3, N3, Sent);
  Mesh.AddQuad(i0, i1, i2, i3);
end;

{ Собрать полигоны НП: замкнутые way с тегом place и name. Кольцо строится тем
  же BuildRing и приводится к CCW. (Place-узлы-точки и relation-границы здесь
  не обрабатываются — нужны площадные place для понятия «вход».) }
function CollectPlaceAreas(Dataset: TOSMDataset;
  Projection: TLocalProjection): TPlaceAreaArray;
var
  Way: TOSMWay;
  Ring: TV3Array;
  Nm: string;
  Cnt, I: Integer;
  mnx, mnz, mxx, mxz: Single;
begin
  Result := nil; Cnt := 0;
  for Way in Dataset.Ways.Values do
  begin
    if not Way.IsClosed then Continue;
    if not Way.Tags.HasKey('place') then Continue;
    Nm := Trim(Way.Tags.Get('name'));
    if Nm = '' then Continue;
    if not BuildRing(Way, Dataset, Projection, Ring) then Continue;
    EnsureCCWXZ(Ring);
    if Length(Ring) < 3 then Continue;
    mnx := Ring[0].X; mxx := mnx; mnz := Ring[0].Z; mxz := mnz;
    for I := 1 to High(Ring) do
    begin
      if Ring[I].X < mnx then mnx := Ring[I].X;
      if Ring[I].X > mxx then mxx := Ring[I].X;
      if Ring[I].Z < mnz then mnz := Ring[I].Z;
      if Ring[I].Z > mxz then mxz := Ring[I].Z;
    end;
    { Amortised O(1) growth: double capacity, trim at the end. }
    if Cnt >= Length(Result) then
      if Length(Result) = 0 then SetLength(Result, 16)
      else SetLength(Result, Length(Result) * 2);
    Result[Cnt].Id   := Way.Id;
    Result[Cnt].Name := Nm;
    Result[Cnt].Ring := Copy(Ring, 0, Length(Ring));
    Result[Cnt].MinX := mnx; Result[Cnt].MaxX := mxx;
    Result[Cnt].MinZ := mnz; Result[Cnt].MaxZ := mxz;
    Inc(Cnt);
  end;
  SetLength(Result, Cnt);   { обрезаем до фактического числа }
end;

{ Shared body of a sign-on-a-post: text panel + backplate + post, facing the driver (normal = -D),
  offset right of the axis. place/river differ only by params: VBias (text style), PanelSentU
  (panel/post colour), ExitStripe (red exit diagonal). SignX/SignZ = panel-centre world XZ. }
function AppendOneSign(Mesh: TMesh; Atlas: TPlateGlyphAtlas;
  const Text: string; const Cross, D: TVector3; GroundY: Single;
  VBias, PanelSentU: Single; ExitStripe: Boolean;
  out SignX, SignZ: Single): Boolean;
var
  RX, RZ: Single;
  N3: TVector3;
  Scale, TextW, HalfW, PRx, PRz, BaselineY, PanelBot, UC: Single;
  B: TPlateBounds;
begin
  Result := False;
  SignX := Cross.X; SignZ := Cross.Z;
  { лицом к водителю: N3 = -D; текст слева-направо для него: rightDir = cross(D,Up) }
  RX := -D.Z; RZ := D.X;
  N3 := Vector3(-D.X, 0, -D.Z);
  Scale := PLACE_SIGN_EM / Atlas.FontSizePx;
  TextW := Atlas.Font.TextWidth(Text) * Scale;
  if TextW <= 0 then Exit;
  { Панель целиком вправо от дороги: ближний (дорожный) край панели на SIDE от
    оси, поэтому центр сдвинут на полширины панели (TextW/2 + поле). }
  HalfW := TextW * 0.5 + PLATE_PAD_X;
  SignX := Cross.X + RX * (PLACE_SIGN_SIDE_M + HalfW);
  SignZ := Cross.Z + RZ * (PLACE_SIGN_SIDE_M + HalfW);
  PRx := SignX + RX * (TextW * 0.5);    { правый край текста (текст центр. на панели) }
  PRz := SignZ + RZ * (TextW * 0.5);
  BaselineY := GroundY + PLACE_SIGN_HEIGHT_M;
  B.HasAny := False;
  AppendLine(Mesh, Atlas, Text, Scale, BaselineY, PRx, PRz, RX, RZ, N3,
             PLATE_GLYPH_OFFSET, VBias, B);
  if not B.HasAny then Exit;
  AppendBackplate(Mesh, PRx, PRz, RX, RZ, N3, B, PLATE_BACK_OFFSET, PanelSentU);
  { столб: полоса фона от земли до низа панели, по центру под текстом }
  PanelBot := B.MinY - PLATE_PAD_Y;
  UC := -(TextW * 0.5);                 { локальный U центра панели }
  if PanelBot > GroundY + 0.05 then
    AppendSentinelQuad(Mesh, PRx, PRz, RX, RZ, N3,
      UC - PLACE_POST_W * 0.5, UC + PLACE_POST_W * 0.5,
      GroundY, PanelBot, PLATE_BACK_OFFSET, PanelSentU);
  { выездная табличка — красная диагональ поверх текста }
  if ExitStripe then
    AppendDiagStripe(Mesh, PRx, PRz, RX, RZ, N3,
      B.MinU - PLATE_PAD_X, B.MaxU + PLATE_PAD_X,
      B.MinY - PLATE_PAD_Y, B.MaxY + PLATE_PAD_Y,
      PLATE_STRIPE_OFFSET, PLATE_STRIPE_W * 0.5, PLATE_SENT_RED);
  Result := True;
end;

{ Одна въездная табличка: панель с названием НП у точки Cross, лицом к
  въезжающему (нормаль = -D), сдвинута вправо от оси дороги, на «столбе».
  D — единичное направление въезда (снаружи внутрь). SignX/SignZ — мировой XZ
  центра панели (для тайл-якоря). place: синий текст на белом, выезд — диагональ. }
function AppendOnePlaceSign(Mesh: TMesh; Atlas: TPlateGlyphAtlas;
  const Name: string; const Cross, D: TVector3; GroundY: Single;
  IsExit: Boolean; out SignX, SignZ: Single): Boolean;
begin
  Result := AppendOneSign(Mesh, Atlas, Name, Cross, D, GroundY,
              STYLE_PLACE_VBIAS, PLATE_SENT_WHITE, IsExit, SignX, SignZ);
end;

{ Есть ли в строке буквы кириллицы (блоки Unicode U+0400..04FF / U+0500..052F).
  Иначе считаем название латинским (европейским). }
function NameHasCyrillic(const S: string): Boolean;
var
  Iter: TCastleStringIterator;
  cp: TUnicodeChar;
begin
  Result := False;
  Iter.Start(S);
  while Iter.GetNext do
  begin
    cp := Iter.Current;
    if ((cp >= $0400) and (cp <= $04FF)) or ((cp >= $0500) and (cp <= $052F)) then
      Exit(True);
  end;
end;

{ Текст речной таблички с учётом письменности: «р. Имя» для кириллицы, для
  латиницы — европейский усреднённый вариант (по умолчанию само имя, без рода). }
function RiverSignText(const Name: string): string;
begin
  if NameHasCyrillic(Name) then
    Result := RIVER_PREFIX_CYRILLIC + Name
  else
    Result := RIVER_PREFIX_LATIN + Name;
end;

{ Одна речная табличка: панель «р. …» БЕЛЫМ по СИНЕМУ (стиль дома) у конца моста
  Cross, лицом к въезжающему (нормаль = -D, D — направление ВНУТРЬ моста), сдвинута
  вправо от оси, на «столбе» (синяя полоса фона до уровня настила). }
function AppendOneRiverSign(Mesh: TMesh; Atlas: TPlateGlyphAtlas;
  const Text: string; const Cross, D: TVector3; GroundY: Single;
  out SignX, SignZ: Single): Boolean;
begin
  { река: белый текст на синем (стиль дома), синяя подложка/столб, без диагонали }
  Result := AppendOneSign(Mesh, Atlas, Text, Cross, D, GroundY,
              STYLE_HOUSE_VBIAS, PLATE_SENT_BLUE, False, SignX, SignZ);
end;

{ Приоритет дороги для дедупа табличек: крупнее дорога — выше число. Классификацию
  не дублируем — берём готовую TRoadBuilder.ClassifyHighway. }
function RoadPriority(const Tags: TOSMTags): Single;
begin
  case TRoadBuilder.ClassifyHighway(Tags) of
    rkMajor:                                        RoadPriority := 5.0;
    rkSecondary:                                    RoadPriority := 4.0;
    rkMinor:                                        RoadPriority := 3.0;
    rkService:                                      RoadPriority := 2.0;
    rkFootway, rkCycleway, rkDirtPath, rkSandPath:  RoadPriority := 1.0;
  else                                              RoadPriority := 0.0;  { rkNone/rkRailway }
  end;
end;

{ Жадная дедупликация табличек по радиусу. Кандидаты обходятся в порядке УБЫВАНИЯ
  приоритета (Prio больше = крупнее дорога/мост); кандидат принимается, если он
  дальше R от всех уже принятых, иначе отбрасывается (рядом уже стоит табличка не
  меньшего приоритета). Grp — id группы: кандидаты ОДНОЙ группы не конфликтуют
  между собой (так два конца одного моста не «съедают» друг друга; для въездных
  Grp у всех разный — давим любые близкие). Возврат: Keep[i] — ставить ли i. }
function DedupByRadius(const K: TDedupKeyArray; Count: Integer; R2: Single): TBoolArray;
var
  n, i, j, a, b, nAcc, tmp: Integer;
  ordr, acc: array of Integer;
  dx, dz: Single;
  conflict: Boolean;
begin
  n := Count;
  Result := nil;
  SetLength(Result, n);
  for i := 0 to n - 1 do Result[i] := False;
  if n = 0 then Exit;
  { индексы по убыванию приоритета (вставками — кандидатов немного) }
  SetLength(ordr, n);
  for i := 0 to n - 1 do ordr[i] := i;
  for i := 1 to n - 1 do
  begin
    tmp := ordr[i]; j := i - 1;
    while (j >= 0) and (K[ordr[j]].Prio < K[tmp].Prio) do begin ordr[j + 1] := ordr[j]; Dec(j); end;
    ordr[j + 1] := tmp;
  end;
  SetLength(acc, n); nAcc := 0;
  for i := 0 to n - 1 do
  begin
    a := ordr[i]; conflict := False;
    for j := 0 to nAcc - 1 do
    begin
      b := acc[j];
      if K[a].Grp = K[b].Grp then Continue;   { своя группа (тот же мост) — не конфликт }
      dx := K[a].X - K[b].X; dz := K[a].Z - K[b].Z;
      if dx * dx + dz * dz < R2 then begin conflict := True; Break; end;
    end;
    if conflict then Continue;
    acc[nAcc] := a; Inc(nAcc); Result[a] := True;
  end;
end;

class procedure TPlateBuilder.AppendRiverSigns(Mesh: TMesh;
  const Signs: TRiverSignArray; Atlas: TPlateGlyphAtlas;
  var Anchors: TPlateTileAnchorArray; var AnchorCount, Made: Integer;
  Log: TLogProc);
var
  i, nC, made0: Integer;
  Txt: string;
  keys: TDedupKeyArray;     { ключи дедупа (позиция/приоритет/группа=WayId) }
  eCross, eD: TV3Array;     { данные для эмита, параллельно keys }
  eGY:  array of Single;
  eTxt: array of string;
  keep: TBoolArray;

  { Добавить конец-кандидат (вырожденное направление пропускаем сразу). }
  procedure AddEnd(const Cross, D: TVector3; GY, Prio: Single; WayId: Int64; const ATxt: string);
  var cap: Integer;
  begin
    if D.X*D.X + D.Z*D.Z < 1e-12 then Exit;   { нет направления — не ставим }
    if nC >= Length(keys) then
    begin
      if Length(keys) = 0 then cap := 64 else cap := Length(keys) * 2;
      SetLength(keys, cap); SetLength(eCross, cap); SetLength(eD, cap);
      SetLength(eGY, cap); SetLength(eTxt, cap);
    end;
    keys[nC].X := Cross.X; keys[nC].Z := Cross.Z; keys[nC].Prio := Prio; keys[nC].Grp := WayId;
    eCross[nC] := Cross; eD[nC] := D; eGY[nC] := GY; eTxt[nC] := ATxt;
    Inc(nC);
  end;

  { Поставить одну табличку по кандидату и записать её якорь. }
  procedure EmitOne(const Cross, D: TVector3; GroundY: Single; Id: Int64; const ATxt: string);
  var sx, sz: Single; vs, ts: Integer;
  begin
    if Made >= PLACE_SIGN_MAX then Exit;
    Mesh.CurrentOsmId := Id;
    vs := Mesh.VertexCount; ts := Mesh.TriangleCount;
    if AppendOneRiverSign(Mesh, Atlas, ATxt, Cross, D, GroundY, sx, sz) then
    begin
      if AnchorCount >= Length(Anchors) then
      begin
        if Length(Anchors) = 0 then SetLength(Anchors, 64)
        else SetLength(Anchors, Length(Anchors) * 2);
      end;
      Anchors[AnchorCount].AnchorX   := sx;
      Anchors[AnchorCount].AnchorZ   := sz;
      Anchors[AnchorCount].VertStart := vs;
      Anchors[AnchorCount].VertEnd   := Mesh.VertexCount;
      Anchors[AnchorCount].TriStart  := ts;
      Anchors[AnchorCount].TriEnd    := Mesh.TriangleCount;
      Inc(AnchorCount);
      Inc(Made);
    end;
    Mesh.CurrentOsmId := 0;
  end;

begin
  if (Mesh = nil) or (Atlas = nil) or (Length(Signs) = 0) then Exit;
  made0 := Made;
  { 1) собираем кандидаты-концы (по 2 на мост); приоритет = ширина моста (Prio). }
  nC := 0;
  for i := 0 to High(Signs) do
  begin
    if Trim(Signs[i].Name) = '' then Continue;
    Txt := RiverSignText(Signs[i].Name);
    { отладка: номер моста «#N» в начало (тот же, что в логе); <0 — не показывать. }
    if Signs[i].Num >= 0 then
      Txt := '#' + IntToStr(Signs[i].Num) + ' ' + Txt;
    AddEnd(Vector3(Signs[i].Ax, Signs[i].Ay, Signs[i].Az),
           Vector3(Signs[i].Adx, 0, Signs[i].Adz), Signs[i].Ay, Signs[i].Prio, Signs[i].WayId, Txt);
    AddEnd(Vector3(Signs[i].Bx, Signs[i].By, Signs[i].Bz),
           Vector3(Signs[i].Bdx, 0, Signs[i].Bdz), Signs[i].By, Signs[i].Prio, Signs[i].WayId, Txt);
  end;
  { 2) дедуп 30 м: концы РАЗНЫХ мостов (Grp=WayId) рядом — оставляем тот, что на
       более широком мосту; два конца ОДНОГО моста (одна Grp) не конфликтуют, так
       что короткий мост (концы <30 м) сохраняет обе таблички. }
  keep := DedupByRadius(keys, nC, SIGN_DEDUP_R2);
  { 3) ставим выживших (в исходном порядке). }
  for i := 0 to nC - 1 do
    if keep[i] then
      EmitOne(eCross[i], eD[i], eGY[i], keys[i].Grp, eTxt[i]);
  if Assigned(Log) then
    Log(Format('plates: river signs +%d (rivers=%d)', [Made - made0, Length(Signs)]));
end;

{ Въездные таблички: для каждого НП и каждой дороги ищем сегменты, где дорога
  пересекает границу СНАРУЖИ ВНУТРЬ, и ставим табличку у точки входа справа от
  дороги. Таблички идут в тот же Mesh и Anchors (тот же атлас/материал/тайлинг). }
procedure AppendPlaceSigns(Mesh: TMesh; Dataset: TOSMDataset; HM: THeightmap;
  Projection: TLocalProjection; Terrain: TTerrainSampler; Atlas: TPlateGlyphAtlas;
  const Places: TPlaceAreaArray; var Anchors: TPlateTileAnchorArray;
  var AnchorCount, Made: Integer; Log: TLogProc);
var
  pI, nI, eI, RN, nC, ci: Integer;
  Way: TOSMWay;
  Node: TOSMNode;
  PrevPos, CurPos, Cross, BestCross, Inward: TVector3;
  prevInside, curInside, hasPrev, found: Boolean;
  bestT, t, dl, GroundYv, prio: Single;
  MadeHere, EntrySigns, ExitSigns: Integer;
  keys: TDedupKeyArray;      { ключи дедупа пересечений ТЕКУЩЕГО НП }
  eCross, eInward: TV3Array; { данные для эмита, параллельно keys }
  eGY: array of Single;
  keep: TBoolArray;

  { Поставить одну табличку у Cr в направлении Dir и записать её якорь. }
  procedure Emit(const Cr, Dir: TVector3; GY: Single; IsExit: Boolean);
  var
    sx, sz: Single;
    vs, ts: Integer;
  begin
    if MadeHere >= PLACE_SIGN_MAX then Exit;
    Mesh.CurrentOsmId := Places[pI].Id;
    vs := Mesh.VertexCount; ts := Mesh.TriangleCount;
    if AppendOnePlaceSign(Mesh, Atlas, Places[pI].Name, Cr, Dir, GY,
         IsExit, sx, sz) then
    begin
      AppendPlateAnchor(Anchors, AnchorCount, sx, sz,
        vs, Mesh.VertexCount, ts, Mesh.TriangleCount);
      Inc(Made); Inc(MadeHere);
      if IsExit then Inc(ExitSigns) else Inc(EntrySigns);
    end;
    Mesh.CurrentOsmId := 0;
  end;

  { Добавить кандидат-пересечение (направление Inw уже нормировано). }
  procedure AddCross(const Cr, Inw: TVector3; GY, APrio: Single);
  var cap: Integer;
  begin
    if nC >= Length(keys) then
    begin
      if Length(keys) = 0 then cap := 32 else cap := Length(keys) * 2;
      SetLength(keys, cap); SetLength(eCross, cap);
      SetLength(eInward, cap); SetLength(eGY, cap);
    end;
    { Grp у каждого свой (=nC) — внутри одного НП давим ЛЮБЫЕ близкие пересечения. }
    keys[nC].X := Cr.X; keys[nC].Z := Cr.Z; keys[nC].Prio := APrio; keys[nC].Grp := nC;
    eCross[nC] := Cr; eInward[nC] := Inw; eGY[nC] := GY;
    Inc(nC);
  end;

begin
  MadeHere := 0; EntrySigns := 0; ExitSigns := 0;
  for pI := 0 to High(Places) do
  begin
    RN := Length(Places[pI].Ring);
    if RN < 3 then Continue;
    { 1) собираем пересечения границы ЭТОГО НП всеми дорогами (приоритет по классу
         дороги; keys переиспользуется между НП — без перевыделения на каждый НП). }
    nC := 0;
    for Way in Dataset.Ways.Values do
    begin
      if not Way.Tags.HasKey('highway') then Continue;
      if Length(Way.NodeRefs) < 2 then Continue;
      prio := RoadPriority(Way.Tags);
      hasPrev := False; prevInside := False;
      PrevPos := Vector3(0, 0, 0);
      for nI := 0 to High(Way.NodeRefs) do
      begin
        Node := Dataset.FindNode(Way.NodeRefs[nI]);
        if Node = nil then Continue;
        if Dataset.LatticeReady then
        begin
          { int-first: решётка узла (Osm3dOsmData.PrecomputeLattice) }
          CurPos.X := Node.LatticeX * (1.0 / 64.0);
          CurPos.Y := 0;
          CurPos.Z := Node.LatticeZ * (1.0 / 64.0);
        end
        else
        begin
          CurPos := Projection.Project(Node.Position, 0);
          CurPos.X := Round(CurPos.X * 64.0) * (1.0 / 64.0);
          CurPos.Z := Round(CurPos.Z * 64.0) * (1.0 / 64.0);
        end;
        if (CurPos.X < Places[pI].MinX) or (CurPos.X > Places[pI].MaxX)
           or (CurPos.Z < Places[pI].MinZ) or (CurPos.Z > Places[pI].MaxZ) then
          curInside := False
        else
          curInside := PointInPolygonXZ(CurPos, Places[pI].Ring);

        { пересечение границы в любую сторону → потенциальные въезд + выезд }
        if hasPrev and (prevInside <> curInside) then
        begin
          found := False; bestT := 2.0; BestCross := CurPos;
          for eI := 0 to RN - 1 do
            if SegSegXZ(PrevPos, CurPos, Places[pI].Ring[eI],
                        Places[pI].Ring[(eI + 1) mod RN], Cross, t) then
              if t < bestT then begin bestT := t; BestCross := Cross; found := True; end;
          if found then
          begin
            { Inward — к внутренней точке отрезка (направление въезда) }
            if curInside then
              Inward := Vector3(CurPos.X - PrevPos.X, 0, CurPos.Z - PrevPos.Z)
            else
              Inward := Vector3(PrevPos.X - CurPos.X, 0, PrevPos.Z - CurPos.Z);
            dl := Sqrt(Inward.X * Inward.X + Inward.Z * Inward.Z);
            if dl > 1e-6 then
            begin
              Inward.X := Inward.X / dl; Inward.Z := Inward.Z / dl;
              GroundYv := SampleTerrainYGeo(Terrain, HM,
                Projection.Unproject(BestCross.X, BestCross.Z));
              AddCross(BestCross, Inward, GroundYv, prio);
            end;
          end;
        end;
        hasPrev := True; PrevPos := CurPos; prevInside := curInside;
      end;
    end;
    { 2) дедуп 30 м: близкие въезды одного НП — оставляем тот, что на более КРУПНОЙ
         дороге (приоритет по классу; Grp у всех разный — давятся любые близкие). }
    keep := DedupByRadius(keys, nC, SIGN_DEDUP_R2);
    { 3) на каждый выживший въезд — пара табличек (въезд + выезд). }
    for ci := 0 to nC - 1 do
    begin
      if MadeHere >= PLACE_SIGN_MAX then Break;
      if not keep[ci] then Continue;
      Emit(eCross[ci], eInward[ci], eGY[ci], False);                               { въезд: белая }
      Emit(eCross[ci], Vector3(-eInward[ci].X, 0, -eInward[ci].Z), eGY[ci], True); { выезд: + красная }
    end;
  end;
  if Assigned(Log) then
    Log(Format('plates: place signs entry=%d exit=%d (place areas=%d)',
      [EntrySigns, ExitSigns, Length(Places)]));
end;

{ One name plate for a barrier way (any fence, incl. amenity=prison via
  ParseFenceParams) that carries a name. Placed on the way's LONGEST edge, at
  mid-height of the fence band, facing the outward side (for a closed prison
  perimeter made CCW). Reuses the POI panel style (per-way colour). Returns 1
  if a plate was emitted, else 0. Points are projected + snapped to the same
  1/64 m grid as walls, so the plate sits flush on the fence line. }
function AppendFenceNamePlate(Mesh: TMesh; Way: TOSMWay; Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection; Terrain: TTerrainSampler;
  Atlas: TPlateGlyphAtlas; const Params: TFenceParams; const Name: string;
  var Anchors: TPlateTileAnchorArray; var AnchorCount, Made: Integer): Integer;
var
  Pts: TV3Array;
  N, I, Cnt, BestI: Integer;
  Node: TOSMNode;
  P: TVector3;
  Ax, Az, Bx, Bz, EDx, EDz, ELen, BestLen: Single;
  Qx, Qz: Single;
  Scale, LineW, PlateW, AvailW, Sc, HalfW, Lo, Hi, Uc, PRu, PRx, PRz: Single;
  GroundY, BaselineY: Single;
  N3: TVector3;
  B: TPlateBounds;
  ColorIdx, VStart, TStart: Integer;
  SentU, VBias: Single;
begin
  Result := 0;
  if (Made >= PLATE_MAX) or (Name = '') then Exit;

  { projected + quantised points (same 1/64 grid as walls/footprints). }
  N := Length(Way.NodeRefs);
  if N < 2 then Exit;
  SetLength(Pts, N);
  Cnt := 0;
  for I := 0 to N - 1 do
  begin
    Node := Dataset.FindNode(Way.NodeRefs[I]);
    if Node = nil then Continue;
    if Dataset.LatticeReady then
    begin
      { int-first: точные решёточные координаты узла (мировая решётка 1/64 м
        минус целый сдвиг блока) — побитно одинаковы во всех блоках halo,
        см. Osm3dOsmData.PrecomputeLattice }
      P.X := Node.LatticeX * (1.0 / 64.0);
      P.Y := 0;
      P.Z := Node.LatticeZ * (1.0 / 64.0);
    end
    else
    begin
      P := Projection.Project(Node.Position, 0);
      P.X := Round(P.X * 64.0) * (1.0 / 64.0);
      P.Z := Round(P.Z * 64.0) * (1.0 / 64.0);
    end;
    Pts[Cnt] := P; Inc(Cnt);
  end;
  SetLength(Pts, Cnt);
  if Cnt < 2 then Exit;

  { closed perimeter (prison): CCW so the edge normal points OUT (toward the
    public side where the sign is read). }
  if Way.IsClosed and (Cnt >= 3) then EnsureCCWXZ(Pts);

  { longest edge — most room for the name + most stable placement. }
  BestI := -1; BestLen := 0;
  for I := 0 to Cnt - 2 do
  begin
    EDx := Pts[I + 1].X - Pts[I].X;
    EDz := Pts[I + 1].Z - Pts[I].Z;
    ELen := Sqrt(EDx * EDx + EDz * EDz);
    if ELen > BestLen then begin BestLen := ELen; BestI := I; end;
  end;
  if (BestI < 0) or (BestLen < 0.5) then Exit;

  Ax := Pts[BestI].X;     Az := Pts[BestI].Z;
  Bx := Pts[BestI + 1].X; Bz := Pts[BestI + 1].Z;
  EDx := (Bx - Ax) / BestLen;
  EDz := (Bz - Az) / BestLen;
  { OUTWARD normal of a CCW edge A->B is (-EDz, EDx) — same convention as
    NearestRingEdge, which puts building POI plates on the street side. After
    EnsureCCWXZ above, this faces the OUTSIDE of a closed perimeter (prison),
    so the sign reads from outside the fence. }
  N3  := Vector3(-EDz, 0, EDx);

  Qx := (Ax + Bx) * 0.5;
  Qz := (Az + Bz) * 0.5;
  GroundY := SampleTerrainYGeo(Terrain, HM, Projection.Unproject(Qx, Qz));
  BaselineY := GroundY + Params.MinHeight + Params.Height * 0.5;  { mid-band }

  { font: shrink toward a floor if the name is wider than the edge. }
  Scale := PLATE_FENCE_EM / Atlas.FontSizePx;
  LineW := Atlas.Font.TextWidth(Name) * Scale;
  PlateW := LineW + 2 * PLATE_PAD_X;
  AvailW := BestLen - 2 * PLATE_EDGE_MARGIN;
  if (AvailW > 0.5) and (PlateW > AvailW) then
  begin
    Sc := AvailW / PlateW;
    if Sc < PLATE_MIN_FONT_SCALE then Sc := PLATE_MIN_FONT_SCALE;
    Scale := Scale * Sc;
    LineW := Atlas.Font.TextWidth(Name) * Scale;
    PlateW := LineW + 2 * PLATE_PAD_X;
  end;

  { centre the panel on the edge midpoint without overrunning the ends. }
  HalfW := PlateW * 0.5;
  Lo := PLATE_EDGE_MARGIN + HalfW;
  Hi := BestLen - PLATE_EDGE_MARGIN - HalfW;
  Uc := BestLen * 0.5;
  if Lo <= Hi then
  begin
    if Uc < Lo then Uc := Lo;
    if Uc > Hi then Uc := Hi;
  end;
  PRu := Uc + LineW * 0.5;         { right edge of text (U=0 origin) }
  PRx := Ax + EDx * PRu;
  PRz := Az + EDz * PRu;

  { reuse the POI panel style/colour (per-way hash) — no new shader channel. }
  ColorIdx := Integer(HashInt64(Way.Id) mod LongWord(PLATE_POI_COLOR_COUNT));
  SentU := -(PLATE_SENT_POI_BASE + ColorIdx);
  VBias := (PLATE_STYLE_POI_BASE + ColorIdx) * PLATE_STYLE_VSTEP;

  B.HasAny := False;
  Mesh.CurrentOsmId := Way.Id;
  VStart := Mesh.VertexCount;
  TStart := Mesh.TriangleCount;
  AppendLine(Mesh, Atlas, Name, Scale, BaselineY,
             PRx, PRz, EDx, EDz, N3, PLATE_GLYPH_OFFSET, VBias, B);
  AppendBackplate(Mesh, PRx, PRz, EDx, EDz, N3, B, PLATE_BACK_OFFSET, SentU);
  Mesh.CurrentOsmId := 0;
  if not B.HasAny then Exit;       { name unrenderable — nothing emitted }

  AppendPlateAnchor(Anchors, AnchorCount, Qx, Qz,
    VStart, Mesh.VertexCount, TStart, Mesh.TriangleCount);
  Inc(Made);
  Result := 1;
end;

{ Name plate for a bus stop / platform, placed at the model's road-facing
  position (PlacedPos) and turned to face the road (Yaw = the model's +Y yaw,
  so the sign shares the shelter's facing). Reuses the POI panel style. Returns
  1 if a plate was emitted, else 0. }
function AppendStopNamePlate(Mesh: TMesh; Atlas: TPlateGlyphAtlas;
  const Name: string; const PlacedPos: TVector3; Yaw: Single; OsmId: Int64;
  var Anchors: TPlateTileAnchorArray; var AnchorCount, Made: Integer): Integer;
var
  EDx, EDz, Cx, Cz, PRx, PRz, Scale, LineW, BaselineY: Single;
  N3: TVector3;
  B: TPlateBounds;
  VStart, TStart: Integer;
  SentU, VBias: Single;
begin
  Result := 0;
  if (Made >= PLATE_MAX) or (Name = '') then Exit;

  { text baseline direction + facing that satisfy N3 = (-EDz, EDx) — the same
    relationship AppendLine/AppendBackplate expect. With N3 = model +Z =
    (sinYaw, cosYaw), the sign faces the road exactly like the shelter. }
  EDx := Cos(Yaw); EDz := -Sin(Yaw);
  N3  := Vector3(Sin(Yaw), 0, Cos(Yaw));

  Cx := PlacedPos.X; Cz := PlacedPos.Z;
  BaselineY := PlacedPos.Y + STOP_PLATE_BASE_H;

  Scale := PLATE_POI_EM / Atlas.FontSizePx;
  LineW := Atlas.Font.TextWidth(Name) * Scale;

  { centre the text on the stop; PR is the right edge (U=0 origin). }
  PRx := Cx + EDx * (LineW * 0.5);
  PRz := Cz + EDz * (LineW * 0.5);

  { fixed grey background + white text (dedicated slot, no per-id hashing). }
  SentU := PLATE_SENT_GRAY;
  VBias := PLATE_STYLE_STOP * PLATE_STYLE_VSTEP;

  B.HasAny := False;
  Mesh.CurrentOsmId := OsmId;
  VStart := Mesh.VertexCount;
  TStart := Mesh.TriangleCount;
  AppendLine(Mesh, Atlas, Name, Scale, BaselineY,
             PRx, PRz, EDx, EDz, N3, PLATE_GLYPH_OFFSET, VBias, B);
  AppendBackplate(Mesh, PRx, PRz, EDx, EDz, N3, B, PLATE_BACK_OFFSET, SentU);
  Mesh.CurrentOsmId := 0;
  if not B.HasAny then Exit;

  AppendPlateAnchor(Anchors, AnchorCount, Cx, Cz,
    VStart, Mesh.VertexCount, TStart, Mesh.TriangleCount);
  Inc(Made);
  Result := 1;
end;

class function TPlateBuilder.BuildAll(Dataset: TOSMDataset; HM: THeightmap;
  Projection: TLocalProjection; Atlas: TPlateGlyphAtlas;
  out Anchors: TPlateTileAnchorArray;
  Terrain: TTerrainSampler; Log: TLogProc;
  ARoadIdx: TOsmRoadIndex): TMesh;
const
  LOG_CAP = 200;            { предел построчных «нет номера дома» (анти-флуд) }
var
  Mesh: TMesh;
  Way:  TOSMWay;
  RoadPts, SelPts: TV2Array;
  RoadGrid, PoiGrid, SelGrid: TPtGrid;
  StreetIdx: TStringList;
  Places: TPlaceAreaArray;
  NamedPOIs: TNamedPOIArray;
  Consumed:  TBoolArray;
  Street, Number, Reason: string;
  Made, AnchorCount, VStart, TStart, K: Integer;
  ScanBld, WithNum, SkRing, SkFacade, SkGlyph, NoNumWithAddr, StreetMatched: Integer;
  PoiPlates: Integer;
  CenX, CenZ: Single;
  HasLog, DbgWay, Matched: Boolean;
  { Fence/prison name plates. }
  FenceParams: TFenceParams;
  FenceOk: Boolean;
  FenceNm: string;
  FencePlates: Integer;
  { Bus stop / platform name plates. }
  StopNode: TOSMNode;
  StopNm:   string;
  StopP:    TVector3;
  StopYaw:  Single;
  StopPlates: Integer;
  OwnIdx: Boolean;                 { индекс построен здесь (хост без общего) }

  function F6(V: Double): string;          { дот-сепаратор независимо от локали }
  begin
    Str(V:0:6, Result);
  end;

  function NodeLL(W: TOSMWay): string;     { lat,lon первого узла — для поиска на карте }
  var Nd: TOSMNode;
  begin
    Result := '?,?';
    if Length(W.NodeRefs) = 0 then Exit;
    Nd := Dataset.FindNode(W.NodeRefs[0]);
    if Nd <> nil then
      Result := F6(Nd.Position.Lat) + ',' + F6(Nd.Position.Lon);
  end;

  function HasAddrHint(const T: TOSMTags): Boolean;  { есть хоть какой-то addr:* }
  begin
    Result := (Trim(T.Get('addr:street'))   <> '')
           or (Trim(T.Get('addr:housename'))<> '')
           or (Trim(T.Get('addr:place'))    <> '')
           or (Trim(T.Get('addr:full'))     <> '');
  end;

begin
  Anchors := nil;
  Mesh := TMesh.Create('plates');
  Result := Mesh;
  if (Dataset = nil) or (Atlas = nil) or (Atlas.Font = nil)
     or (Projection = nil) then Exit;

  HasLog := Assigned(Log);
  RoadPts := CollectHighwayPts(Dataset, Projection);   { fallback: все дороги }
  RoadGrid := BuildV2Grid(RoadPts);                    { ближайшая дорожная точка за O(1) }
  StreetIdx := BuildStreetIndex(Dataset, Projection);  { name → точки улицы }
  NamedPOIs := CollectNamedPOIs(Dataset, Projection);  { именованные POI-узлы }
  PoiGrid := BuildPOIGrid(NamedPOIs);                  { POI-кандидаты здания за O(1) }
  SetLength(Consumed, Length(NamedPOIs));
  Made := 0; AnchorCount := 0;
  ScanBld := 0; WithNum := 0; SkRing := 0; SkFacade := 0; SkGlyph := 0;
  NoNumWithAddr := 0; StreetMatched := 0; PoiPlates := 0;
  FencePlates := 0;
  StopPlates := 0;
  OwnIdx := False;
  try
    for Way in Dataset.Ways.Values do
    begin
      DbgWay := HasLog and (PlateDebugWayId <> 0) and (Way.Id = PlateDebugWayId);
      if HasLog and PlateDebugAll and Way.Tags.HasKey('building') then
        Log(Format('plate-bld way=%d closed=%s @%s tags={%s}',
          [Way.Id, BoolToStr(Way.IsClosed, True), NodeLL(Way), Way.Tags.ToString]));
      if Made >= PLATE_MAX then
      begin
        if DbgWay then Log(Format('plate[%d] skipped: PLATE_MAX cap', [Way.Id]));
        Break;
      end;

      { Fence / prison name plate. A named barrier (incl. amenity=prison, via
        ParseFenceParams — the same classifier the fence builder uses) gets one
        plate on its longest edge. Handled BEFORE the closed/building gates
        below (fences may be open lines) and only for non-building ways, so
        named buildings still fall through to the address/POI path. }
      FenceNm := Trim(Way.Tags.Get('name'));
      if (FenceNm <> '') and (not Way.Tags.HasKey('building')) then
      begin
        FenceParams := TFenceBuilder.ParseFenceParams(Way.Tags, Way.Id, FenceOk);
        if FenceOk then
        begin
          Inc(FencePlates, AppendFenceNamePlate(Mesh, Way, Dataset, HM,
            Projection, Terrain, Atlas, FenceParams, FenceNm,
            Anchors, AnchorCount, Made));
          Continue;   { a barrier way is not a building — skip the rest }
        end;
      end;

      if not Way.IsClosed then
      begin
        if DbgWay then Log(Format('plate[%d] skipped: way not closed (nodes=%d)',
          [Way.Id, Length(Way.NodeRefs)]));
        Continue;
      end;
      if not Way.Tags.HasKey('building') then
      begin
        if DbgWay then Log(Format('plate[%d] skipped: no building tag', [Way.Id]));
        Continue;
      end;
      Inc(ScanBld);

      { POI-таблички (name из узлов внутри контура) — для ЛЮБОГО здания,
        независимо от наличия адреса на самом контуре. }
      if Length(NamedPOIs) > 0 then
        Inc(PoiPlates, AppendBuildingPOIPlates(Mesh, Way, Dataset, HM, Projection,
          Terrain, Atlas, NamedPOIs, PoiGrid, Consumed, Anchors, AnchorCount, Made));

      Number := Trim(Way.Tags.Get('addr:housenumber'));
      if Number = '' then
      begin
        if DbgWay then Log(Format('plate[%d] skipped: no addr:housenumber', [Way.Id]));
        { Нет номера дома на самом контуре — табличку не строим. Логируем только
          дома, у которых ЕСТЬ другой addr:* (частичный адрес), чтобы не залить
          лог тысячами зданий вовсе без адреса. }
        if HasLog and HasAddrHint(Way.Tags) then
        begin
          Inc(NoNumWithAddr);
          if NoNumWithAddr <= LOG_CAP then
            Log(Format('plates: SKIP way=%d @%s no addr:housenumber (addr:street="%s")',
              [Way.Id, NodeLL(Way), Trim(Way.Tags.Get('addr:street'))]));
        end;
        Continue;
      end;
      Inc(WithNum);
      Street := Trim(Way.Tags.Get('addr:street'));

      { Лицевой фасад — на улицу ДОМА: если addr:street найден среди именованных
        дорог, берём точки именно этой улицы; иначе — все дороги (ближайшая). }
      SelPts := RoadPts;
      SelGrid := RoadGrid;
      Matched := False;
      if Street <> '' then
      begin
        K := StreetIdx.IndexOf(Street);
        if (K >= 0) and (TStreetPts(StreetIdx.Objects[K]).Cnt > 0) then
        begin
          SelPts := TStreetPts(StreetIdx.Objects[K]).Pts;
          SelGrid.Cols := 0;                { индекс строился по RoadPts — неприменим }
          Matched := True;
          Inc(StreetMatched);
        end;
      end;
      if DbgWay then
        Log(Format('plate[%d] facade-pts: street="%s" matched=%s pts=%d (fallback-all-roads=%d)',
          [Way.Id, Street, BoolToStr(Matched, True), Length(SelPts), Length(RoadPts)]));

      { OsmId штампуется на все вершины таблички — наследует id здания
        (полезно для пикинга/LOD; переживает merge/split/composite). }
      Mesh.CurrentOsmId := Way.Id;
      VStart := Mesh.VertexCount;
      TStart := Mesh.TriangleCount;
      if AppendBuildingPlate(Mesh, Way, Dataset, HM, Projection, Terrain,
                             SelPts, SelGrid, Atlas, Street, Number, CenX, CenZ, Reason, Log) then
      begin
        AppendPlateAnchor(Anchors, AnchorCount, CenX, CenZ,
          VStart, Mesh.VertexCount, TStart, Mesh.TriangleCount);
        Inc(Made);
        if HasLog and PlateDebugAll then
          Log(Format('plate-ok way=%d num="%s" street="%s" matched=%s verts=%d',
            [Way.Id, Number, Street, BoolToStr(Matched, True),
             Mesh.VertexCount - VStart]));
      end
      else
      begin
        { Есть номер дома, но табличка не вышла — настоящая «недостача».
          reason: ring (контур <3 вершин / нет узлов), facade (нет годного
          ребра), glyph (номер пуст/нерисуемый после Trim). }
        if Reason = 'ring' then Inc(SkRing)
        else if Reason = 'facade' then Inc(SkFacade)
        else Inc(SkGlyph);
        if HasLog then
          Log(Format('plates: SKIP way=%d @%s num="%s" street="%s" reason=%s',
            [Way.Id, NodeLL(Way), Number, Street, Reason]));
      end;
      Mesh.CurrentOsmId := 0;
    end;

    { Въездные таблички НП — в тот же меш/якоря. Собираем площадные place и на
      каждом входе дороги в границу ставим табличку справа. }
    Places := CollectPlaceAreas(Dataset, Projection);
    if Length(Places) > 0 then
      AppendPlaceSigns(Mesh, Dataset, HM, Projection, Terrain, Atlas, Places,
                       Anchors, AnchorCount, Made, Log)
    else if HasLog then
      Log('plates: no closed-way place areas in dataset — no entry signs');

    { Bus stop / platform name plates — one per named stop node, placed and
      turned to match the model via the SAME ComputeStopPlacement, so plate and
      shelter share position + facing. }
    for StopNode in Dataset.Nodes.Values do
    begin
      if Made >= PLATE_MAX then Break;
      { безтеговые вершины геометрии — подавляющее большинство узлов }
      if StopNode.Tags.Count = 0 then Continue;
      if TPOIBuilderExt.ClassifyNode(StopNode.Tags) <> pkxBusStop then Continue;
      if ARoadIdx = nil then
      begin
        { хост без общего индекса (GeomBuilder строит и передаёт) —
          строим свой один раз }
        ARoadIdx := TOsmRoadIndex.Build(Dataset, Projection);
        OwnIdx := True;
      end;
      { De-dup: skip the stop_position "point on road" name plate when a nearby
        platform/bus_stop POI covers this stop (same rule as the model builder).
        Индексная версия: O(окрестности) вместо O(датасета) на остановку. }
      if TPOIBuilderExt.IsRedundantStopPositionNode(ARoadIdx, Dataset, Projection,
           StopNode) then Continue;
      StopNm := Trim(StopNode.Tags.Get('name'));
      if StopNm = '' then Continue;
      if Dataset.LatticeReady then
      begin
        { int-first: решётка узла как стартовая точка размещения }
        StopP.X := StopNode.LatticeX * (1.0 / 64.0);
        StopP.Y := 0;
        StopP.Z := StopNode.LatticeZ * (1.0 / 64.0);
      end
      else
        StopP := Projection.Project(StopNode.Position, 0);
      StopP := TPOIBuilderExt.ComputeStopPlacement(ARoadIdx, StopP, StopYaw);
      StopP.Y := SampleTerrainYGeo(Terrain, HM, Projection.Unproject(StopP.X, StopP.Z));
      Inc(StopPlates, AppendStopNamePlate(Mesh, Atlas, StopNm, StopP, StopYaw,
        StopNode.Id, Anchors, AnchorCount, Made));
    end;

    SetLength(Anchors, AnchorCount);

    if HasLog then
    begin
      Log(Format('plates: built=%d | buildings=%d, with addr:housenumber=%d (street-matched=%d) | skipped-with-number: ring=%d facade=%d glyph=%d | partial-addr-no-number=%d | poi=%d | fence=%d | stop=%d',
        [Made, ScanBld, WithNum, StreetMatched, SkRing, SkFacade, SkGlyph, NoNumWithAddr, PoiPlates, FencePlates, StopPlates]));
      if NoNumWithAddr > LOG_CAP then
        Log(Format('plates: (%d "no addr:housenumber" lines capped at %d)',
          [NoNumWithAddr, LOG_CAP]));
      Log('plates: note — a building absent from the SKIP lines has no addr:housenumber on its own way; its address is on a separate node or a building relation, so no plate is generated.');
    end;
  finally
    if OwnIdx then ARoadIdx.Free;   { свой индекс — наш; и на error-путях }
    FreeStreetIndex(StreetIdx);
  end;
end;

{ ---- shape builders ---- }

function BuildPlateCompositeShape(Composite: TGroundCompositeMesh;
  Atlas: TPlateGlyphAtlas; const SunDirToward: TVector3;
  LogProc: TLogProc): TShapeNode;
var
  Geo:    TIndexedFaceSetNode;
  Mat:    TUnlitMaterialNode;
  App:    TAppearanceNode;
  Effect: TEffectNode;
  PV, PF: TEffectPartNode;
  Tex:    TImageTextureNode;
  PoiI:   Integer;
begin
  Result := nil;
  if (Composite = nil) or (Composite.TriangleCount = 0) then Exit;
  if Atlas = nil then
    raise EInvalidOperation.Create('BuildPlateCompositeShape: Atlas is nil');
  if Atlas.Url = '' then Exit;   { без закэшированного PNG таблички не строим }

  { Solid=True: таблички односторонние, лицо наружу (+pltNormal). }
  Geo := BuildCompositeIFS(Composite, 'pltUV', 'pltNormal', True, False);
  if Geo = nil then Exit;

  Mat := TUnlitMaterialNode.Create;
  Mat.EmissiveColor := Vector3(1.0, 1.0, 1.0);   { FS-emitted RGB passes through }
  App := TAppearanceNode.Create;
  App.Material := Mat;

  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;

  PV := TEffectPartNode.Create;
  PV.ShaderType := stVertex;
  PV.Contents   := PLATE_COMPOSITE_VS;
  PF := TEffectPartNode.Create;
  PF.ShaderType := stFragment;
  PF.Contents   := PLATE_COMPOSITE_FS;
  Effect.SetParts([PV, PF]);

  Tex := Atlas.CreateTextureNode;
  Effect.AddCustomField(TSFNode.Create(Effect, True, 'u_plt_atlas',
    [TAbstractTexture2DNode], Tex));
  Effect.AddCustomField(TSFVec3f.Create(Effect, True, 'u_plt_blue',  PLATE_BG_COLOR));
  Effect.AddCustomField(TSFVec3f.Create(Effect, True, 'u_plt_white', PLATE_TEXT_COLOR));
  Effect.AddCustomField(TSFVec3f.Create(Effect, True, 'u_plt_red',   PLATE_RED_COLOR));
  Effect.AddCustomField(TSFVec3f.Create(Effect, True, 'u_plt_gray',  PLATE_GRAY_COLOR));
  { палитра POI: u_plt_poi0..N — синхронно с pltPoiColor()/uniform'ами в FS }
  for PoiI := 0 to PLATE_POI_COLOR_COUNT - 1 do
    Effect.AddCustomField(TSFVec3f.Create(Effect, True,
      Format('u_plt_poi%d', [PoiI]), PLATE_POI_COLORS[PoiI]));
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'u_plt_lodmax', PLATE_LOD_MAX_M));

  App.SetEffects([Effect]);

  Result := TShapeNode.Create;
  Result.Geometry   := Geo;
  Result.Appearance := App;
  CompactTileGeometry(Result);

  if Assigned(LogProc) then
    LogProc(Format('  Plates: 1 merged shape, %d v, %d t',
      [Composite.VertexCount, Composite.TriangleCount]));
end;

function BuildPlateShape(PlateMesh: TMesh; Atlas: TPlateGlyphAtlas;
  const SunDirToward: TVector3; LogProc: TLogProc): TShapeNode;
var
  Builder: TGroundCompositeBuilder;
  Comp:    TGroundCompositeMesh;
begin
  Result := nil;
  if (PlateMesh = nil) or (PlateMesh.TriangleCount = 0) then Exit;

  { Один материал (0); UV/нормали переезжают из меша в composite, sentinel-UV
    фона переживает дедуп (входит в ключ вершины). }
  Builder := TGroundCompositeBuilder.Create('plate_composite', 0.999);
  try
    Builder.Append(PlateMesh, 0);
    Comp := Builder.Finalize(nil);   { владение переходит к нам }
  finally
    Builder.Free;
  end;

  try
    Result := BuildPlateCompositeShape(Comp, Atlas, SunDirToward, LogProc);
  finally
    Comp.Free;
  end;
end;

initialization
  { Точечная отладка одной таблички: OSM3D_PLATE_DEBUG_WAYID=<id> включает
    подробный лог построения для здания с этим way-id (0/не задано = выкл). }
  PlateDebugWayId := StrToInt64Def(GetEnvironmentVariable('OSM3D_PLATE_DEBUG_WAYID'), 0);
  { Полный дамп всех домов и табличек: OSM3D_PLATE_DEBUG_ALL=1. }
  PlateDebugAll := (Trim(GetEnvironmentVariable('OSM3D_PLATE_DEBUG_ALL')) <> '')
              and (Trim(GetEnvironmentVariable('OSM3D_PLATE_DEBUG_ALL')) <> '0');
end.
