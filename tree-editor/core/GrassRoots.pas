unit GrassRoots;
{$mode objfpc}{$H+}{$Q-}{$R-}
interface
uses Math,GrassModel;
type
  TGrassRoot = packed record Patch,Blade:LongWord; end;
  TGrassRoots = array of TGrassRoot;
  TGrassRootSelection = record
    Blades,Heads:array of LongWord;
    StableCount:Integer;
    Candidates,Rejected:QWord;
  end;
{ Conservative CPU admission of the original shader population. Near a source
  edge retain the candidate and let the unchanged GLSL inside() decide. This
  explicitly preserves shared-edge and stacked-surface behaviour. }
function SelectGrassRoots(const Patch:TGrassPatch;const Profile:TGrassProfile;Grid:Integer):TGrassRootSelection;
{ Compact only the lookup table: Patch is an address, never the random seed.
  Preserve original table order, every descriptor byte, blade/head order and
  IDs. Invalid references leave both input lists unchanged for legacy fallback. }
function CompactGrassRootPatches(const Patches:TGrassPatches;var Roots,Heads:TGrassRoots;
  out Table:TGrassPatches):Boolean;
implementation
function CompactGrassRootPatches(const Patches:TGrassPatches;var Roots,Heads:TGrassRoots;
  out Table:TGrassPatches):Boolean;
var Remap:array of LongWord;I,N:SizeInt;
begin
  Result:=False;Table:=nil;
  if(Length(Roots)=0)and(Length(Heads)=0)then Exit(True);
  if(Length(Patches)=0)or(QWord(Length(Patches))>High(LongWord))then Exit;
  SetLength(Remap,Length(Patches));FillChar(Remap[0],Length(Remap)*SizeOf(LongWord),$ff);
  { Validate the entire input before altering any accepted ID. }
  for I:=0 to High(Roots)do begin
    if QWord(Roots[I].Patch)>=QWord(Length(Patches))then Exit;
    Remap[Roots[I].Patch]:=0;
  end;
  for I:=0 to High(Heads)do begin
    if QWord(Heads[I].Patch)>=QWord(Length(Patches))then Exit;
    Remap[Heads[I].Patch]:=0;
  end;
  N:=0;
  for I:=0 to High(Patches)do if Remap[I]<>High(LongWord)then begin Remap[I]:=N;Inc(N)end;
  SetLength(Table,N);
  for I:=0 to High(Patches)do if Remap[I]<>High(LongWord)then Table[Remap[I]]:=Patches[I];
  for I:=0 to High(Roots)do Roots[I].Patch:=Remap[Roots[I].Patch];
  for I:=0 to High(Heads)do Heads[I].Patch:=Remap[Heads[I].Patch];
  Result:=True;
end;
function Smooth(A,B,X:Single):Single;inline;
begin Result:=EnsureRange((X-A)/(B-A),0.0,1.0);Result:=Result*Result*(3-2*Result);end;
function SafeInside(const P:TGrassPatch;X,Z:Single):Boolean;
var A,B,C,E:Single;
begin
  A:=(P.BX-P.AX)*(Z-P.AZ)-(P.BZ-P.AZ)*(X-P.AX);
  B:=(P.CX-P.BX)*(Z-P.BZ)-(P.CZ-P.BZ)*(X-P.BX);
  C:=(P.AX-P.CX)*(Z-P.CZ)-(P.AZ-P.CZ)*(X-P.CX);
  { Bounds cover Single/FMA evaluation differences without accepting a new
    visible root: the original GPU clipping is deliberately retained. }
  E:=0.00002*(1+Abs(P.AX)+Abs(P.AZ)+Abs(P.BX)+Abs(P.BZ)+Abs(P.CX)+Abs(P.CZ));
  Result:=((A>=-E)and(B>=-E)and(C>=-E))or((A<=E)and(B<=E)and(C<=E));
end;
function SelectGrassRoots(const Patch:TGrassPatch;const Profile:TGrassProfile;Grid:Integer):TGrassRootSelection;
var Blade,Row,Col,GX,GZ,FlowerCol,Kind,Form,N,H,Stable,Phase:Integer;
    Seed,Bits,GroupBits,ColumnBits,WeedBits:LongWord;
    RX,RY,RZ,RW,RootX,RootZ,PlantX,PlantZ,Community,Habitat,FX,FY,Choice,HeadChoice,T,Abundance:Single;
    Flower,SeedHead,Admit:Boolean;
    Accepted:array of Boolean;
begin
  Result:=Default(TGrassRootSelection);if not(Grid in[16,32])then Exit;
  Seed:=Trunc(Patch.Seed);Kind:=Trunc(Patch.Kind+0.5);
  Community:=EnsureRange((Patch.Kind-Kind)*2.5,0.0,1.0);
  Habitat:=1+(0.22+(1.78-0.22)*Smooth(0.2,0.8,Community)-1)*Profile.Variation;
  FX:=Profile.Broadleaf*Habitat;FY:=Profile.Rosettes*Habitat;
  T:=Max(1.0,(FX+FY)/0.92);FX:=FX/T;FY:=FY/T;
  SetLength(Result.Blades,Grid*Grid);SetLength(Result.Heads,Grid);
  SetLength(Accepted,Grid*Grid);N:=0;H:=0;Stable:=0;
  for Row:=0 to Grid-1 do begin
    ColumnBits:=GrassHash(Seed xor LongWord(Row)*$85ebca6b xor $c2b2ae35);
    FlowerCol:=ColumnBits and LongWord(Grid-1);
    for Col:=0 to Grid-1 do begin
      Blade:=Row*Grid+Col;Inc(Result.Candidates);
      Bits:=GrassHash(Seed+LongWord(Blade)*$9e3779b9);
      RX:=(Bits and 255)/255;RY:=((Bits shr 8)and 255)/255;
      RZ:=((Bits shr 16)and 255)/255;RW:=(Bits shr 24)/255;
      RootX:=(Col+(0.12+(0.88-0.12)*RX))/Grid-0.5;
      RootZ:=(Row+(0.12+(0.88-0.12)*RY))/Grid-0.5;
      GX:=Col div 3;GZ:=Row div 3;
      GroupBits:=GrassHash(Seed xor LongWord(GX+GZ*Grid)*$85ebca6b);
      Choice:=(GroupBits and 65535)/65535;
      if Choice<FX then Form:=1 else if Choice<FX+FY then Form:=2 else Form:=0;
      if(Form=1)and(Kind=1)and(((GroupBits shr 20)and 3)<>0)then Form:=3;
      PlantX:=(GX*3+1.5)/Grid-0.5+(((GroupBits shr 16)and 255)/255-0.5)/Grid;
      PlantZ:=(GZ*3+1.5)/Grid-0.5+((GroupBits shr 24)/255-0.5)/Grid;
      if Form=0 then T:=0.28*Profile.Variation else T:=0.78*Profile.Variation;
      RootX:=RootX*(1-T)+PlantX*T;RootZ:=RootZ*(1-T)+PlantZ*T;
      Admit:=(RW<=Profile.Density+0.000001)and SafeInside(Patch,RootX,RootZ);
      if(Abs(Choice-FX)<0.00001)or(Abs(Choice-FX-FY)<0.00001)then
        Admit:=RW<=Profile.Density+0.000001;
      Accepted[Blade]:=Admit;
      if not Admit then Inc(Result.Rejected);
      if Admit and(Col=FlowerCol)and not((Row<2)and(Profile.Weeds>0))then begin
        Flower:=RZ<Profile.Flowers*Grid+0.000001;
        HeadChoice:=(GrassHash(Bits xor $b5297a4d)and 65535)/65535;
        SeedHead:=HeadChoice<Profile.SeedHeads*(0.65+(1.35-0.65)*Community)+0.000001;
        if Flower or SeedHead then begin Result.Heads[H]:=Row;Inc(H) end;
      end;
    end;
    if(Row<2)and(Profile.Weeds>0)then begin
      WeedBits:=GrassHash(Seed xor LongWord(Row)*$85ebca6b xor $b4f03e77);
      RX:=(WeedBits and 255)/255;RY:=((WeedBits shr 8)and 255)/255;RW:=(WeedBits shr 24)/255;
      RootX:=(RX-0.5)*0.76;RootZ:=(RY-0.5)*0.76;
      Abundance:=Profile.Weeds*(0.25+(1.65-0.25)*Smooth(0.2,0.8,Community));
      if(RW<Abundance+0.000001)and SafeInside(Patch,RootX,RootZ)then begin Result.Heads[H]:=Row;Inc(H) end;
    end;
  end;
  { Preserve a stable prefix for the existing sparse index level. }
  for Phase:=0 to 1 do begin
    for Blade:=0 to Grid*Grid-1 do if Accepted[Blade]and
      (Ord((GrassHash(LongWord(Blade)xor $68bc21eb)and 3)<>0)=Phase)then begin
      Result.Blades[N]:=Blade;Inc(N);
    end;
    if Phase=0 then Stable:=N;
  end;
  SetLength(Result.Blades,N);SetLength(Result.Heads,H);Result.StableCount:=Stable;
end;
end.
