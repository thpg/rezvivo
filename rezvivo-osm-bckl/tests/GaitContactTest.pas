program GaitContactTest;
{$mode objfpc}{$H+}
uses SysUtils,Math,TripoRig,AvatarGait;
const Speeds:array[0..4]of Single=(0,1.4,2.5,4.5,5.5);
  Slopes:array[0..4]of Single=(-0.3,-0.05,0,0.05,0.3);
  Sides:array[0..1]of string=('L','R');
var R:TTripoRig;G:TGaitFrame;I,J,K,N,Foot,Parent,Bone:Integer;
  P,A,B:TTripoVec3;Q:TTripoVec4;Height,DA,DB,Length,BindLength:Single;
procedure Require(OK:Boolean;const Msg:string);
begin if not OK then raise Exception.Create(Msg)end;
begin
  R:=TTripoRig.Create;
  try
    Require(R.LoadFromFile(ParamStr(1)),'Cannot load rig');
    for I:=0 to High(Speeds)do for J:=0 to High(Slopes)do for K:=0 to 120 do begin
      PoseAvatarGait(R,K/120,Speeds[I],Speeds[I]>2.5,G,-1,Slopes[J]);
      for N:=0 to 1 do begin
        Foot:=R.JointIndexByName(Sides[N]+'_Foot');
        P:=V3Add(R.JointWorldPos(Foot),G.Offset);
        Q:=QuatMul(R.JointWorldRot(Foot),QuatConj(Mat4ToQuat(R.BindWorld[Foot])));
        Height:=R.JointBindPos(Foot).Y-0.029*G.Scale;
        A:=V3Add(P,QuatRotateV3(Q,V3Add(V3Scale(G.Forward,-0.078*G.Scale),V3(0,-Height,0))));
        B:=V3Add(P,QuatRotateV3(Q,V3Add(V3Scale(G.Forward,0.205*G.Scale),V3(0,-Height,0))));
        DA:=A.Y-Slopes[J]*V3Dot(A,G.Forward);DB:=B.Y-Slopes[J]*V3Dot(B,G.Forward);
        Require(Min(DA,DB)>-0.002,'Sole penetrates measured support plane');
        if G.Feet[N].Stance then Require(Abs(Min(DA,DB))<0.002,'Stance foot floats');
        Require(G.Feet[N].Error<0.002,'Leg IK misses support target');
        for Bone:=0 to 1 do begin
          if Bone=0 then Foot:=R.JointIndexByName(Sides[N]+'_Calf')
          else Foot:=R.JointIndexByName(Sides[N]+'_Foot');
          Parent:=R.JointParent[Foot];
          Length:=V3Len(V3Sub(R.JointWorldPos(Foot),R.JointWorldPos(Parent)));
          BindLength:=V3Len(V3Sub(R.JointBindPos(Foot),R.JointBindPos(Parent)));
          Require(Abs(Length-BindLength)<0.0001,'Support stretches a leg bone');
        end;
      end;
    end;
    WriteLn('PASS: 3025 poses, level/uphill/downhill sole contact, leg reach and bone lengths');
  finally R.Free end;
end.
