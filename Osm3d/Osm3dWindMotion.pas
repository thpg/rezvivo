unit Osm3dWindMotion;
{$mode objfpc}{$H+}{$modeswitch advancedrecords}
interface
uses CastleVectors;
type
  { One viewer observation per rendered frame, independent of simulation speed.
    SourceTime may be the real clock or the ride replay clock. }
  TVegetationWindClock = record
  private
    FValid, FFast: Boolean;
    FKey: PtrUInt;
    FFrame, FTick, FMoveTick: QWord;
    FPosition: TVector3;
    FTime, FSource: Double;
    FSpeed, FRate: Single;
  public
    procedure Observe(const Position:TVector3; Key:PtrUInt; Frame,Tick:QWord;
      SourceTime:Double; Enabled:Boolean);
    function Time:Double;
    function Speed:Single;
    function Rate:Single;
    function Fast:Boolean;
    function Valid:Boolean;
  end;
implementation
uses Math;

procedure TVegetationWindClock.Observe(const Position:TVector3;Key:PtrUInt;
  Frame,Tick:QWord;SourceTime:Double;Enabled:Boolean);
var Dt,MoveDt,Distance,Raw,Blend,OldRate,SourceDt:Double; Cut:Boolean;
begin
  if FValid and (Frame=FFrame) and (Key=FKey) then Exit;
  if not FValid then begin
    FValid:=True;FTime:=SourceTime;FRate:=1;FSource:=SourceTime;
    FKey:=Key;FFrame:=Frame;FTick:=Tick;FMoveTick:=Tick;FPosition:=Position;Exit;
  end;
  Cut:=(Key<>FKey) or (Tick<FTick) or (Tick-FTick>1000);
  Dt:=0;if not Cut then Dt:=Min(0.1,(Tick-FTick)*0.001);
  if not Cut and (Tick-FMoveTick>=50) then begin
    MoveDt:=(Tick-FMoveTick)*0.001;Distance:=(Position-FPosition).Length;
    Cut:=Distance>Max(12,MoveDt*80);
    if not Cut then begin
      Raw:=Distance/MoveDt;Blend:=1-Exp(-MoveDt/0.18);
      FSpeed:=FSpeed+(Raw-FSpeed)*Blend;
      if Raw<0.05 then FSpeed:=0;
    end;
    FMoveTick:=Tick;FPosition:=Position;
  end;
  if Cut then begin
    FSpeed:=0;FFast:=False;FMoveTick:=Tick;FPosition:=Position;
  end;
  if not Enabled then FFast:=False
  else if FSpeed>15/3.6 then FFast:=True
  else if FSpeed<13.5/3.6 then FFast:=False;
  OldRate:=FRate;
  if FFast then FRate:=Max(0,FRate-Dt*2.5)
  else FRate:=Min(1,FRate+Dt*2.5);
  SourceDt:=SourceTime-FSource;
  { A seek is an explicit discontinuity. A menu pause keeps the vegetation
    phase, so returning cannot abruptly straighten or jump the canopy. }
  if (SourceDt<0) or ((Abs(SourceDt)>1) and not Cut and not FFast) then FTime:=SourceTime
  else if not Cut then FTime:=FTime+Max(0,SourceDt)*(OldRate+FRate)*0.5;
  FSource:=SourceTime;FTick:=Tick;FFrame:=Frame;FKey:=Key;
end;
function TVegetationWindClock.Time:Double;
begin Result:=FTime;end;
function TVegetationWindClock.Speed:Single;
begin Result:=FSpeed;end;
function TVegetationWindClock.Rate:Single;
begin if FValid then Result:=FRate else Result:=1;end;
function TVegetationWindClock.Fast:Boolean;
begin Result:=FFast;end;
function TVegetationWindClock.Valid:Boolean;
begin Result:=FValid;end;
end.
