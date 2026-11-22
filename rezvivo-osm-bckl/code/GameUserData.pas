unit GameUserData;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, SysUtils, fpjson, VeloSiteAPI, RiderBodyParameters, AppSettings;

const
  DefaultDreamWorldId = 'krylatskoye-island';
  FirstRideWorldId = DefaultDreamWorldId;
  MaxLocalRiders = 8;
type
  TRideMapKind = (rmkDream, rmkReal);
  { Identity is a persistent UUID, never a name, slot number, or account 0.
    Multiple guests have separate credentials, preferences and ride journals. }
  TLocalRiderProfile = class
  private
    FIndex: Integer;
    FKey, FRoot, FBoundDir: String;
    FApi: TVeloSiteAPI;
    FSettings: TAppSettings;
    FPreferences: TJSONObject;
    FRideHolds:Integer;
    FRideDataDir:String;
    FRideProfile:TVeloSiteProfile;
    function GetPreferences: TJSONObject;
    function GetSettings: TAppSettings;
  public
    constructor Create(Index: Integer; const Key, Root: String);
    destructor Destroy; override;
    function DataDir: String;
    function DisplayName: String;
    procedure SavePreferences;
    procedure HoldRideIdentity;
    procedure ReleaseRideIdentity;
    property Key: String read FKey;
    property Index: Integer read FIndex;
    property Api: TVeloSiteAPI read FApi;
    property Appearance: TAppSettings read GetSettings;
    property Preferences: TJSONObject read GetPreferences;
  end;

function LocalRider(Index: Integer = 0): TLocalRiderProfile;
function LocalRiderCount: Integer;
procedure SetLocalRiderCount(Value: Integer);
function RiderApi(Index: Integer = 0): TVeloSiteAPI;
function RiderSettings(Index: Integer = 0): TAppSettings;
function RiderDataDir(Index: Integer = 0): String;
function RiderPreferences(Index: Integer = 0): TJSONObject;
function RiderPreference(const Key: String; const Default: String = ''; Index: Integer = 0): String;
procedure SetRiderPreference(const Key, Value: String; Index: Integer = 0);

function UserDataDir: String;
function UserPreferences: TJSONObject;
procedure SaveUserPreferences;
function UserPreference(const Key: String; const Default: String = ''): String;
procedure SetUserPreference(const Key, Value: String);
procedure RememberRideMap(Kind: TRideMapKind; const MapId: String);
procedure LastRideMap(out Kind: TRideMapKind; out MapId: String);
function AvatarBodyParameters(Index: Integer = 0): TRiderBodyParameters;
procedure SaveAvatarBody(const Value: TRiderBodyParameters; Index: Integer = 0);
procedure SelectAvatarBodySex(const Sex: Single; Index: Integer = 0);
function EffectiveRiderProfile(Index: Integer = 0): TVeloSiteProfile;
procedure SaveLocalRider(const Nickname: String; Weight: Single; Ftp: Integer;
  const Zones: String; Index: Integer = 0);
procedure AcceptServerRider(Index: Integer = 0);
procedure RememberWorkout(const Url: String);
function WorkoutFavorite(const Url: String): Boolean;
procedure ToggleWorkoutFavorite(const Url: String);

implementation
uses GameRouteLibraryData, DebugLog, Math, CastleURIUtils, CastleFilesUtils;
var Profiles: array[0..MaxLocalRiders-1] of TLocalRiderProfile;
  Roster: TJSONObject; RosterPath, RosterRoot: String;

procedure EnsureRoster;
var I,Count,OriginalCount:Integer;A:TJSONArray;G:TGUID;Changed,Recovered:Boolean;
  Seen:TStringList;Key,Canonical:String;D:TJSONData;
  Source,Backup:TFileStream;
begin
  if Roster<>nil then Exit;
  RosterRoot:=ExtractFilePath(URIToFilenameSafe(ApplicationConfig('local-riders.json')));
  if GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>''then
    RosterRoot:=ExtractFilePath(ExpandFileName(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')));
  if RosterRoot=''then RosterRoot:=IncludeTrailingPathDelimiter(GetAppConfigDir(False));
  RosterPath:=RosterRoot+'local-riders.json';Recovered:=False;
  try if FileExists(RosterPath)then Roster:=ReadAccountJSON(RosterPath);
  except on E:Exception do begin Recovered:=True;Logger.Warning('[LocalRiders] '+E.Message)end end;
  if Roster=nil then Roster:=TJSONObject.Create(['version',1,'count',1]);
  Changed:=Recovered;
  D:=Roster.Find('count');Count:=1;
  try if(D<>nil)and(D.JSONType=jtNumber)then Count:=EnsureRange(D.AsInteger,1,MaxLocalRiders);
  except Count:=1;Recovered:=True end;
  if(D=nil)or(D.JSONType<>jtNumber)then Recovered:=True;
  if(D=nil)or(D.JSONType<>jtNumber)or(D.AsFloat<>Count)then begin
    Roster.Delete('count');Roster.Add('count',Count);Changed:=True;
  end;
  if not(Roster.Find('profiles')is TJSONArray)then begin
    Roster.Delete('profiles');Roster.Add('profiles',TJSONArray.Create);Changed:=True;Recovered:=True;
  end;
  A:=Roster.Arrays['profiles'];OriginalCount:=A.Count;Seen:=TStringList.Create;
  try
    Seen.CaseSensitive:=False;
    for I:=0 to MaxLocalRiders-1 do begin
      if I>=A.Count then begin A.Add('');Changed:=True end;
      Key:='';if A.Items[I].JSONType=jtString then Key:=A.Strings[I];Canonical:='';
      try
        G:=StringToGUID('{'+Key+'}');Canonical:=LowerCase(Copy(GUIDToString(G),2,36));
        if Canonical='00000000-0000-0000-0000-000000000000'then Canonical:='';
      except Canonical:='' end;
      if(Canonical='')or(Seen.IndexOf(Canonical)>=0)then begin
        if I<OriginalCount then Recovered:=True;
        repeat
          if CreateGUID(G)<>0 then raise Exception.Create('Cannot create local rider identity');
          Canonical:=LowerCase(Copy(GUIDToString(G),2,36));
        until Seen.IndexOf(Canonical)<0;
      end;
      if(A.Items[I].JSONType<>jtString)or(Key<>Canonical)then begin
        A.Items[I]:=TJSONString.Create(Canonical);Changed:=True;
      end;
      Seen.Add(Canonical);
    end;
  finally Seen.Free end;
  { Keep the damaged roster for manual recovery without trusting it as a path.
    Existing profile directories and credentials are never removed or copied. }
  if Recovered and FileExists(RosterPath)and not FileExists(RosterPath+'.invalid')then
    try
      Source:=TFileStream.Create(RosterPath,fmOpenRead or fmShareDenyWrite);
      try Backup:=TFileStream.Create(RosterPath+'.invalid',fmCreate);
        try Backup.CopyFrom(Source,0)finally Backup.Free end;
      finally Source.Free end;
    except on E:Exception do Logger.Warning('[LocalRiders] Could not preserve damaged roster: '+E.Message)end;
  if Changed then WriteAccountJSON(RosterPath,Roster);
end;

function LocalRiderCount: Integer;
begin EnsureRoster;Result:=EnsureRange(Roster.Get('count',1),1,MaxLocalRiders) end;

procedure SetLocalRiderCount(Value: Integer);
begin
  EnsureRoster;Value:=EnsureRange(Value,1,MaxLocalRiders);
  if Roster.Get('count',1)=Value then Exit;
  Roster.Integers['count']:=Value;WriteAccountJSON(RosterPath,Roster);
end;

function LocalRider(Index: Integer): TLocalRiderProfile;
var Key: String; G: TGUID;
begin
  EnsureRoster;
  if (Index<0)or(Index>=MaxLocalRiders)then raise ERangeError.Create('Local rider index');
  if Profiles[Index]=nil then begin
    Key:=Roster.Arrays['profiles'].Strings[Index];
    { A damaged/imported roster cannot escape the profile directory. }
    try G:=StringToGUID('{'+Key+'}');Key:=LowerCase(Copy(GUIDToString(G),2,36));
    except raise EConvertError.Create('Invalid local rider identity') end;
    Profiles[Index]:=TLocalRiderProfile.Create(Index,Key,
      RosterRoot+'local-riders'+PathDelim+Key+PathDelim);
  end;
  Result:=Profiles[Index];
end;

constructor TLocalRiderProfile.Create(Index: Integer; const Key,Root: String);
begin
  inherited Create;FIndex:=Index;FKey:=Key;FRoot:=Root;
  if Index=0 then FApi:=VeloSite else FApi:=TVeloSiteAPI.Create(FRoot+'auth.json');
end;

destructor TLocalRiderProfile.Destroy;
begin
  FPreferences.Free;
  if FIndex<>0 then begin FSettings.Free;FApi.Free end;
  inherited;
end;

function TLocalRiderProfile.DataDir: String;
var Id: Int64; TestRoot: String;
begin
  if FRideHolds>0 then Exit(FRideDataDir);
  Id:=0;
  if FApi.IsAuthorized then begin
    Id:=FApi.CachedProfile.Id;
    if Id<=0 then Id:=-1; { Authenticated-but-unloaded never borrows guest data. }
  end;
  if FIndex<>0 then Exit(FRoot+'accounts'+PathDelim+IntToStr(Id)+PathDelim);
  TestRoot:=GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR');
  if(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'')and(TestRoot<>'')then
    Result:=IncludeTrailingPathDelimiter(TestRoot)+IntToStr(Id)+PathDelim
  else Result:=RouteAccountDir(Id);
end;

procedure TLocalRiderProfile.HoldRideIdentity;
begin
  if FRideHolds=0 then begin
    FRideDataDir:=DataDir;
    FRideProfile:=Default(TVeloSiteProfile);
    if FApi.IsAuthorized then FRideProfile:=FApi.CachedProfile;
  end;
  Inc(FRideHolds);
end;

procedure TLocalRiderProfile.ReleaseRideIdentity;
begin
  if FRideHolds>0 then Dec(FRideHolds);
  if FRideHolds=0 then begin
    FRideDataDir:='';FRideProfile:=Default(TVeloSiteProfile);
  end;
end;

function TLocalRiderProfile.GetSettings: TAppSettings;
begin
  if FIndex=0 then Exit(Settings);
  if FSettings=nil then FSettings:=TAppSettings.Create(FRoot+'appearance.json');
  Result:=FSettings;
end;

function TLocalRiderProfile.GetPreferences: TJSONObject;
var Dir: String;
begin
  Dir:=DataDir;
  if(FPreferences=nil)or(Dir<>FBoundDir)then begin
    FreeAndNil(FPreferences);FBoundDir:=Dir;
    try if FileExists(Dir+'experience.json')then FPreferences:=ReadAccountJSON(Dir+'experience.json');
    except on E:Exception do Logger.Warning('[LocalRiders] '+E.Message) end;
    if FPreferences=nil then FPreferences:=TJSONObject.Create;
  end;
  Result:=FPreferences;
end;

procedure TLocalRiderProfile.SavePreferences;
begin
  if FPreferences=nil then GetPreferences;
  { Save the object to the identity it was loaded for, even if an auth worker
    changes the API between editing a field and committing its preferences. }
  WriteAccountJSON(FBoundDir+'experience.json',FPreferences);
end;

function TLocalRiderProfile.DisplayName: String;
begin
  Result:=EffectiveRiderProfile(FIndex).Nickname;
  if Trim(Result)='' then Result:='Rider '+IntToStr(FIndex+1);
end;

function RiderApi(Index:Integer):TVeloSiteAPI;
begin Result:=LocalRider(Index).Api end;
function RiderSettings(Index:Integer):TAppSettings;
begin Result:=LocalRider(Index).Appearance end;
function RiderDataDir(Index:Integer):String;
begin Result:=LocalRider(Index).DataDir end;
function RiderPreferences(Index:Integer):TJSONObject;
begin Result:=LocalRider(Index).Preferences end;
function RiderPreference(const Key,Default:String;Index:Integer):String;
begin Result:=RiderPreferences(Index).Get(Key,Default) end;
procedure SetRiderPreference(const Key,Value:String;Index:Integer);
var O:TJSONObject;
begin
  O:=RiderPreferences(Index);
  if O.Get(Key,'')=Value then Exit;
  O.Strings[Key]:=Value;LocalRider(Index).SavePreferences;
end;

function UserDataDir: String;
begin Result:=RiderDataDir(0) end;

function UserPreferences: TJSONObject;
begin Result:=RiderPreferences(0) end;

procedure SaveUserPreferences;
begin LocalRider(0).SavePreferences;end;

function UserPreference(const Key,Default:String):String;
begin Result:=UserPreferences.Get(Key,Default);end;

procedure SetUserPreference(const Key,Value:String);
begin SetRiderPreference(Key,Value,0);end;

procedure RememberRideMap(Kind:TRideMapKind;const MapId:String);
var Key,KindName:String;O:TJSONObject;
begin
  if MapId='' then Exit;
  if Kind=rmkReal then begin Key:='last_route';KindName:='real';end
  else begin Key:='last_world';KindName:='dream';end;
  O:=UserPreferences;
  if(O.Get(Key,'')=MapId)and(O.Get('last_map_kind','')=KindName)then Exit;
  O.Strings[Key]:=MapId;O.Strings['last_map_kind']:=KindName;
  SaveUserPreferences;
end;

procedure LastRideMap(out Kind:TRideMapKind;out MapId:String);
var KindName:String;
begin
  KindName:=UserPreference('last_map_kind');
  Kind:=rmkDream;MapId:='';
  if KindName='real' then begin
    Kind:=rmkReal;MapId:=UserPreference('last_route');
  end else if KindName='dream' then MapId:=UserPreference('last_world')
  else begin
    { Older profiles have separate choices without their order. Preserve the
      previous quick-start world, or their real route if no world was saved. }
    MapId:=UserPreference('last_world');
    if MapId='' then begin Kind:=rmkReal;MapId:=UserPreference('last_route');end;
  end;
  if MapId='' then begin
    Kind:=rmkDream;MapId:=FirstRideWorldId;
  end;
end;

function AvatarBodyParameters(Index:Integer):TRiderBodyParameters;
var O:TJSONData; P:TVeloSiteProfile; S:TAppSettings;
begin
  S:=RiderSettings(Index);
  Result:=DefaultRiderBody(Ord(S.GetGender='female'));
  if S.FitHeightCm>=130 then Result.HeightCm:=S.FitHeightCm;
  if S.FitInseamCm>=50 then Result.InseamCm:=S.FitInseamCm;
  O:=RiderPreferences(Index).Find('avatar_body');
  if O is TJSONObject then Result:=ReadRiderBody(TJSONObject(O),Result);
  P:=EffectiveRiderProfile(Index);
  if P.WeightKg>=35 then Result.WeightKg:=P.WeightKg;
  Result:=NormalizeRiderBody(Result);
end;

procedure SaveAvatarBody(const Value:TRiderBodyParameters;Index:Integer);
var P:TRiderBodyParameters;O,R:TJSONObject;
begin
  P:=NormalizeRiderBody(Value);O:=RiderPreferences(Index);
  O.Delete('avatar_body');O.Add('avatar_body',WriteRiderBody(P));
  if not(O.Find('rider')is TJSONObject)then begin O.Delete('rider');O.Add('rider',TJSONObject.Create)end;
  R:=O.Objects['rider'];R.Floats['weight']:=P.WeightKg;
  LocalRider(Index).SavePreferences;
end;

procedure SelectAvatarBodySex(const Sex:Single;Index:Integer);
var P:TRiderBodyParameters;
begin
  P:=AvatarBodyParameters(Index); P.Sex:=Sex; P.HeadShape:=Sex;
  SaveAvatarBody(P,Index);
end;

function EffectiveRiderProfile(Index:Integer):TVeloSiteProfile;
var O:TJSONObject; Api:TVeloSiteAPI;
begin
  Api:=RiderApi(Index);
  { Token expiry makes this participant offline. It must not change the
    owner, FTP or data directory of an already running ride into a guest. }
  if LocalRider(Index).FRideHolds>0 then Result:=LocalRider(Index).FRideProfile
  else begin
    Result:=Api.CachedProfile;
    if not Api.IsAuthorized then Result:=Default(TVeloSiteProfile);
  end;
  O:=RiderPreferences(Index);
  if O.Find('rider') is TJSONObject then begin
    O:=O.Objects['rider'];
    Result.Nickname:=O.Get('nickname',Result.Nickname);
    Result.WeightKg:=O.Get('weight',Double(Result.WeightKg));
    Result.FtpW:=O.Get('ftp',Result.FtpW);
    Result.TrainingZonesJSON:=O.Get('zones',Result.TrainingZonesJSON);
  end;
end;

procedure SaveLocalRider(const Nickname:String;Weight:Single;Ftp:Integer;const Zones:String;Index:Integer);
var Root,O:TJSONObject;
begin
  Root:=RiderPreferences(Index);
  if not(Root.Find('rider')is TJSONObject)then begin Root.Delete('rider');Root.Add('rider',TJSONObject.Create)end;
  O:=Root.Objects['rider'];O.Strings['nickname']:=Nickname;
  if Weight>=0 then O.Floats['weight']:=Weight;
  if Ftp>=0 then O.Integers['ftp']:=Ftp;
  if Zones<>''then O.Strings['zones']:=Zones;
  LocalRider(Index).SavePreferences;
end;

procedure AcceptServerRider(Index:Integer);
var P:TVeloSiteProfile;
begin
  P:=RiderApi(Index).CachedProfile;
  SaveLocalRider(P.Nickname,P.WeightKg,P.FtpW,P.TrainingZonesJSON,Index);
end;

procedure RememberWorkout(const Url:String);
var A:TJSONArray;I:Integer;
begin
  if Url='' then Exit;
  if not(UserPreferences.Find('recent_workouts') is TJSONArray)then
    UserPreferences.Add('recent_workouts',TJSONArray.Create);
  A:=UserPreferences.Arrays['recent_workouts'];
  for I:=A.Count-1 downto 0 do if A.Strings[I]=Url then A.Delete(I);
  A.Insert(0,Url);
  while A.Count>12 do A.Delete(A.Count-1);
  UserPreferences.Strings['last_workout']:=Url;SaveUserPreferences;
end;

function WorkoutFavorite(const Url:String):Boolean;
var A:TJSONArray;I:Integer;
begin
  Result:=False;
  if not(UserPreferences.Find('favorite_workouts') is TJSONArray)then Exit;
  A:=UserPreferences.Arrays['favorite_workouts'];
  for I:=0 to A.Count-1 do if A.Strings[I]=Url then Exit(True);
end;

procedure ToggleWorkoutFavorite(const Url:String);
var A:TJSONArray;I:Integer;
begin
  if Url='' then Exit;
  if not(UserPreferences.Find('favorite_workouts') is TJSONArray)then
    UserPreferences.Add('favorite_workouts',TJSONArray.Create);
  A:=UserPreferences.Arrays['favorite_workouts'];
  for I:=0 to A.Count-1 do if A.Strings[I]=Url then begin
    A.Delete(I);SaveUserPreferences;Exit;
  end;
  A.Add(Url);SaveUserPreferences;
end;

procedure FreeProfiles;
var I:Integer;
begin
  for I:=0 to MaxLocalRiders-1 do FreeAndNil(Profiles[I]);
  FreeAndNil(Roster);
end;
finalization
  FreeProfiles;
end.
