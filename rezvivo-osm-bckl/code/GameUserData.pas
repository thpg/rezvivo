unit GameUserData;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, SysUtils, fpjson, VeloSiteAPI;

const
  DefaultDreamWorldId = 'castle-island';
  FirstRideWorldId = 'lighthouse-island';
type
  TRideMapKind = (rmkDream, rmkReal);

function UserDataDir: String;
function UserPreferences: TJSONObject;
procedure SaveUserPreferences;
function UserPreference(const Key: String; const Default: String = ''): String;
procedure SetUserPreference(const Key, Value: String);
procedure RememberRideMap(Kind: TRideMapKind; const MapId: String);
procedure LastRideMap(out Kind: TRideMapKind; out MapId: String);
function EffectiveRiderProfile: TVeloSiteProfile;
procedure SaveLocalRider(const Nickname: String; Weight: Single; Ftp: Integer;
  const Zones: String);
procedure AcceptServerRider;
procedure RememberWorkout(const Url: String);
function WorkoutFavorite(const Url: String): Boolean;
procedure ToggleWorkoutFavorite(const Url: String);

implementation
uses GameRouteLibraryData, DebugLog;
var Preferences: TJSONObject; BoundDir: String;

function UserDataDir: String;
var Id: Int64; TestRoot: String;
begin
  Id:=0;
  if VeloSite.IsAuthorized then Id:=VeloSite.CachedProfile.Id;
  TestRoot:=GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR');
  if (GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'') and (TestRoot<>'') then
    Result:=IncludeTrailingPathDelimiter(TestRoot)+IntToStr(Id)+PathDelim
  else Result:=RouteAccountDir(Id);
end;

function UserPreferences: TJSONObject;
var Dir: String;
begin
  Dir:=UserDataDir;
  if (Preferences=nil) or (Dir<>BoundDir) then begin
    FreeAndNil(Preferences);BoundDir:=Dir;
    if FileExists(Dir+'experience.json')then
      try Preferences:=ReadAccountJSON(Dir+'experience.json');
      except on E:Exception do Logger.Warning('[UserData] '+E.Message);end;
    if Preferences=nil then Preferences:=TJSONObject.Create;
  end;
  Result:=Preferences;
end;

procedure SaveUserPreferences;
begin WriteAccountJSON(UserDataDir+'experience.json',UserPreferences);end;

function UserPreference(const Key,Default:String):String;
begin Result:=UserPreferences.Get(Key,Default);end;

procedure SetUserPreference(const Key,Value:String);
begin
  if UserPreference(Key)=Value then Exit;
  UserPreferences.Strings[Key]:=Value;SaveUserPreferences;
end;

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
  if MapId='' then begin Kind:=rmkDream;MapId:=FirstRideWorldId;end;
end;

function EffectiveRiderProfile:TVeloSiteProfile;
var O:TJSONObject;
begin
  Result:=VeloSite.CachedProfile;
  if not VeloSite.IsAuthorized then Result:=Default(TVeloSiteProfile);
  O:=UserPreferences;
  if O.Find('rider') is TJSONObject then begin
    O:=O.Objects['rider'];
    Result.Nickname:=O.Get('nickname',Result.Nickname);
    Result.WeightKg:=O.Get('weight',Double(Result.WeightKg));
    Result.FtpW:=O.Get('ftp',Result.FtpW);
    Result.TrainingZonesJSON:=O.Get('zones',Result.TrainingZonesJSON);
  end;
end;

procedure SaveLocalRider(const Nickname:String;Weight:Single;Ftp:Integer;const Zones:String);
var O:TJSONObject;
begin
  if not(UserPreferences.Find('rider') is TJSONObject) then
    UserPreferences.Add('rider',TJSONObject.Create);
  O:=UserPreferences.Objects['rider'];
  O.Strings['nickname']:=Nickname;
  if Weight>=0 then O.Floats['weight']:=Weight;
  if Ftp>=0 then O.Integers['ftp']:=Ftp;
  if Zones<>'' then O.Strings['zones']:=Zones;
  SaveUserPreferences;
end;

procedure AcceptServerRider;
var P:TVeloSiteProfile;
begin
  P:=VeloSite.CachedProfile;
  SaveLocalRider(P.Nickname,P.WeightKg,P.FtpW,P.TrainingZonesJSON);
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

finalization
  FreeAndNil(Preferences);
end.
