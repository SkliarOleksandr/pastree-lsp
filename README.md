# PasTree IDE Plugin

## Repo layout

This repo was split out of `object-pascal-tree`'s `ide-plugin/` directory
(2026-08-16, no history carried over - see that repo's git log for the
prior commits).

**No sibling checkout is needed to build the package any more.** It used to
compile the ~20 `PasTree.*.pas` analysis units directly from
`..\object-pascal-tree\source\`; since the LSP move it links none of them -
the analysis lives in `pastree-server.exe`, which owns that dependency
instead. The package is a thin LSP client: `requires rtl, vcl, designide` and
nothing else. (The `tests/` harnesses need only this repo and a built server
exe.)

The sibling `pastree-lsp-server` repo hosts the out-of-process LSP server that
now does all the analysis; **both features have moved onto it**. See
"Architecture" below.

A RAD Studio IDE package that surfaces PasTree's analysis inside the Delphi
editor itself. Two features so far: **Find References** (the feature
already available in `object-pascal-tree`'s `demo/`) and **Go to
Declaration**, replacing RAD
Studio's own DelphiLSP-based navigation (reported to work poorly on large
projects) - both the native menu item and Ctrl+Click.

## Status: working over LSP, confirmed in the IDE

Ctrl+Click and the Find References menu item were both confirmed working
against the out-of-process server in a running RAD Studio (2026-08-19), which
was the one thing no test here can cover - whether the asynchronous answer
lands correctly in a real editor.

The transport, session and configuration harvest are each also exercised
against a real server by `tests/` (see "Files"), which is what the earlier
in-process version never had.

Not yet exercised by hand, in rough order of how likely they are to matter:
switching the active project or platform mid-session (restarts the server),
recovery after killing `pastree-server.exe` while the IDE is open, navigation
from a buffer with unsaved edits, and a `uses` item in a `.dpr` - the
three-identity case that motivated moving the resolve order into the server in
the first place.

The ToolsAPI side is built directly from RAD Studio's own official samples
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
working** in the in-process version and unchanged as ToolsAPI plumbing by the
LSP move - what changed underneath them is that the jump now happens in a
callback rather than before the handler returns:

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

### Shared analysis pipeline

Both features now ask the LSP server the same way, through
`PasTreeIdePlugin.LspSession` - `LspDefinition` and `LspReferences`. The
three-identity lookup (symbol / unit / builtin) and the caching that used to
live in this package are the server's job now, which is the point: one
implementation, shared with every other LSP client, instead of the same
resolve order written twice. See "Architecture" below.

Two things LSP does not carry, and where they come from instead:
- **The identifier's name.** A `Location` has no name. Find References reads
  it out of the same snapshot the server was given (`IdentifierAt`) at answer
  time, for the report's title.
- **The snippet line.** `TPasRefHit` carried the source line; a `Location`
  does not. `TSnippetCache` reads it from that same snapshot rather than
  re-reading the file, so an unsaved buffer's line numbers still match the
  text shown.

### Diagnostics

Logged only on failure (no active project, cursor's file not analyzed, no
identifier resolved, unhandled exception) - not on every step or on
success. Go to Declaration fires on every Ctrl+Click, far more often than a
menu click, so logging progress/success would be much noisier than useful.
Goes to the IDE's own default Messages tab (the "Build" tab -
`AddTitleMessage` with no group), tagged `[pastree]` so it's identifiable
alongside compiler/linker output, rather than into a dedicated tab of its
own.

## Architecture: out of process, over LSP

Both features ask `pastree-server.exe` (Win64) over the Language Server
Protocol. **Nothing is analyzed inside the package any more** - it links no
PasTree units at all, and went from ~30,500 lines of compiled code to ~3,600
when the last of them went. The four LSP units are described in "Files";
`tests/` drives three of them against a real server without needing the IDE.

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
- **Sync on request, not on keystroke.** Live buffer text is read and sent just
  before a request, not pushed from an editor notifier. One less notifier to
  tear down - see the hot-reload note under "Known first-pass limitations" for
  why that matters here - and no keystroke-rate traffic. It also means the
  server's incremental sync goes unused: one whole-document replacement per
  user action is cheaper than a stream of ranged patches, and cannot silently
  desynchronise the way a mis-applied patch can. A push-based `didChange`
  becomes necessary when `publishDiagnostics` arrives, and belongs alongside
  this rather than instead of it.
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
  strictly more than the in-process path ever managed: it guessed the real
  `.dpr`/`.dpk` by naming convention and never read the project's defines at
  all. Only the IDE's own RTL/VCL/ToolsAPI source location has to be passed
  separately, as extra `searchPaths` - no `.dproj` lists it.

### Why the in-process path had to go

It ran `TPasSemaProject` **inside the 32-bit designtime package**,
synchronously. That was a deliberate, accepted limitation for the PoC stage -
not an oversight - and these are the reasons it could not stay:

- A designtime package is forced to run **Win32** (the IDE itself is a
  32-bit process) - there is no way to make this package itself Win64.
- The real target project this plugin is ultimately for is large enough to
  need **Win64 and several GB** to analyze (see project memory - the same
  codebase OOMs when analyzed as Win32). That analysis was never going to fit
  inside this Win32 package.
- Synchronous analysis on the UI thread froze the IDE for as long as it took.
  The measurement above puts that at ~2.7s for this small package; at the real
  target's scale it is not a pause, it is a hang.

### What is left

`publishDiagnostics` (server phase 3), which is also what will require a
push-based `didChange` alongside the sync-on-request path.

## Pointing the plugin at the server

No path is hardcoded. `FindServerExe` looks in two places, in order:

1. `%PASTREE_LSP_SERVER%`, if set - the development override, so the IDE runs
   whatever was last built into `pastree-lsp-server\out\`. A value that is set
   but wrong is **reported rather than ignored**: falling back would silently
   run some other build, and a typo would cost an afternoon.
2. `pastree-server.exe` next to the package's own BPL, so a matched pair can be
   deployed together.

Note where the BPL actually lands - with no `DCC_BplOutput` in the `.dproj` it
is the IDE default, e.g.
`C:\Users\Public\Documents\Embarcadero\Studio\37.0\Bpl\` - which is *not* next
to this repo. So one of these has to happen before the plugin can do anything:

```
copy ..\pastree-lsp-server\out\pastree-server.exe "%PUBLIC%\Documents\Embarcadero\Studio\37.0\Bpl"
```

or, better for a development loop because it never goes stale:

```
setx PASTREE_LSP_SERVER "C:\Repos\pastree-lsp-server\out\pastree-server.exe"
```

The environment variable is only picked up on the next IDE start - a process's
environment is captured when it launches. Copying the exe next to the BPL, by
contrast, needs no restart: the session re-looks for the server on every
request until it finds one, precisely so that fixing this does not cost an IDE
restart on top of everything else.

If neither is in place, both features log to the Build tab and do nothing else.

## Building and testing

Everything below runs from a shell with `rsvars.bat` sourced (it sets `%BDS%`,
which `LspProjectSmoke` uses to find the RTL/VCL/ToolsAPI sources).

The package:

```
msbuild PasTreeIdePlugin.dproj /t:Build /p:Config=Debug /p:Platform=Win32
```

The test harnesses are plain programs, not part of the package - `dcc32`
straight at them, with `-U` pointing at the repo root so they can see the two
IDE-free units:

```
dcc32 -B tests\LspTransportSmoke.dpr -U. -Etests\out -Ntests\out
```

Then run the exe. Each takes the server path as its first argument and
defaults to `..\pastree-lsp-server\out\pastree-server.exe`; each prints a
per-check `[ok]`/`[FAIL]` list and exits non-zero on failure. `LspClientSmoke`
and `LspProjectSmoke` need a built server; `LspProjectSmoke` also needs this
repo's own `.dproj` to be buildable, since that is what it asks the server to
analyze.

## Known first-pass limitations

- **The server must be found.** It is looked for next to the package's BPL, or
  wherever `PASTREE_LSP_SERVER` points (a set-but-wrong value is deliberately
  reported rather than falling back, so a typo does not silently run some other
  build). Missing, and both features log to the Build tab and do nothing.
- Positions are exact for ASCII and all BMP text, including Cyrillic. A
  character outside the BMP occupies two UTF-16 code units but may be counted
  once by the editor, so a line containing one could be off by one after it -
  inherited unchanged from the in-process path, which relied on the same
  identity (see the header of `PasTreeIdePlugin.LspDocuments.pas`).
- Nothing reaches the server between requests, by design (sync on request).
  Harmless for navigation; the reason diagnostics will need a notifier.
- Rebuilding this package inside the same running IDE session is unreliable
  even with an explicit Uninstall/Build/Install cycle - always restart the
  IDE before testing a rebuild (see project memory on package hot-reload;
  the likely cause is `AddEditorEventsNotifier` not being fully torn down
  by the IDE's own Uninstall step).

## Files

- `PasTreeIdePlugin.dpk` / `.dproj` - package project, `Win32`.
  `requires: rtl, vcl, designide` and its own seven units - no PasTree, no
  sibling checkout (see "Repo layout" above).
- `PasTreeIdePlugin.Wizard.pas` - `TIDEWizard` (`IOTAWizard`): owns the
  single editor-menu action list (Find Declaration + Find References,
  both under Identifier), the Ctrl+Click notifier's lifetime, and the LSP
  session's.

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
