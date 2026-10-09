{ BikeGeometryLib — Bike Insights (apolloState) parser + apply to TBikeInstance.

  Shared by the game BikeFit page (and available to the editor). Listing a
  catalog is filename-only so opening a folder of ~1400 dumps stays cheap;
  a file is parsed only when the user picks it. }
unit BikeGeometryLib;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Generics.Collections,
  BikeParametric;

type
  { Geometry data extracted from a single BikeGeometry entry in JSON }
  TBikeGeometryData = record
    Size: string;
    HeadTubeAngle: Single;
    SeatTubeAngle: Single;
    ChainstayLength: Single;
    Wheelbase: Single;
    BBDrop: Single;
    Stack: Single;
    Reach: Single;
    SeatTubeLength: Single;
    HeadTubeLength: Single;
    EffectiveTopTubeLength: Single;
    ForkRake: Single;
    ForkAxleToCrown: Single;
    TopTubeSlope: Single;
    SeatTubeLengthToTT: Single;
    TopTubeHTRatio: Single;
    DownTubeHTRatio: Single;
    HasJunctionRatios: Boolean;
    StemLength: Single;
    StemAngle: Single;
    StemAngleValid: Boolean;
    CrankLength: Single;
    HandlebarWidth: Single;
    WheelBSD: Single;
    TireWidth: Single;
    TireOuterDiameter: Single;
  end;

  TBikeModelInfo = record
    BrandName: string;
    BikeName: string;
    VersionName: string;
    BuildName: string;
    BarType: string;
    SuspensionType: string;
    ForkTravel: Single;
    RearTravel: Single;
    CategoryName: string;
    FixedGear:Boolean;
    ChainringTeeth,RearSprocketTeeth:Integer;
  end;

  TBikeGeometryList = specialize TList<TBikeGeometryData>;

function InsightsCatalogDir: string;
function InsightsDisplayName(const FileName: string): string;
function InsightsModelCaption(const Info: TBikeModelInfo;
  const FallbackFile: string): string;
function IsBikeInsightsPath(const APath: string): Boolean;
procedure ScanInsightsCatalog(APaths, ANames: TStrings);
function ExtractBikeInsights(const FileName: string;
  out ModelInfo: TBikeModelInfo;
  out Geometries: TBikeGeometryList): Boolean;
function CollectInsightSizes(Geometries: TBikeGeometryList;
  ASizes: TStrings): Integer;
function FindInsightGeometry(Geometries: TBikeGeometryList;
  const ASize: string; out Geo: TBikeGeometryData): Boolean;
procedure ApplyGeometryToBikeInstance(Inst: TBikeInstance;
  const Geo: TBikeGeometryData; const Info: TBikeModelInfo);
function ApplyInsightsFileToBikeInstance(Inst: TBikeInstance;
  const FileName, ASize: string): Boolean;
procedure ReadFitAdjustments(Inst: TBikeInstance;
  out SeatExt, SaddleOffset, Spacers, StemLen: Single);
procedure ApplyFitAdjustments(Inst: TBikeInstance;
  SeatExt, SaddleOffset, Spacers, StemLen: Single);
procedure ReadFrameStackReach(Inst: TBikeInstance;
  out StackMm, ReachMm: Single);

implementation

uses
  Math, fpjson, jsonparser, BikeCatalogNames,
  CastleURIUtils,
  BikeParametric_Frame,
  BikeParametric_Fork,
  BikeParametric_Wheel,
  BikeParametric_Seat,
  BikeParametric_DropBar,
  BikeParametric_FlatBar,
  BikeParametric_Crankset, BikeParametric_Drivetrain;

function InsightsCatalogDir: string;
var
  Fn: string;
begin
  Fn := URIToFilenameSafe('castle-data:/bike_jsons/');
  if Fn <> '' then
    Result := IncludeTrailingPathDelimiter(Fn)
  else
    Result := '';
end;

function InsightsDisplayName(const FileName: string): string;
begin
  Result := BikeCatalogDisplayName(FileName);
end;

function InsightsModelCaption(const Info: TBikeModelInfo;
  const FallbackFile: string): string;
begin
  if Info.BrandName <> '' then
    Result := Trim(BikeBrandDisplayName(Info.BrandName) + ' ' + Info.BikeName)
  else
    Result := Trim(Info.BikeName);
  if Info.VersionName <> '' then
  begin
    if Result <> '' then
      Result := Result + ' (' + Info.VersionName + ')'
    else
      Result := Info.VersionName;
  end;
  if Result = '' then
    Result := InsightsDisplayName(FallbackFile);
end;

function IsBikeInsightsPath(const APath: string): Boolean;
begin
  Result := Pos('bike_jsons', LowerCase(APath)) > 0;
end;

{ castle-data:/file has ':/' not '://'. Always try URI + catalog dir. }
function ResolveInsightsFilename(const APath: string): string;
var
  Conv, Catalog: string;
begin
  Result := Trim(APath);
  if Result = '' then Exit;
  if FileExists(Result) then Exit;
  Conv := URIToFilenameSafe(Result);
  if (Conv <> '') and FileExists(Conv) then
    Exit(Conv);
  Catalog := InsightsCatalogDir;
  if Catalog <> '' then
  begin
    Conv := Catalog + ExtractFileName(StringReplace(Result, '/',
      PathDelim, [rfReplaceAll]));
    if FileExists(Conv) then
      Exit(Conv);
  end;
end;

procedure ScanInsightsCatalog(APaths, ANames: TStrings);
var
  Dir, Fn, Url, Disp: string;
  SR: TSearchRec;
  Pair: TStringList;
  I: Integer;
begin
  if APaths = nil then Exit;
  APaths.Clear;
  if ANames <> nil then
    ANames.Clear;
  Dir := InsightsCatalogDir;
  if (Dir = '') or (not DirectoryExists(Dir)) then Exit;

  Pair := TStringList.Create;
  try
    Pair.Sorted := True;
    Pair.Duplicates := dupAccept;
    if FindFirst(Dir + '*.json', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory) <> 0 then Continue;
        Fn := Dir + SR.Name;
        Disp := InsightsDisplayName(SR.Name);
        Url := 'castle-data:/bike_jsons/' + SR.Name;
        Pair.Add(Disp + '=' + Url);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    for I := 0 to Pair.Count - 1 do
    begin
      APaths.Add(Pair.ValueFromIndex[I]);
      if ANames <> nil then
        ANames.Add(Pair.Names[I]);
    end;
  finally
    Pair.Free;
  end;
end;

function ExtractBikeInsights(const FileName: string;
  out ModelInfo: TBikeModelInfo;
  out Geometries: TBikeGeometryList): Boolean;

  function SafeFloat(D: TJSONData; Default: Single): Single;
  begin
    if (D = nil) or D.IsNull then Exit(Default);
    case D.JSONType of
      jtNumber:
        Result := D.AsFloat;
      jtString:
        Result := StrToFloatDef(D.AsString, Default);
      jtBoolean:
        if D.AsBoolean then Result := 1 else Result := 0;
    else
      Result := Default;
    end;
  end;

  function SafeInt(D: TJSONData; Default: Integer): Integer;
  begin
    if (D = nil) or D.IsNull then Exit(Default);
    case D.JSONType of
      jtNumber:
        Result := D.AsInteger;
      jtString:
        Result := StrToIntDef(D.AsString, Default);
      jtBoolean:
        if D.AsBoolean then Result := 1 else Result := 0;
    else
      Result := Default;
    end;
  end;

  function SafeStr(D: TJSONData; const Default: string): string;
  begin
    if (D = nil) or D.IsNull then Exit(Default);
    case D.JSONType of
      jtString:
        Result := D.AsString;
      jtNumber:
        Result := D.AsJSON;
      jtBoolean:
        if D.AsBoolean then Result := 'true' else Result := 'false';
    else
      Result := Default;
    end;
  end;

  function ObjGetStr(const Obj: TJSONObject; const AName: string;
    const Default: string): string;
  begin
    Result := SafeStr(Obj.Find(AName), Default);
  end;

  function ObjGetFloat(const Obj: TJSONObject; const AName: string;
    Default: Single): Single;
  begin
    Result := SafeFloat(Obj.Find(AName), Default);
  end;

  function ObjGetInt(const Obj: TJSONObject; const AName: string;
    Default: Integer): Integer;
  begin
    Result := SafeInt(Obj.Find(AName), Default);
  end;

  function GetFloatPath(const Obj: TJSONObject; const Path: string;
    Default: Single): Single;
  var
    Parts: TStringList;
    CurObj: TJSONObject;
    JData: TJSONData;
    J: Integer;
  begin
    Result := Default;
    Parts := TStringList.Create;
    try
      Parts.Delimiter := '.';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := Path;
      CurObj := Obj;
      for J := 0 to Parts.Count - 2 do
      begin
        if not CurObj.Find(Parts[J], JData) then Exit;
        if not (JData is TJSONObject) then Exit;
        CurObj := JData as TJSONObject;
      end;
      if CurObj.Find(Parts[Parts.Count - 1], JData) then
        Result := SafeFloat(JData, Default);
    finally
      Parts.Free;
    end;
  end;

  function GetStrPath(const Obj: TJSONObject; const Path: string;
    Default: string): string;
  var
    Parts: TStringList;
    CurObj: TJSONObject;
    JData: TJSONData;
    J: Integer;
  begin
    Result := Default;
    Parts := TStringList.Create;
    try
      Parts.Delimiter := '.';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := Path;
      CurObj := Obj;
      for J := 0 to Parts.Count - 2 do
      begin
        if not CurObj.Find(Parts[J], JData) then Exit;
        if not (JData is TJSONObject) then Exit;
        CurObj := JData as TJSONObject;
      end;
      if CurObj.Find(Parts[Parts.Count - 1], JData) then
        Result := SafeStr(JData, Default);
    finally
      Parts.Free;
    end;
  end;

  function GetFloatFallback(const Obj: TJSONObject;
    const Path1, Path2: string; Default: Single): Single;
  begin
    Result := GetFloatPath(Obj, Path1, Default);
    if Result = Default then
      Result := GetFloatPath(Obj, Path2, Default);
  end;

  function IsNonNull(const Obj: TJSONObject; const Key: string): Boolean;
  var
    JData: TJSONData;
  begin
    Result := Obj.Find(Key, JData) and (not JData.IsNull);
  end;

  function GetLengthMm(const Obj: TJSONObject; const Path: string;
    Default: Single): Single;
  var
    UnitPath, UnitStr: string;
  begin
    Result := GetFloatPath(Obj, Path, Default);
    if Result <> Default then
    begin
      UnitPath := Path + '_unit';
      UnitStr := GetStrPath(Obj, UnitPath, 'mm');
      if LowerCase(UnitStr) = 'cm' then
        Result := Result * 10
      else if LowerCase(UnitStr) = 'in' then
        Result := Result * 25.4;
    end;
  end;

  function GetLengthMmFallback(const Obj: TJSONObject;
    const Path1, Path2: string; Default: Single): Single;
  begin
    Result := GetLengthMm(Obj, Path1, Default);
    if Result = Default then
      Result := GetLengthMm(Obj, Path2, Default);
  end;

var
  SL: TStringList;
  JsonData: TJSONData;
  Apollo, Obj, GeoObj, BaseBuildObj, DiagObj: TJSONObject;
  JData, DiagData: TJSONData;
  Key: string;
  I: Integer;
  Geo: TBikeGeometryData;
  FirstBuildFound: Boolean;
  DiagStr: string;
  HTTopY, HTBotY, TTJctY, DTJctY, HTPxLen: Single;
  Fn: string;
begin
  Result := False;
  ModelInfo := Default(TBikeModelInfo);
  Geometries := TBikeGeometryList.Create;

  Fn := ResolveInsightsFilename(FileName);
  if (Fn = '') or (not FileExists(Fn)) then Exit;

  SL := TStringList.Create;
  JsonData := nil;
  try
    try
    SL.LoadFromFile(Fn);
    JsonData := GetJSON(SL.Text);
    if not (JsonData is TJSONObject) then Exit;
    JData := (JsonData as TJSONObject).FindPath('props.apolloState');
    if (JData = nil) or not (JData is TJSONObject) then Exit;
    Apollo := JData as TJSONObject;
    FirstBuildFound := False;

    for I := 0 to Apollo.Count - 1 do
    begin
      Key := Apollo.Names[I];
      if not (Apollo.Items[I] is TJSONObject) then Continue;
      Obj := Apollo.Items[I] as TJSONObject;

      if (Copy(Key, 1, 5) = 'Bike:') and (Length(Key) < 40) then
      begin
        ModelInfo.BikeName := ObjGetStr(Obj, 'name', '');
      end;

      if Copy(Key, 1, 6) = 'Brand:' then
        ModelInfo.BrandName := ObjGetStr(Obj, 'name', '');

      if (Copy(Key, 1, 12) = 'BikeVersion:') and (ModelInfo.VersionName = '') then
        ModelInfo.VersionName := ObjGetStr(Obj, 'name', '');

      if (Copy(Key, 1, 10) = 'BikeBuild:') and (not FirstBuildFound) then
      begin
        FirstBuildFound := True;
        ModelInfo.BuildName := ObjGetStr(Obj, 'name', '');
        ModelInfo.BarType := ObjGetStr(Obj, 'bar_type', '');
        { Bike Insights calls a MTB riser bar "moto". It belongs to the
          flat-bar geometry path, including its shorter cockpit. }
        if SameText(ModelInfo.BarType,'moto')then ModelInfo.BarType:='flat';
        ModelInfo.SuspensionType := ObjGetStr(Obj, 'suspension_type', '');
        ModelInfo.ForkTravel := GetLengthMm(Obj, 'fork_travel', 0);
        ModelInfo.RearTravel := GetLengthMm(Obj, 'rear_travel', 0);
        ModelInfo.FixedGear:=SameText(ObjGetStr(Obj,'drivetrain_type',''),'fixed');
        ModelInfo.ChainringTeeth:=ObjGetInt(Obj,'chainring_teeth',0);
        ModelInfo.RearSprocketTeeth:=ObjGetInt(Obj,'sprocket_teeth',0);
      end;

      if Copy(Key, 1, 13) = 'BikeCategory:' then
        if ObjGetInt(Obj, 'level', 0) = 3 then
          ModelInfo.CategoryName := ObjGetStr(Obj, 'name', '');

      if Copy(Key, 1, 13) = 'BikeGeometry:' then
      begin
        GeoObj := Obj;
        Geo := Default(TBikeGeometryData);
        Geo.Size := ObjGetStr(GeoObj, 'size', '');

        Geo.HeadTubeAngle := GetFloatFallback(GeoObj,
          'frame.head_tube_angle', 'calculated.frame.head_tube_angle', 0);
        Geo.SeatTubeAngle := GetFloatFallback(GeoObj,
          'frame.seat_tube_angle', 'calculated.frame.seat_tube_angle', 0);
        Geo.ChainstayLength := GetLengthMmFallback(GeoObj,
          'frame.chainstay_length', 'calculated.frame.chainstay_length', 0);
        Geo.Wheelbase := GetLengthMmFallback(GeoObj,
          'frame.wheelbase', 'calculated.frame.wheelbase', 0);

        Geo.BBDrop := GetLengthMmFallback(GeoObj,
          'frame.bottom_bracket_drop', 'calculated.frame.bottom_bracket_drop', 0);

        Geo.Stack := GetLengthMmFallback(GeoObj,
          'frame.stack', 'calculated.frame.stack', 0);
        Geo.Reach := GetLengthMmFallback(GeoObj,
          'frame.reach', 'calculated.frame.reach', 0);

        Geo.SeatTubeLength := GetLengthMm(GeoObj,
          'frame.seat_tube_length_center_st_top', 0);
        if Geo.SeatTubeLength = 0 then
          Geo.SeatTubeLength := GetLengthMm(GeoObj,
            'calculated.frame.seat_tube_length_center_st_top', 0);
        if Geo.SeatTubeLength = 0 then
          Geo.SeatTubeLength := GetLengthMm(GeoObj,
            'frame.seat_tube_length_center_center', 0);
        if Geo.SeatTubeLength = 0 then
          Geo.SeatTubeLength := GetLengthMm(GeoObj,
            'calculated.frame.seat_tube_length_center_center', 0);
        if Geo.SeatTubeLength = 0 then
          Geo.SeatTubeLength := GetLengthMm(GeoObj,
            'frame.seat_tube_length_unknown', 0);
        if Geo.SeatTubeLength = 0 then
          Geo.SeatTubeLength := GetLengthMm(GeoObj,
            'calculated.frame.seat_tube_length_unknown', 0);

        Geo.HeadTubeLength := GetLengthMmFallback(GeoObj,
          'frame.head_tube_length', 'calculated.frame.head_tube_length', 0);

        Geo.EffectiveTopTubeLength := GetLengthMm(GeoObj,
          'frame.effective_top_tube_length_center_center', 0);
        if Geo.EffectiveTopTubeLength = 0 then
          Geo.EffectiveTopTubeLength := GetLengthMm(GeoObj,
            'calculated.frame.effective_top_tube_length_center_center', 0);
        if Geo.EffectiveTopTubeLength = 0 then
          Geo.EffectiveTopTubeLength := GetLengthMm(GeoObj,
            'frame.effective_top_tube_length_unknown', 0);

        Geo.ForkRake := GetLengthMmFallback(GeoObj,
          'fork.offset', 'calculated.fork.offset', 0);
        Geo.ForkAxleToCrown := GetLengthMm(GeoObj,
          'fork.axle_to_crown_distance', 0);
        if Geo.ForkAxleToCrown = 0 then
          Geo.ForkAxleToCrown := GetLengthMm(GeoObj,
            'calculated.fork.axle_to_crown_distance', 0);
        if Geo.ForkAxleToCrown = 0 then
          Geo.ForkAxleToCrown := GetLengthMm(GeoObj, 'fork.length_unknown', 0);
        if Geo.ForkAxleToCrown = 0 then
          Geo.ForkAxleToCrown := GetLengthMm(GeoObj, 'calculated.fork.length', 0);
        if Geo.ForkAxleToCrown = 0 then
          Geo.ForkAxleToCrown := GetLengthMm(GeoObj, 'fork.length', 0);

        Geo.TopTubeSlope := GetFloatFallback(GeoObj,
          'calculated.frame.top_tube_slope', 'frame.top_tube_slope', 0);
        Geo.SeatTubeLengthToTT := GetLengthMm(GeoObj,
          'frame.seat_tube_length_center_tt_top', 0);
        if Geo.SeatTubeLengthToTT = 0 then
          Geo.SeatTubeLengthToTT := GetLengthMm(GeoObj,
            'calculated.frame.seat_tube_length_center_tt_top', 0);

        Geo.HasJunctionRatios := False;
        Geo.TopTubeHTRatio := 0;
        Geo.DownTubeHTRatio := 0;
        DiagStr := GetStrPath(GeoObj, 'calculated.diagram_calcs', '');
        if DiagStr <> '' then
        begin
          DiagData := nil;
          try
            try
              DiagData := GetJSON(DiagStr);
            except
              DiagData := nil;
            end;
            if DiagData is TJSONObject then
            begin
              DiagObj := DiagData as TJSONObject;
              HTTopY  := GetFloatPath(DiagObj, 'headTubeTop.cy', 0);
              HTBotY  := GetFloatPath(DiagObj, 'headTubeBottom.cy', 0);
              TTJctY  := GetFloatPath(DiagObj, 'headTubeTopTubeIntersection.cy', 0);
              DTJctY  := GetFloatPath(DiagObj, 'headTubeDownTubeIntersection.cy', 0);
              HTPxLen := HTBotY - HTTopY;
              if HTPxLen > 1 then
              begin
                Geo.TopTubeHTRatio  := (TTJctY - HTTopY) / HTPxLen;
                Geo.DownTubeHTRatio := (HTBotY - DTJctY) / HTPxLen;
                Geo.HasJunctionRatios := True;
              end;
            end;
          finally
            DiagData.Free;
          end;
        end;

        Geo.StemLength := GetLengthMmFallback(GeoObj,
          'base_build.stem_length', 'calculated.base_build.stem_length', 0);
        if GeoObj.Find('base_build', JData) and (JData is TJSONObject) then
        begin
          BaseBuildObj := JData as TJSONObject;
          if IsNonNull(BaseBuildObj, 'stem_angle') then
          begin
            Geo.StemAngle := ObjGetFloat(BaseBuildObj, 'stem_angle', 0.0);
            Geo.StemAngleValid := True;
          end;
        end;

        Geo.CrankLength := GetLengthMmFallback(GeoObj,
          'base_build.crank_length', 'calculated.base_build.crank_length', 0);
        if Geo.CrankLength = 0 then
          Geo.CrankLength := GetLengthMm(GeoObj, 'calculated.fit.crank_length', 0);

        Geo.HandlebarWidth := GetLengthMmFallback(GeoObj,
          'base_build.handlebar_width', 'calculated.base_build.handlebar_width', 0);
        Geo.WheelBSD := GetLengthMmFallback(GeoObj,
          'base_build.wheel_bsd', 'calculated.base_build.wheel_bsd', 0);

        Geo.TireWidth := GetLengthMmFallback(GeoObj,
          'base_build.tire_width', 'calculated.base_build.tire_width', 0);
        Geo.TireOuterDiameter := GetLengthMmFallback(GeoObj,
          'base_build.tire_outer_diameter', 'calculated.base_build.tire_outer_diameter', 0);

        if (Geo.HeadTubeAngle > 0) and
           ((Geo.Wheelbase > 0) or ((Geo.Stack > 0) and (Geo.Reach > 0))) then
          Geometries.Add(Geo);
      end;
    end;
    Result := Geometries.Count > 0;
    except
      FreeAndNil(Geometries);
      raise;
    end;
  finally
    JsonData.Free;
    SL.Free;
  end;
end;

function LooksLikeCrankSize(const S: string): Boolean;
var
  T: string;
begin
  T := LowerCase(Trim(S));
  Result := (Length(T) >= 2) and (Copy(T, Length(T) - 1, 2) = 'mm');
end;

function CollectInsightSizes(Geometries: TBikeGeometryList;
  ASizes: TStrings): Integer;
var
  Unique: TStringList;
  Geo: TBikeGeometryData;
begin
  Result := 0;
  if ASizes = nil then Exit;
  ASizes.Clear;
  if Geometries = nil then Exit;
  Unique := TStringList.Create;
  try
    Unique.Sorted := True;
    Unique.Duplicates := dupIgnore;
    for Geo in Geometries do
      if (Geo.Size <> '') and (not LooksLikeCrankSize(Geo.Size)) then
        Unique.Add(Geo.Size);
    { some dumps only label geometries with crank length — keep those }
    if Unique.Count = 0 then
      for Geo in Geometries do
        if Geo.Size <> '' then
          Unique.Add(Geo.Size);
    ASizes.Assign(Unique);
    Result := ASizes.Count;
  finally
    Unique.Free;
  end;
end;

function FindInsightGeometry(Geometries: TBikeGeometryList;
  const ASize: string; out Geo: TBikeGeometryData): Boolean;
var
  Item: TBikeGeometryData;
begin
  Result := False;
  Geo := Default(TBikeGeometryData);
  if Geometries = nil then Exit;
  if ASize <> '' then
    for Item in Geometries do
      if SameText(Item.Size, ASize) then
      begin
        Geo := Item;
        Exit(True);
      end;
  if Geometries.Count > 0 then
  begin
    Geo := Geometries[0];
    Exit(True);
  end;
end;

procedure ApplyGeometryToBikeInstance(Inst: TBikeInstance;
  const Geo: TBikeGeometryData; const Info: TBikeModelInfo);
var
  FrameComp: TFrameComponent;
  ForkComp: TForkComponent;
  WheelComp: TWheelComponent;
  SeatComp: TSeatComponent;
  CrankComp: TCranksetComponent;
  DriveComp:TDrivetrainComponent;
  DropBar: TDropBarComponent;
  FlatBar: TFlatBarComponent;
  WantFlat, HaveFlat: Boolean;
  Comps: TBikeComponentClassArray;
  SinHA: Single;
  BikePreset:string;
begin
  if Inst = nil then Exit;

  WantFlat := SameText(Info.BarType, 'flat');
  BikePreset:='road';
  if WantFlat then BikePreset:='mtb' else if Info.FixedGear then BikePreset:='fixed';
  HaveFlat := Inst.BarType = btFlat;
  if WantFlat then
    Comps := MTBComponents
  else
    Comps := RoadBikeComponents;
  if WantFlat <> HaveFlat then
    Inst.EnsureComponents(Comps);

  FrameComp := TFrameComponent(Inst.Component(TFrameComponent));
  ForkComp  := TForkComponent(Inst.Component(TForkComponent));
  WheelComp := TWheelComponent(Inst.Component(TWheelComponent));
  SeatComp  := TSeatComponent(Inst.Component(TSeatComponent));
  CrankComp := TCranksetComponent(Inst.Component(TCranksetComponent));
  DriveComp := TDrivetrainComponent(Inst.Component(TDrivetrainComponent));
  DropBar   := TDropBarComponent(Inst.Component(TDropBarComponent));
  FlatBar   := TFlatBarComponent(Inst.Component(TFlatBarComponent));

  if CrankComp<>nil then CrankComp.ApplyPreset(BikePreset);
  if DriveComp<>nil then begin
    DriveComp.ApplyPreset(BikePreset);
    if Info.FixedGear and(Info.RearSprocketTeeth>=8)then
      DriveComp.CassetteTeeth[0]:=EnsureRange(Info.RearSprocketTeeth,8,32);
  end;
  if DropBar<>nil then DropBar.ShowHoods:=not Info.FixedGear;
  if ForkComp<>nil then begin
    ForkComp.ForkAxleToCrown:=DEF_FORK_AXLE_TO_CROWN;
    ForkComp.ForkRake:=DEF_FORK_RAKE;ForkComp.StemLength:=100;ForkComp.StemAngle:=7;
    if WantFlat then begin ForkComp.StemLength:=50;ForkComp.StemAngle:=0 end;
    if Info.ForkTravel>0 then ForkComp.ForkAxleToCrown:=410+Info.ForkTravel;
  end;
  if WheelComp<>nil then begin
    WheelComp.WheelRadius:=DEF_WHEEL_RADIUS;WheelComp.TireWidth:=DEF_TIRE_WIDTH;
    WheelComp.FrontRimHeight:=30;WheelComp.RearRimHeight:=30;WheelComp.SpokeCount:=16;
    if WantFlat then begin
      WheelComp.WheelRadius:=368;WheelComp.TireWidth:=29;
      WheelComp.FrontRimHeight:=20;WheelComp.RearRimHeight:=20;WheelComp.SpokeCount:=28;
    end;
    if Info.FixedGear then WheelComp.SpokeCount:=24;
  end;

  if ForkComp <> nil then
    ForkComp.ForkTravel := Info.ForkTravel;
  if FrameComp <> nil then
    FrameComp.RearTravel := Info.RearTravel;

  if FrameComp <> nil then
  begin
    FrameComp.HeadTubeAngle := Geo.HeadTubeAngle;
    FrameComp.SeatTubeAngle := Geo.SeatTubeAngle;
    FrameComp.ChainstayLength := Geo.ChainstayLength;
    FrameComp.Wheelbase := Geo.Wheelbase;
    FrameComp.BBDrop := Geo.BBDrop;
    FrameComp.Stack := Geo.Stack;
    FrameComp.Reach := Geo.Reach;
    FrameComp.EffectiveTopTubeLength := Geo.EffectiveTopTubeLength;
    if Geo.SeatTubeLength > 0 then
      FrameComp.SeatTubeLength := Geo.SeatTubeLength;
    if Geo.HeadTubeLength > 0 then FrameComp.HeadTubeLength := Geo.HeadTubeLength;
    FrameComp.TopTubeHTRatio:=0.15;FrameComp.DownTubeHTRatio:=0.20;
    FrameComp.TopTubeSeatRatio:=0.97;FrameComp.TopTubeSlope:=0;
    if Geo.HasJunctionRatios then
    begin
      if Geo.TopTubeHTRatio > 0 then
        FrameComp.TopTubeHTRatio := Geo.TopTubeHTRatio;
      if Geo.DownTubeHTRatio > 0 then
        FrameComp.DownTubeHTRatio := Geo.DownTubeHTRatio;
    end;
    if Geo.TopTubeSlope > 0 then
      FrameComp.TopTubeSlope := Geo.TopTubeSlope;
    if (Geo.SeatTubeLengthToTT > 0) and (Geo.SeatTubeLength > 0) then
      FrameComp.TopTubeSeatRatio := Geo.SeatTubeLengthToTT / Geo.SeatTubeLength;
  end;

  if ForkComp <> nil then
  begin
    if Geo.ForkRake > 0 then
      ForkComp.ForkRake := Geo.ForkRake;
    if Geo.ForkAxleToCrown > 0 then
      ForkComp.ForkAxleToCrown := Geo.ForkAxleToCrown;
    if Geo.StemLength > 0 then
      ForkComp.StemLength := Geo.StemLength;
    if Geo.StemAngleValid then
      ForkComp.StemAngle := Geo.StemAngle;
    if(FrameComp<>nil)and(Geo.HeadTubeLength<=0)and(Geo.Stack>0)then begin
      { Stack is measured from the bottom bracket, not from the ground. }
      SinHA:=Sin(DegToRad(Geo.HeadTubeAngle));
      if SinHA>0.01 then FrameComp.HeadTubeLength:=Max(20,
        (Geo.Stack-Geo.BBDrop+ForkComp.ForkRake*Cos(DegToRad(Geo.HeadTubeAngle)))/SinHA-ForkComp.ForkAxleToCrown);
    end;
  end;

  if WheelComp <> nil then
  begin
    if Geo.TireOuterDiameter > 0 then
      WheelComp.WheelRadius := Geo.TireOuterDiameter / 2
    else if (Geo.WheelBSD > 0) and (Geo.TireWidth > 0) then
      WheelComp.WheelRadius := (Geo.WheelBSD + Geo.TireWidth * 2) / 2
    else if Geo.WheelBSD > 0 then
      WheelComp.WheelRadius := (Geo.WheelBSD + 56) / 2;
    if Geo.TireWidth > 0 then
      WheelComp.TireWidth := Geo.TireWidth / 2;
  end;

  if (Geo.CrankLength > 0) and (CrankComp <> nil) then
    CrankComp.CrankLength := Geo.CrankLength;
  if(CrankComp<>nil)and(Info.ChainringTeeth>=20)then
    CrankComp.ChainringTeeth:=EnsureRange(Info.ChainringTeeth,20,64);

  if Geo.HandlebarWidth > 0 then
  begin
    if FlatBar <> nil then
      FlatBar.FlatBarWidth := Geo.HandlebarWidth;
    if DropBar <> nil then
      DropBar.BarWidth := Geo.HandlebarWidth;
  end;

  if WantFlat then
  begin
    if CrankComp <> nil then
      CrankComp.QFactorHalf := MTB_QFACTOR_HALF;
    if FrameComp <> nil then
    begin
      FrameComp.DownTubeDia := 44;
      FrameComp.SeatTubeDia := 34;
      FrameComp.TopTubeDia := 32;
      FrameComp.HeadTubeDia := 56;
      FrameComp.ChainstayDia := 24;
      FrameComp.SeatstayDia := 16;
      FrameComp.BBShellWidth := 73;
      FrameComp.RearDropoutSpacing := 148;
      FrameComp.FrontDropoutSpacing := 110;
    end;
    if ForkComp <> nil then
    begin
      ForkComp.ForkBladeDia := 36;
      ForkComp.ForkTipDia := 20;
      ForkComp.StemDia := 28;
    end;
    if SeatComp <> nil then
      SeatComp.SeatpostDia := 31.6;
  end
  else
  begin
    if CrankComp <> nil then
      CrankComp.QFactorHalf := ROAD_QFACTOR_HALF;
    if FrameComp <> nil then
    begin
      FrameComp.DownTubeDia := 36;
      FrameComp.SeatTubeDia := 32;
      FrameComp.TopTubeDia := 30;
      FrameComp.HeadTubeDia := 44;
      FrameComp.ChainstayDia := 20;
      FrameComp.SeatstayDia := 14;
      FrameComp.BBShellWidth := 68;
      FrameComp.RearDropoutSpacing := 130;
      FrameComp.FrontDropoutSpacing := 100;
      if Info.FixedGear then FrameComp.RearDropoutSpacing:=120;
    end;
    if ForkComp <> nil then
    begin
      ForkComp.ForkBladeDia := 20;
      ForkComp.ForkTipDia := 14;
      ForkComp.StemDia := 24;
    end;
    if SeatComp <> nil then
      SeatComp.SeatpostDia := 24;
  end;

  { Preset is a component-layout key in serialized bikes, not a caption. }
  Inst.Preset := BikePreset;

  if WantFlat <> HaveFlat then
    Inst.BuildWithLOD(Comps, Inst.LastBuildColors, nil, 15, 40, 80)
  else
    Inst.RebuildAllWithLOD(15, 40, 80);
end;

function ApplyInsightsFileToBikeInstance(Inst: TBikeInstance;
  const FileName, ASize: string): Boolean;
var
  Info: TBikeModelInfo;
  Geos: TBikeGeometryList;
  Geo: TBikeGeometryData;
begin
  Result := False;
  if Inst = nil then Exit;
  Geos := nil;
  try
    if not ExtractBikeInsights(FileName, Info, Geos) then Exit;
    if not FindInsightGeometry(Geos, ASize, Geo) then Exit;
    ApplyGeometryToBikeInstance(Inst, Geo, Info);
    Result := True;
  finally
    Geos.Free;
  end;
end;

procedure ReadFitAdjustments(Inst: TBikeInstance;
  out SeatExt, SaddleOffset, Spacers, StemLen: Single);
var
  Seat: TSeatComponent;
  Fork: TForkComponent;
begin
  SeatExt := 150;
  SaddleOffset := 0;
  Spacers := 20;
  StemLen := 100;
  if Inst = nil then Exit;
  Seat := TSeatComponent(Inst.Component(TSeatComponent));
  Fork := TForkComponent(Inst.Component(TForkComponent));
  if Seat <> nil then
  begin
    SeatExt := Seat.SeatpostExtension;
    SaddleOffset := Seat.SaddleOffset;
  end;
  if Fork <> nil then
  begin
    Spacers := Fork.HeadsetSpacer;
    StemLen := Fork.StemLength;
  end;
end;

procedure ApplyFitAdjustments(Inst: TBikeInstance;
  SeatExt, SaddleOffset, Spacers, StemLen: Single);
var
  Seat: TSeatComponent;
  Fork: TForkComponent;
begin
  if Inst = nil then Exit;
  Seat := TSeatComponent(Inst.Component(TSeatComponent));
  Fork := TForkComponent(Inst.Component(TForkComponent));
  if Seat <> nil then
  begin
    Seat.SeatpostExtension := SeatExt;
    Seat.SaddleOffset := SaddleOffset;
  end;
  if Fork <> nil then
  begin
    Fork.HeadsetSpacer := Spacers;
    Fork.StemLength := StemLen;
  end;
  Inst.RebuildGroup(BSG_FRAME, True);
end;

procedure ReadFrameStackReach(Inst: TBikeInstance;
  out StackMm, ReachMm: Single);
var
  Frame: TFrameComponent;
begin
  StackMm := 0;
  ReachMm := 0;
  if Inst = nil then Exit;
  Frame := TFrameComponent(Inst.Component(TFrameComponent));
  if Frame = nil then Exit;
  StackMm := Frame.Stack;
  ReachMm := Frame.Reach;
end;

end.
