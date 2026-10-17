unit Osm3dReflectionCandidates;
{$mode objfpc}{$H+}
interface
uses Classes, Generics.Collections, CastleScene, CastleTransform, CastleBoxes,
  CastleVectors, CastleFrustum;
type
  TReflectionSceneEntry=class
    Scene:TCastleScene;
    Identity,Revision,MaterialRevision,Seen:QWord;
    Bounds:array of TBox3D;
  end;
  TReflectionSceneEntries=specialize TObjectDictionary<TCastleScene,TReflectionSceneEntry>;
  { Conservative candidate bounds, never GPU visibility results. Stores local
    boxes only; changing origin/parent transform uses the current WorldTransform. }
  TOsmReflectionCandidates=class(TComponent)
  private
    FEntries:TReflectionSceneEntries;
    FVisit:QWord;
    FFrustum:TFrustum;
    FFound:Boolean;
    FRetired:array of TCastleScene;
    procedure Visit(Node:TCastleTransform);
  protected
    procedure Notification(AComponent:TComponent;Operation:TOperation);override;
  public
    Rebuilds,Hits,EmptyViews:QWord;
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure Clear;
    function HasCandidates(World:TCastleTransform;const Frustum:TFrustum):Boolean;
  end;
implementation
uses SysUtils, CastleShapes, Osm3dRtxMaterials;
constructor TOsmReflectionCandidates.Create(AOwner:TComponent);
begin inherited;FEntries:=TReflectionSceneEntries.Create([doOwnsValues]) end;
destructor TOsmReflectionCandidates.Destroy;
begin Clear;FEntries.Free;inherited end;
procedure TOsmReflectionCandidates.Clear;
var Scene:TCastleScene;
begin
  for Scene in FEntries.Keys do Scene.RemoveFreeNotification(Self);
  FEntries.Clear;
end;
procedure TOsmReflectionCandidates.Notification(AComponent:TComponent;Operation:TOperation);
begin
  inherited;
  if (Operation=opRemove) and (AComponent is TCastleScene) and (FEntries<>nil) then
    FEntries.Remove(TCastleScene(AComponent));
end;
procedure TOsmReflectionCandidates.Visit(Node:TCastleTransform);
var Scene:TCastleScene;E:TReflectionSceneEntry;Shapes:TShapeList;S:TShape;
  I,N:Integer;B:TBox3D;
begin
  if (Node=nil) or not Node.ExistsInRoot then Exit;
  if Node is TCastleScene then begin
    Scene:=TCastleScene(Node);
    if not FEntries.TryGetValue(Scene,E) then begin
      E:=TReflectionSceneEntry.Create;E.Scene:=Scene;Scene.FreeNotification(Self);FEntries.Add(Scene,E);
    end;
    E.Seen:=FVisit;
    if (E.Identity<>Scene.InternalSnapshotIdentity) or (E.Revision<>Scene.InternalSnapshotRevision) or
       (E.MaterialRevision<>RtxMaterialRevision) then begin
      E.Bounds:=nil;
      { Include inactive/hidden shapes too: visibility alone may change without
        a geometry revision and can only create extra false-positive candidates. }
      if Scene.Shapes<>nil then begin
        Shapes:=Scene.Shapes.TraverseList(False,False,False);
        SetLength(E.Bounds,Shapes.Count);N:=0;
        for S in Shapes do if IsRtxReflector(S) then begin
          E.Bounds[N]:=S.BoundingBox;Inc(N);
        end;
        SetLength(E.Bounds,N);
      end;
      E.Identity:=Scene.InternalSnapshotIdentity;E.Revision:=Scene.InternalSnapshotRevision;
      E.MaterialRevision:=RtxMaterialRevision;Inc(Rebuilds);
    end else Inc(Hits);
    if not FFound then
      for I:=0 to High(E.Bounds) do begin
        B:=E.Bounds[I];
        { Empty/dynamic bounds cannot prove absence. }
        if B.IsEmpty or not Scene.HasWorldTransform then begin FFound:=True;Break end;
        B:=B.Transform(Scene.WorldTransform);
        if FFrustum.Box3DCollisionPossibleSimple(B) then begin FFound:=True;Break end;
      end;
  end;
  for I:=0 to Node.Count-1 do Visit(Node[I]);
end;
function TOsmReflectionCandidates.HasCandidates(World:TCastleTransform;const Frustum:TFrustum):Boolean;
var Pair:specialize TPair<TCastleScene,TReflectionSceneEntry>;
  N,I:Integer;
begin
  Inc(FVisit);FFrustum:=Frustum;FFound:=False;Visit(World);
  { Unlinked but not yet destroyed scenes must not grow this cache forever. }
  N:=0;if Length(FRetired)<FEntries.Count then SetLength(FRetired,FEntries.Count);
  for Pair in FEntries do if Pair.Value.Seen<>FVisit then begin FRetired[N]:=Pair.Key;Inc(N) end;
  for I:=0 to N-1 do begin FRetired[I].RemoveFreeNotification(Self);FEntries.Remove(FRetired[I]);FRetired[I]:=nil end;
  Result:=FFound;if not Result then Inc(EmptyViews);
end;
end.
