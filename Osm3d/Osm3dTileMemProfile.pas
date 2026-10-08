unit Osm3dTileMemProfile;

{ Профайлер РЕАЛЬНОГО размера тайла в памяти. Считает байты ОТДЕЛЬНО по каждому массиву TTileModel
  (вершины, индексы, per-vertex materialId, border-индексы, деревья/кусты, дорожные сегменты, POI,
  теневые данные) для путей 'cache' (с диска) и 'gen' (только сгенерированный). Размеры — через
  SizeOf() реальных записей и фактическую длину массивов, без «магических» констант. Пишет разбивку
  в общий лог (тот же TLogTarget, что у кеша и генератора) и копит итог за сессию.

  ЗАКРЫТ ПОД DEFINE: без TILE_MEM_PROFILE юнит пуст, вызовы (под тем же {$IFDEF}) не компилируются.
  DEFINE должен быть ПРОЕКТНЫМ (-dTILE_MEM_PROFILE в Custom Options / .lpi), т.к. он обязан
  действовать и здесь, и в Osm3dGeoTileCache, и в Osm3dBlockGenerator — unit-level $DEFINE не годится. }

{$mode objfpc}{$H+}

interface

{$IFDEF TILE_MEM_PROFILE}
uses
  Osm3dStudioLog,        { TLogTarget }
  Osm3dTileX3D;          { TTileModel }

{ Считает и логирует разбивку памяти одного тайла.
    Model    — поднятый/сгенерированный тайл (nil безопасен);
    ASource  — 'cache' или 'gen' (любая короткая метка пути);
    ATileTag — текст идентификатора тайла для строки лога (TileId.ToString);
    AExtraMs — load/build ms для контекста (0, если не нужно);
    ALog     — лог-таргет; nil => только обновить итог, без печати. }
procedure ProfileTileModel(Model: TTileModel; const ASource, ATileTag: string;
  AExtraMs: Int64; ALog: TLogTarget);
{$ENDIF}

implementation

{$IFDEF TILE_MEM_PROFILE}
uses
  SysUtils,
  Osm3dGeomMesh;         { TMeshVertex — для SizeOf }

const
  MB = 1024.0 * 1024.0;
  { Порог печати отдельного меша (мелочь не засоряет лог). }
  MESH_LOG_THRESHOLD = 256 * 1024;   { 256 KB }

{ Накопительный итог за сессию. ProfileTileModel вызывается из IO/gen
  воркеров, поэтому доступ под критической секцией. Сама секция создаётся
  один раз в initialization (однопоточно), без ленивых гонок. }
var
  GLock:       TRTLCriticalSection;
  GCacheBytes: Int64 = 0;
  GGenBytes:   Int64 = 0;
  GCacheTiles: Integer = 0;
  GGenTiles:   Integer = 0;

function FmtMB(B: Int64): string;
begin
  Result := FormatFloat('0.00', B / MB);
end;

{ 1234567 -> "1,234,567" (без зависимости от локали). }
function FmtN(N: Int64): string;
var
  S: string;
  i, c: Integer;
begin
  if N < 0 then Exit(IntToStr(N));
  S := IntToStr(N);
  Result := '';
  c := 0;
  for i := Length(S) downto 1 do
  begin
    Result := S[i] + Result;
    Inc(c);
    if (c mod 3 = 0) and (i > 1) then
      Result := ',' + Result;
  end;
end;

procedure ProfileTileModel(Model: TTileModel; const ASource, ATileTag: string;
  AExtraMs: Int64; ALog: TLogTarget);
var
  i: Integer;
  MR: TTileMeshRec;
  meshVtxB, meshIdxB: Int64;
  vtxB, idxB, matB, borB: Int64;
  treeB, poiB, roadB, shadB, listB, totB: Int64;
  vCount, triCount: Int64;
  cumB: Int64;
  cumTiles: Integer;
begin
  if Model = nil then Exit;

  vtxB := 0; idxB := 0; matB := 0; borB := 0;
  vCount := 0; triCount := 0;

  for i := 0 to Model.MeshCount - 1 do
  begin
    MR := Model.Meshes[i];   { копия записи: Mesh — ссылка, массивы — refcount }
    if MR.Mesh <> nil then
    begin
      meshVtxB := Int64(MR.Mesh.VertexCount)   * SizeOf(TMeshVertex);
      meshIdxB := Int64(MR.Mesh.TriangleCount) * 3 * SizeOf(Cardinal);
      vtxB     := vtxB + meshVtxB;
      idxB     := idxB + meshIdxB;
      vCount   := vCount   + MR.Mesh.VertexCount;
      triCount := triCount + MR.Mesh.TriangleCount;
    end
    else
    begin
      meshVtxB := 0; meshIdxB := 0;
    end;
    matB := matB + Int64(Length(MR.WaterScale)) * SizeOf(Single);
    matB := matB + Int64(Length(MR.MatIds))    * SizeOf(Integer);
    borB := borB + Int64(Length(MR.BorderIdx)) * SizeOf(Integer);
  end;

  { Прочие массивы тайла (счётчики/типы — публичные). }
  treeB := Int64(Model.TreeCount)    * SizeOf(TTileTreeRec);
  poiB  := Int64(Model.POICount)     * SizeOf(TTilePOIRec);
  roadB := Int64(Model.RoadSegCount) * SizeOf(TTileRoadSeg);

  { Теневые данные (TRANSIENT — есть у gen-тайла, у disk-тайла обычно пусто). }
  shadB := Int64(Length(Model.ShadowTris))  * SizeOf(TProjTri)
         + Int64(Length(Model.ShadowTrees)) * SizeOf(TShadowTreeCard)
         + Int64(Length(Model.ShadowMask));   { TShadowMaskBytes = array of Byte }

  { Сам массив записей мешей. }
  listB := Int64(Model.MeshCount) * SizeOf(TTileMeshRec);

  totB := vtxB + idxB + matB + borB + treeB + poiB + roadB + shadB + listB;

  { Итог за сессию. }
  EnterCriticalSection(GLock);
  try
    if ASource = 'gen' then
    begin
      GGenBytes := GGenBytes + totB; Inc(GGenTiles);
    end
    else
    begin
      GCacheBytes := GCacheBytes + totB; Inc(GCacheTiles);
    end;
    cumB     := GGenBytes + GCacheBytes;
    cumTiles := GGenTiles + GCacheTiles;
  finally
    LeaveCriticalSection(GLock);
  end;

  if ALog = nil then Exit;

  ALog.Write(llInfo, Format(
    '[tile-mem %s] %s  %dms  TOTAL %s MB   (session: %s MB / %d tiles; cache=%s gen=%s MB)',
    [ASource, ATileTag, AExtraMs, FmtMB(totB),
     FmtMB(cumB), cumTiles, FmtMB(GCacheBytes), FmtMB(GGenBytes)]));

  ALog.Write(llInfo, Format(
    '    arrays[MB]: vtx %s (%s v x%dB) | idx %s (%s tri x%dB) | matId %s | border %s | trees %s (%s) | road %s (%d) | poi %s (%d) | shadow %s | list %s',
    [FmtMB(vtxB), FmtN(vCount), SizeOf(TMeshVertex),
     FmtMB(idxB), FmtN(triCount), 3 * SizeOf(Cardinal),
     FmtMB(matB), FmtMB(borB),
     FmtMB(treeB), FmtN(Model.TreeCount),
     FmtMB(roadB), Model.RoadSegCount,
     FmtMB(poiB), Model.POICount,
     FmtMB(shadB), FmtMB(listB)]));

  { Покрупному — каждый меш >= порога отдельной строкой (реальные данные на
    каждый значимый массив вершин/индексов). }
  for i := 0 to Model.MeshCount - 1 do
  begin
    MR := Model.Meshes[i];
    if MR.Mesh = nil then Continue;
    meshVtxB := Int64(MR.Mesh.VertexCount)   * SizeOf(TMeshVertex);
    meshIdxB := Int64(MR.Mesh.TriangleCount) * 3 * SizeOf(Cardinal);
    if (meshVtxB + meshIdxB) >= MESH_LOG_THRESHOLD then
      ALog.Write(llInfo, Format(
        '      mesh %-22s %s MB  (%s v / %s tri)',
        [Copy(MR.Name, 1, 22), FmtMB(meshVtxB + meshIdxB),
         FmtN(MR.Mesh.VertexCount), FmtN(MR.Mesh.TriangleCount)]));
  end;
end;
{$ENDIF}

initialization
  {$IFDEF TILE_MEM_PROFILE}
  InitCriticalSection(GLock);
  {$ENDIF}

finalization
  {$IFDEF TILE_MEM_PROFILE}
  DoneCriticalSection(GLock);
  {$ENDIF}

end.
