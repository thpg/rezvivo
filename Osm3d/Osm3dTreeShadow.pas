unit Osm3dTreeShadow;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  SysUtils,
  CastleImages;

const
  { Diffuse-PNG деревьев; альфа-канал каждого = силуэт кроны.
    Индекс = TexId карточки тени (0..4). }
  TREE_SHADOW_FILE: array[0..4] of string =
    ('beech_diffuse.png', 'fir_diffuse.png', 'linden0_diffuse.png',
     'linden1_diffuse.png', 'oak_diffuse.png');

{ Ленивый сеттер: только запоминает каталог; альфы загрузятся при первом
  EnsureTreeShadowAlpha. Если каталог не задан — тени деревьев просто
  пропускаются. }
procedure SetTreeShadowTexturesDir(const ADir: string);

{ Жадный сеттер: запоминает каталог И грузит альфы НЕМЕДЛЕННО на вызывающем (главном) потоке —
  LoadImage небезопасен на теневом воркере. При смене каталога
  принудительно перезагружает. Повторный вызов с тем же каталогом при
  уже загруженных альфах — no-op. }
procedure SetTreeShadowDir(const ADir: string);

{ Лениво загрузить пять diffuse-PNG и оставить только их альфа-канал
  (силуэт) как grayscale-маски. Загрузка без class-constraint и чтение
  через Colors[], чтобы 16-битные/float PNG конвертировались чисто.
  Однократна (guard); CPU-only, без GL. }
procedure EnsureTreeShadowAlpha;

{ Альфа-маска дерева Index (0..4); nil, если PNG отсутствует/не
  загрузился или каталог не задан. Владелец — этот юнит, не Free'ить. }
function TreeShadowAlpha(Index: Integer): TGrayscaleImage;

{ Темнота тени в точке, чей наземный сдвиг от основания стены равен L
  метров: полная у основания (контакт), с выходом на остаточный пол к
  кончику, чтобы длинные тени растворялись. Бесплатно даёт contact-
  darkening у оснований стен. }
function ShadowIntensityFor(L: Single): Byte;

implementation

uses
  Osm3dImageCodecLock;   { Vampyre не потокобезопасен — LoadImage под общим замком }

var
  GTreeShadowDir:   string  = '';
  GTreeShadowReady: Boolean = False;
  GTreeShadowAlpha: array[0..4] of TGrayscaleImage = (nil, nil, nil, nil, nil);
  { Ленивая загрузка может случиться на теневом воркере (RasterizeSnapshotMask /
    RasterizeTreeMaskPacked зовут EnsureTreeShadowAlpha), а смена каталога —
    на главном потоке: проверку/загрузку/сброс сериализуем; Ready ставится
    только ПОСЛЕ завершения загрузки, не до неё. }
  GTreeShadowCS: TRTLCriticalSection;

procedure SetTreeShadowTexturesDir(const ADir: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1823);{$ENDIF}
  EnterCriticalSection(GTreeShadowCS);
  try
    if ADir = GTreeShadowDir then Exit;
    GTreeShadowDir   := ADir;
    GTreeShadowReady := False;   { force reload on next Ensure for a new dir }
  finally
    LeaveCriticalSection(GTreeShadowCS);
  end;
end;

procedure SetTreeShadowDir(const ADir: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1824);{$ENDIF}
  EnterCriticalSection(GTreeShadowCS);
  try
    { unchanged + already loaded — alphas valid, nothing to do }
    if (ADir = GTreeShadowDir) and GTreeShadowReady then Exit;
    if ADir <> GTreeShadowDir then
    begin
      GTreeShadowDir   := ADir;
      GTreeShadowReady := False;   { force reload for the new directory }
    end;
    { Load the alphas NOW, on the thread that sets the directory (the main
      thread). LoadImage is not safe to run on the shadow worker, and this is
      always called from MountBatch before any mask job is enqueued, so the
      worker only ever READS the already-published GTreeShadowAlpha images. }
    EnsureTreeShadowAlpha;
  finally
    LeaveCriticalSection(GTreeShadowCS);
  end;
end;

procedure EnsureTreeShadowAlpha;
var
  i, x, y: Integer;
  Src: TCastleImage;
  G:   TGrayscaleImage;
  Fn:  string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1825);{$ENDIF}
  EnterCriticalSection(GTreeShadowCS);
  try
    if GTreeShadowReady then Exit;
    { новый каталог → прежние маски устарели }
    for i := 0 to 4 do
      FreeAndNil(GTreeShadowAlpha[i]);
    if GTreeShadowDir <> '' then
      for i := 0 to 4 do
      begin
        Fn := IncludeTrailingPathDelimiter(GTreeShadowDir) + TREE_SHADOW_FILE[i];
        if not FileExists(Fn) then Continue;
        Src := nil;
        try
          EnterImageCodec;
          try
            Src := LoadImage(Fn);
          finally
            LeaveImageCodec;
          end;
        except
          on E: Exception do Src := nil;
        end;
        if Src = nil then Continue;
        try
          G := TGrayscaleImage.Create(Src.Width, Src.Height);
          for y := 0 to Integer(Src.Height) - 1 do
            for x := 0 to Integer(Src.Width) - 1 do
              PByte(G.PixelPtr(x, y))^ := Round(Src.Colors[x, y, 0].W * 255.0);
          GTreeShadowAlpha[i] := G;
        finally
          Src.Free;
        end;
      end;
    { Ready — только после того, как маски в консистентном состоянии
      (проход завершён; отдельные маски могут остаться nil = файла нет). }
    GTreeShadowReady := True;
  finally
    LeaveCriticalSection(GTreeShadowCS);
  end;
end;

function TreeShadowAlpha(Index: Integer): TGrayscaleImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1826);{$ENDIF}
  if (Index < 0) or (Index > 4) then Exit(nil);
  EnterCriticalSection(GTreeShadowCS);
  try
    Result := GTreeShadowAlpha[Index];
  finally
    LeaveCriticalSection(GTreeShadowCS);
  end;
end;

function ShadowIntensityFor(L: Single): Byte;
const
  FALLOFF_M = 55.0;   { distance over which the umbra washes out }
  MIN_K     = 0.40;   { residual darkness at/after the falloff }
var
  t, kf: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1827);{$ENDIF}
  t := L / FALLOFF_M;
  if t < 0.0 then t := 0.0;   { L<0: иначе kf>1 и переполнение Byte ниже }
  if t > 1.0 then t := 1.0;
  kf := 1.0 - (1.0 - MIN_K) * t;
  Result := Round(kf * 255.0);
end;

initialization
  InitCriticalSection(GTreeShadowCS);

{ Намеренно БЕЗ finalization/DoneCriticalSection — см. комментарий в
  Osm3dCacheHTTPFetcher: поздние Destroy при закрытии приложения могут
  ещё входить в секцию, когда finalization этого юнита уже отработал. }
end.
