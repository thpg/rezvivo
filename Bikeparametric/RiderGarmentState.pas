unit RiderGarmentState;
{$mode objfpc}{$H+}{$Q-}{$R-}
{ Persistent cloth layout. Pure numeric preparation, no scene or GL access.
  A garment has its own ease and history; neither camera nor frame time seeds
  its folds. This is a reduced cloth model, not a full collision solver. }
interface
uses Math, SysUtils, fpjson, RiderBodyParameters;
const GarmentFoldCount=64;
  GarmentPanelCircumference=0.90; { canonical material metres, periodic seam }
  GarmentAtlasWidth=512;GarmentAtlasHeight=384;
type
  TRiderGarmentParameters=record
    Seed,Revision:Cardinal;
    Ease,LengthEase:Single; { -1 tight/short, 0 fitted, +1 roomy/long }
    Adjusted:Boolean;
  end;
  TGarmentFold=record
    X,Y,Slope,Curve,Width,Length,Height:Single;
    Broad:Boolean; { low-frequency geometry or residual normal detail }
  end;
  TGarmentRecipe=array[0..GarmentFoldCount-1]of TGarmentFold;
  TGarmentHeights=array of Single;
function DefaultRiderGarment(Seed:Cardinal=1):TRiderGarmentParameters;
function NormalizeRiderGarment(const P:TRiderGarmentParameters):TRiderGarmentParameters;
function SameRiderGarment(const A,B:TRiderGarmentParameters):Boolean;
function RiderGarmentSeed(const Body:TRiderBodyParameters):Cardinal;
function ReadRiderGarment(O:TJSONObject;const Default:TRiderGarmentParameters):TRiderGarmentParameters;
function WriteRiderGarment(const P:TRiderGarmentParameters):TJSONObject;
procedure PrepareGarmentRecipe(const Params:TRiderGarmentParameters;out Recipe:TGarmentRecipe);
procedure GarmentHeight(const Recipe:TGarmentRecipe;X,Y:Single;out Broad,Fine:Single);
procedure BakeGarmentHeight(const Recipe:TGarmentRecipe;out Broad,Fine:TGarmentHeights);
function GarmentSmooth(Value:Single):Single;
implementation
function Hash(Value:Cardinal):Cardinal;inline;
begin Value:=(Value xor(Value shr 16))*$7feb352d;Value:=(Value xor(Value shr 15))*$846ca68b;Result:=Value xor(Value shr 16)end;
function GarmentSmooth(Value:Single):Single;
begin Value:=EnsureRange(Value,0,1);Result:=Value*Value*(3-2*Value)end;
function DefaultRiderGarment(Seed:Cardinal):TRiderGarmentParameters;
begin Result:=Default(TRiderGarmentParameters);Result.Seed:=Seed;Result.Ease:=0.15 end;
function NormalizeRiderGarment(const P:TRiderGarmentParameters):TRiderGarmentParameters;
begin
  Result:=P;
  if IsNan(P.Ease)or IsInfinite(P.Ease)then Result.Ease:=0;
  if IsNan(P.LengthEase)or IsInfinite(P.LengthEase)then Result.LengthEase:=0;
  Result.Ease:=EnsureRange(Result.Ease,-1,1);Result.LengthEase:=EnsureRange(Result.LengthEase,-1,1);
end;
function SameRiderGarment(const A,B:TRiderGarmentParameters):Boolean;
begin
  Result:=(A.Seed=B.Seed)and(A.Revision=B.Revision)and(A.Ease=B.Ease)and
    (A.LengthEase=B.LengthEase)and(A.Adjusted=B.Adjusted);
end;
function RiderGarmentSeed(const Body:TRiderBodyParameters):Cardinal;
var P:TRiderBodyParameters;
begin
  P:=NormalizeRiderBody(Body);
  Result:=Hash(Cardinal(Round(P.HeightCm*100)) xor Hash(Cardinal(Round(P.WeightKg*100))) xor
    Hash(Cardinal(Round(P.Sex*10000))) xor Hash(Cardinal(Round(P.Composition*10000))));
end;
function ReadRiderGarment(O:TJSONObject;const Default:TRiderGarmentParameters):TRiderGarmentParameters;
begin
  Result:=Default;
  if O<>nil then begin
    Result.Seed:=Cardinal(O.Get('seed',Int64(Result.Seed)));
    Result.Revision:=Cardinal(O.Get('revision',Int64(Result.Revision)));
    Result.Ease:=O.Get('ease',Double(Result.Ease));Result.LengthEase:=O.Get('length_ease',Double(Result.LengthEase));
    Result.Adjusted:=O.Get('adjusted',Result.Adjusted);
  end;
  Result:=NormalizeRiderGarment(Result);
end;
function WriteRiderGarment(const P:TRiderGarmentParameters):TJSONObject;
var V:TRiderGarmentParameters;
begin
  V:=NormalizeRiderGarment(P);Result:=TJSONObject.Create;
  Result.Add('seed',Int64(V.Seed));Result.Add('revision',Int64(V.Revision));
  Result.Add('ease',Double(V.Ease));Result.Add('length_ease',Double(V.LengthEase));Result.Add('adjusted',V.Adjusted);
end;
procedure PrepareGarmentRecipe(const Params:TRiderGarmentParameters;out Recipe:TGarmentRecipe);
var P:TRiderGarmentParameters;State:Cardinal;I,Group,Strand:Integer;Side,T,Jitter:Single;
  function Rand:Single;inline;
  begin State:=Hash(State+$9e3779b9);Result:=(State and $ffffff)/16777215 end;
begin
  P:=NormalizeRiderGarment(Params);
  FillChar(Recipe,SizeOf(Recipe),0);
  for I:=0 to High(Recipe)do with Recipe[I]do begin
    State:=Hash(P.Seed xor Hash(Cardinal(I+1)*7919));
    Group:=I div 16;Strand:=(I mod 16)div 2;T:=(Strand+0.8*(Rand-0.5))/7;
    { Pattern construction, not 64 independent random bumps. Two underarm
      fans, side-waist compression, pocket gathers and short front-hem folds.
      The smooth upper back and stretched sleeve remain deliberately clear. }
    if Group<>0 then State:=Hash(State xor Hash(P.Revision+17));
    Side:=1;if I mod 2=0 then Side:=-1;Jitter:=Rand-0.5;
    Broad:=(Group<2)and(Strand mod 3=0);
    case Group of
      0:begin X:=Side*(0.230+0.035*T);Y:=1.325-0.125*T;
        Slope:=Side*(0.30+0.60*T);Length:=0.045+0.020*T end;
      1:begin X:=Side*(0.250+0.018*Jitter);Y:=1.060+0.137*T;
        Slope:=Side*(0.18+0.25*T);Length:=0.075-0.020*T end;
      2:begin X:=Side*(0.335+0.065*T);Y:=1.055+0.110*T;
        Slope:=Side*(-0.70+1.20*T);Length:=0.025+0.040*Rand end;
      else begin X:=Side*(0.055+0.080*T);Y:=1.055+0.080*T;
        Slope:=Side*(-0.16-0.26*T);Length:=0.037+0.020*Rand end;
    end;
    X:=X+Side*Jitter*0.018;Y:=Y+(Rand-0.5)*0.012+P.LengthEase*0.008;
    Slope:=Slope+(Rand-0.5)*0.40;
    Curve:=(Rand-0.5)*5.0;Length:=Length*(0.75+0.45*Rand);
    if Broad then begin Width:=0.012+Rand*0.006;Height:=0.0022+Rand*0.0018 end
    else begin Width:=0.0055+Rand*0.0035;Height:=0.0014+Rand*0.0015 end;
    { Ease is handled ONCE by strain at runtime, not again in atlas height. }
    if P.Adjusted and(Group<>0)then begin
      Height:=Height*(0.38+0.62*GarmentSmooth((Y-1.14)/0.10));
      Y:=Y-0.008;
    end;
  end;
end;
procedure GarmentHeight(const Recipe:TGarmentRecipe;X,Y:Single;out Broad,Fine:Single);
var I:Integer;U,V,Along,H,Seam,Sewn:Single;F:TGarmentFold;
begin
  Broad:=0;Fine:=0;
  Seam:=GarmentSmooth((Y-1.005)/0.035)*GarmentSmooth((1.455-Y)/0.07);
  if Seam<=0 then Exit;
  for I:=0 to High(Recipe)do begin
    F:=Recipe[I];U:=X-F.X;
    U:=U-GarmentPanelCircumference*Floor(U/GarmentPanelCircumference+0.5);
    Along:=U/F.Length;
    if Abs(Along)>2.5 then Continue;
    V:=(Y-F.Y-F.Slope*U-F.Curve*U*U)/F.Width;
    if(V< -4)or(V>5)then Continue;
    { Outward buckling above the support surface. No negative broad trough
      can push the jersey through its own body/pocket attachments. }
    H:=F.Height*Exp(-2*Along*Along)*Exp(-0.5*V*V)*Seam;
    if F.Broad then Broad:=Broad+H
    else Fine:=Fine+H-F.Height*Exp(-2*Along*Along-0.5*Sqr(V-1.65))*0.42*Seam;
  end;
  { The three sewn rear pockets span |s| >= .311 and y=1.026..1.190
    in the shared pattern. Their carrier and outer layer use different
    triangulations. Keep their common support shell smooth; transfer its
    unresolved relief to the normal band, preserving TOTAL height exactly.
    Free side panels retain geometric buckling. This is a band split at a
    sewn constraint, not a second wrinkle painted over the same height. }
  U:=X-GarmentPanelCircumference*Floor(X/GarmentPanelCircumference+0.5);
  Sewn:=GarmentSmooth((Abs(U)-0.285)/0.025)*GarmentSmooth((Y-1.005)/0.020)*
    GarmentSmooth((1.225-Y)/0.035);
  Fine:=Fine+Broad*Sewn;Broad:=Broad*(1-Sewn);
end;
procedure BakeGarmentHeight(const Recipe:TGarmentRecipe;out Broad,Fine:TGarmentHeights);
const W=GarmentAtlasWidth;H=GarmentAtlasHeight;
var F:TGarmentFold;I,X,Y,K,X0,X1,Y0,Y1:Integer;PX,PY,U,V,Along,Envelope,Value,Seam,Sewn:Single;
begin
  { Rasterize each curve only over its footprint. Doubling atlas resolution
    must not turn bot creation into W*H*FoldCount exponential evaluations. }
  SetLength(Broad,W*H);SetLength(Fine,W*H);
  for I:=0 to High(Recipe)do begin
    F:=Recipe[I];
    X0:=Floor((F.X-2.5*F.Length)/GarmentPanelCircumference*W+W*0.5);
    X1:=Ceil((F.X+2.5*F.Length)/GarmentPanelCircumference*W+W*0.5);
    for X:=X0 to X1 do begin
      PX:=((X+0.5)/W-0.5)*GarmentPanelCircumference;U:=PX-F.X;Along:=U/F.Length;
      if Abs(Along)>2.5 then Continue;
      Envelope:=F.Height*Exp(-2*Along*Along);
      PY:=F.Y+F.Slope*U+F.Curve*U*U;
      Y0:=Max(0,Floor((PY-4*F.Width-1)/0.48*H));
      Y1:=Min(H-1,Ceil((PY+5*F.Width-1)/0.48*H));
      for Y:=Y0 to Y1 do begin
        V:=(1+(Y+0.5)/H*0.48-PY)/F.Width;
        if(V< -4)or(V>5)then Continue;
        Value:=Envelope*Exp(-0.5*V*V);
        K:=Y*W+((X mod W)+W)mod W;
        if F.Broad then Broad[K]:=Broad[K]+Value
        else Fine[K]:=Fine[K]+Value-Envelope*Exp(-0.5*Sqr(V-1.65))*0.42;
      end;
    end;
  end;
  for Y:=0 to H-1 do begin
    PY:=1+(Y+0.5)/H*0.48;
    Seam:=GarmentSmooth((PY-1.005)/0.035)*GarmentSmooth((1.455-PY)/0.07);
    for X:=0 to W-1 do begin
      PX:=((X+0.5)/W-0.5)*GarmentPanelCircumference;K:=Y*W+X;
      Sewn:=GarmentSmooth((Abs(PX)-0.285)/0.025)*GarmentSmooth((PY-1.005)/0.020)*GarmentSmooth((1.225-PY)/0.035);
      Broad[K]:=Broad[K]*Seam;Fine[K]:=Fine[K]*Seam+Broad[K]*Sewn;
      Broad[K]:=Broad[K]*(1-Sewn);
    end;
  end;
end;
end.
