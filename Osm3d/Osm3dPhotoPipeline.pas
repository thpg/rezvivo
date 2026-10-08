unit Osm3dPhotoPipeline;
{$mode objfpc}{$H+}
{ Durable, transport-independent tile workflow. Agent reasoning is explicitly
  a stage, never guessed from downloaded bytes. External MCP and Assistant use
  the same optimistic journal. No work is performed in the rendering loop. }
interface
uses Classes, SysUtils, fpjson;
function PhotoPipelineRequest(const CacheRoot:string;Request:TJSONObject):TJSONObject;
function PhotoPipelineCapabilities:TJSONObject;
{ Read once in a background job / scene snapshot, never during rendering. }
function PhotoPipelineTileIndex(const CacheRoot:string;Zoom,Edge:Integer):TJSONObject;
implementation
uses DateUtils, Math, MD5, Osm3dTileKnowledge, Osm3dPhotoSources;
const Stages:array[0..7] of string=('discover','acquire','review','match','refine','validate','build','accept');
  MaxFileBytes=4*1024*1024;

procedure Need(B:Boolean;const S:string);
begin if not B then raise ETileKnowledge.Create('photo_pipeline: '+S) end;
function NowUnix:Int64;
begin Result:=DateTimeToUnix(Now,False) end;
function ReadJson(const Path:string):TJSONObject;
var F:TFileStream;S:RawByteString;J:TJSONData;
begin
  Result:=nil;if not FileExists(Path) then Exit;
  F:=TFileStream.Create(Path,fmOpenRead or fmShareDenyNone);
  try Need(F.Size<=MaxFileBytes,'job journal too large');SetLength(S,F.Size);if S<>'' then F.ReadBuffer(S[1],Length(S)) finally F.Free end;
  J:=ParsePhotoJson(S);if not (J is TJSONObject) then begin J.Free;Need(False,'corrupt job') end;
  Result:=TJSONObject(J);
end;
function StageIndex(const Name:string):Integer;
begin for Result:=Low(Stages) to High(Stages) do if Stages[Result]=Name then Exit;Result:=-1 end;
function SafeId(const S:string):Boolean;
var C:Char;
begin
  Result:=False;if (Length(S)<1) or (Length(S)>80) then Exit;
  for C in S do if not (C in ['A'..'Z','a'..'z','0'..'9','-','_']) then Exit;
  Result:=True;
end;
function Summary(D:TJSONObject):TJSONObject;
var T,S:TJSONArray;I,J,Done,Deferred:Integer;Next,Tile:TJSONObject;
begin
  Done:=0;Deferred:=0;Next:=nil;T:=TJSONArray(D.Find('tiles'));
  for I:=0 to T.Count-1 do begin
    Tile:=TJSONObject(T[I]);S:=TJSONArray(Tile.Find('stages'));
    for J:=0 to S.Count-1 do
      if TJSONObject(S[J]).Get('state','')='done' then Inc(Done)
      else if TJSONObject(S[J]).Get('state','')='deferred' then begin Inc(Done);Inc(Deferred) end
      else if Next=nil then Next:=TJSONObject.Create(['tile_index',I,'tile',Tile.Find('tile').Clone,
        'stage',Stages[J],'state',TJSONObject(S[J]).Get('state','pending')]);
  end;
  Result:=TJSONObject.Create(['job_id',D.Get('id',''),'revision',D.Get('revision',0),
    'state',D.Get('state',''),'tiles',T.Count,'completed_steps',Done,'total_steps',T.Count*Length(Stages),
    'deferred_steps',Deferred,'cost',D.Find('cost').Clone,'budgets',D.Find('budgets').Clone]);
  if Next<>nil then Result.Add('next',Next);
end;
function PhotoPipelineTileIndex(const CacheRoot:string;Zoom,Edge:Integer):TJSONObject;
var Store:TTileKnowledgeStore;Folder,Key,State,Stage,Reason:string;F:TSearchRec;
  D,Tile,Spec,S,Entry,Old:TJSONObject;Tiles,StepsArray:TJSONArray;
  I,J,Seen,Deferred:Integer;Stamp:Int64;
begin
  Result:=TJSONObject.Create;Store:=TTileKnowledgeStore.Create(CacheRoot);
  try Folder:=IncludeTrailingPathDelimiter(Store.Root)+'jobs'+PathDelim finally Store.Free end;
  Seen:=0;
  if FindFirst(Folder+'*.json',faAnyFile,F)<>0 then Exit;
  try repeat
    Inc(Seen);D:=nil;
    try
      try
        D:=ReadJson(Folder+F.Name);if D=nil then Continue;
        if not (D.Find('tiles') is TJSONArray) then Continue;Tiles:=TJSONArray(D.Find('tiles'));
        Stamp:=D.Get('updated_unix',D.Get('created_unix',Int64(0)));
        for I:=0 to Tiles.Count-1 do begin
          Tile:=TJSONObject(Tiles[I]);Spec:=TJSONObject(Tile.Find('tile'));
          if (Spec=nil) or (Spec.Get('zoom',13)<>Zoom) or (Spec.Get('edge_px',256)<>Edge) then Continue;
          Key:=IntToStr(Spec.Get('tile_x',Spec.Get('x',-1)))+'/'+IntToStr(Spec.Get('tile_y',Spec.Get('y',-1)));
          Old:=TJSONObject(Result.Find(Key));
          if (Old<>nil) and ((Old.Get('updated_unix',Int64(0))>Stamp) or
            ((Old.Get('updated_unix',Int64(0))=Stamp) and (Old.Get('job_id','')>=D.Get('id','')))) then Continue;
          if not (Tile.Find('stages') is TJSONArray) then Continue;StepsArray:=TJSONArray(Tile.Find('stages'));
          Deferred:=0;Stage:='';Reason:='';State:=D.Get('state','ready');
          for J:=0 to StepsArray.Count-1 do begin
            S:=TJSONObject(StepsArray[J]);
            if S.Get('state','')='deferred' then begin
              Inc(Deferred);
              if (Reason='') and (S.Find('receipt') is TJSONObject) then Reason:=TJSONObject(S.Find('receipt')).Get('reason','');
            end else if S.Get('state','')='running' then begin
              Stage:=S.Get('name','');if State<>'cancelled' then State:='running';
            end else if (Stage='') and (S.Get('state','')='pending') then Stage:=S.Get('name','');
          end;
          if (Stage='') and (State<>'cancelled') then
            if Deferred>0 then State:='complete_with_deferred' else State:='complete';
          Entry:=TJSONObject.Create(['job_id',D.Get('id',''),'state',State,'stage',Stage,
            'deferred_steps',Deferred,'reason',Reason,'updated_unix',Stamp]);
          if Old<>nil then Result.Delete(Key);Result.Add(Key,Entry);
        end;
      except
        { A corrupt optional journal must not prevent loading valid geometry.
          Its full error remains available through photo_pipeline.read. }
        on E:Exception do ;
      end;
    finally D.Free end;
  until (Seen>=256) or (FindNext(F)<>0);
  finally FindClose(F) end;
end;
procedure RefreshState(D:TJSONObject);
var S,C,B:TJSONObject;
begin
  if D.Get('state','')='cancelled' then Exit;
  S:=Summary(D);
  try
    if S.Get('completed_steps',0)=S.Get('total_steps',0) then begin
      if S.Get('deferred_steps',0)>0 then D.Strings['state']:='complete_with_deferred'
      else D.Strings['state']:='complete';
    end else begin
      D.Strings['state']:='ready';C:=TJSONObject(D.Find('cost'));B:=TJSONObject(D.Find('budgets'));
      if ((B.Get('seconds',0.0)>0) and (C.Get('wall_s',0.0)>=B.Get('seconds',0.0))) or
        ((B.Get('images',Int64(0))>0) and (C.Get('images',Int64(0))>=B.Get('images',Int64(0)))) or
        ((B.Get('tokens',Int64(0))>0) and (C.Get('input_tokens',Int64(0))+C.Get('output_tokens',Int64(0))>=B.Get('tokens',Int64(0)))) then
        D.Strings['state']:='budget_exhausted';
    end;
  finally S.Free end;
end;
function PhotoPipelineRequest(const CacheRoot:string;Request:TJSONObject):TJSONObject;
var Store:TTileKnowledgeStore;Folder,Path,Id,Action,S,Owner,State:string;H:THandle;
  D,Tile,Step,Q,C,B,R,Usage,Existing:TJSONObject;A,StepsArray:TJSONArray;
  I,J,K,N:Integer;Changed:Boolean;Amount:Double;T0:Int64;F:TSearchRec;
  procedure Save;
  begin
    D.Integers['revision']:=D.Get('revision',0)+1;D.Int64s['updated_unix']:=NowUnix;
    S:=D.FormatJSON([],2);Need(Length(S)<=MaxFileBytes,'job journal exceeds limit');KnowledgeAtomicText(Path,S);
  end;
  procedure SetBudgets;
  var BI:Integer;
  begin
    Need(Request.Find('budgets') is TJSONObject,'budgets object required');
    B:=TJSONObject(Request.Find('budgets'));C:=TJSONObject(D.Find('budgets'));
    for BI:=0 to B.Count-1 do begin
      Need((B.Names[BI]='seconds') or (B.Names[BI]='images') or (B.Names[BI]='tokens'),'unknown budget');
      Need(B.Items[BI].JSONType=jtNumber,'numeric budget required');Amount:=B.Items[BI].AsFloat;
      Need(not IsNan(Amount) and not IsInfinite(Amount) and (Amount>=0) and (Amount<=1e12),'invalid budget');
      if B.Names[BI]<>'seconds' then Need(Frac(Amount)=0,'integer budget required');
      C.Floats[B.Names[BI]]:=Amount;
    end;
  end;
  procedure AccountTime(Step:TJSONObject);
  begin
    C:=TJSONObject(D.Find('cost'));T0:=Step.Get('started_unix',NowUnix);
    Amount:=Max(Int64(0),Min(NowUnix,Step.Get('lease_until',NowUnix))-T0);
    C.Floats['wall_s']:=C.Get('wall_s',0.0)+Amount;
    Step.Floats['worker_s']:=Step.Get('worker_s',0.0)+Amount;
  end;
begin
  Result:=nil;Store:=TTileKnowledgeStore.Create(CacheRoot);
  try Folder:=IncludeTrailingPathDelimiter(Store.Root)+'jobs'+PathDelim finally Store.Free end;
  ForceDirectories(Folder);Action:=Request.Get('action','read');
  if Action='capabilities' then Exit(PhotoPipelineCapabilities);
  if Action='tile_status' then Exit(PhotoPipelineTileIndex(CacheRoot,Request.Get('zoom',13),Request.Get('edge_px',256)));
  if Action='list' then begin
    A:=TJSONArray.Create;Result:=TJSONObject.Create(['jobs',A]);
    if FindFirst(Folder+'*.json',faAnyFile,F)=0 then try
      repeat D:=ReadJson(Folder+F.Name);try if D<>nil then A.Add(Summary(D)) finally D.Free end until (FindNext(F)<>0) or (A.Count>=256);
    finally FindClose(F) end;
    Exit;
  end;
  Id:=Request.Get('job_id','');Need(SafeId(Id),'job_id must be a bounded ASCII name');Path:=Folder+Id+'.json';
  H:=KnowledgeAcquireWriter(Path+'.lock');D:=nil;
  try
    D:=ReadJson(Path);Changed:=False;
    if Action='create' then begin
      Need(D=nil,'job exists; read/resume it instead');
      Need(Request.Find('tiles') is TJSONArray,'tiles required');A:=TJSONArray(Request.Find('tiles'));
      Need((A.Count>0) and (A.Count<=1024),'1..1024 tiles required');
      D:=TJSONObject.Create(['schema_version',1,'id',Id,'revision',0,'state','ready',
        'created_unix',NowUnix,'tiles',TJSONArray.Create,'usage',TJSONObject.Create,
        'cost',TJSONObject.Create(['wall_s',0.0,'api_s',0.0,'images',0,'input_tokens',0,'cached_input_tokens',0,'output_tokens',0,'unmetered_calls',0]),
        'budgets',TJSONObject.Create(['seconds',0,'images',0,'tokens',0])]);
      if Request.Find('budgets')<>nil then SetBudgets;
      for I:=0 to A.Count-1 do begin
        Need(A[I] is TJSONObject,'tile object required');Q:=KnowledgeTile(TJSONObject(A[I]),13,256);
        for J:=0 to D.Arrays['tiles'].Count-1 do
          Need(TJSONObject(D.Arrays['tiles'][J]).Find('tile').AsJSON<>Q.AsJSON,'duplicate tile');
        Tile:=TJSONObject.Create(['tile',Q,'stages',TJSONArray.Create]);D.Arrays['tiles'].Add(Tile);
        for J:=0 to High(Stages) do Tile.Arrays['stages'].Add(TJSONObject.Create(['name',Stages[J],'state','pending']));
      end;
      Save;Exit(Summary(D));
    end;
    Need(D<>nil,'job not found');
    if Action='read' then Exit(TJSONObject(D.Clone));
    if Action='next' then Exit(Summary(D));
    Need(Request.Find('expected_revision')<>nil,'expected_revision required');
    Need(Request.Get('expected_revision',-1)=D.Get('revision',0),'revision conflict: read job before retry');
    Owner:=Request.Get('agent','');Need((Owner<>'') and (Length(Owner)<=120),'agent name required');
    if Action='budgets' then begin SetBudgets;Changed:=True end
    else if Action='cancel' then begin D.Strings['state']:='cancelled';Changed:=True end
    else if Action='resume' then begin
      D.Strings['state']:='ready';Changed:=True;
      A:=TJSONArray(D.Find('tiles'));for I:=0 to A.Count-1 do begin
        StepsArray:=TJSONObject(A[I]).Arrays['stages'];
        for J:=0 to StepsArray.Count-1 do begin
          Step:=TJSONObject(StepsArray[J]);
          if Step.Get('state','')='running' then begin
            Need((Step.Get('agent','')=Owner) or (Step.Get('lease_until',Int64(0))<NowUnix),'another agent owns a live stage lease');
            AccountTime(Step);
            Step.Strings['state']:='pending';
          end;
        end;
      end;
    end else if Action='usage' then begin
      Id:=Request.Get('request_id','');Need(SafeId(Id),'stable request_id required');
      Need(Request.Find('usage') is TJSONObject,'usage object required');Usage:=TJSONObject(Request.Find('usage'));
      Need(Length(Usage.AsJSON)<8192,'usage too large');R:=TJSONObject(D.Find('usage'));Existing:=TJSONObject(R.Find(Id));
      if Existing<>nil then begin Need(Existing.AsJSON=Usage.AsJSON,'conflicting usage for request_id');Exit(Summary(D)) end;
      C:=TJSONObject(D.Find('cost'));
      for I:=0 to Usage.Count-1 do begin
        S:=Usage.Names[I];
        Need((S='api_s') or (S='images') or (S='input_tokens') or (S='cached_input_tokens') or (S='output_tokens') or
          (S='unmetered_calls'),'unsupported usage counter');Need(Usage.Items[I].JSONType=jtNumber,'numeric usage required');
        Amount:=Usage.Items[I].AsFloat;Need(not IsNan(Amount) and not IsInfinite(Amount) and (Amount>=0) and (Amount<=1e12),'invalid usage');
        if S<>'api_s' then Need(Frac(Amount)=0,'integer usage required');
        C.Floats[S]:=C.Get(S,0.0)+Amount;
      end;
      Need(Usage.Get('cached_input_tokens',Int64(0))<=Usage.Get('input_tokens',Int64(0)),'cached input is part of input, not extra tokens');
      R.Add(Id,Usage.Clone);Changed:=True;
    end else begin
      Need((Action='claim') or (Action='finish') or (Action='heartbeat') or (Action='invalidate'),'unknown action');
      I:=Request.Get('tile_index',-1);J:=StageIndex(Request.Get('stage',''));A:=TJSONArray(D.Find('tiles'));
      Need((I>=0) and (I<A.Count) and (J>=0),'invalid tile/stage');Tile:=TJSONObject(A[I]);StepsArray:=Tile.Arrays['stages'];Step:=TJSONObject(StepsArray[J]);
      State:=D.Get('state','');Need(State<>'cancelled','resume the cancelled job first');
      if Action='invalidate' then begin
        Need(Request.Get('reason','')<>'','invalidation reason required');
        for K:=J to High(Stages) do begin
          R:=TJSONObject(StepsArray[K]);
          if R.Get('state','')='running' then begin
            Need((R.Get('agent','')=Owner) or (R.Get('lease_until',Int64(0))<NowUnix),'another agent owns a live stage lease');
            AccountTime(R);
          end;
          R.Strings['state']:='pending';if R.Find('receipt')<>nil then R.Delete('receipt');
        end;
        Step.Strings['reason']:=Request.Get('reason','');Changed:=True;
      end else begin
        if Action='claim' then Need(State<>'budget_exhausted','budget exhausted');
        for K:=0 to J-1 do Need((TJSONObject(StepsArray[K]).Get('state','')='done') or
          (TJSONObject(StepsArray[K]).Get('state','')='deferred'),'previous stage is incomplete');
        if Action='heartbeat' then begin
          Need((Step.Get('state','')='running') and (Step.Get('agent','')=Owner),'heartbeat requires stage ownership');
          Step.Int64s['lease_until']:=NowUnix+1800;Changed:=True;
        end else if Action='claim' then begin
          Need((Step.Get('state','')='pending') or
            ((Step.Get('state','')='running') and (Step.Get('lease_until',Int64(0))<NowUnix)),'stage already claimed or finished');
          if Step.Get('state','')='running' then AccountTime(Step);
          Step.Strings['state']:='running';Step.Strings['agent']:=Owner;Step.Int64s['started_unix']:=NowUnix;
          Step.Int64s['lease_until']:=NowUnix+1800;Changed:=True;
        end else begin
          Need((Step.Get('state','')='running') and (Step.Get('agent','')=Owner),'claim stage with this agent first');
          Need(Request.Find('receipt') is TJSONObject,'a concrete receipt is required');R:=TJSONObject(Request.Find('receipt'));
          Need(Length(R.AsJSON)<=32768,'receipt too large; link the report');
          Need(R.Get('report','')<>'','receipt must reference its report/artifact');
          if Request.Get('deferred',False) then begin
            Need(R.Get('reason','')<>'','deferred stage requires reason');Step.Strings['state']:='deferred';
          end else begin
            Need(R.Get('verified',False),'completed stage requires verified receipt');Step.Strings['state']:='done';
          end;
          Step.Add('receipt',R.Clone);Step.Int64s['finished_unix']:=NowUnix;
          AccountTime(Step);Changed:=True;
        end;
      end;
    end;
    if Changed then begin RefreshState(D);Save end;
    Result:=Summary(D);
  finally D.Free;KnowledgeReleaseWriter(H) end;
end;
function PhotoPipelineCapabilities:TJSONObject;
var A:TJSONArray;S:string;
begin
  A:=TJSONArray.Create;for S in Stages do A.Add(S);
  Result:=TJSONObject.Create(['schema_version',1,'stages',A,
    'actions','create, list, read, next, tile_status, claim, heartbeat, finish, cancel, resume, invalidate, usage, budgets',
    'persistence','knowledge-root/jobs; atomic revisioned journals shared by Studio, game and Assistant',
    'execution','claim next stage, perform existing photos/knowledge/map operation, finish with verified artifact receipt',
    'changed_only','invalidate a changed tile from the earliest affected stage; other tiles remain complete',
    'cost','unique request_id per API attempt; cached input is part of input; unknown usage stays explicit; wall_s is cumulative leased worker time, not job elapsed time',
    'budgets','seconds, images, tokens; 0 means unbounded; checked before each new stage',
    'offline','jobs never run implicitly at ride startup; existing cached tiles load without an agent']);
end;
end.
