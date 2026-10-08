unit Osm3dKnowledgeEvidence;
{$mode objfpc}{$H+}
{ Provenance, not image recognition. Metadata may reject obvious non-scene
  subjects; it never establishes that an image was viewed or used by geometry. }
interface
uses Classes,SysUtils,fpjson,Osm3dPhotoApi;
type
  TKnowledgeSourceIndex=class
  private
    FItems:TStringList;
  public
    constructor Create(Document:TJSONObject;Catalog:TJSONObject=nil);
    destructor Destroy;override;
    function RejectedSupport(Observation:TJSONObject):string;
    function ReviewStatus(const Id:string):string;
  end;
function BuildKnowledgeEvidenceReport(Document,Catalog:TJSONObject;Client:TPhotoApiClient;
  Recipe:TJSONObject=nil;const KnowledgeHash:string=''):TJSONObject;
implementation
uses MD5,Osm3dPhotoRelevance,Osm3dKnowledgeProperties;

function MediaKey(S:TJSONObject):string;forward;

constructor TKnowledgeSourceIndex.Create(Document:TJSONObject;Catalog:TJSONObject);
var A,Photos:TJSONArray;I,N:Integer;S,P:TJSONObject;Aliases:TStringList;Key,OriginalId:string;
begin
  inherited Create;FItems:=TStringList.Create;FItems.Sorted:=True;FItems.CaseSensitive:=True;
  FItems.Duplicates:=dupIgnore;A:=ArrayAt(Document,'sources');
  if A<>nil then for I:=0 to A.Count-1 do if A[I] is TJSONObject then begin
    S:=TJSONObject(A[I]);FItems.AddObject(S.Get('id',''),S.Clone);
  end;
  Aliases:=TStringList.Create;Aliases.Sorted:=True;Aliases.CaseSensitive:=True;Aliases.Duplicates:=dupIgnore;
  try
    for I:=0 to FItems.Count-1 do begin
      S:=TJSONObject(FItems.Objects[I]);Aliases.AddObject('id:'+S.Get('id',''),TObject(PtrInt(I)));
      Key:=MediaKey(S);if Key<>'' then Aliases.AddObject(Key,TObject(PtrInt(I)));
    end;
    Photos:=ArrayAt(Catalog,'photos');if Photos=nil then Exit;
    for I:=0 to Photos.Count-1 do if Photos[I] is TJSONObject then begin
      P:=TJSONObject(Photos[I]);N:=Aliases.IndexOf('id:'+P.Get('id',''));
      if (N<0) and (MediaKey(P)<>'') then N:=Aliases.IndexOf(MediaKey(P));if N<0 then Continue;
      N:=PtrInt(Aliases.Objects[N]);S:=TJSONObject(FItems.Objects[N]);OriginalId:=S.Get('id','');
      P:=TJSONObject(P.Clone);ApplyPhotoReviews(P,A);P.Strings['id']:=OriginalId;
      S.Free;FItems.Objects[N]:=P;
    end;
  finally Aliases.Free end;
end;
destructor TKnowledgeSourceIndex.Destroy;
var I:Integer;
begin if FItems<>nil then for I:=0 to FItems.Count-1 do FItems.Objects[I].Free;FItems.Free;inherited end;
function TKnowledgeSourceIndex.RejectedSupport(Observation:TJSONObject):string;
var A:TJSONArray;I,N:Integer;
begin
  Result:='';A:=ArrayAt(Observation,'source_ids');if A=nil then Exit;
  for I:=0 to A.Count-1 do begin
    N:=FItems.IndexOf(A[I].AsString);
    if (N>=0) and PhotoSourceRejected(TJSONObject(FItems.Objects[N])) then Exit(A[I].AsString);
  end;
end;
function TKnowledgeSourceIndex.ReviewStatus(const Id:string):string;
var N:Integer;
begin N:=FItems.IndexOf(Id);if N<0 then Exit('');Result:=EffectivePhotoReviewStatus(TJSONObject(FItems.Objects[N])) end;

function MediaKey(S:TJSONObject):string;
begin
  Result:='';if (S.Get('kind','')='video_frame') or (S.Find('time_s')<>nil) then Exit;
  Result:=S.Get('media_id',S.Get('image_id',''));
  if Result<>'' then Result:='media:'+S.Get('provider','')+':'+Result;
end;

function Coverage(Document,Report:TJSONObject):TJSONObject;
var Objects,Obs,Inventories:TJSONArray;Categories,Entry,O,R:TJSONObject;
  I,J,Reviewed,Deferred:Integer;Applied,Confirmed:Boolean;Kind,State:string;
begin
  Categories:=TJSONObject.Create;Result:=TJSONObject.Create(['categories',Categories]);
  Objects:=ArrayAt(Document,'objects');Obs:=ArrayAt(Report,'observations');
  if Objects<>nil then for I:=0 to Objects.Count-1 do begin
    O:=TJSONObject(Objects[I]);Kind:=O.Get('category','other');
    Entry:=TJSONObject(Categories.Find(Kind));
    if Entry=nil then begin Entry:=TJSONObject.Create(['known_objects',0,'applied',0,'confirmed',0,'unapplied',0]);Categories.Add(Kind,Entry) end;
    Entry.Integers['known_objects']:=Entry.Get('known_objects',0)+1;Applied:=False;Confirmed:=False;
    if Obs<>nil then for J:=0 to Obs.Count-1 do begin
      R:=TJSONObject(Obs[J]);if R.Get('object_id','')<>O.Get('id','') then Continue;
      Applied:=Applied or R.Get('used',False);Confirmed:=Confirmed or (R.Get('effect','')='confirmed_osm');
    end;
    if Applied then State:='applied' else if Confirmed then State:='confirmed' else State:='unapplied';
    Entry.Integers[State]:=Entry.Get(State,0)+1;
  end;
  Reviewed:=0;Deferred:=0;Inventories:=ArrayAt(Document,'image_inventory');
  if Inventories<>nil then for I:=0 to Inventories.Count-1 do begin
    O:=TJSONObject(Inventories[I]);if O.Get('scope','')='objects' then Inc(Reviewed);
    Objects:=ArrayAt(O,'objects');if Objects<>nil then for J:=0 to Objects.Count-1 do
      if TJSONObject(Objects[J]).Get('status','')='deferred' then Inc(Deferred);
  end;
  Result.Add('object_reviewed_images',Reviewed);Result.Add('deferred_inventory_items',Deferred);
  State:='ordinary';
  if Report.Get('recipe_current',False) and (TJSONObject(Report.Find('counts')).Get('used',0)>0) then State:='photo_enhanced';
  Result.Add('tile_mode',State);Result.Add('photo_textured',False);
  Result.Add('note','Known evidence coverage, not a percentage of every real object in the tile.');
end;

function BuildKnowledgeEvidenceReport(Document,Catalog:TJSONObject;Client:TPhotoApiClient;
  Recipe:TJSONObject;const KnowledgeHash:string):TJSONObject;
var Entries,ObsRows,Styles:TJSONArray;Counts,Row,S,P,O,Obs,Link,E,Target,Tags,Entry:TJSONObject;
  Index,Aliases,EvidenceIndex,TargetsIndex:TStringList;SourceIndex:TKnowledgeSourceIndex;
  A,Objects,Observations,Refs,Evidence,Targets:TJSONArray;
  I,J,K,N,UsedCount,ConfirmedCount,AcceptedCount,RejectedCount,UnreviewedCount,DownloadedCount,
  LinkedCount,UnusedCount,ExcludedCount,UnsupportedCount,RejectedRecipeSupport:Integer;
  Id,State,Key,Reason,Effect,RejectedId,TargetId,Hash,RecipeState:string;
  Current,Used,Confirmed,PendingProperties:Boolean;
  procedure AddSource(Item:TJSONObject;Authored:Boolean);
  var Q:TJSONObject;Posn:Integer;Mid,Status:string;Cached:Boolean;
  begin
    Id:=Item.Get('id','');if Id='' then Exit;Posn:=Aliases.IndexOf('id:'+Id);Mid:=MediaKey(Item);
    if (Posn<0) and (Mid<>'') then Posn:=Aliases.IndexOf(Mid);
    Cached:=False;
    if Client<>nil then begin
      Key:=Item.Get('cache_key','');
      Cached:=(Key<>'') and Client.HasCachedImage(Key);
      if not Cached then Cached:=Client.CachedImageKey(Item)<>'';
    end;
    if Posn>=0 then begin
      Q:=TJSONObject(Aliases.Objects[Posn]);
      if Cached then Q.Booleans['downloaded']:=True;
      { Explicit authored reviews win inferred provider metadata. }
      if Q.Get('review_status','unreviewed')='unreviewed' then begin
        Status:=EffectivePhotoReviewStatus(Item);Q.Strings['review_status']:=Status;
        if Item.Find('review_reason')<>nil then Q.Strings['review_reason']:=Item.Get('review_reason','');
      end;
      if Aliases.IndexOf('id:'+Id)<0 then Aliases.AddObject('id:'+Id,Q);
      Exit;
    end;
    Status:=SourceIndex.ReviewStatus(Id);if Status='' then Status:=EffectivePhotoReviewStatus(Item);
    Q:=TJSONObject.Create(['id',Id,'provider',Item.Get('provider',''),
      'review_status',Status,'downloaded',Cached,'authored',Authored,
      'used',False,'confirmed_osm',False,'links',TJSONArray.Create]);
    if Item.Find('review_reason')<>nil then Q.Add('review_reason',Item.Get('review_reason',''));
    Entries.Add(Q);Index.AddObject(Id,Q);Aliases.AddObject('id:'+Id,Q);
    if Mid<>'' then Aliases.AddObject(Mid,Q);
  end;
begin
  Entries:=TJSONArray.Create;ObsRows:=TJSONArray.Create;Counts:=TJSONObject.Create;
  Result:=TJSONObject.Create(['schema_version',1,'counts',Counts,'sources',Entries,'observations',ObsRows,
    'network_requests',0,'visual_review_inferred',False,'download_status_checked',Client<>nil,
    'policy','Downloaded is cached bytes; accepted is explicit review; used requires matching compiled evidence. Metadata is never proof of visual inspection.']);
  if Document.Find('tile')<>nil then Result.Add('tile',Document.Find('tile').Clone);
  Index:=TStringList.Create;Aliases:=TStringList.Create;EvidenceIndex:=TStringList.Create;TargetsIndex:=TStringList.Create;
  SourceIndex:=TKnowledgeSourceIndex.Create(Document,Catalog);
  Index.Sorted:=True;Index.CaseSensitive:=True;Aliases.Sorted:=True;Aliases.CaseSensitive:=True;Aliases.Duplicates:=dupIgnore;
  EvidenceIndex.Sorted:=True;EvidenceIndex.CaseSensitive:=True;TargetsIndex.Sorted:=True;TargetsIndex.CaseSensitive:=True;
  try
    try
      A:=ArrayAt(Document,'sources');if A<>nil then for I:=0 to A.Count-1 do if A[I] is TJSONObject then AddSource(TJSONObject(A[I]),True);
      A:=ArrayAt(Catalog,'photos');if A<>nil then for I:=0 to A.Count-1 do if A[I] is TJSONObject then AddSource(TJSONObject(A[I]),False);
      Evidence:=ArrayAt(Recipe,'evidence');Targets:=ArrayAt(Recipe,'targets');Hash:='';
      if Targets<>nil then Hash:=MD5Print(MD5String(Targets.AsJSON));
      Current:=(Recipe<>nil) and (KnowledgeHash<>'') and (Recipe.Get('knowledge_hash','')=KnowledgeHash) and
        (Recipe.Get('geometry_hash','')=Hash);
      RejectedRecipeSupport:=0;
      if Evidence<>nil then for I:=0 to Evidence.Count-1 do if Evidence[I] is TJSONObject then
        if SourceIndex.RejectedSupport(TJSONObject(Evidence[I]))<>'' then Inc(RejectedRecipeSupport);
      if RejectedRecipeSupport>0 then Current:=False;
      PendingProperties:=False;Objects:=ArrayAt(Document,'objects');
      if Objects<>nil then for I:=0 to Objects.Count-1 do begin
        Observations:=ArrayAt(Objects[I],'observations');if Observations=nil then Continue;
        for J:=0 to Observations.Count-1 do begin
          Obs:=TJSONObject(Observations[J]);
          if (Obs.Get('decision','')='accepted') and (Obs.Find('property')<>nil) and
            (SourceIndex.RejectedSupport(Obs)='') then PendingProperties:=True;
        end;
      end;
      if Recipe=nil then begin
        if PendingProperties then RecipeState:='not_compiled'
        else begin RecipeState:='no_effective_changes';Current:=True end;
      end else if not Current then RecipeState:='stale_recipe'
      else if Evidence=nil then RecipeState:='legacy_evidence_unverified'
      else if (Targets<>nil) and (Targets.Count=0) then RecipeState:='no_effective_changes'
      else RecipeState:='current';
      Result.Add('recipe_present',Recipe<>nil);Result.Add('recipe_current',Current);
      Result.Add('recipe_state',RecipeState);
      Result.Add('recipe_evidence_available',Evidence<>nil);
      Result.Add('recipe_rejected_support_count',RejectedRecipeSupport);
      Result.Add('requires_recompile',(RecipeState<>'no_effective_changes') and
        (not Current or (Evidence=nil)));
      if Recipe<>nil then Result.Add('geometry_hash',Recipe.Get('geometry_hash',''));
      if Current and (Evidence<>nil) then for I:=0 to Evidence.Count-1 do if Evidence[I] is TJSONObject then begin
        E:=TJSONObject(Evidence[I]);EvidenceIndex.AddObject(E.Get('observation_id',''),E);
      end;
      if Current and (Targets<>nil) then for I:=0 to Targets.Count-1 do if Targets[I] is TJSONObject then begin
        Target:=TJSONObject(Targets[I]);TargetsIndex.AddObject(Target.Get('id',''),Target);
      end;
      ExcludedCount:=0;UnsupportedCount:=0;Objects:=ArrayAt(Document,'objects');
      if Objects<>nil then for I:=0 to Objects.Count-1 do begin
        O:=TJSONObject(Objects[I]);Observations:=ArrayAt(O,'observations');if Observations=nil then Continue;
        for J:=0 to Observations.Count-1 do begin
          Obs:=TJSONObject(Observations[J]);Refs:=ArrayAt(Obs,'source_ids');Reason:='';Effect:='';Used:=False;Confirmed:=False;
          RejectedId:=SourceIndex.RejectedSupport(Obs);
          { A candidate may have acquired a new automatic rejection since the
            authored document was last saved. Report it without rewriting it. }
          if (RejectedId='') and (Refs<>nil) then for K:=0 to Refs.Count-1 do begin
            N:=Aliases.IndexOf('id:'+Refs[K].AsString);
            if (N>=0) and (TJSONObject(Aliases.Objects[N]).Get('review_status','')='rejected') then begin RejectedId:=Refs[K].AsString;Break end;
          end;
          if RejectedId<>'' then begin Reason:='rejected_source';Inc(ExcludedCount) end
          else if Obs.Get('decision','')<>'accepted' then Reason:='observation_'+Obs.Get('decision','unreviewed')
          else if Obs.Find('property')=nil then Reason:='text_only'
          else if not KnowledgePropertySupported(Obs.Get('property','')) then begin Reason:='unsupported_property';Inc(UnsupportedCount) end
          else if not KnowledgePropertyCategory(Obs.Get('property',''),O.Get('category','')) then Reason:='unsupported_category'
          else if O.Get('mapping_status','')<>'confirmed' then Reason:='unconfirmed_binding'
          else if not Current then if Recipe=nil then Reason:='not_compiled' else Reason:='stale_recipe'
          else begin
            N:=EvidenceIndex.IndexOf(Obs.Get('id',''));E:=nil;if N>=0 then E:=TJSONObject(EvidenceIndex.Objects[N]);
            if (E=nil) or (E.Get('object_id','')<>O.Get('id','')) or (E.Get('property','')<>Obs.Get('property','')) or
              (E.Find('source_ids')=nil) or (Refs=nil) or (E.Find('source_ids').AsJSON<>Refs.AsJSON) then Reason:='not_in_compiled_recipe'
            else begin
              Effect:=E.Get('effect','');TargetId:=E.Get('target_id','');N:=TargetsIndex.IndexOf(TargetId);
              if Effect='confirmed_osm' then Confirmed:=True
              else if (Effect='changed') and (N>=0) then begin
                Target:=TJSONObject(TargetsIndex.Objects[N]);Tags:=TJSONObject(Target.Find('set_tags'));
                Used:=(Tags<>nil) and (Tags.Find(E.Get('tag',''))<>nil) and (Tags.Get(E.Get('tag',''),'')=E.Get('after',''));
              end;
              if not Used and not Confirmed then Reason:='not_in_compiled_recipe';
            end;
          end;
          Row:=TJSONObject.Create(['object_id',O.Get('id',''),'observation_id',Obs.Get('id',''),
            'property',Obs.Get('property',''),'origin',Obs.Get('origin',''),'decision',Obs.Get('decision',''),
            'used',Used,'confirmed_osm',Confirmed,'reason',Reason,'effect',Effect]);
          if Refs<>nil then Row.Add('source_ids',Refs.Clone);if RejectedId<>'' then Row.Add('rejected_source_id',RejectedId);
          ObsRows.Add(Row);
          if Refs<>nil then for K:=0 to Refs.Count-1 do begin
            N:=Aliases.IndexOf('id:'+Refs[K].AsString);if N<0 then Continue;Entry:=TJSONObject(Aliases.Objects[N]);
            if Used then Entry.Booleans['used']:=True;if Confirmed then Entry.Booleans['confirmed_osm']:=True;
            Link:=TJSONObject.Create(['object_id',O.Get('id',''),'observation_id',Obs.Get('id',''),
              'property',Obs.Get('property',''),'effect',Effect,'reason',Reason]);Entry.Arrays['links'].Add(Link);
          end;
        end;
      end;
      UsedCount:=0;ConfirmedCount:=0;AcceptedCount:=0;RejectedCount:=0;UnreviewedCount:=0;DownloadedCount:=0;LinkedCount:=0;UnusedCount:=0;
      for I:=0 to Entries.Count-1 do begin
        Entry:=TJSONObject(Entries[I]);State:=Entry.Get('review_status','unreviewed');
        if State='accepted' then Inc(AcceptedCount) else if State='rejected' then Inc(RejectedCount) else Inc(UnreviewedCount);
        if Entry.Get('downloaded',False) then Inc(DownloadedCount);if Entry.Get('used',False) then Inc(UsedCount) else Inc(UnusedCount);
        if Entry.Get('confirmed_osm',False) then Inc(ConfirmedCount);
        if Entry.Arrays['links'].Count>0 then Inc(LinkedCount);
        if not Entry.Get('used',False) then begin
          if State='rejected' then Reason:='rejected_source'
          else if Entry.Arrays['links'].Count=0 then Reason:='no_observations'
          else if Entry.Get('confirmed_osm',False) then Reason:='confirmed_osm'
          else Reason:='observations_not_applied';
          Entry.Add('unused_reason',Reason);
        end;
      end;
      Counts.Add('discovered',Entries.Count);Counts.Add('downloaded',DownloadedCount);Counts.Add('accepted',AcceptedCount);
      Counts.Add('rejected',RejectedCount);Counts.Add('unreviewed',UnreviewedCount);Counts.Add('used',UsedCount);
      Counts.Add('confirmed_osm',ConfirmedCount);Counts.Add('linked',LinkedCount);Counts.Add('unused',UnusedCount);
      Counts.Add('observations',ObsRows.Count);Counts.Add('excluded_observations',ExcludedCount);Counts.Add('unsupported_observations',UnsupportedCount);
      Styles:=ArrayAt(Document,'local_styles');if Styles<>nil then Counts.Add('local_styles_not_automatically_applied',Styles.Count);
      Result.Add('coverage',Coverage(Document,Result));
      Result.Add('limits',TJSONObject.Create(['knowledge_sources',2048,'knowledge_objects',2048,
        'observations_per_object',256,'photo_views',64,'knowledge_bytes',2*1024*1024,
        'catalog_complete',False,'note','Counts describe this saved tile catalog, not exhaustive provider coverage.']));
    except Result.Free;raise end;
  finally SourceIndex.Free;TargetsIndex.Free;EvidenceIndex.Free;Aliases.Free;Index.Free end;
end;
end.
