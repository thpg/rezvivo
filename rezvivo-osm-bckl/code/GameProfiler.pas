unit GameProfiler;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, CastleTimeUtils;

const
  PROF_MAX_MARKS = 16;

type
  { Легковесный покадровый профилировщик.
    Ставим Mark('имя') между участками кода,
    в конце кадра Flush пишет одну строку в лог. }

  TFrameProfiler = class
  private
    FNames: array[0..PROF_MAX_MARKS-1] of string;
    FTimes: array[0..PROF_MAX_MARKS-1] of TTimerResult;
    FCount: Integer;
    FEnabled: Boolean;
    FFrameStart: TTimerResult;
    FAgentName: string;
  public
    constructor Create;

    { Включить/выключить. Привязать к DebugSpheresVisible. }
    property Enabled: Boolean read FEnabled write FEnabled;

    { Имя агента для лога }
    property AgentName: string read FAgentName write FAgentName;

    { Начало кадра — сбрасывает все отметки }
    procedure BeginFrame;

    { Поставить отметку времени с именем.
      Время считается от предыдущей отметки (или от BeginFrame). }
    procedure Mark(const AName: string);

    { Записать результаты в лог (одна строка) и сбросить.
      Вызывать один раз в конце кадра. }
    procedure Flush;
  end;

implementation

uses DebugLog;

constructor TFrameProfiler.Create;
begin
  inherited Create;
  FEnabled := false;
  FCount := 0;
  FAgentName := '';
end;

procedure TFrameProfiler.BeginFrame;
begin
  FCount := 0;
  if not FEnabled then Exit;
  FFrameStart := Timer;
end;

procedure TFrameProfiler.Mark(const AName: string);
begin
  if not FEnabled then Exit;
  if FCount >= PROF_MAX_MARKS then Exit;
  FNames[FCount] := AName;
  FTimes[FCount] := Timer;
  Inc(FCount);
end;

procedure TFrameProfiler.Flush;
var
  I: Integer;
  Prev: TTimerResult;
  DeltaUs, TotalUs: Single;
  S: string;
begin
  if not FEnabled then Exit;
  if FCount = 0 then Exit;

  TotalUs := TimerSeconds(FTimes[FCount-1], FFrameStart) * 1000000;

  S := Format('PROF [%s] total=%.0fus |', [FAgentName, TotalUs]);

  Prev := FFrameStart;
  for I := 0 to FCount - 1 do
  begin
    DeltaUs := TimerSeconds(FTimes[I], Prev) * 1000000;
    S := S + Format(' %s=%.0f', [FNames[I], DeltaUs]);
    Prev := FTimes[I];
  end;

  Logger.Info(S);
  FCount := 0;
end;

end.
