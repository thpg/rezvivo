unit CyclingRevolutions;
{$mode objfpc}{$H+}
interface
uses SysUtils, Math;
type
  { One tracker per source characteristic/counter. BLE CPS wheel time uses
    2048 Hz; BLE CSC and ANT speed/cadence use 1024 Hz. }
  TRevolutionTracker = record
    Initialized: Boolean;
    PreviousRevs: Cardinal;
    PreviousTime: Word;
    LastChangeMs, TimeoutMs: QWord;
    Rate: Single;
  end;
function RevolutionRate(var State: TRevolutionTracker; Revs: Cardinal;
  EventTime: Word; TimeHz: Integer; Counter16: Boolean;
  MaxRevsPerSecond: Single; TickMs: QWord = 0): Single;
implementation
function RevolutionRate(var State: TRevolutionTracker; Revs: Cardinal;
  EventTime: Word; TimeHz: Integer; Counter16: Boolean;
  MaxRevsPerSecond: Single; TickMs: QWord): Single;
var DR: QWord; DT: Cardinal; NewRate: Double;
begin
  if TickMs=0 then TickMs:=GetTickCount64;
  if not State.Initialized then
  begin
    State.Initialized:=True;
    State.PreviousRevs:=Revs;
    State.PreviousTime:=EventTime;
    State.LastChangeMs:=TickMs;
    State.TimeoutMs:=3000;
    State.Rate:=0;
    Exit(0);
  end;
  if Counter16 then DR:=(QWord(Revs)+$10000-State.PreviousRevs) and $FFFF
  else DR:=(QWord(Revs)+QWord($100000000)-State.PreviousRevs) and $FFFFFFFF;
  DT:=(Cardinal(EventTime)+$10000-State.PreviousTime) and $FFFF;
  if (DR<>0) or (DT<>0) then
  begin
    State.PreviousRevs:=Revs;
    State.PreviousTime:=EventTime;
    if (DR>0) and (DT>0) then
    begin
      NewRate:=DR*Double(TimeHz)/DT;
      if NewRate<=MaxRevsPerSecond then
      begin
        State.Rate:=NewRate;
        State.LastChangeMs:=TickMs;
        State.TimeoutMs:=Max(3000,Round(2000/NewRate));
      end
      else State.Rate:=0; { reset/corrupt counter, never a power/speed spike }
    end;
  end;
  if TickMs-State.LastChangeMs>=State.TimeoutMs then State.Rate:=0;
  Result:=State.Rate;
end;
end.
