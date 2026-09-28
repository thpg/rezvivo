unit GameAudioOptions;
{$mode objfpc}{$H+}
interface
type
  TAudioOption=(aoMaster,aoAmbience,aoEffects,aoWorkout,aoMenu);
  TAudioValues=array[TAudioOption]of Integer;
const
  AudioKeys:array[TAudioOption]of string=('master','ambience','effects','workout','menu');
  AudioTitles:array[TAudioOption]of string=('Master volume','Environment sounds','Bicycle sounds','Workout cues','Menu clicks');
  AudioDefaults:TAudioValues=(75,50,75,100,50);
implementation
end.
