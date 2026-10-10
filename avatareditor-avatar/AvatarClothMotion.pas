unit AvatarClothMotion;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, Math, fpjson, X3DNodes, X3DFields, CastleVectors, AvatarGlbIO,
  TripoRig, AvatarClothSolver, AvatarHemDynamics, RiderOcclusion, CastleImages;
type
  TClothRenderBinding = record
    Solver:TAvatarClothSolver;
    First,Count:Integer;
    Position,Normal:TFloatVertexAttributeNode;
    P,N:array of Single;
  end;
  TClothContactUniforms = record
    Solver:TAvatarClothSolver;
    A,B,Aspect:TMFVec4f;
    Floor:TSFFloat;
  end;
  TAvatarClothMotion = class
  private
    FDoc: TGlbDoc;
    FRoot: TX3DNode;
    FMotions: array of TSFVec2f;
    FTime, FDrive, FVelocity, FLastSpeed: Single;
    FRig:TTripoRig;
    FSimulate:Boolean;
    FFabricSurfaces,FDenimSurfaces:Integer;
    FSolvers:array of TAvatarClothSolver;
    FBindings:array of TClothRenderBinding;
    FContacts:array of TClothContactUniforms;
    FHem:TAvatarHemDynamics;
    FHemTexture:TPixelTextureNode;
    FHemProfile:TVector4;
    FLocalFrame,FWorldFrame:TMatrix4;
    FWind:TVector3;
    FHasFrame:Boolean;
    FPelvis:Integer;
    FPelvisRest,FHipRadii:TVector3;
    FLegA,FLegB:array[0..3]of TVector3;
    FLegValid:array[0..3]of Boolean;
    FBuild:Single;
    FSkinQuery:TRiderSkinQuery;
    FCageJoints:array[0..HemPoints-1]of TJointInf;
    FCageWeights:array[0..HemPoints-1]of TWeightInf;
    FCageFrames,FCageMetricFrames:array of TMatrix4;
    FLegEnvelope,FLegWidthEnvelope:TVector4;
    FLegInnerEnvelope:TVector4;
    FLegCentreOffset:Single;
    procedure MeasureLowerLayer;
    procedure BindGarmentCage(Item:TJSONObject);
    procedure UpdateGarmentPose;
    function HasHem:Boolean;
    function HemShader:string;
    procedure Visit(Node: TX3DNode);
    procedure AttachPhysics(Shape:TShapeNode;Item:TJSONObject;PrimIndex:Integer);
    procedure UploadPhysics;
  public
    constructor Create(Root: TX3DNode; Doc: TGlbDoc;Rig:TTripoRig;Simulate:Boolean=True);
    destructor Destroy;override;
    procedure Update(Dt, Speed: Single;const Offset:TVector3;Reset:Boolean=False);
    procedure SetFrame(const Local,World:TMatrix4;const Wind:TVector3);
    procedure SetLegContact(Index:Integer;const A,B:TVector3;Valid:Boolean;Build:Single);
    procedure State(O:TJSONObject);
    function SurfaceCount: Integer;
    property Time: Single read FTime;
    property UsesHemPhysics:Boolean read HasHem;
    property SkinQuery:TRiderSkinQuery read FSkinQuery write FSkinQuery;
  end;
implementation
uses GltfCore, AvatarWardrobe, AvatarWardrobeGeometry, AvatarGarmentPattern, AvatarFabricMaterial, AvatarDenimMaterial, RiderShaderSharing, CastleRenderOptions;
const
  ClothVS =
    'attribute float avatarClothFree;' + #10 + '#ifndef GL_ES' + #10 + 'attribute vec4 castle_Vertex;' + #10 + '#endif' + #10 + ''+#10+
    'uniform vec2 acMotion;uniform vec4 acCloth;'+#10+
    '#ifndef AVATAR_HEM_UNIFORMS'+#10+'#define AVATAR_HEM_UNIFORMS'+#10+
    'uniform vec4 uGarmentHem;'+#10+'#endif'+#10+
    'void PLUG_vertex_object_space(inout vec4 p,inout vec3 n) {'+#10+
    ' float acTime=acMotion.x,acDrive=acMotion.y,acScale=acCloth.x,acFlutter=acCloth.y,acStiffness=acCloth.z,acWind=acCloth.w;'+#10+
    ' float free=avatarClothFree*avatarClothFree;'+#10+
    // The physical cage already has inertia and wind. Do not add a second
    // procedural wave after its collision correction.
    ' if(uGarmentHem.y>0.0)free=0.0;'+#10+
    ' float phase=acTime*(2.4+0.25*acWind)+castle_Vertex.x*13.0/acScale+castle_Vertex.y*7.0/acScale;'+#10+
    ' float ripple=sin(phase)+0.38*sin(phase*1.73+castle_Vertex.z*19.0/acScale);'+#10+
    ' float amplitude=acScale*acFlutter*(1.0-0.85*acStiffness)*free;'+#10+
    ' float wave=amplitude*(0.005+0.0025*acWind+0.01*abs(acDrive));'+#10+
    ' float billow=wave*(0.6+0.4*ripple);'+#10+
    // Outward displacement keeps the fitted shell clear of the body. The
    // tangential lag is deliberately bounded; this is a visual cloth model.
    ' p.xyz+=n*billow+vec3(0.12*sin(phase*0.61),0.0,0.25*acDrive)*wave;'+#10+
    ' vec3 grad=wave*vec3(13.0,7.0,0.0)/acScale*cos(phase)*0.4;'+#10+
    ' n=normalize(n-grad+n*dot(grad,n));'+#10+
    '#ifdef AVATAR_DYNAMIC_HEM'+#10+'acHemDeform(castle_Vertex.xyz,castle_Normal,p,n);'+#10+'#endif'+#10+
    '}';

constructor TAvatarClothMotion.Create(Root: TX3DNode; Doc: TGlbDoc;Rig:TTripoRig;Simulate:Boolean);
var Bind:TTripoMat4;
begin
  inherited Create;FDoc:=Doc;FRoot:=Root;FRig:=Rig;FSimulate:=Simulate;
  FBuild:=1;
  SetLength(FCageFrames,Rig.JointCount);SetLength(FCageMetricFrames,Rig.JointCount);
  FPelvis:=Rig.JointIndexByName('Pelvis');
  if FPelvis>=0 then begin
    Bind:=Mat4Inverse(FRig.NativeInvBind[FPelvis]);
    FPelvisRest:=Vector3(Bind[12],Bind[13],Bind[14]);
  end;
  FRig.ClothingRadiusX:=0;FRig.ClothingRadiusZ:=0;
  MeasureLowerLayer;
  if Root<>nil then Root.EnumerateNodes(TShapeNode,@Visit,False);
  { All runtime bindings and solver data now belong to the motion object.
    The game may release the large authoring document after construction. }
  FDoc:=nil;
  Update(0,0,TVector3.Zero,True);
end;

procedure TAvatarClothMotion.BindGarmentCage(Item:TJSONObject);
var Prims:TJSONArray;Attrs:TJSONObject;P,W,J:TWardrobeFloats;
  Best:array[0..HemPoints-1]of Single;I,K,V,N,C,L,Bone:Integer;D,Sum:Single;Q,R:TVector3;
begin
  for I:=0 to HemPoints-1 do Best[I]:=1e30;
  N:=IntOf(FDoc.NodeObj(Item.Get('node',-1)),'mesh',-1);
  Prims:=ArrOf(ObjAt(ArrOf(FDoc.Root,'meshes'),N),'primitives');
  for K:=0 to CountOf(Prims)-1 do begin
    Attrs:=ObjOf(ObjAt(Prims,K),'attributes');
    P:=WardrobeReadAcc(FDoc,IntOf(Attrs,'POSITION',-1),C);
    W:=WardrobeReadAcc(FDoc,IntOf(Attrs,'WEIGHTS_0',-1),C);
    J:=WardrobeReadAcc(FDoc,IntOf(Attrs,'JOINTS_0',-1),C);
    for I:=0 to HemPoints-1 do begin
      R:=FHem.RestPoint(I);
      for V:=0 to Length(P)div 3-1 do begin
        Q:=Vector3(P[V*3],P[V*3+1],P[V*3+2]);D:=(Q-R).LengthSqr;
        if D>=Best[I]then Continue;Sum:=0;
        for L:=0 to 3 do begin
          Bone:=Round(J[V*4+L]);
          if(Bone=FPelvis)or(Pos('Spine',FRig.JointName[Bone])>0)or(FRig.JointName[Bone]='Waist')then Sum:=Sum+W[V*4+L];
        end;
        if Sum<0.35 then Continue;
        Best[I]:=D;
        for L:=0 to 3 do begin
          Bone:=Round(J[V*4+L]);FCageJoints[I][L]:=Bone;FCageWeights[I][L]:=0;
          if(Bone=FPelvis)or(Pos('Spine',FRig.JointName[Bone])>0)or(FRig.JointName[Bone]='Waist')then FCageWeights[I][L]:=W[V*4+L]/Sum;
        end;
      end;
    end;
  end;
end;

procedure TAvatarClothMotion.UpdateGarmentPose;
const Names:array[0..4]of string=('Pelvis','Waist','Spine','Spine01','Spine02');
var Frames:array[0..4]of TMatrix4;Y:array[0..4]of Single;
  Targets,Metric:THemPositions;I,J,K,R,C,Row,B:Integer;P:TVector3;
  M:TMatrix4;Bind:TTripoMat4;T:Single;
begin
  if FHem=nil then Exit;
  for I:=0 to 4 do begin
    J:=FRig.JointIndexByName(Names[I]);Frames[I]:=TMatrix4.Identity;Y[I]:=1+I*0.1;
    if J<0 then Continue;
    Bind:=Mat4Inverse(FRig.NativeInvBind[J]);Y[I]:=Bind[13];
    if not(Assigned(FSkinQuery)and FSkinQuery(Names[I],Frames[I]))then
      for C:=0 to 3 do for R:=0 to 3 do Frames[I].Data[C,R]:=FRig.SkinMatrix[J][C*4+R];
    FCageFrames[J]:=Frames[I];
    Bind:=Mat4Mul(FRig.BindWorld[J],FRig.NativeInvBind[J]);
    for C:=0 to 3 do for R:=0 to 3 do FCageMetricFrames[J].Data[C,R]:=Bind[C*4+R];
  end;
  for Row:=0 to HemRows-1 do begin
    P:=FHem.RestPoint(Row*HemRing);J:=0;
    if Row>=HemTorsoRows then
      T:=0.42*(1-GarmentSmooth(0,0.09,1.10-P.Y/FHemProfile.Z))
    else begin
      while(J<3)and(P.Y>Y[J+1])do Inc(J);
      T:=EnsureRange((P.Y-Y[J])/Max(0.001,Y[J+1]-Y[J]),0.0,1.0);
    end;
    M:=TMatrix4.Identity;
    for C:=0 to 3 do for R:=0 to 3 do M.Data[C,R]:=Frames[J].Data[C,R]*(1-T)+Frames[J+1].Data[C,R]*T;
    for K:=0 to HemRing-1 do begin
      I:=Row*HemRing+K;P:=FHem.RestPoint(I);Targets[I]:=TVector3.Zero;Metric[I]:=TVector3.Zero;
      for B:=0 to 3 do if FCageWeights[I][B]>0 then begin
        J:=FCageJoints[I][B];Targets[I]:=Targets[I]+FCageFrames[J].MultPoint(P)*FCageWeights[I][B];
        Metric[I]:=Metric[I]+FCageMetricFrames[J].MultPoint(P)*FCageWeights[I][B];
      end;
    end;
    if Row<=HemTorsoRows then FHem.SetBody(Row,M,FBuild);
  end;
  FHem.SetPose(Targets);FHem.SetMetric(Metric);
  FHem.SetHip(Frames[0],FPelvisRest+Vector3(0,0,-0.012*FHemProfile.Z),FHipRadii*FBuild);
end;

procedure TAvatarClothMotion.MeasureLowerLayer;
var Items,Prims:TJSONArray;Item,Attrs:TJSONObject;I,J,V,K,L,C,Joint,N,Slot,Pass:Integer;
  P,W,Ids,Indices:TWardrobeFloats;A,B,Q,Axis,Lat,Front:TVector3;M:TTripoMat4;
  Scale,T,Weight,Denom,Lateral,Depth,RX,RZ,Metric:Single;Side,First,Last:string;
  Outer,Inner:Boolean;
  procedure Expand(var Envelope:TVector4;Required:Single);
  var Extra:Single;
  begin
    Extra:=Required-(Envelope.Data[Slot]*(1-T)+Envelope.Data[Slot+1]*T);
    if Extra<=0 then Exit;
    Denom:=Sqr(1-T)+Sqr(T);
    Envelope.Data[Slot]:=Envelope.Data[Slot]+Extra*(1-T)/Denom;
    Envelope.Data[Slot+1]:=Envelope.Data[Slot+1]+Extra*T/Denom;
  end;
begin
  Scale:=WardrobeBindScale(FDoc);FLegEnvelope:=Vector4(0.113,0.079,0.083,0.060)*Scale;
  FLegWidthEnvelope:=Vector4(0.110,0.080,0.083,0.063)*Scale;
  FLegInnerEnvelope:=FLegWidthEnvelope;
  Items:=WardrobeItems(FDoc);
  Outer:=False;
  for I:=0 to CountOf(Items)-1 do begin
    Item:=ObjAt(Items,I);
    if Item.Get('enabled',False)and(Item.Get('slot','')='outer')then begin Outer:=True;Break end;
  end;
  if not Outer then Exit;
  FLegCentreOffset:=0;
  for I:=0 to CountOf(Items)-1 do begin
    Item:=ObjAt(Items,I);
    if Item.Get('enabled',False)and(Item.Get('preset','')='jeans')then begin
      { Denim is centred behind the leg bone, like the trouser pattern.
        Fitting a symmetric radius around the bone added the rear ease
        again at the front and started from an oversized lateral radius. }
      FLegCentreOffset:=0.015*Scale;
      FLegWidthEnvelope:=Vector4(0.060,0.052,0.050,0.040)*Scale;
      FLegInnerEnvelope:=FLegWidthEnvelope;
      FLegEnvelope:=Vector4(0.095,0.065,0.060,0.045)*Scale;
      Break;
    end;
  end;
  for Pass:=0 to 1 do for I:=0 to CountOf(Items)-1 do begin
    Item:=ObjAt(Items,I);
    if not Item.Get('enabled',False)or(Item.Get('slot','')<>'bottom')then Continue;
    N:=IntOf(ObjAt(ArrOf(FDoc.Root,'nodes'),Item.Get('node',-1)),'mesh',-1);
    Prims:=ArrOf(ObjAt(ArrOf(FDoc.Root,'meshes'),N),'primitives');
    for J:=0 to CountOf(Prims)-1 do begin
      Attrs:=ObjOf(ObjAt(Prims,J),'attributes');
      P:=WardrobeReadAcc(FDoc,IntOf(Attrs,'POSITION',-1),C);
      Ids:=WardrobeReadAcc(FDoc,IntOf(Attrs,'JOINTS_0',-1),C);
      W:=WardrobeReadAcc(FDoc,IntOf(Attrs,'WEIGHTS_0',-1),C);
      Indices:=WardrobeReadAcc(FDoc,IntOf(ObjAt(Prims,J),'indices',-1),C);
      for L:=0 to 3 do begin
        if L mod 2=0 then Side:='L_'else Side:='R_';
        if L<2 then begin First:='Thigh';Last:='Calf';Slot:=0 end
        else begin First:='Calf';Last:='Foot';Slot:=2 end;
        Joint:=FRig.JointIndexByName(Side+First);
        M:=Mat4Inverse(FRig.NativeInvBind[Joint]);A:=Vector3(M[12],M[13],M[14]);
        M:=Mat4Inverse(FRig.NativeInvBind[FRig.JointIndexByName(Side+Last)]);B:=Vector3(M[12],M[13],M[14]);Axis:=B-A;
        Lat:=Vector3(1,0,0)-Axis*(Axis.X/Max(Axis.LengthSqr,1e-8));Lat:=Lat.Normalize;
        Front:=TVector3.CrossProduct(Lat,Axis).Normalize;
        A:=A+Front*FLegCentreOffset;
        for K:=0 to High(Indices)do begin
          V:=Round(Indices[K]);Weight:=0;
          for N:=0 to 3 do if Round(Ids[V*4+N])=Joint then Weight:=Weight+W[V*4+N];
          if Weight<0.45 then Continue;
          Q:=Vector3(P[V*3],P[V*3+1],P[V*3+2])-A;
          T:=TVector3.DotProduct(Q,Axis)/Max(Axis.LengthSqr,1e-8);
          if(T<0.06)or(T>0.94)then Continue;
          Q:=Q-Axis*T;
          { Fit lateral and sagittal dimensions independently. A round
            collider sized for the buttocks gives the jacket a skirt flare. }
          Lateral:=TVector3.DotProduct(Q,Lat);if Side='R_'then Lateral:=-Lateral;
          Inner:=Lateral<0;Lateral:=Abs(Lateral);Depth:=Abs(TVector3.DotProduct(Q,Front));
          if Pass=0 then begin
            if Inner then Expand(FLegInnerEnvelope,Lateral+0.007*Scale)
            else Expand(FLegWidthEnvelope,Lateral+0.007*Scale);
            Expand(FLegEnvelope,Depth+0.007*Scale);
          end else begin
            { Fit the combined section, not only its axis extents. The
              medial crotch bridge has a rounded rectangular corner;
              the outside of the thigh retains its elliptical profile. }
            if Inner then RX:=FLegInnerEnvelope.Data[Slot]*(1-T)+FLegInnerEnvelope.Data[Slot+1]*T
            else RX:=FLegWidthEnvelope.Data[Slot]*(1-T)+FLegWidthEnvelope.Data[Slot+1]*T;
            RZ:=FLegEnvelope.Data[Slot]*(1-T)+FLegEnvelope.Data[Slot+1]*T;
            if Inner then Metric:=Sqrt(Sqrt(Sqr(Sqr(Lateral/Max(0.001,RX)))+Sqr(Sqr(Depth/Max(0.001,RZ)))))
            else Metric:=Sqrt(Sqr(Lateral/Max(0.001,RX))+Sqr(Depth/Max(0.001,RZ)));
            { Apply clearance to the measured point instead of inflating
              the front/back by the narrower lateral radius. }
            Metric:=Metric*(1+0.007*Scale/Max(0.001,Sqrt(Sqr(Lateral)+Sqr(Depth))));
            if Metric>1 then begin
              if Inner then Expand(FLegInnerEnvelope,RX*Metric)
              else Expand(FLegWidthEnvelope,RX*Metric);
              Expand(FLegEnvelope,RZ*Metric);
            end;
          end;
        end;
      end;
    end;
  end;
end;

destructor TAvatarClothMotion.Destroy;
var I:Integer;
begin
  for I:=0 to High(FSolvers) do FSolvers[I].Free;FHem.Free;
  if FHemTexture<>nil then begin FHemTexture.KeepExistingEnd;FHemTexture.FreeIfUnused end;
  inherited;
end;

procedure TAvatarClothMotion.SetFrame(const Local,World:TMatrix4;const Wind:TVector3);
begin FLocalFrame:=Local;FWorldFrame:=World;FWind:=Wind;FHasFrame:=True end;
function TAvatarClothMotion.HasHem:Boolean;
begin Result:=FHem<>nil end;
procedure TAvatarClothMotion.SetLegContact(Index:Integer;const A,B:TVector3;Valid:Boolean;Build:Single);
begin
  if(Index<0)or(Index>3)then Exit;
  FLegA[Index]:=A;FLegB[Index]:=B;FLegValid[Index]:=Valid;FBuild:=Build;
end;

procedure TAvatarClothMotion.AttachPhysics(Shape:TShapeNode;Item:TJSONObject;PrimIndex:Integer);
{ Apply the solved displacement after CGE's skin and the authored body
  correctives. Replacing the entire position with linear CPU skinning would
  undo the shoulder/wrist corrections and detach sleeves from the hands. }
const VS=
  'attribute vec4 acSolvedPosition;attribute vec3 acSolvedNormal;'+#10+
  'uniform float acScale,acFloor;'+#10+
  'uniform vec4 acCapsA[10],acCapsB[10],acCapsAspect[10];'+#10+
  'void PLUG_vertex_object_space(inout vec4 p,inout vec3 n){'+#10+
  'p.xyz+=acSolvedPosition.xyz;n=normalize(n+acSolvedNormal);'+#10+
  'if(acSolvedPosition.w>0.5){for(int pass=0;pass<3;pass++){for(int i=0;i<10;i++){'+#10+
  'vec3 aspect=acCapsAspect[i].xyz;vec3 axis=(acCapsB[i].xyz-acCapsA[i].xyz)/aspect;'+#10+
  'vec3 d=(p.xyz-acCapsA[i].xyz)/aspect;float t=clamp(dot(d,axis)/max(dot(axis,axis),0.000001),0.0,1.0);'+#10+
  'vec3 q=d-axis*t;float len=length(q);float radius=mix(acCapsA[i].w,acCapsB[i].w,t)+0.009*acScale;'+#10+
  'if(len<radius && len>0.000001){vec3 centre=mix(acCapsA[i].xyz,acCapsB[i].xyz,t);'+#10+
  'p.xyz=centre+q*(radius/len)*aspect;n=normalize(mix(n,normalize(q/aspect),clamp((radius-len)*18.0,0.0,0.65)));}'+#10+
  '}}p.y=max(p.y,acFloor);} }' +#10;
var I,N,C:Integer;Solver:TAvatarClothSolver;Geo:TAbstractComposedGeometryNode;
  Eff:TEffectNode;V:TEffectPartNode;
  function Attribute(const Name:string;Components:Integer):TFloatVertexAttributeNode;
  var K:Integer;
  begin
    Result:=TFloatVertexAttributeNode.Create;Result.NameField:=Name;Result.NumComponents:=Components;
    for K:=0 to FBindings[N].Count*Components-1 do Result.FdValue.Items.Add(0);
    Geo.FdAttrib.Add(Result);
  end;
begin
  Solver:=nil;
  for I:=0 to High(FSolvers) do if FSolvers[I].Id=Item.Get('id','') then Solver:=FSolvers[I];
  if Solver=nil then begin
    Solver:=TAvatarClothSolver.Create(FDoc,Item,FRig);I:=Length(FSolvers);
    SetLength(FSolvers,I+1);FSolvers[I]:=Solver;
  end;
  if (PrimIndex<0) or (PrimIndex>=Length(Solver.Primitives)) then
    raise EReadError.Create('Cannot identify simulated clothing primitive');
  Geo:=TAbstractComposedGeometryNode(Shape.Geometry);
  if TCoordinateNode(Geo.Coord).FdPoint.Count<>Solver.Primitives[PrimIndex].Count then
    raise EReadError.Create('Cloth render vertex count does not match the GLB');
  N:=Length(FBindings);SetLength(FBindings,N+1);
  FBindings[N].Solver:=Solver;FBindings[N].First:=Solver.Primitives[PrimIndex].First;
  FBindings[N].Count:=Solver.Primitives[PrimIndex].Count;
  FBindings[N].Position:=Attribute('acSolvedPosition',4);FBindings[N].Normal:=Attribute('acSolvedNormal',3);
  SetLength(FBindings[N].P,FBindings[N].Count*4);SetLength(FBindings[N].N,FBindings[N].Count*3);
  for I:=0 to Shape.Appearance.FdEffects.Count-1 do
    if Shape.Appearance.FdEffects[I].X3DName='AvatarSolvedCloth' then Exit;
  Eff:=TEffectNode.Create('AvatarSolvedCloth');Eff.Language:=slGLSL;Eff.UniformMissing:=umIgnore;
  C:=Length(FContacts);SetLength(FContacts,C+1);FContacts[C].Solver:=Solver;
  FContacts[C].A:=TMFVec4f.Create(Eff,True,'acCapsA',[]);Eff.AddCustomField(FContacts[C].A);
  FContacts[C].B:=TMFVec4f.Create(Eff,True,'acCapsB',[]);Eff.AddCustomField(FContacts[C].B);
  FContacts[C].Aspect:=TMFVec4f.Create(Eff,True,'acCapsAspect',[]);Eff.AddCustomField(FContacts[C].Aspect);
  FContacts[C].Floor:=TSFFloat.Create(Eff,True,'acFloor',0);Eff.AddCustomField(FContacts[C].Floor);
  Eff.AddCustomField(TSFFloat.Create(Eff,True,'acScale',Max(0.1,FRig.JointBindPos(FRig.JointIndexByName('Head')).Y/1.58)));
  V:=TEffectPartNode.Create;V.ShaderType:=stVertex;V.Contents:=VS;
  Eff.SetParts([V]);ShareRiderEffect(Eff);Shape.Appearance.FdEffects.Add(Eff);Eff.Scene:=FRoot.Scene;
end;

procedure TAvatarClothMotion.UploadPhysics;
var I,J,K:Integer;SampleP,SampleN:TTripoVec3;Cap:TClothCapsule;
  A,B,Aspects:array[0..9]of TVector4;
begin
  for I:=0 to High(FBindings) do with FBindings[I] do begin
    for J:=0 to Count-1 do begin
      K:=First+J;SampleP:=Solver.Offsets[K];SampleN:=Solver.NormalOffsets[K];
      FBindings[I].P[J*4]:=SampleP.X;FBindings[I].P[J*4+1]:=SampleP.Y;FBindings[I].P[J*4+2]:=SampleP.Z;
      FBindings[I].P[J*4+3]:=Solver.VertexMovable(K);
      FBindings[I].N[J*3]:=SampleN.X;FBindings[I].N[J*3+1]:=SampleN.Y;FBindings[I].N[J*3+2]:=SampleN.Z;
    end;
    Position.FdValue.Send(FBindings[I].P);Normal.FdValue.Send(FBindings[I].N);
  end;
  for I:=0 to High(FContacts) do begin
    for J:=0 to 9 do begin
      A[J]:=Vector4(0,-100,0,0);B[J]:=A[J];Aspects[J]:=Vector4(1,1,1,0);
      if J<FContacts[I].Solver.CapsuleCount then begin
        Cap:=FContacts[I].Solver.Capsule(J);SampleP:=FContacts[I].Solver.Offset;
        A[J]:=Vector4(Cap.A.X-SampleP.X,Cap.A.Y-SampleP.Y,Cap.A.Z-SampleP.Z,Cap.RA);
        B[J]:=Vector4(Cap.B.X-SampleP.X,Cap.B.Y-SampleP.Y,Cap.B.Z-SampleP.Z,Cap.RB);
        Aspects[J]:=Vector4(Cap.Aspect.X,Cap.Aspect.Y,Cap.Aspect.Z,0);
      end;
    end;
    FContacts[I].A.Send(A);FContacts[I].B.Send(B);FContacts[I].Aspect.Send(Aspects);
    FContacts[I].Floor.Send(0.003-FContacts[I].Solver.Offset.Y);
  end;
end;

function TAvatarClothMotion.HemShader:string;
var S:TStringList;I,J,K:Integer;Side:string;
  function Num(X:Single):string;
  begin Str(X:0:9,Result) end;
  function Pivot(J:Integer):string;
  var M:TTripoMat4;
  begin M:=Mat4Inverse(FRig.NativeInvBind[J]);Result:='vec3('+Num(M[12])+','+Num(M[13])+','+Num(M[14])+')' end;
begin
  S:=TStringList.Create;
  try
    S.Add('#define AVATAR_DYNAMIC_HEM');
    S.Add('#ifndef AVATAR_HEM_UNIFORMS');S.Add('#define AVATAR_HEM_UNIFORMS');
    S.Add('uniform vec4 uGarmentHem;uniform sampler2D uGarmentMotion;');S.Add('#endif');
    S.Add('uniform vec4 uGarmentClearance,uGarmentLegRadii,uGarmentLegWidths,uGarmentLegInnerWidths;uniform float uGarmentSlack,uGarmentLegOffset;');
    { CGE compiles each effect as a separate GLSL object. Declare the
      shared skin interface explicitly; its definitions live in the native
      corrective or procedural GPU skin effect. }
    S.Add('mat4 bodyJoint(int j);' + #10 + '#ifndef GL_ES' + #10 + 'mat4 skinMatrix;' + #10 + '#endif' + #10 + 'uniform vec4 uBodyProfile;');
    S.Add('attribute vec4 riderTissue;attribute vec3 castle_Normal;');
    S.Add('mat4 garmentHip;mat3 garmentHipInverse;vec3 garmentA[4],garmentB[4],garmentX[4],garmentArmA[2],garmentArmB[2],garmentRadii,garmentOut;float garmentBuild,garmentFreedom,garmentArmContact;');
    S.Add('void acGarmentPrepare(){garmentHip=bodyJoint('+IntToStr(FRig.JointIndexByName('Pelvis'))+');');
    { Body proportions can scale the skin frame. Transpose alone is not
      its inverse and inflated contact around the pelvis on scaled riders. }
    S.Add('vec3 hx=garmentHip[0].xyz,hy=garmentHip[1].xyz,hz=garmentHip[2].xyz;vec3 ix=cross(hy,hz),iy=cross(hz,hx),iz=cross(hx,hy);float det=dot(hx,ix);');
    S.Add('garmentHipInverse=abs(det)>1e-8?transpose(mat3(ix,iy,iz))/det:mat3(1.0);');
    S.Add('garmentBuild=clamp(1.0+0.18*uBodyProfile.x+0.09*uBodyProfile.y,0.88,1.27);garmentRadii=uGarmentClearance.xyz*garmentBuild;');
    for I:=0 to 3 do begin
      if I mod 2=0 then Side:='R_'else Side:='L_';
      if I<2 then begin J:=FRig.JointIndexByName(Side+'Thigh');K:=FRig.JointIndexByName(Side+'Calf')end
      else begin J:=FRig.JointIndexByName(Side+'Calf');K:=FRig.JointIndexByName(Side+'Foot')end;
      S.Add('garmentA['+IntToStr(I)+']=(bodyJoint('+IntToStr(J)+')*vec4('+Pivot(J)+',1)).xyz;');
      S.Add('garmentB['+IntToStr(I)+']=(bodyJoint('+IntToStr(K)+')*vec4('+Pivot(K)+',1)).xyz;');
      S.Add('garmentX['+IntToStr(I)+']=normalize(mat3(bodyJoint('+IntToStr(J)+'))*vec3(1,0,0));');
      S.Add('{vec3 offset=normalize(cross(garmentX['+IntToStr(I)+'],garmentB['+IntToStr(I)+']-garmentA['+IntToStr(I)+']))*uGarmentLegOffset*garmentBuild;garmentA['+IntToStr(I)+']+=offset;garmentB['+IntToStr(I)+']+=offset;}');
    end;
    for I:=0 to 1 do begin
      if I=0 then Side:='R_'else Side:='L_';
      J:=FRig.JointIndexByName(Side+'Forearm');K:=FRig.JointIndexByName(Side+'Hand');
      S.Add('garmentArmA['+IntToStr(I)+']=(bodyJoint('+IntToStr(J)+')*vec4('+Pivot(J)+',1)).xyz;');
      S.Add('garmentArmB['+IntToStr(I)+']=(bodyJoint('+IntToStr(K)+')*vec4('+Pivot(K)+',1)).xyz;');
      S.Add('garmentArmB['+IntToStr(I)+']+=normalize(garmentArmB['+IntToStr(I)+']-garmentArmA['+IntToStr(I)+'])*0.065*uGarmentHem.z;');
    end;
    S.Add('}');
    S.Add(OuterwearSectionGLSL);
    { One continuous cage spans torso and hem. Smooth interpolation keeps
      the armhole seam pinned. There is no artificial hinge at the waist. }
    S.Add('vec3 acMotionPoint(int i){return texture2D(uGarmentMotion,vec2((float(i-18*(i/18))+0.5)/18.0,(float(i/18)+0.5)/8.0)).xyz;}');
    S.Add('vec3 acHemRing(int r,int side,int j,float f,float sewn){if(r==0)return vec3(0);int base=(r-1)*18;vec3 p=mix(acMotionPoint(base+side+j),acMotionPoint(base+side+j+1),f);');
    S.Add('if(sewn>0.0001){int other=9-side;p=mix(p,mix(acMotionPoint(base+other+j),acMotionPoint(base+other+j+1),f),sewn);}return p;}');
    S.Add('vec3 acHemOffset(vec3 rest){float t=clamp((uGarmentHem.x-rest.y)/max(uGarmentHem.y,0.001),0.0,1.0);');
    S.Add('float front=(0.014+0.12*smoothstep(0.05,0.6,t))*uGarmentHem.w,back=0.10*smoothstep(0.66,1.0,t)*uGarmentHem.w;');
    S.Add('vec3 section=acGarmentSection(rest.y/uGarmentHem.z,uGarmentSlack)*uGarmentHem.z;vec2 q=vec2(rest.x,rest.z-section.z)/section.xy;float exponent=acGarmentSectionExponent(rest.y/uGarmentHem.z);q=sign(q)*pow(abs(q),vec2(1.0/exponent));float angle=abs(atan(q.x,q.y));');
    S.Add('float c=clamp((angle-front)/(3.14159265-front-back)*8.0,0.0,8.0);int j=int(min(floor(c),7.0)),side=rest.x<0.0?9:0;float f=c-float(j);');
    S.Add('float sewn=0.5*smoothstep(0.82,1.0,c/8.0)*(1.0-smoothstep(0.66,0.84,t)*uGarmentHem.w);');
    S.Add('sewn=max(sewn,0.5*(1.0-smoothstep(0.0,0.18,c/8.0))*(1.0-uGarmentHem.w));');
    S.Add('float v=rest.y>uGarmentHem.x?clamp((1.43*uGarmentHem.z-rest.y)/(0.33*uGarmentHem.z),0.0,1.0)*4.0:4.0+t*4.0;int row=int(min(floor(v),7.0));v-=float(row);vec3 a=acHemRing(row,side,j,f,sewn),b=acHemRing(row+1,side,j,f,sewn);');
    { Hermite tangents are derivatives with respect to actual rest height.
      Torso rows span 33 cm; hem rows span the preset's different length.
      Equal-index tangents introduced a shading crease at their join. }
    S.Add('float upper=0.33*uGarmentHem.z,lower=max(uGarmentHem.y,0.001),dy=row<4?upper:lower,previous=row<5?upper:lower,next=row<3?upper:lower;');
    S.Add('vec3 da=row==0?vec3(0):(b-acHemRing(row-1,side,j,f,sewn))*(dy/(previous+dy)),db=row==7?b-a:(acHemRing(row+2,side,j,f,sewn)-a)*(dy/(dy+next));');
    S.Add('float influence=(1.0-smoothstep(1.41,1.47,rest.y/uGarmentHem.z))*(1.0-smoothstep(0.19,0.275,abs(rest.x)/uGarmentHem.z));return influence*((2.0*v*v*v-3.0*v*v+1.0)*a+(v*v*v-2.0*v*v+v)*da+(-2.0*v*v*v+3.0*v*v)*b+(v*v*v-v*v)*db);}');
    S.Add('vec3 acLinedOffset(vec3 rest,vec3 n){vec3 d=acHemOffset(rest);float lining=smoothstep(1.08,1.16,rest.y/uGarmentHem.z);return d-n*min(0.0,dot(d,n)+0.010*uGarmentHem.z)*lining;}');
    S.Add('void acGarmentDrape(vec3 rest,vec3 normal,mat4 skin,inout vec3 p,inout vec3 n){');
    S.Add('vec3 d=acLinedOffset(rest,garmentOut);vec3 a=normalize(cross(normal,abs(normal.y)<0.9?vec3(0,1,0):vec3(1,0,0))),b=cross(normal,a);float e=0.0005;');
    S.Add('vec3 ta=mat3(skin)*a+(acLinedOffset(rest+a*e,garmentOut)-acLinedOffset(rest-a*e,garmentOut))/(2.0*e);');
    S.Add('vec3 tb=mat3(skin)*b+(acLinedOffset(rest+b*e,garmentOut)-acLinedOffset(rest-b*e,garmentOut))/(2.0*e);');
    S.Add('vec3 area=cross(ta,tb);if(dot(area,area)>1e-12)n=normalize(area);p+=d;}');
    S.Add('vec3 acGarmentPush(vec3 p){vec3 start=p;if(uGarmentClearance.x<0.001)return vec3(0);vec3 hc='+Pivot(FRig.JointIndexByName('Pelvis'))+'+vec3(0.0,0.0,-0.012*uGarmentHem.z);');
    S.Add('if(garmentFreedom>0.001)for(int pass=0;pass<2;pass++){vec3 q=garmentHipInverse*(p-garmentHip[3].xyz)-hc;float d=pow(dot(pow(abs(q/garmentRadii),vec3('+Num(OuterwearHipPower)+')),vec3(1.0)),'+Num(1/OuterwearHipPower)+');if(d<1.04&&d>0.001){float depth=d<0.96?1.0-d:(1.04-d)*(1.04-d)/0.16;p+=mat3(garmentHip)*(q*(depth/d));}');
    S.Add('for(int i=0;i<4;i++){vec3 a=garmentA[i],ab=garmentB[i]-a;float t=clamp(dot(p-a,ab)/max(dot(ab,ab),1e-5),0.025,0.99);vec3 q=p-a-ab*t;vec3 ay=normalize(ab),ax=normalize(garmentX[i]-ay*dot(garmentX[i],ay)),az=cross(ax,ay);');
    S.Add('float rz=(i<2?mix(uGarmentLegRadii.x,uGarmentLegRadii.y,t):mix(uGarmentLegRadii.z,uGarmentLegRadii.w,t))*garmentBuild,rx=(i<2?mix(uGarmentLegWidths.x,uGarmentLegWidths.y,t):mix(uGarmentLegWidths.z,uGarmentLegWidths.w,t))*garmentBuild;');
    S.Add('float ri=(i<2?mix(uGarmentLegInnerWidths.x,uGarmentLegInnerWidths.y,t):mix(uGarmentLegInnerWidths.z,uGarmentLegInnerWidths.w,t))*garmentBuild,side=(i==0||i==2)?1.0:-1.0;');
    { Use the same fitted section as the cage. Clearance is measured from
      the lower garment once; do not add it again to every rendered vertex. }
    S.Add('float ry=max(rx,rz);if(i<2&&dot(q,ay)<0.0)ry=min(ry,0.035*uGarmentHem.z*garmentBuild);vec3 section=vec3(dot(q,ax),dot(q,ay),dot(q,az)),local=section/vec3(rx,ry,rz);float d=length(local);if(section.x*side>0.0&&ri>rx+0.0001){local.x=section.x/ri;d=sqrt(length(local.xz*local.xz)+local.y*local.y);}if(d<1.025&&d>0.001){');
    { The cage carries sided contact and panel motion. The dense mesh
      receives only a continuous residual correction, without an alternate
      outward ray that could pull neighbouring vertices apart. }
    S.Add('float depth=d<0.975?1.0-d:(1.025-d)*(1.025-d)/0.10;vec3 radial=q*(depth/d);');
    S.Add('p+=radial;}}');
    S.Add('}p=mix(start,p,garmentFreedom);');
    S.Add('if(garmentArmContact>0.001)for(int i=0;i<2;i++){vec3 a=garmentArmA[i],ab=garmentArmB[i]-a;float t=clamp(dot(p-a,ab)/max(dot(ab,ab),1e-5),0.0,1.0);vec3 q=p-a-ab*t;float d=length(q),r=mix(0.061,0.047,t)*uGarmentHem.z*garmentBuild;');
    S.Add('if(d<r&&d>0.001)p+=q*(min(0.035*uGarmentHem.z,r-d)/d)*garmentArmContact;}return p-start;}');

    S.Add('void acHemDeform(vec3 rest,vec3 restN,inout vec4 vertex,inout vec3 n){');
    S.Add('if(riderTissue.z<2.5)return;float y=rest.y/uGarmentHem.z,x=abs(rest.x)/uGarmentHem.z;');
    { Contact must use the outside of the garment panel. A hem/seam normal
      may point down or sideways and can push adjacent vertices onto
      opposite sides of a leg, tearing an otherwise continuous panel. }
    S.Add('vec3 section=acGarmentSection(y,uGarmentSlack)*uGarmentHem.z;vec2 outside=vec2(rest.x,rest.z-section.z)/section.xy;outside=sign(outside)*pow(abs(outside),vec2(2.0/acGarmentSectionExponent(y)-1.0))/section.xy;garmentOut=normalize(mat3(skinMatrix)*vec3(outside.x,0,outside.y));');
    S.Add('garmentFreedom=1.0-smoothstep(1.12,1.26,y);garmentArmContact=(1.0-smoothstep(0.18,0.27,x))*(1.0-smoothstep(1.29,1.38,y));');
    S.Add('if(y>1.48||x>0.28)return;acGarmentPrepare();vec3 p=vertex.xyz;');
    S.Add('acGarmentDrape(rest,restN,skinMatrix,p,n);vec3 push=acGarmentPush(p);');
    S.Add('if(dot(push,push)>1e-16){vec3 t=normalize(cross(n,abs(n.y)<0.9?vec3(0,1,0):vec3(1,0,0))),b=cross(n,t);float e=0.0005;');
    S.Add('vec3 dt=t+(acGarmentPush(p+t*e)-acGarmentPush(p-t*e))/(2.0*e),db=b+(acGarmentPush(p+b*e)-acGarmentPush(p-b*e))/(2.0*e);');
    S.Add('n=normalize(cross(dt,db));p+=push;}vertex.xyz=p;}');
    Result:=S.Text;
  finally S.Free end;
end;

procedure TAvatarClothMotion.Visit(Node: TX3DNode);
var Sh: TShapeNode; App: TAppearanceNode; Mat: TPhysicalMaterialNode;
  Geo: TAbstractComposedGeometryNode; Coord: TCoordinateNode;
  Attr,Contact: TFloatVertexAttributeNode; Eff: TEffectNode; VS: TEffectPartNode;
  Items,Origins,TintMaterials: TJSONArray; Item: TJSONObject; I,J,PrimIndex: Integer; Name,Id,MaterialName: string;
  SourceShape: TShapeNode; SourceGeo: TAbstractComposedGeometryNode;
  YMin,YMax,Freedom,Scale: Single; P: TVector3; Motion: TSFVec2f;
  HasDonor,IsFabric,Outer,Denim:Boolean;K,Mask:Integer;Marker,Value,Slack,Density:Single;
  TextureField:TSFNode;Pixels:TRGBAlphaFloatImage;Props:TTexturePropertiesNode;
  Pattern:TOuterwearPattern;
  procedure ZeroAttribute(const Name:string;Components:Integer);
  var A:TFloatVertexAttributeNode;K:Integer;
  begin
    for K:=0 to Geo.FdAttrib.Count-1 do
      if(Geo.FdAttrib[K]is TFloatVertexAttributeNode)and(TFloatVertexAttributeNode(Geo.FdAttrib[K]).NameField=Name)then Exit;
    A:=TFloatVertexAttributeNode.Create;A.NameField:=Name;A.NumComponents:=Components;
    for K:=1 to Coord.FdPoint.Count*Components do A.FdValue.Items.Add(0);
    Geo.FdAttrib.Add(A);
  end;
begin
  Sh:=TShapeNode(Node);
  if not (Sh.Appearance is TAppearanceNode) or not (Sh.Geometry is TAbstractComposedGeometryNode) then Exit;
  App:=TAppearanceNode(Sh.Appearance);
  if not (App.Material is TPhysicalMaterialNode) then Exit;
  Mat:=TPhysicalMaterialNode(App.Material);Name:=LowerCase(Sh.X3DName+' '+Mat.X3DName+' '+App.X3DName);
  if Pos('avatarcloth_',Name)=0 then Exit;
  Items:=WardrobeItems(FDoc);Item:=nil;
  for I:=0 to CountOf(Items)-1 do begin
    Id:=ObjAt(Items,I).Get('id','');
    if Pos('avatarcloth_'+Id,Name)>0 then begin Item:=ObjAt(Items,I);Break end;
  end;
  if Item=nil then Exit;
  { Fabric belongs only on fabric, not on buttons, soles or metal trim.
    Imported cloth without a tint list uses its declared material list. }
  TintMaterials:=ArrOf(Item,'tintMaterials');
  if TintMaterials=nil then TintMaterials:=ArrOf(Item,'materials');
  IsFabric:=False;
  for I:=0 to CountOf(TintMaterials)-1 do begin
    MaterialName:=StrOf(ObjAt(ArrOf(FDoc.Root,'materials'),TintMaterials.Integers[I]),'name','');
    if(MaterialName<>'')and((App.X3DName=MaterialName)or(Mat.X3DName=MaterialName))then begin
      IsFabric:=True;
      if ApplyAvatarFabric(Sh,Item.Get('preset',''))then Inc(FFabricSurfaces);
      Break;
    end;
  end;
  if not Item.Get('cloth',True) then Exit;
  Geo:=TAbstractComposedGeometryNode(Sh.Geometry);
  if not (Geo.Coord is TCoordinateNode) then Exit;
  Coord:=TCoordinateNode(Geo.Coord);if Coord.FdPoint.Count=0 then Exit;
  { Preset garments retain the donor's vertex ordering. Share its authored
    corrective attributes so the sewn edges stay together during bending. }
  Outer:=Item.Get('slot','')='outer';Denim:=Item.Get('preset','')='jeans';
  HasDonor:=False;Origins:=ArrOf(Item,'sourceShapes');I:=Pos('_Primitive',Sh.X3DName);
  PrimIndex:=StrToIntDef(Copy(Sh.X3DName,I+10,MaxInt),-1);
  if not Outer and not Denim and (I>0) and (PrimIndex>=0) and (PrimIndex<CountOf(Origins)) then begin
    SourceShape:=FRoot.FindNode(TShapeNode,Origins.Strings[PrimIndex],[fnNilOnMissing]) as TShapeNode;
    if (SourceShape<>nil) and (SourceShape.Geometry is TAbstractComposedGeometryNode) then begin
      SourceGeo:=TAbstractComposedGeometryNode(SourceShape.Geometry);
      if (SourceGeo.Coord is TCoordinateNode) and
        (TCoordinateNode(SourceGeo.Coord).FdPoint.Count=Coord.FdPoint.Count) then begin
        HasDonor:=True;
        for J:=0 to SourceGeo.FdAttrib.Count-1 do
          if SourceGeo.FdAttrib[J] is TFloatVertexAttributeNode then Geo.FdAttrib.Add(SourceGeo.FdAttrib[J]);
      end;
    end;
  end;
  if not HasDonor then begin
    { Missing vec4 attributes have GL's default w=1. A generated panel has
      no body CoR or atlas span; make this explicit instead of deforming it
      around the origin or reading an unrelated corrective entry. }
    ZeroAttribute('riderCentre',4);ZeroAttribute('riderTissue',4);
    ZeroAttribute('riderContactRest',4);ZeroAttribute('riderGradient0',4);
    ZeroAttribute('riderGradient1',4);ZeroAttribute('riderGradient2',4);
    ZeroAttribute('riderPsdSpan',3);ZeroAttribute('riderSurfaceDelta',3);
  end;
  { Sewn hardware shares the same displacement as its cloth panel. Other
    accessories keep their skin weights without a garment cage. }
  if not IsFabric and not Outer then Exit;
  if Outer or Denim then begin
    Scale:=WardrobeBindScale(FDoc);
    for J:=0 to Geo.FdAttrib.Count-1 do
      if(Geo.FdAttrib[J]is TFloatVertexAttributeNode)and
        (TFloatVertexAttributeNode(Geo.FdAttrib[J]).NameField='riderTissue')then begin
        Attr:=TFloatVertexAttributeNode(Geo.FdAttrib[J]);
        Contact:=TFloatVertexAttributeNode.Create;Contact.NameField:='riderTissue';Contact.NumComponents:=4;
        for I:=0 to Coord.FdPoint.Count-1 do begin
          { Tailored clothing has its own envelope and connected cage;
            muscle bulges and jersey PSDs do not belong on it. }
          Marker:=4;if(PrimIndex>=0)and(Item.Get('tailPrimitive',-1)=PrimIndex)then Marker:=3;
          for K:=0 to 3 do begin
            Value:=Attr.FdValue.Items[I*4+K];
            if Marker>0 then begin
              if K=1 then Value:=0 else if K=2 then Value:=Marker
              else if K=3 then begin Mask:=Round(Value)or 3;Value:=Mask end;
            end;
            Contact.FdValue.Items.Add(Value);
          end;
        end;
        Geo.FdAttrib.Add(Contact);Geo.FdAttrib.Remove(Attr);Break;
      end;
  end;
  if Denim and IsFabric then begin
    ApplyAvatarDenim(Sh,FRig,WardrobeBindScale(FDoc),not(FSimulate and Item.Get('simulation',False)));
    if FSimulate and Item.Get('simulation',False)then AttachPhysics(Sh,Item,PrimIndex)
    else Inc(FDenimSurfaces);
    { Preserve the editor's optional full cloth solver. The runtime uses
      cached pose folds instead of wind billowing for this heavy fabric. }
    Exit;
  end;
  if FSimulate and Item.Get('simulation',False)and(Item.Get('slot','')<>'outer')then begin AttachPhysics(Sh,Item,PrimIndex);Exit end;
  YMin:=Coord.FdPoint.Items[0].Y;YMax:=YMin;
  for I:=0 to Coord.FdPoint.Count-1 do begin
    YMin:=Min(YMin,Coord.FdPoint.Items[I].Y);YMax:=Max(YMax,Coord.FdPoint.Items[I].Y);
  end;
  YMin:=Item.Get('pinBottom',Double(YMin));YMax:=Item.Get('pinTop',Double(YMax));
  Attr:=TFloatVertexAttributeNode.Create;Attr.NameField:='avatarClothFree';Attr.NumComponents:=1;
  for I:=0 to Coord.FdPoint.Count-1 do begin
    P:=Coord.FdPoint.Items[I];Freedom:=EnsureRange((YMax-P.Y)/Max(YMax-YMin,0.001),0.0,1.0);
    Freedom:=EnsureRange((Freedom-0.08)/0.72,0.0,1.0);Freedom:=Freedom*Freedom*(3-2*Freedom);Attr.FdValue.Items.Add(Freedom);
  end;
  Geo.FdAttrib.Add(Attr);
  for I:=0 to App.FdEffects.Count-1 do if App.FdEffects[I].X3DName='AvatarFreeCloth' then Exit;
  Eff:=TEffectNode.Create('AvatarFreeCloth');Eff.Language:=slGLSL;Eff.UniformMissing:=umIgnore;
  Eff.InternalCacheVertexAnimation:=True;
  Motion:=TSFVec2f.Create(Eff,True,'acMotion',Vector2(0,0));Eff.AddCustomField(Motion);
  SetLength(FMotions,Length(FMotions)+1);FMotions[High(FMotions)]:=Motion;
  Scale:=Max(0.1,FDoc.MeshExtentY/1.8);
  Eff.AddCustomField(TSFVec4f.Create(Eff,True,'acCloth',Vector4(Scale,
    Item.Get('flutter',0.65)*Ord(IsFabric),Item.Get('stiffness',0.4),Item.Get('wind',1.5))));
  if Item.Get('tailPrimitive',-1)>=0 then begin
    Scale:=WardrobeBindScale(FDoc);
    Pattern:=OuterwearPattern(Item.Get('preset',''));
    FHipRadii:=Vector3(0.193,0.108,0.137)*Scale;
    Eff.AddCustomField(TSFVec4f.Create(Eff,True,'uGarmentClearance',Vector4(FHipRadii.X,FHipRadii.Y,FHipRadii.Z,0)));
    Eff.AddCustomField(TSFVec4f.Create(Eff,True,'uGarmentLegRadii',FLegEnvelope));
    Eff.AddCustomField(TSFVec4f.Create(Eff,True,'uGarmentLegWidths',FLegWidthEnvelope));
    Eff.AddCustomField(TSFVec4f.Create(Eff,True,'uGarmentLegInnerWidths',FLegInnerEnvelope));
    Eff.AddCustomField(TSFFloat.Create(Eff,True,'uGarmentLegOffset',FLegCentreOffset));
    Eff.AddCustomField(TSFFloat.Create(Eff,True,'uGarmentSlack',Pattern.Slack));
    if FHem=nil then begin
      Slack:=Pattern.Slack;Density:=Pattern.Density;
      FHemProfile:=Vector4(1.10*Scale,Pattern.HemLength*Scale,Scale,Ord(Pattern.LongHem));
      FHem:=TAvatarHemDynamics.Create(Scale,FHemProfile.Y/Scale,Density,Slack,FHemProfile.W>0);
      BindGarmentCage(Item);
      FHemTexture:=TPixelTextureNode.Create;FHemTexture.KeepExistingBegin;
      Props:=TTexturePropertiesNode.Create;Props.GUITexture:=True;Props.GenerateMipMaps:=False;
      Props.FdMinificationFilter.Value:='NEAREST_PIXEL';Props.FdMagnificationFilter.Value:='NEAREST_PIXEL';
      FHemTexture.FdTextureProperties.Value:=Props;FHemTexture.RepeatS:=False;FHemTexture.RepeatT:=False;
      Pixels:=TRGBAlphaFloatImage.Create(HemRing,HemRows-1);
      FillChar(Pixels.RawPixels^,HemMovingPoints*SizeOf(TVector4),0);FHemTexture.FdImage.Value:=Pixels;
      FRig.ClothingRadiusX:=0.218+Slack;FRig.ClothingRadiusZ:=0.148+Slack;
    end;
    Eff.AddCustomField(TSFVec4f.Create(Eff,True,'uGarmentHem',FHemProfile));
    TextureField:=TSFNode.Create(Eff,True,'uGarmentMotion',[TPixelTextureNode]);
    TextureField.Value:=FHemTexture;Eff.AddCustomField(TextureField);
  end else Eff.AddCustomField(TSFVec4f.Create(Eff,True,'uGarmentHem',Vector4(0,0,0,0)));
  VS:=TEffectPartNode.Create;VS.ShaderType:=stVertex;VS.Contents:=ClothVS;
  if Item.Get('tailPrimitive',-1)>=0 then VS.Contents:=HemShader+ClothVS;
  Eff.SetParts([VS]);ShareRiderEffect(Eff);App.FdEffects.Add(Eff);Eff.Scene:=FRoot.Scene;
end;

procedure TAvatarClothMotion.Update(Dt,Speed: Single;const Offset:TVector3;Reset:Boolean);
var I,N,K: Integer; Step,Acceleration: Single;
  Local,World,Inverse,ToParent:TMatrix4;Forward,Wind,Gravity:TVector3;
  Offsets:THemOffsets;
  GpuOffsets:array[0..HemMovingPoints-1]of TVector4;
begin
  for I:=0 to High(FSolvers) do FSolvers[I].Update(Dt,Speed,TripoRig.V3(Offset.X,Offset.Y,Offset.Z),Reset);
  if Length(FSolvers)>0 then UploadPhysics;
  if FHem<>nil then begin
    if Reset then FHem.Reset;
    Local:=TMatrix4.Identity;Local.Data[3,0]:=Offset.X;Local.Data[3,1]:=Offset.Y;Local.Data[3,2]:=Offset.Z;
    World:=Local;
    if FHasFrame then begin Local:=FLocalFrame;World:=FWorldFrame end;
    UpdateGarmentPose;
    ToParent:=TMatrix4.Identity;if World.TryInverse(Inverse)then ToParent:=Local*Inverse;
    Forward:=World.MultDirection(Vector3(0,0,1));
    if Forward.LengthSqr>1e-8 then Forward:=Forward.Normalize;
    Wind:=ToParent.MultDirection(FWind-Forward*Max(0,Speed));
    Gravity:=ToParent.MultDirection(Vector3(0,-9.81,0));
    if Local.TryInverse(Inverse)then for I:=0 to 3 do begin
      K:=0;if I>=2 then K:=2;
      if FLegValid[I]then FHem.SetLegSection(I,Inverse.MultPoint(FLegA[I]),Inverse.MultPoint(FLegB[I]),
        FLegWidthEnvelope.Data[K]*FBuild,FLegEnvelope.Data[K]*FBuild,
        FLegWidthEnvelope.Data[K+1]*FBuild,FLegEnvelope.Data[K+1]*FBuild,FLegCentreOffset*FBuild,
        FLegInnerEnvelope.Data[K]*FBuild,FLegInnerEnvelope.Data[K+1]*FBuild)
      else FHem.SetLeg(I,TVector3.Zero,TVector3.Zero,0);
    end;
    FHem.Advance(Dt,Local,Gravity,Wind,ToParent.MultDirection(Forward),Speed);
    FHem.Offsets(Offsets);
    for I:=0 to HemMovingPoints-1 do GpuOffsets[I]:=Vector4(Offsets[I].X,Offsets[I].Y,Offsets[I].Z,0);
    { Update one tiny float texture in place, shared by all panels and
      render passes. Keep the CPU image current for first upload/context
      recreation; no scene/geometry invalidation or texture reallocation. }
    Move(GpuOffsets,FHemTexture.FdImage.Value.RawPixels^,SizeOf(GpuOffsets));
    if FHemTexture.InternalRendererResource<>nil then
      FHemTexture.InternalRendererResource.UpdateTextureContentsRgbaFloat(HemRing,HemRows-1,@GpuOffsets[0]);
  end;
  Dt:=EnsureRange(Dt,0.0,0.1);if Dt<=0 then Exit;
  FTime:=FTime+Dt;Acceleration:=EnsureRange((Speed-FLastSpeed)/Dt,-8.0,8.0);FLastSpeed:=Speed;
  N:=Max(1,Ceil(Dt/0.01));Step:=Dt/N;
  for I:=1 to N do begin
    FVelocity:=FVelocity+(Speed*1.8+Acceleration*0.3-18*FDrive-7*FVelocity)*Step;
    FDrive:=EnsureRange(FDrive+FVelocity*Step,-2.0,2.0);
  end;
  for I:=0 to High(FMotions) do FMotions[I].Send(Vector2(FTime,FDrive));
end;

function TAvatarClothMotion.SurfaceCount: Integer;
begin Result:=Length(FMotions)+Length(FBindings)+FDenimSurfaces end;

procedure TAvatarClothMotion.State(O:TJSONObject);
var A:TJSONArray;I,EdgeA,EdgeB:Integer;Error:Single;S:TJSONObject;
begin
  O.Add('fabric_surfaces',FFabricSurfaces);
  O.Add('fabric_material','procedural_weave_relief');
  if FDenimSurfaces>0 then O.Add('denim_deformation','gpu_pose_folds');
  if FHem<>nil then begin
    FHem.StretchPeak(EdgeA,EdgeB,Error);
    O.Add('hem_dynamics',TJSONObject.Create([
    'particles',HemPoints,'free_particles',HemMovingPoints,'time',FHem.SimulatedTime,
    'max_displacement_m',FHem.MaxDisplacement,'max_velocity_mps',FHem.MaxSpeed,
    'max_stretch_m',Abs(Error),'torso_displacement_m',FHem.TorsoDisplacement,
    'strain_edge_a',EdgeA,'strain_edge_b',EdgeB,'strain_error_m',Error,
    'strain_travel_a_m',FHem.PointDisplacement(EdgeA),'strain_travel_b_m',FHem.PointDisplacement(EdgeB),
    'support','armhole_seam','solver','xpbd_drape','mesh_deformation','gpu']));
  end;
  if FHem<>nil then O.Add('lower_layer_contact_radii',TJSONArray.Create([
    FLegEnvelope.X,FLegEnvelope.Y,FLegEnvelope.Z,FLegEnvelope.W]));
  if FHem<>nil then O.Add('lower_layer_contact_widths',TJSONArray.Create([
    FLegWidthEnvelope.X,FLegWidthEnvelope.Y,FLegWidthEnvelope.Z,FLegWidthEnvelope.W]));
  if FHem<>nil then O.Add('lower_layer_contact_inner_widths',TJSONArray.Create([
    FLegInnerEnvelope.X,FLegInnerEnvelope.Y,FLegInnerEnvelope.Z,FLegInnerEnvelope.W]));
  A:=TJSONArray.Create;O.Add('cloth_physics',A);
  for I:=0 to High(FSolvers) do begin S:=TJSONObject.Create;FSolvers[I].State(S);A.Add(S) end;
end;
end.
