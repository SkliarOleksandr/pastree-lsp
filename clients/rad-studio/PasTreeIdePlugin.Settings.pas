unit PasTreeIdePlugin.Settings;

{
  The user-visible settings: a store in the registry, and the Tools > PasTree >
  Settings menu item that opens the dialog over it (the dialog itself is
  PasTreeIdePlugin.SettingsForm, which owns a .dfm so it can be laid out in the
  Form Designer).

  WHERE THEY LIVE. HKCU\<IOTAServices.GetBaseRegistryKey>\PasTree - the same
  per-installation root the IDE keeps its own settings under, read the same way
  GetIDELibraryPaths already reads the library paths. That is what makes two
  side-by-side RAD Studio versions two independent sets of settings, which is
  the behaviour anyone with two installations expects; a key of our own under
  HKCU would have quietly shared one set between them.

  DEFAULT IS ON, FOR EVERY SWITCH THAT TURNS SOMETHING OFF. Those switches
  disable something this plugin already does, so a missing value - a fresh
  installation, a user who never opened the dialog - must read as "behave as
  before". "Advanced logging", "Log all IDE crashes" and Find References'
  implementation headers are the exceptions, and the rule is the same one seen from the other side: each
  turns something ON, so its default is OFF. The IDE Fixes tab is the
  exception to the exception: each fix turns something on and is still ON by
  default (Alex, 2026-09-29), because a fix nobody enables fixes nothing.
  Written only by the dialog:
  nothing else in the package writes to the registry - except the Go To
  picker's own sizes (WritePickerValue) and the marker that remembers the
  IDE's Error Insight level the error underline choice replaced
  (ApplyErrorInsightChoice; the level itself goes through the IDE's
  environment options).

  READ AT THE POINT OF USE, NOT CACHED AT STARTUP. Every switch is read on
  each gesture (an editor tab activating, a key being pressed), which is what
  makes a change in the dialog take effect on the next keystroke rather than at
  the next IDE start. The cost is a registry read per gesture, which is far
  below the LSP round-trip it gates - and GSettings caches the values anyway,
  so the read only happens once until the dialog writes.
}

interface

uses
  System.SysUtils,
  System.UITypes;   // TColor and TFontStyles without dragging in the VCL

/// <summary>
/// Whether we replace the IDE's Structure pane content for Pascal sources
/// (PasTreeIdePlugin.Outline). False leaves the pane to the IDE's own
/// provider - our outline simply stops pushing, which is all it takes.
///
/// WITHDRAWN, TEMPORARILY, ON 2026-09-01: this always answers False and the
/// dialog no longer shows the checkbox. The outline is not finished, and a
/// half-finished pane is worse than the IDE's own - it looks like the
/// feature, so what it gets wrong reads as what PasTree gets wrong.
///
/// The stored value, the record field and the registry name are all left
/// alone deliberately: withdrawing a feature must not throw away the choice
/// of anyone who had it on, so switching it back on is deleting the two
/// lines below and putting the checkbox back in the .dfm - not recovering a
/// setting nobody wrote down.
/// </summary>
function OverrideStructureView: Boolean;

/// <summary>
/// Whether "Find Declaration" is OURS - both the Ctrl+Click gesture
/// (PasTreeIdePlugin.GotoDeclaration's mouse override) and the editor menu
/// item (the cEdMenuCatIdentifier takeover in PasTreeIdePlugin.Wizard).
///
/// Independent of the Insight Provider selection, and it has to be: the
/// override exists precisely for the people who cannot select PasTree there,
/// because RAD Studio gates part of the Code Insight UI on DelphiLSP being
/// the provider. When PasTree IS the selected provider the CLICK override
/// stands down on its own regardless of this switch - the IDE's own click
/// chain already resolves through us.
///
/// THE ONE SWITCH WHOSE TWO HALVES ANSWER AT DIFFERENT TIMES. The click is
/// asked per click, so turning it off takes effect immediately. The menu
/// takeover is asked once, at package load, because it cannot be undone
/// within a session - unregistering the native action list is a one-way
/// door. Turned off mid-session, our menu item hides and the slot stays
/// empty until the IDE restarts; the dialog's hint says so.
/// </summary>
function CtrlClickNavigation: Boolean;

/// <summary>
/// Whether Ctrl+Shift+Up/Down runs OUR declaration/implementation jump. False
/// hands the keystroke back to the IDE, which then runs its own - see
/// ToggleKeyProc (PasTreeIdePlugin.Wizard), where that fallback is the whole
/// mechanism.
/// </summary>
function OverrideDeclImplToggle: Boolean;

/// <summary>
/// Whether Ctrl+Shift+E and the editor menu's "Rename..." are ours. False
/// hands the keystroke back to the IDE and hides the menu item - the same
/// off switch shape as the toggle above, and for the same reason: a feature
/// that EDITS the user's code has to be refusable outright.
/// </summary>
function RenameEnabled: Boolean;

/// <summary>
/// Whether the editor menu offers the "Find All" submenu - References,
/// Overrides, Implementations, Descendants, Assignments, Creations,
/// Destructions, and whatever joins them. ONE switch for the family, on
/// purpose: they are one kind of question ("show me everywhere that...")
/// answered into one kind of tab, and a dialog with a row per member would
/// grow a row every time PasTree learns a new one (it did, twice in a week -
/// 0.34.0 had two switches here). False HIDES the submenu, as for Rename: a
/// disabled item reads as "not right now", and this one would never come
/// back without the settings dialog. Nothing in it replaces a native command,
/// so off means gone rather than "the native one".
///
/// Replaces EnableFindOverrides / EnableFindImplementations (0.34.0-0.36.x);
/// their registry values are neither read nor deleted - a user who had one
/// of the two off gets the family on, which is the safe direction.
/// </summary>
function FindAllEnabled: Boolean;

/// <summary>
/// Whether Find References also lists the implementation headers that spell
/// the name without using it: for a type, the `TFoo` of every `procedure
/// TFoo.Bar;`; for a method, its own implementation header. Sent as the
/// request's `context.includeImplementationHeaders`.
///
/// OFF BY DEFAULT, the other side of the rule in this unit's header: it adds
/// rows rather than taking a feature away, and on a form's class it adds one
/// per event handler, burying the uses the search was for. Rename does not
/// read it - it always rewrites those headers, or the code would not compile.
/// </summary>
function FindReferencesImplHeaders: Boolean;

/// <summary>
/// Whether Ctrl+Shift+C is ours - class completion AND the prototype sync
/// that now runs in front of it (PasTreeIdePlugin.SyncPrototypes), which is
/// one keystroke and therefore one switch. False hands the keystroke back to
/// the IDE, which then runs its own class completion: the same off-switch
/// shape as the decl/impl toggle, and for the same reason - what is being
/// switched off is a REPLACEMENT of a native command, so off has to mean
/// "the native one".
/// </summary>
function ClassCompleteEnabled: Boolean;

/// <summary>
/// Where class completion puts a new body: True = after the body of the
/// nearest earlier declaration, False = alphabetically among the type's
/// bodies (the default - what the native command does). See
/// PasLsp.ClassComplete.PlaceBodies.
/// </summary>
function ClassCompleteDeclarationOrder: Boolean;

/// <summary>
/// Whether Ctrl+G is ours - the Go To picker (PasTreeIdePlugin.GoToPicker). False
/// hands the keystroke back to the IDE, whatever the user's keymap binds it
/// to: the same off-switch shape as the decl/impl toggle.
/// </summary>
function GoToEnabled: Boolean;

/// <summary>
/// Whether Ctrl+F12 and Alt+F11 are ours - the View Unit and Use Unit dialogs
/// over the whole analyzed closure (PasTreeIdePlugin.UnitPicker). False hands
/// both keys back to the IDE, the Go To switch's shape.
/// </summary>
function UnitDialogsEnabled: Boolean;

/// <summary>
/// The Go To picker's own remembered state - window size, the kind boxes -
/// as named integers under the same registry key as the switches. THE ONE
/// EXCEPTION to "written only by the dialog": the picker writes these when
/// it closes, because a size the user dragged out is a preference too, and
/// asking for it in the settings dialog would be absurd. ADefault answers
/// for a value never written or unreadable.
/// </summary>
function ReadPickerValue(const AName: string; ADefault: Integer): Integer;
procedure WritePickerValue(const AName: string; AValue: Integer);

/// <summary>
/// HKCU-relative path of this plugin's settings key, for the units that keep
/// a value of their own beneath it (PasTreeIdePlugin.GroupScope keeps the
/// per-group project ticks in a GroupScope subkey). '' without IOTAServices.
/// </summary>
function SettingsRegistryKey: string;

/// <summary>
/// Whether Enter after an unclosed block opener inserts the closer (block
/// completion - PasTreeIdePlugin.BlockClose). False stops the plugin from
/// even asking the server, and Enter is never swallowed either way.
/// </summary>
function BlockCompletionEnabled: Boolean;

/// <summary>
/// Whether Tooltip symbol insight - the editor's hover hint - is ours
/// (PasTreeIdePlugin.TooltipSymbolInsight): the declaration in the editor's
/// colours with its documentation and a link. Named after the IDE's own
/// option it replaces, which is switched off while this is True and put
/// back when this goes False or the package unloads.
/// </summary>
function TooltipSymbolInsightEnabled: Boolean;

/// <summary>
/// Whether our Code Completion list draws a declaration's name in bold - the
/// one bold run of a row, the detail being colours only. Default True;
/// unticked, nothing in a row is bold (Alex, 2026-10-22).
/// </summary>
function CompletionBoldNames: Boolean;

/// <summary>
/// Whether the server writes pastree-lsp.log beside the project at all.
/// False sends no logFile to the server, which is what "no log" means on its
/// side - nothing is written rather than written and discarded, so a
/// read-only source tree stays untouched. The IDE-side crash record
/// (PasTreeIdePlugin.CrashLog) is a different file and is NOT gated: a fault
/// nobody recorded is the one thing worse than a log nobody reads.
/// </summary>
function LoggingEnabled: Boolean;

/// <summary>
/// Whether that log carries the DETAIL - the configuration inventory (every
/// search path, define, namespace and unit alias), the closure's diagnostics,
/// an analysis's stages, every background request, the IDE's asking/answer
/// pairs, Rename's steps, the toolbar's construction, the timing lines.
/// Without it the log is one or two lines per command the user ran, the
/// analysis status, the document notifications and every failure (2026-10-22,
/// Alex; LspLogDetail and the server's logDetail). Meaningful only while
/// LoggingEnabled; the dialog greys it out otherwise.
///
/// OFF BY DEFAULT, unlike every other switch here, and deliberately: this one
/// does not turn a FEATURE off, it turns a diagnostic on. The detail is
/// hundreds of lines per configuration and a line per keystroke, and it
/// answers questions you go looking for rather than ones you want answered
/// every time. The counts (`configured: platform=... paths=N defines=N`,
/// `N diagnostics`) are logged either way, so they never disappear.
/// </summary>
function AdvancedLoggingEnabled: Boolean;

/// <summary>
/// Whether the project's log is emptied when that project is opened, so a
/// session's log is that session's and not the history of every run since
/// the file was created (Alex, 2026-09-21, the default). Off keeps the
/// server's behaviour of appending with a separator per run. False whenever
/// logging itself is off - there is no file to clear. Read by
/// TLspSession.ProjectOpened, the one place that knows an open from a
/// switch of the active project inside a group.
/// </summary>
function ClearLogOnProjectOpen: Boolean;

/// <summary>
/// Whether pastree-ide-crash.log takes every access violation in the IDE
/// rather than only those with this plugin on the faulting stack (see
/// PasTreeIdePlugin.CrashLog). OFF BY DEFAULT, for AdvancedLoggingEnabled's
/// reason: a diagnostic turned on, and the IDE's own faults are the noise the
/// filter exists to remove. Independent of LoggingEnabled, as the crash log
/// is. Not read at the point of use - the handler must not read settings -
/// but pushed with SetCrashLogAll at load and by SaveSettings.
/// </summary>
function LogAllIdeCrashes: Boolean;

/// <summary>
/// Whether the editor's error underlines are OURS (PasTreeIdePlugin.
/// ErrorPaint, over the server's publishDiagnostics) rather than the IDE's
/// Error Insight. One choice, not two switches: the two drawn together put
/// two families of underline on the same code in the same colours, and
/// nothing on screen says which one is PasTree's. OFF BY DEFAULT since
/// 0.52.4, and labelled experimental in the dialog (Alex, 2026-09-24): the
/// Code Insight manager is withdrawn and DelphiLSP owns the insight
/// features, so the native underlines are the expected ones.
///
/// FORCED ON WHILE PASTREE IS THE CODE INSIGHT MANAGER (0.73.7): the IDE's
/// Error Insight takes its errors from the selected provider alone, through
/// a private interface (clients/rad-studio/SPEC.md, the 2026-10-20 spike),
/// so with PasTree selected the IDE underlines nothing and ours are the only
/// ones there can be. The stored choice is kept for when the manager is
/// RAD Studio again; the dialog greys it meanwhile.
/// Read per paint run, from the cache.
/// </summary>
function PasTreeErrorSquigglesEnabled: Boolean;

/// <summary>
/// The highest LSP severity our underlines and their hint show (1 error,
/// 2 warning, 3 information, 4 hint): the Error Insight level the user had
/// before PasTree took the underlines over - the level ApplyErrorInsightChoice
/// remembered when it set the IDE's to None. "Errors" is 1, "Errors and
/// Warnings" 2, "Errors, Warnings and Hints" and "Everything" 4. Nothing
/// remembered (the IDE's level was None already) shows everything. Until
/// 0.73.7 everything was drawn whatever the user's level had been.
/// </summary>
function PasTreeErrorMaxSeverity: Integer;

/// <summary>
/// Code Insight tab (0.68.0, labelled experimental): whether PasTree's Code
/// Insight manager is registered and selected as the IDE's Insight Provider
/// through the environment option InsightManager - see
/// PasTreeIdePlugin.CodeInsight's ApplyInsightManagerChoice. Default False:
/// DelphiLSP stays the provider unless the user asks.
/// </summary>
function PasTreeInsightManagerEnabled: Boolean;

/// <summary>
/// IDE Fixes tab: whether the form designer is kept from writing ExplicitLeft/
/// Top/Width/Height into form files (PasTreeIdePlugin.DfmExplicitFix). ON BY
/// DEFAULT - see this unit's header. NOT read at the point of use: it is a
/// patch of the VCL in the IDE process, applied at package load and
/// re-applied by SaveSettings, so a change in the dialog still takes effect
/// on the next form save.
/// </summary>
function DfmNoExplicitProperties: Boolean;

/// <summary>
/// IDE Fixes tab: whether an inherited form or a frame is kept from writing
/// an unchanged StyleElements (PasTreeIdePlugin.DfmStyleElementsFix). ON BY
/// DEFAULT, applied like DfmNoExplicitProperties.
/// </summary>
function DfmNoDefaultStyleElements: Boolean;

type
  /// <summary>
  /// Tools > Options > Language > Delphi > Error Insight > "Editor rendering
  /// style", in the order of its ValueNames (Classic=0 .. Dots=3).
  /// </summary>
  TErrorMarkStyle = (emsClassic, emsSmoothWave, emsSolidLine, emsDots);

/// <summary>
/// The IDE's own choice of underline shape, so ours draw the one the user
/// picked for Error Insight rather than a second setting of our own. Read from
/// the IDE's live environment option ErrorInsightMarks (IOTAEnvironment-
/// Options.Values), which answers what Tools > Options holds now - the
/// registry ("ErrorInsight Marks" under Editor\Source Options\
/// Borland.EditOptions.Pascal) is written only when the IDE saves, and holds
/// the NAME ("Dots"), which the registry read before 0.63.4 took for Classic.
/// Asked per paint run, so the read is THROTTLED rather than cached for the
/// session: at most one read a second, which is what lets a change in Tools >
/// Options show on the next repaint. Unreadable is Classic, the IDE's own
/// default. The Pascal option set's style (0.73.8): while the IDE has another
/// language's set current the last answer stands - see
/// PasTreeIdePlugin.OptionSets.
/// </summary>
function IdeErrorMarkStyle: TErrorMarkStyle;

/// <summary>
/// Makes the IDE's own Error Insight level agree with
/// PasTreeErrorSquigglesEnabled. Ours: the level the IDE has is remembered
/// under our key and the IDE's is set to None. The IDE's: the remembered
/// level is put back - only a level WE replaced, so a None the user chose in
/// Tools > Options stays theirs. Idempotent; called after the dialog saves and
/// once at package load. A level raised in Tools > Options while ours is
/// selected is the user's choice of the IDE's underlines: since 0.73.7 the
/// setting follows it (SyncErrorInsightChoice), where before it was switched
/// off again at the next start.
///
/// THROUGH THE IDE'S LIVE OPTIONS, NOT THE REGISTRY (since 0.63.4): the
/// environment option ErrorInsightLevel (IOTAEnvironmentOptions.Values), the
/// in-memory value the Options dialog itself edits - the same switch Tooltip
/// symbol insight uses for DeclarationInformation, measured there to act at
/// once where a registry write did nothing to a running IDE. The IDE persists
/// it on exit as it does its own. Before 0.63.4 this wrote the registry value
/// ErrorInsightLevel under Editor\Source Options\Borland.EditOptions.Pascal,
/// which took effect only after a restart. The only registry value left is
/// our own marker, SavedErrorInsightLevel, holding the replaced level's name
/// ("None", "Errors", "Errors and Warnings", "Errors, Warnings and Hints",
/// "Everything") - or "<absent>" from an older version, put back as Errors.
///
/// A LEVEL THAT DOES NOT READ IS RETRIED (since 0.66.1). The call at package
/// load is early, and an option that is not loaded yet used to be logged and
/// given up on for the session. Now it stays pending, and
/// SyncErrorInsightChoice asks again, at most once a second. What was read
/// and done goes to the LSP log.
///
/// THE PASCAL OPTION SET'S LEVEL ONLY (0.73.8). ErrorInsightLevel is a field
/// of the IDE's per-language editor option sets, and Values reaches whichever
/// is current - none at package load, where the call used to read the
/// field's default and write into no set at all, and Default on other
/// occasions (2026-10-20: "Errors" written into Default). Through the door of
/// PasTreeIdePlugin.OptionSets now, which makes the Pascal set current for the
/// read and the writes when it is not and puts back the set that was; a door
/// that does not open leaves the call pending like an unreadable level.
/// </summary>
procedure ApplyErrorInsightChoice;

/// <summary>
/// Retries an ApplyErrorInsightChoice whose level did not read, hands its
/// log line to the LSP log once a session can take it, and makes the setting
/// follow a level raised in Tools > Options (at most one read a second).
/// Cheap when there is nothing to do; called on every editor mouse move (from
/// PasTreeIdePlugin.TooltipSymbolInsight).
/// </summary>
procedure SyncErrorInsightChoice;

/// <summary>Registers Tools > PasTree > Settings.</summary>
procedure InitializeSettings;

/// <summary>
/// Removes the menu item before the BPL unloads - a menu item whose OnClick
/// points into unloaded code is the same immediate crash every other
/// registration in this package is unregistered to avoid.
/// </summary>
procedure FinalizeSettings;

/// <summary>
/// Opens the modal settings dialog. Public because the menu item is not the
/// only plausible way in - a "configure" affordance elsewhere would use this
/// rather than reaching into the form unit.
/// </summary>
procedure ShowSettingsDialog;

/// <summary>
/// The current values, and the write the dialog performs on OK. A record
/// rather than two out-parameters so adding a third switch is one field and
/// its default, not a new signature everywhere.
/// </summary>
type
  TPasTreeSettings = record
    OverrideStructureView: Boolean;
    CtrlClickNavigation: Boolean;
    OverrideDeclImplToggle: Boolean;
    EnableRename: Boolean;
    EnableFindAll: Boolean;
    // Find References with the `TFoo.Bar` implementation headers - see
    // FindReferencesImplHeaders. Default False.
    FindRefsImplHeaders: Boolean;
    EnableBlockCompletion: Boolean;
    EnableTooltipSymbolInsight: Boolean;
    // See CompletionBoldNames. Default True.
    CompletionBoldNames: Boolean;
    EnableClassComplete: Boolean;
    // Where Ctrl+Shift+C puts a new body among its type's existing ones:
    // False = alphabetically (the native command's order, the default),
    // True = in declaration order. Sent as the request's `bodyOrder`.
    ClassCompleteDeclOrder: Boolean;
    EnableGoTo: Boolean;
    EnableUnitDialogs: Boolean;
    EnableLogging: Boolean;
    AdvancedLogging: Boolean;
    ClearLogOnOpen: Boolean;
    // See LogAllIdeCrashes. Default False.
    LogAllIdeCrashes: Boolean;
    // Highlighting tab: a type name painted in its own colour and style
    // wherever the analysis resolved one (PasTreeIdePlugin.SemanticPaint).
    HighlightTypes: Boolean;
    TypeColor: TColor;
    TypeFontStyle: TFontStyles;
    // Highlighting tab: the lines an $IFDEF leaves out, as the analysis
    // evaluated the conditions, painted one flat grey. Default True.
    HighlightInactive: Boolean;
    // False = the IDE's Error Insight draws the error underlines, True = we
    // do (and the IDE's level is set to None) - see ApplyErrorInsightChoice.
    PasTreeErrorSquiggles: Boolean;
    // Code Insight tab - see PasTreeInsightManagerEnabled. Default False.
    PasTreeInsightManager: Boolean;
    // IDE Fixes tab - see DfmNoExplicitProperties. Default True.
    DfmNoExplicitProps: Boolean;
    // IDE Fixes tab - see DfmNoDefaultStyleElements. Default True.
    DfmNoDefaultStyleElems: Boolean;
    // Performance tab: the width of the server's analysis thread pool, 0 =
    // auto (one per logical core, PasTree's default). See
    // AnalysisThreadCount.
    AnalysisThreads: Integer;
    // Performance tab, "Parsing mode" Fast (True) / Full: the server analyzes library units interface-only
    // ("lightLibraries", the server's light mode). Default True, as the
    // server's. See LightLibrariesEnabled.
    LightLibraries: Boolean;
  end;

function LoadSettings: TPasTreeSettings;
procedure SaveSettings(const ASettings: TPasTreeSettings);

/// <summary>
/// The Highlighting tab as the paint path reads it - per syntax run per
/// repaint, so all four come from the cached record, no registry read.
/// </summary>
function TypeHighlightEnabled: Boolean;
function TypeHighlightColor: TColor;
function TypeHighlightStyle: TFontStyles;
function InactiveHighlightEnabled: Boolean;

/// <summary>
/// The Performance tab's thread count, sent to every server it starts as
/// analysisThreads - 0 for Auto. The pool is pinned once per server process,
/// so a change takes effect as each server restarts: TLspSession compares it
/// with what its server was started with, like the log switches.
/// </summary>
function AnalysisThreadCount: Integer;

/// <summary>
/// The Performance tab's library switch, sent as lightLibraries=false when
/// off. Fixed per server process like the thread count: TLspSession restarts
/// a server started with the other value.
/// </summary>
function LightLibrariesEnabled: Boolean;

/// <summary>
/// Registers the ONE listener called (main thread) after the dialog saved -
/// the colouring layer repaints every open editor with the new colour, so a
/// change shows without a restart. nil unregisters.
/// </summary>
procedure SetSettingsSavedListener(const AListener: TProc);

implementation

uses
  System.TypInfo,   // GetEnumName - OptionKindText
  System.Classes,
  System.Variants,
  System.Win.Registry,
  Winapi.Windows,
  Vcl.Menus,
  ToolsAPI,
  // Implementation-section only, and it uses this unit back the same way -
  // a cycle Delphi permits precisely here. The split is deliberate: the
  // store must be readable (OverrideStructureView, from Outline and the key
  // binding) without dragging a form and its .dfm into the caller.
  PasTreeIdePlugin.SettingsForm,
  PasTreeIdePlugin.DfmExplicitFix,
  PasTreeIdePlugin.DfmStyleElementsFix,
  PasTreeIdePlugin.CrashLog,
  // ApplyInsightManagerChoice after a save - the same implementation-only
  // cycle as the form's.
  PasTreeIdePlugin.CodeInsight,
  // ErrorInsightLevel and ErrorInsightMarks are fields of the editor option
  // sets: read and written in the Pascal set only.
  PasTreeIdePlugin.OptionSets,
  // LspLogToServer only, for SyncErrorInsightChoice's line.
  PasTreeIdePlugin.LspSession;

const
  cSettingsKey = 'PasTree';
  cValueStructureView = 'OverrideStructureView';
  cValueCtrlClick = 'CtrlClickNavigation';
  cValueDeclImplToggle = 'OverrideDeclImplToggle';
  cValueRename = 'EnableRename';
  cValueFindAll = 'EnableFindAll';
  cValueFindRefsImplHeaders = 'FindReferencesImplHeaders';
  cValueBlockCompletion = 'EnableBlockCompletion';
  cValueTooltipSymbolInsight = 'EnableTooltipSymbolInsight';
  cValueCompletionBoldNames = 'CompletionBoldNames';
  cValueClassComplete = 'EnableClassComplete';
  cValueClassCompleteOrder = 'ClassCompleteDeclarationOrder';
  cValueGoTo = 'EnableGoTo';
  cValueUnitDialogs = 'EnableUnitDialogs';
  cValueLogging = 'EnableLogging';
  cValueAdvancedLogging = 'AdvancedLogging';
  cValueClearLogOnOpen = 'ClearLogOnProjectOpen';
  cValueLogAllIdeCrashes = 'LogAllIdeCrashes';
  cValueHighlightTypes = 'HighlightTypes';
  cValueTypeColor = 'TypeColor';
  cValueTypeFontStyle = 'TypeFontStyle';
  cValueHighlightInactive = 'HighlightInactiveCode';
  cValueErrorSquiggles = 'PasTreeErrorSquiggles';
  cValueInsightManager = 'PasTreeInsightManager';
  cValueDfmNoExplicit = 'DfmNoExplicitProperties';
  cValueDfmNoDefaultStyleElements = 'DfmNoDefaultStyleElements';
  cValueAnalysisThreads = 'AnalysisThreads';
  cValueLightLibraries = 'LightLibraries';
  // The IDE level ApplyErrorInsightChoice replaced with None, to put back -
  // by name, one of cErrorInsightLevelNames.
  cValueSavedErrorInsightLevel = 'SavedErrorInsightLevel';
  // Tools > Options > Language > Delphi > Error Insight, as IOTAEnvironment-
  // Options names them; the ValueNames of the two comboboxes, in index order
  // (coreide370.bpl, 2026-09-24). The registry keeps the NAME ("Dots").
  cEnvErrorInsightLevel = 'ErrorInsightLevel';
  cEnvErrorInsightMarks = 'ErrorInsightMarks';
  cErrorInsightLevelNames: array[0..4] of string = ('None', 'Errors',
    'Errors and Warnings', 'Errors, Warnings and Hints', 'Everything');
  cLevelNone = 0;
  cLevelErrors = 1;
  cMarkStyleNames: array[0..3] of string = ('Classic', 'Smooth Wave',
    'Solid Line', 'Dots');
  // See IdeErrorMarkStyle.
  cMarkStyleRereadMs = 1000;
  // See SyncErrorInsightChoice.
  cErrorInsightRetryMs = 1000;
  // Teal, BGR - the PasTree demo's default, readable on both IDE themes.
  cDefaultTypeColor = TColor($00808000);

var
  // See SetSettingsSavedListener.
  GSettingsSavedListener: TProc;
  // The in-memory copy. Loaded on first read, replaced on every save, so a
  // gesture never pays for a registry round trip and never reads a stale
  // value either.
  GSettings: TPasTreeSettings;
  GLoaded: Boolean = False;
  // IdeErrorMarkStyle's throttle: the last answer and when it was read.
  GMarkStyle: TErrorMarkStyle = emsClassic;
  GMarkStyleReadAt: UInt64 = 0;
  GMarkStyleRead: Boolean = False;
  // ApplyErrorInsightChoice's level did not read: retried no sooner than
  // GErrorInsightRetryAt. The unreadable value is reported once.
  GErrorInsightPending: Boolean = False;
  GErrorInsightRetryAt: UInt64 = 0;
  GErrorInsightUnreadableNoted: Boolean = False;
  // A door to the Pascal option set that did not open, said once per wait.
  GErrorInsightDeferNoted: Boolean = False;
  // ApplyErrorInsightChoice left the IDE's level at None for our underlines
  // this session - what makes a level other than None, read later, the
  // user's own change in Tools > Options (SyncErrorInsightChoice). Never set
  // before Apply has read the level, so the level a start finds is not
  // taken for one.
  GErrorInsightNoneByUs: Boolean = False;
  // The level remembered for PasTreeErrorMaxSeverity, as an index into
  // cErrorInsightLevelNames; -1 = none remembered. Kept in step with the
  // SavedErrorInsightLevel marker by ApplyErrorInsightChoice.
  GErrorInsightSavedLevel: Integer = -1;
  GErrorInsightKindLogged: Boolean = False;
  GErrorInsightFollowAt: UInt64 = 0;
  // The last line for the LSP log, until a session takes it.
  // Every line until a session can take it - the package-load call runs
  // before any project is open. Until 0.73.7 only the LAST line was kept,
  // and what a start did to the level never reached the log.
  GErrorInsightLogLines: TArray<string> = nil;
  // The two menu items we own: the "PasTree" submenu parent and its one
  // child. Held so FinalizeSettings can take them back out of the IDE's menu
  // - freeing the parent frees the child with it.
  GRootItem: TMenuItem = nil;

type
  // The OnClick target has to live on an object, and a TComponent one is
  // freed with the menu item that references it. A plain class with a class
  // procedure would do as well; this keeps the handler next to nothing else.
  TMenuHandler = class
    procedure SettingsClick(ASender: TObject);
    procedure ToolsMenuClick(ASender: TObject);
  end;

var
  GHandler: TMenuHandler = nil;
  { The Tools menu itself, and whatever OnClick it already had.

    HOOKED SO THE REPAIR RUNS WHEN IT MATTERS. The child of our submenu is
    wiped some time during IDE startup - the probe caught children going 1
    -> 0 between package load and the first project opening - and repairing
    it on a timer would only be a guess about when that happens. The moment
    the answer is actually needed is the moment the user drops the Tools
    menu down, so that is where the check goes: OnClick on a top-level menu
    item fires as it opens.

    CHAINED, never replaced: the IDE's own handler is kept and called after
    ours, and FinalizeSettings puts it back. Dropping it would silently
    break whatever the IDE does there. }
  GToolsMenu: TMenuItem = nil;
  GPrevToolsClick: TNotifyEvent = nil;

{ The Build tab, tagged like every other line this package puts there - see
  PasTreeIdePlugin.LspSession's LogDiagnostic for the convention. }
procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

function SettingsRegistryKey: string;
var
  LServices: IOTAServices;
begin
  Result := '';
  if not Supports(BorlandIDEServices, IOTAServices, LServices) then
    Exit;
  Result := IncludeTrailingPathDelimiter(LServices.GetBaseRegistryKey)
    + cSettingsKey;
end;

{ TFontStyles <-> one registry integer: bit 0 bold, 1 italic, 2 underline,
  3 strikeout - Ord(TFontStyle), and stable for as long as the enum is. }
function StyleBits(AStyles: TFontStyles): Integer;
var
  LStyle: TFontStyle;
begin
  Result := 0;
  for LStyle in AStyles do
    Result := Result or (1 shl Ord(LStyle));
end;

function StylesOf(ABits: Integer): TFontStyles;
var
  LStyle: TFontStyle;
begin
  Result := [];
  for LStyle := Low(TFontStyle) to High(TFontStyle) do
    if ABits and (1 shl Ord(LStyle)) <> 0 then
      Include(Result, LStyle);
end;

function LoadSettings: TPasTreeSettings;
var
  LReg: TRegistry;
  LKey: string;

  // A value that is absent, or holds something that is not a number, reads
  // as the default. Both are the same case in practice - a key written by an
  // older version, a hand-edited value - and both mean "we were not told
  // otherwise", which is exactly the default.
  function ReadFlag(ALReg: TRegistry; const AName: string;
    ADefault: Boolean): Boolean;
  begin
    Result := ADefault;
    if not ALReg.ValueExists(AName) then
      Exit;
    try
      Result := ALReg.ReadInteger(AName) <> 0;
    except
      Result := ADefault;
    end;
  end;

  function ReadInt(ALReg: TRegistry; const AName: string;
    ADefault: Integer): Integer;
  begin
    Result := ADefault;
    if not ALReg.ValueExists(AName) then
      Exit;
    try
      Result := ALReg.ReadInteger(AName);
    except
      Result := ADefault;
    end;
  end;

begin
  // DEFAULTS FIRST, so every early exit below lands on them.
  Result.OverrideStructureView := True;
  Result.CtrlClickNavigation := True;
  Result.OverrideDeclImplToggle := True;
  Result.EnableRename := True;
  Result.EnableFindAll := True;
  Result.FindRefsImplHeaders := False;
  Result.EnableBlockCompletion := True;
  Result.EnableTooltipSymbolInsight := True;
  Result.CompletionBoldNames := True;
  Result.EnableClassComplete := True;
  Result.ClassCompleteDeclOrder := False;
  Result.EnableGoTo := True;
  Result.EnableUnitDialogs := True;
  Result.EnableLogging := True;
  // See AdvancedLoggingEnabled: the one default that is False.
  Result.AdvancedLogging := False;
  Result.ClearLogOnOpen := True;
  Result.LogAllIdeCrashes := False;
  Result.HighlightTypes := True;
  Result.TypeColor := cDefaultTypeColor;
  Result.TypeFontStyle := [];
  Result.HighlightInactive := True;
  Result.PasTreeErrorSquiggles := False;
  Result.PasTreeInsightManager := False;
  Result.DfmNoExplicitProps := True;
  Result.DfmNoDefaultStyleElems := True;
  Result.AnalysisThreads := 0;
  Result.LightLibraries := True;

  LKey := SettingsRegistryKey;
  if LKey = '' then
    Exit;

  LReg := TRegistry.Create(KEY_READ);
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if not LReg.OpenKeyReadOnly(LKey) then
      Exit;   // never saved - the defaults stand
    try
      Result.HighlightTypes :=
        ReadFlag(LReg, cValueHighlightTypes, Result.HighlightTypes);
      Result.TypeColor :=
        TColor(ReadInt(LReg, cValueTypeColor, Integer(Result.TypeColor)));
      Result.TypeFontStyle := StylesOf(ReadInt(LReg, cValueTypeFontStyle, 0));
      Result.HighlightInactive :=
        ReadFlag(LReg, cValueHighlightInactive, Result.HighlightInactive);
      Result.OverrideStructureView :=
        ReadFlag(LReg, cValueStructureView, Result.OverrideStructureView);
      Result.CtrlClickNavigation :=
        ReadFlag(LReg, cValueCtrlClick, Result.CtrlClickNavigation);
      Result.OverrideDeclImplToggle :=
        ReadFlag(LReg, cValueDeclImplToggle, Result.OverrideDeclImplToggle);
      Result.EnableRename :=
        ReadFlag(LReg, cValueRename, Result.EnableRename);
      Result.EnableFindAll :=
        ReadFlag(LReg, cValueFindAll, Result.EnableFindAll);
      Result.FindRefsImplHeaders := ReadFlag(LReg, cValueFindRefsImplHeaders,
        Result.FindRefsImplHeaders);
      Result.EnableBlockCompletion :=
        ReadFlag(LReg, cValueBlockCompletion, Result.EnableBlockCompletion);
      Result.EnableTooltipSymbolInsight :=
        ReadFlag(LReg, cValueTooltipSymbolInsight, Result.EnableTooltipSymbolInsight);
      Result.CompletionBoldNames :=
        ReadFlag(LReg, cValueCompletionBoldNames, Result.CompletionBoldNames);
      Result.EnableClassComplete :=
        ReadFlag(LReg, cValueClassComplete, Result.EnableClassComplete);
      Result.ClassCompleteDeclOrder := ReadFlag(LReg,
        cValueClassCompleteOrder, Result.ClassCompleteDeclOrder);
      Result.EnableGoTo := ReadFlag(LReg, cValueGoTo, Result.EnableGoTo);
      Result.EnableUnitDialogs :=
        ReadFlag(LReg, cValueUnitDialogs, Result.EnableUnitDialogs);
      Result.EnableLogging :=
        ReadFlag(LReg, cValueLogging, Result.EnableLogging);
      Result.AdvancedLogging :=
        ReadFlag(LReg, cValueAdvancedLogging, Result.AdvancedLogging);
      Result.ClearLogOnOpen :=
        ReadFlag(LReg, cValueClearLogOnOpen, Result.ClearLogOnOpen);
      Result.LogAllIdeCrashes :=
        ReadFlag(LReg, cValueLogAllIdeCrashes, Result.LogAllIdeCrashes);
      Result.PasTreeErrorSquiggles :=
        ReadFlag(LReg, cValueErrorSquiggles, Result.PasTreeErrorSquiggles);
      Result.PasTreeInsightManager :=
        ReadFlag(LReg, cValueInsightManager, Result.PasTreeInsightManager);
      Result.DfmNoExplicitProps :=
        ReadFlag(LReg, cValueDfmNoExplicit, Result.DfmNoExplicitProps);
      Result.DfmNoDefaultStyleElems := ReadFlag(LReg,
        cValueDfmNoDefaultStyleElements, Result.DfmNoDefaultStyleElems);
      Result.AnalysisThreads :=
        ReadInt(LReg, cValueAnalysisThreads, Result.AnalysisThreads);
      if Result.AnalysisThreads < 0 then
        Result.AnalysisThreads := 0;
      Result.LightLibraries :=
        ReadFlag(LReg, cValueLightLibraries, Result.LightLibraries);
    finally
      LReg.CloseKey;
    end;
  finally
    LReg.Free;
  end;
end;

procedure SaveSettings(const ASettings: TPasTreeSettings);
var
  LReg: TRegistry;
  LKey: string;
  LApply: TProc;
begin
  // The cache is updated FIRST and unconditionally: a registry that cannot be
  // written (a locked-down machine, a policy) must still leave the dialog's
  // choice in effect for this session rather than silently reverting it.
  GSettings := ASettings;
  GLoaded := True;

  LKey := SettingsRegistryKey;
  if LKey = '' then
    Exit;

  LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    try
      LReg.RootKey := HKEY_CURRENT_USER;
      if not LReg.OpenKey(LKey, True) then
        Exit;
      try
        LReg.WriteInteger(cValueStructureView,
          Ord(ASettings.OverrideStructureView));
        LReg.WriteInteger(cValueCtrlClick, Ord(ASettings.CtrlClickNavigation));
        LReg.WriteInteger(cValueDeclImplToggle,
          Ord(ASettings.OverrideDeclImplToggle));
        LReg.WriteInteger(cValueRename, Ord(ASettings.EnableRename));
        LReg.WriteInteger(cValueFindAll, Ord(ASettings.EnableFindAll));
        LReg.WriteInteger(cValueFindRefsImplHeaders,
          Ord(ASettings.FindRefsImplHeaders));
        LReg.WriteInteger(cValueBlockCompletion,
          Ord(ASettings.EnableBlockCompletion));
        LReg.WriteInteger(cValueTooltipSymbolInsight, Ord(ASettings.EnableTooltipSymbolInsight));
        LReg.WriteInteger(cValueCompletionBoldNames,
          Ord(ASettings.CompletionBoldNames));
        LReg.WriteInteger(cValueClassComplete,
          Ord(ASettings.EnableClassComplete));
        LReg.WriteInteger(cValueClassCompleteOrder,
          Ord(ASettings.ClassCompleteDeclOrder));
        LReg.WriteInteger(cValueGoTo, Ord(ASettings.EnableGoTo));
        LReg.WriteInteger(cValueUnitDialogs, Ord(ASettings.EnableUnitDialogs));
        LReg.WriteInteger(cValueLogging, Ord(ASettings.EnableLogging));
        LReg.WriteInteger(cValueAdvancedLogging,
          Ord(ASettings.AdvancedLogging));
        LReg.WriteInteger(cValueClearLogOnOpen,
          Ord(ASettings.ClearLogOnOpen));
        LReg.WriteInteger(cValueLogAllIdeCrashes,
          Ord(ASettings.LogAllIdeCrashes));
        LReg.WriteInteger(cValueHighlightTypes, Ord(ASettings.HighlightTypes));
        LReg.WriteInteger(cValueTypeColor, Integer(ASettings.TypeColor));
        LReg.WriteInteger(cValueTypeFontStyle,
          StyleBits(ASettings.TypeFontStyle));
        LReg.WriteInteger(cValueHighlightInactive,
          Ord(ASettings.HighlightInactive));
        LReg.WriteInteger(cValueErrorSquiggles,
          Ord(ASettings.PasTreeErrorSquiggles));
        LReg.WriteInteger(cValueInsightManager,
          Ord(ASettings.PasTreeInsightManager));
        LReg.WriteInteger(cValueDfmNoExplicit,
          Ord(ASettings.DfmNoExplicitProps));
        LReg.WriteInteger(cValueDfmNoDefaultStyleElements,
          Ord(ASettings.DfmNoDefaultStyleElems));
        LReg.WriteInteger(cValueAnalysisThreads, ASettings.AnalysisThreads);
        LReg.WriteInteger(cValueLightLibraries,
          Ord(ASettings.LightLibraries));
      finally
        LReg.CloseKey;
      end;
    except
      // A settings write is never worth an exception into the IDE: the choice
      // is already live (above), and the only thing lost is that it does not
      // survive a restart.
    end;
  finally
    LReg.Free;
  end;
  // One door of PasTreeIdePlugin.OptionSets for both: each would open its
  // own, and each door the Pascal set had to be made current for ends in a
  // save of every option. Inside, both find Pascal current; a door that does
  // not open lets each ask on its own, and wait.
  LApply :=
    procedure
    begin
      ApplyErrorInsightChoice;
      ApplyInsightManagerChoice;
    end;
  if not WithPascalOptionSet(LApply) then
    LApply();
  SetDfmExplicitFix(ASettings.DfmNoExplicitProps);
  SetDfmStyleElementsFix(ASettings.DfmNoDefaultStyleElems);
  SetCrashLogAll(ASettings.LogAllIdeCrashes);
end;

function CurrentSettings: TPasTreeSettings;
begin
  if not GLoaded then
  begin
    GSettings := LoadSettings;
    GLoaded := True;
  end;
  Result := GSettings;
end;

function OverrideStructureView: Boolean;
begin
  // WITHDRAWN - see the declaration. To bring the feature back, this becomes
  //   Result := CurrentSettings.OverrideStructureView;
  // again; CurrentSettings still holds the user's real choice throughout.
  Result := False;
end;

function CtrlClickNavigation: Boolean;
begin
  Result := CurrentSettings.CtrlClickNavigation;
end;

function OverrideDeclImplToggle: Boolean;
begin
  Result := CurrentSettings.OverrideDeclImplToggle;
end;

function RenameEnabled: Boolean;
begin
  Result := CurrentSettings.EnableRename;
end;

function FindAllEnabled: Boolean;
begin
  Result := CurrentSettings.EnableFindAll;
end;

function FindReferencesImplHeaders: Boolean;
begin
  Result := CurrentSettings.FindRefsImplHeaders;
end;

function BlockCompletionEnabled: Boolean;
begin
  Result := CurrentSettings.EnableBlockCompletion;
end;

function TooltipSymbolInsightEnabled: Boolean;
begin
  Result := CurrentSettings.EnableTooltipSymbolInsight;
end;

function CompletionBoldNames: Boolean;
begin
  Result := CurrentSettings.CompletionBoldNames;
end;

function ClassCompleteEnabled: Boolean;
begin
  Result := CurrentSettings.EnableClassComplete;
end;

function ClassCompleteDeclarationOrder: Boolean;
begin
  Result := CurrentSettings.ClassCompleteDeclOrder;
end;

function GoToEnabled: Boolean;
begin
  Result := CurrentSettings.EnableGoTo;
end;

function UnitDialogsEnabled: Boolean;
begin
  Result := CurrentSettings.EnableUnitDialogs;
end;

function ReadPickerValue(const AName: string; ADefault: Integer): Integer;
var
  LReg: TRegistry;
  LKey: string;
begin
  Result := ADefault;
  LKey := SettingsRegistryKey;
  if LKey = '' then
    Exit;
  LReg := TRegistry.Create(KEY_READ);
  try
    try
      LReg.RootKey := HKEY_CURRENT_USER;
      if LReg.OpenKeyReadOnly(LKey) and LReg.ValueExists(AName) then
        Result := LReg.ReadInteger(AName);
    except
      Result := ADefault;
    end;
  finally
    LReg.Free;
  end;
end;

procedure WritePickerValue(const AName: string; AValue: Integer);
var
  LReg: TRegistry;
  LKey: string;
begin
  LKey := SettingsRegistryKey;
  if LKey = '' then
    Exit;
  LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    try
      LReg.RootKey := HKEY_CURRENT_USER;
      if LReg.OpenKey(LKey, True) then
        LReg.WriteInteger(AName, AValue);
    except
      // As for SaveSettings: a picker size that does not survive a restart
      // is not worth an exception into the IDE.
    end;
  finally
    LReg.Free;
  end;
end;

function LoggingEnabled: Boolean;
begin
  Result := CurrentSettings.EnableLogging;
end;

function AdvancedLoggingEnabled: Boolean;
begin
  // The dependency is enforced HERE as well as in the dialog: the stored pair
  // can legally be (logging off, advanced on) - the dialog leaves the value
  // it was given alone when it greys the box out - and a caller asking "should
  // I log the inventory?" must get False for that, not the stale tick.
  Result := CurrentSettings.EnableLogging and CurrentSettings.AdvancedLogging;
end;

function ClearLogOnProjectOpen: Boolean;
begin
  // Same dependency as AdvancedLoggingEnabled, for the same reason.
  Result := CurrentSettings.EnableLogging and CurrentSettings.ClearLogOnOpen;
end;

function LogAllIdeCrashes: Boolean;
begin
  Result := CurrentSettings.LogAllIdeCrashes;
end;

function PasTreeErrorSquigglesEnabled: Boolean;
begin
  Result := CurrentSettings.PasTreeErrorSquiggles or
    CurrentSettings.PasTreeInsightManager;
end;

function PasTreeErrorMaxSeverity: Integer;
begin
  case GErrorInsightSavedLevel of
    1: Result := 1;   // Errors
    2: Result := 2;   // Errors and Warnings
  else
    Result := 4;      // hints and everything, or nothing remembered
  end;
end;

function PasTreeInsightManagerEnabled: Boolean;
begin
  Result := CurrentSettings.PasTreeInsightManager;
end;

function DfmNoExplicitProperties: Boolean;
begin
  Result := CurrentSettings.DfmNoExplicitProps;
end;

function DfmNoDefaultStyleElements: Boolean;
begin
  Result := CurrentSettings.DfmNoDefaultStyleElems;
end;

{ The IDE's live options object - nil without IOTAServices. }
function IdeEnvironmentOptions: IOTAEnvironmentOptions;
var
  LServices: IOTAServices;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAServices, LServices) then
    Result := LServices.GetEnvironmentOptions;
end;

{ An environment option that is a ValueNames combobox, as its index: the
  option may answer the index itself or the name ("Dots", which is what the
  registry holds for it). -1 for anything else. }
function ValueNameIndex(const AValue: Variant;
  const ANames: array of string): Integer;
var
  LText: string;
  I: Integer;
begin
  LText := Trim(VarToStrDef(AValue, ''));
  Result := StrToIntDef(LText, -1);
  if Result >= 0 then
  begin
    if Result > High(ANames) then
      Result := -1;
    Exit;
  end;
  for I := 0 to High(ANames) do
    if SameText(LText, ANames[I]) then
      Exit(I);
end;

{ The index AIndex in the form the option currently answers in - a number if
  it gave a number, the name otherwise - so a write never hands the IDE a
  kind of value it did not give us. }
function ValueNameLike(const ACurrent: Variant; AIndex: Integer;
  const ANames: array of string): Variant; forward;
procedure ErrorInsightLog(const AText: string); forward;
function VariantForLog(const AValue: Variant): string; forward;

{ Writes level AIndex into the option ACurrent was read from and reads it
  back. The form the option answered in comes first (ValueNameLike); when
  that does not read back, the index as an Integer, as a string and the name
  in turn. Until 0.73.7 one form was written and not read back: the level
  that read as Integer 1 at the start read as the STRING "0" after our
  None, the Integer 1 written back over it did not hold, and the log said
  "put back" while Tools > Options still showed None (Alex, 2026-10-20).
  Each write and read through PasTreeIdePlugin.OptionSets (0.73.8): the
  level is a field of the editor option sets, and only Pascal's is ours to
  touch - another set current stops the loop with nothing written. }
function WriteLevelVerified(const AName: string; const ACurrent: Variant;
  AIndex: Integer; const ANames: array of string; out AReads: string): Boolean;
var
  LForms: array[0..3] of Variant;
  LRead: Variant;
  LIdx: Integer;
begin
  LForms[0] := ValueNameLike(ACurrent, AIndex, ANames);
  LForms[1] := AIndex;
  LForms[2] := IntToStr(AIndex);
  LForms[3] := ANames[AIndex];
  Result := False;
  AReads := '';
  for LIdx := 0 to High(LForms) do
  begin
    try
      if not WritePascalSetOption(AName, LForms[LIdx]) then
      begin
        AReads := 'the IDE''s current editor option set is '
          + OptionSetText(CurrentOptionSet) + ', not Pascal - not written';
        Exit;
      end;
      if not ReadPascalSetOption(AName, LRead) then
      begin
        AReads := 'wrote ' + VariantForLog(LForms[LIdx]) + ', and the'
          + ' current option set was ' + OptionSetText(CurrentOptionSet)
          + ' at the read-back';
        Exit;
      end;
      AReads := 'wrote ' + VariantForLog(LForms[LIdx]) + ', reads '
        + VariantForLog(LRead);
      if ValueNameIndex(LRead, ANames) = AIndex then
        Exit(True);
      if AdvancedLoggingEnabled then
        ErrorInsightLog(AName + ': ' + AReads + ' - not ' + ANames[AIndex]
          + ', next form');
    except
      on E: Exception do
        AReads := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

function ValueNameLike(const ACurrent: Variant; AIndex: Integer;
  const ANames: array of string): Variant;
begin
  if StrToIntDef(Trim(VarToStrDef(ACurrent, '')), -1) >= 0 then
    Result := AIndex
  else
    Result := ANames[AIndex];
end;

{ The Pascal set's style, or AKept while another option set is current -
  ErrorInsightMarks is a field of the editor option sets, and another
  language's style is not the one Pascal's underlines take (0.73.8). A peek,
  not the door: asked from the paint path, which must not pay for a save of
  every option. }
function ReadIdeErrorMarkStyle(AKept: TErrorMarkStyle): TErrorMarkStyle;
var
  LValue: Variant;
  LIndex: Integer;
begin
  Result := AKept;
  try
    if not PeekPascalSetOption(cEnvErrorInsightMarks, LValue) then
      Exit;
    Result := emsClassic;
    LIndex := ValueNameIndex(LValue, cMarkStyleNames);
    if LIndex >= 0 then
      Result := TErrorMarkStyle(LIndex);
  except
    Result := emsClassic;
  end;
end;

function IdeErrorMarkStyle: TErrorMarkStyle;
var
  LNow: UInt64;
begin
  LNow := GetTickCount64;
  if (not GMarkStyleRead) or (LNow - GMarkStyleReadAt >= cMarkStyleRereadMs) then
  begin
    GMarkStyle := ReadIdeErrorMarkStyle(GMarkStyle);
    GMarkStyleReadAt := LNow;
    GMarkStyleRead := True;
  end;
  Result := GMarkStyle;
end;

procedure FlushErrorInsightLog;
var
  LIdx: Integer;
begin
  for LIdx := 0 to High(GErrorInsightLogLines) do
    if not LspLogToServer(GErrorInsightLogLines[LIdx]) then
    begin
      Delete(GErrorInsightLogLines, 0, LIdx);
      Exit;
    end;
  GErrorInsightLogLines := nil;
end;

procedure ErrorInsightLog(const AText: string);
begin
  if Length(GErrorInsightLogLines) < 50 then
    GErrorInsightLogLines := GErrorInsightLogLines +
      ['error insight: ' + AText];
  FlushErrorInsightLog;
end;

{ An option value as the log should show it: the text and the Variant type -
  the IDE answered the level as Integer at a start and as UnicodeString after
  our writes (2026-10-20), and which form the Options dialog understands is
  the open question. }
function VariantForLog(const AValue: Variant): string;
begin
  Result := '"' + VarToStrDef(AValue, '') + '" ('
    + VarTypeAsText(VarType(AValue)) + ')';
end;

{ Once per session: the type the IDE DECLARES for an option, from
  GetOptionNames - tkEnumeration, tkInteger or a string kind decides which
  Variant a write should carry. }
function OptionKindText(const AOptions: IOTAEnvironmentOptions;
  const AName: string): string;
var
  LNames: TOTAOptionNameArray;
  LIdx: Integer;
begin
  Result := 'not listed';
  try
    LNames := AOptions.GetOptionNames;
    for LIdx := 0 to High(LNames) do
      if SameText(LNames[LIdx].Name, AName) then
        Exit(GetEnumName(TypeInfo(TTypeKind), Ord(LNames[LIdx].Kind)));
  except
    on E: Exception do
      Result := 'unreadable: ' + E.Message;
  end;
end;

{ Not now: the Pascal option set could not be made current (the door of
  PasTreeIdePlugin.OptionSets did not open). Asked again by
  SyncErrorInsightChoice, like a level that does not read. }
procedure DeferErrorInsightChoice;
begin
  GErrorInsightPending := True;
  GErrorInsightRetryAt := GetTickCount64 + cErrorInsightRetryMs;
  if GErrorInsightDeferNoted then
    Exit;
  GErrorInsightDeferNoted := True;
  ErrorInsightLog('the Pascal option set could not be made current (the'
    + ' current one is ' + OptionSetText(CurrentOptionSet) + ') - the level is'
    + ' read and set later');
end;

{ The level, inside the door of PasTreeIdePlugin.OptionSets: the read and
  every write below reach the Pascal set and no other. }
procedure ApplyErrorInsightInPascal;
var
  LOptions: IOTAEnvironmentOptions;
  LOurs: TRegistry;
  LCurrent: Variant;
  LLevel, LSaved: Integer;
  LRead, LReads: string;
begin
  LOptions := IdeEnvironmentOptions;
  LOurs := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    try
      LOurs.RootKey := HKEY_CURRENT_USER;
      if not LOurs.OpenKey(SettingsRegistryKey, True) then
        Exit;
      if not ReadPascalSetOption(cEnvErrorInsightLevel, LCurrent) then
      begin
        DeferErrorInsightChoice;
        Exit;
      end;
      GErrorInsightDeferNoted := False;
      LLevel := ValueNameIndex(LCurrent, cErrorInsightLevelNames);
      LRead := 'the IDE''s level read as ' + VariantForLog(LCurrent);
      if not GErrorInsightKindLogged then
      begin
        GErrorInsightKindLogged := True;
        LRead := LRead + ', declared ' + OptionKindText(LOptions,
          cEnvErrorInsightLevel);
      end;
      if LLevel < 0 then
      begin
        // A value we cannot read is one we cannot put back either: leave the
        // IDE's level alone for now and ask again - it may not be loaded yet.
        GErrorInsightPending := True;
        GErrorInsightRetryAt := GetTickCount64 + cErrorInsightRetryMs;
        if not GErrorInsightUnreadableNoted then
        begin
          GErrorInsightUnreadableNoted := True;
          ErrorInsightLog(LRead + ' - left as it is, asked again');
        end;
        Exit;
      end;
      if PasTreeErrorSquigglesEnabled then
      begin
        // Already off: nothing to remember, and a level remembered earlier
        // must survive rather than be overwritten with None.
        if LLevel = cLevelNone then
        begin
          GErrorInsightNoneByUs := True;
          GErrorInsightSavedLevel := -1;
          if LOurs.ValueExists(cValueSavedErrorInsightLevel) then
            GErrorInsightSavedLevel := ValueNameIndex(
              LOurs.ReadString(cValueSavedErrorInsightLevel),
              cErrorInsightLevelNames);
          ErrorInsightLog(LRead + ' - PasTree draws the underlines, already None');
          Exit;
        end;
        // Remembered BEFORE it is switched off: the other order, interrupted,
        // loses the user's level for good.
        LOurs.WriteString(cValueSavedErrorInsightLevel,
          cErrorInsightLevelNames[LLevel]);
        GErrorInsightSavedLevel := LLevel;
        if WriteLevelVerified(cEnvErrorInsightLevel, LCurrent,
          cLevelNone, cErrorInsightLevelNames, LReads) then
        begin
          GErrorInsightNoneByUs := True;
          ErrorInsightLog(LRead + ' - PasTree draws the underlines, set to'
            + ' None: ' + LReads);
        end
        else
          LogDiagnostic('could not set the IDE''s Error Insight level to None'
            + ' - it reads "' + LReads + '"; both underlines may show');
      end
      else
      begin
        GErrorInsightNoneByUs := False;
        GErrorInsightSavedLevel := -1;
        if not LOurs.ValueExists(cValueSavedErrorInsightLevel) then
        begin
          ErrorInsightLog(LRead + ' - the IDE draws the underlines, nothing'
            + ' of ours to undo');
          Exit;
        end;
        LSaved := ValueNameIndex(LOurs.ReadString(cValueSavedErrorInsightLevel),
          cErrorInsightLevelNames);
        // "<absent>", from a version that wrote the registry: the IDE had no
        // value then, and a fresh IDE's default is Errors.
        if LSaved < 0 then
          LSaved := cLevelErrors;
        // Only over OUR None: a level the user has set since in Tools >
        // Options is theirs, and wins.
        if LLevel = cLevelNone then
        begin
          if WriteLevelVerified(cEnvErrorInsightLevel, LCurrent,
            LSaved, cErrorInsightLevelNames, LReads) then
            ErrorInsightLog(LRead + ' - the IDE draws the underlines, put'
              + ' back "' + cErrorInsightLevelNames[LSaved] + '": ' + LReads)
          else
          begin
            // Kept: the marker is what a later attempt puts back.
            LogDiagnostic('could not put the IDE''s Error Insight level back'
              + ' to "' + cErrorInsightLevelNames[LSaved] + '" - it reads "'
              + LReads + '"; set it in Tools > Options > Editor > Language');
            Exit;
          end;
        end
        else
          ErrorInsightLog(LRead + ' - the IDE draws the underlines, the'
            + ' user''s level kept');
        LOurs.DeleteValue(cValueSavedErrorInsightLevel);
      end;
    except
      on E: Exception do
        // A failure, so it is worth the Build tab: the two underline layers
        // now disagree with what the dialog says.
        LogDiagnostic('could not set the IDE''s Error Insight level: '
          + E.Message);
    end;
  finally
    LOurs.Free;
  end;
end;

procedure ApplyErrorInsightChoice;
var
  LOptions: IOTAEnvironmentOptions;
begin
  GErrorInsightPending := False;
  LOptions := IdeEnvironmentOptions;
  if not Assigned(LOptions) then
  begin
    GErrorInsightPending := True;
    GErrorInsightRetryAt := GetTickCount64 + cErrorInsightRetryMs;
    Exit;
  end;
  // ONLY THE PASCAL SET'S LEVEL (0.73.8) - a field of the editor option sets,
  // and Values reaches whichever is current: until 0.73.8 the load-time call
  // read and wrote Default's (2026-10-20). One door for the read and the
  // writes - each door the Pascal set had to be made current for ends in a
  // save of every option.
  if not WithPascalOptionSet(ApplyErrorInsightInPascal) then
    DeferErrorInsightChoice;
end;

{ OUR SETTING FOLLOWS A LEVEL RAISED IN TOOLS > OPTIONS - the same rule as the
  Insight Provider's (PasTreeIdePlugin.CodeInsight, FollowIdeProviderChoice).
  With PasTree drawing the underlines the IDE's level is our None; a level
  other than None read later was set by the user, who wants the IDE's
  underlines. Until 0.73.7 both layers drew until the next start, and that
  start's ApplyErrorInsightChoice switched the user's level off again. Now
  the setting turns to the IDE's underlines and our marker goes - the level
  is the user's, nothing of ours is left to put back. The IDE sends no
  notification for an option, so this is a read, at most once a second, on
  the mouse-move path SyncErrorInsightChoice already runs on. }
procedure FollowIdeErrorInsightLevel;
var
  LCurrent: Variant;
  LLevel: Integer;
  LReg: TRegistry;
  LSettings: TPasTreeSettings;
begin
  if not GErrorInsightNoneByUs or GErrorInsightPending or
     (GetTickCount64 < GErrorInsightFollowAt) then
    Exit;
  GErrorInsightFollowAt := GetTickCount64 + cErrorInsightRetryMs;
  if not PasTreeErrorSquigglesEnabled then
  begin
    GErrorInsightNoneByUs := False;
    Exit;
  end;
  // Forced by PasTree as the Code Insight Manager: a level raised there
  // draws nothing (PasTreeErrorSquigglesEnabled), so there is no choice of
  // the IDE's underlines to follow - and turning ours off would leave none.
  if CurrentSettings.PasTreeInsightManager then
    Exit;
  try
    // The Pascal set's level only: another set's is not the one we set to
    // None, and anything but None there is not the user raising ours. A
    // peek, not the door: this runs once a second, and a door the Pascal
    // set had to be made current for ends in a save of every option.
    if not PeekPascalSetOption(cEnvErrorInsightLevel, LCurrent) then
      Exit;
    LLevel := ValueNameIndex(LCurrent, cErrorInsightLevelNames);
    if (LLevel < 0) or (LLevel = cLevelNone) then
      Exit;
    GErrorInsightNoneByUs := False;
    GErrorInsightSavedLevel := -1;
    // The marker first: SaveSettings re-applies the choice, and with no
    // marker that leaves the user's level as it is.
    LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
    try
      LReg.RootKey := HKEY_CURRENT_USER;
      if LReg.OpenKey(SettingsRegistryKey, False) and
         LReg.ValueExists(cValueSavedErrorInsightLevel) then
        LReg.DeleteValue(cValueSavedErrorInsightLevel);
    finally
      LReg.Free;
    end;
    ErrorInsightLog('the IDE''s level was set to "'
      + cErrorInsightLevelNames[LLevel] + '" in Tools > Options - the IDE'
      + ' draws the underlines, the setting follows');
    LSettings := CurrentSettings;
    LSettings.PasTreeErrorSquiggles := False;
    SaveSettings(LSettings);
  except
    on E: Exception do
      ErrorInsightLog('following the IDE''s level failed: ' + E.ClassName
        + ': ' + E.Message);
  end;
end;

procedure SyncErrorInsightChoice;
begin
  if GErrorInsightLogLines <> nil then
    FlushErrorInsightLog;
  // Retried only while the Pascal set is current by itself: a retry that had
  // to make it current would save every option once a second
  // (PasTreeIdePlugin.OptionSets).
  if GErrorInsightPending and (GetTickCount64 >= GErrorInsightRetryAt) and
     PascalOptionSetIsCurrent then
    ApplyErrorInsightChoice;
  FollowIdeErrorInsightLevel;
end;

function TypeHighlightEnabled: Boolean;
begin
  Result := CurrentSettings.HighlightTypes;
end;

function TypeHighlightColor: TColor;
begin
  Result := CurrentSettings.TypeColor;
end;

function TypeHighlightStyle: TFontStyles;
begin
  Result := CurrentSettings.TypeFontStyle;
end;

function InactiveHighlightEnabled: Boolean;
begin
  Result := CurrentSettings.HighlightInactive;
end;

function AnalysisThreadCount: Integer;
begin
  Result := CurrentSettings.AnalysisThreads;
end;

function LightLibrariesEnabled: Boolean;
begin
  Result := CurrentSettings.LightLibraries;
end;

procedure SetSettingsSavedListener(const AListener: TProc);
begin
  GSettingsSavedListener := AListener;
end;

procedure ShowSettingsDialog;
begin
  if ExecuteSettingsDialog and Assigned(GSettingsSavedListener) then
    GSettingsSavedListener;
end;

{ TMenuHandler }

procedure TMenuHandler.SettingsClick(ASender: TObject);
begin
  ShowSettingsDialog;
end;

{ The Tools menu is opening. Make sure our item is there and populated
  BEFORE it paints, then let the IDE's own handler run.

  InitializeSettings is idempotent and self-repairing, so the ordinary case
  costs one liveness check and nothing else. }
procedure TMenuHandler.ToolsMenuClick(ASender: TObject);
begin
  try
    InitializeSettings;
  except
    // A menu that is being opened is the worst possible place to raise: the
    // repair is best-effort, the IDE's handler below is not.
  end;
  if Assigned(GPrevToolsClick) then
    GPrevToolsClick(ASender);
end;

{ ---------------------------------------------------------------------------
  The Tools menu item
  --------------------------------------------------------------------------- }

{ INTAServices.AddActionMenu, NOT MainMenu.Items[...].Add.

  THIS WAS THE BUG, and it was invisible in exactly the way that made it
  expensive: walking MainMenu.Items for the Tools item and calling .Add on it
  DOES parent the item - GRootItem.Parent came back assigned, so the
  idempotence check below was satisfied and every retry exited quietly - and
  the item still never appeared in the menu. Nothing failed, nothing logged,
  and there was nothing to read.

  The IDE keeps its own bookkeeping over the main menu (that is what
  MenuBeginUpdate/MenuEndUpdate on this same interface exist for), and a
  TMenuItem grafted straight onto the VCL tree is not in it. AddActionMenu is
  the documented way in, and it is positional rather than parental:

    Name          an EXISTING menu item's COMPONENT NAME to position against
                  ('ToolsMenu'), and it RAISES if that name is not found -
                  which is why the try/except below is load-bearing, not
                  decoration.
    NewAction     nil: this item has an OnClick, not an action.
    InsertAfter,  together: make it the LAST CHILD of ToolsMenu - the
    InsertAsChild bottom of the Tools menu, which is where it was asked for.

  See https://docwiki.embarcadero.com/RADStudio/Sydney/en/
  Adding_an_Item_to_the_Main_Menu_of_the_IDE and ToolsAPI.pas's own comment
  on INTAServices90.AddActionMenu. }

const
  // The IDE's Tools menu, by component name. Not localised (the CAPTION is),
  // which is the entire reason the API addresses menus this way.
  cToolsMenuName = 'ToolsMenu';
  // Our own two items' component names - REQUIRED, not decoration: the child
  // is anchored to the parent by name, and AddActionMenu has no other way to
  // address it.
  cRootItemName = 'PasTreeToolsMenuItem';
  cSettingsItemName = 'PasTreeToolsSettingsItem';

{ Is AItem reachable from the menu the IDE is showing RIGHT NOW?

  ASKING ABOUT Parent IS NOT ENOUGH. A parented item is not necessarily one
  on the live tree: if the IDE replaces its main menu, an item added to the
  old one keeps a Parent pointing into the discarded tree, so an
  Assigned(Parent) gate would report success over a menu nobody can open.
  Walking up to the root and comparing it with the CURRENT MainMenu.Items is
  the question a stale pointer cannot answer wrongly.

  NECESSARY BUT NOT SUFFICIENT - see the caller, which also requires the
  submenu to still have children. That second half is the one that actually
  mattered here: the item stayed on the live tree throughout and was emptied
  instead. }
function MenuItemIsLive(AItem: TMenuItem): Boolean;
var
  LServices: INTAServices;
  LMenu: TMainMenu;
  LRoot: TMenuItem;
begin
  Result := False;
  if not Assigned(AItem) then
    Exit;
  if not Supports(BorlandIDEServices, INTAServices, LServices) then
    Exit;
  LMenu := LServices.MainMenu;
  if not Assigned(LMenu) then
    Exit;
  LRoot := AItem;
  while Assigned(LRoot.Parent) do
    LRoot := LRoot.Parent;
  Result := LRoot = LMenu.Items;
end;

procedure InitializeSettings;
var
  LServices: INTAServices;
  LSettings: TMenuItem;
begin
  LSettings := nil;   // the except block below reads it
  if Assigned(GRootItem) then
  begin
    { LIVE AND STILL POPULATED. The second half is not pedantry: the submenu
      loses its only child during IDE startup, and a childless submenu
      renders as nothing - so "in the tree" alone was the check that kept
      reporting success over an invisible menu. }
    if MenuItemIsLive(GRootItem) and (GRootItem.Count > 0) then
      Exit;
    // On a tree the IDE threw away. Drop ours and build it again against the
    // live menu - this is the repair the Parent check could never make.
    FreeAndNil(GRootItem);
    { GHandler DELIBERATELY SURVIVES: the Tools-menu OnClick hook below holds
      a method pointer into it, and freeing it here would leave that hook
      dangling - a crash the next time the menu is opened. It is stateless
      and process-lifetime; only FinalizeSettings frees it, after unhooking. }
  end;
  if not Supports(BorlandIDEServices, INTAServices, LServices) then
  begin
    LogDiagnostic('no INTAServices - Tools > PasTree > Settings not added.');
    Exit;
  end;

  { MAY NOT THROW PAST HERE. InitializeSettings runs inside TIDEWizard.Create,
    and an exception out of that fails RegisterPackageWizard - which would
    take the ENTIRE plugin down (no analysis, no navigation, no outline)
    because a menu item could not be placed. A settings shortcut is never
    worth that trade. AddActionMenu raising on an unknown menu name is a real
    possibility rather than a theoretical one, so this catch is the mechanism
    by which a renamed IDE menu costs a log line instead of the product. }
  try
    if not Assigned(GHandler) then
      GHandler := TMenuHandler.Create;

    // Owned by nothing: AddActionMenu takes them into the IDE's menu, and
    // FinalizeSettings frees the root before the BPL unloads - which takes
    // the child with it, since TMenuItem.Destroy frees its own items.
    { BOTH LEVELS GO IN THROUGH AddActionMenu, AND BOTH ARE NAMED.

      Measured, 2026-08-29: a hand-Add-ed child survived the call and was
      GONE by the time the IDE had finished starting, leaving a childless
      'PasTree' submenu, which renders as nothing. Every sibling under Tools
      is named - ToolsOptionsItem, GetItMenuItem, CustomToolsItem - and ours
      was the only one with an empty Name, i.e. the only one the IDE had no
      record of. So the child goes in the same way the parent does, anchored
      to the parent BY NAME, which is the only thing AddActionMenu can
      anchor to.

      The names are therefore REQUIRED now, where an earlier version dropped
      them as pointless. They can collide after a package reload that left
      the old items registered - that is what the try/except around this
      block is for, and FinalizeSettings frees both so the ordinary path
      never gets there. }
    GRootItem := TMenuItem.Create(nil);
    GRootItem.Name := cRootItemName;
    GRootItem.Caption := 'PasTree';
    // InsertAsChild + InsertAfter = the last child of Tools, as asked for.
    LServices.AddActionMenu(cToolsMenuName, nil, GRootItem, True, True);

    LSettings := TMenuItem.Create(nil);
    LSettings.Name := cSettingsItemName;
    LSettings.Caption := 'Settings...';
    LSettings.OnClick := GHandler.SettingsClick;
    // Anchored to OUR root, as its only child.
    LServices.AddActionMenu(cRootItemName, nil, LSettings, True, True);
    { Hook the Tools menu ONCE, now that we know which item it is. From here
      on the repair runs whenever the menu is opened, so the item is correct
      before the user ever opens a project - which is when the wipe used to
      leave it empty and unreachable. }
    { RE-RESOLVED, NOT SET ONCE. The guard used to be `if not
      Assigned(GToolsMenu)`, which is exactly wrong on the path this unit
      exists to handle: after the IDE rebuilds its main menu, the repair above
      adds our items to the NEW tree while GToolsMenu still points at the item
      of the OLD one. Both consequences are real - the hook sits on a discarded
      item and never fires again, so the self-repair it exists for is dead from
      that moment; and FinalizeSettings writes OnClick into that item at
      unload, which is a write to freed memory if the IDE has released the old
      tree. So the hook moves to whatever the live parent is, handing the old
      item its own handler back first if it is still alive. }
    if Assigned(GRootItem.Parent) and (GRootItem.Parent <> GToolsMenu) then
    begin
      if Assigned(GToolsMenu) and MenuItemIsLive(GToolsMenu) then
        GToolsMenu.OnClick := GPrevToolsClick;
      GToolsMenu := GRootItem.Parent;
      GPrevToolsClick := GToolsMenu.OnClick;
      GToolsMenu.OnClick := GHandler.ToolsMenuClick;
    end;
  except
    on E: Exception do
    begin
      // LSettings is owned by nothing until AddActionMenu parents it, so a
      // throw from that call - the name collision the comment above predicts
      // after a package reload - leaks it. Only while UNparented: once it is
      // in the tree, freeing GRootItem below takes it, and freeing it here as
      // well would be the double free.
      if Assigned(LSettings) and not Assigned(LSettings.Parent) then
        FreeAndNil(LSettings);
      FreeAndNil(GRootItem);   // GHandler survives - see the rebuild path
      LogDiagnostic(Format('could not add Tools > PasTree > Settings '
        + '(anchor menu "%s"): %s: %s',
        [cToolsMenuName, E.ClassName, E.Message]));
    end;
  end;
end;

procedure FinalizeSettings;
begin
  { UNHOOK FIRST. The IDE keeps its menu; an OnClick pointing into a BPL that
    has unloaded is an immediate crash the next time Tools is opened, and
    that is the one handler here the IDE will definitely call again. }
  if Assigned(GToolsMenu) then
  begin
    // Only if the item is still in the live tree: the hook is re-resolved on
    // every menu rebuild (see InitializeSettings), so this pointer is normally
    // current - but a rebuild that happened with no repair pass since would
    // make this a write into a menu the IDE has released.
    if MenuItemIsLive(GToolsMenu) then
      GToolsMenu.OnClick := GPrevToolsClick;
    GToolsMenu := nil;
    GPrevToolsClick := nil;
  end;
  // Freeing the item unparents it from the Tools menu and takes its children
  // with it - which is the whole point here: an OnClick pointing into a BPL
  // that has unloaded is an immediate crash the next time the menu opens.
  FreeAndNil(GRootItem);
  FreeAndNil(GHandler);
end;

end.
