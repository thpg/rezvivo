unit AvatarWardrobe;
{$mode objfpc}{$H+}{$codepage utf8}
interface
uses SysUtils, Classes, Math, fpjson, AvatarGlbIO;
type TWardrobeFloats = array of Single;

function WardrobeReadAcc(Doc:TGlbDoc;Index:Integer;out Components:Integer):TWardrobeFloats;
function WardrobeData(Doc: TGlbDoc; CreateMissing: Boolean = False): TJSONObject;
function WardrobeItems(Doc: TGlbDoc): TJSONArray;
function WardrobeItem(Doc: TGlbDoc; const Id: string): TJSONObject;
procedure ChangeWardrobe(Doc: TGlbDoc; Params: TJSONObject);
function WardrobeColor(const Hex: string): TVec3;

implementation
uses GltfCore, RiderEquipment, AvatarWardrobeGeometry;
type
  TFloats = TWardrobeFloats;
  TBodyPoint = record
    P: TVec3;
    J, W: array[0..3] of Single;
  end;
  TBodyPoints = array of TBodyPoint;
  TNormalSum = class
    X,Y,Z: Single;
  end;
  TWeldNormals = class(TStringList)
  public
    destructor Destroy; override;
  end;

destructor TWeldNormals.Destroy;
var I: Integer;
begin for I:=0 to Count-1 do Objects[I].Free;inherited end;

function PositionKey(const P:TFloats;Index:Integer):string;
begin
  Result:=IntToStr(Round(P[Index*3]*100000))+','+IntToStr(Round(P[Index*3+1]*100000))+','+
    IntToStr(Round(P[Index*3+2]*100000));
end;

function ObjectChild(O: TJSONObject; const Key: string): TJSONObject;
begin
  Result := ObjOf(O, Key);
  if Result = nil then begin Result := TJSONObject.Create; O.Add(Key, Result) end;
end;

function MaterialColor(const Hex: string): TVec3;
  function Linear(C: Double): Double;
  begin
    if C<=0.04045 then Result:=C/12.92 else Result:=Power((C+0.055)/1.055,2.4);
  end;
begin
  Result:=WardrobeColor(Hex);
  Result:=V3(Linear(Result.X),Linear(Result.Y),Linear(Result.Z));
end;

function ArrayChild(O: TJSONObject; const Key: string): TJSONArray;
begin
  Result := ArrOf(O, Key);
  if Result = nil then begin Result := TJSONArray.Create; O.Add(Key, Result) end;
end;

procedure Put(O: TJSONObject; const Key: string; V: TJSONData);
begin O.Delete(Key); O.Add(Key, V) end;

function WardrobeData(Doc: TGlbDoc; CreateMissing: Boolean): TJSONObject;
begin
  Result := nil;
  if (Doc = nil) or (Doc.Root = nil) then Exit;
  if CreateMissing then begin
    Result := ObjectChild(ObjectChild(Doc.Root, 'extras'), 'avatarWardrobe');
    if not HasKey(Result, 'version') then Result.Add('version', 1);
    ArrayChild(Result, 'items');
  end else Result := ObjOf(ObjOf(Doc.Root, 'extras'), 'avatarWardrobe');
end;

function WardrobeItems(Doc: TGlbDoc): TJSONArray;
begin Result := ArrOf(WardrobeData(Doc), 'items') end;

function WardrobeItem(Doc: TGlbDoc; const Id: string): TJSONObject;
var A: TJSONArray; I: Integer;
begin
  A := WardrobeItems(Doc); Result := nil;
  for I := 0 to CountOf(A)-1 do
    if StrOf(ObjAt(A,I),'id','') = Id then Exit(ObjAt(A,I));
end;

function WardrobeColor(const Hex: string): TVec3;
var S: string; V: LongInt;
begin
  S := Trim(Hex);
  if (Length(S)>0) and (S[1]='#') then Delete(S,1,1);
  if (Length(S)<>6) or not TryStrToInt('$'+S,V) or (V<0) or (V>$ffffff) then
    raise EArgumentException.Create('Color must be #RRGGBB');
  Result := V3(((V shr 16) and 255)/255, ((V shr 8) and 255)/255, (V and 255)/255);
end;

function ReadAcc(Doc: TGlbDoc; Index: Integer; out Components: Integer): TFloats;
var A,B: TJSONObject; C,CT,Step,Start,I,K,Off: Integer; F: Single;
  U: LongWord; Normalized: Boolean;
begin
  Result := nil; Components := 0;
  A := ObjAt(ArrOf(Doc.Root,'accessors'),Index);
  B := ObjAt(ArrOf(Doc.Root,'bufferViews'),IntOf(A,'bufferView',-1));
  if (A=nil) or (B=nil) or HasKey(A,'sparse') then
    raise EReadError.Create('Clothing requires dense GLB accessors');
  CT := IntOf(A,'componentType',0); Components := TypeCount(StrOf(A,'type',''));
  C := IntOf(A,'count',0); Normalized := A.Get('normalized',False);
  if (C<=0) or (C>2000000) or (Components<=0) or
    ((CT<>5121) and (CT<>5123) and (CT<>5125) and (CT<>5126)) then
    raise EReadError.Create('Unsupported clothing accessor');
  Step := IntOf(B,'byteStride',Components*CompSize(CT));
  Start := IntOf(B,'byteOffset',0)+IntOf(A,'byteOffset',0);
  if (Step<Components*CompSize(CT)) or (Start<0) or
    (Int64(Start)+Int64(C-1)*Step+Components*CompSize(CT)>Length(Doc.Bin)) or
    (Int64(Start)+Int64(C-1)*Step+Components*CompSize(CT)>
      Int64(IntOf(B,'byteOffset',0))+IntOf(B,'byteLength',0)) then
    raise EReadError.Create('Clothing accessor exceeds buffer');
  SetLength(Result,C*Components);
  for I:=0 to C-1 do for K:=0 to Components-1 do begin
    Off:=Start+I*Step+K*CompSize(CT); F:=0;
    case CT of
      5121: begin F:=Doc.Bin[Off]; if Normalized then F:=F/255 end;
      5123: begin F:=Doc.Bin[Off]+256*Doc.Bin[Off+1];if Normalized then F:=F/65535 end;
      5125: begin U:=U32(Doc.Bin,Off);F:=U end;
      5126: Move(Doc.Bin[Off],F,4);
    end;
    if IsNan(F) or IsInfinite(F) then raise EReadError.Create('Non-finite clothing vertex');
    Result[I*Components+K]:=F;
  end;
end;

function WardrobeReadAcc(Doc:TGlbDoc;Index:Integer;out Components:Integer):TWardrobeFloats;
begin Result:=ReadAcc(Doc,Index,Components) end;

function AddAcc(Doc: TGlbDoc; const Values: TFloats; Components: Integer;
  const Kind: string; IntegerValues: Boolean=False): Integer;
var V,A: TJSONObject; Bytes: TBytes; I,K,Offset,View: Integer; W: Word;
  Lo,Hi: TJSONArray; MinV,MaxV: Single;
begin
  if Length(Values)=0 then raise EArgumentException.Create('Empty clothing geometry');
  if IntegerValues then begin
    SetLength(Bytes,Length(Values)*2);
    for I:=0 to High(Values) do begin W:=Round(Values[I]); Move(W,Bytes[I*2],2) end;
  end else begin
    SetLength(Bytes,Length(Values)*4); Move(Values[0],Bytes[0],Length(Bytes));
  end;
  Offset:=Doc.AppendBytes(Bytes[0],Length(Bytes));
  V:=TJSONObject.Create(['buffer',0,'byteOffset',Offset,'byteLength',Length(Bytes)]);
  V.Add('target',34962); View:=ArrayChild(Doc.Root,'bufferViews').Count;
  ArrayChild(Doc.Root,'bufferViews').Add(V);
  A:=TJSONObject.Create(['bufferView',View,'count',Length(Values) div Components,'type',Kind]);
  if IntegerValues then A.Add('componentType',5123) else A.Add('componentType',5126);
  if Kind='VEC3' then begin
    Lo:=TJSONArray.Create; Hi:=TJSONArray.Create;
    for K:=0 to 2 do begin
      MinV:=Values[K];MaxV:=MinV;
      for I:=0 to Length(Values) div 3-1 do begin
        MinV:=Min(MinV,Values[I*3+K]);MaxV:=Max(MaxV,Values[I*3+K]);
      end;
      Lo.Add(MinV);Hi.Add(MaxV);
    end;
    A.Add('min',Lo);A.Add('max',Hi);
  end;
  Result:=ArrayChild(Doc.Root,'accessors').Count;ArrayChild(Doc.Root,'accessors').Add(A);
end;

procedure CaptureBase(Doc: TGlbDoc);
var Base,Meshes,Nodes,Refs: TJSONArray; I,J: Integer; O: TJSONObject;
begin
  O:=WardrobeData(Doc,True);
  if HasKey(O,'baseMeshes') then Exit;
  Base:=TJSONArray.Create;O.Add('baseMeshes',Base);
  Meshes:=ArrOf(Doc.Root,'meshes');Nodes:=ArrOf(Doc.Root,'nodes');
  for I:=0 to CountOf(Meshes)-1 do begin
    O:=TJSONObject.Create(['mesh',I]);
    O.Add('primitives',ArrOf(ObjAt(Meshes,I),'primitives').Clone);
    Refs:=TJSONArray.Create;O.Add('nodes',Refs);
    for J:=0 to CountOf(Nodes)-1 do
      if IntOf(ObjAt(Nodes,J),'mesh',-1)=I then Refs.Add(J);
    Base.Add(O);
  end;
end;

function BaseRegion(Doc: TGlbDoc; Mesh: Integer): string;
var N: string;
begin
  N:=LowerCase(StrOf(ObjAt(ArrOf(Doc.Root,'meshes'),Mesh),'name',''));
  if Pos('body_upper',N)>0 then Exit('top');
  if Pos('body_lower',N)>0 then Exit('bottom');
  if Pos('kitlogo',N)>0 then Exit('logo');
  if Pos('cycling shoes',N)>0 then Exit('feet');
  if Pos('head_neck',N)>0 then Exit('head');
  Result:='';
end;

function FabricPrimitive(Doc: TGlbDoc; P: TJSONObject): Boolean;
var N: string;
begin
  N:=LowerCase(StrOf(ObjAt(ArrOf(Doc.Root,'materials'),IntOf(P,'material',-1)),'name',''));
  Result:=(Pos('part_jersey',N)>0) or (Pos('part_sleeves',N)>0);
end;

function BuildWeldNormals(Doc:TGlbDoc;Base:TJSONArray;const Region:string):TWeldNormals;
var I,J,K,C,Idx:Integer;Prims:TJSONArray;Attr:TJSONObject;P,N,Indices:TFloats;
  Key:string;Sum:TNormalSum;Used:array of Boolean;
begin
  Result:=TWeldNormals.Create;Result.Sorted:=True;
  try
    for I:=0 to Base.Count-1 do if BaseRegion(Doc,ObjAt(Base,I).Get('mesh',-1))=Region then begin
      Prims:=ArrOf(ObjAt(Base,I),'primitives');
      for J:=0 to Prims.Count-1 do begin
        Attr:=ObjOf(ObjAt(Prims,J),'attributes');P:=ReadAcc(Doc,IntOf(Attr,'POSITION',-1),C);
        N:=ReadAcc(Doc,IntOf(Attr,'NORMAL',-1),C);
        if Length(P)<>Length(N) then raise EReadError.Create('Invalid clothing normals');
        Indices:=ReadAcc(Doc,IntOf(ObjAt(Prims,J),'indices',-1),C);
        Used:=nil;SetLength(Used,Length(P)div 3);
        for K:=0 to High(Indices)do begin
          Idx:=Round(Indices[K]);
          if(Idx<0)or(Idx>=Length(Used))then raise EReadError.Create('Invalid clothing vertex index');
          Used[Idx]:=True;
        end;
        for K:=0 to Length(P) div 3-1 do begin
          { Unreferenced vertices retained for the body corrective atlas
            include the former bottom cap. Its downward normals must not
            contaminate the actual cloth edge. }
          if not Used[K]then Continue;
          Key:=PositionKey(P,K);Idx:=Result.IndexOf(Key);
          if Idx<0 then begin Sum:=TNormalSum.Create;Result.AddObject(Key,Sum) end
          else Sum:=TNormalSum(Result.Objects[Idx]);
          Sum.X:=Sum.X+N[K*3];Sum.Y:=Sum.Y+N[K*3+1];Sum.Z:=Sum.Z+N[K*3+2];
        end;
      end;
    end;
  except Result.Free;raise end;
end;

procedure RebuildGarmentNormals(Doc:TGlbDoc;Mesh:TJSONObject);
var Sums:TWeldNormals;Prims:TJSONArray;P:TJSONObject;Positions,Indices,Normals:TFloats;
  I,J,K,C,A,B,D,Index:Integer;U,V,N:TVec3;Sum:TNormalSum;Key:string;L:Single;
begin
  Sums:=TWeldNormals.Create;Sums.Sorted:=True;Prims:=ArrOf(Mesh,'primitives');
  try
    for I:=0 to CountOf(Prims)-1 do begin
      P:=ObjAt(Prims,I);Positions:=ReadAcc(Doc,IntOf(ObjOf(P,'attributes'),'POSITION',-1),C);
      Indices:=ReadAcc(Doc,IntOf(P,'indices',-1),C);
      for J:=0 to Length(Indices)div 3-1 do begin
        A:=Round(Indices[J*3])*3;B:=Round(Indices[J*3+1])*3;D:=Round(Indices[J*3+2])*3;
        U:=V3(Positions[B]-Positions[A],Positions[B+1]-Positions[A+1],Positions[B+2]-Positions[A+2]);
        V:=V3(Positions[D]-Positions[A],Positions[D+1]-Positions[A+1],Positions[D+2]-Positions[A+2]);
        N:=V3(U.Y*V.Z-U.Z*V.Y,U.Z*V.X-U.X*V.Z,U.X*V.Y-U.Y*V.X);
        for K:=0 to 2 do begin
          Key:=PositionKey(Positions,Round(Indices[J*3+K]));Index:=Sums.IndexOf(Key);
          if Index<0 then begin Sum:=TNormalSum.Create;Sums.AddObject(Key,Sum) end
          else Sum:=TNormalSum(Sums.Objects[Index]);
          Sum.X:=Sum.X+N.X;Sum.Y:=Sum.Y+N.Y;Sum.Z:=Sum.Z+N.Z;
        end;
      end;
    end;
    for I:=0 to CountOf(Prims)-1 do begin
      P:=ObjOf(ObjAt(Prims,I),'attributes');Positions:=ReadAcc(Doc,IntOf(P,'POSITION',-1),C);
      Normals:=ReadAcc(Doc,IntOf(P,'NORMAL',-1),C);
      for J:=0 to Length(Positions)div 3-1 do begin
        Index:=Sums.IndexOf(PositionKey(Positions,J));if Index<0 then Continue;
        Sum:=TNormalSum(Sums.Objects[Index]);L:=Sqrt(Sqr(Sum.X)+Sqr(Sum.Y)+Sqr(Sum.Z));
        if L<1e-10 then Continue;
        Normals[J*3]:=Sum.X/L;Normals[J*3+1]:=Sum.Y/L;Normals[J*3+2]:=Sum.Z/L;
      end;
      Put(P,'NORMAL',TJSONIntegerNumber.Create(AddAcc(Doc,Normals,3,'VEC3')));
    end;
  finally Sums.Free end;
end;

procedure SyncVisibility(Doc: TGlbDoc);
var Items,Base,Prims,Visible,Roots: TJSONArray; O,P,Mesh,N: TJSONObject;
  I,J,NodeI,MeshI,HiddenMaterial: Integer; Top,LongSleeve,Bottom,Outer,Head,Feet,Active,Hide: Boolean; Region: string;
begin
  Items:=WardrobeItems(Doc);Top:=False;Bottom:=False;LongSleeve:=False;
  Outer:=False;Head:=False;Feet:=False;
  for I:=0 to CountOf(Items)-1 do if ObjAt(Items,I).Get('enabled',False) then begin
    Region:=ObjAt(Items,I).Get('slot','');
    Outer:=Outer or (Region='outer');Head:=Head or (Region='head');Feet:=Feet or (Region='feet');
  end;
  O:=WardrobeData(Doc);HiddenMaterial:=O.Get('hiddenMaterial',-1);
  if HiddenMaterial<0 then begin
    HiddenMaterial:=ArrayChild(Doc.Root,'materials').Count;
    N:=TJSONObject.Create(['name','AvatarHiddenBase','alphaMode','MASK','alphaCutoff',0.5]);
    N.Add('pbrMetallicRoughness',TJSONObject.Create(['baseColorFactor',TJSONArray.Create([0,0,0,0]),
      'metallicFactor',0.0,'roughnessFactor',1.0]));
    ArrayChild(Doc.Root,'materials').Add(N);O.Add('hiddenMaterial',HiddenMaterial);
  end;
  Roots:=ArrayChild(ObjAt(ArrOf(Doc.Root,'scenes'),IntOf(Doc.Root,'scene',0)),'nodes');
  for I:=0 to CountOf(Items)-1 do begin
    O:=ObjAt(Items,I);Active:=O.Get('enabled',False);NodeI:=O.Get('node',-1);
    for J:=Roots.Count-1 downto 0 do if Roots.Integers[J]=NodeI then Roots.Delete(J);
    if Active and not (Outer and (O.Get('slot','')='top')) then begin
      Roots.Add(NodeI);
      if (O.Get('slot','')='top') or (O.Get('slot','')='outer') then begin
        Top:=True;LongSleeve:=LongSleeve or O.Get('coversArms',False);
      end;
      Bottom:=Bottom or (O.Get('slot','')='bottom');
    end;
  end;
  Base:=ArrOf(WardrobeData(Doc),'baseMeshes');
  for I:=0 to CountOf(Base)-1 do begin
    O:=ObjAt(Base,I);MeshI:=O.Get('mesh',-1);Region:=BaseRegion(Doc,MeshI);
    if Region='' then Continue;
    Mesh:=ObjAt(ArrOf(Doc.Root,'meshes'),MeshI);Prims:=ArrOf(O,'primitives');
    Visible:=TJSONArray.Create;
    for J:=0 to CountOf(Prims)-1 do begin
      P:=ObjAt(Prims,J);Hide:=False;
      if (Region='top') and Top then
        Hide:=LongSleeve or (Pos('skin',LowerCase(StrOf(ObjAt(ArrOf(Doc.Root,'materials'),IntOf(P,'material',-1)),'name','')))=0);
      if Region='bottom' then Hide:=Bottom or (Top and FabricPrimitive(Doc,P));
      if (Region='logo') and Top then Hide:=True;
      if (Region='feet') and Feet then Hide:=True;
      N:=TJSONObject(P.Clone);
      if Hide then Put(N,'material',TJSONIntegerNumber.Create(HiddenMaterial));
      Visible.Add(N);
    end;
    { Keep every original primitive and its index: pose corrective atlases
      address those exact shape names and vertex counts. Alpha masking hides
      the underlying kit without invalidating the rig or exported GLB. }
    if Visible.Count>0 then Put(Mesh,'primitives',Visible) else Visible.Free;
  end;
  O:=WardrobeData(Doc);N:=RiderEquipmentInfo(Doc.Root,'helmet',True);
  if Head then begin
    if not HasKey(O,'helmetBeforeHat') then O.Add('helmetBeforeHat',N.Get('enabled',True));
    Put(N,'enabled',TJSONBoolean.Create(False));
  end else if HasKey(O,'helmetBeforeHat') then begin
    Put(N,'enabled',O.Find('helmetBeforeHat').Clone);O.Delete('helmetBeforeHat');
  end;
  Doc.RefreshHierarchy;
end;

function NewMaterial(Doc: TGlbDoc; const Id,Hex: string): Integer;
var M: TJSONObject; C: TVec3;
begin
  C:=MaterialColor(Hex);
  M:=TJSONObject.Create(['name','AvatarCloth_'+Id,'doubleSided',True]);
  M.Add('pbrMetallicRoughness',TJSONObject.Create([
    'baseColorFactor',TJSONArray.Create([C.X,C.Y,C.Z,1.0]),'metallicFactor',0.0,'roughnessFactor',0.86]));
  Result:=ArrayChild(Doc.Root,'materials').Count;ArrayChild(Doc.Root,'materials').Add(M);
end;

function MakeItem(Doc: TGlbDoc; const Name,Slot,Preset: string; Mesh: TJSONObject;
  Materials: TJSONArray): TJSONObject;
var A,Prims: TJSONArray; I,MeshI,NodeI: Integer; Id: string; N,Acc: TJSONObject;
  MinY,MaxY: Double;
begin
  MeshI:=ArrayChild(Doc.Root,'meshes').Count;
  NodeI:=ArrayChild(Doc.Root,'nodes').Count;Id:='garment_'+IntToStr(NodeI);
  Put(Mesh,'name',TJSONString.Create('AvatarCloth_'+Id));
  ArrayChild(Doc.Root,'meshes').Add(Mesh);
  N:=TJSONObject.Create(['name','AvatarCloth_'+Id,'mesh',MeshI,'skin',Doc.MainSkinIndex]);
  ArrayChild(Doc.Root,'nodes').Add(N);
  Result:=TJSONObject.Create(['id',Id,'name',Name,'slot',Slot,'preset',Preset,
    'enabled',True,'node',NodeI,'stiffness',0.4,'flutter',0.65,'wind',1.5,
    'color','#b8cbd1','coversArms',Preset='sweatshirt']);
  Result.Add('cloth',(Slot<>'head') and (Slot<>'feet'));
  Result.Add('materials',Materials);
  for I:=0 to Materials.Count-1 do
    Put(ObjAt(ArrOf(Doc.Root,'materials'),Materials.Integers[I]),'name',
      TJSONString.Create('AvatarCloth_'+Id+'_'+IntToStr(I)));
  MinY:=1e20;MaxY:=-1e20;Prims:=ArrOf(Mesh,'primitives');
  for I:=0 to CountOf(Prims)-1 do begin
    Acc:=ObjAt(ArrOf(Doc.Root,'accessors'),IntOf(ObjOf(ObjAt(Prims,I),'attributes'),'POSITION',-1));
    MinY:=Min(MinY,ArrFloat(ArrOf(Acc,'min'),1,0));MaxY:=Max(MaxY,ArrFloat(ArrOf(Acc,'max'),1,1));
  end;
  Result.Add('pinTop',MaxY);Result.Add('pinBottom',MinY);
  A:=WardrobeItems(Doc);
  for I:=0 to A.Count-1 do if ObjAt(A,I).Get('slot','')=Slot then
    Put(ObjAt(A,I),'enabled',TJSONBoolean.Create(False));
  A.Add(Result);
end;

procedure AddAccessory(Doc:TGlbDoc;const Preset:string);
var Mesh,Item:TJSONObject;Mats:TJSONArray;Name,Slot,Hex:string;
begin
  Slot:='head';Hex:='#7d4740';
  if Preset='beanie' then Name:='Шапка с отворотом'
  else if Preset='cap' then begin Name:='Бейсболка';Hex:='#36516b' end
  else if Preset='bucket' then begin Name:='Панама';Hex:='#b4a382' end
  else begin
    Slot:='feet';
    if Preset='sneakers' then begin Name:='Повседневные кроссовки';Hex:='#eee9df' end
    else if Preset='boots' then begin Name:='Кожаные ботинки';Hex:='#73513d' end
    else if Preset='loafers' then begin Name:='Лоферы';Hex:='#3f3531' end
    else raise EArgumentException.Create('Unknown clothing preset: '+Preset);
  end;
  CaptureBase(Doc);Mesh:=nil;Mats:=nil;
  try
    BuildWardrobeAccessory(Doc,Preset,Hex,Mesh,Mats);
    Item:=MakeItem(Doc,Name,Slot,Preset,Mesh,Mats);Mesh:=nil;Mats:=nil;
    Put(Item,'color',TJSONString.Create(Hex));
    Item.Add('tintMaterials',TJSONArray.Create([ArrOf(Item,'materials').Integers[0]]));
    SyncVisibility(Doc);
  finally Mesh.Free;Mats.Free end;
end;

procedure RemoveDonorPockets(Doc:TGlbDoc;Prim:TJSONObject;const P:TFloats;Scale:Single);
var Idx,OutIdx:TFloats;Parent:array of Integer;Lo,Hi:array of TVec3;
  I,A,B,C,N,Count:Integer;Weld:TStringList;Key:string;Keep:Boolean;
  function Root(V:Integer):Integer;
  var Next:Integer;
  begin
    Result:=V;while Parent[Result]<>Result do Result:=Parent[Result];
    while Parent[V]<>V do begin Next:=Parent[V];Parent[V]:=Result;V:=Next end;
  end;
begin
  N:=Length(P)div 3;SetLength(Parent,N);SetLength(Lo,N);SetLength(Hi,N);
  Weld:=TStringList.Create;Weld.Sorted:=True;
  try
    for I:=0 to N-1 do begin
      Parent[I]:=I;Key:=PositionKey(P,I);A:=Weld.IndexOf(Key);
      if A<0 then Weld.AddObject(Key,TObject(PtrInt(I)))else Parent[I]:=PtrInt(Weld.Objects[A]);
      Lo[I]:=V3(1e10,1e10,1e10);Hi[I]:=V3(-1e10,-1e10,-1e10);
    end;
    Idx:=ReadAcc(Doc,IntOf(Prim,'indices',-1),C);
    I:=0;while I+2<Length(Idx)do begin
      A:=Root(Round(Idx[I]));B:=Root(Round(Idx[I+1]));Parent[B]:=A;
      B:=Root(Round(Idx[I+2]));Parent[B]:=Root(A);Inc(I,3);
    end;
    for I:=0 to High(Idx)do begin
      B:=Round(Idx[I]);A:=Root(B);
      Lo[A].X:=Min(Lo[A].X,P[B*3]);Hi[A].X:=Max(Hi[A].X,P[B*3]);
      Lo[A].Y:=Min(Lo[A].Y,P[B*3+1]);Hi[A].Y:=Max(Hi[A].Y,P[B*3+1]);
      Lo[A].Z:=Min(Lo[A].Z,P[B*3+2]);Hi[A].Z:=Max(Hi[A].Z,P[B*3+2]);
    end;
    SetLength(OutIdx,Length(Idx));Count:=0;I:=0;
    while I+2<Length(Idx)do begin
      A:=Root(Round(Idx[I]));
      Keep:=not((Hi[A].Y<1.22*Scale)and(Lo[A].Y>0.999*Scale)and(Hi[A].Z<-0.064*Scale));
      if Keep then begin
        OutIdx[Count]:=Idx[I];OutIdx[Count+1]:=Idx[I+1];OutIdx[Count+2]:=Idx[I+2];Inc(Count,3);
      end;
      Inc(I,3);
    end;
    if(Count>0)and(Count<Length(Idx))then begin
      SetLength(OutIdx,Count);Put(Prim,'indices',TJSONIntegerNumber.Create(AddAcc(Doc,OutIdx,1,'SCALAR',True)));
    end;
  finally Weld.Free end;
end;

procedure AddPreset(Doc: TGlbDoc; const Preset: string);
var Base,Prims,OutPrims,Mats,Origins: TJSONArray; I,J,K,C,MatI,Index,TailIndex: Integer;
  B,P,Attr,Q,M,Item: TJSONObject; Positions,Normals: TFloats;
  Slot,Name,Region,Id,Hex,BaseSlot: string; Clearance,Scale,BindScale,Pin,YMin,YMax,NormalLength: Single;
  Weld:TWeldNormals;Sum:TNormalSum;
  Loose:Boolean;Point,Normal:TVec3;MaterialName:string;
  GarmentFrame:TGarmentFrame;
begin
  Slot:='top';Hex:='#b8cbd1';
  if Preset='tshirt' then Name:='Свободная футболка'
  else if Preset='sweatshirt' then begin Name:='Свитшот';Hex:='#bda58a' end
  else if Preset='trousers' then begin Name:='Повседневные брюки';Slot:='bottom';Hex:='#304b6a' end
  else if Preset='jacket' then begin Name:='Повседневная куртка';Slot:='outer';Hex:='#52634f' end
  else if Preset='coat' then begin Name:='Пальто';Slot:='outer';Hex:='#8f6d4e' end
  else if Preset='jeans' then begin Name:='Свободные джинсы';Slot:='bottom';Hex:='#345577' end
  else if Preset='loose_jacket' then begin Name:='Свободная куртка';Slot:='outer';Hex:='#65765a' end
  else if Preset='raincoat' then begin Name:='Свободный плащ';Slot:='outer';Hex:='#b99f78' end
  else begin AddAccessory(Doc,Preset);Exit end;
  Loose:=(Preset='jeans') or (Preset='loose_jacket') or (Preset='raincoat');
  BaseSlot:=Slot;if Slot='outer' then BaseSlot:='top';
  CaptureBase(Doc);Base:=ArrOf(WardrobeData(Doc),'baseMeshes');
  { A common attachment field across material splits keeps sewn boundaries
    coincident. Per-primitive bounds would open gaps at shoulders and cuffs. }
  YMin:=1e20;YMax:=-1e20;
  for I:=0 to Base.Count-1 do begin
    B:=ObjAt(Base,I);if BaseRegion(Doc,B.Get('mesh',-1))<>BaseSlot then Continue;
    Prims:=ArrOf(B,'primitives');
    for J:=0 to CountOf(Prims)-1 do begin
      Attr:=ObjOf(ObjAt(Prims,J),'attributes');Positions:=ReadAcc(Doc,IntOf(Attr,'POSITION',-1),C);
      for K:=0 to Length(Positions) div 3-1 do begin
        YMin:=Min(YMin,Positions[K*3+1]);YMax:=Max(YMax,Positions[K*3+1]);
      end;
    end;
  end;
  Id:='garment_'+IntToStr(Doc.NodeCount);MatI:=NewMaterial(Doc,Id,Hex);
  M:=TJSONObject.Create;OutPrims:=TJSONArray.Create;M.Add('primitives',OutPrims);
  Mats:=TJSONArray.Create([MatI]);Origins:=TJSONArray.Create;Scale:=Max(0.1,Doc.MeshExtentY/1.8);Weld:=nil;
  BindScale:=WardrobeBindScale(Doc);
  if Slot='outer'then InitGarmentFrame(Doc,GarmentFrame);
  try
    { A split at a material/UV boundary is still one sewn surface. Use the
      same clearance direction on both sides for every preset, including
      fitted shirts and trousers, not only loose outerwear. }
    if Preset='jeans'then BuildJeansMesh(Doc,M,MatI)
    else begin
    Weld:=BuildWeldNormals(Doc,Base,BaseSlot);
    for I:=0 to Base.Count-1 do begin
      B:=ObjAt(Base,I);Region:=BaseRegion(Doc,B.Get('mesh',-1));
      if Region<>BaseSlot then Continue;
      Prims:=ArrOf(B,'primitives');
      for J:=0 to CountOf(Prims)-1 do begin
        P:=ObjAt(Prims,J);
        MaterialName:=LowerCase(StrOf(ObjAt(ArrOf(Doc.Root,'materials'),IntOf(P,'material',-1)),'name',''));
        { Sew outerwear independently of the bicycle jersey's small hardware. }
        if(Slot='outer')and((Pos('zipper',MaterialName)>0)or(Pos('binding',MaterialName)>0))then Continue;
        if (Preset='tshirt') and
          (Pos('skin',LowerCase(StrOf(ObjAt(ArrOf(Doc.Root,'materials'),IntOf(P,'material',-1)),'name','')))>0) then Continue;
        Attr:=ObjOf(P,'attributes');Positions:=ReadAcc(Doc,IntOf(Attr,'POSITION',-1),C);
        if C<>3 then raise EReadError.Create('Expected VEC3 positions');
        Normals:=ReadAcc(Doc,IntOf(Attr,'NORMAL',-1),C);
        if Length(Normals)<>Length(Positions) then raise EReadError.Create('Invalid normal count');
        Q:=TJSONObject(P.Clone);Q.Delete('targets');OutPrims.Add(Q);
        if Slot='outer'then RemoveDonorPockets(Doc,Q,Positions,BindScale);
        for K:=0 to Length(Positions) div 3-1 do begin
          Index:=Weld.IndexOf(PositionKey(Positions,K));
          if Index>=0 then begin
            Sum:=TNormalSum(Weld.Objects[Index]);
            NormalLength:=Sqrt(Sqr(Sum.X)+Sqr(Sum.Y)+Sqr(Sum.Z));
            if NormalLength>1e-6 then begin
              Normals[K*3]:=Sum.X/NormalLength;Normals[K*3+1]:=Sum.Y/NormalLength;Normals[K*3+2]:=Sum.Z/NormalLength;
            end;
          end;
          Pin:=EnsureRange((YMax-Positions[K*3+1])/Max(0.01,YMax-YMin),0.0,1.0);
          if Slot='outer'then begin
            Point:=V3(Positions[K*3],Positions[K*3+1],Positions[K*3+2]);
            Normal:=V3(Normals[K*3],Normals[K*3+1],Normals[K*3+2]);
            TailorOuterPoint(GarmentFrame,Preset,Point,Normal);
            Positions[K*3]:=Point.X;Positions[K*3+1]:=Point.Y;Positions[K*3+2]:=Point.Z;
            Continue;
          end;
          Clearance:=Scale*(0.008+0.023*Pin);
          if Preset='trousers' then Clearance:=Scale*0.018;
          Point:=V3(Positions[K*3],Positions[K*3+1],Positions[K*3+2]);
          Normal:=V3(Normals[K*3],Normals[K*3+1],Normals[K*3+2]);
          if BaseSlot='top'then Normal:=GarmentClearanceDirection(Point,Normal,BindScale);
          Positions[K*3]:=Positions[K*3]+Normal.X*Clearance;
          Positions[K*3+1]:=Positions[K*3+1]+Normal.Y*Clearance;
          Positions[K*3+2]:=Positions[K*3+2]+Normal.Z*Clearance;
        end;
        Attr:=ObjOf(Q,'attributes');
        Attr.Delete('TANGENT');Index:=AddAcc(Doc,Positions,3,'VEC3');
        Put(Attr,'POSITION',TJSONIntegerNumber.Create(Index));
        if Weld<>nil then Put(Attr,'NORMAL',TJSONIntegerNumber.Create(AddAcc(Doc,Normals,3,'VEC3')));
        Put(Q,'material',TJSONIntegerNumber.Create(MatI));
        Origins.Add(StrOf(ObjAt(ArrOf(Doc.Root,'meshes'),B.Get('mesh',-1)),'name','')+'_Primitive'+IntToStr(J));
      end;
    end;
    end;
    if OutPrims.Count=0 then raise EReadError.Create('This avatar has no separated upper/lower body. Import a fitted GLB garment instead.');
    TailIndex:=-1;
    if Slot='outer'then begin
      TrimOuterwearJoin(Doc,Preset,M);
      { The cut has its own topology, so bind its body proportions by
        surface proximity, just like the independently sewn hem. }
      Origins.Clear;
      OutPrims:=ArrOf(M,'primitives');
      TailorOuterWeights(Doc,M);
      TailIndex:=OutPrims.Count;AddOuterwearPanels(Doc,Preset,M,MatI);
    end;
    if Slot='outer' then AddOuterwearDetails(Doc,Preset,M,Mats);
    if Preset='jeans'then AddJeansDetails(Doc,M,Mats);
    if(BaseSlot='top')or(Preset='jeans')then RebuildGarmentNormals(Doc,M);
    Item:=MakeItem(Doc,Name,Slot,Preset,M,Mats);M:=nil;Mats:=nil;
    Item.Add('sourceShapes',Origins);Origins:=nil;
    if Preset='jeans'then
      Item.Add('tintMaterials',TJSONArray.Create([ArrOf(Item,'materials').Integers[0]]));
    if TailIndex>=0 then Item.Add('tailPrimitive',TailIndex);
    if Slot='outer' then begin
      Item.Add('tintMaterials',TJSONArray.Create([ArrOf(Item,'materials').Integers[0]]));
      Put(Item,'coversArms',TJSONBoolean.Create(True));
      Put(Item,'flutter',TJSONFloatNumber.Create(0.8));
      Put(Item,'stiffness',TJSONFloatNumber.Create(0.55));
    end;
    if Loose then begin
      Item.Add('simulation',True);Item.Add('density',350.0);
      if Preset='jeans' then begin
        { Dense denim uses cached pose folds by default. The editor may
          explicitly enable its full mesh solver for loose custom fabrics. }
        Put(Item,'simulation',TJSONBoolean.Create(False));
        Put(Item,'stiffness',TJSONFloatNumber.Create(0.86));
        Put(Item,'flutter',TJSONFloatNumber.Create(0.45));Put(Item,'density',TJSONFloatNumber.Create(420));
      end else if Preset='raincoat' then begin
        Put(Item,'stiffness',TJSONFloatNumber.Create(0.4));
        Put(Item,'flutter',TJSONFloatNumber.Create(0.95));Put(Item,'density',TJSONFloatNumber.Create(190));
      end;
    end;
    Put(Item,'color',TJSONString.Create(Hex));SyncVisibility(Doc);
  finally Weld.Free;M.Free;Mats.Free;Origins.Free end;
end;

procedure ReadBody(Doc: TGlbDoc; const Slot: string; out Body: TBodyPoints;
  out Lo,Hi: TVec3);
var Base,A: TJSONArray; B,P,Attr: TJSONObject; I,J,K,L,C,N,Count: Integer;
  Pos,Joints,Weights: TFloats; Cut: Single;
begin
  Body:=nil;Count:=0;Base:=ArrOf(WardrobeData(Doc),'baseMeshes');
  Lo:=V3(1e20,1e20,1e20);Hi:=V3(-1e20,-1e20,-1e20);
  for I:=0 to CountOf(Base)-1 do begin
    B:=ObjAt(Base,I);
    if BaseRegion(Doc,B.Get('mesh',-1))<>Slot then Continue;
    A:=ArrOf(B,'primitives');
    for J:=0 to CountOf(A)-1 do begin
      P:=ObjAt(A,J);Attr:=ObjOf(P,'attributes');
      if not HasKey(Attr,'JOINTS_0') then Continue;
      Pos:=ReadAcc(Doc,IntOf(Attr,'POSITION',-1),C);N:=Length(Pos) div 3;
      Joints:=ReadAcc(Doc,IntOf(Attr,'JOINTS_0',-1),C);
      Weights:=ReadAcc(Doc,IntOf(Attr,'WEIGHTS_0',-1),C);
      if (Length(Joints)<>N*4) or (Length(Weights)<>N*4) then raise EReadError.Create('Invalid body skin');
      SetLength(Body,Count+N);
      for K:=0 to N-1 do begin
        Body[Count+K].P:=V3(Pos[K*3],Pos[K*3+1],Pos[K*3+2]);
        Lo.X:=Min(Lo.X,Pos[K*3]);Hi.X:=Max(Hi.X,Pos[K*3]);
        Lo.Y:=Min(Lo.Y,Pos[K*3+1]);Hi.Y:=Max(Hi.Y,Pos[K*3+1]);
        Lo.Z:=Min(Lo.Z,Pos[K*3+2]);Hi.Z:=Max(Hi.Z,Pos[K*3+2]);
        for L:=0 to 3 do begin Body[Count+K].J[L]:=Joints[K*4+L];Body[Count+K].W[L]:=Weights[K*4+L] end;
      end;
      Inc(Count,N);
    end;
  end;
  if (Slot='head') and (Count>0) then begin
    Cut:=Lo.Y+0.63*(Hi.Y-Lo.Y);N:=0;
    Lo:=V3(1e20,1e20,1e20);Hi:=V3(-1e20,-1e20,-1e20);
    for K:=0 to Count-1 do if Body[K].P.Y>=Cut then begin
      Body[N]:=Body[K];Inc(N);
      Lo.X:=Min(Lo.X,Body[K].P.X);Hi.X:=Max(Hi.X,Body[K].P.X);
      Lo.Y:=Min(Lo.Y,Body[K].P.Y);Hi.Y:=Max(Hi.Y,Body[K].P.Y);
      Lo.Z:=Min(Lo.Z,Body[K].P.Z);Hi.Z:=Max(Hi.Z,Body[K].P.Z);
    end;
    Count:=N;SetLength(Body,Count);
  end;
  if Count=0 then raise EReadError.Create('Avatar has no body region for automatic clothing binding');
end;

procedure ReadGarmentGeometry(Src: TGlbDoc; MeshIndex: Integer; Prim: TJSONObject;
  out Positions,Normals: TFloats);
var Attr: TJSONObject; I,C,NodeI: Integer; World,Inv: TMat4; P,N: TVec3; Len: Double;
begin
  NodeI:=-1;
  for I:=0 to Src.NodeCount-1 do if IntOf(Src.NodeObj(I),'mesh',-1)=MeshIndex then begin
    if NodeI>=0 then raise EReadError.Create('Apply clothing mesh instances before import');
    NodeI:=I;
  end;
  if NodeI<0 then raise EReadError.Create('Clothing contains an unattached mesh');
  World:=Src.NodeWorldMatrix(NodeI);
  if not M4InvertAffine(World,Inv) then raise EReadError.Create('Clothing has a zero scale');
  Attr:=ObjOf(Prim,'attributes');Positions:=ReadAcc(Src,IntOf(Attr,'POSITION',-1),C);
  if C<>3 then raise EReadError.Create('Clothing needs VEC3 positions');
  Normals:=ReadAcc(Src,IntOf(Attr,'NORMAL',-1),C);
  if (C<>3) or (Length(Normals)<>Length(Positions)) then raise EReadError.Create('Clothing needs vertex normals');
  for I:=0 to Length(Positions) div 3-1 do begin
    P:=M4MulPoint(World,V3(Positions[I*3],Positions[I*3+1],Positions[I*3+2]));
    Positions[I*3]:=P.X;Positions[I*3+1]:=P.Y;Positions[I*3+2]:=P.Z;
    N:=V3(Normals[I*3],Normals[I*3+1],Normals[I*3+2]);
    P:=V3(Inv[0]*N.X+Inv[1]*N.Y+Inv[2]*N.Z,
      Inv[4]*N.X+Inv[5]*N.Y+Inv[6]*N.Z,Inv[8]*N.X+Inv[9]*N.Y+Inv[10]*N.Z);
    Len:=Max(V3Len(P),1e-8);Normals[I*3]:=P.X/Len;Normals[I*3+1]:=P.Y/Len;Normals[I*3+2]:=P.Z/Len;
  end;
end;

procedure ImportClothing(Doc: TGlbDoc; const Path,Slot,Name: string);
var Src: TGlbDoc; Body: TBodyPoints; Lo,Hi,SLo,SHi,Pnt,D: TVec3;
  SrcMeshes,Prims,OutPrims,Mats: TJSONArray;
  Prim,Attr,NewP,NewAttr,M,Item: TJSONObject;
  I,J,K,L,N,Best,MI,MatI,Idx: Integer;
  Positions,Normals,Js,Ws: TFloats; Dist,BestDist,Len,Total: Double;
  Region,Id,Key: string; Scale: TVec3;
begin
  if (Slot<>'top') and (Slot<>'bottom') and (Slot<>'outer') and (Slot<>'head') and (Slot<>'feet') then
    raise EArgumentException.Create('Slot must be top, bottom, outer, head or feet');
  CaptureBase(Doc);Region:=Slot;if Region='outer' then Region:='top';
  ReadBody(Doc,Region,Body,Lo,Hi);Src:=TGlbDoc.Create;M:=nil;Mats:=nil;
  try
    if not Src.LoadFromFile(Path) then raise EReadError.Create('Cannot load clothing GLB');
    if CountOf(ArrOf(Src.Root,'extensionsRequired'))>0 then raise EReadError.Create('Import requires an uncompressed standard GLB');
    SrcMeshes:=ArrOf(Src.Root,'meshes');SLo:=V3(1e20,1e20,1e20);SHi:=V3(-1e20,-1e20,-1e20);
    N:=0;
    for I:=0 to CountOf(SrcMeshes)-1 do begin
      Prims:=ArrOf(ObjAt(SrcMeshes,I),'primitives');
      for J:=0 to CountOf(Prims)-1 do begin
        Prim:=ObjAt(Prims,J);
        if IntOf(Prim,'mode',4)<>4 then raise EReadError.Create('Only triangle clothing meshes are supported');
        ReadGarmentGeometry(Src,I,Prim,Positions,Normals);
        Inc(N,Length(Positions) div 3);
        for K:=0 to Length(Positions) div 3-1 do begin
          SLo.X:=Min(SLo.X,Positions[K*3]);SHi.X:=Max(SHi.X,Positions[K*3]);
          SLo.Y:=Min(SLo.Y,Positions[K*3+1]);SHi.Y:=Max(SHi.Y,Positions[K*3+1]);
          SLo.Z:=Min(SLo.Z,Positions[K*3+2]);SHi.Z:=Max(SHi.Z,Positions[K*3+2]);
        end;
      end;
    end;
    if (N=0) or (N>50000) then raise EReadError.Create('Import clothing with 1 to 50000 vertices');
    Scale:=V3((Hi.X-Lo.X+0.02)/Max(0.001,SHi.X-SLo.X),
      (Hi.Y-Lo.Y)/Max(0.001,SHi.Y-SLo.Y),(Hi.Z-Lo.Z+0.025)/Max(0.001,SHi.Z-SLo.Z));
    if Region='top' then Scale.X:=Scale.Y;
    if Region='feet' then begin
      Scale.Y:=Min(Scale.X,Scale.Z);Scale.X:=Scale.Y;Scale.Z:=Scale.Y;
    end;
    if Region='head' then begin
      Scale.Y:=Scale.X;Scale.Z:=Scale.X;Lo.Y:=Lo.Y+0.015;
    end;
    Id:='garment_'+IntToStr(Doc.NodeCount);M:=TJSONObject.Create;OutPrims:=TJSONArray.Create;
    M.Add('primitives',OutPrims);Mats:=TJSONArray.Create;
    for I:=0 to CountOf(SrcMeshes)-1 do begin
      Prims:=ArrOf(ObjAt(SrcMeshes,I),'primitives');
      for J:=0 to CountOf(Prims)-1 do begin
        Prim:=ObjAt(Prims,J);Attr:=ObjOf(Prim,'attributes');
        ReadGarmentGeometry(Src,I,Prim,Positions,Normals);N:=Length(Positions) div 3;
        SetLength(Js,N*4);SetLength(Ws,N*4);
        for K:=0 to N-1 do begin
          Pnt:=V3((Positions[K*3]-(SLo.X+SHi.X)*0.5)*Scale.X+(Lo.X+Hi.X)*0.5,
            (Positions[K*3+1]-SLo.Y)*Scale.Y+Lo.Y,
            (Positions[K*3+2]-SLo.Z)*Scale.Z+Lo.Z-0.0125);
          Best:=0;BestDist:=1e30;
          for L:=0 to High(Body) do begin
            D:=V3Sub(Pnt,Body[L].P);Dist:=Sqr(D.X)+Sqr(D.Y)+Sqr(D.Z);
            if Dist<BestDist then begin BestDist:=Dist;Best:=L end;
          end;
          Positions[K*3]:=Pnt.X;Positions[K*3+1]:=Pnt.Y;Positions[K*3+2]:=Pnt.Z;
          Total:=0;for L:=0 to 3 do Total:=Total+Body[Best].W[L];
          if Total<1e-8 then raise EReadError.Create('Body has unweighted vertices');
          for L:=0 to 3 do begin Js[K*4+L]:=Body[Best].J[L];Ws[K*4+L]:=Body[Best].W[L]/Total end;
          Normals[K*3]:=Normals[K*3]/Scale.X;Normals[K*3+1]:=Normals[K*3+1]/Scale.Y;Normals[K*3+2]:=Normals[K*3+2]/Scale.Z;
          Len:=Sqrt(Sqr(Normals[K*3])+Sqr(Normals[K*3+1])+Sqr(Normals[K*3+2]));
          for L:=0 to 2 do Normals[K*3+L]:=Normals[K*3+L]/Max(Len,1e-8);
        end;
        NewP:=TJSONObject.Create;NewAttr:=TJSONObject.Create;NewP.Add('attributes',NewAttr);OutPrims.Add(NewP);
        NewAttr.Add('POSITION',AddAcc(Doc,Positions,3,'VEC3'));NewAttr.Add('NORMAL',AddAcc(Doc,Normals,3,'VEC3'));
        NewAttr.Add('JOINTS_0',AddAcc(Doc,Js,4,'VEC4',True));NewAttr.Add('WEIGHTS_0',AddAcc(Doc,Ws,4,'VEC4'));
        for L:=0 to Attr.Count-1 do begin
          Key:=Attr.Names[L];
          if (Key='TEXCOORD_0') or (Key='TEXCOORD_1') then begin
            Idx:=Doc.CloneAccessorFrom(Src,Attr.Items[L].AsInteger);NewAttr.Add(Key,Idx);
          end;
        end;
        if HasKey(Prim,'indices') then NewP.Add('indices',Doc.CloneAccessorFrom(Src,Prim.Get('indices',-1)));
        MI:=IntOf(Prim,'material',-1);
        if MI>=0 then MatI:=Doc.CloneMaterialFrom(Src,MI) else MatI:=NewMaterial(Doc,Id,'#b8cbd1');
        ObjAt(ArrOf(Doc.Root,'materials'),MatI).Delete('extensions');
        Put(ObjAt(ArrOf(Doc.Root,'materials'),MatI),'name',TJSONString.Create('AvatarCloth_'+Id+'_'+IntToStr(J)));
        Put(ObjAt(ArrOf(Doc.Root,'materials'),MatI),'doubleSided',TJSONBoolean.Create(True));
        Mats.Add(MatI);NewP.Add('material',MatI);
      end;
    end;
    Item:=MakeItem(Doc,Name,Slot,'import',M,Mats);M:=nil;Mats:=nil;
    Item.Add('source',ExtractFileName(Path));SyncVisibility(Doc);
  finally Src.Free;M.Free;Mats.Free end;
end;

procedure ChangeWardrobe(Doc: TGlbDoc; Params: TJSONObject);
var Action,Id,Key: string; Item,O,Pbr: TJSONObject; A: TJSONArray;
  I: Integer; V: Double; Color: TVec3;
begin
  if (Doc=nil) or (Doc.Root=nil) then raise EArgumentException.Create('Open an avatar first');
  Action:=Params.Get('action','list');
  if Action='list' then Exit;
  if Action='add' then begin AddPreset(Doc,Params.Get('preset','tshirt'));Exit end;
  if Action='import' then begin
    ImportClothing(Doc,Params.Get('path',''),Params.Get('slot','top'),
      Params.Get('name',ChangeFileExt(ExtractFileName(Params.Get('path','')),'')));Exit;
  end;
  Id:=Params.Get('id','');Item:=WardrobeItem(Doc,Id);
  if Item=nil then raise EArgumentException.Create('Unknown garment: '+Id);
  if Action='remove' then begin
    Put(Item,'enabled',TJSONBoolean.Create(False));SyncVisibility(Doc);
    A:=WardrobeItems(Doc);
    for I:=A.Count-1 downto 0 do if ObjAt(A,I)=Item then A.Delete(I);
    Exit;
  end;
  if Action<>'update' then raise EArgumentException.Create('Unknown wardrobe action: '+Action);
  for I:=0 to Params.Count-1 do begin
    Key:=Params.Names[I];
    if (Key='stiffness') or (Key='flutter') or (Key='wind') or (Key='density') then begin
      V:=Params.Items[I].AsFloat;
      if IsNan(V) or IsInfinite(V) or (V<0) or
        ((Key='density') and ((V<80) or (V>900))) or
        ((Key='wind') and (V>20)) or
        (((Key='stiffness') or (Key='flutter')) and (V>1)) then
        raise EArgumentException.Create('Invalid '+Key);
    end;
    if Key='color' then WardrobeColor(Params.Items[I].AsString);
  end;
  for I:=0 to Params.Count-1 do begin
    Key:=Params.Names[I];
    if (Key='name') or (Key='enabled') or (Key='stiffness') or
      (Key='flutter') or (Key='wind') or (Key='coversArms') or (Key='color') or
      (Key='simulation') or (Key='density') then
      Put(Item,Key,Params.Items[I].Clone);
  end;
  if Item.Get('enabled',False) then begin
    A:=WardrobeItems(Doc);
    for I:=0 to CountOf(A)-1 do if (ObjAt(A,I)<>Item) and
      (ObjAt(A,I).Get('slot','')=Item.Get('slot','')) then
        Put(ObjAt(A,I),'enabled',TJSONBoolean.Create(False));
  end;
  if HasKey(Params,'color') then begin
    Color:=MaterialColor(Item.Get('color','#b8cbd1'));A:=ArrOf(Item,'tintMaterials');
    if A=nil then A:=ArrOf(Item,'materials');
    for I:=0 to CountOf(A)-1 do begin
      O:=ObjAt(ArrOf(Doc.Root,'materials'),A.Integers[I]);Pbr:=ObjectChild(O,'pbrMetallicRoughness');
      Put(Pbr,'baseColorFactor',TJSONArray.Create([Color.X,Color.Y,Color.Z,1.0]));
    end;
  end;
  SyncVisibility(Doc);
end;
end.
