function TVideoApiClient.FullRecord(Video: TJSONObject): TJSONObject;
var Key: string;
begin
  Key:=Video.Get('record_cache_key','');
  if Key<>'' then begin
    if Pos('video-api/v1/record/',Key)<>1 then raise Exception.Create('Invalid video record key');
    Result:=ReadJsonKey(Key);
    if Result=nil then raise Exception.Create('Camera metadata was removed from cache; repeat the search');
    if Result.Get('id','')<>Video.Get('id','') then begin Result.Free; raise Exception.Create('Video record identity mismatch') end;
  end else Result:=TJSONObject(Video.Clone);
end;

function TVideoApiClient.DownloadVideo(Video: TJSONObject; Offline: Boolean): TJSONObject;
var P: TJSONObject; URL,Key: string; R: TFetchResult;
begin
  P:=FullRecord(Video); Result:=TJSONObject.Create(['success',False]);
  try
    try
    if not P.Get('download_allowed',False) then begin Result.Add('error','discovery_only_or_license_required'); Exit end;
    URL:=P.Get('video_url',''); Key:=VideoKey('media',P.Get('catalog_url','')+'/'+P.Get('id','')+'/preview1280');
    FResponseKind:='media'; FHttp.MaxResponseBytes:=FVideoConfig.MediaMaxBytes;
    R:=FHttp.GetCachedByKey('',Key); if R.Success then Inc(FCacheHits);
    if not R.Success then begin
      if P.Get('provider','')='flickr' then URL:=ResolveFlickrVideo(P,Offline,False);
      if not VideoDirectURL(URL) then begin Result.Add('error','direct_video_unavailable'); Exit end;
      R:=Resource(URL,Key,'media',Offline,False);
      if not R.Success and not Offline and not FHttp.Aborted and (P.Get('provider','')='flickr') and
        ((R.StatusCode=401) or (R.StatusCode=403) or (R.StatusCode=404)) then begin
        URL:=ResolveFlickrVideo(P,False,True);
        if VideoDirectURL(URL) then R:=Resource(URL,Key,'media',False,False);
      end;
    end;
    if R.Success and not FHttp.Cache.Has(Key) then begin Result.Add('error','cache_write_failed'); Exit end;
    Result.Booleans['success']:=R.Success; Result.Add('cache_key',Key); Result.Add('id',P.Get('id',''));
    Result.Add('bytes',Length(R.Data)); Result.Add('from_cache',R.FromCache);
    if not R.Success then Result.Add('error',FailureStatus(R,Offline)); Result.Add('stats',Stats);
    except Result.Free; raise end;
  finally P.Free end;
end;

function TVideoApiClient.ExtractFrame(Video: TJSONObject; TimeS: Double; Offline: Boolean): TJSONObject;
var P,Downloaded,Location: TJSONObject; Samples: TJSONArray; R: TFetchResult;
  URL,Key,MediaKey,Decoder,Dir,InputPath,OutputPath,Filter: string;
  I,Nearest,FrameIndex: Integer; T,Best,Fps: Double; FrameTimeKnown: Boolean;
  Bytes: TBytes; Stream: TFileStream; Proc: TProcess; Start: QWord;
  Buffer: array[0..4095] of Byte; Guid: TGuid;
  procedure Arg(const S: string);
  begin Proc.Parameters.Add(S) end;
  procedure Drain;
  begin
    while Proc.Output.NumBytesAvailable>0 do Proc.Output.Read(Buffer,SizeOf(Buffer));
    while Proc.Stderr.NumBytesAvailable>0 do Proc.Stderr.Read(Buffer,SizeOf(Buffer));
  end;
begin
  if IsNan(TimeS) or IsInfinite(TimeS) or (TimeS<0) or (TimeS>86400) then raise Exception.Create('Frame time must be 0..86400 seconds');
  P:=FullRecord(Video); Result:=TJSONObject.Create(['success',False]); Downloaded:=nil;
  try
    try
      if not P.Get('download_allowed',False) then begin Result.Add('error','discovery_only_or_license_required'); Exit end;
      Samples:=ArrayAt(P,'frames'); URL:=''; FrameIndex:=-1; FrameTimeKnown:=False;
      if Samples=nil then Samples:=ArrayAt(P,'track');
      Nearest:=-1; Best:=1e100;
      if Samples<>nil then for I:=0 to Samples.Count-1 do begin
        if Num(Samples.Items[I],'time_s',T) and (Abs(T-TimeS)<Best) then begin Best:=Abs(T-TimeS); Nearest:=I end;
      end;
      if Nearest>=0 then begin
        URL:=PhotoJsonString(Samples.Items[Nearest],'url');
        if URL<>'' then begin Num(Samples.Items[Nearest],'time_s',TimeS); FrameTimeKnown:=True end
        else if Samples.Items[Nearest].FindPath('frame_index')<>nil then begin
          FrameIndex:=TJSONObject(Samples.Items[Nearest]).Get('frame_index',-1);
          Num(Samples.Items[Nearest],'time_s',TimeS); FrameTimeKnown:=True;
        end;
      end;
      if (FrameIndex<0) and (URL='') and Num(P,'frame_rate',Fps) and (Fps>0) and (Fps<=240) then begin
        FrameIndex:=Round(TimeS*Fps); TimeS:=FrameIndex/Fps; FrameTimeKnown:=True;
      end;
      Key:=VideoKey('frame',P.AsJSON+'/'+FloatText(TimeS)+'/1280/v1');
      R:=ReadImage(Key);
      if not R.Success then begin
        if URL<>'' then begin
          if not VideoDirectURL(URL) then raise Exception.Create('Invalid sequence frame URL');
          R:=Resource(URL,Key,'image',Offline,False);
        end else begin
          Decoder:=FVideoConfig.FFmpeg;
          if Decoder='' then Decoder:=ExeSearch('ffmpeg.exe',GetEnvironmentVariable('PATH'));
          {$ifndef windows}if Decoder='' then Decoder:=ExeSearch('ffmpeg',GetEnvironmentVariable('PATH'));{$endif}
          if (Decoder='') or not FileExists(Decoder) then begin Result.Add('error','ffmpeg_required'); Exit end;
          Downloaded:=DownloadVideo(P,Offline);
          if not Downloaded.Get('success',False) then begin Result.Add('error',Downloaded.Get('error','video_unavailable')); Exit end;
          MediaKey:=Downloaded.Get('cache_key','');
          if not FHttp.Cache.Get(MediaKey,Bytes) then raise Exception.Create('Cached video disappeared');
          CreateGUID(Guid); Dir:=IncludeTrailingPathDelimiter(GetTempDir(False))+'rezvivo-video-'+GUIDToString(Guid);
          if not CreateDir(Dir) then raise Exception.Create('Unable to create decoder scratch directory');
          InputPath:=Dir+DirectorySeparator+'input.bin'; OutputPath:=Dir+DirectorySeparator+'frame.png';
          Proc:=TProcess.Create(nil);
          try
            Stream:=TFileStream.Create(InputPath,fmCreate);
            try if Length(Bytes)>0 then Stream.WriteBuffer(Bytes[0],Length(Bytes)) finally Stream.Free end;
            Bytes:=nil;
            Proc.Executable:=Decoder; Proc.Options:=[poUsePipes,poNoConsole];
            Arg('-nostdin'); Arg('-hide_banner'); Arg('-loglevel'); Arg('error');
            Arg('-threads'); Arg('2'); Arg('-filter_threads'); Arg('1'); Arg('-protocol_whitelist'); Arg('file,pipe');
            if P.Get('container','')='hevc' then begin Arg('-f'); Arg('hevc') end;
            Arg('-i'); Arg(InputPath);
            if FrameIndex<0 then begin Arg('-ss'); Arg(FloatText(TimeS)) end;
            Filter:='scale=1280:1280:force_original_aspect_ratio=decrease';
            if FrameIndex>=0 then Filter:='select=eq(n\,'+IntToStr(FrameIndex)+'),'+Filter;
            Arg('-vf'); Arg(Filter); Arg('-frames:v'); Arg('1'); Arg('-an'); Arg('-sn'); Arg('-y'); Arg(OutputPath);
            Proc.Execute; Start:=GetTickCount64;
            while Proc.Running do begin
              Drain;
              if FHttp.Aborted or (GetTickCount64-Start>60000) then begin Proc.Terminate(1); Break end;
              Sleep(10);
            end;
            Proc.WaitOnExit; Drain;
            if FHttp.Aborted then raise EAbort.Create('cancelled');
            if (Proc.ExitStatus<>0) or not FileExists(OutputPath) then begin Result.Add('error','frame_decode_failed_or_timeout'); Exit end;
            Stream:=TFileStream.Create(OutputPath,fmOpenRead or fmShareDenyWrite);
            try
              if (Stream.Size=0) or (Stream.Size>8*1024*1024) then raise Exception.Create('Invalid decoded frame size');
              SetLength(Bytes,Stream.Size); Stream.ReadBuffer(Bytes[0],Length(Bytes));
            finally Stream.Free end;
            FResponseKind:='image'; FImageResponse:=True; FHttp.MaxResponseBytes:=32*1024*1024;
            if ValidateResponse(Self,'',Bytes,'image/png')<>'' then raise Exception.Create('Invalid decoded image');
            FHttp.Cache.Put(Key,Bytes,TCacheMetadata.Make('image/png')); R:=ReadImage(Key);
          finally
            if Proc.Running then begin Proc.Terminate(1); Proc.WaitOnExit end;
            Proc.Free;
            { Only these exact scratch files are ours; no recursive deletion. }
            DeleteFile(InputPath); DeleteFile(OutputPath); RemoveDir(Dir);
          end;
        end;
      end;
      Result.Booleans['success']:=R.Success;
      if not R.Success then begin Result.Add('error',FailureStatus(R,Offline)); Exit end;
      Result.Add('cache_key',Key); Result.Add('bytes',Length(R.Data)); Result.Add('video_id',P.Get('id',''));
      Result.Add('time_s',TimeS); Result.Add('timestamp_exact',FrameTimeKnown);
      Result.Add('source_url',P.Get('source_url','')); Result.Add('author',P.Get('author',''));
      Result.Add('captured_at',P.Get('captured_at',''));
      Result.Add('license',P.Get('license','')); Result.Add('license_url',P.Get('license_url',''));
      Result.Add('permission_reference',P.Get('permission_reference',''));
      Result.Add('required_attribution',P.Get('required_attribution',''));
      Location:=VideoFrameLocation(P,TimeS);
      if not FrameTimeKnown and Location.Get('camera_position_known',False) then begin
        Location.Booleans['camera_position_known']:=False;
        Location.Strings['coordinate_role']:='estimated_camera';
      end;
      Result.Add('location',Location); Result.Add('stats',Stats);
      PutJsonKey(Key+'/provenance',Result);
    except Result.Free; raise end;
  finally P.Free; Downloaded.Free end;
end;

function TVideoApiClient.ReadImage(const CacheKey: string): TFetchResult;
begin
  if Pos('photo-api/v1/',CacheKey)=1 then Exit(inherited ReadImage(CacheKey));
  if Pos('video-api/v1/frame/',CacheKey)<>1 then Exit(TFetchResult.Failure('Not a video frame cache key'));
  FResponseKind:='image'; FImageResponse:=True; FHttp.MaxResponseBytes:=32*1024*1024;
  Result:=FHttp.GetCachedByKey('',CacheKey); if Result.Success then Inc(FCacheHits);
end;
