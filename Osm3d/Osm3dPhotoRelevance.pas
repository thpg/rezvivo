unit Osm3dPhotoRelevance;
{$mode objfpc}{$H+}{$codepage UTF8}

{ One conservative source-review policy for acquisition, gallery and recipes.
  Metadata can reject a clearly unrelated subject; it never claims that an
  image has been seen, proves a planting position, or accepts unknown content.
  Explicit human/agent visual review has precedence over automatic rules. }
interface
uses SysUtils,Classes,fpjson;
function EffectivePhotoReviewStatus(Source:TJSONObject):string;
function PhotoSourceRejected(Source:TJSONObject):Boolean;
function PhotoAcquisitionAllowed(Photo:TJSONObject):Boolean;
procedure ApplyAutomaticPhotoReview(Photo:TJSONObject);
procedure ApplyPhotoReviews(Photo:TJSONObject;Reviews:TJSONArray);

implementation
function TextAt(J:TJSONObject;const Field:string):string;
var V:TJSONData;
begin
  Result:='';if J=nil then Exit;V:=J.Find(Field);
  if (V<>nil) and (V.JSONType=jtString) then Result:=V.AsString;
end;

function Fold(const S:string):string;
var U:UnicodeString;I:Integer;C:Word;
begin
  U:=UTF8Decode(S);
  for I:=1 to Length(U) do begin
    C:=Ord(U[I]);
    if ((C>=Ord('A')) and (C<=Ord('Z'))) or ((C>=$0410) and (C<=$042F)) then
      U[I]:=WideChar(C+32)
    else if C=$0401 then U[I]:=WideChar($0451);
  end;
  Result:=UTF8Encode(U);
end;

function HasAny(const S:string;const Terms:array of string):Boolean;
var I:Integer;
begin
  for I:=0 to High(Terms) do if Pos(Terms[I],S)>0 then Exit(True);
  Result:=False;
end;

function StrongMetadataReason(Source:TJSONObject):string;
var Basis,Subject,Context,Title,Description,Categories,Combined:string;
begin
  Result:='';if Source=nil then Exit;
  Basis:=UpperCase(TextAt(Source,'basis_of_record'));
  Basis:=StringReplace(StringReplace(StringReplace(Basis,'_','',[rfReplaceAll]),
    '-','',[rfReplaceAll]),' ','',[rfReplaceAll]);
  if Basis='' then begin
    Basis:=UpperCase(TextAt(Source,'basisOfRecord'));
    Basis:=StringReplace(StringReplace(StringReplace(Basis,'_','',[rfReplaceAll]),
      '-','',[rfReplaceAll]),' ','',[rfReplaceAll]);
  end;
  if (Basis='PRESERVEDSPECIMEN') or (Basis='FOSSILSPECIMEN') or (Basis='MATERIALSAMPLE') then
    Exit('preserved_specimen');
  Subject:=Fold(TextAt(Source,'subject_type'));Context:=Fold(TextAt(Source,'photo_context'));
  if (Subject='herbarium_sheet') or (Subject='preserved_specimen') then Exit('preserved_specimen');
  if (Subject='museum_object') or (Context='museum_object') then Exit('museum_object');
  if (Subject='portrait') or (Context='studio_portrait') then Exit('portrait');
  Title:=Fold(TextAt(Source,'title'));Description:=Fold(TextAt(Source,'description'));
  Categories:=Fold(TextAt(Source,'categories'));
  Combined:=Title+' '+Description+' '+Categories;
  { Text can discuss the collection inside a building. Such ambiguous exterior
    descriptions need visual review; decisive structured specimen fields above
    still win. }
  if HasAny(Title+' '+Description,['facade','façade','exterior','entrance','building',
    'mural','monument','memorial','statue','sculpture','plaque','фасад','здание',
    'памятник','скульптур','мемориал','доска']) then Exit;
  if HasAny(Combined,['herbarium sheet','herbarium specimen','herbarbeleg',
    'dried plant specimen','preserved specimen','гербарный лист','гербарный образец']) then
    Exit('preserved_specimen');
  if HasAny(Combined,['museum object photograph','museum specimen','taxidermy specimen',
    'microscope slide','музейный предмет','музейный образец']) then Exit('museum_object');
  if HasAny(Combined,['studio portrait','passport photograph','portrait photograph',
    'photographic portrait','headshot of','студийный портрет','фото на паспорт']) or
    (Pos('portrait of ',Title)=1) or (Pos('file:portrait of ',Title)=1) then Exit('portrait');
end;

function EffectivePhotoReviewStatus(Source:TJSONObject):string;
var Status:string;
begin
  Status:=TextAt(Source,'review_status');
  if Status='rejected' then Exit(Status);
  if (Status='accepted') and (TextAt(Source,'review_origin')<>'automatic') then Exit(Status);
  if StrongMetadataReason(Source)<>'' then Exit('rejected');
  Result:='unreviewed';
end;

function PhotoSourceRejected(Source:TJSONObject):Boolean;
begin Result:=EffectivePhotoReviewStatus(Source)='rejected' end;
function PhotoAcquisitionAllowed(Photo:TJSONObject):Boolean;
begin Result:=(Photo<>nil) and not PhotoSourceRejected(Photo) end;

procedure ApplyAutomaticPhotoReview(Photo:TJSONObject);
var Status,Reason,Note:string;
begin
  if Photo=nil then Exit;
  Status:=TextAt(Photo,'review_status');
  if (Status='rejected') or ((Status='accepted') and
    (TextAt(Photo,'review_origin')<>'automatic')) then Exit;
  Reason:=StrongMetadataReason(Photo);
  if Reason='' then begin
    if (Status='') or (TextAt(Photo,'review_origin')='automatic') then
      Photo.Strings['review_status']:='unreviewed';
    Exit;
  end;
  if Reason='preserved_specimen' then
    Note:='Metadata identifies a preserved or collected specimen, not the appearance of this place.'
  else if Reason='museum_object' then
    Note:='Metadata identifies an isolated museum or laboratory object, not this outdoor scene.'
  else Note:='Metadata identifies a portrait rather than evidence of the surrounding place.';
  Photo.Strings['review_status']:='rejected';Photo.Strings['review_reason']:=Reason;
  Photo.Strings['review_note']:=Note;Photo.Strings['review_origin']:='automatic';
end;

function SamePhoto(A,B:TJSONObject):Boolean;
var IdA,IdB,Provider:string;
begin
  IdA:=TextAt(A,'id');IdB:=TextAt(B,'id');
  if (IdA<>'') and (IdA=IdB) then Exit(True);
  if (TextAt(A,'kind')='video_frame') or (TextAt(B,'kind')='video_frame') or
    (A.Find('time_s')<>nil) or (B.Find('time_s')<>nil) then Exit(False);
  Provider:=TextAt(A,'provider');
  if (Provider='') or (Provider<>TextAt(B,'provider')) then Exit(False);
  IdA:=TextAt(A,'media_id');if IdA='' then IdA:=TextAt(A,'image_id');
  IdB:=TextAt(B,'media_id');if IdB='' then IdB:=TextAt(B,'image_id');
  Result:=(IdA<>'') and (IdA=IdB);
end;

procedure CopyReview(Photo,Review:TJSONObject);
const Fields:array[0..3] of string=('review_status','review_reason','review_note','review_origin');
var I:Integer;V:TJSONData;
begin
  for I:=0 to High(Fields) do begin
    Photo.Delete(Fields[I]);V:=Review.Find(Fields[I]);
    if V<>nil then Photo.Add(Fields[I],V.Clone);
  end;
end;

procedure ApplyPhotoReviews(Photo:TJSONObject;Reviews:TJSONArray);
var I:Integer;R,Automatic:TJSONObject;S:string;
begin
  if Photo=nil then Exit;Automatic:=nil;
  { Callers order reviews by ownership: current tile, then neighboring tiles.
    Explicit decisions override automatic metadata and derived-cache flags. }
  if Reviews<>nil then for I:=0 to Reviews.Count-1 do begin
    if not (Reviews[I] is TJSONObject) then Continue;R:=TJSONObject(Reviews[I]);
    if not SamePhoto(Photo,R) then Continue;S:=TextAt(R,'review_status');
    if (S<>'accepted') and (S<>'rejected') then Continue;
    if TextAt(R,'review_origin')<>'automatic' then begin CopyReview(Photo,R);Exit end;
    if (Automatic=nil) and (S='rejected') then Automatic:=R;
  end;
  S:=TextAt(Photo,'review_status');
  if ((S='accepted') or (S='rejected')) and (TextAt(Photo,'review_origin')<>'automatic') then Exit;
  if Automatic<>nil then CopyReview(Photo,Automatic);
  ApplyAutomaticPhotoReview(Photo);
end;
end.
