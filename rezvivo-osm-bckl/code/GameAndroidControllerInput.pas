{ Android controller events reach Pascal through the main-thread messaging
  queue. Preserve button edges even if press+release arrive in one frame. }
unit GameAndroidControllerInput;
{$mode objfpc}{$H+}
interface
uses Classes, CastleStringUtils, GameSteeringInput;
type
  TAndroidControllerInput=class
  private
    FAxis:Single;
    FAvailable:Boolean;
    FPendingTurn:Integer;
    FEdge:TSteeringEdge;
    function Receive(const Received:TCastleStringList;const Stream:TMemoryStream):Boolean;
  public
    constructor Create;
    destructor Destroy;override;
    function Read(out Axis:Single;out Turn:Integer):Boolean;
  end;
implementation
uses SysUtils{$ifdef ANDROID}, CastleMessaging{$endif};
constructor TAndroidControllerInput.Create;
begin
  inherited;
  {$ifdef ANDROID}Messaging.OnReceive.Add(@Receive);{$endif}
end;
destructor TAndroidControllerInput.Destroy;
begin
  {$ifdef ANDROID}Messaging.OnReceive.Remove(@Receive);{$endif}
  inherited;
end;
function TAndroidControllerInput.Receive(const Received:TCastleStringList;const Stream:TMemoryStream):Boolean;
var X,Edge:Integer;
begin
  Result:=(Received.Count=5) and (Received[0]='rezvivo-gamepad');
  if not Result then Exit;
  FAvailable:=Received[1]='1';
  if not TryStrToInt(Received[2],X) then X:=0;
  if FAvailable then
  begin
    FAxis:=GamepadSteeringAxis(X/10000,Received[3]='1',Received[4]='1');
    Edge:=FEdge.Update(FAxis);
    if Edge<>0 then FPendingTurn:=Edge;
  end else begin FAxis:=0; FPendingTurn:=0; FEdge.Reset end;
end;
function TAndroidControllerInput.Read(out Axis:Single;out Turn:Integer):Boolean;
begin
  Axis:=FAxis; Turn:=FPendingTurn; FPendingTurn:=0; Result:=FAvailable;
end;
end.
