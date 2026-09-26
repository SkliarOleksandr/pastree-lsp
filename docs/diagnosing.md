# Diagnosing

Procedures for symptoms that have already cost a round of investigation. Read
the one that matches; `CLAUDE.md` links here by symptom.

Everything starts from **`<project-name>-pastree-lsp.log`, in the same folder
as the `.dproj` being analyzed** - the server's stderr is appended into that
same file, not a sibling.

One log per project, because a project group runs one server per project, all
at once (`clients/rad-studio/SPEC.md`, "Project groups"): with a fixed name the
projects of a group - normally one directory - would interleave two servers'
lines into one file, which is worst exactly when the question is why one of
them behaves differently. A log written by a version before 0.31.0, or by the
VS Code client, is still the bare `pastree-lsp.log`.

## "Ctrl+Click did nothing"

The editor tells you nothing useful: a click that resolves nothing simply does
nothing. The log carries the search paths, every diagnostic with the unit it
belongs to, and both ends of every navigation. Read it before suspecting the
resolver - the last two failures of this kind were a search-path problem and a
stale binary, neither visible from the editor.

For a search-path problem specifically, turn the unit inventory on: `logUnits`
in the initializationOptions (`pastree.logUnits` in VS Code) or
`PASTREE_LSP_LOG_UNITS=1`. It logs one `unit x <- path` line per unit, the only
thing that answers "which of several copies on the search path won?". Off by
default because it is hundreds of lines per rebuild.

## Colours on the wrong spans, or "nothing to toggle" while typing

Half a type name coloured, a method name painted as a type, Ctrl+Shift+Up/Down
answering `nothing to toggle to at that position` on a name plainly on screen -
and all of it gone after a save. The server is analyzing a text the editor
does not hold. Grep the log for `textDocument/didChange <that file>` and read
the character counts: a sequence that keeps coming back to ONE number between
the typed sizes (1085, 989, 1100, 989, 1096, 989) is the file's text on disk
being sent in place of the buffer. That was 0.52.6-0.54.2: the reload detector
took every move of `IOTAEditBuffer.CurrentDate` for a reload, and CurrentDate
is the buffer's AGE - it moves on edits too (2026-09-25). The header of
`PasTreeIdePlugin.IdleSync` has the whole account; with Advanced Logging on,
each `buffer dates moved:` line says whether the buffer was modified and what
was decided.

`file not in the analyzed closure` for a unit that IS in the project is the
same question about the program file: its uses clause on the server does not
list the unit. A unit created in the IDE, or saved under a new name, rewrites
the `.dpr` in a buffer with no view, which raises no editor event - look for a
`didChange` of the `.dpr` after the unit's `didOpen`. None means the program's
edit never left the IDE (the buffer age in `TLspDocumentSync` is what sends it
since 0.54.3). A unit never saved at all also needs PasTree 0.52.2, which
resolves an `in 'path'` to an editor buffer.

## "Back does nothing after Ctrl+Click" - but only sometimes

The IDE's Backward/Forward stack (`IOTAHistoryServices`) is opaque from the
editor, so first make it visible: temporarily log `GetBackwardCount`,
`GetForwardCount` and every `GetBackwardItem`/`GetForwardItem` caption before
and after `AddHistoryItem` and after the navigation, in
`PushHistoryAndNavigate`. The dump answers the two questions that matter:
where the stack pointer is (the current item appears in neither list) and
whether the IDE's own `[ide]` entries are interleaved with ours.

The 2026-09-03 case: Back failed exactly when the jump target had already
been visited in the session. `IOTAHistoryServices.Execute(AItem)` finds
"this position" by an `IsEqual` scan from the bottom of the stack and takes
the first match, and our `IsEqual` compares positions - so the pointer landed
on the old entry, everything newer turned into forward history, and Back was
disabled. `AddHistoryItem` already positions the pointer on `NewItem`; the
fix was to run `NewItem.Execute` ourselves instead of asking the service to.

## "The analysis got slow"

**If it got slow WHILE TYPING, the question is not how fast a rebuild is - it
is why there was a rebuild at all.** Since 0.17.0 an ordinary edit re-analyzes
one module (tens of ms to ~1.5 s); a closure rebuild per keystroke is the fast
path not firing, and it is silent - every answer stays correct. Grep the log
for `analysis started:`:

- `incremental, one module (...)` - fired. If followed by `incremental refused
  ... (module=refused:<reason>)`, PasTree declined and the reason names itself.
  `too-many-consumers(N>L)` is tunable with the `moduleRedoLimit`
  initializationOption; the rest are library decisions.
- `full rebuild` on a single-file edit - the server never offered the fast
  path. That decision is `SingleChangedDoc`, and the cause is always the same
  shape: something made the inputs look like more than one changed document.

The rest of this section is about a slow REBUILD, a different question.

**First suspect: `System.NeverSleepOnMMThreadContention := True` is missing.**
It is the first statement in `pastree-server.dpr` and must stay there - PasTree
parses across cores, and without it Delphi's memory manager sleeps on
allocation contention, so the workers wait instead of working. Dropping it cost
4.5x on a 3757-unit project (70 s vs 15 s). Its fingerprint:

- **CPU time goes DOWN while wall time goes up** - threads waiting, not
  computing. `Get-Process pastree-server` (`TotalProcessorTime` vs elapsed);
  one running thread among thirty asleep is the tell.
- **`intf` and `full` inflate, `cross` does not** - the `stages` field of the
  `analysis done` line. The damage lands on the allocation-heavy stages.

To compare against the library directly, run the same closure in-process:

```
tools\out64\PasTreeSemaProject.exe <project>.dproj -dproj -p:<platform> -studio:<bds>
```

plus one `-L<path>` per search path from the log's own `path` lines. Matching
stage numbers mean the server is fine and the analysis is simply that
expensive; a server 3x worse than in-process means the host, not PasTree. The
reasoning is in `SPEC.md`; do not re-derive it.

Ruled out by measurement, so do not start there: out-of-process overhead (nil -
in-process is the same 15 s) and Debug-vs-Release (~2%, inside noise).

## Go To (Ctrl+G) is slow on a big project

Before 0.46.0 this was NOT the analysis - the project list comes off the
retained symbol tables (`TPasNavigator.ProjectOutline`) and cost ~70 ms even
on AVImark (1553 units, 113,613 rows). The delay was the ANSWER's SIZE: one
JSON object per row was 33 MB on the wire, and the client spent 1.5 s in
`TJSONObject.ParseJSONValue` plus per-field `GetValue<T>` on the main thread,
then another ~900 ms in `MeasureHeadColumn` doing one GDI `TextWidth` PER
ROW - all before the picker showed anything. Measured end to end: 2.2 s warm,
worse on a first (cold) request or a slower machine.

0.46.0 answers `pastree/outline` as a TABLE (`kinds`/`heads`/`sections`/
`owners`/`files` interned once, rows as positional index arrays - see
`SPEC.md`'s entry for `pastree/outline` and the header of
`PasTreeIdePlugin.OutlineRows.pas`), read by the client in one pass with no
DOM (`TLspClient.RequestRaw`), and cached on the server until the next
analysis replaces the project. Same project: 205 ms first request, 65 ms on a
repeat. If it is slow again on 0.46.0+:

- Check the server log for `pastree/outline ... -> N rows: list X ms, json Y
  ms` - `list` growing means the symbol tables are unusually large; `json`
  growing
  past a few tens of ms for a project this size means something changed in
  `TJsonBuf` or the row shape.
- `pastree/outline project -> cached` means the server-side cache answered -
  if it is STILL slow, the cost moved to the client or the wire, not PasTree.
- A stale server (built before 0.46.0) still answers the old per-row shape;
  `PasTreeIdePlugin.OutlineRows`'s reader expects the table and will report a
  parse error naming an offset rather than silently misreading it - that
  error means a version mismatch, not a data problem.
- The reproduction bench is `local/bench/OutlineBench.dpr` (untracked,
  `local/` - see `CLAUDE.md`): it drives the real `TLspClient` against a real
  `.dproj` and prints the same breakdown warm/cold, DOM path vs raw path.

Not yet done, noted for when it is needed: a library-wide scope (RTL/VCL/
third-party, 400k+ rows in a project like AVImark) was judged too big to ship
as a full list even in the table format: `pastree/outline` would need
`filter`/`limit` parameters and server-side filtering per keystroke instead.

## The Go To list flickers, or its scrollbar thumb jumps

Three different things, fixed across 0.47.2..0.47.5; the notes are here
because all of them will look like "the list is slow" in the next report.

**Flicker on a tab switch or while scrolling.** The rows are owner-drawn
(`lbItemsDrawItem`), so every repaint is a `FillRect` and a dozen `TextOut`s
per row, and a list box erases its whole client area before the first of
them - on a slow machine that white frame is what is seen. Three things
address it and all three must stay:

- `lbItems.DoubleBuffered := True` (the constructor) - the erase and the
  rows happen in memory, the screen changes once.
- `BeginListUpdate`/`EndListUpdate` (a `WM_SETREDRAW` pair, nested and
  counted) around a tab switch and around `Refilter` - clearing the list,
  setting the count, the selection and the top row are four repaints
  otherwise, with an empty list visible between them.
- Nothing per row that talks to a window or to the IDE. `Scope` used to
  read `tcScope.TabIndex`, a `SendMessage` at 47 us, twice per row; it now
  answers from `FScope`, refreshed by `SyncScope` on every tab change and
  every landed list. `PutColumn`'s cap comes from `FColumnCap` rather than
  `ClientWidth`. And the editor palette is held for the life of the dialog
  (`BeginEditorPalette`/`EndEditorPalette` in
  `PasTreeIdePlugin.ResultRows`), because each colour and style lookup was
  a `Supports(BorlandIDEServices, ...)` and a row asks for six of them.

If it flickers again, look for a new per-row call into the VCL or ToolsAPI
before looking anywhere else - the same mistake cost 5.7 s on AVImark on
2026-09-19 and is recorded in `MeasureHeadColumn`'s header.

**A tab switch flickers on a big list.** Get the `goto tab` timing line
first (Advanced Logging; it says how long the switch held the list).

*The tab control erases the rows' rectangle while OnChange is busy* (fixed
0.47.5). A tab control repaints its whole client area when the selected tab
changes, and it does so BEFORE `OnChange` runs, so for however long the
handler takes to build the new list that rectangle shows the tab control's
background instead of rows. Two changes: `WS_CLIPCHILDREN` on `tcScope`
(set in `FormShow`, since the VCL does not set it) excludes the list box's
rectangle from the parent's painting, and `tcScopeChange` no longer empties
the list before building the new one - the old rows stay up until the new
ones replace them. The switch also does far less work now: both the column
widths (`FWidths`) and the filter result (`FFiltered` / `FilterKey`) are
kept per tab, so a switch back with the filter box untouched rebuilds
nothing.

A third, group-wide tab was withdrawn in 0.47.23 after testing (Alex,
2026-09-22). It answered once per project of the group and had staging of
its own (`FStaged` / `AdoptStaged`, `cGrowthRedrawMs`) to keep a group of
six from re-measuring and repainting the list six times in a second; all of
that went with it, and `git log` has it if the scope is ever wanted back.

**A wait dialog flashes as the picker opens.** Fixed in 0.47.3: the dialog
is ARMED for 250 ms rather than shown (`ShowWaitDialogAfter` in
`PasTreeIdePlugin.WaitDialog`), so a warm project - which answers off the
server's outline cache in tens of milliseconds - never sees it, and a cold
one, which takes seconds, still does. If it flashes again, the outline is
taking longer than 250 ms and the entry above is the one to read. Note that
the dialog no longer disables input for those first milliseconds, so
`GBusy` in `PasTreeIdePlugin.GoToPicker` is what keeps a second Ctrl+G from
starting a second picker; a Ctrl+G that does nothing at all means that flag
is stuck, which means an outline callback never fired.

**The thumb jumps back while dragging it.** This was real dynamic loading:
the group tab refilters on every project that answers, and `Refilter` sets
`lbItems.ItemIndex`, which is `LB_SETCURSEL`, which SCROLLS the selected row
into view. A drag of the scrollbar runs a modal loop that still dispatches
messages, so an answer landing mid-drag yanked the view back to the
selection a few times a second. `Refilter` now puts the top row back when
the selected row did not move; when the selection really changed (typing, a
tab switch, the caret row on first show) the scroll into view is the point
and stands.

## An access violation with only an address

`EAccessViolation ... in module 'pastree-server.exe' (offset NNNNNN)` and
nothing else. Resolve it through the map `build.bat` writes next to the exe:

1. RVA is the reported offset; subtract the `.text` RVA (`0x1000`) to get the
   map offset.
2. Find the nearest preceding entry in `out\pastree-server.map` - the `Publics
   by Value` block names the routine, the `Line numbers for` blocks the line.

**The map must come from the same build as the exe.** A server built from the
IDE has a different layout, and the same offset resolves to a routine that
never ran - which is exactly how the 2026-09-02 report misled for a round.
Check the build stamp on the log's first line against the exe you have.

Two masks to know about, both fixed but both instructive:

- A destructor faulting on a HALF-BUILT object replaces the constructor's
  exception with its own. If an AV appears where an object is being torn down,
  suspect the constructor that raised first.
- The server's own exception lines now carry `[session=... project=...]`, and
  a permanent fault repeats per idle tick. One line plus a repeat count means
  a fault that never cleared; look at what the state says was in flight.

## `LspClientSmoke` fails two checks about a Cyrillic literal

Those two checks were EXPECTED to fail until 2026-08-20 - the ANSI-vs-UTF-8
decode split. It is fixed at the root in PasTree: a preamble-less source whose
bytes are valid UTF-8 now decodes as UTF-8, so the analysis and the editor read
the same text.

If they come back, the first thing to check is **which PasTree the server was
built against**, not the resolver. `cMinPasTreeVersion` is pinned at or past
the version where the fix landed, so an older sibling should fail loudly rather
than quietly shift columns - a failure here means something got past that gate.

## The server works from `build.bat` but not from the IDE

The IDE's stock Debug configuration sets `DCC_IntegerOverflowCheck` and
`DCC_RangeChecking`; `build.bat` uses the compiler's defaults, which have both
off. Anything relying on deliberate wraparound behaves differently between the
two. PasTree's suites are built with `-$Q+ -$R+` since 0.15.2 for this reason,
and `cMinPasTreeVersion` refuses a sibling older than the fix.

Bisect a suspected switch by rebuilding with it turned off:

```
msbuild pastree-server.dproj /t:Build /p:Config=Debug /p:Platform=Win64 /p:DCC_IntegerOverflowCheck=false
```
