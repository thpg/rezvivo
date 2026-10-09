unit AvatarClothSolver;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, Math, fpjson, AvatarGlbIO, TripoRig;
type
  TClothPoints = array of TTripoVec3;
  TClothCapsule = record
    A,B,Aspect: TTripoVec3;
    RA,RB: Single;
  end;
  TClothCapsules = array of TClothCapsule;
  TClothVertex = record
    Rest,Normal: TTripoVec3;
    Joints:TJointInf;
    Weights:TWeightInf;
    Particle:Integer;
    Neighbours:array[0..3]of Integer;
    Blend:array[0..3]of Single;
    Travel:Single;
  end;
  TClothParticle = record
    Rest,Target,LastTarget,Position,Previous,Velocity,Normal:TTripoVec3;
    Joints:TJointInf;
    Weights:TWeightInf;
    Travel,InvMass:Single;
    Count:Integer;
  end;
  TClothEdge = record
    A,B:Integer;
    Rest,Lambda:Single;
    Bend:Boolean;
  end;
  TClothPrimitive = record First,Count:Integer end;
  TAvatarClothSolver = class
  private
    FRig:TTripoRig;
    FVertices:array of TClothVertex;
    FParticles:array of TClothParticle;
    FEdges:array of TClothEdge;
    FIndices:array of Integer;
    FCapsules:TClothCapsules;
    FFrameTargets:TClothPoints;
    FSkinPositions,FBaseNormals:TClothPoints;
    FOffset:TTripoVec3;
    FScale,FCell,FStiffness,FFreedom,FDensity,FWind,FLastSpeed:Single;
    FTime,FAccum:Double;
    FSteps,FContacts:Integer;
    FReady:Boolean;
    FPreset:string;
    function TravelAt(const P:TTripoVec3):Single;
    function Skinned(const P:TTripoVec3;const J:TJointInf;const W:TWeightInf):TTripoVec3;
    procedure BuildCage;
    procedure BuildCapsules;
    procedure Step(Speed,Acceleration:Single);
    procedure Render;
    function Project(var P:TTripoVec3;Thickness:Single):Boolean;
  public
    Id:string;
    Primitives:array of TClothPrimitive;
    Positions,Normals,Offsets,NormalOffsets:TClothPoints;
    constructor Create(Doc:TGlbDoc;Item:TJSONObject;Rig:TTripoRig);
    procedure Update(Dt,Speed:Single;const Offset:TTripoVec3;Reset:Boolean=False);
    procedure State(O:TJSONObject);
    function MaxDisplacement:Single;
    function MaxPenetration:Single;
    function MaxPinError:Single;
    function ParticleCount:Integer;
    function CapsuleCount:Integer;
    function Capsule(Index:Integer):TClothCapsule;
    function VertexMovable(Index:Integer):Single;
    property Offset:TTripoVec3 read FOffset;
    property SimulatedTime:Double read FTime;
  end;
implementation
uses GltfCore, AvatarWardrobe;
const StepTime=1/120;

{ Secondary cloth motion on a welded, reduced cage. XPBD stretch and bending
  distance constraints follow Macklin et al. (2016), equation 18:
  https://matthias-research.github.io/pages/publications/XPBD.pdf
  Animated attachment targets, bounded tethers and tapered body capsules
  keep this editor approximation stable. It is not a self-collision solver. }
function Limited(const P:TTripoVec3;Limit:Single):TTripoVec3;
var L:Single;
begin L:=V3Len(P);Result:=P;if L>Limit then Result:=V3Scale(P,Limit/L) end;
function Mix(const A,B:TTripoVec3;T:Single):TTripoVec3;
begin Result:=V3Add(A,V3Scale(V3Sub(B,A),T)) end;

function TAvatarClothSolver.TravelAt(const P:TTripoVec3):Single;
var X,Y,Arm,Hem:Single;
begin
  X:=Abs(P.X)/FScale;Y:=P.Y/FScale;
  if FPreset='jeans' then begin
    if Y>0.975 then Exit(0);
    Result:=(0.015+0.035*EnsureRange((0.97-Y)/0.8,0.0,1.0))*FScale;
  end else begin
    if (FPreset='raincoat') and (Y<1.055) and (X<0.5) then
      Result:=(0.025+0.26*Sqr(EnsureRange((1.055-Y)/0.72,0.0,1.0)))*FScale
    else begin
      Arm:=EnsureRange((X-0.18)/0.13,0.0,1.0);
      Hem:=EnsureRange((1.43-Y)/0.48,0.0,1.0);
      Result:=((1-Arm)*0.055*Hem+Arm*0.045)*FScale;
      if ((Y>1.42) and (X<0.23)) or (X>0.675) then Result:=0;
    end;
  end;
  Result:=Result*(0.25+0.75*FFreedom);
end;

constructor TAvatarClothSolver.Create(Doc:TGlbDoc;Item:TJSONObject;Rig:TTripoRig);
var Mesh,Prim,Attr:TJSONObject;PA:TJSONArray;P,N,J,W,Idx:TWardrobeFloats;
  I,K,L,C,First,Base:Integer;Head:Integer;
begin
  inherited Create;FRig:=Rig;Id:=Item.Get('id','');FPreset:=Item.Get('preset','');
  FStiffness:=EnsureRange(Item.Get('stiffness',0.55),0.0,1.0);
  FFreedom:=EnsureRange(Item.Get('flutter',0.7),0.0,1.0);
  FDensity:=EnsureRange(Item.Get('density',350.0),80.0,900.0);
  FWind:=EnsureRange(Item.Get('wind',1.5),0.0,20.0);
  Head:=Rig.JointIndexByName('Head');FScale:=1;
  if Head>=0 then FScale:=Mat4Inverse(Rig.NativeInvBind[Head])[13]/1.58;
  FCell:=0.055*FScale;
  Mesh:=ObjAt(ArrOf(Doc.Root,'meshes'),IntOf(Doc.NodeObj(Item.Get('node',-1)),'mesh',-1));
  PA:=ArrOf(Mesh,'primitives');SetLength(Primitives,CountOf(PA));
  for I:=0 to CountOf(PA)-1 do begin
    Prim:=ObjAt(PA,I);Attr:=ObjOf(Prim,'attributes');
    P:=WardrobeReadAcc(Doc,IntOf(Attr,'POSITION',-1),C);
    N:=WardrobeReadAcc(Doc,IntOf(Attr,'NORMAL',-1),C);
    J:=WardrobeReadAcc(Doc,IntOf(Attr,'JOINTS_0',-1),C);
    W:=WardrobeReadAcc(Doc,IntOf(Attr,'WEIGHTS_0',-1),C);
    First:=Length(FVertices);C:=Length(P) div 3;
    if (Length(N)<>C*3) or (Length(J)<>C*4) or (Length(W)<>C*4) then
      raise EReadError.Create('Invalid cloth skin');
    Primitives[I].First:=First;Primitives[I].Count:=C;SetLength(FVertices,First+C);
    for K:=0 to C-1 do with FVertices[First+K] do begin
      Rest:=TripoRig.V3(P[K*3],P[K*3+1],P[K*3+2]);
      Normal:=TripoRig.V3(N[K*3],N[K*3+1],N[K*3+2]);
      for L:=0 to 3 do begin
        Joints[L]:=Round(J[K*4+L]);Weights[L]:=W[K*4+L];
        if Joints[L]>=Rig.JointCount then raise EReadError.Create('Invalid cloth joint');
      end;
      Travel:=TravelAt(Rest);
    end;
    if HasKey(Prim,'indices') then Idx:=WardrobeReadAcc(Doc,IntOf(Prim,'indices',-1),C)
    else begin SetLength(Idx,Primitives[I].Count);for K:=0 to High(Idx) do Idx[K]:=K end;
    Base:=Length(FIndices);SetLength(FIndices,Base+Length(Idx));
    for K:=0 to High(Idx) do begin
      L:=Round(Idx[K]);
      if (L<0) or (L>=Primitives[I].Count) then raise EReadError.Create('Invalid cloth index');
      FIndices[Base+K]:=First+L;
    end;
  end;
  BuildCage;SetLength(Positions,Length(FVertices));SetLength(Normals,Length(FVertices));
  SetLength(Offsets,Length(FVertices));SetLength(NormalOffsets,Length(FVertices));
  SetLength(FSkinPositions,Length(FVertices));SetLength(FBaseNormals,Length(FVertices));
  SetLength(FFrameTargets,Length(FParticles));
end;

procedure TAvatarClothSolver.BuildCage;
var Cells,Edges,Opposites:TStringList;I,J,K,L,A,B,C,At,Other:Integer;
  Key:string;D:TTripoVec3;Dist,Total:Single;Best:array[0..3]of Single;
  procedure Edge(V0,V1:Integer;Bending:Boolean);
  var S:string;E,Swap:Integer;
  begin
    if V0=V1 then Exit;if V0>V1 then begin Swap:=V0;V0:=V1;V1:=Swap end;
    S:=IntToStr(V0)+':'+IntToStr(V1);
    if Edges.IndexOf(S)>=0 then Exit;
    E:=Length(FEdges);Edges.Add(S);SetLength(FEdges,E+1);
    FEdges[E].A:=V0;FEdges[E].B:=V1;FEdges[E].Bend:=Bending;
    FEdges[E].Rest:=V3Len(V3Sub(FParticles[V0].Rest,FParticles[V1].Rest));
  end;
  procedure Side(V0,V1,V2:Integer);
  var S:string;E,Swap:Integer;
  begin
    Edge(V0,V1,False);if V0>V1 then begin Swap:=V0;V0:=V1;V1:=Swap end;
    S:=IntToStr(V0)+':'+IntToStr(V1);E:=Opposites.IndexOf(S);
    if E<0 then Opposites.AddObject(S,TObject(PtrInt(V2)))
    else begin Other:=PtrInt(Opposites.Objects[E]);if Other<>V2 then Edge(Other,V2,True) end;
  end;
begin
  Cells:=TStringList.Create;Edges:=TStringList.Create;Opposites:=TStringList.Create;
  Cells.Sorted:=True;Edges.Sorted:=True;Opposites.Sorted:=True;
  try
    for I:=0 to High(FVertices) do begin
      D:=FVertices[I].Rest;
      Key:=IntToStr(Floor(D.X/FCell))+','+IntToStr(Floor(D.Y/FCell))+','+IntToStr(Floor(D.Z/FCell));
      At:=Cells.IndexOf(Key);
      if At<0 then begin
        J:=Length(FParticles);SetLength(FParticles,J+1);Cells.AddObject(Key,TObject(PtrInt(J)));
        FParticles[J].Joints:=FVertices[I].Joints;FParticles[J].Weights:=FVertices[I].Weights;
        FParticles[J].Travel:=FVertices[I].Travel;
      end else J:=PtrInt(Cells.Objects[At]);
      FVertices[I].Particle:=J;
      with FParticles[J] do begin
        Rest:=V3Add(Rest,D);Normal:=V3Add(Normal,FVertices[I].Normal);Inc(Count);
        Travel:=Min(Travel,FVertices[I].Travel);
      end;
    end;
    for I:=0 to High(FParticles) do with FParticles[I] do begin
      Rest:=V3Scale(Rest,1/Count);Normal:=V3Norm(Normal);
      if Travel<1e-5 then InvMass:=0 else InvMass:=350/FDensity;
    end;
    for I:=0 to Length(FIndices) div 3-1 do begin
      A:=FVertices[FIndices[I*3]].Particle;B:=FVertices[FIndices[I*3+1]].Particle;
      C:=FVertices[FIndices[I*3+2]].Particle;
      if (A=B) or (A=C) or (B=C) then Continue;
      Side(A,B,C);Side(B,C,A);Side(C,A,B);
    end;
    { Smooth cage offsets across material/UV seams. Exact coincident positions
      receive the same nearest neighbours even when glTF duplicates vertices. }
    for I:=0 to High(FVertices) do begin
      for K:=0 to 3 do begin Best[K]:=1e30;FVertices[I].Neighbours[K]:=FVertices[I].Particle end;
      for J:=0 to High(FParticles) do begin
        D:=V3Sub(FVertices[I].Rest,FParticles[J].Rest);Dist:=V3Dot(D,D);
        if V3Dot(FVertices[I].Normal,FParticles[J].Normal)<-0.2 then Dist:=Dist+1;
        for K:=0 to 3 do if Dist<Best[K] then begin
          for L:=3 downto K+1 do begin Best[L]:=Best[L-1];FVertices[I].Neighbours[L]:=FVertices[I].Neighbours[L-1] end;
          Best[K]:=Dist;FVertices[I].Neighbours[K]:=J;Break;
        end;
      end;
      Total:=0;for K:=0 to 3 do begin FVertices[I].Blend[K]:=1/Max(Best[K],1e-6);Total:=Total+FVertices[I].Blend[K] end;
      for K:=0 to 3 do FVertices[I].Blend[K]:=FVertices[I].Blend[K]/Total;
    end;
  finally Cells.Free;Edges.Free;Opposites.Free end;
end;

function TAvatarClothSolver.Skinned(const P:TTripoVec3;const J:TJointInf;const W:TWeightInf):TTripoVec3;
var K:Integer;
begin
  Result:=FOffset;
  for K:=0 to 3 do if W[K]>0 then
    Result:=V3Add(Result,V3Scale(Mat4MulPoint(FRig.SkinMatrix[J[K]],P),W[K]));
end;

procedure TAvatarClothSolver.BuildCapsules;
  procedure Add(const AName,BName:string;RA,RB,AX,AZ:Single);
  var A,B,N:Integer;
  begin
    A:=FRig.JointIndexByName(AName);B:=FRig.JointIndexByName(BName);if (A<0) or (B<0) then Exit;
    N:=Length(FCapsules);SetLength(FCapsules,N+1);
    FCapsules[N].A:=V3Add(FRig.JointWorldPos(A),FOffset);
    FCapsules[N].B:=V3Add(FRig.JointWorldPos(B),FOffset);
    FCapsules[N].RA:=RA*FScale;FCapsules[N].RB:=RB*FScale;
    FCapsules[N].Aspect:=TripoRig.V3(AX,1,AZ);
  end;
var Side:string;I:Integer;
begin
  FCapsules:=nil;
  Add('Pelvis','Waist',0.135,0.125,1.3,0.83);
  Add('Waist','Spine02',0.125,0.14,1.22,0.79);
  for I:=0 to 1 do begin
    if I=0 then Side:='L_' else Side:='R_';
    if FPreset='raincoat' then begin
      { Reserve the volume of loose jeans underneath the skirt, including
        their straight calves and the small secondary-motion envelope. }
      Add(Side+'Thigh',Side+'Calf',0.145,0.138,1,1);
      Add(Side+'Calf',Side+'Foot',0.136,0.09,1,1);
    end else begin
      Add(Side+'Thigh',Side+'Calf',0.082,0.056,1,1);
      Add(Side+'Calf',Side+'Foot',0.053,0.032,1,1);
    end;
    Add(Side+'Upperarm',Side+'Forearm',0.055,0.044,1,1);
    Add(Side+'Forearm',Side+'Hand',0.043,0.029,1,1);
  end;
end;

function TAvatarClothSolver.Project(var P:TTripoVec3;Thickness:Single):Boolean;
var I,Pass:Integer;D,Axis,Q,Center:TTripoVec3;T,L,Radius:Single;Hit:Boolean;
begin
  Result:=False;
  for Pass:=0 to 23 do begin
  Hit:=False;
  for I:=0 to High(FCapsules) do with FCapsules[I] do begin
    D:=V3Sub(P,A);Axis:=V3Sub(B,A);
    D:=TripoRig.V3(D.X/Aspect.X,D.Y,D.Z/Aspect.Z);
    Axis:=TripoRig.V3(Axis.X/Aspect.X,Axis.Y,Axis.Z/Aspect.Z);
    T:=EnsureRange(V3Dot(D,Axis)/Max(V3Dot(Axis,Axis),1e-9),0.0,1.0);
    Q:=V3Sub(D,V3Scale(Axis,T));L:=V3Len(Q);Radius:=RA+(RB-RA)*T+Thickness;
    if L<Radius-0.00001 then begin
      if L<1e-7 then Q:=TripoRig.V3(0,0,1) else Q:=V3Scale(Q,1/L);
      Center:=V3Add(A,V3Scale(V3Sub(B,A),T));
      Q:=V3Scale(Q,Radius);Q.X:=Q.X*Aspect.X;Q.Z:=Q.Z*Aspect.Z;
      P:=V3Add(Center,Q);Result:=True;Hit:=True;
    end;
  end;
  if not Hit then Break;
  end;
  if P.Y<Thickness then begin P.Y:=Thickness;Result:=True end;
end;

procedure TAvatarClothSolver.Step(Speed,Acceleration:Single);
var I,J:Integer;D,Force:TTripoVec3;L,W,Alpha,DL,Compliance,Drag:Single;
begin
  Drag:=0.8+1.8*FStiffness;
  Force:=TripoRig.V3((FWind*0.3)*Sin(FTime*1.7),-9.81,
    -(0.6*Sqr(Speed)+0.35*Sqr(FWind))*(350/FDensity)-Acceleration);
  Force:=Limited(Force,55);
  for I:=0 to High(FParticles) do with FParticles[I] do begin
    Previous:=Position;
    if InvMass=0 then begin Position:=Target;Velocity:=TripoRig.V3(0,0,0) end
    else begin
      Velocity:=V3Scale(Velocity,Exp(-Drag*StepTime));
      Velocity:=V3Add(Velocity,V3Scale(Force,StepTime));
      Position:=V3Add(Position,V3Scale(Velocity,StepTime));
    end;
  end;
  for I:=0 to High(FEdges) do FEdges[I].Lambda:=0;
  for J:=0 to 5 do begin
    for I:=0 to High(FEdges) do with FEdges[I] do begin
      W:=FParticles[A].InvMass+FParticles[B].InvMass;
      if W=0 then Continue;
      D:=V3Sub(FParticles[A].Position,FParticles[B].Position);L:=V3Len(D);if L<1e-7 then Continue;
      if Bend then Compliance:=0.0002+0.008*Sqr(1-FStiffness)
      else Compliance:=0.0000002+0.000025*Sqr(1-FStiffness);
      Alpha:=Compliance/Sqr(StepTime);DL:=(-(L-Rest)-Alpha*Lambda)/(W+Alpha);Lambda:=Lambda+DL;
      D:=V3Scale(D,DL/L);
      FParticles[A].Position:=V3Add(FParticles[A].Position,V3Scale(D,FParticles[A].InvMass));
      FParticles[B].Position:=V3Sub(FParticles[B].Position,V3Scale(D,FParticles[B].InvMass));
    end;
    for I:=0 to High(FParticles) do with FParticles[I] do begin
      if InvMass=0 then begin Position:=Target;Continue end;
      Position:=V3Add(Target,Limited(V3Sub(Position,Target),Travel));
      if Project(Position,0.004*FScale) then Inc(FContacts);
    end;
  end;
  for I:=0 to High(FParticles) do with FParticles[I] do begin
    Velocity:=Limited(V3Scale(V3Sub(Position,Previous),1/StepTime),6*FScale);
    if IsNan(Position.X) or IsInfinite(Position.X) or IsNan(Position.Y) or IsInfinite(Position.Y) or
      IsNan(Position.Z) or IsInfinite(Position.Z) or (V3Len(V3Sub(Position,Target))>FScale) then begin
      Position:=Target;Velocity:=TripoRig.V3(0,0,0);
    end;
  end;
  FTime:=FTime+StepTime;Inc(FSteps);
end;

procedure TAvatarClothSolver.Render;
var I,J,K,A,B,C:Integer;P,D,N,Base:TTripoVec3;
begin
  for I:=0 to High(FVertices) do with FVertices[I] do begin
    P:=Skinned(Rest,Joints,Weights);Base:=P;D:=TripoRig.V3(0,0,0);
    if Travel>0 then begin
      for J:=0 to 3 do begin
        K:=Neighbours[J];D:=V3Add(D,V3Scale(V3Sub(FParticles[K].Position,FParticles[K].Target),Blend[J]));
      end;
      P:=V3Add(P,Limited(D,Travel));
      Project(P,0.003*FScale);
    end;
    Positions[I]:=V3Sub(P,FOffset);Offsets[I]:=V3Sub(P,Base);Normals[I]:=TripoRig.V3(0,0,0);
    FSkinPositions[I]:=V3Sub(Base,FOffset);FBaseNormals[I]:=TripoRig.V3(0,0,0);
  end;
  for I:=0 to Length(FIndices) div 3-1 do begin
    A:=FIndices[I*3];B:=FIndices[I*3+1];C:=FIndices[I*3+2];
    N:=V3Cross(V3Sub(Positions[B],Positions[A]),V3Sub(Positions[C],Positions[A]));
    Normals[A]:=V3Add(Normals[A],N);Normals[B]:=V3Add(Normals[B],N);Normals[C]:=V3Add(Normals[C],N);
    N:=V3Cross(V3Sub(FSkinPositions[B],FSkinPositions[A]),V3Sub(FSkinPositions[C],FSkinPositions[A]));
    FBaseNormals[A]:=V3Add(FBaseNormals[A],N);FBaseNormals[B]:=V3Add(FBaseNormals[B],N);FBaseNormals[C]:=V3Add(FBaseNormals[C],N);
  end;
  for I:=0 to High(Normals) do begin
    if V3Len(Normals[I])<1e-9 then Normals[I]:=FVertices[I].Normal else Normals[I]:=V3Norm(Normals[I]);
    NormalOffsets[I]:=V3Sub(Normals[I],V3Norm(FBaseNormals[I]));
  end;
end;

procedure TAvatarClothSolver.Update(Dt,Speed:Single;const Offset:TTripoVec3;Reset:Boolean);
var I,Steps,N:Integer;StartAccum,T,Acceleration,Jump:Single;
begin
  FOffset:=Offset;BuildCapsules;if Dt>0 then FContacts:=0;
  for I:=0 to High(FParticles) do with FParticles[I] do begin
    FFrameTargets[I]:=Skinned(Rest,Joints,Weights);
  end;
  Jump:=0;
  for I:=0 to High(FParticles) do Jump:=Max(Jump,V3Len(V3Sub(FFrameTargets[I],FParticles[I].LastTarget)));
  if ((Dt=0) and (Jump>0.0001)) or (Jump>0.35*FScale) then Reset:=True;
  Reset:=Reset or not FReady or (Dt>0.25);
  if Reset then begin
    FAccum:=0;FLastSpeed:=Speed;FReady:=True;
    for I:=0 to High(FParticles) do with FParticles[I] do begin
      Target:=FFrameTargets[I];LastTarget:=Target;Position:=Target;Previous:=Target;
      Velocity:=TripoRig.V3(0,0,0);
      if InvMass>0 then Project(Position,0.004*FScale);
    end;
  end;
  if (Dt>0) and (Dt<=0.25) then begin
    Acceleration:=EnsureRange((Speed-FLastSpeed)/Dt,-12.0,12.0);FLastSpeed:=Speed;
    StartAccum:=FAccum;FAccum:=FAccum+Dt;Steps:=Min(30,Floor((FAccum+1e-8)/StepTime));
    for N:=1 to Steps do begin
      T:=EnsureRange((N*StepTime-StartAccum)/Dt,0.0,1.0);
      for I:=0 to High(FParticles) do with FParticles[I] do Target:=Mix(LastTarget,FFrameTargets[I],T);
      Step(Speed,Acceleration);FAccum:=FAccum-StepTime;
    end;
    FAccum:=Max(0,FAccum);
  end;
  for I:=0 to High(FParticles) do FParticles[I].LastTarget:=FFrameTargets[I];
  Render;
end;

function TAvatarClothSolver.MaxDisplacement:Single;
var I:Integer;
begin Result:=0;for I:=0 to High(FParticles) do Result:=Max(Result,V3Len(V3Sub(FParticles[I].Position,FParticles[I].Target))) end;
function TAvatarClothSolver.MaxPinError:Single;
var I:Integer;
begin Result:=0;for I:=0 to High(FParticles) do if FParticles[I].InvMass=0 then Result:=Max(Result,V3Len(V3Sub(FParticles[I].Position,FParticles[I].Target))) end;
function TAvatarClothSolver.MaxPenetration:Single;
var I,J:Integer;P,D,Axis:TTripoVec3;T,L,Depth:Single;
begin
  Result:=0;
  for I:=0 to High(FParticles) do if FParticles[I].InvMass>0 then begin
    P:=FParticles[I].Position;Result:=Max(Result,0.004*FScale-P.Y);
    for J:=0 to High(FCapsules) do with FCapsules[J] do begin
      D:=V3Sub(P,A);Axis:=V3Sub(B,A);
      D:=TripoRig.V3(D.X/Aspect.X,D.Y,D.Z/Aspect.Z);
      Axis:=TripoRig.V3(Axis.X/Aspect.X,Axis.Y,Axis.Z/Aspect.Z);
      T:=EnsureRange(V3Dot(D,Axis)/Max(V3Dot(Axis,Axis),1e-9),0.0,1.0);
      L:=V3Len(V3Sub(D,V3Scale(Axis,T)));Depth:=RA+(RB-RA)*T+0.004*FScale-L;
      Result:=Max(Result,Depth*Max(1,Max(Aspect.X,Aspect.Z)));
    end;
  end;
end;
function TAvatarClothSolver.ParticleCount:Integer;
begin Result:=Length(FParticles) end;
function TAvatarClothSolver.CapsuleCount:Integer;
begin Result:=Length(FCapsules) end;
function TAvatarClothSolver.Capsule(Index:Integer):TClothCapsule;
begin Result:=FCapsules[Index] end;
function TAvatarClothSolver.VertexMovable(Index:Integer):Single;
begin Result:=Ord(FVertices[Index].Travel>0) end;
procedure TAvatarClothSolver.State(O:TJSONObject);
begin
  O.Add('id',Id);O.Add('solver','xpbd');O.Add('particles',Length(FParticles));
  O.Add('vertices',Length(FVertices));O.Add('constraints',Length(FEdges));
  O.Add('steps',FSteps);O.Add('time',FTime);O.Add('contacts',FContacts);
  O.Add('max_displacement_m',MaxDisplacement);O.Add('max_pin_error_m',MaxPinError);
  O.Add('max_penetration_m',MaxPenetration);
end;
end.
