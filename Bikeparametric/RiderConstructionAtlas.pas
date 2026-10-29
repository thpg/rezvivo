unit RiderConstructionAtlas;
{$mode objfpc}{$H+}
interface
uses X3DNodes;
function CreateRiderConstructionTexture:TImageTextureNode;
function CreateRiderMasterLimbTexture:TImageTextureNode;
implementation
uses Classes,SysUtils,CastleImages;
{$I RiderConstructionData.inc}
{$I RiderLimbMasterData.inc}
var Atlas,LimbAtlas:TCastleImage;
function CreateDataTexture(var Image:TCastleImage;const Data:array of Byte;const Key:string;MipMaps:Boolean):TImageTextureNode;
var Stream:TMemoryStream;Props:TTexturePropertiesNode;
begin
  if Image=nil then begin
    Stream:=TMemoryStream.Create;
    try
      Stream.WriteBuffer(Data[0],Length(Data));Stream.Position:=0;
      Image:=LoadImage(Stream,'image/png',[]);
    finally Stream.Free end;
  end;
  Result:=TImageTextureNode.Create;
  try
    Props:=TTexturePropertiesNode.Create;Props.GUITexture:=True;
    Props.GenerateMipMaps:=MipMaps;
    if MipMaps then Props.FdMinificationFilter.Value:='AVG_PIXEL_AVG_MIPMAP'
    else Props.FdMinificationFilter.Value:='AVG_PIXEL';
    Props.FdMagnificationFilter.Value:='AVG_PIXEL';Result.FdTextureProperties.Value:=Props;
    Result.RepeatS:=True;Result.RepeatT:=False;
    Result.LoadFromImage(Image,False,'castle-internal:/rider/'+Key);
  except Result.Free;raise end;
end;
function CreateRiderConstructionTexture:TImageTextureNode;
begin Result:=CreateDataTexture(Atlas,RiderConstructionPng,'construction-v1',True)end;
function CreateRiderMasterLimbTexture:TImageTextureNode;
begin Result:=CreateDataTexture(LimbAtlas,RiderLimbMasterPng,'limb-master-v1',False)end;
finalization
  FreeAndNil(Atlas);FreeAndNil(LimbAtlas);
end.
