unit GameControllerGears;
{$mode objfpc}{$H+}
interface
uses TrainerData;
type
  TControllerGearCursor=record
    Generation,Serial:Cardinal;
  end;
procedure PrimeControllerGears(var Cursor:TControllerGearCursor;const Data:TTrainerDataRecord);
function ConsumeControllerGears(var Cursor:TControllerGearCursor;
  const Data:TTrainerDataRecord;Gear,MaxGear:Integer):Integer;
implementation
uses Math;
procedure PrimeControllerGears(var Cursor:TControllerGearCursor;const Data:TTrainerDataRecord);
begin Cursor.Generation:=Data.ControllerGeneration;Cursor.Serial:=Data.ControllerSerial end;
function ConsumeControllerGears(var Cursor:TControllerGearCursor;
  const Data:TTrainerDataRecord;Gear,MaxGear:Integer):Integer;
var Count,I:Cardinal;
begin
  Result:=Gear;
  if not(tmController in Data.ValidMetrics) or(Data.ControllerGeneration=0) then Exit;
  if Cursor.Generation<>Data.ControllerGeneration then begin
    Cursor.Generation:=Data.ControllerGeneration;Cursor.Serial:=0;
  end;
  if Data.ControllerSerial<Cursor.Serial then begin
    { Reset/wrap: never replay a whole prior connection. }
    Cursor.Serial:=Data.ControllerSerial;Exit;
  end;
  Count:=Min(Cardinal(Length(Data.ControllerActions)),Data.ControllerSerial-Cursor.Serial);
  if Count>0 then for I:=Count downto 1 do
    Result:=EnsureRange(Result+Data.ControllerActions[(Data.ControllerSerial-I) mod 16],1,MaxGear);
  Cursor.Serial:=Data.ControllerSerial;
end;
end.
