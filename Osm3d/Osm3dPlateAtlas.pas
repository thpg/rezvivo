unit Osm3dPlateAtlas;

{ overflow/range-проверки выключены намеренно (как в остальных atlas-юнитах) }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

{ Атлас алфавита для домовых табличек. В отличие от GRID-атласов земли/зданий (material = номер
  ячейки), это PACKED-атлас: глифы разного размера лежат в произвольных местах, а UV каждого
  бэйкаются ПОВЕРШИННО в меш (как стены зданий).

  Источник — готовый глифовый атлас CGE: встроенный шрифт Font_Default3D_Sans (DejaVu Sans, size
  25, 2048×2048 grayscale, та же, что у X3D TTextNode). Содержит цифры и ПОЛНУЮ кириллицу, так что
  номера с литерами рендерятся без FreeType и без поставки .ttf.

  Атлас НЕ владеет шрифтом (глобальный singleton CGE). Единственная «сборка» — один раз сохранить
  grayscale-изображение в PNG и отдавать TImageTextureNode по file://-URL (GPU-загрузка
  дедуплицируется CGE по URL). Метрики глифов берутся из TTextureFontData без RAM-картинки, поэтому
  после SaveToCache её можно не держать. }

interface

uses
  Classes,
  SysUtils,
  CastleImages,
  CastleVectors,
  CastleUriUtils,
  CastleRenderOptions,
  CastleTextureFontData,            { TTextureFontData / TGlyph }
  CastleTextureFont_Default3D_Sans, { Font_Default3D_Sans }
  X3DNodes,
  Osm3dGeoMath                      { TLogProc }
  {$IFDEF TEX_SIZE_PROFILE}, Osm3dTexProfile{$ENDIF}
;

const
  { Имя PNG-файла атласа в кэш-каталоге. }
  PLATE_ATLAS_FILE = 'plate_glyph_atlas.png';

type
  { Тонкая обёртка вокруг встроенного шрифта CGE. }
  TPlateGlyphAtlas = class
  private
    FFont: TTextureFontData;   { = Font_Default3D_Sans; НЕ владеем }
    FUrl:  string;             { file://…/plate_glyph_atlas.png — пусто, пока не сохранён }
    function FullPath(const ACacheDir: string): string;
  public
    constructor Create; reintroduce;

    { Сохранить grayscale-изображение шрифта в PNG в ACacheDir (создаётся при
      отсутствии) и запомнить его file://-URL. Идемпотентно: если файл уже
      есть, перезапись не делается (как и в TryLoadFromCache). False — каталог
      или запись не удались (URL остаётся пустым). }
    function SaveToCache(const ACacheDir: string; LogProc: TLogProc = nil): Boolean;

    { Переиспользование дискового кэша: если PNG уже лежит в ACacheDir — просто
      включить URL без повторной записи. False — файла нет. }
    function TryLoadFromCache(const ACacheDir: string): Boolean;

    { Свежая TImageTextureNode на закэшированный PNG (clamp + mipmaps + aniso).
      Требует непустого Url (после SaveToCache / TryLoadFromCache). Каждый вызов
      — новая нода; GPU-текстуру CGE грузит один раз на URL и реф-каунтит сам. }
    function CreateTextureNode: TImageTextureNode;

    { Прямой доступ к метрикам глифов (TextWidth, Glyph(...) и т.п.). }
    property Font: TTextureFontData read FFont;

    { Размеры атласа в пикселях (для нормировки UV). }
    function ImageWidth:  Integer;
    function ImageHeight: Integer;

    { Оптимальный размер шрифта в пикселях (Font.Size). }
    function FontSizePx: Single;

    { file://-URL закэшированного PNG ('' пока не сохранён). }
    property Url: string read FUrl;
  end;

implementation

constructor TPlateGlyphAtlas.Create;
begin
  inherited Create;
  { Лениво инициализируемый глобальный singleton CGE (аллокация 2048² grayscale
    из embedded-данных — один раз на процесс). }
  FFont := Font_Default3D_Sans;
  FUrl  := '';
end;

function TPlateGlyphAtlas.FullPath(const ACacheDir: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ACacheDir) + PLATE_ATLAS_FILE;
end;

function TPlateGlyphAtlas.TryLoadFromCache(const ACacheDir: string): Boolean;
var
  P: string;
begin
  P := FullPath(ACacheDir);
  Result := FileExists(P);
  if Result then
    FUrl := FilenameToUriSafe(P);
end;

function TPlateGlyphAtlas.SaveToCache(const ACacheDir: string;
  LogProc: TLogProc): Boolean;
var
  P: string;
begin
  Result := False;
  if (FFont = nil) or (FFont.Image = nil) then Exit;

  if not ForceDirectories(ACacheDir) then
  begin
    if Assigned(LogProc) then
      LogProc('PlateAtlas: cannot create cache dir ' + ACacheDir);
    Exit;
  end;

  P := FullPath(ACacheDir);
  try
    if not FileExists(P) then
      SaveImage(FFont.Image, FilenameToUriSafe(P));
    FUrl   := FilenameToUriSafe(P);
    Result := True;
    if Assigned(LogProc) then
      LogProc(Format('PlateAtlas: glyph atlas %dx%d -> %s',
        [ImageWidth, ImageHeight, PLATE_ATLAS_FILE]));
  except
    on E: Exception do
    begin
      FUrl := '';
      if Assigned(LogProc) then
        LogProc('PlateAtlas: SaveImage failed: ' + E.Message);
    end;
  end;
end;

function TPlateGlyphAtlas.CreateTextureNode: TImageTextureNode;
var
  Props: TTexturePropertiesNode;
begin
  if FUrl = '' then
    raise EInvalidOperation.Create(
      'TPlateGlyphAtlas.CreateTextureNode: atlas not saved (Url empty)');

  Props := TTexturePropertiesNode.Create;
  Props.MagnificationFilter := magLinear;
  Props.MinificationFilter  := minLinearMipmapLinear;
  Props.AnisotropicDegree   := 8;
  Props.BoundaryModeS       := bmClampToEdge;
  Props.BoundaryModeT       := bmClampToEdge;

  Result := TImageTextureNode.Create;
  Result.SetUrl([FUrl]);
  {$IFDEF TEX_SIZE_PROFILE}ProfileTexNode(Result, 'plate');{$ENDIF}
  Result.RepeatS := False;
  Result.RepeatT := False;
  Result.TextureProperties := Props;
end;

function TPlateGlyphAtlas.ImageWidth: Integer;
begin
  if (FFont <> nil) and (FFont.Image <> nil) then
    Result := FFont.Image.Width
  else
    Result := 2048;   { размер embedded-атласа Font_Default3D_Sans }
end;

function TPlateGlyphAtlas.ImageHeight: Integer;
begin
  if (FFont <> nil) and (FFont.Image <> nil) then
    Result := FFont.Image.Height
  else
    Result := 2048;
end;

function TPlateGlyphAtlas.FontSizePx: Single;
begin
  if FFont <> nil then
    Result := FFont.Size
  else
    Result := 25.0;
end;

end.
