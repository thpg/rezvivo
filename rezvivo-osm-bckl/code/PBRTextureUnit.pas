unit PBRTextureUnit;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math,
  CastleVectors, CastleImages, CastleColors,
  X3DNodes;

type
  { Уровень качества PBR-текстур }
  TTextureQuality = (
    tqLow,      { BaseColor only, aniso=2 }
    tqMedium,   { BaseColor + Normal, aniso=4 }
    tqHigh,     { BaseColor + Normal + Roughness + AO, aniso=8 }
    tqUltra     { All PBR channels, aniso=16 }
  );

  { Набор путей к PBR-текстурам, найденным в папке }
  TPBRTextureSet = record
    BaseColor: string;
    Normal: string;
    Roughness: string;
    AO: string;
    Height: string;
    Mask: string;
  end;

  { Какие PBR-каналы использовать }
  TPBREffects = record
    UseBaseColor: Boolean;
    UseNormal: Boolean;
    UseRoughness: Boolean;
    UseAO: Boolean;
    UseHeight: Boolean;
    UseMask: Boolean;
    UsePhysicalMaterial: Boolean;
    UseOldMode: Boolean;  { True = PhysicalMaterial без обработок, False = CommonSurfaceShader }
  end;

  { Процессор PBR-текстур: поиск в папке, преобразования, сборка Appearance }
  TPBRTextureProcessor = class
  private
    FTempFiles: TStringList;
    { In-memory cache of processed images. The PBR processors used to
      write each intermediate texture to a temp PNG and return its path;
      that round-trip went through SaveImage → libpng, which crashes in
      some builds (missing/mismatched libpng) and is slow regardless.
      Instead a processed TCastleImage is kept here under a synthetic
      'pbr-mem:<n>' key, and CreateImageTexture turns that key into a
      TPixelTextureNode with the pixels embedded — no disk, no libpng. }
    FMemImages: TStringList;          { key → TCastleImage (Objects[]) }
    FMemCounter: Integer;
    { Store AImage in the cache (processor takes ownership) and return
      its synthetic 'pbr-mem:<n>' key. }
    function CacheProcessedImage(AImage: TCastleImage): string;
    { Load an image by file path, OR — when AFileName is a synthetic
      'pbr-mem:<n>' key — return an independent copy of the cached
      image. Lets processors chain (one's output feeds another's input)
      without any disk round-trip. Caller owns the returned image. }
    function LoadImageResolved(const AFileName: string): TCastleImage;
  public
    constructor Create;
    destructor Destroy; override;

    { Найти PBR-текстуры в папке по именам (BaseColor/Diffuse/Albedo, Normal, Roughness и т.д.) }
    class function FindTextures(const AFolder: string): TPBRTextureSet;

    { Найти только base-color текстуру в папке (для 2D-наложения и т.п.) }
    class function FindBaseColorFile(const AFolder: string): string;

    { Создать текстурную ноду из файла ИЛИ из синтетического ключа
      'pbr-mem:<n>' (тогда строится TPixelTextureNode из кэшированного
      в памяти изображения — без обращения к диску). }
    function CreateImageTexture(const AFileName: string;
      ARepeatS, ARepeatT: Boolean): TAbstractTexture2DNode;

    { Like CreateImageTexture, but for a synthetic 'pbr-mem:<n>' key it
      first writes the processed pixels to ACachePngPath ONCE (creating
      dirs as needed) and then builds a URL-based TImageTextureNode from
      that PNG — exactly like the ground atlas. CGE then dedups and
      ref-counts the GPU texture by URL across every scene that references
      it, so it is never dropped on tile churn (the embedded-pixel node
      used otherwise has no such URL-cache safety net and gets released
      globally when shared across tile scenes). Falls back to the
      embedded-pixel node when ACachePngPath is '' or the save fails
      (e.g. libpng unavailable), and is a no-op wrapper for real file
      inputs (already URL-loadable). }
    function CreateImageTexturePersisted(const AKeyOrFile, ACachePngPath: string;
      ARepeatS, ARepeatT: Boolean): TAbstractTexture2DNode;

    { Инвертировать зелёный канал нормалей (DirectX → OpenGL) }
    function ConvertNormalDXtoGL(const AFileName: string): string;

    { Упаковать нормаль + высоту в RGBA (RGB = normal GL, A = height) }
    function PackNormalWithHeight(const ANormalFile, AHeightFile: string): string;

    { Инвертировать roughness → shininess }
    function InvertRoughnessToShininess(const ARoughnessFile: string): string;

    { Применить маску к diffuse (умножение) }
    function ApplyMaskToDiffuse(const ADiffuseFile, AMaskFile: string): string;

    { Упаковать roughness в glTF metallic-roughness формат (G=roughness, B=metallic=0) }
    function PackMetallicRoughness(const ARoughnessFile: string): string;

    { Переупаковать streets-gl mask-текстуру в glTF metallic-roughness.
      streets-gl mask: R=roughness, G=metalness, B=tint-factor
      (см. extruded.frag: outRoughnessMetalnessF0 = vec3(mask.r,mask.g,..)).
      glTF/CGE MetallicRoughnessTexture ждёт G=roughness, B=metalness.
      Эта функция переносит R→G и G→B, выдаёт временный PNG.
      ADeMetalGlass=True: тексели стекла (metalness>0.5) переводятся в
      гладкий диэлектрик (metalness→0, roughness ограничивается). Это
      нужно, чтобы базовый цвет стекла (несущий отражение неба из
      шейдера) был виден — у металла PBR его почти игнорирует. }
    function PackStreetsGLMask(const AMaskFile: string;
      ADeMetalGlass: Boolean = False): string;

    { Построить emissive-карту окон из streets-gl glow-текстуры
      (window0_glow.png и т.п.). Яркие области glow = стёкла окон;
      они красятся тоном ATintR/G/B, тёмные области → чёрные.
      Используется как EmissiveTexture, чтобы поднять ТОЛЬКО окна из
      черноты, не трогая стены/крыши (там glow чёрный → emissive 0). }
    function BuildWindowEmissive(const AGlowFile: string;
      ATintR, ATintG, ATintB: Single): string;

    { Поднять почти-чёрные тексели изображения до цвета-пола.
      streets-gl рисует стекло окна чисто чёрным (0,0,0) — на чёрной
      базе любой шейдерный вклад умножается в ноль. Эта функция
      заменяет тексели темнее порога на floor-цвет (плавно), давая
      стеклу базовый тёмный тон, на котором отражение видно.
      Выдаёт временный PNG. }
    function LiftBlacks(const AFileName: string;
      AFloorR, AFloorG, AFloorB, AThreshold: Single): string;

    { Залить область СТЕКЛА фасадного diffuse ровным цветом.
      ADiffuseFile — <mat>_window_diffuse.png, AGlowFile — парная
      glow-маска (белое = стекло). Где glow ярче 0.5, тексель diffuse
      становится (AR,AG,AB); рамы и стена остаются как есть.
      Зачем: у части материалов (brick) стекло в diffuse чисто
      чёрное; шейдер PLUG_main_texture_apply домножается на базовый
      diffuse ПОСЛЕ себя, и на чёрном стекле любой отражённый цвет
      гаснет в ноль. Залив стекло ненулевым тоном, мы даём отражению
      основу, на которой оно видно (и окна перестают быть чёрными).
      Выдаёт временный PNG. }
    function CompositeGlassBase(const ADiffuseFile, AGlowFile: string;
      AR, AG, AB: Single): string;

    { Уменьшить текстуру в соответствии с уровнем качества.
      Ultra=1x, High=1/2, Medium=1/4, Low=1/8 }
    function DownscaleTexture(const AFileName: string): string;

    { Уменьшить все текстуры набора по уровню качества }
    procedure DownscaleTextureSet(var ATextures: TPBRTextureSet);

    { Собрать TAppearanceNode из набора текстур и эффектов.
      AParallaxHeight — высота параллакса для CSS-режима. }
    function BuildAppearance(const ATextures: TPBRTextureSet;
      const AEffects: TPBREffects;
      AParallaxHeight: Single): TAppearanceNode;

    { Удалить все временные файлы }
    procedure CleanupTempFiles;
  end;

const
  TextureQualityNames: array[TTextureQuality] of string = (
    'Low', 'Medium', 'High', 'Ultra'
  );

{ Build TPBREffects based on current quality level and available textures }
function MakeEffectsForQuality(AQuality: TTextureQuality;
  const ATextures: TPBRTextureSet;
  AUsePhysicalMaterial: Boolean): TPBREffects;

{ Anisotropic degree for quality level }
function AnisoDegreeForQuality(AQuality: TTextureQuality): Integer;

var
  GlobalTextureQuality: TTextureQuality;

implementation

{ ======================== Quality helpers ======================== }

function AnisoDegreeForQuality(AQuality: TTextureQuality): Integer;
begin
  case AQuality of
    tqLow:    Result := 2;
    tqMedium: Result := 4;
    tqHigh:   Result := 8;
    tqUltra:  Result := 16;
    else      Result := 16;
  end;
end;

function MakeEffectsForQuality(AQuality: TTextureQuality;
  const ATextures: TPBRTextureSet;
  AUsePhysicalMaterial: Boolean): TPBREffects;
begin
  Result := Default(TPBREffects);
  Result.UsePhysicalMaterial := AUsePhysicalMaterial;
  Result.UseOldMode := False;

  case AQuality of
    tqLow:
    begin
      Result.UseBaseColor := ATextures.BaseColor <> '';
      Result.UseNormal := False;
      Result.UseRoughness := False;
      Result.UseAO := False;
      Result.UseHeight := False;
      Result.UseMask := False;
    end;
    tqMedium:
    begin
      Result.UseBaseColor := ATextures.BaseColor <> '';
      Result.UseNormal := ATextures.Normal <> '';
      Result.UseRoughness := False;
      Result.UseAO := False;
      Result.UseHeight := False;
      Result.UseMask := False;
    end;
    tqHigh:
    begin
      Result.UseBaseColor := ATextures.BaseColor <> '';
      Result.UseNormal := ATextures.Normal <> '';
      Result.UseRoughness := ATextures.Roughness <> '';
      Result.UseAO := ATextures.AO <> '';
      Result.UseHeight := False;
      Result.UseMask := False;
    end;
    tqUltra:
    begin
      Result.UseBaseColor := ATextures.BaseColor <> '';
      Result.UseNormal := ATextures.Normal <> '';
      Result.UseRoughness := ATextures.Roughness <> '';
      Result.UseAO := ATextures.AO <> '';
      Result.UseHeight := ATextures.Height <> '';
      Result.UseMask := ATextures.Mask <> '';
    end;
  end;
end;

{ ======================== TPBRTextureProcessor ======================== }

constructor TPBRTextureProcessor.Create;
begin
  inherited Create;
  FTempFiles := TStringList.Create;
  FMemImages := TStringList.Create;
  FMemCounter := 0;
end;

destructor TPBRTextureProcessor.Destroy;
var
  I: Integer;
begin
  CleanupTempFiles;
  FTempFiles.Free;
  if Assigned(FMemImages) then
  begin
    for I := 0 to FMemImages.Count - 1 do
      FMemImages.Objects[I].Free;     { освобождаем кэшированные TCastleImage }
    FMemImages.Free;
  end;
  inherited Destroy;
end;

function TPBRTextureProcessor.CacheProcessedImage(
  AImage: TCastleImage): string;
begin
  Inc(FMemCounter);
  Result := 'pbr-mem:' + IntToStr(FMemCounter);
  FMemImages.AddObject(Result, AImage);    { кэш забирает владение AImage }
end;

function TPBRTextureProcessor.LoadImageResolved(
  const AFileName: string): TCastleImage;
var
  Idx: Integer;
begin
  if Copy(AFileName, 1, 8) = 'pbr-mem:' then
  begin
    { Вход — синтетический ключ: отдаём независимую копию кэшированного
      изображения (вызывающий код владеет и освобождает результат). }
    Idx := FMemImages.IndexOf(AFileName);
    if (Idx >= 0) and (FMemImages.Objects[Idx] is TCastleImage) then
      Result := TCastleImage(FMemImages.Objects[Idx]).MakeCopy as TCastleImage
    else
      raise Exception.Create('PBR: ключ pbr-mem не найден: ' + AFileName);
  end
  else
    Result := LoadImage(AFileName);
end;

procedure TPBRTextureProcessor.CleanupTempFiles;
var
  I: Integer;
begin
  for I := 0 to FTempFiles.Count - 1 do
    if FileExists(FTempFiles[I]) then
      DeleteFile(FTempFiles[I]);
  FTempFiles.Clear;
end;

{ -------------------- Поиск текстур -------------------- }

class function TPBRTextureProcessor.FindTextures(const AFolder: string): TPBRTextureSet;
var
  SR: TSearchRec;
  FName, FNameUp, Folder: string;
begin
  Result.BaseColor := '';
  Result.Normal := '';
  Result.Roughness := '';
  Result.AO := '';
  Result.Height := '';
  Result.Mask := '';

  Folder := AFolder;
  if (Folder <> '') and not (Folder[Length(Folder)] in ['/', '\']) then
    Folder := Folder + PathDelim;

  if FindFirst(Folder + '*.*', faAnyFile, SR) = 0 then
  begin
    repeat
      FName := SR.Name;
      FNameUp := UpperCase(FName);
      if (Pos('.PNG', FNameUp) = 0) and (Pos('.JPG', FNameUp) = 0) and
         (Pos('.JPEG', FNameUp) = 0) and (Pos('.TGA', FNameUp) = 0) then
        Continue;

      if (Pos('BASECOLOR', FNameUp) > 0) or (Pos('BASE_COLOR', FNameUp) > 0)
         or (Pos('DIFFUSE', FNameUp) > 0) or (Pos('ALBEDO', FNameUp) > 0) then
        Result.BaseColor := Folder + FName
      else if (Pos('NORMAL', FNameUp) > 0) then
        Result.Normal := Folder + FName
      else if (Pos('ROUGHNESS', FNameUp) > 0) then
        Result.Roughness := Folder + FName
      else if (Pos('AMBIENTOCCLUSION', FNameUp) > 0) or
              (Pos('AMBIENT_OCCLUSION', FNameUp) > 0) or
              (Pos('_AO', FNameUp) > 0) then
        Result.AO := Folder + FName
      else if (Pos('HEIGHT', FNameUp) > 0) or (Pos('DISPLACEMENT', FNameUp) > 0) then
        Result.Height := Folder + FName
      else if (Pos('MASK', FNameUp) > 0) then
        Result.Mask := Folder + FName;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

class function TPBRTextureProcessor.FindBaseColorFile(const AFolder: string): string;
var
  Textures: TPBRTextureSet;
begin
  Textures := FindTextures(AFolder);
  Result := Textures.BaseColor;
end;

{ -------------------- Создание ImageTexture -------------------- }

function TPBRTextureProcessor.CreateImageTexture(const AFileName: string;
  ARepeatS, ARepeatT: Boolean): TAbstractTexture2DNode;
var
  TexProps: TTexturePropertiesNode;
  ImgNode: TImageTextureNode;
  PixNode: TPixelTextureNode;
  Idx: Integer;
  CachedImg, ImgCopy: TCastleImage;
begin
  if Copy(AFileName, 1, 8) = 'pbr-mem:' then
  begin
    { Синтетический ключ — текстура из кэша в памяти. Строим
      TPixelTextureNode с встроенными пикселями: ни диска, ни libpng. }
    PixNode := TPixelTextureNode.Create;
    Idx := FMemImages.IndexOf(AFileName);
    if (Idx >= 0) and (FMemImages.Objects[Idx] is TCastleImage) then
    begin
      CachedImg := TCastleImage(FMemImages.Objects[Idx]);
      { Нода-владелец освобождает FdImage.Value; кэш тоже владеет своей
        копией. Поэтому в ноду кладём независимый дубликат. }
      ImgCopy := CachedImg.MakeCopy as TCastleImage;
      PixNode.FdImage.Value := ImgCopy;
    end;
    PixNode.RepeatS := ARepeatS;
    PixNode.RepeatT := ARepeatT;
    TexProps := TTexturePropertiesNode.Create;
    TexProps.AnisotropicDegree := AnisoDegreeForQuality(GlobalTextureQuality);
    PixNode.TextureProperties := TexProps;
    Result := PixNode;
    Exit;
  end;

  ImgNode := TImageTextureNode.Create;
  ImgNode.SetUrl([AFileName]);
  ImgNode.RepeatS := ARepeatS;
  ImgNode.RepeatT := ARepeatT;

  { Анизотропная фильтрация — степень зависит от качества }
  TexProps := TTexturePropertiesNode.Create;
  TexProps.AnisotropicDegree := AnisoDegreeForQuality(GlobalTextureQuality);
  ImgNode.TextureProperties := TexProps;
  Result := ImgNode;
end;

function TPBRTextureProcessor.CreateImageTexturePersisted(
  const AKeyOrFile, ACachePngPath: string;
  ARepeatS, ARepeatT: Boolean): TAbstractTexture2DNode;
var
  Img:   TCastleImage;
  Saved: Boolean;
begin
  { Only the in-memory keys need persisting; a real file path is already
    URL-loadable, so just delegate (CreateImageTexture builds a URL node
    for it). When a cache path is given, write the processed pixels to that
    PNG ONCE (skip if it already exists from a previous session) and build
    the URL node from it — same ownership model as TGroundAtlas.SaveToCache.
    Any failure (no cache dir, SaveImage/libpng error) falls back to the
    embedded-pixel node, i.e. exactly the previous behaviour. }
  if (Copy(AKeyOrFile, 1, 8) = 'pbr-mem:') and (ACachePngPath <> '') then
  begin
    Saved := FileExists(ACachePngPath);
    if not Saved then
    begin
      Img := nil;
      try
        Img := LoadImageResolved(AKeyOrFile);   { owned copy }
        if Img <> nil then
        begin
          ForceDirectories(ExtractFilePath(ACachePngPath));
          SaveImage(Img, ACachePngPath);
          Saved := True;
        end;
      except
        Saved := False;                          { e.g. libpng missing }
      end;
      if Img <> nil then Img.Free;
    end;
    if Saved then
      Exit(CreateImageTexture(ACachePngPath, ARepeatS, ARepeatT));
  end;

  { Fallback: embedded-pixel node (or plain URL node for a file input). }
  Result := CreateImageTexture(AKeyOrFile, ARepeatS, ARepeatT);
end;

{ -------------------- Преобразования текстур -------------------- }

function TPBRTextureProcessor.ConvertNormalDXtoGL(const AFileName: string): string;
var
  Img: TCastleImage;
  X, Y: Integer;
  C: TCastleColor;
begin
  Result := AFileName;
  try
    Img := LoadImageResolved(AFileName);
    try
      for Y := 0 to Img.Height - 1 do
        for X := 0 to Img.Width - 1 do
        begin
          C := Img.Colors[X, Y, 0];
          C.Y := 1.0 - C.Y;
          Img.Colors[X, Y, 0] := C;
        end;
      { Кэшируем в памяти — кэш забирает владение Img, освобождать нельзя. }
      Result := CacheProcessedImage(Img);
    except
      Img.Free;        { ошибка обработки — кэш не получил Img, чистим сами }
      raise;
    end;
  except
  end;
end;

function TPBRTextureProcessor.PackNormalWithHeight(
  const ANormalFile, AHeightFile: string): string;
var
  NImg, HImg: TCastleImage;
  OutImg: TRGBAlphaImage;
  X, Y, W, H: Integer;
  NC, HC: TCastleColor;
begin
  Result := ANormalFile;
  try
    NImg := LoadImageResolved(ANormalFile);
    try
      HImg := LoadImageResolved(AHeightFile);
      try
        W := NImg.Width;
        H := NImg.Height;
        OutImg := TRGBAlphaImage.Create(W, H);
        try
          for Y := 0 to H - 1 do
            for X := 0 to W - 1 do
            begin
              NC := NImg.Colors[X, Y, 0];
              NC.Y := 1.0 - NC.Y;
              HC := HImg.Colors[
                Trunc(X / W * (HImg.Width - 1)),
                Trunc(Y / H * (HImg.Height - 1)), 0];
              OutImg.Colors[X, Y, 0] := Vector4(
                NC.X, NC.Y, NC.Z,
                (HC.X + HC.Y + HC.Z) / 3.0);
            end;
          { Кэшируем OutImg — кэш забирает владение. }
          Result := CacheProcessedImage(OutImg);
          OutImg := nil;
        except
          OutImg.Free;
          raise;
        end;
      finally
        HImg.Free;
      end;
    finally
      NImg.Free;
    end;
  except
  end;
end;

function TPBRTextureProcessor.InvertRoughnessToShininess(
  const ARoughnessFile: string): string;
var
  Img: TCastleImage;
  X, Y: Integer;
  C: TCastleColor;
  R: Single;
begin
  Result := ARoughnessFile;
  try
    Img := LoadImageResolved(ARoughnessFile);
    try
      for Y := 0 to Img.Height - 1 do
        for X := 0 to Img.Width - 1 do
        begin
          C := Img.Colors[X, Y, 0];
          R := (C.X + C.Y + C.Z) / 3.0;
          R := 1.0 - R;
          Img.Colors[X, Y, 0] := Vector4(R, R, R, 1.0);
        end;
      Result := CacheProcessedImage(Img);
    except
      Img.Free;
      raise;
    end;
  except
  end;
end;

function TPBRTextureProcessor.ApplyMaskToDiffuse(
  const ADiffuseFile, AMaskFile: string): string;
var
  DImg, MImg: TCastleImage;
  X, Y: Integer;
  DC, MC: TCastleColor;
  MVal: Single;
begin
  Result := ADiffuseFile;
  try
    DImg := LoadImageResolved(ADiffuseFile);
    try
      MImg := LoadImageResolved(AMaskFile);
      try
        for Y := 0 to DImg.Height - 1 do
          for X := 0 to DImg.Width - 1 do
          begin
            DC := DImg.Colors[X, Y, 0];
            MC := MImg.Colors[
              Trunc(X / DImg.Width * (MImg.Width - 1)),
              Trunc(Y / DImg.Height * (MImg.Height - 1)), 0];
            MVal := (MC.X + MC.Y + MC.Z) / 3.0;
            DImg.Colors[X, Y, 0] := Vector4(
              DC.X * MVal, DC.Y * MVal, DC.Z * MVal, 1.0);
          end;
      finally
        MImg.Free;
      end;
      { DImg обработан in-place — кэшируем его, владение уходит в кэш. }
      Result := CacheProcessedImage(DImg);
    except
      DImg.Free;
      raise;
    end;
  except
  end;
end;

function TPBRTextureProcessor.PackMetallicRoughness(
  const ARoughnessFile: string): string;
var
  RoughImg, PackedImg: TCastleImage;
  X, Y: Integer;
  C: TCastleColor;
  RoughVal: Single;
begin
  Result := ARoughnessFile;
  try
    RoughImg := LoadImageResolved(ARoughnessFile);
    try
      PackedImg := TRGBImage.Create(RoughImg.Width, RoughImg.Height);
      try
        for Y := 0 to RoughImg.Height - 1 do
          for X := 0 to RoughImg.Width - 1 do
          begin
            C := RoughImg.Colors[X, Y, 0];
            RoughVal := (C.X + C.Y + C.Z) / 3.0;
            PackedImg.Colors[X, Y, 0] := Vector4(0.0, RoughVal, 0.0, 1.0);
          end;
        Result := CacheProcessedImage(PackedImg);
        PackedImg := nil;
      except
        PackedImg.Free;
        raise;
      end;
    finally
      RoughImg.Free;
    end;
  except
  end;
end;

function TPBRTextureProcessor.PackStreetsGLMask(
  const AMaskFile: string; ADeMetalGlass: Boolean): string;
var
  MaskImg, PackedImg: TCastleImage;
  X, Y: Integer;
  C: TCastleColor;
  Rough, Metal: Single;
begin
  Result := AMaskFile;
  try
    MaskImg := LoadImageResolved(AMaskFile);
    try
      PackedImg := TRGBImage.Create(MaskImg.Width, MaskImg.Height);
      try
        for Y := 0 to MaskImg.Height - 1 do
          for X := 0 to MaskImg.Width - 1 do
          begin
            C := MaskImg.Colors[X, Y, 0];
            { streets-gl mask: R=roughness, G=metalness.
              glTF MetallicRoughnessTexture: G=roughness, B=metalness.
              R-out unused (kept 0). }
            Rough := C.X;
            Metal := C.Y;
            if ADeMetalGlass then
            begin
              if Metal > 0.5 then
              begin
                { Glass (metalness ~1) is a metal in the streets-gl
                  mask, so the PBR model treats its albedo as nearly
                  invisible and the colour is dictated by specular /
                  IBL only — which CGE cannot do. Demote glass to a
                  glossy DIELECTRIC: metalness 0 so the base colour
                  (carrying the shader's sky reflection) shows, and
                  keep it smooth (low roughness) so it still reads as
                  glass. }
                Metal := 0.0;
                if Rough > 0.25 then Rough := 0.25;
              end
              else
              begin
                { Everything that is NOT glass — window frames and
                  the wall — must be MATTE. The streets-gl frame is
                  only semi-rough (~0.37); left as is it is a glossy
                  dielectric that catches a specular highlight and
                  reads as shiny metal. Force a high roughness so
                  frames / wall scatter light diffusely, and pin
                  metalness to 0. Glass keeps its low roughness in
                  the branch above. }
                if Rough < 0.85 then Rough := 0.85;
                Metal := 0.0;
              end;
            end;
            PackedImg.Colors[X, Y, 0] := Vector4(0.0, Rough, Metal, 1.0);
          end;
        Result := CacheProcessedImage(PackedImg);
        PackedImg := nil;
      except
        PackedImg.Free;
        raise;
      end;
    finally
      MaskImg.Free;
    end;
  except
  end;
end;

function TPBRTextureProcessor.BuildWindowEmissive(const AGlowFile: string;
  ATintR, ATintG, ATintB: Single): string;
var
  GlowImg, EmisImg: TCastleImage;
  X, Y: Integer;
  C: TCastleColor;
  W: Single;
begin
  Result := '';
  try
    GlowImg := LoadImageResolved(AGlowFile);
    try
      EmisImg := TRGBImage.Create(GlowImg.Width, GlowImg.Height);
      try
        for Y := 0 to GlowImg.Height - 1 do
          for X := 0 to GlowImg.Width - 1 do
          begin
            C := GlowImg.Colors[X, Y, 0];
            W := (C.X + C.Y + C.Z) / 3.0;
            if W < 0.5 then
              W := 0.0
            else
              W := 1.0;
            EmisImg.Colors[X, Y, 0] :=
              Vector4(ATintR * W, ATintG * W, ATintB * W, 1.0);
          end;
        Result := CacheProcessedImage(EmisImg);
        EmisImg := nil;
      except
        EmisImg.Free;
        raise;
      end;
    finally
      GlowImg.Free;
    end;
  except
  end;
end;

function TPBRTextureProcessor.LiftBlacks(const AFileName: string;
  AFloorR, AFloorG, AFloorB, AThreshold: Single): string;
var
  Img, OutImg: TCastleImage;
  X, Y: Integer;
  C: TCastleColor;
  L: Single;
begin
  Result := AFileName;
  try
    Img := LoadImageResolved(AFileName);
    try
      OutImg := TRGBImage.Create(Img.Width, Img.Height);
      try
        for Y := 0 to Img.Height - 1 do
          for X := 0 to Img.Width - 1 do
          begin
            C := Img.Colors[X, Y, 0];
            L := (C.X + C.Y + C.Z) / 3.0;
            if L < AThreshold then
              OutImg.Colors[X, Y, 0] :=
                Vector4(AFloorR, AFloorG, AFloorB, 1.0)
            else
              OutImg.Colors[X, Y, 0] := Vector4(C.X, C.Y, C.Z, 1.0);
          end;
        Result := CacheProcessedImage(OutImg);
        OutImg := nil;
      except
        OutImg.Free;
        raise;
      end;
    finally
      Img.Free;
    end;
  except
  end;
end;

function TPBRTextureProcessor.CompositeGlassBase(
  const ADiffuseFile, AGlowFile: string;
  AR, AG, AB: Single): string;
var
  DiffImg, GlowImg, OutImg: TCastleImage;
  X, Y, GX, GY: Integer;
  C, G: TCastleColor;
  GlowLum: Single;
begin
  Result := ADiffuseFile;
  try
    DiffImg := LoadImageResolved(ADiffuseFile);
    try
      GlowImg := LoadImageResolved(AGlowFile);
      try
        OutImg := TRGBImage.Create(DiffImg.Width, DiffImg.Height);
        try
          for Y := 0 to DiffImg.Height - 1 do
            for X := 0 to DiffImg.Width - 1 do
            begin
              C := DiffImg.Colors[X, Y, 0];
              { Sample the glow at the matching position (glow and
                diffuse are the same 512x512 facade tile, but guard
                against a size mismatch just in case). }
              if (GlowImg.Width = DiffImg.Width) and
                 (GlowImg.Height = DiffImg.Height) then
              begin
                GX := X; GY := Y;
              end
              else
              begin
                GX := (X * GlowImg.Width)  div DiffImg.Width;
                GY := (Y * GlowImg.Height) div DiffImg.Height;
              end;
              G := GlowImg.Colors[GX, GY, 0];
              GlowLum := (G.X + G.Y + G.Z) / 3.0;
              if GlowLum >= 0.5 then
                { Glass pane → flat base colour. }
                OutImg.Colors[X, Y, 0] := Vector4(AR, AG, AB, 1.0)
              else
                { Frame / wall → keep the original diffuse. }
                OutImg.Colors[X, Y, 0] := Vector4(C.X, C.Y, C.Z, 1.0);
            end;
          Result := CacheProcessedImage(OutImg);
          OutImg := nil;
        except
          OutImg.Free;
          raise;
        end;
      finally
        GlowImg.Free;
      end;
    finally
      DiffImg.Free;
    end;
  except
  end;
end;

function TPBRTextureProcessor.DownscaleTexture(const AFileName: string): string;
var
  Img, Resized: TCastleImage;
  NewW, NewH, Divisor: Integer;
begin
  Result := AFileName;
  if AFileName = '' then Exit;

  { Ultra = no downscale }
  case GlobalTextureQuality of
    tqHigh:   Divisor := 2;
    tqMedium: Divisor := 4;
    tqLow:    Divisor := 8;
    else Exit;
  end;

  try
    Img := LoadImageResolved(AFileName);
    try
      NewW := Img.Width div Divisor;
      NewH := Img.Height div Divisor;
      if NewW < 4 then NewW := 4;
      if NewH < 4 then NewH := 4;
      if (NewW >= Img.Width) and (NewH >= Img.Height) then Exit;

      Resized := Img.MakeResized(NewW, NewH, riBilinear);
      try
        Result := CacheProcessedImage(Resized);
        Resized := nil;
      except
        Resized.Free;
        raise;
      end;
    finally
      Img.Free;
    end;
  except
  end;
end;

procedure TPBRTextureProcessor.DownscaleTextureSet(var ATextures: TPBRTextureSet);
begin
  if GlobalTextureQuality = tqUltra then Exit;
  if ATextures.BaseColor <> '' then
    ATextures.BaseColor := DownscaleTexture(ATextures.BaseColor);
  if ATextures.Normal <> '' then
    ATextures.Normal := DownscaleTexture(ATextures.Normal);
  if ATextures.Roughness <> '' then
    ATextures.Roughness := DownscaleTexture(ATextures.Roughness);
  if ATextures.AO <> '' then
    ATextures.AO := DownscaleTexture(ATextures.AO);
  if ATextures.Height <> '' then
    ATextures.Height := DownscaleTexture(ATextures.Height);
  if ATextures.Mask <> '' then
    ATextures.Mask := DownscaleTexture(ATextures.Mask);
end;


{ -------------------- Сборка Appearance -------------------- }

function TPBRTextureProcessor.BuildAppearance(const ATextures: TPBRTextureSet;
  const AEffects: TPBREffects;
  AParallaxHeight: Single): TAppearanceNode;
var
  PhysMat: TPhysicalMaterialNode;
  CSS: TCommonSurfaceShaderNode;
  FnDiffuseProcessed, FnNormalProcessed, FnShininessProcessed, FnMRPacked: string;
begin
  Result := TAppearanceNode.Create;

  if AEffects.UseOldMode then
  begin
    { ---------- Old: PhysicalMaterial без обработок ---------- }
    PhysMat := TPhysicalMaterialNode.Create;
    PhysMat.BaseColor := Vector3(1, 1, 1);
    PhysMat.Metallic := 0.0;
    PhysMat.Roughness := 0.85;

    if ATextures.BaseColor <> '' then
    begin
      FnDiffuseProcessed := ATextures.BaseColor;
      PhysMat.BaseTexture := CreateImageTexture(FnDiffuseProcessed, True, True);
    end;

    if ATextures.Normal <> '' then
    begin
      FnNormalProcessed := ConvertNormalDXtoGL(ATextures.Normal);
      PhysMat.NormalTexture := CreateImageTexture(FnNormalProcessed, True, True);
    end;

    if ATextures.Roughness <> '' then
    begin
      FnMRPacked := PackMetallicRoughness(ATextures.Roughness);
      PhysMat.MetallicRoughnessTexture := CreateImageTexture(FnMRPacked, True, True);
    end;

    if ATextures.AO <> '' then
      PhysMat.OcclusionTexture := CreateImageTexture(ATextures.AO, True, True);

    Result.Material := PhysMat;
  end
  else if AEffects.UsePhysicalMaterial then
  begin
    { ---------- PhysicalMaterial (PBR, блеск от Roughness) ---------- }
    PhysMat := TPhysicalMaterialNode.Create;
    PhysMat.BaseColor := Vector3(1, 1, 1);
    PhysMat.Metallic := 0.0;
    PhysMat.Roughness := 0.85;

    if AEffects.UseBaseColor and (ATextures.BaseColor <> '') then
    begin
      FnDiffuseProcessed := ATextures.BaseColor;
      if AEffects.UseMask and (ATextures.Mask <> '') then
        FnDiffuseProcessed := ApplyMaskToDiffuse(ATextures.BaseColor, ATextures.Mask);
      
      PhysMat.BaseTexture := CreateImageTexture(FnDiffuseProcessed, True, True);
    end;

    if AEffects.UseNormal and (ATextures.Normal <> '') then
    begin
      FnNormalProcessed := ConvertNormalDXtoGL(ATextures.Normal);
      PhysMat.NormalTexture := CreateImageTexture(FnNormalProcessed, True, True);
    end;

    if AEffects.UseRoughness and (ATextures.Roughness <> '') then
    begin
      FnMRPacked := PackMetallicRoughness(ATextures.Roughness);
      PhysMat.MetallicRoughnessTexture := CreateImageTexture(FnMRPacked, True, True);
    end;

    if AEffects.UseAO and (ATextures.AO <> '') then
      PhysMat.OcclusionTexture := CreateImageTexture(ATextures.AO, True, True);

    Result.Material := PhysMat;
  end
  else
  begin
    { ---------- CommonSurfaceShader (параллакс, specular maps) ---------- }
    CSS := TCommonSurfaceShaderNode.Create;
    CSS.DiffuseFactor := Vector3(0.85, 0.85, 0.85);
    CSS.SpecularFactor := Vector3(0.15, 0.15, 0.15);
    CSS.ShininessFactor := 0.2;
    CSS.AmbientFactor := Vector3(0.3, 0.3, 0.3);

    if AEffects.UseBaseColor then
    begin
      FnDiffuseProcessed := ATextures.BaseColor;
      if AEffects.UseMask and (ATextures.Mask <> '') and (ATextures.BaseColor <> '') then
        FnDiffuseProcessed := ApplyMaskToDiffuse(ATextures.BaseColor, ATextures.Mask);
      if FnDiffuseProcessed <> '' then
      begin
        
        CSS.DiffuseTexture := CreateImageTexture(FnDiffuseProcessed, True, True);
      end;
    end;

    if AEffects.UseNormal and (ATextures.Normal <> '') then
    begin
      if AEffects.UseHeight and (ATextures.Height <> '') then
      begin
        FnNormalProcessed := PackNormalWithHeight(ATextures.Normal, ATextures.Height);
        CSS.NormalTexture := CreateImageTexture(FnNormalProcessed, True, True);
        CSS.NormalTextureParallaxHeight := AParallaxHeight;
      end
      else
      begin
        FnNormalProcessed := ConvertNormalDXtoGL(ATextures.Normal);
        CSS.NormalTexture := CreateImageTexture(FnNormalProcessed, True, True);
      end;
    end;

    if AEffects.UseRoughness and (ATextures.Roughness <> '') then
    begin
      FnShininessProcessed := InvertRoughnessToShininess(ATextures.Roughness);
      CSS.ShininessTexture := CreateImageTexture(FnShininessProcessed, True, True);
      CSS.SpecularTexture := CreateImageTexture(FnShininessProcessed, True, True);
    end;

    if AEffects.UseAO and (ATextures.AO <> '') then
      CSS.AmbientTexture := CreateImageTexture(ATextures.AO, True, True);

    Result.FdShaders.Add(CSS);
  end;
end;

initialization
  GlobalTextureQuality := tqUltra;

end.
