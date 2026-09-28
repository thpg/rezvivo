{
  BikeGfxUtil — small shared graphics helpers for the parametric bike
  components.

  Removes byte-for-byte duplications:
    • PackRGB         — was copied in BikeParametric_DropBar / _FlatBar
    • ResolveTexURL   — was copied in BikeParametric_Crankset / _Drivetrain
                        (the two copies differed only by their log tag, which
                         is now an explicit parameter)
    • GNum            — was copied in BikeGpuSkin / BikeGpuSpin
    • RotateXYZ       — was copied in BikeParametric_Seat / _DropBar
    • ResolveModelURL — was copied in BikeParametric_Seat / _DropBar
    • LoadModelNode   — was TSeatComponent/TDropBarComponent.TryLoadModel
}
unit BikeGfxUtil;

{$mode objfpc}{$H+}

interface

uses
  CastleVectors, X3DNodes;

{ Unpack a 0xRRGGBB integer into a 0..1 linear RGB vector. }
function PackRGB(C: LongInt): TVector3;

{ Resolve a texture path to a CGE URL.
  Tries castle-data:/ first, then a plain file on disk; returns '' (and logs
  a not-found notice prefixed with Tag, e.g. '[Crankset] ') when neither
  exists. Pass '' as Tag to suppress the prefix. }
function ResolveTexURL(const Path, Tag: string): string;

{ Resolve a model filename to a URL: castle-data:/ first, then filesystem.
  Returns '' (without logging) when neither exists. }
function ResolveModelURL(const Path: string): string;

{ Format a Single as a GLSL numeric literal: '.' decimal separator and an
  explicit fraction/exponent so the text is never a bare integer. }
function GNum(V: Single): string;

const
  { BicycleAnkleFlexCurve shape constants: phase offsets of the two
    harmonics and the positive/negative half-wave peaks normalizing the
    sum to ±1. Single source for the CPU curve below AND its GLSL ports
    in BikeGpuSkin / BikeGpuSpin (emitted via GNum). }
  ANKLE_CURVE_PHASE1   = 310.0;
  ANKLE_CURVE_PHASE2   = 250.0;
  ANKLE_CURVE_POS_PEAK = 0.992690685;
  ANKLE_CURVE_NEG_PEAK = 1.182432177;

{ Anatomically plausible ankling: dorsi/plantarflexion varying with crank
  angle. }
function BicycleAnkleFlexCurve(const CrankDeg, MaxFlexDeg: Double): Double;

{ Rotate V about X, then Y, then Z (degrees) — matches the nested Rx/Ry/Rz
  transform nodes used when placing an external model. }
function RotateXYZ(const V: TVector3; RxDeg, RyDeg, RzDeg: Single): TVector3;

{ Shared resolve→LoadNode→log for external component models (glb):
  resolves Path via ResolveModelURL, loads it, and StartupLog's failures
  prefixed with Tag (e.g. '[Seat] '); What names the model in the not-found
  message (e.g. 'saddle model'). Returns nil on any failure.
  ResolvedURL returns the URL that was loaded ('' when nothing was). }
function LoadModelNode(const Path, Tag, What: string;
  out ResolvedURL: string): TX3DRootNode;

implementation

uses
  Classes, SysUtils, Math, CastleURIUtils, X3DLoad, DebugLog, BikeLog;

var
  GModelCache: TStringList; { URL → template TX3DRootNode, DeepCopy per use }

function PackRGB(C: LongInt): TVector3;
begin
  Result := Vector3(((C shr 16) and $FF) / 255.0,
                    ((C shr  8) and $FF) / 255.0,
                    ( C         and $FF) / 255.0);
end;

function ResolveTexURL(const Path, Tag: string): string;
begin
  if Path = '' then Exit('');
  if URIFileExists('castle-data:/' + Path) then
    Exit('castle-data:/' + Path);
  if FileExists(Path) then
    Exit(FilenameToURISafe(Path));
  Logger.Info(Tag + 'Texture not found: ' + Path);
  Result := '';
end;

function ResolveModelURL(const Path: string): string;
begin
  if Path = '' then Exit('');
  if URIFileExists('castle-data:/' + Path) then Exit('castle-data:/' + Path);
  if FileExists(Path) then Exit(FilenameToURISafe(Path));
  Result := '';
end;

function GNum(V: Single): string;
var FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := FloatToStrF(V, ffGeneral, 7, 4, FS);
  if (Pos('.', Result) = 0) and (Pos('E', Result) = 0) and (Pos('e', Result) = 0) then
    Result := Result + '.0';
end;

function BicycleAnkleFlexCurve(const CrankDeg, MaxFlexDeg: Double): Double;
var
  A, S: Double;
begin
  A := CrankDeg - 360.0 * Floor(CrankDeg / 360.0);
  if A < 0.0 then A := A + 360.0;
  S := Cos(DegToRad(A - ANKLE_CURVE_PHASE1)) + 0.25 * Cos(DegToRad(2.0 * (A - ANKLE_CURVE_PHASE2)));
  if S >= 0.0 then Result := MaxFlexDeg * (S / ANKLE_CURVE_POS_PEAK)
  else Result := MaxFlexDeg * (S / ANKLE_CURVE_NEG_PEAK);
end;

function RotateXYZ(const V: TVector3; RxDeg, RyDeg, RzDeg: Single): TVector3;
var rx, ry, rz, x, y, z, t: Single;
begin
  rx := DegToRad(RxDeg); ry := DegToRad(RyDeg); rz := DegToRad(RzDeg);
  x := V.X; y := V.Y; z := V.Z;
  t := y * Cos(rx) - z * Sin(rx);  z := y * Sin(rx) + z * Cos(rx);  y := t;   { about X }
  t := x * Cos(ry) + z * Sin(ry);  z := -x * Sin(ry) + z * Cos(ry); x := t;   { about Y }
  t := x * Cos(rz) - y * Sin(rz);  y := x * Sin(rz) + y * Cos(rz);  x := t;   { about Z }
  Result := Vector3(x, y, z);
end;

function LoadModelNode(const Path, Tag, What: string;
  out ResolvedURL: string): TX3DRootNode;
var
  Idx: Integer;
  Template: TX3DRootNode;
  Copied: TX3DNode;
begin
  Result := nil;
  ResolvedURL := ResolveModelURL(Path);
  if ResolvedURL = '' then begin
    StartupLog(Tag + What + ' not found: ' + Path);
    Exit;
  end;
  if GModelCache = nil then
  begin
    GModelCache := TStringList.Create;
    GModelCache.Sorted := True;
    GModelCache.Duplicates := dupIgnore;
  end;
  Idx := GModelCache.IndexOf(ResolvedURL);
  if Idx >= 0 then
    Template := TX3DRootNode(GModelCache.Objects[Idx])
  else
  begin
    Template := nil;
    try
      Template := LoadNode(ResolvedURL);
    except
      on E: Exception do begin
        StartupLog(Tag + 'LoadNode failed for ' + ResolvedURL + ': ' + E.Message);
        Template := nil;
      end;
    end;
    if Template = nil then
    begin
      StartupLog(Tag + 'LoadNode returned nil: ' + ResolvedURL);
      Exit;
    end;
    GModelCache.AddObject(ResolvedURL, Template);
  end;
  Copied := Template.DeepCopy;
  if Copied is TX3DRootNode then
    Result := TX3DRootNode(Copied)
  else
  begin
    Copied.Free;
    Result := nil;
  end;
end;

procedure FreeModelCache;
var
  I: Integer;
begin
  if GModelCache = nil then Exit;
  for I := 0 to GModelCache.Count - 1 do
    GModelCache.Objects[I].Free;
  FreeAndNil(GModelCache);
end;

initialization
finalization
  FreeModelCache;
end.
