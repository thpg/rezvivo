unit Osm3dLocalStyles;
{$mode objfpc}{$H+}
interface
uses Classes,SysUtils,fpjson;
function ProposeKnowledgeLocalStyles(const CacheRoot:string;Request:TJSONObject;Cancel:TThread=nil):TJSONObject;
implementation
uses Math,MD5,Osm3dTileKnowledge,Osm3dKnowledgeContext,Osm3dKnowledgeProperties,
  Osm3dKnowledgeEvidence,Osm3dPhotoSources,Osm3dKnowledgeOsm,Osm3dGeoMath;

function ProposeKnowledgeLocalStyles(const CacheRoot:string;Request:TJSONObject;Cancel:TThread):TJSONObject;
var Store:TTileKnowledgeStore;ReadBack,Doc,Ctx,Q,Rule,Match,Src,Tag,Target,Example,Observation,Row:TJSONObject;
  Rules,Objects,ContextObjects,Examples,SourceIds,Values,Obs,Changes,Warnings:TJSONArray;
  ObjIndex,ContextIndex:TStringList;I,J,K,L,N,PIdx,Confirmed,Added:Integer;
  Id,Prop,Value,Candidate,Building,Before,Key:string;Valid,HasValue:Boolean;
  Sources:TKnowledgeSourceIndex;B,EB:TLatLonBox;Dist,MaxDist,Area:Double;Refs:TJSONArray;
  function ObjectById(const Name:string;Index:TStringList):TJSONObject;
  var Pos:Integer;
  begin Pos:=Index.IndexOf(Name);if Pos<0 then Result:=nil else Result:=TJSONObject(Index.Objects[Pos]) end;
  procedure AddSource(const Name:string);
  var X:Integer;
  begin for X:=0 to SourceIds.Count-1 do if SourceIds[X].AsString=Name then Exit;SourceIds.Add(Name) end;
begin
  Result:=nil;Store:=TTileKnowledgeStore.Create(CacheRoot);ReadBack:=nil;Ctx:=nil;Doc:=nil;Q:=nil;
  Sources:=nil;ObjIndex:=TStringList.Create;ContextIndex:=TStringList.Create;
  ObjIndex.Sorted:=True;ObjIndex.CaseSensitive:=True;ContextIndex.Sorted:=True;ContextIndex.CaseSensitive:=True;
  try
   try
    ReadBack:=Store.Read(Request,13,256);Doc:=TJSONObject(ReadBack.Find('document').Clone);
    Q:=TJSONObject(Request.Clone);if Q.Find('route_scope')<>nil then Q.Delete('route_scope');
    Q.Add('route_scope',TJSONObject.Create(['enabled',False]));Q.Integers['max_objects']:=10000;
    Ctx:=CachedKnowledgeContext(CacheRoot,Q,Cancel);
    if not Ctx.Get('complete',False) or Ctx.Get('truncated',False) then raise ETileKnowledge.Create('Local styles need complete cached OSM');
    Sources:=TKnowledgeSourceIndex.Create(Doc);Objects:=Doc.Arrays['objects'];Rules:=Doc.Arrays['local_styles'];
    ContextObjects:=Ctx.Arrays['objects'];
    for I:=0 to Objects.Count-1 do begin Target:=TJSONObject(Objects[I]);ObjIndex.AddObject(Target.Get('id',''),Target) end;
    for I:=0 to ContextObjects.Count-1 do begin Src:=TJSONObject(ContextObjects[I]);ContextIndex.AddObject(Src.Get('id',''),Src) end;
    Changes:=TJSONArray.Create;Warnings:=TJSONArray.Create;
    Result:=TJSONObject.Create(['document',Doc,'expected_revision',Doc.Get('revision',0),
      'expected_hash',ReadBack.Get('content_hash',''),'proposals',Changes,'warnings',Warnings,
      'saved',False,'activated',False,'network_requests',0]);Doc:=nil;
    for I:=0 to Rules.Count-1 do begin
      Rule:=TJSONObject(Rules[I]);Match:=TJSONObject(Rule.Find('match'));
      if Match=nil then begin Warnings.Add(Rule.Get('id','')+': descriptive style has no bounded matching rule');Continue end;
      Building:=Match.Get('building','');MaxDist:=Match.Get('within_m',200.0);Examples:=Rule.Arrays['example_objects'];
      if (Building='') or (MaxDist<=0) or (MaxDist>500) or (Examples.Count<2) then begin
        Warnings.Add(Rule.Get('id','')+': need building class, radius <=500m and at least two examples');Continue end;
      Values:=Rule.Arrays['fill_properties'];
      for J:=0 to Values.Count-1 do begin
        Prop:=Values[J].AsString;
        if (Prop<>'facade.material') and (Prop<>'roof.shape') then raise ETileKnowledge.Create('Local rules may fill only facade.material and roof.shape');
        PIdx:=KnowledgePropertyIndex(Prop);Value:='';Confirmed:=0;Valid:=True;SourceIds:=TJSONArray.Create;EB:=TLatLonBox.Empty;
        try
          for K:=0 to Examples.Count-1 do begin
            Example:=ObjectById(Examples[K].AsString,ObjIndex);Src:=ObjectById(Examples[K].AsString,ContextIndex);
            if (Example=nil) or (Src=nil) or (Example.Get('mapping_status','')<>'confirmed') then Continue;
            Tag:=TJSONObject(Src.Find('tags'));
            if (Tag=nil) or (Tag.Get('building','')<>Building) or
              (Tag.Find('historic')<>nil) or (Tag.Find('amenity')<>nil) or
              (Tag.Find('tourism')<>nil) or (Tag.Find('office')<>nil) or
              (Tag.Find('building:part')<>nil) then Continue;
            B:=KnowledgeBox(Src.Find('bbox'));
            Area:=B.Width*B.Height*Sqr(111320)*Cos(B.Center.Lat*Pi/180);
            if (Area<Match.Get('min_bbox_area_m2',0.0)) or
              (Area>Match.Get('max_bbox_area_m2',1e9)) then Continue;
            Obs:=Example.Arrays['observations'];Candidate:='';
            for L:=0 to Obs.Count-1 do begin
              Observation:=TJSONObject(Obs[L]);
              if (Observation.Get('property','')<>Prop) or (Observation.Get('decision','')<>'accepted') or
                (Observation.Get('origin','')='local_inferred') or (Observation.Get('visibility','')='not_visible') or
                (Sources.RejectedSupport(Observation)<>'') or (Observation.Arrays['source_ids'].Count=0) then Continue;
              Candidate:=CanonicalKnowledgeScalar(PIdx,Observation.Find('value'),'');
              Refs:=Observation.Arrays['source_ids'];for N:=0 to Refs.Count-1 do AddSource(Refs[N].AsString);
            end;
            if Candidate='' then Continue;
            EB:=EB.Union(B);
            if Value='' then Value:=Candidate else if Value<>Candidate then Valid:=False;
            Inc(Confirmed);
          end;
          if not Valid or (Confirmed<2) or (SourceIds.Count<2) then begin Warnings.Add(Rule.Get('id','')+': no independent agreement on '+Prop);Continue end;
          Added:=0;
          for K:=0 to ContextObjects.Count-1 do begin
            if (Cancel<>nil) and Cancel.CheckTerminated then raise EAbort.Create('cancelled');
            Src:=TJSONObject(ContextObjects[K]);if Src.Get('category','')<>'building' then Continue;
            Tag:=TJSONObject(Src.Find('tags'));Id:=Src.Get('id','');
            if (Tag.Get('building','')<>Building) or (Tag.Find('historic')<>nil) or (Tag.Find('amenity')<>nil) or
              (Tag.Find('tourism')<>nil) or (Tag.Find('office')<>nil) or (Tag.Find('building:part')<>nil) then Continue;
            Before:=Tag.Get(KnowledgeProperties[PIdx].TagName,'');if Before<>'' then Continue;
            B:=KnowledgeBox(Src.Find('bbox'));Area:=B.Width*B.Height*Sqr(111320)*Cos(B.Center.Lat*Pi/180);
            if (Area<Match.Get('min_bbox_area_m2',0.0)) or (Area>Match.Get('max_bbox_area_m2',1e9)) then Continue;
            Dist:=Sqrt(Sqr((B.Center.Lat-EB.Center.Lat)*111320)+Sqr((B.Center.Lon-EB.Center.Lon)*111320*Cos(B.Center.Lat*Pi/180)));
            if Dist>MaxDist then Continue;
            Target:=ObjectById(Id,ObjIndex);HasValue:=False;
            if Target<>nil then for L:=0 to Target.Arrays['observations'].Count-1 do
              if TJSONObject(Target.Arrays['observations'][L]).Get('property','')=Prop then HasValue:=True;
            if HasValue then Continue;
            if Objects.Count>=2048 then begin Warnings.Add('Object capacity reached');Break end;
            if Target=nil then begin
              Target:=TJSONObject.Create(['id',Id,'category','building','description','Local typology inference; no direct photograph claim.',
                'mapping_status','confirmed','match_confidence',1.0,'observations',TJSONArray.Create,
                'osm_refs',TJSONArray.Create([TJSONObject.Create(['type',Src.Get('type',''),'id',Src.Get('osm_id',''),'fingerprint',Src.Get('fingerprint','')])])]);
              Objects.Add(Target);ObjIndex.AddObject(Id,Target);
            end;
            Key:='local-style:'+Copy(MD5Print(MD5String(Rule.Get('id','')+Id+Prop)),1,24);
            Row:=TJSONObject.Create(['id',Key,'property',Prop,'value',Value,
              'text','Shared appearance of nearby independently photographed buildings of the same OSM class.',
              'origin','local_inferred','source_ids',SourceIds.Clone,'confidence',Min(0.6,Rule.Get('confidence',0.6)),
              'visibility','not_visible','decision','accepted',
              'note','Rule '+Rule.Get('id','')+'; '+IntToStr(Confirmed)+' agreeing examples, radius '+FloatToStr(MaxDist)+'m. Fills missing appearance only; does not infer floor count, geometry or identical decoration.']);
            Target.Arrays['observations'].Add(Row);Changes.Add(TJSONObject.Create(['object_id',Id,'property',Prop,'value',Value,'style_id',Rule.Get('id','')]));Inc(Added);
          end;
        finally SourceIds.Free end;
      end;
    end;
    ValidateTileKnowledge(TJSONObject(Result.Find('document')),TJSONObject(Result.FindPath('document.tile')));
   except Result.Free;Result:=nil;raise end;
  finally ContextIndex.Free;ObjIndex.Free;Sources.Free;Doc.Free;Q.Free;Ctx.Free;ReadBack.Free;Store.Free end;
end;
end.
