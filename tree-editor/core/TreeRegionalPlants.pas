unit TreeRegionalPlants;
{$mode objfpc}{$H+}
interface
uses TreeModel;
{ The same compact descriptors as ordinary trees: no per-instance CPU mesh.
  These plants have no recursively branching deciduous crown. }
function GenerateRegionalPlant(const P:TTreeParams; IncludeLeaves:Boolean):TTreeData;
implementation
uses Math,TreeMath;
function GenerateRegionalPlant(const P:TTreeParams; IncludeLeaves:Boolean):TTreeData;
var D:TTreeData;BC,LC,I,J,K,Q,N,Stems,Fronds,Parent,First,Last:Integer;
    A,T,H,R,L,W,Spread,TwigAngle:Single;Seed,TwigSeed:LongWord;
    Base,Top,Control,Tip,Dir,Side,At,EndPoint,Axis,TwigBase,TwigTip:TTreeVec3;
    Branch:TTreeBranch;Leaf:TTreeLeaf;
  procedure Bounds(const V:TTreeVec3;Radius:Single);
  begin
    D.BoundsMin.X:=Min(D.BoundsMin.X,V.X-Radius);D.BoundsMax.X:=Max(D.BoundsMax.X,V.X+Radius);
    D.BoundsMin.Y:=Min(D.BoundsMin.Y,V.Y-Radius);D.BoundsMax.Y:=Max(D.BoundsMax.Y,V.Y+Radius);
    D.BoundsMin.Z:=Min(D.BoundsMin.Z,V.Z-Radius);D.BoundsMax.Z:=Max(D.BoundsMax.Z,V.Z+Radius);
  end;
  procedure Fingerprint(V:Single);
  var Bits:LongWord;
  begin Move(V,Bits,4);D.Fingerprint:=Hash32(D.Fingerprint xor Bits);end;
  function Stem(const B,C,E:TTreeVec3;Radius,TipRadius:Single;AParent:Integer):Integer;
  begin
    if BC=Length(D.Branches) then SetLength(D.Branches,Max(64,BC*2));
    Branch:=Default(TTreeBranch);Branch.ID:=HashChild(P.Seed,BC+100);
    Branch.Parent:=AParent;Branch.Depth:=0;Branch.Start:=B;Branch.Control:=C;Branch.Tip:=E;
    Branch.Radius:=Radius;Branch.TipRadius:=TipRadius;D.Branches[BC]:=Branch;
    Result:=BC;Inc(BC);Bounds(B,Radius);Bounds(C,Radius);Bounds(E,Radius);
  end;
  procedure Blade(const FromPoint,ToPoint:TTreeVec3;Aspect:Single);
  begin
    if LC=Length(D.Leaves) then SetLength(D.Leaves,Max(256,LC*2));
    Leaf.Center:=Mix(FromPoint,ToPoint,0.5);Leaf.Axis:=Normalize(Sub(ToPoint,FromPoint));
    Leaf.Size:=Magnitude(Sub(ToPoint,FromPoint))*0.5;Leaf.Aspect:=Aspect;
    Leaf.Phase:=HashUnit(P.Seed,LC+900);D.Leaves[LC]:=Leaf;Inc(LC);
    Bounds(Leaf.Center,Leaf.Size*Max(1,Aspect));
  end;
begin
  D:=Default(TTreeData);D.Params:=P;BC:=0;LC:=0;H:=P.Height;
  D.Fingerprint:=Hash32(P.Seed xor $52475001);
  case P.Species of
    tsBamboo: begin
      Stems:=5+Integer(HashChild(P.Seed,71) mod 4);Spread:=H*P.CrownSpread*0.28;
      for I:=0 to Stems-1 do begin
        Seed:=HashChild(P.Seed,I);A:=I*2.39996323;R:=Spread*Sqrt((I+0.5)/Stems);
        Base:=Vec(Cos(A)*R,0,Sin(A)*R);L:=H*(0.70+0.30*HashUnit(Seed,1));
        Top:=Add(Base,Vec(Cos(A)*L*0.08,L,Sin(A)*L*0.08));Control:=Mix(Base,Top,0.47);
        Control.Y:=L*0.53;Parent:=Stem(Base,Control,Top,P.TrunkRadius,P.TrunkRadius*0.30,-1);
        if IncludeLeaves and (P.LeafDensity>0) then
        for J:=0 to P.PrimaryBranches-1 do begin
          T:=P.CrownStart+(0.96-P.CrownStart)*(J+0.5)/P.PrimaryBranches;
          At:=Curve(Base,Control,Top,T);A:=J*2.39996323+I*1.7;
          W:=H*0.20*(1-T*0.55)*P.CrownSpread/0.45;
          Tip:=Add(At,Vec(Cos(A)*W,W*0.35,Sin(A)*W));
          Stem(At,Mix(At,Tip,0.5),Tip,P.TrunkRadius*0.15,0.001,Parent);
          { Loose sprays on lateral twigs. Equally spaced opposing blades on
            the main branch looked like a conifer ladder rather than bamboo. }
          N:=Max(3,Round(5*P.LeafDensity));
          for K:=0 to 2 do begin
            TwigSeed:=HashChild(Seed,J*11+K);
            TwigBase:=Mix(At,Tip,0.24+K*0.25+HashUnit(TwigSeed,1)*0.06);
            TwigAngle:=A+(K-1)*0.80+(HashUnit(TwigSeed,2)-0.5)*0.55;
            L:=W*(0.38+HashUnit(TwigSeed,3)*0.28);
            TwigTip:=Add(TwigBase,Vec(Cos(TwigAngle)*L,L*(0.10+HashUnit(TwigSeed,4)*0.20),Sin(TwigAngle)*L));
            Stem(TwigBase,Mix(TwigBase,TwigTip,0.5),TwigTip,P.TrunkRadius*0.055,0.001,Parent);
            for Q:=0 to N-1 do begin
              EndPoint:=Mix(TwigBase,TwigTip,0.28+0.70*HashUnit(TwigSeed,Q+90));
              R:=TwigAngle+((Q mod 2)*2-1)*(0.4+HashUnit(TwigSeed,Q+120)*0.9);
              L:=P.LeafSize*(1.4+HashUnit(TwigSeed,Q+140)*1.1);
              Blade(EndPoint,Add(EndPoint,Vec(Cos(R)*L,L*(0.15-HashUnit(TwigSeed,Q+160)*0.65),Sin(R)*L)),0.18);
            end;
          end;
        end;
      end;
    end;
    tsPalm,tsFanPalm: begin
      A:=HashUnit(P.Seed,70)*Pi*2;R:=H*P.Irregularity*0.22;
      Top:=Vec(Cos(A)*R,H*0.82,Sin(A)*R);
      Stem(Vec(0,0,0),Vec(Top.X*0.20,Top.Y*0.48,Top.Z*0.20),Top,P.TrunkRadius,P.TrunkRadius*0.72,-1);
      Fronds:=P.PrimaryBranches;
      for I:=0 to Fronds-1 do begin
        Seed:=HashChild(P.Seed,I);A:=I*2.39996323;
        Dir:=Vec(Cos(A),0,Sin(A));Side:=Vec(-Sin(A),0,Cos(A));
        T:=(I+0.5)/Fronds;L:=H*P.CrownSpread*(0.30+0.18*HashUnit(Seed,1));
        Base:=Add(Top,Scale(Dir,P.TrunkRadius*0.45));
        Tip:=Add(Base,Add(Scale(Dir,L),Vec(0,H*(0.15-T*0.30)*P.Droop/0.55,0)));
        Control:=Add(Base,Add(Scale(Dir,L*0.50),Vec(0,H*0.20,0)));
        if P.Species=tsFanPalm then begin
          Tip:=Add(Base,Add(Scale(Dir,L*0.68),Vec(0,H*(0.16-T*0.22),0)));
          Control:=Mix(Base,Tip,0.5);
        end;
        Stem(Base,Control,Tip,0.022*H/10,0.003,0);
        if not IncludeLeaves or (P.LeafDensity<=0) then Continue;
        if P.Species=tsPalm then begin
          N:=Max(12,Round(25*P.LeafDensity));
          for J:=0 to N-1 do begin
            T:=0.12+0.85*(J+0.5)/N;At:=Curve(Base,Control,Tip,T);
            W:=P.LeafSize*2*Power(Sin(T*Pi),0.65)*(0.85+HashUnit(Seed,J+3)*0.25);
            for K:=-1 to 1 do if K<>0 then begin
              EndPoint:=Add(At,Add(Scale(Side,W*K),Add(Scale(Dir,W*0.24),Vec(0,-W*0.32,0))));
              Blade(At,EndPoint,0.055+0.02*P.LeafDensity);
            end;
          end;
        end else begin
          Axis:=Normalize(Add(Scale(Dir,0.30+T*0.40),Vec(0,1.0-T*0.40,0)));
          N:=Max(13,Round(21*P.LeafDensity));
          for J:=0 to N-1 do begin
            A:=((J+0.5)/N-0.5)*Pi*1.12;
            L:=P.LeafSize*2.4*(0.88+HashUnit(Seed,J+5)*0.18);
            Blade(Tip,Add(Tip,Scale(Add(Scale(Axis,Cos(A)),Scale(Side,Sin(A))),L)),0.11);
          end;
        end;
      end;
    end;
    tsCactus: begin
      Stem(Vec(0,0,0),Vec(0,H*0.5,0),Vec(0,H,0),P.TrunkRadius,0,-1);
      N:=Min(6,Max(1,Round(P.PrimaryBranches*Min(1,P.Maturity)*0.75)));
      for I:=0 to N-1 do begin
        Seed:=HashChild(P.Seed,I);A:=I*2.39996323+HashUnit(P.Seed,7)*Pi*2;
        R:=H*(0.17+HashUnit(Seed,1)*0.12);Dir:=Vec(Cos(A),0,Sin(A));
        Base:=Vec(0,H*(0.27+HashUnit(Seed,2)*0.29),0);
        Tip:=Add(Base,Add(Scale(Dir,R),Vec(0,R*0.65,0)));
        Control:=Add(Base,Scale(Dir,R));W:=P.TrunkRadius*(0.60+HashUnit(Seed,3)*0.15);
        Parent:=Stem(Base,Control,Tip,W,W,0);
        EndPoint:=Add(Tip,Vec(0,H*(0.20+HashUnit(Seed,4)*0.25),0));
        Stem(Tip,Mix(Tip,EndPoint,0.5),EndPoint,W,0,Parent);
      end;
    end;
    tsPricklyPear: begin
      { Pads are closed succulent bodies, not seasonal leaves. Keep them even
        for wood-only requests and draw them in the wood atlas layer. }
      Stem(Vec(0,0,0),Vec(0,H*0.10,0),Vec(0,H*0.20,0),P.TrunkRadius,P.TrunkRadius*0.5,-1);
      Blade(Vec(0,H*0.08,0),Vec(0,H*0.43,0),0.56);
      First:=0;Last:=0;
      for I:=1 to 3 do begin
        N:=LC;
        for J:=First to Last do begin
          Leaf:=D.Leaves[J];Base:=Add(Leaf.Center,Scale(Leaf.Axis,Leaf.Size*0.72));
          for K:=0 to 1 do begin
            Seed:=HashChild(P.Seed,J*3+K);A:=(J+K)*2.39996323+HashUnit(P.Seed,7)*Pi*2;
            L:=H*(0.31-I*0.035)*(0.88+HashUnit(Seed,1)*0.24);
            Axis:=Normalize(Vec(Cos(A)*(0.38+I*0.12)*P.CrownSpread,1,Sin(A)*(0.38+I*0.12)*P.CrownSpread));
            Blade(Base,Add(Base,Scale(Axis,L)),0.55+HashUnit(Seed,2)*0.10);
          end;
        end;
        First:=N;Last:=LC-1;
      end;
    end;
  end;
  SetLength(D.Branches,BC);SetLength(D.Leaves,LC);
  for Branch in D.Branches do begin
    Fingerprint(Branch.Start.X);Fingerprint(Branch.Start.Y);Fingerprint(Branch.Start.Z);
    Fingerprint(Branch.Tip.X);Fingerprint(Branch.Tip.Y);Fingerprint(Branch.Tip.Z);Fingerprint(Branch.Radius);
  end;
  for Leaf in D.Leaves do begin
    Fingerprint(Leaf.Center.X);Fingerprint(Leaf.Center.Y);Fingerprint(Leaf.Center.Z);Fingerprint(Leaf.Size);
  end;
  Result:=D;
end;
end.
