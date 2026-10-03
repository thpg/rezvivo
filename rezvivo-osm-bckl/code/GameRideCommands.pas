unit GameRideCommands;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses CastleKeysMouse,CastleUIControls;
type TRideCommand=(rcPause,rcSkip,rcPowerDown,rcPowerUp,rcFocus);
const RideCommandTitles:array[TRideCommand]of String=
  ('Pause / resume','Skip interval','−5 W','+5 W','Training focus');
function RideCommandKey(Command:TRideCommand):TKey;
function SetRideCommandKey(Command:TRideCommand;Key:TKey):Boolean;
function MatchRideCommand(const Event:TInputPressRelease;out Command:TRideCommand):Boolean;
function ExecuteRideCommand(Command:TRideCommand):Boolean;
procedure ResetRideCommandKeys;
function UserInterfaceScale:Single;
procedure ApplyUserInterfaceScale(Container:TCastleContainer);
implementation
uses SysUtils,Math,GameUserData,GameWorkoutPlayer;
const Keys:array[TRideCommand]of String=('ride_pause','ride_skip','ride_power_down','ride_power_up','ride_focus');
  Defaults:array[TRideCommand]of TKey=(keySpace,keyPageDown,keyLeftBracket,keyRightBracket,keyF4);

function RideCommandKey(Command:TRideCommand):TKey;
begin Result:=StrToKey(UserPreferences.Get(Keys[Command],KeyToStr(Defaults[Command])),Defaults[Command]);end;

function SetRideCommandKey(Command:TRideCommand;Key:TKey):Boolean;
var C:TRideCommand;
begin
  { Keep navigation, text editing and existing ride / camera controls intact. }
  Result:=Key in[keySpace,keyPageUp,keyPageDown,keyHome,keyEnd,keyInsert,keyDelete,
    keyLeftBracket,keyRightBracket,keyF3,keyF4,keyF6,keyF7,keyF8,
    keyF,keyG,keyH,keyI,keyJ,keyK,keyM,keyN,keyT,keyU,keyX,keyY,keyZ,key0..key9];
  if not Result then Exit;
  for C:=Low(C)to High(C)do if(C<>Command)and(RideCommandKey(C)=Key)then Exit(False);
  UserPreferences.Strings[Keys[Command]]:=KeyToStr(Key);SaveUserPreferences;
end;

procedure ResetRideCommandKeys;
var C:TRideCommand;
begin for C:=Low(C)to High(C)do UserPreferences.Delete(Keys[C]);SaveUserPreferences;end;

function MatchRideCommand(const Event:TInputPressRelease;out Command:TRideCommand):Boolean;
var C:TRideCommand;
begin
  Result:=False;Command:=rcPause;
  for C:=Low(C)to High(C)do if Event.IsKey(RideCommandKey(C),[])then begin Command:=C;Exit(True);end;
end;

function ExecuteRideCommand(Command:TRideCommand):Boolean;
begin
  Result:=False;
  if WorkoutPlayer.State in[wsIdle,wsFinished]then Exit;
  case Command of
    rcPause:if WorkoutPlayer.State=wsPaused then WorkoutPlayer.Resume else WorkoutPlayer.Pause;
    rcSkip:WorkoutPlayer.Skip;
    rcPowerDown:WorkoutPlayer.ChangeReferenceWatts(-5);
    rcPowerUp:WorkoutPlayer.ChangeReferenceWatts(5);
    else Exit;
  end;
  Result:=True;
end;

function UserInterfaceScale:Single;
begin
  Result:=EnsureRange(UserPreferences.Get('interface_scale',100),100,150)/100;
end;

procedure ApplyUserInterfaceScale(Container:TCastleContainer);
var Scale:Single;
begin
  if Container=nil then Exit;
  Scale:=UserInterfaceScale;
  Container.UIScaling:=usEncloseReferenceSize;
  Container.UIReferenceWidth:=1600/Scale;Container.UIReferenceHeight:=900/Scale;
end;
end.
