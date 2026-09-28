unit Osm3dOsmTagUtils;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  SysUtils;

{ Deterministic Int64 hash with uniform distribution.
  Murmur-style finaliser mix. Used in PaletteIndex and jitter. }
function HashInt64(X: Int64): LongWord; inline;

{ TFormatSettings with DecimalSeparator='.' and ThousandSeparator=#0.
  Call instead of repeating this boilerplate in Parse functions. }
function InvariantFmt: TFormatSettings;

{ Normalize an OSM tag value for comparison: LowerCase + strip
  spaces, dashes, and underscores.  Use before matching colour names,
  material names, or other free-form tag values. }
function NormalizeTagValue(const S: string): string;

{ Parse a numeric value from an OSM tag into metres.

  Supported suffixes:
    no suffix     → multiplied by DefaultFactor
                    (1.0 for heights/widths; 0.001 for trunk-diameter in mm)
    'm'           → metres
    'cm'          → centimetres (×0.01)
    ' / "         → feet/inches (formats 5', 5'6", 12")
    'feet', 'ft'  → foot synonyms
  Separator may be '.' or ','; spaces are ignored.
  Returns 0 on error or empty string. }
function ParseOSMMeters(const S: string; DefaultFactor: Double = 1.0): Double;

implementation

function HashInt64(X: Int64): LongWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1599);{$ENDIF}
  X := X xor (X shr 30);
  X := X * Int64($BF58476D1CE4E5B5);
  X := X xor (X shr 27);
  X := X * Int64($94D049BB133111EB);
  X := X xor (X shr 31);
  Result := LongWord(X);
end;

function InvariantFmt: TFormatSettings;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1601);{$ENDIF}
  Result := DefaultFormatSettings;
  Result.DecimalSeparator  := '.';
  Result.ThousandSeparator := #0;
end;

function NormalizeTagValue(const S: string): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1602);{$ENDIF}
  Result := LowerCase(S);
  Result := StringReplace(Result, ' ',  '', [rfReplaceAll]);
  Result := StringReplace(Result, '-',  '', [rfReplaceAll]);
  Result := StringReplace(Result, '_',  '', [rfReplaceAll]);
end;

function ParseOSMMeters(const S: string; DefaultFactor: Double): Double;
var
  Str, BeforeQ, AfterQ: string;
  Feet, Inches: Double;
  P: Integer;
  Fmt: TFormatSettings;

  function SafeFloat(const Sv: string): Double;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1603);{$ENDIF}
    if not TryStrToFloat(Sv, Result, Fmt) then Result := 0;
  end;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1604);{$ENDIF}
  Result := 0;
  if S = '' then Exit;
  Fmt := InvariantFmt;
  Str := StringReplace(S,   ',',    '.', [rfReplaceAll]);
  Str := StringReplace(Str, ' ',    '',  [rfReplaceAll]);
  Str := StringReplace(Str, 'feet', '''', [rfReplaceAll]);
  Str := StringReplace(Str, 'ft',   '''', [rfReplaceAll]);
  { 'cm' before 'm', otherwise 'm' would consume the 'c' of 'cm'. }
  if Pos('cm', Str) > 0 then
  begin
    Result := SafeFloat(StringReplace(Str, 'cm', '', [rfReplaceAll])) * 0.01;
    Exit;
  end;
  if Pos('m', Str) > 0 then
  begin
    Result := SafeFloat(StringReplace(Str, 'm', '', [rfReplaceAll]));
    Exit;
  end;
  if Pos('''', Str) > 0 then
  begin
    P := Pos('''', Str);
    BeforeQ := Copy(Str, 1, P - 1);
    AfterQ  := StringReplace(Copy(Str, P + 1, Length(Str)), '"', '', [rfReplaceAll]);
    Feet   := SafeFloat(BeforeQ);
    Inches := SafeFloat(AfterQ);
    Result := (Feet * 12 + Inches) * 0.0254;
    Exit;
  end;
  if Pos('"', Str) > 0 then
  begin
    Result := SafeFloat(StringReplace(Str, '"', '', [rfReplaceAll])) * 0.0254;
    Exit;
  end;
  Result := SafeFloat(Str) * DefaultFactor;
end;

end.
