unit Osm3dOsmIndex;

{ ЕДИНЫЙ пер-блочный индекс дорог поверх TOSMDataset.

  Мотивация. Несколько потребителей независимо сканировали ВЕСЬ датасет
  на каждый свой объект — класс O(объектов × датасета):
    - остановки (модели POI и таблички): ComputeStopPlacement обходил все
      ways × узлы на каждую остановку (~24 с из ~26 с фазы табличек);
    - мосты: FindApproach на КАЖДЫЙ конец КАЖДОГО моста обходил все ways
      с ParseRoadParams (строковый разбор тегов!) и все их узлы — на
      мостатых блоках ~14 с однопоточной работы.
  Вместо трёх ad-hoc индексов — один общий: строится ОДИН раз на блок
  (TGeometryBuilder.Build, сразу после решётки узлов), после Build
  read-only и потому безопасен для параллельных категорий пула.

  Содержимое:
    - кэш классификации: WayId -> Ord(TRoadKind), один ParseRoadParams
      на way за блок вместо тысяч;
    - adjacency: NodeId -> список (дорожный way, позиция узла) — запрос
      «какие дороги проходят через узел» становится O(степени узла);
    - CSR-сетка (ячейка 64 м) сегментов ПРОЕЗЖИХ дорог (фильтр остановок:
      без footway/path/cycleway/steps/pedestrian/bridleway/corridor/
      platform/track) — ближайший сегмент в радиусе за O(окрестности);
    - координаты POI-остановок (platform/bus_stop) для дедупа
      stop_position.

  Координаты — через NodePlanePos (int-first решётка при её наличии). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Generics.Collections,
  CastleVectors,
  Osm3dGeoMath,       { TLocalProjection }
  Osm3dOsmData,       { TOSMDataset/Way/Node, NodePlanePos }
  Osm3dGeomRoads;     { TRoadBuilder.ParseRoadParams, TRoadKind }

type
  TRoadAdjEntry = record
    Way: TOSMWay;
    Pos: Integer;      { позиция узла в Way.NodeRefs }
  end;
  TRoadAdjArray = array of TRoadAdjEntry;

  TIdxSeg = record
    Ax, Az, Bx, Bz: Single;
  end;

  TOsmRoadIndex = class
  private
    type
      TAdjMap  = specialize TDictionary<Int64, TRoadAdjArray>;
      TKindMap = specialize TDictionary<Int64, Integer>;
    const
      GRID_CELL_M = 64.0;   { ячейка сетки; запрос ±40 м покрывает <= 3x3 }
  private
    FAdj:  TAdjMap;
    FKind: TKindMap;
    FSegs: array of TIdxSeg;
    FSegN: Integer;
    FGridMinX, FGridMinZ: Single;
    FCellsX, FCellsZ: Integer;
    FCellStart: array of Integer;   { CSR-префиксы, FCellsX*FCellsZ + 1 }
    FCellSegs:  array of Integer;
    FPoiX, FPoiZ: array of Single;
    FPoiN: Integer;
  public
    constructor Build(ADataset: TOSMDataset; AProjection: TLocalProjection);
    destructor Destroy; override;

    { Ord(TRoadKind) дорожного way; -1 — way не дорога или неизвестен. }
    function RoadKindOrd(AWayId: Int64): Integer;

    { Дорожные ways (Kind<>rkNone), проходящие через узел. False — узел
      не принадлежит ни одной дороге. Список read-only. }
    function AdjOf(ANodeId: Int64; out AList: TRoadAdjArray): Boolean;

    { Ближайший к (APx,APz) сегмент ПРОЕЗЖЕЙ дороги в радиусе AMaxSearch.
      AQx/AQz — ближайшая точка на сегменте, AEx/AEz — вектор сегмента. }
    function NearestVehicularSeg(APx, APz, AMaxSearch: Single;
      out AQx, AQz, AEx, AEz: Single): Boolean;

    { Есть ли POI-остановка (platform/bus_stop) в радиусе ARadius. }
    function HasPoiStopWithin(APx, APz, ARadius: Single): Boolean;

    property VehicularSegCount: Integer read FSegN;
    property PoiStopCount: Integer read FPoiN;
  end;

implementation

{ фильтр «проезжей» дороги для остановок — 1:1 со старым строковым
  фильтром ComputeStopPlacement (автобус смотрит на проезжую часть) }
function VehicularHighway(const AHwy: string): Boolean;
begin
  Result := (AHwy <> '') and (AHwy <> 'footway') and (AHwy <> 'path')
    and (AHwy <> 'cycleway') and (AHwy <> 'steps') and (AHwy <> 'pedestrian')
    and (AHwy <> 'bridleway') and (AHwy <> 'corridor')
    and (AHwy <> 'platform') and (AHwy <> 'track');
end;

{ POI-остановка — точная копия BusStopIsPoiNode из Osm3dGeomPOI (та функция
  в implementation-секции; дублируем четыре сравнения, а не тянем юнит) }
function PoiStopNode(const ATags: TOSMTags): Boolean;
var
  V: string;
begin
  if ATags.GetLower('highway') = 'bus_stop' then Exit(True);
  if ATags.GetLower('highway') = 'platform' then Exit(True);
  V := ATags.GetLower('public_transport');
  Result := (V = 'platform') or (V = 'station');
end;

constructor TOsmRoadIndex.Build(ADataset: TOSMDataset;
  AProjection: TLocalProjection);
var
  Way:  TOSMWay;
  Node: TOSMNode;
  RP:   TRoadParams;
  KindOrd, I, SegCap, K, AdjN: Integer;
  Lst:  TRoadAdjArray;
  AdjCnt: TKindMap;   { фактические степени узлов (Length в FAdj — ёмкость) }
  CntPair: specialize TPair<Int64, Integer>;
  P:    TVector3;
  PrevOK, HaveBox, Vehic: Boolean;
  Ax, Az, Bx, Bz: Single;
  MinX, MinZ, MaxX, MaxZ: Single;
  CX0, CX1, CZ0, CZ1, CX, CZ, CI: Integer;

  procedure CellRangeOf(const S: TIdxSeg; out AX0, AZ0, AX1, AZ1: Integer);
  var
    LoX, HiX, LoZ, HiZ: Single;
  begin
    if S.Ax < S.Bx then begin LoX := S.Ax; HiX := S.Bx; end
    else begin LoX := S.Bx; HiX := S.Ax; end;
    if S.Az < S.Bz then begin LoZ := S.Az; HiZ := S.Bz; end
    else begin LoZ := S.Bz; HiZ := S.Az; end;
    AX0 := Trunc((LoX - FGridMinX) / GRID_CELL_M);
    AX1 := Trunc((HiX - FGridMinX) / GRID_CELL_M);
    AZ0 := Trunc((LoZ - FGridMinZ) / GRID_CELL_M);
    AZ1 := Trunc((HiZ - FGridMinZ) / GRID_CELL_M);
    if AX0 < 0 then AX0 := 0;
    if AZ0 < 0 then AZ0 := 0;
    if AX1 >= FCellsX then AX1 := FCellsX - 1;
    if AZ1 >= FCellsZ then AZ1 := FCellsZ - 1;
  end;

begin
  inherited Create;
  FAdj  := TAdjMap.Create;
  FKind := TKindMap.Create;
  FSegs := nil; FSegN := 0;
  FCellStart := nil; FCellSegs := nil;
  FPoiX := nil; FPoiZ := nil; FPoiN := 0;
  FGridMinX := 0; FGridMinZ := 0;
  FCellsX := 1; FCellsZ := 1;

  if (ADataset = nil) or (AProjection = nil) then
  begin
    SetLength(FCellStart, 2);
    FCellStart[0] := 0; FCellStart[1] := 0;
    Exit;
  end;

  { adjacency-списки: Length — ёмкость, фактическая степень в AdjCnt;
    блочный рост удвоением, trim до степени после основного цикла }
  AdjCnt := TKindMap.Create;
  try
  { один проход по ways: классификация + adjacency + сегменты проезжих }
  SegCap := 0;
  HaveBox := False;
  MinX := 0; MinZ := 0; MaxX := 0; MaxZ := 0;
  for Way in ADataset.Ways.Values do
  begin
    if (Way = nil) or (Length(Way.NodeRefs) = 0) then Continue;
    RP := TRoadBuilder.ParseRoadParams(Way.Tags);
    if RP.Kind = rkNone then Continue;
    KindOrd := Ord(RP.Kind);
    FKind.AddOrSetValue(Way.Id, KindOrd);

    { adjacency: каждое вхождение узла (само-петли дают два входа —
      семантика 1:1 со старым полным сканом FindApproach) }
    for I := 0 to High(Way.NodeRefs) do
    begin
      if not FAdj.TryGetValue(Way.NodeRefs[I], Lst) then Lst := nil;
      if not AdjCnt.TryGetValue(Way.NodeRefs[I], AdjN) then AdjN := 0;
      if AdjN >= Length(Lst) then
      begin
        if Length(Lst) = 0 then SetLength(Lst, 4)
        else SetLength(Lst, Length(Lst) * 2);
        FAdj.AddOrSetValue(Way.NodeRefs[I], Lst);
      end;
      Lst[AdjN].Way := Way;
      Lst[AdjN].Pos := I;
      AdjCnt.AddOrSetValue(Way.NodeRefs[I], AdjN + 1);
    end;

    { сегменты проезжих дорог для остановок }
    Vehic := VehicularHighway(Way.Tags.GetLower('highway'))
             and (Length(Way.NodeRefs) >= 2);
    if not Vehic then Continue;
    PrevOK := False;
    Ax := 0; Az := 0;
    for I := 0 to High(Way.NodeRefs) do
    begin
      Node := ADataset.FindNode(Way.NodeRefs[I]);
      if Node = nil then begin PrevOK := False; Continue; end;
      P := NodePlanePos(ADataset, Node, AProjection);
      Bx := P.X; Bz := P.Z;
      if PrevOK then
      begin
        if FSegN >= SegCap then
        begin
          if SegCap = 0 then SegCap := 4096 else SegCap := SegCap * 2;
          SetLength(FSegs, SegCap);
        end;
        FSegs[FSegN].Ax := Ax; FSegs[FSegN].Az := Az;
        FSegs[FSegN].Bx := Bx; FSegs[FSegN].Bz := Bz;
        Inc(FSegN);
        if not HaveBox then
        begin
          MinX := Ax; MaxX := Ax; MinZ := Az; MaxZ := Az; HaveBox := True;
        end;
        if Ax < MinX then MinX := Ax else if Ax > MaxX then MaxX := Ax;
        if Bx < MinX then MinX := Bx else if Bx > MaxX then MaxX := Bx;
        if Az < MinZ then MinZ := Az else if Az > MaxZ then MaxZ := Az;
        if Bz < MinZ then MinZ := Bz else if Bz > MaxZ then MaxZ := Bz;
      end;
      Ax := Bx; Az := Bz; PrevOK := True;
    end;
  end;

  { trim adjacency-ёмкостей до фактических степеней }
  for CntPair in AdjCnt do
  begin
    Lst := FAdj[CntPair.Key];
    SetLength(Lst, CntPair.Value);
    FAdj[CntPair.Key] := Lst;
  end;
  finally
    AdjCnt.Free;
  end;

  { CSR-сетка: счёт -> префиксы -> раскладка (со сдвигом и откатом) }
  if HaveBox then
  begin
    FGridMinX := MinX;
    FGridMinZ := MinZ;
    FCellsX := Trunc((MaxX - MinX) / GRID_CELL_M) + 1;
    FCellsZ := Trunc((MaxZ - MinZ) / GRID_CELL_M) + 1;
    if FCellsX < 1 then FCellsX := 1;
    if FCellsZ < 1 then FCellsZ := 1;
  end;
  SetLength(FCellStart, FCellsX * FCellsZ + 1);
  for I := 0 to High(FCellStart) do FCellStart[I] := 0;
  for I := 0 to FSegN - 1 do
  begin
    CellRangeOf(FSegs[I], CX0, CZ0, CX1, CZ1);
    for CZ := CZ0 to CZ1 do
      for CX := CX0 to CX1 do
        Inc(FCellStart[CZ * FCellsX + CX + 1]);
  end;
  for I := 1 to High(FCellStart) do
    FCellStart[I] := FCellStart[I] + FCellStart[I - 1];
  SetLength(FCellSegs, FCellStart[High(FCellStart)]);
  for I := 0 to FSegN - 1 do
  begin
    CellRangeOf(FSegs[I], CX0, CZ0, CX1, CZ1);
    for CZ := CZ0 to CZ1 do
      for CX := CX0 to CX1 do
      begin
        CI := CZ * FCellsX + CX;
        FCellSegs[FCellStart[CI]] := I;
        Inc(FCellStart[CI]);
      end;
  end;
  for I := High(FCellStart) downto 1 do
    FCellStart[I] := FCellStart[I - 1];
  FCellStart[0] := 0;

  { POI-остановки для дедупа stop_position }
  K := 0;
  for Node in ADataset.Nodes.Values do
  begin
    if Node.Tags.Count = 0 then Continue;
    if not PoiStopNode(Node.Tags) then Continue;
    if K >= Length(FPoiX) then
    begin
      if Length(FPoiX) = 0 then
      begin
        SetLength(FPoiX, 64); SetLength(FPoiZ, 64);
      end
      else
      begin
        SetLength(FPoiX, Length(FPoiX) * 2);
        SetLength(FPoiZ, Length(FPoiZ) * 2);
      end;
    end;
    P := NodePlanePos(ADataset, Node, AProjection);
    FPoiX[K] := P.X;
    FPoiZ[K] := P.Z;
    Inc(K);
  end;
  FPoiN := K;
end;

destructor TOsmRoadIndex.Destroy;
begin
  FAdj.Free;
  FKind.Free;
  inherited;
end;

function TOsmRoadIndex.RoadKindOrd(AWayId: Int64): Integer;
begin
  if not FKind.TryGetValue(AWayId, Result) then Result := -1;
end;

function TOsmRoadIndex.AdjOf(ANodeId: Int64;
  out AList: TRoadAdjArray): Boolean;
begin
  Result := FAdj.TryGetValue(ANodeId, AList);
  if not Result then AList := nil;
end;

function TOsmRoadIndex.NearestVehicularSeg(APx, APz, AMaxSearch: Single;
  out AQx, AQz, AEx, AEz: Single): Boolean;
var
  CX0, CX1, CZ0, CZ1, CX, CZ, CI, K, SI: Integer;
  Ax, Az, Bx, Bz, ex, ez, len2, t, qx, qz, dx, dz, d2, bestD2: Single;
begin
  Result := False;
  AQx := 0; AQz := 0; AEx := 0; AEz := 0;
  if FSegN = 0 then Exit;

  CX0 := Trunc((APx - AMaxSearch - FGridMinX) / GRID_CELL_M);
  CX1 := Trunc((APx + AMaxSearch - FGridMinX) / GRID_CELL_M);
  CZ0 := Trunc((APz - AMaxSearch - FGridMinZ) / GRID_CELL_M);
  CZ1 := Trunc((APz + AMaxSearch - FGridMinZ) / GRID_CELL_M);
  if CX0 < 0 then CX0 := 0;
  if CZ0 < 0 then CZ0 := 0;
  if CX1 >= FCellsX then CX1 := FCellsX - 1;
  if CZ1 >= FCellsZ then CZ1 := FCellsZ - 1;
  if (CX0 > CX1) or (CZ0 > CZ1) then Exit;

  bestD2 := AMaxSearch * AMaxSearch;
  for CZ := CZ0 to CZ1 do
    for CX := CX0 to CX1 do
    begin
      CI := CZ * FCellsX + CX;
      for K := FCellStart[CI] to FCellStart[CI + 1] - 1 do
      begin
        SI := FCellSegs[K];
        Ax := FSegs[SI].Ax; Az := FSegs[SI].Az;
        Bx := FSegs[SI].Bx; Bz := FSegs[SI].Bz;
        ex := Bx - Ax; ez := Bz - Az;
        len2 := ex * ex + ez * ez;
        if len2 <= 1.0e-9 then Continue;
        t := ((APx - Ax) * ex + (APz - Az) * ez) / len2;
        if t < 0 then t := 0 else if t > 1 then t := 1;
        qx := Ax + ex * t; qz := Az + ez * t;
        dx := APx - qx; dz := APz - qz;
        d2 := dx * dx + dz * dz;
        { сегмент может лежать в нескольких посещённых ячейках — повтор
          даёт тот же минимум, дедуп не нужен }
        if d2 < bestD2 then
        begin
          bestD2 := d2;
          Result := True;
          AQx := qx; AQz := qz; AEx := ex; AEz := ez;
        end;
      end;
    end;
end;

function TOsmRoadIndex.HasPoiStopWithin(APx, APz, ARadius: Single): Boolean;
var
  I: Integer;
  dx, dz: Single;
begin
  Result := False;
  for I := 0 to FPoiN - 1 do
  begin
    dx := FPoiX[I] - APx;
    dz := FPoiZ[I] - APz;
    if dx * dx + dz * dz <= ARadius * ARadius then Exit(True);
  end;
end;

end.
