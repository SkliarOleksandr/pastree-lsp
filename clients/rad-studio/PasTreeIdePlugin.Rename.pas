unit PasTreeIdePlugin.Rename;

{
  Rename, on Ctrl+Shift+E and in the editor's local menu - the one feature in
  this package that CHANGES the user's code, and the shape it takes is the
  demo's (see PasTreeDemo.Main's RenameActionExecute/ApplyRenameEdits/
  ShowRenameTab), because the ToolsAPI has no refactoring surface to plug
  into: the IDE's own rename is not extensible, so ours is a plain command
  that edits buffers and then SHOWS what it did.

  THE RESULTS TAB IS THE POINT. A rename that silently touched fourteen
  places in five files is indistinguishable from one that touched the wrong
  fourteen. So every applied edit is listed afterwards in a Messages tab
  shaped exactly like Find References (grouped by file, one navigable line
  each) - except the text of each line is the line AS IT NOW READS. The
  server hands those previews over ready-made in pastree/renamePlan; nothing
  here re-reads a buffer to build them.

  SYMBOLS ONLY - a routine, a type, a field, a variable, a parameter. Text
  edits and nothing else - except in a FORM FILE whose form is loaded.

  A LOADED FORM IS THE DESIGNER'S (since 0.57.0). Its form file is held as
  live components and written out of them on every save, so no text edit
  survives there; the form designer itself makes the rename - a component's
  Name, a handler's RenameMethod - and the plan does the rest, after checking
  that the designer did exactly the plan's part (TDesignerAction has the
  rules and the measurements behind them). A component's rename carries its
  handlers named after it along (Button1Click -> OKButtonClick) and a caption
  that read its name - as the designer does, so the two paths agree. What
  the designer cannot do whole is refused before anything is touched.

  A UNIT IS DECLINED, and not for want of a plan: the server produces a
  correct one (the header, every `uses` item, the `in '...'` path, and the
  file name the unit then requires), and a plain LSP client applies all of it
  as one workspace edit. Inside the IDE it does not work. The IDE performs a
  rename of its OWN the moment a unit whose `unit` clause changed is saved or
  closed - through its project manager and SaveAs paths - and it cannot be
  asked to stand still while ours runs. Four live runs on a 3759-unit project
  each ended in a different collision between the two: a file already moved
  under us, a project entry already rewritten, an IDE dialog "Unable to
  rename A to B" over a rename that had already happened. Whatever the right
  approach is, it is not "do it ourselves and hope", so the plugin refuses
  and says where to do it instead. The removed half is kept on the
  feature/unit-rename branch, trace and all.

  A compiler builtin is refused too (there is no declaration to rename), as is
  a `uses` spelling the analysis has no rule for. Those refusals arrive as the
  server's own message and are shown verbatim - this unit invents no
  vocabulary of its own for them.

  THE NAME UNDER THE CARET IS ASKED FOR, NOT READ. prepareRename runs before
  the dialog opens, because a unit's name may be dotted - `Namespace.Foo` is
  ONE name - and the text under the caret is at best one segment of it. A
  dialog pre-filled from the buffer would offer half a name.

  THE NEW NAME IS VALIDATED IN TWO PLACES, AND THAT IS DELIBERATE. Only the
  ANALYSIS knows that `begin` is a reserved word (IsValidRenameName lives in
  PasTree, which this designtime package must never link - see
  clients/rad-studio/README.md), so the real verdict always comes from the
  server. What happens here is the cheap half: obvious non-identifiers are
  refused without a round trip, so a typo does not cost a request. Never
  extend LooksLikeName into keyword knowledge - a copy of that list
  here would be a second answer able to disagree with the first.

  APPLIED AND SAVED AT ONCE, ACROSS THE GROUP, WITH ONE WAY BACK. The plan
  is the union of every running project server's answer for the position
  (LspRenamePlan). A file the user has open is changed through its edit
  buffer - an ordinary Ctrl+Z step in its tab - and saved through its module;
  a file nobody has open is read, edited in memory and written back in the
  encoding it came in (PasLsp.SourceText), never loaded into the IDE. No tab
  is opened for anything. The results tab then carries ONE button, Revert
  (PasTreeIdePlugin.RenameToolbar): the same applier run backwards over the
  files as they now stand, saved again.

  That is the fourth shape this has had, settled with the user on
  2026-09-11/12, and the other three are worth a line each so they are not
  tried again. Disk writes for closed files (to 0.27) had no way back.
  A tab per file (0.28 to 0.38) had Ctrl+Z but walked a dozen tabs across the
  screen per rename. Loading closed files as INVISIBLE modules (OpenModule
  without Show, 0.39.0 for a day) had no tabs - and saving a form unit's
  module rewrote its untouched .dfm too, while Save(False, False) asked
  about every file instead. A Save button between the rename and the disk
  was tried the same day and dropped as a click that only confirmed what the
  tab already showed; a rename applied to buffers but not yet to disk also
  left the server seeing open files renamed and closed ones not.

  APPLYING IS TWO PASSES OVER THE WHOLE PLAN, NOT PER FILE, IN EITHER
  DIRECTION. Pass one gathers every touched file and checks that each site
  still reads what it should - the old name going forward, the new name
  coming back; pass two writes. A single mismatch aborts everything before
  anything has been written, because a half-applied rename across five files
  is far worse than one that did not happen - and it is a real case, not a
  theoretical one: the plan describes the sources as the server last saw
  them, and the user may have typed since. Revert has two tolerances the
  rename does not: a site already reading the OLD name is skipped (the user
  pressed Ctrl+Z in a file they had open - Revert is how the other files
  follow), and a site whose LINE moved is found again by the line's
  post-rename text if exactly one line reads that way (LocateSite). Anything
  less certain is a refusal that names the file and line, and Revert stays
  live for a second try once the user has looked.

  Sites are addressed as BYTES of the UTF-8 content, because those are the
  offsets an IOTAEditWriter takes; a held disk text is encoded the same way
  so one applier serves both kinds. The conversion from the plan's line and
  character column lives in LineBytes and SiteByteOffset and nowhere else.

  THE SERVER IS TOLD TWICE: the ordinary document sync carries the buffers
  it holds overlays for, and workspace/didChangeWatchedFiles names the files
  written on disk, which no editor event ever reports.

  Within a file the edits are applied ASCENDING through one undoable writer -
  the same rule (and the same reason) as PasTreeIdePlugin.ClassComplete: a
  writer cannot move backwards. Every offset is resolved BEFORE the first
  write, against the untouched buffer, for that unit's other hard-won reason.
  Note that this is where the IDE differs from the demo, which walks each
  file backwards through SynEdit's SelText: a writer's offsets all address
  the original text, so ascending order needs no shifting arithmetic at all.

  EVERY STEP IS TRACED into pastree-lsp.log, always - see Trace. A rename is
  rare and deliberate, and the question after something odd is always "which
  step did that"; answering that by adding logging afterwards cost several
  round trips through a live IDE.
}

interface

uses
  ToolsAPI;

/// <summary>
/// Entry point for both the editor's local menu action and Ctrl+Shift+E.
/// Asks for the new name, plans, applies, reports. Returns immediately -
/// everything after the prompt happens on a later main-thread turn.
/// </summary>
procedure ExecuteRename(const AView: IOTAEditView);

/// <summary>Registers the Ctrl+Shift+E binding.</summary>
procedure InitializeRename;

/// <summary>
/// Removes the binding and the "PasTree Rename" Messages tab. Same shutdown
/// rule as PasTreeIdePlugin.FindReferences' own finalizer - read its comment
/// on RemoveMessageGroup before touching this one.
/// </summary>
procedure FinalizeRename;

/// <summary>
/// Drops the results tab because the project it describes is closing. The
/// binding and the rest of the feature stay - this is only the tab.
///
/// A rename tab outliving its project is worse than a stale search: it says
/// sites were changed, and closing the project without saving is exactly how
/// those changes get discarded. What is then left on screen is a list of
/// edits that no longer exist, with rows that navigate into whatever file
/// takes those lines in the next project opened.
/// </summary>
procedure CloseRenameResults;

implementation

uses
  System.SysUtils, System.StrUtils, System.Classes, System.Character,
  System.Generics.Collections, System.TypInfo,
  Vcl.Menus, Vcl.Forms, Vcl.Dialogs, Winapi.Windows,
  // DesignIntf: IDesigner, for a loaded form's handlers (RenameMethod,
  // MethodExists) - see TDesignerAction.
  DesignIntf,
  // PasLsp.SourceText: reading a closed file and writing it back in its own
  // encoding, for the files the IDE does not have open - see CollectFiles.
  PasLsp.SourceText,
  ToolsAPI.UI,
  PasTreeIdePlugin.LspSession, PasTreeIdePlugin.LspDocuments,
  PasTreeIdePlugin.Settings, PasTreeIdePlugin.ResultRows,
  PasTreeIdePlugin.WaitDialog, PasTreeIdePlugin.RenameToolbar,
  PasTreeIdePlugin.KeyBindings, PasTreeIdePlugin.GroupScope,
  PasTreeIdePlugin.RenameForm, PasTreeIdePlugin.FormModules;

const
  cMessageGroupName = 'PasTree Rename';
  // LocateSite's answer for a site that already reads what the pass would
  // write - nothing to verify, nothing to write. 0 stays "not found".
  cAlreadyDone = -1;

type
  { One touched FILE, of one of two kinds.

    OPEN in the IDE - on screen, or loaded behind a form - and then Module
    and Editor are set: it is edited through its buffer (an undo step in its
    tab) and saved through its module. Or NOT open, OnDisk, and then Text is
    the file as read, edited in memory, and Encoding is what to write it back
    in at Save (a .pas is UTF-8-with-BOM, bare UTF-8 or ANSI, and rewriting
    it as a different one of those moves every non-ASCII column in it).
    Nothing of the disk kind touches the disk before Save.

    The disk kind has been in and out of this record twice; CollectFiles has
    the reasons it is back.

    A THIRD KIND, LiveForm: a form file (.dfm/.fmx) whose form is LOADED.
    The form designer holds it as live components, not as text, so its edits
    are the designer's (see TDesignerAction) - the applier leaves them alone -
    and it reaches the disk when its module (Module) is saved. }
  TRenameFile = record
    Path: string;
    Module: IOTAModule;
    Editor: IOTASourceEditor;
    OnDisk: Boolean;
    LiveForm: Boolean;
    Text: string;
    Encoding: TPasSourceEncoding;
  end;

  TRenameFiles = TDictionary<string, TRenameFile>;

  { Where a site stands in the text a pass reads: still reading what the pass
    replaces (Pending), already reading what it writes (Done - the designer
    did it, or a Ctrl+Z did the revert's work), or in a live form, where the
    designer owns it (Live). Row/Col are where it actually is, which is not
    always the plan's: see VerifySites. }
  TSiteState = (ssPending, ssDone, ssLive);

  TSiteSpot = record
    Row, Col: Integer;
    State: TSiteState;
  end;

  TSiteSpots = TArray<TSiteSpot>;

  { WHAT THE FORM DESIGNER DOES for a rename whose form is loaded - "the IDE
    first, then we complete" (Alex, 2026-09-27; the facts from four spike
    runs are in local/DFM-PLAN.md). A loaded form cannot take a text edit:
    the designer writes its live components out over the file on every save.
    So the designer is asked to make the rename itself, and the plan does the
    rest - every site the designer did not reach (calls and references in
    code, the form files of forms that are not loaded) - after checking that
    the designer did exactly what was expected.

    dakComponent: the component's Name is set in its form's designer. The
    IDE then renames the field and every handler named after the component
    (the plan's carried renames, predicted and checked), a caption that read
    the name, and - LIVE, in every other loaded form - the descendants'
    `inherited` headers, their links to those handlers, the references
    from other modules (`DataModule1.Action1`) and, for a frame's component,
    the `inherited X` headers in its hosts' inline blocks (spike run 5, F).
    dakHandler: IDesigner.RenameMethod in the form of the class that declares
    it - both headers and that form's own links, one inside an inline
    frame's block too (run 5, I). A loaded DESCENDANT's link reads the new
    name at once but its form stream keeps the old one until the event is
    assigned again (run 5, R) - so every other loaded form that links a
    renamed handler (Relinks) has its links re-assigned afterwards, each
    with its own TMethod read back (RelinkHandlers). Done for a component's
    carried handlers too: re-assigning a link that is already right changes
    nothing.

    FormFile is the form whose designer acts; Handlers the carried renames
    that designer makes along with a component's; Relinks the other loaded
    forms whose handler links are re-assigned after it. }
  TDesignerActionKind = (dakNone, dakComponent, dakHandler);

  TDesignerAction = record
    Kind: TDesignerActionKind;
    FormFile: string;
    OldName, NewName: string;
    Handlers: TArray<TLspCarriedRename>;
    Relinks: TArray<string>;
  end;

  { Which way a plan is being applied. Forward is the rename: each site reads
    OldText and gets NewText. Backward is Cancel: each site reads NewText -
    at the column the forward pass left it at, see SiteCol - and gets OldText
    back. One applier, two directions, so the revert cannot drift from the
    rename it undoes. }
  TApplyDirection = (adForward, adBackward);

  { The rename that Revert would undo: its PLAN, and nothing of the IDE's.
    Revert exists for the user who presses Ctrl+Z in the one file they had
    open and finds the other fifty-one still renamed (2026-09-11): it is the
    button that finishes what the Ctrl+Z started. Cleared by Revert, by the
    next rename, by a project close, and at unload.

    NO MODULE OR EDITOR IS HELD HERE, and that is a rule with a date. The
    files a rename touched used to be kept for Revert, with their IOTAModule
    and IOTASourceEditor - which Revert never used (it gathers the files
    again, as they stand then), and which outlived the user closing a tab:
    the IDE destroys that tab's editor with our reference still on it,
    "Instance of Class TEditSource has dangling reference count of 1"
    (Alex, 2026-09-27, closing forms after a rename). Every interface to
    the IDE's objects lives for one rename or one Revert, never between. }
  TAppliedRename = class
    Plan: TLspRenamePlan;
    constructor Create(const APlan: TLspRenamePlan);
  end;

var
  GMessageGroup: IOTAMessageGroup;
  // Same teardown guard every async feature here carries: a plan can answer
  // while the package is unloading, and by then nothing it touches is safe.
  GAlive: Boolean = False;
  // One rename at a time. Between the request and its answer this feature
  // is holding coordinates for buffers it is about to edit; a second plan
  // started meanwhile would be verified against the text the first one is
  // in the middle of changing. The window is short and the key is easy to
  // press twice, so it is closed rather than reasoned about.
  GPlanning: Boolean = False;
  GApplied: TAppliedRename = nil;

procedure LogDiagnostic(const AMessage: string);
var
  LMessageServices: IOTAMessageServices;
begin
  if Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage('[pastree] ' + AMessage);
end;

{ ONE LINE PER STEP OF A RENAME, into pastree-lsp.log beside the project.

  ALWAYS ON, and that is a decision rather than an oversight. A rename is a
  rare, deliberate act - a dozen lines per invocation is nothing next to what
  an analysis writes - and it is the one command here that CHANGES the user's
  code across several files and the project file. When something about it
  behaves oddly, the question is always "which step did that", and answering
  it by adding logging after the fact costs another round trip through a live
  IDE (it cost several, 2026-08-31). So the trace is part of the feature.

  Into the SERVER'S log rather than the Build tab: the Build tab is where
  the user's own compiler output lives and a step-by-step trace would bury
  it, while the log is already the place this product answers "what actually
  happened" from. Failures still go to the Build tab through LogDiagnostic. }
procedure Trace(const AWhat: string);
begin
  LspLogToServer('rename: ' + AWhat);
end;

{ The same, formatted - saves every caller a Format call. }
procedure TraceFmt(const AFormat: string; const AArgs: array of const);
begin
  Trace(Format(AFormat, AArgs));
end;

/// <summary>
/// A modal message for the user - as opposed to LogDiagnostic, which files
/// something in the Build tab. A rename is a deliberate act, so its refusals
/// are said to the user's face rather than left in a panel they would have
/// to think to open.
/// </summary>
procedure TellUser(const AMessage: string; AKind: TMsgDlgType);
begin
  (BorlandIDEServices as INTAIDEUIServices).MessageDlg(AMessage, AKind,
    [mbOK], -1);
end;

{ The cheap half of the name check - see the unit header on why the other
  half is the server's and must stay there.

  DOTS ARE ALLOWED, because a UNIT name is dotted: `Namespace.Foo` is one
  name, and each segment has to be an identifier. Whether a dotted name is
  legal for what is actually being renamed is NOT decided here - a symbol
  cannot have one, and the analysis says so (IsValidRenameName), which keeps
  this to the one question it can answer without knowing the target. }
function LooksLikeName(const AName: string): Boolean;
const
  cFirst = ['A'..'Z', 'a'..'z', '_'];
  cRest = ['A'..'Z', 'a'..'z', '0'..'9', '_'];
var
  LSegment: string;
  LIdx: Integer;
begin
  Result := False;
  if AName = '' then
    Exit;
  for LSegment in AName.Split(['.']) do
  begin
    if LSegment = '' then
      Exit;   // a leading, trailing or doubled dot
    if not CharInSet(LSegment[1], cFirst) then
      Exit;
    for LIdx := 2 to Length(LSegment) do
      if not CharInSet(LSegment[LIdx], cRest) then
        Exit;
  end;
  Result := True;
end;

function GetOrCreateMessageGroup(
  const AMessageServices: IOTAMessageServices): IOTAMessageGroup;
begin
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.GetGroup(cMessageGroupName);
  if not Assigned(GMessageGroup) then
    GMessageGroup := AMessageServices.AddMessageGroup(cMessageGroupName);
  Result := GMessageGroup;
end;

{ TAppliedRename }

constructor TAppliedRename.Create(const APlan: TLspRenamePlan);
begin
  inherited Create;
  Plan := APlan;
end;

procedure RevertApplied; forward;

{ The rename's own results tab: the same owner-drawn rows Find References
  uses (PasTreeIdePlugin.ResultRows - Find in Files skeleton, editor syntax
  colors), fed the POST-rename lines, with the NEW name carrying the maroon
  match marker: the server's HiFrom/HiTo (0-based, end-exclusive, into the
  snippet) span exactly it. See PasTreeIdePlugin.FindReferences for why the
  removal below is conditional on the IDE not terminating - it is the same
  group mechanism and the same 2026-08-22 access violation.

  And, above the rows, the Revert toolbar (PasTreeIdePlugin.RenameToolbar):
  the one way back. }
procedure ReportRename(const APlan: TLspRenamePlan;
  ADiskCount, AFileCount, AFailed: Integer;
  const AUnconfirmed: TArray<string>);
var
  LMessageServices: IOTAMessageServices;
  LGroup: IOTAMessageGroup;
  LFileCounts: TDictionary<string, Integer>;
  LFileHeaders: TDictionary<string, Pointer>;
  LParentRef: Pointer;
  LEdit: TLspRenameEdit;
  LKey, LTitleHead, LTitleCount, LLine: string;
  LExisting, LFileCount: Integer;
  LCarried: TLspCarriedRename;
begin
  if not Supports(BorlandIDEServices, IOTAMessageServices,
    LMessageServices) then
    Exit;
  LGroup := GetOrCreateMessageGroup(LMessageServices);
  LMessageServices.ClearMessageGroup(LGroup);
  // Built by concatenation so the count's orange span is known, not
  // searched for - same as the Find References title.
  // HOW FAR ACROSS THE GROUP, when there is a group: the plan is the union
  // of every running project server's answer (LspRenamePlan), and a project
  // whose server was not up contributed nothing - which this line has to
  // say, because the rows below read as complete.
  if APlan.ProjectsInGroup > 1 then
    LTitleHead := Format('PasTree Rename: "%s" -> "%s" in %d of %d project(s) - ',
      [APlan.OldName, APlan.NewName, APlan.ProjectsAnswered,
       APlan.ProjectsInGroup])
  else
    LTitleHead := Format('PasTree Rename: "%s" -> "%s" - ',
      [APlan.OldName, APlan.NewName]);
  LTitleCount := IntToStr(Length(APlan.Edits));
  LMessageServices.AddCustomMessagePtr(
    NewTitleRow(LTitleHead + LTitleCount + ' site(s) changed',
      Length(LTitleHead) + 1, Length(LTitleCount)), LGroup);
  { The one thing the rows cannot show: which files were not on screen, and
    that everything is already on disk. Revert above is the way back. }
  LMessageServices.AddTitleMessage(
    Format('%d file(s) changed and saved - %d open in the IDE (Ctrl+Z works ' +
      'there), %d not open (written to disk)%s. Revert puts every site back.',
      [AFileCount, AFileCount - ADiskCount, ADiskCount,
       IfThen(AFailed > 0, Format('; %d could not be saved, see the Build tab',
         [AFailed]), '')]), LGroup);
  // What the rename carried along - the handlers named after a component
  // (see TLspCarriedRename): rows below show them, this says why they are
  // there.
  for LCarried in APlan.Carried do
    LMessageServices.AddTitleMessage(Format('Carried along: the handler %s ' +
      '-> %s, named after the component.', [LCarried.OldName,
      LCarried.NewName]), LGroup);
  // Form-file sites the designer was trusted with and the file does not show
  // (ConfirmLiveForms) - the one thing that must not go unsaid.
  for LLine in AUnconfirmed do
    LMessageServices.AddTitleMessage('Form file ' + LLine + ' - check it.',
      LGroup);

  LFileCounts := TDictionary<string, Integer>.Create;
  LFileHeaders := TDictionary<string, Pointer>.Create;
  try
    for LEdit in APlan.Edits do
    begin
      LKey := LowerCase(LEdit.FilePath);
      LFileCounts.TryGetValue(LKey, LExisting);
      LFileCounts.AddOrSetValue(LKey, LExisting + 1);
    end;
    for LEdit in APlan.Edits do
    begin
      LKey := LowerCase(LEdit.FilePath);
      if not LFileHeaders.TryGetValue(LKey, LParentRef) then
      begin
        LFileCounts.TryGetValue(LKey, LFileCount);
        LParentRef := LMessageServices.AddCustomMessagePtr(
          NewFileHeaderRow(LEdit.FilePath, LFileCount), LGroup);
        LFileHeaders.Add(LKey, LParentRef);
      end;
      // The declaration is labelled rather than shown as its own line: the
      // snippet is worth more than the word "declaration", and losing which
      // row it was is exactly what the demo's pinned first row avoids.
      LMessageServices.AddCustomMessage(
        NewSnippetRow(LEdit.FilePath, LEdit.Row, LEdit.Col,
          TrimRight(LEdit.Snippet), LEdit.HiFrom + 1,
          LEdit.HiTo - LEdit.HiFrom,
          IfThen(LEdit.IsDecl, 'declaration', ''), LEdit.TypeSpans),
        LParentRef);
    end;
  finally
    LFileHeaders.Free;
    LFileCounts.Free;
  end;
  LMessageServices.ShowMessageView(LGroup);
  ResultScrollToTop;
  // AFTER ShowMessageView: the tab has to exist before a control can be put
  // in it, and showing the group is what makes the IDE build it.
  ShowRenameToolbar(cMessageGroupName, RevertApplied);
end;

{ One more line under the rows once Revert has run. The toolbar goes grey at
  the same time: there is nothing left to take back. }
procedure ReportOutcome(const AText: string);
var
  LMessageServices: IOTAMessageServices;
begin
  SetRenameToolbarEnabled(False);
  if Assigned(GMessageGroup) and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    LMessageServices.AddTitleMessage(AText, GMessageGroup);
end;

function SourceEditorOf(const AModule: IOTAModule): IOTASourceEditor;
var
  LIdx: Integer;
begin
  for LIdx := 0 to AModule.GetModuleFileCount - 1 do
    if Supports(AModule.GetModuleFileEditor(LIdx), IOTASourceEditor,
      Result) then
      Exit;
  Result := nil;
end;

{ Every file the plan touches, told apart into the two kinds - see
  TRenameFile. ADiskCount comes back with how many are of the disk kind,
  which is what the results tab tells the user about afterwards.

  NO OpenModule, and that is a decision with a date. Loading a closed unit as
  a module (0.39.0's first shape) gave it a buffer and no tab, which looked
  ideal - until Save: a form unit's module owns its .dfm, the designer comes
  up with the module, and saving the module rewrote every .dfm untouched, as
  IDE churn in every diff after a rename (user, 2026-09-11). Save(False,
  False) instead asks about every file one by one. So a file the IDE does not
  have is not given to the IDE at all: its text is read here, edited here,
  and written back here at Save, in the encoding it came in.

  A FORM FILE (.dfm/.fmx) is the disk kind or the LiveForm kind. Its unit's
  module, when loaded, holds it in the FORM DESIGNER - as live components,
  not as text - and writes it out of them on every save, so an edit on disk
  would be undone by the next save, and the module's only source buffer is
  the .pas, never the form file. A form is loaded far more often than it is
  on screen: opening a form loads its ancestors and every data module its
  form file references. Such a file is marked LiveForm here and left to the
  designer (TDesignerAction); whether the designer CAN do this rename is
  ResolveDesignerAction's question, and a refusal comes from there.

  False (with AError set) for any file that is neither open nor readable,
  and that refuses the WHOLE rename rather than skipping a site - the same
  all-or-nothing rule every other check here follows. }
function CollectFiles(const APlan: TLspRenamePlan; AFiles: TRenameFiles;
  out ADiskCount: Integer; out AError: string): Boolean;
var
  LEdit: TLspRenameEdit;
  LFile: TRenameFile;
  LKey: string;
  LOwner: IOTAModule;
begin
  Result := False;
  AError := '';
  ADiskCount := 0;
  for LEdit in APlan.Edits do
  begin
    LKey := LowerCase(LEdit.FilePath);
    if AFiles.ContainsKey(LKey) then
      Continue;
    LFile := Default(TRenameFile);
    LFile.Path := LEdit.FilePath;
    if IsFormFile(LEdit.FilePath) then
    begin
      LOwner := FormOwnerModule(LEdit.FilePath);
      if Assigned(LOwner) then
      begin
        TraceFmt('  %s: its form is loaded in the IDE (module %s) - the ' +
          'designer''s', [ExtractFileName(LEdit.FilePath), LOwner.FileName]);
        LFile.LiveForm := True;
        LFile.Module := LOwner;
        AFiles.Add(LKey, LFile);
        Continue;
      end;
      LFile.OnDisk := True;
      if not TryReadSourceForEdit(LEdit.FilePath, {out} LFile.Text,
        {out} LFile.Encoding) then
      begin
        TraceFmt('  %s: form file not readable - refusing',
          [ExtractFileName(LEdit.FilePath)]);
        AError := Format('%s could not be read.'#13#10#13#10'Nothing was ' +
          'renamed.', [LEdit.FilePath]);
        Exit;
      end;
      Inc(ADiskCount);
      TraceFmt('  %s: form file, its form not loaded - held for the disk ' +
        '(encoding=%d)', [ExtractFileName(LEdit.FilePath),
        Ord(LFile.Encoding)]);
      AFiles.Add(LKey, LFile);
      Continue;
    end;
    LFile.Module := ModuleOf(LEdit.FilePath);
    if Assigned(LFile.Module) then
    begin
      if not SameText(LFile.Module.FileName, LEdit.FilePath) then
        // Not always a spelling difference: the IDE answers for a program's
        // .dpr with its PROJECT module, whose own FileName is the .dproj.
        // Both cases are fine and both are worth seeing in the log.
        TraceFmt('  %s: answered by the module %s',
          [ExtractFileName(LEdit.FilePath), LFile.Module.FileName]);
      LFile.Editor := SourceEditorOf(LFile.Module);
    end;
    if Assigned(LFile.Editor) then
      TraceFmt('  %s: open in the IDE (modified=%s, views=%d)',
        [ExtractFileName(LEdit.FilePath),
         BoolToStr(LFile.Editor.Modified, True), LFile.Editor.GetEditViewCount])
    else
    begin
      LFile.Module := nil;
      LFile.OnDisk := True;
      if not TryReadSourceForEdit(LEdit.FilePath, {out} LFile.Text,
        {out} LFile.Encoding) then
      begin
        TraceFmt('  %s: not open and not readable - refusing',
          [ExtractFileName(LEdit.FilePath)]);
        AError := Format('%s is not open in the IDE and could not be ' +
          'read.'#13#10#13#10'Nothing was renamed.', [LEdit.FilePath]);
        Exit;
      end;
      Inc(ADiskCount);
      TraceFmt('  %s: not open - held for the disk (encoding=%d)',
        [ExtractFileName(LEdit.FilePath), Ord(LFile.Encoding)]);
    end;
    AFiles.Add(LKey, LFile);
  end;
  Result := True;
end;

{ ---- Sites in a buffer's bytes -------------------------------------------

  Everything below addresses the buffer as the UTF-8 BYTES IOTAEditorContent
  hands out, because those are the offsets an IOTAEditWriter takes. A plan's
  Row/Col are 1-based line and CHARACTER column; the conversion is a line
  found by counting line breaks and a column turned into bytes by encoding
  that line's prefix. Non-ASCII before a site on the same line (a string
  literal, a comment) is exactly where char and byte columns part ways, and
  encoding the prefix is what keeps them together. A BOM, if the buffer
  holds one, is bytes before line 1 like any other and is skipped by the
  line scan for line 1's text. }

{ The byte range [AStart, AStart + ALen) of line ARow in AText, without its
  line break. False when the buffer has fewer lines. }
function LineBytes(const AText: UTF8String; ARow: Integer;
  out AStart, ALen: Integer): Boolean;
var
  LPos, LLine, LTotal: Integer;
begin
  Result := False;
  LTotal := Length(AText);
  LPos := 1;
  // A UTF-8 BOM before line 1 is not part of the line.
  if (LTotal >= 3) and (AText[1] = #$EF) and (AText[2] = #$BB) and
     (AText[3] = #$BF) then
    LPos := 4;
  LLine := 1;
  while LLine < ARow do
  begin
    while (LPos <= LTotal) and (AText[LPos] <> #10) do
      Inc(LPos);
    if LPos > LTotal then
      Exit;
    Inc(LPos);   // past the LF
    Inc(LLine);
  end;
  AStart := LPos;
  while (LPos <= LTotal) and (AText[LPos] <> #10) and (AText[LPos] <> #13) do
    Inc(LPos);
  ALen := LPos - AStart;
  Result := True;
end;

{ Line ARow as a string, '' past the end. }
function LineText(const AText: UTF8String; ARow: Integer): string;
var
  LStart, LLen: Integer;
begin
  if LineBytes(AText, ARow, {out} LStart, {out} LLen) then
    Result := UTF8ToString(Copy(AText, LStart, LLen))
  else
    Result := '';
end;

{ The byte offset, 0-based as a writer wants it, of character column ACol
  (1-based) on line ARow. -1 when the line does not exist. }
function SiteByteOffset(const AText: UTF8String; ARow, ACol: Integer): Integer;
var
  LStart, LLen: Integer;
  LLine: string;
begin
  Result := -1;
  if not LineBytes(AText, ARow, {out} LStart, {out} LLen) then
    Exit;
  LLine := UTF8ToString(Copy(AText, LStart, LLen));
  Result := (LStart - 1) + Length(UTF8Encode(Copy(LLine, 1, ACol - 1)));
end;

{ What a site reads before this pass, what it becomes, and where it is.

  The column is the plan's for the forward pass. For the BACKWARD pass it is
  where the forward pass LEFT the site: every earlier edit on the same line
  moved it by the difference between the two names, so the shift is the sum
  of those - the plan is sorted by (file, line, column), so "earlier" is
  "before it in the array with the same file and row". }
function SiteCol(const APlan: TLspRenamePlan; AIdx: Integer;
  ADirection: TApplyDirection): Integer;
var
  LPrev: Integer;
begin
  Result := APlan.Edits[AIdx].Col;
  if ADirection = adForward then
    Exit;
  LPrev := AIdx - 1;
  while (LPrev >= 0) and
        SameText(APlan.Edits[LPrev].FilePath, APlan.Edits[AIdx].FilePath) and
        (APlan.Edits[LPrev].Row = APlan.Edits[AIdx].Row) do
  begin
    Inc(Result, Length(APlan.Edits[LPrev].NewText) -
      Length(APlan.Edits[LPrev].OldText));
    Dec(LPrev);
  end;
end;

function SiteExpected(const AEdit: TLspRenameEdit;
  ADirection: TApplyDirection): string;
begin
  if ADirection = adForward then
    Result := AEdit.OldText
  else
    Result := AEdit.NewText;
end;

function SiteReplacement(const AEdit: TLspRenameEdit;
  ADirection: TApplyDirection): string;
begin
  if ADirection = adForward then
    Result := AEdit.NewText
  else
    Result := AEdit.OldText;
end;

{ Whether ALine reads AText at character column ACol - as a whole name: the
  character after it may not continue an identifier, or `Button1` would be
  found at the start of `Button10`, and a rename between two such names
  could not tell a done site from a pending one. }
function ReadsAt(const ALine: string; ACol: Integer; const AText: string): Boolean;
var
  LAfter: Integer;
begin
  Result := (AText <> '') and (ACol >= 1) and
    SameText(Copy(ALine, ACol, Length(AText)), AText);
  if not Result then
    Exit;
  LAfter := ACol + Length(AText);
  Result := (LAfter > Length(ALine)) or
    not (ALine[LAfter].IsLetterOrDigit or (ALine[LAfter] = '_'));
end;

{ The one row of AText that reads ASnippet (trailing blanks ignored), or 0
  when none does or several do - two identical lines is a guess, and a
  revert does not guess. }
function UniqueRowReading(const AText: UTF8String; const ASnippet: string;
  out ACount: Integer): Integer;
var
  LLine, LWanted: string;
  LRow: Integer;
begin
  Result := 0;
  ACount := 0;
  LWanted := TrimRight(ASnippet);
  if LWanted = '' then
    Exit;
  LRow := 1;
  while True do
  begin
    LLine := LineText(AText, LRow);
    if (LLine = '') and (LRow > 1) and (SiteByteOffset(AText, LRow, 1) < 0) then
      Break;
    if TrimRight(LLine) = LWanted then
    begin
      Inc(ACount);
      Result := LRow;
    end;
    Inc(LRow);
  end;
  if ACount <> 1 then
    Result := 0;
end;

{ The text of every file in AFiles as UTF-8 bytes, read once per pass: the
  live buffer for an open file, the held text for a disk one. UTF8Encode of
  a disk file's text is an internal representation, not the file's encoding:
  a single-byte source came in as identity-mapped characters (see
  PasLsp.SourceText) and goes back the same way after UTF8ToString, so the
  bytes here only have to agree with SiteByteOffset, which they do. }
type
  TBufferTexts = TDictionary<string, UTF8String>;

function ReadBuffers(AFiles: TRenameFiles): TBufferTexts;
var
  LPair: TPair<string, TRenameFile>;
begin
  Result := TBufferTexts.Create;
  for LPair in AFiles do
    if LPair.Value.LiveForm then
      Continue   // the designer's - it has no text here (TRenameFile)
    else if LPair.Value.OnDisk then
      Result.Add(LPair.Key, UTF8Encode(LPair.Value.Text))
    else
      Result.Add(LPair.Key, ReadModuleBufferUtf8(LPair.Value.Module));
end;

{ Pass one of two: every site is checked against the live buffer that is
  about to be rewritten. The plan's coordinates describe what the server
  last saw (forward) or what the rename wrote (backward), and the user may
  have typed since; a mismatch refuses the WHOLE pass, naming the file and
  line, rather than writing over whatever now sits there.

  Per EDIT rather than per rename, deliberately: a peer routine header's own
  parameter is a separate symbol and could, in already-broken code, be
  spelled differently from the one that was clicked.

  A SITE IS PENDING OR DONE, and ATolerant says whether Done is allowed at
  all. Pending reads what the pass replaces (the old name going forward, the
  new one coming back); Done already reads what the pass writes - after the
  form designer made its part of the rename (forward), or after a Ctrl+Z in
  a file the user had open (backward, always tolerated: Revert is how the
  other files follow). The strict forward pass, before anything happened,
  allows no Done at all.

  WHERE A SITE IS depends on its neighbours: the plan's column is in the text
  as it read BEFORE the rename, and every site to its left on the same line
  that now reads its new text has moved it by the difference between the two
  names. So each line's sites are walked left to right (the plan is sorted
  so) with that difference carried along. One fallback, for the backward
  pass only: a site whose LINE moved - the user added or removed lines above
  it in a file they had open - is found again if exactly one line reads the
  plan's post-rename text (Snippet). The forward pass has none: its plan is
  fresh from the analysis, and a mismatch means the analysis and the buffer
  disagree, which is a reason to stop.

  ASpots comes back with each site's actual row, column and state, so pass
  two writes where pass one looked. A site in a LiveForm file is ssLive and
  not looked at - the designer owns it. }
function VerifySites(const APlan: TLspRenamePlan; AFiles: TRenameFiles;
  ATexts: TBufferTexts; ADirection: TApplyDirection; ATolerant: Boolean;
  out ASpots: TSiteSpots; out AError: string): Boolean;
var
  LIdx, LShift, LCount: Integer;
  LText: UTF8String;
  LEdit: TLspRenameEdit;
  LFile: TRenameFile;
  LLine, LExpected, LTarget: string;
  LReadsExpected, LReadsTarget: Boolean;
begin
  Result := False;
  AError := '';
  SetLength(ASpots, Length(APlan.Edits));
  LShift := 0;
  for LIdx := 0 to High(APlan.Edits) do
  begin
    LEdit := APlan.Edits[LIdx];
    if (LIdx = 0) or (APlan.Edits[LIdx - 1].Row <> LEdit.Row) or
       not SameText(APlan.Edits[LIdx - 1].FilePath, LEdit.FilePath) then
      LShift := 0;
    ASpots[LIdx].Row := LEdit.Row;
    ASpots[LIdx].Col := LEdit.Col;
    if AFiles.TryGetValue(LowerCase(LEdit.FilePath), LFile) and
       LFile.LiveForm then
    begin
      ASpots[LIdx].State := ssLive;
      Continue;
    end;
    if not ATexts.TryGetValue(LowerCase(LEdit.FilePath), LText) then
      Exit;   // CollectFiles succeeded, so this cannot happen
    if LText = '' then
    begin
      AError := Format('%s has no editable buffer.',
        [ExtractFileName(LEdit.FilePath)]);
      Exit;
    end;
    LExpected := SiteExpected(LEdit, ADirection);
    LTarget := SiteReplacement(LEdit, ADirection);
    LLine := LineText(LText, LEdit.Row);
    ASpots[LIdx].Col := LEdit.Col + LShift;
    LReadsExpected := ReadsAt(LLine, ASpots[LIdx].Col, LExpected);
    LReadsTarget := ReadsAt(LLine, ASpots[LIdx].Col, LTarget);
    if LReadsExpected then
      ASpots[LIdx].State := ssPending
    else if LReadsTarget and (ATolerant or (ADirection = adBackward)) then
      ASpots[LIdx].State := ssDone
    else if ADirection = adBackward then
    begin
      // The line moved: found again by its post-rename text, where every
      // site on it reads the new name.
      ASpots[LIdx].Row := UniqueRowReading(LText, LEdit.Snippet, LCount);
      if ASpots[LIdx].Row = 0 then
      begin
        TraceFmt('  %s: line %d not where it was and its text matches %d ' +
          'line(s)', [ExtractFileName(LEdit.FilePath), LEdit.Row, LCount]);
        AError := Format('%s line %d no longer reads "%s" - the file has ' +
          'been edited since the rename.'#13#10#13#10 +
          'Nothing was reverted. Undo the edit there (or put "%s" back by ' +
          'hand) and press Revert again.',
          [ExtractFileName(LEdit.FilePath), LEdit.Row, LEdit.NewText,
           LEdit.NewText]);
        Exit;
      end;
      TraceFmt('  %s: line %d moved to %d - found by its text',
        [ExtractFileName(LEdit.FilePath), LEdit.Row, ASpots[LIdx].Row]);
      ASpots[LIdx].Col := SiteCol(APlan, LIdx, adBackward);
      ASpots[LIdx].State := ssPending;
    end
    else
    begin
      AError := Format('%s line %d no longer reads "%s" - the buffer has ' +
        'changed since the last analysis.'#13#10#13#10 +
        'Nothing was renamed. Try again in a moment.',
        [ExtractFileName(LEdit.FilePath), LEdit.Row, LEdit.OldText]);
      Exit;
    end;
    // What this site reads NOW moves the ones after it on the line.
    if ((ADirection = adForward) and (ASpots[LIdx].State = ssDone)) or
       ((ADirection = adBackward) and (ASpots[LIdx].State = ssPending)) then
      Inc(LShift, Length(LEdit.NewText) - Length(LEdit.OldText));
  end;
  Result := True;
end;

{ Pass two, one FILE. The sites' byte offsets are all resolved first, against
  the bytes pass one verified - a writer's positions address the ORIGINAL
  text, so converting inside the loop would read a buffer the earlier writes
  had already changed (see ApplyClassComplete, which learned that the
  expensive way). Within the file the edits go ASCENDING; the plan is sorted
  so, and a backward pass keeps that order because it shifts columns rather
  than reordering. A site that is not Pending (see VerifySites) is left
  alone; a file where no site is, is not touched at all.

  An OPEN file goes through one IOTASourceEditor.CreateUndoableWriter, so the
  file's pass is one Ctrl+Z in its tab. A DISK file is spliced in memory and
  the result held in AFiles until Save writes it - nothing reaches the disk
  from here. }
procedure WriteFile(AFiles: TRenameFiles; const AKey: string;
  const AText: UTF8String; const APlan: TLspRenamePlan;
  const ASpots: TSiteSpots; AFrom, ATo: Integer;
  ADirection: TApplyDirection);
var
  LFile: TRenameFile;
  LIdx, LFrom: Integer;
  LAny: Boolean;
  LWriter: IOTAEditWriter;
  LOffsets: TArray<Integer>;
  LExpected: string;
  LOut: UTF8String;
begin
  if not AFiles.TryGetValue(AKey, LFile) or LFile.LiveForm then
    Exit;
  SetLength(LOffsets, ATo - AFrom + 1);
  LAny := False;
  for LIdx := AFrom to ATo do
  begin
    if ASpots[LIdx].State <> ssPending then
    begin
      LOffsets[LIdx - AFrom] := cAlreadyDone;
      Continue;
    end;
    LAny := True;
    LOffsets[LIdx - AFrom] := SiteByteOffset(AText, ASpots[LIdx].Row,
      ASpots[LIdx].Col);
    if LOffsets[LIdx - AFrom] < 0 then
      Exit;   // pass one just found this line; a miss here is a logic error
  end;
  if not LAny then
    Exit;

  if LFile.OnDisk then
  begin
    // The same walk a writer makes - copy up to the site, skip what it
    // read, put the replacement - over a string instead of a buffer.
    LOut := '';
    LFrom := 0;
    for LIdx := AFrom to ATo do
    begin
      if LOffsets[LIdx - AFrom] = cAlreadyDone then
        Continue;
      LExpected := SiteExpected(APlan.Edits[LIdx], ADirection);
      LOut := LOut + Copy(AText, LFrom + 1, LOffsets[LIdx - AFrom] - LFrom) +
        UTF8Encode(SiteReplacement(APlan.Edits[LIdx], ADirection));
      LFrom := LOffsets[LIdx - AFrom] + Length(UTF8Encode(LExpected));
    end;
    LOut := LOut + Copy(AText, LFrom + 1, MaxInt);
    LFile.Text := UTF8ToString(LOut);
    AFiles.AddOrSetValue(AKey, LFile);
    Exit;
  end;

  LWriter := LFile.Editor.CreateUndoableWriter;
  if not Assigned(LWriter) then
    Exit;
  try
    for LIdx := AFrom to ATo do
    begin
      if LOffsets[LIdx - AFrom] = cAlreadyDone then
        Continue;
      LExpected := SiteExpected(APlan.Edits[LIdx], ADirection);
      LWriter.CopyTo(LOffsets[LIdx - AFrom]);
      LWriter.DeleteTo(LOffsets[LIdx - AFrom] +
        Length(UTF8Encode(LExpected)));
      // The site's OWN new text: a unit rename writes the full dotted name
      // where the reference was written in full and the bare leaf where a
      // namespace prefix resolved it, on the same line.
      LWriter.Insert(UTF8String(SiteReplacement(APlan.Edits[LIdx],
        ADirection)));
    end;
  finally
    LWriter := nil;   // the writer commits on release
  end;
  // The document sync re-reads a buffer when its change count moved, and
  // that count is fed by an editor VIEW notifier - which a module loaded
  // behind a form, with no view, never fires. Said explicitly.
  NoteBufferModified(LFile.Path);
  if LFile.Editor.GetEditViewCount > 0 then
    LFile.Editor.GetEditView(0).Paint;
end;

{ ---- The form designer -------------------------------------------------------

  Everything a rename asks of a LOADED form's designer - see TDesignerAction
  for the shape and local/DFM-PLAN.md for the four spike runs the facts come
  from. The rule of this section: nothing is asked of the designer that
  cannot be checked afterwards, and what is checked is exactly what the plan
  expects - a designer that did more, or less, is undone before anything
  else is written. }

function Opposite(ADirection: TApplyDirection): TApplyDirection;
begin
  if ADirection = adForward then
    Result := adBackward
  else
    Result := adForward;
end;

{ The name the designer holds now and the one it is to hold, by direction:
  forward it holds OldName, and Revert runs the other way. }
procedure ActionNames(const AOld, ANew: string; ADirection: TApplyDirection;
  out AFrom, ATo: string);
begin
  if ADirection = adForward then
  begin
    AFrom := AOld;
    ATo := ANew;
  end
  else
  begin
    AFrom := ANew;
    ATo := AOld;
  end;
end;

// One line for the trace: what the designer is about to be asked.
function DescribeAction(const AAction: TDesignerAction;
  ADirection: TApplyDirection): string;
var
  LFrom, LTo: string;
begin
  ActionNames(AAction.OldName, AAction.NewName, ADirection, LFrom, LTo);
  case AAction.Kind of
    dakComponent:
      Result := Format('%s: component %s -> %s through its Name (%d handler(s) ' +
        'named after it)', [ExtractFileName(AAction.FormFile), LFrom, LTo,
        Length(AAction.Handlers)]);
    dakHandler:
      Result := Format('%s: IDesigner.RenameMethod(%s, %s)',
        [ExtractFileName(AAction.FormFile), LFrom, LTo]);
  else
    Result := 'none';
  end;
end;

{ WHETHER THE DESIGNER CAN DO THIS RENAME, and which designer. dakNone (and
  True) when no form of the plan is loaded - the plain path. Otherwise the
  rename must be one the spike runs showed the designer doing whole, or it is
  refused before anything is touched (False, AError for the user):

  - a component: the form of the class that declares it must be loaded (its
    designer sets the Name); every carried handler linked in a loaded form
    must be that same form's own method - the one designer renames only its
    own. Sites inside an inline frame's block follow the frame's designer
    live (spike run 5, F), and so do descendants and other modules;
  - a handler: the form of the class that declares it must be loaded (its
    designer runs RenameMethod), and every OTHER loaded form that links it -
    a descendant, or one inside an inline block of a descendant host - must
    have a designer, where its links are re-assigned afterwards (Relinks,
    run 5, R and I);
  - anything else a loaded form names (a class) is refused as before.

  Until 0.58.0 an inline site and a handler linked by another loaded form
  were refused too - before spike run 5 measured what the designer does
  there. }
function ResolveDesignerAction(const APlan: TLspRenamePlan;
  AFiles: TRenameFiles; out AAction: TDesignerAction;
  out AError: string): Boolean;
const
  cCloseHint = #13#10#13#10'Close it and rename again. A form that uses it ' +
    'keeps it loaded too, so File > Close All is the sure way.'#13#10#13#10 +
    'Nothing was renamed.';
var
  LPair: TPair<string, TRenameFile>;
  LLive: string;
  LEdit: TLspRenameEdit;
  LFile: TRenameFile;
  LCarried: TLspCarriedRename;
  LLinkedLive: Boolean;
  LHandlers: TArray<string>;
begin
  Result := False;
  AAction := Default(TDesignerAction);
  AError := '';
  LLive := '';
  for LPair in AFiles do
    if LPair.Value.LiveForm then
    begin
      LLive := LPair.Value.Path;
      Break;
    end;
  if LLive = '' then
    Exit(True);
  AAction.OldName := APlan.OldName;
  AAction.NewName := APlan.NewName;
  AAction.FormFile := APlan.FormRole.FormFile;
  if SameText(APlan.FormRole.Kind, 'component') then
    AAction.Kind := dakComponent
  else if SameText(APlan.FormRole.Kind, 'handler') then
    AAction.Kind := dakHandler
  else
  begin
    AError := Format('The form of %s is loaded in the IDE, and its form file ' +
      'is part of this rename - renaming %s there through the form designer ' +
      'is not supported yet, and the designer would write the old name back ' +
      'the next time it saves.%s', [ExtractFileName(LLive), APlan.OldName,
      cCloseHint]);
    Exit;
  end;
  if (AAction.FormFile = '') or
     not Assigned(FormOwnerModule(AAction.FormFile)) then
  begin
    AError := Format('The form of %s is loaded in the IDE and names %s, but ' +
      'the form of the class that declares it (%s) is not - the designer ' +
      'that would rename it is not there.%s', [ExtractFileName(LLive),
      APlan.OldName, APlan.FormRole.OwnerClass, cCloseHint]);
    Exit;
  end;
  for LCarried in APlan.Carried do
  begin
    if SameFile(LCarried.Role.FormFile, AAction.FormFile) then
    begin
      AAction.Handlers := AAction.Handlers + [LCarried];
      Continue;
    end;
    LLinkedLive := (LCarried.Role.FormFile <> '') and
      Assigned(FormOwnerModule(LCarried.Role.FormFile));
    for LEdit in APlan.Edits do
      if SameText(LEdit.FormKind, 'handler') and
         SameText(LEdit.OldText, LCarried.OldName) and
         AFiles.TryGetValue(LowerCase(LEdit.FilePath), LFile) and
         LFile.LiveForm then
        LLinkedLive := True;
    if LLinkedLive then
    begin
      AError := Format('Renaming %s also renames %s, the handler named after ' +
        'it, which belongs to %s - and a form that links it is loaded. The ' +
        'designer of %s renames only its own handlers.%s', [APlan.OldName,
        LCarried.OldName, LCarried.Role.OwnerClass,
        ExtractFileName(AAction.FormFile), cCloseHint]);
      Exit;
    end;
  end;
  // The handlers the designer renames - the one, or a component's carried
  // ones - and every other loaded form that links one of them.
  if AAction.Kind = dakHandler then
    LHandlers := [APlan.OldName]
  else
  begin
    LHandlers := nil;
    for LCarried in AAction.Handlers do
      LHandlers := LHandlers + [LCarried.OldName];
  end;
  for LEdit in APlan.Edits do
  begin
    if not SameText(LEdit.FormKind, 'handler') or
       (IndexText(LEdit.OldText, LHandlers) < 0) or
       SameFile(LEdit.FilePath, AAction.FormFile) or
       not AFiles.TryGetValue(LowerCase(LEdit.FilePath), LFile) or
       not LFile.LiveForm or
       (IndexText(LEdit.FilePath, AAction.Relinks) >= 0) then
      Continue;
    if not Assigned(DesignerOf(LFile.Module)) then
    begin
      AError := Format('%s is loaded and links the handler %s (line %d), but ' +
        'its form designer is not available to take the new name.%s',
        [ExtractFileName(LEdit.FilePath), LEdit.OldText, LEdit.Row,
         cCloseHint]);
      Exit;
    end;
    AAction.Relinks := AAction.Relinks + [LEdit.FilePath];
  end;
  Result := True;
end;

{ The handlers the IDE renames when component AComp's Name goes from AFrom to
  ATo, predicted from the LIVE component the way the designer decides it
  (measured, 2026-09-27): each event of the component whose handler is named
  AFrom + the event's name without "On" becomes ATo + that suffix. Pairs as
  'old=new', the new name in the case the designer will write it. }
function PredictHandlerRenames(const AComp: IOTAComponent;
  const ADesigner: IDesigner; const AFrom, ATo: string): TArray<string>;
var
  LNta: INTAComponent;
  LObj: TComponent;
  LProps: PPropList;
  LCount, LIdx: Integer;
  LMethod: TMethod;
  LName, LSuffix, LPair: string;
begin
  Result := nil;
  if not Supports(AComp, INTAComponent, LNta) or
     not Assigned(LNta.GetComponent) then
    Exit;
  LObj := LNta.GetComponent;
  LCount := GetPropList(LObj.ClassInfo, [tkMethod], nil);
  if LCount <= 0 then
    Exit;
  GetMem(LProps, LCount * SizeOf(PPropInfo));
  try
    GetPropList(LObj.ClassInfo, [tkMethod], LProps);
    for LIdx := 0 to LCount - 1 do
    begin
      LMethod := GetMethodProp(LObj, LProps^[LIdx]);
      if LMethod.Code = nil then
        Continue;
      LName := ADesigner.GetMethodName(LMethod);
      LSuffix := string(LProps^[LIdx]^.Name);
      if (Length(LSuffix) >= 2) and SameText(Copy(LSuffix, 1, 2), 'On') then
        Delete(LSuffix, 1, 2);
      if (LName = '') or not SameText(LName, AFrom + LSuffix) then
        Continue;
      LPair := LowerCase(LName) + '=' + ATo + LSuffix;
      if IndexStr(LPair, Result) < 0 then
        Result := Result + [LPair];
    end;
  finally
    FreeMem(LProps);
  end;
end;

// The carried renames the designer is to make, as PredictHandlerRenames
// spells them, by direction.
function ExpectedHandlerRenames(const AAction: TDesignerAction;
  ADirection: TApplyDirection): TArray<string>;
var
  LCarried: TLspCarriedRename;
  LFrom, LTo: string;
begin
  Result := nil;
  for LCarried in AAction.Handlers do
  begin
    ActionNames(LCarried.OldName, LCarried.NewName, ADirection, LFrom, LTo);
    Result := Result + [LowerCase(LFrom) + '=' + LTo];
  end;
end;

// Case-insensitively, as Pascal names are: the designer writing a handler
// back as `GoButtonClick` where it once read `GoButtonclick` is the same one.
function SameStringSets(const A, B: TArray<string>): Boolean;
var
  LItem: string;
begin
  Result := Length(A) = Length(B);
  if Result then
    for LItem in A do
      if IndexText(LItem, B) < 0 then
        Exit(False);
end;

{ BEFORE the designer is asked anything: it must hold the name to rename and
  not the one to rename to, and - for a component - the handlers it will
  rename along must be exactly the plan's carried ones. The plan was made
  from the form file on disk and the designer holds the form as it is now;
  a difference means the form has unsaved changes, or the designer decides
  differently from how the plan was told it does, and either way the result
  would not be the plan's. }
function CheckDesignerReady(const AAction: TDesignerAction;
  ADirection: TApplyDirection; out AError: string): Boolean;
var
  LModule: IOTAModule;
  LFE: IOTAFormEditor;
  LDesigner: IDesigner;
  LComp: IOTAComponent;
  LFrom, LTo, LForm: string;
  LPredicted, LExpected: TArray<string>;
  LPair: string;
  LParts: TArray<string>;
begin
  Result := False;
  AError := '';
  ActionNames(AAction.OldName, AAction.NewName, ADirection, LFrom, LTo);
  LForm := ExtractFileName(AAction.FormFile);
  LModule := FormOwnerModule(AAction.FormFile);
  LFE := FormEditorOf(LModule);
  LDesigner := DesignerOf(LModule);
  if not Assigned(LFE) or not Assigned(LDesigner) then
  begin
    AError := Format('The form designer of %s is not available.%s', [LForm,
      #13#10#13#10'Nothing was renamed.']);
    Exit;
  end;
  case AAction.Kind of
    dakComponent:
      begin
        LComp := LFE.FindComponent(LFrom);
        if not Assigned(LComp) then
        begin
          AError := Format('The form designer of %s has no component named ' +
            '%s - the form in the designer differs from the file. Save the ' +
            'form and rename again.'#13#10#13#10'Nothing was renamed.',
            [LForm, LFrom]);
          Exit;
        end;
        if Assigned(LFE.FindComponent(LTo)) then
        begin
          AError := Format('The form designer of %s already has a component ' +
            'named %s.'#13#10#13#10'Nothing was renamed.', [LForm, LTo]);
          Exit;
        end;
        LPredicted := PredictHandlerRenames(LComp, LDesigner, LFrom, LTo);
        LExpected := ExpectedHandlerRenames(AAction, ADirection);
        TraceFmt('  designer will rename the handler(s) [%s]; the plan ' +
          'carries [%s]', [string.Join(', ', LPredicted),
          string.Join(', ', LExpected)]);
        if not SameStringSets(LPredicted, LExpected) then
        begin
          AError := Format('The form designer of %s would rename the ' +
            'handlers named after %s differently from the plan (designer: ' +
            '%s; plan: %s) - the form in the designer differs from the file. ' +
            'Save the form and rename again.'#13#10#13#10'Nothing was renamed.',
            [LForm, LFrom, IfThen(Length(LPredicted) = 0, 'none',
             string.Join(', ', LPredicted)), IfThen(Length(LExpected) = 0,
             'none', string.Join(', ', LExpected))]);
          Exit;
        end;
        for LPair in LExpected do
        begin
          LParts := LPair.Split(['=']);
          if LDesigner.MethodExists(LParts[1]) then
          begin
            AError := Format('%s already has a method named %s - the ' +
              'handler %s cannot take that name.'#13#10#13#10'Nothing was ' +
              'renamed.', [LForm, LParts[1], LParts[0]]);
            Exit;
          end;
        end;
      end;
    dakHandler:
      begin
        if not LDesigner.MethodExists(LFrom) then
        begin
          AError := Format('The form designer of %s has no method named %s - ' +
            'the form in the designer differs from the file. Save the form ' +
            'and rename again.'#13#10#13#10'Nothing was renamed.', [LForm,
            LFrom]);
          Exit;
        end;
        if LDesigner.MethodExists(LTo) then
        begin
          AError := Format('%s already has a method named %s.'#13#10#13#10 +
            'Nothing was renamed.', [LForm, LTo]);
          Exit;
        end;
      end;
  end;
  Result := True;
end;

{ The designer, asked. Guarded: the designer raises on a name it will not
  take (EComponentError, EModuleError - a form Name may not equal a unit's). }
function RunDesignerAction(const AAction: TDesignerAction;
  ADirection: TApplyDirection; out AError: string): Boolean;
var
  LModule: IOTAModule;
  LComp: IOTAComponent;
  LDesigner: IDesigner;
  LFrom, LTo, LName: string;
begin
  Result := False;
  AError := '';
  ActionNames(AAction.OldName, AAction.NewName, ADirection, LFrom, LTo);
  LModule := FormOwnerModule(AAction.FormFile);
  try
    case AAction.Kind of
      dakComponent:
        begin
          LComp := FormEditorOf(LModule).FindComponent(LFrom);
          LName := LTo;
          Result := Assigned(LComp) and LComp.SetPropByName('Name', LName);
          if not Result then
            AError := Format('The form designer of %s did not take the name ' +
              '%s.', [ExtractFileName(AAction.FormFile), LTo]);
        end;
      dakHandler:
        begin
          LDesigner := DesignerOf(LModule);
          Result := Assigned(LDesigner);
          if Result then
            LDesigner.RenameMethod(LFrom, LTo);
        end;
    end;
  except
    on E: Exception do
    begin
      AError := Format('The form designer of %s refused: %s (%s)',
        [ExtractFileName(AAction.FormFile), E.Message, E.ClassName]);
      Result := False;
    end;
  end;
  // The IDE applies what the designer did to the source buffer by the time
  // this returns; the spike runs read it after one message pump, and so does
  // this.
  Application.ProcessMessages;
end;

{ AFTER the designer: it holds the new name and not the old one - the
  component, and each handler it was to rename with it. }
function CheckDesignerResult(const AAction: TDesignerAction;
  ADirection: TApplyDirection; out AError: string): Boolean;
var
  LModule: IOTAModule;
  LFE: IOTAFormEditor;
  LDesigner: IDesigner;
  LFrom, LTo, LPair: string;
  LParts: TArray<string>;
begin
  Result := False;
  AError := '';
  ActionNames(AAction.OldName, AAction.NewName, ADirection, LFrom, LTo);
  LModule := FormOwnerModule(AAction.FormFile);
  LFE := FormEditorOf(LModule);
  LDesigner := DesignerOf(LModule);
  if not Assigned(LFE) or not Assigned(LDesigner) then
  begin
    AError := 'The form designer went away during the rename.';
    Exit;
  end;
  case AAction.Kind of
    dakComponent:
      begin
        if not Assigned(LFE.FindComponent(LTo)) or
           Assigned(LFE.FindComponent(LFrom)) then
        begin
          AError := Format('After the rename the form designer does not hold ' +
            'the component as %s.', [LTo]);
          Exit;
        end;
        for LPair in ExpectedHandlerRenames(AAction, ADirection) do
        begin
          LParts := LPair.Split(['=']);
          if not LDesigner.MethodExists(LParts[1]) or
             LDesigner.MethodExists(LParts[0]) then
          begin
            AError := Format('After the rename the form designer did not ' +
              'rename the handler %s to %s.', [LParts[0], LParts[1]]);
            Exit;
          end;
        end;
      end;
    dakHandler:
      if not LDesigner.MethodExists(LTo) or LDesigner.MethodExists(LFrom) then
      begin
        AError := Format('After the rename the form designer does not hold ' +
          'the method as %s.', [LTo]);
        Exit;
      end;
  end;
  Result := True;
end;

{ A LOADED FORM'S LINKS TO A RENAMED HANDLER, ASSIGNED AGAIN, after the
  designer of the form that declares the handler renamed it. Measured, spike
  run 5 (R, I): a loaded descendant's link reads the new name through its
  designer at once, but its form stream - what Save writes - keeps the old
  one until the event is assigned again; SetMethodProp with the TMethod the
  event already holds then writes the new name, marks only the form file
  modified and adds no stub (CreateMethod would add an `inherited;` one).

  Every event of every component under the form's root is looked at - the
  root's own, and those inside an inline frame's block, where a host's
  handler is linked on the frame's child (I) - and each that reads one of
  ANames (the names the handlers have NOW) is assigned its own value back.
  The count comes back for the trace; the saved file is what is checked
  (ConfirmLiveForms). -1: no designer. }
function RelinkHandlers(const AFormFile: string;
  const ANames: TArray<string>): Integer;
var
  LDesigner: IDesigner;
  LCount: Integer;

  procedure Walk(AComp: TComponent);
  var
    LProps: PPropList;
    LPropCount, LIdx: Integer;
    LMethod: TMethod;
    LName: string;
  begin
    LPropCount := GetPropList(AComp.ClassInfo, [tkMethod], nil);
    if LPropCount > 0 then
    begin
      GetMem(LProps, LPropCount * SizeOf(PPropInfo));
      try
        GetPropList(AComp.ClassInfo, [tkMethod], LProps);
        for LIdx := 0 to LPropCount - 1 do
        begin
          LMethod := GetMethodProp(AComp, LProps^[LIdx]);
          if LMethod.Code = nil then
            Continue;
          try
            LName := LDesigner.GetMethodName(LMethod);
          except
            LName := '';   // not a method this designer knows
          end;
          if (LName = '') or (IndexText(LName, ANames) < 0) then
            Continue;
          SetMethodProp(AComp, LProps^[LIdx], LMethod);
          Inc(LCount);
          TraceFmt('  %s: %s.%s = %s assigned again',
            [ExtractFileName(AFormFile), AComp.Name,
             string(LProps^[LIdx]^.Name), LName]);
        end;
      finally
        FreeMem(LProps);
      end;
    end;
    for LIdx := 0 to AComp.ComponentCount - 1 do
      Walk(AComp.Components[LIdx]);
  end;

begin
  LDesigner := DesignerOf(FormOwnerModule(AFormFile));
  if not Assigned(LDesigner) or not Assigned(LDesigner.Root) then
    Exit(-1);
  LCount := 0;
  Walk(LDesigner.Root);
  if LCount > 0 then
    LDesigner.Modified;
  Result := LCount;
end;

// RelinkHandlers over every form of AAction.Relinks, with the names the
// handlers have after the designer ran in ADirection.
procedure RelinkLiveForms(const AAction: TDesignerAction;
  ADirection: TApplyDirection);
var
  LNames: TArray<string>;
  LCarried: TLspCarriedRename;
  LFrom, LTo, LForm: string;
  LCount: Integer;
begin
  if Length(AAction.Relinks) = 0 then
    Exit;
  LNames := nil;
  if AAction.Kind = dakHandler then
  begin
    ActionNames(AAction.OldName, AAction.NewName, ADirection, LFrom, LTo);
    LNames := [LTo];
  end
  else
    for LCarried in AAction.Handlers do
    begin
      ActionNames(LCarried.OldName, LCarried.NewName, ADirection, LFrom, LTo);
      LNames := LNames + [LTo];
    end;
  for LForm in AAction.Relinks do
  begin
    LCount := RelinkHandlers(LForm, LNames);
    if LCount < 0 then
      TraceFmt('  %s: no form designer - its links were not assigned again',
        [ExtractFileName(LForm)])
    else
      TraceFmt('  %s: %d link(s) to [%s] assigned again',
        [ExtractFileName(LForm), LCount, string.Join(', ', LNames)]);
  end;
end;

function SplitLines(const AText: UTF8String): TArray<string>;
begin
  Result := UTF8ToString(AText).Replace(#13#10, #10).Split([#10]);
end;

{ EVERY LINE THE DESIGNER CHANGED MUST BE ONE THE PLAN EXPLAINS: a changed
  line must read exactly its old text with the plan's sites that went from
  Pending to Done (APre -> APost) replaced - nothing else on it, and no line
  added or removed. A designer that renamed one handler more than the plan
  carries, or reformatted a declaration, fails here, and is undone. }
function ExplainChanges(const APlan: TLspRenamePlan; ABefore,
  AAfter: TBufferTexts; const APre, APost: TSiteSpots;
  ADirection: TApplyDirection; out AError: string): Boolean;
var
  LPair: TPair<string, UTF8String>;
  LBeforeText: UTF8String;
  LOld, LNew: TArray<string>;
  LRow, LIdx, LDelta: Integer;
  LLine, LFrom, LTo: string;
begin
  Result := False;
  AError := '';
  for LPair in AAfter do
  begin
    if not ABefore.TryGetValue(LPair.Key, LBeforeText) or
       (LBeforeText = LPair.Value) then
      Continue;
    LOld := SplitLines(LBeforeText);
    LNew := SplitLines(LPair.Value);
    if Length(LOld) <> Length(LNew) then
    begin
      AError := Format('The form designer added or removed lines in %s ' +
        '(%d -> %d), which the plan does not do.', [ExtractFileName(LPair.Key),
        Length(LOld), Length(LNew)]);
      Exit;
    end;
    for LRow := 1 to Length(LOld) do
    begin
      if LOld[LRow - 1] = LNew[LRow - 1] then
        Continue;
      LLine := LOld[LRow - 1];
      LDelta := 0;
      for LIdx := 0 to High(APlan.Edits) do
      begin
        if (APre[LIdx].Row <> LRow) or (APre[LIdx].State <> ssPending) or
           (APost[LIdx].State <> ssDone) or
           not SameText(LowerCase(APlan.Edits[LIdx].FilePath), LPair.Key) then
          Continue;
        if ADirection = adForward then
        begin
          LFrom := APlan.Edits[LIdx].OldText;
          LTo := APlan.Edits[LIdx].NewText;
        end
        else
        begin
          LFrom := APlan.Edits[LIdx].NewText;
          LTo := APlan.Edits[LIdx].OldText;
        end;
        LLine := Copy(LLine, 1, APre[LIdx].Col - 1 + LDelta) + LTo +
          Copy(LLine, APre[LIdx].Col + LDelta + Length(LFrom), MaxInt);
        Inc(LDelta, Length(LTo) - Length(LFrom));
      end;
      if not SameText(LLine, LNew[LRow - 1]) then
      begin
        AError := Format('The form designer changed %s line %d in a way the ' +
          'plan does not explain:'#13#10'  was: %s'#13#10'  now: %s',
          [ExtractFileName(LPair.Key), LRow, Trim(LOld[LRow - 1]),
           Trim(LNew[LRow - 1])]);
        Exit;
      end;
    end;
  end;
  Result := True;
end;

{ The designer's change undone, after a check refused it - the same request
  the other way round, which the designer answers with the exact inverse
  (the spike runs renamed every component and handler back and forth this
  way). AError is extended with what the user needs to know: whether every
  buffer reads again what it read before. }
procedure UndoDesigner(const AAction: TDesignerAction;
  ADirection: TApplyDirection; AFiles: TRenameFiles; ABefore: TBufferTexts;
  var AError: string);
var
  LUndoError: string;
  LNow: TBufferTexts;
  LPair: TPair<string, UTF8String>;
  LNowText: UTF8String;
  LDiffers: string;
begin
  Trace('  undoing the designer''s change: ' +
    DescribeAction(AAction, Opposite(ADirection)));
  if not RunDesignerAction(AAction, Opposite(ADirection), LUndoError) then
    Trace('  undo FAILED: ' + LUndoError);
  LNow := ReadBuffers(AFiles);
  try
    LDiffers := '';
    for LPair in ABefore do
      if LNow.TryGetValue(LPair.Key, LNowText) and (LNowText <> LPair.Value) then
        LDiffers := LDiffers + ' ' + ExtractFileName(LPair.Key);
  finally
    LNow.Free;
  end;
  if LDiffers = '' then
    AError := AError + #13#10#13#10'The form designer''s change was undone. ' +
      'Nothing was renamed.'
  else
  begin
    Trace('  after the undo these still differ:' + LDiffers);
    AError := AError + #13#10#13#10'The form designer''s change could NOT be ' +
      'undone completely - these files differ from before:' + LDiffers +
      '. Check them (Ctrl+Z there) before saving.';
  end;
end;

// Every open buffer the designer changed, told to the document sync - see
// WriteFile on why a buffer with no view needs saying.
procedure NoteChangedBuffers(AFiles: TRenameFiles; ABefore,
  AAfter: TBufferTexts);
var
  LPair: TPair<string, UTF8String>;
  LBeforeText: UTF8String;
  LFile: TRenameFile;
begin
  for LPair in AAfter do
    if ABefore.TryGetValue(LPair.Key, LBeforeText) and
       (LBeforeText <> LPair.Value) and AFiles.TryGetValue(LPair.Key, LFile) and
       not LFile.OnDisk then
      NoteBufferModified(LFile.Path);
end;

{ Verify EVERYTHING, then write - the two passes the unit header describes,
  in either direction, over files CollectFiles has already gathered.

  With a DESIGNER ACTION the designer goes between the two: verified first
  (every site still reads what it should), then asked (CheckDesignerReady,
  RunDesignerAction), then checked - every site reads its old or its new
  text, every line it changed is one the plan explains, it holds the new
  names - and only then are the other loaded forms' links to a renamed
  handler assigned again (RelinkLiveForms) and the rest written, the sites
  it already did left alone (Done). A check that fails undoes the designer's
  change and writes nothing. }
function ApplyDirection(const APlan: TLspRenamePlan; AFiles: TRenameFiles;
  ADirection: TApplyDirection; const AAction: TDesignerAction;
  out AError: string): Boolean;
var
  LTexts, LAfter: TBufferTexts;
  LSpots, LPost: TSiteSpots;
  LText: UTF8String;
  LKey: string;
  LIdx, LRun, LDone: Integer;
begin
  Result := False;
  LAfter := nil;
  LTexts := ReadBuffers(AFiles);
  try
    Trace('verifying every site against the text that will be rewritten');
    if not VerifySites(APlan, AFiles, LTexts, ADirection, False, {out} LSpots,
      {out} AError) then
    begin
      Trace('verify FAILED: ' + AError);
      Exit;
    end;
    if AAction.Kind <> dakNone then
    begin
      Trace('designer: ' + DescribeAction(AAction, ADirection));
      if Length(AAction.Relinks) > 0 then
        TraceFmt('  then the links in %d other loaded form(s) assigned ' +
          'again: %s', [Length(AAction.Relinks), string.Join(', ',
          AAction.Relinks)]);
      if not CheckDesignerReady(AAction, ADirection, {out} AError) then
      begin
        Trace('designer not ready: ' + AError);
        Exit;
      end;
      if not RunDesignerAction(AAction, ADirection, {out} AError) then
      begin
        Trace('designer FAILED: ' + AError);
        UndoDesigner(AAction, ADirection, AFiles, LTexts, AError);
        Exit;
      end;
      LAfter := ReadBuffers(AFiles);
      if not VerifySites(APlan, AFiles, LAfter, ADirection, True, {out} LPost,
           {out} AError) or
         not ExplainChanges(APlan, LTexts, LAfter, LSpots, LPost, ADirection,
           {out} AError) or
         not CheckDesignerResult(AAction, ADirection, {out} AError) then
      begin
        Trace('designer result REJECTED: ' + AError);
        UndoDesigner(AAction, ADirection, AFiles, LTexts, AError);
        Exit;
      end;
      LDone := 0;
      for LIdx := 0 to High(LPost) do
        if LPost[LIdx].State = ssDone then
          Inc(LDone);
      TraceFmt('designer done: %d site(s) already renamed by it', [LDone]);
      RelinkLiveForms(AAction, ADirection);
      NoteChangedBuffers(AFiles, LTexts, LAfter);
      LTexts.Free;
      LTexts := LAfter;
      LAfter := nil;
      LSpots := LPost;
    end;
    Trace('verified; writing');
    LIdx := 0;
    while LIdx <= High(APlan.Edits) do
    begin
      // The run of edits belonging to one file - the plan is sorted by file.
      LRun := LIdx;
      while (LRun < High(APlan.Edits)) and
            SameText(APlan.Edits[LRun + 1].FilePath,
              APlan.Edits[LIdx].FilePath) do
        Inc(LRun);
      LKey := LowerCase(APlan.Edits[LIdx].FilePath);
      if LTexts.TryGetValue(LKey, LText) then
      begin
        WriteFile(AFiles, LKey, LText, APlan, LSpots, LIdx, LRun, ADirection);
        TraceFmt('  %s: %d edit(s) applied',
          [ExtractFileName(APlan.Edits[LIdx].FilePath), LRun - LIdx + 1]);
      end
      else if LSpots[LIdx].State = ssLive then
        TraceFmt('  %s: %d edit(s) left to the form designer',
          [ExtractFileName(APlan.Edits[LIdx].FilePath), LRun - LIdx + 1]);
      LIdx := LRun + 1;
    end;
    Result := True;
  finally
    LAfter.Free;
    LTexts.Free;
  end;
end;

{ Gather every touched file, decide what the form designer has to do, then
  the forward pass. On success AFiles is handed to the caller (for Save and
  Revert) with AAction saying what the designer did; on refusal it is freed
  here and the user has been told why. }
function ApplyPlan(const APlan: TLspRenamePlan; out ADiskCount: Integer;
  out AFiles: TRenameFiles; out AAction: TDesignerAction): Boolean;
var
  LError: string;
begin
  Result := False;
  ADiskCount := 0;
  AAction := Default(TDesignerAction);
  AFiles := TRenameFiles.Create;
  try
    TraceFmt('applying %d edit(s) - gathering files', [Length(APlan.Edits)]);
    if not CollectFiles(APlan, AFiles, {out} ADiskCount, {out} LError) or
       not ResolveDesignerAction(APlan, AFiles, {out} AAction, {out} LError) or
       not ApplyDirection(APlan, AFiles, adForward, AAction, {out} LError) then
    begin
      CloseWaitDialog;
      TellUser(LError, mtError);
      Exit;
    end;
    Result := True;
  finally
    if not Result then
      FreeAndNil(AFiles);
  end;
end;

{ ---- Revert ---------------------------------------------------------------- }

{ The rename that was waiting for Revert is over, one way or the other. }
procedure DropApplied;
begin
  FreeAndNil(GApplied);
end;

{ Every file in AFiles to disk: an open one through its module (Save(False,
  True) - keep the name, no question asked; a module here is one the IDE
  already had, so nothing is closed and its .dfm is the IDE's own affair), a
  disk one through TryWriteSource in the encoding it came in. The disk paths
  come back for the server, which has no other way of hearing about them.
  ASaved and AFailed count; a failure is logged with the file.

  A LIVE FORM is saved through its module too - after its form editor is
  marked modified. The designer updates a loaded descendant, or a form that
  references a renamed component of another module, LIVE, and leaves it
  unmodified (spike run 3): unsaved, its form file would keep the old names.
  Marked and saved, it writes the new ones (run 4, verified on disk).
  AFirstForm's module goes first - the form whose designer made the rename,
  which a descendant is written against. A module shared by two entries
  (the unit and its form file) is saved once. }
procedure SaveFiles(AFiles: TRenameFiles; const AFirstForm: string;
  out ASaved, AFailed: Integer; out ADiskPaths: TArray<string>);
var
  LPair: TPair<string, TRenameFile>;
  LFile: TRenameFile;
  LOk: Boolean;
  LSaved: TStringList;
  LFE: IOTAFormEditor;

  function SaveModule(const AModule: IOTAModule): Boolean;
  begin
    if not Assigned(AModule) then
      Exit(False);
    if LSaved.IndexOf(AModule.FileName) >= 0 then
      Exit(True);
    LSaved.Add(AModule.FileName);
    Result := AModule.Save(False, True);
  end;

  procedure Count(const APath: string; AOk: Boolean);
  begin
    if AOk then
      Inc(ASaved)
    else
    begin
      Inc(AFailed);
      TraceFmt('  %s: could not be saved', [ExtractFileName(APath)]);
    end;
  end;

begin
  ASaved := 0;
  AFailed := 0;
  ADiskPaths := nil;
  LSaved := TStringList.Create;
  try
    LSaved.CaseSensitive := False;
    for LPair in AFiles do
      if LPair.Value.LiveForm then
      begin
        LFE := FormEditorOf(LPair.Value.Module);
        if Assigned(LFE) then
          LFE.MarkModified;
      end;
    if (AFirstForm <> '') and
       AFiles.TryGetValue(LowerCase(AFirstForm), LFile) and LFile.LiveForm then
    begin
      UpdateWaitDialogWork(ExtractFileName(LFile.Path));
      Count(LFile.Path, SaveModule(LFile.Module));
    end;
    for LPair in AFiles do
    begin
      if (AFirstForm <> '') and SameText(LPair.Key, LowerCase(AFirstForm)) and
         LPair.Value.LiveForm then
        Continue;   // saved first, above
      UpdateWaitDialogWork(ExtractFileName(LPair.Value.Path));
      if LPair.Value.OnDisk then
      begin
        LOk := TryWriteSource(LPair.Value.Path, LPair.Value.Text,
          LPair.Value.Encoding);
        if LOk then
          ADiskPaths := ADiskPaths + [LPair.Value.Path];
      end
      else
        LOk := SaveModule(LPair.Value.Module);
      Count(LPair.Value.Path, LOk);
    end;
  finally
    LSaved.Free;
  end;
end;

{ AFTER THE SAVE, each live form's file read back from disk: every one of its
  sites must now read the pass's text there. The designer wrote those files
  out of its live components, and whether it propagated each rename is the
  one thing no check before the save can see. What does not read so comes
  back as a line for the results tab, and the trace - a site the designer
  did not follow is a form that will not load (a handler it cannot find) or
  a caption left behind.

  A form file the designer rewrote in a layout other than the one analyzed
  (one saved by hand, or by an older IDE) can move its lines, and then this
  reports sites that are in fact fine - it says "could not confirm", never
  "wrong". }
function ConfirmLiveForms(const APlan: TLspRenamePlan; AFiles: TRenameFiles;
  ADirection: TApplyDirection): TArray<string>;
var
  LIdx, LShift: Integer;
  LEdit: TLspRenameEdit;
  LFile: TRenameFile;
  LTexts: TDictionary<string, UTF8String>;
  LText: UTF8String;
  LRead: string;
  LEncoding: TPasSourceEncoding;
  LKey, LWant: string;
begin
  Result := nil;
  LTexts := TDictionary<string, UTF8String>.Create;
  try
    LShift := 0;
    for LIdx := 0 to High(APlan.Edits) do
    begin
      LEdit := APlan.Edits[LIdx];
      if (LIdx = 0) or (APlan.Edits[LIdx - 1].Row <> LEdit.Row) or
         not SameText(APlan.Edits[LIdx - 1].FilePath, LEdit.FilePath) then
        LShift := 0;
      LKey := LowerCase(LEdit.FilePath);
      if not AFiles.TryGetValue(LKey, LFile) or not LFile.LiveForm then
        Continue;
      if not LTexts.TryGetValue(LKey, LText) then
      begin
        if TryReadSourceForEdit(LEdit.FilePath, LRead, LEncoding) then
          LText := UTF8Encode(LRead)
        else
          LText := '';
        LTexts.Add(LKey, LText);
      end;
      LWant := SiteReplacement(LEdit, ADirection);
      if not ReadsAt(LineText(LText, LEdit.Row), LEdit.Col + LShift, LWant) then
      begin
        Result := Result + [Format('%s line %d: not confirmed to read "%s"',
          [ExtractFileName(LEdit.FilePath), LEdit.Row, LWant])];
        TraceFmt('  %s line %d: after the save it does not read "%s" at ' +
          'column %d: [%s]', [ExtractFileName(LEdit.FilePath), LEdit.Row,
          LWant, LEdit.Col + LShift, LineText(LText, LEdit.Row)]);
      end;
      if ADirection = adForward then
        Inc(LShift, Length(LEdit.NewText) - Length(LEdit.OldText));
    end;
  finally
    LTexts.Free;
  end;
end;

{ Revert: every site back to the old name and every file saved again - the
  same applier run backwards, verified first, all or nothing, refused with
  the file and line if a site no longer reads the new name. A site that
  already reads the OLD name is skipped, not refused: that is the user who
  pressed Ctrl+Z in the one file they had open and now wants the other
  fifty-one back too. The plan's files are gathered again as they now stand
  (a file opened since the rename is an open file now), and the server hears
  about the result the same two ways the rename told it. }
procedure RevertApplied;
var
  LFiles: TRenameFiles;
  LError, LOldName, LLine: string;
  LReverted, LFileCount, LDiskCount, LSaved, LFailed: Integer;
  LDiskPaths, LUnconfirmed: TArray<string>;
  LAction: TDesignerAction;
begin
  if not GAlive or not Assigned(GApplied) then
    Exit;
  LFiles := nil;
  try
    try
      Trace('Revert pressed');
      ShowWaitDialog('Reverting the rename...');
      LFiles := TRenameFiles.Create;
      // The designer question is asked again, of the forms as they are NOW:
      // a form opened since the rename is the designer's now, one closed
      // since is a file on disk.
      if not CollectFiles(GApplied.Plan, LFiles, {out} LDiskCount,
           {out} LError) or
         not ResolveDesignerAction(GApplied.Plan, LFiles, {out} LAction,
           {out} LError) then
      begin
        CloseWaitDialog;
        TellUser(LError, mtError);
        Exit;
      end;
      if not ApplyDirection(GApplied.Plan, LFiles, adBackward, LAction,
        {out} LError) then
      begin
        // Refused: the rename stands, Revert stays live, and the user has
        // been told which line to look at.
        CloseWaitDialog;
        TellUser(LError, mtError);
        Exit;
      end;
      LReverted := Length(GApplied.Plan.Edits);
      LOldName := GApplied.Plan.OldName;
      LFileCount := LFiles.Count;
      SaveFiles(LFiles, LAction.FormFile, {out} LSaved, {out} LFailed,
        {out} LDiskPaths);
      LUnconfirmed := ConfirmLiveForms(GApplied.Plan, LFiles, adBackward);
      CloseWaitDialog;
      TraceFmt('reverted %d site(s) in %d file(s); saved %d, %d failed, %d ' +
        'form-file site(s) not confirmed', [LReverted, LFileCount, LSaved,
        LFailed, Length(LUnconfirmed)]);
      ReportOutcome(Format('Reverted - %d site(s) in %d file(s) read "%s" ' +
        'again, saved%s.', [LReverted, LFileCount, LOldName,
        IfThen(LFailed > 0, Format(' (%d could not be saved)', [LFailed]),
        '')]));
      for LLine in LUnconfirmed do
        ReportOutcome('  ' + LLine);
      DropApplied;
      LspSyncDocuments;
      LspFilesChangedOnDisk(LDiskPaths);
    except
      on E: Exception do
        LogDiagnostic(Format('Rename Revert: unhandled %s: %s',
          [E.ClassName, E.Message]));
    end;
  finally
    // Every module and editor reference goes here - see TAppliedRename.
    LFiles.Free;
  end;
end;

{ The rename proper, once the analysis has said WHAT is being renamed (see
  ExecuteRename): ask for the new name, plan, apply, report.

  THE RESULTS TAB COMES BEFORE THE FILE RENAME, deliberately. The text edits
  are done by then and the user is entitled to see them whatever happens next;
  on the first live run a failure inside the file half took the tab down with
  it and the rename looked like it had done nothing (2026-08-31). Reporting
  first also means the tab is the record of what was changed even when the
  file half then complains.

  EVERYTHING HERE RUNS INSIDE A CALLBACK, which is why the whole body is
  guarded. ExecuteRename's own try/except only covers issuing the request -
  by the time the answer arrives that frame is long gone, so an exception
  raised here would escape into the IDE's message loop with nothing to catch
  it. That is exactly what happened on the first live run. }
procedure RenameFrom(const AFileName: string; ARow, ACol: Integer;
  const AOldName: string);
var
  LNewName: string;
  LScope: TGroupScopeProjects;
  LProjects: TArray<string>;
begin
  // Our own themed form (PasTreeIdePlugin.RenameForm), since 0.51.0 with the
  // group's project list beneath the name: which other closures the plan
  // covers is the user's choice, remembered per group - starting every
  // server of a big group ran the machine out of memory (Alex, 2026-09-22).
  // Until then this was INTAIDEUIServices.InputQuery, chosen over the VCL
  // one because that came up light in the dark theme (user, 2026-08-31).
  // Outside a group LScope is nil and the form is the plain name prompt.
  LScope := GroupScopeProjects(LspOwningProjectFile(AFileName));
  if not ExecuteRenameDialog(AOldName, LScope, LNewName, LProjects) then
    Exit;
  if LNewName = AOldName then
    Exit;   // not a refusal worth a dialog: the user changed nothing
  if not LooksLikeName(LNewName) then
  begin
    TellUser(Format('"%s" is not a valid name.', [LNewName]), mtWarning);
    Exit;
  end;

  GPlanning := True;
  // No names in the text: the dialog does not grow for it, and two
  // identifiers plus decoration is clipped (user, 2026-08-31).
  ShowWaitDialog('Renaming...');
  LspRenamePlan(AFileName, ARow, ACol, LNewName, LProjects,
    procedure(ASuccess: Boolean; const APlan: TLspRenamePlan;
      const AError: string)
    var
      LFiles: TRenameFiles;
      LDiskCount, LSaved, LFailed, LFileCount: Integer;
      LDiskPaths, LUnconfirmed: TArray<string>;
      LAction: TDesignerAction;
    begin
      // The wait dialog STAYS UP through the apply and the save below - it
      // was shown before the request went out and the file names run on
      // its work line - and is closed before every dialog and before the
      // report: it disables input, and a message box over disabled input is
      // a stuck IDE. Hence a CloseWaitDialog ahead of every TellUser here.
      GPlanning := False;
      if not GAlive then
      begin
        CloseWaitDialog;
        Exit;
      end;
      try
        TraceFmt('plan for %s -> %s: success=%s',
          [AOldName, LNewName, BoolToStr(ASuccess, True)]);
        // The server's own sentence, verbatim - a reserved word, a builtin, a
        // `uses` spelling it has no rule for. See the unit header on why none
        // of these is re-worded here.
        if not ASuccess then
        begin
          CloseWaitDialog;
          TellUser(AError, mtWarning);
          Exit;
        end;
        { A UNIT, DECLINED HERE - BEFORE ANYTHING IS WRITTEN. The server plans
          one correctly (the header, every `uses` item, the `in '...'` path and
          the file name the unit then requires), and a plain LSP client applies
          all of that as one workspace edit. Inside the IDE it does not work,
          and the reason is not in this code: the IDE performs a rename of its
          own the moment a unit whose `unit` clause changed is saved or closed,
          through its project manager and SaveAs paths, and those cannot be
          told to stand still while ours runs. Four live runs on a 3759-unit
          project each ended in a different collision between the two - a file
          already moved, a project entry already rewritten, an IDE dialog
          "Unable to rename A to B" over a rename that had already happened.

          The refusal is deliberately at this point rather than earlier: the
          plan is what says whether the target is a unit, and asking is one
          round trip that changes nothing. Nothing has been applied yet, so
          there is nothing to undo. }
        if APlan.IsUnit then
        begin
          Trace('declined: a unit rename is not applied from the IDE');
          CloseWaitDialog;
          TellUser(Format('"%s" is a unit.'#13#10#13#10 +
            'Renaming a unit also renames its file, and the IDE performs a ' +
            'rename of its own whenever a unit''s name changes - the two ' +
            'collide, so this plugin does not do it. Rename the unit through ' +
            'the Project Manager instead; renaming symbols works as usual.',
            [APlan.OldName]), mtInformation);
          Exit;
        end;
        if Length(APlan.Edits) = 0 then
        begin
          CloseWaitDialog;
          TellUser('Nothing to rename.', mtInformation);
          Exit;
        end;
        TraceFmt('plan: old=%s new=%s edits=%d, form role %s of %s (%s), ' +
          '%d carried', [APlan.OldName, APlan.NewName, Length(APlan.Edits),
          IfThen(APlan.FormRole.Kind = '', 'none', APlan.FormRole.Kind),
          APlan.FormRole.OwnerClass, ExtractFileName(APlan.FormRole.FormFile),
          Length(APlan.Carried)]);
        // APPLIED AND SAVED, HERE AND NOW - open files through their
        // buffers (an undo step in each tab), closed ones straight to disk,
        // loaded forms through their designer - and the tab then shows what
        // was done, with Revert above it. A separate Save step was tried and
        // dropped (user, 2026-09-12): one click that only confirmed what the
        // tab already showed.
        if not ApplyPlan(APlan, {out} LDiskCount, {out} LFiles,
          {out} LAction) then
        begin
          Trace('apply refused - nothing was changed');
          Exit;   // ApplyPlan has already said why, and changed nothing
        end;
        try
          SaveFiles(LFiles, LAction.FormFile, {out} LSaved, {out} LFailed,
            {out} LDiskPaths);
          LUnconfirmed := ConfirmLiveForms(APlan, LFiles, adForward);
          LFileCount := LFiles.Count;
        finally
          // Every module and editor reference goes here, not with GApplied:
          // a tab the user closes later must not find ours on its editor
          // (see TAppliedRename).
          FreeAndNil(LFiles);
        end;
        CloseWaitDialog;
        DropApplied;
        GApplied := TAppliedRename.Create(APlan);
        TraceFmt('applied %d site(s); saved %d file(s), %d failed, %d of them ' +
          'on disk, %d form-file site(s) not confirmed', [Length(APlan.Edits),
          LSaved, LFailed, Length(LDiskPaths), Length(LUnconfirmed)]);
        ReportRename(APlan, LDiskCount, LFileCount, LFailed, LUnconfirmed);
        LogDiagnostic(Format('rename: %s -> %s, %d site(s) in %d file(s), ' +
          '%d of them not open in the IDE%s - Revert in the PasTree Rename tab',
          [APlan.OldName, APlan.NewName, Length(APlan.Edits), LFileCount,
           LDiskCount, IfThen(LFailed > 0,
             Format(', %d could not be saved', [LFailed]), '')]));
        // Two audiences at the server: the buffers it holds overlays for (the
        // ordinary sync) and the files it reads from disk, which only this
        // notification can tell it about.
        LspSyncDocuments;
        LspFilesChangedOnDisk(LDiskPaths);
      except
        on E: Exception do
          LogDiagnostic(Format('Rename: unhandled %s: %s',
            [E.ClassName, E.Message]));
      end;
    end);
end;


{ THE ANALYSIS IS ASKED WHAT IS UNDER THE CARET BEFORE THE DIALOG OPENS, and
  that is not ceremony. A UNIT's name may be dotted - `Namespace.Foo` is ONE
  name - and the text under the caret is at best one segment of it, so a
  dialog pre-filled from the buffer would offer half a name and rename it to
  something the user did not mean. prepareRename answers with the whole of
  it, and refuses (with a reason) where nothing can be renamed at all, which
  makes it also the earliest point a refusal can be shown. }
procedure ExecuteRename(const AView: IOTAEditView);
var
  LFileName: string;
  LRow, LCol: Integer;
begin
  try
    if not Assigned(AView) or not Assigned(AView.Buffer) then
      Exit;
    // Checked here too, not only at the two entry points: this is the
    // procedure that edits code, and it should be impossible to reach with
    // the feature switched off no matter who calls it.
    if not RenameEnabled then
      Exit;
    if GPlanning then
    begin
      TellUser('A rename is already in progress.', mtInformation);
      Exit;
    end;
    LFileName := AView.Buffer.FileName;
    LRow := AView.Buffer.EditPosition.Row;
    LCol := AView.Buffer.EditPosition.Column;

    GPlanning := True;
    // Visible progress for the slow half: on a cold big project this
    // prepareRename is what takes the seconds, not the plan.
    ShowWaitDialog('Resolving identifier...');
    LspRenameTarget(LFileName, LRow, LCol,
      procedure(ASuccess: Boolean; const AName, AError: string)
      begin
        CloseWaitDialog;
        GPlanning := False;
        if not GAlive then
          Exit;
        // Guarded for RenameFrom's reason: this body runs long after the
        // frame below returned, so there is nothing else to catch it.
        try
          if not ASuccess then
          begin
            TellUser(AError, mtWarning);
            Exit;
          end;
          if AName = '' then
          begin
            TellUser('No identifier under the cursor.', mtInformation);
            Exit;
          end;
          // The caret may have moved while we were asking, and that is fine:
          // the POSITION we asked about is the one we keep renaming from,
          // and the server still holds the snapshot it answered from.
          RenameFrom(LFileName, LRow, LCol, AName);
        except
          on E: Exception do
            LogDiagnostic(Format('Rename: unhandled %s: %s',
              [E.ClassName, E.Message]));
        end;
      end);
  except
    on E: Exception do
    begin
      CloseWaitDialog;
      GPlanning := False;
      LogDiagnostic(Format('Rename: unhandled %s: %s',
        [E.ClassName, E.Message]));
    end;
  end;
end;

{ The key's handler - Ctrl+Shift+E, through PasTreeIdePlugin.KeyBindings
  (the package's one binding). }
procedure RenameKeyProc(const AContext: IOTAKeyContext;
  AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
begin
  // krHandled once the key is recognised, for the reason the toggle and
  // class completion both state: krUnhandled would hand the keystroke back
  // to the IDE, and a position ours declines would silently get some other
  // behaviour instead.
  { THE OFF SWITCH, and the one line in here that may answer krUnhandled -
    which is exactly what makes "rename off" mean "the key is the IDE's
    again", with no keymap to unbind. Same shape as the decl/impl toggle's,
    and it must stay ahead of the unconditional krHandled below. }
  if not RenameEnabled then
  begin
    ABindingResult := krUnhandled;
    Exit;
  end;
  ABindingResult := krHandled;
  if not GAlive or not Assigned(AContext) or
     not Assigned(AContext.EditBuffer) then
    Exit;
  ExecuteRename(AContext.EditBuffer.TopView);
end;

procedure InitializeRename;
begin
  GAlive := True;
  // Ctrl+Shift+E, not Ctrl+E: the IDE gives Ctrl+E to incremental search,
  // which is used far more often than this is. Registered, not bound: the
  // wizard binds everything at once (InitializeKeyBindings).
  RegisterKey(ShortCut(Ord('E'), [ssCtrl, ssShift]), RenameKeyProc);
end;

procedure FinalizeRename;
var
  LMessageServices: IOTAMessageServices;
begin
  GAlive := False;
  // The toolbar first: it lives in a control the IDE owns, and the pending
  // rename it acts on is gone with GAlive anyway.
  HideRenameToolbar;
  DropApplied;
  // The key binding itself is already gone - FinalizeKeyBindings runs first.
  // NOT AT IDE SHUTDOWN - PasTreeIdePlugin.FindReferences' finalizer carries
  // the full story of the access violation this guard exists for.
  if Assigned(GMessageGroup) and not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    try
      LMessageServices.RemoveMessageGroup(GMessageGroup);
    except
      // Deliberately silent: this runs while the package is unloading.
    end;
  GMessageGroup := nil;
end;

{ The same removal for a project close, leaving GAlive and the key binding
  alone - the package lives on and the next rename must work.

  WORSE HERE THAN FOR A SEARCH, which is why it is worth its own note: this
  tab claims sites were CHANGED. Close the project without saving and every
  one of those changes is gone, but the tab still stands, still lists them,
  and its rows still navigate - into whatever file now occupies those lines
  in the next project opened. A record of edits that were undone is not a
  stale result, it is a false one. }
procedure CloseRenameResults;
var
  LMessageServices: IOTAMessageServices;
begin
  // A pending rename in a project that is closing: the IDE asks about each
  // modified module itself, tab or no tab, so nothing is lost silently -
  // but the buttons that referred to those modules must not outlive them.
  HideRenameToolbar;
  DropApplied;
  if Assigned(GMessageGroup) and not Application.Terminated and
     Supports(BorlandIDEServices, IOTAMessageServices, LMessageServices) then
    try
      LMessageServices.RemoveMessageGroup(GMessageGroup);
    except
      // Cosmetic cleanup on a path the user did not ask anything of.
    end;
  GMessageGroup := nil;
end;

end.