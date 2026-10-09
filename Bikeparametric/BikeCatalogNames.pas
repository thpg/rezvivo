unit BikeCatalogNames;
{$mode objfpc}{$H+}
interface

{ Display names only. Catalog filenames, geometry and saved bike IDs stay stable. }
function BikeBrandDisplayName(const Brand: string): string;
function BikeCatalogDisplayName(const FileName: string): string;

implementation
uses SysUtils;
type TBrandAlias = record Original, Fictional: string; end;
const
  Brands: array[0..40] of TBrandAlias = (
    (Original:'3T Cycling'; Fictional:'3V Cycling'),
    (Original:'Allied Cycle Works'; Fictional:'Allyd Cycle Works'),
    (Original:'Argon 18'; Fictional:'Argen 19'),
    (Original:'Bianchi'; Fictional:'Bianco'),
    (Original:'BMC Switzerland'; Fictional:'BMXC Alpine'),
    (Original:'Cannondale Bikes'; Fictional:'Cannondell'),
    (Original:'Canyon Bicycles'; Fictional:'Canyor'),
    (Original:'Cervelo Cycles'; Fictional:'Cervalo'),
    (Original:'CHAPTER2'; Fictional:'CHAPTER3'),
    (Original:'Colnago'; Fictional:'Colnaro'),
    (Original:'CUBE Bikes'; Fictional:'CUBIQ'),
    (Original:'De Rosa'; Fictional:'De Rossa'),
    (Original:'Enve'; Fictional:'Enva'),
    (Original:'Factor Bikes'; Fictional:'Faktor'),
    (Original:'Felt Bicycles'; Fictional:'Felto'),
    (Original:'FOCUS Bikes'; Fictional:'FOKUS'),
    (Original:'Giant Bicycles'; Fictional:'Gigant'),
    (Original:'Lapierre'; Fictional:'Lapierra'),
    (Original:'Liv Cycling'; Fictional:'Liva'),
    (Original:'LOOK Cycle'; Fictional:'LOOQ'),
    (Original:'Merida Bikes'; Fictional:'Meridia'),
    (Original:'Moots Cycles'; Fictional:'Mootz'),
    (Original:'OPEN Cycle'; Fictional:'OPN'),
    (Original:'Orbea'; Fictional:'Orvea'),
    (Original:'Parlee Cycles'; Fictional:'Parley'),
    (Original:'Pinarello'; Fictional:'Pinarollo'),
    (Original:'Polygon'; Fictional:'Poligon'),
    (Original:'Ribble Cycles'; Fictional:'Ribbel'),
    (Original:'Ridley Bikes'; Fictional:'Ridlee'),
    (Original:'ROSE Bikes'; Fictional:'ROSA'),
    (Original:'Salsa Cycles'; Fictional:'Salza'),
    (Original:'Santa Cruz Bicycles'; Fictional:'Santa Crux'),
    (Original:'SCOTT Sports'; Fictional:'SKOTT'),
    (Original:'Specialized Bicycles'; Fictional:'Specialis'),
    (Original:'TIME'; Fictional:'TYME'),
    (Original:'Trek Bikes'; Fictional:'Trekk'),
    (Original:'Van Rysel'; Fictional:'Van Rysen'),
    (Original:'Wilier Triestina'; Fictional:'Willier Triestano'),
    (Original:'Winspace Cycle Co'; Fictional:'Windspace'),
    (Original:'Yeti Cycles'; Fictional:'Yetto'),
    (Original:'Yoeleo'; Fictional:'Yoleo')
  );

function BikeBrandDisplayName(const Brand: string): string;
var I: Integer;
begin
  for I := Low(Brands) to High(Brands) do
    if SameText(Trim(Brand), Brands[I].Original) then Exit(Brands[I].Fictional);
  Result := Brand;
end;

function BikeCatalogDisplayName(const FileName: string): string;
var Stem, Prefix: string; I: Integer;
begin
  Stem := ChangeFileExt(ExtractFileName(FileName), '');
  if SameText(Stem,'rezvivo-trail-mtb') then Exit('REZVIVO Trail MTB');
  if SameText(Stem,'rezvivo-track-fixed') then Exit('REZVIVO Track Fixed');
  for I := Low(Brands) to High(Brands) do
  begin
    Prefix := LowerCase(StringReplace(Brands[I].Original, ' ', '-', [rfReplaceAll])) + '-';
    if SameText(Copy(Stem, 1, Length(Prefix)), Prefix) then
      Exit(Brands[I].Fictional + ' ' + StringReplace(
        Copy(Stem, Length(Prefix)+1, MaxInt), '-', ' ', [rfReplaceAll]));
  end;
  Result := Trim(StringReplace(Stem, '-', ' ', [rfReplaceAll]));
  if Result = '' then Result := ExtractFileName(FileName);
end;
end.
