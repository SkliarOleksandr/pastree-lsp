unit PasTreeIdePlugin.Splash;

{
  One line on RAD Studio's startup splash screen, naming this plugin and the
  build that is loading.

  WHY THE VERSION IS IN THE CAPTION and not just the product name. "Is the BPL
  the IDE loaded the one I just built?" is the question this repository spends
  a shared version constant and a handshake equality check on, and the splash
  is the earliest and cheapest place it gets answered - before a project opens,
  before any request is made, without reading a log. The wording otherwise
  matches the $DESCRIPTION directive in the .dpk, which is what Component >
  Install Packages shows. (Written without its braces on purpose: a brace
  comment does not nest, so the closing one would end this comment here and
  turn the rest of the header into code.)

  WHY initialization AND NOT Register. IOTASplashScreenServices is documented
  as the first service available during product initialization, and the splash
  is gone by the time the IDE is idle - so this has to happen while the package
  is being loaded. A unit's initialization section runs before Register does,
  and needs no wizard to exist yet. SplashScreenServices is nil when the
  package is loaded any other way (a later Install, a design-time host that
  never showed a splash), which is not an error and is why the nil check is not
  defensive padding.

  NOTHING ELSE DEPENDS ON THIS UNIT. It is listed in the .dpk contains clause
  and reached only by being linked; no other unit uses it, so removing it
  removes the feature and nothing more.
}

interface

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  ToolsAPI,
  PasLsp.ProductVersion;

const
  /// The bitmap in PasTreeIdePlugin.Logo.rc, shared with the settings dialog.
  /// 24x24, lower-left pixel naming the transparent colour - AddPluginBitmap's
  /// documented requirement, and VCL's convention too, which is what lets one
  /// bitmap serve both.
  cSplashBitmapName = 'PASTREE_LOGO';

procedure AddSplashEntry;
var
  LBitmap: HBITMAP;
begin
  if not Assigned(SplashScreenServices) then
    Exit;
  // HInstance inside a package is the package's own module, which is where the
  // linked resource lives - not the host IDE's exe.
  LBitmap := LoadBitmap(HInstance, cSplashBitmapName);
  if LBitmap = 0 then
    Exit;   // no icon, no entry: passing 0 is not documented to be safe
  SplashScreenServices.AddPluginBitmap(
    Format('PasTree LSP %s - Object Pascal code intelligence',
      [PasTreeLspVersion]), LBitmap);
end;

initialization
  // Swallowed deliberately, and this is the one place in this package where
  // that is right: a splash line is decoration, and an exception raised while
  // the IDE is still building its main window takes the IDE down with it. The
  // plugin works identically without it.
  try
    AddSplashEntry;
  except
    // nothing to report to - no log, no IDE services, no window yet
  end;

end.
