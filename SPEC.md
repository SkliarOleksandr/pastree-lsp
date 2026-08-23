# PasTree LSP Server — specification

Status: 2026-08-19. Phases 1-2 are implemented and exercised live against
VS Code; see "Protocol coverage" below for what the standard still holds and
the repo README for what the server does today.

## Goal

One out-of-process analysis server, `pastree-server.exe` (Win64), that speaks
the Language Server Protocol (JSON-RPC 2.0). It serves two kinds of clients
with the SAME protocol:

1. the RAD Studio IDE package (`clients/rad-studio/`, merged into this
   repository on 2026-08-20 — see the README for why), reduced to a
   thin LSP client over ToolsAPI;
2. standard editors — VS Code, Neovim, anything with an LSP client.

We deliberately do NOT build a private RPC for the plugin first and LSP later:
that is the same protocol written twice. LSP is the native protocol from day
one; the plugin is just its first client.

## Versioning

**One version for the whole product** — this server and every client in
`clients/` — as `PasTreeLspVersion` in `source/PasLsp.ProductVersion.pas`. Two
rules; PasTree counts its own commits under the same two:

- **Every commit bumps the PATCH.** `0.5.0` → `0.5.1` → `0.5.2`, mechanically,
  no judgement call about whether a change "deserves" it.
- **A substantial change bumps the MINOR** and resets the patch: a newly
  supported request, a new initializationOption, a reworked subsystem — anything
  a consumer might reasonably need to *require*.

The per-commit patch bump exists so that a version identifies a **build**. The
server is deployed alongside a RAD Studio package that runs whatever exe is on
disk, so "which build is running" is a question that comes up constantly, and a
number that only moved on release could not answer it.

**Why one number rather than one per component.** The server and the RAD Studio
package are one deliverable built from one commit by one script, so "which
version is the package" and "which version is the server" were never two
questions — giving them two numbers only created a way for the answers to
disagree. They did, on 2026-08-20: a freshly built package ran against the
previous day's exe, the old `cMinServerVersion` gate was satisfied by the stale
server, and nothing was reported. The mismatch was caught by a human reading a
version string. With one number the client checks **equality** and says so,
which is the difference between a guess about compatibility and a fact about
deployment. `clients/vscode` shares the number too, at the mild cost that a
package-only fix moves a version VS Code users see — acceptable, since the
number identifies a build rather than a feature set.

The minor component keeps its ordinary semver meaning, which is what makes the
one remaining compatibility constant readable:

- **`cMinPasTreeVersion`** (`source/PasLsp.Version.pas`) moves only when this
  server's code starts depending on something a PasTree did not previously
  provide. Ordinary commits do not touch it. It can legitimately name a *patch*
  version: a resolver fix is a patch in PasTree's own terms and can still be a
  hard requirement here. Checked at startup, because PasTree is linked into this
  exe.
- **`serverInfo` reports both numbers**, the product's and the PasTree it was
  built against, because a client's real question is almost always about the
  latter.
- **There is no `cMinServerVersion` any more.** It was the client's guess at
  what it needed from a separately versioned server; with one repository and one
  number, equality replaces it.

## Why out-of-process at all

- **Address space.** The large client project needs ~3.5 GB and analyzes clean
  only on Win64; a 32-bit IDE cannot host that in-process. (PasTree memory:
  `win32-oom-is-address-space`.)
- **Isolation.** An analyzer crash or the suspected `TPasSourceManager`
  Prefetch race must not take the IDE down.
- **Reuse.** The same exe is the future editor-agnostic LSP server for free.

## Architecture

```
┌──────────────────────┐         ┌───────────────────────────────┐
│ RAD Studio           │  stdio/ │ pastree-server.exe (Win64)    │
│  IDE plugin (BPL)    │◄───────►│  LSP over JSON-RPC 2.0        │
│  thin LSP client     │  pipe   │  PasTree: SourceManager,      │
└──────────────────────┘         │  Sema, Navigator, caches      │
        VS Code / Neovim ───────►│                               │
                                 └───────────────────────────────┘
```

Three layers, strict dependency direction:

1. **PasTree core** (existing repo) — no knowledge of transport. Exposes a
   facade API over (project, file, position) plus:
   - **overlay buffers**: in-memory file contents supplied by the host,
     consulted before disk everywhere, including Prefetch; versioned;
   - **cancellation**: long analysis takes a token and polls it.
   These two items live in the PasTree repo's To do and are prerequisites.
2. **pastree-server.exe** (this repo) — owns the JSON-RPC loop, LSP lifecycle,
   project state, and all caches (the plugin's BuildNavigator cache moves
   here). Win64 only, like every PasTree tool.
3. **Clients** — the IDE plugin translates ToolsAPI events to LSP and LSP
   results back to IDE actions; IDE-specific features (IOTAHistoryServices
   Backward/Forward) stay in the plugin, layered over LSP results.

### Hosting PasTree: `NeverSleepOnMMThreadContention`

```pascal
System.NeverSleepOnMMThreadContention := True;
```

**The first statement in `pastree-server.dpr`, and it must stay there.** PasTree
fans parse and resolve out across cores, and with this global left at its default
(`False`) Delphi's memory manager *sleeps* when it cannot take its lock. Every
one of those passes allocates heavily — a token stream, a tree and a model per
unit — so the workers sit in `Sleep` instead of allocating. The library cannot
set it: it is a process-wide mode the application owns.

Missed here until 2026-08-20, at a cost of **4.5x**. Measured on a 3757-unit
project, identical closure and inputs:

| | wall | CPU | `intf` | `full` | `cross` |
|---|---|---|---|---|---|
| with the flag | **15.4 s** | 135 s | 2 928 | 4 825 | 7 598 |
| without it | **70.3 s** | 50 s | 18 586 | 29 836 | 21 847 |

Two things in that table are worth memorising, because they are how this gets
recognised next time rather than re-investigated for an afternoon:

- **CPU went DOWN while wall time went up.** Threads waiting, not working —
  sampling showed one thread running and thirty-odd asleep. A slowdown that
  burns *less* CPU is never a "we compute too much" problem.
- **`cross` was unaffected; `intf` and `full` were 3x worse than a deliberately
  single-threaded run** (44.7 s total). The damage lands exactly on the
  allocation-heavy stages, which is the fingerprint of this flag and of nothing
  else.

What it was NOT, both checked by measurement rather than argument: the cost of
running out of process (the same analysis in-process takes the same 15 s), and
a Debug-versus-Release build — rebuilding the server with full release flags
(`-$O+ -$C- -$D- -$R- -$Q-`) was worth about 2%, inside the noise. The server
and the demo are built by identical `dcc64` invocations and neither carries
debug-only directives, so there is no Release build to switch to.

The PasTree side of this is in that repo's README (`## Multithreading` → "The
one line every host must set"); it is a requirement of hosting the library, and
this server is the host that proved a host can forget.

## Protocol coverage

Phases 1-2 (the plugin-parity set) and part of phase 3 are implemented. What
follows walks the whole LSP 3.17 inventory, so this list is CLOSED — every
request in the standard is either implemented, in a tier below, or explicitly
out of scope with a reason. Tiers are by value-per-effort for OUR clients (the
IDE plugin first, VS Code second), not by protocol order.

### Implemented

| | |
|---|---|
| `initialize`, `initialized`, `shutdown`, `exit` | project config via `initializationOptions` |
| `textDocument/didOpen`, `didChange`, `didClose` | incremental sync, versioned overlays |
| `textDocument/definition` | |
| `textDocument/declaration`, `textDocument/implementation` | the decl-impl toggle |
| `textDocument/references` | symbol / unit / builtin identities |
| `textDocument/documentSymbol` | outline, types with members |
| `textDocument/hover` | declaration card, plus the XMLDoc block (PasLsp.XmlDoc) |
| `textDocument/publishDiagnostics` | push, open documents |
| `workspace/didChangeWatchedFiles` | client watches, server decides |
| `$/cancelRequest` | |
| `$/progress` + `window/workDoneProgress/create` | server-initiated, message-only (see below) |
| `window/logMessage`, `window/showMessage` | user-actionable trouble, not just the log |
| `textDocument/typeDefinition` | via the declared type expression, so it crosses units |
| `textDocument/documentHighlight` | occurrences in the current file |
| `textDocument/completion` | PasTree's engine through the seam; `documentation` per item; [COMPLETION.md](COMPLETION.md) owns the story |
| `textDocument/signatureHelp` | the engine's `CallAt`; call anchor rides as `pastreeCall` |
| `workspace/symbol` | project-wide substring query over the prefetched index |

`textDocument/didSave` is accepted and ignored (we advertise no save interest).

**Encoding disagreement — fixed 2026-08-20, in PasTree, and the diagnosis is
worth keeping because the obvious explanation was wrong.** PasTree used to
decode a source with no BOM as ANSI (dcc's own rule, and the point of its
tolerant loader) while an editor decodes it as UTF-8. Three consequences, in the
order they were understood:

- *the visible cost:* every PasTree source with an em-dash in a comment looked
  "modified" to the rebuild gate, so peeking a declaration — VS Code opens the
  target file and closes it milliseconds later — cost two full closure rebuilds,
  about 14 seconds of the editor apparently reparsing a file nobody touched. The
  gate now also accepts "re-encoding the editor's text as UTF-8 reproduces the
  file's bytes", because a decode disagreement is not an edit (`FileMatches`,
  now `FileHoldsText` in `PasLsp.SourceText`).
- *what this document used to claim, and it was wrong:* that the remaining skew
  only affected files the editor does NOT have open. It affected open ones too,
  and by way of the fix above. The gate correctly concludes "no edit, so no
  rebuild" — but the analysis then keeps its own ANSI reading of a file the
  editor has open, and no rebuild is ever due to correct it. The log said
  `textDocument/definition: DemoUnicode.pas(31,31) no identifier at that
  position` for a column that was
  right: 31 is where `Wrap` sits in UTF-16 code units, while the analysis, with
  13 Cyrillic characters inflated to 26, had it at 44.
- *the fix, and why it is not here:* the server cannot paper over this — it
  would have to re-decode every file the analysis reads. It is a decode decision
  for the library, and PasTree 0.2.3 makes it: a preamble-less file whose bytes
  are valid UTF-8 decodes as UTF-8, ANSI only when they are not. Both sides then
  read the same text out of the same bytes, which is what makes the byte-level
  gate sound rather than merely cheap. `cMinPasTreeVersion` is pinned there, so
  an older sibling checkout fails loudly instead of shifting columns quietly.

**The suite is fully green as of 0.5.4** — `build.bat` ends with `all built, all
harnesses passed`. The two long-standing red checks in
`clients/rad-studio/tests/LspClientSmoke` (*"Wrap resolves despite the Cyrillic
literal earlier on the line"* and *"and lands exactly on Wrap's declaration
(18,9)"*), red since before the move into this repository, are the two the fix
above turned green. If they return, suspect which PasTree the server was built
against before suspecting the resolver.

**A leading BOM in `didOpen` text breaks navigation for the whole file — server
side — fixed 0.5.3, and worth keeping the symptom written down.** Measured
2026-08-20: open a document whose text begins with U+FEFF and `FNav.IdentAt`
then finds nothing at *any* position in that file, not merely on line 1. The log
says only `no identifier at ...`, which reads exactly like a resolver failure
and sent one debugging session down the wrong path entirely.

The RAD Studio client already stripped a leading BOM before sending
(`ReadBufferText`), so the IDE was covered — but that was one client defending
itself against a server-side flaw, and any other client still hit it. An editor
is free to hand its buffer over with the BOM included, and a UTF-8-with-BOM
`.pas` is completely ordinary in Delphi projects. So the strip now happens at
the one place documents enter: `StripLeadingBom` in `PasLsp.Documents`, applied
to `didOpen` text and to a rangeless (full-replacement) `didChange`, before the
rebuild gate so a BOM'd file still compares equal to its own bytes on disk. The
residual cost is one column on line 1 for a client that counts the BOM as a
character — strictly smaller than a file where nothing resolves. Pinned by
`LspClientSmoke` section 4b, which sends the BOM as a raw notification
precisely because the plugin's own document layer can no longer produce one.

**The standing rule, since this was the third layer to learn it separately: any
source text entering the product — from a client's buffer or from a file — may
begin with a BOM, and a BOM is not content.** Delphi writes UTF-8-with-BOM by
default, so it is the ordinary case. Do not open-code the handling; use
`PasLsp.SourceText` (`StripLeadingBom`, `TryReadTextNoBom`, `FileHoldsText`),
which is one of the two units shared with the RAD Studio package and therefore
dependency-free by construction. A new rule about incoming text goes in there,
where both halves get it, rather than in the layer that happened to notice.

### Tier 1 — done 2026-08-19

All four shipped. Two notes worth keeping:

- **No percentage in `$/progress`.** `Total` is "modules discovered so far"
  and grows as the closure opens up — measured going 3/4 → 3/145 within a
  second — so a percentage during discovery is arithmetic about a denominator
  that has not happened yet. Clamping it monotonic (tried first) parked the bar
  at 75%% while the real ratio was 2%%, which is worse than no bar: a wrong
  number reads as fact. The message carries phase and counts instead.
- **Not cancellable.** The machinery exists (the session cancels mid-pass), but
  a cancelled build leaves the user with no results at all — worse than
  waiting. The demo can offer a Stop button because it keeps the previous
  project; here that is what the next edit does anyway.

### Tier 2 — real features, bounded work

- **`workspace/symbol` (+ `workspaceSymbol/resolve`).** Project-wide symbol
  search: on a 3747-unit project this is the feature people reach for most
  (the IDE's own Ctrl+T). Every model's unit and implementation scopes already
  hold what it needs, keyed by `NameLower`.
- **`textDocument/rename` (+ `prepareRename`).** Precise *because* the
  references are resolved rather than textual, and the three-identity model
  already decides what a rename even means. Work is in the edges: a
  `WorkspaceEdit` touching files nobody has open, and a refusal for a builtin
  or a symbol declared in a library unit the user cannot edit. (Listed as a
  non-goal in the original phase plan; the reason it was — no precise
  references — has since gone away.)
- **`workspace/didChangeConfiguration` (+ `workspace/configuration`).**
  Reconfigure without a restart. Today a changed `.dproj` only prints a note
  from the watched-files handler, because search paths, defines and namespaces
  are read once at `initialize`.
- **`textDocument/foldingRange`.** From the CST: unit sections, type bodies,
  `begin`/`end` blocks, `$REGION`.
- **`textDocument/documentLink`.** A `uses` item and an `$I` include name are
  links to files, and the source manager resolves both already.
- **`textDocument/prepareCallHierarchy` + `callHierarchy/incoming|outgoingCalls`.**
  The call bindings exist (that is what the cross-call pass checks).
- **`textDocument/prepareTypeHierarchy` + `typeHierarchy/super|subtypes`.**
  Ancestry is exactly what the inherited-member pass walks.
- **`textDocument/codeLens` (+ `codeLens/resolve`).** "N references" over a
  declaration; a reference search per lens, so it only makes sense with the
  resolve split doing the counting lazily.
- **`textDocument/diagnostic` + `workspace/diagnostic` (pull model).** Lets a
  client ask for whole-closure diagnostics instead of only the open documents
  we push — the natural home for the "diagnostics beyond open files" idea.

### Tier 3 — large, or blocked on library work

- **`textDocument/completion` (+ `completionItem/resolve`).** The biggest
  single feature: members after a dot, names in scope, unit names in a `uses`
  clause. The scopes and member scopes are all there; what is missing is a
  scope lookup AT A POSITION in text that usually does NOT parse — a buffer
  mid-typing is invalid by definition, and that is a different requirement
  from anything the analyzer does today. **The server/plugin half is planned
  in [COMPLETION.md](COMPLETION.md)** — built against a seam so the PasTree
  API (planned in that repository) drops into one unit when it lands.
- **`textDocument/semanticTokens/full|range|full/delta`.** Semantic
  highlighting is a strong fit — the model knows what every identifier
  resolved to, and the demo's own PasTree highlighter is the precedent — but
  it means emitting every token of a file, plus the delta protocol to keep it
  affordable while typing.
- **`textDocument/signatureHelp`.** DELIVERED 2026-08-22 alongside
  completion (see [COMPLETION.md](COMPLETION.md)): PasTree's `CallAt`
  answers through the same seam, active argument counted per request.
- **`textDocument/selectionRange`.** Wants a declaration's full extent — the
  `NodeSpan` the PasTree To-do already lists, which is also the fix for
  `documentSymbol`'s name-only ranges.
- **`textDocument/codeAction` (+ resolve), `workspace/executeCommand`,
  `workspace/applyEdit`.** Quick fixes. "Add the missing unit to `uses`" is
  the obvious first one, and the unresolved-unit diagnostics already know
  which unit is missing.
- **`textDocument/inlayHint` (+ resolve).** Pascal infers little (`var` with
  inferred type), so the payoff is small.
- **`client/registerCapability` / `unregisterCapability`.** Only needed if we
  want to register the file watcher dynamically instead of having each client
  configure it.

### Out of scope, with the reason

- **`textDocument/formatting`, `rangeFormatting`, `onTypeFormatting`,
  `willSaveWaitUntil`.** All need a PRINTER. PasTree parses and analyzes; it
  does not emit source. A formatter is its own project, and a half-correct one
  reformats code wrongly and silently.
- **`notebookDocument/*`.** No notebooks in Pascal.
- **`textDocument/documentColor`, `colorPresentation`, `inlineValue`,
  `moniker`, `linkedEditingRange`.** Either not applicable to the language or
  they serve tooling we do not have (a debugger, an indexer protocol).
- **`workspace/didChangeWorkspaceFolders`, `willCreate|Rename|DeleteFiles`.**
  The server tracks one project, not a folder set — multi-root stays a
  non-goal.

### Explicit non-goals (for now)

- multi-root workspaces beyond one `.dproj`/directory target
- running on anything but Windows x64

## Key decisions and their costs

- **Position encoding.** LSP defaults to UTF-16 code units for columns; the
  Delphi editor and PasTree each count their own way. One conversion layer at
  the protocol boundary, written once, tested on non-ASCII lines. Negotiate
  `positionEncoding` in `initialize`; prefer `utf-16` for compatibility.
- **Document truth.** Once a file is open (`didOpen`), the overlay is the
  truth and the server never reads that path from disk until `didClose`.
  Versions from `didChange` are echoed into results so stale async answers can
  be discarded.
- **Asynchrony in the plugin.** IPC latency is milliseconds; the plugin must
  never block the IDE main thread waiting for a response (the AnalyzeProject
  deadlock lesson). All requests are async with UI-thread marshalling of
  results.
- **Process lifetime.** The plugin starts the server, restarts it on crash
  (with backoff and a give-up count), and the server exits when its stdio
  closes — no orphans after an IDE crash. Two IDEs on one project = two
  independent server processes; no shared state.
- **Project configuration.** The server needs what the CLI tools need: the
  `.dproj`, platform (`-p:Win64` semantics), and the IDE registry search
  paths (`-L` equivalents). Passed in `initializationOptions`; the plugin
  harvests them from ToolsAPI, other clients from a config file.

## Order of work

Done, in this order (2026-08-16 … 19):

1. (PasTree repo) overlay buffers + cancellation in the facade — versioned
   `SetBuffer`/`BufferVersion` and mid-pass cancellation.
2. Server skeleton: JSON-RPC loop, lifecycle, document sync, `definition`.
3. Diagnostics, file logging, and a VS Code dev client.
4. Async core: background session, reader thread, honored `$/cancelRequest`.
5. `references`, the decl-impl toggle, `documentSymbol`, `hover`.
6. Incremental sync, the watched-files handler, the liveness watchdog.
7. Validated with VS Code as a second client — the proof that no IDE-specific
   assumption leaked into the protocol.

Next, and NOT in protocol order:

8. The IDE plugin becomes an LSP client (its own repo) — the point of the
   whole exercise, and the only step that retires in-process analysis.
9. Tier 1 of the coverage list above, `$/progress` first: a 5-second rebuild
   the client cannot see is the most visible remaining gap.
10. (PasTree repo) incremental reanalysis — see that repo's To do; the host
    side here is already doing everything it can without library support.

## Open questions

- stdio vs named pipe for the IDE plugin specifically (stdio needs the plugin
  to own the child process's pipes; ToolsAPI imposes no obstacle, but verify)
- how much of `TPasAsyncSession` (the demo's async layer) is reusable as the
  server's scheduling core vs. server-owned from scratch
- incremental reanalysis granularity: MEASURED and written up as a feature in
  the PasTree repo To-do (parse-artifact cache, then single-module reanalysis
  with a fallback guard). On the demo closure a rebuild splits 21% interface
  parse / 27% full parse / 52% cross passes, so caching the parse is at best
  half the answer
- **a git hash in the build stamp — deliberately deferred, 2026-08-20.** The
  version identifies a commit only if nobody forgets to bump it, and the
  binary's timestamp identifies a compile rather than a commit; embedding
  `git rev-parse --short HEAD` would identify both exactly, with no discipline
  required (`0.5.1+a1b2c3d`). Not done because it needs a real build step:
  `build.bat` would generate an include file, and the package builds through
  msbuild, which would need a pre-build event. Decided to wait until a missed
  bump actually causes confusion — the two existing signals have not failed yet.
  Revisit rather than re-derive.
- **the RAD Studio package's `.dproj` version resource** still says
  `FileVersion=1.0.0.0`, unrelated to `PasTreeLspVersion`. Harmless today (the
  BPL's version resource is not what anything reads), but it is a second number
  claiming to be the package's version, which is exactly the situation this
  project just spent a day removing.
