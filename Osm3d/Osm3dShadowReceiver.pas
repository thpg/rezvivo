unit Osm3dShadowReceiver;

{$mode objfpc}{$H+}

interface

uses Math, CastleVectors;

const
  SHADOW_MAX_REACH = 200.0;

type
  TShadowGroundTriangle = record
    A, B, C: TVector3;
  end;
  TShadowGroundTriangles = array of TShadowGroundTriangle;

  { Worker-local height raster of the actual receiving mesh. No scene pointers,
    GL access or terrain queries from the render thread. Shared by both masks. }
  TShadowReceiverRaster = class
  private
    FHeights: array of Single;
    FBlockMin, FBlockMax: array of Single;
    FBlocksX, FBlocksZ: Integer;
    FOrigin, FSize: TVector2;
    FWidth, FHeight: Integer;
    FMinY, FMaxY: Single;
    FCancel: PBoolean;
    procedure AddGround(const T: TShadowGroundTriangle);
  public
    constructor Create(const Ground: TShadowGroundTriangles;
      const Origin, Size: TVector2; W, H: Integer; Cancel: PBoolean);
    function GroundAt(Index: Integer; out Y: Single): Boolean; inline;
    function Cancelled: Boolean; inline;
    function HeightRange(MinX,MinZ,MaxX,MaxZ: Single; const Slope: TVector2;
      out LoY,HiY: Single): Boolean;
    procedure PixelBounds(MinX, MinZ, MaxX, MaxZ: Single;
      out X0, Z0, X1, Z1: Integer);
    procedure CastTriangle(const A, B, C: TVector3;
      const SunSlope: TVector2; Mask: PByte);
    property MinY: Single read FMinY;
    property MaxY: Single read FMaxY;
  end;

implementation

uses Osm3dTreeShadow;

constructor TShadowReceiverRaster.Create(const Ground: TShadowGroundTriangles;
  const Origin, Size: TVector2; W, H: Integer; Cancel: PBoolean);
var I,X,Z,B: Integer;
begin
  inherited Create;
  FOrigin := Origin; FSize := Size; FWidth := W; FHeight := H;
  FCancel := Cancel; FMinY := 1e30; FMaxY := -1e30;
  if (W < 2) or (H < 2) or (Size.X <= 0) or (Size.Y <= 0) then Exit;
  SetLength(FHeights, W * H);
  for I := 0 to High(FHeights) do FHeights[I] := -1e30;
  for I := 0 to High(Ground) do
  begin
    if Cancelled then Exit;
    AddGround(Ground[I]);
  end;
  FBlocksX := (W+63) div 64; FBlocksZ := (H+63) div 64;
  SetLength(FBlockMin,FBlocksX*FBlocksZ); SetLength(FBlockMax,Length(FBlockMin));
  for I:=0 to High(FBlockMin) do begin FBlockMin[I]:=1e30; FBlockMax[I]:=-1e30 end;
  for Z:=0 to H-1 do
  begin
    if ((Z and 31)=0) and Cancelled then Exit;
    for X:=0 to W-1 do
    begin
      I:=Z*W+X;
      if FHeights[I]<-1e29 then Continue;
      B:=(Z div 64)*FBlocksX+X div 64;
      FBlockMin[B]:=Min(FBlockMin[B],FHeights[I]);
      FBlockMax[B]:=Max(FBlockMax[B],FHeights[I]);
    end;
  end;
end;

function TShadowReceiverRaster.HeightRange(MinX,MinZ,MaxX,MaxZ: Single;
  const Slope: TVector2; out LoY,HiY: Single): Boolean;
var X0,Z0,X1,Z1,X,Z,B: Integer; L,DX,DZ: Single;
begin
  LoY:=1e30; HiY:=-1e30;
  if (FBlocksX=0) or Cancelled then Exit(False);
  L:=Sqrt(Sqr(Slope.X)+Sqr(Slope.Y));
  if L>1e-6 then
  begin
    DX:=-Slope.X/L*SHADOW_MAX_REACH; DZ:=-Slope.Y/L*SHADOW_MAX_REACH;
    MinX:=MinX+Min(0,DX); MaxX:=MaxX+Max(0,DX);
    MinZ:=MinZ+Min(0,DZ); MaxZ:=MaxZ+Max(0,DZ);
  end;
  PixelBounds(MinX,MinZ,MaxX,MaxZ,X0,Z0,X1,Z1);
  if (X0>X1) or (Z0>Z1) then Exit(False);
  for Z:=Z0 div 64 to Z1 div 64 do for X:=X0 div 64 to X1 div 64 do
  begin
    B:=Z*FBlocksX+X; LoY:=Min(LoY,FBlockMin[B]); HiY:=Max(HiY,FBlockMax[B]);
  end;
  Result:=LoY<=HiY;
end;

function TShadowReceiverRaster.Cancelled: Boolean;
begin
  Result := (FCancel <> nil) and FCancel^;
end;

function TShadowReceiverRaster.GroundAt(Index: Integer; out Y: Single): Boolean;
begin
  Y := FHeights[Index];
  Result := Y > -1e29;
end;

procedure TShadowReceiverRaster.PixelBounds(MinX, MinZ, MaxX, MaxZ: Single;
  out X0, Z0, X1, Z1: Integer);
begin
  if (MaxX < FOrigin.X) or (MaxZ < FOrigin.Y) or
     (MinX > FOrigin.X + FSize.X) or (MinZ > FOrigin.Y + FSize.Y) then
  begin X0 := 1; X1 := 0; Z0 := 1; Z1 := 0; Exit; end;
  X0 := Floor(EnsureRange((MinX-FOrigin.X)/FSize.X, 0.0, 1.0)*(FWidth-1));
  X1 := Ceil (EnsureRange((MaxX-FOrigin.X)/FSize.X, 0.0, 1.0)*(FWidth-1));
  Z0 := Floor(EnsureRange((MinZ-FOrigin.Y)/FSize.Y, 0.0, 1.0)*(FHeight-1));
  Z1 := Ceil (EnsureRange((MaxZ-FOrigin.Y)/FSize.Y, 0.0, 1.0)*(FHeight-1));
end;

procedure TShadowReceiverRaster.AddGround(const T: TShadowGroundTriangle);
var
  X, Z, X0, Z0, X1, Z1, Idx: Integer;
  AX, AZ, BX, BZ, Den, U, V, PX, PZ, Y: Double;
begin
  AX := T.A.X-T.C.X; AZ := T.A.Z-T.C.Z;
  BX := T.B.X-T.C.X; BZ := T.B.Z-T.C.Z;
  Den := AX*BZ-AZ*BX;
  if Abs(Den) < 1e-10 then Exit; { vertical skirts are not receivers }
  PixelBounds(Min(T.A.X, Min(T.B.X,T.C.X)), Min(T.A.Z,Min(T.B.Z,T.C.Z)),
    Max(T.A.X,Max(T.B.X,T.C.X)), Max(T.A.Z,Max(T.B.Z,T.C.Z)), X0,Z0,X1,Z1);
  Den := 1/Den;
  for Z := Z0 to Z1 do
  begin
    if ((Z and 31)=0) and Cancelled then Exit;
    PZ := FOrigin.Y + Z/(FHeight-1)*FSize.Y - T.C.Z;
    for X := X0 to X1 do
    begin
      PX := FOrigin.X + X/(FWidth-1)*FSize.X - T.C.X;
      U := (PX*BZ-PZ*BX)*Den;
      V := (AX*PZ-AZ*PX)*Den;
      if (U < -1e-6) or (V < -1e-6) or (U+V > 1.000001) then Continue;
      Y := T.C.Y + U*(T.A.Y-T.C.Y) + V*(T.B.Y-T.C.Y);
      Idx := Z*FWidth+X;
      if Y > FHeights[Idx] then FHeights[Idx] := Y;
      FMinY := Min(FMinY,Y); FMaxY := Max(FMaxY,Y);
    end;
  end;
end;

procedure TShadowReceiverRaster.CastTriangle(const A, B, C: TVector3;
  const SunSlope: TVector2; Mask: PByte);
var
  X,Z,X0,Z0,X1,Z1,Idx,Intensity: Integer;
  AX,AZ,BX,BZ,Den,U,V,WX,WZ,GY,Gap,RayLength: Double;
  Ux,Uz,Uy,Vx,Vz,Vy,Sl: Double;
  GX,LoX,LoZ,HiX,HiZ,DX0,DX1,DZ0,DZ1,LowY,HighY: Single;
begin
  if (FMinY > FMaxY) or (Mask=nil) then Exit;
  if not HeightRange(Min(A.X,Min(B.X,C.X)),Min(A.Z,Min(B.Z,C.Z)),
    Max(A.X,Max(B.X,C.X)),Max(A.Z,Max(B.Z,C.Z)),SunSlope,LowY,HighY) then Exit;
  HighY:=Min(HighY,Max(A.Y,Max(B.Y,C.Y)));
  if LowY>HighY then Exit;
  { Light-plane barycentrics, relative to C to retain precision far from the
    session origin. At each texel use its receiving Y, not a wall-base datum. }
  AX := A.X-C.X-SunSlope.X*(A.Y-C.Y);
  AZ := A.Z-C.Z-SunSlope.Y*(A.Y-C.Y);
  BX := B.X-C.X-SunSlope.X*(B.Y-C.Y);
  BZ := B.Z-C.Z-SunSlope.Y*(B.Y-C.Y);
  Den := AX*BZ-AZ*BX;
  if Abs(Den)<1e-10 then Exit;
  Den := 1/Den;
  Ux := BZ*Den; Uz := -BX*Den; Uy := -Ux*SunSlope.X-Uz*SunSlope.Y;
  Vx := -AZ*Den; Vz := AX*Den; Vy := -Vx*SunSlope.X-Vz*SunSlope.Y;
  LoX := Min(0,Min(AX,BX))+C.X; HiX := Max(0,Max(AX,BX))+C.X;
  LoZ := Min(0,Min(AZ,BZ))+C.Z; HiZ := Max(0,Max(AZ,BZ))+C.Z;
  DX0 := SunSlope.X*(LowY-C.Y); DX1 := SunSlope.X*(HighY-C.Y);
  DZ0 := SunSlope.Y*(LowY-C.Y); DZ1 := SunSlope.Y*(HighY-C.Y);
  PixelBounds(LoX+Min(DX0,DX1),LoZ+Min(DZ0,DZ1),
    HiX+Max(DX0,DX1),HiZ+Max(DZ0,DZ1),X0,Z0,X1,Z1);
  Sl := Sqrt(Sqr(SunSlope.X)+Sqr(SunSlope.Y));
  for Z := Z0 to Z1 do
  begin
    if ((Z and 31)=0) and Cancelled then Exit;
    WZ := FOrigin.Y + Z/(FHeight-1)*FSize.Y-C.Z;
    for X := X0 to X1 do
    begin
      Idx := Z*FWidth+X;
      if not GroundAt(Idx,GX) then Continue;
      GY := GX-C.Y;
      WX := FOrigin.X + X/(FWidth-1)*FSize.X-C.X;
      U := Ux*WX+Uz*WZ+Uy*GY;
      V := Vx*WX+Vz*WZ+Vy*GY;
      if (U < -1e-6) or (V < -1e-6) or (U+V > 1.000001) then Continue;
      Gap := U*(A.Y-C.Y)+V*(B.Y-C.Y)-GY;
      if Gap < 0.01 then Continue; { underground foundations cannot cast up }
      RayLength := Gap*Sl;
      if RayLength > SHADOW_MAX_REACH then Continue;
      Intensity := ShadowIntensityFor(RayLength);
      if Intensity > Mask[Idx] then Mask[Idx] := Intensity;
    end;
  end;
end;

end.
