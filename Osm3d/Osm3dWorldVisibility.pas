unit Osm3dWorldVisibility;
{$mode objfpc}{$H+}
interface

uses X3DNodes;

type
  TWorldRenderLayer = (wrlTrees, wrlGrass, wrlBuildings, wrlOther, wrlGround);

function WorldLayerVisible(const Layer: TWorldRenderLayer): Boolean;
function SetWorldLayerVisible(const Layer: TWorldRenderLayer; const Value: Boolean): Boolean;
function WorldGeometryHidden: Boolean;
procedure ApplyWorldVisibility(Root: TX3DNode);
procedure MarkWorldBuilding(Root: TX3DNode);

implementation

uses SysUtils, Osm3dStudioSettings;

const
  BuildingKey = 'rezvivo.render.building';
  HiddenKey = 'rezvivo.render.hiddenByLayer';
var
  BuildingsVisible: Boolean = True;
  OtherVisible: Boolean = True;
  GroundVisible: Boolean = True;

type
  TVisibilityVisitor = class
    procedure Apply(Node: TX3DNode);
    procedure MarkBuilding(Node: TX3DNode);
  end;

function WorldLayerVisible(const Layer: TWorldRenderLayer): Boolean;
begin
  case Layer of
    wrlTrees: Result := RenderTreesActive;
    wrlGrass: Result := RenderGrassActive;
    wrlBuildings: Result := BuildingsVisible;
    wrlOther: Result := OtherVisible;
    wrlGround: Result := GroundVisible;
  end;
end;

function SetWorldLayerVisible(const Layer: TWorldRenderLayer; const Value: Boolean): Boolean;
begin
  Result := WorldLayerVisible(Layer) <> Value;
  case Layer of
    wrlTrees: RenderTreesActive := Value;
    wrlGrass: RenderGrassActive := Value;
    wrlBuildings: BuildingsVisible := Value;
    wrlOther: OtherVisible := Value;
    wrlGround: GroundVisible := Value;
  end;
end;

function WorldGeometryHidden: Boolean;
begin
  Result := not BuildingsVisible or not OtherVisible or not GroundVisible;
end;

procedure TVisibilityVisitor.Apply(Node: TX3DNode);
var S: TAbstractShapeNode; Name: String; Wanted: Boolean;
begin
  S := TAbstractShapeNode(Node);
  Name := S.X3DName;
  if Pos('WorldCaster_', Name) = 1 then Delete(Name, 1, Length('WorldCaster_'));
  if S.MetadataBoolean[BuildingKey] or
     (Pos('AtlasBuilding', Name) = 1) or
     (Name = 'BuildingNearDetails') or (Name = 'ArchitectureFallback') then
    Wanted := BuildingsVisible
  else if (Name = 'GroundComposite') or (Name = 'DreamGround') or
          (Name = 'DreamGroundCaster') then
    Wanted := GroundVisible
  else
    Wanted := OtherVisible;
  { Visible affects CGE rendering and RTX source enumeration, but
    leaves collision geometry and the light rig intact. Only restore shapes
    hidden by us: invisible contact helpers must never become visible. }
  if not Wanted and S.Visible then
  begin
    S.MetadataBoolean[HiddenKey] := True;
    S.Visible := False;
  end else if Wanted and S.MetadataBoolean[HiddenKey] then
  begin
    S.MetadataBoolean[HiddenKey] := False;
    S.Visible := True;
  end;
end;

procedure TVisibilityVisitor.MarkBuilding(Node: TX3DNode);
begin
  TAbstractShapeNode(Node).MetadataBoolean[BuildingKey] := True;
end;

procedure ApplyWorldVisibility(Root: TX3DNode);
var Visitor: TVisibilityVisitor;
begin
  if Root = nil then Exit;
  Visitor := TVisibilityVisitor.Create;
  try
    { Only on a toggle or a newly mounted tile, never in the render loop. }
    Root.EnumerateNodes(TAbstractShapeNode, @Visitor.Apply, False);
  finally Visitor.Free; end;
end;

procedure MarkWorldBuilding(Root: TX3DNode);
var Visitor: TVisibilityVisitor;
begin
  if Root = nil then Exit;
  Visitor := TVisibilityVisitor.Create;
  try Root.EnumerateNodes(TAbstractShapeNode, @Visitor.MarkBuilding, False);
  finally Visitor.Free; end;
end;

end.
