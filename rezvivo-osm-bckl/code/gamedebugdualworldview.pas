unit GameDebugDualWorldView;

interface

uses
  Classes, SysUtils,
  CastleViewport, CastleTransform, CastleScene, CastleShapes, CastleColors,
  CastleVectors;

type
  TDualWorldDebugVisualMode = (
    dvmClientOnly,
    dvmServerOnly,
    dvmBoth
  );

  TDualWorldDebugView = class
  private
    FOwner: TComponent;
    FViewport: TCastleViewport;

    FClientTransform: TCastleTransform;
    FClientScene: TCastleScene;

    FServerTransform: TCastleTransform;
    FServerScene: TCastleScene;

    FDistanceMarker: TCastleSphere;
    FMode: TDualWorldDebugVisualMode;

    procedure ApplyVisibility;
  public
    constructor Create(AOwner: TComponent; const AViewport: TCastleViewport);
    destructor Destroy; override;

    procedure SetClientVisual(const ATransform: TCastleTransform; const AScene: TCastleScene);
    procedure CreateServerVisualFrom(const ASourceScene: TCastleScene);

    procedure UpdateServerVisual(const Position, Direction: TVector3);
    procedure UpdateClientVisual(const Position, Direction: TVector3);
    procedure UpdateDistanceMarker(const ClientPos, ServerPos: TVector3);

    procedure SetMode(const AMode: TDualWorldDebugVisualMode);
    procedure ToggleMode;

    function ServerTransform: TCastleTransform;
    function ServerScene: TCastleScene;
    function Mode: TDualWorldDebugVisualMode;
  end;

implementation

constructor TDualWorldDebugView.Create(AOwner: TComponent; const AViewport: TCastleViewport);
begin
  inherited Create;
  FOwner := AOwner;
  FViewport := AViewport;
  FMode := dvmBoth;
end;

destructor TDualWorldDebugView.Destroy;
begin
  inherited;
end;

procedure TDualWorldDebugView.SetClientVisual(const ATransform: TCastleTransform; const AScene: TCastleScene);
begin
  FClientTransform := ATransform;
  FClientScene := AScene;
  ApplyVisibility;
end;

procedure TDualWorldDebugView.CreateServerVisualFrom(const ASourceScene: TCastleScene);
begin
  if not Assigned(FViewport) then Exit;

  if not Assigned(FServerTransform) then
  begin
    FServerTransform := TCastleTransform.Create(FOwner);
    FServerTransform.Name := 'ServerDebugTransform';
    FViewport.Items.Add(FServerTransform);
  end;

  if not Assigned(FServerScene) then
  begin
    FServerScene := TCastleScene.Create(FOwner);
    FServerScene.Name := 'ServerDebugScene';

    if Assigned(ASourceScene) then
      FServerScene.Load(ASourceScene.Url, true);

    FServerScene.Pickable := false;
    FServerScene.Collides := false;

    FServerTransform.Add(FServerScene);
  end;

  if not Assigned(FDistanceMarker) then
  begin
    FDistanceMarker := TCastleSphere.Create(FOwner);
    FDistanceMarker.Name := 'DualWorldDistanceMarker';
    FDistanceMarker.Radius := 0.15;
    FDistanceMarker.Color := Yellow;
    FDistanceMarker.Pickable := false;
    FDistanceMarker.Collides := false;
    FDistanceMarker.CastShadows := false;
    FViewport.Items.Add(FDistanceMarker);
  end;

  ApplyVisibility;
end;

procedure TDualWorldDebugView.UpdateServerVisual(const Position, Direction: TVector3);
begin
  if not Assigned(FServerTransform) then Exit;

  FServerTransform.Translation := Position;
  FServerTransform.Direction := Direction;
end;

procedure TDualWorldDebugView.UpdateClientVisual(const Position, Direction: TVector3);
begin
  if not Assigned(FClientTransform) then Exit;

  FClientTransform.Translation := Position;
  FClientTransform.Direction := Direction;
end;

procedure TDualWorldDebugView.UpdateDistanceMarker(const ClientPos, ServerPos: TVector3);
var
  MidPos: TVector3;
begin
  if not Assigned(FDistanceMarker) then Exit;

  MidPos := (ClientPos + ServerPos) * 0.5;
  FDistanceMarker.Translation := MidPos;

  if (ClientPos - ServerPos).Length > 1.0 then
    FDistanceMarker.Color := Red
  else
  if (ClientPos - ServerPos).Length > 0.2 then
    FDistanceMarker.Color := Yellow
  else
    FDistanceMarker.Color := Green;
end;

procedure TDualWorldDebugView.ApplyVisibility;
begin
  if Assigned(FClientTransform) then
    FClientTransform.Exists := FMode in [dvmClientOnly, dvmBoth];

  if Assigned(FServerTransform) then
    FServerTransform.Exists := FMode in [dvmServerOnly, dvmBoth];

  if Assigned(FDistanceMarker) then
    FDistanceMarker.Exists := FMode = dvmBoth;
end;

procedure TDualWorldDebugView.SetMode(const AMode: TDualWorldDebugVisualMode);
begin
  FMode := AMode;
  ApplyVisibility;
end;

procedure TDualWorldDebugView.ToggleMode;
begin
  case FMode of
    dvmClientOnly: SetMode(dvmServerOnly);
    dvmServerOnly: SetMode(dvmBoth);
    dvmBoth: SetMode(dvmClientOnly);
  end;
end;

function TDualWorldDebugView.ServerTransform: TCastleTransform;
begin
  Result := FServerTransform;
end;

function TDualWorldDebugView.ServerScene: TCastleScene;
begin
  Result := FServerScene;
end;

function TDualWorldDebugView.Mode: TDualWorldDebugVisualMode;
begin
  Result := FMode;
end;

end.
