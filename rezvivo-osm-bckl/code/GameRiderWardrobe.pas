unit GameRiderWardrobe;
{$mode objfpc}{$H+}{$codepage utf8}
interface
uses Classes, SysUtils, fpjson, RiderTripo, RiderHeadAppearance,
  CastleUIControls, CastleControls, CastleVectors, GameMenuTheme;
const
  WardrobeSlots:array[0..4]of string=('top','bottom','outer','feet','head');
function WardrobeSelection(Slot:Integer):string;
procedure SelectWardrobe(const Slot,Preset:string);
function WardrobeRiderPath(const BasePath:string):string;
function WardrobeHeadwear:TRiderHeadwear;
procedure WardrobeState(Rider:TTripoRiderScene;Result:TJSONObject);
type
  TGameWardrobePanel=class(TCastleUserInterface)
  private
    FTitle:TCastleLabel;
    FLabels:array[0..4]of TCastleLabel;
    FChoices:array[0..4]of TMenuButton;
    FPrev,FNext:array[0..4]of TMenuButton;
    FColors:array[0..4]of TMenuButton;
    FOnChange,FOnColorClick:TNotifyEvent;
    procedure Click(Sender:TObject);
    procedure ClickColor(Sender:TObject);
  public
    constructor Create(AOwner:TComponent);override;
    procedure Resize;override;
    procedure Refresh;
    procedure SetColor(Slot:Integer;const C:TVector4);
    property OnChange:TNotifyEvent read FOnChange write FOnChange;
    property OnColorClick:TNotifyEvent read FOnColorClick write FOnColorClick;
  end;
implementation
uses Math, SyncObjs, md5, jsonparser, UiTranslations, GameUserData,
  GameRouteLibraryData, GltfCore, AvatarGlbIO, AvatarWardrobe, AvatarClothMotion, X3DNodes,
  RiderHair, RiderOcclusion, RiderBodyParameters;
const
  SlotTitles:array[0..4]of string=('Top','Bottom','Outer layer','Footwear','Headwear');
  OptionCount:array[0..4]of Integer=(3,3,5,4,4);
  Options:array[0..4,0..4]of string=(
    ('','tshirt','sweatshirt','',''),('','trousers','jeans','',''),
    ('','jacket','coat','loose_jacket','raincoat'),
    ('','sneakers','boots','loafers',''),('','beanie','cap','bucket',''));
  Titles:array[0..4,0..4]of string=(
    ('Cycling jersey','T-shirt','Sweatshirt','',''),
    ('Cycling shorts','Trousers','Jeans','',''),
    ('None','Jacket','Coat','Loose jacket','Raincoat'),
    ('Cycling shoes','Sneakers','Boots','Loafers',''),
    ('Use head editor','Beanie','Baseball cap','Bucket hat',''));
var BuildLock:TCriticalSection;

function OptionIndex(Slot:Integer;const Preset:string):Integer;
begin
  for Result:=0 to OptionCount[Slot]-1 do if Options[Slot,Result]=Preset then Exit;
  Result:=-1;
end;
function WardrobeSelection(Slot:Integer):string;
begin
  Result:=UserPreference('avatar_clothing_'+WardrobeSlots[Slot]);
  if OptionIndex(Slot,Result)<0 then Result:='';
end;
procedure SelectWardrobe(const Slot,Preset:string);
var I:Integer;
begin
  for I:=0 to High(WardrobeSlots)do if Slot=WardrobeSlots[I]then begin
    if OptionIndex(I,Preset)<0 then raise EArgumentException.Create('Unknown clothing preset for '+Slot);
    SetUserPreference('avatar_clothing_'+Slot,Preset);Exit;
  end;
  raise EArgumentException.Create('Unknown clothing slot: '+Slot);
end;
function WardrobeHeadwear:TRiderHeadwear;
begin
  if WardrobeSelection(4)<>''then Result:=rhwNone
  else Result:=ParseHeadwear(UserPreference('rider_headwear','helmet'));
end;

function WardrobeRiderPath(const BasePath:string):string;
var O:TJSONObject;A:TJSONArray;I:Integer;Preset,Key,Dir:string;Info:TSearchRec;
begin
  Result:=BasePath;O:=TJSONObject.Create;
  try
    A:=TJSONArray.Create;O.Add('items',A);
    for I:=0 to High(WardrobeSlots)do begin
      Preset:=WardrobeSelection(I);
      if Preset<>''then A.Add(TJSONObject.Create(['slot',WardrobeSlots[I],'preset',Preset]));
    end;
    if(A.Count=0)or(BasePath='')then Exit;
    O.Add('base',BasePath);Key:='wardrobe-v14|'+O.AsJSON;
    if FindFirst(BasePath,faAnyFile,Info)=0 then begin
      Key:=Key+'|'+IntToStr(Info.Time)+'|'+IntToStr(Info.Size);FindClose(Info);
    end;
    Dir:=UserDataDir+'wardrobe'+PathDelim;ForceDirectories(Dir);
    Result:=Dir+'wardrobe-'+MD5Print(MD5String(Key))+'.wardrobe';
    if not FileExists(Result)then WriteAccountJSON(Result,O);
  finally O.Free end;
end;

function PrepareWardrobe(const Path:string):string;
var Doc:TGlbDoc;O,Item,P:TJSONObject;Items,Existing:TJSONArray;I:Integer;Temp:string;
  HasOuter:Boolean;
begin
  Result:=Path;
  if not SameText(ExtractFileExt(Path),'.wardrobe')then Exit;
  Result:=ChangeFileExt(Path,'.glb');
  if FileExists(Result)then Exit;
  BuildLock.Enter;
  try
    if FileExists(Result)then Exit;
    O:=ReadAccountJSON(Path);Doc:=TGlbDoc.Create;
    try
      if(O=nil)or not Doc.LoadFromFile(O.Get('base',''))then raise EReadError.Create('Cannot load clothing base');
      Existing:=WardrobeItems(Doc);
      for I:=0 to CountOf(Existing)-1 do begin
        P:=TJSONObject.Create(['action','update','id',ObjAt(Existing,I).Get('id',''),'enabled',False]);
        try ChangeWardrobe(Doc,P) finally P.Free end;
      end;
      Items:=ArrOf(O,'items');
      HasOuter:=False;
      for I:=0 to CountOf(Items)-1 do
        HasOuter:=HasOuter or(ObjAt(Items,I).Get('slot','')='outer');
      for I:=0 to CountOf(Items)-1 do begin
        Item:=ObjAt(Items,I);
        { The jacket replaces the top. Keep its selection in the profile,
          without generating a second, entirely hidden garment underneath. }
        if HasOuter and(Item.Get('slot','')='top')then Continue;
        P:=TJSONObject.Create(['action','add','preset',Item.Get('preset','')]);
        try ChangeWardrobe(Doc,P) finally P.Free end;
      end;
      Temp:=Result+'.tmp';
      try
        Doc.SaveToFile(Temp);
        if not RenameFile(Temp,Result)then raise EWriteError.Create('Cannot store clothing cache');
      finally if FileExists(Temp)then DeleteFile(Temp) end;
    finally Doc.Free;O.Free end;
  finally BuildLock.Leave end;
end;

type
  TWardrobeTint=record
    Material:TPhysicalMaterialNode;
    Name:string;
    Original:TVector3;
    RelativeTone:Single;
    Slot:Integer;
    Enabled:Boolean;
  end;
  TWardrobeAppearance=class(TRiderAppearanceAddon)
    Motion:TAvatarClothMotion;
    Rider:TTripoRiderScene;
    Tints:array of TWardrobeTint;
    procedure BindColors(Doc:TGlbDoc);
    procedure ApplyColor(Slot:Integer;const Color:TVector3;Enabled:Boolean);
    procedure ClothColorChanged(Slot:TClothSlot;const Color:TVector3;Enabled:Boolean);override;
    procedure HeadwearColorChanged(const Color:TVector3;Enabled:Boolean);override;
    procedure ColorState(O:TJSONObject);
    destructor Destroy;override;
    procedure Update(Dt,Speed:Single);override;
  end;
destructor TWardrobeAppearance.Destroy;
begin Motion.Free;inherited end;
procedure TWardrobeAppearance.Update(Dt,Speed:Single);
var World:TMatrix4;Wind,A,B:TVector3;Query:TRiderJointQuery;
  I:Integer;Side:string;Valid:Boolean;Fat,Muscle,Lean,Build:Single;
begin
  if Motion.UsesHemPhysics then begin
    World:=Rider.Scene.Transform;
    if Rider.Scene.HasWorldTransform then World:=Rider.Scene.WorldTransform;
    Wind:=RiderWindWorld;
    if Assigned(RiderWindSampler)then Wind:=RiderWindSampler(World.MultPoint(Vector3(0,1,0)));
    Motion.SetFrame(Rider.Scene.Transform,World,Wind);
    Query:=Rider.OcclusionJointQuery;if not Assigned(Query)then Query:=@Rider.PosedJointParent;
    Motion.SkinQuery:=Rider.ClothingSkinQuery;
    RiderBodyShapeWeights(Rider.BodyParameters,Fat,Muscle,Lean);
    Build:=EnsureRange(1+0.18*Max(0,Fat)+0.09*Max(0,Muscle),0.88,1.27);
    for I:=0 to 3 do begin
      if I mod 2=0 then Side:='R_'else Side:='L_';
      A:=TVector3.Zero;B:=TVector3.Zero;
      if I<2 then Valid:=Query(Side+'Thigh',A)and Query(Side+'Calf',B)
      else Valid:=Query(Side+'Calf',A)and Query(Side+'Foot',B);
      Motion.SetLegContact(I,A,B,Valid,Build);
    end;
  end;
  Motion.Update(Dt,Speed,Rider.Scene.Translation);
end;

procedure TWardrobeAppearance.BindColors(Doc:TGlbDoc);
var Items,Materials:TJSONArray;Item:TJSONObject;I,J,Slot,N:Integer;
  Mat:TPhysicalMaterialNode;App:TAppearanceNode;Name:string;Reference,Lum:Single;
begin
  Items:=WardrobeItems(Doc);
  for I:=0 to CountOf(Items)-1 do begin
    Item:=ObjAt(Items,I);
    if not Item.Get('enabled',False)then Continue;
    Slot:=0;
    while(Slot<=High(WardrobeSlots))and(WardrobeSlots[Slot]<>Item.Get('slot',''))do Inc(Slot);
    if Slot>High(WardrobeSlots)then Continue;
    Materials:=ArrOf(Item,'tintMaterials');
    if Materials=nil then Materials:=ArrOf(Item,'materials');
    Reference:=0;
    for J:=0 to CountOf(Materials)-1 do begin
      Name:=ObjAt(ArrOf(Doc.Root,'materials'),Materials.Integers[J]).Get('name','');
      { CGE preserves the glTF material name on its Appearance node. }
      App:=Rider.Scene.RootNode.FindNode(TAppearanceNode,Name,[fnNilOnMissing])as TAppearanceNode;
      if(App=nil)or not(App.Material is TPhysicalMaterialNode)then Continue;
      Mat:=TPhysicalMaterialNode(App.Material);
      Lum:=0.2126*Mat.BaseColor.X+0.7152*Mat.BaseColor.Y+0.0722*Mat.BaseColor.Z;
      if Reference=0 then Reference:=Max(0.00001,Lum);
      N:=Length(Tints);SetLength(Tints,N+1);
      Tints[N].Material:=Mat;Tints[N].Original:=Mat.BaseColor;
      Tints[N].Name:=Name;
      Tints[N].Slot:=Slot;Tints[N].RelativeTone:=Lum/Reference;
    end;
  end;
end;

procedure TWardrobeAppearance.ApplyColor(Slot:Integer;const Color:TVector3;Enabled:Boolean);
var I:Integer;
begin
  { Only material uniforms change. Do not regenerate clothing, textures or
    shader programs on a palette click. Soles, buttons and trim keep theirs. }
  for I:=0 to High(Tints)do if Tints[I].Slot=Slot then begin
    Tints[I].Enabled:=Enabled;
    if Enabled then Tints[I].Material.BaseColor:=Color*Tints[I].RelativeTone
    else Tints[I].Material.BaseColor:=Tints[I].Original;
  end;
end;
procedure TWardrobeAppearance.ClothColorChanged(Slot:TClothSlot;
  const Color:TVector3;Enabled:Boolean);
begin
  case Slot of
    csJersey:begin ApplyColor(0,Color,Enabled);ApplyColor(2,Color,Enabled) end;
    csShorts:ApplyColor(1,Color,Enabled);
    csBoots:ApplyColor(3,Color,Enabled);
  end;
end;
procedure TWardrobeAppearance.HeadwearColorChanged(const Color:TVector3;Enabled:Boolean);
begin ApplyColor(4,Color,Enabled) end;
procedure TWardrobeAppearance.ColorState(O:TJSONObject);
var A:TJSONArray;I:Integer;C:TVector3;
begin
  A:=TJSONArray.Create;O.Add('colors',A);
  for I:=0 to High(Tints)do begin
    C:=Tints[I].Material.BaseColor;
    A.Add(TJSONObject.Create(['slot',WardrobeSlots[Tints[I].Slot],
      'material',Tints[I].Name,'enabled',Tints[I].Enabled,
      'color',TJSONArray.Create([C.X,C.Y,C.Z])]));
  end;
end;

procedure BindGarmentBodies(Rider:TTripoRiderScene;Doc:TGlbDoc);
var Meshes,Nodes,Items,Prims,Origins:TJSONArray;Item,Prim,Attrs:TJSONObject;
  M,I,J,N,First,Count,Skin:Integer;UsesSkin,FitSurface:Boolean;Source,Garment:TShapeNode;
begin
  if Rider.BodyMorph=nil then Exit;
  Meshes:=ArrOf(Doc.Root,'meshes');Nodes:=ArrOf(Doc.Root,'nodes');
  Items:=WardrobeItems(Doc);Skin:=Doc.MainSkinIndex;First:=0;
  { Match the rig loader's mesh/primitive order. Clothing follows the same
    sex, build and weight morph as its donor without rebuilding a GLB. }
  for M:=0 to CountOf(Meshes)-1 do begin
    UsesSkin:=False;
    for I:=0 to CountOf(Nodes)-1 do
      if(IntOf(ObjAt(Nodes,I),'mesh',-1)=M)and(IntOf(ObjAt(Nodes,I),'skin',-1)=Skin)then UsesSkin:=True;
    if not UsesSkin then Continue;
    Origins:=nil;FitSurface:=False;
    for I:=0 to CountOf(Items)-1 do begin
      Item:=ObjAt(Items,I);N:=Item.Get('node',-1);
      if IntOf(ObjAt(Nodes,N),'mesh',-1)=M then begin
        Origins:=ArrOf(Item,'sourceShapes');
        FitSurface:=(Item.Get('slot','')='outer')or(Item.Get('preset','')='jeans');
      end;
    end;
    Prims:=ArrOf(ObjAt(Meshes,M),'primitives');
    for J:=0 to CountOf(Prims)-1 do begin
      Prim:=ObjAt(Prims,J);Attrs:=ObjOf(Prim,'attributes');
      if(Attrs=nil)or(Attrs.Find('JOINTS_0')=nil)then Continue;
      Count:=IntOf(ObjAt(ArrOf(Doc.Root,'accessors'),IntOf(Attrs,'POSITION',-1)),'count',0);
      if J<CountOf(Origins)then begin
        Source:=Rider.Scene.RootNode.FindNode(TShapeNode,Origins.Strings[J],[fnNilOnMissing])as TShapeNode;
        Garment:=Rider.Scene.RootNode.FindNode(TShapeNode,
          ObjAt(Meshes,M).Get('name','')+'_Primitive'+IntToStr(J),[fnNilOnMissing])as TShapeNode;
        if(Source<>nil)and(Garment<>nil)and
          (Source.Geometry is TAbstractComposedGeometryNode)and(Garment.Geometry is TAbstractComposedGeometryNode)then
          Rider.BodyMorph.BindGarment(TAbstractComposedGeometryNode(Source.Geometry),
            TAbstractComposedGeometryNode(Garment.Geometry),First,Rider.Rig);
      end else if FitSurface then begin
        Garment:=Rider.Scene.RootNode.FindNode(TShapeNode,
          ObjAt(Meshes,M).Get('name','')+'_Primitive'+IntToStr(J),[fnNilOnMissing])as TShapeNode;
        if(Garment<>nil)and(Garment.Geometry is TAbstractComposedGeometryNode)then
          Rider.BodyMorph.BindGarmentSurface(TAbstractComposedGeometryNode(Garment.Geometry),First,Rider.Rig);
      end;
      Inc(First,Count);
    end;
  end;
end;

function CreateWardrobeAppearance(Rider:TTripoRiderScene;const Path:string):TRiderAppearanceAddon;
var A:TWardrobeAppearance;Doc:TGlbDoc;
begin
  Result:=nil;
  if not FileExists(ChangeFileExt(Path,'.wardrobe'))then Exit;
  A:=TWardrobeAppearance.Create;Doc:=TGlbDoc.Create;
  try
    A.Rider:=Rider;
    if not Doc.LoadFromFile(Path)then raise EReadError.Create('Cannot load clothing animation data');
    BindGarmentBodies(Rider,Doc);
    A.BindColors(Doc);
    { Keep the full editor mesh solver disabled during gameplay. The small
      hem cage uses the already solved joint query in both animation paths;
      all rendered vertices and final contact remain on the GPU. }
    A.Motion:=TAvatarClothMotion.Create(Rider.Scene.RootNode,Doc,Rider.Rig,False);
    Result:=A;A:=nil;
  finally Doc.Free;A.Free end;
end;
procedure WardrobeState(Rider:TTripoRiderScene;Result:TJSONObject);
var O:TJSONObject;I:Integer;
begin
  O:=TJSONObject.Create;Result.Add('clothing',O);
  for I:=0 to High(WardrobeSlots)do O.Add(WardrobeSlots[I],WardrobeSelection(I));
  if(Rider<>nil)and(Rider.AppearanceAddon is TWardrobeAppearance)then
  begin
    O.Add('surfaces',TWardrobeAppearance(Rider.AppearanceAddon).Motion.SurfaceCount);
    if TWardrobeAppearance(Rider.AppearanceAddon).Motion.UsesHemPhysics then
      O.Add('animation','gpu_skin_hem_physics')else O.Add('animation','gpu_skin_flutter');
    TWardrobeAppearance(Rider.AppearanceAddon).Motion.State(O);
    TWardrobeAppearance(Rider.AppearanceAddon).ColorState(O);
  end;
end;

constructor TGameWardrobePanel.Create(AOwner:TComponent);
const ColorSlots:array[0..4]of Integer=(0,1,0,3,9);
var I:Integer;
begin
  inherited;WidthFraction:=1;
  FTitle:=TMenuLabel.Create(Self);BindUiText(FTitle,'Clothing');FTitle.FontSize:=16;InsertFront(FTitle);
  for I:=0 to High(FLabels)do begin
    FLabels[I]:=TMenuLabel.Create(Self);BindUiText(FLabels[I],SlotTitles[I]);FLabels[I].Color:=MenuMuted;InsertFront(FLabels[I]);
    FChoices[I]:=TMenuButton.Create(Self);FChoices[I].Name:='Clothing_'+WardrobeSlots[I];
    FChoices[I].AutoSize:=False;FChoices[I].AutoIcon:=False;FChoices[I].Tag:=I*2+1;
    FChoices[I].OnClick:=@Click;InsertFront(FChoices[I]);
    FPrev[I]:=TMenuButton.Create(Self);FPrev[I].Name:='ClothingPrev_'+WardrobeSlots[I];
    FPrev[I].Caption:='‹';FPrev[I].AutoSize:=False;FPrev[I].AutoIcon:=False;
    FPrev[I].Tag:=I*2;FPrev[I].OnClick:=@Click;InsertFront(FPrev[I]);
    FNext[I]:=TMenuButton.Create(Self);FNext[I].Name:='ClothingNext_'+WardrobeSlots[I];
    FNext[I].Caption:='›';FNext[I].AutoSize:=False;FNext[I].AutoIcon:=False;
    FNext[I].Tag:=I*2+1;FNext[I].OnClick:=@Click;InsertFront(FNext[I]);
    FColors[I]:=TMenuButton.Create(Self);FColors[I].Name:='ClothingColor_'+WardrobeSlots[I];
    BindUiText(FColors[I],'Color');FColors[I].AutoSize:=False;FColors[I].AutoIcon:=False;
    FColors[I].CustomBackground:=True;FColors[I].Tag:=ColorSlots[I];
    FColors[I].OnClick:=@ClickColor;InsertFront(FColors[I]);
  end;
  Refresh;
end;
procedure TGameWardrobePanel.Refresh;
var I:Integer;
begin
  for I:=0 to High(FLabels)do BindUiText(FChoices[I],Titles[I,OptionIndex(I,WardrobeSelection(I))]);
  FColors[0].Enabled:=WardrobeSelection(2)='';
  FColors[2].Enabled:=WardrobeSelection(2)<>'';
  Resize;
end;
procedure TGameWardrobePanel.SetColor(Slot:Integer;const C:TVector4);
begin
  FColors[Slot].CustomColorNormal:=C;FColors[Slot].CustomColorFocused:=C;
  FColors[Slot].CustomColorPressed:=C;FColors[Slot].CustomTextColorUse:=True;
  if C.X*0.2126+C.Y*0.7152+C.Z*0.0722>0.55 then
    FColors[Slot].CustomTextColor:=Vector4(0.04,0.06,0.08,1)
  else FColors[Slot].CustomTextColor:=Vector4(1,1,1,1);
end;
procedure TGameWardrobePanel.ClickColor(Sender:TObject);
begin if Assigned(FOnColorClick)then FOnColorClick(Sender) end;
procedure TGameWardrobePanel.Resize;
var I:Integer;S,W,Y:Single;
begin
  inherited;if FTitle=nil then Exit;S:=Max(0.65,Min(1,UIScale));W:=EffectiveWidth;
  Height:=338/S;FTitle.Anchor(hpLeft,6);FTitle.Anchor(vpTop,-6/S);FTitle.FontSize:=16/S;
  for I:=0 to High(FLabels)do if FChoices[I]<>nil then begin
    Y:=(34+I*60)/S;FLabels[I].FontSize:=12/S;FLabels[I].Anchor(hpLeft,6);FLabels[I].Anchor(vpTop,-Y);
    FChoices[I].Width:=Max(50,W-148/S);FChoices[I].Height:=32/S;FChoices[I].FontSize:=14/S;
    FChoices[I].Anchor(hpLeft,40/S);FChoices[I].Anchor(vpTop,-(Y+20/S));
    FPrev[I].Width:=30/S;FPrev[I].Height:=32/S;FPrev[I].FontSize:=18/S;
    FPrev[I].Anchor(hpLeft,6/S);FPrev[I].Anchor(vpTop,-(Y+20/S));
    FNext[I].Width:=30/S;FNext[I].Height:=32/S;FNext[I].FontSize:=18/S;
    FNext[I].Anchor(hpRight,-72/S);FNext[I].Anchor(vpTop,-(Y+20/S));
    FColors[I].Width:=60/S;FColors[I].Height:=32/S;FColors[I].FontSize:=12/S;
    FColors[I].Anchor(hpRight,-6/S);FColors[I].Anchor(vpTop,-(Y+20/S));
  end;
end;
procedure TGameWardrobePanel.Click(Sender:TObject);
var Slot,Index:Integer;
begin
  Slot:=TComponent(Sender).Tag div 2;Index:=OptionIndex(Slot,WardrobeSelection(Slot));
  if Odd(TComponent(Sender).Tag)then Inc(Index)else Dec(Index);
  Index:=(Index+OptionCount[Slot])mod OptionCount[Slot];
  SelectWardrobe(WardrobeSlots[Slot],Options[Slot,Index]);Refresh;
  if Assigned(FOnChange)then FOnChange(Self);
end;
initialization
  BuildLock:=TCriticalSection.Create;
  RiderAssetResolver:=@PrepareWardrobe;RiderAppearanceFactory:=@CreateWardrobeAppearance;
finalization
  RiderAssetResolver:=nil;RiderAppearanceFactory:=nil;BuildLock.Free;
end.
