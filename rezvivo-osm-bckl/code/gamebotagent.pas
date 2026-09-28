{ GameBotAgent — backward compatibility.
  TBotAgent is now just TPhysicalAgent.
  Use TPhysicalAgent.SpawnOnPath + TPowerController instead. }
unit GameBotAgent;

interface

uses
  GamePhysicalAgent;

type
  TBotAgent = TPhysicalAgent;

implementation

end.
