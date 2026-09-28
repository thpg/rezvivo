{ GameWorkoutPreview — виджет визуализации профиля мощности тренировки.

  Каждый сегмент тренировки рисуется как столбец (или трапеция для
  warmup/cooldown/ramp) высотой пропорциональной мощности, шириной
  пропорциональной длительности.

  Дополнения по сравнению с базовой отрисовкой:
   • Под каждым сегментом — однопиксельная тень со смещением (+1, −1).
     Это делает гистограмму чуть «объёмной», как в референсе с
     mywhooshinfo.
   • При наведении мыши на конкретный сегмент он подсвечивается
     инверсной реакцией: слегка темнеет и «опускается» на 2 px вниз —
     создаётся эффект продавливания. Идентификация сегмента под
     курсором делается в Motion(), сама отрисовка — в Render().

  Цветовая палитра по зонам FTP:
    < 55%   — серый      (recovery, free ride)
    55–75%  — тёмно-синий (endurance, zone 2)
    75–90%  — голубой    (tempo, sweetspot)
    90–105% — зелёный    (threshold)
    105–120% — оранжевый (VO2max)
    > 120%  — красный    (anaerobic) }
unit GameWorkoutPreview;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils,
  CastleUIControls, CastleControls, CastleVectors, CastleColors,
  CastleRectangles, CastleKeysMouse,
  WorkoutFile;

type
  TWorkoutPreview = class(TCastleUserInterface)
  private
    FWorkout:    TWorkoutFile;
    FShowGrid:   Boolean;
    FMaxPower:   Single;   { верхний край шкалы; 1.5 = 150% FTP }
    FFtpWatts:   Integer;  { FTP пользователя в ваттах }
    FHoverIndex: Integer;  { индекс сегмента под мышью, -1 = нет }
    FPlaybackIndex: Integer; { -1: static preview; count: completed workout }
    FPlaybackTime, FIntensity: Single;

    { Хинт со значением мощности под курсором. }
    FTooltipBg:    TCastleRectangleControl;
    FTooltipLabel: TCastleLabel;
    FTooltipX:     Single;   { локальная X-координата кончика стрелки }

    function PowerToY(Power, MaxBarHeight: Single): Single;
    function SegmentAtX(LocalX, ChartLeft, ChartW: Single): Integer;
    function SegmentCenterLocalX(Index: Integer; Pad, ChartW: Single): Single;
    procedure UpdateTooltip;
  public
    constructor Create(AOwner: TComponent); override;

    procedure LoadWorkout(AWorkout: TWorkoutFile);
    procedure SetPlayback(Index: Integer; StageTime, Intensity: Single);
    procedure Render; override;
    function Motion(const Event: TInputMotion): Boolean; override;
    procedure Update(const SecondsPassed: Single;
      var HandleInput: Boolean); override;

    property ShowGrid: Boolean read FShowGrid write FShowGrid;
    property MaxPower: Single  read FMaxPower write FMaxPower;
    property FtpWatts: Integer read FFtpWatts write FFtpWatts;
    property Workout: TWorkoutFile read FWorkout;
  end;

implementation

uses
  Math,CastleGLUtils,GameMenuTheme,UiTranslations,GameWorkoutColors;

const
  EDGE_INSET      = 1.0;    { ширина тёмной обводки вокруг сегмента, px }
  MIN_INSET_WIDTH = 4.0;    { уже которой обводку не рисуем }
  HOVER_SINK      = 2.0;    { насколько «продавливается» сегмент при hover, px }
  HOVER_DARKEN    = 0.18;   { насколько затемняется цвет при hover (0..1) }

constructor TWorkoutPreview.Create(AOwner: TComponent);
begin
  inherited;
  FShowGrid := False;
  FMaxPower := 1.5;
  FFtpWatts := 260;
  FHoverIndex := -1;
  FPlaybackIndex := -1;
  FIntensity := 1;
  Width := 300;
  Height := 80;

  { Хинт: светло-жёлтая плашка с тёмным текстом. Прячется по умолчанию,
    показывается в UpdateTooltip когда мышь над сегментом. }
  FTooltipBg := TMenuPanel.Create(Self);
  FTooltipBg.Color := MenuSurface;  { светло-жёлтый }
  FTooltipBg.Width := 160;
  FTooltipBg.Height := 28;
  FTooltipBg.Exists := False;
  InsertFront(FTooltipBg);

  FTooltipLabel := TMenuLabel.Create(Self);
  FTooltipLabel.Color := MenuText;
  FTooltipLabel.FontScale := 0.85;
  FTooltipLabel.Anchor(hpMiddle);
  FTooltipLabel.Anchor(vpMiddle);
  FTooltipBg.InsertFront(FTooltipLabel);
end;

procedure TWorkoutPreview.LoadWorkout(AWorkout: TWorkoutFile);
begin
  FWorkout := AWorkout;
  FHoverIndex := -1;
  FPlaybackIndex := -1;
  FPlaybackTime := 0;
  FIntensity := 1;
  if Assigned(FTooltipBg) then
    FTooltipBg.Exists := False;
  VisibleChange([chRender]);
end;

procedure TWorkoutPreview.SetPlayback(Index: Integer; StageTime, Intensity: Single);
var Changed: Boolean; I: Integer;
begin
  Changed := (FPlaybackIndex <> Index) or (FPlaybackTime <> StageTime) or
    (FIntensity <> Intensity);
  if not Changed then Exit;
  if ((FPlaybackIndex<0) or (FIntensity<>Intensity)) and (FWorkout<>nil) then begin
    FMaxPower:=1.5;
    for I:=0 to FWorkout.Segments.Count-1 do
      FMaxPower:=Max(FMaxPower,1.05*Intensity*Max(FWorkout.Segments[I].PowerLow,
        FWorkout.Segments[I].PowerHigh));
  end;
  if FIntensity <> Intensity then begin
    FIntensity := Intensity;
    if FHoverIndex >= 0 then UpdateTooltip;
  end;
  FPlaybackIndex := Index;
  FPlaybackTime := StageTime;
  VisibleChange([chRender]);
end;


function TWorkoutPreview.PowerToY(Power, MaxBarHeight: Single): Single;
var
  Norm: Single;
begin
  Norm := Power / Max(0.01, FMaxPower);
  if Norm < 0 then Norm := 0;
  if Norm > 1 then Norm := 1;
  Result := Norm * MaxBarHeight;
end;

{ Какой сегмент находится под локальной X-координатой? Локальная — то
  есть отсчитанная от левого края chart-области (R.Left + Pad). }
function TWorkoutPreview.SegmentAtX(
  LocalX, ChartLeft, ChartW: Single): Integer;
var
  I: Integer;
  AccumX, BarW, TotalDur: Single;
  Seg: TWorkoutSegment;
begin
  Result := -1;
  if not Assigned(FWorkout) then Exit;
  if FWorkout.Segments.Count = 0 then Exit;
  TotalDur := FWorkout.TotalDuration;
  if TotalDur <= 0 then Exit;

  AccumX := ChartLeft;
  for I := 0 to FWorkout.Segments.Count - 1 do
  begin
    Seg := FWorkout.Segments[I];
    BarW := (Seg.Duration / TotalDur) * ChartW;
    if (LocalX >= AccumX) and (LocalX < AccumX + BarW) then
      Exit(I);
    AccumX := AccumX + BarW;
  end;
end;

{ Возвращает X-координату центра сегмента Index в локальной системе
  координат виджета (X отсчитывается от левого края виджета).
  Используется для привязки подсказки к центру сегмента. }
function TWorkoutPreview.SegmentCenterLocalX(
  Index: Integer; Pad, ChartW: Single): Single;
var
  I: Integer;
  AccumX, BarW, TotalDur: Single;
  Seg: TWorkoutSegment;
begin
  Result := 0;
  if not Assigned(FWorkout) then Exit;
  if (Index < 0) or (Index >= FWorkout.Segments.Count) then Exit;
  TotalDur := FWorkout.TotalDuration;
  if TotalDur <= 0 then Exit;

  AccumX := Pad;  { локальный X-старт chart-области }
  for I := 0 to Index do
  begin
    Seg := FWorkout.Segments[I];
    BarW := (Seg.Duration / TotalDur) * ChartW;
    if I = Index then
      Exit(AccumX + BarW / 2);
    AccumX := AccumX + BarW;
  end;
end;

procedure TWorkoutPreview.UpdateTooltip;
var
  Seg: TWorkoutSegment;
  W1, W2: Integer;
  Txt, DurStr: String;
  TooltipW, TooltipH: Single;
  ParentW, X: Single;
begin
  if (FHoverIndex < 0) or (not Assigned(FWorkout)) or
     (FHoverIndex >= FWorkout.Segments.Count) then
  begin
    FTooltipBg.Exists := False;
    Exit;
  end;

  Seg := FWorkout.Segments[FHoverIndex];

  { Время интервала в начале строки: "30s" для коротких,
    "1:30" / "5:00" / "12:00" для более длинных. }
  if Seg.Duration < 60 then
    DurStr := Format(UiText('%ds'), [Round(Seg.Duration)])
  else
    DurStr := FormatWorkoutDuration(Seg.Duration);

  { Формируем текст. Ватты считаем как FFtpWatts × доля FTP. }
  case Seg.Kind of
    wskSteady, wskInterval:
      begin
        W1 := Round(FFtpWatts * Seg.PowerLow * FIntensity);
        if FFtpWatts>0 then Txt := Format('%s | %dW (%d%%)',[DurStr,W1,Round(Seg.PowerLow*FIntensity*100)])
        else Txt:=Format('%s | %d%%',[DurStr,Round(Seg.PowerLow*FIntensity*100)]);
      end;
    wskWarmup, wskCooldown, wskRamp:
      begin
        W1 := Round(FFtpWatts * Seg.PowerLow * FIntensity);
        W2 := Round(FFtpWatts * Seg.PowerHigh * FIntensity);
        if FFtpWatts>0 then Txt := Format('%s | %dW (%d%%) → %dW (%d%%)',
          [DurStr,
           W1, Round(Seg.PowerLow * FIntensity * 100),
           W2, Round(Seg.PowerHigh * FIntensity * 100)])
        else Txt:=Format('%s | %d%% → %d%%',[DurStr,Round(Seg.PowerLow*FIntensity*100),Round(Seg.PowerHigh*FIntensity*100)]);
      end;
    wskFreeRide:
      Txt := DurStr+' | '+UiText('Free Ride');
  else
    Txt := '';
  end;

  if Txt = '' then
  begin
    FTooltipBg.Exists := False;
    Exit;
  end;

  FTooltipLabel.Caption := Txt;

  { Прикидочная ширина: примерно 9 px на символ при FontScale 0.85,
    плюс по 14 px полей с каждой стороны. С запасом, чтобы стрелка → 
    и широкие символы тоже влезли. }
  TooltipW := Length(Txt) * 9.0 + 28;
  TooltipH := 28;
  FTooltipBg.Width := TooltipW;
  FTooltipBg.Height := TooltipH;

  { Позиционируем по горизонтали — следуем за курсором, но не вылазим
    за пределы виджета. По вертикали — внутри виджета, прижато к верху,
    с небольшим отступом от его верхнего края. }
  ParentW := EffectiveWidth;
  X := FTooltipX - TooltipW / 2;
  if X < 0 then X := 0;
  if X + TooltipW > ParentW then X := Max(0, ParentW - TooltipW);

  FTooltipBg.Anchor(hpLeft, X);
  FTooltipBg.Anchor(vpTop, -8);  { плашка висит в верхней части виджета }
  FTooltipBg.Exists := True;
end;

function TWorkoutPreview.Motion(const Event: TInputMotion): Boolean;
var
  R: TFloatRectangle;
  Pad, ChartW: Single;
  NewIndex: Integer;
begin
  Result := inherited;
  if not Assigned(FWorkout) then Exit;

  R := RenderRect;
  Pad := 4;
  ChartW := R.Width - Pad * 2;
  if ChartW <= 0 then Exit;

  { Event.Position в координатах окна. RenderRect — экранный
    прямоугольник нашего виджета. Если позиция вне него — hover нет. }
  if not R.Contains(Event.Position) then
    NewIndex := -1
  else
    NewIndex := SegmentAtX(Event.Position.X, R.Left + Pad, ChartW);

  { Запоминаем X в локальных координатах (от левого края виджета). }
  FTooltipX := Event.Position.X - R.Left;

  if NewIndex <> FHoverIndex then
  begin
    FHoverIndex := NewIndex;

    { Центр текущего сегмента в локальных координатах виджета —
      туда поставим хинт. Считаем по той же логике что и SegmentAtX:
      проходим до нужного индекса и берём середину. }
    if FHoverIndex >= 0 then
    begin
      FTooltipX := SegmentCenterLocalX(FHoverIndex,
        Pad, ChartW);
    end;

    UpdateTooltip;
    VisibleChange([chRender]);
  end;
end;

procedure TWorkoutPreview.Update(const SecondsPassed: Single;
  var HandleInput: Boolean);
var
  R: TFloatRectangle;
  MousePos: TVector2;
begin
  inherited;

  { Motion НЕ приходит когда мышь покидает виджет — событие приходит
    только пока курсор над контролом. Поэтому раз в кадр сами проверяем
    положение мыши, и если она ушла за пределы — гасим hover и хинт.
    Без этой проверки подсказка «залипает» с последнего hover-сегмента. }
  if FHoverIndex < 0 then Exit;
  if not Assigned(Container) then Exit;

  MousePos := Container.MousePosition;
  R := RenderRect;
  if not R.Contains(MousePos) then
  begin
    FHoverIndex := -1;
    UpdateTooltip;
    VisibleChange([chRender]);
  end;
end;

procedure TWorkoutPreview.Render;
var
  R: TFloatRectangle;
  TotalDur, TimeBefore, X, BarW, ChartW, MaxBarH: Single;
  ChartBaseY, Y0, H1, H2, Inset, Brightness, Fraction, CursorX: Single;
  LowPower, HighPower: Single;
  I: Integer;
  Seg: TWorkoutSegment;
  Col, ShadowCol: TCastleColor;
  Playback, IsCurrent: Boolean;

  procedure DrawPart(const Amount, Light: Single);
  var RightX, RightH: Single; C: TCastleColor;
  begin
    RightX := X + BarW * Amount - Inset;
    if RightX <= X + Inset then Exit;
    RightH := H1 + (H2-H1) * Amount;
    C := Vector4(Col.X*Light, Col.Y*Light, Col.Z*Light, Col.W);
    DrawPrimitive2D(pmTriangleFan,
      [Vector2(X+Inset, Y0+Inset), Vector2(RightX, Y0+Inset),
       Vector2(RightX, Y0+Max(Inset, RightH-Inset)),
       Vector2(X+Inset, Y0+Max(Inset, H1-Inset))], C);
  end;

begin
  inherited;
  if (FWorkout=nil) or (FWorkout.Segments.Count=0) then Exit;
  R := RenderRect;
  ChartW := R.Width-8;
  MaxBarH := R.Height-8;
  if (ChartW<=0) or (MaxBarH<=0) then Exit;
  TotalDur := FWorkout.TotalDuration;
  if TotalDur<=0 then Exit;
  ChartBaseY := R.Bottom+4;
  Playback := FPlaybackIndex>=0;
  CursorX := R.Left+4;
  if FPlaybackIndex>=FWorkout.Segments.Count then CursorX:=CursorX+ChartW;
  if FShowGrid then
    DrawRectangle(FloatRectangle(R.Left+4, ChartBaseY+PowerToY(1,MaxBarH),
      ChartW, 1), Vector4(1,1,1,0.15));
  ShadowCol := Vector4(0,0,0,0.55);
  TimeBefore := 0;
  for I:=0 to FWorkout.Segments.Count-1 do begin
    Seg := FWorkout.Segments[I];
    { Use time boundaries, not minimum pixel widths: many short intervals must
      still end at the same point as the playback cursor and hit testing. }
    X := R.Left+4+ChartW*TimeBefore/TotalDur;
    BarW := ChartW*Seg.Duration/TotalDur;
    TimeBefore := TimeBefore+Seg.Duration;
    if BarW<=0 then Continue;
    IsCurrent := Playback and (I=FPlaybackIndex);
    Y0 := ChartBaseY;
    if (I=FHoverIndex) and not Playback then Y0:=Y0-HOVER_SINK;
    if BarW>=MIN_INSET_WIDTH then Inset:=EDGE_INSET else Inset:=0;
    LowPower := Seg.PowerLow*FIntensity;
    HighPower := LowPower;
    if Seg.Kind in [wskWarmup,wskCooldown,wskRamp] then
      HighPower:=Seg.PowerHigh*FIntensity;
    if Seg.Kind=wskFreeRide then begin LowPower:=0.55;HighPower:=0.55;end;
    H1:=PowerToY(LowPower,MaxBarH);H2:=PowerToY(HighPower,MaxBarH);
    Col:=WorkoutSegmentColor(Seg,FIntensity);
    if IsCurrent then
      DrawRectangle(FloatRectangle(X,ChartBaseY,BarW,MaxBarH),Vector4(1,1,1,0.05));
    if Inset>0 then
      DrawPrimitive2D(pmTriangleFan,
        [Vector2(X,Y0),Vector2(X+BarW,Y0),
         Vector2(X+BarW,Y0+H2),Vector2(X,Y0+H1)],ShadowCol);
    Brightness:=1;
    if Playback and (I>=FPlaybackIndex) then Brightness:=0.38;
    if I=FHoverIndex then Brightness:=Brightness*(1-HOVER_DARKEN);
    DrawPart(1,Brightness);
    if IsCurrent then begin
      Fraction:=EnsureRange(FPlaybackTime/Max(0.001,Seg.Duration),0.0,1.0);
      DrawPart(Fraction,1);
      CursorX:=X+BarW*Fraction;
      DrawRectangle(FloatRectangle(X,ChartBaseY-2,BarW,2),Vector4(1,1,1,0.5));
    end;
  end;
  if Playback then begin
    DrawRectangle(FloatRectangle(R.Left+4,R.Bottom,ChartW,2),Vector4(1,1,1,0.15));
    if CursorX>R.Left+4 then
      DrawRectangle(FloatRectangle(R.Left+4,R.Bottom,CursorX-R.Left-4,2),MenuAccent);
    { The marker follows actual stage time: pause freezes it, skip jumps to the
      next stage, and restarting returns to the beginning without interpolation. }
    DrawRectangle(FloatRectangle(CursorX-1,ChartBaseY,2,MaxBarH),White);
    DrawPrimitive2D(pmTriangles,
      [Vector2(CursorX-4,R.Top),Vector2(CursorX+4,R.Top),
       Vector2(CursorX,R.Top-5)],White);
  end;
end;

end.
