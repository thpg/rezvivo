{ Derived tile indexes live in the same disposable HTTP cache as source bytes.
  Discovery is not an observation: nothing here marks a photo as reviewed. }
function TPhotoApiClient.SearchMapillaryCoverage(const Box:TLatLonBox;MaxTiles,MaxPhotos:Integer;
  Offline,Refresh:Boolean;Photos:TJSONArray):TJSONObject;
const Zoom=14;Count=16384;
var X0,X1,Y0,Y1,X,Y,I,J,Added,Rejected,ReadTiles,Failed:Integer;URL,Key,State,Id:string;
  R:TFetchResult;Items:TJSONArray;P:TJSONObject;Seen,Order:TStringList;More:Boolean;Lon,Lat,CX,CY:Double;
  function TileY(Latitude:Double):Integer;
  var V:Double;
  begin V:=DegToRad(Max(-85.05112878,Min(85.05112878,Latitude)));
    Result:=Max(0,Min(Count-1,Floor((1-Ln(Tan(V)+1/Cos(V))/Pi)*0.5*Count))) end;
begin
  Added:=0;Rejected:=0;ReadTiles:=0;Failed:=0;More:=False;State:='coverage_empty';
  X0:=Max(0,Min(Count-1,Floor((Box.MinLon+180)/360*Count)));
  X1:=Max(0,Min(Count-1,Floor((Box.MaxLon+180)/360*Count)));
  Y0:=TileY(Box.MaxLat);Y1:=TileY(Box.MinLat);Seen:=TStringList.Create;Order:=TStringList.Create;
  Seen.Sorted:=True;Seen.CaseSensitive:=True;Seen.Duplicates:=dupIgnore;Order.Sorted:=True;
  Result:=TJSONObject.Create(['method','coverage_tiles','metadata','coverage_only',
    'note','Coverage points are candidates; image metadata and availability are checked lazily on download.']);
  try
    for I:=0 to Photos.Count-1 do Seen.Add(PhotoJsonString(Photos[I],'id'));
    if Int64(X1-X0+1)*(Y1-Y0+1)>4096 then begin
      Result.Add('status','coverage_area_limit');Result.Add('has_more',True);Result.Add('limit_reached',True);
      Result.Add('complete',False);Result.Add('photos',0);Exit;
    end;
    CX:=(X0+X1)*0.5;CY:=(Y0+Y1)*0.5;
    for Y:=Y0 to Y1 do for X:=X0 to X1 do
      Order.AddObject(Format('%.8d/%.5d/%.5d',[Round((Sqr(X-CX)+Sqr(Y-CY))*4),X,Y]),TObject(PtrInt(Y*Count+X)));
    for I:=0 to Order.Count-1 do begin
      if FHttp.Aborted then begin State:='cancelled';Break end;
      if (ReadTiles>=MaxTiles) or (Added>=MaxPhotos) then begin More:=True;Break end;
      X:=PtrInt(Order.Objects[I]) mod Count;Y:=PtrInt(Order.Objects[I]) div Count;
      URL:=FConfig.MapillaryCoverageUrl+'/'+IntToStr(Zoom)+'/'+IntToStr(X)+'/'+IntToStr(Y);
      Key:='photo-api/v1/mapillary/coverage/'+MD5Print(MD5String(URL));
      if FConfig.MapillaryToken<>'' then URL:=URL+'?access_token='+URLParam(FConfig.MapillaryToken);
      FCoverageResponse:=True;
      try R:=Fetch(URL,Key,'',Offline,Refresh,False) finally FCoverageResponse:=False end;
      Inc(ReadTiles);
      if not R.Success then begin
        Inc(Failed);
        case R.StatusCode of
          400:State:='request_rejected';401,403:State:='access_denied';429:State:='rate_limited';
        end;
        if (State='request_rejected') or (State='access_denied') or (State='rate_limited') then begin
          Result.Add('http_status',R.StatusCode);Break;
        end;
        Continue;
      end;
      Items:=nil;
      try
        try Items:=DecodeMapillaryCoverage(R.Data,Zoom,X,Y)
        except
          if FHttp.Cache<>nil then FHttp.Cache.Delete(Key);Inc(Failed);Continue;
        end;
        for J:=0 to Items.Count-1 do begin
          P:=NormalizeStreetPhoto('mapillary',TJSONObject(Items[J]),FConfig.MapillaryUrl,Key);
          if P=nil then begin Inc(Rejected);Continue end;
          Lat:=P.Get('latitude',0.0);Lon:=P.Get('longitude',0.0);Id:=P.Get('id','');
          if (Lat<Box.MinLat) or (Lat>Box.MaxLat) or (Lon<Box.MinLon) or (Lon>Box.MaxLon) or
            not FRouteScope.Contains(Lat,Lon) then begin P.Free;Inc(Rejected);Continue end;
          if Seen.IndexOf(Id)>=0 then begin P.Free;Continue end;
          if Added>=MaxPhotos then begin P.Free;More:=True;Break end;
          P.Add('discovery_method','coverage_tile');P.Add('metadata_level','coverage');
          P.Add('image_availability','not_checked');P.Add('coordinate_uncertainty_m',1.0);
          Seen.Add(Id);Photos.Add(P);Inc(Added);
        end;
      finally Items.Free end;
      if Assigned(FOnProgress) then FOnProgress('coverage:mapillary',ReadTiles,Min(Order.Count,MaxTiles));
    end;
    if not ((State='cancelled') or (State='request_rejected') or (State='access_denied') or (State='rate_limited')) then
      if More then State:='coverage_truncated'
      else if Added>0 then State:='coverage_only'
      else if Failed>0 then if Offline then State:='cache_miss' else State:='coverage_unavailable';
    Result.Add('status',State);Result.Add('photos',Added);Result.Add('tiles',ReadTiles);
    Result.Add('complete',not More and (Failed=0) and (ReadTiles=Order.Count) and not FHttp.Aborted);
    Result.Add('total_tiles',Order.Count);
    Result.Add('failed_tiles',Failed);Result.Add('rejected',Rejected);Result.Add('has_more',More);
    Result.Add('limit_reached',More);
  finally Seen.Free;Order.Free end;
end;

function EvidenceKey(Grid:TGeoTileGrid; const Tile:TGeoTileId):string;
begin
  Result:='photo-api/v1/tile-evidence/z'+IntToStr(Grid.Zoom)+'/e'+IntToStr(Grid.EdgePx)+
    '/'+IntToStr(Tile.TX)+'/'+IntToStr(Tile.TY);
end;

function TPhotoApiClient.LockTileCatalog(const Key:string):THandle;
var Started:QWord;
{$IFDEF MSWINDOWS}LockPath:UnicodeString;Code:DWORD;{$ENDIF}
  procedure CheckWait;
  begin
    if FHttp.Aborted then raise EAbort.Create('cancelled');
    if GetTickCount64-Started>=5000 then raise Exception.Create('Photo catalog is busy; retry the operation');
    Sleep(10);
  end;
begin
  Started:=GetTickCount64;Result:=0;
  while System.TryEnterCriticalSection(PhotoCatalogCriticalSection)=0 do CheckWait;
  try
    {$IFDEF MSWINDOWS}
    if FHttp.Cache is TFileSystemCache then begin
      { Exclusive, delete-on-close lock works across game/Studio processes and
        short/Unicode aliases of the same existing HTTP cache. A crashed process
        releases it automatically. No provider request occurs while held. }
      LockPath:=UTF8Decode(IncludeTrailingPathDelimiter(TFileSystemCache(FHttp.Cache).RootDir)+
        'photo-catalog-'+MD5Print(MD5String(Key))+'.lock');
      repeat
        Result:=CreateFileW(PWideChar(LockPath),GENERIC_READ or GENERIC_WRITE,0,nil,
          OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL or FILE_FLAG_DELETE_ON_CLOSE,0);
        if Result<>INVALID_HANDLE_VALUE then Break;
        Code:=GetLastError;
        if not (Code in [ERROR_SHARING_VIOLATION,ERROR_LOCK_VIOLATION,ERROR_ACCESS_DENIED]) then
          raise Exception.Create('Cannot lock photo catalog');
        CheckWait;
      until False;
    end;
    {$ENDIF}
  except LeaveCriticalSection(PhotoCatalogCriticalSection);raise end;
end;

procedure TPhotoApiClient.UnlockTileCatalog(Handle:THandle);
begin
  {$IFDEF MSWINDOWS}if (Handle<>0) and (Handle<>INVALID_HANDLE_VALUE) then CloseHandle(Handle);{$ENDIF}
  LeaveCriticalSection(PhotoCatalogCriticalSection);
end;

function TPhotoApiClient.CachedImageKey(Photo:TJSONObject):string;
const Sizes:array[0..2] of string=('preview','original','thumbnail');
var I:Integer; K:string;
begin
  Result:=''; if FHttp.Cache=nil then Exit;
  for I:=0 to High(Sizes) do begin
    K:=KeyFor(Photo.Get('provider','')+'/image/'+Sizes[I],
      Photo.Get('catalog_url','')+'/'+Photo.Get('image_id',''));
    if FHttp.Cache.Has(K) then Exit(K);
  end;
end;

procedure TPhotoApiClient.RememberTileCatalog(Grid:TGeoTileGrid; const Tile:TGeoTileId; Catalog:TJSONObject);
const MaxCatalogPhotos=100000;
var Old,J:TJSONObject; Photos,Incoming,Reports:TJSONArray; Seen,OldPhotos,ProviderSeen:TStringList;
  Bytes:TBytes; S:RawByteString; I,Omitted:Integer; D:TJSONData; K:string;Lock:THandle;
  procedure AddPhotos(A:TJSONArray;PreferDetailed:Boolean);
  var N,Index:Integer;Id:string;Item,Stored:TJSONObject;
  begin
    if A=nil then Exit;
    for N:=0 to A.Count-1 do begin
      if not (A[N] is TJSONObject) then Continue;Item:=TJSONObject(A[N]);Id:=Item.Get('id','');
      if (Id='') or (Seen.IndexOf(Id)>=0) then Continue;Seen.Add(Id);
      if Photos.Count>=MaxCatalogPhotos then begin Inc(Omitted);Continue end;
      Stored:=Item;
      { A subsequent coverage refresh must not downgrade a verified computed
        Graph camera back to its rough vector-tile point/compass. }
      if PreferDetailed and (Item.Get('metadata_level','')='coverage') then begin
        Index:=OldPhotos.IndexOf(Id);
        if (Index>=0) and (TJSONObject(OldPhotos.Objects[Index]).Get('metadata_level','')<>'coverage') then
          Stored:=TJSONObject(OldPhotos.Objects[Index]);
      end;
      Photos.Add(Stored.Clone);
    end;
  end;
  procedure AddReports(A:TJSONArray);
  var N:Integer;Id:string;
  begin
    if A=nil then Exit;
    for N:=0 to A.Count-1 do begin
      if not (A[N] is TJSONObject) then Continue;Id:=TJSONObject(A[N]).Get('provider','');
      if (Id='') or (ProviderSeen.IndexOf(Id)>=0) then Continue;
      ProviderSeen.Add(Id);Reports.Add(A[N].Clone);
    end;
  end;
begin
  if FHttp.Cache=nil then Exit; K:=EvidenceKey(Grid,Tile);Lock:=LockTileCatalog(K);
  try
  Old:=nil;
  if FHttp.Cache.Get(K,Bytes) and (Length(Bytes)>0) then begin
    SetString(S,PAnsiChar(@Bytes[0]),Length(Bytes));
    try D:=ParsePhotoJson(S); if D is TJSONObject then Old:=TJSONObject(D) else D.Free except end;
  end;
  J:=TJSONObject.Create; Seen:=TStringList.Create; Seen.Sorted:=True;Seen.CaseSensitive:=True;
  OldPhotos:=TStringList.Create;OldPhotos.Sorted:=True;OldPhotos.CaseSensitive:=True;OldPhotos.Duplicates:=dupIgnore;
  ProviderSeen:=TStringList.Create;ProviderSeen.Sorted:=True;ProviderSeen.CaseSensitive:=True;
  Photos:=TJSONArray.Create;J.Add('photos',Photos);
  Reports:=TJSONArray.Create;J.Add('providers',Reports);Omitted:=0;
  try
    Incoming:=ArrayAt(Old,'photos');
    if Incoming<>nil then for I:=0 to Incoming.Count-1 do
      if Incoming[I] is TJSONObject then begin
        S:=PhotoJsonString(Incoming[I],'id');if S<>'' then OldPhotos.AddObject(S,Incoming[I]);
      end;
    AddPhotos(ArrayAt(Catalog,'photos'),True);AddPhotos(Incoming,False);
    AddReports(ArrayAt(Catalog,'providers'));AddReports(ArrayAt(Old,'providers'));
    if Old<>nil then Omitted:=Max(Omitted,Old.Get('catalog_omitted_capacity',0));
    J.Add('catalog_omitted_capacity',Omitted);J.Add('catalog_limit',MaxCatalogPhotos);
    J.Add('catalog_truncated',Omitted>0);
    J.Add('schema_version',1);J.Add('photo_count',Photos.Count);
    S:=J.AsJSON;SetLength(Bytes,Length(S));if Length(S)>0 then Move(S[1],Bytes[0],Length(S));
    FHttp.Cache.Put(K,Bytes,TCacheMetadata.Make('application/json'));
  finally Old.Free;J.Free;Seen.Free;OldPhotos.Free;ProviderSeen.Free end;
  finally UnlockTileCatalog(Lock) end;
end;

function TPhotoApiClient.CachedTileCatalog(Grid:TGeoTileGrid; const Tile:TGeoTileId):TJSONObject;
var Bytes:TBytes; S:RawByteString; D:TJSONData;Lock:THandle;
  Providers:TJSONArray;I:Integer;P:TJSONObject;
begin
  Result:=nil;
  if FHttp.Cache<>nil then begin
    Lock:=LockTileCatalog(EvidenceKey(Grid,Tile));
    try
      if FHttp.Cache.Get(EvidenceKey(Grid,Tile),Bytes) and (Length(Bytes)>0) then begin
        SetString(S,PAnsiChar(@Bytes[0]),Length(Bytes));
        try D:=ParsePhotoJson(S);if D is TJSONObject then Result:=TJSONObject(D) else D.Free except end;
      end;
    finally UnlockTileCatalog(Lock) end;
  end;
  { Backward-compatible discovery: re-read this tile's previously cached HTTP
    queries only. Never scan unrelated caches or contact providers from UI. }
  if Result=nil then Result:=SearchTile(Grid,Tile,'all',80,50,5000,True,False);
  Providers:=ArrayAt(Result,'providers');
  if Providers<>nil then for I:=0 to Providers.Count-1 do begin
    P:=TJSONObject(Providers[I]);
    if P.Get('provider','')='mapillary' then P.Booleans['credentials_available']:=FConfig.MapillaryToken<>'';
  end;
end;

function TPhotoApiClient.SequenceNeighbors(Photo:TJSONObject; BeforeCount,AfterCount,MaxPages:Integer;
  Offline,Refresh:Boolean; Grid:TGeoTileGrid):TJSONObject;
var Seq,Anchor,URL,Cursor,Auth,Key,State,S:string; IDs,Pages,TileGroups:TStringList;
  Items,Photos,Failures:TJSONArray; J,P,Stub,One:TJSONObject; R:TFetchResult;
  I,Page,At,L,H,Index,GroupIndex:Integer; More,Missing:Boolean; Tile:TGeoTileId;
begin
  FMetadataProvider:='';
  if Photo.Get('provider','')<>'mapillary' then raise Exception.Create('Sequence browsing currently supports Mapillary');
  Seq:=Photo.Get('sequence_id',''); Anchor:=Photo.Get('image_id','');
  if (Seq='') or (Length(Seq)>256) or (Anchor='') then raise Exception.Create('Photo has no sequence identity');
  if (BeforeCount<0) or (BeforeCount>50) or (AfterCount<0) or (AfterCount>50) or
    (MaxPages<1) or (MaxPages>50) then raise Exception.Create('Sequence limits: 0..50 neighbors each side, 1..50 pages');
  Photos:=TJSONArray.Create;Failures:=TJSONArray.Create;
  Result:=TJSONObject.Create(['provider','mapillary','sequence_id',Seq,'anchor_id',Photo.Get('id',''),
    'photos',Photos,'failures',Failures]);
  State:='complete';Auth:='';Page:=0;More:=False;L:=-1;H:=-1;
  if FConfig.MapillaryToken<>'' then Auth:='OAuth '+FConfig.MapillaryToken
  else if not Offline then begin
    Result.Add('status','credentials_required');Result.Add('complete',False);Result.Add('photo_count',0);Exit;
  end;
  IDs:=TStringList.Create;Pages:=TStringList.Create;TileGroups:=TStringList.Create;
  try
    Cursor:='';At:=-1;
    repeat
      if FHttp.Aborted then begin State:='cancelled';Break end;
      URL:=FConfig.MapillaryUrl+'/image_ids?sequence_id='+URLParam(Seq);
      if Cursor<>'' then URL:=URL+'&after='+URLParam(Cursor);
      if Pages.IndexOf(URL)>=0 then begin State:='invalid_pagination';Break end;Pages.Add(URL);
      Key:=KeyFor('mapillary/sequence',URL);
      if not FetchJson(URL,Key,Auth,Offline,Refresh,J,R) then begin
        if Offline then State:='cache_miss' else if R.StatusCode=429 then State:='rate_limited'
        else if R.StatusCode=400 then State:='request_rejected'
        else if (R.StatusCode=401) or (R.StatusCode=403) then State:='access_denied'
        else State:='unavailable';
        Result.Add('http_status',R.StatusCode);Break;
      end;
      Inc(Page);
      try
        Items:=ArrayAt(J,'data');if Items=nil then begin State:='invalid_response';Break end;
        for I:=0 to Items.Count-1 do begin
          S:=PhotoJsonString(Items[I],'id');
          if (S<>'') and (IDs.IndexOf(S)<0) then begin
            Index:=IDs.Add(S);if S=Anchor then At:=Index;
          end;
          if IDs.Count>=20000 then Break;
        end;
        More:=PhotoJsonString(J,'paging.next')<>'';Cursor:=PhotoJsonString(J,'paging.cursors.after');
        if More and (Cursor='') then begin State:='invalid_pagination';Break end;
      finally J.Free end;
      { image_ids is capture-time order. Keep only the bounded neighborhood,
        but scan enough IDs to reach the selected anchor, never all details. }
      if (At>=0) and (IDs.Count>At+AfterCount) then Break;
    until not More or (Page>=MaxPages) or (IDs.Count>=20000);
    if At<0 then begin
      if State='complete' then if More then State:='truncated_anchor_not_found' else State:='anchor_not_found';
    end else begin
      if (State='complete') and More and (IDs.Count<=At+AfterCount) then State:='truncated';
      L:=Max(0,At-BeforeCount);H:=Min(IDs.Count-1,At+AfterCount);
      for I:=L to H do begin
        if FHttp.Aborted then begin State:='cancelled';Break end;
        { An anchor can be only an id/sequence stub or a coverage-tile point.
          Resolve it through the same bounded detail/cache path as neighbors:
          Graph's computed camera pose takes precedence over coverage compass,
          and absent metadata must not create a spurious tile at (0, 0). }
        Stub:=TJSONObject.Create(['provider','mapillary','image_id',IDs[I],'id','mapillary:'+IDs[I]]);
        try P:=LoadDetail(Stub,Offline,Refresh) finally Stub.Free end;
        Missing:=(P=nil);
        if not Missing then Missing:=P.Get('sequence_id','')<>Seq;
        if Missing then begin
          P.Free;Failures.Add(TJSONObject.Create(['id','mapillary:'+IDs[I],'error','metadata_unavailable_or_wrong_sequence']));
          if FLastMetadataStatus=400 then begin State:='request_rejected';Break end;
          if (FLastMetadataStatus=401) or (FLastMetadataStatus=403) then begin State:='access_denied';Break end;
          if FLastMetadataStatus=429 then begin State:='rate_limited';Break end;
          Continue;
        end;
        P.Integers['sequence_index']:=I;P.Integers['relative_index']:=I-At;
        S:=CachedImageKey(P);if S<>'' then P.Strings['cache_key']:=S;
        Photos.Add(P);
        if Grid<>nil then begin
          Tile:=Grid.TileAt(TLatLon.Make(P.Get('latitude',0.0),P.Get('longitude',0.0)));
          S:=IntToStr(Tile.TX)+'/'+IntToStr(Tile.TY);GroupIndex:=TileGroups.IndexOf(S);
          if GroupIndex<0 then begin
            One:=TJSONObject.Create(['tile_x',Int64(Tile.TX),'tile_y',Int64(Tile.TY),'photos',TJSONArray.Create]);
            TileGroups.AddObject(S,One);
          end else One:=TJSONObject(TileGroups.Objects[GroupIndex]);
          TJSONArray(One.Find('photos')).Add(P.Clone);
        end;
        if Assigned(FOnProgress) then FOnProgress('sequence:mapillary',I-L+1,H-L+1);
      end;
      if (State='complete') and (Failures.Count>0) then State:='partial';
    end;
    for I:=0 to TileGroups.Count-1 do begin
      One:=TJSONObject(TileGroups.Objects[I]);Tile:=TGeoTileId.Make(0,True,One.Get('tile_x',0),One.Get('tile_y',0));
      RememberTileCatalog(Grid,Tile,One);
    end;
    Result.Add('status',State);Result.Add('complete',State='complete');Result.Add('photo_count',Photos.Count);
    Result.Add('scope','neighborhood');Result.Add('sequence_complete',not More and (State='complete') and
      (At>=0) and (L=0) and (H=IDs.Count-1));
    Result.Add('has_more',More);Result.Add('requested_before',BeforeCount);Result.Add('requested_after',AfterCount);
    Result.Add('pages',Page);Result.Add('listed_ids',IDs.Count);Result.Add('stats',Stats);
  finally for I:=0 to TileGroups.Count-1 do TileGroups.Objects[I].Free;TileGroups.Free;IDs.Free;Pages.Free end;
end;
