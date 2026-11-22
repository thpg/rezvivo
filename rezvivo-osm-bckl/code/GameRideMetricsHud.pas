unit GameRideMetricsHud;

{$mode objfpc}{$H+}{$codepage UTF8}

interface

uses Classes, CastleUIControls, CastleControls, CastleFonts, CastleColors,
  GameBLEHud, GameZoneWheel, GameDeviceService;

type
  { A fixed-width number cell. Only unusually long readings reduce the font;
    changing the number of digits never moves neighbouring controls. }
  TRideHudValue = class(TCastleLabel)
  private
    FNominalSize, FLastSize, FLastWidth, FLastScale: Single;
    FLastText: String;
  public
    procedure Render; override;
    property NominalSize: Single read FNominalSize write FNominalSize;
  end;

  TRideHudMetric = record
    Root: TCastleUserInterface;
    Icon: TCastleImageControl;
    Value: TRideHudValue;
    Units: TCastleLabel;
    Wheel: TCastleZoneWheel;
  end;

  { Presentation only. TBLEHudUpdater remains the sole telemetry/accounting
    source, and the existing zone-wheel widget retains its signal/animation rules. }
  TRideMetricsHud = class(TCastleUserInterface)
  private
    FLabels: THudLabels;
    FProfileIndex,FGridIndex,FGridCount:Integer;
    FGridBottom:Single;
    FComparisonRows:Integer;
    FRiderNumber:TCastleLabel;
    FRegularFont, FBoldFont: TCastleFont;
    FMetrics: array[0..2] of TRideHudMetric;
    FSpeedIcon, FWorkIcon, FGradeIcon: TCastleImageControl;
    FSpeedTitle, FSpeedUnits, FWorkTitle, FWorkUnits, FTSSTitle,
      FGradeTitle: TCastleLabel;
    FGearDown,FGearUp:TCastleButton;
    FReady, FArranging, FCompactLayout, FDenseLayout: Boolean;
    FLayoutScale: Single;
    FParentWidth,FParentHeight,FParentScale:Single;
    function NewLabel(const AName, Source: String; const Bold: Boolean): TCastleLabel;
    function NewValue(const AName: String): TRideHudValue;
    procedure LanguageChanged(Sender: TObject);
    procedure ShiftGear(Sender:TObject);
    procedure SetProfileIndex(Value:Integer);
    function RiderDevices:TGameDeviceService;
    function ComparisonRows:Integer;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Resize; override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean); override;
    procedure Render; override;
    procedure SetGridSlot(Index,Count:Integer);
    property ProfileIndex:Integer read FProfileIndex write SetProfileIndex;
    { Logical distance from the parent top to the bottom of all HUD rows. }
    property GridBottom:Single read FGridBottom;
    property Labels: THudLabels read FLabels;
  end;

implementation

uses SysUtils, Math, CastleVectors, CastleRectangles, CastleImages,
  CastleGLUtils, GameMenuTheme, GameRideLayout, UiTranslations,GameVirtualGearing,GameUserData,GameRiderPalette;

const
  HudWidth = 1000;
  HudHeight = 148;
  HudHeaderHeight = 42;
  HudInk: TCastleColor = (X:0.047; Y:0.125; Z:0.341; W:1);
  HudBlue: TCastleColor = (X:0.035; Y:0.357; Z:0.98; W:1);
  HudHeart: TCastleColor = (X:1; Y:0.357; Z:0.294; W:1);
  HudSurface: TCastleColor = (X:0.89; Y:0.953; Z:0.988; W:0.98);
  HudEdge: TCastleColor = (X:0.77; Y:0.866; Z:0.925; W:1);

type
  THudIconKind = (hiPower, hiHeart, hiCadence, hiSpeed, hiWork, hiGrade);

function HudIconImage(const Kind: THudIconKind): TRGBAlphaImage;
const
  Size = 96;
var X,Y,SX,SY,Coverage: Integer;
  function Polygon(const X, Y: Single; const XY: array of Single): Boolean;
  var I, J: Integer;
  begin
    Result:=False; J:=Length(XY) div 2-1;
    for I:=0 to Length(XY) div 2-1 do
    begin
      if ((XY[2*I+1]>Y)<>(XY[2*J+1]>Y)) and
        (X<(XY[2*J]-XY[2*I])*(Y-XY[2*I+1])/
        (XY[2*J+1]-XY[2*I+1])+XY[2*I]) then Result:=not Result;
      J:=I;
    end;
  end;
  function Segment(const X,Y,AX,AY,BX,BY,HalfWidth: Single): Boolean;
  var T: Single;
  begin
    T:=EnsureRange(((X-AX)*(BX-AX)+(Y-AY)*(BY-AY))/
      (Sqr(BX-AX)+Sqr(BY-AY)),0,1);
    Result:=Sqr(X-AX-T*(BX-AX))+Sqr(Y-AY-T*(BY-AY))<=Sqr(HalfWidth);
  end;
  function Inside(const X,Y: Single): Boolean;
  var U,V,D,A,R: Single; K: Integer;
  begin
    Result:=False;
    case Kind of
      hiPower: Result:=Polygon(X,Y,[0.38,0.94,0.82,0.94,0.58,0.58,
        0.85,0.58,0.30,0.04,0.43,0.44,0.17,0.44]);
      hiHeart:
        begin
          U:=(X-0.5)*2.65; V:=(Y-0.44)*2.65;
          D:=Sqr(U)+Sqr(V)-1;
          Result:=(D*D*D-Sqr(U)*V*V*V<=0);
        end;
      hiCadence:
        begin
          U:=X-0.5; V:=Y-0.5; D:=Sqrt(Sqr(U)+Sqr(V));
          A:=ArcTan2(V,U); R:=0.30;
          if Cos(A*12)>0.15 then R:=0.35;
          Result:=((D>=0.24) and (D<=R)) or (D<=0.075) or
            Segment(X,Y,0.5,0.5,0.19,0.81,0.035) or
            Segment(X,Y,0.5,0.5,0.81,0.19,0.035) or
            ((X>=0.065) and (X<=0.295) and (Y>=0.785) and (Y<=0.855)) or
            ((X>=0.705) and (X<=0.935) and (Y>=0.145) and (Y<=0.215));
          for K:=0 to 3 do
          begin
            A:=K*Pi/2+Pi/4;
            Result:=Result or Segment(X,Y,0.5,0.5,
              0.5+0.26*Cos(A),0.5+0.26*Sin(A),0.025);
          end;
        end;
      hiSpeed:
        begin
          D:=Sqrt(Sqr(X-0.5)+Sqr(Y-0.43));
          Result:=((D>=0.345) and (D<=0.42) and (Y>=0.25)) or
            Segment(X,Y,0.5,0.43,0.73,0.70,0.035) or
            (Sqr(X-0.5)+Sqr(Y-0.43)<0.006);
          for K:=0 to 4 do
          begin
            A:=(0.15+K*0.175)*Pi;
            Result:=Result or Segment(X,Y,
              0.5+0.28*Cos(A),0.43+0.28*Sin(A),
              0.5+0.345*Cos(A),0.43+0.345*Sin(A),0.025);
          end;
        end;
      hiWork:
        for K:=0 to 3 do
          Result:=Result or ((X>=0.09+K*0.22) and (X<=0.25+K*0.22) and
            (Y>=0.12) and (Y<=0.32+K*0.19));
      hiGrade: Result:=Polygon(X,Y,[0.06,0.14,0.34,0.67,0.60,0.14]) or
        Polygon(X,Y,[0.39,0.14,0.71,0.91,0.95,0.14]);
    end;
  end;
begin
  { Generated once per HUD, not per frame. Coverage sampling and the high-
    resolution mask keep icon edges smooth even when scene MSAA is disabled. }
  Result:=TRGBAlphaImage.Create(Size,Size);
  for Y:=0 to Size-1 do for X:=0 to Size-1 do
  begin
    Coverage:=0;
    for SY:=0 to 1 do for SX:=0 to 1 do
      if Inside((X+0.25+SX*0.5)/Size,(Y+0.25+SY*0.5)/Size) then Inc(Coverage);
    Result.Colors[X,Y,0]:=Vector4(1,1,1,Coverage/4);
  end;
end;

function AddIcon(const Owner: TComponent; const Parent: TCastleUserInterface;
  const Kind: THudIconKind; const Color: TCastleColor): TCastleImageControl;
begin
  Result:=TCastleImageControl.Create(Owner);
  Result.Stretch:=True;
  { Thin icons contain too few partial-alpha pixels for automatic detection;
    force blending so their sampled edges are not alpha-tested away. }
  Result.AlphaChannel:=acBlending;
  Result.Image:=HudIconImage(Kind); Result.Color:=Color;
  Parent.InsertFront(Result);
end;

function LoadHudFont(const Owner: TComponent; const Bold: Boolean): TCastleFont;
var Ch: Integer; Characters: UnicodeString;
begin
  Result:=TCastleFont.Create(Owner);
  if Bold then Result.OptimalSize:=56 else Result.OptimalSize:=20;
  Characters:='−—';
  if not Bold then
  begin
    for Ch:=$A0 to $17F do Characters:=Characters+WideChar(Ch);
    for Ch:=$400 to $45F do Characters:=Characters+WideChar(Ch);
    Characters:=Characters+'Ґґ';
  end;
  Result.LoadCharacters:=UTF8Encode(Characters);
  if Bold then Result.Url:='castle-data:/menu/fonts/Montserrat-Bold.ttf'
  else Result.Url:='castle-data:/menu/fonts/Montserrat-Regular.ttf';
  Result.Size:=20;
end;

procedure TRideHudValue.Render;
var TextWidth: Single;
begin
  if (FLastText<>Caption) or (FLastSize<>FNominalSize) or
    (FLastWidth<>Width) or (FLastScale<>UIScale) then
  begin
    FLastText:=Caption; FLastSize:=FNominalSize;
    FLastWidth:=Width; FLastScale:=UIScale;
    FontSize:=FNominalSize;
    TextWidth:=Font.TextWidth(Caption)/Max(0.01,UIScale);
    if TextWidth>Width then FontSize:=FNominalSize*Width/TextWidth;
  end;
  inherited;
end;

function TRideMetricsHud.NewLabel(const AName, Source: String;
  const Bold: Boolean): TCastleLabel;
begin
  Result:=TCastleLabel.Create(Self); Result.Name:=AName;
  if Bold then Result.CustomFont:=FBoldFont else Result.CustomFont:=FRegularFont;
  Result.Color:=HudInk; Result.Outline:=0; Result.AutoSize:=False;
  Result.VerticalAlignment:=vpMiddle;
  if Source<>'' then BindUiText(Result,Source);
  InsertFront(Result);
end;

function TRideMetricsHud.NewValue(const AName: String): TRideHudValue;
begin
  Result:=TRideHudValue.Create(Self); Result.Name:=AName;
  Result.CustomFont:=FBoldFont; Result.Color:=HudInk; Result.Outline:=0;
  Result.AutoSize:=False; Result.Alignment:=hpRight;
  Result.VerticalAlignment:=vpMiddle; Result.Caption:='0.0';
  InsertFront(Result);
end;

constructor TRideMetricsHud.Create(AOwner: TComponent);
const
  ValueNames: array[0..2] of String = ('LabelPower','LabelHeart','LabelCadence');
  WheelNames: array[0..2] of String = ('PowerZoneWheel','HeartZoneWheel','CadenceZoneWheel');
  UnitNames: array[0..2] of String = ('W','bpm','rpm');
  MetricNames: array[0..2] of String = ('Power','Heart Rate','Cadence');
var I: Integer; IconColor: TCastleColor;
begin
  inherited;
  FGridCount:=1;
  Name:='RideMetricsBackground'; Width:=HudWidth; Height:=HudHeight;
  Anchor(hpMiddle); Anchor(vpTop,-12); FLayoutScale:=1;
  FRegularFont:=LoadHudFont(Self,False); FBoldFont:=LoadHudFont(Self,True);
  for I:=0 to 2 do
  begin
    FMetrics[I].Root:=TCastleUserInterface.Create(Self);
    FMetrics[I].Root.Name:='RideMetric'+IntToStr(I); InsertFront(FMetrics[I].Root);
    IconColor:=HudBlue; if I=1 then IconColor:=HudHeart;
    FMetrics[I].Icon:=AddIcon(Self,FMetrics[I].Root,THudIconKind(I),IconColor);
    FMetrics[I].Icon.Name:='RideMetricIcon'+IntToStr(I);
    FMetrics[I].Value:=NewValue(ValueNames[I]);
    FMetrics[I].Value.Parent.RemoveControl(FMetrics[I].Value);
    FMetrics[I].Root.InsertFront(FMetrics[I].Value);
    FMetrics[I].Value.Caption:='--';
    BindUiText(FMetrics[I].Value,MetricNames[I],'Tooltip');
    FMetrics[I].Units:=NewLabel(ValueNames[I]+'Units',UnitNames[I],False);
    FMetrics[I].Units.Parent.RemoveControl(FMetrics[I].Units);
    FMetrics[I].Root.InsertFront(FMetrics[I].Units);
    FMetrics[I].Wheel:=TCastleZoneWheel.Create(Self);
    FMetrics[I].Wheel.Name:=WheelNames[I]; FMetrics[I].Wheel.Orientation:=woHorizontal;
    FMetrics[I].Wheel.CustomFont:=FBoldFont;
    FMetrics[I].Wheel.RoundedFrame:=True;
    FMetrics[I].Wheel.FrameBackground:=HudSurface;
    FMetrics[I].Root.InsertFront(FMetrics[I].Wheel);
  end;
  FLabels.LabelRiderName:=NewValue('LabelRiderName');
  FLabels.LabelRiderName.CustomFont:=FRegularFont;FLabels.LabelRiderName.Alignment:=hpLeft;
  FLabels.LabelRiderName.Exists:=False;
  FRiderNumber:=NewLabel('LocalRiderNumber','',False);FRiderNumber.Exists:=False;
  FLabels.LabelPowerComparison:=NewLabel('LabelPowerComparison','',False);
  FLabels.LabelPowerComparison.CustomFont:=FRegularFont;FLabels.LabelPowerComparison.Alignment:=hpLeft;
  FLabels.LabelPowerComparison.Caption:='';FLabels.LabelPowerComparison.Exists:=False;
  FLabels.LabelPower:=FMetrics[0].Value; FLabels.WheelPower:=FMetrics[0].Wheel;
  FLabels.LabelHeart:=FMetrics[1].Value; FLabels.WheelHeart:=FMetrics[1].Wheel;
  FLabels.LabelCadence:=FMetrics[2].Value; FLabels.WheelCadence:=FMetrics[2].Wheel;
  FLabels.LabelSpeed:=NewValue('LabelSpeed');
  FLabels.LabelWork:=NewValue('LabelWork');
  FLabels.LabelWorkTSS:=NewValue('LabelWorkTSS');
  FLabels.LabelSlope:=NewValue('LabelSlope');
  FLabels.LabelTransmission:=NewValue('LabelTransmission');
  FLabels.LabelTransmission.Alignment:=hpMiddle;
  FLabels.LabelTransmission.Caption:='--';
  BindUiText(FLabels.LabelTransmission,'Gear','Tooltip');
  FGearDown:=TMenuButton.Create(Self);FGearDown.Name:='GearDown';FGearDown.Caption:='-';
  TMenuButton(FGearDown).AutoIcon:=False;FGearDown.Tag:=-1;FGearDown.OnClick:=@ShiftGear;
  FGearDown.AutoSize:=False;InsertFront(FGearDown);
  FGearUp:=TMenuButton.Create(Self);FGearUp.Name:='GearUp';FGearUp.Caption:='+';
  TMenuButton(FGearUp).AutoIcon:=False;FGearUp.Tag:=1;FGearUp.OnClick:=@ShiftGear;
  FGearUp.AutoSize:=False;InsertFront(FGearUp);
  BindUiText(FGearDown,'Easier gear (Page Down)','Tooltip');
  BindUiText(FGearUp,'Harder gear (Page Up)','Tooltip');
  FLabels.LabelSlope.Caption:='0.0%';
  FLabels.LabelCorr:=NewLabel('LabelCorr','',False); FLabels.LabelCorr.Caption:='--';
  FLabels.LabelCorr.Alignment:=hpRight;
  FSpeedTitle:=NewLabel('LabelSpeedName','Speed',False);
  FSpeedUnits:=NewLabel('LabelSpeedUnits','km/h',False);
  FWorkTitle:=NewLabel('LabelWorkTitle','Today',False);
  FWorkUnits:=NewLabel('LabelWorkUnits','kJ',False);
  FTSSTitle:=NewLabel('LabelTSSTitle','TSS',False);
  FGradeTitle:=NewLabel('LabelSlopeName','Gradient',False);
  FSpeedIcon:=AddIcon(Self,Self,hiSpeed,HudInk);
  FWorkIcon:=AddIcon(Self,Self,hiWork,HudBlue);
  FGradeIcon:=AddIcon(Self,Self,hiGrade,HudInk);
  BindUiText(FLabels.LabelWork,'Work today. Resets at 00:00 local time.','Tooltip');
  SetProfileIndex(0);
  FReady:=True;
  ObserveUiLanguage(Self,@LanguageChanged);
  Resize;
end;

procedure TRideMetricsHud.LanguageChanged(Sender: TObject);
begin
  Resize;
end;
function TRideMetricsHud.RiderDevices:TGameDeviceService;
begin
  if DeviceService=nil then Exit(nil);
  Result:=DeviceService.ForRider(FProfileIndex);
end;

procedure TRideMetricsHud.SetProfileIndex(Value:Integer);
begin
  if (Value<0)or(Value>=MaxLocalRiders)then raise ERangeError.Create('Local rider index');
  FProfileIndex:=Value;
  FLabels.LabelRiderName.Caption:=LocalRider(Value).DisplayName;
  FRiderNumber.Caption:=IntToStr(Value+1)+'.';
end;

procedure TRideMetricsHud.SetGridSlot(Index,Count:Integer);
begin
  FGridCount:=EnsureRange(Count,1,MaxLocalRiders);
  FGridIndex:=EnsureRange(Index,0,FGridCount-1);
  Resize;
end;

procedure TRideMetricsHud.ShiftGear(Sender:TObject);
begin
  if(RiderDevices<>nil)and not RiderDevices.TrainerErgActive then
    RiderDevices.ShiftVirtualGear(TCastleButton(Sender).Tag);
end;

function TRideMetricsHud.ComparisonRows:Integer;
var I:Integer;
begin
  Result:=0;if DeviceService=nil then Exit;
  if FGridCount>1 then begin
    for I:=0 to LocalRiderCount-1 do
      Result:=Max(Result,DeviceService.ForRider(I).ComparisonPowerLineCount);
  end else Result:=RiderDevices.ComparisonPowerLineCount;
end;

procedure TRideMetricsHud.Update(const SecondsPassed:Single;var HandleInput:Boolean);
begin
  inherited;
  if (ComparisonRows<>FComparisonRows)or((Parent<>nil) and ((Abs(Parent.EffectiveWidth-FParentWidth)>0.1) or
    (Abs(Parent.EffectiveHeight-FParentHeight)>0.1) or
    (Abs(UIScale-FParentScale)>0.001))) then Resize;
end;

procedure TRideMetricsHud.Resize;
var Available, AvailableHeight, S, NumberWidth, UnitWidth, RowX: Single;
  Usable,GridLeft,GridWidth,GridTop,GridGap,GridHeader,TileWidth,TileHeight,FooterHeight,BaseHeight:Single;
  I,Columns,Rows: Integer; L:TRideHudLayout;
  procedure Place(const C: TCastleUserInterface; const X, Y, W, H: Single);
  begin
    C.Width:=W*S; C.Height:=H*S; C.Anchor(hpLeft,X*S);
    if C.Parent=Self then C.Anchor(vpTop,-(Y+GridHeader)*S)
    else C.Anchor(vpTop,-Y*S);
  end;
  procedure Text(const C: TCastleLabel; const X,Y,W,H,Size: Single);
  begin
    Place(C,X,Y,W,H); C.FontSize:=Size*S;
    if C is TRideHudValue then TRideHudValue(C).NominalSize:=Size*S;
  end;
begin
  inherited;
  if not FReady or FArranging then Exit;
  FArranging:=True;
  try
    Available:=HudWidth+400;AvailableHeight:=900;
    if Parent<>nil then begin Available:=Parent.EffectiveWidth;AvailableHeight:=Parent.EffectiveHeight end;
    FParentWidth:=Available;FParentHeight:=AvailableHeight;FParentScale:=UIScale;
    GridHeader:=0;FDenseLayout:=False;FComparisonRows:=ComparisonRows;
    FooterHeight:=0;if FComparisonRows>0 then FooterHeight:=8+FComparisonRows*17;
    L:=RideHudLayout(Available,AvailableHeight);FCompactLayout:=L.CompactMetrics;
    if FGridCount>1 then begin
      GridGap:=8;GridLeft:=L.Margin;GridTop:=L.MetricsTop;
      if Available>=640 then GridLeft:=L.ButtonWidth+3*L.Margin;
      Usable:=Max(1,Available-GridLeft-L.Margin);
      { Effective dimensions already account for DPI/accessibility scaling.
        Keep at least 280 logical units per column before selecting another. }
      Columns:=Min(FGridCount,Min(3,Max(1,Floor((Usable+GridGap)/(280+GridGap)))));
      Rows:=(FGridCount+Columns-1)div Columns;
      TileWidth:=Min(360,(Usable-(Columns-1)*GridGap)/Columns);
      BaseHeight:=188+FooterHeight;
      S:=Min(TileWidth/360,Max(0.01,(AvailableHeight*0.50-(Rows-1)*GridGap)/(Rows*BaseHeight)));
      TileWidth:=360*S;TileHeight:=BaseHeight*S;
      { Eight full dashboards cannot be made readable by shrinking every
        glyph to fit half a small screen. Reflow the essential live values
        into short cards, retaining the three wheels and gear controls. }
      if S<0.72 then begin
        FDenseLayout:=True;
        Columns:=Min(FGridCount,Min(3,Max(1,Floor((Usable+GridGap)/(164+GridGap)))));
        Rows:=(FGridCount+Columns-1)div Columns;
        TileWidth:=Min(230,(Usable-(Columns-1)*GridGap)/Columns);
        S:=TileWidth/180;BaseHeight:=96+FooterHeight;
        TileHeight:=BaseHeight*S;
      end;
      GridWidth:=Columns*TileWidth+(Columns-1)*GridGap;
      GridLeft:=GridLeft+Max(0,(Usable-GridWidth)/2);
      L.CompactMetrics:=True;FCompactLayout:=True;
      L.MetricsWidth:=TileWidth;L.MetricsHeight:=TileHeight;
      L.MetricsLeft:=GridLeft+(FGridIndex mod Columns)*(TileWidth+GridGap);
      L.MetricsTop:=GridTop+(FGridIndex div Columns)*(TileHeight+GridGap);
      FGridBottom:=GridTop+Rows*TileHeight+(Rows-1)*GridGap;
      if FDenseLayout then GridHeader:=22 else GridHeader:=32;
    end else begin
      if FCompactLayout then S:=L.MetricsWidth/360 else S:=L.MetricsWidth/HudWidth;
      L.MetricsHeight:=L.MetricsHeight+FooterHeight*S;
      FGridBottom:=L.MetricsTop+L.MetricsHeight;
    end;
    if FDenseLayout then S:=L.MetricsWidth/180
    else if FCompactLayout then S:=L.MetricsWidth/360 else S:=L.MetricsWidth/HudWidth;
    FLayoutScale:=S;
    Width:=L.MetricsWidth; Height:=L.MetricsHeight;
    Anchor(hpLeft,L.MetricsLeft);Anchor(vpTop,-L.MetricsTop);
    FLabels.LabelRiderName.Exists:=FGridCount>1;FRiderNumber.Exists:=FGridCount>1;
    FLabels.LabelPowerComparison.Exists:=FLabels.LabelPowerComparison.Caption<>'';
    if FGridCount>1 then begin
      Text(FRiderNumber,8,-28,26,24,14);
      Text(FLabels.LabelRiderName,34,-28,318,24,14);
      Text(FLabels.LabelPowerComparison,8,158,344,FooterHeight,11);
    end else begin
      if FCompactLayout then BaseHeight:=156 else BaseHeight:=HudHeight;
      Place(FLabels.LabelPowerComparison,8,BaseHeight+3,
        Width/S-16,FooterHeight);
      FLabels.LabelPowerComparison.FontSize:=12*S;
    end;
    FSpeedTitle.Exists:=not FCompactLayout;FWorkTitle.Exists:=not FCompactLayout;
    FGradeTitle.Exists:=not FCompactLayout;
    FWorkIcon.Exists:=not FDenseLayout;FLabels.LabelWork.Exists:=not FDenseLayout;
    FWorkUnits.Exists:=not FDenseLayout;FTSSTitle.Exists:=not FDenseLayout;
    FLabels.LabelWorkTSS.Exists:=not FDenseLayout;FLabels.LabelCorr.Exists:=not FDenseLayout;
    if FDenseLayout then begin
      Text(FRiderNumber,5,-21,18,20,12);
      Text(FLabels.LabelRiderName,23,-21,152,20,12);
      Place(FSpeedIcon,4,5,11,11);Text(FLabels.LabelSpeed,17,0,34,22,14);
      Text(FSpeedUnits,52,1,21,20,9);
      Place(FGradeIcon,76,5,10,11);Text(FLabels.LabelSlope,87,0,35,22,12);
      Place(FGearDown,124,2,14,18);FGearDown.FontSize:=12*S;
      Text(FLabels.LabelTransmission,139,1,24,20,12);
      Place(FGearUp,164,2,14,18);FGearUp.FontSize:=12*S;
      for I:=0 to 2 do begin
        Place(FMetrics[I].Root,I*60,22,60,52);
        Place(FMetrics[I].Icon,4,7,11,13);
        Text(FMetrics[I].Value,17,0,39,28,23);
        Text(FMetrics[I].Units,28,25,28,14,10);
        Place(FMetrics[I].Wheel,4,41,52,10);FMetrics[I].Wheel.FontSize:=10*S;
      end;
      Text(FLabels.LabelPowerComparison,5,76,170,FooterHeight,11);
      Exit;
    end;
    if FCompactLayout then begin
      { Reflow at a readable physical size instead of shrinking the desktop
        strip. The three original wheels and telemetry bindings are retained. }
      Place(FSpeedIcon,8,9,16,16);Text(FLabels.LabelSpeed,28,4,46,26,18);
      Text(FSpeedUnits,78,6,34,24,11);
      Place(FWorkIcon,124,9,16,16);Text(FLabels.LabelWork,144,4,70,26,18);
      Text(FWorkUnits,218,6,23,24,11);
      Text(FTSSTitle,256,6,28,24,11);Text(FLabels.LabelWorkTSS,287,4,64,26,18);
      Place(FGradeIcon,8,44,16,16);Text(FLabels.LabelSlope,27,38,62,28,18);
      Text(FLabels.LabelCorr,94,39,50,26,11);
      Place(FGearDown,182,35,40,32);FGearDown.FontSize:=18*S;
      Text(FLabels.LabelTransmission,226,35,78,32,18);
      Place(FGearUp,308,35,40,32);FGearUp.FontSize:=18*S;
      for I:=0 to 2 do begin
        Place(FMetrics[I].Root,I*120,72,120,84);
        Place(FMetrics[I].Icon,8,18,20,20);
        if I=2 then Place(FMetrics[I].Icon,5,15,26,26);
        Text(FMetrics[I].Value,29,1,82,42,32);
        Text(FMetrics[I].Units,80,37,32,18,11);
        Place(FMetrics[I].Wheel,8,60,104,17);FMetrics[I].Wheel.FontSize:=12*S;
      end;
      Exit;
    end;
    for I:=0 to 2 do
    begin
      Place(FMetrics[I].Root,I*HudWidth/3,HudHeaderHeight,HudWidth/3,HudHeight-HudHeaderHeight);
      NumberWidth:=112; UnitWidth:=80;
      if I=0 then begin NumberWidth:=142; UnitWidth:=50 end;
      RowX:=(HudWidth/3-(36+12+NumberWidth+8+UnitWidth))/2;
      Place(FMetrics[I].Icon,RowX,18,36,36);
      if I=2 then Place(FMetrics[I].Icon,RowX-6,12,48,48);
      Text(FMetrics[I].Value,RowX+48,3,NumberWidth,70,56);
      Text(FMetrics[I].Units,RowX+48+NumberWidth+8,32,UnitWidth,25,17);
      Place(FMetrics[I].Wheel,(HudWidth/3-238)/2,73,238,24);
      FMetrics[I].Wheel.FontSize:=18*S;
    end;
    Place(FSpeedIcon,12,11,20,20);
    Text(FSpeedTitle,38,7,53,28,13);
    Text(FLabels.LabelSpeed,92,4,68,32,25);
    Text(FSpeedUnits,165,7,40,28,13);
    Place(FWorkIcon,218,11,20,20);
    Text(FWorkTitle,244,7,54,28,13);
    Text(FLabels.LabelWork,300,4,99,32,25);
    Text(FWorkUnits,403,7,25,28,13);
    Text(FTSSTitle,440,7,30,28,13);
    Text(FLabels.LabelWorkTSS,472,4,74,32,25);
    Place(FGradeIcon,562,11,20,20);
    Text(FGradeTitle,589,7,65,28,13);
    Text(FLabels.LabelSlope,656,4,86,32,25);
    Place(FGearDown,760,5,28,32);FGearDown.FontSize:=16*S;
    Text(FLabels.LabelTransmission,793,5,102,32,22);
    Place(FGearUp,900,5,28,32);FGearUp.FontSize:=16*S;
    Text(FLabels.LabelCorr,938,7,50,28,13);
  finally
    FArranging:=False;
  end;
end;

procedure TRideMetricsHud.Render;
var R: TFloatRectangle; S, LineWidth: Single; I: Integer;
  Surface,Edge:TCastleColor;P:TRiderPanelPalette;
const HeaderDividers: array[0..3] of Single = (210,430,554,750);
begin
  inherited;
  FLabels.LabelRiderName.Exists:=FGridCount>1;FRiderNumber.Exists:=FGridCount>1;
  FLabels.LabelPowerComparison.Exists:=FLabels.LabelPowerComparison.Caption<>'';
  FGearUp.Enabled:=(RiderDevices<>nil)and not RiderDevices.TrainerErgActive and
    (RiderDevices.GearingBackend in[gbNative,gbFTMSPower]);
  FGearDown.Enabled:=FGearUp.Enabled;
  Surface:=HudSurface;Edge:=HudEdge;
  if FGridCount>1 then begin
    P:=RiderPanelPalette(FProfileIndex);Surface:=P.Surface;Edge:=P.Border;
    FLabels.LabelRiderName.Color:=P.Accent;FRiderNumber.Color:=P.Accent;
    for I:=0 to 2 do FMetrics[I].Wheel.FrameBackground:=Surface;
    ApplyRiderButtonPalette(FGearDown,FProfileIndex);
    ApplyRiderButtonPalette(FGearUp,FProfileIndex);
  end;
  R:=RenderRect; S:=FLayoutScale*UIScale; LineWidth:=Max(1,S);
  DrawMenuPanel(R,12*S,Edge);
  DrawMenuPanel(R.Grow(-LineWidth),Max(0,12*S-LineWidth),Surface);
  if FDenseLayout then begin
    DrawRectangle(FloatRectangle(R.Left+1,R.Top-44*S,R.Width-2,LineWidth),Edge);
    for I:=1 to 2 do
      DrawRectangle(FloatRectangle(R.Left+I*R.Width/3,R.Top-94*S,LineWidth,50*S),Edge);
    Exit;
  end;
  if FCompactLayout then begin
    DrawRectangle(FloatRectangle(R.Left+1,R.Top-(72+Ord(FGridCount>1)*32)*S,R.Width-2,LineWidth),Edge);
    for I:=1 to 2 do
      DrawRectangle(FloatRectangle(R.Left+I*R.Width/3,R.Top-(148+Ord(FGridCount>1)*32)*S,LineWidth,68*S),Edge);
    Exit;
  end;
  DrawRectangle(FloatRectangle(R.Left+1,R.Top-HudHeaderHeight*S,R.Width-2,LineWidth),Edge);
  for I:=0 to High(HeaderDividers) do
    DrawRectangle(FloatRectangle(R.Left+HeaderDividers[I]*S,R.Top-33*S,
      LineWidth,24*S),Edge);
  for I:=1 to 2 do
    DrawRectangle(FloatRectangle(R.Left+I*R.Width/3,R.Top-(HudHeight-12)*S,
      LineWidth,80*S),Edge);
end;

end.
