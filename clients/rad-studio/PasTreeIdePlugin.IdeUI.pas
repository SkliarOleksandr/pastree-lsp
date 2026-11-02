unit PasTreeIdePlugin.IdeUI;

{
  The IDE's themed dialogs and accent palette, behind one seam.

  INTAIDEUIServices (unit ToolsAPI.UI) is a Delphi 12 addition: it is where
  the IDE hands out its theme-aware accent colors and its own MessageDlg /
  InputQuery, which come up in the IDE's theme rather than in VCL's light
  default. Delphi 11 has neither the unit nor the interface, and a `uses`
  clause cannot be made conditional on a Declared() test - the unit has to be
  named before anything in it can be declared. So the version test lives here
  and nowhere else: this is the only unit that names ToolsAPI.UI, and it does
  so under CompilerVersion, which is 36.0 for Delphi 12 and 35.0 for 11.

  ON DELPHI 11 THE PALETTE IS OURS. ThemeAwareColors is three fixed tables in
  designide370.bpl's TIDEThemePalette - Generic, Dark, Light, each in
  TIdeAccent's order - and they are copied here, the table picked as the IDE
  would: Dark when the IDE's style paints a dark window, Light when it paints
  a light one, Generic with IDE theming off. Until 0.78.1 11 had no accents
  at all and every result row in Messages was the plain text colour - file
  names and numbers included (Alex, 2026-11-02, next to the same search in
  13). The dialogs are still Vcl.Dialogs' there - light inside a dark IDE,
  the very thing the switch to INTAIDEUIServices fixed on 12 (user,
  2026-08-31). That is a known cost of running on 11, not a bug to hunt.

  TIdeAccent duplicates the order of ToolsAPI.UI.TIDEThemeColors ON PURPOSE:
  a type alias would not re-export the enum's constants, and every caller
  would then need ToolsAPI.UI in scope for `itcBlue`, which is exactly what
  this unit exists to avoid. The Ord() cast in IdeThemeColor depends on the
  two orders staying equal.
}

interface

uses
  System.UITypes, Vcl.Graphics;

type
  /// <summary>
  /// The IDE palette, in ToolsAPI.UI.TIDEThemeColors' order.
  /// </summary>
  TIdeAccent = (itcBlue, itcRed, itcYellow, itcGreen, itcViolet, itcGray,
    itcOrange);

/// <summary>
/// True when theme-aware accents are available: the IDE's on Delphi 12 and
/// newer when the service answered, our copy of its palette on 11. Callers
/// that have no sensible fallback color of their own use this to keep the
/// canvas's prepared color instead.
/// </summary>
function HaveIdeAccents: Boolean;

/// <summary>
/// The IDE's theme-aware accent, or AFallback where the IDE has none.
/// </summary>
function IdeThemeColor(AAccent: TIdeAccent; AFallback: TColor): TColor;

/// <summary>
/// The IDE's own message box where it has one, Vcl.Dialogs.MessageDlg where
/// it has not.
/// </summary>
function IdeMessageDlg(const AMsg: string; ADlgType: TMsgDlgType;
  AButtons: TMsgDlgButtons): Integer;

/// <summary>
/// The IDE's own single-line prompt where it has one, Vcl.Dialogs.InputQuery
/// where it has not.
/// </summary>
function IdeInputQuery(const ACaption, APrompt: string;
  var AValue: string): Boolean;

implementation

uses
  Vcl.Dialogs, System.SysUtils, ToolsAPI
{$IF CompilerVersion >= 36}
  , ToolsAPI.UI
{$ELSE}
  , Winapi.Windows, Vcl.Themes
{$IFEND}
  ;

{$IF CompilerVersion >= 36}
function TryUI(out AUI: INTAIDEUIServices): Boolean;
begin
  Result := Supports(BorlandIDEServices, INTAIDEUIServices, AUI);
end;
{$ELSE}
type
  TIdePalette = (ipGeneric, ipDark, ipLight);

const
  // designide370.bpl's TIDEThemePalette, read off the binary (2026-09-26):
  // what INTAIDEUIServices.ThemeAwareColors answers on 12 and 13.
  cPalette: array[TIdePalette, TIdeAccent] of TColor = (
    ($B2783D, $324CCB, $64B5E8, $7D9F4D, $9F528A, $787878, $008CFF),
    ($DFB68C, $5870E3, $64B5E8, $A1BC78, $FFAA7F, $787878, $008CFF),
    ($844A0E, $01177E, $28495E, $4B6E18, $9F528A, $454545, $008CFF));

{ Which table the IDE would answer from: its style's window colour decides
  dark or light; with IDE theming off there is no theme, and 12 answers
  Generic. }
function ActivePalette: TIdePalette;
var
  LTheming: IOTAIDEThemingServices250;
  LRgb: Cardinal;
begin
  Result := ipGeneric;
  if not Supports(BorlandIDEServices, IOTAIDEThemingServices250, LTheming) or
     not LTheming.IDEThemingEnabled or (LTheming.StyleServices = nil) then
    Exit;
  LRgb := ColorToRGB(LTheming.StyleServices.GetSystemColor(clWindow));
  if (2 * GetRValue(LRgb) + 5 * GetGValue(LRgb) + GetBValue(LRgb)) div 8 < 128 then
    Result := ipDark
  else
    Result := ipLight;
end;
{$IFEND}

function HaveIdeAccents: Boolean;
{$IF CompilerVersion >= 36}
var
  LUI: INTAIDEUIServices;
begin
  Result := TryUI(LUI);
end;
{$ELSE}
begin
  Result := True;
end;
{$IFEND}

function IdeThemeColor(AAccent: TIdeAccent; AFallback: TColor): TColor;
{$IF CompilerVersion >= 36}
var
  LUI: INTAIDEUIServices;
begin
  if TryUI(LUI) then
    Result := LUI.ThemeAwareColors[TIDEThemeColors(Ord(AAccent))]
  else
    Result := AFallback;
end;
{$ELSE}
begin
  Result := cPalette[ActivePalette, AAccent];
end;
{$IFEND}

function IdeMessageDlg(const AMsg: string; ADlgType: TMsgDlgType;
  AButtons: TMsgDlgButtons): Integer;
{$IF CompilerVersion >= 36}
var
  LUI: INTAIDEUIServices;
begin
  if TryUI(LUI) then
    Result := LUI.MessageDlg(AMsg, ADlgType, AButtons, -1)
  else
    Result := Vcl.Dialogs.MessageDlg(AMsg, ADlgType, AButtons, -1);
end;
{$ELSE}
begin
  Result := Vcl.Dialogs.MessageDlg(AMsg, ADlgType, AButtons, -1);
end;
{$IFEND}

function IdeInputQuery(const ACaption, APrompt: string;
  var AValue: string): Boolean;
{$IF CompilerVersion >= 36}
var
  LUI: INTAIDEUIServices;
begin
  if TryUI(LUI) then
    Result := LUI.InputQuery(ACaption, APrompt, AValue)
  else
    Result := Vcl.Dialogs.InputQuery(ACaption, APrompt, AValue);
end;
{$ELSE}
begin
  Result := Vcl.Dialogs.InputQuery(ACaption, APrompt, AValue);
end;
{$IFEND}

end.
