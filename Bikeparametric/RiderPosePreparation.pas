unit RiderPosePreparation;
{$mode objfpc}{$H+}
{ Pure pose preparation: immutable authored inputs -> current pose constants.
  No scene, X3D events, GL state or clocks. Callers own scratch/output arrays,
  so independent riders may prepare concurrently and publish on the scene
  thread. Expressions are compiled from the same GLSL metadata as the legacy
  vertex path, with shared subexpressions instead of a second authored model. }
interface
uses Classes, SysUtils, Math, CastleVectors;
type
  TRiderPoseJointInput=record
    Routing,Parent:Integer;
    Rest,HandRest,Face,BindRotation:TMatrix4;
    NeedAngles:Boolean;
  end;
  TRiderPoseMuscle=record
    A,B:TVector3;
    Response:TVector4;
    JA,JB:Integer;
    BroadAttachment:Boolean;
    Channel:Integer;
    RestLength:Single;
  end;
  TRiderPoseThigh=record
    A,B:TVector3;
    JA,JB:Integer;
  end;
  TRiderPoseOp=(poConstant,poInput,poNegate,poAdd,poSubtract,poMultiply,poDivide,
    poMin,poMax,poClamp,poAbs,poSqrt,poSin,poCos,poPow,poMix,poSmoothstep);
  TRiderPoseExpressionNode=record
    Op:TRiderPoseOp;
    A,B,C:Integer;
    Value:Single;
  end;
  TRiderPoseExpressions=class
  private
    FNodes:array of TRiderPoseExpressionNode;
    FRoots:array of Integer;
    FSource:string;
    FPosition:Integer;
    FVariables:TStrings;
    function Node(Op:TRiderPoseOp;A:Integer=-1;B:Integer=-1;C:Integer=-1;Value:Single=0):Integer;
    procedure Space;
    function Take(Ch:Char):Boolean;
    procedure Expect(Ch:Char);
    function Expression:Integer;
    function Product:Integer;
    function Primary:Integer;
    function GetNodeCount:Integer;
    function GetCount:Integer;
  public
    procedure Add(const Source:string;const Variables:TStrings);
    procedure Evaluate(const Inputs:array of Single;var Scratch:array of Single;
      var Outputs:array of Single);
    property NodeCount:Integer read GetNodeCount;
    property Count:Integer read GetCount;
  end;
function RiderPoseQuaternion(const M:TMatrix4):TVector4;
function RiderPoseLocalAngles(const Child,Parent,BindRotation:TMatrix4):TVector3;
function RiderPoseRotation(const M:TMatrix4):TMatrix4;
procedure RiderPoseJoint(const Input:TRiderPoseJointInput;const Palette:TMatrix4List;
  const Grip:TVector2;out Matrix,Delta:TMatrix4);
procedure RiderPoseBody(const Joints:TMatrix4List;const Muscles:array of TRiderPoseMuscle;
  const Thighs:array of TRiderPoseThigh;const Profile:TVector4;const Frame:TVector2;
  const Dynamics:TVector4List;const BellyCentre,BellyRadii:TVector3;const ThighRadius:Single;
  const Output:TVector4List);
procedure RiderPoseJoints(const Inputs:array of TRiderPoseJointInput;const Palette:TMatrix4List;
  const Grip:TVector2;const Matrices,Deltas:TMatrix4List;const Quaternions:TVector4List;
  const Angles:TVector3List);
implementation
uses TripoRig;
procedure RiderPoseJoint(const Input:TRiderPoseJointInput;const Palette:TMatrix4List;
  const Grip:TVector2;out Matrix,Delta:TMatrix4);
var Code,Kind,Part,Slot,HandSlot,Side,C,R:Integer;D,Hand,M:TMatrix4;
  Q:TTripoVec4;P:TTripoVec3;T:TTripoMat4;Amount:Single;
begin
    Code:=Input.Routing;HandSlot:=Code div 64;Code:=Code-HandSlot*64;
    D:=TMatrix4.Identity;M:=Input.Rest;
    if Code<>0 then begin
      Kind:=Code div 8;Part:=Code-Kind*8;
      case Kind of 1:Slot:=1;2:Slot:=4;3:if Part<5 then Slot:=7 else Slot:=15;
        4:Slot:=12;else Slot:=16 end;
      if(Kind>=4)and(Part>=4)then begin
        Side:=Kind-4;M:=Palette[22+Side];
        Q.X:=M.Data[0,0];Q.Y:=M.Data[0,1];Q.Z:=M.Data[0,2];Q.W:=M.Data[0,3];
        P:=V3(M.Data[1,0],M.Data[1,1],M.Data[1,2]);
        if Part=4 then begin Q.W:=Q.W+1;Q:=QuatNormalize(Q)end;
        T:=Mat4FromTRS(V3Sub(P,QuatRotateV3(Q,P)),Q,V3(1,1,1));Move(T,M,SizeOf(M));
        D:=M*Palette[14+Side*4];M:=D*Input.Rest;
      end else begin
        D:=Palette[Slot+Part];Hand:=TMatrix4.Identity;
        if(Kind>=4)and(Part=3)then begin
          Amount:=Grip.Data[Kind-4];Hand:=Input.HandRest;
          for C:=0 to 3 do for R:=0 to 3 do begin
            Hand.Data[C,R]:=Hand.Data[C,R]*Amount;
            if C=R then Hand.Data[C,R]:=(1-Amount)+Hand.Data[C,R];
          end;
        end;
        M:=D*Hand*Input.Rest*Input.Face;
      end;
    end;
    Matrix:=M;Delta:=D;
end;
procedure RiderPoseJoints(const Inputs:array of TRiderPoseJointInput;const Palette:TMatrix4List;
  const Grip:TVector2;const Matrices,Deltas:TMatrix4List;const Quaternions:TVector4List;
  const Angles:TVector3List);
var I,J:Integer;M,D,Parent:TMatrix4;
begin
  for I:=0 to High(Inputs)do begin
    RiderPoseJoint(Inputs[I],Palette,Grip,M,D);
    Deltas[I]:=D;Matrices[I]:=M;Quaternions[I]:=RiderPoseQuaternion(M);
  end;
  for I:=0 to High(Inputs)do if Inputs[I].NeedAngles then begin
    J:=Inputs[I].Parent;Parent:=TMatrix4.Identity;if J>=0 then Parent:=Deltas[J];
    Angles[I]:=RiderPoseLocalAngles(Deltas[I],Parent,Inputs[I].BindRotation);
  end;
end;
procedure RiderPoseBody(const Joints:TMatrix4List;const Muscles:array of TRiderPoseMuscle;
  const Thighs:array of TRiderPoseThigh;const Profile:TVector4;const Frame:TVector2;
  const Dynamics:TVector4List;const BellyCentre,BellyRadii:TVector3;const ThighRadius:Single;
  const Output:TVector4List);
var I,Base,Channel,Side,Part:Integer;A,B,Axis,C,R:TVector3;
  Len,Activation,Tissue,Wave,Strain,Share,Soft,Radius:Single;Response:TVector4;
begin
  Share:=EnsureRange(0.28+0.16*Profile.Y-0.12*Profile.X,0.10,0.52);
  for I:=0 to High(Muscles)do begin
    A:=(Joints[Muscles[I].JA]*Vector4(Muscles[I].A,1)).XYZ;
    B:=(Joints[Muscles[I].JB]*Vector4(Muscles[I].B,1)).XYZ;
    Axis:=B-A;Len:=Max(Axis.Length,0.001);Axis:=Axis/Len;
    Response:=Muscles[I].Response;Tissue:=0;Channel:=Muscles[I].Channel;
    if Dynamics[3].W>0.5 then begin
      if Channel>=0 then begin
        Side:=Channel div 4;Part:=Channel-4*Side;Activation:=Dynamics[Side].Data[Part];
        if Part=0 then Tissue:=Dynamics[2].Data[Side]
        else if Part=1 then Tissue:=Dynamics[2].Data[2+Side];
      end else Activation:=EnsureRange(Frame.X*0.12,0,0.35);
    end else begin
      Wave:=Max(0,Cos(6.2831853*(Frame.Y-Response.X)));
      Activation:=EnsureRange(Frame.X*0.5,0,1)*((1-Response.Y)+(0.08+0.92*Wave*Wave)*Response.Y);
    end;
    Strain:=(EnsureRange(Sqrt(Muscles[I].RestLength/Len),0.90,1.12)-1)*Response.W+Response.Z*Activation;
    Output[I*2]:=Vector4(A,Len);Output[I*2+1]:=Vector4(Axis,Strain*Share+Tissue);
  end;
  Base:=Length(Muscles)*2;Soft:=EnsureRange(0.45+0.22*Profile.X-0.12*Profile.Y,0.25,0.8);
  C:=BellyCentre;R:=BellyRadii;
  C.Z:=C.Z+0.035*Profile.X;R.X:=R.X*(1+0.35*Profile.X);R.Z:=R.Z*(1+0.65*Profile.X);
  Radius:=ThighRadius*(1+0.28*Profile.X+0.24*Profile.Y);
  Output[Base]:=Vector4(C,Soft);Output[Base+1]:=Vector4(R,Radius);
  for I:=0 to High(Thighs)do begin
    A:=(Joints[Thighs[I].JA]*Vector4(Thighs[I].A,1)).XYZ;
    B:=(Joints[Thighs[I].JB]*Vector4(Thighs[I].B,1)).XYZ-A;
    Output[Base+2+I*2]:=Vector4(A,Max(B.LengthSqr,0.0001));
    Output[Base+3+I*2]:=Vector4(B,0);
  end;
end;
function TRiderPoseExpressions.GetNodeCount:Integer;
begin Result:=Length(FNodes)end;
function TRiderPoseExpressions.GetCount:Integer;
begin Result:=Length(FRoots)end;
function TRiderPoseExpressions.Node(Op:TRiderPoseOp;A,B,C:Integer;Value:Single):Integer;
var I:Integer;
begin
  { Hash-free exact interning is a model-load operation only. Repeated ramps
    in spline controls become one arithmetic chain per pose, not per vertex. }
  for I:=0 to High(FNodes)do
    if(FNodes[I].Op=Op)and(FNodes[I].A=A)and(FNodes[I].B=B)and
      (FNodes[I].C=C)and(FNodes[I].Value=Value)then Exit(I);
  Result:=Length(FNodes);SetLength(FNodes,Result+1);
  FNodes[Result].Op:=Op;FNodes[Result].A:=A;FNodes[Result].B:=B;
  FNodes[Result].C:=C;FNodes[Result].Value:=Value;
end;
procedure TRiderPoseExpressions.Space;
begin while(FPosition<=Length(FSource))and(FSource[FPosition]<=' ')do Inc(FPosition)end;
function TRiderPoseExpressions.Take(Ch:Char):Boolean;
begin
  Space;Result:=(FPosition<=Length(FSource))and(FSource[FPosition]=Ch);
  if Result then Inc(FPosition);
end;
procedure TRiderPoseExpressions.Expect(Ch:Char);
begin if not Take(Ch)then raise EReadError.CreateFmt('Pose expression expected %s at %d',[Ch,FPosition])end;
function TRiderPoseExpressions.Expression:Integer;
begin
  Result:=Product;
  while True do
    if Take('+')then Result:=Node(poAdd,Result,Product)
    else if Take('-')then Result:=Node(poSubtract,Result,Product)
    else Break;
end;
function TRiderPoseExpressions.Product:Integer;
begin
  Result:=Primary;
  while True do
    if Take('*')then Result:=Node(poMultiply,Result,Primary)
    else if Take('/')then Result:=Node(poDivide,Result,Primary)
    else Break;
end;
function TRiderPoseExpressions.Primary:Integer;
var Start,I,A,B,C,Arity:Integer;Name:string;Value:Single;Fmt:TFormatSettings;Op:TRiderPoseOp;
begin
  Space;
  if Take('-')then Exit(Node(poNegate,Primary()));
  if Take('+')then Exit(Primary());
  if Take('(')then begin Result:=Expression;Expect(')');Exit end;
  if FPosition>Length(FSource)then raise EReadError.Create('Incomplete pose expression');
  Start:=FPosition;
  if FSource[FPosition]in['0'..'9','.']then begin
    while(FPosition<=Length(FSource))and(FSource[FPosition]in['0'..'9','.'])do Inc(FPosition);
    if(FPosition<=Length(FSource))and(FSource[FPosition]in['e','E'])then begin
      Inc(FPosition);if(FPosition<=Length(FSource))and(FSource[FPosition]in['+','-'])then Inc(FPosition);
      while(FPosition<=Length(FSource))and(FSource[FPosition]in['0'..'9'])do Inc(FPosition);
    end;
    Name:=Copy(FSource,Start,FPosition-Start);Fmt:=DefaultFormatSettings;Fmt.DecimalSeparator:='.';
    Value:=StrToFloat(Name,Fmt);Exit(Node(poConstant,-1,-1,-1,Value));
  end;
  while(FPosition<=Length(FSource))and(FSource[FPosition]in['a'..'z','A'..'Z','0'..'9','_','.'])do Inc(FPosition);
  Name:=Copy(FSource,Start,FPosition-Start);
  if Name=''then raise EReadError.CreateFmt('Unexpected pose expression token at %d',[FPosition]);
  if not Take('(')then begin
    I:=FVariables.IndexOf(Name);
    if I<0 then raise EReadError.Create('Unknown pose expression variable '+Name);
    Exit(Node(poInput,PtrInt(FVariables.Objects[I])));
  end;
  Arity:=1;
  if Name='min'then begin Op:=poMin;Arity:=2 end
  else if Name='max'then begin Op:=poMax;Arity:=2 end
  else if Name='clamp'then begin Op:=poClamp;Arity:=3 end
  else if Name='abs'then Op:=poAbs
  else if Name='sqrt'then Op:=poSqrt
  else if Name='sin'then Op:=poSin
  else if Name='cos'then Op:=poCos
  else if Name='pow'then begin Op:=poPow;Arity:=2 end
  else if Name='mix'then begin Op:=poMix;Arity:=3 end
  else if Name='smoothstep'then begin Op:=poSmoothstep;Arity:=3 end
  else raise EReadError.Create('Unsupported pose expression function '+Name);
  A:=Expression;B:=-1;C:=-1;
  if Arity>=2 then begin Expect(',');B:=Expression end;
  if Arity>=3 then begin Expect(',');C:=Expression end;
  Expect(')');Result:=Node(Op,A,B,C);
end;
procedure TRiderPoseExpressions.Add(const Source:string;const Variables:TStrings);
var Root,N:Integer;
begin
  FSource:=Source;FPosition:=1;FVariables:=Variables;
  try
    Root:=Expression;Space;
    if FPosition<=Length(FSource)then raise EReadError.Create('Unexpected suffix in pose expression');
    N:=Length(FRoots);SetLength(FRoots,N+1);FRoots[N]:=Root;
  finally FVariables:=nil;FSource:='' end;
end;
procedure TRiderPoseExpressions.Evaluate(const Inputs:array of Single;var Scratch:array of Single;var Outputs:array of Single);
var I:Integer;N:TRiderPoseExpressionNode;A,B,C,T:Single;
begin
  if(Length(Scratch)<NodeCount)or(Length(Outputs)<Count)then raise ERangeError.Create('Pose preparation output size');
  for I:=0 to High(FNodes)do begin
    N:=FNodes[I];A:=0;B:=0;C:=0;
    if N.Op=poInput then begin Scratch[I]:=Inputs[N.A];Continue end;
    if N.A>=0 then A:=Scratch[N.A];if N.B>=0 then B:=Scratch[N.B];if N.C>=0 then C:=Scratch[N.C];
    case N.Op of
      poConstant:T:=N.Value;poNegate:T:=-A;poAdd:T:=A+B;poSubtract:T:=A-B;
      poMultiply:T:=A*B;poDivide:T:=A/B;poMin:T:=Min(A,B);poMax:T:=Max(A,B);
      poClamp:T:=Min(Max(A,B),C);poAbs:T:=Abs(A);poSqrt:T:=Sqrt(A);
      poSin:T:=Sin(A);poCos:T:=Cos(A);poPow:T:=Power(A,B);poMix:T:=A*(1-C)+B*C;
      poSmoothstep:begin T:=Min(Max((C-A)/(B-A),0),1);T:=T*T*(3-2*T)end;
      else T:=0;
    end;
    Scratch[I]:=T;
  end;
  for I:=0 to High(FRoots)do Outputs[I]:=Scratch[FRoots[I]];
end;
function RiderPoseQuaternion(const M:TMatrix4):TVector4;
var T,S:Single;
begin
  T:=M.Data[0,0]+M.Data[1,1]+M.Data[2,2];
  if T>0 then begin
    S:=Sqrt(T+1)*2;
    Result:=Vector4((M.Data[1,2]-M.Data[2,1])/S,(M.Data[2,0]-M.Data[0,2])/S,(M.Data[0,1]-M.Data[1,0])/S,S*0.25);
  end else if(M.Data[0,0]>M.Data[1,1])and(M.Data[0,0]>M.Data[2,2])then begin
    S:=Sqrt(Max(1e-8,1+M.Data[0,0]-M.Data[1,1]-M.Data[2,2]))*2;
    Result:=Vector4(S*0.25,(M.Data[1,0]+M.Data[0,1])/S,(M.Data[2,0]+M.Data[0,2])/S,(M.Data[1,2]-M.Data[2,1])/S);
  end else if M.Data[1,1]>M.Data[2,2]then begin
    S:=Sqrt(Max(1e-8,1+M.Data[1,1]-M.Data[0,0]-M.Data[2,2]))*2;
    Result:=Vector4((M.Data[1,0]+M.Data[0,1])/S,S*0.25,(M.Data[2,1]+M.Data[1,2])/S,(M.Data[2,0]-M.Data[0,2])/S);
  end else begin
    S:=Sqrt(Max(1e-8,1+M.Data[2,2]-M.Data[0,0]-M.Data[1,1]))*2;
    Result:=Vector4((M.Data[2,0]+M.Data[0,2])/S,(M.Data[2,1]+M.Data[1,2])/S,S*0.25,(M.Data[0,1]-M.Data[1,0])/S);
  end;
  Result:=Result/Result.Length;
end;
function RiderPoseRotation(const M:TMatrix4):TMatrix4;
var C,R:Integer;
begin
  Result:=TMatrix4.Identity;
  for C:=0 to 2 do for R:=0 to 2 do Result.Data[C,R]:=M.Data[C,R];
end;
function RiderPoseLocalAngles(const Child,Parent,BindRotation:TMatrix4):TVector3;
var C,P,B,D:TMatrix4;
begin
  C:=RiderPoseRotation(Child);P:=RiderPoseRotation(Parent);B:=RiderPoseRotation(BindRotation);
  D:=B.Transpose*P.Transpose*C*B;
  Result.X:=ArcTan2(D.Data[1,2],D.Data[2,2]);
  Result.Y:=ArcTan2(-D.Data[0,2],Sqrt(Sqr(D.Data[0,0])+Sqr(D.Data[0,1])));
  Result.Z:=ArcTan2(D.Data[0,1],D.Data[0,0]);
end;
end.
