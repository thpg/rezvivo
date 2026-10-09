program GaitContactTest;
{$mode objfpc}{$H+}
uses SysUtils,Math,TripoRig,AvatarGait;
const Speeds:array[0..4]of Single=(0,1.4,2.5,4.5,5.5);
  Slopes:array[0..4]of Single=(-0.3,-0.05,0,0.05,0.3);
  Sides:array[0..1]of string=('L','R');
var R:TTripoRig;G:TGaitFrame;I,J,K,N,Foot,Parent,Bone:Integer;
  P,A,B,HeelNative,ToeNative:TTripoVec3;Q:TTripoVec4;
  DA,DB,Length,BindLength,Factor:Single;M:TTripoMat4;
  Saved:array[0..1,0..1]of TTripoMat4;
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
        AvatarGaitSole(R,Foot,G.Forward,A,B);
        A:=V3Add(P,QuatRotateV3(Q,A));B:=V3Add(P,QuatRotateV3(Q,B));
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
    { Alter leg lengths independently of shoe geometry, as body fitting
      does. Test the authored sole through skin matrices, without using
      the gait solver's own support points as the expected result. }
    for N:=0 to 1 do for Bone:=0 to 1 do begin
      if Bone=0 then Foot:=R.JointIndexByName(Sides[N]+'_Calf')
      else Foot:=R.JointIndexByName(Sides[N]+'_Foot');
      Saved[N,Bone]:=R.BindLocal[Foot];
    end;
    for I:=0 to 1 do begin
      if I=0 then Factor:=0.78 else Factor:=1.23;
      for N:=0 to 1 do for Bone:=0 to 1 do begin
        if Bone=0 then Foot:=R.JointIndexByName(Sides[N]+'_Calf')
        else Foot:=R.JointIndexByName(Sides[N]+'_Foot');
        R.BindLocal[Foot]:=Saved[N,Bone];
        for J:=12 to 14 do R.BindLocal[Foot][J]:=Saved[N,Bone][J]*Factor;
      end;
      R.RecomputeBindWorld(True);
      for K:=0 to 120 do begin
        PoseAvatarGait(R,K/120,0,False,G);
        for N:=0 to 1 do Require(G.Feet[N].KneeFlexion<5,
          'Resized rider remains crouched at rest');
        PoseAvatarGait(R,K/120,3.9,True,G);
        for N:=0 to 1 do begin
          Foot:=R.JointIndexByName(Sides[N]+'_Foot');M:=Mat4Inverse(R.NativeInvBind[Foot]);
          P:=V3(M[12],M[13],M[14]);
          HeelNative:=V3Add(P,V3Scale(G.Forward,-0.078));HeelNative.Y:=0.029;
          ToeNative:=V3Add(P,V3Scale(G.Forward,0.205));ToeNative.Y:=0.029;
          A:=V3Add(Mat4MulPoint(R.SkinMatrix[Foot],HeelNative),G.Offset);
          B:=V3Add(Mat4MulPoint(R.SkinMatrix[Foot],ToeNative),G.Offset);
          Require(Min(A.Y,B.Y)>-0.002,'Long/short legs put the shoe below ground');
          if G.Feet[N].Stance then Require(Abs(Min(A.Y,B.Y))<0.002,'Resized rider shoe floats');
        end;
      end;
    end;
    WriteLn('PASS: 3025 poses, level/uphill/downhill sole contact, leg reach and bone lengths');
    WriteLn('PASS: 242 short/long leg poses, native skinned shoe support independent of inseam');
  finally R.Free end;
end.
