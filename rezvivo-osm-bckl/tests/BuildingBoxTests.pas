program BuildingBoxTests;
{$mode objfpc}{$H+}
uses Osm3dOSHeap, SysUtils, Math, Windows, CastleVectors,
  Osm3dBuildingContact, Osm3dBuildingObstacleIndex;

var Index:TBuildingObstacleIndex; Count:Integer;
  OriginalMM,TrackedMM:TMemoryManager; Tracking:Boolean; Allocations:QWord;
function Alloc(Size:PtrUInt):Pointer;
begin if Tracking then Inc(Allocations);Result:=OriginalMM.GetMem(Size) end;
function AllocZero(Size:PtrUInt):Pointer;
begin if Tracking then Inc(Allocations);Result:=OriginalMM.AllocMem(Size) end;
function Realloc(var P:Pointer;Size:PtrUInt):Pointer;
begin if Tracking then Inc(Allocations);Result:=OriginalMM.ReAllocMem(P,Size) end;
procedure Check(OK:Boolean;const Msg:string);
begin Inc(Count);if not OK then raise Exception.Create(Msg) end;

procedure AddRect(X0,Z0,X1,Z1:Single;Reverse:Boolean=False;Base:Single=0);
var A:TBuildingObstacleArray;V:TVector3;
begin
  SetLength(A,1);SetLength(A[0].Footprint,4);
  A[0].Footprint[0]:=Vector3(X0,0,Z0);A[0].Footprint[1]:=Vector3(X1,0,Z0);
  A[0].Footprint[2]:=Vector3(X1,0,Z1);A[0].Footprint[3]:=Vector3(X0,0,Z1);
  if Reverse then begin V:=A[0].Footprint[1];A[0].Footprint[1]:=A[0].Footprint[3];A[0].Footprint[3]:=V end;
  A[0].BaseY:=Base;A[0].MaxY:=Base+12;RebuildObstacleAABB(A[0]);
  Index.AddObstacles(A,1);
end;

procedure TestWalls;
var Start,Target,Forward,HalfSize:TVector3;Reverse:Integer;
begin
  for Reverse:=0 to 1 do begin
    Index.Clear;AddRect(0,-20,10,20,Reverse=1);
    Forward:=Vector3(1,0,0);HalfSize:=Vector3(0.36,0.9,1);
    Start:=Vector3(-2,0,0);Target:=Vector3(-0.6,0,0);
    Check(Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'front reaches wall before centre');
    Check(Abs(Target.X+1.005)<0.001,'bicycle front clearance');
    Target:=Vector3(30,0,0);
    Check(Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'fast sweep');
    Check(Abs(Target.X+1.005)<0.001,'no tunnelling');
    Target:=Vector3(1,0,6);
    Check(Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'diagonal slide');
    Check((Target.X<=-1)and(Abs(Target.Z-6)<0.002),'slides along wall');
    Start:=Vector3(-1.005,0,0);Target:=Vector3(-3,0,0);
    Check(not Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'leave wall');
    Start:=Vector3(-1.005,0,0);Target:=Vector3(-1.005,0,3);
    Check(not Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'parallel contact');
    Start:=Vector3(-0.5,0,0);Target:=Start;
    Check(Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'existing overlap');
    Check(Target.X<=-1,'entire box recovered');
    Start:=Vector3(5,0,0);Target:=Start;
    Check(Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'centre inside');
    Check((Target.X<=-1)or(Target.X>=11),'exits either wall');
    Start:=Vector3(0,0,0);Target:=Start;
    Check(Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'centre on wall');
    Check(Target.X<=-1,'winding-independent outward normal');
    Forward:=Vector3(Sqrt(0.5),0,Sqrt(0.5));Start:=Vector3(-2,0,0);Target:=Vector3(1,0,0);
    Check(Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'rotated body');
    Check(Abs(Target.X+Sqrt(0.5)*1.36+0.005)<0.002,'rotated support');
    Forward:=Vector3(0,0,1);Start:=Vector3(-0.8,0,0);Target:=Vector3(0.5,0,0);
    Check(Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'shoulder contact');
    Check(Abs(Target.X+0.365)<0.001,'shoulder width');
    Start:=Vector3(-2,13,0);Target:=Vector3(2,13,0);
    Check(not Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'above roof');
    Start:=Vector3(-2,-3,0);Target:=Vector3(2,-3,0);
    Check(Index.ConstrainBoxMove(Start,Forward,HalfSize,Target),'foundation extends below facade base');
  end;
  Index.Clear;AddRect(0,-20,0.02,20);
  Start:=Vector3(-10,0,0);Target:=Vector3(10,0,0);
  Check(Index.ConstrainBoxMove(Start,Vector3(1,0,0),HalfSize,Target),'thin building');
  Check(Target.X<=-1,'thin building fast sweep');
  Index.Clear;AddRect(-10,0,-0.45,10);AddRect(0.45,0,10,10);
  Start:=Vector3(0,0,-2);Target:=Vector3(0,0,12);
  Check(not Index.ConstrainBoxMove(Start,Vector3(0,0,1),HalfSize,Target),'0.9 m passage remains open');
  Index.Clear;AddRect(0,0,10,10);
  Start:=Vector3(-2,0,-2);Target:=Vector3(2,0,2);
  Check(Index.ConstrainBoxMove(Start,Vector3(0,0,1),HalfSize,Target),'corner sweep');
  Check((Target.X<=-0.36)or(Target.Z<=-1),'corner stops full box');
  Index.Clear;AddRect(15,-40,70,40);
  Start:=Vector3(13,0,15.9);Target:=Vector3(30,0,16.1);
  Check(Index.ConstrainBoxMove(Start,Vector3(1,0,0),HalfSize,Target),'multi-cell footprint');
  Check((Target.X<=14)and(Abs(Target.Z-16.1)<0.001),'cell seam and slide');
  Index.Clear;AddRect(0,-20,10,20,False,420.43);
  Start:=Vector3(-2,417.5,0);Target:=Vector3(3,418,0);
  Check(Index.ConstrainBoxMove(Start,Vector3(1,0,0),HalfSize,Target),'uphill foundation contact');
  Check(Target.X<=-1,'uphill house blocks before facade elevation is reached');
end;

procedure TestConcave;
var A:TBuildingObstacleArray;P,T:TVector3;
begin
  Index.Clear;SetLength(A,1);SetLength(A[0].Footprint,6);
  A[0].Footprint[0]:=Vector3(0,0,0);A[0].Footprint[1]:=Vector3(10,0,0);
  A[0].Footprint[2]:=Vector3(10,0,3);A[0].Footprint[3]:=Vector3(3,0,3);
  A[0].Footprint[4]:=Vector3(3,0,10);A[0].Footprint[5]:=Vector3(0,0,10);
  A[0].MaxY:=10;RebuildObstacleAABB(A[0]);Index.AddObstacles(A,1);
  P:=Vector3(8,0,8);T:=Vector3(5,0,5);
  Check(not Index.ConstrainBoxMove(P,Vector3(0,0,1),Vector3(0.36,0.9,1),T),'concave courtyard free');
  T:=Vector3(1,0,1);
  Check(Index.ConstrainBoxMove(P,Vector3(0,0,1),Vector3(0.36,0.9,1),T),'concave inner corner');
  Check((T.X>=3.36)and(T.Z>=4),'no inner wall penetration');
end;

procedure Benchmark;
const N=500000;
var I,J,Mode,Kind:Integer;Start,Target,Dir,Size:TVector3;
  X,Z,Base,Top:Single;T0,T1,Frequency:Int64;Micros:Double;
begin
  Index.Clear;
  for I:=0 to 63 do for J:=0 to 63 do AddRect(I*24,J*24,I*24+12,J*24+12);
  Dir:=Vector3(1,0,0);Size:=Vector3(0.36,0.9,1);QueryPerformanceFrequency(Frequency);
  for Kind:=0 to 2 do for Mode:=0 to 1 do begin
    Allocations:=0;Tracking:=True;QueryPerformanceCounter(T0);
    for I:=0 to N-1 do begin
      Start:=Vector3((I mod 64)*24-3,0,((I div 64)mod 64)*24+6);
      if Kind=0 then Start.Z+=12;
      Target:=Start+Vector3(0.2,0,0);
      if Kind=2 then Target.X+=5;
      if Mode=0 then begin
        X:=Target.X;Z:=Target.Z;Index.TryPushOutXZ(X,Z,Base,Top);
      end else Index.ConstrainBoxMove(Start,Dir,Size,Target);
    end;
    QueryPerformanceCounter(T1);Tracking:=False;
    Micros:=(T1-T0)*1e6/Frequency/N;
    WriteLn('kind=',Kind,' box=',Mode,' us_per_query=',Micros:0:4,' allocations=',Allocations);
    Check(Allocations=0,'no hot-path allocation');
  end;
end;
begin
  GetMemoryManager(OriginalMM);TrackedMM:=OriginalMM;
  TrackedMM.GetMem:=@Alloc;TrackedMM.AllocMem:=@AllocZero;TrackedMM.ReAllocMem:=@Realloc;
  SetMemoryManager(TrackedMM);Index:=TBuildingObstacleIndex.Create;
  try TestWalls;TestConcave;Benchmark;WriteLn('BUILDING_BOX_OK checks=',Count)
  finally Index.Free;SetMemoryManager(OriginalMM) end;
end.
