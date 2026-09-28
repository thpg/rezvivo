unit GameZoneWheel;

{$mode objfpc}{$H+}

interface

uses Classes, CastleUIControls, CastleControls, CastleColors, CastleGLImages,
  CastleGLUtils, CastleRenderContext;

type
  TZoneWheelOrientation = (woVertical, woHorizontal);

  { A reusable reel with either orientation. Zero-based sectors are supplied by the caller;
    a negative selection displays an optional no-signal sector before sector zero. No telemetry dependency. }
  TCastleZoneWheel = class(TCastleUserInterfaceFont)
  private
    FColors: array of TCastleColor;
    FNumbers: array of String;
    FShowNumbers, FShowNoSignalSector: Boolean;
    FSelected: Integer;
    FPosition, FTargetPosition: Single;
    FOrientation, FShadeOrientation: TZoneWheelOrientation;
    FShade: TDrawableImage;
    FClip: TScissor;
    procedure EnsureShade;
    procedure SetSelected(const Value: Integer);
    procedure SetShowNumbers(const Value: Boolean);
    procedure SetShowNoSignalSector(const Value: Boolean);
    procedure SetTargetPosition(const Value: Single);
    procedure SetOrientation(const Value: TZoneWheelOrientation);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Configure(const Colors: array of TCastleColor;
      const AShowNumbers: Boolean);
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    procedure Render; override;
    procedure GLContextClose; override;
  published
    property Selected: Integer read FSelected write SetSelected;
    property Position: Single read FPosition;
    // Fractional positions are retained; no detents or integer rounding.
    property TargetPosition: Single read FTargetPosition write SetTargetPosition;
    property Orientation: TZoneWheelOrientation read FOrientation write SetOrientation;
    property ShowNoSignalSector: Boolean read FShowNoSignalSector write SetShowNoSignalSector;
    property ShowNumbers: Boolean read FShowNumbers write SetShowNumbers;
  end;

implementation

uses SysUtils, Math, CastleVectors, CastleRectangles, CastleImages;

constructor TCastleZoneWheel.Create(AOwner: TComponent);
begin
  inherited;
  Width:=30; Height:=56; FontSize:=24;
  FSelected:=-1; FShowNumbers:=True; FPosition:=-1; FTargetPosition:=-1;
  FClip:=TScissor.Create;
end;

destructor TCastleZoneWheel.Destroy;
begin
  FreeAndNil(FShade);
  FreeAndNil(FClip);
  inherited;
end;

procedure TCastleZoneWheel.GLContextClose;
begin
  FreeAndNil(FShade);
  inherited;
end;

procedure TCastleZoneWheel.Configure(const Colors: array of TCastleColor;
  const AShowNumbers: Boolean);
var I: Integer;
begin
  SetLength(FColors,Length(Colors)); SetLength(FNumbers,Length(Colors));
  for I:=0 to High(Colors) do
  begin FColors[I]:=Colors[I]; FNumbers[I]:=IntToStr(I+1) end;
  FShowNumbers:=AShowNumbers; FSelected:=-1; FPosition:=-1; FTargetPosition:=-1;
  VisibleChange([chRender]);
end;

procedure TCastleZoneWheel.SetShowNumbers(const Value: Boolean);
begin
  if FShowNumbers=Value then Exit;
  FShowNumbers:=Value;
  VisibleChange([chRender]);
end;

procedure TCastleZoneWheel.SetShowNoSignalSector(const Value: Boolean);
begin
  if FShowNoSignalSector=Value then Exit;
  FShowNoSignalSector:=Value;
  if FSelected<0 then begin FPosition:=-1; FTargetPosition:=-1 end;
  VisibleChange([chRender]);
end;

procedure TCastleZoneWheel.SetOrientation(const Value: TZoneWheelOrientation);
begin
  if FOrientation=Value then Exit;
  FOrientation:=Value;
  VisibleChange([chRender]);
end;

procedure TCastleZoneWheel.SetSelected(const Value: Integer);
begin
  if (Value<0) or (Value>=Length(FColors)) then
  begin
    if FSelected<0 then Exit;
    FSelected:=-1; FTargetPosition:=-1; VisibleChange([chRender]);
  end else SetTargetPosition(Value);
end;

procedure TCastleZoneWheel.SetTargetPosition(const Value: Single);
var V: Single;
begin
  if (Length(FColors)=0) or IsNan(Value) or IsInfinite(Value) then
  begin SetSelected(-1); Exit end;
  V:=EnsureRange(Value,-0.5,Length(FColors)-0.5);
  if (FSelected>=0) and (V=FTargetPosition) then Exit;
  if (FSelected<0) and not FShowNoSignalSector then FPosition:=V;
  FTargetPosition:=V;
  FSelected:=EnsureRange(Floor(V+0.5),0,High(FColors));
  VisibleChange([chRender]);
end;

procedure TCastleZoneWheel.Update(const SecondsPassed: Single; var HandleInput: Boolean);
begin
  inherited;
  if ((FSelected<0) and not FShowNoSignalSector) or (FPosition=FTargetPosition) then Exit;
  FPosition:=FPosition+(FTargetPosition-FPosition)*(1-Exp(-14*Max(0,SecondsPassed)));
  if Abs(FTargetPosition-FPosition)<0.001 then FPosition:=FTargetPosition;
  VisibleChange([chRender]);
end;

procedure TCastleZoneWheel.EnsureShade;
var Img: TRGBAlphaImage; X,Y,W,H: Integer; V,E,A: Single;
begin
  if (FShade<>nil) and (FShadeOrientation=FOrientation) then Exit;
  FreeAndNil(FShade); FShadeOrientation:=FOrientation;
  if FOrientation=woHorizontal then begin W:=128; H:=32 end
  else begin W:=32; H:=128 end;
  Img:=TRGBAlphaImage.Create(W,H);
  try
    for Y:=0 to H-1 do for X:=0 to W-1 do
    begin
      if FOrientation=woHorizontal then
      begin V:=Abs((X+0.5)/64-1); E:=Abs((Y+0.5)/16-1) end
      else begin V:=Abs((Y+0.5)/64-1); E:=Abs((X+0.5)/16-1) end;
      A:=Min(0.88,0.80*Power(V,2.5)+0.22*Power(E,12));
      Img.Colors[X,Y,0]:=Vector4(0,0,0,A);
    end;
    FShade:=TDrawableImage.Create(Img,True,True); Img:=nil;
  finally Img.Free end;
end;

procedure TCastleZoneWheel.Render;
const SectorAngle=Pi/2.4;
var R,Inside,Sector: TFloatRectangle; I,FirstSector: Integer;
  A,B,P0,P1,CX,CY,Radius,Scale,TextX,TextY,HalfIcon: Single;
  NoSignalHalfWidth, ViewPosition, SectorCenter: Single;
  C: TCastleColor; S: String; Horizontal: Boolean;
begin
  inherited;
  R:=RenderRect;
  if (R.Width<4) or (R.Height<4) then Exit;
  Horizontal:=FOrientation=woHorizontal;
  Scale:=Min(R.Width/Max(Width,1),R.Height/Max(Height,1));
  Inside:=FloatRectangle(R.Left+Scale,R.Bottom+Scale,R.Width-2*Scale,R.Height-2*Scale);
  DrawRectangle(R,Vector4(0.035,0.045,0.055,0.96));
  FClip.Rect:=Inside.Round; FClip.Enabled:=True;
  try
    CX:=Inside.Left+Inside.Width*0.5; CY:=Inside.Bottom+Inside.Height*0.5;
    if Horizontal then Radius:=Inside.Width*0.5 else Radius:=Inside.Height*0.5;
    if (FSelected<0) and (not FShowNoSignalSector or (Length(FColors)=0)) then
    begin
      DrawRectangle(Inside,Vector4(0.24,0.27,0.30,1));
      if FShowNumbers then Font.Print(CX-Font.TextWidth('-')*0.5,
        CY-Font.TextHeight('-')*0.5,White,'-');
    end else
    begin
    FirstSector:=0; if FShowNoSignalSector then FirstSector:=-1;
    // The missing-data sector shares the first zone's boundary at -0.5.
    // Its projected width equals the window's short side when centred.
    NoSignalHalfWidth:=Min(0.5,ArcSin(Min(1,Min(Inside.Width,Inside.Height)/(2*Radius)))/SectorAngle);
    ViewPosition:=FPosition;
    if FShowNoSignalSector and (FPosition<-0.5) then
      ViewPosition:=-0.5+(FPosition+0.5)*2*NoSignalHalfWidth;
    for I:=Max(FirstSector,Floor(FPosition)-2) to Min(High(FColors),Ceil(FPosition)+2) do
    begin
      if I=-1 then
      begin
        SectorCenter:=-0.5-NoSignalHalfWidth;
        A:=(-0.5-2*NoSignalHalfWidth-ViewPosition)*SectorAngle;
        B:=(-0.5-ViewPosition)*SectorAngle;
      end else
      begin
        SectorCenter:=I;
        A:=(I-ViewPosition-0.5)*SectorAngle;
        B:=(I-ViewPosition+0.5)*SectorAngle;
      end;
      if (A>=Pi/2) or (B<=-Pi/2) then Continue;
      if Horizontal then
      begin
        P0:=CX+Sin(Max(A,-Pi/2))*Radius; P1:=CX+Sin(Min(B,Pi/2))*Radius;
        Sector:=FloatRectangle(P0,Inside.Bottom,P1-P0,Inside.Height);
      end else
      begin
        P0:=CY-Sin(Min(B,Pi/2))*Radius; P1:=CY-Sin(Max(A,-Pi/2))*Radius;
        Sector:=FloatRectangle(Inside.Left,P0,Inside.Width,P1-P0);
      end;
      if I=-1 then DrawRectangle(Sector,White)
      else DrawRectangle(Sector,FColors[I]);
      if Horizontal then
        DrawRectangle(FloatRectangle(P0,Inside.Bottom,Scale,Inside.Height),Vector4(0,0,0,0.28))
      else DrawRectangle(FloatRectangle(Inside.Left,P0,Inside.Width,Scale),Vector4(0,0,0,0.28));
      A:=(SectorCenter-ViewPosition)*SectorAngle;
      if (I=-1) and (Abs(A)<Pi/2) then
      begin
        // A font-independent red cross, also visible on unnumbered reels.
        TextX:=CX; TextY:=CY;
        if Horizontal then TextX:=TextX+Sin(A)*Radius else TextY:=TextY-Sin(A)*Radius;
        HalfIcon:=Min(10*Scale,Min(Inside.Width,Inside.Height)*0.45);
        HalfIcon:=HalfIcon*0.65;
        C:=Vector4(0.9,0.025,0.035,1);
        DrawPrimitive2D(pmTriangleFan,
          [Vector2(TextX-HalfIcon,TextY-HalfIcon+Scale), Vector2(TextX-HalfIcon+Scale,TextY-HalfIcon),
           Vector2(TextX+HalfIcon,TextY+HalfIcon-Scale), Vector2(TextX+HalfIcon-Scale,TextY+HalfIcon)],C);
        DrawPrimitive2D(pmTriangleFan,
          [Vector2(TextX-HalfIcon,TextY+HalfIcon-Scale), Vector2(TextX+HalfIcon-Scale,TextY-HalfIcon),
           Vector2(TextX+HalfIcon,TextY-HalfIcon+Scale), Vector2(TextX-HalfIcon+Scale,TextY+HalfIcon)],C);
      end else
      if (I>=0) and FShowNumbers and (Abs(A)<Pi/2) then
      begin
        C:=FColors[I];
        if C.X*0.2126+C.Y*0.7152+C.Z*0.0722>0.58 then C:=Vector4(0.06,0.07,0.08,1)
        else C:=White;
        S:=FNumbers[I]; TextX:=CX-Font.TextWidth(S)*0.5; TextY:=CY-Font.TextHeight(S)*0.5;
        if Horizontal then TextX:=TextX+Sin(A)*Radius else TextY:=TextY-Sin(A)*Radius;
        Font.Print(TextX,TextY,C,S);
      end;
    end;
    end;
    EnsureShade; FShade.Draw(Inside);
  finally FClip.Enabled:=False end;
  DrawRectangleOutline(R,Vector4(0.62,0.68,0.73,0.85),Scale);
  // Fixed centre tick belongs to the bezel, never scrolls with the sectors.
  if Horizontal then
    DrawRectangle(FloatRectangle(R.Left+R.Width*0.5-Scale,R.Bottom,2*Scale,3*Scale),White)
  else DrawRectangle(FloatRectangle(R.Right-3*Scale,R.Bottom+R.Height*0.5-Scale,3*Scale,2*Scale),White);
end;

end.
