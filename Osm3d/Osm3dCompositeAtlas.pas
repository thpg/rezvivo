unit Osm3dCompositeAtlas;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  CastleImages,
  CastleVectors,
  CastleRenderOptions,
  X3DNodes,
  X3DFields,
  Osm3dGeoMath,  { TLogProc }
  Osm3dImageCodecLock   { EnterImageCodec/Leave — Vampyre не потокобезопасен }
  {$IFDEF TEX_SIZE_PROFILE}, Osm3dTexProfile{$ENDIF}
;

const
  { Atlas cell gutter, px per side. Must match u_*_cell_inset = G/TilePixels in the
    composite shaders. Raise if seams appear at mid distance (costs texture resolution). }
  ATLAS_CELL_GUTTER = 8;

  { Disk-cache format version; bump on any packing/channel change to invalidate old .manifest. }
  ATLAS_CACHE_VERSION = 1;

{ Всеядный промоут в RGBA: попиксельная конвертация через Colors[] —
  переваривает ЛЮБОЙ TCastleImage, включая 16-битные grayscale PNG
  (TGrayscaleFloatImage: Roughness / Height / AO из PBR-наборов), которые
  быстрый Assign отвергает с EImageAssignmentError. Медленнее Assign —
  использовать как фолбэк для неподдерживаемых им классов (так делают и
  AtlasLoadPngForTile здесь, и TGroundAtlas.LoadSetRGBA). }
function AtlasCopyViaColors(ASource: TCastleImage): TRGBAlphaImage;

type
  { Atlas is GridCols*TilePixels x GridRows*TilePixels; material N -> cell
    (N mod GridCols, N div GridCols). GridCols/GridRows go to the shader as uniforms. }
  TAtlasLayout = record
    GridCols:   Integer;
    GridRows:   Integer;
    TilePixels: Integer;
  end;

  { Channel set per atlas: ground/fence = diffuse+normal+mask, building = all four. }
  TAtlasChannel  = (acDiffuse, acNormal, acMask, acGlow);
  TAtlasChannels = set of TAtlasChannel;

  { Normalised per-material description the shared Build*Image use; subclasses
    map their own descriptor into it via MaterialInfo. }
  TAtlasMaterialInfo = record
    Name:          string;
    DiffusePath:   string;
    NormalPath:    string;
    MaskPath:      string;
    FallbackColor: TVector3;
    Roughness:     Single;
  end;

  { Channel build pass (one Build*Image), for parallel runs. }
  TAtlasBuildPass = procedure(LogProc: TLogProc) of object;

  TCompositeAtlasBase = class
  private
    FLayout:   TAtlasLayout;
    FChannels: TAtlasChannels;
    FImages:   array[TAtlasChannel] of TRGBAlphaImage;
    FUrls:     array[TAtlasChannel] of string;
    FBuildFailed: Boolean;

    { Average-colour cache so CellAverageRGB/ImageAverageRGB still answer after the
      atlas images are freed (URL/cache mode). Filled by WriteManifest or ReadManifestAndValidate. }
    FCacheCellR, FCacheCellG, FCacheCellB: array of Byte;
    FCacheCellValid: array of Boolean;
    FCacheImgR, FCacheImgG, FCacheImgB: Byte;
    FCacheImgValid: Boolean;
    FAvgCached: Boolean;

    function GetDiffuseUrl: string;
    function GetNormalUrl:  string;
    function GetMaskUrl:    string;
    function GetGlowUrl:    string;
    function GetDiffuseImage: TRGBAlphaImage;
    procedure ClearUrls;
  protected
    { Log / assert prefix, e.g. 'GroundAtlas'. }
    function LogPrefix: string; virtual; abstract;

    { Channel PNG filename in the cache dir. Keep stable — existing disk caches depend on it. }
    function CacheFileName(Ch: TAtlasChannel): string; virtual; abstract;

    { Material count + normalised info, used by the shared Build*Image. Simple
      cell=material atlases (building/fence) override these; atlases with custom
      build logic (ground) override Build* instead and leave these empty. }
    function MaterialCount: Integer; virtual;
    function MaterialInfo(MatId: Integer): TAtlasMaterialInfo; virtual;

    { Ширина gutter-кольца; по умолчанию ATLAS_CELL_GUTTER. }
    function CellGutter: Integer; virtual;

    { Subclass access to a channel image (e.g. ground post-processing).
      nil before the channel is built or after ownership passes to a node / SaveToCache. }
    function ChannelImage(Ch: TAtlasChannel): TRGBAlphaImage;

    { Lazily allocate a channel (diffuse is allocated eagerly in Create). }
    procedure EnsureChannelImage(Ch: TAtlasChannel);

    function CellRectX(MatId: Integer): Integer;
    function CellRectY(MatId: Integer): Integer;

    { Fingerprint of everything that defines the baked atlas (layout + materials/paths);
      a mismatch means the disk cache is stale. Ground overrides it. }
    function BuildSignature: string; virtual;
    function ManifestPath(const ACacheDir: string): string;
    procedure WriteManifest(const ACacheDir: string);
    function ReadManifestAndValidate(const ACacheDir: string): Boolean;

    { Run the channel build passes in parallel (one thread each; logs buffered per
      thread and replayed in order after join). Channels are independent. }
    procedure RunBuildPasses(const Passes: array of TAtlasBuildPass;
      LogProc: TLogProc);
  public
    { Average colour of a cell / the whole diffuse (only A>=128 pixels counted).
      False if the diffuse image was already freed. }
    function CellAverageRGB(MatId: Integer; out R, G, B: Byte): Boolean;
    function ImageAverageRGB(out R, G, B: Byte): Boolean;
  protected

    { Shared atlas texture properties: clamp + mipmaps + anisotropic 16. Fresh node each call. }
    function MakeAtlasTexProps: TTexturePropertiesNode;

    { Solid-fill a channel cell with C. No-op if the channel image is not built. }
    procedure FillCellSolid(Ch: TAtlasChannel; MatId: Integer;
      const C: TVector4Byte);

    { Load TexturePath, resize to the cell INTERIOR (TilePixels - 2*Gutter), blit into
      cell MatId of channel Ch, and fill the gutter ring with a wrapped self-copy.
      dmOverwrite preserves source alpha. False if the file is missing/unreadable. }
    function FillCellFromPNG(Ch: TAtlasChannel; MatId: Integer;
      const TexturePath: string): Boolean;

    { Like FillCellFromPNG but from an in-memory image (lets callers pre-combine channels).
      ASrc is resized to the cell interior if needed and is NOT freed. False if Ch or ASrc nil. }
    function FillCellFromImage(Ch: TAtlasChannel; MatId: Integer;
      ASrc: TCastleImage): Boolean;

    { Like FillCellFromPNG but alpha-BLENDS over the existing interior (gutter untouched).
      Used to feather a transparent overlay (sand/dirt road) onto an opaque base (grass). }
    function BlendCellInteriorFromPNG(Ch: TAtlasChannel; MatId: Integer;
      const TexturePath: string): Boolean;

    { One-shot pixel node for a channel; image ownership moves to the node (field -> nil). }
    function CreateChannelTextureNode(Ch: TAtlasChannel): TPixelTextureNode;

    { URL node for a channel (needs a successful SaveToCache). Fresh node each call;
      CGE loads the GPU texture once per URL and ref-counts it. }
    function CreateChannelTextureNodeUrl(Ch: TAtlasChannel): TImageTextureNode;
  public
    function CreateTextureNode: TPixelTextureNode;
    function CreateNormalTextureNode: TPixelTextureNode;
    function CreateMaskTextureNode: TPixelTextureNode;
    function CreateGlowTextureNode: TPixelTextureNode;
    function CreateTextureNodeUrl: TImageTextureNode;
    function CreateNormalTextureNodeUrl: TImageTextureNode;
    function CreateMaskTextureNodeUrl: TImageTextureNode;
    function CreateGlowTextureNodeUrl: TImageTextureNode;

    constructor Create(const ALayout: TAtlasLayout;
      const AChannels: TAtlasChannels);
    destructor Destroy; override;

    { Shared channel builders over MaterialCount + MaterialInfo. Diffuse is allocated
      eagerly in Create; normal/mask lazily. }
    procedure BuildImage(LogProc: TLogProc = nil); virtual;
    procedure BuildNormalImage(LogProc: TLogProc = nil); virtual;
    procedure BuildMaskImage(LogProc: TLogProc = nil); virtual;

    { Build all channels in parallel. Base = diffuse/normal/mask; subclasses with extra
      channels (building: +glow) override. }
    procedure BuildChannelsParallel(LogProc: TLogProc = nil); virtual;

    { Write all built channels to PNGs in ACacheDir, record their file:// URLs and
      FREE the in-memory images (disk is now source of truth). On success the URL path is
      enabled. On failure all URLs stay empty (no partial state) and the images are kept,
      so the one-shot pixel-node path still works. }
    function SaveToCache(const ACacheDir: string;
      LogProc: TLogProc = nil): Boolean; virtual;

    { If ACacheDir holds a valid cache (manifest version+signature match, all PNGs present),
      point channel URLs at them and load the average-colour cache without rebuilding.
      True = cache used (images are freed, render goes via URL). }
    function TryLoadFromCache(const ACacheDir: string;
      LogProc: TLogProc = nil): Boolean; virtual;

    property Layout:   TAtlasLayout   read FLayout;
    property Channels: TAtlasChannels read FChannels;

    { Empty until a successful SaveToCache; the URL is the GPU texture-cache key. }
    property DiffuseUrl: string read GetDiffuseUrl;
    property NormalUrl:  string read GetNormalUrl;
    property MaskUrl:    string read GetMaskUrl;
    property GlowUrl:    string read GetGlowUrl;

    { Diffuse image; nil after ownership passes to a node or after SaveToCache. }
    property Image: TRGBAlphaImage read GetDiffuseImage;
  end;

{ Atlas cell PNG loader. Loads without AllowedImageClasses (CGE's FixImageClass dies on
  16-bit/float PNG), promotes to TRGBAlphaImage (fast Assign where possible, slow per-pixel
  for 16-bit PNG that Assign rejects), and resizes to TilePixels. Source alpha kept.
  nil if missing or load failed. }
function AtlasLoadPngForTile(const TexturePath: string;
  TilePixels: Integer): TCastleImage;

implementation

uses
  CastleURIUtils;

type
  { Encodes one channel to PNG on its own thread (pure CPU+IO, no OpenGL). }
  TAtlasSaveWorker = class(TThread)
  private
    FImg:  TRGBAlphaImage;
    FPath: string;
    FOk:   Boolean;
    FErr:  string;
  protected
    procedure Execute; override;
  public
    constructor Create(AImg: TRGBAlphaImage; const APath: string);
    property Ok:  Boolean read FOk;
    property Err: string  read FErr;
  end;

  { One channel build pass on its own thread; log buffered per thread and replayed
    after join (deterministic order). }
  TAtlasBuildWorker = class(TThread)
  private
    FPass: TAtlasBuildPass;
    FBuf:  TStringList;
    FOk:   Boolean;
    FErr:  string;
    procedure BufferLine(const Msg: string);
  protected
    procedure Execute; override;
  public
    constructor Create(APass: TAtlasBuildPass);
    destructor Destroy; override;
    property Buf: TStringList read FBuf;
    property Ok:  Boolean     read FOk;
    property Err: string      read FErr;
  end;

constructor TAtlasSaveWorker.Create(AImg: TRGBAlphaImage; const APath: string);
begin
  inherited Create(True);
  FImg := AImg; FPath := APath; FOk := False;
  FreeOnTerminate := False;
  Start;
end;

procedure TAtlasSaveWorker.Execute;
begin
  try
    { Vampyre не потокобезопасен, а SaveToCache пускает save-воркеры по
      каналам параллельно — кодирование под общим замком. }
    EnterImageCodec;
    try
      SaveImage(FImg, FPath);
    finally
      LeaveImageCodec;
    end;
    FOk := True;
  except
    on E: Exception do begin FOk := False; FErr := E.Message; end;
  end;
end;

constructor TAtlasBuildWorker.Create(APass: TAtlasBuildPass);
begin
  inherited Create(True);
  FPass := APass; FBuf := TStringList.Create; FOk := False;
  FreeOnTerminate := False;
  Start;
end;

destructor TAtlasBuildWorker.Destroy;
begin
  inherited Destroy;
  FBuf.Free;
end;

procedure TAtlasBuildWorker.BufferLine(const Msg: string);
begin
  FBuf.Add(Msg);            { только этот поток пишет в свой буфер }
end;

procedure TAtlasBuildWorker.Execute;
var lp: TLogProc;
begin
  lp := @BufferLine;        { метод-указатель, привязанный к Self }
  try
    FPass(lp);
    FOk := True;
  except
    on E: Exception do begin FOk := False; FErr := E.Message; end;
  end;
end;

{ Per-pixel promote to RGBAlpha; handles any TCastleImage incl. 16-bit PNG that Assign rejects.
  Raw row access where the source class is known (RGBAlpha — straight copy, RGB — opaque
  expand); the generic fallback still READS via virtual Colors[] (no raw layout to rely on)
  but WRITES through PixelPtr rows. }
function AtlasCopyViaColors(ASource: TCastleImage): TRGBAlphaImage;
var
  PX, PY: Integer;
  DstRow:  PVector4ByteArray;
  SrcARow: PVector4ByteArray;
  SrcRRow: PVector3ByteArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1360);{$ENDIF}
  Result := TRGBAlphaImage.Create(ASource.Width, ASource.Height);
  try
    if ASource is TRGBAlphaImage then
      for PY := 0 to Integer(ASource.Height) - 1 do
      begin
        DstRow  := Result.RowPtr(PY);
        SrcARow := TRGBAlphaImage(ASource).RowPtr(PY);
        Move(SrcARow^[0], DstRow^[0], Integer(ASource.Width) * SizeOf(TVector4Byte));
      end
    else if ASource is TRGBImage then
      for PY := 0 to Integer(ASource.Height) - 1 do
      begin
        DstRow  := Result.RowPtr(PY);
        SrcRRow := TRGBImage(ASource).RowPtr(PY);
        for PX := 0 to Integer(ASource.Width) - 1 do
          DstRow^[PX] := Vector4Byte(SrcRRow^[PX].X, SrcRRow^[PX].Y,
                                     SrcRRow^[PX].Z, 255);
      end
    else
      for PY := 0 to Integer(ASource.Height) - 1 do
      begin
        DstRow := Result.RowPtr(PY);
        for PX := 0 to Integer(ASource.Width) - 1 do
          DstRow^[PX] := Vector4Byte(ASource.Colors[PX, PY, 0]);
      end;
  except
    Result.Free;
    raise;
  end;
end;

function AtlasLoadPngForTile(const TexturePath: string;
  TilePixels: Integer): TCastleImage;
var
  Src, Resized: TCastleImage;
  Promoted: TRGBAlphaImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1361);{$ENDIF}
  Result := nil;
  if (TexturePath = '') or (not FileExists(TexturePath)) then Exit;
  Src := nil;
  try
    { Декод под общим замком: BuildChannelsParallel гонит три декодера
      одновременно, а Vampyre весь на процессных синглтонах — оба
      пойманных стека (EStringListError в TMetadata.ClearMetaList и
      порча кучи с детонацией в SysGetMem) падали именно на этом вызове.
      См. Osm3dImageCodecLock. }
    EnterImageCodec;
    try
      Src := LoadImage(TexturePath);
    finally
      LeaveImageCodec;
    end;
  except
    Src := nil;
    Exit;
  end;
  try
    if not (Src is TRGBAlphaImage) then
    begin
      if (Src is TRGBImage) or
         (Src is TGrayscaleImage) or
         (Src is TGrayscaleAlphaImage) or
         (Src is TRGBFloatImage) then
      begin
        Promoted := TRGBAlphaImage.Create(Src.Width, Src.Height);
        try
          Promoted.Assign(Src);
        except
          Promoted.Free;
          raise;
        end;
      end
      else
        Promoted := AtlasCopyViaColors(Src);

      Src.Free;
      Src := Promoted;
    end;
    if (Src.Width  <> Cardinal(TilePixels)) or
       (Src.Height <> Cardinal(TilePixels)) then
    begin
      Resized := Src.MakeResized(TilePixels, TilePixels, riBilinear);
      Src.Free;
      Src := Resized;
    end;
    Result := Src;
  except
    Src.Free;
    raise;
  end;
end;

constructor TCompositeAtlasBase.Create(const ALayout: TAtlasLayout;
  const AChannels: TAtlasChannels);
var
  Ch: TAtlasChannel;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1362);{$ENDIF}
  inherited Create;
  FLayout   := ALayout;
  FChannels := AChannels + [acDiffuse];   { diffuse есть всегда }
  for Ch := Low(TAtlasChannel) to High(TAtlasChannel) do
  begin
    FImages[Ch] := nil;
    FUrls[Ch]   := '';
  end;
  { Diffuse allocated eagerly; other channels lazily in the subclass Build*Image. }
  FImages[acDiffuse] := TRGBAlphaImage.Create(
    ALayout.GridCols * ALayout.TilePixels,
    ALayout.GridRows * ALayout.TilePixels);
end;

destructor TCompositeAtlasBase.Destroy;
var
  Ch: TAtlasChannel;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1363);{$ENDIF}
  for Ch := Low(TAtlasChannel) to High(TAtlasChannel) do
    if FImages[Ch] <> nil then FImages[Ch].Free;
  inherited Destroy;
end;

function TCompositeAtlasBase.GetDiffuseUrl: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1364);{$ENDIF}
  Result := FUrls[acDiffuse];
end;

function TCompositeAtlasBase.GetNormalUrl: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1365);{$ENDIF}
  Result := FUrls[acNormal];
end;

function TCompositeAtlasBase.GetMaskUrl: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1366);{$ENDIF}
  Result := FUrls[acMask];
end;

function TCompositeAtlasBase.GetGlowUrl: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1367);{$ENDIF}
  Result := FUrls[acGlow];
end;

function TCompositeAtlasBase.GetDiffuseImage: TRGBAlphaImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1368);{$ENDIF}
  Result := FImages[acDiffuse];
end;

procedure TCompositeAtlasBase.ClearUrls;
var
  Ch: TAtlasChannel;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1369);{$ENDIF}
  for Ch := Low(TAtlasChannel) to High(TAtlasChannel) do
    FUrls[Ch] := '';
end;

function TCompositeAtlasBase.CellGutter: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1370);{$ENDIF}
  Result := ATLAS_CELL_GUTTER;
end;

function TCompositeAtlasBase.MaterialCount: Integer;
begin
  Result := 0;
end;

function TCompositeAtlasBase.MaterialInfo(MatId: Integer): TAtlasMaterialInfo;
begin
  Result.Name          := '';
  Result.DiffusePath   := '';
  Result.NormalPath    := '';
  Result.MaskPath      := '';
  Result.FallbackColor := TVector3.Zero;
  Result.Roughness     := 0;
end;

procedure TCompositeAtlasBase.BuildImage(LogProc: TLogProc);
var
  I, Loaded: Integer;
  D: TAtlasMaterialInfo;
  C: TVector4Byte;
  Img: TRGBAlphaImage;
begin
  Loaded := 0;
  for I := 0 to MaterialCount - 1 do
  begin
    D := MaterialInfo(I);
    C.X := Round(D.FallbackColor.X * 255);
    C.Y := Round(D.FallbackColor.Y * 255);
    C.Z := Round(D.FallbackColor.Z * 255);
    C.W := 255;
    FillCellSolid(acDiffuse, I, C);
    if FillCellFromPNG(acDiffuse, I, D.DiffusePath) then
      Inc(Loaded)
    else if Assigned(LogProc) then
      LogProc(Format('  %s: missing %s (mat %d "%s") -> fallback colour',
        [LogPrefix, D.DiffusePath, I, D.Name]));
  end;
  Img := ChannelImage(acDiffuse);
  if Assigned(LogProc) and (Img <> nil) then
    LogProc(Format('  %s: diffuse %dx%d (%d PNG loaded)',
      [LogPrefix, Img.Width, Img.Height, Loaded]));
end;

procedure TCompositeAtlasBase.BuildNormalImage(LogProc: TLogProc);
var
  I: Integer;
  D: TAtlasMaterialInfo;
  C: TVector4Byte;
  Img: TRGBAlphaImage;
begin
  EnsureChannelImage(acNormal);
  { neutral tangent-space normal (0,0,1) }
  C.X := 128; C.Y := 128; C.Z := 255; C.W := 255;
  for I := 0 to MaterialCount - 1 do
  begin
    D := MaterialInfo(I);
    FillCellSolid(acNormal, I, C);
    FillCellFromPNG(acNormal, I, D.NormalPath);
  end;
  Img := ChannelImage(acNormal);
  if Assigned(LogProc) and (Img <> nil) then
    LogProc(Format('  %s: normal %dx%d', [LogPrefix, Img.Width, Img.Height]));
end;

procedure TCompositeAtlasBase.BuildMaskImage(LogProc: TLogProc);
var
  I: Integer;
  D: TAtlasMaterialInfo;
  C: TVector4Byte;
  Img: TRGBAlphaImage;
begin
  EnsureChannelImage(acMask);
  for I := 0 to MaterialCount - 1 do
  begin
    D := MaterialInfo(I);
    { maskless cell: solid R = constant roughness (the FS reads .r). }
    C.X := Round(D.Roughness * 255);
    C.Y := 0; C.Z := 0; C.W := 255;
    FillCellSolid(acMask, I, C);
    { When a mask PNG exists, its R channel overrides as per-texel roughness. }
    FillCellFromPNG(acMask, I, D.MaskPath);
  end;
  Img := ChannelImage(acMask);
  if Assigned(LogProc) and (Img <> nil) then
    LogProc(Format('  %s: mask %dx%d', [LogPrefix, Img.Width, Img.Height]));
end;

function TCompositeAtlasBase.ChannelImage(Ch: TAtlasChannel): TRGBAlphaImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1371);{$ENDIF}
  Result := FImages[Ch];
end;

procedure TCompositeAtlasBase.EnsureChannelImage(Ch: TAtlasChannel);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1372);{$ENDIF}
  if FImages[Ch] = nil then
    FImages[Ch] := TRGBAlphaImage.Create(
      FLayout.GridCols * FLayout.TilePixels,
      FLayout.GridRows * FLayout.TilePixels);
end;

function TCompositeAtlasBase.CellRectX(MatId: Integer): Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1373);{$ENDIF}
  Result := (MatId mod FLayout.GridCols) * FLayout.TilePixels;
end;

function TCompositeAtlasBase.CellRectY(MatId: Integer): Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1374);{$ENDIF}
  Result := (MatId div FLayout.GridCols) * FLayout.TilePixels;
end;

function AverageRectRGB(Img: TRGBAlphaImage; X0, Y0, W, H: Integer;
  out R, G, B: Byte): Boolean;
var
  X, Y, N: Integer;
  SR, SG, SB: Int64;
  P: PByte;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1375);{$ENDIF}
  Result := False;
  if Img = nil then Exit;
  if X0 < 0 then X0 := 0;
  if Y0 < 0 then Y0 := 0;
  if X0 + W > Img.Width  then W := Img.Width  - X0;
  if Y0 + H > Img.Height then H := Img.Height - Y0;
  if (W <= 0) or (H <= 0) then Exit;
  SR := 0; SG := 0; SB := 0; N := 0;
  for Y := Y0 to Y0 + H - 1 do
  begin
    P := PByte(Img.RawPixels) + (Y * Img.Width + X0) * 4;
    for X := 0 to W - 1 do
    begin
      if P[3] >= 128 then
      begin
        Inc(SR, P[0]); Inc(SG, P[1]); Inc(SB, P[2]);
        Inc(N);
      end;
      Inc(P, 4);
    end;
  end;
  if N = 0 then Exit;
  R := SR div N; G := SG div N; B := SB div N;
  Result := True;
end;

function TCompositeAtlasBase.CellAverageRGB(MatId: Integer;
  out R, G, B: Byte): Boolean;
var Gt: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1376);{$ENDIF}
  R := 0; G := 0; B := 0;
  if FImages[acDiffuse] = nil then
  begin
    { картинка освобождена (URL/кэш-режим) — отвечаем из кэша средних }
    if FAvgCached and (MatId >= 0) and (MatId < Length(FCacheCellValid)) then
    begin
      Result := FCacheCellValid[MatId];
      if Result then
      begin R := FCacheCellR[MatId]; G := FCacheCellG[MatId]; B := FCacheCellB[MatId]; end;
    end
    else
      Result := False;
    Exit;
  end;
  Gt := CellGutter;
  Result := AverageRectRGB(FImages[acDiffuse],
    CellRectX(MatId) + Gt, CellRectY(MatId) + Gt,
    FLayout.TilePixels - 2 * Gt, FLayout.TilePixels - 2 * Gt, R, G, B);
end;

function TCompositeAtlasBase.ImageAverageRGB(out R, G, B: Byte): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1377);{$ENDIF}
  R := 0; G := 0; B := 0;
  if FImages[acDiffuse] <> nil then
    Result := AverageRectRGB(FImages[acDiffuse], 0, 0,
      FImages[acDiffuse].Width, FImages[acDiffuse].Height, R, G, B)
  else
  begin
    Result := FAvgCached and FCacheImgValid;
    if Result then begin R := FCacheImgR; G := FCacheImgG; B := FCacheImgB; end;
  end;
end;

function TCompositeAtlasBase.MakeAtlasTexProps: TTexturePropertiesNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1378);{$ENDIF}
  { Mipmaps + aniso 16: composite shaders use textureGrad with pre-fract derivatives,
    so the GPU picks LOD by screen density; aniso kills shimmer on roads at grazing angles. }
  Result := TTexturePropertiesNode.Create;
  Result.MinificationFilter  := minLinearMipmapLinear;
  Result.MagnificationFilter := magLinear;
  Result.AnisotropicDegree   := 16.0;
end;

procedure TCompositeAtlasBase.FillCellSolid(Ch: TAtlasChannel;
  MatId: Integer; const C: TVector4Byte);
var
  Target: TRGBAlphaImage;
  X0, Y0, Px, Py: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1379);{$ENDIF}
  Target := FImages[Ch];
  if Target = nil then Exit;
  X0 := CellRectX(MatId);
  Y0 := CellRectY(MatId);
  for Py := 0 to FLayout.TilePixels - 1 do
    for Px := 0 to FLayout.TilePixels - 1 do
      Target.PixelPtr(X0 + Px, Y0 + Py)^ := C;
end;

function TCompositeAtlasBase.FillCellFromPNG(Ch: TAtlasChannel;
  MatId: Integer; const TexturePath: string): Boolean;
var
  Target: TRGBAlphaImage;
  Src: TCastleImage;
  X0, Y0, TP, G, S, px, py, sx, sy: Integer;

  { One gutter pixel: virtual coord (px-G, py-G) wrapped into [0,S) and sampled from Src.
    Src is always TRGBAlphaImage here (AtlasLoadPngForTile promotes), so sample raw. }
  procedure WrapPx(APx, APy: Integer);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1380);{$ENDIF}
    sx := ((APx - G) mod S + S) mod S;
    sy := ((APy - G) mod S + S) mod S;
    Target.PixelPtr(X0 + APx, Y0 + APy)^ :=
      TRGBAlphaImage(Src).PixelPtr(sx, sy)^;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1381);{$ENDIF}
  Result := False;
  Target := FImages[Ch];
  if Target = nil then Exit;
  TP := FLayout.TilePixels;
  G  := CellGutter;
  S  := TP - 2 * G;
  if S < 1 then S := 1;

  { Загрузка с ресайзом под размер ИНТЕРЬЕРА S, не всей ячейки. }
  Src := AtlasLoadPngForTile(TexturePath, S);
  if Src = nil then Exit;
  try
    X0 := CellRectX(MatId);
    Y0 := CellRectY(MatId);

    { Interior: native blit from the inset origin; dmOverwrite keeps source alpha. }
    Target.DrawFrom(Src, X0 + G, Y0 + G, dmOverwrite);

    { Gutter ring (width G): wrapped self-copy so mip averaging at the interior edge
      stays tile-correct. Only the thin ring is touched per-pixel. }
    for py := 0 to G - 1 do
      for px := 0 to TP - 1 do WrapPx(px, py);                 { top }
    for py := TP - G to TP - 1 do
      for px := 0 to TP - 1 do WrapPx(px, py);                 { bottom }
    for py := G to TP - G - 1 do
    begin
      for px := 0 to G - 1 do WrapPx(px, py);                  { left }
      for px := TP - G to TP - 1 do WrapPx(px, py);            { right }
    end;

    Result := True;
  finally
    Src.Free;
  end;
end;

function TCompositeAtlasBase.FillCellFromImage(Ch: TAtlasChannel;
  MatId: Integer; ASrc: TCastleImage): Boolean;
var
  Target: TRGBAlphaImage;
  Src:    TCastleImage;
  OwnSrc: Boolean;
  X0, Y0, TP, G, S, px, py, sx, sy: Integer;

  procedure WrapPx(APx, APy: Integer);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1381);{$ENDIF}
    sx := ((APx - G) mod S + S) mod S;
    sy := ((APy - G) mod S + S) mod S;
    if Src is TRGBAlphaImage then
      Target.PixelPtr(X0 + APx, Y0 + APy)^ :=
        TRGBAlphaImage(Src).PixelPtr(sx, sy)^
    else
      Target.Colors[X0 + APx, Y0 + APy, 0] := Src.Colors[sx, sy, 0];
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1381);{$ENDIF}
  Result := False;
  Target := FImages[Ch];
  if (Target = nil) or (ASrc = nil) then Exit;
  TP := FLayout.TilePixels;
  G  := CellGutter;
  S  := TP - 2 * G;
  if S < 1 then S := 1;

  { Resize to interior S only if the caller did not already size it. }
  OwnSrc := False;
  Src := ASrc;
  if (Src.Width <> Cardinal(S)) or (Src.Height <> Cardinal(S)) then
  begin
    Src := ASrc.MakeResized(S, S, riBilinear);
    OwnSrc := True;
  end;
  try
    X0 := CellRectX(MatId);
    Y0 := CellRectY(MatId);

    { Interior blit (dmOverwrite keeps packed alpha/blue) + wrapped gutter ring, as FillCellFromPNG. }
    Target.DrawFrom(Src, X0 + G, Y0 + G, dmOverwrite);

    for py := 0 to G - 1 do
      for px := 0 to TP - 1 do WrapPx(px, py);
    for py := TP - G to TP - 1 do
      for px := 0 to TP - 1 do WrapPx(px, py);
    for py := G to TP - G - 1 do
    begin
      for px := 0 to G - 1 do WrapPx(px, py);
      for px := TP - G to TP - 1 do WrapPx(px, py);
    end;

    Result := True;
  finally
    if OwnSrc then Src.Free;
  end;
end;

function TCompositeAtlasBase.BlendCellInteriorFromPNG(Ch: TAtlasChannel;
  MatId: Integer; const TexturePath: string): Boolean;
var
  Target: TRGBAlphaImage;
  Src:    TCastleImage;
  X0, Y0, TP, G, S: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1381);{$ENDIF}
  Result := False;
  Target := FImages[Ch];
  if Target = nil then Exit;
  TP := FLayout.TilePixels;
  G  := CellGutter;
  S  := TP - 2 * G;
  if S < 1 then S := 1;

  Src := AtlasLoadPngForTile(TexturePath, S);
  if Src = nil then Exit;
  try
    X0 := CellRectX(MatId);
    Y0 := CellRectY(MatId);
    { Alpha-over the existing interior; gutter ring is left as the base laid it. }
    Target.DrawFrom(Src, X0 + G, Y0 + G, dmBlend);
    Result := True;
  finally
    Src.Free;
  end;
end;

function TCompositeAtlasBase.CreateChannelTextureNode(
  Ch: TAtlasChannel): TPixelTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1382);{$ENDIF}
  Assert(FImages[Ch] <> nil,
    LogPrefix + '.CreateChannelTextureNode: channel image not built (Build*Image not called)');
  Result := TPixelTextureNode.Create;
  Result.FdImage.Value := FImages[Ch];
  {$IFDEF TEX_SIZE_PROFILE}ProfileTexNode(Result, 'atlas');{$ENDIF}
  FImages[Ch] := nil;   { владение перешло ноде }

  { RepeatS/T = False: wrapping at the atlas edge would bleed neighbouring materials in. }
  Result.RepeatS := False;
  Result.RepeatT := False;
  Result.TextureProperties := MakeAtlasTexProps;
end;

function TCompositeAtlasBase.CreateChannelTextureNodeUrl(
  Ch: TAtlasChannel): TImageTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1383);{$ENDIF}
  Assert(FUrls[Ch] <> '',
    LogPrefix + '.CreateChannelTextureNodeUrl: SaveToCache not called or failed');
  Result := TImageTextureNode.Create;
  Result.SetUrl([FUrls[Ch]]);
  {$IFDEF TEX_SIZE_PROFILE}ProfileTexNode(Result, 'atlas');{$ENDIF}
  Result.RepeatS := False;
  Result.RepeatT := False;
  Result.TextureProperties := MakeAtlasTexProps;
end;

function TCompositeAtlasBase.CreateTextureNode: TPixelTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1384);{$ENDIF}
  Result := CreateChannelTextureNode(acDiffuse);
end;

function TCompositeAtlasBase.CreateNormalTextureNode: TPixelTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1385);{$ENDIF}
  Result := CreateChannelTextureNode(acNormal);
end;

function TCompositeAtlasBase.CreateMaskTextureNode: TPixelTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1386);{$ENDIF}
  Result := CreateChannelTextureNode(acMask);
end;

function TCompositeAtlasBase.CreateGlowTextureNode: TPixelTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1387);{$ENDIF}
  Result := CreateChannelTextureNode(acGlow);
end;

function TCompositeAtlasBase.CreateTextureNodeUrl: TImageTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1388);{$ENDIF}
  Result := CreateChannelTextureNodeUrl(acDiffuse);
end;

function TCompositeAtlasBase.CreateNormalTextureNodeUrl: TImageTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1389);{$ENDIF}
  Result := CreateChannelTextureNodeUrl(acNormal);
end;

function TCompositeAtlasBase.CreateMaskTextureNodeUrl: TImageTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1390);{$ENDIF}
  Result := CreateChannelTextureNodeUrl(acMask);
end;

function TCompositeAtlasBase.CreateGlowTextureNodeUrl: TImageTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1391);{$ENDIF}
  Result := CreateChannelTextureNodeUrl(acGlow);
end;

function TCompositeAtlasBase.SaveToCache(const ACacheDir: string;
  LogProc: TLogProc): Boolean;
var
  Ch: TAtlasChannel;
  Dir: string;
  N: Integer;
  Savers: array[TAtlasChannel] of TAtlasSaveWorker;
  SaveFailed: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1392);{$ENDIF}
  Result := False;
  ClearUrls;
  if ACacheDir = '' then Exit;
  if FBuildFailed then
  begin
    if Assigned(LogProc) then
      LogProc('  ' + LogPrefix + '.SaveToCache: incomplete build — skipped');
    Exit;
  end;

  if FImages[acDiffuse] = nil then
  begin
    if Assigned(LogProc) then
      LogProc('  ' + LogPrefix + '.SaveToCache: BuildImage not called — skipped');
    Exit;
  end;

  Dir := IncludeTrailingPathDelimiter(ACacheDir);
  try
    if not ForceDirectories(Dir) then
    begin
      if Assigned(LogProc) then
        LogProc('  ' + LogPrefix + '.SaveToCache: cannot create dir ' + Dir);
      Exit;
    end;

    { Все заявленные каналы должны быть построены до записи. }
    for Ch in FChannels do
      if FImages[Ch] = nil then
      begin
        if Assigned(LogProc) then
          LogProc('  ' + LogPrefix
            + '.SaveToCache: a channel image is missing — skipped');
        Exit;
      end;

    { Encode channels to PNG in parallel (independent files); one worker per channel,
      join, then set URLs. Any failure -> no partial state (ClearUrls). }
    for Ch := Low(TAtlasChannel) to High(TAtlasChannel) do
      Savers[Ch] := nil;
    try
      for Ch in FChannels do
        Savers[Ch] := TAtlasSaveWorker.Create(FImages[Ch], Dir + CacheFileName(Ch));
      SaveFailed := False;
      N := 0;
      for Ch in FChannels do
      begin
        Savers[Ch].WaitFor;
        if Savers[Ch].Ok then
        begin
          FUrls[Ch] := FilenameToURISafe(Dir + CacheFileName(Ch));
          if FUrls[Ch] = '' then SaveFailed := True
          else Inc(N);
        end
        else
        begin
          SaveFailed := True;
          if Assigned(LogProc) then
            LogProc('  ' + LogPrefix + '.SaveToCache: encode failed for '
              + CacheFileName(Ch) + ' — ' + Savers[Ch].Err);
        end;
      end;
    finally
      for Ch := Low(TAtlasChannel) to High(TAtlasChannel) do
        if Savers[Ch] <> nil then Savers[Ch].Free;
    end;

    if SaveFailed then
    begin
      ClearUrls;   { без частичного состояния — иначе DiffuseUrl<>''
                     включил бы URL-путь с битыми остальными нодами }
      Exit;
    end;

    { Take average colours and write the manifest BEFORE freeing the images, so
      TryLoadFromCache can reuse both, and so CellAverageRGB/ImageAverageRGB keep working. }
    WriteManifest(ACacheDir);

    { Disk PNGs are now the source of truth (CGE caches GPU textures by URL); free the buffers. }
    for Ch in FChannels do
      FreeAndNil(FImages[Ch]);

    Result := True;
    if Assigned(LogProc) then
      LogProc(Format('  %s: saved %d atlas PNGs to %s (in-memory images freed)',
        [LogPrefix, N, ACacheDir]));
  except
    on E: Exception do
    begin
      ClearUrls;
      if Assigned(LogProc) then
        LogProc('  ' + LogPrefix + '.SaveToCache FAILED: ' + E.Message
          + ' — falling back to inline texture nodes');
    end;
  end;
end;

procedure TCompositeAtlasBase.RunBuildPasses(
  const Passes: array of TAtlasBuildPass; LogProc: TLogProc);
var
  i, j: Integer;
  W: array of TAtlasBuildWorker;
begin
  if Length(Passes) = 0 then Exit;
  FBuildFailed := True;
  SetLength(W, Length(Passes));
  try
    for i := 0 to High(Passes) do
      W[i] := TAtlasBuildWorker.Create(Passes[i]);
    for i := 0 to High(Passes) do
      W[i].WaitFor;
    for i := 0 to High(Passes) do
      if not W[i].Ok then
        raise Exception.Create(LogPrefix + ': build pass ' + IntToStr(i)
          + ' failed: ' + W[i].Err);
    { Replay logs only after every pass is joined and checked. }
    if Assigned(LogProc) then
      for i := 0 to High(Passes) do
        for j := 0 to W[i].Buf.Count - 1 do
          LogProc(W[i].Buf[j]);
    FBuildFailed := False;
  finally
    { TThread.Destroy joins started workers, including when a later constructor
      or the caller's logger raises. Their log buffers must outlive that join. }
    for i := 0 to High(W) do
      W[i].Free;
  end;
end;

procedure TCompositeAtlasBase.BuildChannelsParallel(LogProc: TLogProc);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1395);{$ENDIF}
  RunBuildPasses([@BuildImage, @BuildNormalImage, @BuildMaskImage], LogProc);
end;

{ Parse exactly Need ints separated by Delim; wrong count or non-number -> False. }
function AtlasSplitInts(const S: string; Delim: Char;
  out Vals: array of Integer; Need: Integer): Boolean;
var i, n, start, parsed: Integer; part: string;
begin
  Result := False; n := 0; start := 1;
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or (S[i] = Delim) then
    begin
      if n >= Need then Exit;                 { лишние поля }
      part := Trim(Copy(S, start, i - start));
      parsed := StrToIntDef(part, -2147483647);
      if parsed = -2147483647 then Exit;       { не число }
      Vals[n] := parsed; Inc(n); start := i + 1;
    end;
  Result := (n = Need);
end;

function TCompositeAtlasBase.BuildSignature: string;
var i: Integer; mi: TAtlasMaterialInfo; ch: TAtlasChannel; chs: string;
begin
  chs := '';
  for ch := Low(TAtlasChannel) to High(TAtlasChannel) do
    if ch in FChannels then chs := chs + IntToStr(Ord(ch));
  Result := Format('%s;L=%dx%dx%d;C=%s;N=%d',
    [LogPrefix, FLayout.GridCols, FLayout.GridRows, FLayout.TilePixels,
     chs, MaterialCount]);
  for i := 0 to MaterialCount - 1 do
  begin
    mi := MaterialInfo(i);
    Result := Result + Format('|%s,%s,%s,%s,%.3f,%.3f,%.3f,%.3f',
      [mi.Name, mi.DiffusePath, mi.NormalPath, mi.MaskPath,
       mi.FallbackColor.X, mi.FallbackColor.Y, mi.FallbackColor.Z, mi.Roughness]);
  end;
end;

function TCompositeAtlasBase.ManifestPath(const ACacheDir: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ACacheDir) + LogPrefix + '.manifest';
end;

procedure TCompositeAtlasBase.WriteManifest(const ACacheDir: string);
var
  sl: TStringList;
  i, nCells, iv: Integer;
  rr, gg, bb: Byte;
begin
  nCells := FLayout.GridCols * FLayout.GridRows;
  SetLength(FCacheCellR, nCells); SetLength(FCacheCellG, nCells);
  SetLength(FCacheCellB, nCells); SetLength(FCacheCellValid, nCells);
  sl := TStringList.Create;
  try
    sl.Add('osm3d-atlas');
    sl.Add('ver=' + IntToStr(ATLAS_CACHE_VERSION));
    sl.Add('sig=' + BuildSignature);
    if ImageAverageRGB(rr, gg, bb) then
    begin
      FCacheImgValid := True; FCacheImgR := rr; FCacheImgG := gg; FCacheImgB := bb; iv := 1;
    end
    else
    begin FCacheImgValid := False; rr := 0; gg := 0; bb := 0; iv := 0; end;
    sl.Add(Format('img=%d,%d,%d,%d', [iv, rr, gg, bb]));
    sl.Add('cells=' + IntToStr(nCells));
    for i := 0 to nCells - 1 do
    begin
      if CellAverageRGB(i, rr, gg, bb) then
      begin
        FCacheCellValid[i] := True;
        FCacheCellR[i] := rr; FCacheCellG[i] := gg; FCacheCellB[i] := bb; iv := 1;
      end
      else
      begin FCacheCellValid[i] := False; rr := 0; gg := 0; bb := 0; iv := 0; end;
      sl.Add(Format('%d %d %d %d %d', [i, iv, rr, gg, bb]));
    end;
    FAvgCached := True;
    try
      sl.SaveToFile(ManifestPath(ACacheDir));
    except
      { манифест необязателен: без него просто не будет переиспользования }
    end;
  finally
    sl.Free;
  end;
end;

function TCompositeAtlasBase.ReadManifestAndValidate(
  const ACacheDir: string): Boolean;
var
  sl: TStringList;
  i, k, cellsN, nCells: Integer;
  ln: string;
  v4: array[0..3] of Integer;
  v5: array[0..4] of Integer;
  verOK, sigOK, imgParsed: Boolean;
begin
  Result := False;
  verOK := False; sigOK := False; imgParsed := False; cellsN := -1;
  nCells := FLayout.GridCols * FLayout.GridRows;
  if not FileExists(ManifestPath(ACacheDir)) then Exit;
  SetLength(FCacheCellR, nCells); SetLength(FCacheCellG, nCells);
  SetLength(FCacheCellB, nCells); SetLength(FCacheCellValid, nCells);
  for k := 0 to nCells - 1 do FCacheCellValid[k] := False;
  FCacheImgValid := False;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(ManifestPath(ACacheDir));
    except
      Exit;
    end;
    i := 0;
    while i < sl.Count do
    begin
      ln := sl[i];
      if Copy(ln, 1, 4) = 'ver=' then
      begin
        if StrToIntDef(Copy(ln, 5, 99), -1) = ATLAS_CACHE_VERSION then verOK := True;
      end
      else if Copy(ln, 1, 4) = 'sig=' then
      begin
        if Copy(ln, 5, Length(ln)) = BuildSignature then sigOK := True;
      end
      else if Copy(ln, 1, 4) = 'img=' then
      begin
        if AtlasSplitInts(Copy(ln, 5, Length(ln)), ',', v4, 4) then
        begin
          FCacheImgValid := v4[0] <> 0;
          FCacheImgR := Byte(v4[1]); FCacheImgG := Byte(v4[2]); FCacheImgB := Byte(v4[3]);
          imgParsed := True;
        end;
      end
      else if Copy(ln, 1, 6) = 'cells=' then
      begin
        cellsN := StrToIntDef(Copy(ln, 7, 99), -1);
        if cellsN <> nCells then Exit;            { дрейф раскладки — кэш стар }
        for k := 0 to cellsN - 1 do
        begin
          Inc(i);
          if i >= sl.Count then Exit;             { обрезан }
          if not AtlasSplitInts(sl[i], ' ', v5, 5) then Exit;
          if (v5[0] < 0) or (v5[0] >= nCells) then Exit;
          FCacheCellValid[v5[0]] := v5[1] <> 0;
          FCacheCellR[v5[0]] := Byte(v5[2]);
          FCacheCellG[v5[0]] := Byte(v5[3]);
          FCacheCellB[v5[0]] := Byte(v5[4]);
        end;
      end;
      Inc(i);
    end;
  finally
    sl.Free;
  end;
  Result := verOK and sigOK and imgParsed and (cellsN = nCells);
  if Result then FAvgCached := True;
end;

function TCompositeAtlasBase.TryLoadFromCache(const ACacheDir: string;
  LogProc: TLogProc): Boolean;
var
  Ch: TAtlasChannel;
  Dir, FullPath: string;
  N: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1394);{$ENDIF}
  Result := False;
  ClearUrls;
  if ACacheDir = '' then Exit;
  Dir := IncludeTrailingPathDelimiter(ACacheDir);

  { манифест должен совпасть (версия + сигнатура раскладки/материалов) }
  if not ReadManifestAndValidate(ACacheDir) then Exit;

  { все PNG каналов должны быть на месте }
  for Ch in FChannels do
    if not FileExists(Dir + CacheFileName(Ch)) then Exit;

  { навести URL каналов на закэшированные PNG (как успешный SaveToCache) }
  N := 0;
  for Ch in FChannels do
  begin
    FullPath := Dir + CacheFileName(Ch);
    FUrls[Ch] := FilenameToURISafe(FullPath);
    if FUrls[Ch] = '' then begin ClearUrls; Exit; end;
    Inc(N);
  end;

  { освободить жадно выделенный diffuse-буфер — рендер идёт по PNG,
    средние цвета отдаём из кэша манифеста. }
  for Ch in FChannels do
    FreeAndNil(FImages[Ch]);

  Result := True;
  if Assigned(LogProc) then
    LogProc(Format('  %s: reused %d cached atlas PNGs (no rebuild)',
      [LogPrefix, N]));
end;

end.
