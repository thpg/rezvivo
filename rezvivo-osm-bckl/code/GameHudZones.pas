unit GameHudZones;

{$mode objfpc}{$H+}

interface

uses CastleColors;

type
  TZoneBounds = array of Single;

{ Server maxima are inclusive. The final zero denotes an open-ended zone. }
function ZoneAt(const Value: Double; const Bounds: TZoneBounds): Integer;
function ZonePosition(const Value: Double; const Bounds: TZoneBounds): Single;
function ReadZoneBounds(const Json, Key: String): TZoneBounds;
function TrainingZoneColor(const Index, Count: Integer): TCastleColor;

implementation

uses SysUtils, Math, fpjson, jsonparser, CastleVectors;

function ZonePosition(const Value: Double; const Bounds: TZoneBounds): Single;
var I: Integer; Lower,Upper,LastSpan: Double;
begin
  Result:=NaN;
  if IsNan(Value) or IsInfinite(Value) or (Value<0) or (Length(Bounds)=0) then Exit;
  Lower:=0; LastSpan:=1;
  for I:=0 to High(Bounds) do
  begin
    Upper:=Bounds[I];
    // Extend the open final zone by the previous zone's width, then saturate.
    if Upper=0 then Upper:=Lower+LastSpan;
    if Upper<=Lower then Exit;
    if (Value<=Upper) or (I=High(Bounds)) then
      Exit(I-0.5+EnsureRange((Value-Lower)/(Upper-Lower),0.0,1.0));
    LastSpan:=Upper-Lower; Lower:=Upper;
  end;
end;

function ZoneAt(const Value: Double; const Bounds: TZoneBounds): Integer;
var I: Integer;
begin
  Result:=-1;
  if IsNan(Value) or IsInfinite(Value) or (Value<0) then Exit;
  for I:=0 to High(Bounds) do
    if (Bounds[I]=0) or (Value<=Bounds[I]) then Exit(I);
  // HR above the highest configured bound still belongs to the highest zone.
  if Length(Bounds)>0 then Result:=High(Bounds);
end;

function ReadZoneBounds(const Json, Key: String): TZoneBounds;
var Root,Group,Item,MaxValue: TJSONData; I,N,Previous,V: Integer;
begin
  Result:=nil; Root:=nil;
  if Json='' then Exit;
  try
    try
      Root:=GetJSON(Json);
      if not (Root is TJSONObject) then Exit;
      Group:=TJSONObject(Root).Find(Key);
      if not (Group is TJSONArray) then Exit;
      N:=Group.Count;
      if (N<2) or (N>10) then Exit;
      SetLength(Result,N); Previous:=0;
      for I:=0 to N-1 do
      begin
        Item:=Group.Items[I];
        if not (Item is TJSONObject) then begin Result:=nil; Exit end;
        MaxValue:=TJSONObject(Item).Find('max');
        if (MaxValue=nil) or (MaxValue.JSONType<>jtNumber) then begin Result:=nil; Exit end;
        V:=MaxValue.AsInteger;
        if MaxValue.AsFloat<>V then begin Result:=nil; Exit end;
        if not ((Key='power') and (I=N-1) and (V=0)) then
          if (V<=Previous) or ((Key='heart_rate') and (V>250)) or (V>1000) then
          begin Result:=nil; Exit end;
        Result[I]:=V; Previous:=V;
      end;
      if (Key='power') and (Result[N-1]<>0) then Result:=nil;
    except
      on E: Exception do Result:=nil;
    end;
  finally Root.Free end;
end;

function TrainingZoneColor(const Index, Count: Integer): TCastleColor;
const Palette: array[0..6] of TVector4 = (
  (X:0.52;Y:0.56;Z:0.60;W:1), (X:0.18;Y:0.48;Z:0.92;W:1),
  (X:0.12;Y:0.74;Z:0.88;W:1), (X:0.22;Y:0.78;Z:0.40;W:1),
  (X:0.98;Y:0.78;Z:0.20;W:1), (X:0.98;Y:0.43;Z:0.15;W:1),
  (X:0.90;Y:0.22;Z:0.29;W:1));
var P,F: Single; A,B: Integer;
begin
  P:=EnsureRange(Index/Max(Count-1,1)*6,0.0,6.0);
  A:=Floor(P); B:=Min(6,A+1); F:=P-A;
  Result:=Palette[A]*(1-F)+Palette[B]*F;
end;

end.
