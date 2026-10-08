{ Included in PhotoApi: additional catalogs share the exact same transport/cache. }
function TPhotoApiClient.SearchCatalog(const Provider: string; const Box: TLatLonBox;
  MaxPages, MaxPhotos: Integer; Offline, Refresh: Boolean; Photos: TJSONArray): TJSONObject;
var C: TPhotoSourceConfig; Registry, J, Detail, Licenses, Item, P, Binding: TJSONObject;
  Items, Media, Entries: TJSONArray; V: TJSONData;
  Base, URL, Key, Auth, Header, State, Query, Titles, LicenseIds, Wkt, Id: string;
  I,K,Page,Added,Rejected,Offset,Pending,Count,RelevanceRejected: Integer;
  X,Y,Radius: Double; R: TFetchResult; More,Full: Boolean; Seen: TStringList;
  Boxes: array of TLatLonBox; B: TLatLonBox;

  function Read(const CleanURL, Kind: string; out Data: TJSONObject): Boolean;
  var Actual: string;
  begin
    FMetadataProvider:=Kind; Key:=KeyFor(Provider+'/search',CleanURL); Actual:=CleanURL;
    if Provider='flickr' then Actual:=Actual+'&api_key='+URLParam(C.FlickrKey)
    else if Provider='geograph' then Actual:=Actual+'&key='+URLParam(C.GeographKey);
    R:=Fetch(Actual,Key,Auth,Offline,Refresh,False,Header); Data:=nil; Result:=R.Success;
    if Result then begin
      SetString(Actual,PAnsiChar(@R.Data[0]),Length(R.Data));
      Data:=TJSONObject(ParsePhotoJson(Actual));
    end else begin
      if FHttp.Aborted then State:='cancelled'
      else if Offline then State:='cache_miss'
      else if R.StatusCode=429 then State:='rate_limited'
      else if (R.StatusCode=401) or (R.StatusCode=403) or (R.ErrorMsg='Photo provider denied access') then State:='access_denied'
      else if R.StatusCode=200 then State:='invalid_response'
      else State:='unavailable';
    end;
  end;

  procedure Accept(Photo: TJSONObject);
  var Existing: TJSONObject; N: Integer;
  begin
    if Photo=nil then begin Inc(Rejected); Exit end;
    X:=Photo.Floats['longitude']; Y:=Photo.Floats['latitude'];
    if (X<Box.MinLon) or (X>Box.MaxLon) or (Y<Box.MinLat) or (Y>Box.MaxLat) then
    begin Photo.Free; Inc(Rejected); Exit end;
    if not FRouteScope.Contains(Y,X) then begin Photo.Free; Inc(Rejected); Exit end;
    Id:=Photo.Strings['id']; N:=Seen.IndexOf(Id);
    if N>=0 then begin
      Existing:=TJSONObject(Seen.Objects[N]);
      if Photo.Find('wikidata_id')<>nil then begin
        Existing.Strings['wikidata_id']:=Photo.Strings['wikidata_id'];
        Existing.Floats['subject_latitude']:=Y; Existing.Floats['subject_longitude']:=X;
      end;
      Photo.Free; Exit;
    end;
    if Added>=MaxPhotos then begin More:=True; Photo.Free; Exit end;
    { Keep excluded metadata with its reason: cached images can be inspected
      in Show rejected, and discovery must not silently erase provenance. }
    if Photo.Get('review_status','')='rejected' then Inc(RelevanceRejected);
    Seen.AddObject(Id,Photo); Photos.Add(Photo); Inc(Added);
  end;

  function BboxText(const Q: TLatLonBox): string;
  begin Result:=FloatText(Q.MinLon)+','+FloatText(Q.MinLat)+','+FloatText(Q.MaxLon)+','+FloatText(Q.MaxLat) end;

  procedure SplitBox(const Q: TLatLonBox);
  var N,A: Integer; HalfX,HalfY: Double; Child:TLatLonBox;
  begin
    { A full spatial query is not proof of full coverage. Refine while bounded
      by max_pages, then report truncated. Never issue an unbounded world scan. }
    if (Q.MaxLon-Q.MinLon<0.00001) or (Q.MaxLat-Q.MinLat<0.00001) then begin More:=True; Exit end;
    N:=Length(Boxes); HalfX:=(Q.MinLon+Q.MaxLon)*0.5; HalfY:=(Q.MinLat+Q.MaxLat)*0.5;
    for A:=0 to 3 do begin
      Child:=Q;
      if (A and 1)=0 then Child.MaxLon:=HalfX else Child.MinLon:=HalfX;
      if A<2 then Child.MaxLat:=HalfY else Child.MinLat:=HalfY;
      if not FRouteScope.HitsBox(Child) then Continue;
      SetLength(Boxes,N+1); Boxes[N]:=Child; Inc(N);
    end;
  end;

  function CommonsParams: string;
  begin
    Result:='action=query&format=json&formatversion=2&maxlag=5&prop=imageinfo|coordinates'+
      '&iiprop=url|size|mime|extmetadata|sha1&iiurlwidth=1280&coprop=type|globe&colimit=max';
  end;

  procedure ResolveWikidata;
  var A,N,NextItem,FirstItem: Integer; Pages: TJSONArray; Qid, Name, WikiKey, ImageName, Encoded: string;
    Lat,Lon: Double; F: TFormatSettings;
  begin
    WikiKey:=Key; NextItem:=0;
    while NextItem<Items.Count do begin
      FirstItem:=NextItem; Titles:='';
      while NextItem<Items.Count do begin
        ImageName:=PhotoJsonString(Items.Items[NextItem],'image.value');
        N:=Pos('/Special:FilePath/',ImageName);
        if N=0 then begin Inc(NextItem); Continue end;
        Encoded:=URLParam('File:'+DecodeURLElement(Copy(ImageName,N+18,MaxInt)));
        if Length(Encoded)>5000 then begin Inc(Rejected); Inc(NextItem); Continue end;
        if (Titles<>'') and (Length(Titles)+Length(Encoded)>5500) then Break;
        if Titles<>'' then Titles:=Titles+'%7C'; Titles:=Titles+Encoded; Inc(NextItem);
      end;
      if Titles='' then Continue;
      if not Read(C.CommonsUrl+'?'+CommonsParams+'&titles='+Titles,'commons',Detail) then Exit;
    try
      Pages:=ArrayAt(Detail,'query.pages'); if Pages=nil then Exit;
      F:=DefaultFormatSettings; F.DecimalSeparator:='.'; F.ThousandSeparator:=#0;
      for A:=FirstItem to NextItem-1 do begin
        Binding:=TJSONObject(Items.Items[A]);
        ImageName:=PhotoJsonString(Binding,'image.value'); N:=Pos('/Special:FilePath/',ImageName);
        if N=0 then Continue;
        Name:=StringReplace('File:'+DecodeURLElement(Copy(ImageName,N+18,MaxInt)),'_',' ',[rfReplaceAll]);
        Wkt:=PhotoJsonString(Binding,'location.value');
        if Pos('Point(',Wkt)<>1 then Continue;
        Wkt:=Copy(Wkt,7,Length(Wkt)-7); N:=Pos(' ',Wkt);
        if not TryStrToFloat(Copy(Wkt,1,N-1),Lon,F) or not TryStrToFloat(Copy(Wkt,N+1,MaxInt),Lat,F) then Continue;
        if IsNan(Lat) or IsNan(Lon) or IsInfinite(Lat) or IsInfinite(Lon) then Continue;
        Qid:=PhotoJsonString(Binding,'item.value'); Qid:=Copy(Qid,LastDelimiter('/',Qid)+1,MaxInt);
        for N:=0 to Pages.Count-1 do begin
          if (Pages.Items[N].JSONType<>jtObject) or
            (StringReplace(PhotoJsonString(Pages.Items[N],'title'),'_',' ',[rfReplaceAll])<>Name) then Continue;
          P:=TJSONObject(Pages.Items[N].Clone);
          try
            P.Floats['_subject_lat']:=Lat; P.Floats['_subject_lon']:=Lon; P.Strings['_wikidata']:=Qid;
            Item:=NormalizeCatalogPhoto('commons',P,C.CommonsUrl,Key);
            if Item<>nil then begin
              Item.Add('discovered_via','wikidata'); Item.Add('object_metadata_cache_key',WikiKey);
            end;
            Accept(Item);
          finally P.Free end;
          Break;
        end;
      end;
    finally Detail.Free end;
    end;
  end;

begin
  Result:=TJSONObject.Create(['provider',Provider]); C:=FConfig.Sources;
  Registry:=PhotoSourceRegistry(C);
  try
    V:=Registry.Find(Provider);
    if V=nil then begin Result.Add('status','unsupported'); Result.Add('complete',False); Exit end;
    State:=PhotoJsonString(V,'status');
    if (State<>'ready') and not ((State='credentials_required') and Offline) then begin
      Result.Add('status',State); Result.Add('complete',False); Exit;
    end;
    Base:=PhotoJsonString(V,'api_url');
  finally Registry.Free end;
  if (Provider='geograph') and ((Box.MaxLat<49) or (Box.MinLat>62) or (Box.MaxLon < -11) or (Box.MinLon>2.5)) then
  begin Result.Add('status','outside_coverage'); Result.Add('complete',True); Result.Add('photos',0); Exit end;
  Auth:=''; Header:='Authorization'; State:='complete'; Page:=0; Added:=0; Rejected:=0; Offset:=0;RelevanceRejected:=0;
  More:=False; Full:=False; R:=Default(TFetchResult); Pending:=0; Licenses:=nil; Seen:=TStringList.Create;
  Seen.Sorted:=True; Seen.Duplicates:=dupIgnore;
  SetLength(Boxes,1); Boxes[0]:=Box;
  if Provider='citylens' then begin Auth:=C.CityLensKey; Header:='X-API-Key' end;
  if Provider='cyclomedia' then Auth:='Basic '+EncodeStringBase64(C.CyclomediaUser+':'+C.CyclomediaPassword);
  try
    for I:=0 to Photos.Count-1 do Seen.AddObject(PhotoJsonString(Photos.Items[I],'id'),Photos.Items[I]);
    if Provider='flickr' then begin
      if Read(Base+'?method=flickr.photos.licenses.getInfo&format=json&nojsoncallback=1','flickr',Licenses) then begin
        Entries:=ArrayAt(Licenses,'licenses.license'); LicenseIds:='';
        if Entries<>nil then for I:=0 to Entries.Count-1 do
          if PhotoLicenseReusable(PhotoJsonString(Entries.Items[I],'name'),PhotoJsonString(Entries.Items[I],'url')) then begin
            if LicenseIds<>'' then LicenseIds:=LicenseIds+','; LicenseIds:=LicenseIds+PhotoJsonString(Entries.Items[I],'id');
          end;
        if LicenseIds='' then State:='invalid_response';
      end;
    end;
    while (State='complete') and (Page<MaxPages) and (Added<MaxPhotos) do begin
      if FHttp.Aborted then begin State:='cancelled'; Break end;
      B:=Box;
      if (Provider='commons') or (Provider='cyclomedia') then begin
        if Pending>=Length(Boxes) then Break; B:=Boxes[Pending]; Inc(Pending);
      end;
      if Provider='commons' then URL:=Base+'?'+CommonsParams+
        '&generator=geosearch&ggsnamespace=6&ggslimit=50&ggsbbox='+
        FloatText(B.MaxLat)+'|'+FloatText(B.MinLon)+'|'+FloatText(B.MinLat)+'|'+FloatText(B.MaxLon)
      else if Provider='wikidata' then begin
        Query:='SELECT DISTINCT ?item ?location ?image WHERE { SERVICE wikibase:box { ?item wdt:P625 ?location . '+
          'bd:serviceParam wikibase:cornerSouthWest "Point('+FloatText(B.MinLon)+' '+FloatText(B.MinLat)+')"^^geo:wktLiteral ; '+
          'wikibase:cornerNorthEast "Point('+FloatText(B.MaxLon)+' '+FloatText(B.MaxLat)+')"^^geo:wktLiteral . } '+
          '?item wdt:P18 ?image . } ORDER BY ?item ?image LIMIT 50 OFFSET '+IntToStr(Offset);
        URL:=Base+'?format=json&query='+URLParam(Query);
      end else if Provider='gbif' then URL:=Base+'/occurrence/search?kingdomKey=6&mediaType=StillImage'+
        '&hasGeospatialIssue=false&decimalLatitude='+FloatText(B.MinLat)+','+FloatText(B.MaxLat)+
        '&decimalLongitude='+FloatText(B.MinLon)+','+FloatText(B.MaxLon)+'&limit=100&offset='+IntToStr(Offset)
      else if Provider='flickr' then URL:=Base+'?method=flickr.photos.search&format=json&nojsoncallback=1'+
        '&bbox='+BboxText(B)+'&has_geo=1&media=photos&safe_search=1&content_types=0'+
        '&min_taken_date=1970-01-01&license='+LicenseIds+'&per_page=100&page='+IntToStr(Page+1)+
        '&extras=license,date_taken,owner_name,geo,o_dims,media,url_t,url_z,url_l,url_o'
      else if Provider='geograph' then begin
        Radius:=Min(20.0,Sqrt(Sqr((B.MaxLat-B.MinLat)*111.32)+Sqr((B.MaxLon-B.MinLon)*111.32*Cos(DegToRad((B.MaxLat+B.MinLat)*0.5))))*0.5);
        URL:=Base+'?format=GeoRSS&location='+FloatText((B.MinLat+B.MaxLat)*0.5)+','+FloatText((B.MinLon+B.MaxLon)*0.5)+
          '&distance='+FloatText(Max(0.01,Radius))+'&perpage=100&page='+IntToStr(Page+1);
      end else if Provider='citylens' then URL:=Base+'/export-api/v1/frames?from_dt='+URLParam(C.CityLensFrom)+
        '&to_dt='+URLParam(C.CityLensTo)+'&limit=100&offset='+IntToStr(Offset)
      else if Provider='cyclomedia' then URL:=Base+'?service=WFS&version=1.1.0&request=GetFeature&typename=atlas:Recording'+
        '&outputformat=application/json&srsName=urn:ogc:def:crs:OGC:1.3:CRS84&maxFeatures=100&bbox='+
        BboxText(B)+',urn:ogc:def:crs:OGC:1.3:CRS84'
      else begin State:='unsupported'; Break end;
      if not Read(URL,Provider,J) then Break;
      Inc(Page); Full:=False;
      try
        Items:=nil;
        if Provider='commons' then begin Items:=ArrayAt(J,'query.pages'); Full:=(Items<>nil) and (Items.Count>=50) end
        else if Provider='wikidata' then begin Items:=ArrayAt(J,'results.bindings'); Full:=(Items<>nil) and (Items.Count>=50) end
        else if Provider='gbif' then begin Items:=ArrayAt(J,'results'); Full:=not J.Get('endOfRecords',False) end
        else if Provider='flickr' then begin Items:=ArrayAt(J,'photos.photo'); Full:=Page<StrToIntDef(PhotoJsonString(J,'photos.pages'),Page) end
        else if Provider='geograph' then begin Items:=ArrayAt(J,'items'); Full:=(Items<>nil) and (Items.Count>=100) end
        else if Provider='citylens' then begin Items:=ArrayAt(J,'frames'); Full:=Offset+100<StrToIntDef(PhotoJsonString(J,'total_count'),Offset+100) end
        else if Provider='cyclomedia' then begin Items:=ArrayAt(J,'features'); Full:=(Items<>nil) and (Items.Count>=100) end;
        if Items=nil then begin
          if (Provider='commons') and (J.Find('batchcomplete')<>nil) then Continue;
          State:='invalid_response'; Break;
        end;
        Count:=Items.Count;
        if Provider='wikidata' then ResolveWikidata
        else for I:=0 to Items.Count-1 do begin
          if FHttp.Aborted then begin State:='cancelled'; Break end;
          if Items.Items[I].JSONType<>jtObject then begin Inc(Rejected); Continue end;
          Item:=TJSONObject(Items.Items[I]);
          if Provider='gbif' then begin
            Media:=ArrayAt(Item,'media'); if Media=nil then Continue;
            for K:=0 to Media.Count-1 do begin
              Item.Add('_media',Media.Items[K].Clone);
              try Accept(NormalizeCatalogPhoto(Provider,Item,Base,Key)) finally Item.Delete('_media') end;
            end;
          end else begin
            if Provider='flickr' then begin
              Entries:=ArrayAt(Licenses,'licenses.license');
              if Entries<>nil then for K:=0 to Entries.Count-1 do
                if PhotoJsonString(Entries.Items[K],'id')=PhotoJsonString(Item,'license') then begin
                  Item.Strings['_license_name']:=PhotoJsonString(Entries.Items[K],'name');
                  Item.Strings['_license_url']:=PhotoJsonString(Entries.Items[K],'url'); Break;
                end;
            end else if Provider='citylens' then begin
              Item.Strings['_license']:=C.CityLensLicense;
              URL:=PhotoJsonString(Item,'frame_url');
              if not ResolveRelativeURI(Base+'/',URL,Query) or not SameOrigin(Base,Query) then begin Inc(Rejected); Continue end;
              Item.Strings['_image_url']:=Query;
            end else if Provider='cyclomedia' then begin
              Item.Strings['_license']:=C.CyclomediaLicense;
              Item.Strings['_source_url']:=C.CyclomediaRenderUrl;
              Item.Strings['_image_url']:=C.CyclomediaRenderUrl+'/Render/'+URLParam(PhotoJsonString(Item,'properties.imageId'))+
                '/?width=1280&height=960&srsName=epsg:4326&yaw=0&pitch=0&hfov=100';
            end;
            Accept(NormalizeCatalogPhoto(Provider,Item,Base,Key));
          end;
        end;
        if (Provider='commons') or (Provider='cyclomedia') then begin
          if Full then SplitBox(B);
          Full:=Pending<Length(Boxes);
        end;
        Inc(Offset,Count);
        if Count=0 then begin
          if Full then State:='invalid_pagination'; Full:=False;
        end;
        if Assigned(FOnProgress) then FOnProgress('search:'+Provider,Page,0);
        if not Full then Break;
      finally J.Free end;
    end;
    More:=More or Full or (((Provider='commons') or (Provider='cyclomedia')) and (Pending<Length(Boxes)));
    if (State='complete') and More then State:='truncated';
    Result.Add('status',State); Result.Add('complete',State='complete');
    Result.Add('pages',Page); Result.Add('photos',Added); Result.Add('rejected',Rejected); Result.Add('has_more',More);
    Result.Add('relevance_rejected',RelevanceRejected);
    if (State='invalid_response') and ((R.ErrorMsg='Photo API returned an error object') or
      (R.ErrorMsg='Invalid photo search response schema') or (R.ErrorMsg='Invalid photo API JSON')) then
      Result.Add('message',R.ErrorMsg);
    if State<>'complete' then Result.Add('http_status',R.StatusCode);
  finally Seen.Free; Licenses.Free; FMetadataProvider:='' end;
end;
