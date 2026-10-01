unit RiderHairData;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, CastleVectors, X3DNodes;
const
  HairGuideCount = 24;
  HairGuidePoints = 8;
  HairPointCount = HairGuideCount * HairGuidePoints;
  HairLodCount = 4;
type
  THairGuide = record
    Stiffness: Single;
    Pinned: LongWord;
    Rest, Helmet: array[0..HairGuidePoints-1] of TVector3;
  end;
  THairGuides = array[0..HairGuideCount-1] of THairGuide;
  THairVertex = packed record
    Position, Normal: TVector3;
    UV: TVector2;
    Bind: TVector4;
    Rest, GuideTangent, StrandTangent, HelmetDelta: TVector3;
  end;
  THairMesh = record
    Vertices: array of THairVertex;
    Indices: array of LongWord;
  end;
  THairStyleData = record
    Id: String;
    Guides: THairGuides;
    Mesh: array[0..HairLodCount-1] of THairMesh;
  end;
  TRiderHairData = class
  public
    Styles: array of THairStyleData;
    Scalp: array[0..HairLodCount-1] of THairMesh;
    Path: String;
    constructor Create(const APath: String);
    function IndexOf(const Id: String): Integer;
    function Geometry(Style, Lod: Integer): TIndexedTriangleSetNode;
    function ScalpGeometry(Lod: Integer): TIndexedTriangleSetNode;
  end;
{ Packed vertices and guides are immutable and shared across riders. CGE nodes
  belong to one scene: their Scene/shape-association callbacks must never be
  shared between the menu preview, the player and bots. Node construction is
  only done when loading an avatar, outside the frame loop. }
function LoadRiderHairData(const Path: String): TRiderHairData;
implementation
uses Math;
var Cache: TStringList;

constructor TRiderHairData.Create(const APath: String);
var S:TFileStream; Magic:array[0..3]of Char; V,N,G,P,LC:LongWord;
  I,J,K,L:Integer; Name:array[0..15]of Char;Values:array[0..23]of Single;
  procedure Finite(const Value:Single);
  begin
    if IsNan(Value)or IsInfinite(Value)then raise Exception.Create('Non-finite rider groom data');
  end;
  procedure ReadMesh(var Mesh:THairMesh;const IsScalp:Boolean);
  var VC,IC:LongWord;A,B:Integer;
  begin
    with Mesh do begin
      S.ReadBuffer(VC,4);S.ReadBuffer(IC,4);
      if(VC>100000)or(IC>600000)or(IC mod 3<>0)or
        (Int64(VC)*SizeOf(THairVertex)+Int64(IC)*4>S.Size-S.Position)then
        raise Exception.Create('Invalid rider groom mesh');
      SetLength(Vertices,VC);SetLength(Indices,IC);
      if VC>0 then S.ReadBuffer(Vertices[0],VC*SizeOf(THairVertex));
      if IC>0 then S.ReadBuffer(Indices[0],IC*4);
      for A:=0 to Integer(IC)-1 do if Indices[A]>=VC then
        raise Exception.Create('Invalid rider groom index');
      for A:=0 to Integer(VC)-1 do begin
        Move(Vertices[A],Values,SizeOf(Values));
        for B:=0 to High(Values)do Finite(Values[B]);
        if IsScalp then begin
          if Vertices[A].Bind.X<>-1 then raise Exception.Create('Invalid groom scalp binding');
        end else
        if(Vertices[A].Bind.X<0)or(Vertices[A].Bind.X>HairPointCount-HairGuidePoints)or
          (Frac(Vertices[A].Bind.X/HairGuidePoints)<>0)or
          (Vertices[A].Bind.Y<0)or(Vertices[A].Bind.Y>HairGuidePoints-1)then
          raise Exception.Create('Invalid rider groom vertex');
      end;
    end;
  end;
begin
  inherited Create; Path:=APath;
  S:=TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite);
  try
    S.ReadBuffer(Magic,4);S.ReadBuffer(V,4);S.ReadBuffer(N,4);
    S.ReadBuffer(G,4);S.ReadBuffer(P,4);
    if(Magic<>'RZHR')or not(V in [1,2])or(N<1)or(N>32)or
      (G<>HairGuideCount)or(P<>HairGuidePoints)then
      raise Exception.Create('Unsupported rider groom: '+Path);
    LC:=3;
    if V=2 then begin
      S.ReadBuffer(LC,4);
      if LC<>HairLodCount then raise Exception.Create('Unsupported groom LOD count');
      for J:=0 to HairLodCount-1 do ReadMesh(Scalp[J],True);
    end;
    SetLength(Styles,N);
    for I:=0 to N-1 do begin
      S.ReadBuffer(Name,SizeOf(Name));Name[15]:=#0;Styles[I].Id:=StrPas(@Name[0]);
      for J:=0 to HairGuideCount-1 do begin
        S.ReadBuffer(Styles[I].Guides[J],SizeOf(THairGuide));
        Finite(Styles[I].Guides[J].Stiffness);
        if(Styles[I].Guides[J].Pinned<1)or(Styles[I].Guides[J].Pinned>=HairGuidePoints)then
          raise Exception.Create('Invalid groom root binding');
        for K:=0 to HairGuidePoints-1 do for L:=0 to 2 do begin
          Finite(Styles[I].Guides[J].Rest[K].Data[L]);
          Finite(Styles[I].Guides[J].Helmet[K].Data[L]);
        end;
      end;
      for J:=0 to Integer(LC)-1 do ReadMesh(Styles[I].Mesh[J],False);
      if V=1 then Styles[I].Mesh[3]:=Styles[I].Mesh[2];
    end;
    if S.Position<>S.Size then raise Exception.Create('Trailing rider groom data');
  finally S.Free end;
end;

function TRiderHairData.IndexOf(const Id:String):Integer;
var I:Integer;
begin
  for I:=0 to High(Styles)do if Styles[I].Id=Id then Exit(I);
  Result:=-1;
end;

function MeshGeometry(const Mesh:THairMesh):TIndexedTriangleSetNode;
var Co:TCoordinateNode;No:TNormalNode;UV:TTextureCoordinateNode;
  B,R,G,T,H,U:TFloatVertexAttributeNode;I:Integer;V:THairVertex;
  function Attr(const Name:String;Size:Integer):TFloatVertexAttributeNode;
  begin
    Result:=TFloatVertexAttributeNode.Create;Result.NameField:=Name;
    Result.NumComponents:=Size;
  end;
  procedure Vec(A:TFloatVertexAttributeNode;const P:TVector3);
  begin A.FdValue.Items.Add(P.X);A.FdValue.Items.Add(P.Y);A.FdValue.Items.Add(P.Z) end;
begin
  Result:=TIndexedTriangleSetNode.Create;Result.Solid:=False;
  Co:=TCoordinateNode.Create;No:=TNormalNode.Create;UV:=TTextureCoordinateNode.Create;
  Result.Coord:=Co;Result.Normal:=No;Result.TexCoord:=UV;
  B:=Attr('riderHairBind',4);R:=Attr('riderHairRest',3);G:=Attr('riderHairGuide',3);
  T:=Attr('riderHairStrand',3);H:=Attr('riderHairHelmet',3);
  U:=Attr('riderHairUV',2);
  Result.FdAttrib.Add(B);Result.FdAttrib.Add(R);Result.FdAttrib.Add(G);
  Result.FdAttrib.Add(T);Result.FdAttrib.Add(H);
  Result.FdAttrib.Add(U);
  for I:=0 to High(Mesh.Vertices)do begin
    V:=Mesh.Vertices[I];
    Co.FdPoint.Items.Add(V.Position);No.FdVector.Items.Add(V.Normal);UV.FdPoint.Items.Add(V.UV);
    B.FdValue.Items.Add(V.Bind.X);B.FdValue.Items.Add(V.Bind.Y);
    B.FdValue.Items.Add(V.Bind.Z);B.FdValue.Items.Add(V.Bind.W);
    U.FdValue.Items.Add(V.UV.X);U.FdValue.Items.Add(V.UV.Y);
    Vec(R,V.Rest);Vec(G,V.GuideTangent);Vec(T,V.StrandTangent);Vec(H,V.HelmetDelta);
  end;
  for I:=0 to High(Mesh.Indices)do
    Result.FdIndex.Items.Add(Mesh.Indices[I]);
end;

function TRiderHairData.Geometry(Style,Lod:Integer):TIndexedTriangleSetNode;
begin Result:=MeshGeometry(Styles[Style].Mesh[Lod]) end;

function TRiderHairData.ScalpGeometry(Lod:Integer):TIndexedTriangleSetNode;
begin Result:=MeshGeometry(Scalp[Lod]) end;

function LoadRiderHairData(const Path:String):TRiderHairData;
var I:Integer;
begin
  Result:=nil;if not FileExists(Path)then Exit;
  if Cache=nil then Cache:=TStringList.Create;
  I:=Cache.IndexOf(ExpandFileName(Path));
  if I>=0 then Exit(TRiderHairData(Cache.Objects[I]));
  Result:=TRiderHairData.Create(Path);Cache.AddObject(ExpandFileName(Path),Result);
end;

procedure ClearCache;
var I:Integer;
begin
  if Cache=nil then Exit;
  for I:=0 to Cache.Count-1 do Cache.Objects[I].Free;
  FreeAndNil(Cache);
end;
finalization
  ClearCache;
end.
