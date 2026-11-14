unit GameNeuralRiders;
{$mode objfpc}{$H+}
interface
uses Classes,fpjson,CastleUIControls;
function CreateNeuralRiderNoticeControl(AOwner:TComponent):TCastleUserInterface;
function NeuralRiderStatus:string;
function NeuralRiderDiagnostics:TJSONObject;
function CheckNeuralRiderReference(const Density:Integer;const FileName:string):Double;
implementation
uses SysUtils,Math,CastleVectors,CastleScene,CastleImages,CastleColors,CastleNotifications,
 X3DNodes,CastleURIUtils,CastleFilesUtils,CastleTimeUtils,
 AppSettings,UiTranslations,DebugLog,RiderTripo,RiderBodyParameters,TripoRig,
 NeuralSuitAsset,NeuralAnatomyMath,NeuralRigidMath;
type
 TNeuralPose=record
  Knee,Hip,HipSide,Ankle,AnkleRoll,Shoulder,ShoulderForward,ShoulderTwist,Elbow:array[0..1]of Double;
  Effort,Pedaling,PedalPhase,PelvisTilt,SpineBend:Double;
 end;
 TNeuralBoneState=record Pivot,Tip:TVec3 end;
 TNeuralMuscleState=record ActionGroup,ActionSide:Integer;AutoActivation,ManualActivation:Double end;
 TNeuralRider=class(TRiderSurfaceOverride)
 private
  Rider:TTripoRiderScene;Asset:TNeuralSuitAsset;Density:Integer;Epoch:Cardinal;
  MeshSwitch:TSwitchNode;Host:TAbstractGroupingNode;Coord:array[0..2]of TCoordinateNode;Normals:array[0..2]of TNormalNode;
  Materials:array[0..2]of TPhysicalMaterialNode;Texture:TPixelTextureNode;
  Shapes:array of TShapeNode;WasVisible:array of Boolean;Hidden:Boolean;
  Body:TRiderBodyParameters;BodyScale:Double;Rest,Pivots,Tips,Axes,Origins,Insertions:TVecArray;
  Transforms,PreviousRig:TRigTransforms;Previous,Older:TNeuralFloats;PreviousDt:Double;
  Bones:array of TNeuralBoneState;Muscles:array of TNeuralMuscleState;
  Pose:TNeuralPose;LegSupport,LegDemand,ArmDemand,ArmElevation,PedalPress:array[0..1]of Double;
  DynamicFrameActive:Boolean;TopColor,BottomColor:TVector3;HaveColors:Boolean;
  FramePositions,FrameNormals:TVecArray;LastMS:Double;Frames:QWord;LastEffort:Single;
  function BoneIndex(const Name:string):Integer;
  procedure GrabShape(Node:TX3DNode);
  procedure Release(const Restore:Boolean=True);
  procedure HideOriginal;
  procedure BindBody;
  procedure BuildScene;
  procedure Retarget;
  procedure UpdateMuscleDemand;
  function MuscleActivationFor(const Index:Integer;const Ratio:Double):Double;
  procedure Features(const Dt:Double;const Effort,Phase:Single;const BreathPhase:Double;out X:TNeuralFloats);
  procedure Display(const Y:TNeuralFloats);
  procedure UpdateColors;
 public
  constructor Create(ARider:TTripoRiderScene);
  destructor Destroy;override;
  function Active:Boolean;override;
  procedure Update(Dt,Effort,PedalPhase:Single;BreathPhase:Double);override;
 end;
 TNeuralRiderNotice=class(TCastleUserInterface)
 private
  Notice:TCastleNotifications;SeenEpoch:Cardinal;Announced:Boolean;NextCheck:QWord;
 public
  constructor Create(AOwner:TComponent);override;
  procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
 end;
var Assets:array[1..2]of TNeuralSuitAsset;Attempted:array[1..2]of Boolean;
 Errors:array[1..2]of string;CurrentMode:Integer=-1;ModeEpoch:Cardinal=0;
 Instances:TList;LoadCount:QWord=0;LastFailure:string='';
function DataDirectory(const Mode:Integer):string;
begin
 Result:=GetEnvironmentVariable('REZVIVO_NEURAL_RIDERS');
 if Result=''then Result:=URIToFilenameSafe(ApplicationData('neural-riders/'));
 Result:=IncludeTrailingPathDelimiter(Result);if Mode=1 then Result+='reduced'else Result+='dense';
end;
procedure SyncMode;
var M,I:Integer;
begin
 M:=0;if Settings<>nil then M:=Settings.GraphicsNeuralRiders;
 if M=CurrentMode then Exit;CurrentMode:=M;Inc(ModeEpoch);LastFailure:='';
 for I:=0 to Instances.Count-1 do TNeuralRider(Instances[I]).Release;
 for I:=1 to 2 do begin Attempted[I]:=False;Errors[I]:='';if(Assets[I]<>nil)and(Assets[I].Users=0)then FreeAndNil(Assets[I])end;
end;
function Acquire(const Mode:Integer):TNeuralSuitAsset;
var Directory:string;
begin
 Result:=nil;if not(Mode in[1,2])then Exit;
 if Assets[Mode]<>nil then begin Inc(Assets[Mode].Users);Exit(Assets[Mode])end;
 if Attempted[Mode]then Exit;Attempted[Mode]:=True;Directory:=DataDirectory(Mode);
 try
  Require(FileExists(Directory+'/suit.nn')and FileExists(Directory+'/suit.mesh'),'Missing suit.nn or suit.mesh: '+Directory);
  TNeuralSuitAsset.RequireGPU;
  Assets[Mode]:=TNeuralSuitAsset.Create(Directory);Inc(LoadCount);Assets[Mode].Users:=1;Result:=Assets[Mode];
  Logger.Info('[NeuralRiders] Loaded '+Directory);
 except on E:Exception do begin Errors[Mode]:=E.Message;LastFailure:=E.Message;Logger.Info('[NeuralRiders] Ordinary rider fallback: '+E.Message)end end;
end;
procedure Drop(var Asset:TNeuralSuitAsset;const Mode:Integer);
begin
 if Asset=nil then Exit;Dec(Asset.Users);Asset:=nil;
 if(Assets[Mode]<>nil)and(Assets[Mode].Users=0)and((CurrentMode<>Mode)or(Errors[Mode]<>''))then FreeAndNil(Assets[Mode]);
end;
function NeuralRiderStatus:string;
var Dir:string;
begin
 SyncMode;Result:='';if CurrentMode=0 then Exit;
 if(Assets[CurrentMode]<>nil)and(Errors[CurrentMode]='')then Exit;
 Dir:=DataDirectory(CurrentMode);
 if(Errors[CurrentMode]<>'')or not FileExists(Dir+'/suit.nn')or not FileExists(Dir+'/suit.mesh')then
  Result:=UiText('Neural rider models are missing or unavailable. Ordinary riders are used.');
end;
function NeuralRiderDiagnostics:TJSONObject;
var I,J,VisibleCount:Integer;R:TNeuralRider;A,Rows:TJSONArray;Row:TJSONObject;
begin
 SyncMode;Result:=TJSONObject.Create(['mode',CurrentMode,'model_loads',Int64(LoadCount),'message',NeuralRiderStatus,'error',LastFailure]);A:=TJSONArray.Create;Result.Add('models',A);
 for I:=1 to 2 do if Assets[I]<>nil then A.Add(TJSONObject.Create(['density',I,'users',Assets[I].Users,'vertices',Assets[I].VertexCount,'calls',Int64(Assets[I].Calls),'inference_ms',Assets[I].LastMS]));
 Rows:=TJSONArray.Create;Result.Add('riders',Rows);
 for I:=0 to Instances.Count-1 do begin
  R:=TNeuralRider(Instances[I]);VisibleCount:=0;
  for J:=0 to High(R.Shapes)do if R.Shapes[J].Visible then Inc(VisibleCount);
  Row:=TJSONObject.Create(['density',R.Density,'active',R.Hidden,'frames',Int64(R.Frames),'update_ms',R.LastMS,'sex',R.Body.Sex,'height_cm',R.Body.HeightCm,'inseam_cm',RiderBodyInseamCm(R.Body),
   'ordinary_shapes',Length(R.Shapes),'ordinary_visible',VisibleCount]);
  Row.Add('top_linear',TJSONArray.Create([R.TopColor.X,R.TopColor.Y,R.TopColor.Z]));
  Row.Add('bottom_linear',TJSONArray.Create([R.BottomColor.X,R.BottomColor.Y,R.BottomColor.Z]));
  Rows.Add(Row);
 end;
end;
function CheckNeuralRiderReference(const Density:Integer;const FileName:string):Double;
var A:TNeuralSuitAsset;
begin
 SyncMode;Require((CurrentMode=Density)and(Density in[1,2]),'Enable the requested neural density first');
 A:=Acquire(Density);Require(A<>nil,Errors[Density]);try Result:=A.CheckReference(FileName)finally Drop(A,Density)end;
end;
function NewSurface(Rider:TTripoRiderScene):TRiderSurfaceOverride;
begin SyncMode;Result:=nil;if CurrentMode<>0 then Result:=TNeuralRider.Create(Rider)end;
constructor TNeuralRiderNotice.Create(AOwner:TComponent);
begin
 inherited;FullSize:=True;CapturesEvents:=False;KeepInFront:=True;SeenEpoch:=High(Cardinal);
 Notice:=TCastleNotifications.Create(Self);Notice.CapturesEvents:=False;
 Notice.Anchor(hpMiddle);Notice.Anchor(vpTop,-150);Notice.TextAlignment:=hpMiddle;
 Notice.FontSize:=18;Notice.MaxMessages:=1;Notice.Timeout:=12;InsertFront(Notice);
end;
procedure TNeuralRiderNotice.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var Message:string;
begin
 inherited;SyncMode;
 if SeenEpoch<>ModeEpoch then begin SeenEpoch:=ModeEpoch;Announced:=False;NextCheck:=0;Notice.Clear end;
 if(CurrentMode=0)or Announced or(GetTickCount64<NextCheck)then Exit;
 NextCheck:=GetTickCount64+1000;Message:=NeuralRiderStatus;
 if Message<>''then begin Notice.Show(Message);Announced:=True end;
end;
function CreateNeuralRiderNoticeControl(AOwner:TComponent):TCastleUserInterface;
begin Result:=TNeuralRiderNotice.Create(AOwner)end;
function Smooth01(const Value:Double):Double;
var T:Double;begin T:=EnsureRange(Value,0.0,1.0);Result:=T*T*(3-2*T)end;
function Atlas(const P:TVector3):TVec3;inline;
begin Result:=V(-P.Z,P.Y,P.X)end;
function Bike(const P:TVec3):TVector3;inline;
begin Result:=Vector3(P.Z,P.Y,-P.X)end;
function FrameRotation(const Axis,Normal,Goal,GoalNormal:TVec3):TQuat;
var A,B,D:TVec3;Angle:Double;
begin
 Result:=QBetween(Axis,Goal);D:=SafeUnit(Goal);A:=QRotate(Result,Normal);A:=Sub(A,Scale(D,Dot(A,D)));B:=Sub(GoalNormal,Scale(D,Dot(GoalNormal,D)));
 if(Norm(A)>1e-6)and(Norm(B)>1e-6)then begin A:=SafeUnit(A);B:=SafeUnit(B);Angle:=ArcTan2(Dot(D,Cross(A,B)),Dot(A,B));Result:=QMul(QAxis(D,Angle),Result)end;
end;
constructor TNeuralRider.Create(ARider:TTripoRiderScene);
begin inherited Create;Rider:=ARider;Epoch:=ModeEpoch-1;Instances.Add(Self)end;
destructor TNeuralRider.Destroy;
begin Release(False);Instances.Remove(Self);inherited end;
function TNeuralRider.Active:Boolean;
begin Result:=Hidden end;
procedure TNeuralRider.GrabShape(Node:TX3DNode);
var N,I:Integer;
begin
 for I:=0 to High(Shapes)do if Shapes[I]=Node then Exit;
 { LOD/garment controllers may detach their nodes before rider destruction. }
 Node.KeepExistingBegin;
 N:=Length(Shapes);SetLength(Shapes,N+1);SetLength(WasVisible,N+1);Shapes[N]:=TShapeNode(Node);WasVisible[N]:=Shapes[N].Visible end;
procedure TNeuralRider.Release(const Restore:Boolean);
var I:Integer;
begin
 if Hidden and Restore then for I:=0 to High(Shapes)do Shapes[I].Visible:=WasVisible[I];Hidden:=False;
 if(MeshSwitch<>nil)and(Host<>nil)then Host.RemoveChildren(MeshSwitch);MeshSwitch:=nil;Host:=nil;
 for I:=0 to High(Shapes)do begin Shapes[I].KeepExistingEnd;Shapes[I].FreeIfUnused end;
 Shapes:=nil;WasVisible:=nil;HaveColors:=False;
 Drop(Asset,Density);Density:=0;Frames:=0;PreviousRig:=nil;Previous:=nil;Older:=nil;
end;
procedure TNeuralRider.HideOriginal;
var I:Integer;
begin
 for I:=0 to High(Shapes)do if Shapes[I].Visible then Shapes[I].Visible:=False;
end;
function TNeuralRider.BoneIndex(const Name:string):Integer;
var I:Integer;
begin for I:=0 to High(Asset.Bones)do if Asset.Bones[I].Name=Name then Exit(I);raise Exception.Create('Neural atlas bone missing: '+Name)end;
procedure TNeuralRider.BindBody;
var I:Integer;
begin
 Body:=NormalizeRiderBody(Rider.BodyParameters);Asset.BodyShape(Body,Rest,Pivots,Tips,Axes,Origins,Insertions,BodyScale);
 SetLength(Bones,NeuralBones);for I:=0 to NeuralBones-1 do begin Bones[I].Pivot:=Pivots[I];Bones[I].Tip:=Tips[I]end;
 SetLength(Muscles,NeuralMuscles);for I:=0 to NeuralMuscles-1 do begin Muscles[I].ActionGroup:=Asset.Muscles[I].Action;Muscles[I].ActionSide:=Asset.Muscles[I].Side end;
 PreviousRig:=nil;Previous:=nil;Older:=nil;PreviousDt:=1/60;Frames:=0;
end;
procedure TNeuralRider.BuildScene;
var Root:TGroupNode;Scope:TX3DNode;Shape:TShapeNode;App:TAppearanceNode;Geo:TIndexedTriangleSetNode;
 UV:TTextureCoordinateNode;Pts:TVector3List;Tex:TVector2List;S,I,J:Integer;
begin
 Scope:=Rider.Scene.RootNode.TryFindNodeByName(TGroupNode,'RiderVisContent',False);
 if Scope=nil then Scope:=Rider.Scene.RootNode;
 Host:=Scope as TAbstractGroupingNode;Host.EnumerateNodes(TShapeNode,@GrabShape,False);
 Root:=TGroupNode.Create;MeshSwitch:=TSwitchNode.Create;MeshSwitch.X3DName:='NeuralRiderSurface';MeshSwitch.WhichChoice:=-1;MeshSwitch.AddChildren(Root);
 for S:=0 to 2 do if Length(Asset.Parts[S].Faces)>0 then begin
  Shape:=TShapeNode.Create;Shape.X3DName:='NeuralRider'+IntToStr(S);Geo:=TIndexedTriangleSetNode.Create;Geo.Solid:=False;
  Coord[S]:=TCoordinateNode.Create;Normals[S]:=TNormalNode.Create;Geo.Coord:=Coord[S];Geo.Normal:=Normals[S];
  Pts:=TVector3List.Create;try for I in Asset.Parts[S].Slots do Pts.Add(Vector3(Rest[I].X,Rest[I].Y,Rest[I].Z));Coord[S].SetPoint(Pts)finally Pts.Free end;
  for I:=0 to High(Asset.Parts[S].Faces)do for J:=0 to 2 do Geo.FdIndex.Items.Add(Asset.Parts[S].Faces[I,J]);
  App:=TAppearanceNode.Create;Materials[S]:=TPhysicalMaterialNode.Create;Materials[S].Metallic:=0;Materials[S].Roughness:=0.78;App.Material:=Materials[S];
  if S=2 then begin
   UV:=TTextureCoordinateNode.Create;Tex:=TVector2List.Create;try for I:=0 to High(Asset.Parts[S].UV)do Tex.Add(Vector2(Asset.Parts[S].UV[I].U,Asset.Parts[S].UV[I].V));UV.SetPoint(Tex)finally Tex.Free end;Geo.TexCoord:=UV;
   Texture:=TPixelTextureNode.Create;Texture.RepeatS:=False;Texture.RepeatT:=False;App.Texture:=Texture;Materials[S].BaseColor:=Vector3(1,1,1);
  end else Materials[S].BaseColor:=Rider.SkinToneColor;
  Shape.Geometry:=Geo;Shape.Appearance:=App;Root.AddChildren(Shape);
 end;
 Host.AddChildren(MeshSwitch);UpdateColors;
end;
procedure TNeuralRider.UpdateColors;
var A,B,C:TVector3;Image:TRGBImage;X,Y:Integer;U,Vv,Edge,Weave:Single;
 function ByteColor(F:Single):Byte;
 begin F:=EnsureRange(F,0.0,1.0);if F<=0.0031308 then F*=12.92 else F:=1.055*Power(F,1/2.4)-0.055;Result:=Round(F*255)end;
 function LinearChannel(F:Single):Single;
 begin F:=EnsureRange(F,0.0,1.0);if F<=0.04045 then Result:=F/12.92 else Result:=Power((F+0.055)/1.055,2.4)end;
 function LinearColor(const Color:TVector3):TVector3;
 begin Result:=Vector3(LinearChannel(Color.X),LinearChannel(Color.Y),LinearChannel(Color.Z))end;
begin
 A:=Rider.DisplayClothColor(csJersey);B:=Rider.DisplayClothColor(csShorts);
 { Picker/bot overrides are display sRGB; authored material factors are linear. }
 if Rider.ClothDyeMode<>cdmNone then begin
  if Rider.ClothColorActive[csJersey]then A:=LinearColor(A);
  if Rider.ClothColorActive[csShorts]then B:=LinearColor(B);
 end;
 if Rider.AppearanceAddon<>nil then begin
  if not(Rider.ClothColorActive[csJersey]and(Rider.ClothDyeMode<>cdmNone))and Rider.AppearanceAddon.DisplayTopColor(C)then A:=C;
  if not(Rider.ClothColorActive[csShorts]and(Rider.ClothDyeMode<>cdmNone))and Rider.AppearanceAddon.DisplayBottomColor(C)then B:=C;
 end;
 if HaveColors and CompareMem(@A,@TopColor,SizeOf(A))and CompareMem(@B,@BottomColor,SizeOf(B))then Exit;TopColor:=A;BottomColor:=B;HaveColors:=True;
 Image:=TRGBImage.Create(512,512);
 for Y:=0 to 511 do for X:=0 to 511 do begin
  U:=(X+0.5)/512;Vv:=(Y+0.5)/512;C:=B;if Vv>0.50 then C:=A;
  Edge:=Abs(Frac(U*2)-0.5);Weave:=0.97+0.03*Ord(Odd(X+Y));
  if(Edge>0.39)or(Abs(Vv-0.50)<0.003)then Weave*=0.76;
  if(Abs(U-0.25)<0.002)and(Vv>0.5)then Weave*=0.65;
  Image.PixelPtr(X,Y)^:=Vector3Byte(ByteColor(C.X*Weave),ByteColor(C.Y*Weave),ByteColor(C.Z*Weave));
 end;
 Texture.FdImage.Value:=Image;Texture.FdImage.Changed;
end;
procedure TNeuralRider.Retarget;
var Done:array of Byte;I,S,D,J,Anchor:Integer;Suffix,Prefix,N,Digit,GameName,EndName:string;
 P,Q,A,B,C,Normal,Forward,Across:TVec3;Twist:TQuat;TwistAngle:Double;
 function Joint(const Name:string):TMatrix4;
 begin Require(Rider.NeuralJointMatrix(Name,Result),'Rider pose joint unavailable: '+Name)end;
 function Point(const Name:string):TVec3;
 var K:TMatrix4;begin K:=Joint(Name);Result:=Atlas(K.MultPoint(TVector3.Zero))end;
 procedure SetBone(const Name,GameJoint,EndJoint:string;const RestAxis:TVec3;const RestNormal:TVec3);
 var K,G,Parent:Integer;World,RestM,Change:TMatrix4;Goal,GoalN,Target:TVec3;BindAxis:TTripoVec3;
 begin
  K:=BoneIndex(Name);World:=Joint(GameJoint);G:=Rider.Rig.JointIndexByName(GameJoint);Move(Rider.Rig.BindWorld[G],RestM,SizeOf(RestM));RestM:=Rider.Scene.Transform*RestM;
  Change:=World*RestM.Inverse(RestM.Determinant);GoalN:=Atlas(Change.MultDirection(Bike(RestNormal)));
  if EndJoint<>''then Goal:=Sub(Point(EndJoint),Atlas(World.MultPoint(TVector3.Zero)))else Goal:=Atlas(Change.MultDirection(Bike(RestAxis)));
  if(EndJoint='')and(Pos('hand_phalanx_',Name)=1)then begin
   Parent:=Rider.Rig.JointParent[G];if Parent>=0 then begin BindAxis:=V3Sub(Rider.Rig.JointBindPos(G),Rider.Rig.JointBindPos(Parent));Goal:=Atlas(Change.MultDirection(Rider.Scene.Transform.MultDirection(Vector3(BindAxis.X,BindAxis.Y,BindAxis.Z))))end;
  end;
  Transforms[K].Q:=FrameRotation(RestAxis,RestNormal,Goal,GoalN);
  Target:=Atlas(World.MultPoint(TVector3.Zero));Transforms[K].T:=Sub(Target,QRotate(Transforms[K].Q,Pivots[K]));CompleteRigid(Transforms[K]);Done[K]:=2;
 end;
 procedure Spine;
 const Chain:array[0..6]of string=('Pelvis','Waist','Spine01','Spine02','NeckTwist01','NeckTwist02','Head');
 var BindY:array[0..6]of Double;Now:array[0..6]of TVec3;Rot:array[0..6]of TQuat;
  K,J,B:Integer;World,RestM,Change:TMatrix4;H,T,Lo,Hi,LengthQ,Sign:Double;Name:string;U,W:TQuat;
 begin
  for J:=0 to 6 do begin World:=Joint(Chain[J]);B:=Rider.Rig.JointIndexByName(Chain[J]);Move(Rider.Rig.BindWorld[B],RestM,SizeOf(RestM));RestM:=Rider.Scene.Transform*RestM;
   BindY[J]:=RestM.MultPoint(TVector3.Zero).Y;Now[J]:=Atlas(World.MultPoint(TVector3.Zero));Change:=World*RestM.Inverse(RestM.Determinant);
   Rot[J]:=FrameRotation(V(0,1,0),V(0,0,1),Atlas(Change.MultDirection(Vector3(0,1,0))),Atlas(Change.MultDirection(Vector3(1,0,0))));
  end;
  Lo:=Pivots[BoneIndex('sacrum')].Y;Hi:=Pivots[BoneIndex('C7')].Y;
  for K:=0 to NeuralBones-1 do begin
   Name:=Asset.Bones[K].Name;
   if(Name<>'sacrum')and not((Length(Name)<=3)and(Name[1]in['L','T','C']))then Continue;
   H:=Pivots[K].Y;
   if H<=Hi then H:=BindY[0]+(BindY[4]-BindY[0])*(H-Lo)/(Hi-Lo)
   else H:=BindY[4]+(BindY[6]-BindY[4])*(H-Hi)/(Pivots[BoneIndex('C1')].Y-Hi);
   J:=0;while(J<5)and(H>BindY[J+1])do Inc(J);
   T:=EnsureRange((H-BindY[J])/Max(1e-5,BindY[J+1]-BindY[J]),0.0,1.0);
   U:=Rot[J];W:=Rot[J+1];Sign:=1;if U.X*W.X+U.Y*W.Y+U.Z*W.Z+U.W*W.W<0 then Sign:=-1;
   U.X:=U.X*(1-T)+W.X*T*Sign;U.Y:=U.Y*(1-T)+W.Y*T*Sign;U.Z:=U.Z*(1-T)+W.Z*T*Sign;U.W:=U.W*(1-T)+W.W*T*Sign;
   LengthQ:=Sqrt(Sqr(U.X)+Sqr(U.Y)+Sqr(U.Z)+Sqr(U.W));U.X/=LengthQ;U.Y/=LengthQ;U.Z/=LengthQ;U.W/=LengthQ;
   Transforms[K].Q:=U;Transforms[K].T:=Sub(Lerp(Now[J],Now[J+1],T),QRotate(U,Pivots[K]));CompleteRigid(Transforms[K]);Done[K]:=2;
  end;
 end;
 procedure InheritBone(K:Integer);
 var Parent:Integer;
 begin
  if Done[K]=2 then Exit;Require(Done[K]=0,'Neural rig cycle');Done[K]:=1;Parent:=Asset.Bones[K].Parent;
  if Parent>=0 then begin InheritBone(Parent);Transforms[K]:=Transforms[Parent]end else Transforms[K]:=RIdentity;Done[K]:=2;
 end;
begin
 SetLength(Transforms,NeuralBones);SetLength(Done,NeuralBones);
 Spine;
 for S:=0 to 1 do begin
  Suffix:='.L';Prefix:='L_';if S=1 then begin Suffix:='.R';Prefix:='R_'end;
  I:=BoneIndex('femur'+Suffix);J:=BoneIndex('tibia'+Suffix);SetBone('femur'+Suffix,Prefix+'Thigh',Prefix+'Calf',Sub(Pivots[J],Pivots[I]),V(0,0,1));
  I:=J;J:=BoneIndex('talus'+Suffix);SetBone('tibia'+Suffix,Prefix+'Calf',Prefix+'Foot',Sub(Pivots[J],Pivots[I]),V(0,0,1));
  I:=J;J:=BoneIndex('foot_phalanx_II_1'+Suffix);
  SetBone('talus'+Suffix,Prefix+'Foot',Prefix+'ToeBase',Sub(Pivots[J],Pivots[I]),V(0,1,0));
  I:=BoneIndex('humerus'+Suffix);J:=BoneIndex('ulna'+Suffix);SetBone('humerus'+Suffix,Prefix+'Upperarm',Prefix+'Forearm',Sub(Pivots[J],Pivots[I]),V(0,0,1));
  I:=J;J:=BoneIndex('capitate'+Suffix);SetBone('ulna'+Suffix,Prefix+'Forearm',Prefix+'Hand',Sub(Pivots[J],Pivots[I]),V(0,0,1));
  { Align the palm by its anatomical forward and transverse directions.
    Bind-pose axes of the game and atlas hands are different. }
  I:=BoneIndex('capitate'+Suffix);P:=Tips[BoneIndex('metacarpal_II'+Suffix)];Q:=Tips[BoneIndex('metacarpal_V'+Suffix)];
  Forward:=Sub(Lerp(P,Q,0.5),Pivots[I]);Normal:=Cross(Forward,Sub(P,Q));
  P:=Point(Prefix+'Index1');Q:=Point(Prefix+'Little1');A:=Point(Prefix+'Hand');
  Across:=Sub(P,Q);B:=Sub(Lerp(P,Q,0.5),A);
  Transforms[I].Q:=FrameRotation(Forward,Normal,B,Cross(B,Across));
  Transforms[I].T:=Sub(A,QRotate(Transforms[I].Q,Pivots[I]));CompleteRigid(Transforms[I]);Done[I]:=2;
  J:=BoneIndex('ulna'+Suffix);Twist:=QMul(Transforms[I].Q,QInverse(Transforms[J].Q));
  if Twist.W<0 then begin Twist.X:=-Twist.X;Twist.Y:=-Twist.Y;Twist.Z:=-Twist.Z;Twist.W:=-Twist.W end;
  C:=SafeUnit(QRotate(Transforms[J].Q,Sub(Pivots[I],Pivots[J])));
  TwistAngle:=2*ArcTan2(Dot(V(Twist.X,Twist.Y,Twist.Z),C),Twist.W);
  I:=BoneIndex('radius'+Suffix);A:=RPoint(Transforms[J],Pivots[I]);
  Transforms[I].Q:=QMul(QAxis(C,TwistAngle),Transforms[J].Q);Transforms[I].T:=Sub(A,QRotate(Transforms[I].Q,Pivots[I]));CompleteRigid(Transforms[I]);Done[I]:=2;
  I:=BoneIndex('metacarpal_I'+Suffix);J:=BoneIndex('hand_phalanx_I_1'+Suffix);
  SetBone('metacarpal_I'+Suffix,Prefix+'Thumb1',Prefix+'Thumb2',Sub(Pivots[J],Pivots[I]),V(0,0,1));
  for D:=0 to 4 do begin
   case D of 0:begin Digit:='I';GameName:='Thumb'end;1:begin Digit:='II';GameName:='Index'end;2:begin Digit:='III';GameName:='Middle'end;3:begin Digit:='IV';GameName:='Ring'end;else begin Digit:='V';GameName:='Little'end end;
   for J:=1 to 3 do begin
    if(D=0)and(J=2)then Continue;N:='hand_phalanx_'+Digit+'_'+IntToStr(J)+Suffix;I:=BoneIndex(N);Anchor:=J;if(D=0)and(J=1)then Anchor:=2;
    if Rider.Rig.JointIndexByName(Prefix+GameName+IntToStr(Anchor))<0 then Continue;
    EndName:='';if Anchor<3 then EndName:=Prefix+GameName+IntToStr(Anchor+1);
    SetBone(N,Prefix+GameName+IntToStr(Anchor),EndName,Sub(Tips[I],Pivots[I]),V(0,0,1));
   end;
  end;
 end;
 for I:=0 to NeuralBones-1 do InheritBone(I);
 for S:=0 to 1 do begin Suffix:='.L';if S=1 then Suffix:='.R';
  I:=BoneIndex('femur'+Suffix);J:=BoneIndex('tibia'+Suffix);P:=RPoint(Transforms[I],Pivots[I]);Q:=RPoint(Transforms[J],Pivots[J]);J:=BoneIndex('talus'+Suffix);A:=RPoint(Transforms[J],Pivots[J]);
  Pose.Knee[S]:=RadToDeg(ArcCos(EnsureRange(Dot(SafeUnit(Sub(Q,P)),SafeUnit(Sub(A,Q))),-1.0,1.0)));
  J:=BoneIndex('patella'+Suffix);
  Transforms[J]:=RCompose(Transforms[I],RPivot(Pivots[J],QAxis(Axes[J],DegToRad(Pose.Knee[S]*0.70))));
  B:=QRotate(QInverse(Transforms[BoneIndex('sacrum')].Q),SafeUnit(Sub(Q,P)));Pose.Hip[S]:=RadToDeg(ArcTan2(B.Z,-B.Y));Pose.HipSide[S]:=RadToDeg(ArcSin(EnsureRange(B.X,-1.0,1.0)))*(1-2*S);
  I:=BoneIndex('humerus'+Suffix);J:=BoneIndex('ulna'+Suffix);P:=RPoint(Transforms[I],Pivots[I]);Q:=RPoint(Transforms[J],Pivots[J]);J:=BoneIndex('capitate'+Suffix);A:=RPoint(Transforms[J],Pivots[J]);
  Pose.Elbow[S]:=RadToDeg(ArcCos(EnsureRange(Dot(SafeUnit(Sub(Q,P)),SafeUnit(Sub(A,Q))),-1.0,1.0)));
  B:=QRotate(QInverse(Transforms[BoneIndex('T1')].Q),SafeUnit(Sub(Q,P)));Pose.ShoulderForward[S]:=RadToDeg(ArcTan2(B.Z,-B.Y));Pose.Shoulder[S]:=RadToDeg(ArcSin(EnsureRange(B.X,-1.0,1.0)))*(1-2*S);
 end;
end;
{$I neural_rider_activity.inc}
procedure TNeuralRider.Features(const Dt:Double;const Effort,Phase:Single;const BreathPhase:Double;out X:TNeuralFloats);
var Frame,I,J,K,At:Integer;R,RO,RI:TRigid;Root,P:TVec3;Q:TQuat;Ratio,Old,Velocity:Double;
 B:TRiderBodyParameters;Values:array[0..11]of Single absolute B;Extra:array[0..14]of Double;
begin
 Pose.Effort:=EnsureRange(Effort/2,0.0,1.0);Pose.Pedaling:=Rider.CurrentPose.Motion.Pedalling;Pose.PedalPhase:=-Phase+0.75;DynamicFrameActive:=False;
 UpdateMuscleDemand;SetLength(X,NeuralInputs);Root:=RPoint(Transforms[BoneIndex('sacrum')],Pivots[BoneIndex('sacrum')]);At:=0;
 for Frame:=0 to 1 do for I:=0 to NeuralBones-1 do begin R:=Transforms[I];if(Frame=1)and(Length(PreviousRig)=NeuralBones)then R:=PreviousRig[I];
  P:=Sub(RPoint(R,Pivots[I]),Root);Q:=R.Q;if Q.W<0 then begin Q.X:=-Q.X;Q.Y:=-Q.Y;Q.Z:=-Q.Z;Q.W:=-Q.W end;
  X[At]:=Q.X;X[At+1]:=Q.Y;X[At+2]:=Q.Z;X[At+3]:=Q.W;X[At+4]:=P.X;X[At+5]:=P.Y;X[At+6]:=P.Z;Inc(At,7);
 end;
 for I:=0 to NeuralMuscles-1 do begin RO:=BlendRigid(Asset.Muscles[I].OriginWeight,Transforms);RI:=BlendRigid(Asset.Muscles[I].InsertionWeight,Transforms);
  Ratio:=EnsureRange(Norm(Sub(RPoint(RO,Origins[I]),RPoint(RI,Insertions[I])))/Max(0.001,Norm(Sub(Origins[I],Insertions[I]))),0.55,1.65);X[At]:=MuscleActivationFor(I,Ratio);X[At+1]:=Ratio;Inc(At,2);
 end;
 for I:=0 to 63 do begin J:=I*3;for K:=0 to 2 do begin Old:=0;Velocity:=0;if Length(Previous)>0 then Old:=Previous[J+K];if Length(Older)>0 then Velocity:=(Old-Older[J+K])/PreviousDt;
  X[At+K]:=Old*50;X[At+3+K]:=EnsureRange(Velocity,-2.0,2.0)end;Inc(At,6)end;
 B:=Body;B.InseamCm:=RiderBodyInseamCm(B);B.ArmLengthCm:=RiderBodyArmCm(B);for I:=0 to 11 do begin X[At]:=Values[I];if I in[1,2,4,5]then X[At]/=100;Inc(At)end;
 Extra[0]:=Dt*60;Extra[1]:=0.008;Extra[2]:=0.75;Extra[3]:=Pose.Effort;Extra[4]:=0.5+0.25*Sin(2*Pi*BreathPhase);
 Extra[5]:=1;Extra[6]:=1;Extra[7]:=0.25;Extra[8]:=1;Extra[9]:=1;Extra[10]:=0.28;Extra[11]:=1;Extra[12]:=1;Extra[13]:=BodyScale;Extra[14]:=1;
 for I:=0 to 14 do begin X[At]:=Extra[I];Inc(At)end;Require(At=NeuralInputs,'Neural features layout');
end;
procedure TNeuralRider.Display(const Y:TNeuralFloats);
var I,J,K,S:Integer;R:TRigid;P,N:TVec3;A,B,C:Integer;Points,Vectors:TVector3List;Local:TMatrix4;
begin
 SetLength(FramePositions,Asset.VertexCount);SetLength(FrameNormals,Asset.VertexCount);FillChar(FrameNormals[0],Length(FrameNormals)*SizeOf(TVec3),0);
 for I:=0 to Asset.VertexCount-1 do begin R:=BlendRigid(Asset.Weights[I],Transforms);FramePositions[I]:=RPoint(R,Add(Rest[I],V(Y[3*I],Y[3*I+1],Y[3*I+2])))end;
 for S:=0 to 2 do for I:=0 to High(Asset.Parts[S].Faces)do begin
  A:=Asset.Parts[S].Slots[Asset.Parts[S].Faces[I,0]];B:=Asset.Parts[S].Slots[Asset.Parts[S].Faces[I,1]];C:=Asset.Parts[S].Slots[Asset.Parts[S].Faces[I,2]];
  N:=Cross(Sub(FramePositions[B],FramePositions[A]),Sub(FramePositions[C],FramePositions[A]));
  FrameNormals[A]:=Add(FrameNormals[A],N);FrameNormals[B]:=Add(FrameNormals[B],N);FrameNormals[C]:=Add(FrameNormals[C],N);
 end;
 Local:=Rider.Scene.InverseTransform;
 for S:=0 to 2 do if Length(Asset.Parts[S].Faces)>0 then begin
  Points:=TVector3List.Create;Vectors:=TVector3List.Create;
  try for I in Asset.Parts[S].Slots do begin Points.Add(Local.MultPoint(Bike(FramePositions[I])));Vectors.Add(Local.MultDirection(Bike(SafeUnit(FrameNormals[I]))).Normalize)end;Coord[S].SetPoint(Points);Normals[S].SetVector(Vectors);
  finally Points.Free;Vectors.Free end;
 end;
 { The ordinary LOD and wardrobe update before us and may re-enable a shape.
   The network supplies the complete exterior, including hands, head and feet. }
 HideOriginal;
 Hidden:=True;MeshSwitch.WhichChoice:=0;
end;
procedure TNeuralRider.Update(Dt,Effort,PedalPhase:Single;BreathPhase:Double);
var X,Y:TNeuralFloats;I,K:Integer;T:TTimerResult;
begin
 SyncMode;T:=Timer;
 try
 if Epoch<>ModeEpoch then begin Release;Epoch:=ModeEpoch;if CurrentMode=0 then Exit;Density:=CurrentMode;Asset:=Acquire(Density);if Asset<>nil then begin BindBody;BuildScene end end;
 if(Asset=nil)or(CurrentMode=0)then Exit;
 if Errors[Density]<>''then begin Release;Exit end;
  if not SameRiderBody(Body,NormalizeRiderBody(Rider.BodyParameters))then BindBody;
  UpdateColors;if Hidden then HideOriginal;Retarget;
  if(Dt<=0)and(Frames>0)and(Length(PreviousRig)=Length(Transforms))and
   (LastEffort=Effort)and CompareMem(@PreviousRig[0],@Transforms[0],Length(Transforms)*SizeOf(TRigid))then Exit;
  if(Dt<=0)or(Dt>0.1)then begin PreviousRig:=nil;Previous:=nil;Older:=nil;Dt:=1/60 end;
  Features(Dt,Effort,PedalPhase,BreathPhase,X);Asset.Predict(X,Y);Display(Y);LastEffort:=Effort;
  PreviousRig:=Copy(Transforms);Older:=Previous;Previous:=nil;SetLength(Previous,192);for I:=0 to 63 do for K:=0 to 2 do Previous[I*3+K]:=Y[Asset.Samples[I]*3+K];PreviousDt:=Dt;Inc(Frames);
 except on E:Exception do begin Errors[Density]:=E.Message;LastFailure:=E.Message;Logger.Info('[NeuralRiders] Ordinary rider fallback: '+E.Message);Release end end;
 LastMS:=TimerSeconds(Timer,T)*1000;
end;
initialization
 Instances:=TList.Create;RiderSurfaceFactory:=@NewSurface;
finalization
 RiderSurfaceFactory:=nil;Instances.Free;
 Assets[1].Free;Assets[2].Free;
end.
