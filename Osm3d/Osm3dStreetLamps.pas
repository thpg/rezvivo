unit Osm3dStreetLamps;

{$mode objfpc}{$H+}

{ Small static templates. +Z is the illuminated side; origin is ground level.
  No lights, textures, per-frame updates or per-lamp scene objects are needed. }
interface
uses Math, CastleVectors, Osm3dGeomMesh;
type
  TStreetLampStyle = (slRoad, slCurved, slDouble, slPark, slBollard);
function StreetLampHeight(Style: TStreetLampStyle): Single;
function BuildStreetLamp(Style: TStreetLampStyle; Lens: Boolean = False): TMesh;

implementation

function StreetLampHeight(Style: TStreetLampStyle): Single;
const Heights: array[TStreetLampStyle] of Single = (8.0, 7.2, 9.0, 3.8, 0.95);
begin Result := Heights[Style] end;

procedure Tube(M: TMesh; const Points: array of TVector3;
  R0, R1: Single; Sides: Integer = 8);
var I, J, K, Base, Cap: Integer; T, N, P: TVector3; R, A: Single;
begin
  Base := M.VertexCount;
  for I := 0 to High(Points) do
  begin
    if I = 0 then T := Points[1]-Points[0]
    else if I = High(Points) then T := Points[I]-Points[I-1]
    else T := Points[I+1]-Points[I-1];
    T := VecNormalize(T);
    R := R0+(R1-R0)*I/High(Points);
    for J := 0 to Sides-1 do
    begin
      A := 2*Pi*J/Sides;
      N := Vector3(Cos(A), -T.Z*Sin(A), T.Y*Sin(A));
      M.AddVertex(Points[I]+N*R, N, Vector2(J/Sides,I/High(Points)));
      if I > 0 then
      begin
        K := (J+1) mod Sides;
        M.AddQuad(Base+(I-1)*Sides+J, Base+I*Sides+J,
          Base+I*Sides+K, Base+(I-1)*Sides+K);
      end;
    end;
  end;
  { Separate cap normals keep the stem smooth and the feet/head flat. }
  for I := 0 to 1 do
  begin
    if I = 0 then begin K:=0; N:=VecNormalize(Points[0]-Points[1]) end
    else begin K:=High(Points); N:=VecNormalize(Points[K]-Points[K-1]) end;
    Cap := M.AddVertex(Points[K],N);
    for J := 0 to Sides-1 do
    begin P:=M.VertexAt[Base+K*Sides+J].Position; M.AddVertex(P,N) end;
    for J := 0 to Sides-1 do M.AddTriangle(Cap,Cap+1+J,Cap+1+(J+1) mod Sides);
  end;
end;

{ Thin chamfered LED head, with a separate recessed diffuser on the underside. }
procedure Head(M: TMesh; Y, Z, Sign: Single; Lens: Boolean);
const Xs: array[0..7] of Single = (-0.12,0.12,0.18,0.18,0.12,-0.12,-0.18,-0.18);
      Zs: array[0..7] of Single = (-0.38,-0.38,-0.30,0.30,0.38,0.38,0.30,-0.30);
var I,J,B: Integer; A,C,InnerA,InnerC,N: TVector3;
begin
  B:=M.VertexCount;
  if Lens then
  begin
    for I:=0 to 7 do M.AddVertex(Vector3(Xs[I]*0.83,Y-0.032,Z+Sign*Zs[I]*0.87),Vector3(0,-1,0));
    for I:=1 to 6 do M.AddTriangle(B,B+I+1,B+I);
  end else
  begin
    for I:=0 to 7 do M.AddVertex(Vector3(Xs[I],Y+0.04,Z+Sign*Zs[I]),Vector3(0,1,0));
    for I:=1 to 6 do M.AddTriangle(B,B+I,B+I+1);
    for I:=0 to 7 do
    begin
      J:=(I+1) mod 8;
      A:=Vector3(Xs[I],Y-0.04,Z+Sign*Zs[I]); C:=Vector3(Xs[J],Y-0.04,Z+Sign*Zs[J]);
      N:=VecNormalize(Vector3((A.X+C.X)*0.5,0,(A.Z+C.Z)*0.5-Z));
      B:=M.AddVertex(A,N); M.AddVertex(C,N);
      M.AddVertex(C+Vector3(0,0.08,0),N); M.AddVertex(A+Vector3(0,0.08,0),N);
      M.AddQuad(B,B+1,B+2,B+3);
    end;
    { Open bezel around the inset diffuser, not a coincident metal sheet
      underneath it: avoids depth fighting as a small lamp recedes. }
    for I:=0 to 7 do
    begin
      J:=(I+1) mod 8;N:=Vector3(0,-1,0);
      A:=Vector3(Xs[I],Y-0.04,Z+Sign*Zs[I]); C:=Vector3(Xs[J],Y-0.04,Z+Sign*Zs[J]);
      InnerA:=Vector3(Xs[I]*0.83,Y-0.04,Z+Sign*Zs[I]*0.87);
      InnerC:=Vector3(Xs[J]*0.83,Y-0.04,Z+Sign*Zs[J]*0.87);
      B:=M.AddVertex(A,N);M.AddVertex(C,N);M.AddVertex(InnerC,N);M.AddVertex(InnerA,N);
      M.AddQuad(B,B+1,B+2,B+3);
      N:=VecNormalize(Vector3(-(InnerA.X+InnerC.X)*0.5,0,Z-(InnerA.Z+InnerC.Z)*0.5));
      B:=M.AddVertex(InnerA,N);M.AddVertex(InnerC,N);
      M.AddVertex(InnerC+Vector3(0,0.008,0),N);M.AddVertex(InnerA+Vector3(0,0.008,0),N);
      M.AddQuad(B,B+1,B+2,B+3);
    end;
  end;
end;

function BuildStreetLamp(Style: TStreetLampStyle; Lens: Boolean): TMesh;
var P: array[0..12] of TVector3; I,S: Integer; H,T,Z,Y: Single;
begin
  Result:=TMesh.Create('street_lamp');
  try
    H:=StreetLampHeight(Style);
    case Style of
      slRoad,slDouble:
      begin
        if not Lens then
        begin
          Tube(Result,[Vector3(0,0,0),Vector3(0,0.18,0)],0.16,0.14);
          Tube(Result,[Vector3(0,0.18,0),Vector3(0,H-0.65,0)],0.095,0.042);
        end;
        for S:=-1 to 1 do
          if (S<>0) and ((Style=slDouble) or (S=1)) then
          begin
            if not Lens then Tube(Result,[Vector3(0,H-0.8,0),Vector3(0,H-0.15,S*0.65),Vector3(0,H-0.10,S*1.55)],0.044,0.025);
            Head(Result,H-0.10,S*1.85,S,Lens);
          end;
      end;
      slCurved:
      begin
        { Track column: continuously bowed/tapered upper stem, short LED head
          below its tip. Not a square elbow or a 90-degree shepherd's crook. }
        for I:=0 to High(P) do
        begin
          T:=I/High(P); Z:=1.2*Sqr(Max(0,(T-0.35)/0.65));
          P[I]:=Vector3(0,T*H,Z);
        end;
        Y:=H*0.945; Z:=1.2*Sqr((0.945-0.35)/0.65);
        if not Lens then
        begin
          Tube(Result,[Vector3(0,0,0),Vector3(0,0.22,0)],0.15,0.13);
          Tube(Result,P,0.075,0.022);
          Tube(Result,[Vector3(0,Y,Z),Vector3(0,Y,Z+0.32)],0.028,0.023);
        end;
        Head(Result,Y,Z+0.62,1,Lens);
      end;
      slPark:
        if Lens then Tube(Result,[Vector3(0,H-0.53,0),Vector3(0,H-0.12,0)],0.20,0.26)
        else begin
          Tube(Result,[Vector3(0,0,0),Vector3(0,0.22,0)],0.17,0.12);
          Tube(Result,[Vector3(0,0.22,0),Vector3(0,H-0.6,0)],0.065,0.036);
          Tube(Result,[Vector3(0,H-0.62,0),Vector3(0,H-0.54,0)],0.13,0.25);
          Tube(Result,[Vector3(0,H-0.11,0),Vector3(0,H,0)],0.36,0.045);
        end;
      slBollard:
        if Lens then Tube(Result,[Vector3(0,0.69,0),Vector3(0,0.87,0)],0.092,0.092)
        else begin
          Tube(Result,[Vector3(0,0,0),Vector3(0,0.69,0)],0.10,0.10);
          Tube(Result,[Vector3(0,0.87,0),Vector3(0,H,0)],0.12,0.11);
        end;
    end;
    Result.MakeWindingMatchNormals;
  except Result.Free;raise end;
end;
end.
