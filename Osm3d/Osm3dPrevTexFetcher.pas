unit Osm3dPrevTexFetcher;

{ Osm3d-юниты отлаживались с выключенными overflow/range проверками. }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  Math,
  SyncObjs,
  Generics.Collections,
  FPImage,
  FPReadPNG,
  FPWritePNG,
  Osm3dGeoMath,
  Osm3dGeoTileGrid,
  Osm3dGeoTileBlock,
  Osm3dGeoTileCache,
  Osm3dStudioSettings,        { GEO_BLOCK_SIZE }
  Osm3dTilePreview            { (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX), TTilePreviewData }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { Internal LRU brick — one decoded block texture + bookkeeping. }
  TPrevTexEntry = class
  public
    RGB: TBytes;       { Px*Px*3 RGB, row 0 = север; пусто = блока нет на диске }
    Px:  Integer;      { сторона (BlockSize*(GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX)) }
    Seq: Int64;        { last-touch для LRU }
  end;

  { Источник+кэш превью-текстур по блокам. ACache — DI (путь к диску); владелец
    его НЕ здесь. }
  TPrevTexFetcher = class
  private
    FCache:     TGeoTileCache;
    FLock:      TCriticalSection;
    FBlocks:    specialize TObjectDictionary<string, TPrevTexEntry>;
    FLoading:   specialize TDictionary<string, Boolean>;
    FMaxBlocks: Integer;
    FSeq:       Int64;
    FBlockSize: Integer;
    FBlockPx:   Integer;       { = FBlockSize * (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX) }

    procedure EvictLocked;
    { NW (северо-западный) тайл блока — по нему кэш строит путь PNG. }
    function  BlockNW(const B: TBlockId): TGeoTileId;
    { Декод блок-PNG с диска. False -> файла нет/битый (ARGB пуст). }
    function  LoadBlockPng(const B: TBlockId; out ARGB: TBytes;
                out APx: Integer): Boolean;
    { Кэшированная (или загруженная, коалесц.) RGB блока. Пусто, если блока
      нет на диске. Возвращает ССЫЛКУ (refcount) — caller не держит лок. }
    function  BlockRGB(const B: TBlockId): TBytes;
    procedure StoreBlock(const AKey: string; const ARGB: TBytes; APx: Integer);
  public
    constructor Create(ACache: TGeoTileCache;
      ABlockSize: Integer = 0; AMaxBlocks: Integer = 64);
    destructor  Destroy; override;

    { Записать блок-PNG из per-tile превью-текстур пачки. ATiles[i] и ATex[i]
      параллельны; берётся .Tex ((GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX) RGB) каждого тайла и кладётся
      в свою клетку блок-картинки (позиция = TX/TY mod BlockSize, строка 0 =
      север). Отсутствующий/без-текстуры тайл -> зелёный. Кэш блока обновляется
      на свежезаписанный (без повторного чтения с диска). }
    procedure WriteBatch(const ABlock: TBlockId;
      const ATiles: array of TGeoTileId;
      const ATex: array of TTilePreviewData);

    { 1x1: (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX) RGB тайла, вырезанный из его блок-PNG.
      Пусто (Length=0), если блок-PNG отсутствует. row 0 = север. }
    function GetTileTexture(const ATile: TGeoTileId): TBytes;

    { Супер: AOutPx*AOutPx RGB на span*span тайлов от ANW (углового NW), сшитый
      из покрывающих блок-PNG (каждый уменьшается в свою долю). Отсутствующий
      блок -> зелёный квадрат. row 0 = север. ASpan кратен BlockSize (суперы
      блок-выровнены: 4/16/64). }
    function GetSuperTexture(const ANW: TGeoTileId;
      ASpan, AOutPx: Integer): TBytes;

    property BlockPx: Integer read FBlockPx;
  end;

implementation

type
  { Protected-member crack for TFPMemoryImage.FData — the row-major
    TFPColor array fcl-image's own Get/SetInternalColor indexes as
    PFPColorArray(FData)^[y*FWidth+x]. Direct pixel access instead of
    per-pixel virtual Colors[] calls. }
  TFPMemoryImageCrack = class(TFPMemoryImage);

{ Цвет «нет данных» — PREVIEW_NODATA_RGB из Osm3dTilePreview (там же ей
  заливается база тайловой превью-текстуры): продюсеры и детектор пустого
  супертайла сверяются с одним значением. }

{ Залить RGB-буфер плоским зелёным PREVIEW_NODATA_RGB. }
procedure FillGreen(var ARGB: TBytes);
var I, N: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1605);{$ENDIF}
  N := Length(ARGB) div 3;
  for I := 0 to N - 1 do
  begin
    ARGB[I * 3]     := PREVIEW_NODATA_RGB[0];
    ARGB[I * 3 + 1] := PREVIEW_NODATA_RGB[1];
    ARGB[I * 3 + 2] := PREVIEW_NODATA_RGB[2];
  end;
end;

{ Скопировать квадрат SrcPx px из ASrc в клетку (ADX,ADY) приёмника ADst
  (сторона ADstPx) БЕЗ масштаба (1:1). Используется для записи тайла в блок
  и кропа тайла из блока. }
procedure BlitSquare(var ADst: TBytes; ADstPx, ADstX0, ADstY0: Integer;
  const ASrc: TBytes; ASrcPx: Integer);
var X, Y, S, D: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1606);{$ENDIF}
  for Y := 0 to ASrcPx - 1 do
    for X := 0 to ASrcPx - 1 do
    begin
      S := (Y * ASrcPx + X) * 3;
      D := ((ADstY0 + Y) * ADstPx + (ADstX0 + X)) * 3;
      ADst[D]     := ASrc[S];
      ADst[D + 1] := ASrc[S + 1];
      ADst[D + 2] := ASrc[S + 2];
    end;
end;

{ Box-усреднение ASrc (сторона ASrcPx) в квадрат AReg px в клетку (AOX,AOY)
  приёмника ADst (сторона ADstPx). Для сшивки супера: блок 512 -> доля (напр.
  128 для L1, 32 для L2). }
procedure DownscaleInto(var ADst: TBytes; ADstPx, AOX, AOY, AReg: Integer;
  const ASrc: TBytes; ASrcPx: Integer);
var
  DX, DY, OX, OY, SX, SY, SI, DI: Integer;
  RR, AccR, AccG, AccB, Cnt: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1607);{$ENDIF}
  if AReg < 1 then Exit;
  RR := ASrcPx div AReg;                  { сторона усредняемого блока }
  if RR < 1 then RR := 1;                  { апскейл -> ближайший }
  for DY := 0 to AReg - 1 do
    for DX := 0 to AReg - 1 do
    begin
      AccR := 0; AccG := 0; AccB := 0; Cnt := 0;
      for OY := 0 to RR - 1 do
        for OX := 0 to RR - 1 do
        begin
          SX := DX * ASrcPx div AReg + OX;
          SY := DY * ASrcPx div AReg + OY;
          if (SX < ASrcPx) and (SY < ASrcPx) then
          begin
            SI := (SY * ASrcPx + SX) * 3;
            Inc(AccR, ASrc[SI]);
            Inc(AccG, ASrc[SI + 1]);
            Inc(AccB, ASrc[SI + 2]);
            Inc(Cnt);
          end;
        end;
      if Cnt < 1 then Cnt := 1;
      DI := ((AOY + DY) * ADstPx + (AOX + DX)) * 3;
      ADst[DI]     := AccR div Cnt;
      ADst[DI + 1] := AccG div Cnt;
      ADst[DI + 2] := AccB div Cnt;
    end;
end;

constructor TPrevTexFetcher.Create(ACache: TGeoTileCache;
  ABlockSize, AMaxBlocks: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1608);{$ENDIF}
  inherited Create;
  FCache := ACache;
  if ABlockSize < 1 then ABlockSize := GEO_BLOCK_SIZE;
  FBlockSize := ABlockSize;
  FBlockPx   := FBlockSize * (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX);
  if AMaxBlocks < 4 then AMaxBlocks := 4;
  FMaxBlocks := AMaxBlocks;
  FLock    := TCriticalSection.Create;
  FBlocks  := specialize TObjectDictionary<string, TPrevTexEntry>.Create([doOwnsValues]);
  FLoading := specialize TDictionary<string, Boolean>.Create;
  FSeq     := 0;
end;

destructor TPrevTexFetcher.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1609);{$ENDIF}
  { FCache — DI, НЕ владеем. }
  FreeAndNil(FBlocks);     { doOwnsValues -> освобождает все записи (ссылки RGB) }
  FreeAndNil(FLoading);
  FreeAndNil(FLock);
  inherited;
end;

procedure TPrevTexFetcher.EvictLocked;
var
  K, VictimKey: string;
  E, Victim: TPrevTexEntry;
  Low: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1610);{$ENDIF}
  while FBlocks.Count > FMaxBlocks do
  begin
    Victim := nil; VictimKey := ''; Low := High(Int64);
    for K in FBlocks.Keys do
    begin
      E := FBlocks[K];
      if E.Seq < Low then begin Low := E.Seq; Victim := E; VictimKey := K; end;
    end;
    if Victim = nil then Break;
    FBlocks.Remove(VictimKey);     { doOwnsValues -> освобождает ссылку RGB }
  end;
end;

function TPrevTexFetcher.BlockNW(const B: TBlockId): TGeoTileId;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1611);{$ENDIF}
  Result := TGeoTileId.Make(B.Zone, B.North,
              B.BX * Cardinal(FBlockSize), B.BY * Cardinal(FBlockSize));
end;

function TPrevTexFetcher.LoadBlockPng(const B: TBlockId; out ARGB: TBytes;
  out APx: Integer): Boolean;
var
  Path:   string;
  Img:    TFPMemoryImage;
  Reader: TFPReaderPNG;
  Stream: TFileStream;
  X, Y, Idx: Integer;
  C:      TFPColor;
  Pix:    PFPColorArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1612);{$ENDIF}
  Result := False;
  ARGB   := nil;
  APx    := 0;
  Path := FCache.BlockTexPath(BlockNW(B),FBlockSize);
  if not FileExists(Path) then Exit;

  { экземпляр — crack-класса: ниже жёсткий каст TFPMemoryImageCrack(Img),
    при objectchecks он требует runtime-тип crack (см. Osm3dHeightmap) }
  Img    := TFPMemoryImageCrack.Create(0, 0);
  Reader := TFPReaderPNG.Create;
  Stream := nil;
  try
    try
      Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
      Img.LoadFromStream(Stream, Reader);
      if (Img.Width <= 0) or (Img.Width <> Img.Height) then Exit;
      APx := Img.Width;
      SetLength(ARGB, APx * APx * 3);
      if not Img.UsePalette then
      begin
        { Прямой доступ к сырым пикселям (см. TFPMemoryImageCrack). }
        Pix := PFPColorArray(TFPMemoryImageCrack(Img).FData);
        for Y := 0 to APx - 1 do
          for X := 0 to APx - 1 do
          begin
            C := Pix^[Y * APx + X];
            Idx := (Y * APx + X) * 3;
            ARGB[Idx]     := Byte(C.Red   shr 8);
            ARGB[Idx + 1] := Byte(C.Green shr 8);
            ARGB[Idx + 2] := Byte(C.Blue  shr 8);
          end;
      end
      else
        for Y := 0 to APx - 1 do
          for X := 0 to APx - 1 do
          begin
            C := Img.Colors[X, Y];
            Idx := (Y * APx + X) * 3;
            ARGB[Idx]     := Byte(C.Red   shr 8);
            ARGB[Idx + 1] := Byte(C.Green shr 8);
            ARGB[Idx + 2] := Byte(C.Blue  shr 8);
          end;
      Result := True;
    except
      ARGB := nil; APx := 0; Result := False;
    end;
  finally
    Stream.Free;
    Reader.Free;
    Img.Free;
  end;
end;

procedure TPrevTexFetcher.StoreBlock(const AKey: string; const ARGB: TBytes;
  APx: Integer);
var E: TPrevTexEntry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1613);{$ENDIF}
  FLock.Enter;
  try
    E := TPrevTexEntry.Create;
    E.RGB := ARGB;                 { делим ссылку }
    E.Px  := APx;
    Inc(FSeq); E.Seq := FSeq;
    FBlocks.AddOrSetValue(AKey, E);
    EvictLocked;
  finally
    FLock.Leave;
  end;
end;

function TPrevTexFetcher.BlockRGB(const B: TBlockId): TBytes;
var
  Key: string;
  E:   TPrevTexEntry;
  RGB: TBytes;
  Px:  Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1614);{$ENDIF}
  Key := B.ToString;

  { Фаза 1: claim — кэш (touch+return) / стать загрузчиком / ждать загрузчика. }
  repeat
    FLock.Enter;
    try
      if FBlocks.TryGetValue(Key, E) then
      begin
        Inc(FSeq); E.Seq := FSeq;
        Exit(E.RGB);              { ссылка — refcount держит при эвикте }
      end;
      if not FLoading.ContainsKey(Key) then
      begin
        FLoading.Add(Key, True);
        Break;                    { грузим мы }
      end;
    finally
      FLock.Leave;
    end;
    Sleep(1);                     { другой поток декодит этот блок }
  until False;

  { Фаза 2: декод ВНЕ лока. }
  RGB := nil; Px := 0;
  try
    LoadBlockPng(B, RGB, Px);     { пусто, если файла нет — это валидно }
  except
    RGB := nil; Px := 0;
  end;

  { Фаза 3: публикуем (даже пустой — мемоизируем отсутствие) и снимаем слот.
    Если параллельный StoreBlock (генерация записала этот блок) успел положить
    свежую запись — используем её, не перетираем загруженной с диска. }
  FLock.Enter;
  try
    FLoading.Remove(Key);
    if FBlocks.TryGetValue(Key, E) then
      Result := E.RGB
    else
    begin
      E := TPrevTexEntry.Create;
      E.RGB := RGB;                 { пусто допустимо }
      E.Px  := Px;
      Inc(FSeq); E.Seq := FSeq;
      FBlocks.Add(Key, E);
      EvictLocked;
      Result := RGB;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TPrevTexFetcher.WriteBatch(const ABlock: TBlockId;
  const ATiles: array of TGeoTileId; const ATex: array of TTilePreviewData);
var
  Img:    TBytes;
  I, LX, LY: Integer;
  Path:   string;
  TX0, TY0: Int64;
  OutImg: TFPMemoryImage;
  Writer: TFPWriterPNG;
  Stream: TFileStream;
  X, Y, Idx: Integer;
  C:      TFPColor;
  Pix:    PFPColorArray;
  Dir:    string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1615);{$ENDIF}
  Img := nil;                               { managed; снимает hint 5091 }
  SetLength(Img, FBlockPx * FBlockPx * 3);
  FillGreen(Img);

  TX0 := Int64(ABlock.BX) * FBlockSize;     { TX/TY северо-западного тайла блока }
  TY0 := Int64(ABlock.BY) * FBlockSize;
  for I := 0 to High(ATiles) do
  begin
    if I > High(ATex) then Break;
    if (ATex[I] = nil) or (not ATex[I].HasTex)
       or (ATex[I].TexPx <> (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX)) then Continue;   { зелёная клетка }
    LX := Integer(Int64(ATiles[I].TX) - TX0);
    LY := Integer(Int64(ATiles[I].TY) - TY0);   { меньший TY = север = верх }
    if (LX < 0) or (LY < 0) or (LX >= FBlockSize) or (LY >= FBlockSize) then
      Continue;
    BlitSquare(Img, FBlockPx, LX * (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX), LY * (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX),
      ATex[I].Tex, (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX));
  end;

  { запись PNG }
  Path := FCache.BlockTexPath(BlockNW(ABlock),FBlockSize);
  Dir  := ExtractFilePath(Path);
  if (Dir <> '') and (not DirectoryExists(Dir)) then
    ForceDirectories(Dir);

  { crack-класс как runtime-тип — под жёсткий каст ниже (см. выше) }
  OutImg := TFPMemoryImageCrack.Create(FBlockPx, FBlockPx);
  Writer := TFPWriterPNG.Create;
  Stream := nil;
  try
    Writer.UseAlpha := False;
    { Прямая запись в сырые пиксели (см. TFPMemoryImageCrack) — свежий
      OutImg гарантированно не палитровый. }
    Pix := PFPColorArray(TFPMemoryImageCrack(OutImg).FData);
    for Y := 0 to FBlockPx - 1 do
      for X := 0 to FBlockPx - 1 do
      begin
        Idx := (Y * FBlockPx + X) * 3;
        C.Red   := Img[Idx]     * 257;   { 8 -> 16 бит: B*257 = B*256+B, [0..255]->[0..65535] }
        C.Green := Img[Idx + 1] * 257;
        C.Blue  := Img[Idx + 2] * 257;
        C.Alpha := $FFFF;
        Pix^[Y * FBlockPx + X] := C;
      end;
    Stream := TFileStream.Create(Path, fmCreate);
    OutImg.SaveToStream(Stream, Writer);
  finally
    Stream.Free;
    Writer.Free;
    OutImg.Free;
  end;

  { свежий блок -> в кэш (без повторного чтения) }
  StoreBlock(ABlock.ToString, Img, FBlockPx);
end;

function TPrevTexFetcher.GetTileTexture(const ATile: TGeoTileId): TBytes;
var
  B:   TBlockId;
  Blk: TBytes;
  LX, LY, X, Y, S, D, BPx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1616);{$ENDIF}
  Result := nil;
  B   := BlockOf(ATile, FBlockSize);
  Blk := BlockRGB(B);
  if Length(Blk) = 0 then Exit;                 { блока нет }
  BPx := FBlockSize * (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX);
  if Length(Blk) <> BPx * BPx * 3 then Exit;     { неожиданный размер — пас }

  LX := Integer(Int64(ATile.TX) - Int64(B.BX) * FBlockSize);
  LY := Integer(Int64(ATile.TY) - Int64(B.BY) * FBlockSize);
  if (LX < 0) or (LY < 0) or (LX >= FBlockSize) or (LY >= FBlockSize) then Exit;

  SetLength(Result, (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX) * (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX) * 3);
  for Y := 0 to (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX) - 1 do
    for X := 0 to (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX) - 1 do
    begin
      S := (((LY * (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX)) + Y) * BPx + (LX * (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX)) + X) * 3;
      D := (Y * (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX) + X) * 3;
      Result[D]     := Blk[S];
      Result[D + 1] := Blk[S + 1];
      Result[D + 2] := Blk[S + 2];
    end;
end;

function TPrevTexFetcher.GetSuperTexture(const ANW: TGeoTileId;
  ASpan, AOutPx: Integer): TBytes;
var
  BlocksSide, RegionPx, BX, BY: Integer;
  B0, B: TBlockId;
  Blk: TBytes;
  BPx, I, N: Integer;
  AllGreen: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1617);{$ENDIF}
  Result := nil;
  if (ASpan < 1) or (AOutPx < 1) then Exit;

  BlocksSide := ASpan div FBlockSize;            { суперы блок-выровнены }
  if BlocksSide < 1 then BlocksSide := 1;
  RegionPx := AOutPx div BlocksSide;
  if RegionPx < 1 then RegionPx := 1;
  BPx := FBlockSize * (GEO_TILE_EDGE_PX * PREVIEW_TEX_PER_HPX);

  SetLength(Result, AOutPx * AOutPx * 3);
  FillGreen(Result);                             { отсутствующие блоки = зелёные }

  B0 := BlockOf(ANW, FBlockSize);
  for BY := 0 to BlocksSide - 1 do
    for BX := 0 to BlocksSide - 1 do
    begin
      B := TBlockId.Make(B0.Zone, B0.North,
             B0.BX + Cardinal(BX), B0.BY + Cardinal(BY));
      Blk := BlockRGB(B);
      if Length(Blk) <> BPx * BPx * 3 then Continue;   { нет блока -> зелёный }
      { BY=0 = север = верх (как при записи): доля в выходе по той же сетке }
      DownscaleInto(Result, AOutPx, BX * RegionPx, BY * RegionPx, RegionPx,
        Blk, BPx);
    end;

  { Супер без реальной имажери = ВСЕ пиксели = PREVIEW_NODATA_RGB (блока нет
    ИЛИ блок залит «нет данных»). Это не текстура, а салатовая заглушка —
    отдаём пусто: у caller'а супер выходит БЕЗ текстуры (HasTex=False) и его
    сцена вообще не создаётся (НЕ перекрашивается). Зону держит дальний
    клипмап, файтинг исчезает. Первый же не-зелёный пиксель = есть имажери
    -> текстуру оставляем. Скан идёт на воркере при сборке супера, не в кадре. }
  AllGreen := True;
  N := Length(Result) div 3;
  for I := 0 to N - 1 do
    if (Result[I * 3]     <> PREVIEW_NODATA_RGB[0]) or
       (Result[I * 3 + 1] <> PREVIEW_NODATA_RGB[1]) or
       (Result[I * 3 + 2] <> PREVIEW_NODATA_RGB[2]) then
    begin
      AllGreen := False;
      Break;
    end;
  if AllGreen then SetLength(Result, 0);
end;

end.
