unit GameRideMetricsHud;

{$mode objfpc}{$H+}{$codepage UTF8}

interface

uses Classes, CastleUIControls, CastleControls, CastleFonts, CastleColors,
  GameBLEHud, GameZoneWheel;

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
    FRegularFont, FBoldFont: TCastleFont;
    FMetrics: array[0..2] of TRideHudMetric;
    FSpeedIcon, FWorkIcon, FGradeIcon: TCastleImageControl;
    FSpeedTitle, FSpeedUnits, FWorkTitle, FWorkUnits, FTSSTitle,
      FGradeTitle: TCastleLabel;
    FReady, FArranging: Boolean;
    FLayoutScale: Single;
    function NewLabel(const AName, Source: String; const Bold: Boolean): TCastleLabel;
    function NewValue(const AName: String): TRideHudValue;
    procedure LanguageChanged(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Resize; override;
    procedure Render; override;
    property Labels: THudLabels read FLabels;
  end;

implementation

uses SysUtils, Math, CastleVectors, CastleRectangles, CastleImages,
  CastleGLUtils, GameMenuTheme, GameRideCommands, UiTranslations;

const
  HudWidth = 1000;
  HudHeight = 148;
  HudHeaderHeight = 42;
  { At 100% UI size, keep the same physical size as in a 1280-pixel-wide
    window. Wider/taller windows must not magnify the ride metrics. }
  HudMaxPixelWidth = 800;
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
    FMetrics[I].Value.Caption:='—';
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
  FLabels.LabelPower:=FMetrics[0].Value; FLabels.WheelPower:=FMetrics[0].Wheel;
  FLabels.LabelHeart:=FMetrics[1].Value; FLabels.WheelHeart:=FMetrics[1].Wheel;
  FLabels.LabelCadence:=FMetrics[2].Value; FLabels.WheelCadence:=FMetrics[2].Wheel;
  FLabels.LabelSpeed:=NewValue('LabelSpeed');
  FLabels.LabelWork:=NewValue('LabelWork');
  FLabels.LabelWorkTSS:=NewValue('LabelWorkTSS');
  FLabels.LabelSlope:=NewValue('LabelSlope');
  FLabels.LabelSlope.Caption:='0.0%';
  FLabels.LabelCorr:=NewLabel('LabelCorr','',False); FLabels.LabelCorr.Caption:='—';
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
  FReady:=True;
  ObserveUiLanguage(Self,@LanguageChanged);
  Resize;
end;

procedure TRideMetricsHud.LanguageChanged(Sender: TObject);
begin
  Resize;
end;

procedure TRideMetricsHud.Resize;
var Available, S, NumberWidth, UnitWidth, RowX: Single; I: Integer;
  procedure Place(const C: TCastleUserInterface; const X, Y, W, H: Single);
  begin
    C.Width:=W*S; C.Height:=H*S; C.Anchor(hpLeft,X*S); C.Anchor(vpTop,-Y*S);
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
    Available:=HudWidth+400;
    if Parent<>nil then Available:=Parent.EffectiveWidth;
    S:=Min(1,Max(0.1,(Available-24)/HudWidth));
    { The container's reference-size scaling applies again when rendering.
      Counteract only its automatic enlargement; preserve the user's
      explicit accessibility scale and shrinking in smaller windows. }
    S:=Min(S,HudMaxPixelWidth*UserInterfaceScale/(HudWidth*Max(0.01,UIScale)));
    FLayoutScale:=S;
    Width:=HudWidth*S; Height:=HudHeight*S;
    if Available>=HudWidth*S+340 then Anchor(vpTop,-12)
    else Anchor(vpTop,-108);
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
    Place(FSpeedIcon,20,10,23,23);
    Text(FSpeedTitle,51,7,74,28,14);
    Text(FLabels.LabelSpeed,126,4,92,32,28);
    Text(FSpeedUnits,226,7,45,28,14);
    Place(FWorkIcon,292,10,22,23);
    Text(FWorkTitle,322,7,66,28,14);
    Text(FLabels.LabelWork,391,4,134,32,28);
    Text(FWorkUnits,533,7,40,28,14);
    Text(FTSSTitle,594,7,32,28,14);
    Text(FLabels.LabelWorkTSS,632,4,88,32,28);
    Place(FGradeIcon,748,10,23,23);
    Text(FGradeTitle,779,7,72,28,14);
    Text(FLabels.LabelSlope,850,4,85,32,28);
    Text(FLabels.LabelCorr,938,7,50,28,13);
  finally
    FArranging:=False;
  end;
end;

procedure TRideMetricsHud.Render;
var R: TFloatRectangle; S, LineWidth: Single; I: Integer;
const HeaderDividers: array[0..2] of Single = (278,582,732);
begin
  inherited;
  R:=RenderRect; S:=FLayoutScale*UIScale; LineWidth:=Max(1,S);
  DrawMenuPanel(R,12*S,HudEdge);
  DrawMenuPanel(R.Grow(-LineWidth),Max(0,12*S-LineWidth),HudSurface);
  DrawRectangle(FloatRectangle(R.Left+1,R.Top-HudHeaderHeight*S,R.Width-2,LineWidth),HudEdge);
  for I:=0 to 2 do
    DrawRectangle(FloatRectangle(R.Left+HeaderDividers[I]*S,R.Top-33*S,
      LineWidth,24*S),HudEdge);
  for I:=1 to 2 do
    DrawRectangle(FloatRectangle(R.Left+I*R.Width/3,R.Bottom+12*S,
      LineWidth,80*S),HudEdge);
end;

end.
