| Signature help | **DELIVERED** | Code Insight; `IOTACodeInsightParameterList100` (`8594`) carries real parameter ranges | shipped with completion, same manager || Completion | **DELIVERED 2026-08-21** | Code Insight (`PasTreeIdePlugin.CodeInsight`) | the position-in-invalid-text block is gone: PasTree answers it || Rename | **DELIVERED 2026-08-30** | `IOTAEditWriter` via# PasTree IDE Plugin - capability specification

Status: draft, 2026-08-19. What this plugin COULD present, and what it would
take. The README describes what it does today; this describes the space.

Companion to the repository root's [SPEC.md](../../SPEC.md), which owns the other half of the
same question. That document walks the LSP 3.17 inventory and says which
requests the server implements, could implement, or refuses - a protocol-side
list. This one walks the **ToolsAPI** inventory and says which IDE surfaces
could show the answers. A capability needs both halves: a server that can answer
and a place in the IDE to put it.

## Versioning

This package shares **one version with the server**: `PasTreeLspVersion` in
`..\..\source\PasLsp.ProductVersion.pas`. The policy and the reasoning live in
the root [SPEC.md](../../SPEC.md); the short form is two rules, which PasTree
also follows for its own independent number:

- **Every commit bumps the PATCH.** `0.5.0` → `0.5.1` → `0.5.2`, mechanically,
  no judgement call about whether a change "deserves" it.
- **A substantial change bumps the MINOR** and resets the patch: a new feature,
  a new IDE surface, a reworked subsystem.

The per-commit patch bump exists so that a version identifies a **build**. This
package is rebuilt inside a live IDE that does not reliably pick up the new BPL,
so "which build is the IDE actually running" is a question that comes up
constantly, and a number that only moved on release could not answer it. (The
build stamp next to it answers the same question independently, and without
depending on anyone remembering to bump - the two are deliberate belt and
braces.)

What this replaced, and why, is worth keeping in mind when touching the
handshake: the package used to carry its own version plus a `cMinServerVersion`
minimum, which was a *guess* at what it needed from a separately versioned
server. Sharing the number turns that into an equality check - both halves come
from one commit, so any difference means one binary on disk was not rebuilt. The
old loose check had already failed to report exactly that. Only
`cMinPasTreeVersion`, on the server side, remains a real minimum, because PasTree
genuinely is a separately versioned dependency.

## How to read this

Every entry below is one of:

- **Have** - working in the IDE today.
- **Ready** - the server already answers it; only the ToolsAPI presentation is
  missing. These are the cheap wins, and the reason for writing this document.
- **Needs server work** - the IDE surface exists and is understood; the server
  side is a tier-2/tier-3 item in the server spec.
- **Blocked** - neither half is close, or something concrete prevents it. The
  reason is stated, because a "no" without a reason gets re-litigated every
  few months.

## What constrains the answers

These four facts decide what is implementable here, and they are the reason
several otherwise-obvious features are more expensive than they look.

**A designtime package is Win32 and in-process with the IDE.** Everything this
plugin does happens inside the IDE's own address space and, for anything
touching ToolsAPI, on its main thread. That is what forced the analysis out of
process to begin with, and it still forbids doing real work in a handler.

**Nothing may block the main thread waiting for the server.** Every answer
arrives in a callback on a later main-thread turn. So the first question to ask
of any candidate surface is whether the IDE will accept an answer LATER, and it
is asked explicitly in each entry below.

The good news, and it reshapes several entries: the IDE's own Code Insight
contract has an asynchronous form built for exactly this
(`IOTAAsyncCodeInsightManager`, `ToolsAPI.pas:10730`) - request id in, callback
out, with a cancel. Embarcadero clearly expects a language service to live in
another process. The bad news is that some surfaces are still synchronous by
construction: `IOTAHighlighter.Tokenize` (`1801`) is a per-line character-buffer
callback, and `IOTACodeInsightSymbolList.SetFilter`/`FindIdent` (`8428`) are
called on us per keystroke. Those can only be served from a local cache the
server fills in the background, never from a round trip.

**Teardown is unforgiving.** A live thread, a registered notifier or a queued
closure that outlives the BPL unload is an immediate crash, and this repo has
paid for that lesson more than once (see the package hot-reload note in the
README). Every registration a new feature adds is another thing to unregister,
in order, at unload. Reusing a registration we already own is materially
cheaper than adding one.

**Paint handlers run constantly.** The editor paint events fire per visible
line, per repaint. Anything hung off them must do a bounded lookup and allocate
nothing, or the editor becomes visibly slower while scrolling.

## Feeding the server: configuration

Not a user-visible feature, but it is upstream of the correctness of every one
of them, so it comes first.

**Today** the plugin hands the server the `.dproj` path plus the platform, and
the server evaluates that file itself with the same MSBuild logic the CLI tools
use. That works, and it is why the LSP path already gets the project's real
defines and search paths where the old in-process path did not. Two things are
nonetheless wrong with it:

- It reads the file **on disk**. Project options the user changed but has not
  saved are invisible, and so is anything the IDE itself contributes.
- It cannot see IDE-level paths at all. For a Win32 project that is where
  third-party and DCU-only library paths live.

**The IDE's own resolved values are readable**, and that is the better source.
`IOTAProject.ProjectOptions` gives `IOTAProjectOptions`; the active
`IOTABuildConfiguration` (via `IOTAProjectOptionsConfigurations`) exposes
`Value[PropName]` - and, importantly, `GetValue(PropName,
IncludeInheritedValues: Boolean)` at `ToolsAPI.pas:3461`. Build configurations
inherit from `Base`, so **without the inherited flag you read only what this
configuration overrides, not the effective value** - a Debug configuration that
adds no defines of its own would otherwise look like it has none.

The property names are constants in `DCCStrs.pas`, generated from the same
`DCCTask.xml` that defines the `.dproj` schema, so they are exactly the keys the
project file uses:

| What the server needs | `DCCStrs` constant | Key |
|---|---|---|
| Conditional defines | `sDefine` | `DCC_Define` |
| Unit search path | `sUnitSearchPath` | `DCC_UnitSearchPath` |
| Unit scope names (namespaces) | `sNamespace` | `DCC_Namespace` |
| Unit aliases | `sUnitAlias` | `DCC_UnitAlias` |
| Include path (`{$I}`) | `sIncludePath` | `DCC_IncludePath` |

Beyond paths, a set of switches change **what the analysis means**, not just
what the compiler emits, and the server currently assumes defaults for all of
them: `sLegacyIFEND`, `sStringChecks`, `sLongStrings`, `sExtendedSyntax`,
`sTypedAtParameter`, `sWriteableConstants`, `sMinimumEnumSize`, and the
range/IO/overflow/assertion checks. `{$IFEND}` acceptance in particular decides
whether a file parses at all.

`DCCStrs` also carries the whole warning table as `DCC_<WARNING_NAME>` triples
(`true`/`false`/`error`), which is the source for honouring a project's warning
suppression - and its promotion of warnings to errors - in our diagnostics.

Three concrete hazards to design around:

- **Name collision.** `DCCStrs` and `CommonOptionStrs` both declare
  `sIncludePath`, `sTaskName`, `sOutputExt` and `sShowGeneralMessages`, with
  DIFFERENT string values (`DCC_IncludePath` vs `IncludePath`). With both in a
  `uses` clause the later one silently wins and the wrong key is queried with no
  compiler complaint. Always qualify: `DCCStrs.sIncludePath`.
- **Unexpanded macros.** Values can come back containing `$(...)` MSBuild
  macros; whoever consumes them has to expand or reject them.
- **Regenerated headers.** Both units are machine-generated and say so, meaning
  constant *names* are not a cross-version stability contract even when the
  string values are.

**Platform data has its own service.** `IOTAPlatformServices` and
`IOTAPlatform160.GetNamespaceSearchPaths` (`PlatformAPI.pas:233`) give the
platform's implicit unit-scope search list - `Win;System.Win` and friends -
which appears in NO `.dproj`. The server currently hardcodes an equivalent list
(`PasDefaultNamespaces`), read once out of a real IDE-written project file; this
is the authoritative source for it. `IOTAProjectPlatforms.CurrentPlatform`
(`PlatformAPI.pas:893`) is the active-platform source of truth, and
`IOTAPlatformSDKNotifier` (`2185`) is a legitimate reconfigure trigger.

**Still missing, and it is a real gap.** The IDE's own Library Path and Browsing
Path per platform are in none of this - not in `DCCStrs`, not in `PlatformAPI`.
They live in environment options: `IOTAServices.GetEnvironmentOptions`
(`ToolsAPI.pas:7301`) and `GetBaseRegistryKey` (`7287`), under
`Library\<Platform>`. Until that is read, a project depending on a third-party
library installed IDE-wide will have identifiers the server cannot resolve, and
the symptom is the quiet one: navigation resolves nothing, with no error.

## Feeding the server: change events

The plugin currently syncs documents only when a request is about to go out
(sync-on-request, see the README for why). That is right for navigation and
wrong for anything continuous, and these are the surfaces that fix it.

- **`INTAEditViewNotifier.EditorIdle(View)`** - `ToolsAPI.pas:2346`. Fires after
  editing stops for a period **tied to the user's own Code Insight delay
  setting**. This is the debounce trigger the push-based `didChange` needs, and
  it is better than any timer we would pick ourselves: the user has already told
  the IDE how patient they are. Note the `BeginPaint`/`PaintLine`/`EndPaint`
  members on this same interface are explicitly `deprecated` in favour of
  `ToolsAPI.Editor`'s events (`2364`, `2397`, `2405`) - do not use them.
- **`IOTAModuleNotifier`** - `2926`, with `Modified` and `AfterSave` inherited
  from `IOTANotifier` (`1493`), plus `BeforeRename`/`AfterRename` on `…80`
  (`2940`). Per-document change and rename.
- **`IOTAEditorContent.GetContentAge: TDateTime`** - `1607`. A cheap version
  stamp. We currently detect "did this buffer change" by comparing the whole
  text we last sent; this is O(1).
- **`IOTAEditBufferIterator`** - `7530`, from
  `IOTAEditorServices60.GetEditBufferIterator` (`7764`). Enumerates every open
  buffer, which is the missing `didOpen` catch-up at startup: today the first
  request discovers them.
- **`IOTAProjectNotifier`** - `3928`: `ModuleAdded`, `ModuleRemoved`,
  `ModuleRenamed`. Feeds `workspace/didChangeWatchedFiles` precisely instead of
  the server guessing from a file watcher.
- ~~**`IOTAIDENotifier80`** - `5929`~~ - **partly adopted 2026-08-21.**
  `TProjectOpenNotifier` (a plain `IOTAIDENotifier`) starts the analysis on
  `ofnEndProjectGroupOpen` and `ofnActiveProjectChanged`, so the ~15 s a large
  closure costs is spent while nobody is waiting instead of inside the user's
  first Ctrl+Click. What is still NOT adopted is using it to replace "compare
  the harvested config on every request" - `EnsureSession` still does that, and
  it is what makes the notifier-driven restart correct rather than a second
  source of truth.
- **`IOTACompileNotifier`** - `9793`, and `IsBackgroundCompileActive`. Worth
  having in order to *stop* analysing while the IDE compiles in the background,
  rather than competing with it for the machine.
- **`IOTAEditLineTracker` + `IOTAEditLineNotifier`** - `7474` / `7469`, from
  `IOTAEditBuffer60.GetEditLineTracker` (`7501`). Attaches data to a line and
  reports `LineChanged(OldLine, NewLine)` as the user edits. This is the fix for
  the *stale decoration* problem: between two server round trips, everything we
  have drawn is anchored to line numbers that the user is actively invalidating.
  Without it, squiggles drift as soon as someone presses Enter above them.

Also worth adopting for configuration, on top of the previous section:
`IOTABuildConfiguration140.GetValues(PropName, Values, IncludeInherited)`
(`3383`) reads **list-valued** properties like search paths as a list instead of
one flattened string, and **`IOTAServices.ExpandRootMacro`** (`7379`) expands
`$(BDS)`-style macros - which is the answer to the unexpanded-macro hazard noted
above. `IOTAProjectUnitScopes.GetUnitScopes(ConfigName, PlatformName)`
(`10478`) gives the project's unit scope prefixes directly.

## The strategic fork: become Code Insight, or sit beside it

This is the one decision that shapes everything else, and it was not obvious
before this survey.

**The IDE has a first-class contract for an external language service.**
`IOTACodeInsightManager100` (`8611`) plus `IOTAAsyncCodeInsightManager`
(`10730`, `290` at `10782`) is a provider interface for completion, signature
help, hover and go-to-definition, in the IDE's own UI, with an async
request/callback shape. `IOTACodeInsightSelection` (`9065`) puts our name in
**Tools → Options → Editor → Source → Insight Provider**, so the user chooses
between the built-in engine and ours. And the option-change constants at
`1016`-`1023` - `icExecutableChanged`, `icTimeoutChanged`, `icInitOptionChanged`,
`icLanguageChanged` - together with
`IOTACodeInsightManagerEnvOptions64BitBinary.Use64BitBinary` (`8841`) show the
IDE already has UI for configuring an out-of-process, 64-bit language server.
We are not fighting the grain here; we are standing exactly on it.

The appeal is obvious: completion, hover and signature help arrive in the
native UI, keyboard-triggered and themed, with no popup windows of our own.

The costs are real and should be stated before anyone commits:

- `IOTACodeInsightManager100` is roughly thirty methods, and the async interface
  is a *companion* - registration goes through
  `IOTACodeInsightServices60.AddCodeInsightManager` (`9019`), which takes the
  synchronous interface. So the whole surface has to be implemented and then
  the async one offered.
- Some of it is called synchronously per keystroke (`SetFilter`, `FindIdent` on
  `IOTACodeInsightSymbolList`, `8428`), so a local cache is mandatory.
- Becoming the Insight Provider means **replacing** the IDE's engine for Pascal,
  not augmenting it. Everything the built-in one does that we do not - every
  edge case, every file type - becomes a regression the moment a user switches.
- `GotoDefinition` on the synchronous interface returns file+line with no
  column; only `IOTAAsyncCodeInsightManager290.AsyncGotoDefinitionEx` (`10782`)
  gives a column.

**DECIDED 2026-08-21: sit beside it for now, and becoming the manager IS the
destination.** The concrete build plan - server plumbing, the
`PasTreeIdePlugin.CodeInsight` manager skeleton, gated registration, and the
final switch - is [COMPLETION.md](../../COMPLETION.md) at the repository root. Not "revisit someday" - the manager route is the committed
endgame, deferred only until the server answers enough of the interface to
replace what a user would lose by switching. The gate is **completion** (a
tier-3 item on the server side, blocked on position-in-invalid-text): a manager
that navigates brilliantly but cannot complete is a regression the moment the
user selects it, because selecting a manager replaces the IDE's engine for
Pascal wholesale, not per-feature.

What the migration buys and costs, worked out in advance so the future
implementer does not re-derive it:

> **The gate named above is OPEN.** Completion shipped 2026-08-21 (PasTree
> answers position-in-invalid-text; the manager is `PasTreeIdePlugin.CodeInsight`
> and is registered and live), and signature help with it. The paragraph above
> is kept because the *reasoning* for the endgame still stands - what is stale
> is only its claim about what is blocking.

- **Superseded by the manager** - `GotoDefinition`/`AsyncGotoDefinitionEx` is
  the IDE's own Ctrl+Click: the mouse-notifier override in
  `PasTreeIdePlugin.GotoDeclaration` (down/up suppression, position mapping)
  and the `cEdMenuCatIdentifier` menu takeover in `PasTreeIdePlugin.Wizard` both
  get **deleted**, and with them the one-way-door caveat. (BOTH were restored on 2026-09-01, for the
  users who cannot spend the Insight Provider slot - RAD Studio gates part of
  the editor UI on DelphiLSP being selected. The mouse override stands down
  whenever PasTree IS the selected provider, so the two never both run; the
  menu takeover has no such option, because the native item never reaches the
  package at all, and it is therefore decided once at load from the same
  switch. The one-way-door caveat comes back with it, knowingly.) The IDE draws the
  Ctrl+hover underline from OUR resolver (today it underlines from the native
  engine while the click resolves through ours - a visible disagreement we
  currently just live with), navigates, and feeds its own history.
- **Not covered by the manager, stays ours either way** - Find References
  (no references in the interface; our Messages-panel tree remains the
  surface), the decl↔impl toggle key binding (not a Code Insight concept), and
  the project-open prewarm.
- **The price of entry** - all ~30 methods of `IOTACodeInsightManager100`
  (registration takes the synchronous interface; the async one is a companion
  offered via `Supports`), a local symbol cache for the per-keystroke
  synchronous calls (`SetFilter`/`FindIdent`), and hint text for Ctrl+hover.
  Delegating the parts we lack to the built-in manager (discoverable via
  `GetCodeInsightManager(Index)`) was considered and rejected: DelphiLSP's
  manager is not designed to be driven through a foreign wrapper, and the
  manager-selection order for two `HandlesFile('.pas')` claimants is
  undocumented.

## The open experiment - CLOSED 2026-08-22, verdict NEGATIVE

The spike ran a full session armed, with a live probe, and answered on two
independent grounds (readout verbatim from the Build tab):

- `probe: FindFileTrait(IOTAModuleErrors) answers NIL` - the personality-wide
  `AddPersonalityTrait(sDelphiPersonality, ...)` registration is INVISIBLE to
  the very lookup that would have to find it.
- `probe: the module itself implements IOTAModuleErrors natively (GetErrors
  answers 0 entries)` - the editor's query is answered by the IDE's own
  module implementation before any fallback could run. The trait route is
  dead no matter how the registration is spelled.

`GetErrors` on our trait was never called. Consequences: diagnostics take
the painted route (`PasTreeIdePlugin.ErrorPaint`, PaintText overlay -
delivered the same day), and the same wall stands for `IOTAModuleRegions`
(folding), `IOTAHelpInsight` and `IOTACodeBrowsePreview` - assume the
module answers those natively too and plan the custom-draw route for each.
The original reasoning follows, kept because the catch it names is now a
measured fact.

## What the experiment was (historical)

Two interfaces would give us **native** diagnostics and **native** folding, with
no painting code at all:

- **`IOTAModuleErrors`** - `3257`. `GetErrors(FileName): TOTAErrors`, records
  carrying text, start/stop character positions and severity (1 error,
  2 warning, 3 hint). The declaration's own comment says the editor uses this to
  draw error hints and red squiggles. This is `publishDiagnostics`, rendered by
  the IDE, including Error Insight.
- **`IOTAModuleRegions`** - `3225`. `GetRegions(FileName): TOTARegions` with
  kind, start/stop and an `Active` flag. That is `foldingRange`, fed into the
  IDE's own elision engine - and `Active` even models inactive `{$IFDEF}`
  branches.

**The catch, and it is unresolved.** Both are documented as "query an
`IOTAModule` for this interface", and for a `.pas` file that module belongs to
the Delphi personality, which we do not implement. The only registration path
visible anywhere is `IOTAPersonalityServices100.AddFileTrait(APersonality,
AFileType, ATraitGUID, ATrait)` (`9445`), with `GetFileTrait` /
`SupportsFileTrait`. Whether the IDE consults file traits for *these particular
GUIDs* cannot be determined from the declarations.

So this is a spike, not a plan: register a trait, return a hand-built
`TOTAErrors`, see whether a squiggle appears. It is a few hours, and the answer
decides whether diagnostics and folding are nearly free or need the whole
painting path below. Everything else in this document is knowable from the
declarations; this is the one thing that is not, which is exactly why it goes
first.

`IOTAHelpInsight` (`6787`) and `IOTACodeBrowsePreview` (`8851`) - a
documentation panel and peek-definition, three methods each - sit behind the
same wall and would be answered by the same spike.

## Capability inventory

Status column: **Have** / **Ready** (server answers it; only the IDE side is
missing) / **Server** (needs server-side work first) / **Spike** (blocked on the
file-trait question above).

### Navigation

| Capability | Status | IDE surface | Notes |
|---|---|---|---|
| Go to declaration | Have | the Code Insight manager, plus a mouse override and the menu takeover for everyone else | With PasTree selected as Insight Provider, Ctrl+Click routes through `AsyncGotoDefinitionEx`. Under any other provider the mouse-notifier override in `PasTreeIdePlugin.GotoDeclaration` claims plain Ctrl+Click. The `cEdMenuCatIdentifier` takeover is back too - a menu item never reaches the package, so nothing else can reach it. Both restored 2026-09-01 under one switch; the click is decided per click, the takeover once at load (one-way door) |
| Declaration ↔ implementation toggle | Ready | a menu item | server already answers `declaration` and `implementation` |
| Find references | Have | Messages panel, grouped by file | upgrade path below |
| Type definition | **Have** (2026-08-21) | "Find Type Declaration" menu item | same history-aware navigation as the other jumps |
| Peek definition | Server | `IOTACodeBrowsePreview` (`8851`) | trait route ruled out by the closed experiment; needs a window of our own |
| Back/Forward across jumps | Have | `IOTAHistoryServices` | we supply our own captioned `IOTAHistoryItem` |

### Diagnostics

| Capability | Status | IDE surface | Notes |
|---|---|---|---|
| Squiggles, native | **DEAD** (spike NEGATIVE 2026-08-22) | - | the module answers `IOTAModuleErrors` natively and `FindFileTrait` never saw our registration; see the closed experiment above |
| Squiggles, painted | **Have** (2026-08-22) | `PasTreeIdePlugin.ErrorPaint`: `PaintText` after-event overlay, per token run | wavy underline over the run∩diagnostic column intersection, red/orange/gray by severity; repaint via the session's diagnostics-changed listener |
| Gutter error glyph | Ready | `RequestGutterColumn` (`984`) + `PaintGutter` (`726`) | reserves our own gutter column; size is in 96-DPI pixels, the editor scales it |
| Whole-file diagnostic minimap | Ready | `INTACodeEditorScrollbarAnnotation` (`1005`) + `AddScrollbarAnnotationEntry` (`1094`) | marks every affected line on the scrollbar; 16px of lanes shared between providers |
| A diagnostics list pane | Ready | custom messages, or `IOTAToDoManager` (`8330`) | see "Result surfaces" |
| Honour project warning suppression | Server | - | the `DCC_<WARNING>` triples name which warnings are off or promoted to errors |

### Structure and search

| Capability | Status | IDE surface | Notes |
|---|---|---|---|
| Outline | **Have** (2026-08-22, first live run pending) | Structure pane, private `StructureType` 'PasTree.Outline' | refreshed on EditorViewActivated; two recorded unknowns: is `IOTAStructureView` a BorlandIDEServices service (logged once if not), and do the IDE's providers re-take the pane |
| Outline follows the caret | Ready | `IOTAStructureView370.SelectNodeEx` (`105`) + `EditorSetCaretPos` (`ToolsAPI.Editor.pas:878`) | scroll-into-view select, driven by a real caret event instead of polling |
| Outline survives a refresh | Ready | `IOTAStructureNodeStatePreserver` (`135`) | without it, a rebuild collapses everything the user expanded |
| Project-wide symbol search | **Have** (2026-08-22) | IDE Insight omnibox (Ctrl+.), 'PasTree symbols' category | prefetched index (the dialog's RequestingItems is once-per-open, no filter text); first cold open may be empty and kicks the fetch |
| Document highlight (occurrences) | Ready | `PaintText` underlay, or `plsBackground` row wash | server answers it today |
| Folding ranges | Server | `pgsElision` custom-draw | `IOTAModuleRegions` ruled out by the closed experiment (module answers natively); `IOTAElideActions` (`2530`) only exposes categories, not arbitrary ranges |

### Editing

| Capability | Status | IDE surface | Notes |
|---|---|---|---|
| Rename | **DELIVERED 2026-08-30** | `IOTAEditWriter` via `CreateUndoableWriter` (`2551`) | apply edits front-to-back - the writer cannot move backward (`1690`), and a plain writer flushes undo (`1693`) |
| Rename, in-place multi-caret | Server | `IOTASyncEditPoints` (`2158`) + `IOTAEditBlock.SyncEditBlock` (`2226`) | drives the editor's own sync-edit mode from positions we supply |
| Rename, from the outline | Server | `IOTAEditableStructureNode` (`245`) | F2 on an outline node, `SetValue` comes back to us - a rename UI for free |
| Quick fixes / code actions | Server | menu, plus `stSurroundsWith`/`stRefactoring` templates (`CodeTemplateAPI.pas:57`) | the IDE already stores surround-with templates we could expose as actions |
| Completion | **DELIVERED 2026-08-21** | Code Insight (`PasTreeIdePlugin.CodeInsight`) | the position-in-invalid-text block below is gone - PasTree's completion engine answers it |
| Signature help | **DELIVERED** | Code Insight; `IOTACodeInsightParameterList100` (`8594`) carries real parameter ranges | shipped with completion, same manager |
| Semantic tokens | Server | `PaintText` with `AllowDefaultPainting := False` | `IOTAHighlighter` (`1801`) is the other route but is synchronous per line; either way it must paint from a cache. `INTACodeEditorOptions` (`881`) is read-only - a new named colour cannot be registered, only painted |

### Syntax highlighting: override the lexer, or repaint over it

The syntax highlighter is genuinely replaceable, not merely paintable-over:
implement `IOTAHighlighter` (`ToolsAPI.pas:1801`), register it with
`IOTAHighlightServices.AddHighlighter` (`1893`), and assign it - the
`IOTAEditOptions.SyntaxHighlighter` property is read/**write** (`7745`).
Cross-line state is provided for and is ours to define: `TOTALineClass` is
documented as user-definable "to gain context for lines", and
`TokenizeLineClass` returns the state at end of line for the IDE to feed into
the next, which is enough to lex `{...}`, `(* *)` and multi-line strings
correctly.

**But that path cannot express semantics, for three separate reasons, any one of
which is decisive.** The code vocabulary is fixed and lexical - `TOTASyntaxCode`
is a `Byte`, the declaration says "do not exceed `SyntaxOff`" (15), and the
usable values (`440`-`454`) are whitespace, comment, reserved word, identifier,
symbol, string, number, float, hex, binary, preproc, assembler. There is no
"type name", "parameter", "local", "method" or "unit": every identifier is
`atIdentifier` whatever it resolves to, which is exactly the distinction
semantic tokens exist to draw. Second, no new colour can be registered -
`INTACodeEditorOptions` exposes `FontColor`/`BackgroundColor`/`FontStyles`
read-only, with no setter anywhere, so even a spare code would have nowhere for
the user to configure it. (`atOverridable = $8000` at `456` looks promising and
is not usable: it does not fit the `Byte` element, and appears nowhere else in
the ToolsAPI headers.) Third, `Tokenize` is synchronous, per line, over a byte
buffer, called from the paint path - it can never consult the server.

**So the recommendation is a hybrid, and it is cheaper than either extreme.**
Do not replace the highlighter at all. `PaintText` already delivers each token
run *together with the `SyntaxCode` the IDE assigned it*, so the line is
pre-split for us: leave everything lexical - comments, strings, keywords,
numbers - to the built-in highlighter, which works and which the user has
already themed, and repaint only the runs whose code is `atIdentifier` and for
which the server has a classification cached. Minimum pixels drawn, maximum
reuse, and the user's colour scheme survives everywhere else. Replacing the
lexer would only be worth it if the *lexical* markup were wrong, and it is not.

One case where our analysis is strictly better than the IDE's is worth naming
here: inactive `{$IFDEF}` branches. The editor has an `eceDisabledCode` cell
state, so it models the idea, but the server evaluates conditional compilation
properly and knows which branches are really dead.

### Result surfaces

| Capability | Status | IDE surface | Notes |
|---|---|---|---|
| Grouped, navigable result tree | **Done 2026-08-31** | `IOTACustomMessage100` (`6316`) + `INTACustomDrawMessage` (`6332`), tree via `AddCustomMessagePtr`/`AddCustomMessage(Parent)` | `PasTreeIdePlugin.ResultRows`, used by Find References: owner-drawn syntax-colored snippets, match highlight, navigable headers. The Rename tab is the same shape and the natural next adopter |
| Menu items on results | Ready | `INTAMessageNotifier.MessageViewMenuShown` (`6458`) | "rename this", "open all" |
| A filterable results pane | Ready | `IOTAToDoManager` (`8330`) + `INTAToDoItem` (`8250`) | free filtering and navigation; **Professional/Enterprise only** (`10858`), so gate on `IOTAVersionSKUInfoService` (`10810`) |
| Hierarchy views (call, type) | Server | `INTACustomEditorView` (`7882`) or `INTACustomDockableForm` (`7121`) | a whole frame as an editor tab or a dockable window; an editor view also gets a Structure pane via `IOTACustomEditorViewStructure` |
| Progress for long operations | **Done 2026-08-31** | `IOTAIDEWaitDialogServices270` (`10597`) | `PasTreeIdePlugin.WaitDialog`, over Find References and Rename. `290` (`10626`) makes it cancellable - not used yet; still the natural home for the server's `$/progress` |

### Keyboard

| Capability | Status | IDE surface | Notes |
|---|---|---|---|
| Shortcuts for our commands | **Done 2026-08-21** | `IOTAKeyboardBinding` (`7594`) with `btPartial` (`1432`) | `TToggleKeyBinding` takes Ctrl+Shift+Up/Down for the decl↔impl jump. `btPartial` layers over the user's keymap instead of replacing it and shows up on Key Mappings, where it can be reordered or switched off; `btComplete` would claim to *be* the keymap. Returns `krHandled` even with nowhere to go - `krUnhandled` hands the key back to the IDE, which would then run its own version of the jump, and the two disagreeing is indistinguishable from ours misbehaving |
| Trigger characters | Server | `cevKeyboardEvents` + `EditorKeyDown` (`848`) | coordinate with `IOTACodeTemplateServices.AutoComplete` (`CodeTemplateAPI.pas:290`) and read the user's template trigger keys (`303`-`311`) so we do not shadow snippet expansion |

## Infrastructure to adopt regardless of feature order

Small, cheap, and each one fixes something we currently do wrong or crudely:

- **`ENonAIRException`** - `ToolsAPI.pas:1085`. Exceptions descending from it do
  not raise the IDE's stack-trace dialog or offer to file a report. For a plugin
  whose server can die under it, ours should descend from this.
- **`IOTAServices.GetLocalApplicationDataDirectory`** - `7343`. The right home
  home for a *cache*. Not for the log: that now goes next to the project as
  `pastree-lsp.log`, with stderr beside it, because a log is only useful where
  the person debugging a failed navigation will look for it.
- **`INTAIDEUIServices.ThemeAwareColors[]`** - `ToolsAPI.UI.pas:99`, over
  `itcRed`/`itcYellow`/`itcBlue`/`itcGray`. Anything we paint on a raw canvas is
  unthemed by default; hardcoded `clRed` is unreadable in the dark theme. Pair
  with `INTACodeEditorOptions.FontColor[]` for the syntax palette, and
  `IOTAIDEThemingServices250` (`10537`) for custom panes.
- **`INTAIDEUIServices.InputQuery`** - `ToolsAPI.UI.pas:91`. A correctly themed
  prompt; enough for a rename dialog without designing a form.
- **`IOTAEditPosition.RipText`** (`2095`) or
  **`INTACodeEditorState290.EditorToken`** (`ToolsAPI.Editor.pas:304`) - the
  identifier under the cursor, tokenized by the IDE. Replaces `IdentifierAt` in
  `PasTreeIdePlugin.FindReferences`, which scans word characters by hand.
- **`INTACodeEditorState280.GetCharacterPosPx`** (`219`) - position to pixels,
  which is what anchors a squiggle rect or a popup. We already use its inverse,
  `PointToCharacterPos`.
- **`InvalidateEditorLogicalLine`** (`992`) - repaint by *logical* line, so LSP
  line numbers go straight in without mapping around folds.
- **`IOTAEditorServices70.GetEditOptionsIDString`** (`7775`) - maps a file to
  `cDefEdPascal` and friends: a reliable `languageId` for `didOpen` instead of
  hardcoding `'pascal'`.
- **`IOTABufferOptions`** (`7459`) - tab stops, tab-vs-space, block indent. Any
  edit we generate should match the user's settings, and this is also where the
  `TOTAEditPos` (tab-expanded column) versus `TOTACharPos` (character index)
  distinction bites: `ToolsAPI.pas:1136`/`1145`, and
  `IOTAEditView40.ConvertPos` (`1983`) converts. Tab-indented Pascal is the norm
  and this is exactly where column bugs live.

## Cross-cutting hazards found in the declarations

- **Versioned interfaces are separate, not merged.** `INTACodeEditorEvents370`
  is its own interface; an object must declare both it and
  `INTACodeEditorEvents` or the IDE's `Supports` probe fails and we silently get
  only the legacy mouse events - no keyboard, no caret. Same for every `…280` /
  `…290` / `…370` pair. Always `Supports`, never assume.
- **`TNTACodeEditorNotifier` returns `[]` from all three `Allowed*` methods**
  (`1249`, `1254`, `1259`). `AllowedEvents`, `AllowedLineStages` and
  `AllowedGutterStages` are three separate opt-ins and each must be overridden.
- **`AllowDefaultPainting` on `PaintText` is documented as effective only when
  `BeforeEvent` is True** (`756`); the same is not stated for `PaintLine` or
  `PaintGutter`. Verify rather than assume.
- **Nothing in a paint handler may touch the server.** Paint from a cache the
  reader thread filled, then `Invalidate*`.
- **`IOTAStructureNode.Data` is reserved by the IDE** (`StructureViewAPI.pas:221`)
  - keep a side table, do not stash a symbol pointer there.
- **Structure and history interfaces are `IDispatch` + `safecall`**: stub the
  four `IDispatch` methods and implement `SafeCallException`, or an exception in
  a getter becomes a silent nothing.
- **`GetKnownEditors` / `GetKnownViews` return a concrete `TList<>` by value**
  across the package boundary (`ToolsAPI.Editor.pas:955`/`959`) - settle
  ownership before calling either in a loop.
- **Do not hold `IOTAEditView` references** (`ToolsAPI.pas:2004`); and
  `INTACodeEditorState.Refresh` (`310`) implies the state object caches, so
  re-acquire per frame rather than keeping one.
- **`EditIntf.pas` is `deprecated` at the unit level** (line 10) and nothing in
  it is live. Its one useful legacy is conceptual: the `TEditPos` versus
  `TCharPos` distinction described above.

## Suggested order

1. **The file-trait spike.** It is the only unknown, and it decides whether
   diagnostics and folding cost a day or a fortnight.
2. **Diagnostics**, by whichever route the spike settles - plus the gutter
   column and the scrollbar minimap, which are independent of it and are what
   make a diagnostic findable rather than merely visible.
3. **`EditorIdle`-driven `didChange`**, without which diagnostics lag behind
   typing. Bring `IOTAEditLineTracker` with it or the decorations drift.
4. **The Structure pane outline**, with caret sync and state preservation. The
   server already answers `documentSymbol`; this is presentation only.
5. **Result-surface upgrade** for Find References: hierarchy plus owner-drawn
   rows, which also closes the "highlight the match in the snippet" TODO.
6. **Keyboard bindings** for what exists by then.
7. **Workspace symbol** into IDE Insight, once the server answers it.
8. **Code Insight**, as its own project, once the server can answer completion.

## The live queue (2026-08-22, user asks - supersedes "Suggested order" above,
## whose items 1-8 are all delivered or running)

1. **Error Insight - DELIVERED via the paint path (2026-08-22, first live
   run pending).** The spike answered NEGATIVE the same day (closed
   experiment above); `PasTreeIdePlugin.ErrorPaint` draws the squiggles
   from the session's publishDiagnostics cache. Still queued from the
   diagnostics table: the gutter glyph and the scrollbar minimap, which
   make a squiggle findable rather than merely visible.
2. **Help Insight: XMLDoc documentation - DELIVERED 2026-08-23 (first live
   run pending).** PasTree 0.6.3 landed §8D, so the block arrives from the
   engine (`SymDocComment` for hover, `ItemDocComment` per completion item)
   and the RENDERING is ours: `source/PasLsp.XmlDoc.pas` turns the raw
   `///` run into display text - summary, remarks, parameters, returns,
   exceptions, blocks separated by blank lines, and deliberately NO
   markdown emphasis anywhere, because a `**Returns:**` would reach a
   Delphi hint window with the asterisks still in it. Hover appends it
   between the code fence and the provenance note;
   `completionItem.documentation` carries it per row, EAGERLY, because
   `IOTACodeInsightSymbolList80.GetSymbolDocumentation` is a synchronous
   UI-thread call and a `completionItem/resolve` round-trip is not
   available there. `cMinPasTreeVersion` has moved on since (0.13.2 today) - see
   [PasLsp.Version](../../source/PasLsp.Version.pas) for the current value
   rather than trusting a number written here.
   **The look, settled 2026-08-23 by reading the product.** The first live
   run said the text was right and the presentation wrong - the doc ran
   straight into the declaration line, blank lines and all. That symptom is
   the answer: **the IDE's Help Insight surfaces are HTML windows**, and an
   HTML renderer collapses newlines. It is documented, quietly, in two
   places, and the product ships the proof:

   - `IOTACodeInsightSymbolList80.GetSymbolDocumentation` - "Return
     documentation for the symbol, in HTML" (`ToolsAPI.pas:8506`).
   - `IOTACodeInsightManager90.GetHelpInsightHtml: WideString` (`8864`) -
     the viewer's Help Insight pane for the selected row. A SIBLING of
     `IOTACodeInsightManager`, so the IDE finds it with `Supports`; we now
     implement it.
   - `ObjRepos\HelpInsight.xsl` + `HelpInsight.css` - the IDE builds its own
     page by XSL-transforming a `<member>` document. So the native look is
     not a mystery to reverse-engineer: `PasLsp.XmlDoc.HelpInsightPage`
     emits what that transform emits - `<div class="maincaption">` with the
     declaration, `<a class="codelink" href="helpinsight:/filelink:<path>?
     <line>,<col>">file (line)</a>`, then the summary and `h4`+`dl`
     sections. Same classes, same stylesheet, same link scheme.

   **Measured the same day: the EDITOR hint is not one of those windows.**
   Fed the HTML page, `AsyncGetHintText`'s hint showed the tags. So the hint
   is plain text again - but with its blank lines kept, which is what the
   first complaint was actually about. Two leads on the rich window remain,
   and both are cheap:

   - **the option set.** Code Insight settings live per option set under
     `<BaseRegistryKey>\Code Insight` - `Borland.EditOptions.Pascal` and
     `Borland.EditOptions.Borland.CodeInsight.LSP.Pascal`, each with a
     `Help Insight` flag (True in both here). `GetOptionSetName` returned
     `''` until 2026-08-23, so OUR provider had no set at all and every such
     option read as a bare default. It now names the classic Pascal set, so
     the user's own Code Insight settings apply to us - including whatever
     `Help Insight` gates.
   - **`IOTAHelpInsight` - ANSWERED, negative (2026-08-23).** The readout
     says `absent on module <the open .pas>`, so the interface the editor's
     Help Insight window is fed from is not on the module at all and there is
     nothing for us to implement. Combined with the hint being a plain
     window, that closes the question: **the editor tooltip is plain text,
     and the only way to make it look like the native one is to draw it
     ourselves** (`INTACustomDrawCodeInsightViewer.DrawLine` with
     `DrawingHintText=True`, item 6's custom hint window). Do not re-derive
     this; the option set below was the other candidate and changed nothing.

   The VIEWER's documentation pane, by contrast, does render HTML - and it
   sizes itself to the **min-content** width of the document it is handed
   (measured: the pane came out as wide as the longest word, one or two words
   per line, and resizing the popup changed nothing). So `XmlDocHtml` wraps
   its sections in a fixed-width table; `cDocPaneWidthPx` in
   `source/PasLsp.XmlDoc.pas` is that width and the comment there carries the
   measurement.

   Hover therefore carries `pastreeHtml` beside the standard markdown
   contents (our field, ignored by other clients - the `pastreeCall`
   precedent) and it is what the rich window would be fed the moment one is
   reachable; completion rows carry `data.docHtml`, which the viewer's
   documentation pane does want as HTML. A custom-drawn
   hint window (see 6) is no longer the plan for this; what remains open is
   the OTHER door into the editor's Help Insight window,
   **`IOTAHelpInsight`** (`6787`) - queried FROM the module, which the
   file-trait spike suggests is the IDE's own. A one-time readout now says
   which it is on the first hover of a session (`[pastree] IOTAHelpInsight:
   ...` on the Build tab), so the next decision is made on a measurement
   rather than on the assumption.
3. **Class completion (Ctrl+Shift+C), ours - DELIVERED and VERIFIED LIVE
   2026-08-23 (v0.13.0 → v0.15.2), on a 4000-line demo unit and a
   22 000-line one in the user's own project.** Bodies, property accessors,
   bare-property completion and interface properties all work; the user
   confirmed each stage. What the live runs cost, and what they taught, is
   the list at the end of this item - every one of the seven was a real
   defect that no harness had a chance of catching, because each needed a
   REAL buffer (a parameter with a default, a class method, a 22 000-line
   file, a property as the last member of its section, an unfinished line).

   `pastree/classComplete` (our
   request, not an LSP method - see the handler's comment for why not
   `codeAction`) parses the LIVE buffer and answers with the text that
   implements every declaration lacking a body: methods, and - the ask that
   started this - **free routines declared in the unit's interface
   section**, which the native completion ignores. Skipped, by rule and by
   harness: an implemented routine (matched on chain + name + parameter
   TYPES, so overloads are told apart), an `abstract` or `external` one, an
   interface type's methods, and nested `forward`s. `class` and `static`
   come back on the header because they must (both were lost in the first
   run: `class` is not in the routine node's span, it is `Aux=1`).
   Bodies land at the end of the implementation section in declaration
   order, caret on the first empty body line. `PasTreeIdePlugin.ClassComplete`
   is the binding; `krHandled` unconditionally, so a decline can never fall
   through to the native one behind the user's back. **Switchable off** since
   2026-09-01 as **Complete Class At Cursor** in the Overrides group, which
   is the one path that answers `krUnhandled` - that is what makes "off" mean
   the IDE's own class completion, with no keymap to unbind. It gates the
   prototype sync below with it: one keystroke, one switch.
   **Property accessors - DELIVERED 2026-08-23**, the part the user called
   the one that is really missing. A `read`/`write` specifier naming
   something the type does not declare becomes a member edit into the type's
   `private` section (a new one right before its `end` when there is none),
   and the RULE for which kind is ours, stated so it is predictable from the
   name alone: **`Get`/`Set` prefix means a method, anything else means a
   field.** So `read GetFoo` declares `function GetFoo: T;` plus a body,
   `read FFoo` declares the field and nothing else. Indexed properties pass
   their index parameters into both accessors, the setter's `const Value`
   last; a `class property` gets `class` accessors; a dotted specifier
   (`read FInner.Value`) is nobody's to declare and is left alone.

   **A property with NEITHER `read` nor `write`** - `property X: Integer;`,
   the shape people type first - is completed too (asked 2026-08-23): both
   accessors are synthesized as `GetX`/`SetX`, declared, given bodies, and
   `read GetX write SetX` is written into the property line itself (after any
   `index` specifier, which the grammar keeps in front of `read`). Methods
   rather than a field, by the user's call - and the only answer an interface
   could take, so one rule covers both. A property with EITHER specifier is
   left alone: a read-only property is a design, not an omission.

   **Interface properties** take part as well, with two differences that
   follow from what an interface is: an accessor there can only be a METHOD
   (no fields exist to point at), and it gets NO body - its implementors
   write those. Members land before the interface's `end`, after its last
   member, with no `private` to write.

   One edit per PLACE, never per routine: all bodies in one insertion, each
   type's members in one more, each completed property line one more. Which is
   why the answer is a list, sorted ascending - the writer applies them in
   that order (see the client's ApplyClassComplete), and the caret's line is
   corrected for the lines the earlier edits add above it.

   **A BROKEN BUFFER GENERATES NOTHING, with one repair.** A generator that
   works from a tree the parser had to guess at writes guesses: on a buffer
   with `property XX: Integer` and no `;` yet, the unterminated property
   swallowed the rest of the class, every implementation in the unit stopped
   being one, and the answer was 1339 lines of bodies for methods that all
   had them - two of them landing inside an unrelated routine. So any parse
   diagnostic refuses the whole request and says which one it was. The single
   exception is the missing semicolon itself, because it is the commonest
   press of the key: up to three of them are WRITTEN (as `semi` edits), each
   guessed at the parser's first complaint and each validated by a reparse -
   a guess that did not work cannot produce a clean tree, which is what makes
   guessing safe. Error tolerance is right for the reading features and wrong
   for a generator; this is where that line sits.

   **What the live runs taught, in order - do not re-derive these:**
   1. A parameter's TYPE is an `nkIdent` exactly like its NAME, so a
      decl-vs-impl key must come from the parameter's TEXT (the colon
      separates names from type, `=` starts the default), never from node
      kinds. Otherwise a defaulted parameter keys differently from its own
      implementation and you get a duplicate body.
   2. A generated implementation must NOT repeat a default value (E2226).
   3. `class` is not inside the routine node's span - the parser consumes it
      before opening the node and records `Aux = 1`.
   4. A qualified name is a CHAIN of `nkIdent` segments, not one node; the
      dot between them is the only thing that distinguishes another segment
      from `function Foo: Integer`'s result type.
   5. `EditPosition.InsertText` goes through the editor, which auto-indents
      every line it is handed - generated code came out with creeping
      indentation. Use an edit writer.
   6. `CharPosToPos` answers about the buffer AS IT IS, so every edit offset
      must be resolved BEFORE the first insertion; converting inside the
      write loop pushed the bodies past the unit's own `end.`.
   7. Several edits can share ONE position (a property that is the last
      member of its section anchors all three there), and an unstable sort
      then wrote `procedure SetXX(const Value: Integer); read GetXX write
      SetXX;`. `CompareClassEdits` fixes the order: spec, semi, member, body.

   **PROTOTYPE SYNC, the second half of the key - DELIVERED AND VERIFIED
   LIVE 2026-09-01 (v0.25.0 → v0.26.2).** Ctrl+Shift+C now does two things:
   first `pastree/syncPrototypes` mirrors the signature under the caret onto
   the routine's other half, then class completion proper runs. The two are
   the same thought from either end - class completion writes the body a
   declaration is missing, this keeps an existing pair in step - and they
   never collide over one routine, because sync only touches a pair that HAS
   both halves. Sequenced, not fired together: the sync's callback starts
   the class-completion request, so the second is built from the text the
   first left (fire them together and the second's positions describe a
   buffer that has moved - lesson 6 above, again).

   The rules are in `PasLsp.SyncPrototypes`, and the ones worth naming here:
   **the side under the caret wins** (it is where the user just typed; there
   is nothing in a buffer that says which of two signatures is newer);
   mirrored are the parameter list, the result type, the routine word
   (`procedure` <-> `function`) and `class`; NOT mirrored are the name (the
   pair is found BY it - a rename has no counterpart to find, and that is
   Rename's job), the directives past the header's `;` (`virtual`,
   `overload`, a calling convention - they belong to the side that declares
   them), and a default value into an implementation (E2226, again). An
   overload set whose signatures differ is REFUSED rather than paired by
   guesswork. The answer is a REPLACEMENT - the first edit in this package
   with a real range end - applied CopyTo/DeleteTo/Insert through one
   undoable writer. `LspClientSmoke` section 5h pins all of it over
   `DemoSyncPrototypes.pas`, whose pairs deliberately disagree.

   **IT IS NOT THE IDE'S OWN "Sync Prototypes" MENU ITEM, and cannot be.**
   The user asked for that command to be fixed or replaced; three attempts,
   each verified live, each a dead end:
   1. Hide the native command and put ours beside it - it is not in
      `INTAServices.ActionList` at all (that list is what the ToolsAPI hands
      out for THIRD-PARTY items), so there was nothing to hide.
   2. Find the `TMenuItem` by walking the component tree / VCL's `PopupList`
      and hide it - worked, and took the IDE down: a heap-corrupting AV in
      `vcl370.bpl`, surfacing later in unrelated frames (`clr.dll`, and
      `TThread.CheckSynchronize` failing with "No synchronizable method
      found" in the LSP transport's reader thread).
   3. Repoint that item's `OnClick`, re-applying it from the parent
      `TPopupMenu`'s `OnPopup` so it could not be undone - same crash.

   The answer is one line in `ToolsAPI.pas`, on
   `INTAEditorLocalMenu.RegisterActionList`: **"The local menu will be
   created each time it is used"**. The editor's local menu is rebuilt from
   scratch on every open, so a `TMenuItem` found by walking components
   belongs to ONE showing of it and a pointer held across the next is a
   use-after-free. No ToolsAPI call enumerates or replaces another package's
   registered actions. So the feature lives on Ctrl+Shift+C, with no menu
   item and no switch of its own, and the IDE's own command stays broken -
   which it always was, independently of this package (the user confirmed
   "No synchronizable method found" long predates it).

   **Still open on this feature:** implementing an INTERFACE a class declares
   (`TFoo = class(TObject, IBar)` → stubs for every `IBar` method - the one
   thing the native completion does that this does not, and it needs the
   project model rather than the buffer); `class var` for a class property
   whose accessor is a field; and harness coverage for a type with no
   `private` section at all, a `record`, and `strict private`.

   The original entry, for the reasoning that has not changed: the native one
   is not gated
   by the Insight Provider selection and "works very badly" (user,
   2026-08-22) - so this is a REPLACEMENT by keyboard binding: take the
   editor command, ask the server for the missing implementation stubs /
   property accessors (a custom `pastree/classComplete` request over the
   overlay AST - decl vs impl diff is exactly what the model knows), apply
   through `CreateUndoableWriter` front-to-back, land the caret in the
   first generated body.
4. **Block completion, ours - DELIVERED AND VERIFIED LIVE 2026-08-31,
   both IDEs, after five live iterations worth remembering:** the Enter
   binding that killed the key (below), `end.` inserted mid-unit (the
   module-head-as-stack-entry model - now `end.` closes the main `begin`
   of a program/library and nothing in a unit, regression pinned in
   `LspClientSmoke` 5h), a bare `try` completing to just `end;` (now the
   full `finally`/`end;` skeleton), the caret (now: the plan's second
   edit re-indents the caret line to body depth; VS Code's cursor
   anchoring proved untrustable in three different ways, so the
   extension places it explicitly - a middleware over
   `provideOnTypeFormattingEdits` that waits for the edits to actually
   land via a one-shot `onDidChangeTextDocument`; a plain setTimeout(0)
   fired too early and the edits carried the premature selection past
   the closer), and VS Code sending nothing at all until
   `editor.formatOnType` is on (the extension now defaults it on for
   `[objectpascal]` via `configurationDefaults`). A bare `while`/`for`
   header is NOT this feature's gesture - that is a template; VS Code
   snippets for the statement skeletons shipped in the extension
   (0.15.7) and further template work is DEFERRED by the user's call
   (2026-08-31). Same verdict on the native one. Standard LSP, per the
   standing rule (protocol first, the IDE stretched onto it):
   `textDocument/onTypeFormatting` with `\n` as the only trigger, declared
   at initialize, decided lexically in `PasLsp.BlockClose` (a token-stack
   balance over PasTree's lexer; the cascade reasoning and the context
   rules for `class`/`interface`/variant-`case` are in its header) - so VS
   Code gets it free. The plugin (`PasTreeIdePlugin.BlockClose`): an
   `INTACodeEditorEvents.EditorKeyUp` OBSERVER (`TNTACodeEditorNotifier`,
   like ErrorPaint) - NOT a keyboard binding: the first build bound plain
   Enter with `krUnhandled` and the first live run had Enter dead in the
   whole editor, because a binding CLAIMS its keys and `krUnhandled` only
   offers them to other bindings, never back to the editor's default
   processing. The observer cannot swallow anything; at key-up the buffer
   already holds the line break, so it asks right there and applies the
   answer through `CreateUndoableWriter`, dropping it if the caret left
   the row. Fourth
   switch in Settings (`EnableBlockCompletion`), checked at keystroke time.
   `LspClientSmoke` section 5h pins both the insertion (opener's
   indentation, caret line untouched) and the balanced-file `null`.
5. **Rename refactoring, ours - DELIVERED 2026-08-30, VERIFIED LIVE
   2026-08-31** (a constant renamed across a 3759-unit project: 9 sites,
   6 files, 5 of them rewritten on disk - the tab said so). The dialog
   goes through `INTAIDEUIServices.InputQuery` since 0.21.10 (the VCL
   one came up light inside the dark theme), and both this and Find
   References run under the IDE wait dialog since 0.21.11
   (`PasTreeIdePlugin.WaitDialog` over `IOTAIDEWaitDialogServices`;
   texts kept short - the dialog does not grow for them; every terminal
   path closes it FIRST because it disables input, and a message box
   over disabled input is a stuck IDE. Synchronous-with-hourglass was
   rejected: the answer arrives via TThread.Queue on the main thread,
   so blocking it is a deadlock).
   The built-in one existed and Embarcadero DISABLED it for being
   buggy (user, 2026-08-22) - the demand was proven and the field was empty.
   PasTree 0.12.0 landed `PlanRename`/`IsValidRenameName`, which is what made
   this a client-side job at all.

   Server: `textDocument/rename` + `prepareRename` (a WorkspaceEdit over the
   references machinery - already correct cross-unit) and, for us,
   `pastree/renamePlan`, which keeps the two things a WorkspaceEdit throws
   away: each site's `oldText`, and the line as it READS after the rename.
   See the server `SPEC.md`.

   Plugin (`PasTreeIdePlugin.Rename`): the editor's local menu plus
   Ctrl+Shift+E - not Ctrl+E, which is incremental search - a dialog
   prefilled with the identifier, then **two passes over the whole plan**:
   open every touched file and check each site still reads the old name, and
   only then write. A single mismatch aborts everything with the file and
   line named, because a half-applied rename across five files is far worse
   than one that did not happen. Within a file the edits go through ONE
   `CreateUndoableWriter` in ASCENDING order - a writer cannot move backward
   (see the Editing table), and its offsets all address the original text, so
   ascending needs no shifting arithmetic; offsets are resolved before the
   first write, for `ApplyClassComplete`'s hard-won reason.

   **And then it shows what it did**, in a "PasTree Rename" Messages tab
   shaped exactly like Find References - grouped by file, one navigable line
   per site, the declaration labelled - where each line is the source AS IT
   NOW READS. That is the demo's shape (`PasTreeDemo.Main.ShowRenameTab`) and
   it is the half that makes the feature trustworthy: a rename that silently
   touched fourteen places is indistinguishable from one that touched the
   wrong fourteen.

   **Two validators, deliberately.** The keyword verdict is the analysis's
   (`IsValidRenameName`, in PasTree - which this Win32 package must never
   link), so every real refusal comes from the server and is shown verbatim.
   The plugin only rejects obvious non-identifiers, to save a round trip on a
   typo. A copy of the keyword list here would be a second answer able to
   disagree with the first.

   **Switchable off** in Tools > PasTree > Settings, third switch in the
   Overrides group. Off hides the menu item (hidden, not greyed - a disabled
   item reads as "not right now", and this one would not come back on its
   own) and answers `krUnhandled` for Ctrl+Shift+E, which hands the key back
   to the IDE. A feature that EDITS the user's code is the one that most
   needs a way to be refused outright.

   **The UNIT half was built and then WITHDRAWN from the plugin (2026-08-31),
   and the reason is worth keeping.** The server side is done and stays: it
   plans the header, every `uses` item, the `in '...'` path and the file name
   the unit then requires, and a plain LSP client applies all of it as one
   workspace edit (see the server SPEC).

   Inside the IDE it does not work, and not because of a missing API. The IDE
   performs a rename of its OWN the moment a unit whose `unit` clause changed
   is saved or closed - through the project manager and SaveAs paths - and it
   cannot be asked to hold still while ours runs. Four live runs on a
   3759-unit project each ended in a different collision between the two:
   the file already moved under us (so `TFile.Move` reported "file not
   found"), the project entry already rewritten (so `AddFile` reported "the
   project already contains a module named X"), and finally the IDE's own
   "Unable to rename A to B" over a rename that had already happened.
   `IOTAProject100.Rename` returned False throughout while doing part of the
   work anyway.

   The lesson for whoever picks this up: the IDE is not a passive file store
   here, and the sequence has to be ITS sequence, not ours with reconciliation
   bolted on. A plausible next attempt is to let the IDE do the whole thing -
   rename through the Project Manager first and let its own save path rewrite
   the unit clause - and to contribute only the OTHER units' `uses` edits.
   The withdrawn implementation, its trace and its four failure modes are on
   the `feature/unit-rename` branch.

   Still queued: `IOTASyncEditPoints` as the cheap same-file variant.
6. **Find References results upgrade - DELIVERED AND VERIFIED LIVE
   2026-08-31, settled over six styling iterations with the user; the
   "PasTree Rename" tab runs on the same rows since 0.21.8.** The final
   look: blue bold title line with the count in orange (a custom row -
   `AddTitleMessage` is IDE-drawn and uncolorable), blue bold header
   `<full path> [N]` with the N orange, hit rows
   `Name.pas (line):` in blue/orange accents, the snippet
   syntax-colored with indentation preserved, the match bold+underline
   in clMaroon (theme-aware red on a dark panel). Header and title rows
   REFUSE navigation (`CanGotoSource` false with default handling
   suppressed), so double-click expands/collapses - the panel's own
   behavior - instead of jumping to line 1, and F8 walks hits only.
   Owner-drawn rows (`PasTreeIdePlugin.ResultRows`:
   `IOTACustomMessage100` + `INTACustomDrawMessage`, inserted via
   `AddCustomMessagePtr`/`AddCustomMessage(Parent)`): every snippet is
   painted in the user's LIVE editor syntax colors -
   `INTACodeEditorServices.Options.FontColor/BackgroundColor/FontStyles`
   per `TOTASyntaxCode`, read at draw time so a Tools > Options color or
   theme change shows on the next repaint. The layout is a HYBRID settled
   with the user over three live runs: the skeleton replicates the native
   Find in Files rows - full path bold + blue `[N]` on headers,
   `Name.pas (line):` prefix in the `ThemeAwareColors` blue/orange accents,
   snippets with indentation preserved, the match bold + underlined - while
   the snippet keeps the editor's syntax colors (the match marker stays in
   the run's own syntax color; two background variants lost first: the
   `SearchMatch` element is white-on-black by default - a black box punched
   into every row - and any filled rectangle repeated down a list reads as
   noise), and file header rows
   (bold name + count) that finally navigate on double-click, which
   `AddToolMessage` headers never could. The line is classified by a
   display-only tokenizer in that unit (best effort, one detached line;
   reserved words only, no context directives - its header says why), the
   real tokenizer being Win64-only in PasTree. A match is highlighted only
   if the text at the mapped column still reads as the identifier -
   anything stale degrades to an unhighlighted snippet, never to a
   highlight on the wrong characters. The **custom colored hint window**
   is carried over from the old order, still queued.
   **Idle-debounced `didChange` DELIVERED 2026-08-22**
   (`PasTreeIdePlugin.IdleSync`: `EditorViewModified` + 600 ms timer →
   `LspIdleSync`, a no-op without a running server) - first live run
   found squiggles updating only on save, because the doc sync ran only in
   front of requests. `IOTAEditLineTracker` stays queued: between an edit
   and the next publishDiagnostics the painted ranges are stale by
   whatever lines were inserted above them; the tracker is what would
   shift them live.
7. **Toggle decl/impl on a cursor that was never on a routine - DELIVERED
   2026-08-29, silent now.** Ctrl+Shift+Up/Down on a constant, a type, a
   comment, blank space - anywhere except a routine with a separate
   declaration and body - used to write `[pastree] Toggle decl/impl: no
   routine with a separate declaration and body at cursor.` to the Build tab.
   That is the ordinary outcome of a key that does not apply, not a failure.

   No server or PasTree change was needed: the protocol already tells the two
   cases apart, and the plugin simply was not using the distinction. The
   server answers this case as **success with `null`** (`HandleToggle`, after
   both directions are tried), while a REAL refusal - no server, cancelled
   request, dead connection - arrives as `ASuccess=False` with a reason and
   still logs. So only the empty-answer branch went silent.

   The reason a diagnosis would want is not lost, it just moved out of the
   user's face: the server logs `nothing to toggle to at that position` into
   `pastree-lsp.log` for exactly this answer.
8. **The Build tab is for what the user must ACT on - DELIVERED 2026-09-01,
   and it is item 7's rule applied to the rest.** Class completion wrote
   `nothing to implement` on most presses of Ctrl+Shift+C and prototype sync
   wrote a line on every one; both are ordinary outcomes of a key pressed
   constantly, and a panel read for compiler errors is the wrong place for
   them (user). They now go to `pastree-lsp.log` through `LspLogToServer`
   (a `LogTrace` beside each unit's `LogDiagnostic`, so the split is visible
   at every call site). What still reaches the Build tab: a request that
   FAILED, an answer dropped because the buffer moved under it, and an
   overload set too ambiguous to mirror - each of which means the keystroke
   did not do what it looked like it did.
9. **Logging, and the settings that gate it - DELIVERED 2026-09-01
   (v0.24.0).** Two switches in a new Logging group of the dialog.
   **Enable logging** (default on) decides whether `pastree-lsp.log` exists
   at all: off sends the server no `logFile`, which is how it already
   understands "no log" - nothing is written rather than written and
   discarded. The IDE-side crash record is deliberately NOT gated by it: a
   fault nobody recorded is worse than a log nobody reads.
   **Advanced logging** (default OFF, the one switch here that is) maps to a
   new `logDetail` initialization option and controls the configuration
   inventory - every search path, define, namespace and alias. The one-line
   `configured: platform=... paths=N defines=N` summary is logged either way,
   deliberately: turning the detail off must cost the list, never the counts
   that say the list is worth asking for. Both are part of the server's
   configuration for restart purposes (like platform and build config), so
   changing either takes effect on the next gesture rather than at the next
   IDE start. `pastree.logDetail` is the VS Code equivalent.
10. **The analysis starts when the project opens - DELIVERED 2026-09-01
   (v0.24.1).** It used to start on whichever came first: a `didOpen` or a
   request reaching `WaitAnalyzed`. Both are the wrong moment for a client
   that opens a PROJECT rather than a folder - RAD Studio hands over the
   `.dproj` at project-open time and may send no `didOpen` until the user
   activates a tab, so the whole closure was parsed on the first Ctrl+Click,
   the one gesture that is then slow for a reason the user cannot see. The
   server now schedules the first analysis on the `initialized` notification
   when a project was configured (scheduled, not started, so the didOpen
   burst that follows folds into the same build). `LspProjectSmoke` pins it:
   after the handshake, with no request sent and no document open, the log
   must show `analysis done`.
11. **`didOpen` says whether the IDE is SHOWING the document - DELIVERED
   2026-09-01 (v0.24.2).** Opening one form in RAD Studio pulls in its
   visual-inheritance ancestors and every datamodule its `.dfm` references,
   and each arrives as a `didOpen` the user did not ask for - so the log read
   as though five files had been opened when one was. The plugin now asks the
   module for `EditViewCount` and sends `pastreeShown` on the
   `TextDocumentItem` (a non-standard member on a standard object; the spec
   says unknown members are ignored, so it costs other clients nothing), and
   the server writes `(background)` for a document that is loaded but not on
   screen. Absent means "a client that does not report this", which is not
   the same as "not shown", so VS Code says nothing either way.

## Non-goals

- **A formatter.** Needs a printer; PasTree parses and analyzes but does not
  emit source. Same verdict, same reason, as the server spec's.
- **Becoming the Pascal Insight Provider before completion works.** See the
  fork above: it is a replacement, not an addition, and every gap becomes a
  regression the day a user switches.
- **Anything design-time.** Component and property editors, the Object
  Inspector (`PropInspAPI.pas`), the palette, the form designer: their currency
  is instantiated objects on a designer, ours is declarations in text. Checked;
  there is no path between them.
- **The AI plugin registry** (`ToolsAPI.AI.pas`). Checked: unstructured string
  in, string out, correlated by GUID, with no notion of a file, position, range
  or edit anywhere in the unit. Registering the server as a chat backend would
  mean serialising structured results into prose and losing the ranges that make
  them useful.
- **A VCS provider.** `FileHistoryAPI.pas` has the tantalising
  `IOTAAnnotationLineProvider` (`113`) - arbitrary per-line gutter text and a
  per-line tooltip, which is shaped exactly like code lens - but reaching it
  requires registering as a file-history provider and it only fires when the
  user turns on annotate for a revision. `RequestGutterColumn` reaches the same
  pixels without the pretence.