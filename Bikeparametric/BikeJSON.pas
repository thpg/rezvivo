{
  JSON serialization / deserialization for TBikeBuilder.

  SaveBikeToJSON   — serialize TBikeBuilder state to a JSON string
  LoadBikeFromJSON — create a new TBikeBuilder from a JSON string

  Component classes are stored by their ComponentName string and
  resolved through a registry.  Call RegisterBikeComponent for any
  custom components before loading.

  License: MIT
}
unit BikeJSON;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser,
  CastleVectors,
  BikeParametric;

{ Save the full builder state to a JSON string.
  Includes Preset, TBikeColors, component class list,
  and per-component params. }
function SaveBikeToJSON(Builder: TBikeBuilder): string;

{ Create a new TBikeBuilder from a JSON string.
  Caller owns the returned builder and must free it.
  Raises an exception if a component class name is unknown. }
function LoadBikeFromJSON(const AJSON: string): TBikeBuilder;

{ Parse only the header of an already-parsed bike JSON root object:
  "params" → APreset (default 'road'), "colors" → AColors (default
  DefaultBikeColors). This is everything LoadBikeFromJSON extracts besides
  the per-component dispatch — but no component instances are constructed.
  For pipelines that feed component params straight into a TBikeInstance
  (TBikeInstance.AssignComponentStateFromJSON). }
procedure ParseBikeHeaderJSON(Root: TJSONObject;
  out APreset: string; out AColors: TBikeColors);

{ Register a component class so LoadBikeFromJSON can find it by name.
  All built-in components are registered automatically at unit init. }
procedure RegisterBikeComponent(AClass: TBikeComponentClass);

{ Find a registered component class by its ComponentName.
  Returns nil if not found. }
function FindBikeComponentClass(const AName: string): TBikeComponentClass;

{ Canonical JSON number text: strictly digits, optional leading '-', '.'
  as the decimal separator. Never an exponent, never a locale comma, never
  NaN/Inf (those become '0'), no float-precision tails: the value is
  rounded to 6 decimals and trailing zeros are stripped
  (0.10000000149 -> "0.1", -30.0 -> "-30").
  Registered for ALL fpjson float nodes at unit initialization, so every
  AsJSON / FormatJSON in the program emits numbers in this form. }
function CleanJSONFloatStr(const V: Double): string;

implementation

uses
  Math,
  GameMath,
  BikeParametric_Frame,
  BikeParametric_Fork,
  BikeParametric_DropBar,
  BikeParametric_FlatBar,
  BikeParametric_Seat,
  BikeParametric_Wheel,
  BikeParametric_Crankset,
  BikeParametric_Drivetrain,
  BikeParametric_Animation;

{ ═══════════════════════════════════════════════════════════════════
  Component class registry
  ═══════════════════════════════════════════════════════════════════ }

var
  GRegistry: array of TBikeComponentClass;

procedure RegisterBikeComponent(AClass: TBikeComponentClass);
var I: Integer;
begin
  { Avoid duplicates }
  for I := 0 to High(GRegistry) do
    if GRegistry[I] = AClass then Exit;
  SetLength(GRegistry, Length(GRegistry) + 1);
  GRegistry[High(GRegistry)] := AClass;
end;

function FindBikeComponentClass(const AName: string): TBikeComponentClass;
var I: Integer;
begin
  for I := 0 to High(GRegistry) do
    if GRegistry[I].ComponentName = AName then
      Exit(GRegistry[I]);
  Result := nil;
end;

{ ═══════════════════════════════════════════════════════════════════
  Canonical float formatting for ALL fpjson output
  ═══════════════════════════════════════════════════════════════════ }

function CleanJSONFloatStr(const V: Double): string;
var
  FS: TFormatSettings;
begin
  { junk values must never reach a file: they would either break the parser
    (NaN/Inf are not valid JSON) or poison the loaded state }
  if IsNan(V) or IsInfinite(V) then Exit('0');
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';      { locale-proof: never a comma }
  FS.ThousandSeparator := #0;
  { '0.######' = plain decimal, max 6 fraction digits, trailing zeros
    stripped, never exponent notation. 6 decimals: a micron for metre
    values and 1e-6 for coefficients — beyond Single precision anyway,
    which is exactly what kills the 0.10000000149 tails. }
  Result := FormatFloat('0.######', V, FS);
  if Result = '-0' then Result := '0';
end;

type
  { fpjson float node with the canonical text form above; registered via
    SetJSONInstanceType so the parser AND every Add(..., Double)/CreateJSON
    produce this class — one switch cleans every file the program writes. }
  TCleanJSONFloat = class(TJSONFloatNumber)
  protected
    function GetAsString: TJSONStringType; override;
  end;

function TCleanJSONFloat.GetAsString: TJSONStringType;
begin
  Result := CleanJSONFloatStr(AsFloat);
end;

{ ═══════════════════════════════════════════════════════════════════
  JSON helpers — Vec3ToJSON and JSONToVec3 moved to GameMath.pas;
  call sites below resolve to GameMath via the uses clause above.
  ═══════════════════════════════════════════════════════════════════ }

procedure WriteStr(Obj: TJSONObject; const Key: string; const Val: string);
begin
  Obj.Add(Key, Val);
end;

procedure WriteVec3(Obj: TJSONObject; const Key: string; const Val: TVector3);
begin
  Obj.Add(Key, Vec3ToJSON(Val));
end;

function ReadStr(Obj: TJSONObject; const Key: string; const Def: string): string;
var D: TJSONData;
begin
  D := Obj.Find(Key);
  if (D <> nil) and (D.JSONType = jtString) then Result := D.AsString else Result := Def;
end;

function ReadVec3(Obj: TJSONObject; const Key: string; const Def: TVector3): TVector3;
var D: TJSONData;
begin
  D := Obj.Find(Key);
  if (D <> nil) and (D is TJSONArray) then
    Result := JSONToVec3(TJSONArray(D))
  else
    Result := Def;
end;

{ ═══════════════════════════════════════════════════════════════════
  Builder.Preset → JSON "params" object

  TBikeParams is gone; the only field that still serialises at this
  top level is Preset (owned by TBikeBuilder). DetailLevel is runtime,
  not persisted. Legacy SuspensionType is ignored on read and no longer
  written. BarType is derived from the component list.
  ═══════════════════════════════════════════════════════════════════ }

function ParamsToJSON(const APreset: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  WriteStr(Result, 'Preset', APreset);
end;

{ ═══════════════════════════════════════════════════════════════════
  JSON "params" object → preset string out-param
  ═══════════════════════════════════════════════════════════════════ }

procedure JSONToParams(Obj: TJSONObject; out APreset: string);
begin
  APreset := ReadStr(Obj, 'Preset', 'road');
  { Legacy keys (SuspensionType, BarType, and every flat-format rider /
    spine / physics key that used to live here) are silently ignored —
    components now read their own sub-object in 'components'. }
end;

{ ═══════════════════════════════════════════════════════════════════
  TBikeColors ↔ JSON
  ═══════════════════════════════════════════════════════════════════ }

function ColorsToJSON(const C: TBikeColors): TJSONObject;
begin
  Result := TJSONObject.Create;
  WriteVec3(Result, 'Frame', C.Frame);
  WriteVec3(Result, 'FrameSpec', C.FrameSpec);
  WriteVec3(Result, 'Chrome', C.Chrome);
  WriteVec3(Result, 'ChromeSpec', C.ChromeSpec);
  WriteVec3(Result, 'Dark', C.Dark);
  WriteVec3(Result, 'Tire', C.Tire);
  WriteVec3(Result, 'Seat', C.Seat);
  WriteVec3(Result, 'Tape', C.Tape);
  WriteVec3(Result, 'Spoke', C.Spoke);
  WriteVec3(Result, 'Rim', C.Rim);
  WriteVec3(Result, 'RimSpec', C.RimSpec);
  WriteVec3(Result, 'TireSpec', C.TireSpec);
end;

procedure JSONToColors(Obj: TJSONObject; out C: TBikeColors);
begin
  C := DefaultBikeColors;
  if Obj = nil then Exit;
  C.Frame := ReadVec3(Obj, 'Frame', C.Frame);
  C.FrameSpec := ReadVec3(Obj, 'FrameSpec', C.FrameSpec);
  C.Chrome := ReadVec3(Obj, 'Chrome', C.Chrome);
  C.ChromeSpec := ReadVec3(Obj, 'ChromeSpec', C.ChromeSpec);
  C.Dark := ReadVec3(Obj, 'Dark', C.Dark);
  C.Tire := ReadVec3(Obj, 'Tire', C.Tire);
  C.Seat := ReadVec3(Obj, 'Seat', C.Seat);
  C.Tape := ReadVec3(Obj, 'Tape', C.Tape);
  C.Spoke := ReadVec3(Obj, 'Spoke', C.Spoke);
  C.Rim := ReadVec3(Obj, 'Rim', C.Rim);
  C.RimSpec := ReadVec3(Obj, 'RimSpec', C.RimSpec);
  C.TireSpec := ReadVec3(Obj, 'TireSpec', C.TireSpec);
end;

{ ═══════════════════════════════════════════════════════════════════
  SaveBikeToJSON
  ═══════════════════════════════════════════════════════════════════ }

{ Post-process FormatJSON output: collapse scientific-notation floats
  (e.g. "1.7500000000000000E+003") into plain decimals ("1750"). Walks the
  string once; preserves JSON string literals verbatim. }
function PrettifyFloats(const S: string): string;
var
  I, N, Start: Integer;
  Buf: string;
  V: Double;
  InString: Boolean;
  Fmt: TFormatSettings;
  SB: TStringBuilder;
begin
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  Fmt.ThousandSeparator := #0;
  SB := TStringBuilder.Create(Length(S));
  try
    InString := False;
    I := 1;
    N := Length(S);
    while I <= N do
    begin
      if S[I] = '"' then begin
        InString := not InString;
        SB.Append(S[I]); Inc(I); Continue;
      end;
      if InString then begin
        if (S[I] = '\') and (I < N) then begin
          SB.Append(S[I]); SB.Append(S[I+1]); Inc(I, 2); Continue;
        end;
        SB.Append(S[I]); Inc(I); Continue;
      end;
      { Try to scan a number: optional '-' then digits, optional .digits,
        optional E±digits. We only rewrite when '.' or 'E' is present — plain
        integers pass through unchanged. }
      if (S[I] in ['0'..'9']) or
         ((S[I] = '-') and (I < N) and (S[I+1] in ['0'..'9'])) then
      begin
        Start := I;
        if S[I] = '-' then Inc(I);
        while (I <= N) and (S[I] in ['0'..'9']) do Inc(I);
        if (I <= N) and (S[I] = '.') then begin
          Inc(I);
          while (I <= N) and (S[I] in ['0'..'9']) do Inc(I);
        end;
        if (I <= N) and ((S[I] = 'E') or (S[I] = 'e')) then begin
          Inc(I);
          if (I <= N) and (S[I] in ['+', '-']) then Inc(I);
          while (I <= N) and (S[I] in ['0'..'9']) do Inc(I);
        end;
        Buf := Copy(S, Start, I - Start);
        if (Pos('.', Buf) > 0) or (Pos('E', UpperCase(Buf)) > 0) then
        begin
          try
            V := StrToFloat(Buf, Fmt);
            Buf := FloatToStrF(V, ffGeneral, 7, 0, Fmt);
          except
            { Unparseable — leave original text as-is. }
          end;
        end;
        SB.Append(Buf);
      end
      else begin
        SB.Append(S[I]); Inc(I);
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function SaveBikeToJSON(Builder: TBikeBuilder): string;
var
  Root, ParamsObj, ColorsObj, CompsObj, OneCompObj: TJSONObject;
  I: Integer;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('version', 2);

    { Params — only Preset persists at this top level (DetailLevel is
      runtime; TBikeParams is gone). }
    ParamsObj := ParamsToJSON(Builder.Preset);
    Root.Add('params', ParamsObj);

    { Colors }
    ColorsObj := ColorsToJSON(Builder.Colors);
    Root.Add('colors', ColorsObj);

    { Components — each gets its own sub-object keyed by ComponentName.
      Order is preserved by TJSONObject. }
    CompsObj := TJSONObject.Create;
    for I := 0 to Builder.ComponentCount - 1 do
    begin
      OneCompObj := TJSONObject.Create;
      Builder.Components[I].ParamsToJSON(OneCompObj);
      CompsObj.Add(Builder.Components[I].ComponentName, OneCompObj);
    end;
    Root.Add('components', CompsObj);

    Result := PrettifyFloats(Root.FormatJSON);
  finally
    Root.Free;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════
  LoadBikeFromJSON
  ═══════════════════════════════════════════════════════════════════ }

procedure ParseBikeHeaderJSON(Root: TJSONObject;
  out APreset: string; out AColors: TBikeColors);
var
  D: TJSONData;
begin
  { Params — only Preset; default 'road'. }
  APreset := 'road';
  D := Root.Find('params');
  if (D <> nil) and (D is TJSONObject) then
    JSONToParams(TJSONObject(D), APreset);

  { Colors }
  D := Root.Find('colors');
  if (D <> nil) and (D is TJSONObject) then
    JSONToColors(TJSONObject(D), AColors)
  else
    AColors := DefaultBikeColors;
end;

function LoadBikeFromJSON(const AJSON: string): TBikeBuilder;
var
  RootData: TJSONData;
  Builder: TBikeBuilder;
  Root, CompsObj, OneCompObj: TJSONObject;
  I: Integer;
  Preset: string;
  C: TBikeColors;
  CompClasses: TBikeComponentClassArray;
  CompNames: array of string;
  CC: TBikeComponentClass;
  CompName: string;
  D: TJSONData;
begin
  Builder := nil;
  RootData := GetJSON(AJSON);
  try
    if not (RootData is TJSONObject) then
      raise Exception.Create('Bike JSON root must be an object');
    Root := TJSONObject(RootData);
    ParseBikeHeaderJSON(Root, Preset, C);

    { Components — v2 format: object mapping ComponentName → params sub-object.
      (Legacy v1 array-of-names format is not supported for loading.) }
    CompsObj := nil;
    D := Root.Find('components');
    if (D <> nil) and (D is TJSONObject) then
    begin
      CompsObj := TJSONObject(D);
      SetLength(CompClasses, CompsObj.Count);
      SetLength(CompNames, CompsObj.Count);
      for I := 0 to CompsObj.Count - 1 do
      begin
        CompName := CompsObj.Names[I];
        if not (CompsObj.Items[I] is TJSONObject) then
          raise Exception.CreateFmt('Parameters for component "%s" must be an object', [CompName]);
        CC := FindBikeComponentClass(CompName);
        if CC = nil then
          raise Exception.CreateFmt('Unknown component class: "%s"', [CompName]);
        CompClasses[I] := CC;
        CompNames[I]   := CompName;
      end;
    end
    else begin
      CompClasses := RoadBikeComponents;
      SetLength(CompNames, Length(CompClasses));
      for I := 0 to High(CompClasses) do
        CompNames[I] := CompClasses[I].ComponentName;
    end;

    Builder := TBikeBuilder.Create(CompClasses);
    Builder.Preset := Preset;
    Builder.Colors := C;

    { Dispatch ParamsFromJSON per-component, passing each its own sub-object.
      CompsObj уже найден выше — повторный Root.Find('components') не нужен. }
    if CompsObj <> nil then
    begin
      for I := 0 to Builder.ComponentCount - 1 do
      begin
        OneCompObj := TJSONObject(CompsObj.Find(CompNames[I]));
        if OneCompObj <> nil then
          Builder.Components[I].ParamsFromJSON(OneCompObj);
      end;
    end;

    Result := Builder;
    Builder := nil;                    { передать владение только после полного чтения }
  finally
    Builder.Free;
    RootData.Free;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════
  Auto-register all built-in components
  ═══════════════════════════════════════════════════════════════════ }

initialization
  { every fpjson float node in the program (parser + Add(Double) + CreateJSON)
    serializes via TCleanJSONFloat: digits + '.' only, no exponent/locale
    comma/precision tails, NaN/Inf -> 0 }
  SetJSONInstanceType(jitNumberFloat, TCleanJSONFloat);
  RegisterBikeComponent(TFrameComponent);
  RegisterBikeComponent(TForkComponent);
  RegisterBikeComponent(TDropBarComponent);
  RegisterBikeComponent(TFlatBarComponent);
  RegisterBikeComponent(TSeatComponent);
  RegisterBikeComponent(TWheelComponent);
  RegisterBikeComponent(TCranksetComponent);
  RegisterBikeComponent(TDrivetrainComponent);
  RegisterBikeComponent(TAnimationComponent);

end.
