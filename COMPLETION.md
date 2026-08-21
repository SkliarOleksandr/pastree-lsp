# Completion plumbing — server and plugin plan

Status: agreed plan, 2026-08-21. Not started.

Scope: everything completion needs in THIS repository — the LSP server and the
RAD Studio plugin — built now, against a seam, so that when PasTree grows its
completion API (planned separately, in the PasTree repository) it drops into
one unit and everything around it already works. The companion documents:
[SPEC.md](SPEC.md) owns the protocol inventory (completion is its tier-3
entry), [clients/rad-studio/SPEC.md](clients/rad-studio/SPEC.md) owns the
ToolsAPI side and the decided endgame this plan feeds (the Code Insight
manager route).

## The seam: one unit owns the PasTree call

`source/PasLsp.Completion.pas` (new) is the ONLY unit that will ever call the
future PasTree completion API. Everything else in this plan compiles and runs
before that API exists.

What the server hands across the seam (this is the requirement list for the
PasTree-side plan, to be reconciled with it):

- **The current overlay text of the edited file** — not the model's copy. The
  model is stale by definition mid-typing; the overlay is the truth
  (`PasLsp.Documents` already enforces that rule for every other request). The
  provider needs the live text to read the token being typed and the dotted
  prefix left of the cursor.
- The analysis snapshot (model), the module id, and the position — 1-based
  line/col in UTF-16 code units, PasTree's own convention, so the existing
  `PasLsp.Protocol` conversions apply unchanged.

What the server needs back, per item: name, symbol kind, a short detail string
(signature), and — non-negotiable — **the replace span**: the start column of
the partially-typed token the item replaces. LSP clients edit by `textEdit`
range, and a provider that only returns names forces every client to re-derive
tokenization; the provider computed it anyway.

**The engine is wired (2026-08-21).** The seam now runs
`PasTree.Sema.Complete` — per request: preprocess+parse the live overlay
text into a fresh model (so "as analyzed" and "as typed" are the same text),
then `TPasCompletion` BRIDGED to the last completed closure analysis, where
every name leaving the overlay (inherited members, used units' types)
resolves through the project. No analysis yet degrades to standalone mode:
locals, own-unit names and keywords still answer. The replace span comes
from the engine's caret primitive (mid-word invocation spans the whole word,
the clangd behavior; the server never filters by prefix — clients do).
Buckets map to `sortText` (`00`–`09` + lowercased name), so precedence-aware
clients sort by resolution precedence. `cMinPasTreeVersion` is pinned at the
engine's stabilization version.

The interim keyword provider this plan shipped first (revising its own
stub-by-default: a mechanism has to be SEEN working) served its purpose —
every wiring fix from the wire format to the RAD viewer's columns landed
against it — and was deleted the day the engine arrived.

## Server (phase A — done 2026-08-21, on the keyword provider)

1. **Advertise** `completionProvider: {"triggerCharacters": ["."]}` in the
   `initialize` response (`PasLsp.Server.pas:994`). No `resolveProvider` yet —
   nothing lazy to resolve until the provider has documentation to defer.
2. **`HandleCompletion`**, dispatched like the other `textDocument/*`
   requests, with one deliberate difference: **it must not call
   `WaitAnalyzed`** (`PasLsp.Server.pas:860`). That helper flushes the pending
   rebuild and blocks until the closure is analyzed — exactly right for a
   click on stable code, exactly wrong per keystroke (a full rebuild is ~15 s
   on the reference project). The completion rule is: answer from the snapshot
   that exists, now.
   - No snapshot, or a build in flight → empty `CompletionList` with
     `isIncomplete: true` (a legal "ask me again"), in microseconds.
   - Snapshot present → call the seam. The snapshot may trail the text; that
     staleness is acknowledged and lives on the PasTree side of the seam
     (its plan owns "stale model + fresh parse of the one edited file"). The
     server passes the live overlay text precisely so no server rework is
     needed when that lands.
   - Completion never schedules a rebuild either — `didChange` already did.
3. **Response**: `CompletionList` with `isIncomplete` and items carrying
   `label`, `kind`, `detail`, `sortText`, and a `textEdit` built from the
   provider's replace span. Always `textEdit`, never bare `insertText` — the
   span is authoritative and survives a cursor that moved while the answer was
   in flight.
4. **Cancellation**: nothing new — `$/cancelRequest` and the cancel-poll
   already cover it; the handler checks the cancel set before serializing.
5. **Log line**: `completion <file>:<line>:<col> in <N> ms -> <M> items
   (<provider>)` — same discipline as `analysis done`/navigation lines; the
   log is the diagnosis surface for "completion shows nothing".
6. **Harness** (`LspClientSmoke`, section 5b): the request answers; items are
   filtered by the typed prefix; every item's `textEdit` range is exactly the
   typed token; and the replace span survives the UTF-16 column conversion on
   the Cyrillic fixture line (`DemoUnicode.pas` — same line the decode split
   was pinned on). The checks pin the CONTRACT, not the vocabulary: when
   PasTree replaces the keyword provider, everything but the literal labels
   must keep passing unchanged.

## Plugin (phase B — done 2026-08-21: LspCompletion plus the gated manager)

1. **`PasTreeIdePlugin.LspSession`** (done): add `LspCompletion(AFileName, ARow,
   ACol, ATriggerChar, AOnDone)` on the existing `Ask` pattern — its own
   pending-id slot, supersede-cancels-the-previous, closure-per-call capture,
   `FDocs.Sync` before send (sync-on-request already guarantees the server
   sees the freshest text — the requirement above is satisfied by the
   existing design, nothing new to build). Parses the `CompletionList` into a
   plain record array (`TLspCompletionItem`: label, kind, detail, replace
   span) — no JSON escapes past the session boundary, same as `TLspHit`.
2. **`PasTreeIdePlugin.CodeInsight`** (built; live bring-up CONFIRMED
   2026-08-21 — viewer, prefix filtering and accept-replaces-prefix all
   behave. Two findings a future reader needs: the undocumented AsyncInvoke*
   position parameters do NOT point at the caret's text, so completion reads
   EditPosition instead; and the native row layout is reproduced by the STOCK
   renderer once the columns are fed natively — SymbolClassText carries the
   left-hand class word in DelphiLSP's own vocabulary ('keyword', 'function',
   'const', …), SymbolTypeText is the glued-after-the-name slot where real
   signatures will go verbatim. Custom drawing was tried and backed out: the
   stock look IS the native look. The native viewer's bottom key-legend panel
   is that window's own chrome — nothing in ToolsAPI reaches it, managers get
   the classic window): `TPasCodeInsightManager`
   implementing `IOTACodeInsightManager100` (registration takes the sync
   interface) and offering `IOTAAsyncCodeInsightManager`/`…290` via
   `Supports` — the async shape is the whole point. The method map:
   - `HandlesFile` → `IsPascalSourceFile` (already shared).
   - `AsyncInvokeCodeCompletion` → `LspCompletion`; on answer, fill a local
     `TPasSymbolList` (implements `IOTACodeInsightSymbolList`) and invoke the
     IDE's callback. `SetFilter`/`FindIdent` are then answered synchronously
     from that cached array — they are called per keystroke and may never
     round-trip (the constraint clients/rad-studio/SPEC.md documents).
   - `AsyncGotoDefinitionEx` → the existing definition path in
     `PasTreeIdePlugin.GotoDeclaration`'s resolve logic — but returning
     file/line/col to the IDE instead of navigating ourselves: under the
     manager, the IDE navigates and keeps history. This is the migration seam
     the decided endgame needs.
   - Everything the server cannot answer yet — parameter insight, hint text —
     declines honestly (`AllowCodeInsight` says no for those invocations), so
     the IDE shows nothing rather than something wrong.
3. **Registration** — always on (revised 2026-08-21 at the user's call; the
   plan originally gated it behind `PASTREE_CODEINSIGHT=1`, and the gate was
   judged more ceremony than safety for a dev-stage plugin whose recovery
   path is uninstalling it). The IDE's own selection step is the real gate:
   registration alone takes nothing over — the manager only answers once the
   user picks "PasTree" under Tools > Options > Editor > Source > Insight
   Provider, and the same combobox switches back.
4. **Teardown**, per the standing rule: `RemoveCodeInsightManager` before the
   BPL unloads, ordered with the other unregistrations in
   `TIDEWizard.Destroy`.

## Phase C — the switch (after PasTree lands and quality clears the bar)

**Stepping stone in place (2026-08-21):** the mouse override stands down
whenever OUR manager is the selected Insight Provider
(`PasTreeIsActiveInsightProvider`), so the native click chain reaches
`AsyncGotoDefinitionEx` and the manager's browse path — the last untested
piece of the switch — is exercised live while every user who never touched
Options keeps the old behavior bit for bit. A bring-up log line in
`AsyncGotoDefinitionEx` records the raw position parameters (completion's
proved untrustworthy; browse's convention still needs pinning) and comes out
once a run confirms where the jump lands.

Per the decision recorded in clients/rad-studio/SPEC.md: the mouse-notifier Ctrl+Click override plus the
`cEdMenuCatIdentifier` menu takeover are **deleted** — the manager's
`GotoDefinition` becomes the one navigation path, the IDE draws the Ctrl+hover
underline from our resolver, and the one-way-door caveat retires with the code
that carried it.

## Deliberately not in this plan

- **`completionItem/resolve`** — until the provider defers documentation
  loading there is nothing to resolve; advertising it buys latency for
  nothing.
- **A word-scan-the-buffer provider** — identifiers harvested textually would
  LOOK scope-aware while ignoring scope, which teaches distrust. The keyword
  provider skirts this by being visibly, unmistakably just the reserved
  words; anything smarter waits for PasTree.
- **`textDocument/signatureHelp`** — same seam, separate feature; it enters
  this plan only after completion itself is real.
- **Incremental reanalysis** — the freshness gap is owned by the PasTree plan;
  this side is already shaped so that neither outcome (fresh-file-parse or
  true incremental) changes the server or plugin code.
