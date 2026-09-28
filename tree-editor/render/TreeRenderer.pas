unit TreeRenderer;
{$mode objfpc}{$H+}
interface
uses SysUtils, TreeMath, TreeModel, TreeLOD, TreeSeason, TreeFoliageLOD, GL, GLExt;
type
  TTreeGPUItem = packed array[0..15] of Single;
  TTreeGPUItems = array of TTreeGPUItem;
  TTreeIndices = array of GLushort;
  TPreparedTreeLOD = record
    Species: TTreeSpecies;
    Key: string;
    Frames: TLODFrames;
    Seasonal, FruitLayer: Boolean;
    Pixels: array of Byte;
  end;
  TTreeRenderEnvironment = record
    Enabled, DepthOnly, DirectBranches: Boolean;
    SunDirection, BillboardRight, FogColor: TTreeVec3;
    FogDensity, OutputGamma: Single;
    LeafFraction: Single; { 0 = all; game may thin distant leaves/needles }
    NeedleDetail: Single; { direct branches: 0 = integrated shoots, 1 = individual needles }
    ViewportHeight, BranchSides, BranchSegments: Integer;
  end;
  TTreeRenderStats = record
    DrawCalls, Triangles, Branches, Leaves, Needles, Shoots, Fruits, Proxies, FarTrees, BakedFarTrees: Integer;
    FarMinHeight, FarMaxHeight: Single;
    UploadBytes: Int64;
  end;
  TTreeRenderer = class
  private
    FProgram: GLuint;
    FShared: TTreeRenderer;
    FVAO, FVBO: array[0..5] of GLuint;
    FNeedleVAO: array[0..NEEDLE_DENSITY_GROUPS-1] of GLuint;
    FCardIndices,FNeedleIndices:GLuint;
    FGridIndices:array of record Slices,Segments:Integer;Buffer:GLuint;end;
    FBranchCount,FLeafCount,FCrownCount,FForestCount,FNeedleShootCount,FNeedlesPerFascicle: Integer;
    FFruitCount,FFruitMembers:Integer;
    FFruitRadius:Single;
    FNeedleGroups:array[0..NEEDLE_DENSITY_GROUPS-1]of record First,Count:Integer;end;
    FFarMinHeight,FFarMaxHeight: Single;
    FDepthCounts: array[0..4] of Integer;
    FStats: TTreeRenderStats;
    FReady: Boolean;
    FEnvironment: TTreeRenderEnvironment;
    USunDirection,UBillboardRight,UFogColor,UFogDensity,UOutputGamma,UDepthOnly,UDirectBranches,ULeafScale,UNeedleScale: GLint;
    FLODTextures: array[TTreeSpecies] of GLuint;
    FLODFrames: array[TTreeSpecies] of TLODFrames;
    FLODKeys: array[TTreeSpecies] of string;
    { Profile serialization is only needed on a change, never per draw. }
    FCheckedProfiles: array[TTreeSpecies] of TTreeParams;
    FCheckedKeys: array[TTreeSpecies] of string;
    FLODSeasonParts: array[TTreeSpecies] of Boolean;
    FLODFruitLayer: array[TTreeSpecies] of Boolean;
    FSeason: Single;
    FBakePart: Integer; { 0 complete, 1 wood, 2 foliage, 3 fruit }
    USeasonLeaf,ULeafRatio,ULODSeasonParts: GLint;
    UFruitAmount,UFruitMembers,ULODFruitLayer:GLint;
    FBakeMode,FUseBakedLOD: Boolean;
    UBakeMode,UUseBakedLOD,ULODTexture,ULODFrames: GLint;
    UProjection,UView,UModel,UKind,USlices,USegments,UQuality,UTime,UWind,
    UProfile,UBark,ULeaf,UEye,USpecies,UDensity,UDebug,UNeedlePairs,UNeedlesPerFascicle,UNeedleVertices,UViewportHeight,UNeedleDetail: GLint;
    procedure Upload(Index: Integer; const Items: TTreeGPUItems);
    function UploadIndices(const Indices:TTreeIndices):GLuint;
    function GridIndices(Slices,Segments:Integer):GLuint;
    function CardIndices:GLuint;
    function NeedleIndices:GLuint;
    procedure Draw(Kind, BufferIndex, Vertices, Count: Integer; VertexArray: GLuint = 0; IndexBuffer:GLuint = 0);
  public
    procedure Initialize(const ShaderDirectory: string; SharedWith: TTreeRenderer = nil);
    procedure Release; { MUST be called while the owning GL context is current }
    procedure UploadTree(const Data: TTreeData);
    { Batch by species/profile. Positions stay in Double until rebased against
      WorldOrigin, then become GPU floats. No detailed generation is performed. }
    procedure UploadDistantTrees(const Instances: array of TTreeInstance;
      const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition);
    { Identity need not share the render projection (e.g. ECEF versus a local
      map). Resolve size/seed from Instances, rebase only RenderPositions. }
    procedure UploadDistantTreesAt(const Instances: array of TTreeInstance;
      const RenderPositions: array of TTreeWorldPosition;
      const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition);
    class function PackDistantTreesAt(const Instances: array of TTreeInstance;
      const RenderPositions: array of TTreeWorldPosition;
      const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition): TTreeGPUItems; static;
    procedure UploadDistantItems(const Items: TTreeGPUItems);
    procedure UpdateDistantItems(First: Integer; const Items: TTreeGPUItems);
    procedure UploadForest(const Center: TTreeInstance; const P: TTreeParams; Count: Integer);
    function VerifyPackedType(Expected: TTreeTypeCode): Boolean; { smoke only; synchronous GPU readback }
    procedure Render(const Instance: TTreeInstance; const P: TTreeParams;
      const Projection,View,Model: TTreeMat4; const Eye: TTreeVec3;
      Quality,Seconds,Wind: Single; Wireframe,Debug,ShowLeaves,ShowGround,ShowForest: Boolean;
      PreserveGLState: Boolean = True);
    procedure LoadLODAtlas(const Directory: string; const Profile: TTreeParams);
    class function PrepareLODAtlas(const Directory: string;
      const Profile: TTreeParams): TPreparedTreeLOD; static;
    procedure UploadLODAtlas(const Prepared: TPreparedTreeLOD);
    function HasLODAtlas(const Profile: TTreeParams): Boolean;
    function HasSeasonLOD(const Profile: TTreeParams): Boolean;
    property BakeMode: Boolean read FBakeMode write FBakeMode;
    property UseBakedLOD: Boolean read FUseBakedLOD write FUseBakedLOD;
    property Season: Single read FSeason write FSeason;
    property BakePart: Integer read FBakePart write FBakePart;
    property Ready: Boolean read FReady;
    property Environment: TTreeRenderEnvironment read FEnvironment write FEnvironment;
    property Stats: TTreeRenderStats read FStats;
  end;
implementation
uses Classes, Math, TreeFruits;
function CompileShader(Kind: GLenum; const Source: string): GLuint;
var P: PChar; OK,Len: GLint; Log: string;
begin
  Result:=glCreateShader(Kind); P:=PChar(Source); glShaderSource(Result,1,@P,nil); glCompileShader(Result);
  glGetShaderiv(Result,GL_COMPILE_STATUS,@OK);
  if OK=0 then begin
    glGetShaderiv(Result,GL_INFO_LOG_LENGTH,@Len); SetLength(Log,Max(1,Len));
    glGetShaderInfoLog(Result,Len,nil,PChar(Log)); glDeleteShader(Result);
    raise Exception.Create('Tree shader compilation failed: '+Log);
  end;
end;
function ReadText(const Path: string): string;
var S: TStringList;
begin S:=TStringList.Create; try S.LoadFromFile(Path); Result:=S.Text; finally S.Free; end; end;
procedure TTreeRenderer.Initialize(const ShaderDirectory: string; SharedWith: TTreeRenderer);
var VS,FS: GLuint; OK,Len,I,J: GLint; Log: string;
begin
  if FReady then Exit;
  FShared:=SharedWith;
  if Assigned(FShared) then begin
    if not FShared.Ready or Assigned(FShared.FShared) then raise Exception.Create('Shared renderer must be a ready resource owner');
  end else if not Load_GL_version_3_3_CORE then raise Exception.Create('OpenGL 3.3 is required');
  VS:=0; FS:=0;
  try
    if Assigned(FShared) then FProgram:=FShared.FProgram else begin
    VS:=CompileShader(GL_VERTEX_SHADER,ReadText(IncludeTrailingPathDelimiter(ShaderDirectory)+'tree.vert'));
    FS:=CompileShader(GL_FRAGMENT_SHADER,ReadText(IncludeTrailingPathDelimiter(ShaderDirectory)+'tree.frag'));
    FProgram:=glCreateProgram(); glAttachShader(FProgram,VS); glAttachShader(FProgram,FS); glLinkProgram(FProgram);
    glGetProgramiv(FProgram,GL_LINK_STATUS,@OK);
    if OK=0 then begin
      glGetProgramiv(FProgram,GL_INFO_LOG_LENGTH,@Len); SetLength(Log,Max(1,Len));
      glGetProgramInfoLog(FProgram,Len,nil,PChar(Log)); raise Exception.Create('Tree shader link failed: '+Log);
    end;
    end;
    UProjection:=glGetUniformLocation(FProgram,'uProjection'); UView:=glGetUniformLocation(FProgram,'uView');
    UModel:=glGetUniformLocation(FProgram,'uModel'); UKind:=glGetUniformLocation(FProgram,'uKind');
    USlices:=glGetUniformLocation(FProgram,'uSlices'); USegments:=glGetUniformLocation(FProgram,'uSegments');
    UQuality:=glGetUniformLocation(FProgram,'uQuality'); UTime:=glGetUniformLocation(FProgram,'uTime');
    UWind:=glGetUniformLocation(FProgram,'uWind'); UProfile:=glGetUniformLocation(FProgram,'uProfile');
    UBark:=glGetUniformLocation(FProgram,'uBark'); ULeaf:=glGetUniformLocation(FProgram,'uLeaf');
    UEye:=glGetUniformLocation(FProgram,'uEye'); USpecies:=glGetUniformLocation(FProgram,'uSpecies');
    UDensity:=glGetUniformLocation(FProgram,'uDensity'); UDebug:=glGetUniformLocation(FProgram,'uDebug');
    UNeedlePairs:=glGetUniformLocation(FProgram,'uNeedlePairs');
    UNeedlesPerFascicle:=glGetUniformLocation(FProgram,'uNeedlesPerFascicle');
    UNeedleVertices:=glGetUniformLocation(FProgram,'uNeedleVertices');
    UViewportHeight:=glGetUniformLocation(FProgram,'uViewportHeight');
    UBakeMode:=glGetUniformLocation(FProgram,'uBakeMode');
    UUseBakedLOD:=glGetUniformLocation(FProgram,'uUseBakedLOD');
    ULODTexture:=glGetUniformLocation(FProgram,'uLODTexture');
    ULODFrames:=glGetUniformLocation(FProgram,'uLODFrames[0]');
    USeasonLeaf:=glGetUniformLocation(FProgram,'uSeasonLeaf'); ULeafRatio:=glGetUniformLocation(FProgram,'uLeafRatio');
    ULODSeasonParts:=glGetUniformLocation(FProgram,'uLODSeasonParts');
    USunDirection:=glGetUniformLocation(FProgram,'uSunDirection');
    UBillboardRight:=glGetUniformLocation(FProgram,'uBillboardRight');
    UFogColor:=glGetUniformLocation(FProgram,'uFogColor');
    UFogDensity:=glGetUniformLocation(FProgram,'uFogDensity');
    UOutputGamma:=glGetUniformLocation(FProgram,'uOutputGamma');
    UDepthOnly:=glGetUniformLocation(FProgram,'uDepthOnly');
    UDirectBranches:=glGetUniformLocation(FProgram,'uDirectBranches');
    ULeafScale:=glGetUniformLocation(FProgram,'uLeafScale');
    UNeedleScale:=glGetUniformLocation(FProgram,'uNeedleScale');
    UNeedleDetail:=glGetUniformLocation(FProgram,'uNeedleDetail');
    UFruitAmount:=glGetUniformLocation(FProgram,'uFruitAmount');
    UFruitMembers:=glGetUniformLocation(FProgram,'uFruitMembers');
    ULODFruitLayer:=glGetUniformLocation(FProgram,'uLODFruitLayer');
    FSeason:=TREE_SUMMER;
    FUseBakedLOD:=True;
    glGenVertexArrays(Length(FVAO),@FVAO[0]); glGenBuffers(Length(FVBO),@FVBO[0]);
    glGenVertexArrays(NEEDLE_DENSITY_GROUPS,@FNeedleVAO[0]);
    for I:=0 to High(FVAO) do begin
      glBindVertexArray(FVAO[I]); glBindBuffer(GL_ARRAY_BUFFER,FVBO[I]);
      for J:=0 to 3 do begin
        glEnableVertexAttribArray(J); glVertexAttribPointer(J,4,GL_FLOAT,GL_FALSE,SizeOf(TTreeGPUItem),Pointer(PtrUInt(J*16)));
        glVertexAttribDivisor(J,1);
      end;
      { The packed code is an integer attribute. Converting it to float would
        silently lose family/age bits for variants above 15. Offset 52 stays
        inside the original 64-byte descriptor. }
      glEnableVertexAttribArray(4);
      glVertexAttribIPointer(4,1,GL_UNSIGNED_INT,SizeOf(TTreeGPUItem),Pointer(PtrUInt(52)));
      glVertexAttribDivisor(4,1);
    end;
    glBindVertexArray(0); glBindBuffer(GL_ARRAY_BUFFER,0); FReady:=True;
  except
    if (FProgram<>0) and not Assigned(FShared) then glDeleteProgram(FProgram); FProgram:=0;
    if VS<>0 then glDeleteShader(VS); if FS<>0 then glDeleteShader(FS); raise;
  end;
  if VS<>0 then glDeleteShader(VS); if FS<>0 then glDeleteShader(FS);
end;
procedure TTreeRenderer.Release;
var S: TTreeSpecies;I:Integer;
begin
  if not FReady then Exit;
  for S:=Low(TTreeSpecies) to High(TTreeSpecies) do begin
    if FLODTextures[S]<>0 then glDeleteTextures(1,@FLODTextures[S]); FLODTextures[S]:=0; FLODKeys[S]:='';
  end;
  glDeleteBuffers(Length(FVBO),@FVBO[0]); glDeleteVertexArrays(Length(FVAO),@FVAO[0]); if not Assigned(FShared) then glDeleteProgram(FProgram);
  glDeleteVertexArrays(NEEDLE_DENSITY_GROUPS,@FNeedleVAO[0]);
  FillChar(FNeedleVAO,SizeOf(FNeedleVAO),0);
  if FCardIndices<>0 then glDeleteBuffers(1,@FCardIndices);
  if FNeedleIndices<>0 then glDeleteBuffers(1,@FNeedleIndices);
  for I:=0 to High(FGridIndices) do glDeleteBuffers(1,@FGridIndices[I].Buffer);
  FCardIndices:=0;FNeedleIndices:=0;FGridIndices:=nil;
  FillChar(FVBO,SizeOf(FVBO),0); FillChar(FVAO,SizeOf(FVAO),0); FProgram:=0; FReady:=False;
end;
function TTreeRenderer.HasLODAtlas(const Profile: TTreeParams): Boolean;
begin
  if Assigned(FShared) then Exit(FShared.HasLODAtlas(Profile));
  if FLODTextures[Profile.Species]=0 then Exit(False);
  if (FCheckedKeys[Profile.Species]='') or
     not CompareMem(@FCheckedProfiles[Profile.Species],@Profile,SizeOf(Profile)) then begin
    FCheckedProfiles[Profile.Species]:=Profile;
    FCheckedKeys[Profile.Species]:=LODProfileKey(Profile);
  end;
  Result:=FLODKeys[Profile.Species]=FCheckedKeys[Profile.Species];
end;
function TTreeRenderer.HasSeasonLOD(const Profile: TTreeParams): Boolean;
begin
  if Assigned(FShared) then Exit(FShared.HasSeasonLOD(Profile));
  Result:=HasLODAtlas(Profile) and FLODSeasonParts[Profile.Species];
end;
procedure TTreeRenderer.LoadLODAtlas(const Directory: string; const Profile: TTreeParams);
var Prepared: TPreparedTreeLOD;
begin
  if Assigned(FShared) then begin FShared.LoadLODAtlas(Directory,Profile); Exit; end;
  Prepared:=PrepareLODAtlas(Directory,Profile);
  if Length(Prepared.Pixels)>0 then UploadLODAtlas(Prepared);
end;
class function TTreeRenderer.PrepareLODAtlas(const Directory: string;
  const Profile: TTreeParams): TPreparedTreeLOD;
var Path: string; Atlas: TLODPixels;
    G,V,X,Y,C,Src,Dst,Part,Parts,LayerSize: Integer;
begin
  Result:=Default(TPreparedTreeLOD); Result.Species:=Profile.Species;
  Path:=IncludeTrailingPathDelimiter(Directory)+SpeciesName(Profile.Species);
  if not ReadLODMetadata(Path+'.json',Profile,Result.Frames) then Exit;
  Result.Key:=LODProfileKey(Profile);
  Result.Seasonal:=ReadLODSeasonMetadata(Path+'.json') and FileExists(Path+'-wood.png') and FileExists(Path+'-foliage.png');
  Result.FruitLayer:=Result.Seasonal and HasTreeFruit(Profile.Species) and FileExists(Path+'-fruit.png');
  Parts:=1; if Result.Seasonal then Parts:=2;
  if Result.FruitLayer then Parts:=3;
  LayerSize:=LOD_SIZE*LOD_SIZE*LOD_VIEWS*LOD_AGES*4; SetLength(Result.Pixels,LayerSize*Parts);
  for Part:=0 to Parts-1 do begin
  if not Result.Seasonal then Atlas:=LoadLODPng(Path+'.png',LOD_SIZE*LOD_VIEWS,LOD_SIZE*LOD_AGES)
  else if Part=0 then Atlas:=LoadLODPng(Path+'-wood.png',LOD_SIZE*LOD_VIEWS,LOD_SIZE*LOD_AGES)
  else if Part=1 then Atlas:=LoadLODPng(Path+'-foliage.png',LOD_SIZE*LOD_VIEWS,LOD_SIZE*LOD_AGES)
  else Atlas:=LoadLODPng(Path+'-fruit.png',LOD_SIZE*LOD_VIEWS,LOD_SIZE*LOD_AGES);
  for G:=0 to LOD_AGES-1 do for V:=0 to LOD_VIEWS-1 do
    for Y:=0 to LOD_SIZE-1 do for X:=0 to LOD_SIZE-1 do begin
      Src:=(((LOD_AGES-1-G)*LOD_SIZE+Y)*LOD_SIZE*LOD_VIEWS+V*LOD_SIZE+X)*4;
      Dst:=Part*LayerSize+(((G*LOD_VIEWS+V)*LOD_SIZE+Y)*LOD_SIZE+X)*4;
      for C:=0 to 3 do Result.Pixels[Dst+C]:=Round(Max(0,Min(1,Atlas[Src+C]))*255);
    end;
  end;
end;
procedure TTreeRenderer.UploadLODAtlas(const Prepared: TPreparedTreeLOD);
var OldTexture: GLint; Tex: GLuint; S: TTreeSpecies; Parts: Integer;
begin
  if Assigned(FShared) then begin FShared.UploadLODAtlas(Prepared); Exit; end;
  S:=Prepared.Species; Parts:=1; if Prepared.Seasonal then Parts:=2;
  if Prepared.FruitLayer then Parts:=3;
  if Length(Prepared.Pixels)<>LOD_SIZE*LOD_SIZE*LOD_VIEWS*LOD_AGES*4*Parts then
    raise EArgumentException.Create('Invalid prepared tree atlas');
  Tex:=0; glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldTexture);
  try
    glGenTextures(1,@Tex); glBindTexture(GL_TEXTURE_2D_ARRAY,Tex);
    glTexImage3D(GL_TEXTURE_2D_ARRAY,0,GL_RGBA8,LOD_SIZE,LOD_SIZE,LOD_VIEWS*LOD_AGES*Parts,0,GL_RGBA,GL_UNSIGNED_BYTE,@Prepared.Pixels[0]);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MIN_FILTER,GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    glGenerateMipmap(GL_TEXTURE_2D_ARRAY);
    if glGetError()<>GL_NO_ERROR then raise Exception.Create('Cannot upload LOD texture array');
    if FLODTextures[S]<>0 then glDeleteTextures(1,@FLODTextures[S]);
    FLODTextures[S]:=Tex; Tex:=0; FLODFrames[S]:=Prepared.Frames; FLODKeys[S]:=Prepared.Key; FLODSeasonParts[S]:=Prepared.Seasonal;
    FLODFruitLayer[S]:=Prepared.FruitLayer;
  finally
    if Tex<>0 then glDeleteTextures(1,@Tex);
    glBindTexture(GL_TEXTURE_2D_ARRAY,OldTexture);
  end;
end;
procedure TTreeRenderer.Upload(Index: Integer; const Items: TTreeGPUItems);
var P: Pointer; PreviousBuffer: GLint;
begin
  P:=nil; if Length(Items)>0 then P:=@Items[0];
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@PreviousBuffer);
  glBindBuffer(GL_ARRAY_BUFFER,FVBO[Index]); glBufferData(GL_ARRAY_BUFFER,Length(Items)*SizeOf(TTreeGPUItem),P,GL_STATIC_DRAW);
  glBindBuffer(GL_ARRAY_BUFFER,PreviousBuffer);
end;
procedure SetVec(var Item: TTreeGPUItem; Offset: Integer; const V: TTreeVec3; W: Single);
begin Item[Offset]:=V.X; Item[Offset+1]:=V.Y; Item[Offset+2]:=V.Z; Item[Offset+3]:=W; end;
procedure SetType(var Item: TTreeGPUItem; const Actual: TTreeParams);
begin
  Move(Actual.TypeCode,Item[13],SizeOf(TTreeTypeCode));
  Item[14]:=Actual.Maturity;
  Item[15]:=Actual.Irregularity;
end;
procedure TTreeRenderer.UploadTree(const Data: TTreeData);
var Items: TTreeGPUItems; I,G,N,Index,J,Offset: Integer; B: TTreeBranch; L: TTreeLeaf; C: TTreeCrown; Shoot: TTreeNeedleShoot;
    Next:array[0..NEEDLE_DENSITY_GROUPS-1]of Integer;
    OldVAO,OldBuffer:GLint;Fruit:TTreeFruit;
begin
  FBranchCount:=Length(Data.Branches); FLeafCount:=Length(Data.Leaves); FCrownCount:=Length(Data.Crowns);
  FNeedleShootCount:=Length(Data.NeedleShoots);
  FFruitCount:=Length(Data.Fruits);FFruitRadius:=0;FFruitMembers:=1;
  if FFruitCount>0 then FFruitMembers:=FruitClusterMembers(Data.Fruits[0].Kind);
  FNeedlesPerFascicle:=NeedlesPerFascicle(Data.Params.Species);
  FStats.UploadBytes:=Int64(FBranchCount+FLeafCount+FCrownCount+FNeedleShootCount+FFruitCount)*SizeOf(TTreeGPUItem);
  FillChar(FDepthCounts,SizeOf(FDepthCounts),0); SetLength(Items,FBranchCount);
  for I:=0 to FBranchCount-1 do begin
    B:=Data.Branches[I]; SetVec(Items[I],0,B.Start,B.Radius); SetVec(Items[I],4,B.Control,B.TipRadius);
    SetVec(Items[I],8,B.Tip,B.Depth); Items[I][12]:=HashUnit(B.ID,60); SetType(Items[I],Data.Params);
    Inc(FDepthCounts[B.Depth]);
  end;
  Upload(0,Items); Items:=nil; SetLength(Items,FLeafCount);
  for I:=0 to FLeafCount-1 do begin
    L:=Data.Leaves[I]; SetVec(Items[I],0,L.Center,L.Size); SetVec(Items[I],4,L.Axis,L.Aspect);
    Items[I][12]:=L.Phase; SetType(Items[I],Data.Params);
  end;
  Upload(1,Items); Items:=nil; SetLength(Items,FCrownCount);
  for I:=0 to FCrownCount-1 do begin
    C:=Data.Crowns[I]; SetVec(Items[I],0,C.Center,C.Phase); SetVec(Items[I],4,C.Radius,0);
    Items[I][12]:=C.Phase; SetType(Items[I],Data.Params);
  end;
  Upload(2,Items);
  Items:=nil;SetLength(Items,FFruitCount);
  for I:=0 to FFruitCount-1 do begin
    Fruit:=Data.Fruits[I];
    SetVec(Items[I],0,Fruit.Center,Fruit.Radius);SetVec(Items[I],4,Fruit.Axis,Fruit.HalfLength);
    SetVec(Items[I],8,Fruit.Color,Ord(Fruit.Kind));Items[I][12]:=Fruit.Phase;SetType(Items[I],Data.Params);
    FFruitRadius:=Max(FFruitRadius,Max(Fruit.Radius,Fruit.HalfLength)*IfThen(FFruitMembers>1,8,1));
  end;
  Upload(5,Items);
  Items:=nil; SetLength(Items,FNeedleShootCount);
  FillChar(FNeedleGroups,SizeOf(FNeedleGroups),0);
  for I:=0 to FNeedleShootCount-1 do
    Inc(FNeedleGroups[NeedleDensityGroup(Data.NeedleShoots[I],Data.Params)].Count);
  N:=0;
  for G:=0 to NEEDLE_DENSITY_GROUPS-1 do begin
    FNeedleGroups[G].First:=N;Next[G]:=N;Inc(N,FNeedleGroups[G].Count);
  end;
  for I:=0 to FNeedleShootCount-1 do begin
    Shoot:=Data.NeedleShoots[I];
    G:=NeedleDensityGroup(Shoot,Data.Params);Index:=Next[G];Inc(Next[G]);
    SetVec(Items[Index],0,Shoot.Start,Shoot.Radius); SetVec(Items[Index],4,Shoot.Control,Shoot.NeedleLength);
    SetVec(Items[Index],8,Shoot.Tip,Shoot.NeedleWidth);
    Items[Index][12]:=Shoot.Phase; SetType(Items[Index],Data.Params);
  end;
  Upload(4,Items);
  { All density groups share one descriptor buffer. Their offsets are fixed
    until the next upload, so do not mutate attribute layouts on every draw. }
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer);
  try
    glBindBuffer(GL_ARRAY_BUFFER,FVBO[4]);
    for G:=0 to NEEDLE_DENSITY_GROUPS-1 do begin
      glBindVertexArray(FNeedleVAO[G]);
      Offset:=FNeedleGroups[G].First*SizeOf(TTreeGPUItem);
      for J:=0 to 3 do begin
        glEnableVertexAttribArray(J);
        glVertexAttribPointer(J,4,GL_FLOAT,GL_FALSE,SizeOf(TTreeGPUItem),Pointer(PtrUInt(Offset+J*16)));
        glVertexAttribDivisor(J,1);
      end;
      glEnableVertexAttribArray(4);
      glVertexAttribIPointer(4,1,GL_UNSIGNED_INT,SizeOf(TTreeGPUItem),Pointer(PtrUInt(Offset+52)));
      glVertexAttribDivisor(4,1);
    end;
  finally
    glBindVertexArray(OldVAO);glBindBuffer(GL_ARRAY_BUFFER,OldBuffer);
  end;
end;
procedure TTreeRenderer.UploadForest(const Center: TTreeInstance; const P: TTreeParams; Count: Integer);
var Instances: array of TTreeInstance; I,Side,X,Z: Integer; Inst: TTreeInstance; Pos: TTreeVec3;
begin
  FForestCount:=Max(1,Min(10001,Count)); SetLength(Instances,FForestCount); Side:=Ceil(Sqrt(FForestCount));
  for I:=0 to FForestCount-1 do begin
    Inst:=Center; Pos:=Vec(0,0,0);
    if I>0 then begin
      X:=(I-1) mod Side-Side div 2; Z:=(I-1) div Side-Side div 2;
      Pos:=Vec(X*22+(HashUnit(I,10)-0.5)*12,0,Z*22+(HashUnit(I,11)-0.5)*12);
      { Reserve the inspection area around the selected tree. }
      if Magnitude(Pos)<75 then Pos.Z:=Pos.Z+110;
      Inst.Position.X:=Inst.Position.X+Pos.X; Inst.Position.Z:=Inst.Position.Z+Pos.Z;
    end;
    Instances[I]:=Inst;
  end;
  UploadDistantTrees(Instances,P,Center.Position);
end;
procedure TTreeRenderer.UploadDistantTrees(const Instances: array of TTreeInstance;
  const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition);
begin
  UploadDistantTreesAt(Instances, [], Profile, WorldOrigin);
end;
procedure TTreeRenderer.UploadDistantTreesAt(const Instances: array of TTreeInstance;
  const RenderPositions: array of TTreeWorldPosition;
  const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition);
begin
  UploadDistantItems(PackDistantTreesAt(Instances,RenderPositions,Profile,WorldOrigin));
end;
class function TTreeRenderer.PackDistantTreesAt(const Instances: array of TTreeInstance;
  const RenderPositions: array of TTreeWorldPosition;
  const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition): TTreeGPUItems;
var Items: TTreeGPUItems; I: Integer; Pos: TTreeVec3; Actual: TTreeParams;
begin
  ValidateTreeParams(Profile); SetLength(Items,Length(Instances));
  if (Length(RenderPositions)<>0) and (Length(RenderPositions)<>Length(Instances)) then
    raise EArgumentException.Create('Render positions must match tree instances');
  for I:=0 to High(Instances) do begin
    if Instances[I].Species<>Profile.Species then raise EArgumentException.Create('Distant batch must share one type profile');
    Pos:=Vec(Instances[I].Position.X-WorldOrigin.X,Instances[I].Position.Y-WorldOrigin.Y,Instances[I].Position.Z-WorldOrigin.Z);
    if Length(RenderPositions)<>0 then
      Pos:=Vec(RenderPositions[I].X-WorldOrigin.X,RenderPositions[I].Y-WorldOrigin.Y,RenderPositions[I].Z-WorldOrigin.Z);
    Actual:=ResolveTreeParams(Instances[I],Profile);
    SetVec(Items[I],0,Pos,0); SetVec(Items[I],4,Vec(Actual.Height,Actual.TrunkRadius,Actual.CrownSpread),Actual.CrownStart);
    Items[I][12]:=HashUnit(Actual.Seed,10); SetType(Items[I],Actual);
  end;
  Result:=Items;
end;
procedure TTreeRenderer.UploadDistantItems(const Items:TTreeGPUItems);
var I:Integer;
begin
  FFarMinHeight:=0;FFarMaxHeight:=0;
  for I:=0 to High(Items) do begin
    if I=0 then FFarMinHeight:=Items[I][4] else FFarMinHeight:=Min(FFarMinHeight,Items[I][4]);
    FFarMaxHeight:=Max(FFarMaxHeight,Items[I][4]);
  end;
  FForestCount:=Length(Items);
  Upload(3,Items);
end;
procedure TTreeRenderer.UpdateDistantItems(First: Integer; const Items: TTreeGPUItems);
var Previous: GLint; Bytes: Int64;
begin
  if Length(Items)=0 then Exit;
  if (First<0) or (First+Length(Items)>FForestCount) then
    raise EArgumentException.Create('Tree instance update outside buffer');
  Bytes:=Int64(Length(Items))*SizeOf(TTreeGPUItem);
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@Previous);
  glBindBuffer(GL_ARRAY_BUFFER,FVBO[3]);
  try glBufferSubData(GL_ARRAY_BUFFER,Int64(First)*SizeOf(TTreeGPUItem),Bytes,@Items[0]);
  finally glBindBuffer(GL_ARRAY_BUFFER,Previous) end;
  Inc(FStats.UploadBytes,Bytes);
end;

function TTreeRenderer.UploadIndices(const Indices:TTreeIndices):GLuint;
var PreviousBuffer:GLint;
begin
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@PreviousBuffer);
  glGenBuffers(1,@Result);glBindBuffer(GL_ARRAY_BUFFER,Result);
  glBufferData(GL_ARRAY_BUFFER,Length(Indices)*SizeOf(GLushort),@Indices[0],GL_STATIC_DRAW);
  glBindBuffer(GL_ARRAY_BUFFER,PreviousBuffer);
end;
function TTreeRenderer.GridIndices(Slices,Segments:Integer):GLuint;
var Indices:TTreeIndices;I,X,Y,K:Integer;
  function VertexID(VX,VY:Integer):GLushort;
  begin
    { Reuse an existing gl_VertexID with the same grid corner. The shader's
      coordinates, seam normals and triangle order are exactly preserved. }
    if VY<Segments then begin
      if VX<Slices then Result:=(VY*Slices+VX)*6
      else Result:=(VY*Slices+Slices-1)*6+1;
    end else begin
      if VX<Slices then Result:=((Segments-1)*Slices+VX)*6+5
      else Result:=Segments*Slices*6-4;
    end;
  end;
begin
  if Assigned(FShared) then Exit(FShared.GridIndices(Slices,Segments));
  if (Slices<=0) or (Segments<=0) or (Int64(Slices)*Segments*6>65536) then Exit(0);
  for I:=0 to High(FGridIndices) do
    if (FGridIndices[I].Slices=Slices) and (FGridIndices[I].Segments=Segments) then Exit(FGridIndices[I].Buffer);
  SetLength(Indices,Slices*Segments*6);K:=0;
  for Y:=0 to Segments-1 do for X:=0 to Slices-1 do begin
    Indices[K]:=VertexID(X,Y);Indices[K+1]:=VertexID(X+1,Y);Indices[K+2]:=VertexID(X+1,Y+1);
    Indices[K+3]:=Indices[K];Indices[K+4]:=Indices[K+2];Indices[K+5]:=VertexID(X,Y+1);Inc(K,6);
  end;
  Result:=UploadIndices(Indices);I:=Length(FGridIndices);SetLength(FGridIndices,I+1);
  FGridIndices[I].Slices:=Slices;FGridIndices[I].Segments:=Segments;FGridIndices[I].Buffer:=Result;
end;
function TTreeRenderer.CardIndices:GLuint;
var Indices:TTreeIndices;
begin
  if Assigned(FShared) then Exit(FShared.CardIndices);
  if FCardIndices=0 then begin
    Indices:=TTreeIndices.Create(0,1,2,0,2,5);FCardIndices:=UploadIndices(Indices);
  end;
  Result:=FCardIndices;
end;
function TTreeRenderer.NeedleIndices:GLuint;
const Corners:array[0..8]of Integer=(0,1,2,2,1,5,2,5,8);
var Indices:TTreeIndices;I,J:Integer;
begin
  if Assigned(FShared) then Exit(FShared.NeedleIndices);
  if FNeedleIndices=0 then begin
    { Largest density group and fascicle fit in 16-bit IDs. One shared table,
      no needle positions or geometry on the CPU. Prefixes serve every LOD. }
    SetLength(Indices,NEEDLE_GROUP_PAIRS[NEEDLE_DENSITY_GROUPS-1]*8*9);
    for I:=0 to Length(Indices) div 9-1 do for J:=0 to 8 do Indices[I*9+J]:=I*9+Corners[J];
    FNeedleIndices:=UploadIndices(Indices);
  end;
  Result:=FNeedleIndices;
end;
procedure TTreeRenderer.Draw(Kind,BufferIndex,Vertices,Count: Integer; VertexArray: GLuint; IndexBuffer:GLuint);
var J: Integer;
begin
  if Count<=0 then Exit;
  glUniform1i(UKind,Kind);
  if VertexArray=0 then VertexArray:=FVAO[BufferIndex];
  glBindVertexArray(VertexArray);
  { Ground uses only gl_VertexID. A scene may have zero forest descriptors;
    never let the driver fetch enabled attributes from that empty buffer. }
  if Kind=4 then for J:=0 to 4 do glDisableVertexAttribArray(J);
  try
    if IndexBuffer<>0 then begin
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,IndexBuffer);
      glDrawElementsInstanced(GL_TRIANGLES,Vertices,GL_UNSIGNED_SHORT,nil,Count);
    end else glDrawArraysInstanced(GL_TRIANGLES,0,Vertices,Count);
  finally if Kind=4 then for J:=0 to 4 do glEnableVertexAttribArray(J); end;
  Inc(FStats.DrawCalls); Inc(FStats.Triangles,Vertices div 3*Count);
end;
function TTreeRenderer.VerifyPackedType(Expected: TTreeTypeCode): Boolean;
const GL_VERTEX_ATTRIB_ARRAY_DIVISOR_QUERY = $88FE; { core 3.3; absent in this FPC header }
var OldVAO,OldBuffer,IsInteger,Kind,Divisor: GLint; Code: TTreeTypeCode;
begin
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO); glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer);
  try
    glBindVertexArray(FVAO[3]); glBindBuffer(GL_ARRAY_BUFFER,FVBO[3]);
    Code:=0; glGetBufferSubData(GL_ARRAY_BUFFER,52,SizeOf(Code),@Code);
    glGetVertexAttribiv(4,GL_VERTEX_ATTRIB_ARRAY_INTEGER,@IsInteger);
    glGetVertexAttribiv(4,GL_VERTEX_ATTRIB_ARRAY_TYPE,@Kind);
    glGetVertexAttribiv(4,GL_VERTEX_ATTRIB_ARRAY_DIVISOR_QUERY,@Divisor);
    Result:=(Code=Expected) and (IsInteger=GL_TRUE) and (Kind=GL_UNSIGNED_INT) and (Divisor=1);
  finally glBindVertexArray(OldVAO); glBindBuffer(GL_ARRAY_BUFFER,OldBuffer); end;
end;
procedure TTreeRenderer.Render(const Instance: TTreeInstance; const P: TTreeParams;
  const Projection,View,Model: TTreeMat4; const Eye: TTreeVec3;
  Quality,Seconds,Wind: Single; Wireframe,Debug,ShowLeaves,ShowGround,ShowForest: Boolean;
  PreserveGLState: Boolean);
var OldProgram,OldVAO,OldBuffer,OldDepthFunc: GLint; OldPolygon: array[0..1] of GLint;
    WasDepth,WasBlend,WasCull,OldDepthMask: GLBoolean; Slices,Segments,Count,D,J: Integer; Bytes: Int64;
    Actual: TTreeParams; Resources: TTreeRenderer; UseAtlas: Boolean; OldActiveTexture,OldTexture: GLint;
    Viewport: array[0..3] of GLint; SeasonState: TTreeSeasonState;
    DirectBranches: Boolean; G,FullPairs,ViewHeight,FruitMembers:Integer;NeedleIndexBuffer:GLuint;
    NeedleDetail,RenderWind,FruitAmount,FruitPixels,EyeDistance:Single;
begin
  if not FReady then Exit;
  Bytes:=FStats.UploadBytes; FStats:=Default(TTreeRenderStats); FStats.UploadBytes:=Bytes;
  FStats.FarMinHeight:=FFarMinHeight; FStats.FarMaxHeight:=FFarMaxHeight;
  Actual:=ResolveTreeParams(Instance,P);
  DirectBranches:=(FEnvironment.Enabled and FEnvironment.DirectBranches) or
    (P.Species in [tsBamboo,tsPalm,tsFanPalm,tsCactus,tsPricklyPear]);
  Resources:=Self; if Assigned(FShared) then Resources:=FShared;
  SeasonState:=EvaluateTreeSeason(P.Species,P.LeafColor,Resources.FSeason);
  if FBakeMode then SeasonState:=EvaluateTreeSeason(P.Species,P.LeafColor,TREE_SUMMER);
  FruitAmount:=TreeFruitAmount(P.Species,Resources.FSeason);
  if FBakeMode then FruitAmount:=1;
  UseAtlas:=FUseBakedLOD and not FBakeMode and ShowLeaves and HasLODAtlas(P);
  if UseAtlas and not Resources.FLODSeasonParts[P.Species] and
    (Abs(WrapTreeSeason(Resources.FSeason)-TREE_SUMMER)>0.0001) then UseAtlas:=False;
  if PreserveGLState then begin
  glGetIntegerv(GL_ACTIVE_TEXTURE,@OldActiveTexture); glActiveTexture(GL_TEXTURE0);
  glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldTexture);
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram); glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer); glGetIntegerv(GL_POLYGON_MODE,@OldPolygon[0]);
  glGetIntegerv(GL_DEPTH_FUNC,@OldDepthFunc); glGetBooleanv(GL_DEPTH_WRITEMASK,@OldDepthMask);
  WasDepth:=glIsEnabled(GL_DEPTH_TEST); WasBlend:=glIsEnabled(GL_BLEND); WasCull:=glIsEnabled(GL_CULL_FACE);
  end;
  try
    glEnable(GL_DEPTH_TEST); glDepthFunc(GL_LEQUAL); glDepthMask(GL_TRUE); glDisable(GL_BLEND); glDisable(GL_CULL_FACE);
    glUseProgram(FProgram);
    if FEnvironment.Enabled then begin
      glUniform3fv(USunDirection,1,@FEnvironment.SunDirection);
      glUniform3fv(UBillboardRight,1,@FEnvironment.BillboardRight);
      glUniform3fv(UFogColor,1,@FEnvironment.FogColor);
      glUniform1f(UFogDensity,FEnvironment.FogDensity);
      glUniform1f(UOutputGamma,FEnvironment.OutputGamma);
      glUniform1i(UDepthOnly,Ord(FEnvironment.DepthOnly));
    end else begin
      glUniform3f(USunDirection,-0.5,0.85,0.45);
      glUniform3f(UBillboardRight,View[0],0,View[8]);
      glUniform3f(UFogColor,0.19,0.26,0.27);
      glUniform1f(UFogDensity,0.0014); glUniform1f(UOutputGamma,1/2.2);
      glUniform1i(UDepthOnly,0);
    end;
    glUniform1i(UBakeMode,Ord(FBakeMode)); glUniform1i(UUseBakedLOD,Ord(UseAtlas));
    glUniform1i(UDirectBranches,Ord(DirectBranches));
    glUniform1f(ULeafScale,1);
    glUniform1f(UNeedleScale,1);
    NeedleDetail:=1;
    if DirectBranches and not FBakeMode then NeedleDetail:=Clamp(FEnvironment.NeedleDetail,0,1);
    RenderWind:=Wind;
    if FEnvironment.Enabled and FEnvironment.DepthOnly and IsConifer(P.Species) and not FBakeMode then begin
      { Filter sub-texel needle motion in shadows. Wood and foliage share the
        reduced sway, so their shadow silhouettes stay attached. Individual
        needles and their viewer-dependent LOD are only needed in colour. }
      RenderWind:=Wind*0.15;
      if DirectBranches then NeedleDetail:=0;
    end;
    glUniform1f(UNeedleDetail,NeedleDetail);
    glUniform1f(USeasonLeaf,SeasonState.LeafAmount);
    glUniform3f(ULeafRatio,SeasonState.LeafColor.X/Max(0.0001,P.LeafColor.X),
      SeasonState.LeafColor.Y/Max(0.0001,P.LeafColor.Y),SeasonState.LeafColor.Z/Max(0.0001,P.LeafColor.Z));
    glUniform1i(ULODSeasonParts,Ord(Resources.FLODSeasonParts[P.Species]));
    glUniform1i(ULODFruitLayer,Ord(Resources.FLODFruitLayer[P.Species]));
    glUniform1f(UFruitAmount,FruitAmount);glUniform1i(UFruitMembers,FFruitMembers);
    glUniform1i(ULODTexture,0);
    if UseAtlas then begin
      glBindTexture(GL_TEXTURE_2D_ARRAY,Resources.FLODTextures[P.Species]);
      glUniform3fv(ULODFrames,LOD_AGES,@Resources.FLODFrames[P.Species][0].X);
    end;
    glUniformMatrix4fv(UProjection,1,GL_FALSE,@Projection[0]);
    glUniformMatrix4fv(UView,1,GL_FALSE,@View[0]); glUniformMatrix4fv(UModel,1,GL_FALSE,@Model[0]);
    glUniform3f(UEye,Eye.X,Eye.Y,Eye.Z); glUniform1f(UTime,Seconds); glUniform1f(UWind,RenderWind);
    if FEnvironment.Enabled and (FEnvironment.ViewportHeight>0) then
      ViewHeight:=FEnvironment.ViewportHeight
    else begin glGetIntegerv(GL_VIEWPORT,@Viewport[0]);ViewHeight:=Max(1,Viewport[3]);end;
    glUniform1f(UViewportHeight,ViewHeight);
    glUniform4f(UProfile,Actual.Height,Actual.TrunkRadius,Actual.CrownSpread,Actual.CrownStart);
    glUniform3f(UBark,P.BarkColor.X,P.BarkColor.Y,P.BarkColor.Z);
    glUniform3f(ULeaf,SeasonState.LeafColor.X,SeasonState.LeafColor.Y,SeasonState.LeafColor.Z);
    glUniform1i(USpecies,Ord(P.Species)); glUniform1i(UDebug,Ord(Debug));
    glUniform1f(UDensity,P.LeafDensity*Ord(ShowLeaves));
    glUniform1f(UQuality,Quality);
    if ShowGround then Draw(4,3,6,1,0,CardIndices);
    if Wireframe then glPolygonMode(GL_FRONT_AND_BACK,GL_LINE);
    if ShowForest and (FForestCount>1) and (Quality<=0.35) then begin
      glUniform1f(UQuality,0); Draw(3,3,6,FForestCount,0,CardIndices); FStats.FarTrees:=FForestCount;
      glUniform1f(UQuality,Quality);
    end else if ShowForest and (FForestCount>1) then begin
      glUniform1f(UQuality,0);
      { The first instance is the selected tree. Offset attributes to skip it. }
      glBindVertexArray(FVAO[3]); glBindBuffer(GL_ARRAY_BUFFER,FVBO[3]);
      for J:=0 to 3 do glVertexAttribPointer(J,4,GL_FLOAT,GL_FALSE,SizeOf(TTreeGPUItem),Pointer(PtrUInt(64+J*16)));
      glVertexAttribIPointer(4,1,GL_UNSIGNED_INT,SizeOf(TTreeGPUItem),Pointer(PtrUInt(64+52)));
      Draw(3,3,6,FForestCount-1,0,CardIndices); FStats.FarTrees:=FForestCount-1;
      for J:=0 to 3 do glVertexAttribPointer(J,4,GL_FLOAT,GL_FALSE,SizeOf(TTreeGPUItem),Pointer(PtrUInt(J*16)));
      glVertexAttribIPointer(4,1,GL_UNSIGNED_INT,SizeOf(TTreeGPUItem),Pointer(PtrUInt(52)));
      glUniform1f(UQuality,Quality);
    end;
    if (Quality<0.95) and not (ShowForest and (FForestCount>1) and (Quality<=0.35)) then begin
      Draw(3,3,6,Min(1,FForestCount),0,CardIndices); Inc(FStats.FarTrees,Min(1,FForestCount));
    end;
    if Quality>0.35 then begin
      if Quality>2.4 then begin Slices:=9; Segments:=5; end else begin Slices:=5; Segments:=3; end;
      if (P.Species=tsMountainPine) and (Quality>2.4) then Segments:=12;
      if FEnvironment.Enabled then begin
        if FEnvironment.BranchSides>0 then Slices:=FEnvironment.BranchSides;
        if FEnvironment.BranchSegments>0 then Segments:=FEnvironment.BranchSegments;
      end;
      if P.Species=tsCactus then begin Slices:=Max(Slices,12);Segments:=Max(Segments,10);end;
      glUniform1i(USlices,Slices); glUniform1i(USegments,Segments);
      Count:=FDepthCounts[0];
      for D:=1 to 4 do if DirectBranches or (BranchGrowth(D,Quality)>0) then Inc(Count,FDepthCounts[D]);
      if not FBakeMode or (FBakePart in [0,1]) then begin Draw(0,0,Slices*Segments*6,Count,0,GridIndices(Slices,Segments)); FStats.Branches:=Count; end;
      if (P.Species=tsPricklyPear) and (not FBakeMode or (FBakePart in [0,1])) then begin
        glUniform1i(USlices,8);glUniform1i(USegments,8);
        Draw(8,1,8*8*6,FLeafCount,0,GridIndices(8,8));FStats.Leaves:=FLeafCount;
      end;
      if ShowLeaves and (P.LeafDensity>0) and (SeasonState.LeafAmount>0.0001) and (not FBakeMode or (FBakePart in [0,2])) then begin
        if (Quality<4) and not DirectBranches then begin
          glUniform1i(USlices,8); glUniform1i(USegments,5);
          Draw(2,2,8*5*6,FCrownCount,0,GridIndices(8,5)); FStats.Proxies:=FCrownCount;
        end;
        if DirectBranches or (Quality>3.4) then begin
          if IsConifer(P.Species) then begin
            glUniform1i(UNeedlesPerFascicle,FNeedlesPerFascicle);
            glUniform1i(UNeedleVertices,NeedleVertices(P.Species));
            NeedleIndexBuffer:=0;
            if (NeedleDetail>0) and (NeedleVertices(P.Species)=9) then NeedleIndexBuffer:=NeedleIndices;
            for G:=0 to NEEDLE_DENSITY_GROUPS-1 do if FNeedleGroups[G].Count>0 then begin
              FullPairs:=NEEDLE_GROUP_PAIRS[G];Count:=FullPairs;
              if NeedleDetail<1 then begin
                glUniform1i(UNeedlePairs,FullPairs);
                Draw(6,4,12,FNeedleGroups[G].Count,FNeedleVAO[G],GridIndices(1,2));
                Inc(FStats.Shoots,FNeedleGroups[G].Count);
              end;
              if NeedleDetail<=0 then Continue;
              if DirectBranches then
                Count:=DrawNeedlePairs(FullPairs,FNeedleShootCount,P.Species,
                  FEnvironment.LeafFraction,FEnvironment.NeedleDetail);
              if Count>0 then glUniform1f(UNeedleScale,FullPairs/Count);
              glUniform1i(UNeedlePairs,Count);
              Draw(5,4,Count*FNeedlesPerFascicle*NeedleVertices(P.Species),FNeedleGroups[G].Count,FNeedleVAO[G],NeedleIndexBuffer);
              Inc(FStats.Needles,FNeedleGroups[G].Count*Count*FNeedlesPerFascicle);
            end;
          end else begin
            Count:=FLeafCount;
            if DirectBranches and not (P.Species in [tsBamboo,tsPalm,tsFanPalm]) and
              (FEnvironment.LeafFraction>0) and (Count>0) then begin
              Count:=Max(1,Min(Count,Round(Count*FEnvironment.LeafFraction)));
              glUniform1f(ULeafScale,Sqrt(FLeafCount/Count));
            end;
            Draw(1,1,6,Count,0,CardIndices);FStats.Leaves:=Count;
          end;
        end;
      end;
      if (FFruitCount>0) and ShowLeaves and (FruitAmount>0.001) and
         (DirectBranches or (Quality>3.4)) and (not FBakeMode or (FBakePart in [0,3])) then begin
        EyeDistance:=Max(0.1,Magnitude(Sub(Eye,
          Vec(Model[12],Model[13]+Actual.Height*0.55,Model[14])))-Actual.Height*0.2);
        FruitPixels:=FFruitRadius*ViewHeight*Abs(Projection[5])/EyeDistance;
        if FBakeMode or (FruitPixels>0.4) then begin
          FruitMembers:=FFruitMembers;
          { A few-pixel bunch is one surface, not dozens of subpixel spheres. }
          if not FBakeMode and ((FruitPixels<10) or
            ((Actual.Species=tsRowan) and (FruitPixels<18))) then FruitMembers:=1;
          glUniform1i(UFruitMembers,FruitMembers);
          { A rowan bunch contains 36 berries: tessellate individual berries
            finely only in close-up, not when the whole bunch is a few pixels. }
          if FBakeMode or ((FruitPixels>12) and (Actual.Species<>tsRowan)) or
             (FruitPixels>32) then begin Slices:=8;Segments:=5 end
          else begin Slices:=6;Segments:=3 end;
          glUniform1i(USlices,Slices);glUniform1i(USegments,Segments);
          Draw(7,5,(Slices*Segments*6+12*Ord(FruitMembers>1))*FruitMembers+24,FFruitCount);
          FStats.Fruits:=FFruitCount*FruitMembers;
        end;
      end;
    end;
    if UseAtlas then FStats.BakedFarTrees:=FStats.FarTrees;
  finally
    if PreserveGLState then begin
    glBindTexture(GL_TEXTURE_2D_ARRAY,OldTexture); glActiveTexture(OldActiveTexture);
    glUseProgram(OldProgram); glBindVertexArray(OldVAO); glBindBuffer(GL_ARRAY_BUFFER,OldBuffer);
    glPolygonMode(GL_FRONT_AND_BACK,OldPolygon[0]); glDepthFunc(OldDepthFunc); glDepthMask(OldDepthMask);
    if WasDepth=GL_TRUE then glEnable(GL_DEPTH_TEST) else glDisable(GL_DEPTH_TEST);
    if WasBlend=GL_TRUE then glEnable(GL_BLEND) else glDisable(GL_BLEND);
    if WasCull=GL_TRUE then glEnable(GL_CULL_FACE) else glDisable(GL_CULL_FACE);
    end;
  end;
end;
end.
