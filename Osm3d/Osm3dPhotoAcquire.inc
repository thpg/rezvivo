{ Explicit, bounded acquisition shared by Studio and MCP jobs. Merely opening
  a gallery stays offline. A completed download updates only disposable cache
  metadata; it never accepts evidence or edits tile knowledge. }
function TPhotoApiClient.AcquireMapillary(Grid:TGeoTileGrid;const Tile:TGeoTileId;
  const Focus:TLatLon;Photo:TJSONObject;MaxDownloads,BeforeCount,AfterCount:Integer;
  Offline,Refresh:Boolean):TJSONObject;
begin
  Result:=AcquireTile(Grid,Tile,Focus,Photo,MaxDownloads,BeforeCount,AfterCount,
    Offline,Refresh,'batch','mapillary',4,2000);
end;

function TPhotoApiClient.AcquireTile(Grid:TGeoTileGrid;const Tile:TGeoTileId;
  const Focus:TLatLon;Photo:TJSONObject;MaxDownloads,BeforeCount,AfterCount:Integer;
  Offline,Refresh:Boolean;const Mode,Providers:string;MaxPages,MaxCandidates:Integer):TJSONObject;
var Catalog,Fresh,P,D,Original,Group,Provider:TJSONObject;Candidates,Output,Failures,Reports,ProviderFailures:TJSONArray;
  Order,Seen,Groups,Blocked:TStringList;I,N,GroupIndex,Available,Eligible,Excluded,LicensePending,
    BlockedCount,Ready,Attempted,Downloaded,Failed,PriorFailures,Remaining,AttemptLimit:Integer;
  Lat,Lon,Distance:Double;Id,Key,State,SequenceState,Selected,ProviderName,FailureState,BlockedState:string;T:TGeoTileId;
  Incomplete,FreshDiscovery,AllMode,ProviderFound,LimitReached,DiscoveryLimit,DownloadLimit:Boolean;
  function AttemptKey(Item:TJSONObject):string;
  begin
    Result:=KeyFor(Item.Get('provider','')+'/acquire-attempt',Item.Get('catalog_url','')+'/'+Item.Get('image_id',''));
  end;
  function FailureCount(Item:TJSONObject):Integer;
  var Bytes:TBytes;S:RawByteString;J:TJSONData;
  begin
    Result:=0;
    if Refresh or (FHttp.Cache=nil) then Exit;
    if FHttp.Cache.Get(AttemptKey(Item),Bytes) and (Length(Bytes)>0) and (Length(Bytes)<4096) then begin
      SetString(S,PAnsiChar(@Bytes[0]),Length(Bytes));J:=nil;
      try
        try
          J:=ParsePhotoJson(S);
          if J is TJSONObject then Result:=EnsureRange(TJSONObject(J).Get('failure_count',0),0,1000000);
        except Result:=0 end;
      finally J.Free end;
    end;
  end;
  procedure RememberFailure(Item:TJSONObject;Status:Integer);
  var J:TJSONObject;S:RawByteString;Bytes:TBytes;
  begin
    { This is retry ordering, never a negative HTTP response: still-available
      candidates run first, and failed images remain retryable on later batches.
      Keep it in the existing disposable HTTP cache, stable across worker jobs. }
    if Offline or FHttp.Aborted or (FHttp.Cache=nil) then Exit;
    J:=TJSONObject.Create(['failure_count',Min(1000000,FailureCount(Item)+1),'http_status',Status]);
    try
      S:=J.AsJSON;SetLength(Bytes,Length(S));Move(S[1],Bytes[0],Length(S));
      FHttp.Cache.Put(AttemptKey(Item),Bytes,TCacheMetadata.Make('application/json'));
    finally J.Free end;
  end;
  function StopsAcquisition(const Status:string):Boolean;
  begin
    Result:=(Status='credentials_required') or (Status='access_denied') or
      (Status='request_rejected') or (Status='rate_limited') or (Status='cancelled');
  end;
  function DiscoveryWasLimited(Report:TJSONObject):Boolean;
  var Status:string;
  begin
    { Older cached reports predate limit_reached. Their explicit truncation
      status remains useful; has_more may merely mean a failed pending URL. }
    if Report.Find('limit_reached')<>nil then Exit(Report.Get('limit_reached',False));
    Status:=Report.Get('status','');
    Result:=(Status='truncated') or (Status='coverage_truncated') or (Status='coverage_area_limit');
  end;
  procedure BlockProvider(const Name,Status:string;HttpStatus:Integer);
  begin
    if Blocked.IndexOf(Name)>=0 then Exit;
    Blocked.Add(Name);
    if BlockedState='' then BlockedState:=Status;
    ProviderFailures.Add(TJSONObject.Create(['provider',Name,'status',Status,'http_status',HttpStatus]));
  end;
  function IsCandidate(Item:TJSONObject):Boolean;
  begin
    Result:=(Pos(','+Item.Get('provider','')+',',','+Selected+',')>0) and
      Num(Item,'latitude',Lat) and Num(Item,'longitude',Lon);
    if not Result then Exit;
    Result:=(Abs(Lat)<=WEB_MERCATOR_MAX_LAT) and (Abs(Lon)<=180) and FRouteScope.Contains(Lat,Lon);
    if Result and (Photo=nil) then Result:=Grid.TileAt(TLatLon.Make(Lat,Lon)).Equals(Tile);
  end;
  procedure AddToTile(Item:TJSONObject;const ItemTile:TGeoTileId);
  var TileKey:string;
  begin
    TileKey:=IntToStr(ItemTile.TX)+'/'+IntToStr(ItemTile.TY);
    GroupIndex:=Groups.IndexOf(TileKey);
    if GroupIndex<0 then begin
      Group:=TJSONObject.Create(['tile_x',Int64(ItemTile.TX),'tile_y',Int64(ItemTile.TY),'photos',TJSONArray.Create]);
      Groups.AddObject(TileKey,Group);
    end else Group:=TJSONObject(Groups.Objects[GroupIndex]);
    TJSONArray(Group.Find('photos')).Add(Item.Clone);
  end;
  procedure RememberDownloaded(Item,Discovered:TJSONObject);
  var OriginalTile:TGeoTileId;
  begin
    if not Num(Item,'latitude',Lat) or not Num(Item,'longitude',Lon) then Exit;
    T:=Grid.TileAt(TLatLon.Make(Lat,Lon));AddToTile(Item,T);
    { A computed Graph pose can move across the discovery tile boundary.
      Replace that tile's coverage stub as well, or its gallery revives the
      stale pose now that image bytes exist. IsCandidate filters the new pose. }
    if Num(Discovered,'latitude',Lat) and Num(Discovered,'longitude',Lon) then begin
      OriginalTile:=Grid.TileAt(TLatLon.Make(Lat,Lon));
      if not T.Equals(OriginalTile) then AddToTile(Item,OriginalTile);
    end;
  end;
  procedure FlushCatalogs;
  var Index:Integer;One:TJSONObject;ItemTile:TGeoTileId;
  begin
    while Groups.Count>0 do begin
      Index:=Groups.Count-1;
      One:=TJSONObject(Groups.Objects[Index]);ItemTile:=TGeoTileId.Make(0,True,One.Get('tile_x',0),One.Get('tile_y',0));
      RememberTileCatalog(Grid,ItemTile,One);Groups.Delete(Index);One.Free;
    end;
  end;
begin
  AllMode:=Mode='all';
  if not AllMode and (Mode<>'batch') then raise Exception.Create('Acquisition mode: batch or all');
  if AllMode and (Photo<>nil) then raise Exception.Create('All acquisition targets a tile; omit the selected photo');
  if AllMode then begin
    if (MaxDownloads<1) or (MaxDownloads>50000) then raise Exception.Create('All acquisition limit: 1..50000 photos');
  end else if (MaxDownloads<1) or (MaxDownloads>48) then raise Exception.Create('Acquisition batch: 1..48 photos');
  if (MaxPages<1) or (MaxPages>500) or (MaxCandidates<1) or (MaxCandidates>50000) then
    raise Exception.Create('Discovery limits: 1..500 pages, 1..50000 candidates per provider');
  Selected:=StringReplace(LowerCase(Trim(Providers)),' ','',[rfReplaceAll]);
  if (Selected='all') or (Selected='auto') then Selected:=AllPhotoProviders;
  if Selected='' then raise Exception.Create('At least one photo provider is required');
  if not AllMode and (Selected<>'mapillary') then raise Exception.Create('Batch acquisition currently targets Mapillary');
  if (BeforeCount<0) or (BeforeCount>20) or (AfterCount<0) or (AfterCount>20) then
    raise Exception.Create('Acquisition sequence: 0..20 neighbors each side');
  if IsNan(Focus.Lat) or IsInfinite(Focus.Lat) or IsNan(Focus.Lon) or IsInfinite(Focus.Lon) or
    (Abs(Focus.Lat)>WEB_MERCATOR_MAX_LAT) or (Abs(Focus.Lon)>180) then raise Exception.Create('Invalid acquisition focus');
  Output:=TJSONArray.Create;Failures:=TJSONArray.Create;ProviderFailures:=TJSONArray.Create;
  Result:=TJSONObject.Create(['photos',Output,'failures',Failures,'provider_failures',ProviderFailures]);
  Catalog:=nil;Order:=TStringList.Create;Seen:=TStringList.Create;Groups:=TStringList.Create;
  Blocked:=TStringList.Create;Blocked.Sorted:=True;Blocked.Duplicates:=dupIgnore;
  Order.Sorted:=True;Seen.Sorted:=True;Seen.CaseSensitive:=True;
  Available:=0;Eligible:=0;Excluded:=0;LicensePending:=0;BlockedCount:=0;
  Ready:=0;Attempted:=0;Downloaded:=0;Failed:=0;Incomplete:=False;
  FreshDiscovery:=False;DiscoveryLimit:=False;DownloadLimit:=False;
  State:='complete';SequenceState:='';BlockedState:='';
  try
    try
      if not AllMode and (FConfig.MapillaryToken='') and not Offline then begin State:='credentials_required';Incomplete:=True end
      else begin
        if Assigned(FOnProgress) then FOnProgress('acquire:search',0,0);
        if Photo<>nil then begin
          Catalog:=SequenceNeighbors(Photo,BeforeCount,AfterCount,20,Offline,Refresh,Grid);
          SequenceState:=Catalog.Get('status','unavailable');Incomplete:=not Catalog.Get('complete',False);
          if StopsAcquisition(SequenceState) then State:=SequenceState;
        end else begin
          Catalog:=CachedTileCatalog(Grid,Tile);Candidates:=ArrayAt(Catalog,'photos');N:=0;
          if Candidates<>nil then for I:=0 to Candidates.Count-1 do
            if (Candidates[I] is TJSONObject) and IsCandidate(TJSONObject(Candidates[I])) then Inc(N);
          if AllMode or Refresh or (N=0) then begin
            Fresh:=SearchTile(Grid,Tile,Selected,0,MaxPages,MaxCandidates,Offline,Refresh,AllMode);
            Fresh.Free;Catalog.Free;Catalog:=CachedTileCatalog(Grid,Tile);FreshDiscovery:=True;
          end;
          Reports:=ArrayAt(Catalog,'providers');ProviderFound:=False;
          if Reports<>nil then for I:=0 to Reports.Count-1 do begin
            Provider:=TJSONObject(Reports[I]);ProviderName:=Provider.Get('provider','');
            if Pos(','+ProviderName+',',','+Selected+',')>0 then begin
              ProviderFound:=True;
              if not Provider.Get('discovery_complete',Provider.Get('complete',False)) then Incomplete:=True;
              if DiscoveryWasLimited(Provider) then DiscoveryLimit:=True;
              { A cached denial/limit is historical, not a ban on an explicit
                new attempt after credentials/network/provider recovery. }
              if FreshDiscovery and StopsAcquisition(Provider.Get('status','')) then
                if AllMode then BlockProvider(ProviderName,Provider.Get('status',''),Provider.Get('http_status',0))
                else State:=Provider.Get('status','');
            end;
          end;
          if not ProviderFound then Incomplete:=True;
          if Catalog.Get('catalog_truncated',False) then begin Incomplete:=True;DiscoveryLimit:=True end;
        end;
        Candidates:=ArrayAt(Catalog,'photos');
        if Candidates<>nil then for I:=0 to Candidates.Count-1 do begin
          if not (Candidates[I] is TJSONObject) then Continue;P:=TJSONObject(Candidates[I]);
          if not IsCandidate(P) then Continue;Id:=P.Get('id','');
          if (Id='') or (Seen.IndexOf(Id)>=0) then Continue;Seen.Add(Id);Inc(Available);
          ApplyPhotoReviews(P,FPhotoReviews);
          if not PhotoAcquisitionAllowed(P) or
            ((P.Find('download_allowed')<>nil) and not P.Get('download_allowed',False)) then begin
            Inc(Excluded);
            if not PhotoSourceRejected(P) then Inc(LicensePending);
            Continue;
          end;
          Inc(Eligible);
          Key:=CachedImageKey(P);
          if Key<>'' then begin Inc(Ready);Continue end;
          if Blocked.IndexOf(P.Get('provider',''))>=0 then begin Inc(BlockedCount);Continue end;
          Distance:=Sqr(Lat-Focus.Lat)+Sqr((Lon-Focus.Lon)*Cos(DegToRad(Focus.Lat)));
          PriorFailures:=FailureCount(P);
          Order.AddObject(Format('%.8d/%.18d/',[PriorFailures,Round(Distance*1e12)])+Id,P);
        end;
        AttemptLimit:=Min(Order.Count,MaxDownloads);
        for I:=0 to Order.Count-1 do begin
          if StopsAcquisition(State) then Break;
          if FHttp.Aborted then begin State:='cancelled';Break end;
          P:=TJSONObject(Order.Objects[I]);
          if Blocked.IndexOf(P.Get('provider',''))>=0 then Continue;
          if Attempted>=MaxDownloads then begin DownloadLimit:=True;Break end;
          if Assigned(FOnProgress) then FOnProgress('acquire:download',Attempted,AttemptLimit);
          D:=Download(P,'preview',Offline);Inc(Attempted);
          try
            if D.Get('success',False) then begin
              Inc(Downloaded);Original:=P;P:=TJSONObject(D.Find('photo'));
              Output.Add(P.Clone);RememberDownloaded(P,Original);
            end else if FHttp.Aborted then begin
              { An intentional cancellation is neither a failed image nor a
                reason to demote it behind other candidates on the next run. }
              State:='cancelled';
            end else begin
              Inc(Failed);Failures.Add(TJSONObject.Create(['id',P.Get('id',''),
                'error',D.Get('error','unavailable'),'http_status',D.Get('http_status',0)]));
              FailureState:='';
              case D.Get('http_status',0) of
                400:FailureState:='request_rejected';401,403:FailureState:='access_denied';429:FailureState:='rate_limited';
              end;
              if FailureState<>'' then begin
                if AllMode then BlockProvider(P.Get('provider',''),FailureState,D.Get('http_status',0))
                else State:=FailureState;
              end else RememberFailure(P,D.Get('http_status',0));
            end;
          finally D.Free end;
          if AllMode and (Attempted mod 24=0) then FlushCatalogs;
          if Assigned(FOnProgress) then FOnProgress('acquire:download',Attempted,AttemptLimit);
          if StopsAcquisition(State) then Break;
        end;
        { A provider refusal is scoped to that provider. Continue unrelated
          downloads in all mode, but report every deferred image and refusal. }
        for I:=0 to Order.Count-1 do
          if Blocked.IndexOf(TJSONObject(Order.Objects[I]).Get('provider',''))>=0 then Inc(BlockedCount);
        for I:=0 to Output.Count-1 do
          if Blocked.IndexOf(TJSONObject(Output[I]).Get('provider',''))>=0 then Dec(BlockedCount);
        if FHttp.Aborted then State:='cancelled'
        else if State='complete' then begin
          if BlockedState<>'' then State:=BlockedState
          else if Failed>0 then State:='partial'
          else if Order.Count>Attempted then if AllMode then State:='limit_reached' else State:='batch_complete'
          else if Incomplete then State:='search_incomplete'
          else if Available=0 then State:='no_candidates';
        end;
      end;
      FlushCatalogs;Remaining:=Max(0,Eligible-Ready-Downloaded);
      LimitReached:=DiscoveryLimit or DownloadLimit;
      Result.Add('status',State);Result.Add('candidate_count',Available);Result.Add('cached_count',Ready);
      Result.Add('attempted_count',Attempted);Result.Add('downloaded_count',Downloaded);Result.Add('failed_count',Failed);
      Result.Add('remaining_count',Remaining);Result.Add('discovery_incomplete',Incomplete);
      Result.Add('mode',Mode);Result.Add('provider_selection',Selected);
      Result.Add('eligible_count',Eligible);Result.Add('excluded_count',Excluded);
      Result.Add('rejected_count',Excluded-LicensePending);
      Result.Add('license_pending_count',LicensePending);Result.Add('blocked_count',BlockedCount);
      Result.Add('discovery_complete',not Incomplete and (Catalog<>nil));
      Result.Add('acquisition_complete',(Remaining=0) and (Catalog<>nil));
      Result.Add('complete',not Incomplete and (Remaining=0) and (Catalog<>nil) and not StopsAcquisition(State));
      Result.Add('limit_reached',LimitReached);Result.Add('resumable',(Remaining>0) or Incomplete);
      if DiscoveryLimit then Result.Add('resume_hint','increase_discovery_limits')
      else if Remaining>0 then Result.Add('resume_hint','resume_from_cache');
      if (Catalog<>nil) and (Catalog.Find('providers')<>nil) then Result.Add('providers',Catalog.Find('providers').Clone);
      Result.Add('sequence_status',SequenceState);Result.Add('photo_count',Output.Count);Result.Add('stats',Stats);
    except Result.Free;raise end;
  finally
    for I:=0 to Groups.Count-1 do Groups.Objects[I].Free;
    Groups.Free;Seen.Free;Order.Free;Blocked.Free;Catalog.Free;
  end;
end;
