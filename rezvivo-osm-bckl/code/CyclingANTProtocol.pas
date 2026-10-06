unit CyclingANTProtocol;
{$mode objfpc}{$H+}
interface
uses SysUtils, Math, TrainerData, CyclingRevolutions;
type
  TCyclingANTParser = class
  private
    FLast: TTrainerDataRecord;
    FWheel, FCrank: TRevolutionTracker;
    FElapsed, FDistance: Cardinal;
    FPrevElapsed, FPrevDistance: Byte;
    FHaveGeneral: Boolean;
    FTorqueInitialized: array[0..1] of Boolean;
    FPrevTorque, FPrevPeriod: array[0..1] of Word;
    FPrevTicks: array[0..1] of Byte;
  public
    WheelCircumferenceM: Single;
    Features: TTrainerFeatures;
    constructor Create;
    procedure Reset;
    function Parse(DeviceType: Byte; const Page: TBytes;
      out Data: TTrainerDataRecord): Boolean;
  end;
function DecodeFECFrame(const Data: TBytes; out Page: TBytes; out Channel: Byte): Boolean;
function FECUserConfiguration(RiderKg, BikeKg, CircumferenceM: Single): TBytes;
function FECWindParameters(WindSpeed, DragCoefficient: Single): TBytes;
function FECRequestPage(PageNumber: Byte): TBytes;
implementation
function U16(const B: TBytes; P: Integer): Word; inline;
begin Result:=Word(B[P]) or (Word(B[P+1]) shl 8) end;

function DecodeFECFrame(const Data: TBytes; out Page: TBytes; out Channel: Byte): Boolean;
var O,I,N: Integer; C: Byte;
begin
  Result:=False; Page:=nil; Channel:=255; N:=Length(Data); O:=0;
  { Some Tacx firmwares prepend two zero bytes. }
  if (N in [10,15]) and (Data[0]=0) and (Data[1]=0) then O:=2;
  if N-O=8 then Page:=Copy(Data,O,8)
  else if N-O=9 then begin Channel:=Data[O]; Page:=Copy(Data,O+1,8) end
  else if (N-O>=13) and (Data[O]=$A4) then
  begin
    if (Data[O+1]<>9) or not (Data[O+2] in [$4E,$4F]) or (N-O<>13) then Exit;
    C:=0;
    for I:=O to O+12 do C:=C xor Data[I];
    if C<>0 then Exit;
    Channel:=Data[O+3]; Page:=Copy(Data,O+4,8);
  end else Exit;
  Result:=True;
end;

constructor TCyclingANTParser.Create;
begin inherited; WheelCircumferenceM:=2.105; Reset end;
procedure TCyclingANTParser.Reset;
begin
  FLast:=Default(TTrainerDataRecord);
  FWheel:=Default(TRevolutionTracker); FCrank:=Default(TRevolutionTracker);
  Features:=Default(TTrainerFeatures);
  FHaveGeneral:=False; FElapsed:=0; FDistance:=0;
  FillChar(FTorqueInitialized,SizeOf(FTorqueInitialized),0);
end;

function TCyclingANTParser.Parse(DeviceType: Byte; const Page: TBytes;
  out Data: TTrainerDataRecord): Boolean;
var Raw,RawCad: Word; Index: Integer; DT,DQ,DR: Cardinal; W: Double;
begin
  Data:=FLast; Result:=False;
  if Length(Page)<>8 then Exit;
  BeginTrainerPacket(Data);
  case DeviceType of
    17: case Page[0] of
      16:
      begin
        Raw:=U16(Page,4);
        if Raw=$FFFF then Data.InstantSpeed:=0 else Data.InstantSpeed:=Raw*0.0036;
        MarkTrainerMetric(Data,tmSpeed,Raw<>$FFFF);
        Data.HeartRate:=Page[6];
        MarkTrainerMetric(Data,tmHeartRate,(Page[6]>0) and (Page[6]<>255));
        if FHaveGeneral then
        begin
          Inc(FElapsed,(Cardinal(Page[2])+256-FPrevElapsed) and $FF);
          Inc(FDistance,(Cardinal(Page[3])+256-FPrevDistance) and $FF);
        end
        else begin FElapsed:=Page[2]; FDistance:=Page[3]; FHaveGeneral:=True end;
        FPrevElapsed:=Page[2]; FPrevDistance:=Page[3];
        Data.ElapsedTime:=FElapsed div 4;
        Data.Distance:=FDistance;
        MarkTrainerMetric(Data,tmElapsed);
        if (Page[7] and 4)<>0 then MarkTrainerMetric(Data,tmDistance);
      end;
      25:
      begin
        Raw:=Page[5] or ((Word(Page[6]) and $F) shl 8);
        if Raw=$FFF then Data.InstantPower:=0 else Data.InstantPower:=Raw;
        Data.AveragePower:=Data.InstantPower;
        MarkTrainerMetric(Data,tmPower,Raw<>$FFF);
        if Page[2]=255 then Data.InstantCadence:=0 else Data.InstantCadence:=Page[2];
        MarkTrainerMetric(Data,tmCadence,Page[2]<>255);
      end;
      54:
      begin
        Features.Known:=True;
        Features.SupportsResistanceControl:=(Page[7] and 1)<>0;
        Features.SupportsPowerControl:=(Page[7] and 2)<>0;
        Features.SupportsSimulation:=(Page[7] and 4)<>0;
        Features.SupportsInclineControl:=Features.SupportsSimulation;
        Features.MaxResistance:=100;
        Features.SupportsPower:=True;
        Exit;
      end;
      else Exit;
    end;
    120:
    begin
      Data.HeartRate:=Page[7];
      MarkTrainerMetric(Data,tmHeartRate,(Page[7]>0) and (Page[7]<>255));
    end;
    121,122,123:
    begin
      if DeviceType in [121,122] then
      begin
        if DeviceType=121 then Index:=0 else Index:=4;
        Data.InstantCadence:=Round(RevolutionRate(FCrank,U16(Page,Index+2),
          U16(Page,Index),1024,True,6)*60);
        MarkTrainerMetric(Data,tmCadence);
      end;
      if DeviceType in [121,123] then
      begin
        Data.InstantSpeed:=RevolutionRate(FWheel,U16(Page,6),U16(Page,4),
          1024,True,30)*WheelCircumferenceM*3.6;
        MarkTrainerMetric(Data,tmSpeed);
      end;
    end;
    11: case Page[0] of
      $10:
      begin
        Raw:=U16(Page,6);
        if Raw=$FFFF then Data.InstantPower:=0 else Data.InstantPower:=Raw;
        Data.AveragePower:=Data.InstantPower;
        MarkTrainerMetric(Data,tmPower,Raw<>$FFFF);
        if Page[3]=255 then Data.InstantCadence:=0 else Data.InstantCadence:=Page[3];
        MarkTrainerMetric(Data,tmCadence,Page[3]<>255);
      end;
      $11,$12:
      begin
        Index:=Page[0]-$11;
        Raw:=U16(Page,6); RawCad:=U16(Page,4);
        if FTorqueInitialized[Index] then
        begin
          DQ:=(Cardinal(Raw)+65536-FPrevTorque[Index]) and $FFFF;
          DT:=(Cardinal(RawCad)+65536-FPrevPeriod[Index]) and $FFFF;
          DR:=(Cardinal(Page[2])+256-FPrevTicks[Index]) and $FF;
          if (DT>0) and (DR>0) then
          begin
            W:=128*Pi*DQ/DT;
            Data.InstantPower:=Round(Min(W,65534));
            MarkTrainerMetric(Data,tmPower,W<65535);
            if Index=0 then
            begin
              Data.InstantSpeed:=DR*2048.0/DT*WheelCircumferenceM*3.6;
              MarkTrainerMetric(Data,tmSpeed);
            end;
          end;
        end;
        FTorqueInitialized[Index]:=True;
        FPrevTorque[Index]:=Raw; FPrevPeriod[Index]:=RawCad; FPrevTicks[Index]:=Page[2];
        if Page[3]=255 then Data.InstantCadence:=0 else Data.InstantCadence:=Page[3];
        MarkTrainerMetric(Data,tmCadence,Page[3]<>255);
      end;
      else Exit;
    end;
    else Exit;
  end;
  Data.IsMoving:=(Data.InstantPower>0) or (Data.InstantSpeed>0.1);
  FLast:=Data;
  Result:=Data.PresentMetrics<>[];
end;

function FECUserConfiguration(RiderKg, BikeKg, CircumferenceM: Single): TBytes;
var Rider: Word; Bike,Diameter: Integer;
begin
  SetLength(Result,8); FillChar(Result[0],8,$FF); Result[0]:=55;
  Rider:=Round(EnsureRange(RiderKg,0,655.34)*100);
  Bike:=Round(EnsureRange(BikeKg,0,50)*20);
  Diameter:=Round(EnsureRange(CircumferenceM/Pi,0.1,2.54)*1000);
  Result[1]:=Lo(Rider); Result[2]:=Hi(Rider);
  { Bike weight: 12 bits, 0.05 kg. Wheel diameter offset: low nibble, 1 mm. }
  Result[4]:=((Bike and $F) shl 4) or (Diameter mod 10);
  Result[5]:=(Bike shr 4) and $FF;
  Result[6]:=Diameter div 10;
  Result[7]:=0; { Gear ratio unknown, not 255 (= 7.65). }
end;

function FECRequestPage(PageNumber: Byte): TBytes;
begin
  Result:=TBytes.Create(70,$FF,$FF,$FF,$FF,1,PageNumber,1);
end;

function FECWindParameters(WindSpeed, DragCoefficient: Single): TBytes;
begin
  SetLength(Result,8); FillChar(Result[0],8,$FF); Result[0]:=50;
  Result[5]:=Round(EnsureRange(DragCoefficient,0,1.86)*100);
  Result[6]:=Round(EnsureRange(WindSpeed*3.6,-127,127))+127;
  Result[7]:=100; { no drafting reduction }
end;
end.
