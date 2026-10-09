unit AvatarWardrobeGeometry;
{$mode objfpc}{$H+}
interface
uses SysUtils, Classes, Math, fpjson, AvatarGlbIO;
type TGarmentFrame=record
  Scale:Single;
  Shoulder,Elbow,Wrist:array[0..1]of TVec3;
  Hip,Knee,Ankle:array[0..1]of TVec3;
end;
procedure InitGarmentFrame(Doc:TGlbDoc;out Frame:TGarmentFrame);
procedure TailorOuterPoint(const Frame:TGarmentFrame;const Preset:string;var P:TVec3;const N:TVec3);
procedure BuildWardrobeAccessory(Doc: TGlbDoc; const Preset,Color: string;
  out Mesh: TJSONObject; out Materials: TJSONArray);
procedure AddOuterwearDetails(Doc:TGlbDoc;const Preset:string;Mesh:TJSONObject;Materials:TJSONArray);
function WardrobeBindScale(Doc:TGlbDoc):Single;
function GarmentClearanceDirection(const P,N:TVec3;Scale:Single):TVec3;
procedure BuildJeansMesh(Doc:TGlbDoc;Mesh:TJSONObject;Material:Integer);
procedure AddJeansDetails(Doc:TGlbDoc;Mesh:TJSONObject;Materials:TJSONArray);
procedure AddOuterwearPanels(Doc:TGlbDoc;const Preset:string;Mesh:TJSONObject;Material:Integer);
procedure TailorOuterWeights(Doc:TGlbDoc;Mesh:TJSONObject);
procedure TrimOuterwearJoin(Doc:TGlbDoc;const Preset:string;Mesh:TJSONObject);
function OuterwearHemLength(const Preset:string):Single;
implementation
uses GltfCore, AvatarWardrobe, AvatarGarmentPattern;
type
  TFloats=TWardrobeFloats;
  TSurfacePrimitive=record
    P,J,W,Indices:TFloats;
  end;
  TMeshBuilder=class
    Doc:TGlbDoc;
    Mesh:TJSONObject;
    Points,Normals,UV,Joints,Weights:TFloats;
    Indices:array of Word;
    Joint,SecondJoint:Integer;
    Mix:Single;
    Surface:array of TSurfacePrimitive;
    function Vertex(X,Y,Z,U,V:Single):Integer;
    procedure CaptureSurface;
    function SurfaceVertex(X,Y,Lift,U,V:Single;Back:Boolean=False):Integer;
    procedure Triangle(A,B,C:Integer);
    procedure Quad(A,B,C,D:Integer);
    procedure Lathe(CX,CZ:Single; const Ys,RX,RZ:array of Single; Segments:Integer=64);
    procedure Box(X,Y,Z,DX,DY,DZ:Single);
    procedure Finish(Material:Integer);
  end;
function EnsureArray(O:TJSONObject;const Key:string):TJSONArray;
begin
  Result:=ArrOf(O,Key);
  if Result=nil then begin Result:=TJSONArray.Create;O.Add(Key,Result) end;
end;
function Acc(Doc:TGlbDoc;const Data:TFloats;C:Integer;const Kind:string;Ints:Boolean=False):Integer;
var Bytes:TBytes;I,K,Offset,View:Integer;W:Word;A:TJSONObject;Lo,Hi:TJSONArray;MinV,MaxV:Single;
begin
  if Ints then begin
    SetLength(Bytes,Length(Data)*2);
    for I:=0 to High(Data) do begin W:=Round(Data[I]);Move(W,Bytes[I*2],2) end;
  end else begin SetLength(Bytes,Length(Data)*4);Move(Data[0],Bytes[0],Length(Bytes)) end;
  Offset:=Doc.AppendBytes(Bytes[0],Length(Bytes));View:=EnsureArray(Doc.Root,'bufferViews').Count;
  EnsureArray(Doc.Root,'bufferViews').Add(TJSONObject.Create(['buffer',0,'byteOffset',Offset,'byteLength',Length(Bytes)]));
  A:=TJSONObject.Create(['bufferView',View,'count',Length(Data) div C,'type',Kind]);
  if Ints then A.Add('componentType',5123) else A.Add('componentType',5126);
  if Kind='VEC3' then begin
    Lo:=TJSONArray.Create;Hi:=TJSONArray.Create;
    for K:=0 to 2 do begin
      MinV:=Data[K];MaxV:=MinV;
      for I:=0 to Length(Data) div 3-1 do begin MinV:=Min(MinV,Data[I*3+K]);MaxV:=Max(MaxV,Data[I*3+K]) end;
      Lo.Add(MinV);Hi.Add(MaxV);
    end;
    A.Add('min',Lo);A.Add('max',Hi);
  end;
  Result:=EnsureArray(Doc.Root,'accessors').Count;EnsureArray(Doc.Root,'accessors').Add(A);
end;
function Material(Doc:TGlbDoc;const Hex:string;Roughness:Single):Integer;
var M:TJSONObject;V:LongInt;C:array[0..2] of Single;I:Integer;
begin
  V:=StrToInt('$'+Copy(Hex,2,6));
  for I:=0 to 2 do begin
    C[I]:=((V shr ((2-I)*8)) and 255)/255;
    if C[I]<=0.04045 then C[I]:=C[I]/12.92 else C[I]:=Power((C[I]+0.055)/1.055,2.4);
  end;
  M:=TJSONObject.Create(['name','AvatarAccessory','doubleSided',True]);
  M.Add('pbrMetallicRoughness',TJSONObject.Create(['baseColorFactor',TJSONArray.Create([C[0],C[1],C[2],1]),
    'metallicFactor',0,'roughnessFactor',Roughness]));
  Result:=EnsureArray(Doc.Root,'materials').Count;EnsureArray(Doc.Root,'materials').Add(M);
end;
function Palette(Doc:TGlbDoc;const Name:string):Integer;
var A:TJSONArray;I:Integer;
begin
  A:=ArrOf(ObjAt(ArrOf(Doc.Root,'skins'),Doc.MainSkinIndex),'joints');
  for I:=0 to CountOf(A)-1 do if SameText(Doc.NodeName(A.Integers[I]),Name) then Exit(I);
  raise EReadError.Create('Accessory requires joint '+Name);
end;
function BindPoint(Doc:TGlbDoc;Joint:Integer):TVec3;
var A,V:TJSONObject;Offset,I:Integer;F:Single;IBM,World:TMat4;
begin
  A:=ObjAt(ArrOf(Doc.Root,'accessors'),IntOf(ObjAt(ArrOf(Doc.Root,'skins'),Doc.MainSkinIndex),'inverseBindMatrices',-1));
  V:=ObjAt(ArrOf(Doc.Root,'bufferViews'),IntOf(A,'bufferView',-1));
  if (A=nil) or (V=nil) or (IntOf(A,'componentType',0)<>5126) then raise EReadError.Create('Accessory needs inverse bind matrices');
  Offset:=IntOf(V,'byteOffset',0)+IntOf(A,'byteOffset',0)+Joint*IntOf(V,'byteStride',64);
  if (Offset<0) or (Offset+64>Length(Doc.Bin)) then raise EReadError.Create('Invalid inverse bind matrix');
  for I:=0 to 15 do begin Move(Doc.Bin[Offset+I*4],F,4);IBM[I]:=F end;
  if not M4InvertAffine(IBM,World) then raise EReadError.Create('Singular inverse bind matrix');
  Result:=V3(World[12],World[13],World[14]);
end;
function TMeshBuilder.Vertex(X,Y,Z,U,V:Single):Integer;
begin
  Result:=Length(Points) div 3;
  SetLength(Points,(Result+1)*3);SetLength(Normals,Length(Points));
  SetLength(UV,(Result+1)*2);SetLength(Joints,(Result+1)*4);SetLength(Weights,Length(Joints));
  Points[Result*3]:=X;Points[Result*3+1]:=Y;Points[Result*3+2]:=Z;
  UV[Result*2]:=U;UV[Result*2+1]:=V;
  Joints[Result*4]:=Joint;Joints[Result*4+1]:=SecondJoint;
  Weights[Result*4]:=1-Mix;Weights[Result*4+1]:=Mix;
end;

procedure TMeshBuilder.CaptureSurface;
var A:TJSONArray;P,Attrs:TJSONObject;I,C:Integer;
begin
  A:=ArrOf(Mesh,'primitives');SetLength(Surface,CountOf(A));
  for I:=0 to High(Surface)do begin
    P:=ObjAt(A,I);Attrs:=ObjOf(P,'attributes');
    Surface[I].P:=WardrobeReadAcc(Doc,IntOf(Attrs,'POSITION',-1),C);
    Surface[I].J:=WardrobeReadAcc(Doc,IntOf(Attrs,'JOINTS_0',-1),C);
    Surface[I].W:=WardrobeReadAcc(Doc,IntOf(Attrs,'WEIGHTS_0',-1),C);
    Surface[I].Indices:=WardrobeReadAcc(Doc,IntOf(P,'indices',-1),C);
  end;
end;

function TMeshBuilder.SurfaceVertex(X,Y,Lift,U,V:Single;Back:Boolean):Integer;
var I,K,L,Q,BestPrim,BestTri,PaletteCount,J:Integer;
  A,B,C:TVec3;Det,T0,T1,T2,Z,BestZ,Sum,BestWeight,Dist,BestDist:Single;
  Bary:array[0..2]of Single;WeightsByJoint:array of Single;Idx:array[0..2]of Integer;
begin
  { Project sewing details onto the actual tailored surface. Interpolating
    its skin weights is essential: rigid waist/chest boxes would float off
    the garment when the wearer bends. }
  BestZ:=-1e10;if Back then BestZ:=1e10;
  BestPrim:=-1;BestTri:=-1;BestDist:=1e10;
  for I:=0 to High(Surface)do begin
    K:=0;while K+2<Length(Surface[I].Indices)do begin
      for L:=0 to 2 do Idx[L]:=Round(Surface[I].Indices[K+L])*3;
      A:=V3(Surface[I].P[Idx[0]],Surface[I].P[Idx[0]+1],Surface[I].P[Idx[0]+2]);
      B:=V3(Surface[I].P[Idx[1]],Surface[I].P[Idx[1]+1],Surface[I].P[Idx[1]+2]);
      C:=V3(Surface[I].P[Idx[2]],Surface[I].P[Idx[2]+1],Surface[I].P[Idx[2]+2]);
      Det:=(B.Y-C.Y)*(A.X-C.X)+(C.X-B.X)*(A.Y-C.Y);
      if Abs(Det)>1e-10 then begin
        T0:=((B.Y-C.Y)*(X-C.X)+(C.X-B.X)*(Y-C.Y))/Det;
        T1:=((C.Y-A.Y)*(X-C.X)+(A.X-C.X)*(Y-C.Y))/Det;T2:=1-T0-T1;
        if(Min(T0,Min(T1,T2))>=-0.25)then begin
          T0:=Max(0,T0);T1:=Max(0,T1);T2:=Max(0,T2);Sum:=T0+T1+T2;
          T0:=T0/Sum;T1:=T1/Sum;T2:=T2/Sum;
          Dist:=Sqr(A.X*T0+B.X*T1+C.X*T2-X)+Sqr(A.Y*T0+B.Y*T1+C.Y*T2-Y);
          Z:=A.Z*T0+B.Z*T1+C.Z*T2;
          if(Dist<0.000225)and((Dist<BestDist-1e-8)or((Abs(Dist-BestDist)<1e-8)and
            (((not Back)and(Z>BestZ))or(Back and(Z<BestZ)))))then begin
            BestDist:=Dist;BestZ:=Z;BestPrim:=I;BestTri:=K;Bary[0]:=T0;Bary[1]:=T1;Bary[2]:=T2;
          end;
        end;
      end;
      Inc(K,3);
    end;
  end;
  if BestPrim<0 then raise EReadError.CreateFmt('No garment surface at %0.4f %0.4f',[X,Y]);
  if Back then Lift:=-Lift;
  Result:=Vertex(X,Y,BestZ+Lift,U,V);
  PaletteCount:=CountOf(ArrOf(ObjAt(ArrOf(Doc.Root,'skins'),Doc.MainSkinIndex),'joints'));
  SetLength(WeightsByJoint,PaletteCount);
  for L:=0 to 2 do begin
    Q:=Round(Surface[BestPrim].Indices[BestTri+L])*4;
    for K:=0 to 3 do begin
      J:=Round(Surface[BestPrim].J[Q+K]);
      WeightsByJoint[J]:=WeightsByJoint[J]+Max(0,Bary[L])*Surface[BestPrim].W[Q+K];
    end;
  end;
  Sum:=0;
  for K:=0 to 3 do begin
    J:=0;BestWeight:=0;
    for I:=0 to High(WeightsByJoint)do if WeightsByJoint[I]>BestWeight then begin J:=I;BestWeight:=WeightsByJoint[I]end;
    Joints[Result*4+K]:=J;Weights[Result*4+K]:=BestWeight;WeightsByJoint[J]:=0;Sum:=Sum+BestWeight;
  end;
  for K:=0 to 3 do Weights[Result*4+K]:=Weights[Result*4+K]/Max(1e-8,Sum);
end;

function WardrobeBindScale(Doc:TGlbDoc):Single;
begin Result:=BindPoint(Doc,Palette(Doc,'Head')).Y/1.58 end;

function Smooth(A,B,X:Single):Single;
begin Result:=EnsureRange((X-A)/(B-A),0.0,1.0);Result:=Result*Result*(3-2*Result) end;

procedure InitGarmentFrame(Doc:TGlbDoc;out Frame:TGarmentFrame);
var I:Integer;Side:string;
begin
  Frame.Scale:=WardrobeBindScale(Doc);
  for I:=0 to 1 do begin
    if I=0 then Side:='R_'else Side:='L_';
    Frame.Shoulder[I]:=BindPoint(Doc,Palette(Doc,Side+'Upperarm'));
    Frame.Elbow[I]:=BindPoint(Doc,Palette(Doc,Side+'Forearm'));
    Frame.Wrist[I]:=BindPoint(Doc,Palette(Doc,Side+'Hand'));
    Frame.Hip[I]:=BindPoint(Doc,Palette(Doc,Side+'Thigh'));
    Frame.Knee[I]:=BindPoint(Doc,Palette(Doc,Side+'Calf'));
    Frame.Ankle[I]:=BindPoint(Doc,Palette(Doc,Side+'Foot'));
  end;
end;

procedure TailorOuterPoint(const Frame:TGarmentFrame;const Preset:string;var P:TVec3;const N:TVec3);
var S,X,Y,T,Q,RX,RZ,CZ,Slack,L,Blend,Radius,Best,Clearance:Single;I,Side:Integer;
  Original,Direction,Axis,D,C,Candidate,ArmPoint:TVec3;Pattern:TOuterwearPattern;
begin
  S:=Frame.Scale;Original:=P;X:=Abs(P.X)/S;Y:=P.Y/S;
  Pattern:=OuterwearPattern(Preset);Slack:=Pattern.Slack;
  Direction:=GarmentClearanceDirection(P,N,S);
  { The garment rests on the shoulder. Full torso ease here raised the
    shoulder cap and chest by 19--27 mm before the envelope expansion. }
  Clearance:=0.006+0.4*(Slack-0.019);
  P:=V3Add(P,V3Scale(Direction,Clearance*S));
  { A cloth envelope spans muscles and small donor folds. It is not an
    extrusion of skin normals; those produced sharp bulges at the elbow. }
  Blend:=Smooth(0.205,0.29,X);
  if Blend>0 then begin
    Side:=0;if Original.X>0 then Side:=1;Best:=1e10;ArmPoint:=P;
    for I:=0 to 1 do begin
      if I=0 then begin C:=Frame.Shoulder[Side];Axis:=V3Sub(Frame.Elbow[Side],C) end
      else begin C:=Frame.Elbow[Side];Axis:=V3Sub(Frame.Wrist[Side],C) end;
      D:=V3Sub(Original,C);
      T:=EnsureRange((D.X*Axis.X+D.Y*Axis.Y+D.Z*Axis.Z)/Sqr(Max(V3Len(Axis),1e-5)),0.0,1.0);
      C:=V3Add(C,V3Scale(Axis,T));D:=V3Sub(Original,C);L:=V3Len(D);
      if L>=Best then Continue;Best:=L;
      if I=0 then Radius:=(0.066-0.013*T)*S else Radius:=(0.053-0.018*T)*S;
      Radius:=Max(Radius,L+S*(0.006+0.006*(1-T)));
      if L>1e-6 then ArmPoint:=V3Add(C,V3Scale(D,Radius/L));
    end;
    P:=V3Add(V3Scale(P,1-Blend),V3Scale(ArmPoint,Blend));
  end;
  { A regular-fit shell bridges the waist instead of tracing the jersey's
    muscles. Leave underarm ease, and meet the independent hem at 1.10. }
  if X<0.24 then P.Y:=P.Y+S*0.087*(1-Smooth(1.00,1.24,Y));
  Blend:=(1-Smooth(1.35,1.45,Y))*(1-Smooth(0.18,0.245,X));
  if Blend>0 then begin
    OuterwearSection(Slack,P.Y/S,RX,RZ,CZ);
    D:=V3(Original.X,0,Original.Z-CZ*S);
    Q:=Sqrt(Sqr(D.X/(RX*S))+Sqr(D.Z/(RZ*S)));
    if Q>1e-6 then begin
      Candidate:=V3(D.X/Q,P.Y,D.Z/Q+CZ*S);
      P.X:=P.X+(Candidate.X-P.X)*Blend;P.Z:=P.Z+(Candidate.Z-P.Z)*Blend;
    end;
  end;
end;

procedure TailorOuterWeights(Doc:TGlbDoc;Mesh:TJSONObject);
var Prims:TJSONArray;Attr:TJSONObject;P,J,W,BlendWeights:TFloats;
  I,V,K,C,Count,Hip,Waist,Best,N:Integer;S,T,WaistMix,Sum:Single;
begin
  S:=WardrobeBindScale(Doc);Hip:=Palette(Doc,'Pelvis');Waist:=Palette(Doc,'Waist');
  Count:=CountOf(ArrOf(ObjAt(ArrOf(Doc.Root,'skins'),Doc.MainSkinIndex),'joints'));
  SetLength(BlendWeights,Count);Prims:=ArrOf(Mesh,'primitives');
  for I:=0 to CountOf(Prims)-1 do begin
    Attr:=ObjOf(ObjAt(Prims,I),'attributes');
    P:=WardrobeReadAcc(Doc,IntOf(Attr,'POSITION',-1),C);
    J:=WardrobeReadAcc(Doc,IntOf(Attr,'JOINTS_0',-1),C);
    W:=WardrobeReadAcc(Doc,IntOf(Attr,'WEIGHTS_0',-1),C);
    for V:=0 to Length(P)div 3-1 do begin
      T:=(1-Smooth(1.13,1.25,P[V*3+1]/S))*(1-Smooth(0.21,0.27,Abs(P[V*3])/S));
      if T<=0 then Continue;
      FillChar(BlendWeights[0],Count*SizeOf(Single),0);
      for K:=0 to 3 do begin N:=Round(J[V*4+K]);BlendWeights[N]:=BlendWeights[N]+W[V*4+K]*(1-T)end;
      WaistMix:=0.42*(1-Smooth(0,0.09,1.10-P[V*3+1]/S));
      BlendWeights[Hip]:=BlendWeights[Hip]+T*(1-WaistMix);
      BlendWeights[Waist]:=BlendWeights[Waist]+T*WaistMix;Sum:=0;
      for K:=0 to 3 do begin
        Best:=0;for N:=1 to Count-1 do if BlendWeights[N]>BlendWeights[Best]then Best:=N;
        J[V*4+K]:=Best;W[V*4+K]:=BlendWeights[Best];Sum:=Sum+W[V*4+K];BlendWeights[Best]:=0;
      end;
      for K:=0 to 3 do W[V*4+K]:=W[V*4+K]/Max(Sum,1e-6);
    end;
    Attr.Delete('JOINTS_0');Attr.Add('JOINTS_0',Acc(Doc,J,4,'VEC4',True));
    Attr.Delete('WEIGHTS_0');Attr.Add('WEIGHTS_0',Acc(Doc,W,4,'VEC4'));
  end;
end;

procedure TrimOuterwearJoin(Doc:TGlbDoc;const Preset:string;Mesh:TJSONObject);
var Prims:TJSONArray;Prim,Attrs,Trimmed:TJSONObject;B:TMeshBuilder;
  P,UV,Joints,Weights,Indices:TFloats;Map:array of Integer;Edges:TStringList;
  I,J,K,C,A,Z,Count,PolyCount,SewnCount:Integer;
  Poly:array[0..3]of Integer;Sewn:array[0..4]of Integer;
  S,Cut,RX,RZ,CZ:Single;Pattern:TOuterwearPattern;

  function SourceVertex(V:Integer):Integer;
  var K:Integer;
  begin
    if Map[V]>=0 then Exit(Map[V]);
    Result:=B.Vertex(P[V*3],P[V*3+1],P[V*3+2],UV[V*2],UV[V*2+1]);Map[V]:=Result;
    for K:=0 to 3 do begin
      B.Joints[Result*4+K]:=Joints[V*4+K];B.Weights[Result*4+K]:=Weights[V*4+K];
    end;
  end;

  function Intersection(A,Z:Integer):Integer;
  var Key:string;Index:Integer;T,X,Y,Angle:Single;
  begin
    if Abs(P[A*3+1]-Cut)<1e-7 then Exit(SourceVertex(A));
    if Abs(P[Z*3+1]-Cut)<1e-7 then Exit(SourceVertex(Z));
    Key:=IntToStr(Min(A,Z))+':'+IntToStr(Max(A,Z));Index:=Edges.IndexOf(Key);
    if Index>=0 then Exit(PtrInt(Edges.Objects[Index]));
    T:=(Cut-P[A*3+1])/(P[Z*3+1]-P[A*3+1]);
    X:=P[A*3]*(1-T)+P[Z*3]*T;Y:=P[A*3+2]*(1-T)+P[Z*3+2]*T;
    Angle:=ArcTan2(X/RX,(Y-CZ)/RZ);
    Result:=B.Vertex(RX*Sin(Angle),Cut,CZ+RZ*Cos(Angle),
      UV[A*2]*(1-T)+UV[Z*2]*T,UV[A*2+1]*(1-T)+UV[Z*2+1]*T);
    Edges.AddObject(Key,TObject(PtrInt(Result)));
  end;

  function CentreSeam(A,Z:Integer):Integer;
  var T,Depth:Single;
  begin
    T:=-B.Points[A*3]/(B.Points[Z*3]-B.Points[A*3]);
    Depth:=B.Points[A*3+2]*(1-T)+B.Points[Z*3+2]*T;
    if Depth>=CZ then Depth:=CZ+RZ else Depth:=CZ-RZ;
    Result:=B.Vertex(0,Cut,Depth,B.UV[A*2]*(1-T)+B.UV[Z*2]*T,
      B.UV[A*2+1]*(1-T)+B.UV[Z*2+1]*T);
  end;

begin
  { Remove the overlapping donor bottom and expose one actual sewing
    boundary. Its vertices are also used by the first ring of the skirt. }
  S:=WardrobeBindScale(Doc);Cut:=1.10*S;Pattern:=OuterwearPattern(Preset);
  OuterwearSection(Pattern.Slack,1.10,RX,RZ,CZ);RX:=RX*S;RZ:=RZ*S;CZ:=CZ*S;
  Trimmed:=TJSONObject.Create;B:=TMeshBuilder.Create;Edges:=TStringList.Create;
  try
    B.Doc:=Doc;B.Mesh:=Trimmed;B.Joint:=Palette(Doc,'Pelvis');B.SecondJoint:=Palette(Doc,'Waist');B.Mix:=0.42;
    Edges.Sorted:=True;Prims:=ArrOf(Mesh,'primitives');
    for I:=0 to CountOf(Prims)-1 do begin
      Prim:=ObjAt(Prims,I);Attrs:=ObjOf(Prim,'attributes');
      P:=WardrobeReadAcc(Doc,IntOf(Attrs,'POSITION',-1),C);
      UV:=WardrobeReadAcc(Doc,IntOf(Attrs,'TEXCOORD_0',-1),C);
      Joints:=WardrobeReadAcc(Doc,IntOf(Attrs,'JOINTS_0',-1),C);
      Weights:=WardrobeReadAcc(Doc,IntOf(Attrs,'WEIGHTS_0',-1),C);
      Indices:=WardrobeReadAcc(Doc,IntOf(Prim,'indices',-1),C);
      Count:=Length(P)div 3;SetLength(Map,Count);for J:=0 to Count-1 do Map[J]:=-1;
      if Length(UV)<>Count*2 then SetLength(UV,Count*2);
      Edges.Clear;
      for J:=0 to Length(Indices)div 3-1 do begin
        PolyCount:=0;
        for K:=0 to 2 do begin
          A:=Round(Indices[J*3+K]);Z:=Round(Indices[J*3+(K+1)mod 3]);
          if P[A*3+1]>=Cut then begin Poly[PolyCount]:=SourceVertex(A);Inc(PolyCount)end;
          if (P[A*3+1]<Cut)<>(P[Z*3+1]<Cut)then begin
            Poly[PolyCount]:=Intersection(A,Z);Inc(PolyCount);
          end;
        end;
        { The two lower panels meet on the front/back centreline. Split a
          crossing cut edge there too; otherwise it would be a T-junction. }
        SewnCount:=0;
        for K:=0 to PolyCount-1 do begin
          A:=Poly[K];Z:=Poly[(K+1)mod PolyCount];
          Sewn[SewnCount]:=A;Inc(SewnCount);
          if(Abs(B.Points[A*3+1]-Cut)<1e-7)and(Abs(B.Points[Z*3+1]-Cut)<1e-7)and
            (B.Points[A*3]*B.Points[Z*3]<0)then begin
            Sewn[SewnCount]:=CentreSeam(A,Z);Inc(SewnCount);
          end;
        end;
        A:=0;
        for K:=0 to SewnCount-1 do if B.Points[Sewn[K]*3+1]>Cut+1e-7 then begin A:=K;Break end;
        for K:=1 to SewnCount-2 do begin
          Z:=Sewn[(A+K)mod SewnCount];C:=Sewn[(A+K+1)mod SewnCount];
          if(Sewn[A]<>Z)and(Z<>C)and(Sewn[A]<>C)then B.Triangle(Sewn[A],Z,C);
        end;
      end;
      B.Finish(IntOf(Prim,'material',0));
      { A primitive completely below the cut may have no triangles. }
      B.Points:=nil;B.Normals:=nil;B.UV:=nil;B.Joints:=nil;B.Weights:=nil;B.Indices:=nil;
    end;
    Mesh.Delete('primitives');Mesh.Add('primitives',ArrOf(Trimmed,'primitives').Clone);
  finally Edges.Free;B.Free;Trimmed.Free end;
end;

function GarmentClearanceDirection(const P,N:TVec3;Scale:Single):TVec3;
var T,Side,L:Single;Radial:TVec3;
begin
  { The torso shell expands away from the body, not along tiny folds,
    zipper teeth or the donor's horizontal bottom cap. Inflating those
    normals turns millimetre details into centimetre spikes. Blend to the
    original surface around shoulders/arms, where a torso axis is unsuitable. }
  T:=EnsureRange((P.Y/Scale-1.28)/0.16,0.0,1.0);T:=1-T*T*(3-2*T);
  Side:=EnsureRange((Abs(P.X)/Scale-0.21)/0.11,0.0,1.0);
  T:=T*(1-Side*Side*(3-2*Side));
  Radial:=V3(P.X/Scale/Sqr(0.18),0,(P.Z/Scale+0.035)/Sqr(0.135));
  L:=Sqrt(Sqr(Radial.X)+Sqr(Radial.Z));
  if L<1e-6 then Exit(N);
  Radial:=V3Scale(Radial,1/L);
  Result:=V3Add(V3Scale(N,1-T),V3Scale(Radial,T));
  L:=Sqrt(Sqr(Result.X)+Sqr(Result.Y)+Sqr(Result.Z));
  if L>1e-6 then Result:=V3Scale(Result,1/L)else Result:=N;
end;

procedure BuildJeansMesh(Doc:TGlbDoc;Mesh:TJSONObject;Material:Integer);
const Cols=32;Rows=40;
var B:TMeshBuilder;Frame:TGarmentFrame;Side,I,J,K,N,Hip,Waist,Thigh,Calf:Integer;
  S,T,A,Y,TopY,X,Z,CX,CZ,RX,RZ,Blend,SignX,Fold,KneeMix,HipMix,WaistMix:Single;
  C:TVec3;Prefix:string;
begin
  InitGarmentFrame(Doc,Frame);S:=Frame.Scale;
  Hip:=Palette(Doc,'Pelvis');Waist:=Palette(Doc,'Waist');
  B:=TMeshBuilder.Create;B.Doc:=Doc;B.Mesh:=Mesh;
  try
    { Two leg panels meet along a continuous curved crotch seam. Their
      shared seam positions AND weights are identical. No bib pad, sock
      rim, skin caps or corrective topology remains in the garment. }
    for Side:=0 to 1 do begin
      SignX:=1;if Side=0 then SignX:=-1;
      if Side=0 then Prefix:='R_'else Prefix:='L_';
      Thigh:=Palette(Doc,Prefix+'Thigh');Calf:=Palette(Doc,Prefix+'Calf');
      N:=Length(B.Points)div 3;
      for I:=0 to Rows do for J:=0 to Cols do begin
        T:=I/Rows;A:=2*Pi*J/Cols;
        TopY:=1.004-0.200*Power(Max(0,-Sin(A)),1.6);
        { Full-length denim overlaps low shoes. The old ankle-height edge
          exposed the hidden lower body, especially when the foot flexed. }
        Y:=0.068+(TopY-0.068)*T;
        if Y*S<Frame.Knee[Side].Y then begin
          Blend:=EnsureRange((Frame.Knee[Side].Y-Y*S)/Max(0.01,Frame.Knee[Side].Y-Frame.Ankle[Side].Y),0.0,1.0);
          C:=V3Add(Frame.Knee[Side],V3Scale(V3Sub(Frame.Ankle[Side],Frame.Knee[Side]),Blend));
        end else begin
          Blend:=EnsureRange((Y*S-Frame.Knee[Side].Y)/Max(0.01,Frame.Hip[Side].Y-Frame.Knee[Side].Y),0.0,1.0);
          C:=V3Add(Frame.Knee[Side],V3Scale(V3Sub(Frame.Hip[Side],Frame.Knee[Side]),Blend));
        end;
        CX:=Abs(C.X)/S;CZ:=C.Z/S-0.017*(1-Smooth(0.43,0.58,Y));
        RX:=0.060+0.024*Smooth(0.49,0.80,Y);RZ:=0.064+0.035*Smooth(0.49,0.80,Y);
        X:=CX+RX*Sin(A);Z:=CZ+RZ*Cos(A);
        Blend:=Smooth(0.64,1.0,T);
        RX:=0.187-0.025*Smooth(0.94,1.005,Y);RZ:=0.135-0.027*Smooth(0.94,1.005,Y);
        X:=X+(RX*Max(0,Sin(A))-X)*Blend;
        Z:=Z+(-0.032+RZ*Cos(A)-Z)*Blend;
        { A little standing slack above the shoe. The fold is oblique and
          fades at its ends instead of making a regular stack of rings. }
        Fold:=0.0026*Sin((Y-0.115)*98+1.1*Sin(A)+Side*0.8)*Exp(-Sqr((Y-0.21)/0.07));
        X:=SignX*(X+Sin(A)*Fold);Z:=Z+Cos(A)*Fold;
        K:=B.Vertex(X*S,Y*S,Z*S,A*0.074,Y);
        KneeMix:=Smooth(0.455,0.585,Y);
        HipMix:=Smooth(0.805,0.995,Y);
        HipMix:=Max(HipMix,(1-Smooth(0.0,0.061,Abs(X)))*Smooth(0.75,0.803,Y));
        if I=Rows then HipMix:=1;
        WaistMix:=0.20*Smooth(0.966,1.026,Y);
        B.Joints[K*4]:=Calf;B.Joints[K*4+1]:=Thigh;B.Joints[K*4+2]:=Hip;B.Joints[K*4+3]:=Waist;
        B.Weights[K*4]:=(1-KneeMix)*(1-HipMix);
        B.Weights[K*4+1]:=KneeMix*(1-HipMix);
        B.Weights[K*4+2]:=HipMix*(1-WaistMix);B.Weights[K*4+3]:=HipMix*WaistMix;
      end;
      for I:=0 to Rows-1 do for J:=0 to Cols-1 do begin
        K:=N+I*(Cols+1)+J;
        if Side=1 then B.Quad(K,K+1,K+Cols+2,K+Cols+1)
        else B.Quad(K+Cols+1,K+Cols+2,K+1,K);
      end;
    end;
    B.Finish(Material);
  finally B.Free end;
end;

function OuterwearHemLength(const Preset:string):Single;
begin
  Result:=OuterwearPattern(Preset).HemLength;
end;

procedure AddOuterwearPanels(Doc:TGlbDoc;const Preset:string;Mesh:TJSONObject;Material:Integer);
const Columns=36;
var B:TMeshBuilder;I,J,K,Side,N,Waist,Rows,TopStart,TopCount,Column,TopColumn,C,V:Integer;
  S,T,A,RX,RZ,CZ,Y,E,Fold,LengthY,Slack,FrontVent,BackVent,NextLower:Single;
  LongHem:Boolean;Pattern:TOuterwearPattern;
  Angles,Points:TFloats;Prims:TJSONArray;
  procedure AddAngle(Value:Single);
  var I,J:Integer;
  begin
    I:=0;while(I<Length(Angles))and(Angles[I]<Value-1e-5)do Inc(I);
    if(I<Length(Angles))and(Abs(Angles[I]-Value)<1e-5)then Exit;
    SetLength(Angles,Length(Angles)+1);
    for J:=High(Angles)downto I+1 do Angles[J]:=Angles[J-1];Angles[I]:=Value;
  end;
  procedure SewTriangle(A,B0,C0:Integer);
  begin if Side=0 then B.Triangle(A,B0,C0)else B.Triangle(C0,B0,A)end;
begin
  S:=WardrobeBindScale(Doc);B:=TMeshBuilder.Create;B.Doc:=Doc;B.Mesh:=Mesh;
  try
    Pattern:=OuterwearPattern(Preset);LengthY:=Pattern.HemLength;Slack:=Pattern.Slack;
    LongHem:=Pattern.LongHem;Rows:=20;if LongHem then Rows:=30;
    B.Joint:=Palette(Doc,'Pelvis');Waist:=Palette(Doc,'Waist');
    { The hem is attached at its waist, not to individual thighs. A persistent
      cloth cage supplies drape/inertia; the render shader handles leg contact. }
    for Side:=0 to 1 do begin
      { Match all vertices of the clipped upper boundary, then stitch to
        the regular skirt grid. Only this first band needs extra vertices. }
      Angles:=nil;AddAngle(0);AddAngle(Pi);
      OuterwearSection(Slack,1.10,RX,RZ,CZ);Prims:=ArrOf(Mesh,'primitives');
      for I:=0 to CountOf(Prims)-1 do begin
        Points:=WardrobeReadAcc(Doc,IntOf(ObjOf(ObjAt(Prims,I),'attributes'),'POSITION',-1),C);
        for V:=0 to Length(Points)div 3-1 do
          if(Abs(Points[V*3+1]/S-1.10)<1e-5)and
            (((Side=0)and(Points[V*3]>=-1e-7))or((Side=1)and(Points[V*3]<=1e-7)))then
              AddAngle(Abs(ArcTan2(Points[V*3]/(RX*S),(Points[V*3+2]/S-CZ)/RZ)));
      end;
      TopStart:=Length(B.Points)div 3;TopCount:=Length(Angles);
      B.SecondJoint:=Waist;
      B.Mix:=0.42;
      for J:=0 to High(Angles)do begin
        A:=Angles[J];if Side=1 then A:=-A;
        B.Vertex(RX*S*Sin(A),1.10*S,CZ*S+RZ*S*Cos(A),Angles[J]/Pi,0);
      end;
      N:=Length(B.Points)div 3;
      for I:=1 to Rows do for J:=0 to Columns do begin
        { Spend rows around the hip/thigh contact, not on the nearly flat
          free hem. This removes large facets at a raised knee. }
        if LongHem then begin
          if I<=12 then T:=0.55*I/12 else T:=0.55+0.45*(I-12)/(Rows-12);
        end else T:=I/Rows;
        OuterwearOpening(T,LongHem,FrontVent,BackVent);
        A:=FrontVent+(Pi-FrontVent-BackVent)*J/Columns;
        if Side=1 then A:=-A;
        { Hip ease narrows towards the hem, matching the physical cage.
          Walking opens the panels through contact, not a permanent flare. }
        Y:=1.10-LengthY*T;
        OuterwearSection(Slack,Y,RX,RZ,CZ);RX:=RX*S;RZ:=RZ*S;
        E:=OuterwearSectionExponent(Y);
        Fold:=S*0.0025*T*Sin(A*8+T*1.8);
        B.Mix:=0.42*(1-Smooth(0.0,0.09,LengthY*T));
        K:=B.Vertex((RX+Fold)*Sign(Sin(A))*Power(Abs(Sin(A)),E),S*Y,
          CZ*S+(RZ+Fold)*Sign(Cos(A))*Power(Abs(Cos(A)),E),J/Columns,T);
      end;
      T:=1/Rows;if LongHem then T:=0.55/12;
      OuterwearOpening(T,LongHem,FrontVent,BackVent);TopColumn:=0;Column:=0;
      while(TopColumn<TopCount-1)or(Column<Columns)do begin
        NextLower:=FrontVent+(Pi-FrontVent-BackVent)*(Column+1)/Columns;
        if(TopColumn<TopCount-1)and((Column=Columns)or(Angles[TopColumn+1]<=NextLower))then begin
          SewTriangle(TopStart+TopColumn,N+Column,TopStart+TopColumn+1);Inc(TopColumn);
        end else begin
          SewTriangle(TopStart+TopColumn,N+Column,N+Column+1);Inc(Column);
        end;
      end;
      for I:=1 to Rows-1 do for J:=0 to Columns-1 do begin
        K:=N+(I-1)*(Columns+1)+J;
        if Side=0 then B.Quad(K,K+Columns+1,K+Columns+2,K+1)
        else B.Quad(K+1,K+Columns+2,K+Columns+1,K);
      end;
    end;
    B.Finish(Material);
  finally B.Free end;
end;
procedure TMeshBuilder.Triangle(A,B,C:Integer);
var N,I,K:Integer;X,Y,Z,UX,UY,UZ,VX,VY,VZ:Single;
begin
  N:=Length(Indices);SetLength(Indices,N+3);Indices[N]:=A;Indices[N+1]:=B;Indices[N+2]:=C;
  UX:=Points[B*3]-Points[A*3];UY:=Points[B*3+1]-Points[A*3+1];UZ:=Points[B*3+2]-Points[A*3+2];
  VX:=Points[C*3]-Points[A*3];VY:=Points[C*3+1]-Points[A*3+1];VZ:=Points[C*3+2]-Points[A*3+2];
  X:=UY*VZ-UZ*VY;Y:=UZ*VX-UX*VZ;Z:=UX*VY-UY*VX;
  for I:=N to N+2 do begin K:=Indices[I]*3;Normals[K]:=Normals[K]+X;Normals[K+1]:=Normals[K+1]+Y;Normals[K+2]:=Normals[K+2]+Z end;
end;
procedure TMeshBuilder.Quad(A,B,C,D:Integer);
begin Triangle(A,B,C);Triangle(A,C,D) end;
procedure TMeshBuilder.Lathe(CX,CZ:Single;const Ys,RX,RZ:array of Single;Segments:Integer);
var I,J,N,A:Integer;Theta:Single;
begin
  N:=Length(Points) div 3;
  for I:=0 to High(Ys) do for J:=0 to Segments-1 do begin
    Theta:=2*Pi*J/Segments;
    Vertex(CX+RX[I]*Cos(Theta),Ys[I],CZ+RZ[I]*Sin(Theta),J/Segments,I/High(Ys));
  end;
  for I:=0 to High(Ys)-1 do for J:=0 to Segments-1 do begin
    A:=N+I*Segments;Quad(A+J,A+Segments+J,A+Segments+(J+1) mod Segments,A+(J+1) mod Segments);
  end;
end;
procedure TMeshBuilder.Box(X,Y,Z,DX,DY,DZ:Single);
const Faces:array[0..5,0..3] of Integer=((0,2,3,1),(4,5,7,6),(0,1,5,4),(2,6,7,3),(0,4,6,2),(1,3,7,5));
var I,J,N,K:Integer;
begin
  for I:=0 to 5 do begin
    N:=Length(Points) div 3;
    for J:=0 to 3 do begin K:=Faces[I,J];Vertex(X+((K and 1)-0.5)*DX,Y+(((K shr 1) and 1)-0.5)*DY,Z+(((K shr 2) and 1)-0.5)*DZ,J mod 2,J div 2) end;
    Quad(N,N+1,N+2,N+3);
  end;
end;
procedure TMeshBuilder.Finish(Material:Integer);
var I,J:Integer;L:Single;A,P:TJSONObject;Idx:TFloats;
begin
  if Length(Indices)=0 then Exit;
  for I:=0 to Length(Points) div 3-1 do begin
    L:=Sqrt(Sqr(Normals[I*3])+Sqr(Normals[I*3+1])+Sqr(Normals[I*3+2]));
    for J:=0 to 2 do Normals[I*3+J]:=Normals[I*3+J]/Max(L,1e-10);
  end;
  A:=TJSONObject.Create;P:=TJSONObject.Create(['attributes',A,'material',Material]);
  A.Add('POSITION',Acc(Doc,Points,3,'VEC3'));A.Add('NORMAL',Acc(Doc,Normals,3,'VEC3'));
  A.Add('TEXCOORD_0',Acc(Doc,UV,2,'VEC2'));A.Add('JOINTS_0',Acc(Doc,Joints,4,'VEC4',True));
  A.Add('WEIGHTS_0',Acc(Doc,Weights,4,'VEC4'));SetLength(Idx,Length(Indices));
  for I:=0 to High(Indices) do Idx[I]:=Indices[I];
  P.Add('indices',Acc(Doc,Idx,1,'SCALAR',True));EnsureArray(Mesh,'primitives').Add(P);
  Points:=nil;Normals:=nil;UV:=nil;Joints:=nil;Weights:=nil;Indices:=nil;
end;
procedure BuildWardrobeAccessory(Doc:TGlbDoc;const Preset,Color:string;
  out Mesh:TJSONObject;out Materials:TJSONArray);
var B:TMeshBuilder;Primary,Accent,Detail,I,J,K,N,S:Integer;
  P:TVec3;CX,CZ,Top,Scale,RX,RZ,Theta,T,Y,Width,Height,Z:Single;
  Ys,Xs,Zs:array[0..12] of Single;
  IsHead:Boolean;
const SideNames:array[0..1] of string=('L','R');
  ShoeZ:array[0..8] of Single=(-0.078,-0.072,-0.047,0,0.055,0.12,0.17,0.198,0.205);
  ShoeW:array[0..8] of Single=(0.008,0.047,0.054,0.052,0.059,0.061,0.053,0.029,0.001);
  ShoeH:array[0..8] of Single=(0.07,0.105,0.132,0.145,0.122,0.096,0.078,0.061,0.046);
begin
  IsHead:=(Preset='beanie') or (Preset='cap') or (Preset='bucket');
  Mesh:=TJSONObject.Create;Materials:=TJSONArray.Create;
  B:=TMeshBuilder.Create;B.Doc:=Doc;B.Mesh:=Mesh;
  try
    Primary:=Material(Doc,Color,0.82);Materials.Add(Primary);
    Accent:=Material(Doc,'#e5dfd3',0.90);Materials.Add(Accent);
    Detail:=Material(Doc,'#303238',0.62);Materials.Add(Detail);
    if IsHead then begin
      B.Joint:=Palette(Doc,'Head');B.SecondJoint:=B.Joint;
      P:=BindPoint(Doc,B.Joint);Scale:=P.Y/1.58;
      CX:=P.X;CZ:=P.Z+0.028*Scale;Top:=P.Y+0.173*Scale;
      RX:=0.100*Scale;RZ:=0.108*Scale;
      if Preset='beanie' then begin
        for I:=0 to 12 do begin T:=I/12*Pi/2;Ys[I]:=Top-0.082*Scale+Sin(T)*0.148*Scale;Xs[I]:=Max(0.0001,RX*Cos(T));Zs[I]:=Max(0.0001,RZ*Cos(T)) end;
        B.Lathe(CX,CZ,Ys,Xs,Zs);B.Finish(Primary);
        B.Lathe(CX,CZ,[Top-0.092*Scale,Top-0.084*Scale,Top-0.045*Scale,Top-0.039*Scale],
          [RX*1.01,RX*1.05,RX*1.05,RX*0.97],[RZ*1.01,RZ*1.05,RZ*1.05,RZ*0.97]);B.Finish(Primary);
      end else if Preset='cap' then begin
        for I:=0 to 12 do begin T:=I/12*Pi/2;Ys[I]:=Top-0.073*Scale+Sin(T)*0.112*Scale;Xs[I]:=Max(0.0001,RX*Cos(T));Zs[I]:=Max(0.0001,RZ*Cos(T)) end;
        B.Lathe(CX,CZ,Ys,Xs,Zs);B.Finish(Primary);
        N:=Length(B.Points) div 3;
        for I:=0 to 5 do for J:=0 to 32 do begin
          Theta:=-Pi*0.49+Pi*0.98*J/32;T:=I/5;
          B.Vertex(CX+Sin(Theta)*RX*(1+0.18*T),Top-0.074*Scale-0.018*Scale*T*T,
            CZ+Cos(Theta)*(RZ+0.082*Scale*T),J/32,T);
        end;
        for I:=0 to 4 do for J:=0 to 31 do begin K:=N+I*33+J;B.Quad(K+33,K+34,K+1,K) end;
        B.Finish(Primary);B.Box(CX,Top+0.039*Scale,CZ,0.016*Scale,0.007*Scale,0.016*Scale);B.Finish(Detail);
      end else begin
        B.Lathe(CX,CZ,[Top-0.08*Scale,Top+0.025*Scale,Top+0.04*Scale,Top+0.042*Scale],
          [RX,RX*0.91,RX*0.8,0.0001],[RZ,RZ*0.91,RZ*0.8,0.0001]);B.Finish(Primary);
        B.Lathe(CX,CZ,[Top-0.08*Scale,Top-0.085*Scale,Top-0.11*Scale],
          [RX*0.99,RX*1.2,RX*1.5],[RZ*0.99,RZ*1.2,RZ*1.45]);B.Finish(Primary);
        B.Lathe(CX,CZ,[Top-0.075*Scale,Top-0.055*Scale],[RX*1.006,RX*0.989],[RZ*1.006,RZ*0.989]);B.Finish(Detail);
      end;
    end else begin
      for S:=0 to 1 do begin
        B.Joint:=Palette(Doc,SideNames[S]+'_Foot');B.SecondJoint:=Palette(Doc,SideNames[S]+'_Calf');B.Mix:=0;
        P:=BindPoint(Doc,B.Joint);Scale:=P.Y/0.132;
        CX:=P.X;CZ:=P.Z;
        N:=0;
        for I:=0 to 8 do for J:=0 to 31 do begin
          Theta:=2*Pi*J/32;Width:=ShoeW[I]*Scale;Height:=ShoeH[I]*Scale;
          if Preset='loafers' then Height:=Height*0.85;
          Y:=(Height+0.045*Scale)/2+Cos(Theta)*(Height-0.045*Scale)/2;
          B.Vertex(CX+Width*Sin(Theta),Y,CZ+ShoeZ[I]*Scale,J/32,I/8);
        end;
        for I:=0 to 7 do for J:=0 to 31 do begin K:=I*32;B.Quad(K+J,K+32+J,K+32+(J+1) mod 32,K+(J+1) mod 32) end;
        B.Finish(Primary);
        { A separate flat outsole replaces cycling cleats. }
        for I:=0 to 8 do for J:=0 to 31 do begin
          Theta:=2*Pi*J/32;Y:=0.039*Scale+0.010*Scale*Cos(Theta);
          B.Vertex(CX+ShoeW[I]*Scale*1.03*Sin(Theta),Y,CZ+ShoeZ[I]*Scale,J/32,I/8);
        end;
        for I:=0 to 7 do for J:=0 to 31 do begin K:=I*32;B.Quad(K+J,K+32+J,K+32+(J+1) mod 32,K+(J+1) mod 32) end;
        if Preset='sneakers' then B.Finish(Accent) else B.Finish(Detail);
        if Preset='boots' then begin
          { Cuff weights gradually transfer from foot to calf. }
          for I:=0 to 5 do for J:=0 to 47 do begin
            Theta:=2*Pi*J/48;B.Mix:=I/5;
            B.Vertex(CX+0.062*Scale*Cos(Theta),Scale*(0.105+I*0.029),
              CZ+0.061*Scale*Sin(Theta),J/48,I/5);
          end;
          for I:=0 to 4 do for J:=0 to 47 do begin K:=I*48;B.Quad(K+J,K+48+J,K+48+(J+1) mod 48,K+(J+1) mod 48) end;
          B.Finish(Primary);B.Mix:=0;
        end;
        if Preset<>'loafers' then begin
          for I:=0 to 4 do B.Box(CX,Scale*(0.144-I*0.008),CZ+Scale*(0.015+I*0.018),0.073*Scale,0.004*Scale,0.005*Scale);
          B.Finish(Accent);
        end else begin
          B.Box(CX,0.111*Scale,CZ+0.03*Scale,0.09*Scale,0.006*Scale,0.022*Scale);B.Finish(Primary);
        end;
      end;
    end;
  finally B.Free end;
end;
procedure AddJeansDetails(Doc:TGlbDoc;Mesh:TJSONObject;Materials:TJSONArray);
const Cols=6;Rows=6;
var B:TMeshBuilder;Side,I,J,K,N,Metal:Integer;S,U,V,X,Y,Lift,A:Single;
  procedure Disc(X,Y,R:Single);
  var Q,L:Integer;Angle:Single;
  begin
    Q:=Length(B.Points)div 3;
    B.SurfaceVertex(X*S,Y*S,0.004*S,0.5,0.5);
    for L:=0 to 9 do begin
      Angle:=2*Pi*L/10;
      B.SurfaceVertex((X+R*Cos(Angle))*S,(Y+R*Sin(Angle))*S,0.003*S,
        0.5+0.5*Cos(Angle),0.5+0.5*Sin(Angle));
    end;
    for L:=0 to 9 do B.Triangle(Q,Q+1+L,Q+1+(L+1)mod 10);
  end;
begin
  B:=TMeshBuilder.Create;B.Doc:=Doc;B.Mesh:=Mesh;
  try
    S:=WardrobeBindScale(Doc);B.CaptureSurface;
    B.Joint:=Palette(Doc,'Pelvis');B.SecondJoint:=B.Joint;
    { Rear patch pockets follow both the actual surface and its skin weights.
      The pointed bottom and open lip have millimetre, not centimetre relief. }
    for Side:=0 to 1 do begin
      N:=Length(B.Points)div 3;
      for I:=0 to Rows do for J:=0 to Cols do begin
        U:=J/Cols;V:=I/Rows;X:=0.049+0.107*U;
        Y:=0.956-0.010*U-V*(0.109+0.023*(1-Abs(2*U-1)));
        Lift:=0.0016+0.0015*Sin(Pi*U)*Sin(Pi*V)+0.001*(1-V);
        B.SurfaceVertex((1-2*Side)*X*S,Y*S,Lift*S,U,V,True);
      end;
      for I:=0 to Rows-1 do for J:=0 to Cols-1 do begin
        K:=N+I*(Cols+1)+J;
        if Side=0 then B.Quad(K+1,K+Cols+2,K+Cols+1,K)
        else B.Quad(K,K+Cols+1,K+Cols+2,K+1);
      end;
    end;
    { Fly and narrow belt loops. Stitching and folded seams belong to the
      shared denim shader, so there is no separate draw call per thread. }
    N:=Length(B.Points)div 3;
    for I:=0 to 8 do for J:=0 to 1 do
      B.SurfaceVertex((J*0.016-0.006)*S,(0.993-I*0.012)*S,0.0018*S,J,I/8);
    for I:=0 to 7 do begin K:=N+I*2;B.Quad(K+1,K+3,K+2,K)end;
    for Side:=0 to 1 do for J:=0 to 1 do begin
      N:=Length(B.Points)div 3;
      for I:=0 to 4 do for K:=0 to 1 do begin
        V:=I/4;X:=(1-2*Side)*(0.10+(K-0.5)*0.011);
        B.SurfaceVertex(X*S,(0.995-V*0.037)*S,(0.002+0.002*Sin(Pi*V))*S,K,V,J=1);
      end;
      for I:=0 to 3 do begin
        K:=N+I*2;
        if(Side=0)xor(J=1)then B.Quad(K+1,K+3,K+2,K)else B.Quad(K,K+2,K+3,K+1);
      end;
    end;
    B.Finish(Materials.Integers[0]);
    Metal:=Material(Doc,'#967450',0.40);Materials.Add(Metal);
    ObjOf(ObjAt(ArrOf(Doc.Root,'materials'),Metal),'pbrMetallicRoughness').Floats['metallicFactor']:=0.65;
    Disc(0.002,0.985,0.005);
    for Side:=0 to 1 do begin A:=1-2*Side;Disc(A*0.076,0.981,0.0025);Disc(A*0.168,0.925,0.0025)end;
    B.Finish(Metal);
  finally B.Free end;
end;

procedure AddOuterwearDetails(Doc:TGlbDoc;const Preset:string;Mesh:TJSONObject;Materials:TJSONArray);
const LapelRows=6;LapelCols=4;PocketCols=10;
var B:TMeshBuilder;I,J,K,N,Accent,Side:Integer;S,X,Y,U,V,Lift,W,A:Single;
  Corners:array[0..3]of TVec3;
begin
  B:=TMeshBuilder.Create;B.Doc:=Doc;B.Mesh:=Mesh;
  try
    S:=WardrobeBindScale(Doc);B.CaptureSurface;
    B.Joint:=Palette(Doc,'Spine02');B.SecondJoint:=B.Joint;
    { A rolled collar/lapel is a curved cloth patch, not a four-corner plate. }
    for Side:=0 to 1 do begin
      W:=1;if(Preset='jacket')or(Preset='loose_jacket')then W:=0.78;
      Corners[0]:=V3(0.042,1.478,0);Corners[1]:=V3(0.106*W,1.426,0);
      Corners[2]:=V3(0.067*W,1.331,0);Corners[3]:=V3(0.017,1.393,0);
      N:=Length(B.Points)div 3;
      for I:=0 to LapelRows do for J:=0 to LapelCols do begin
        U:=J/LapelCols;V:=I/LapelRows;
        X:=(Corners[0].X*(1-U)+Corners[1].X*U)*(1-V)+(Corners[3].X*(1-U)+Corners[2].X*U)*V;
        Y:=(Corners[0].Y*(1-U)+Corners[1].Y*U)*(1-V)+(Corners[3].Y*(1-U)+Corners[2].Y*U)*V;
        Lift:=0.003+0.007*Sin(Pi*U)*(0.5+0.5*V);
        B.SurfaceVertex((1-2*Side)*X*S,Y*S,Lift*S,U,V);
      end;
      for I:=0 to LapelRows-1 do for J:=0 to LapelCols-1 do begin
        K:=N+I*(LapelCols+1)+J;
        if Side=0 then B.Quad(K+1,K+LapelCols+2,K+LapelCols+1,K)
        else B.Quad(K,K+LapelCols+1,K+LapelCols+2,K+1);
      end;
    end;
    B.Finish(Materials.Integers[0]);
    { Thin welt pockets with rounded ends lie on the shell; no floating boxes. }
    for Side:=0 to 1 do begin
      N:=Length(B.Points)div 3;
      for I:=0 to PocketCols do for J:=0 to 2 do begin
        U:=I/PocketCols;V:=J/2;
        X:=0.061+0.102*U;Y:=1.091-0.031*U-0.018*V;
        Lift:=0.0015+0.003*Sin(Pi*V)*Sin(Pi*U);
        B.SurfaceVertex((1-2*Side)*X*S,Y*S,Lift*S,U,V);
      end;
      for I:=0 to PocketCols-1 do for J:=0 to 1 do begin
        K:=N+I*3+J;
        if Side=0 then B.Quad(K,K+1,K+4,K+3)else B.Quad(K+3,K+4,K+1,K);
      end;
    end;
    B.Finish(Materials.Integers[0]);
    { A narrow closure tape covers the old jersey split without inheriting
      its stretched zipper teeth. Buttons are shallow round discs. }
    for I:=0 to 24 do for J:=0 to 1 do
      B.SurfaceVertex((J-0.5)*0.011*S,(1.38-I*0.013)*S,0.0025*S,J,I/24);
    for I:=0 to 23 do begin K:=I*2;B.Quad(K+1,K+3,K+2,K)end;
    B.Finish(Materials.Integers[0]);
    Accent:=Material(Doc,'#474947',0.46);Materials.Add(Accent);
    for I:=0 to 4 do begin
      Y:=1.355-I*0.068;N:=Length(B.Points)div 3;
      B.SurfaceVertex(0,Y*S,0.0045*S,0.5,0.5);
      for J:=0 to 11 do begin
        A:=2*Pi*J/12;B.SurfaceVertex(S*0.0048*Cos(A),S*(Y+0.0048*Sin(A)),0.0035*S,0.5+0.5*Cos(A),0.5+0.5*Sin(A));
      end;
      for J:=0 to 11 do B.Triangle(N,N+1+J,N+1+(J+1)mod 12);
    end;
    B.Finish(Accent);
  finally B.Free end;
end;
end.
