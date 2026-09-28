unit BikeParametric_Drivetrain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, CastleUtils, CastleVectors, CastleURIUtils,
  X3DNodes, fpjson,
  BikeParametric, BikeParametric_Crankset;

type
  TChainPath = array of TVector3;

  TDrivetrainComponent = class(TBikeComponent)
  private
    FCassetteSprocketCount: Integer;
    FCassetteWidth:         Single;
    FCassetteTexturePath:   string;
    { drive-side cassette plane, derived from the frame's rear dropout spacing }
    function CassetteZ(M: Single; out ADropoutZ: Single): Single;
  public
    { Arrays stay as public fields — RTTI can't publish dynamic-array-of-primitive
      properties reliably across FPC versions, so we serialize them manually in
      ParamsToJSON/FromJSON below. }
    CassetteSprockets: array of Single;   { mm, pitch radius of each sprocket }
    CassetteTeeth:     array of Integer;  { tooth count per sprocket }

    constructor Create; override;
    class function ComponentName: string; override;
    procedure ApplyPreset(const APreset: string); override;
    procedure ComputeBones(Skel: TBikeSkeleton); override;
    procedure BuildGeometry(Ctx: TBikeBuildContext); override;
    function ChainPath(Skel: TBikeSkeleton): TChainPath;
    procedure ParamsToJSON(Obj: TJSONObject); override;
    procedure ParamsFromJSON(Obj: TJSONObject); override;
  published
    property CassetteSprocketCount: Integer read FCassetteSprocketCount write FCassetteSprocketCount;
    property CassetteWidth:         Single  read FCassetteWidth         write FCassetteWidth;
    property CassetteTexturePath:   string  read FCassetteTexturePath   write FCassetteTexturePath;
  end;

implementation

uses
  DebugLog, BikeParametric_Frame, BikeGfxUtil;

const
  { Road cassette defaults — единый источник для Create и fallback'ов
    ComputeBones (ApplyPreset 'mtb' задаёт свой набор). }
  DEF_CASSETTE_COUNT = 5;
  DEF_CASSETTE_SPROCKETS: array[0..DEF_CASSETTE_COUNT-1] of Single = (22, 28, 35, 44, 56);
  DEF_CASSETTE_TEETH: array[0..DEF_CASSETTE_COUNT-1] of Integer = (11, 14, 17, 22, 28);
  DEF_CASSETTE_WIDTH = 35;   { mm }
  { derailleur plastic (spec + shininess), repeated per part }
  MECH_BODY_SPEC: TVector3 = (X: 0.25; Y: 0.25; Z: 0.3);
  MECH_BODY_SHININESS = 0.6;

class function TDrivetrainComponent.ComponentName: string; begin Result := 'Drivetrain'; end;

constructor TDrivetrainComponent.Create;
var I: Integer;
begin
  inherited Create;
  FCassetteSprocketCount := DEF_CASSETTE_COUNT;
  SetLength(CassetteSprockets, DEF_CASSETTE_COUNT);
  SetLength(CassetteTeeth, DEF_CASSETTE_COUNT);
  for I := 0 to DEF_CASSETTE_COUNT - 1 do
  begin
    CassetteSprockets[I] := DEF_CASSETTE_SPROCKETS[I];
    CassetteTeeth[I]     := DEF_CASSETTE_TEETH[I];
  end;
  FCassetteWidth := DEF_CASSETTE_WIDTH;
  FCassetteTexturePath := 'Cassette_Shimano_Dura_Ace.png';
end;

procedure TDrivetrainComponent.ApplyPreset(const APreset: string);
begin
  if SameText(APreset, 'mtb') then begin
    FCassetteSprocketCount := 5;
    SetLength(CassetteSprockets, 5);
    CassetteSprockets[0] := 22; CassetteSprockets[1] := 35;
    CassetteSprockets[2] := 50; CassetteSprockets[3] := 72;
    CassetteSprockets[4] := 104;
    SetLength(CassetteTeeth, 5);
    CassetteTeeth[0] := 10; CassetteTeeth[1] := 16;
    CassetteTeeth[2] := 24; CassetteTeeth[3] := 36;
    CassetteTeeth[4] := 52;
    FCassetteWidth := 45;
  end;
end;

{ ResolveTexURL now lives in the shared BikeGfxUtil unit (tag-parameterized). }

{ Drive-side cassette plane. Anchored to the frame's rear dropout so the
  smallest cog sits just inboard of the drive-side dropout face -- i.e. the
  cassette is INSIDE the rear triangle (real road chainline ~ 43.5 mm for a
  130 mm rear end with a 35 mm cassette). Also returns the dropout-face Z. }
function TDrivetrainComponent.CassetteZ(M: Single; out ADropoutZ: Single): Single;
var Fr: TFrameComponent; RearSp, CW: Single;
begin
  Fr := TFrameComponent(FindComponent(TFrameComponent));
  if Fr <> nil then RearSp := Fr.RearDropoutSpacing else RearSp := 130;
  if RearSp < 100 then RearSp := 130;
  ADropoutZ := (RearSp / 2) * M;            { drive-side dropout face }
  CW := CassetteWidth * M; if CW < 0.010 then CW := 0.035;
  { small cog ~4 mm inboard of the dropout; return the cassette CENTRE plane }
  Result := ADropoutZ - 0.004 - CW / 2;
end;

procedure TDrivetrainComponent.ComputeBones(Skel: TBikeSkeleton);
var QZ, M, RX, AY, DropZ, GuideDrop: Single; I: Integer;
begin
  M := Skel.MM;

  if CassetteSprocketCount < 1 then CassetteSprocketCount := DEF_CASSETTE_COUNT;
  CassetteSprocketCount := Min(CassetteSprocketCount, 32);
  { Preserve supplied gears and allocate the requested count, not always five.
    The editor may expose the first five entries even on a single-speed bike. }
  if Length(CassetteSprockets) < Max(CassetteSprocketCount, DEF_CASSETTE_COUNT) then
    SetLength(CassetteSprockets, Max(CassetteSprocketCount, DEF_CASSETTE_COUNT));
  if Length(CassetteTeeth) < Max(CassetteSprocketCount, DEF_CASSETTE_COUNT) then
    SetLength(CassetteTeeth, Max(CassetteSprocketCount, DEF_CASSETTE_COUNT));
  for I := 0 to CassetteSprocketCount - 1 do
  begin
    if IsNan(CassetteSprockets[I]) or IsInfinite(CassetteSprockets[I]) or
       (CassetteSprockets[I] < 10) then
    begin
      if I < DEF_CASSETTE_COUNT then
        CassetteSprockets[I] := DEF_CASSETTE_SPROCKETS[I]
      else CassetteSprockets[I] := CassetteSprockets[I-1] + 6;
    end;
    if CassetteTeeth[I] < 5 then
      CassetteTeeth[I] := Max(5, Round(2 * Pi * CassetteSprockets[I] / 12.7));
  end;
  if CassetteWidth < 10 then CassetteWidth := DEF_CASSETTE_WIDTH;

  { Cassette/derailleur sit on the drive side, just inboard of the rear dropout
    (real road chainline), derived from the frame's rear dropout spacing. }
  QZ := CassetteZ(M, DropZ) + CassetteWidth * M / 2; { selected outer cog }
  RX := Skel['rear_axle'].X; AY := Skel['rear_axle'].Y;
  { rear mech bolts to the hanger at the dropout; the cage swings inboard to the cogs }
  Skel.AddBone('deraill_pivot', Vector3(RX-0.005, AY-0.01, DropZ-0.003));
  { Leave room between the selected sprocket and the guide pulley. }
  GuideDrop := Max(0.045, CassetteSprockets[0]*M + 0.014 + 0.008);
  Skel.AddBone('jockey_upper', Vector3(RX-0.015, AY-GuideDrop, QZ));
  Skel.AddBone('jockey_lower', Vector3(RX-0.035, AY-GuideDrop-0.040, QZ));
end;

function TDrivetrainComponent.ChainPath(Skel: TBikeSkeleton): TChainPath;
const
  Winding: array[0..3] of Single = (1, 1, -1, 1);
var
  Centers, InPoint, OutPoint: array[0..3] of TVector3;
  Radii: array[0..3] of Single;
  Cr: TCranksetComponent;
  I, J, K, N, Steps: Integer;
  D, U, Normal, P: TVector3;
  Dist, DeltaR, H, A, B, Sweep, DropZ: Single;
  procedure AddPoint(const V: TVector3);
  begin
    if (N > 0) and ((Result[N-1] - V).Length < 0.000001) then Exit;
    if N = Length(Result) then SetLength(Result, N + 32);
    Result[N] := V;
    Inc(N);
  end;
begin
  Result := nil; N := 0;
  Centers[0] := Skel['bb'];
  Centers[1] := Skel['rear_axle'];
  Centers[2] := Skel['jockey_upper'];
  Centers[3] := Skel['jockey_lower'];
  Cr := TCranksetComponent(FindComponent(TCranksetComponent));
  if Cr <> nil then
  begin
    Centers[0].Z := (Cr.QFactorHalf + Cr.ChainringPlaneOffset) * Skel.MM;
    Radii[0] := Cr.ChainringPitchRadius * Skel.MM;
  end else begin
    Centers[0].Z := 60 * Skel.MM;
    Radii[0] := 100 * Skel.MM;
  end;
  Centers[1].Z := CassetteZ(Skel.MM, DropZ) + CassetteWidth * Skel.MM / 2;
  Radii[1] := CassetteSprockets[0] * Skel.MM;
  Radii[2] := 0.014; Radii[3] := 0.014;
  { One directed tangent for each span. Signed radii give the S bend through
    the guide/tension pulleys; all contacts lie on the same selected rear cog. }
  for I := 0 to 3 do
  begin
    J := (I+1) mod 4;
    D := Centers[J] - Centers[I]; D.Z := 0;
    Dist := D.Length;
    DeltaR := Winding[I]*Radii[I] - Winding[J]*Radii[J];
    if Dist <= Abs(DeltaR) + 0.000001 then Exit(nil);
    U := D / Dist;
    H := Sqrt(Max(0, 1 - Sqr(DeltaR/Dist)));
    Normal := U*(DeltaR/Dist) + Vector3(U.Y, -U.X, 0)*H;
    OutPoint[I] := Centers[I] + Normal*(Winding[I]*Radii[I]);
    InPoint[J] := Centers[J] + Normal*(Winding[J]*Radii[J]);
  end;
  for I := 0 to 3 do
  begin
    A := ArcTan2(InPoint[I].Y-Centers[I].Y, InPoint[I].X-Centers[I].X);
    B := ArcTan2(OutPoint[I].Y-Centers[I].Y, OutPoint[I].X-Centers[I].X);
    Sweep := (B-A)*Winding[I];
    while Sweep < 0 do Sweep := Sweep + 2*Pi;
    Steps := Max(1, Ceil(Sweep / (Pi/12)));
    AddPoint(InPoint[I]);
    for K := 1 to Steps-1 do
    begin
      B := A + Winding[I]*Sweep*K/Steps;
      P := Centers[I] + Vector3(Cos(B)*Radii[I], Sin(B)*Radii[I], 0);
      AddPoint(P);
    end;
    AddPoint(OutPoint[I]);
  end;
  AddPoint(Result[0]);
  SetLength(Result, N);
end;

procedure TDrivetrainComponent.BuildGeometry(Ctx: TBikeBuildContext);
var DL: Integer;
    { CassetteZ (с FindComponent(TFrameComponent) внутри) — один раз на билд;
      раньше дергался в ComputeBones + DoCassette + DoChain }
    CachedCasZ, CachedDropZ: Single;

  procedure DoCassette;

    { Build separate sprocket plates with a planar cassette texture. }
    procedure BuildCassetteMesh(const Center: TVector3; const TexPath: string);
    var
      Coord: TCoordinateNode;
      TC: TTextureCoordinateNode;
      IFS: TIndexedFaceSetNode;
      ImgTex: TImageTextureNode;
      Mat: TMaterialNode;
      App: TAppearanceNode;
      Shape: TShapeNode;
      Xf: TTransformNode;
      Segs, I, Cog, Ring, Base: Integer;
      Theta, CT, ST, Radius, OuterR, InnerR, Z, MaxR: Single;
    begin
      Segs := Ctx.LOD_TorusSeg;

      Coord := TCoordinateNode.Create;
      TC := TTextureCoordinateNode.Create;

      IFS := TIndexedFaceSetNode.Create;
      IFS.Coord := Coord;
      IFS.TexCoord := TC;
      IFS.Solid := False;
      IFS.CreaseAngle := 0;
      MaxR := 0.001;
      for Cog := 0 to CassetteSprocketCount - 1 do
        MaxR := Max(MaxR, CassetteSprockets[Cog] * Ctx.Skeleton.MM);
      for Cog := 0 to CassetteSprocketCount - 1 do
      begin
        OuterR := CassetteSprockets[Cog] * Ctx.Skeleton.MM;
        InnerR := Min(0.018, OuterR * 0.7);
        Z := CachedCasZ + CassetteWidth * Ctx.Skeleton.MM / 2;
        if CassetteSprocketCount > 1 then
          Z := Z - Cog * CassetteWidth * Ctx.Skeleton.MM / (CassetteSprocketCount - 1);
        Base := Coord.FdPoint.Items.Count;
        { Front annulus, tooth edge and rear annulus: an actual 1.6 mm plate.
          Planar UVs match the circular photo instead of wrapping it like a belt. }
        for Ring := 0 to 3 do
          for I := 0 to Segs do
          begin
            Theta := 2 * Pi * I / Segs;
            CT := Cos(Theta); ST := Sin(Theta);
            if (Ring = 0) or (Ring = 3) then Radius := InnerR else Radius := OuterR;
            Coord.FdPoint.Items.Add(Vector3(Center.X + Radius*CT,
              Center.Y + Radius*ST, Z + 0.0008 - Ord(Ring >= 2)*0.0016));
            TC.FdPoint.Items.Add(Vector2(0.5 + 0.49*Radius*CT/MaxR,
              0.5 + 0.49*Radius*ST/MaxR));
          end;
        for Ring := 0 to 2 do
          for I := 0 to Segs - 1 do
          begin
            IFS.FdCoordIndex.Items.Add(Base + Ring*(Segs+1) + I);
            IFS.FdCoordIndex.Items.Add(Base + (Ring+1)*(Segs+1) + I);
            IFS.FdCoordIndex.Items.Add(Base + (Ring+1)*(Segs+1) + I+1);
            IFS.FdCoordIndex.Items.Add(Base + Ring*(Segs+1) + I+1);
            IFS.FdCoordIndex.Items.Add(-1);
          end;
      end;

      ImgTex := TImageTextureNode.Create;
      ImgTex.SetUrl([TexPath]);  { TexPath is already a resolved URL }
      ImgTex.RepeatS := False;
      ImgTex.RepeatT := False;

      if Ctx.AccumActive then
      begin
        { батч: текстурированный конус кассеты — в текстурный бакет }
        Ctx.EmitBatchedTex(IFS, Coord, TC, ImgTex,
          Vector3(1, 1, 1), Vector3(0.4, 0.4, 0.4), 0.6, 0.0, TMatrix4.Identity);
        Exit;
      end;

      Mat := TMaterialNode.Create;
      Mat.DiffuseColor := Vector3(1, 1, 1);
      Mat.SpecularColor := Vector3(0.4, 0.4, 0.4);
      Mat.Shininess := 0.6;

      App := TAppearanceNode.Create;
      App.Material := Mat;
      App.Texture := ImgTex;

      Shape := TShapeNode.Create;
      Shape.Geometry := IFS;
      Shape.Appearance := App;

      Xf := TTransformNode.Create;
      Xf.AddChildren(Shape);
      Ctx.Add(Xf);
    end;

  var S: TBikeSkeleton; CC: TVector3;
      QZ, CW, SR, ZOff, Z, A: Single;
      I, J, ST: Integer;
      UseTex: Boolean;
      TexURL: string;
  begin
    S := Ctx.Skeleton;
    CC := Ctx.O(S['rear_axle']); QZ := CachedCasZ; CW := CassetteWidth*S.MM;

    TexURL := ResolveTexURL(CassetteTexturePath, '[Drivetrain] ');
    UseTex := TexURL <> '';

    { одна accum-сессия на всю кассету: раньше 2-3 сессии подряд к тому же
      родителю без не-batched вставок между ними }
    Ctx.BeginAccum(Ctx.Root);
    if UseTex then
    begin
      { Textured frustum cone from smallest to largest sprocket — в текстурный бакет }
      BuildCassetteMesh(CC, TexURL);
    end
    else
    begin
      { 3D geometry fallback — individual sprocket tori + teeth.
        батч: все звёзды/зубья/ступица — 1-2 меша вместо десятков Shape-нод }
      for I := 0 to CassetteSprocketCount-1 do begin
        SR := CassetteSprockets[I]*S.MM; ST := CassetteTeeth[I];
        ZOff := CW/2;
        if CassetteSprocketCount > 1 then
          ZOff := ZOff-I*CW/(CassetteSprocketCount-1);
        Z := QZ+ZOff;
        Ctx.Add(Ctx.MakeTorus(Vector3(CC.X,CC.Y,Z), SR, 0.002,
          Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0, Max(ST,16), 6));
        if DL >= 2 then
          for J := 0 to ST-1 do begin
            A := 2*Pi*J/ST;
            Ctx.Add(Ctx.MakeCylinder(
              Vector3(CC.X+Cos(A)*SR, CC.Y+Sin(A)*SR, Z),
              Vector3(CC.X+Cos(A)*(SR+0.004), CC.Y+Sin(A)*(SR+0.004), Z),
              0.0015, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
          end;
      end;
    end;
    { Hub cylinder — always }
    Ctx.Add(Ctx.MakeCylinder(
      Vector3(CC.X, CC.Y, QZ-CW/2-0.003),
      Vector3(CC.X, CC.Y, QZ+CW/2+0.003),
      0.018, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
    Ctx.EndAccum;
  end;

  procedure DoDerailleur;
  var S: TBikeSkeleton; PV, JU, JL: TVector3;
  begin
    S := Ctx.Skeleton;
    PV := Ctx.O(S['deraill_pivot']); JU := Ctx.O(S['jockey_upper']);
    JL := Ctx.O(S['jockey_lower']);
    { батч: весь переключатель — 1-2 меша вместо десятка Shape-нод }
    Ctx.BeginAccum(Ctx.Root);
    Ctx.Add(Ctx.MakeSphere(PV, 0.008, Ctx.Colors.Dark, Vector3(0.3,0.3,0.35), 0.7));
    Ctx.Add(Ctx.MakeCylinder(PV, JU, 0.005, Ctx.Colors.Dark, MECH_BODY_SPEC, MECH_BODY_SHININESS));
    { Cage plates — Med+ }
    if DL >= 1 then begin
      Ctx.Add(Ctx.MakeCylinder(JU+Vector3(0,0,0.005), JL+Vector3(0,0,0.005), 0.003,
        Ctx.Colors.Dark, MECH_BODY_SPEC, MECH_BODY_SHININESS));
      Ctx.Add(Ctx.MakeCylinder(JU+Vector3(0,0,-0.005), JL+Vector3(0,0,-0.005), 0.003,
        Ctx.Colors.Dark, MECH_BODY_SPEC, MECH_BODY_SHININESS));
    end;
    { Jockey wheels — Med+ }
    if DL >= 1 then begin
      Ctx.Add(Ctx.MakeTorus(JU, 0.014, 0.003, Ctx.Colors.Dark, Vector3(0.3,0.3,0.35), 0.5, 16, 6));
      Ctx.Add(Ctx.MakeTorus(JL, 0.014, 0.003, Ctx.Colors.Dark, Vector3(0.3,0.3,0.35), 0.5, 16, 6));
    end;
    { Jockey axle spheres — High+ }
    if DL >= 2 then begin
      Ctx.Add(Ctx.MakeSphere(JU, 0.004, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
      Ctx.Add(Ctx.MakeSphere(JL, 0.004, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
    end;
    Ctx.EndAccum;
  end;

  procedure DoChain;
    { Closed ribbon: 0 = normal in the chain plane, 1 = transverse width. }
    procedure BuildChainStrip(const Pts: array of TVector3; HalfW: Single; OffAxis: Integer);
    var
      Coord: TCoordinateNode;
      IFS: TIndexedFaceSetNode;
      Shape: TShapeNode;
      Xf: TTransformNode;
      N, VI: Integer;
      Pt, Tangent, Side, PrevTangent, NextTangent: TVector3;
      PrevI, NextI: Integer;
    begin
      N := Length(Pts);
      if N < 2 then Exit;
      Coord := TCoordinateNode.Create;
      for VI := 0 to N - 1 do begin
        Pt := Ctx.O(Pts[VI]);
        if OffAxis = 0 then begin
          PrevI := VI-1; if PrevI < 0 then PrevI := N-2;
          NextI := VI+1; if NextI >= N then NextI := 1;
          PrevTangent := Pts[VI] - Pts[PrevI]; PrevTangent.Z := 0;
          NextTangent := Pts[NextI] - Pts[VI]; NextTangent.Z := 0;
          PrevTangent := PrevTangent / Max(PrevTangent.Length, 0.000001);
          NextTangent := NextTangent / Max(NextTangent.Length, 0.000001);
          Tangent := PrevTangent + NextTangent;
          Side := Vector3(-Tangent.Y, Tangent.X, 0);
          Side := Side * (HalfW / Max(Side.Length, 0.000001));
          Coord.FdPoint.Items.Add(Pt - Side);
          Coord.FdPoint.Items.Add(Pt + Side);
        end else begin
          Coord.FdPoint.Items.Add(Vector3(Pt.X, Pt.Y, Pt.Z - HalfW));
          Coord.FdPoint.Items.Add(Vector3(Pt.X, Pt.Y, Pt.Z + HalfW));
        end;
      end;
      IFS := TIndexedFaceSetNode.Create;
      IFS.Coord := Coord; IFS.Solid := False;
      { одна сторона: Solid=False уже отключает backface culling, развёрнутый
        повтор стрипа — мёртвый дубль геометрии }
      for VI := 0 to N - 2 do begin
        IFS.FdCoordIndex.Items.Add(VI*2);
        IFS.FdCoordIndex.Items.Add(VI*2+1);
        IFS.FdCoordIndex.Items.Add((VI+1)*2+1);
        IFS.FdCoordIndex.Items.Add((VI+1)*2);
        IFS.FdCoordIndex.Items.Add(-1);
      end;
      if Ctx.AccumActive then
      begin
        { батч: стрип цепи в аккумулятор (crease 0, координаты уже object-space);
          Shape не создаём — EmitBatched забирает IFS+Coord на переработку }
        Ctx.EmitBatched(IFS, Coord, Ctx.Colors.Dark, Vector3(0.2,0.2,0.25),
          0.5, 0.0, TMatrix4.Identity);
        Exit;
      end;
      Shape := TShapeNode.Create;
      Shape.Geometry := IFS;
      Shape.Appearance := Ctx.MakeMaterial(Ctx.Colors.Dark, Vector3(0.2,0.2,0.25), 0.5);
      Xf := TTransformNode.Create;
      Xf.AddChildren(Shape);
      Ctx.Add(Xf);
    end;

  var
    Pts: TChainPath;
    I: Integer;
    P1, P2: TVector3;
  begin
    Pts := ChainPath(Ctx.Skeleton);
    if Length(Pts) < 2 then Exit;

    if DL >= 3 then begin
      { Ultra: cylinder per segment — батч: вся цепь в один меш }
      Ctx.BeginAccum(Ctx.Root);
      for I := 0 to High(Pts)-1 do begin
        P1 := Ctx.O(Pts[I]); P2 := Ctx.O(Pts[I+1]);
        if (P2-P1).Length > 0.001 then
          Ctx.Add(Ctx.MakeCylinder(P1, P2, 0.003, Ctx.Colors.Dark, Vector3(0.2,0.2,0.25), 0.5));
      end;
      Ctx.EndAccum;
    end else begin
      { High/Med/Low: side quad strip (always) — батч: оба стрипа в один меш }
      Ctx.BeginAccum(Ctx.Root);
      BuildChainStrip(Pts, 0.003, 0);
      { High: + top quad strip }
      if DL >= 2 then
        BuildChainStrip(Pts, 0.003, 1);
      Ctx.EndAccum;
    end;
  end;

begin
  DL := Ctx.DetailLevel;
  CachedCasZ := CassetteZ(Ctx.Skeleton.MM, CachedDropZ);
  DoCassette;
  if DL >= 1 then DoDerailleur;
  if DL >= 1 then DoChain;
end;

procedure TDrivetrainComponent.ParamsToJSON(Obj: TJSONObject);
var Arr: TJSONArray; I: Integer;
begin
  inherited ParamsToJSON(Obj);  { scalars — Count, Width, TexturePath }
  Arr := TJSONArray.Create;
  for I := 0 to High(CassetteSprockets) do
    Arr.Add(CreateJSON(Double(CassetteSprockets[I])));  { registry -> canonical float text }
  Obj.Add('CassetteSprockets', Arr);
  Arr := TJSONArray.Create;
  for I := 0 to High(CassetteTeeth) do
    Arr.Add(CassetteTeeth[I]);
  Obj.Add('CassetteTeeth', Arr);
end;

procedure TDrivetrainComponent.ParamsFromJSON(Obj: TJSONObject);
var Arr: TJSONArray; I: Integer;
begin
  inherited ParamsFromJSON(Obj);  { scalars — Count, Width, TexturePath }
  { Grow the array only if JSON has more entries than we already have; never
    shrink. This way a short or empty JSON array ("CassetteSprockets": [])
    doesn't destroy the defaults set in Create, and a longer-than-default
    JSON array is honored. Consumers like FillParamsEditor index [0..4]
    directly, so preserving at least the default length is required. }
  if Obj.Find('CassetteSprockets') is TJSONArray then
  begin
    Arr := Obj.Arrays['CassetteSprockets'];
    if Arr.Count > Length(CassetteSprockets) then
      SetLength(CassetteSprockets, Arr.Count);
    for I := 0 to Arr.Count-1 do
      CassetteSprockets[I] := Arr.Floats[I];
  end;
  if Obj.Find('CassetteTeeth') is TJSONArray then
  begin
    Arr := Obj.Arrays['CassetteTeeth'];
    if Arr.Count > Length(CassetteTeeth) then
      SetLength(CassetteTeeth, Arr.Count);
    for I := 0 to Arr.Count-1 do
      CassetteTeeth[I] := Arr.Integers[I];
  end;
end;

end.
