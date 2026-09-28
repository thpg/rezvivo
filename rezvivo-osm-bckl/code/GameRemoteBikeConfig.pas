unit GameRemoteBikeConfig;
{$mode objfpc}{$H+}
interface

{ Network configs are descriptions, never file-loading instructions. This
  CPU-only boundary is shared by public relay and private rooms. Local editor
  loading deliberately keeps its full file/model support. }
function SanitizeRemoteBikeConfig(const Input:string;out Output,ErrorText:string):Boolean;

implementation
uses SysUtils,Classes,Math,fpjson,jsonparser;

procedure Require(B:Boolean);
begin if not B then raise Exception.Create('Invalid remote bike configuration');end;

procedure CheckJSONBudget(const S:string);
var I,Depth:Integer;Quoted,Escaped:Boolean;
begin
  Require((Length(S)>0)and(Length(S)<=65536));
  Depth:=0;Quoted:=False;Escaped:=False;
  for I:=1 to Length(S)do
    if Quoted then begin
      if Escaped then Escaped:=False
      else if S[I]='\'then Escaped:=True
      else if S[I]='"'then Quoted:=False;
    end else case S[I]of
      '"':Quoted:=True;
      '{','[':begin Inc(Depth);Require(Depth<=12)end;
      '}',']':begin Dec(Depth);Require(Depth>=0)end;
    end;
  Require((Depth=0)and not Quoted);
end;

procedure CheckTree(D:TJSONData);
var I:Integer;Names:TStringList;V:Double;
begin
  if D is TJSONObject then begin
    Require(D.Count<=128);
    Names:=TStringList.Create;
    try
      Names.CaseSensitive:=False;Names.Sorted:=True;
      for I:=0 to D.Count-1 do begin
        Require(Names.IndexOf(TJSONObject(D).Names[I])<0);
        Names.Add(TJSONObject(D).Names[I]);CheckTree(D.Items[I]);
      end;
    finally Names.Free end;
  end else if D is TJSONArray then begin
    Require(D.Count<=128);
    for I:=0 to D.Count-1 do CheckTree(D.Items[I]);
  end else if D.JSONType=jtNumber then begin
    V:=D.AsFloat;Require(not IsNan(V)and not IsInfinite(V)and(Abs(V)<=1.0e9));
  end;
end;

function ObjectAt(O:TJSONObject;const Key:string):TJSONObject;
var D:TJSONData;
begin
  Result:=nil;if O=nil then Exit;D:=O.Find(Key);
  if D<>nil then begin Require(D is TJSONObject);Result:=TJSONObject(D)end;
end;

procedure Numbers(Source,Dest:TJSONObject;const Keys:string;Lo,Hi:Double;Integers:Boolean=False);
var Names:TStringList;Key:string;D:TJSONData;V:Double;
begin
  if Source=nil then Exit;
  Names:=TStringList.Create;
  try
    Names.Delimiter:=',';Names.StrictDelimiter:=True;Names.DelimitedText:=Keys;
    for Key in Names do begin
      D:=Source.Find(Key);if D=nil then Continue;
      Require(D.JSONType=jtNumber);V:=D.AsFloat;
      Require(not IsNan(V)and not IsInfinite(V)and(V>=Lo)and(V<=Hi));
      if Integers then begin Require(Frac(V)=0);Dest.Add(Key,Round(V))end
      else Dest.Add(Key,V);
    end;
  finally Names.Free end;
end;

procedure Booleans(Source,Dest:TJSONObject;const Keys:string);
var Names:TStringList;Key:string;D:TJSONData;
begin
  if Source=nil then Exit;
  Names:=TStringList.Create;
  try
    Names.Delimiter:=',';Names.StrictDelimiter:=True;Names.DelimitedText:=Keys;
    for Key in Names do begin
      D:=Source.Find(Key);if D=nil then Continue;
      Require(D.JSONType=jtBoolean);Dest.Add(Key,D.AsBoolean);
    end;
  finally Names.Free end;
end;

procedure NumberArray(Source,Dest:TJSONObject;const Key:string;MaxCount:Integer;Lo,Hi:Double;Integers:Boolean=False);
var D:TJSONData;A:TJSONArray;I:Integer;V:Double;
begin
  D:=Source.Find(Key);if D=nil then Exit;
  Require((D is TJSONArray)and(D.Count<=MaxCount));A:=TJSONArray.Create;
  try
    for I:=0 to D.Count-1 do begin
      Require(D.Items[I].JSONType=jtNumber);V:=D.Items[I].AsFloat;
      Require(not IsNan(V)and not IsInfinite(V)and(V>=Lo)and(V<=Hi));
      if Integers then begin Require(Frac(V)=0);A.Add(Round(V))end else A.Add(V);
    end;
    Dest.Add(Key,A);A:=nil;
  finally A.Free end;
end;

procedure Component(const Name:string;Source,Dest:TJSONObject);
var S,O:TJSONObject;
begin
  S:=ObjectAt(Source,Name);if S=nil then Exit;
  O:=TJSONObject.Create;Dest.Add(Name,O);
  if Name='Frame'then begin
    Numbers(S,O,'SeatTubeLength,HeadTubeLength,ChainstayLength,Wheelbase,Stack,Reach,EffectiveTopTubeLength,SeatStayJctHeight',0,2000);
    Numbers(S,O,'SeatTubeAngle,HeadTubeAngle',30,100);
    Numbers(S,O,'BBDrop,TopTubeSlope',-150,150);
    Numbers(S,O,'TopTubeHTRatio,DownTubeHTRatio,TopTubeSeatRatio,SeatStayJctRatio',0,1.5);
    Numbers(S,O,'BBShellWidth,RearDropoutSpacing,FrontDropoutSpacing',20,300);
    Numbers(S,O,'DownTubeDia,SeatTubeDia,TopTubeDia,HeadTubeDia,ChainstayDia,SeatstayDia',1,150);
    Numbers(S,O,'RearTravel',0,300);
  end else if Name='Fork'then begin
    Numbers(S,O,'ForkAxleToCrown',100,1000);
    Numbers(S,O,'ForkRake,ForkTravel,HeadsetSpacer,StemLength',0,300);
    Numbers(S,O,'ForkBladeDia,ForkTipDia,StemDia',1,150);
    Numbers(S,O,'StemAngle',-85,85);
  end else if(Name='Seat')or(Name='DropBar')then begin
    Booleans(S,O,'UseModel');
    Numbers(S,O,'ModelScale',0.1,3);
    Numbers(S,O,'ModelOffsetX,ModelOffsetY,ModelOffsetZ',-500,500);
    Numbers(S,O,'ModelRotX,ModelRotY,ModelRotZ',-180,180);
    if Name='Seat'then begin
      Numbers(S,O,'SeatpostExtension',0,800);Numbers(S,O,'SaddleOffset',-300,300);
      Numbers(S,O,'SaddleLength,SaddleWidth',50,500);Numbers(S,O,'SeatpostDia',1,100);
      Booleans(S,O,'ModelHasPost,UseBoneAngle');
      O.Add('ModelURL','bike/seat.glb');O.Add('RodBone','seat_rod');
    end else begin
      Numbers(S,O,'BarWidth',200,1000);Numbers(S,O,'BarDrop,BarReach,HoodLength',1,350);
      Numbers(S,O,'HoodAngle',-90,90);Numbers(S,O,'TapeColor',-1,$FFFFFF,True);
      Booleans(S,O,'ModelHasStem');
      O.Add('ModelURL','bike/dropbar.glb');O.Add('ModelSteererBone','fork_stock');
    end;
  end else if Name='FlatBar'then begin
    Numbers(S,O,'FlatBarWidth',200,1200);Numbers(S,O,'FlatBarRise',0,300);
    Numbers(S,O,'FlatBarSweep',-85,85);Numbers(S,O,'GripColor',-1,$FFFFFF,True);
  end else if Name='Wheels'then begin
    Numbers(S,O,'WheelRadius',100,600);Numbers(S,O,'TireWidth,FrontRimHeight,RearRimHeight,HubWidth',1,250);
    Numbers(S,O,'SpokeCount',4,64,True);
  end else if Name='Crankset'then begin
    Numbers(S,O,'CrankLength',80,250);Numbers(S,O,'ChainringRadius',10,150);
    Numbers(S,O,'ChainringTeeth',10,80,True);Numbers(S,O,'QFactorHalf',30,150);
    Numbers(S,O,'PedalCenterOffset',10,100);Booleans(S,O,'UseModels');
    O.Add('ModelPathR','bike/cranks/crank_r.glb');O.Add('ModelPathL','bike/cranks/crank_l.glb');
    O.Add('CrankTexturePathR','Crank-Shimano-FC-R9200-R.png');O.Add('CrankTexturePathL','Crank-Shimano-FC-R9200-L.png');
  end else if Name='Drivetrain'then begin
    Numbers(S,O,'CassetteSprocketCount',1,13,True);Numbers(S,O,'CassetteWidth',1,80);
    NumberArray(S,O,'CassetteSprockets',13,10,150);NumberArray(S,O,'CassetteTeeth',13,5,80,True);
    O.Add('CassetteTexturePath','Cassette_Shimano_Dura_Ace.png');
  end else if Name='Animation'then begin
    Numbers(S,O,'CrankCycleInterval',0.2,10);Numbers(S,O,'RiderWeight',20,250);
    Numbers(S,O,'BikeWeight',2,60);Numbers(S,O,'DragCoefficient',0.05,2);
    Numbers(S,O,'FrontalArea',0.05,2);Numbers(S,O,'RollingResistance',0.001,0.1);
  end;
end;

function SanitizeRemoteBikeConfig(const Input:string;out Output,ErrorText:string):Boolean;
const CompNames:array[0..8]of string=('Frame','Fork','DropBar','FlatBar','Seat','Wheels','Crankset','Drivetrain','Animation');
  ColorNames:array[0..11]of string=('Frame','FrameSpec','Chrome','ChromeSpec','Dark','Tire','Seat','Tape','Spoke','Rim','RimSpec','TireSpec');
var Data:TJSONData;Root,Safe,S,O,C:TJSONObject;Name,Preset,Path,Color:string;Ch:Char;
begin
  Output:='';ErrorText:='';Result:=False;Data:=nil;Safe:=nil;
  try
    try
      CheckJSONBudget(Input);Data:=GetJSON(Input);Require(Data is TJSONObject);CheckTree(Data);
      Root:=TJSONObject(Data);Safe:=TJSONObject.Create;Safe.Add('version',2);
      S:=ObjectAt(Root,'params');Preset:='road';
      if S<>nil then begin
        Preset:=LowerCase(S.Get('Preset','road'));
        if(Preset<>'mtb')and(Preset<>'gravel')then Preset:='road';
      end;
      Safe.Add('params',TJSONObject.Create(['Preset',Preset]));
      S:=ObjectAt(Root,'colors');
      if S<>nil then begin
        O:=TJSONObject.Create;Safe.Add('colors',O);
        for Name in ColorNames do begin
          if S.Find(Name)=nil then Continue;
          Require((S.Find(Name)is TJSONArray)and(S.Find(Name).Count=3));
          NumberArray(S,O,Name,3,0,1);
        end;
      end;
      S:=ObjectAt(Root,'components');C:=TJSONObject.Create;Safe.Add('components',C);
      for Name in CompNames do Component(Name,S,C);
      S:=ObjectAt(Root,'tripoRider');
      if S<>nil then begin
        O:=TJSONObject.Create;Safe.Add('tripoRider',O);
        { Never resolve the sender's path. Only use its basename to choose one
          of the two fixed packaged avatars, including old absolute paths. }
        Path:=StringReplace(S.Get('path',''), '\','/',[rfReplaceAll]);
        Path:=Copy(Path,LastDelimiter('/',Path)+1,MaxInt);
        if SameText(Path,'FEM.glb')then O.Add('path','castle-data:/avatars/FEM.glb')
        else O.Add('path','castle-data:/avatars/MEN.glb');
        Numbers(S,O,'scale',0.5,1.5);Numbers(S,O,'yaw',-180,180);Numbers(S,O,'pedalDir',-1,1,True);
        Booleans(S,O,'showRider');Numbers(S,O,'ankleOffX,ankleOffY,ankleOffZ',-100,100);
        Numbers(S,O,'stanceHalf',0,250);Numbers(S,O,'footYawDeg',-45,45);
        Numbers(S,O,'bulk,belly',-0.5,1);Numbers(S,O,'heightScale',-0.4,0.4);
        Numbers(S,O,'legLen,armLen,shoulderWidth,pelvisWidth,torsoLen',0,1.5);
        Numbers(S,O,'roughnessK,metallicK',0,5);Numbers(S,O,'helmetPitchX',-60,60);
        if S.Find('helmetColor')<>nil then begin
          Color:=S.Get('helmetColor','');Require(Length(Color)<=7);
          for Ch in Color do Require(Ch in['#','$','0'..'9','a'..'f','A'..'F']);
          O.Add('helmetColor',Color);
        end;
      end;
      Output:=Safe.AsJSON;Result:=True;
    except
      ErrorText:='Invalid remote bike configuration';Output:='';
    end;
  finally Safe.Free;Data.Free end;
end;
end.
