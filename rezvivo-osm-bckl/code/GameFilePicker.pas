unit GameFilePicker;
{$mode objfpc}{$H+}
interface
uses Classes;
type TPickedFileEvent=procedure(const FileName:String)of object;

{ The callback receives an ordinary local filename on every platform.
  Android documents are copied asynchronously into private persistent storage. }
procedure PickGameFile(Owner:TComponent;const Title,Filters:String;
  Selected:TPickedFileEvent;const InitialUrl:String='');

implementation
uses SysUtils,CastleWindow,CastleURIUtils,UiTranslations
  {$ifdef ANDROID},CastleMessaging,CastleStringUtils{$endif};

{$ifdef ANDROID}
type
  TAndroidFilePicker=class(TComponent)
  private
    FTarget:TComponent;
    FSelected:TPickedFileEvent;
    FRequest,FCounter:QWord;
    procedure ClearTarget;
    function Receive(const Parts:TCastleStringList;const Stream:TMemoryStream):Boolean;
  protected
    procedure Notification(AComponent:TComponent;Operation:TOperation);override;
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure Open(Target:TComponent;const Title,Filters:String;Selected:TPickedFileEvent);
  end;
var Picker:TAndroidFilePicker;

constructor TAndroidFilePicker.Create(AOwner:TComponent);
begin inherited;Messaging.OnReceive.Add(@Receive) end;
destructor TAndroidFilePicker.Destroy;
begin ClearTarget;Messaging.OnReceive.Remove(@Receive);inherited end;
procedure TAndroidFilePicker.ClearTarget;
begin
  if FTarget<>nil then FTarget.RemoveFreeNotification(Self);
  FTarget:=nil;FSelected:=nil;
end;
procedure TAndroidFilePicker.Notification(AComponent:TComponent;Operation:TOperation);
begin
  inherited;
  if(Operation=opRemove)and(AComponent=FTarget)then begin FTarget:=nil;FSelected:=nil end;
end;
procedure TAndroidFilePicker.Open(Target:TComponent;const Title,Filters:String;Selected:TPickedFileEvent);
begin
  if FRequest<>0 then Exit; { Ignore double taps while DocumentsUI is open. }
  Inc(FCounter);FRequest:=FCounter;FTarget:=Target;FSelected:=Selected;
  if FTarget<>nil then FTarget.FreeNotification(Self);
  Messaging.Send(['rezvivo-file-open',IntToStr(FRequest),Title,Filters]);
end;
function TAndroidFilePicker.Receive(const Parts:TCastleStringList;const Stream:TMemoryStream):Boolean;
var Callback:TPickedFileEvent;Status,Value:String;
begin
  Result:=(Parts.Count>0)and(Parts[0]='rezvivo-file-result');
  if not Result or(Parts.Count<>4)then Exit;
  if(FRequest=0)or(Parts[1]<>IntToStr(FRequest))then Exit;
  Callback:=FSelected;Status:=Parts[2];Value:=Parts[3];
  FRequest:=0;ClearTarget;
  if not Assigned(Callback)then Exit;
  if Status='ok' then begin
    try Callback(Value);
    except on E:Exception do Application.MainWindow.MessageOK(UiText('Could not open file: ')+E.Message,mtError) end;
  end else if Status='error' then
    Application.MainWindow.MessageOK(UiText('Could not open file: ')+UiText(Value),mtError);
end;
{$endif}

procedure PickGameFile(Owner:TComponent;const Title,Filters:String;
  Selected:TPickedFileEvent;const InitialUrl:String);
{$ifndef ANDROID}var Url:String;{$endif}
begin
  {$ifdef ANDROID}
  if Picker=nil then Picker:=TAndroidFilePicker.Create(nil);
  Picker.Open(Owner,Title,Filters,Selected);
  {$else}
  Url:=InitialUrl;
  if Application.MainWindow.FileDialog(Title,Url,True,Filters)and Assigned(Selected)then
    Selected(URIToFilenameSafe(Url));
  {$endif}
end;
{$ifdef ANDROID}
finalization
  FreeAndNil(Picker);
{$endif}
end.
