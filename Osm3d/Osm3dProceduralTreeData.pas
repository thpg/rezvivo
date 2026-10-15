unit Osm3dProceduralTreeData;
{$mode objfpc}{$H+}
interface
uses Osm3dGeoMath, Osm3dOsmData, Osm3dTileX3D, TreeModel;
function TreeIdentity(const LL: TLatLon): TTreeWorldPosition;
function TreeTagJSON(Tags: TOSMTags): string;
function ClassifyTreeTag(const Json: string; const LL: TLatLon;
  Shrub: Boolean; Forest: Boolean = False; Elevation: Double = 0;
  PhotoHeight: Double = 0): TProceduralTreeTag;
function ProceduralTreeInstance(const Rec: TTileTreeRec;
  Projection: TLocalProjection): TreeModel.TTreeInstance;
function TreeClassificationErrors: LongInt;
{ Direct billboard -> complete branches/foliage transition. Keep descriptors
  bounded without replacing foliage with crown ellipsoids. CPU worker only. }
procedure PrepareGameTreeDetail(var Data:TTreeData; MaxBytes:Int64 = 2*1024*1024);
implementation
uses SysUtils, Math, fpjson, TreeOsm, TreeForestRegions;
var ClassificationErrorCount: LongInt;
function TreeClassificationErrors: LongInt;
begin Result:=InterlockedCompareExchange(ClassificationErrorCount,0,0);end;
procedure PrepareGameTreeDetail(var Data:TTreeData; MaxBytes:Int64);
var I,N,Keep,First,Last,MaxItems,Branches,Foliage,LeafKeep,ShootKeep:Integer;
  function Representative(Index,Count,Total:Integer):Integer;
  begin
    First:=Int64(Index)*Total div Count;
    Last:=Int64(Index+1)*Total div Count;
    { Stratify over all branches, but do not repeatedly pick the same leaf
      orientation in the generator's periodic twig/leaf order. }
    Result:=First+Integer(Hash32(LongWord(Index) xor Data.Fingerprint) mod LongWord(Max(1,Last-First)));
  end;
begin
  Data.Crowns:=nil;
  Data.SourceLeafCount:=Max(Data.SourceLeafCount,Length(Data.Leaves));
  Data.SourceShootCount:=Max(Data.SourceShootCount,Length(Data.NeedleShoots));
  MaxItems:=Max(4,Min(High(Integer),MaxBytes div 64));
  N:=Length(Data.Fruits);Keep:=Min(N,MaxItems div 8);
  if N>Keep then begin
    for I:=0 to Keep-1 do Data.Fruits[I]:=Data.Fruits[Int64(I)*N div Keep];
    SetLength(Data.Fruits,Keep);
  end;
  Dec(MaxItems,Keep);
  { Under memory pressure retain real branches and distribute the available
    foliage across the entire crown. No ellipsoid or billboard substitution. }
  Foliage:=Length(Data.Leaves)+Length(Data.NeedleShoots);
  Branches:=Length(Data.Branches);
  if Branches+Foliage>MaxItems then begin
    if Foliage>0 then Branches:=Min(Branches,MaxItems div 2)
    else Branches:=Min(Branches,MaxItems);
    SetLength(Data.Branches,Branches); { breadth-first order keeps ancestors }
    Keep:=MaxItems-Branches;
    if Foliage>0 then begin
      LeafKeep:=Min(Length(Data.Leaves),Int64(Keep)*Length(Data.Leaves) div Foliage);
      ShootKeep:=Min(Length(Data.NeedleShoots),Keep-LeafKeep);
      N:=Length(Data.NeedleShoots);
      if N>ShootKeep then begin
        for I:=0 to ShootKeep-1 do begin
          Data.NeedleShoots[I]:=Data.NeedleShoots[Representative(I,ShootKeep,N)];
        end;
        SetLength(Data.NeedleShoots,ShootKeep);
      end;
    end else LeafKeep:=0;
  end else LeafKeep:=Length(Data.Leaves);
  N:=Length(Data.Leaves);
  Keep:=LeafKeep;
  if N>Keep then begin
    { Keep physical blade sizes. The renderer represents the omitted twigs
      with repeated, physically sized foliage on grouped cards. }
    for I:=0 to Keep-1 do begin
      Data.Leaves[I]:=Data.Leaves[Representative(I,Keep,N)];
    end;
    SetLength(Data.Leaves,Keep);
  end;
  { PrepareTreeGPU shuffles the draw prefix once. No second array/permutation. }
  { Preserve biological needle density. The renderer chooses a draw count from
    viewer distance; permanently reducing it here made nearby conifers bare. }
end;
function TreeIdentity(const LL: TLatLon): TTreeWorldPosition;
var Lat, Lon: Double;
begin
  { Quantize once to the persisted OSM precision, then use sea-level ECEF.
    DEM height is deliberately excluded: better terrain must not regrow trees. }
  Lat := Round(LL.Lat * 1e7) * 1e-7 * DEG_TO_RAD;
  Lon := Round(LL.Lon * 1e7) * 1e-7 * DEG_TO_RAD;
  Result.X := EARTH_RADIUS_M * Cos(Lat) * Cos(Lon);
  Result.Y := EARTH_RADIUS_M * Sin(Lat);
  Result.Z := EARTH_RADIUS_M * Cos(Lat) * Sin(Lon);
end;
function TreeTagJSON(Tags: TOSMTags): string;
var J: TJSONObject; I: Integer;
begin
  J := TJSONObject.Create;
  try
    if Tags <> nil then for I := 0 to Tags.Count-1 do J.Add(Tags.Keys[I], Tags.Values[I]);
    Result := J.AsJSON;
  finally J.Free; end;
end;
function ClassifyTreeTag(const Json: string; const LL: TLatLon;
  Shrub: Boolean; Forest: Boolean; Elevation, PhotoHeight: Double): TProceduralTreeTag;
var Code: TTreeTypeCode; Classification: TTreeClassification;Location:TForestLocation;
    Instance:TTreeInstance; Profile,Resolved:TTreeParams;
    Lo,Hi,Mid,Variant:Integer;UpperError:Double;
begin
  Result := Default(TProceduralTreeTag);
  try
    Location:=Default(TForestLocation);Location.Enabled:=Forest;
    Location.Latitude:=Round(LL.Lat*1e7)*1e-7;
    Location.Longitude:=Round(LL.Lon*1e7)*1e-7;Location.Elevation:=Elevation;
    Classification := ClassifyTreeJSON(Json, TreeIdentity(LL),Location);
    Code := Classification.TypeCode;
    if Shrub and (Classification.Source='fallback') then
      Code:=PackTreeType(tsShrub,TreeTypeAge(Code),TreeTypeVariant(Code));
    { Photo-authored height used to affect only the legacy billboard Scale.
      Procedural geometry and its generated LOD read the packed growth stage.
      Fit that stage once during baking; both render paths then use the same
      natural crown/trunk proportions, without runtime scaling or extra work.
      The inferred stage is visual, not a surveyed biological age. Preserve
      explicit ages and leave all ordinary OSM scatter unchanged. }
    if (PhotoHeight>0) and not IsNan(PhotoHeight) and not IsInfinite(PhotoHeight)
      and (TreeTypeAge(Code)=0) then begin
      Instance:=Default(TTreeInstance);Instance.Position:=TreeIdentity(LL);
      Instance.TypeCode:=Code;Profile:=DefaultTreeParams(Instance.Species);
      Variant:=TreeTypeVariant(Code);Lo:=1;Hi:=Min(TREE_MAX_AGE,MatureTreeAge(Profile.Species)*3);
      while Lo<Hi do begin
        Mid:=(Lo+Hi) div 2;
        Instance.TypeCode:=PackTreeType(Profile.Species,Mid,Variant);
        Resolved:=ResolveTreeParams(Instance,Profile);
        if Resolved.Height<PhotoHeight then Lo:=Mid+1 else Hi:=Mid;
      end;
      Instance.TypeCode:=PackTreeType(Profile.Species,Lo,Variant);
      Resolved:=ResolveTreeParams(Instance,Profile);UpperError:=Abs(Resolved.Height-PhotoHeight);
      if Lo>1 then begin
        Instance.TypeCode:=PackTreeType(Profile.Species,Lo-1,Variant);
        Resolved:=ResolveTreeParams(Instance,Profile);
        if Abs(Resolved.Height-PhotoHeight)<UpperError then Dec(Lo);
      end;
      Code:=PackTreeType(Profile.Species,Lo,Variant);
    end;
  except
    on E: Exception do begin
      { Bad age/taxon on one object must not abort an entire chunk. }
      InterlockedIncrement(ClassificationErrorCount);
      if Shrub then Code := PackTreeType(tsShrub) else Code := PackTreeType(tsBroadleaf);
    end;
  end;
  Result.TypePlusOne := Code + 1;
  Result.LatE7 := Round(LL.Lat * 1e7); Result.LonE7 := Round(LL.Lon * 1e7);
end;
function ProceduralTreeInstance(const Rec: TTileTreeRec;
  Projection: TLocalProjection): TreeModel.TTreeInstance;
var LL: TLatLon;
begin
  Result := Default(TreeModel.TTreeInstance);
  if Rec.Procedural.TypePlusOne <> 0 then begin
    Result.TypeCode := Rec.Procedural.TypePlusOne - 1;
    LL := TLatLon.Make(Rec.Procedural.LatE7 * 1e-7, Rec.Procedural.LonE7 * 1e-7);
    if Projection<>nil then Result.Position := TreeIdentity(LL)
    else begin
      Result.Position.X:=Rec.X;Result.Position.Y:=Rec.Y;Result.Position.Z:=Rec.Z;
    end;
  end else begin
    if Rec.IsShrub then Result.TypeCode := PackTreeType(tsShrub)
    else case Round(Rec.Seed) of
      1: Result.TypeCode := PackTreeType(tsSpruce);
      4: Result.TypeCode := PackTreeType(tsOak);
      else Result.TypeCode := PackTreeType(tsBroadleaf);
    end;
    if Projection <> nil then Result.Position := TreeIdentity(Projection.Unproject(Rec.X, Rec.Z))
    else begin { Baked Dream coordinates are stable within their separate world. }
      Result.Position.X := Rec.X; Result.Position.Y := Rec.Y; Result.Position.Z := Rec.Z;
    end;
  end;
end;
end.
