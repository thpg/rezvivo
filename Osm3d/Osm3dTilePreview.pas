unit Osm3dTilePreview;

{$Q-}{$R-}
{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes, SysUtils, Math,
  CastleVectors, CastleImages, CastleScene, X3DNodes,
  Osm3dGeoMath,
  Osm3dHeightmap,
  Osm3dGeomMesh,
  Osm3dTileX3D,
  Osm3dStudioSettings,      { GEO_TILE_EDGE_PX — превью-текстура следует за размером тайла }
  Osm3dGroundComposite,
  Osm3dEffectUtils,   { ChainEffectApp + BuildGroundBlendEffect }     { GROUND_MATERIALS — единый источник превью-цветов MAT_RGB }
  Osm3dSceneMaterials       { TSceneMaterialKind }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  PREVIEW_GRID    = 33;            { вершин на сторону }

  { Плотность превью-текстуры: PREVIEW_TEX_PER_HPX текселей на пиксель хайтмапа
    тайла. Раньше стоял литерал (128), подобранный под старую решётку, и при
    укрупнении тайла 16 -> 256 px плотность превью падала в разы; теперь сторона
    следует за GEO_TILE_EDGE_PX (256 * 2 = 512 px на тайл). Форматы самоописуемые
    (.prev несёт TexPx, блочный .ptex.png — сторону картинки), поэтому чтение
    чужих размеров не ломается: блок иного размера считается отсутствующим и
    перезаписывается при следующей генерации пачки; решётка иного EdgePx в этот
    кэш вообще не попадает (другие quadkey-пути). }
  PREVIEW_TEX_PER_HPX = 2;
  PREVIEW_VERSION = 1;
  PREVIEW_EXT     = '.prev';

  { Цвет заглушки «нет данных» в превью-текстурах (RGB 0..255). ЕДИНЫЙ
    источник для всех продюсеров и детектора: им заливается база тайловой
    превью-текстуры до растеризации (ниже в BuildPreviewTexture) и
    отсутствующие блоки/тайлы в Osm3dPrevTexFetcher (FillGreen), и тем же
    значением детектор «пустого» супертайла (AllGreen) сверяет пиксели —
    до унификации продюсеры писали MAT_RGB[0] (FallbackColor терраина, ещё
    и перекрываемый живым средним атласа), а детектор сверялся с зашитым
    (96,134,66), и «пустой» супер не распознавался. }
  PREVIEW_NODATA_RGB: array[0..2] of Byte = (96, 134, 66);

  { Дальняя земля: КОНСТАНТНЫЙ цвет атмосферной дымки (RGB 0..255, из
    пользовательского образца) вместо расчётного среднего цвета атласа —
    дальний рельеф должен сливаться с горизонтом, а не быть бурым.
    Рисуется эмиссивом без освещения, поэтому на экране ровно этот цвет. }
  FAR_GROUND_R = 147;
  FAR_GROUND_G = 188;
  FAR_GROUND_B = 219;

{ Плоские превью-цвета по TGroundMaterialId. ЕДИНСТВЕННЫЙ источник
  дефолтов — GROUND_MATERIALS[..].FallbackColor (заполняется в
  initialization этого юнита); поверх при старте ложатся живые средние
  цвета ячеек реального атласа (SetPreviewGroundColor). Ручная
  32-строчная таблица-зеркало удалена: она дрейфовала от материалов
  (terrain был (96,134,66) против материального (102,140,77)). }
var
  MAT_RGB: array[0..GROUND_MAT_COUNT - 1] of array[0..2] of Byte;


type
  TTilePreviewData = class
  public
    Grid:    Integer;              { = PREVIEW_GRID }
    TexPx:   Integer;              { 0 = текстуры нет }
    Heights: array of Single;      { Grid², row 0 = север (MaxLat) }
    Tex:     array of Byte;        { TexPx²*3 RGB, row 0 = север }
    HalfX, HalfZ: Single;          { полуразмеры тайла, м }
    constructor Create;
    function HasTex: Boolean;
    function CornerY(NorthWest, East: Boolean): Single;
    procedure SaveToFile(const APath: string);
    function  LoadFromFile(const APath: string): Boolean;
  end;

  { Callback: returns an AGrid×AGrid height grid for ABox (row 0 = north),
    or nil if not yet available. Used by TOsm3dFarGround to pull coarse
    heights per ring level. }
  TFarHeightGridFunc = function(const ABox: TLatLonBox;
    AGrid: Integer): THeightArray of object;

  { Дальняя земля: камера-центрированный ПОЛЯРНЫЙ меш ФИКСИРОВАННОЙ топологии.
    Концентрические окружности (радиус растёт геометрически наружу, ALevels октав),
    каждая разбита на ASectors секторов; соседние окружности делят вершины, сектора
    замкнуты по кругу — меш СПЛОШНОЙ (без T-стыков, без юбок). Внутри AInnerHalfM —
    дыра под деталь. Вершины — В ЛОКАЛЬНЫХ координатах (камера в 0); владелец ставит
    Scene.Translation=(camX,0,camZ). Высоты тянутся через AHeights по-октавным боксам
    (детальность падает с расстоянием); кривизна Земли ЗАПЕКАЕТСЯ по-вершинно
    (y -= ρ²/2R), минус ABiasDownM (деталь выигрывает depth), плюс провал внутренней
    зоны под деталь. Нормали — сглаженные из граней.

    Топология строится ОДИН раз. При пересечении ячейки сцена НЕ пересобирается —
    высоты вершин перенацеливаются (Retarget) и плавно морфятся (Animate) за ~0.4 c.
    Это убирает фриз от полного пересбора (парс X3D, заливка VBO, компиляция шейдеров). }
  TOsm3dFarGround = class
  private
    FScene:  TCastleScene;
    FCoord:  TCoordinateNode;
    FNorm:   TNormalNode;
    FNV, FSectors, FRRings, FLevels: Integer;
    FBias, FMorph, FMorphRate: Single;
    FCenter: TLatLon;
    FVX, FVZ, FOffset, FOctHalf: array of Single;   { фиксированы }
    FYcur, FYfrom, FYto: array of Single;            { морф высот }
    FNormals, FPoints: array of TVector3;
    FCoordIdx: array of LongInt;
    FGeo:      TIndexedFaceSetNode;                  { для живой пересборки индекса (клип) }
    FRingRho:  array of Single;                      { радиус каждого кольца 0..FRRings }
    FClipRing: array of Integer;                     { посекторно: внутреннее оставляемое кольцо }
    procedure SampleHeights(const ACenter: TLatLon; AHeights: TFarHeightGridFunc);
    procedure RecomputeNormals;
    procedure PushToNodes;
    procedure RebuildIndex;
  public
    constructor Create(AOwner: TComponent; const ACenterGeo: TLatLon;
      AInnerHalfM: Single; ALevels, ASectors: Integer; ABiasDownM: Single;
      const AColorR, AColorG, AColorB: Byte; AHeights: TFarHeightGridFunc);
    { Перенацелить на новый центр: текущие высоты — старт морфа, новые — цель. }
    procedure Retarget(const ACenterGeo: TLatLon; AHeights: TFarHeightGridFunc);
    { Каждый кадр: продвигает морф высот, если он идёт. }
    procedure Animate(const ADtSeconds: Single);
    { Посекторный клип внутренней кромки: ARadii[сектор] = радиус покрытия деталью.
      Земля начинается от этого радиуса (мин. перекрытие), в дырах доходит до
      внутреннего кольца. Перестраивает индекс только при изменении. }
    procedure SetClip(const ARadii: array of Single);
    property Scene:    TCastleScene read FScene;
    property Center:   TLatLon read FCenter;
    property Sectors:  Integer read FSectors;
  end;

{ Сэмплирует высоты из HM по боксу тайла; если Model <> nil — растеризует
  превью-текстуру из его грунтового композита (плоские цвета материалов).
  AScaleLatDeg — сессионная широта lon-масштаба. }
function BuildTilePreview(HM: THeightmap; const TileBox: TLatLonBox;
  AScaleLatDeg: Double; Model: TTileModel): TTilePreviewData;

{ Меш высот (+текстура, если есть). Step 1 — полный, 2/4 — прореженный
  дальний подрежим. Серый материал, если текстуры нет (режим 1). }
function PreviewGroup(Data: TTilePreviewData; Step: Integer): TGroupNode;

{ Средние цвета атласов (вызывает ассемблер после BuildImage в
  EnsureAtlas): уровни 0/1 берут цвет терраина, растеризация текстуры
  превью (режим 2) — поматериальные средние, плэйн-дома LOD B/C —
  средний building-атласа. До вызова действуют дефолтные константы. }
procedure SetPreviewGroundColor(AMat: Integer; R, G, B: Byte);
procedure SetPreviewBuildingColor(R, G, B: Byte);
function PreviewBuildingColor: TVector3;

implementation

{$J+}
const
  BLD_RGB: array[0..2] of Byte = (200, 195, 187);
{$J-}
  PREV_MAGIC = $50443344;   { 'D3DP' little-endian read as O3DP marker }

procedure SetPreviewGroundColor(AMat: Integer; R, G, B: Byte);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1765);{$ENDIF}
  if (AMat < 0) or (AMat > High(MAT_RGB)) then Exit;
  MAT_RGB[AMat][0] := R; MAT_RGB[AMat][1] := G; MAT_RGB[AMat][2] := B;
end;

procedure SetPreviewBuildingColor(R, G, B: Byte);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1766);{$ENDIF}
  BLD_RGB[0] := R; BLD_RGB[1] := G; BLD_RGB[2] := B;
end;

function PreviewBuildingColor: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1767);{$ENDIF}
  Result := Vector3(BLD_RGB[0] / 255, BLD_RGB[1] / 255, BLD_RGB[2] / 255);
end;

constructor TTilePreviewData.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1768);{$ENDIF}
  inherited Create;
  Grid  := PREVIEW_GRID;
  TexPx := 0;
end;

function TTilePreviewData.HasTex: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1769);{$ENDIF}
  Result := (TexPx > 0) and (Length(Tex) = TexPx * TexPx * 3);
end;

function TTilePreviewData.CornerY(NorthWest, East: Boolean): Single;
var IX, IZ: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1770);{$ENDIF}
  if Length(Heights) <> Grid * Grid then Exit(0);
  if East then IX := Grid - 1 else IX := 0;
  if NorthWest then IZ := 0 else IZ := Grid - 1;
  Result := Heights[IZ * Grid + IX];
end;

procedure TTilePreviewData.SaveToFile(const APath: string);
var
  S: TFileStream;
  V: LongInt;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1771);{$ENDIF}
  ForceDirectories(ExtractFilePath(APath));
  S := TFileStream.Create(APath, fmCreate);
  try
    V := PREV_MAGIC;        S.WriteBuffer(V, 4);
    V := PREVIEW_VERSION;   S.WriteBuffer(V, 4);
    V := Grid;              S.WriteBuffer(V, 4);
    V := TexPx;             S.WriteBuffer(V, 4);
    S.WriteBuffer(HalfX, 4);
    S.WriteBuffer(HalfZ, 4);
    if Length(Heights) = Grid * Grid then
      S.WriteBuffer(Heights[0], Grid * Grid * 4);
    if HasTex then
      S.WriteBuffer(Tex[0], Length(Tex));
  finally
    S.Free;
  end;
end;

function TTilePreviewData.LoadFromFile(const APath: string): Boolean;
var
  S: TFileStream;
  Magic, Ver, G, T: LongInt;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1772);{$ENDIF}
  Result := False;
  if not FileExists(APath) then Exit;
  try
    S := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  except
    Exit;
  end;
  try
    if S.Size < 24 then Exit;
    S.ReadBuffer(Magic, 4);
    S.ReadBuffer(Ver, 4);
    if (Magic <> PREV_MAGIC) or (Ver <> PREVIEW_VERSION) then Exit;
    S.ReadBuffer(G, 4);
    S.ReadBuffer(T, 4);
    { Потолок текстуры = текущий PREVIEW_TEX_PX: больше мы никогда не пишем,
      а .prev от другой решётки в этот кэш не попадает (иные quadkey-пути). }
    if (G < 2) or (G > 257) or (T < 0) or (T > (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX)) then Exit;
    S.ReadBuffer(HalfX, 4);
    S.ReadBuffer(HalfZ, 4);
    Grid  := G;
    TexPx := T;
    SetLength(Heights, G * G);
    if S.Size - S.Position < G * G * 4 then Exit;
    S.ReadBuffer(Heights[0], G * G * 4);
    if T > 0 then
    begin
      SetLength(Tex, T * T * 3);
      if S.Size - S.Position < Length(Tex) then Exit;
      S.ReadBuffer(Tex[0], Length(Tex));
    end;
    Result := True;
  finally
    S.Free;
  end;
end;

{ Растеризация композита плоскими цветами материалов; порядок треугольников
  меша уже отражает слои (later wins). Вода теперь в композите (matId 20 ->
  водный цвет из FallbackColor): вблизи её оживляет шейдер, на дальних
  превью/суперах — эта запечённая заливка. }
procedure RasterizeComposite(Data: TTilePreviewData; Model: TTileModel);
var
  M, FillIdx: Integer;
  Rec: TTileMeshRec;
  Sc: Single;

  function ToU(X: Single): Single; inline;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1773);{$ENDIF}
    Result := (Data.HalfX - X) / (2 * Data.HalfX);   { восток = -X → u растёт }
  end;
  function ToV(Z: Single): Single; inline;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1774);{$ENDIF}
    Result := (Data.HalfZ - Z) / (2 * Data.HalfZ);   { v растёт к югу }
  end;

  { Растеризовать один меш плоскими цветами. AFixedMat >= 0 -> весь меш этим
    matId (вода); иначе matId берётся повершинно из ARec.MatIds. }
  procedure RasterMesh(const ARec: TTileMeshRec; AFixedMat: Integer);
  var
    Mesh: TMesh;
    VRef: TMeshVertexArray;
    IRef: TMeshIndexArray;
    MatIds: TTileMatIdArray;
    T, TriCount, PX, PY, MinPX, MaxPX, MinPY, MaxPY: Integer;
    I0, I1, I2: Cardinal;
    X0, Y0, X1, Y1, X2, Y2, D, W0, W1, W2, FX, FY: Single;
    Mat, Off: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1775);{$ENDIF}
    Mesh   := ARec.Mesh;
    MatIds := ARec.MatIds;
    if (Mesh = nil) or (Mesh.TriangleCount = 0) then Exit;
    VRef := Mesh.Vertices;
    IRef := Mesh.Indices;
    TriCount := Mesh.TriangleCount;
    for T := 0 to TriCount - 1 do
    begin
      I0 := IRef[T*3]; I1 := IRef[T*3+1]; I2 := IRef[T*3+2];
      if AFixedMat >= 0 then
        Mat := AFixedMat
      else
        Mat := MatIds[I0];
      if (Mat < 0) or (Mat > 31) then Mat := 0;
      X0 := ToU(VRef[I0].Position.X) * Sc; Y0 := ToV(VRef[I0].Position.Z) * Sc;
      X1 := ToU(VRef[I1].Position.X) * Sc; Y1 := ToV(VRef[I1].Position.Z) * Sc;
      X2 := ToU(VRef[I2].Position.X) * Sc; Y2 := ToV(VRef[I2].Position.Z) * Sc;
      D := (Y1 - Y2) * (X0 - X2) + (X2 - X1) * (Y0 - Y2);
      if Abs(D) < 1.0e-9 then Continue;
      MinPX := Max(0, Floor(Min(X0, Min(X1, X2))));
      MaxPX := Min(Data.TexPx - 1, Ceil(Max(X0, Max(X1, X2))));
      MinPY := Max(0, Floor(Min(Y0, Min(Y1, Y2))));
      MaxPY := Min(Data.TexPx - 1, Ceil(Max(Y0, Max(Y1, Y2))));
      D := 1.0 / D;
      for PY := MinPY to MaxPY do
      begin
        FY := PY + 0.5;
        for PX := MinPX to MaxPX do
        begin
          FX := PX + 0.5;
          W0 := ((Y1 - Y2) * (FX - X2) + (X2 - X1) * (FY - Y2)) * D;
          if W0 < 0 then Continue;
          W1 := ((Y2 - Y0) * (FX - X2) + (X0 - X2) * (FY - Y2)) * D;
          if W1 < 0 then Continue;
          W2 := 1.0 - W0 - W1;
          if W2 < 0 then Continue;
          Off := (PY * Data.TexPx + PX) * 3;
          Data.Tex[Off]   := MAT_RGB[Mat][0];
          Data.Tex[Off+1] := MAT_RGB[Mat][1];
          Data.Tex[Off+2] := MAT_RGB[Mat][2];
        end;
      end;
    end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1776);{$ENDIF}
  if (Model = nil) or (Data.HalfX <= 0) or (Data.HalfZ <= 0) then Exit;
  Data.TexPx := GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX;
  SetLength(Data.Tex, Data.TexPx * Data.TexPx * 3);
  { База = цвет заглушки «нет данных» (НЕ MAT_RGB[0]: тот — живой цвет
    терраина из FallbackColor/среднего атласа, а непокрытые растеризацией
    пиксели обязаны побайтово совпадать с заливкой отсутствующих блоков
    Osm3dPrevTexFetcher, иначе детектор пустого супертайла не сработает). }
  for FillIdx := 0 to High(Data.Tex) div 3 do
  begin
    Data.Tex[FillIdx*3]   := PREVIEW_NODATA_RGB[0];
    Data.Tex[FillIdx*3+1] := PREVIEW_NODATA_RGB[1];
    Data.Tex[FillIdx*3+2] := PREVIEW_NODATA_RGB[2];
  end;
  Sc := Data.TexPx;

  { Грунтовый композит (повершинные matId). Вода теперь ВСЕГДА в композите
    (matId 20 -> водный цвет из FallbackColor), отдельного водного прохода нет. }
  for M := 0 to Model.MeshCount - 1 do
  begin
    Rec := Model.Meshes[M];
    if Length(Rec.MatIds) = 0 then Continue;   { только грунтовый композит }
    RasterMesh(Rec, -1);
  end;
end;

function BuildTilePreview(HM: THeightmap; const TileBox: TLatLonBox;
  AScaleLatDeg: Double; Model: TTileModel): TTilePreviewData;
var
  IX, IZ, G: Integer;
  P: TLatLon;
  DLat, DLon: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1300);{$ENDIF}
  Result := TTilePreviewData.Create;
  G := Result.Grid;
  DLat := TileBox.MaxLat - TileBox.MinLat;
  DLon := TileBox.MaxLon - TileBox.MinLon;
  Result.HalfZ := DLat * DEG_TO_RAD * EARTH_RADIUS_M * 0.5;
  Result.HalfX := DLon * DEG_TO_RAD * EARTH_RADIUS_M
                  * Cos(AScaleLatDeg * DEG_TO_RAD) * 0.5;
  SetLength(Result.Heights, G * G);
  if HM <> nil then
    for IZ := 0 to G - 1 do
    begin
      P.Lat := TileBox.MaxLat - DLat * IZ / (G - 1);
      for IX := 0 to G - 1 do
      begin
        P.Lon := TileBox.MinLon + DLon * IX / (G - 1);
        Result.Heights[IZ * G + IX] := THeightmapSampler.SampleBilinear(HM, P);
      end;
    end;
  RasterizeComposite(Result, Model);
end;

function GrayAppearance: TAppearanceNode;
var Mat: TMaterialNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1777);{$ENDIF}
  Mat := TMaterialNode.Create;
  { уровни 0/1 — средний цвет терраина из атласа }
  Mat.DiffuseColor     := Vector3(MAT_RGB[0][0] / 255,
                                  MAT_RGB[0][1] / 255,
                                  MAT_RGB[0][2] / 255);
  Mat.AmbientIntensity := 0.4;
  Result := TAppearanceNode.Create;
  Result.Material := Mat;
end;

function PreviewGroup(Data: TTilePreviewData; Step: Integer): TGroupNode;
var
  G, N, IX, IZ, VI, QI, OX, OZ: Integer;
  Positions: array of TVector3;
  Normals:   array of TVector3;
  TexCoords: array of TVector2;
  CoordIdx:  array of LongInt;
  Coord: TCoordinateNode;
  Norm:  TNormalNode;
  TexC:  TTextureCoordinateNode;
  Geo:   TIndexedFaceSetNode;
  Shape: TShapeNode;
  App:   TAppearanceNode;
  PixTex: TPixelTextureNode;
  Img:   TRGBImage;
  HL, HR, HU, HD, U, V: Single;
  PB: PByte;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1301);{$ENDIF}
  Result := nil;
  if (Data = nil) or (Length(Data.Heights) <> Data.Grid * Data.Grid) then Exit;
  if Step < 1 then Step := 1;
  G := Data.Grid;
  N := (G - 1) div Step + 1;
  if N < 2 then N := 2;

  SetLength(Positions, N * N);
  SetLength(Normals,   N * N);
  SetLength(TexCoords, N * N);
  for IZ := 0 to N - 1 do
  begin
    OZ := Min(IZ * Step, G - 1);
    for IX := 0 to N - 1 do
    begin
      OX := Min(IX * Step, G - 1);
      VI := IZ * N + IX;
      U  := OX / (G - 1);
      V  := OZ / (G - 1);
      Positions[VI] := Vector3(
        Data.HalfX - 2 * Data.HalfX * U,
        Data.Heights[OZ * G + OX],
        Data.HalfZ - 2 * Data.HalfZ * V);
      HL := Data.Heights[OZ * G + Max(OX - 1, 0)];
      HR := Data.Heights[OZ * G + Min(OX + 1, G - 1)];
      HU := Data.Heights[Max(OZ - 1, 0) * G + OX];
      HD := Data.Heights[Min(OZ + 1, G - 1) * G + OX];
      { восток = -X, юг = -Z: знаки производных согласованы с осями }
      Normals[VI] := Vector3(
        (HR - HL) / (4 * Data.HalfX / (G - 1)),
        1.0,
        (HD - HU) / (4 * Data.HalfZ / (G - 1))).Normalize;
      { CGE TRGBImage хранит ряды снизу-вверх (RawPixels ряд 0 = низ), а
        Data.Tex ряд 0 = СЕВЕР -> север ложится в низ текстуры (V=0). Меш
        севера тоже при V=0 (Z=+HalfZ). Значит V НЕ инвертируем: было
        (U, 1-V) -> текстура выходила вверх ногами. }
      TexCoords[VI] := Vector2(U, V);
    end;
  end;

  SetLength(CoordIdx, (N - 1) * (N - 1) * 8);
  QI := 0;
  for IZ := 0 to N - 2 do
    for IX := 0 to N - 2 do
    begin
      VI := IZ * N + IX;
      CoordIdx[QI]   := VI;         CoordIdx[QI+1] := VI + N;
      CoordIdx[QI+2] := VI + N + 1; CoordIdx[QI+3] := -1;
      CoordIdx[QI+4] := VI;         CoordIdx[QI+5] := VI + N + 1;
      CoordIdx[QI+6] := VI + 1;     CoordIdx[QI+7] := -1;
      Inc(QI, 8);
    end;

  Coord := TCoordinateNode.Create;        Coord.SetPoint(Positions);
  Norm  := TNormalNode.Create;            Norm.SetVector(Normals);
  Geo := TIndexedFaceSetNode.Create;
  Geo.Coord := Coord;
  Geo.Normal := Norm;
  Geo.NormalPerVertex := True;
  Geo.Solid := True;
  Geo.SetCoordIndex(CoordIdx);

  if Data.HasTex then
  begin
    TexC := TTextureCoordinateNode.Create; TexC.SetPoint(TexCoords);
    Geo.TexCoord := TexC;
    Img := TRGBImage.Create(Data.TexPx, Data.TexPx);
    PB := PByte(Img.RawPixels);
    Move(Data.Tex[0], PB^, Length(Data.Tex));
    PixTex := TPixelTextureNode.Create;
    PixTex.FdImage.Value := Img;
    App := TAppearanceNode.Create;
    App.Material := TMaterialNode.Create;
    TMaterialNode(App.Material).DiffuseColor := Vector3(1, 1, 1);
    App.Texture := PixTex;
  end
  else
    App := GrayAppearance;

  Shape := TShapeNode.Create;
  Shape.Geometry   := Geo;
  Shape.Appearance := App;
  Result := TGroupNode.Create;
  Result.AddChildren(Shape);
end;

{ Высоты вершин для центра ACenter → FYto. Пересчитывает по-октавные сетки
  (квадратный бокс ±OctHalf, фикс. разрешение) и билинейно семплит их по
  фиксированным локальным X,Z. Это и есть стоимость перенацеливания (без
  пересбора сцены). }
procedure TOsm3dFarGround.SampleHeights(const ACenter: TLatLon;
  AHeights: TFarHeightGridFunc);
const
  OCT_GRID = 65;                { разрешение сетки высот одной октавы }
var
  OctH: array of THeightArray;
  L, V: Integer;
  HalfLatDeg, HalfLonDeg, CosLat: Double;
  Box: TLatLonBox;

  { наименьшая октава, ещё содержащая радиус, билинейно (детальность падает с R) }
  function SampleOct(PX, PZ: Single): Single;
  var
    Lq, ix0, iz0, ix1, iz1: Integer;
    rr, fx, fz, tx, tz, h00, h01, h10, h11, Half: Single;
  begin
    rr := Sqrt(PX * PX + PZ * PZ);
    Lq := 0;
    while (Lq < FLevels - 1) and (FOctHalf[Lq] < rr) do Inc(Lq);
    if OctH[Lq] = nil then begin Result := 0.0; Exit; end;
    Half := FOctHalf[Lq];
    fx := (Half - PX) / (2.0 * Half) * (OCT_GRID - 1);   { col0=запад=+X }
    fz := (Half - PZ) / (2.0 * Half) * (OCT_GRID - 1);   { row0=север=+Z }
    if fx < 0 then fx := 0 else if fx > OCT_GRID - 1 then fx := OCT_GRID - 1;
    if fz < 0 then fz := 0 else if fz > OCT_GRID - 1 then fz := OCT_GRID - 1;
    ix0 := Trunc(fx);  iz0 := Trunc(fz);
    ix1 := ix0 + 1;  if ix1 > OCT_GRID - 1 then ix1 := OCT_GRID - 1;
    iz1 := iz0 + 1;  if iz1 > OCT_GRID - 1 then iz1 := OCT_GRID - 1;
    tx := fx - ix0;  tz := fz - iz0;
    h00 := OctH[Lq][iz0 * OCT_GRID + ix0];
    h01 := OctH[Lq][iz0 * OCT_GRID + ix1];
    h10 := OctH[Lq][iz1 * OCT_GRID + ix0];
    h11 := OctH[Lq][iz1 * OCT_GRID + ix1];
    Result := (h00 * (1 - tx) + h01 * tx) * (1 - tz)
            + (h10 * (1 - tx) + h11 * tx) * tz;
  end;

begin
  CosLat := Cos(ACenter.Lat * DEG_TO_RAD);
  if Abs(CosLat) < 1.0e-6 then CosLat := 1.0e-6;
  SetLength(OctH, FLevels);
  for L := 0 to FLevels - 1 do
  begin
    HalfLatDeg := FOctHalf[L] / (DEG_TO_RAD * EARTH_RADIUS_M);
    HalfLonDeg := FOctHalf[L] / (DEG_TO_RAD * EARTH_RADIUS_M * CosLat);
    Box.MinLat := ACenter.Lat - HalfLatDeg;
    Box.MaxLat := ACenter.Lat + HalfLatDeg;
    Box.MinLon := ACenter.Lon - HalfLonDeg;
    Box.MaxLon := ACenter.Lon + HalfLonDeg;
    OctH[L] := AHeights(Box, OCT_GRID);
  end;
  for V := 0 to FNV - 1 do
    FYto[V] := SampleOct(FVX[V], FVZ[V]) - FOffset[V];
end;

{ Сглаженные нормали из текущих высот FYcur по фиксированной топологии FCoordIdx
  (обход CCW-сверху; грань на всякий случай ориентируем вверх). Покомпонентно. }
procedure TOsm3dFarGround.RecomputeNormals;
var
  Gci, a, b, c, V: Integer;
  ax, ay, az, bx, by, bz, cx, cy, cz: Single;
  ux, uy, uz, vx, vy, vz, fnx, fny, fnz, fl: Single;
  NAX, NAY, NAZ: array of Single;
begin
  SetLength(NAX, FNV);  SetLength(NAY, FNV);  SetLength(NAZ, FNV);
  Gci := 0;
  while Gci < Length(FCoordIdx) do
  begin
    if FCoordIdx[Gci] >= 0 then
    begin
      a := FCoordIdx[Gci];  b := FCoordIdx[Gci + 1];  c := FCoordIdx[Gci + 2];
      ax := FVX[a];  ay := FYcur[a];  az := FVZ[a];
      bx := FVX[b];  by := FYcur[b];  bz := FVZ[b];
      cx := FVX[c];  cy := FYcur[c];  cz := FVZ[c];
      ux := bx - ax;  uy := by - ay;  uz := bz - az;
      vx := cx - ax;  vy := cy - ay;  vz := cz - az;
      fnx := uy * vz - uz * vy;
      fny := uz * vx - ux * vz;
      fnz := ux * vy - uy * vx;
      if fny < 0 then begin fnx := -fnx;  fny := -fny;  fnz := -fnz; end;
      fl := Sqrt(fnx * fnx + fny * fny + fnz * fnz);
      if fl > 1.0e-9 then begin fnx := fnx / fl;  fny := fny / fl;  fnz := fnz / fl; end
      else begin fnx := 0;  fny := 1;  fnz := 0; end;
      NAX[a] := NAX[a] + fnx;  NAY[a] := NAY[a] + fny;  NAZ[a] := NAZ[a] + fnz;
      NAX[b] := NAX[b] + fnx;  NAY[b] := NAY[b] + fny;  NAZ[b] := NAZ[b] + fnz;
      NAX[c] := NAX[c] + fnx;  NAY[c] := NAY[c] + fny;  NAZ[c] := NAZ[c] + fnz;
    end;
    Inc(Gci, 4);
  end;
  for V := 0 to FNV - 1 do
  begin
    fl := Sqrt(NAX[V] * NAX[V] + NAY[V] * NAY[V] + NAZ[V] * NAZ[V]);
    if fl > 1.0e-9 then FNormals[V] := Vector3(NAX[V] / fl, NAY[V] / fl, NAZ[V] / fl)
    else FNormals[V] := Vector3(0, 1, 0);
  end;
end;

{ Текущие высоты+нормали → узлы сцены (живой апдейт VBO, без пересбора). }
procedure TOsm3dFarGround.PushToNodes;
var V: Integer;
begin
  for V := 0 to FNV - 1 do FPoints[V] := Vector3(FVX[V], FYcur[V], FVZ[V]);
  FCoord.SetPoint(FPoints);
  FNorm.SetVector(FNormals);
end;

{ Пересобирает индекс из FClipRing: квад(Ri,Sj) рисуется, если Ri >= min старт-
  кольца двух его секторов (min → закрываем дыры, минимальное перекрытие).
  Винтовка треугольников идентична исходной (CCW сверху → лицо вверх). }
procedure TOsm3dFarGround.RebuildIndex;
var Ri, Sj, jn, a, b, c, QI, StartRi: Integer;
begin
  { верхняя граница — все квады сетки (по 8 индексов); финальный trim по QI }
  SetLength(FCoordIdx, FRRings * FSectors * 8);
  QI := 0;
  for Ri := 0 to FRRings - 1 do
    for Sj := 0 to FSectors - 1 do
    begin
      jn := (Sj + 1) mod FSectors;
      if FClipRing[Sj] < FClipRing[jn] then StartRi := FClipRing[Sj]
      else StartRi := FClipRing[jn];
      if Ri < StartRi then Continue;
      a := Ri * FSectors + Sj;
      b := (Ri + 1) * FSectors + Sj;
      c := (Ri + 1) * FSectors + jn;
      FCoordIdx[QI]   := a; FCoordIdx[QI+1] := c;                  FCoordIdx[QI+2] := b; FCoordIdx[QI+3] := -1;
      FCoordIdx[QI+4] := a; FCoordIdx[QI+5] := Ri * FSectors + jn; FCoordIdx[QI+6] := c; FCoordIdx[QI+7] := -1;
      Inc(QI, 8);
    end;
  SetLength(FCoordIdx, QI);
  if FGeo <> nil then FGeo.SetCoordIndex(FCoordIdx);
end;

{ Посекторный клип. ARadii[Sj] — радиус покрытия деталью в направлении сектора.
  FClipRing[Sj] = самое внутреннее кольцо с радиусом <= ARadii[Sj] (мин. перекрытие);
  <= внутреннего кольца (или <=0) → 0 (земля до внутреннего кольца). Перестройка
  индекса/нормалей только при фактическом изменении клипа. }
procedure TOsm3dFarGround.SetClip(const ARadii: array of Single);
var Sj, Ri, NewClip: Integer; Changed: Boolean; R: Single;
begin
  if (FGeo = nil) or (Length(ARadii) < FSectors) then Exit;
  Changed := False;
  for Sj := 0 to FSectors - 1 do
  begin
    R := ARadii[Sj];
    NewClip := 0;
    if R > FRingRho[0] then
    begin
      Ri := 0;
      while (Ri < FRRings) and (FRingRho[Ri + 1] <= R) do Inc(Ri);
      NewClip := Ri;
    end;
    if NewClip <> FClipRing[Sj] then
    begin
      FClipRing[Sj] := NewClip;
      Changed := True;
    end;
  end;
  if not Changed then Exit;
  RebuildIndex;
  RecomputeNormals;
  PushToNodes;
end;

constructor TOsm3dFarGround.Create(AOwner: TComponent; const ACenterGeo: TLatLon;
  AInnerHalfM: Single; ALevels, ASectors: Integer; ABiasDownM: Single;
  const AColorR, AColorG, AColorB: Byte; AHeights: TFarHeightGridFunc);
const
  RINGS_PER_OCT = 4;            { радиальных колец на октаву (удвоение радиуса) }
  SINK_MAX_M    = 25.0;         { глубина провала у внутренней кромки (под деталь) }
  SINK_OUTER_M  = 2600.0;       { радиус, где провал сходит на нет (за краем детали) }
var
  S, Ri, Sj, V, L: Integer;
  rInner, rOuter, Rho, LX, LZ, Drop, ExtraDip: Single;
  Theta, RhoRatio: Double;
  Root:  TX3DRootNode;
  Geo:   TIndexedFaceSetNode;
  Shape: TShapeNode;
  App:   TAppearanceNode;
  Mat:   TMaterialNode;
  GrR, GrG, GrB, NearM, FarM: Single;
begin
  inherited Create;
  S := ASectors;
  if S < 8 then S := 8;
  FSectors   := S;
  FLevels    := ALevels;
  FBias      := ABiasDownM;
  FMorphRate := 2.5;                            { ~0.4 c на морф }
  rInner := AInnerHalfM;
  rOuter := AInnerHalfM * (1 shl ALevels);      { ±131 км при 1024·2^7 }
  FRRings := ALevels * RINGS_PER_OCT;
  FNV := (FRRings + 1) * S;

  SetLength(FOctHalf, ALevels);
  for L := 0 to ALevels - 1 do
    FOctHalf[L] := AInnerHalfM * (1 shl (L + 1));

  SetLength(FVX, FNV);   SetLength(FVZ, FNV);   SetLength(FOffset, FNV);
  SetLength(FYcur, FNV); SetLength(FYfrom, FNV); SetLength(FYto, FNV);
  SetLength(FNormals, FNV); SetLength(FPoints, FNV);
  SetLength(FRingRho, FRRings + 1);
  SetLength(FClipRing, S);                       { 0-инициализация → без клипа }

  { Топология (ФИКСИРОВАНА): локальные X,Z и постоянный сдвиг вниз
 FOffset = кривизна + bias + провал (зависит только от радиуса). Высота
 вершины = sampledH - FOffset; при морфе меняется лишь sampledH. }
  for Ri := 0 to FRRings do
  begin
    RhoRatio := Power(rOuter / rInner, Ri / FRRings);
    Rho := rInner * RhoRatio;
    FRingRho[Ri] := Rho;
    if Rho >= SINK_OUTER_M then ExtraDip := 0.0
    else ExtraDip := SINK_MAX_M * (SINK_OUTER_M - Rho) / (SINK_OUTER_M - rInner);
    Drop := (Rho * Rho) / (2.0 * EARTH_RADIUS_M);          { кривизна Земли }
    for Sj := 0 to S - 1 do
    begin
      Theta := 2.0 * Pi * Sj / S;
      LX := Rho * Cos(Theta);
      LZ := Rho * Sin(Theta);
      V  := Ri * S + Sj;
      FVX[V] := LX;
      FVZ[V] := LZ;
      FOffset[V] := Drop + FBias + ExtraDip;
    end;
  end;

  { Индексы: квад между кольцами Ri/Ri+1 и секторами Sj/jn (CCW сверху →
 лицо вверх). Посекторный клип (FClipRing) применяется в RebuildIndex;
 здесь FClipRing=0 → полный меш. }
  RebuildIndex;

  { начальные высоты в центре → морф «в покое» (FYcur = FYfrom = FYto) }
  SampleHeights(ACenterGeo, AHeights);
  Move(FYto[0], FYcur[0],  FNV * SizeOf(Single));
  Move(FYto[0], FYfrom[0], FNV * SizeOf(Single));
  FCenter := ACenterGeo;
  FMorph  := 1.0;
  RecomputeNormals;

  { Сцена. Узлы Coord/Norm держим в полях для покадрового апдейта при морфе. }
  FCoord := TCoordinateNode.Create;
  FNorm  := TNormalNode.Create;
  for V := 0 to FNV - 1 do FPoints[V] := Vector3(FVX[V], FYcur[V], FVZ[V]);
  FCoord.SetPoint(FPoints);
  FNorm.SetVector(FNormals);
  Geo := TIndexedFaceSetNode.Create;
  Geo.Coord := FCoord;
  Geo.Normal := FNorm;
  Geo.NormalPerVertex := True;
  Geo.Solid := False;
  Geo.SetCoordIndex(FCoordIdx);
  FGeo := Geo;

  Mat := TMaterialNode.Create;
  { КОНСТАНТНЫЙ цвет дальней земли (FAR_GROUND_*) вместо живого среднего
    цвета атласа: дальняя земля — атмосферная дымка, сливающаяся с
    горизонтом. Эмиссив + нулевой диффуз/эмбиент → без затенения солнцем
    и нормалями, на экране ровно заданный цвет. AColorR/G/B в параметрах
    конструктора и MAT_RGB здесь больше не используются. }
  Mat.DiffuseColor     := Vector3(0, 0, 0);
  Mat.EmissiveColor    := Vector3(FAR_GROUND_R / 255,
                                  FAR_GROUND_G / 255,
                                  FAR_GROUND_B / 255);
  Mat.AmbientIntensity := 0.0;
  App := TAppearanceNode.Create;
  App.Material := Mat;
  { Блендинг по дальности: у внутренней кромки (AInnerHalfM) — цвет травы, дальше
    — цвет дальней земли (FAR_GROUND). Тот же общий шейдер, что и у заглушек. }
  GrR := MAT_RGB[0][0] / 255; GrG := MAT_RGB[0][1] / 255; GrB := MAT_RGB[0][2] / 255;
  if (GrR = 0) and (GrG = 0) and (GrB = 0) then
  begin GrR := 0.35; GrG := 0.50; GrB := 0.28; end;
  NearM := AInnerHalfM;
  FarM  := AInnerHalfM * 3.0;
  ChainEffectApp(App, BuildGroundBlendEffect(GrR, GrG, GrB,
    FAR_GROUND_R / 255, FAR_GROUND_G / 255, FAR_GROUND_B / 255, NearM, FarM));

  Shape := TShapeNode.Create;
  Shape.Geometry   := Geo;
  Shape.Appearance := App;
  Root := TX3DRootNode.Create;
  Root.AddChildren(Shape);

  FScene := TCastleScene.Create(AOwner);
  FScene.Load(Root, True);
  FScene.DistanceCulling := 0;
  FScene.Collides := False;
  FScene.Pickable := False;
end;

{ Перенацелить на новый центр: текущее — старт морфа, новые высоты — цель. }
procedure TOsm3dFarGround.Retarget(const ACenterGeo: TLatLon;
  AHeights: TFarHeightGridFunc);
begin
  Move(FYcur[0], FYfrom[0], FNV * SizeOf(Single));   { старт морфа = текущее }
  SampleHeights(ACenterGeo, AHeights);               { цель = новые высоты }
  FCenter := ACenterGeo;
  FMorph  := 0.0;
end;

{ Каждый кадр: продвигает морф (smoothstep) и заливает геометрию; в покое — выход. }
procedure TOsm3dFarGround.Animate(const ADtSeconds: Single);
var
  V: Integer;
  t: Single;
begin
  if FMorph >= 1.0 then Exit;
  FMorph := FMorph + ADtSeconds * FMorphRate;
  if FMorph > 1.0 then FMorph := 1.0;
  t := FMorph * FMorph * (3.0 - 2.0 * FMorph);       { smoothstep }
  for V := 0 to FNV - 1 do
    FYcur[V] := FYfrom[V] + (FYto[V] - FYfrom[V]) * t;
  RecomputeNormals;
  PushToNodes;
end;

procedure InitPreviewColorsFromMaterials;
var
  I: Integer;
begin
  for I := 0 to GROUND_MAT_COUNT - 1 do
  begin
    MAT_RGB[I][0] := Round(EnsureRange(GROUND_MATERIALS[I].FallbackColor.X, 0, 1) * 255);
    MAT_RGB[I][1] := Round(EnsureRange(GROUND_MATERIALS[I].FallbackColor.Y, 0, 1) * 255);
    MAT_RGB[I][2] := Round(EnsureRange(GROUND_MATERIALS[I].FallbackColor.Z, 0, 1) * 255);
  end;
end;

initialization
  InitPreviewColorsFromMaterials;

end.
