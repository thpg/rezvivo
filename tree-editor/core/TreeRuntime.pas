unit TreeRuntime;
{$mode objfpc}{$H+}
interface
uses TreeModel;
type
  { CPU-only lazy cache. One owner at a time; Configure/EnsureDetail may run on
    a worker. Publish Data to the render thread only after generation completes. }
  TProceduralTree = class
  private
    FInstance: TTreeInstance;
    FProfile: TTreeParams;
    FData: TTreeData;
    FDepth,FGenerationCount: Integer;
    FHasLeaves,FConfigured: Boolean;
    FLastBuildMS: QWord;
  public
    procedure Configure(const Instance: TTreeInstance; const Profile: TTreeParams);
    function EnsureDetail(Quality: Single): Boolean;
    procedure EvictDetail;
    property Data: TTreeData read FData;
    property GenerationCount: Integer read FGenerationCount;
    property LastBuildMS: QWord read FLastBuildMS;
    property CachedDepth: Integer read FDepth;
  end;
implementation
uses SysUtils, Math, TreeMath;
procedure TProceduralTree.Configure(const Instance: TTreeInstance; const Profile: TTreeParams);
begin
  SeedForTree(Instance); ValidateTreeParams(Profile);
  if Instance.Species<>Profile.Species then raise EArgumentException.Create('Instance type and profile differ');
  FInstance:=Instance; FProfile:=Profile; FConfigured:=True; EvictDetail;
end;
procedure TProceduralTree.EvictDetail;
begin FData:=Default(TTreeData); FDepth:=0; FHasLeaves:=False; FLastBuildMS:=0; end;
function TProceduralTree.EnsureDetail(Quality: Single): Boolean;
var Depth: Integer; Leaves: Boolean; Started: QWord; NewData: TTreeData;
begin
  if not FConfigured then raise EInvalidOpException.Create('Configure tree before requesting detail');
  if IsNan(Quality) or IsInfinite(Quality) then raise EArgumentException.Create('Invalid LOD quality');
  Result:=False;
  { Distant trees never allocate a hierarchy or a leaf array. }
  if Quality<=0.35 then Exit;
  Quality:=Clamp(Quality,0,4);
  Depth:=Min(FProfile.MaxDepth,Max(1,Ceil((Quality-0.2)/0.8)));
  Leaves:=((Quality>3.4) or (FProfile.Species in [tsBamboo,tsPalm,tsFanPalm])) and
    (FProfile.LeafDensity>0);
  if (Depth<=FDepth) and (not Leaves or FHasLeaves) then Exit;
  Started:=GetTickCount64;
  NewData:=GenerateTreeAt(FInstance,FProfile,Max(Depth,FDepth),Leaves or FHasLeaves);
  FData:=NewData; FDepth:=Max(Depth,FDepth); FHasLeaves:=Leaves or FHasLeaves;
  FLastBuildMS:=GetTickCount64-Started; Inc(FGenerationCount); Result:=True;
end;
end.
