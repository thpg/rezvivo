unit TreeFruits;
{$mode objfpc}{$H+}
interface
uses TreeModel;
procedure GenerateTreeFruits(var Data:TTreeData);
function FruitClusterMembers(Kind:TTreeFruitKind):Integer;
implementation
uses Math,TreeMath;
function FruitClusterMembers(Kind:TTreeFruitKind):Integer;
begin
  case Kind of
    tfRowan:Result:=36;
    tfHawthorn:Result:=7;
    tfBirdCherry:Result:=12;
    tfJuniper:Result:=3;
    else Result:=1;
  end;
end;
procedure GenerateTreeFruits(var Data:TTreeData);
var I,J,N,Count,Offset,Written,NextCandidate:Integer;
  F,Item:TTreeFruit;B:TTreeBranch;P:TTreeParams;T,Size,Extent:Single;
  C:TTreeVec3;
begin
  Data.Fruits:=nil;P:=Data.Params;
  if not HasTreeFruit(P.Species) or (P.Maturity<0.18) then Exit;
  F:=Default(TTreeFruit);F.Kind:=TreeFruitKind(P.TypeCode);
  F.Radius:=0.037;F.HalfLength:=0.035;C:=Vec(0.78,0.12,0.035);
  case F.Kind of
    tfPear:begin F.Radius:=0.034;F.HalfLength:=0.050;C:=Vec(0.64,0.70,0.12) end;
    tfCherry:begin F.Radius:=0.012;F.HalfLength:=0.012;C:=Vec(0.56,0.025,0.045) end;
    tfPlum:begin F.Radius:=0.021;F.HalfLength:=0.029;C:=Vec(0.23,0.15,0.39) end;
    tfApricot:begin F.Radius:=0.024;F.HalfLength:=0.025;C:=Vec(0.95,0.51,0.12) end;
    tfPeach:begin F.Radius:=0.035;F.HalfLength:=0.034;C:=Vec(0.95,0.42,0.18) end;
    tfHawthorn:begin F.Radius:=0.005;F.HalfLength:=0.005;C:=Vec(0.65,0.06,0.035) end;
    tfBirdCherry:begin F.Radius:=0.0045;F.HalfLength:=0.0045;C:=Vec(0.08,0.04,0.09) end;
    tfWalnut:begin F.Radius:=0.022;F.HalfLength:=0.027;C:=Vec(0.44,0.53,0.16) end;
    tfChestnut:begin F.Radius:=0.026;F.HalfLength:=0.026;C:=Vec(0.50,0.56,0.19) end;
    tfCitrus:begin F.Radius:=0.035;F.HalfLength:=0.035;C:=Vec(1.0,0.54,0.035) end;
    tfOlive:begin F.Radius:=0.008;F.HalfLength:=0.012;C:=Vec(0.20,0.25,0.075) end;
    tfRowan:begin F.Radius:=0.00825;F.HalfLength:=0.00825;C:=Vec(0.88,0.08,0.035) end;
    tfJuniper:begin F.Radius:=0.0045;F.HalfLength:=0.0045;C:=Vec(0.27,0.35,0.46) end;
    tfCone:begin
      F.Radius:=0.023;F.HalfLength:=0.035;C:=Vec(0.39,0.24,0.105);
      case P.Species of
        tsSpruce:begin F.Radius:=0.020;F.HalfLength:=0.067;C:=Vec(0.49,0.31,0.16) end;
        tsMountainPine:begin F.Radius:=0.016;F.HalfLength:=0.023 end;
        tsLarch:begin F.Radius:=0.013;F.HalfLength:=0.018 end;
      end;
    end;
  end;
  F.Color:=ColorToLinear(C);
  N:=0;
  for I:=1 to High(Data.Branches) do
    if Data.Branches[I].Depth=P.MaxDepth then Inc(N);
  if N=0 then Exit; { incomplete LOD never grows fruit in mid-air }
  Count:=Min(N,Round((28+P.Height*2)*Clamp((P.Maturity-0.18)*2.5,0,1)));
  Count:=Min(64,Count);
  if F.Kind=tfRowan then
    Count:=Min(N,Min(240,Round((36+P.Height*P.Height*2.2)*Clamp((P.Maturity-0.18)*2.5,0,1))));
  SetLength(Data.Fruits,Count);
  if Count=0 then Exit;
  Offset:=Trunc(HashUnit(P.Seed,9301)*Max(1,N div Count));
  Written:=0;J:=0;NextCandidate:=Offset;
  for I:=1 to High(Data.Branches) do begin
    if Data.Branches[I].Depth<>P.MaxDepth then Continue;
    Inc(J);
    if J-1<>NextCandidate then Continue;
    { Even coverage of the complete crown, independent of camera or season. }
    B:=Data.Branches[I];
    F.Phase:=HashUnit(B.ID,9302);T:=0.78+HashUnit(B.ID,9303)*0.20;
    if F.Kind=tfRowan then T:=0.96+HashUnit(B.ID,9303)*0.04;
    Size:=0.85+HashUnit(B.ID,9304)*0.30;
    Item:=F;Item.Radius:=F.Radius*Size;Item.HalfLength:=F.HalfLength*Size;
    Item.Axis:=Normalize(Vec((HashUnit(B.ID,9305)-0.5)*0.35,1,(HashUnit(B.ID,9306)-0.5)*0.35));
    if P.Species=tsLarch then Item.Axis:=Scale(Item.Axis,-1);
    Extent:=Item.HalfLength;
    if FruitClusterMembers(Item.Kind)>1 then Extent:=Extent+Item.Radius*7;
    Item.Center:=Sub(Curve(B.Start,B.Control,B.Tip,T),Scale(Item.Axis,Extent+0.018));
    { Rowan corymbs sit close to the tip; retain the larger conservative bounds. }
    if Item.Kind=tfRowan then Item.Center:=Add(Item.Center,Scale(Item.Axis,Item.Radius*4));
    Item.Color:=Scale(F.Color,0.83+F.Phase*0.28);
    Data.Fruits[Written]:=Item;
    Extent:=Max(Extent,Item.Radius)+0.025;
    Data.BoundsMin.X:=Min(Data.BoundsMin.X,Item.Center.X-Extent);
    Data.BoundsMin.Y:=Min(Data.BoundsMin.Y,Item.Center.Y-Extent);
    Data.BoundsMin.Z:=Min(Data.BoundsMin.Z,Item.Center.Z-Extent);
    Data.BoundsMax.X:=Max(Data.BoundsMax.X,Item.Center.X+Extent);
    Data.BoundsMax.Y:=Max(Data.BoundsMax.Y,Item.Center.Y+Extent);
    Data.BoundsMax.Z:=Max(Data.BoundsMax.Z,Item.Center.Z+Extent);
    Data.Fingerprint:=Hash32(Data.Fingerprint xor HashChild(B.ID,9307+Ord(Item.Kind)));
    Inc(Written);
    if Written=Count then Break;
    NextCandidate:=Int64(Written)*N div Count+Offset;
  end;
end;
end.
