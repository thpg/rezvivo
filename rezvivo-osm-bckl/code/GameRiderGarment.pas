unit GameRiderGarment;
{$mode objfpc}{$H+}
interface
uses RiderGarmentState, RiderTripo;
function AvatarGarment(RiderIndex:Integer=0):TRiderGarmentParameters;
procedure SaveAvatarGarment(const P:TRiderGarmentParameters;RiderIndex:Integer=0);
procedure ApplyAvatarGarment(Rider:TTripoRiderScene;RiderIndex:Integer=0);
implementation
uses SysUtils, fpjson, jsonparser, GameUserData;
function AvatarGarment(RiderIndex:Integer):TRiderGarmentParameters;
var D:TJSONData;S:string;
begin
  Result:=DefaultRiderGarment(RiderGarmentSeed(AvatarBodyParameters(RiderIndex)));
  S:=RiderPreference('rider_garment','',RiderIndex);if S=''then Exit;
  D:=nil;
  try
    try
      D:=GetJSON(S);if D is TJSONObject then Result:=ReadRiderGarment(TJSONObject(D),Result);
    except on E:Exception do Exit end;
  finally D.Free end;
end;
procedure SaveAvatarGarment(const P:TRiderGarmentParameters;RiderIndex:Integer);
var O:TJSONObject;
begin
  O:=WriteRiderGarment(P);
  try SetRiderPreference('rider_garment',O.AsJSON,RiderIndex)finally O.Free end;
end;
procedure ApplyAvatarGarment(Rider:TTripoRiderScene;RiderIndex:Integer);
begin
  if(Rider<>nil)and(Rider.Garment<>nil)then Rider.Garment.ConfigureGarment(AvatarGarment(RiderIndex));
end;
end.
