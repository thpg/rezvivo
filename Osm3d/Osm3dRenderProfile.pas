unit Osm3dRenderProfile;

{$I castleconf.inc}

interface

type
  TOsmRenderProfile = (orpFull, orpUniversal);

const
  { Mobile and explicit GLES builds never enter desktop GL passes, even if
    a settings file was copied from a desktop installation. }
  FullRendererSupported = {$ifdef OpenGLES}False{$else}True{$endif};

function UniversalRenderer: Boolean; inline;
procedure SetRenderProfile(const Value: TOsmRenderProfile);
function RenderProfile: TOsmRenderProfile;
function RenderProfileRevision: Cardinal;

implementation

var
  Current: TOsmRenderProfile = {$ifdef OpenGLES}orpUniversal{$else}orpFull{$endif};
  Revision: Cardinal = 1;

function UniversalRenderer: Boolean;
begin Result := Current = orpUniversal; end;

procedure SetRenderProfile(const Value: TOsmRenderProfile);
var Effective: TOsmRenderProfile;
begin
  Effective := Value;
  if not FullRendererSupported then Effective := orpUniversal;
  if Current = Effective then Exit;
  Current := Effective;
  Inc(Revision);
end;

function RenderProfile: TOsmRenderProfile;
begin Result := Current; end;

function RenderProfileRevision: Cardinal;
begin Result := Revision; end;

end.
