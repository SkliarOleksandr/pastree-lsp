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

  ON DELPHI 11 THE FALLBACK IS THE CALLER'S. IdeThemeColor returns the color
  the caller passed as AFallback, and the dialogs are Vcl.Dialogs' - which
  means they are light inside a dark IDE there, the very thing the switch to
  INTAIDEUIServices fixed on 12 (user, 2026-08-31). That is a known cost of
  running on 11, not a bug to hunt.

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
/// True when the IDE hands out theme-aware accents at all (Delphi 12 and
/// newer, and the service answered). Callers that have no sensible fallback
/// color of their own use this to keep the canvas's prepared color instead.
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
  Vcl.Dialogs
{$IF CompilerVersion >= 36}
  , System.SysUtils, ToolsAPI, ToolsAPI.UI
{$IFEND}
  ;

{$IF CompilerVersion >= 36}
function TryUI(out AUI: INTAIDEUIServices): Boolean;
begin
  Result := Supports(BorlandIDEServices, INTAIDEUIServices, AUI);
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
  Result := False;
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
  Result := AFallback;
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
