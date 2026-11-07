{ OpenBikeControl GATT protocol: an open button protocol for handlebar
  controllers and bridges such as BikeControl. Specification:
  https://github.com/OpenBikeControl/openbikecontrol-protocol
  Button notifications are [$01, id, state, id, state...] and carry only the
  buttons that changed, so pressed state is kept for the whole connection. }
unit OpenBikeControlProtocol;
{$mode objfpc}{$H+}
interface
uses SysUtils, TrainerData, GameSteeringInput;
const
  OpenBikeControlServiceUUID='d273f680-d548-419d-b9d1-fa0472345229';
  OpenBikeControlButtonUUID='d273f681-d548-419d-b9d1-fa0472345229';
  OpenBikeControlAppInfoUUID='d273f683-d548-419d-b9d1-fa0472345229';
type
  TOpenBikeControlParser = class
  private
    FEdge: TSteeringEdge;
    FSerial: Cardinal;
    FDirection: ShortInt;
    FShiftUp,FShiftDown,FLeft,FRight,FHaveAngle:Boolean;
    FAngle:Single;
    FJournal, FSnapshot:TTrainerDataRecord;
    procedure RecordShift(Direction:ShortInt);
  public
    constructor Create;
    procedure Reset;
    function Snapshot: TTrainerDataRecord;
    function Parse(const Bytes: TBytes; out Data: TTrainerDataRecord): Boolean;
  end;
{ App Information message: app id, version and the button ids handled here. }
function OpenBikeControlAppInfo: TBytes;
{ Use one controller input protocol per peripheral. Native services retain
  priority, including a trainer's native virtual-gearing handshake. }
function PreferOpenBikeControl(HasObc, HasZwift, HasSterzo: Boolean): Boolean;
procedure DiscoverOpenBikeControl(var Device: TDeviceInfo; const Services: String);
implementation
uses EliteSterzoProtocol, GameBuildInfo;
function PreferOpenBikeControl(HasObc, HasZwift, HasSterzo: Boolean): Boolean;
begin
  Result := HasObc and not (HasZwift or HasSterzo);
end;

procedure DiscoverOpenBikeControl(var Device: TDeviceInfo; const Services: String);
begin
  if Pos(OpenBikeControlServiceUUID, LowerCase(Services)) = 0 then Exit;
  Device.SupportsShifting := True;
  Device.SupportsSteering := True;
end;

function TOpenBikeControlParser.Snapshot: TTrainerDataRecord;
begin
  Result := FSnapshot;
  Result.PresentMetrics := Result.ValidMetrics;
end;

const
  ShiftUpButton=$01; ShiftDownButton=$02;
  SteerLeftButton=$18; SteerRightButton=$19; SteeringAngleButton=$1B;

function OpenBikeControlAppInfo: TBytes;
const AppId='rezvivo';
  Buttons: array[0..4] of Byte=(ShiftUpButton,ShiftDownButton,
    SteerLeftButton,SteerRightButton,SteeringAngleButton);
var Version:String; P,I:Integer;
begin
  Result:=nil; Version:=Copy(ClientVersion,1,32);
  SetLength(Result,5+Length(AppId)+Length(Version)+Length(Buttons));
  Result[0]:=$04;Result[1]:=$01;Result[2]:=Length(AppId);P:=3;
  for I:=1 to Length(AppId) do begin Result[P]:=Ord(AppId[I]);Inc(P) end;
  Result[P]:=Length(Version);Inc(P);
  for I:=1 to Length(Version) do begin Result[P]:=Ord(Version[I]);Inc(P) end;
  Result[P]:=Length(Buttons);Inc(P);
  for I:=0 to High(Buttons) do begin Result[P]:=Buttons[I];Inc(P) end;
end;
constructor TOpenBikeControlParser.Create;
begin inherited;Reset end;
procedure TOpenBikeControlParser.Reset;
begin
  FEdge.Reset;FSerial:=0;FDirection:=0;
  FShiftUp:=False;FShiftDown:=False;FLeft:=False;FRight:=False;
  FHaveAngle:=False;FAngle:=0;
  FJournal:=Default(TTrainerDataRecord);
  FSnapshot:=Default(TTrainerDataRecord);
  FJournal.ControllerGeneration:=NextControllerGeneration;
end;
procedure TOpenBikeControlParser.RecordShift(Direction:ShortInt);
begin
  if FJournal.ControllerSerial=High(Cardinal) then begin
    FJournal.ControllerSerial:=0;
    FJournal.ControllerGeneration:=NextControllerGeneration;
  end;
  FJournal.ControllerActions[FJournal.ControllerSerial mod 16]:=Direction;
  Inc(FJournal.ControllerSerial);
end;
function TOpenBikeControlParser.Parse(const Bytes:TBytes;out Data:TTrainerDataRecord):Boolean;
var P,Turn:Integer; Id,State:Byte; Pressed,HaveShift,HaveSteering:Boolean; Angle:Single;
begin
  Result:=False; Data:=Default(TTrainerDataRecord);
  if (Length(Bytes)<3) or (Length(Bytes)>512) or not Odd(Length(Bytes)) then Exit;
  if Bytes[0]<>$01 then Exit;
  HaveShift:=False; HaveSteering:=False; P:=1;
  while P<High(Bytes) do
  begin
    Id:=Bytes[P]; State:=Bytes[P+1]; Inc(P,2);
    Pressed:=State<>0;
    case Id of
      ShiftUpButton: begin
        if Pressed and not FShiftUp then RecordShift(1);
        FShiftUp:=Pressed; HaveShift:=True;
      end;
      ShiftDownButton: begin
        if Pressed and not FShiftDown then RecordShift(-1);
        FShiftDown:=Pressed; HaveShift:=True;
      end;
      SteerLeftButton: begin FLeft:=Pressed; HaveSteering:=True end;
      SteerRightButton: begin FRight:=Pressed; HaveSteering:=True end;
      SteeringAngleButton: begin
        { $00 = angle unavailable, $01/$FF = no-op, else 0.5 deg steps
          around $80, clockwise positive like STERZO. }
        if State=0 then FHaveAngle:=False
        else if State in [$02..$FE] then begin FAngle:=(State-$80)*0.5; FHaveAngle:=True end;
        HaveSteering:=True;
      end;
    end;
  end;
  if not HaveShift and not HaveSteering then Exit;
  BeginTrainerPacket(Data);
  if HaveSteering then
  begin
    { A calibrated angle wins over Steer Left/Right from the same device. }
    if FHaveAngle then Angle:=FAngle
    else Angle:=(Ord(FRight)-Ord(FLeft))*SterzoRangeDegrees;
    Turn:=FEdge.Update(SteeringAxis(Angle));
    if Turn<>0 then
    begin
      if FSerial=High(Cardinal) then FSerial:=1 else Inc(FSerial);
      FDirection:=Turn;
    end;
    Data.SteeringAngle:=Angle;
    Data.SteeringTurnSerial:=FSerial;
    Data.SteeringTurnDirection:=FDirection;
    MarkTrainerMetric(Data,tmSteering);
  end;
  if HaveShift then begin
    Data.ControllerGeneration:=FJournal.ControllerGeneration;
    Data.ControllerSerial:=FJournal.ControllerSerial;
    Data.ControllerActions:=FJournal.ControllerActions;
    MarkTrainerMetric(Data,tmController);
  end;
  MergeTrainerData(FSnapshot,Data);
  Result:=True;
end;
end.
