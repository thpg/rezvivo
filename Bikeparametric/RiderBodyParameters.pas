unit RiderBodyParameters;

{$mode objfpc}{$H+}

{ One physical profile for the avatar editor, bike fit, local and remote riders.
  Sex is a continuous body-shape coordinate: 0 male, 1 female. Composition
  distributes visible tissue from soft (0) to muscular (1); it is not a
  measurement or estimate of a person's body-fat percentage. }
interface

uses Math, SysUtils, fpjson;

type
  TRiderBodyParameters = record
    Sex, HeightCm, WeightKg, Composition, InseamCm, ArmLengthCm, HeadShape: Single;
  end;

function DefaultRiderBody(const Sex: Single = 0): TRiderBodyParameters;
function NormalizeRiderBody(const Value: TRiderBodyParameters): TRiderBodyParameters;
function SameRiderBody(const A, B: TRiderBodyParameters): Boolean;
function ReadRiderBody(const O: TJSONObject;
  const Default: TRiderBodyParameters): TRiderBodyParameters;
function WriteRiderBody(const Value: TRiderBodyParameters): TJSONObject;
function RiderBodyArmCm(const Value: TRiderBodyParameters): Single;
function RiderBodyInseamCm(const Value: TRiderBodyParameters): Single;
procedure RiderBodyShapeWeights(const Value: TRiderBodyParameters;
  out Fat, Muscle, Lean: Single);

implementation

function SafeValue(const V, Lo, Hi, Fallback: Single): Single;
begin
  if IsNan(V) or IsInfinite(V) then Exit(Fallback);
  Result := EnsureRange(V, Lo, Hi);
end;

function DefaultRiderBody(const Sex: Single): TRiderBodyParameters;
begin
  Result.Sex := SafeValue(Sex, 0, 1, 0);
  Result.HeightCm := 180 - 10 * Result.Sex;
  Result.WeightKg := 75 - 11 * Result.Sex;
  Result.Composition := 0.5;
  Result.InseamCm := 0;
  Result.ArmLengthCm := 0;
  Result.HeadShape := Result.Sex;
end;

function NormalizeRiderBody(const Value: TRiderBodyParameters): TRiderBodyParameters;
begin
  Result := Value;
  Result.Sex := SafeValue(Value.Sex, 0, 1, 0);
  Result.HeightCm := SafeValue(Value.HeightCm, 130, 220, 178);
  Result.WeightKg := SafeValue(Value.WeightKg, 35, 180, 75);
  Result.Composition := SafeValue(Value.Composition, 0, 1, 0.5);
  Result.HeadShape := SafeValue(Value.HeadShape, 0, 1, Result.Sex);
  if (Value.InseamCm = 0) or IsNan(Value.InseamCm) or IsInfinite(Value.InseamCm) then
    Result.InseamCm := 0
  else Result.InseamCm := SafeValue(Value.InseamCm,
    Result.HeightCm * 0.36, Result.HeightCm * 0.58, 0);
  if (Value.ArmLengthCm = 0) or IsNan(Value.ArmLengthCm) or IsInfinite(Value.ArmLengthCm) then
    Result.ArmLengthCm := 0
  else Result.ArmLengthCm := SafeValue(Value.ArmLengthCm,
    Result.HeightCm * 0.24, Result.HeightCm * 0.40, 0);
end;

function SameRiderBody(const A, B: TRiderBodyParameters): Boolean;
begin
  Result := (Abs(A.Sex-B.Sex)<0.00001) and
    (Abs(A.HeightCm-B.HeightCm)<0.001) and (Abs(A.WeightKg-B.WeightKg)<0.001) and
    (Abs(A.Composition-B.Composition)<0.00001) and
    (Abs(A.InseamCm-B.InseamCm)<0.001) and (Abs(A.ArmLengthCm-B.ArmLengthCm)<0.001) and
    (Abs(A.HeadShape-B.HeadShape)<0.00001);
end;

function ReadRiderBody(const O: TJSONObject;
  const Default: TRiderBodyParameters): TRiderBodyParameters;
begin
  Result := Default;
  if O <> nil then
  begin
    Result.Sex := O.Get('sex', Double(Result.Sex));
    Result.HeightCm := O.Get('heightCm', Double(Result.HeightCm));
    Result.WeightKg := O.Get('weightKg', Double(Result.WeightKg));
    Result.Composition := O.Get('composition', Double(Result.Composition));
    Result.InseamCm := O.Get('inseamCm', Double(Result.InseamCm));
    Result.ArmLengthCm := O.Get('armLengthCm', Double(Result.ArmLengthCm));
    Result.HeadShape := O.Get('headShape', Double(Result.HeadShape));
  end;
  Result := NormalizeRiderBody(Result);
end;

function WriteRiderBody(const Value: TRiderBodyParameters): TJSONObject;
var P: TRiderBodyParameters;
begin
  P := NormalizeRiderBody(Value);
  Result := TJSONObject.Create;
  Result.Add('version', 1);
  Result.Add('sex', Double(P.Sex));
  Result.Add('heightCm', Double(P.HeightCm));
  Result.Add('weightKg', Double(P.WeightKg));
  Result.Add('composition', Double(P.Composition));
  Result.Add('inseamCm', Double(P.InseamCm));
  Result.Add('armLengthCm', Double(P.ArmLengthCm));
  Result.Add('headShape', Double(P.HeadShape));
end;

function RiderBodyArmCm(const Value: TRiderBodyParameters): Single;
begin
  Result := Value.ArmLengthCm;
  if Result <= 0 then Result := Value.HeightCm * 0.322;
end;

function RiderBodyInseamCm(const Value: TRiderBodyParameters): Single;
begin
  Result := Value.InseamCm;
  if Result <= 0 then Result := Value.HeightCm * 0.465;
end;

procedure RiderBodyShapeWeights(const Value: TRiderBodyParameters;
  out Fat, Muscle, Lean: Single);
var P: TRiderBodyParameters; ReferenceMass, Radius, Excess: Single;
begin
  P := NormalizeRiderBody(Value);
  { Calibrates an artistic shape, not a clinical body-composition estimate.
    Height and mass remain independent profile quantities. }
  ReferenceMass := (75-11*P.Sex) * Power(P.HeightCm / (180-10*P.Sex), 2.2);
  Radius := Sqrt(P.WeightKg / ReferenceMass);
  Excess := Max(0, Radius - 1);
  Fat := EnsureRange(Excess * (1 - P.Composition) / 0.35 +
    0.42 * (0.5 - P.Composition), -0.21, 1.4);
  Muscle := EnsureRange(Excess * P.Composition / 0.30 +
    0.48 * (P.Composition - 0.5), -0.24, 1.65);
  Lean := EnsureRange((1 - Radius) / 0.32, 0, 1.25);
end;

end.
