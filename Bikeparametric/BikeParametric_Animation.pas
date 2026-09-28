unit BikeParametric_Animation;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, CastleUtils, CastleVectors, X3DNodes,
  fpjson,
  BikeParametric;

type
  TAnimationComponent = class(TBikeComponent)
  private
    FCrankCycleInterval: Single;  { seconds per crank revolution, default 1.20 }
    { ── Physics / simulation (moved from TBikeParams) ── }
    FRiderWeight: Single;        { kg, rider body weight, default 75 }
    FBikeWeight: Single;         { kg, bike + equipment, default 10 }
    FDragCoefficient: Single;    { Cd, aerodynamic drag coefficient, default 0.88 }
    FFrontalArea: Single;        { m², frontal area, default 0.40 }
    FRollingResistance: Single;  { Crr, tire rolling resistance, default 0.005 }
  public
    constructor Create; override;
    class function ComponentName: string; override;
    procedure BuildGeometry(Ctx: TBikeBuildContext); override;
    procedure ParamsToJSON(Obj: TJSONObject); override;
    procedure ParamsFromJSON(Obj: TJSONObject); override;
  published
    property CrankCycleInterval: Single read FCrankCycleInterval write FCrankCycleInterval;
    { ── Physics / simulation (moved from TBikeParams) ── }
    property RiderWeight: Single read FRiderWeight write FRiderWeight;
    property BikeWeight: Single read FBikeWeight write FBikeWeight;
    property DragCoefficient: Single read FDragCoefficient write FDragCoefficient;
    property FrontalArea: Single read FFrontalArea write FFrontalArea;
    property RollingResistance: Single read FRollingResistance write FRollingResistance;
  end;

const
  { seconds per crank revolution — единый источник: Create компонента и
    TBikeInstance.FBaseCrankCycle (BikeParametric, implementation-uses) }
  DEF_CRANK_CYCLE_INTERVAL = 1.20;

implementation

constructor TAnimationComponent.Create;
begin
  inherited Create;
  FCrankCycleInterval := DEF_CRANK_CYCLE_INTERVAL;
  FRiderWeight        := 75.0;
  FBikeWeight         := 10.0;
  FDragCoefficient    := 0.88;
  FFrontalArea        := 0.40;
  FRollingResistance  := 0.005;
end;

class function TAnimationComponent.ComponentName: string; begin Result := 'Animation'; end;

procedure TAnimationComponent.ParamsToJSON(Obj: TJSONObject);
begin
  Obj.Add('CrankCycleInterval', CrankCycleInterval);
  Obj.Add('RiderWeight',        RiderWeight);
  Obj.Add('BikeWeight',         BikeWeight);
  Obj.Add('DragCoefficient',    DragCoefficient);
  Obj.Add('FrontalArea',        FrontalArea);
  Obj.Add('RollingResistance',  RollingResistance);
end;

procedure TAnimationComponent.ParamsFromJSON(Obj: TJSONObject);
var D: TJSONData;
begin
  D := Obj.Find('CrankCycleInterval'); if D <> nil then CrankCycleInterval := D.AsFloat;
  D := Obj.Find('RiderWeight');        if D <> nil then RiderWeight        := D.AsFloat;
  D := Obj.Find('BikeWeight');         if D <> nil then BikeWeight         := D.AsFloat;
  D := Obj.Find('DragCoefficient');    if D <> nil then DragCoefficient    := D.AsFloat;
  D := Obj.Find('FrontalArea');        if D <> nil then FrontalArea        := D.AsFloat;
  D := Obj.Find('RollingResistance');  if D <> nil then RollingResistance  := D.AsFloat;
end;

procedure TAnimationComponent.BuildGeometry(Ctx: TBikeBuildContext);
begin
  { этап 4 (GPU-анимация): TimeSensor/OrientationInterpolator/ROUTE-цепочка
    УДАЛЕНА. Вращение колёс/шатунов/педалей выполняют:
      - GPU-путь: TGpuBikeSpin (BikeGpuSpin.pas) — вершинный шейдер из фаз
        TBikeInstance.FPhase/FWheelPhase;
      - CPU-путь: TBikeInstance.DriveSpinNodesCPU — те же углы пишутся в
        именованные трансформы (RearWheelRot/FrontWheelRot/CranksRot/
        PedalRightRot/PedalLeftRot) из накопителя фазы.
    Параметр CrankCycleInterval остаётся источником FBaseCrankCycle. }
end;

end.
