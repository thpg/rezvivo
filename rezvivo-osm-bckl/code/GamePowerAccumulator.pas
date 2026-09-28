unit GamePowerAccumulator;

{$mode objfpc}{$H+}

interface

type
  { Time-weighted rolling power and mechanical work. Intervals with unchanged
    power coalesce, so storage follows sensor changes, not unlimited FPS. }
  TPowerAccumulator = class
  private
    type TInterval = record Duration, Watts: Double end;
    var FIntervals: array of TInterval;
      FHead,FCount: Integer;
      FDuration,FEnergy,FWork: Double;
    procedure ClearWindow;
    procedure Grow;
    function GetAverage: Double;
  public
    procedure Reset;
    procedure Step(const Watts, Seconds: Double; const Active, Valid: Boolean);
    property AveragePower: Double read GetAverage;
    property WorkJoules: Double read FWork;
    property SampleSeconds: Double read FDuration;
  end;

implementation

uses Math;

procedure TPowerAccumulator.ClearWindow;
begin
  FHead:=0; FCount:=0; FDuration:=0; FEnergy:=0;
end;

procedure TPowerAccumulator.Reset;
begin
  ClearWindow; FWork:=0;
end;

procedure TPowerAccumulator.Grow;
var NewItems: array of TInterval; I: Integer;
begin
  SetLength(NewItems,Max(32,Length(FIntervals)*2));
  for I:=0 to FCount-1 do NewItems[I]:=FIntervals[(FHead+I) mod Length(FIntervals)];
  FIntervals:=NewItems; FHead:=0;
end;

procedure TPowerAccumulator.Step(const Watts, Seconds: Double;
  const Active, Valid: Boolean);
var P,Dt,Remove: Double; Tail: Integer;
begin
  if not Active or not Valid or IsNan(Watts) or IsInfinite(Watts) then
  begin ClearWindow; Exit end;
  if IsNan(Seconds) or IsInfinite(Seconds) or (Seconds<=0) then Exit;
  P:=Max(0,Watts); FWork:=FWork+P*Seconds;
  Dt:=Seconds;
  if Dt>=3 then begin ClearWindow; Dt:=3 end;
  if Length(FIntervals)=0 then Grow;
  Tail:=(FHead+FCount-1+Length(FIntervals)) mod Length(FIntervals);
  if (FCount>0) and (FIntervals[Tail].Watts=P) then
    FIntervals[Tail].Duration:=FIntervals[Tail].Duration+Dt
  else
  begin
    if FCount=Length(FIntervals) then Grow;
    Tail:=(FHead+FCount) mod Length(FIntervals);
    FIntervals[Tail].Duration:=Dt; FIntervals[Tail].Watts:=P; Inc(FCount);
  end;
  FDuration:=FDuration+Dt; FEnergy:=FEnergy+P*Dt;
  while (FDuration>3) and (FCount>0) do
  begin
    Remove:=Min(FDuration-3,FIntervals[FHead].Duration);
    FIntervals[FHead].Duration:=FIntervals[FHead].Duration-Remove;
    FEnergy:=FEnergy-Remove*FIntervals[FHead].Watts;
    FDuration:=FDuration-Remove;
    if FIntervals[FHead].Duration<=1e-12 then
    begin FHead:=(FHead+1) mod Length(FIntervals); Dec(FCount) end;
  end;
end;

function TPowerAccumulator.GetAverage: Double;
begin
  if FDuration>0 then Result:=Max(0,FEnergy/FDuration) else Result:=0;
end;

end.
