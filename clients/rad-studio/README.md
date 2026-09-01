# PasTree LSP - RAD Studio package

The RAD Studio client of [PasTree LSP](../../README.md). `SPEC.md` here is the
companion to this file: what the package COULD present and what each option
costs, mapped over the ToolsAPI surface. This README is what it does today; the
repository root README covers the server and the product as a whole.

## Where this lives, and the one rule that protects it

Two moves brought it here: out of `object-pascal-tree`'s `ide-plugin/` directory
into its own repository (2026-08-16), then into the server's repository as
`clients/rad-studio/` (2026-08-20, history preserved). The second move was
because the server and this package are one deliverable with one version - see
the root README.

**THE PACKAGE LINKS NO PASTREE, AND MUST NOT START.** It is a 32-bit designtime
BPL; PasTree is Win64-only, and that mismatch is the entire reason the analysis
runs out of process at all. So:

```
requires rtl, vcl, designide;
```

plus exactly two units from outside this directory, both dependency-free by
construction and both shared with the server:

- `PasLsp.ProductVersion` - so the two halves cannot disagree about their
  version;
- `PasLsp.SourceText` - the BOM and buffer-vs-file rules. Shared because the
  same BOM bug was fixed locally in three separate layers before it was fixed
  once; anything this package learns about incoming text belongs in there.

This used to be guaranteed by geography - PasTree was in another repository
entirely. Now it is in the same tree, one directory up, and "just link this one
unit" is an easy and plausible mistake that would quietly undo the whole
out-of-process design. `tests/VersionSmoke` is the tripwire for the most likely
version of it: it is a Win32 program over both shared units, so it stops
compiling the moment either one grows a PasTree dependency. A third shared unit
is a decision to weigh, not a convenience - each one is a route in.

The analysis itself lives in `pastree-server.exe`; **both features run through
it**. See "Architecture" below.

A RAD Studio IDE package that surfaces PasTree's analysis inside the Delphi
editor itself. Four features so far:

- **Find References** (the feature already available in
  `object-pascal-tree`'s `demo/`);
- **Go to Declaration**, replacing RAD Studio's own DelphiLSP-based navigation
  (reported to work poorly on large projects) - both the native menu item and
  Ctrl+Click;
- **the decl↔impl jump** on Ctrl+Shift+Up/Down, the IDE's own keys for it,
  taken over the same way;
- **Rename** on Ctrl+Shift+E and in the editor's menu - every use of a symbol across the
  project, then a results tab showing each changed line as it now reads.

The analysis starts when a project finishes opening rather than on the first
navigation, so the closure is usually already built by the time anyone asks it
anything.

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

"Find Type Declaration" and "Find References" live in the editor's
right-click menu under the plugin's own category, ALONGSIDE the native
items (since phase C, 2026-08-22, nothing native is replaced - the native
"Find Declaration" is back in its own slot and, like Ctrl+Click, routes
through our Code Insight manager whenever "PasTree" is the selected
Insight Provider). A miss is reported in the Messages panel tagged
`[pastree]`, which is where the origin shows. See "Go to
Declaration" below for how navigation is reached now.

### Rename

Ctrl+Shift+E, or "Rename..." in the editor's right-click menu. A dialog
prefilled with the identifier under the caret, then the server plans every
site and the plugin applies it - one undo step per file.

- **Nothing is written unless everything can be.** Every site is checked
  first - against the live buffer for a file you have open, against the text
  on disk for one you do not; if any has moved since the analysis the whole
  rename is refused, naming the file and line, with nothing changed.
- **Files you do not have open are not opened.** They are rewritten on disk,
  in the encoding they were stored in. That keeps a rename of something with
  a dozen references from burying you in a dozen new editor tabs - the cost
  is that those files have no undo step, which the results tab says.
- **Results go to a "PasTree Rename" tab** shaped like Find References -
  grouped by file, navigable, the declaration labelled - where every line is
  the source AS IT NOW READS. A rename you cannot see is a rename you cannot
  trust.
- **A UNIT is refused, with the reason.** The server plans one correctly (the
  header, every `uses` item, the `in '...'` path and the file the unit then
  requires) and a plain LSP client applies it in one edit - but the IDE
  performs a rename of its own the moment a unit's name changes, through its
  project manager and SaveAs paths, and the two collide. Four live runs each
  ended in a different collision. Rename a unit through the Project Manager;
  the removed half is kept on the `feature/unit-rename` branch.
- **A compiler builtin is refused** - there is no declaration to rename - as
  is a `uses` spelling the analysis has no rule for. Both refusals are the
  server's own sentence.
- **Switchable off** in Tools > PasTree > Settings. Off hides the menu item
  and hands Ctrl+Shift+E back to the IDE - the same off-switch shape the
  decl/impl toggle has, and a feature that edits your code should have one.
- **The name check is the analysis's**, not ours: this package cannot link
  PasTree, so a reserved word is refused by the server. The plugin only
  rejects obvious non-identifiers, to save a round trip on a typo.

### Find References

- Results go to a dedicated "Find References" tab in the Messages panel
  (`IOTAMessageServices.AddMessageGroup`), grouped by file (one header row
  per file, the same `Parent`/`LineRef` tree structure "Find in Files" uses),
  each hit carrying file/line/column so the IDE's own message navigation
  (double-click, Enter, F8/Shift+F8) jumps straight to it.
- The rows are **owner-drawn**, not plain tool messages:
  `AddCustomMessagePtr`/`AddCustomMessage` over `INTACustomDrawMessage`
  implementations in `PasTreeIdePlugin.ResultRows`, which is what lets a hit
  show its own source line with the identifier picked out. (It began as
  `AddToolMessage`; that is what the earlier version of this paragraph
  described.)

### Go to Declaration

The resolve+navigate logic itself
(`PasTreeIdePlugin.GotoDeclaration.ResolveAndNavigate`) is still what does the
work, and the jump happens in a callback rather than before the handler
returns. How it is REACHED has changed twice, and the two mechanisms below are
history:

> **Both mechanisms below were REMOVED in phase C (2026-08-22)** and are
> described here only because the reasoning behind them is worth keeping. The
> native "Find Declaration" is no longer unregistered, and there is no
> mouse-event interception: both the native menu item and Ctrl+Click route
> through our Code Insight manager whenever "PasTree" is the selected Insight
> Provider, which is the whole point of becoming the manager. See "Menu" above
> for what the editor menu looks like today.

- **Native menu item replaced** *(removed in phase C)*. The built-in "Find
  Declaration" was removed via
  `INTAEditorLocalMenu.UnregisterActionList(cEdMenuCatIdentifier)` and
  replaced with our own action registered under that same category string
  (lands in the exact same, first, menu position). **Its caveat is why it
  went:** a one-way door within a running IDE session - there is no handle to
  the native action list to restore it, so uninstalling the package without
  restarting the IDE left "Find Declaration" missing until restart.
- **Ctrl+Click override** *(removed in phase C)*. Hooked
  `INTACodeEditorServices.AddEditorEventsNotifier` (`ToolsAPI.Editor.pas`, the
  same mechanism the official "KeyboardMouse Events Demo" sample uses) and
  intercepted `OnEditorMouseDownEx`/`OnEditorMouseUpEx`: on Ctrl+Left-click it
  resolved the identifier under the cursor and navigated there itself, setting
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
  all. What no `.dproj` lists is everything the IDE finds through its own
  **Library** configuration, so that is read from the IDE and passed as extra
  `searchPaths`: the **Browsing Path** (RTL/VCL/ToolsAPI source) and the
  **Search Path** (every third-party library the user has installed), for the
  project's platform, with `$(...)` macros expanded - including the user's own
  Environment Variables overrides, which is how a real installation points at
  its third-party source. `GetIDELibraryPaths` in
  `PasTreeIdePlugin.LspSession.pas`.

  This list is not a detail. Getting it wrong is indistinguishable, from the
  editor, from the whole plugin being broken: Ctrl+Click answers "no
  identifier/declaration resolved at cursor" for every type not declared in
  the project's own units, and the reason - a wall of `F1027 Unit not found` -
  appears only in the server log. That was the state until 2026-08-20, when
  the three hardcoded paths this used to send (`source\rtl`, `source\vcl`,
  `source\ToolsAPI`) turned out not to include the RTL at all: the RTL sources
  live in `source\rtl\sys`, `\common`, `\win`, not in `source\rtl` itself.

- **The server log goes next to the project**, as `pastree-lsp.log`, with the
  server's stderr beside it as `pastree-lsp-stderr.log`. Both are appended to,
  with a separator line per server run, so history survives a restart and the
  name stays stable enough to keep open in a tail. Same reason as above: the
  log is the only place the real cause of a failed navigation shows up, so it
  lives where someone will actually look rather than in `%TEMP%`.

### Why the in-process path had to go

It ran `TPasSemaProject` **inside the 32-bit designtime package**,
synchronously. That was a deliberate, accepted limitation for the PoC stage -
not an oversight - and these are the reasons it could not stay:

- A designtime package is forced to run **Win32** (the IDE itself is a
  32-bit process) - there is no way to make this package itself Win64.
- The real target project this plugin is ultimately for is large enough to
  need **Win64 and several GB** to analyze (the same
  codebase OOMs when analyzed as Win32). That analysis was never going to fit
  inside this Win32 package.
- Synchronous analysis on the UI thread froze the IDE for as long as it took.
  The measurement above puts that at ~2.7s for this small package; at the real
  target's scale it is not a pause, it is a hang.

### What is left

`publishDiagnostics`. The server side already exists and sends them
unsolicited; the client currently drops them explicitly (see the stub comment
in `PasTreeIdePlugin.LspSession.pas`). Turning them into a feature needs three
things:

- **A push-based `didChange`**, alongside the sync-on-request path rather than
  instead of it: squiggles have to follow typing, and nothing currently reaches
  the server between requests.
- **Somewhere to draw.** ToolsAPI *can* do this - it has supported painting in
  the code editor since 11.3, on the same `INTACodeEditorEvents` notifier this
  plugin already registers for Ctrl+Click. Add `cevPaintLineEvents` or
  `cevPaintTextEvents` to `AllowedEvents`, and `PaintLine`/`PaintText` arrive
  with an `INTACodeEditorPaintContext` carrying `FileName`, `LogicalLineNum`
  (fold-aware, so it lines up with a diagnostic's own line numbers), a
  `TCanvas` and `CellSize` - enough to underline a column range.
  `PaintGutter` covers a gutter mark. See `ToolsAPI.Editor.pas`.
- **A design, which is the actual work**: severity filtering (error-tolerant
  analysis is the default and can be noisy), what clears a squiggle and when,
  navigation, and a paint path that does a per-visible-line lookup without
  allocating - it runs on every repaint of every line.

## Pointing the plugin at the server

No path is hardcoded. `FindServerExe` looks in two places, in order:

1. `%PASTREE_LSP_SERVER%`, if set - the development override, so the IDE runs
   whatever was last built into the repository's own `out\`. A value that is set
   but wrong is **reported rather than ignored**: falling back would silently
   run some other build, and a typo would cost an afternoon.
2. `pastree-server.exe` next to the package's own BPL, so a matched pair can be
   deployed together.

Note where the BPL actually lands - with no `DCC_BplOutput` in the `.dproj` it
is the IDE default, e.g.
`C:\Users\Public\Documents\Embarcadero\Studio\37.0\Bpl\` - which is *not* next
to this repo. So one of these has to happen before the plugin can do anything:

```
copy ..\..\out\pastree-server.exe "%PUBLIC%\Documents\Embarcadero\Studio\37.0\Bpl"
```

or, better for a development loop because it never goes stale:

```
setx PASTREE_LSP_SERVER "C:\Repos\pastree-lsp\out\pastree-server.exe"
```

The environment variable is only picked up on the next IDE start - a process's
environment is captured when it launches. Copying the exe next to the BPL, by
contrast, needs no restart: the session re-looks for the server on every
request until it finds one, precisely so that fixing this does not cost an IDE
restart on top of everything else.

**The environment variable is the setup in actual use**, with the server left
in its own `out\` directory and never copied anywhere. That keeps one binary in
one place: `build.bat` writes it, the IDE runs it, `pastree-server --version`
identifies it, and there is no second copy to go stale behind a rebuild.

If neither is in place, both features log to the Build tab and do nothing else -
naming which case it is, since the two need different fixes:

```
[pastree-lsp] PASTREE_LSP_SERVER points at "C:\...\out\pastree-server.exe", which does not exist.
[pastree-lsp] pastree-server.exe not found next to the package's BPL (C:\...\Bpl\) - put it there or point PASTREE_LSP_SERVER at it.
```

## Building and testing

**`build.bat` at the repository root builds everything** - server, this
package, all five harnesses - and runs the harnesses. That is the intended way,
and not merely a convenience: the package and the server share one version and
check each other for equality at the handshake, which only means anything if a
normal build produces both halves from the same commit. RAD Studio must be
closed (a running IDE holds the `.bpl`, a live LSP session holds the exe).

The individual commands, for when only one piece needs rebuilding - from a shell
with `rsvars.bat` sourced (`LspProjectSmoke` needs `%BDS%` to find the
RTL/VCL/ToolsAPI sources):

```
msbuild clients\rad-studio\PasTreeIdePlugin.dproj /t:Build /p:Config=Debug /p:Platform=Win32
dcc32 -B clients\rad-studio\tests\LspTransportSmoke.dpr -U"clients\rad-studio;source" -Eclients\rad-studio\tests\out -Nclients\rad-studio\tests\out
```

`-U` names two directories: this one for the IDE-free LSP units, and `source`
for the shared `PasLsp.ProductVersion` and `PasLsp.SourceText`.

Each harness takes the server path as its first argument and otherwise falls
back to `out\pastree-server.exe` resolved relative to its own exe; each prints a
per-check `[ok]`/`[FAIL]` list and exits non-zero on failure. Build them into
`tests\out\` - `LspClientSmoke` finds its fixtures at `..\fixtures` and
`LspProjectSmoke` finds this package's `.dproj` at `..\..`, both relative to the
test exe.

## Versions

**One version for the whole product**, shared with the server:
`PasTreeLspVersion` in `..\..\source\PasLsp.ProductVersion.pas`. Patch bump per
commit, minor for a substantial change - `SPEC.md` has the policy and the
reasoning. PasTree versions itself separately, and is the one dependency the
product states a minimum against.

One line per session in the Build tab, naming the server, the PasTree it was
built against, and the project it was started for:

```
[pastree-lsp] server ready: pastree-lsp-server 0.6.2 (PasTree 0.2.4) for AVImark.dproj
```

The project name is there because there is **one server per project
configuration** and the restart on a project switch is otherwise silent - a line
that did not say which project would leave the reader guessing which server they
are looking at. By name only; the full path is already in the configuration
block at the top of the server's own log.

The package used to announce itself with its own version and build stamp on
every load. That line is gone: it was paid for on every IDE start to answer a
question nobody has except in the minutes after a rebuild, and the version
check below already catches the case that matters. Its build stamp now rides
along with the mismatch warning, which is the moment it is actionable.

**Unequal versions mean a stale binary, not an incompatibility** - both are
built from one commit, so the client compares the server's reported version with
its own for equality and warns when they differ. That check replaced an "at
least version X" minimum which had failed to catch exactly this: on 2026-08-20 a
freshly built package ran against the previous day's exe, the stale server
satisfied the minimum, and the mismatch was found only because someone read the
version out of the Build tab.

The warning is not a refusal: a mismatched pair usually still navigates, and a
package that disabled itself over a version string would produce the same
symptom as every other misconfiguration here - "nothing happens on Ctrl+Click".

`pastree-server.exe --version` answers the same question without speaking
JSON-RPC, which is how to check which exe is actually deployed. The build stamp
comes from each binary's own timestamp rather than a compile-time constant
(Delphi has no compile-date macro), and it answers what a version cannot when no
commit has happened: whether the IDE is running the BPL you just built - worth
being able to check, given that rebuilding inside a live IDE session is
unreliable here.

## When a navigation does nothing

The editor's own report is deliberately thin - `[pastree] Goto Declaration: no
identifier/declaration resolved at cursor` in the Build tab is all a miss ever
says, because it fires on every Ctrl+Click. The actual reason is in
**`pastree-lsp.log`, in the same folder as the `.dproj`**, and it is worth
reading before assuming the resolver is at fault:

- `F1027 Unit not found: 'X'` on a `uses` line means the search paths are
  wrong, not the analysis: nothing declared in that unit can resolve. Compare
  the `configured: ... paths=N` line against the IDE's Library paths.
- `'X' at Y(l,c) did not resolve to a source declaration` means the identifier
  was found but has no declaration reachable from there - usually the same
  cause one step later, sometimes an honest answer (a compiler builtin has no
  source declaration anywhere).
- `no identifier at Y(l,c)` means the position index has nothing there at all,
  which points at the position or the text rather than the resolver.

`pastree-lsp-stderr.log`, beside it, is where a server that dies before it can
log anything leaves its last words.

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
  IDE before testing a rebuild. The likely cause is
  `AddEditorEventsNotifier` not being fully torn down by the IDE's own
  Uninstall step. This has cost real debugging time more than once, and the
  symptom is misleading: a change that appears not to work, or an access
  violation in unrelated IDE code, because the previously loaded BPL is
  still live. What makes this answerable is the version mismatch warning: a
  fresh server against a stale package is exactly what `build.bat` plus a
  not-restarted IDE produces, and the warning names the package's build stamp,
  so a stamp older than the build you just ran says the stale half is the BPL
  and only an IDE restart will fix it.

## Files

- `PasTreeIdePlugin.dpk` / `.dproj` - package project, `Win32`.
  `requires: rtl, vcl, designide`, its own seven units, and the two shared
  `..\..\source\PasLsp.ProductVersion.pas` and
  `..\..\source\PasLsp.SourceText.pas` - no PasTree, ever (see the top of
  this file).
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
- `tests/` - four console harnesses, each built with `dcc32` and run
  directly (no IDE, no package): `LspTransportSmoke` (graceful round trip,
  abrupt teardown with the server live, server killed behind our back),
  `LspClientSmoke` (handshake with a request queued behind it, real
  navigation over `tests/fixtures/`, lazy restart), and `LspProjectSmoke`
  (this package's own `.dproj` plus the IDE source paths - the check that the
  `initializationOptions` harvest actually resolves `TActionList`,
  `IOTAWizard` and the project's own types). `VersionSmoke` needs nothing at
  all - no server, no fixtures - and does three jobs: it pins `CompareVersions`
  (including the `0.10.0` vs `0.9.0` case plain string comparison gets wrong),
  it pins `PasLsp.SourceText` (the BOM rules, and "does this file hold the
  buffer's text" over a temp file it writes itself), and by being a Win32
  program over both shared units it fails to build if either ever gains a
  PasTree dependency - the tripwire on this package's one hard invariant.
- `PasTreeIdePlugin.Rename.pas` - rename: the prompt, the two-pass apply
  (verify everything, then write), and the results tab. Its unit header has
  the reasoning, including why the writer walks ASCENDING here while the
  demo walks backwards.
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
