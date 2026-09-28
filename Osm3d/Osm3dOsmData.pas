unit Osm3dOsmData;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

{$WARN 5091 OFF}

interface

uses
  Classes,
  SysUtils,
  fgl,
  Generics.Collections,
  StrUtils,
  fpjson,
  Osm3dGeoMath,
  Osm3dOsmTagUtils,   { HashInt64 / InvariantFmt / NormalizeTagValue / ParseOSMMeters }
  jsonparser
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
,
  Osm3dIntGeo,
  CastleVectors;       { TVector3 — возврат NodePlanePos }         { DegToE7/E7ToDeg, TLatticeProjection }

type
  EOSMError = class(Exception);

  TTagMap = specialize TFPGMap<string, string>;

  { Sorted key→value with binary-search IndexOf (O(log n) per lookup). }
  TOSMTags = class
  private
    FMap: TTagMap;
    function GetCount: Integer;
    function GetKey(Index: Integer): string;
    function GetValue(Index: Integer): string;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Add(const Key, Value: string);

    function Get(const Key: string; const Default: string = ''): string;

    { LowerCase(Get(Key)) — avoids repeating the wrapping in classifiers. }
    function GetLower(const Key: string): string;

    function HasKey(const Key: string): Boolean;

    { Exact case-sensitive match (e.g. HasKeyValue('building','yes')). }
    function HasKeyValue(const Key, Value: string): Boolean;

    procedure Clear;

    property Count: Integer read GetCount;
    property Keys[I: Integer]: string read GetKey;
    property Values[I: Integer]: string read GetValue;

    { 'building=yes; height=5' — for logs/debug. }
    function ToString: string; override;
  end;

  TOSMNode = class
  public
    Id:       Int64;
    Position: TLatLon;         { каноничный Double-образ E7 (см. Create) }
    Tags:     TOSMTags;        { non-nil; owned }

    { ── int-first ядро ──────────────────────────────────────────────
      LatE7/LonE7 — ТОЧНЫЕ целые координаты (градусы·1e7, нативная
      точность OSM); единственный источник истины, Position выводится
      из них. LatticeX/Z — пер-блочный кэш мировой решётки 1/64 м
      минус целочисленный сдвиг блока; заполняется
      TOSMDataset.PrecomputeLattice, до вызова — не определён. }
    LatE7, LonE7:       Int64;
    LatticeX, LatticeZ: Int32;

    constructor Create(AId: Int64; const APos: TLatLon);
    destructor Destroy; override;
  end;

  { Closed if NodeRefs[0] = NodeRefs[High] and Length >= 4. }
  TOSMWay = class
  public
    Id:       Int64;
    NodeRefs: array of Int64;
    Tags:     TOSMTags;

    constructor Create(AId: Int64);
    destructor Destroy; override;

    function IsClosed: Boolean;
  end;

  TOSMMemberKind = (omkNode, omkWay, omkRelation);
  TOSMRelationMember = record
    Kind: TOSMMemberKind;
    Ref:  Int64;
    Role: string;
  end;

  TOSMRelation = class
  public
    Id:      Int64;
    Members: array of TOSMRelationMember;
    Tags:    TOSMTags;

    constructor Create(AId: Int64);
    destructor Destroy; override;

    function MemberCount: Integer;
  end;

  TOSMNodeMap     = specialize TObjectDictionary<Int64, TOSMNode>;
  TOSMWayMap      = specialize TObjectDictionary<Int64, TOSMWay>;
  TOSMRelationMap = specialize TObjectDictionary<Int64, TOSMRelation>;

  TOSMDataset = class
  private
    FNodes:        TOSMNodeMap;
    FWays:         TOSMWayMap;
    FRelations:    TOSMRelationMap;
    FLatticeReady: Boolean;   { PrecomputeLattice вызван — LatticeX/Z валидны }
  public
    constructor Create;
    destructor Destroy; override;

    { Transfers ownership. If Id collides, the existing entry is freed. }
    procedure AddNode(ANode: TOSMNode);
    procedure AddWay(AWay: TOSMWay);
    procedure AddRelation(ARel: TOSMRelation);

    { Nil when not found. }
    function FindNode(Id: Int64): TOSMNode;
    function FindWay(Id: Int64): TOSMWay;
    function FindRelation(Id: Int64): TOSMRelation;

    { 'N=12345, W=678, R=9'. }
    function StatsString: string;

    { ── int-first ядро ──────────────────────────────────────────────
      Заполнить пер-узловой кэш решётки: LatticeX/Z := мировые лат-
      координаты (AProj, якорь — origin СЕССИИ) минус целочисленный
      сдвиг блока ABlockOffXL/ZL (мировые лат-координаты origin блока
      через ТОТ ЖЕ AProj). Один и тот же узел в разных блоках получает
      координаты, отличающиеся ровно на целый сдвиг — плановая
      геометрия совпадает побитно. Звать один раз на блок до билдеров. }
    procedure PrecomputeLattice(AProj: TLatticeProjection;
      ABlockOffXL, ABlockOffZL: Int64);
    property LatticeReady: Boolean read FLatticeReady;

    property Nodes:     TOSMNodeMap     read FNodes;
    property Ways:      TOSMWayMap      read FWays;
    property Relations: TOSMRelationMap read FRelations;
  end;

type
  EOSMJsonError = class(EOSMError);

  TOSMJsonReader = class
  public
    { Raises EOSMJsonError on invalid JSON. }
    class procedure Parse(const JsonText: string; Dataset: TOSMDataset);
    class procedure ParseBytes(const JsonBytes: TBytes; Dataset: TOSMDataset);
  private
    class procedure ParseElement(Element: TJSONObject; Dataset: TOSMDataset);
    class procedure ParseTags(TagsObj: TJSONObject; Dest: TOSMTags);
    class procedure ParseNodeElement(Element: TJSONObject; Dataset: TOSMDataset);
    class procedure ParseWayElement(Element: TJSONObject; Dataset: TOSMDataset);
    class procedure ParseRelationElement(Element: TJSONObject; Dataset: TOSMDataset);
  end;

{ ── int-first: единая точка входа план-координат узла ────────────────
  Решётка узла (LatticeX/Z · 1/64, точная конверсия), если датасет
  прекомпьютнут; иначе — блок-локальная float-проекция (легаси-хост).
  Elevation кладётся в Y как у TLocalProjection.Project. Все билдеры
  (дороги, вода/landuse, деревья, POI, мосты) берут XZ ТОЛЬКО отсюда —
  одна целочисленная истина плана на все категории. }
function NodePlanePos(ADataset: TOSMDataset; ANode: TOSMNode;
  AProjection: TLocalProjection; AElevation: Double = 0): TVector3;

implementation

constructor TOSMTags.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1193);{$ENDIF}
  inherited Create;
  FMap := TTagMap.Create;
  FMap.Sorted := True;   { enables binary search in IndexOf }
end;

destructor TOSMTags.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1194);{$ENDIF}
  FMap.Free;
  inherited;
end;

function TOSMTags.GetCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(588);{$ENDIF}
  Result := FMap.Count;
end;

function TOSMTags.GetKey(Index: Integer): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(589);{$ENDIF}
  Result := FMap.Keys[Index];
end;

function TOSMTags.GetValue(Index: Integer): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(590);{$ENDIF}
  Result := FMap.Data[Index];
end;

procedure TOSMTags.Add(const Key, Value: string);
var
  Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(591);{$ENDIF}
  if Key = '' then Exit;
  Idx := FMap.IndexOf(Key);
  if Idx >= 0 then
    FMap.Data[Idx] := Value
  else
    FMap.Add(Key, Value);
end;

function TOSMTags.Get(const Key: string; const Default: string): string;
var
  Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(592);{$ENDIF}
  Idx := FMap.IndexOf(Key);
  if Idx < 0 then Exit(Default);
  Result := FMap.Data[Idx];
end;

function TOSMTags.GetLower(const Key: string): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(593);{$ENDIF}
  Result := LowerCase(Get(Key));
end;

function TOSMTags.HasKey(const Key: string): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(594);{$ENDIF}
  Result := FMap.IndexOf(Key) >= 0;
end;

function TOSMTags.HasKeyValue(const Key, Value: string): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(595);{$ENDIF}
  Result := SameStr(Get(Key), Value);
end;

procedure TOSMTags.Clear;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(596);{$ENDIF}
  FMap.Clear;
end;

function TOSMTags.ToString: string;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(597);{$ENDIF}
  Result := '';
  for I := 0 to FMap.Count - 1 do
  begin
    if I > 0 then Result := Result + '; ';
    Result := Result + FMap.Keys[I] + '=' + FMap.Data[I];
  end;
end;

constructor TOSMNode.Create(AId: Int64; const APos: TLatLon);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1195);{$ENDIF}
  inherited Create;
  Id       := AId;
  { Точное восстановление 7-знакового целого из Double: ошибка парса
    < 1e-6 e7-единицы << 0.5, поэтому Round точен (обоснование — шапка
    Osm3dIntGeo). Position канонизируется ИЗ int: один и тот же узел в
    любом блоке/потоке имеет побитно одинаковый Double-образ. }
  LatE7 := DegToE7(APos.Lat);
  LonE7 := DegToE7(APos.Lon);
  Position.Lat := E7ToDeg(LatE7);
  Position.Lon := E7ToDeg(LonE7);
  LatticeX := 0;
  LatticeZ := 0;
  Tags     := TOSMTags.Create;
end;

destructor TOSMNode.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1196);{$ENDIF}
  Tags.Free;
  inherited;
end;

constructor TOSMWay.Create(AId: Int64);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1197);{$ENDIF}
  inherited Create;
  Id   := AId;
  Tags := TOSMTags.Create;
end;

destructor TOSMWay.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1198);{$ENDIF}
  Tags.Free;
  inherited;
end;

function TOSMWay.IsClosed: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(598);{$ENDIF}
  Result := (Length(NodeRefs) >= 4) and
            (NodeRefs[0] = NodeRefs[High(NodeRefs)]);
end;

constructor TOSMRelation.Create(AId: Int64);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1199);{$ENDIF}
  inherited Create;
  Id   := AId;
  Tags := TOSMTags.Create;
end;

destructor TOSMRelation.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1200);{$ENDIF}
  Tags.Free;
  inherited;
end;

function TOSMRelation.MemberCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(600);{$ENDIF}
  Result := Length(Members);
end;

constructor TOSMDataset.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1201);{$ENDIF}
  inherited Create;
  FNodes     := TOSMNodeMap.Create([doOwnsValues]);
  FWays      := TOSMWayMap.Create([doOwnsValues]);
  FRelations := TOSMRelationMap.Create([doOwnsValues]);
end;

destructor TOSMDataset.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1202);{$ENDIF}
  FRelations.Free;       { relations first — they reference ways/nodes }
  FWays.Free;
  FNodes.Free;
  inherited;
end;

procedure TOSMDataset.AddNode(ANode: TOSMNode);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(601);{$ENDIF}
  FNodes.AddOrSetValue(ANode.Id, ANode);
end;

procedure TOSMDataset.AddWay(AWay: TOSMWay);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(602);{$ENDIF}
  FWays.AddOrSetValue(AWay.Id, AWay);
end;

procedure TOSMDataset.AddRelation(ARel: TOSMRelation);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(603);{$ENDIF}
  FRelations.AddOrSetValue(ARel.Id, ARel);
end;

function TOSMDataset.FindNode(Id: Int64): TOSMNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(604);{$ENDIF}
  if not FNodes.TryGetValue(Id, Result) then
    Result := nil;
end;

function TOSMDataset.FindWay(Id: Int64): TOSMWay;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(605);{$ENDIF}
  if not FWays.TryGetValue(Id, Result) then
    Result := nil;
end;

function TOSMDataset.FindRelation(Id: Int64): TOSMRelation;
begin
  if not FRelations.TryGetValue(Id, Result) then
    Result := nil;
end;

function TOSMDataset.StatsString: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(607);{$ENDIF}
  Result := Format('N=%d, W=%d, R=%d',
    [FNodes.Count, FWays.Count, FRelations.Count]);
end;

procedure TOSMDataset.PrecomputeLattice(AProj: TLatticeProjection;
  ABlockOffXL, ABlockOffZL: Int64);
var
  N: TOSMNode;
  WX, WZ: Int64;
begin
  if AProj = nil then Exit;
  for N in FNodes.Values do
  begin
    WX := AProj.XOfLonE7(N.LonE7);
    WZ := AProj.ZOfLatE7(N.LatE7);
    N.LatticeX := Int32(WX - ABlockOffXL);
    N.LatticeZ := Int32(WZ - ABlockOffZL);
  end;
  FLatticeReady := True;
end;

class procedure TOSMJsonReader.Parse(const JsonText: string; Dataset: TOSMDataset);
var
  Root: TJSONData;
  RootObj: TJSONObject;
  Elements: TJSONData;
  ElementsArr: TJSONArray;
  I: Integer;
  Item: TJSONData;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1203);{$ENDIF}
  if Dataset = nil then
    raise EOSMJsonError.Create('TOSMJsonReader.Parse: Dataset = nil');
  if Trim(JsonText) = '' then
    raise EOSMJsonError.Create('TOSMJsonReader.Parse: empty JSON');

  try
    Root := GetJSON(JsonText);
  except
    on E: Exception do
      raise EOSMJsonError.CreateFmt('TOSMJsonReader.Parse: %s', [E.Message]);
  end;

  try
    if not (Root is TJSONObject) then
      raise EOSMJsonError.Create('JSON root is not an object');
    RootObj := TJSONObject(Root);

    Elements := RootObj.Find('elements');
    if Elements = nil then
      raise EOSMJsonError.Create('Missing "elements" field in root');
    if not (Elements is TJSONArray) then
      raise EOSMJsonError.Create('"elements" is not an array');
    ElementsArr := TJSONArray(Elements);

    for I := 0 to ElementsArr.Count - 1 do
    begin
      Item := ElementsArr.Items[I];
      if Item is TJSONObject then
        ParseElement(TJSONObject(Item), Dataset);
    end;
  finally
    Root.Free;
  end;
end;

class procedure TOSMJsonReader.ParseBytes(const JsonBytes: TBytes; Dataset: TOSMDataset);
var
  S: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1204);{$ENDIF}
  if Length(JsonBytes) = 0 then
    raise EOSMJsonError.Create('ParseBytes: empty array');
  SetLength(S, Length(JsonBytes));
  Move(JsonBytes[0], S[1], Length(JsonBytes));
  Parse(S, Dataset);
end;

class procedure TOSMJsonReader.ParseElement(Element: TJSONObject; Dataset: TOSMDataset);
var
  ElType: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1208);{$ENDIF}
  ElType := Element.Get('type', '');
  if ElType = 'node' then
    ParseNodeElement(Element, Dataset)
  else if ElType = 'way' then
    ParseWayElement(Element, Dataset)
  else if ElType = 'relation' then
    ParseRelationElement(Element, Dataset);
end;

class procedure TOSMJsonReader.ParseTags(TagsObj: TJSONObject; Dest: TOSMTags);
var
  I: Integer;
  Key, Val: string;
  Item: TJSONData;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1209);{$ENDIF}
  if TagsObj = nil then Exit;
  for I := 0 to TagsObj.Count - 1 do
  begin
    Key := TagsObj.Names[I];
    Item := TagsObj.Items[I];
    if Item.JSONType in [jtString, jtNumber, jtBoolean] then
      Val := Item.AsString
    else
      Continue;
    Dest.Add(Key, Val);
  end;
end;

class procedure TOSMJsonReader.ParseNodeElement(Element: TJSONObject;
  Dataset: TOSMDataset);
var
  Id: Int64;
  Pos: TLatLon;
  Node: TOSMNode;
  TagsData: TJSONData;
  LatData, LonData: TJSONData;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1210);{$ENDIF}
  Id := Element.Get('id', Int64(0));
  if Id = 0 then Exit;

  LatData := Element.Find('lat');
  LonData := Element.Find('lon');
  if (LatData = nil) or (LonData = nil) then Exit;

  Pos.Lat := LatData.AsFloat;
  Pos.Lon := LonData.AsFloat;

  Node := TOSMNode.Create(Id, Pos);
  TagsData := Element.Find('tags');
  if (TagsData <> nil) and (TagsData is TJSONObject) then
    ParseTags(TJSONObject(TagsData), Node.Tags);
  Dataset.AddNode(Node);
end;

class procedure TOSMJsonReader.ParseWayElement(Element: TJSONObject;
  Dataset: TOSMDataset);
var
  Id: Int64;
  Way: TOSMWay;
  NodesData: TJSONData;
  NodesArr: TJSONArray;
  TagsData: TJSONData;
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1211);{$ENDIF}
  Id := Element.Get('id', Int64(0));
  if Id = 0 then Exit;

  Way := TOSMWay.Create(Id);
  try
    NodesData := Element.Find('nodes');
    if (NodesData <> nil) and (NodesData is TJSONArray) then
    begin
      NodesArr := TJSONArray(NodesData);
      SetLength(Way.NodeRefs, NodesArr.Count);
      for I := 0 to NodesArr.Count - 1 do
        Way.NodeRefs[I] := NodesArr.Items[I].AsInt64;
    end;

    TagsData := Element.Find('tags');
    if (TagsData <> nil) and (TagsData is TJSONObject) then
      ParseTags(TJSONObject(TagsData), Way.Tags);

    Dataset.AddWay(Way);
  except
    Way.Free;
    raise;
  end;
end;

class procedure TOSMJsonReader.ParseRelationElement(Element: TJSONObject;
  Dataset: TOSMDataset);
var
  Id: Int64;
  Rel: TOSMRelation;
  MembersData: TJSONData;
  MembersArr: TJSONArray;
  TagsData: TJSONData;
  I: Integer;
  MemberN: Integer;
  MemberObj: TJSONObject;
  Member: TOSMRelationMember;
  MemberType: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1212);{$ENDIF}
  Id := Element.Get('id', Int64(0));
  if Id = 0 then Exit;

  Rel := TOSMRelation.Create(Id);
  try
    MembersData := Element.Find('members');
    if (MembersData <> nil) and (MembersData is TJSONArray) then
    begin
      MembersArr := TJSONArray(MembersData);
      SetLength(Rel.Members, MembersArr.Count);
      { Запись идёт через отдельный курсор: пропущенные (не-объект / иной
        type) члены НЕ оставляют за собой нулевую запись omkNode/Ref=0,
        которую потребители иначе читали как фантомный node-member. }
      MemberN := 0;
      for I := 0 to MembersArr.Count - 1 do
      begin
        if not (MembersArr.Items[I] is TJSONObject) then Continue;
        MemberObj := TJSONObject(MembersArr.Items[I]);
        MemberType := MemberObj.Get('type', '');
        case MemberType of
          'node':     Member.Kind := omkNode;
          'way':      Member.Kind := omkWay;
          'relation': Member.Kind := omkRelation;
        else
          Continue;
        end;
        Member.Ref  := MemberObj.Get('ref', Int64(0));
        Member.Role := MemberObj.Get('role', '');
        Rel.Members[MemberN] := Member;
        Inc(MemberN);
      end;
      SetLength(Rel.Members, MemberN);
    end;

    TagsData := Element.Find('tags');
    if (TagsData <> nil) and (TagsData is TJSONObject) then
      ParseTags(TJSONObject(TagsData), Rel.Tags);

    Dataset.AddRelation(Rel);
  except
    Rel.Free;
    raise;
  end;
end;

function NodePlanePos(ADataset: TOSMDataset; ANode: TOSMNode;
  AProjection: TLocalProjection; AElevation: Double): TVector3;
begin
  if (ADataset <> nil) and ADataset.LatticeReady then
  begin
    Result.X := ANode.LatticeX * (1.0 / 64.0);
    Result.Y := AElevation;
    Result.Z := ANode.LatticeZ * (1.0 / 64.0);
  end
  else
    Result := AProjection.Project(ANode.Position, AElevation);
end;

end.
