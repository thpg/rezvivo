unit GameFrameStatistics;

{$mode objfpc}{$H+}

interface

const FrameSampleCapacity = 8192;

type
  TFrameSummary = record
    Count: Integer;
    Seen, Rejected: QWord;
    MeanMs, MedianMs, P95Ms, P99Ms, MaxMs, FPS, Low1FPS: Double;
  end;
  { A fixed rolling window. No allocations, sorting or logging on Add. }
  TFrameSamples = class
  private
    FValues: array[0..FrameSampleCapacity-1] of Double;
    FNext, FCount: Integer;
    FSeen, FRejected: QWord;
  public
    procedure Clear;
    procedure Add(Ms: Double);
    function Summary: TFrameSummary;
  end;

implementation

uses Math;

procedure TFrameSamples.Clear;
begin FNext:=0; FCount:=0; FSeen:=0; FRejected:=0; end;

procedure TFrameSamples.Add(Ms: Double);
begin
  if IsNan(Ms) or IsInfinite(Ms) or (Ms<=0) then
  begin Inc(FRejected); Exit; end;
  FValues[FNext]:=Ms;
  FNext:=(FNext+1) mod FrameSampleCapacity;
  if FCount<FrameSampleCapacity then Inc(FCount);
  Inc(FSeen);
end;

function TFrameSamples.Summary: TFrameSummary;
var A: array of Double; I, SlowCount: Integer; Sum, SlowSum: Double;
  procedure Sort(L,R:Integer);
  var I,J:Integer; P,T:Double;
  begin
    I:=L; J:=R; P:=A[(L+R) div 2];
    repeat
      while A[I]<P do Inc(I);
      while A[J]>P do Dec(J);
      if I<=J then begin T:=A[I];A[I]:=A[J];A[J]:=T;Inc(I);Dec(J);end;
    until I>J;
    if L<J then Sort(L,J);
    if I<R then Sort(I,R);
  end;
begin
  Result:=Default(TFrameSummary);
  Result.Count:=FCount;Result.Seen:=FSeen;Result.Rejected:=FRejected;
  if FCount=0 then Exit;
  SetLength(A,FCount);Sum:=0;
  for I:=0 to FCount-1 do begin A[I]:=FValues[I];Sum:=Sum+A[I];end;
  Sort(0,FCount-1);
  Result.MeanMs:=Sum/FCount;Result.FPS:=1000/Result.MeanMs;
  Result.MedianMs:=(A[(FCount-1) div 2]+A[FCount div 2])*0.5;
  Result.P95Ms:=A[Ceil(FCount*0.95)-1];
  Result.P99Ms:=A[Ceil(FCount*0.99)-1];Result.MaxMs:=A[FCount-1];
  SlowCount:=Max(1,Ceil(FCount*0.01));SlowSum:=0;
  for I:=FCount-SlowCount to FCount-1 do SlowSum:=SlowSum+A[I];
  Result.Low1FPS:=1000/(SlowSum/SlowCount);
end;

end.
