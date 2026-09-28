{ Universal RTTI engine for MCP: inspect and modify any published
  property of any registered object via TypInfo (FPC 3.2.2 level RTTI).

  Supports dotted paths: 'mainviewport.camera.translation' — intermediate
  segments must be class (tkClass) properties.

  Supported leaf kinds:
    tkInteger, tkBool, tkEnumeration, tkSet, tkChar, tkWChar,
    tkInt64, tkQWord, tkFloat,
    tkSString, tkLString, tkAString, tkWString, tkUString,
    tkClass (read: class name + navigate deeper; write: not supported)
  Unsupported: tkMethod, tkVariant, tkArray, tkDynArray, tkRecord,
    tkInterface, tkPointer, tkObject, tkClassRef, tkHelper, tkFile,
    tkProcVar, tkInterfaceRaw, tkUnknown.

  IMPORTANT: call these only in the main thread (wrap with
  McpBridge.McpRunInMainThread) — property getters/setters of LCL/CGE
  objects are not thread-safe. }
unit McpRtti;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, TypInfo, fpjson;

{ Appends one JSON object per published property:
  {"name","type","kind","readable","writable","supported"} }
procedure McpDescribeObject(AObject: TObject; AProps: TJSONArray);

{ Reads property at APath, returns a new JSON value (caller frees). }
function McpGetPropJson(AObject: TObject; const APath: String): TJSONData;

{ Writes property at APath from a JSON value. Raises EMcpError on
  type mismatch / read-only / unknown property. }
procedure McpSetPropJson(AObject: TObject; const APath: String; AValue: TJSONData);

implementation

uses McpCommon;

function KindSupported(AKind: TTypeKind): Boolean;
begin
  case AKind of
    tkInteger, tkBool, tkEnumeration, tkSet, tkChar, tkWChar,
    tkInt64, tkQWord, tkFloat,
    tkSString, tkLString, tkAString, tkWString, tkUString,
    tkClass: Result := True;
  else
    Result := False;
  end;
end;

procedure McpDescribeObject(AObject: TObject; AProps: TJSONArray);
var
  Count, I: Integer;
  PL: PPropList;
  PI: PPropInfo;
  J: TJSONObject;
begin
  { FPC 3.2 GetPropList allocates the list itself and returns the count. }
  Count := GetPropList(AObject.ClassInfo, PL);
  if Count = 0 then Exit;
  try
    for I := 0 to Count - 1 do
    begin
      PI := PL^[I];
      J := TJSONObject.Create;
      J.Add('name', String(PI^.Name));
      if PI^.PropType <> nil then
        J.Add('type', String(PI^.PropType^.Name))
      else
        J.Add('type', '?');
      J.Add('kind', GetEnumName(TypeInfo(TTypeKind), Ord(PI^.PropType^.Kind)));
      J.Add('readable', PI^.GetProc <> nil);
      J.Add('writable', PI^.SetProc <> nil);
      J.Add('supported', KindSupported(PI^.PropType^.Kind));
      AProps.Add(J);
    end;
  finally
    FreeMem(PL);
  end;
end;

{ Walks all path segments except the last. Returns owner object of the
  final property; AName receives the last segment. }
function ResolveOwner(AObject: TObject; const APath: String; out AName: String): TObject;
var
  Parts: TStringList;
  I: Integer;
  PI: PPropInfo;
  Next: TObject;
begin
  Result := AObject;
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := '.';
    Parts.DelimitedText := APath;
    if Parts.Count = 0 then
      raise EMcpError.Create('Empty property path');
    for I := 0 to Parts.Count - 2 do
    begin
      PI := GetPropInfo(Result.ClassInfo, Parts[I]);
      if PI = nil then
        raise EMcpError.CreateFmt('Unknown property "%s" on %s',
          [Parts[I], Result.ClassName]);
      if PI^.PropType^.Kind <> tkClass then
        raise EMcpError.CreateFmt('Property "%s" on %s is not an object (kind %s)',
          [Parts[I], Result.ClassName,
           GetEnumName(TypeInfo(TTypeKind), Ord(PI^.PropType^.Kind))]);
      Next := TObject(GetObjectProp(Result, PI));
      if Next = nil then
        raise EMcpError.CreateFmt('Property "%s" on %s is nil',
          [Parts[I], Result.ClassName]);
      Result := Next;
    end;
    AName := Parts[Parts.Count - 1];
  finally
    Parts.Free;
  end;
end;

function PropToJson(AOwner: TObject; PI: PPropInfo): TJSONData;
var
  Sub: TObject;
  J: TJSONObject;
begin
  if PI^.GetProc = nil then
    raise EMcpError.CreateFmt('Property "%s" is write-only', [PI^.Name]);
  case PI^.PropType^.Kind of
    tkInteger:
      Result := TJSONIntegerNumber.Create(GetOrdProp(AOwner, PI));
    tkBool:
      Result := TJSONBoolean.Create(GetOrdProp(AOwner, PI) <> 0);
    tkChar, tkWChar:
      Result := TJSONString.Create(Chr(GetOrdProp(AOwner, PI)));
    tkEnumeration:
      Result := TJSONString.Create(
        GetEnumName(PI^.PropType, GetOrdProp(AOwner, PI)));
    tkSet:
      Result := TJSONString.Create(GetSetProp(AOwner, PI, True));
    tkInt64:
      Result := TJSONInt64Number.Create(GetInt64Prop(AOwner, PI));
    tkQWord:
      { FPC 3.2.2 has no GetQWordProp; GetInt64Prop handles tkQWord. }
      Result := TJSONInt64Number.Create(GetInt64Prop(AOwner, PI));
    tkFloat:
      Result := TJSONFloatNumber.Create(GetFloatProp(AOwner, PI));
    tkSString, tkLString, tkAString:
      Result := TJSONString.Create(GetStrProp(AOwner, PI));
    tkWString:
      Result := TJSONString.Create(String(GetWideStrProp(AOwner, PI)));
    tkUString:
      Result := TJSONString.Create(UTF8Encode(GetUnicodeStrProp(AOwner, PI)));
    tkClass:
      begin
        Sub := GetObjectProp(AOwner, PI);
        if Sub = nil then
          Exit(TJSONNull.Create);
        J := TJSONObject.Create;
        J.Add('_class', Sub.ClassName);
        J.Add('_note', 'Object property — navigate deeper via ' +
          String(PI^.Name) + '.<subproperty>');
        Result := J;
      end;
  else
    raise EMcpError.CreateFmt('Property "%s" has unsupported kind %s',
      [PI^.Name, GetEnumName(TypeInfo(TTypeKind), Ord(PI^.PropType^.Kind))]);
  end;
end;

function McpGetPropJson(AObject: TObject; const APath: String): TJSONData;
var
  Owner: TObject;
  Name: String;
  PI: PPropInfo;
begin
  Owner := ResolveOwner(AObject, APath, Name);
  PI := GetPropInfo(Owner.ClassInfo, Name);
  if PI = nil then
    raise EMcpError.CreateFmt('Unknown property "%s" on %s', [Name, Owner.ClassName]);
  Result := PropToJson(Owner, PI);
end;

procedure JsonToProp(AOwner: TObject; PI: PPropInfo; AValue: TJSONData);
var
  S: String;
  V: Integer;
  EnumName: String;
begin
  if PI^.SetProc = nil then
    raise EMcpError.CreateFmt('Property "%s" is read-only', [PI^.Name]);

  case PI^.PropType^.Kind of
    tkInteger, tkChar, tkWChar:
      if AValue.JSONType = jtNumber then
        SetOrdProp(AOwner, PI, AValue.AsInteger)
      else
        raise EMcpError.CreateFmt('Property "%s": expected number, got %s',
          [PI^.Name, AValue.AsJSON]);
    tkBool:
      case AValue.JSONType of
        jtBoolean: SetOrdProp(AOwner, PI, Ord(AValue.AsBoolean));
        jtNumber:  SetOrdProp(AOwner, PI, Ord(AValue.AsInteger <> 0));
      else
        raise EMcpError.CreateFmt('Property "%s": expected boolean, got %s',
          [PI^.Name, AValue.AsJSON]);
      end;
    tkEnumeration:
      begin
        { Boolean published properties are often declared as tkEnumeration
          with type name 'Boolean'. }
        EnumName := String(PI^.PropType^.Name);
        if (CompareText(EnumName, 'Boolean') = 0) and
           (AValue.JSONType in [jtBoolean, jtNumber]) then
        begin
          if AValue.JSONType = jtBoolean then
            SetOrdProp(AOwner, PI, Ord(AValue.AsBoolean))
          else
            SetOrdProp(AOwner, PI, Ord(AValue.AsInteger <> 0));
          Exit;
        end;
        if AValue.JSONType = jtString then
        begin
          S := AValue.AsString;
          V := GetEnumValue(PI^.PropType, S);
          if V < 0 then
            raise EMcpError.CreateFmt('Property "%s": "%s" is not a value of %s',
              [PI^.Name, S, EnumName]);
          SetOrdProp(AOwner, PI, V);
        end
        else if AValue.JSONType = jtNumber then
          SetOrdProp(AOwner, PI, AValue.AsInteger)
        else
          raise EMcpError.CreateFmt('Property "%s": expected enum name, got %s',
            [PI^.Name, AValue.AsJSON]);
      end;
    tkSet:
      if AValue.JSONType = jtString then
        SetSetProp(AOwner, PI, AValue.AsString)
      else
        raise EMcpError.CreateFmt('Property "%s": expected set string like "[a,b]", got %s',
          [PI^.Name, AValue.AsJSON]);
    tkInt64, tkQWord:
      if AValue.JSONType = jtNumber then
        SetInt64Prop(AOwner, PI, AValue.AsInt64)
      else
        raise EMcpError.CreateFmt('Property "%s": expected number, got %s',
          [PI^.Name, AValue.AsJSON]);
    tkFloat:
      if AValue.JSONType = jtNumber then
        SetFloatProp(AOwner, PI, AValue.AsFloat)
      else
        raise EMcpError.CreateFmt('Property "%s": expected number, got %s',
          [PI^.Name, AValue.AsJSON]);
    tkSString, tkLString, tkAString:
      if AValue.JSONType = jtString then
        SetStrProp(AOwner, PI, AValue.AsString)
      else
        raise EMcpError.CreateFmt('Property "%s": expected string, got %s',
          [PI^.Name, AValue.AsJSON]);
    tkWString:
      if AValue.JSONType = jtString then
        SetWideStrProp(AOwner, PI, WideString(AValue.AsString))
      else
        raise EMcpError.CreateFmt('Property "%s": expected string, got %s',
          [PI^.Name, AValue.AsJSON]);
    tkUString:
      if AValue.JSONType = jtString then
        SetUnicodeStrProp(AOwner, PI, UTF8Decode(AValue.AsString))
      else
        raise EMcpError.CreateFmt('Property "%s": expected string, got %s',
          [PI^.Name, AValue.AsJSON]);
  else
    raise EMcpError.CreateFmt('Property "%s": kind %s is not writable via MCP',
      [PI^.Name, GetEnumName(TypeInfo(TTypeKind), Ord(PI^.PropType^.Kind))]);
  end;
end;

procedure McpSetPropJson(AObject: TObject; const APath: String; AValue: TJSONData);
var
  Owner: TObject;
  Name: String;
  PI: PPropInfo;
begin
  Owner := ResolveOwner(AObject, APath, Name);
  PI := GetPropInfo(Owner.ClassInfo, Name);
  if PI = nil then
    raise EMcpError.CreateFmt('Unknown property "%s" on %s', [Name, Owner.ClassName]);
  JsonToProp(Owner, PI, AValue);
end;

end.
