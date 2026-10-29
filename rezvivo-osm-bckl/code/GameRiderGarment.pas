unit GameRiderGarment;
{$mode objfpc}{$H+}
interface
uses RiderGarmentState, RiderTripo;
function AvatarGarment:TRiderGarmentParameters;
procedure SaveAvatarGarment(const P:TRiderGarmentParameters);
procedure ApplyAvatarGarment(Rider:TTripoRiderScene);
implementation
uses SysUtils, fpjson, jsonparser, GameUserData;
function AvatarGarment:TRiderGarmentParameters;
var D:TJSONData;S:string;
begin
  Result:=DefaultRiderGarment(RiderGarmentSeed(AvatarBodyParameters));
  S:=UserPreference('rider_garment');if S=''then Exit;
  D:=nil;
  try
    try
      D:=GetJSON(S);if D is TJSONObject then Result:=ReadRiderGarment(TJSONObject(D),Result);
    except on E:Exception do Exit end;
  finally D.Free end;
end;
procedure SaveAvatarGarment(const P:TRiderGarmentParameters);
var O:TJSONObject;
begin
  O:=WriteRiderGarment(P);
  try SetUserPreference('rider_garment',O.AsJSON)finally O.Free end;
end;
procedure ApplyAvatarGarment(Rider:TTripoRiderScene);
begin
  if(Rider<>nil)and(Rider.Garment<>nil)then Rider.Garment.ConfigureGarment(AvatarGarment);
end;
end.
