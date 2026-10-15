unit TreeGPUData;
{$mode objfpc}{$H+}
interface
uses TreeModel, TreeMath, TreeFoliageLOD;
type
  TTreeGPUItem = packed array[0..15] of Single;
  TTreeGPUItems = array of TTreeGPUItem;
  TTreeBranchFrame = packed record
    Side: TTreeVec3;
    Length: Single;
  end;
  TTreeBranchFrames = array of TTreeBranchFrame;
  TTreeDepthCounts = array[0..4] of Integer;
  TTreeNeedleGroups = array[0..NEEDLE_DENSITY_GROUPS-1] of record First,Count:Integer;end;
  { Immutable CPU snapshot. No renderer, cell, OpenGL handle or context. }
  TPreparedTreeGPU = record
    Items: array[0..5] of TTreeGPUItems;
    BranchFrames: TTreeBranchFrames;
    PreparedFrames: Boolean;
    Fingerprint: LongWord;
    BoundsMin, BoundsMax: TTreeVec3;
    BranchCount,PrimaryCount,LeafCount,CrownCount,NeedleShootCount:Integer;
    SourceLeafCount,SourceShootCount:Integer;
    FruitCount,FruitMembers,NeedlesPerFascicle:Integer;
    FruitRadius:Single;
    DepthCounts:TTreeDepthCounts;
    NeedleGroups:TTreeNeedleGroups;
    UploadBytes:Int64;
  end;
function TreePreparedFramesExperimentEnabled:Boolean;
function PrepareTreeGPU(const Data:TTreeData):TPreparedTreeGPU;overload;
{ Explicit opt-in for isolated equivalence fixtures. Production callers use
  the process-start environment setting through the overload above. }
function PrepareTreeGPU(const Data:TTreeData;const PrepareFixedFrames:Boolean):TPreparedTreeGPU;overload;
implementation
uses SysUtils, Math, TreeFruits;
var PreparedFramesExperiment:Boolean=False;
function TreePreparedFramesExperimentEnabled:Boolean;
begin Result:=PreparedFramesExperiment end;
function BranchFrame(const B:TTreeBranch; Species:TTreeSpecies):TTreeBranchFrame;
var First,Last,Plane,Axis,Radial:TTreeVec3;
begin
  First:=Sub(B.Control,B.Start);Last:=Sub(B.Tip,B.Control);
  Plane:=Cross(First,Last);
  if Dot(Plane,Plane)<1e-8*Max(Dot(First,First)*Dot(Last,Last),1e-8) then begin
    Axis:=Normalize(First);
    if Abs(Axis.Y)>0.95 then Plane:=Cross(Axis,Vec(1,0,0))
    else Plane:=Cross(Axis,Vec(0,1,0));
  end;
  Result.Side:=Normalize(Plane);
  if Species=tsCactus then begin
    Radial:=Vec(B.Tip.X-B.Start.X,0,B.Tip.Z-B.Start.Z);
    if Dot(Radial,Radial)<0.00001 then Radial:=Vec(B.Start.X,0,B.Start.Z);
    if Dot(Radial,Radial)>0.00001 then Result.Side:=Normalize(Cross(Radial,Vec(0,1,0)))
    else Result.Side:=Vec(0,0,1);
  end;
  Result.Length:=Magnitude(Sub(B.Tip,B.Start));
  if ((B.Depth=0) or (B.Radius>0.025)) and
     ((Ord(Species)<14) or (Ord(Species)>=19)) then
    Result.Length:=0.5*(Magnitude(First)+Magnitude(Last)+Result.Length);
end;
procedure SetVec(var Item: TTreeGPUItem; Offset: Integer; const V: TTreeVec3; W: Single);
begin Item[Offset]:=V.X; Item[Offset+1]:=V.Y; Item[Offset+2]:=V.Z; Item[Offset+3]:=W; end;
procedure SetType(var Item: TTreeGPUItem; const Actual: TTreeParams);
begin
  Move(Actual.TypeCode,Item[13],SizeOf(TTreeTypeCode));
  Item[14]:=Actual.Maturity;
  Item[15]:=Actual.Irregularity;
end;
function PrepareTreeGPU(const Data:TTreeData):TPreparedTreeGPU;
begin Result:=PrepareTreeGPU(Data,PreparedFramesExperiment) end;
function PrepareTreeGPU(const Data:TTreeData;const PrepareFixedFrames:Boolean):TPreparedTreeGPU;
var Items:TTreeGPUItems; I,G,N,Index,J:Integer; B:TTreeBranch; L:TTreeLeaf;
    C:TTreeCrown; Shoot:TTreeNeedleShoot; Fruit:TTreeFruit; SwapItem:TTreeGPUItem;
    Next:array[0..NEEDLE_DENSITY_GROUPS-1]of Integer;
    ParentAxis,Axis,Side:TTreeVec3; OctX,OctY,LeafRoll,Roll,InvLength:Single;
begin
  Result:=Default(TPreparedTreeGPU);
  Result.Fingerprint:=Data.Fingerprint;
  Result.BoundsMin:=Data.BoundsMin;Result.BoundsMax:=Data.BoundsMax;
  Result.BranchCount:=Length(Data.Branches); Result.LeafCount:=Length(Data.Leaves); Result.CrownCount:=Length(Data.Crowns);
  Result.NeedleShootCount:=Length(Data.NeedleShoots);
  Result.SourceLeafCount:=Max(Result.LeafCount,Data.SourceLeafCount);
  Result.SourceShootCount:=Max(Result.NeedleShootCount,Data.SourceShootCount);
  Result.FruitCount:=Length(Data.Fruits);Result.FruitRadius:=0;Result.FruitMembers:=1;
  if Result.FruitCount>0 then Result.FruitMembers:=FruitClusterMembers(Data.Fruits[0].Kind);
  Result.NeedlesPerFascicle:=NeedlesPerFascicle(Data.Params.Species);
  Result.UploadBytes:=Int64(Result.BranchCount+Result.LeafCount+Result.CrownCount+Result.NeedleShootCount+Result.FruitCount)*SizeOf(TTreeGPUItem);
  { Experimental: no frame computation/allocation in the default path. The
    optional local frames are reused by every colour/depth pass and LOD. }
  Result.PreparedFrames:=PrepareFixedFrames;
  if PrepareFixedFrames then begin
    SetLength(Result.BranchFrames,Result.BranchCount);
    Inc(Result.UploadBytes,Int64(Result.BranchCount)*SizeOf(TTreeBranchFrame));
  end;
  FillChar(Result.DepthCounts,SizeOf(Result.DepthCounts),0); SetLength(Items,Result.BranchCount);
  for I:=0 to Result.BranchCount-1 do begin
    B:=Data.Branches[I]; SetVec(Items[I],0,B.Start,B.Radius); SetVec(Items[I],4,B.Control,B.TipRadius);
    if PrepareFixedFrames then Result.BranchFrames[I]:=BranchFrame(B,Data.Params.Species);
    SetVec(Items[I],8,B.Tip,B.Depth); Items[I][12]:=HashUnit(B.ID,60); SetType(Items[I],Data.Params);
    { Wood does not use descriptor irregularity. Store the parent radius for
      an embedded collar; its open starting ring must stay inside the parent. }
    Items[I][15]:=0;
    if B.Parent>=0 then begin
      Items[I][15]:=Data.Branches[B.Parent].Radius*(1-B.Attach)+Data.Branches[B.Parent].TipRadius*B.Attach;
      ParentAxis:=Tangent(Data.Branches[B.Parent].Start,Data.Branches[B.Parent].Control,Data.Branches[B.Parent].Tip,B.Attach);
      ParentAxis:=Scale(ParentAxis,1/Max(0.001,Abs(ParentAxis.X)+Abs(ParentAxis.Y)+Abs(ParentAxis.Z)));
      OctX:=ParentAxis.X;OctY:=ParentAxis.Y;
      if ParentAxis.Z<0 then begin
        OctX:=(1-Abs(ParentAxis.Y))*IfThen(ParentAxis.X<0,-1,1);
        OctY:=(1-Abs(ParentAxis.X))*IfThen(ParentAxis.Y<0,-1,1);
      end;
      { The wood shader does not use maturity; two octahedral 8-bit coordinates
        fit exactly into the existing float. No extra branch buffer or stride. }
      Items[I][14]:=Round((OctX*0.5+0.5)*255)*256+Round((OctY*0.5+0.5)*255);
    end;
    Inc(Result.DepthCounts[B.Depth]);
  end;
  Result.Items[0]:=Items;
  Result.PrimaryCount:=Result.DepthCounts[0]+Result.DepthCounts[1];
  Items:=nil; SetLength(Items,Result.LeafCount);
  LeafRoll:=0;
  if PrepareFixedFrames then begin
    LeafRoll:=Clamp(Sqrt(Result.SourceLeafCount/Max(1,Result.LeafCount))-1,0,1);
    LeafRoll:=0.70*LeafRoll*LeafRoll*(3-2*LeafRoll);
  end;
  for I:=0 to Result.LeafCount-1 do begin
    L:=Data.Leaves[I]; SetVec(Items[I],0,L.Center,L.Size); SetVec(Items[I],4,L.Axis,L.Aspect);
    { The original unused vec4 stays zero unless the experiment is enabled. }
    if PrepareFixedFrames then begin
      InvLength:=1/Max(1e-8,Magnitude(L.Axis));Axis:=Scale(L.Axis,InvLength);
      if Abs(Axis.Y)>0.95 then Side:=Normalize(Cross(Axis,Vec(1,0,0)))
      else Side:=Normalize(Cross(Axis,Vec(0,1,0)));
      Roll:=(L.Phase-0.5)*LeafRoll;
      Side:=Add(Scale(Side,Cos(Roll)),Scale(Cross(Axis,Side),Sin(Roll)));
      SetVec(Items[I],8,Side,InvLength);
    end;
    Items[I][12]:=L.Phase; SetType(Items[I],Data.Params);
  end;
  { A draw prefix must sample the whole crown, not the first branches generated.
    Shuffle once at upload; all LODs use nested subsets with stable identities. }
  for I:=Result.LeafCount-1 downto 1 do begin
    J:=Hash32(LongWord(I) xor Data.Fingerprint) mod LongWord(I+1);
    SwapItem:=Items[I];Items[I]:=Items[J];Items[J]:=SwapItem;
  end;
  Result.Items[1]:=Items; Items:=nil; SetLength(Items,Result.CrownCount);
  for I:=0 to Result.CrownCount-1 do begin
    C:=Data.Crowns[I]; SetVec(Items[I],0,C.Center,C.Phase); SetVec(Items[I],4,C.Radius,0);
    Items[I][12]:=C.Phase; SetType(Items[I],Data.Params);
  end;
  Result.Items[2]:=Items;
  Items:=nil;SetLength(Items,Result.FruitCount);
  for I:=0 to Result.FruitCount-1 do begin
    Fruit:=Data.Fruits[I];
    SetVec(Items[I],0,Fruit.Center,Fruit.Radius);SetVec(Items[I],4,Fruit.Axis,Fruit.HalfLength);
    SetVec(Items[I],8,Fruit.Color,Ord(Fruit.Kind));Items[I][12]:=Fruit.Phase;SetType(Items[I],Data.Params);
    Result.FruitRadius:=Max(Result.FruitRadius,Max(Fruit.Radius,Fruit.HalfLength)*IfThen(Result.FruitMembers>1,8,1));
  end;
  Result.Items[5]:=Items;
  Items:=nil; SetLength(Items,Result.NeedleShootCount);
  FillChar(Result.NeedleGroups,SizeOf(Result.NeedleGroups),0);
  for I:=0 to Result.NeedleShootCount-1 do
    Inc(Result.NeedleGroups[NeedleDensityGroup(Data.NeedleShoots[I],Data.Params)].Count);
  N:=0;
  for G:=0 to NEEDLE_DENSITY_GROUPS-1 do begin
    Result.NeedleGroups[G].First:=N;Next[G]:=N;Inc(N,Result.NeedleGroups[G].Count);
  end;
  for I:=0 to Result.NeedleShootCount-1 do begin
    Shoot:=Data.NeedleShoots[I];
    G:=NeedleDensityGroup(Shoot,Data.Params);Index:=Next[G];Inc(Next[G]);
    SetVec(Items[Index],0,Shoot.Start,Shoot.Radius); SetVec(Items[Index],4,Shoot.Control,Shoot.NeedleLength);
    SetVec(Items[Index],8,Shoot.Tip,Shoot.NeedleWidth);
    Items[Index][12]:=Shoot.Phase; SetType(Items[Index],Data.Params);
  end;
  Result.Items[4]:=Items;
end;
initialization
  PreparedFramesExperiment:=GetEnvironmentVariable('REZVIVO_TREE_PREPARED_FRAMES')='1';
end.
