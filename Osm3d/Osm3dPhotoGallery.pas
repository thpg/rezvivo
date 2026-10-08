unit Osm3dPhotoGallery;
{$mode objfpc}{$H+}
{ Shared cache-only evidence merge. Discovery remains unreviewed until an agent
  explicitly writes observations; opening the gallery never saves a recipe. }
interface
uses SysUtils,Classes,fpjson,Osm3dPhotoApi;
function IsComparisonSource(S:TJSONObject;IncludeRejected:Boolean=False):Boolean;
procedure AppendCachedPhotoSources(Document,Catalog:TJSONObject; Client:TPhotoApiClient;
  NearbyDocuments:TJSONArray=nil);
function FindComparisonView(Document:TJSONObject; RelatedViews:TJSONArray;
  const SourceId:string):TJSONObject;
function CopyComparisonViewForTile(View,Document:TJSONObject):TJSONObject;
implementation
uses MD5,Osm3dCacheHTTPFetcher,Osm3dPhotoRelevance;
type TNeighborPhotoRef=class
  Source,Owner:TJSONObject;
end;
function IsComparisonSource(S:TJSONObject;IncludeRejected:Boolean):Boolean;
begin
  Result:=(S<>nil) and (IncludeRejected or not PhotoSourceRejected(S)) and
    ((S.Get('kind','')='photo') or (S.Get('kind','')='video_frame'));
end;

function FindComparisonView(Document:TJSONObject; RelatedViews:TJSONArray;
  const SourceId:string):TJSONObject;
var A:TJSONArray;I:Integer;V:TJSONObject;
begin
  Result:=nil;A:=ArrayAt(Document,'photo_views');
  if A<>nil then for I:=0 to A.Count-1 do
    if (A[I] is TJSONObject) and (TJSONObject(A[I]).Get('source_id','')=SourceId) then
      Exit(TJSONObject(A[I]));
  if RelatedViews<>nil then for I:=0 to RelatedViews.Count-1 do begin
    if not (RelatedViews[I] is TJSONObject) then Continue;
    V:=nil;
    if TJSONObject(RelatedViews[I]).Find('view') is TJSONObject then
      V:=TJSONObject(TJSONObject(RelatedViews[I]).Find('view'));
    if (V<>nil) and (V.Get('source_id','')=SourceId) then Exit(V);
  end;
end;

function CopyComparisonViewForTile(View,Document:TJSONObject):TJSONObject;
var Regions,Objects,Views:TJSONArray;I,J,Suffix:Integer;Found,Collision:Boolean;Id,BaseId:string;
begin
  Result:=TJSONObject(View.Clone);Regions:=ArrayAt(Result,'regions');
  Objects:=ArrayAt(Document,'objects');
  Views:=ArrayAt(Document,'photo_views');Suffix:=0;
  BaseId:='view:gallery:'+MD5Print(MD5String(Result.Get('source_id','')));
  repeat
    Collision:=False;
    if Views<>nil then for I:=0 to Views.Count-1 do
      if (TJSONObject(Views[I]).Get('id','')=Result.Get('id','')) and
        (TJSONObject(Views[I]).Get('source_id','')<>Result.Get('source_id','')) then begin
        Collision:=True;Break;
      end;
    if Collision then begin
      if Suffix=0 then Result.Strings['id']:=BaseId
      else Result.Strings['id']:=BaseId+':'+IntToStr(Suffix);
      Inc(Suffix);
    end;
  until not Collision;
  if Regions=nil then Exit;
  { The camera and geographic anchors remain meaningful across a tile border.
    Region object ids belong to the authored document, so do not persist dangling
    references when the user explicitly saves a borrowed comparison camera. }
  for I:=Regions.Count-1 downto 0 do begin
    Id:=TJSONObject(Regions[I]).Get('object_id','');Found:=False;
    if Objects<>nil then for J:=0 to Objects.Count-1 do
      if TJSONObject(Objects[J]).Get('id','')=Id then begin Found:=True;Break end;
    if not Found then Regions.Delete(I);
  end;
end;

procedure AppendCachedPhotoSources(Document,Catalog:TJSONObject; Client:TPhotoApiClient;
  NearbyDocuments:TJSONArray);
const Fields:array[0..14] of string=('latitude','longitude','coordinate_role','sequence_id',
  'sequence_index','heading_deg','projection','width','height','captured_at','license_url',
  'review_status','review_reason','review_note','review_origin');
var Sources,Photos,Related:TJSONArray;Seen,Rejected,NeighborIndex:TStringList;
  I,J,K,Omitted:Integer;P,S,Neighbor,NeighborDoc,V,Entry:TJSONObject;Id,Key:string;D:TJSONData;
  function MediaKey(Source:TJSONObject):string;
  begin
    Result:='';
    { Different video frames share a media id; only their unique frame ids can
      identify them. Never collapse all frames of a video into a single image. }
    if (Source.Get('kind','')='video_frame') or (Source.Find('time_s')<>nil) then Exit;
    if Source.Get('provider','')='' then Exit;
    Result:=Source.Get('media_id',Source.Get('image_id',''));
    if Result<>'' then Result:='media:'+Source.Get('provider','')+':'+Result;
  end;
  procedure AddSeen(Source:TJSONObject);
  var Alias:string;
  begin
    Seen.AddObject('id:'+Source.Get('id',''),Source);
    Alias:=MediaKey(Source);if Alias<>'' then Seen.AddObject(Alias,Source);
  end;
  function ReviewPriority(Source:TJSONObject):Integer;
  begin
    Result:=0;
    if Source.Get('review_origin','')<>'automatic' then begin
      if Source.Get('review_status','')='accepted' then Exit(3);
      if Source.Get('review_status','')='rejected' then Exit(2);
    end;
    if PhotoSourceRejected(Source) then Result:=1;
  end;
  procedure IndexNeighbor(const Key:string;Candidate,Owner:TJSONObject);
  var N:Integer;Ref:TNeighborPhotoRef;
  begin
    if Key='' then Exit;N:=NeighborIndex.IndexOf(Key);
    if N<0 then begin
      Ref:=TNeighborPhotoRef.Create;Ref.Source:=Candidate;Ref.Owner:=Owner;
      NeighborIndex.AddObject(Key,Ref);
    end else begin
      Ref:=TNeighborPhotoRef(NeighborIndex.Objects[N]);
      if ReviewPriority(Candidate)>ReviewPriority(Ref.Source) then begin
        Ref.Source:=Candidate;Ref.Owner:=Owner;
      end;
    end;
  end;
  procedure BuildNeighborIndex;
  var A:TJSONArray;N,L:Integer;Candidate,Doc:TJSONObject;Id:string;
  begin
    if NearbyDocuments=nil then Exit;
    for N:=0 to NearbyDocuments.Count-1 do begin
      if not (NearbyDocuments[N] is TJSONObject) then Continue;
      Doc:=TJSONObject(NearbyDocuments[N]);A:=ArrayAt(Doc,'sources');if A=nil then Continue;
      for L:=0 to A.Count-1 do begin
        if not (A[L] is TJSONObject) then Continue;Candidate:=TJSONObject(A[L]);
        Id:=Candidate.Get('id','');if Id<>'' then IndexNeighbor('id:'+Id,Candidate,Doc);
        IndexNeighbor(MediaKey(Candidate),Candidate,Doc);
      end;
    end;
  end;
  function FindNeighbor(Source:TJSONObject; out Owner:TJSONObject):TJSONObject;
  var K:Integer;Alias:string;Ref:TNeighborPhotoRef;
  begin
    Result:=nil;Owner:=nil;K:=NeighborIndex.IndexOf('id:'+Source.Get('id',''));
    if K>=0 then begin
      Ref:=TNeighborPhotoRef(NeighborIndex.Objects[K]);Result:=Ref.Source;Owner:=Ref.Owner;
    end;
    Alias:=MediaKey(Source);if Alias='' then Exit;K:=NeighborIndex.IndexOf(Alias);
    if K<0 then Exit;Ref:=TNeighborPhotoRef(NeighborIndex.Objects[K]);
    if (Result=nil) or (ReviewPriority(Ref.Source)>ReviewPriority(Result)) then begin
      Result:=Ref.Source;Owner:=Ref.Owner;
    end;
  end;
  procedure Enrich(Source,Extra:TJSONObject);
  var F:Integer;Value:TJSONData;Review:TJSONArray;
  begin
    if Extra=nil then Exit;
    ApplyAutomaticPhotoReview(Extra);
    Review:=TJSONArray.Create;
    try
      { Current tile explicit review wins over inherited metadata. }
      Review.Add(Source.Clone);Review.Add(Extra.Clone);
      ApplyPhotoReviews(Source,Review);
    finally Review.Free end;
    for F:=0 to 10 do begin
      Value:=Extra.Find(Fields[F]);
      if (Source.Find(Fields[F])=nil) and (Value<>nil) and (Value.JSONType<>jtNull) then
        Source.Add(Fields[F],Value.Clone);
    end;
  end;
  procedure RepairCachedImage(Source,Extra:TJSONObject);
  var LiveKey,OldKey:string;R:TFetchResult;
  begin
    LiveKey:=Client.CachedImageKey(Extra);
    OldKey:=Source.Get('cache_key','');
    if (LiveKey='') or (LiveKey=OldKey) then Exit;
    if OldKey<>'' then begin
      R:=Client.ReadImage(OldKey);
      if R.Success then Exit;
    end;
    { Runtime gallery document only: keep the authored camera and review, but
      use newly acquired preview bytes when its old thumbnail was evicted. }
    Source.Strings['cache_key']:=LiveKey;
  end;
begin
  Sources:=ArrayAt(Document,'sources');Photos:=ArrayAt(Catalog,'photos');
  if (Sources=nil) or (Photos=nil) then Exit;
  Seen:=TStringList.Create;Seen.Sorted:=True;Seen.CaseSensitive:=True;Seen.Duplicates:=dupIgnore;
  Rejected:=TStringList.Create;Rejected.Sorted:=True;Rejected.CaseSensitive:=True;Rejected.Duplicates:=dupIgnore;
  NeighborIndex:=TStringList.Create;NeighborIndex.Sorted:=True;NeighborIndex.CaseSensitive:=True;
  Related:=TJSONArray.Create;Catalog.Delete('related_photo_views');Catalog.Add('related_photo_views',Related);
  Omitted:=0;
  try
    BuildNeighborIndex;
    for I:=0 to Sources.Count-1 do begin
      S:=TJSONObject(Sources[I]);AddSeen(S);
      ApplyAutomaticPhotoReview(S);
      if PhotoSourceRejected(S) then Rejected.Add(S.Get('id',''));
    end;
    for I:=0 to Photos.Count-1 do begin
      if not (Photos[I] is TJSONObject) then Continue;P:=TJSONObject(Photos[I]);
      ApplyAutomaticPhotoReview(P);
      Id:=P.Get('id','');if Id='' then Continue;K:=Seen.IndexOf('id:'+Id);
      if (K<0) and (MediaKey(P)<>'') then K:=Seen.IndexOf(MediaKey(P));
      if K>=0 then begin
        S:=TJSONObject(Seen.Objects[K]);
        Enrich(S,P);
        RepairCachedImage(S,P);
        if PhotoSourceRejected(S) then Rejected.Add(S.Get('id',''));
        Continue;
      end;
      Key:=Client.CachedImageKey(P);if Key='' then Continue;
      { This is a disposable comparison list. Only a selected source is written
        back by ReviewPhoto/SaveView; persisted knowledge keeps its own limit. }
      if Sources.Count>=50000 then begin Inc(Omitted);Continue end;
      S:=TJSONObject.Create(['id',Id,'kind','photo','provider',P.Get('provider',''),
        'media_id',P.Get('image_id',''),'source_url',P.Get('source_url',''),'cache_key',Key,
        'author',P.Get('author',''),'license',P.Get('license',''),
        'note','Cached discovery candidate; not yet reviewed or used as an observation.']);
      for J:=0 to High(Fields) do begin
        D:=P.Find(Fields[J]);if (D<>nil) and (D.JSONType<>jtNull) then S.Add(Fields[J],D.Clone);
      end;
      Sources.Add(S);AddSeen(S);
      if PhotoSourceRejected(S) then Rejected.Add(Id);
    end;
    for I:=0 to Sources.Count-1 do begin
      S:=TJSONObject(Sources[I]);Neighbor:=FindNeighbor(S,NeighborDoc);
      if Neighbor=nil then Continue;
      Enrich(S,Neighbor);
      if not IsComparisonSource(S) then begin Rejected.Add(S.Get('id',''));Continue end;
      if FindComparisonView(Document,nil,S.Get('id',''))<>nil then Continue;
      V:=FindComparisonView(NeighborDoc,nil,Neighbor.Get('id',''));
      if (V=nil) or (V.Get('status','')='rejected') then Continue;
      V:=TJSONObject(V.Clone);V.Strings['source_id']:=S.Get('id','');
      Entry:=TJSONObject.Create(['view',V]);
      if NeighborDoc.Find('tile')<>nil then Entry.Add('tile',NeighborDoc.Find('tile').Clone);
      Related.Add(Entry);
    end;
    Rejected.Clear;
    for I:=0 to Sources.Count-1 do begin
      S:=TJSONObject(Sources[I]);
      if IsComparisonSource(S,True) and PhotoSourceRejected(S) then Rejected.Add(S.Get('id',''));
    end;
    Catalog.Integers['gallery_omitted_capacity']:=Omitted;
    Catalog.Integers['gallery_omitted_rejected']:=Rejected.Count;
  finally
    for I:=0 to NeighborIndex.Count-1 do NeighborIndex.Objects[I].Free;
    NeighborIndex.Free;Rejected.Free;Seen.Free;
  end;
end;
end.
