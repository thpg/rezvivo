{ Zwift controller plaintext GATT protocol (RideOn handshake).
  Primary protocol research:
  https://www.makinolo.com/blog/2023/10/08/connecting-to-zwift-play-controllers/
  https://www.makinolo.com/blog/2024/07/26/zwift-ride-protocol/
  Current firmware/field-3 format and plaintext handshake:
  https://github.com/OpenBikeControl/bikecontrol/tree/main/lib/bluetooth/devices/zwift
  This is an independent bounded protobuf decoder, not a firmware unlocker.
  Early encrypted Play firmware is deliberately rejected, never guessed. }
unit ZwiftControllerProtocol;
{$mode objfpc}{$H+}
interface
uses SysUtils, TrainerData, GameSteeringInput;
const
  ZwiftServiceUUID='00000001-19ca-4651-86e5-fa29dcdd09d1';
  ZwiftRideServiceUUID='0000fc82-0000-1000-8000-00805f9b34fb';
  ZwiftNotifyUUID='00000002-19ca-4651-86e5-fa29dcdd09d1';
  ZwiftWriteUUID='00000003-19ca-4651-86e5-fa29dcdd09d1';
  ZwiftResponseUUID='00000004-19ca-4651-86e5-fa29dcdd09d1';
type
  TZwiftHandshake = (zhNone,zhPlaintext,zhEncrypted);
  TZwiftControllerParser = class
  private
    FEdge: TSteeringEdge;
    FSerial: Cardinal;
    FDirection: ShortInt;
  public
    procedure Reset;
    function Parse(const Bytes: TBytes; out Data: TTrainerDataRecord): Boolean;
  end;
function IsZwiftControllerName(const Name: String): Boolean;
function ZwiftHandshakeRequest: TBytes;
function ZwiftHandshakeReply(const Bytes: TBytes): TZwiftHandshake;
implementation
uses Math;
function IsZwiftControllerName(const Name: String): Boolean;
var N: String;
begin
  N:=UpperCase(Trim(Name));
  Result:=(Pos('ZWIFT PLAY',N)=1) or (Pos('ZWIFT CLICK',N)=1) or
    (Pos('ZWIFT RIDE',N)=1) or (N='ZWIFT SF2') or (N='ZWIFT RC1') or (N='ZWIFT BC1');
end;
function ZwiftHandshakeRequest: TBytes;
begin Result:=TBytes.Create($52,$69,$64,$65,$4f,$6e) end;
function ZwiftHandshakeReply(const Bytes: TBytes): TZwiftHandshake;
var I: Integer; Header: TBytes;
begin
  Result:=zhNone; Header:=ZwiftHandshakeRequest;
  if Length(Bytes)<Length(Header) then Exit;
  for I:=0 to High(Header) do if Bytes[I]<>Header[I] then Exit;
  if Length(Bytes) in [6,8] then Result:=zhPlaintext
  else if Length(Bytes)=72 then Result:=zhEncrypted;
end;
{ Read a protobuf uint32 and reject overflow/truncation, including malformed
  lengths. All walks are bounded by the enclosing message. No recursive parse. }
function ReadVar(const B:TBytes; var P:Integer; Limit:Integer; out V:Cardinal):Boolean;
var I:Integer; X:Byte;
begin
  Result:=False; V:=0;
  for I:=0 to 4 do
  begin
    if P>=Limit then Exit;
    X:=B[P]; Inc(P);
    if (I=4) and (X>$0F) then Exit;
    V:=V or (Cardinal(X and $7F) shl (I*7));
    if X<$80 then Exit(True);
  end;
end;
function Field(const B:TBytes; var P:Integer; Limit:Integer;
  out Number,Wire:Cardinal; out V:Cardinal; out Start,Stop:Integer):Boolean;
var Tag,N:Cardinal;
begin
  Result:=False; Start:=P; Stop:=P; V:=0;
  if not ReadVar(B,P,Limit,Tag) or (Tag<8) then Exit;
  Number:=Tag shr 3; Wire:=Tag and 7;
  case Wire of
    0: if not ReadVar(B,P,Limit,V) then Exit;
    1: begin if Limit-P<8 then Exit; Inc(P,8) end;
    2: begin
      if not ReadVar(B,P,Limit,N) or (N>Cardinal(Limit-P)) then Exit;
      Start:=P; Inc(P,Integer(N)); Stop:=P;
    end;
    5: begin if Limit-P<4 then Exit; Inc(P,4) end;
    else Exit;
  end;
  Result:=True;
end;
function Zigzag(V:Cardinal):Int64;
begin
  Result:=Int64(V shr 1);
  if (V and 1)<>0 then Result:=-Result-1;
end;
function Analog(const B:TBytes; P,Limit:Integer; out Location:Integer; out Value:Single):Boolean;
var N,W,V:Cardinal; A,Z:Integer; HaveValue:Boolean; SignedValue:Int64;
begin
  Result:=False; Location:=0; Value:=0; HaveValue:=False;
  while P<Limit do
  begin
    if not Field(B,P,Limit,N,W,V,A,Z) then Exit;
    if N in [1,2] then
    begin
      if W<>0 then Exit;
      if N=1 then begin if V>3 then Exit; Location:=V end
      else begin
        SignedValue:=Zigzag(V); if Abs(SignedValue)>100 then Exit;
        Value:=SignedValue/100; HaveValue:=True;
      end;
    end;
  end;
  Result:=HaveValue;
end;
procedure TZwiftControllerParser.Reset;
begin FEdge.Reset; FSerial:=0; FDirection:=0 end;
function TZwiftControllerParser.Parse(const Bytes:TBytes; out Data:TTrainerDataRecord):Boolean;
var P,A,Z,Q,A2,Z2,Location,Turn:Integer; N,W,V,N2,W2,V2:Cardinal;
  Seen: set of 0..9; Values:array[0..9] of Cardinal;
  Mask:Cardinal; Axis,Value,AnalogAxis:Single; HaveMap,HaveAnalog,Left,Right:Boolean;
begin
  Result:=False; Data:=Default(TTrainerDataRecord);
  if (Length(Bytes)<3) or (Length(Bytes)>512) then Exit;
  if not (Bytes[0] in [$07,$23,$37]) then Exit;
  FillChar(Values,SizeOf(Values),0); Seen:=[];
  P:=1; HaveMap:=False; HaveAnalog:=False; AnalogAxis:=0; Mask:=$FFFFFFFF;
  while P<Length(Bytes) do
  begin
    if not Field(Bytes,P,Length(Bytes),N,W,V,A,Z) then Exit;
    if Bytes[0] in [$07,$37] then
    begin
      if N<=9 then
      begin
        if W<>0 then Exit;
        Include(Seen,N); Values[N]:=V;
        if (N<=7) and (V>1) then Exit;
      end;
    end else if N=1 then
    begin
      if W<>0 then Exit;
      HaveMap:=True; Mask:=V;
    end else if N in [2,3] then
    begin
      if W<>2 then Exit;
      if N=3 then
      begin
        if not Analog(Bytes,A,Z,Location,Value) then Exit;
        if Location<2 then begin AnalogAxis:=AnalogAxis-Value; HaveAnalog:=True end;
      end else begin
        { Original Ride firmware: field 2 contains repeated field-1 entries. }
        Q:=A;
        while Q<Z do
        begin
          if not Field(Bytes,Q,Z,N2,W2,V2,A2,Z2) then Exit;
          if N2=1 then
          begin
            if (W2<>2) or not Analog(Bytes,A2,Z2,Location,Value) then Exit;
            if Location<2 then begin AnalogAxis:=AnalogAxis-Value; HaveAnalog:=True end;
          end;
        end;
      end;
    end;
  end;
  Axis:=0; Left:=False; Right:=False;
  case Bytes[0] of
    $07: begin
      if not (1 in Seen) then Exit;
      if 8 in Seen then begin
        if Abs(Zigzag(Values[8]))>100 then Exit;
        Axis:=-Zigzag(Values[8])/100;
      end;
      if Values[1]=1 then begin
        Left:=(3 in Seen) and (Values[3]=0);
        Right:=(4 in Seen) and (Values[4]=0);
      end;
      if not (8 in Seen) and not ((3 in Seen) and (4 in Seen)) then Exit;
    end;
    $23: begin
      if not HaveMap and not HaveAnalog then Exit;
      if HaveMap then begin Left:=(Mask and 1)=0; Right:=(Mask and 4)=0 end;
      Axis:=EnsureRange(AnalogAxis,-1,1);
    end;
    $37: begin
      if not ((1 in Seen) and (2 in Seen)) then Exit;
      { Click: minus selects left, plus selects right. }
      Left:=Values[2]=0; Right:=Values[1]=0;
    end;
  end;
  if Left or Right then Axis:=Ord(Left)-Ord(Right);
  Turn:=FEdge.Update(Axis);
  if Turn<>0 then
  begin
    if FSerial=High(Cardinal) then FSerial:=1 else Inc(FSerial);
    FDirection:=Turn;
  end;
  BeginTrainerPacket(Data);
  { Preserve the existing degree-based sensor/zero calibration interface. }
  if Axis=0 then Data.SteeringAngle:=0
  else Data.SteeringAngle:=-Sign(Axis)*(0.6+Abs(Axis)*33.4);
  Data.SteeringTurnSerial:=FSerial;
  Data.SteeringTurnDirection:=FDirection;
  MarkTrainerMetric(Data,tmSteering);
  Result:=True;
end;
end.
