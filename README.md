# PasTree IDE Plugin

## Repo layout

This repo was split out of `object-pascal-tree`'s `ide-plugin/` directory
(2026-08-16, no history carried over - see that repo's git log for the
prior commits). The package still compiles the ~20 `PasTree.*.pas` analysis
units directly, now via a **sibling-checkout** relative path:
`..\object-pascal-tree\source\PasTree.*.pas` (see `PasTreeIdePlugin.dpk`
and `PasTreeIdePlugin.dproj`). This means `object-pascal-tree` must be
checked out as a sibling directory of this repo (e.g. both under
`C:\Repos\`) for the package to build.

The sibling `pastree-lsp-server` repo hosts the out-of-process LSP server
wrapping the same analysis, and **the move onto it is in progress**: Go to
Declaration now goes through the server, Find References still runs
`TPasSemaProject` in-process. See "Architecture" below for where that
stands and what is left.

A RAD Studio IDE package that surfaces PasTree's analysis inside the Delphi
editor itself. Two features so far: **Find References** (the feature
already available in `object-pascal-tree`'s `demo/`) and **Go to
Declaration**, replacing RAD
Studio's own DelphiLSP-based navigation (reported to work poorly on large
projects) - both the native menu item and Ctrl+Click.

## Status: PoC — confirmed working in-process, on small/test projects

Built directly from RAD Studio's own official samples
(`Samples\Object Pascal\ToolsAPI\Editor Demos\...`), not from an
unofficial/community API surface.

### Menu

Both "Find Declaration (PasTree)" and "Find References (PasTree)" live
together at the top of the editor's right-click menu, in the Identifier
category (`cEdMenuCatIdentifier` in `ToolsAPI.pas`) - the exact slot RAD
Studio's native "Find Declaration" used to occupy alone. See "Go to
Declaration" below for how the native item got replaced.

### Find References

- Results go to a dedicated "Find References" tab in the Messages panel
  (`IOTAMessageServices.AddMessageGroup`), grouped by file (one header row
  per file via `AddToolMessage`'s own `Parent`/`LineRef` mechanism - same
  tree structure "Find in Files" uses), each hit carrying file/line/column
  so the IDE's own message navigation (double-click, Enter, F8/Shift+F8)
  jumps straight to it.

### Go to Declaration

Two ways to trigger the same resolve+navigate logic
(`PasTreeIdePlugin.GotoDeclaration.ResolveAndNavigate`), both **confirmed
working**:

- **Native menu item replaced.** The built-in "Find Declaration" is removed
  via `INTAEditorLocalMenu.UnregisterActionList(cEdMenuCatIdentifier)` and
  replaced with our own action registered under that same category string
  (`PasTreeIdePlugin.Wizard.TMenuManager` - lands in the exact same, first,
  menu position). **Caveat:** this is a one-way door within a running IDE
  session - there's no handle to the native action list to restore it, so
  uninstalling the package without restarting the IDE would leave "Find
  Declaration" missing until restart (which the project's own workflow
  already does after every rebuild - see project memory on package
  hot-reload).
- **Ctrl+Click override.** Hooks `INTACodeEditorServices.AddEditorEventsNotifier`
  (`ToolsAPI.Editor.pas`, the same mechanism the official "KeyboardMouse
  Events Demo" sample uses) and intercepts
  `OnEditorMouseDownEx`/`OnEditorMouseUpEx`: on Ctrl+Left-click it resolves
  the identifier under the cursor and navigates there itself, setting
  `Handled := True` to suppress RAD Studio's own default handling
  (documented as "prevent further processing" - `ToolsAPI.Editor.pas:804-806`).

Every successful jump registers with `IOTAHistoryServices` (the same global
Backward/Forward stack the IDE's own Alt+Left/Alt+Right toolbar buttons
use), via `PushHistoryAndNavigate`/`TPasHistoryItem` - so Alt+Left/Right work
across our jumps too. Every history item handed to the IDE is tracked and
removed via `RemoveHistoryItem` at package unload (`ClearHistoryItems`) -
left registered, a stale entry would call `.Execute` on an object living in
already-unloaded package code the next time the user pressed Alt-Left/Right.

### Shared analysis pipeline (Find References only, now)

Find References still calls `PasTreeIdePlugin.Analysis.BuildNavigator`; Go
to Declaration has moved to the LSP server and no longer touches any of
this. `BuildNavigator`:
- Resolves the active project's real `.dpr`/`.dpk` (`IOTAProject.FileName`
  is the `.dproj` MSBuild wrapper, unparseable by PasTree).
- Overlays live buffer text for every currently-**open** unit
  (`IOTAModuleServices.Modules` - never forcing anything open; an earlier
  version walked every project unit via `IOTAProject.GetModule`+`OpenModule`,
  which force-instantiated every unopened form's design surface).
- Builds a `TPasSemaProject` (`SingleThreaded := True` - see below) and
  `TPasNavigator`, whose three-identity lookup (symbol / unit / builtin -
  see `source/PasTree.Sema.Nav.pas`) resolves whatever's at a given
  file/line/column.
- **Cached across calls.** Rebuilding this from scratch on every menu click
  - and now every Ctrl+Click - was too slow once RTL/VCL search paths were
  added (a full reparse per click, visibly). The built pair is kept alive
  in a package-lifetime cache and only rebuilt when the active project
  changed or an open unit's live text differs from last time (content
  comparison, not time-based). `BuildNavigator`'s result is cache-owned -
  callers must not free it. Known gap: changes to files not open in an
  editor tab aren't detected (no filesystem watcher) - acceptable since
  RTL/VCL essentially never changes mid-session.

### Diagnostics

Logged only on failure (no active project, cursor's file not analyzed, no
identifier resolved, unhandled exception) - not on every step or on
success. Go to Declaration fires on every Ctrl+Click, far more often than a
menu click, so logging progress/success would be much noisier than useful.
Goes to the IDE's own default Messages tab (the "Build" tab -
`AddTitleMessage` with no group), tagged `[pastree]` so it's identifiable
alongside compiler/linker output, rather than into a dedicated tab of its
own.

## Architecture: moving out of process, one feature at a time

Go to Declaration now asks `pastree-server.exe` (Win64) over LSP; Find
References is still the in-process path described below. The four new units
are described in "Files"; `tests/` drives all three of them against a real
server without needing the IDE at all.

### How the client is wired

- **Hybrid pipes.** The plugin creates two uniquely-named pipes itself, keeps
  the overlapped end, and hands the synchronous end to the child as its std
  handles. The server still reads plain stdin/stdout - the same code path the
  VS Code client exercises - while the plugin gets cancellable reads
  (`CancelIoEx`, so no reader thread can be stuck in `ReadFile` while this BPL
  unloads) and explicit handle inheritance (only three handles, instead of
  every inheritable handle the whole IDE process holds).
- **Nothing blocks the main thread.** Requests are fire-and-callback. This is
  not a style preference: on this very package's `.dproj`, the first request
  after a server start takes ~2.7s to analyze the project plus RTL/VCL/
  ToolsAPI, and subsequent ones 0-16ms. In-process, that 2.7s froze the IDE.
- **Sync on request, not on keystroke.** Live buffer text is read and sent
  just before a request, not pushed from an editor notifier. One less
  notifier to tear down - see the hot-reload note under "Known first-pass
  limitations" for why that matters here - and no whole-document traffic per
  keypress. A push-based `didChange` becomes necessary when
  `publishDiagnostics` arrives, and should be added alongside this, not
  instead of it.
- **One server per project configuration.** Changing the active project,
  platform or build configuration restarts the server, because the server
  fixes its configuration at `initialize`.
- **Lazy, timerless restart.** A dead server is respawned by the next
  request, with backoff and a give-up count. A completed handshake clears the
  failure history. On every handshake the open documents are re-sent, since a
  fresh server has none.
- **The server gets the `.dproj` verbatim** and evaluates it with the same
  MSBuild logic the CLI tools use, so main source, search paths, defines,
  namespaces and unit aliases all come from the project file. That is
  strictly more than the in-process path manages: it guesses the real
  `.dpr`/`.dpk` by naming convention and never reads the project's defines
  at all. Only the IDE's own RTL/VCL/ToolsAPI source location has to be
  passed separately, as extra `searchPaths`.

### What is left

`textDocument/references` (retiring `Analysis.pas`, and PasTree with it, from
this package), then `publishDiagnostics`.

### Why the in-process path had to go

The remaining in-process analysis runs `TPasSemaProject` **inside the 32-bit
designtime package**, synchronously. That was a deliberate, accepted
limitation for the PoC stage - not an oversight - and these are the reasons it
could not stay:

- A designtime package is forced to run **Win32** (the IDE itself is a
  32-bit process) - there is no way to make this package itself Win64.
- The real target project this plugin is ultimately for is large enough to
  need **Win64 and several GB** to analyze (see project memory - the same
  codebase OOMs when analyzed as Win32). Running that analysis inside this
  Win32 package is expected to fail or be unusable at that scale.
- The analysis result is cached (see "Shared analysis pipeline" above), so
  this is only a full reparse on a cache miss (project switch, or an open
  unit's text changed) - not on every single call anymore.

The fix is the out-of-process Win64 server, which now exists as the sibling
`pastree-lsp-server` repo and speaks LSP rather than a private protocol -
see "How the client is wired" above.

## Known first-pass limitations

The first three below apply to the **in-process path only** (Find
References). The LSP path is not affected: the server reads the `.dproj`
itself, so it gets the project's real defines and search paths, and it runs
Win64 out of process.

- `uses` resolution includes the active project's own directory, every open
  unit's directory, and (as of 2026-08-15) RTL/VCL/ToolsAPI source
  (`GetIDESourcePaths` in `PasTreeIdePlugin.Analysis.pas`, rooted at
  `IOTAServices.GetRootDirectory`, no hardcoded version) - `TActionList`,
  `IOTAWizard`, etc. now resolve correctly. This was disabled once after an
  AV, re-enabled and re-tested clean after a full IDE restart - the AV was
  most likely the package-hot-reload issue below, not a real bug, but a
  theoretical concurrency risk in PasTree's own `TPasSourceManager` is
  still unconfirmed either way (project memory:
  `pastree-rtl-vcl-scale-av-suspect`). Disable again (see
  `CollectSearchPaths`'s comment) if it ever AVs after a *clean* restart.
- Project `$DEFINE`s aren't read from the `.dproj` yet - `TPasSemaProject`
  is created with an empty extra-defines list.
- Platform is read from `IOTAProject.CurrentPlatform` and mapped to the
  closest `TPasPlatform` (`MapPlatform`) - PasTree doesn't model every RAD
  Studio target (no ARM64EC, no 32-bit non-Windows), those fall back to the
  nearest 64-bit equivalent or `pfWin32`.
- Rebuilding this package inside the same running IDE session is unreliable
  even with an explicit Uninstall/Build/Install cycle - always restart the
  IDE before testing a rebuild (see project memory on package hot-reload;
  the likely cause is `AddEditorEventsNotifier` not being fully torn down
  by the IDE's own Uninstall step).

## Files

- `PasTreeIdePlugin.dpk` / `.dproj` - package project, `Win32`.
  `requires: rtl, vcl, designide`; `contains` the plugin's own units
  plus the same ~20 `PasTree.*.pas` units `object-pascal-tree`'s
  `demo/PasTreeDemo.dproj` already depends on, referenced from the sibling
  `object-pascal-tree` checkout (not trimmed to a minimal subset, since
  that combination is already proven to compile together - see "Repo
  layout" above).
- `PasTreeIdePlugin.Wizard.pas` - `TIDEWizard` (`IOTAWizard`): owns the
  single editor-menu action list (Find Declaration + Find References,
  both under Identifier) and the Ctrl+Click notifier's lifetime.
- `PasTreeIdePlugin.Analysis.pas` - the in-process path, now used by Find
  References only: active-project lookup, live-buffer gathering,
  search-path/platform resolution, and `BuildNavigator` (the
  `TPasSemaProject`+`TPasNavigator` pipeline). **Goes away** once references
  move to the server, taking this package's PasTree dependency with it.

The LSP client, bottom up. The first two touch no ToolsAPI at all, which is
what lets `tests/` drive them against a real server outside the IDE:

- `PasTreeIdePlugin.LspTransport.pas` - the Win32 plumbing: the hybrid pipes,
  process spawn with an explicit inherited-handle list, LSP framing, the
  overlapped reader thread, and an ordered teardown that must leave no thread
  alive in this BPL's code.
- `PasTreeIdePlugin.LspClient.pas` - the JSON-RPC session: request ids,
  pending-response callbacks, the initialize/shutdown lifecycle, requests
  queued behind the handshake, the lazy restart policy, and path↔URI
  conversion mirroring the server's own `PasLsp.Protocol`.
- `PasTreeIdePlugin.LspDocuments.pas` - `didOpen`/`didChange`/`didClose` from
  the live editor buffers, synced on request; plus the IDE↔LSP position
  conversion and why it reduces to the identity the in-process path already
  relies on.
- `PasTreeIdePlugin.LspSession.pas` - the package-lifetime session and the
  replacement for `BuildNavigator`: harvests `initializationOptions` from
  ToolsAPI, restarts the server when the project configuration changes, and
  exposes `LspDefinition`/`LspReferences` as callback-style requests.
- `tests/` - three console harnesses, each built with `dcc32` and run
  directly (no IDE, no package): `LspTransportSmoke` (graceful round trip,
  abrupt teardown with the server live, server killed behind our back),
  `LspClientSmoke` (handshake with a request queued behind it, real
  navigation over `tests/fixtures/`, lazy restart), and `LspProjectSmoke`
  (this package's own `.dproj` plus the IDE source paths - the check that the
  `initializationOptions` harvest actually resolves `TActionList`,
  `IOTAWizard` and the project's own types).
- `PasTreeIdePlugin.FindReferences.pas` - Find References logic and
  Messages-panel reporting. Its unit header has the fuller architecture
  note and a TODO list for what's next (out-of-process, real defines,
  snippet highlighting).
- `PasTreeIdePlugin.GotoDeclaration.pas` - the Ctrl+Click override plus the
  shared `ResolveAndNavigate`/`ExecuteGotoDeclaration` used by both Go to
  Declaration entry points: mouse event interception, cursor
  pixel→file-position conversion, navigation, and `IOTAHistoryServices`
  integration (`TPasHistoryItem`) for Backward/Forward. Since the LSP move,
  `ResolveAndNavigate` issues a request and jumps from the callback, so the
  "jumped from" position is captured at click time rather than at answer time.
