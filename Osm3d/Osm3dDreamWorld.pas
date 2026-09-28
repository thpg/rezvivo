unit Osm3dDreamWorld;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,SyncObjs,fpjson,CastleVectors,Osm3dTileX3D,Osm3dGroundComposite,
  Osm3dBuildingComposite,Osm3dFenceComposite,Osm3dSoundscape;
type
  TDreamPoints = array of TVector3;
  TDreamMaterial = record
    Color:TVector3;
    Roughness,Metallic:Single;
    Walkable,Water,CastShadow:Boolean;
    GroundMaterial,GrassMaterial:Integer;
    BuildingMaterial,FenceMaterial,GrassKind:Integer;
    WaterScale:Single;
  end;
  TDreamTile = record
    Model:TTileModel;
    Soundscape:TSoundscapeField;
    Offset:TVector3;
    Directory:string;
  end;
  TDreamWorld = class
  private
    FManifest:TJSONObject;
    FDirectory:string;
    FTriangles:array of record A,B,C:TVector3; end;
    FBins:array of array of Integer;
    FMinX,FMinZ,FCellX,FCellZ:Single;
    FGridX,FGridZ:Integer;
    procedure BuildGround(Cancel:TThread);
  public
    Id,Title,Description,ManifestPath:string;
    Revision,RoadCondition:Integer;
    Coastal:Boolean;
    Tiles:array of TDreamTile;
    Points:TDreamPoints;
    Width,LengthM:Single;
    Sun,PreviewPosition,PreviewTarget:TVector3;
    TriangleCount,VertexCount:Integer;
    GroundAtlas:TGroundAtlas;
    BuildingAtlas:TBuildingAtlas;
    FenceAtlas:TFenceAtlas;
    constructor Create(const FileName:string;Cancel:TThread=nil);
    destructor Destroy;override;
    function Material(const MeshName:string):TDreamMaterial;
    function GroundNearYAt(X,Z,ReferenceY:Single;out Y:Single):Boolean;
    function Diagnostics:TJSONObject;
    function EnvironmentSoundsAt(const P:TVector3):TEnvironmentMix;
    procedure PrepareMaterials(Cancel:TThread=nil);
    function ModelFile(TileIndex,InstanceIndex:Integer):string;
  end;
  TDreamWorldTask = class(TThread)
  private
    FPath,FError:string;
    FWorld:TDreamWorld;
    FLock:TCriticalSection;
    FDone:Boolean;
  protected
    procedure Execute;override;
    function LoadWorld:TDreamWorld;virtual;
    procedure JoinWithoutEvents;
  public
    constructor Create(const FileName:string);
    destructor Destroy;override;
    function Done:Boolean;
    function Cancelled:Boolean;
    function Take:TDreamWorld;
    function Error:string;
  end;
function DreamWorldFiles(const Directory:string):TStringList;
implementation
uses {$IFDEF MSWINDOWS}Windows,{$ENDIF}Math,jsonparser,Osm3dGeomMesh;
type TThreadAccess=class(TThread);
procedure CheckCancel(Cancel:TThread);
begin if(Cancel<>nil)and TThreadAccess(Cancel).Terminated then raise EAbort.Create('World loading cancelled');end;
function Vec(J:TJSONData;const Default:TVector3):TVector3;
begin
  Result:=Default;
  if J=nil then Exit;
  if not(J is TJSONArray)or(J.Count<>3)then raise Exception.Create('Expected a three-component world vector');
  Result:=Vector3(J.Items[0].AsFloat,J.Items[1].AsFloat,J.Items[2].AsFloat);
  if IsNan(Result.X)or IsNan(Result.Y)or IsNan(Result.Z)or
     IsInfinite(Result.X)or IsInfinite(Result.Y)or IsInfinite(Result.Z)then
    raise Exception.Create('Non-finite world coordinate');
end;
function DreamWorldFiles(const Directory:string):TStringList;
var S:TSearchRec;Path:string;
begin
  Result:=TStringList.Create;
  if FindFirst(IncludeTrailingPathDelimiter(Directory)+'*',faDirectory,S)=0 then
  try repeat
    if(S.Name='.')or(S.Name='..')or(S.Attr and faDirectory=0)then Continue;
    Path:=IncludeTrailingPathDelimiter(Directory)+S.Name+PathDelim+'world.json';
    if FileExists(Path)then Result.Add(Path);
  until FindNext(S)<>0;
  finally SysUtils.FindClose(S);end;
  Result.Sort;
end;
constructor TDreamWorld.Create(const FileName:string;Cancel:TThread);
var F:TFileStream;J:TJSONData;A:TJSONArray;O,R:TJSONObject;I,K:Integer;Path,Rel:string;
    P,Q:TVector3;Measured:Double;
begin
  inherited Create;ManifestPath:=ExpandFileName(FileName);
  FDirectory:=IncludeTrailingPathDelimiter(ExtractFilePath(ManifestPath));
  F:=TFileStream.Create(ManifestPath,fmOpenRead or fmShareDenyWrite);
  try
    if F.Size>4*1024*1024 then raise Exception.Create('World manifest is too large');
    J:=GetJSON(F);
  finally F.Free;end;
  if not(J is TJSONObject)then begin J.Free;raise Exception.Create('Invalid world manifest');end;
  FManifest:=TJSONObject(J);
  if(FManifest.Get('format','')<>'rezvivo-dream-world')or(FManifest.Get('version',0)<>1)or
    (FManifest.Get('coordinates','')<>'local-metres-y-up')then raise Exception.Create('Unsupported Dream World format');
  Id:=FManifest.Get('id','');Title:=FManifest.Get('title',Id);Description:=FManifest.Get('description','');
  if(Id='')or(Length(Id)>80)then raise Exception.Create('Invalid world id');
  for I:=1 to Length(Id)do if not(Id[I]in['a'..'z','0'..'9','-','_'])then raise Exception.Create('Invalid world id');
  Revision:=FManifest.Get('revision',1);
  Coastal:=FManifest.Get('coastal',Id='castle-island');
  RoadCondition:=FManifest.Get('road_condition',0);
  if(RoadCondition<0)or(RoadCondition>5)then raise Exception.Create('Invalid road condition');
  Sun:=Vec(FManifest.Find('sun'),Vector3(-0.55,0.75,-0.35));
  if Sun.Length<0.01 then raise Exception.Create('Invalid world sunlight');Sun:=Sun.Normalize;
  O:=FManifest.Get('preview',TJSONObject(nil));
  PreviewPosition:=Vector3(350,245,390);PreviewTarget:=Vector3(0,18,0);
  if O<>nil then begin PreviewPosition:=Vec(O.Find('position'),PreviewPosition);PreviewTarget:=Vec(O.Find('target'),PreviewTarget);end;
  R:=FManifest.Get('route',TJSONObject(nil));
  if R=nil then raise Exception.Create('World has no route');
  if not R.Get('closed',False)then raise Exception.Create('Dream World v1 requires a closed route');
  A:=R.Get('points',TJSONArray(nil));
  if(A=nil)or(A.Count<4)or(A.Count>100000)then raise Exception.Create('Invalid world route');
  Width:=R.Get('width',7.0);if(Width<1)or(Width>100)then raise Exception.Create('Invalid route width');
  SetLength(Points,A.Count);Measured:=0;
  for I:=0 to A.Count-1 do begin
    Points[I]:=Vec(A.Items[I],TVector3.Zero);
    if not(A.Items[I]is TJSONArray)then raise Exception.Create('Invalid route point');
    if I>0 then begin P:=Points[I]-Points[I-1];Measured:=Measured+P.Length;end;
  end;
  P:=Points[0]-Points[High(Points)];
  if P.Length>0.01 then raise Exception.Create('World route is not closed');
  if Measured<10 then raise Exception.Create('World route is too short');LengthM:=Measured;
  A:=FManifest.Get('tiles',TJSONArray(nil));
  if(A=nil)or(A.Count=0)or(A.Count>256)then raise Exception.Create('Invalid world tile list');
  SetLength(Tiles,A.Count);
  for I:=0 to A.Count-1 do begin
    CheckCancel(Cancel);
    if not(A.Items[I]is TJSONObject)then raise Exception.Create('Invalid world tile');O:=TJSONObject(A.Items[I]);
    Rel:=O.Get('file','');Path:=ExpandFileName(FDirectory+Rel);
    if(Rel='')or(Pos(':',Rel)>0)or(Rel[1]in['/','\'])or
      not SameText(Copy(Path,1,Length(FDirectory)),FDirectory)then raise Exception.Create('Tile path leaves its world');
    F:=TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite);
    try
      if F.Size>128*1024*1024 then raise Exception.Create('World tile is too large');
      Tiles[I].Model:=TTileX3D.LoadStream(F);
    finally F.Free;end;
    Tiles[I].Offset:=Vec(O.Find('offset'),TVector3.Zero);
    Tiles[I].Directory:=ExtractFilePath(Path);
    for K:=0 to High(Tiles[I].Model.ModelInstances)do begin
      CheckCancel(Cancel);ModelFile(I,K);
    end;
    for K:=0 to Tiles[I].Model.MeshCount-1 do begin
      Inc(TriangleCount,Tiles[I].Model.Meshes[K].Mesh.TriangleCount);
      Inc(VertexCount,Tiles[I].Model.Meshes[K].Mesh.VertexCount);
    end;
  end;
  CheckCancel(Cancel);BuildGround(Cancel);
  for I:=0 to High(Tiles)do begin
    CheckCancel(Cancel);
    Tiles[I].Soundscape:=TSoundscapeField.Create(Tiles[I].Model,1,
      FManifest.Get('urban_sounds',False),Coastal);
  end;
  for I:=0 to High(Points)do begin
    P:=Points[I];
    if not GroundNearYAt(P.X,P.Z,P.Y,Q.Y)or(Abs(Q.Y-P.Y)>0.20)then
      raise Exception.CreateFmt('Route is outside the baked surface at point %d',[I]);
  end;
end;
function TDreamWorld.ModelFile(TileIndex,InstanceIndex:Integer):string;
var Rel,Ext:string;
begin
  Rel:=Tiles[TileIndex].Model.ModelInstances[InstanceIndex].FileName;
  Result:=ExpandFileName(Tiles[TileIndex].Directory+Rel);
  if(Rel='')or(Pos(':',Rel)>0)or(Rel[1]in['/','\'])or
    not SameText(Copy(Result,1,Length(FDirectory)),FDirectory)then
    raise Exception.Create('Model path leaves its world');
  Ext:=LowerCase(ExtractFileExt(Result));
  if(Ext<>'.glb')and(Ext<>'.x3d')then raise Exception.Create('Expected a GLB or X3D model');
  if not FileExists(Result)then raise Exception.Create('World model is missing: '+Rel);
end;

destructor TDreamWorld.Destroy;
var I:Integer;
begin for I:=0 to High(Tiles)do begin Tiles[I].Soundscape.Free;Tiles[I].Model.Free;end;
  GroundAtlas.Free;BuildingAtlas.Free;FenceAtlas.Free;FManifest.Free;inherited;end;

function TDreamWorld.EnvironmentSoundsAt(const P:TVector3):TEnvironmentMix;
var I:Integer;Q:TVector3;Mix:TEnvironmentMix;
begin
  Result:=Default(TEnvironmentMix);
  for I:=0 to High(Tiles)do if Tiles[I].Soundscape<>nil then begin
    Q:=P-Tiles[I].Offset;Mix:=Tiles[I].Soundscape.Sample(Q.X,Q.Y,Q.Z);
    MergeEnvironment(Result,Mix);
  end;
end;
procedure TDreamWorld.PrepareMaterials(Cancel:TThread);
var I,J:Integer;Needed,Buildings,Fences:Boolean;CacheDir:string;M:TDreamMaterial;
begin
  if GroundAtlas<>nil then Exit;
  Needed:=False;Buildings:=False;Fences:=False;
  for I:=0 to High(Tiles)do for J:=0 to Tiles[I].Model.MeshCount-1 do begin
    M:=Material(Tiles[I].Model.Meshes[J].Name);
    Needed:=Needed or(M.GroundMaterial>=0);
    Buildings:=Buildings or(M.BuildingMaterial>=0);Fences:=Fences or(M.FenceMaterial>=0);
  end;
  CacheDir:=ExtractFilePath(ParamStr(0))+'cache'+PathDelim+'dream-materials';
  if Buildings and(BuildingAtlas=nil)then begin
    CheckCancel(Cancel);BuildingAtlas:=TBuildingAtlas.Create(DefaultBuildingAtlasLayout);
    if not BuildingAtlas.TryLoadFromCache(CacheDir,nil)then begin
      BuildingAtlas.BuildChannelsParallel(nil);CheckCancel(Cancel);BuildingAtlas.SaveToCache(CacheDir,nil);
    end;
  end;
  if Fences and(FenceAtlas=nil)then begin
    CheckCancel(Cancel);FenceAtlas:=TFenceAtlas.Create(DefaultFenceAtlasLayout);
    if not FenceAtlas.TryLoadFromCache(CacheDir,nil)then begin
      FenceAtlas.BuildChannelsParallel(nil);CheckCancel(Cancel);FenceAtlas.SaveToCache(CacheDir,nil);
    end;
  end;
  if not Needed then Exit;
  CheckCancel(Cancel);
  GroundAtlas:=TGroundAtlas.Create(DefaultGroundAtlasLayout);
  CacheDir:=ExtractFilePath(ParamStr(0))+'cache'+PathDelim+'dream-materials';
  if not GroundAtlas.TryLoadFromCache(CacheDir,nil)then begin
    GroundAtlas.BuildChannelsParallel(nil);CheckCancel(Cancel);
    GroundAtlas.SaveToCache(CacheDir,nil);
  end;
  CheckCancel(Cancel);
end;
function TDreamWorld.Material(const MeshName:string):TDreamMaterial;
var Entries,Mats,O,M:TJSONObject;Name:string;
begin
  Result.Color:=Vector3(0.6,0.6,0.6);Result.Roughness:=0.9;Result.Metallic:=0;
  Result.Walkable:=False;Result.Water:=False;Result.CastShadow:=True;
  Result.GroundMaterial:=-1;Result.GrassMaterial:=-1;
  Result.BuildingMaterial:=-1;Result.FenceMaterial:=-1;Result.GrassKind:=-1;Result.WaterScale:=-1;
  Entries:=FManifest.Get('meshes',TJSONObject(nil));Mats:=FManifest.Get('materials',TJSONObject(nil));
  if(Entries=nil)or(Mats=nil)then Exit;O:=Entries.Get(MeshName,TJSONObject(nil));if O=nil then Exit;
  Result.Walkable:=O.Get('walkable',False);Result.Water:=O.Get('water',False);
  Result.CastShadow:=O.Get('cast_shadow',not Result.Walkable and not Result.Water);
  Result.GroundMaterial:=O.Get('ground_material',-1);Result.GrassMaterial:=O.Get('grass_material',-1);
  Result.BuildingMaterial:=O.Get('building_material',-1);Result.FenceMaterial:=O.Get('fence_material',-1);
  Result.GrassKind:=O.Get('grass_kind',-1);Result.WaterScale:=O.Get('water_scale',-1.0);
  if(Result.BuildingMaterial<-1)or(Result.BuildingMaterial>=BUILDING_MAT_COUNT)or
    (Result.FenceMaterial<-1)or(Result.FenceMaterial>=6)or
    (Result.GrassKind<-1)or(Result.GrassKind>=8)or
    IsNan(Result.WaterScale)or IsInfinite(Result.WaterScale)or
    ((Result.WaterScale<>-1)and((Result.WaterScale<0)or(Result.WaterScale>1)))then
    raise Exception.Create('Invalid Dream World sample material');
  if(Result.GroundMaterial<-1)or(Result.GroundMaterial>=GROUND_MAT_COUNT)or
    (Result.GrassMaterial<-1)or(Result.GrassMaterial>=GROUND_MAT_COUNT)then
    raise Exception.Create('Invalid Dream World ground material');
  Name:=O.Get('material','');M:=Mats.Get(Name,TJSONObject(nil));if M=nil then Exit;
  Result.Color:=Vec(M.Find('color'),Result.Color);
  Result.Roughness:=EnsureRange(M.Get('roughness',0.9),0.0,1.0);
  Result.Metallic:=EnsureRange(M.Get('metallic',0.0),0.0,1.0);
end;
procedure TDreamWorld.BuildGround(Cancel:TThread);
var I,J,K,T,N,X,Z,X0,X1,Z0,Z1,B:Integer;R:TTileMeshRec;V:TMeshVertexArray;Idx:TMeshIndexArray;
    P,A,C:TVector3;MaxX,MaxZ,LoX,LoZ,HiX,HiZ:Single;Counts:array of Integer;
begin
  N:=0;
  for I:=0 to High(Tiles)do for J:=0 to Tiles[I].Model.MeshCount-1 do begin
    R:=Tiles[I].Model.Meshes[J];if Material(R.Name).Walkable then Inc(N,R.Mesh.TriangleCount);
  end;
  if N=0 then raise Exception.Create('World has no rideable geometry');
  SetLength(FTriangles,N);T:=0;FMinX:=1e30;FMinZ:=1e30;MaxX:=-1e30;MaxZ:=-1e30;
  for I:=0 to High(Tiles)do for J:=0 to Tiles[I].Model.MeshCount-1 do begin
    CheckCancel(Cancel);R:=Tiles[I].Model.Meshes[J];if not Material(R.Name).Walkable then Continue;
    V:=R.Mesh.Vertices;Idx:=R.Mesh.Indices;
    for K:=0 to R.Mesh.TriangleCount-1 do begin
      FTriangles[T].A:=V[Idx[K*3]].Position+Tiles[I].Offset;
      FTriangles[T].B:=V[Idx[K*3+1]].Position+Tiles[I].Offset;
      FTriangles[T].C:=V[Idx[K*3+2]].Position+Tiles[I].Offset;
      P:=FTriangles[T].A;A:=FTriangles[T].B;C:=FTriangles[T].C;
      FMinX:=Min(FMinX,Min(P.X,Min(A.X,C.X)));MaxX:=Max(MaxX,Max(P.X,Max(A.X,C.X)));
      FMinZ:=Min(FMinZ,Min(P.Z,Min(A.Z,C.Z)));MaxZ:=Max(MaxZ,Max(P.Z,Max(A.Z,C.Z)));Inc(T);
    end;
  end;
  FGridX:=EnsureRange(Ceil((MaxX-FMinX)/8),1,512);FGridZ:=EnsureRange(Ceil((MaxZ-FMinZ)/8),1,512);
  FCellX:=Max(0.01,(MaxX-FMinX)/FGridX);FCellZ:=Max(0.01,(MaxZ-FMinZ)/FGridZ);
  SetLength(FBins,FGridX*FGridZ);SetLength(Counts,Length(FBins));
  for T:=0 to High(FTriangles)do begin
    if T mod 1024=0 then CheckCancel(Cancel);
    P:=FTriangles[T].A;A:=FTriangles[T].B;C:=FTriangles[T].C;
    LoX:=Min(P.X,Min(A.X,C.X));HiX:=Max(P.X,Max(A.X,C.X));LoZ:=Min(P.Z,Min(A.Z,C.Z));HiZ:=Max(P.Z,Max(A.Z,C.Z));
    X0:=EnsureRange(Floor((LoX-FMinX)/FCellX),0,FGridX-1);X1:=EnsureRange(Floor((HiX-FMinX)/FCellX),0,FGridX-1);
    Z0:=EnsureRange(Floor((LoZ-FMinZ)/FCellZ),0,FGridZ-1);Z1:=EnsureRange(Floor((HiZ-FMinZ)/FCellZ),0,FGridZ-1);
    for Z:=Z0 to Z1 do for X:=X0 to X1 do begin B:=Z*FGridX+X;
      if Counts[B]=Length(FBins[B])then SetLength(FBins[B],Counts[B]*2+8);
      FBins[B][Counts[B]]:=T;Inc(Counts[B]);
    end;
  end;
  for B:=0 to High(FBins)do SetLength(FBins[B],Counts[B]);
end;
function TDreamWorld.GroundNearYAt(X,Z,ReferenceY:Single;out Y:Single):Boolean;
var BX,BZ,I,T:Integer;A,B,C:TVector3;Den,U,V,H,Distance,Best:Double;
begin
  Result:=False;Y:=ReferenceY;
  if(FGridX=0)or(FGridZ=0)then Exit;
  BX:=Floor((X-FMinX)/FCellX);BZ:=Floor((Z-FMinZ)/FCellZ);
  if(BX<0)or(BX>=FGridX)or(BZ<0)or(BZ>=FGridZ)then Exit;Best:=1e30;
  for I:=0 to High(FBins[BZ*FGridX+BX])do begin
    T:=FBins[BZ*FGridX+BX][I];A:=FTriangles[T].A;B:=FTriangles[T].B;C:=FTriangles[T].C;
    Den:=(B.Z-C.Z)*(A.X-C.X)+(C.X-B.X)*(A.Z-C.Z);if Abs(Den)<1e-10 then Continue;
    U:=((B.Z-C.Z)*(X-C.X)+(C.X-B.X)*(Z-C.Z))/Den;
    V:=((C.Z-A.Z)*(X-C.X)+(A.X-C.X)*(Z-C.Z))/Den;
    if(U<-0.00001)or(V<-0.00001)or(U+V>1.00001)then Continue;
    H:=U*A.Y+V*B.Y+(1-U-V)*C.Y;Distance:=Abs(H-ReferenceY);
    { Surfaces within 8 cm belong to the same contact level; prefer the top
      paving over the terrain underneath, without jumping between storeys. }
    if not Result or(Distance<Best-0.08)or((Abs(Distance-Best)<=0.08)and(H>Y))then begin
      Y:=H;Best:=Distance;Result:=True;
    end;
  end;
end;
function TDreamWorld.Diagnostics:TJSONObject;
begin Result:=TJSONObject.Create(['id',Id,'revision',Revision,'title',Title,'tiles',Length(Tiles),
  'road_condition',RoadCondition,
  'vertices',VertexCount,'triangles',TriangleCount,'route_points',Length(Points),'route_length_m',LengthM,
  'coordinates','local-metres-y-up','network_generation',False]);end;
constructor TDreamWorldTask.Create(const FileName:string);
begin inherited Create(True);FreeOnTerminate:=False;FPath:=FileName;FLock:=SyncObjs.TCriticalSection.Create;end;
procedure TDreamWorldTask.JoinWithoutEvents;
begin
  Terminate;
  { Constructor failure/cancellation may free a task before Start. Let the
    RTL exit it without executing the cancelled CPU load. }
  if Suspended then Start;
  {$IFDEF MSWINDOWS}
  { This worker has no Synchronize/OnTerminate dependency. The ordinary
    TThread.WaitFor dispatches UI messages on Windows, allowing reentry into
    a page or viewport while its destructor is still releasing its scene. }
  if Handle<>0 then Windows.WaitForSingleObject(Handle,INFINITE);
  {$ELSE}
  WaitFor;
  {$ENDIF}
end;
destructor TDreamWorldTask.Destroy;
begin JoinWithoutEvents;FWorld.Free;FLock.Free;inherited;end;
function TDreamWorldTask.LoadWorld:TDreamWorld;
begin
  Result:=TDreamWorld.Create(FPath,Self);
  try Result.PrepareMaterials(Self);except Result.Free;raise;end;
end;
procedure TDreamWorldTask.Execute;
begin
  try try FWorld:=LoadWorld;
  except on E:Exception do begin FError:=E.Message;FreeAndNil(FWorld);end;end;
  finally FLock.Enter;try FDone:=True;finally FLock.Leave;end;end;
end;
function TDreamWorldTask.Cancelled:Boolean;
begin Result:=Terminated;end;
function TDreamWorldTask.Done:Boolean;
{ The RTL can skip Execute if Terminate wins the race with thread startup. }
begin
  FLock.Enter;try Result:=FDone or Finished;finally FLock.Leave;end;
  {$IFDEF MSWINDOWS}
  { FDone and TThread.Finished are both published before native thread exit.
    A UI handoff must never block/pump events waiting for that final tail. }
  if Result then Result:=Windows.WaitForSingleObject(Handle,0)=WAIT_OBJECT_0;
  {$ENDIF}
end;
function TDreamWorldTask.Take:TDreamWorld;
begin if not Done then Exit(nil);Result:=FWorld;FWorld:=nil;end;
function TDreamWorldTask.Error:string;
begin if Done then Result:=FError else Result:='';end;
end.
