# Completion plumbing - server and plugin plan

Status: DELIVERED - agreed 2026-08-21, completion and signature help shipped
2026-08-21/22 once PasTree's completion API landed. Kept as the record of the
seam and its reasons; open polish is under "Deferred polish" below.

Scope: everything completion needs in THIS repository - the LSP server and the
RAD Studio plugin - built now, against a seam, so that when PasTree grows its
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

- **The current overlay text of the edited file** - not the model's copy. The
  model is stale by definition mid-typing; the overlay is the truth
  (`PasLsp.Documents` already enforces that rule for every other request). The
  provider needs the live text to read the token being typed and the dotted
  prefix left of the cursor.
- The analysis snapshot (model), the module id, and the position - 1-based
  line/col in UTF-16 code units, PasTree's own convention, so the existing
  `PasLsp.Protocol` conversions apply unchanged.

What the server needs back, per item: name, symbol kind, a short detail string
(signature), and - non-negotiable - **the replace span**: the start column of
the partially-typed token the item replaces. LSP clients edit by `textEdit`
range, and a provider that only returns names forces every client to re-derive
tokenization; the provider computed it anyway.

**The engine is wired (2026-08-21).** The seam now runs
`PasTree.Sema.Complete` - per request: preprocess+parse the live overlay
text into a fresh model (so "as analyzed" and "as typed" are the same text),
then `TPasCompletion` BRIDGED to the last completed closure analysis, where
every name leaving the overlay (inherited members, used units' types)
resolves through the project. No analysis yet degrades to standalone mode:
locals, own-unit names and keywords still answer. The replace span comes
from the engine's caret primitive (mid-word invocation spans the whole word,
the clangd behavior; the server never filters by prefix - clients do).
Buckets map to `sortText` (`00`-`09` + lowercased name), so precedence-aware
clients sort by resolution precedence. `cMinPasTreeVersion` is pinned at the
engine's stabilization version.

The interim keyword provider this plan shipped first (revising its own
stub-by-default: a mechanism has to be SEEN working) served its purpose -
every wiring fix from the wire format to the RAD viewer's columns landed
against it - and was deleted the day the engine arrived.

## List order and filtering - the rules (DRAFT 2026-11-05, under discussion)

**Goal: guess what the user is about to type here, from the context.** The
constraint on every rule below: it is simple enough to state in one row of
one table. A rule that needs a paragraph to explain is a rule the user cannot
predict, and a list the user cannot predict is one they stop reading.

### Terms

- **Context** - a position where the engine knows what the next value (or
  type) must be, and so what "fits" means there. A context only ORDERS the
  list. **Never listed** is the one exception: what the grammar forbids at
  the position, whatever its type - a procedure where a value is read, a
  variable where a constant must stand. Nothing is hidden for its type alone.

Value positions:

| Context | Example | Fits | Never listed | State |
|---|---|---|---|---|
| assignment | `X := \|` | assignable to X's type | procedures | 0.84 |
| comparison | `if X = \|`, `<>` `<` `>` `<=` `>=` | comparable with X | procedures | 0.84 |
| a member chain in either | `X := Obj.\|` | the same, for the chain's last member | procedures | 0.84 |
| an inline variable's initializer | `var X: T := \|` | assignable to T - the assignment, with the type written out | procedures | 0.84 |
| a call argument | `Foo(A, \|)` | assignable to that parameter; over overloads, the best fit among those taking this many arguments | procedures | planned |
| ... a `var`/`out` argument | `Inc(\|)`, `TryStrToInt(S, \|)` | a variable of exactly that type | constants, functions, procedures | planned |
| ... an untyped or generic parameter | `FillChar(\|`, `Max<T>(\|` | no context | procedures | - |
| a value typecast | `Int64(\|)`, `TFoo(\|)` | the cast's family: any ordinal (integer, enumeration, Char, Boolean) for an ordinal type; a class, interface or pointer for a class or pointer type | procedures | planned |
| `Exit(\|)` | | the routine's result type | procedures | planned |
| a condition | `if \|`, `while \|`, `until \|`, `not \|` | Boolean | procedures | planned |
| a `case` selector | `case \| of` | any ordinal | procedures | planned |
| a `case` label | `case K of \|:` | constants of K's type | variables, functions, procedures - a label is a constant expression | planned |
| `for` bounds | `for I := \| to \|` | I's type | procedures | planned |
| `for ... in` | `for X in \|` | what can be enumerated: an array, a set, a string, a class or record with GetEnumerator | procedures | planned |
| an index | `A[\|]`, `Dict[\|]` | the index type: Integer for a dynamic array, the declared ordinal for a static one, the parameter of an array property (a dictionary's key) | procedures | planned |
| a set element | `S := [\|]`, `K in [\|` | the set's element type | procedures | planned |
| an operand of an operator | `X := A + \|` | A's family: a number, a string or Char, a set | procedures | later |
| `with \| do` | | a value with members | procedures | planned |
| `raise \|` | | an exception instance (`EFoo.Create`, an exception variable) | procedures | planned |
| a default parameter value, a typed constant | `(A: Integer = \|)`, `const C: T = \|` | constants of the type | variables, functions, procedures | 0.84 ranks by the type and hides procedures; hiding variables and functions planned |
| an event or method pointer | `OnClick := \|` | methods whose signature matches the procedural type (0.84 keeps every procedure here, unranked) | - | planned |

Type positions (types alone are listed; the context ranks them):

| Context | Example | Fits | State |
|---|---|---|---|
| a declaration | `Name: \|` | any type | done |
| a generic argument | `TList<\|>`, `Foo<\|>(...)` | what the parameter's constraint admits: `class` - classes; `record` - value types; `constructor` - classes with a parameterless constructor; a class or interface - its descendants or implementors | planned |
| `is` / `as` | `if Sender is \|` | descendants of the left side's static type (and interfaces after `as`) | planned |
| an exception handler | `on E: \|` | exception classes | planned |
| a heritage list | `class(\|)` | classes first, then interfaces | done (types alone) |
| a generic constraint | `<T: \|>` | `class`, `record`, `constructor`, classes, interfaces | planned |
| an attribute | `[\|]` before a declaration | TCustomAttribute descendants | planned |

A type NAME fits as a value where its type would (`X := TFoo(Y)`,
`X := TFoo.Create`): the cast and the constructor both produce one.

- **Filter** - the letters already typed of the identifier at the caret.
- **Fit** (per item, decided by PasTree's `MatchOf`, sent as `data.match`:
  0 and 1 are fit 1 - the same type, an assignable one - 2 is fit 2, 3 or
  absent fit 3; split since 0.84.0):

| Fit | What it is |
|---|---|
| 1 - fits | the same type, or assignable with evidence: a descendant class or interface, an integer for an integer or float, a Char for a string, `True`/`False` for a Boolean, `nil` for a reference or a dynamic array, a dynamic array whose element fits (the start of `A[I]`) |
| 2 - leads to it | may reach the value through `.` `[` `(`: a value of a type with members (class, record, interface, a class reference), an array, a pointer, a procedural value, a type (`TFoo.Create`, `TPath.Combine`, a cast), a unit name, a function whose result the engine cannot type (`GetValue<T>`, `Ord`, `Copy`); everything where a Boolean is expected, since a comparison makes one of any value |
| 3 - does not fit | proven wrong: a number, a string, a Char, an enumeration or a set of no fit. A scalar's helper (`S := I.ToString`) is the one way out this ignores. (A procedure is not listed at all - the context's "Never listed".) |

- **Proximity** - where the name is declared, nearest first: locals and
  parameters, members of the class the caret is in, this unit, used units,
  System. The server already sends it as the second key of `sortText`.

### The rules

| # | Context | Filter | What is listed | Order |
|---|---|---|---|---|
| A | no | no | everything reachable from the position | proximity, name |
| B | yes | no | everything reachable, less what the context never lists | fit, proximity, name - fit 3 last |
| C | any | yes | every name the filter matches (tiers 1 to 4 below; tier 1 and 2 alone when the IDE's "contain filter" option is off), less what the context never lists | fit 3 last (with a context); above it and inside it: match tier, then fit, proximity, name |

The match tiers of rule C (the tiers VS Code and Roslyn rank a filtered list by):

| Tier | The filter is | Example |
|---|---|---|
| 1 | the whole name | `str` - `Str` |
| 2 | the start of the name | `str` - `StrAlloc` |
| 3 | the start of a word inside it, or the starts of its words in order | `str` - `pkStripe`; `gs` - `GetSelection`; `fpf` - `CC_FPFASTCALL` |
| 4 | anywhere else in it | `fas` - `CC_FPFASTCALL` |

A word starts at a capital after a small letter or a digit, at the last
capital of a run followed by a small letter (`TIEFast`: T, I, Fast), after an
underscore, and at a digit after a non-digit. Without the IDE's "starts with
first" option tiers 1 to 4 are one run.

Selected row: the first. Under the IDE's "Select shortest matching symbol",
the shortest name of the first row's tier and fit.

### Measured (local/cc-sim, 2026-11-05)

317 real `:=`/`=`/`<>` sites of this repository and PasTree, each replayed as
if the right side were being typed. "top 5" is the share where the name the
author wrote is among the first five rows.

| Typed | Order | Head of the right side: top 5 / median row | Member after a dot: top 5 / median row |
|---|---|---|---|
| nothing | name only (before 0.84) | 0% / 1322 | 25% / 14 |
| nothing | fit, name (0.84) | 12% / 207 | 46% / 11 |
| nothing | fit, proximity, name (rule B order) | 20% / 125 | 46% / 11 |
| 1 letter | fit first, then filter match (0.84 before rule C) | 38% / 12 | 61% / 2 |
| 1 letter | start or contained first, then fit, proximity | 41% / 8 | 87% / 2 |
| 1 letter | the four match tiers, then fit, proximity (rule C) | 41% / 8 | 87% / 2 |
| 2 letters | fit first, then filter match (0.84 before rule C) | 68% / 2 | 88% / 1 |
| 2 letters | start or contained first, then fit, proximity | 72% / 2 | 95% / 1 |
| 2 letters | the four match tiers, then fit, proximity (rule C) | 73% / 2 | 95% / 1 |
| 3 letters | fit first, then filter match (0.84 before rule C) | 87% / 1 | 92% / 1 |
| 3 letters | start or contained first, then fit, proximity | 89% / 1 | 100% / 1 |
| 3 letters | the four match tiers, then fit, proximity (rule C) | 89% / 1 | 100% / 1 |

The selected row (the head of the right side) is the author's name at 45% of
the sites with 2 letters typed under the tiers, 42% without them; 63% with 3
letters, 66% without: a whole-name match comes first even where it does not
fit - `nil` for `NIL_NODE`, `Low` for `LowerCase` - as in Roslyn.

A match at a word start inside the name (`pkStripe` for `str`) counted as a
start-of-name match was also measured and is worse than both (1 letter, after
a dot: 64%): every capital is a word start, so one letter matches nearly
everything.

### Open decisions

- **Rule C - DECIDED 2026-11-05: what is proven wrong (fit 3) last, then
  the match tier, then the fit.** Three steps: the tier outer for all, as
  VS Code and Roslyn do; then the fit outer, after a session in the IDE
  (Alex: a name that matches the letters well but does not fit is no help);
  then, with fit 2 and fit 3 told apart, only fit 3 below everything - a
  value that leads to the type (`LM.` for `LM`) is no worse a start than a
  fitting name that merely contains the letters. `PayKind = str` lists
  `pkStripe` above `StrAlloc` (a PChar, which leads to no enumeration) and
  the string functions.
  The replay prices it (run7, top 5, head of the right side / member after a
  dot): 2 letters 62% / 88% against 73% / 95% with the tier outer; 3 letters
  84% / 92% against 89% / 100%. Every loss is a name of the server's third
  group (`data.match` 2), which today holds both "leads to it" and "does not
  fit": `LM` for `LM.UsesList[LU].UnitId`, `Ord`, `FModel.Symbols` - each
  below every fitting name that merely contains the letters.
  With the third group split (0.84.0, run8): the author's name is never fit
  3, so "proven wrong" is sound. Top 5, head / member, by letters typed:

  | Order | 1 | 2 | 3 |
  |---|---|---|---|
  | tier, then fit (VS Code) | 43% / 90% | 74% / 93% | 90% / 100% |
  | fit (1, 2, 3), then tier | 42% / 83% | 63% / 90% | 87% / 97% |
  | fit 3 last; fit 1 and 2 by tier, then fit - rule C | 43% / 90% | 74% / 93% | 90% / 100% |

  The third also selects the author's name most often (2 letters 48%, 3
  letters 67%, against 37% and 60% with the fit outer).
  After two classification fixes (run9: a subrange bounded by an
  expression - TColor, TModalResult - was uncategorized, and every type name
  led somewhere) rule C reaches 51% / 76% / 92% at the head for 1 / 2 / 3
  letters. A fitting name matched at a word start ranked with the name
  starts (`pkStripe` above `StrToGUID` for `str`) was measured and drops
  it to 33% / 70% / 89%: one or two letters start a word in most names.
- **Rule B - DECIDED 2026-11-05: fit 3 goes last, it is not hidden.** Only
  the grammar hides (the "Never listed" column). Hiding by type would have
  lost the author's name at 15 of the 313 sites with a context (5%): 7 types
  (`TStringBuilder.Create`), 6 functions the engine cannot type
  (`GetValue<string>`, `Default`, `Ord`, `Copy`), 2 casts or untyped names.
  A scalar with a helper has members too (`S := I.ToString`), so "another
  scalar type" is not proof of a wrong name. The major engines agree: clangd,
  Roslyn, VS Code and IntelliJ's basic completion all demote on the expected
  type and hide only what the grammar forbids (VS: base lists, `catch`,
  `is`/`as`); IntelliJ hides by type only in its separate smart completion
  and warns that the list can come out empty when inference fails.
- **Rule A - DECIDED 2026-11-05: proximity, then name**, as VS Code orders
  by sortText; the native list sorts by name alone, but the measurement says
  proximity helps wherever there is no filter.
- **The match tiers - TAKEN 2026-11-05 from VS Code and Roslyn** (0.84.0),
  inside each fit group. Not measured: abbreviations (`gs`), which a replay of
  what was typed never produces.

## Server (phase A - done 2026-08-21, on the keyword provider)

1. **Advertise** `completionProvider: {"triggerCharacters": ["."]}` in the
   `initialize` response (`PasLsp.Server.pas:994`). No `resolveProvider` yet -
   nothing lazy to resolve until the provider has documentation to defer.
2. **`HandleCompletion`**, dispatched like the other `textDocument/*`
   requests, with one deliberate difference: **it must not call
   `WaitAnalyzed`** (`PasLsp.Server.pas:860`). That helper flushes the pending
   rebuild and blocks until the closure is analyzed - exactly right for a
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
   - Completion never schedules a rebuild either - `didChange` already did.
3. **Response**: `CompletionList` with `isIncomplete` and items carrying
   `label`, `kind`, `detail`, `sortText`, and a `textEdit` built from the
   provider's replace span. Always `textEdit`, never bare `insertText` - the
   span is authoritative and survives a cursor that moved while the answer was
   in flight.
4. **Cancellation**: nothing new - `$/cancelRequest` and the cancel-poll
   already cover it; the handler checks the cancel set before serializing.
5. **Log line**: `completion <file>:<line>:<col> in <N> ms -> <M> items
   (<provider>)` - same discipline as `analysis done`/navigation lines; the
   log is the diagnosis surface for "completion shows nothing".
6. **Harness** (`LspClientSmoke`, section 5b): the request answers; items are
   filtered by the typed prefix; every item's `textEdit` range is exactly the
   typed token; and the replace span survives the UTF-16 column conversion on
   the Cyrillic fixture line (`DemoUnicode.pas` - same line the decode split
   was pinned on). The checks pin the CONTRACT, not the vocabulary: when
   PasTree replaces the keyword provider, everything but the literal labels
   must keep passing unchanged.

## Plugin (phase B - done 2026-08-21: LspCompletion plus the gated manager)

1. **`PasTreeIdePlugin.LspSession`** (done): add `LspCompletion(AFileName, ARow,
   ACol, ATriggerChar, AOnDone)` on the existing `Ask` pattern - its own
   pending-id slot, supersede-cancels-the-previous, closure-per-call capture,
   `FDocs.Sync` before send (sync-on-request already guarantees the server
   sees the freshest text - the requirement above is satisfied by the
   existing design, nothing new to build). Parses the `CompletionList` into a
   plain record array (`TLspCompletionItem`: label, kind, detail, replace
   span) - no JSON escapes past the session boundary, same as `TLspHit`.
2. **`PasTreeIdePlugin.CodeInsight`** (built; live bring-up CONFIRMED
   2026-08-21 - viewer, prefix filtering and accept-replaces-prefix all
   behave. Two findings a future reader needs: the undocumented AsyncInvoke*
   position parameters do NOT point at the caret's text, so completion reads
   EditPosition instead; and the native row layout is reproduced by the STOCK
   renderer once the columns are fed natively - SymbolClassText carries the
   left-hand class word in DelphiLSP's own vocabulary ('keyword', 'function',
   'const', …), SymbolTypeText is the glued-after-the-name slot where real
   signatures will go verbatim. Custom drawing was tried and backed out: the
   stock look IS the native look. The native viewer's bottom key-legend panel
   is that window's own chrome - nothing in ToolsAPI reaches it, managers get
   the classic window): `TPasCodeInsightManager`
   implementing `IOTACodeInsightManager100` (registration takes the sync
   interface) and offering `IOTAAsyncCodeInsightManager`/`…290` via
   `Supports` - the async shape is the whole point. The method map:
   - `HandlesFile` → `IsPascalSourceFile` (already shared).
   - `AsyncInvokeCodeCompletion` → `LspCompletion`; on answer, fill a local
     `TPasSymbolList` (implements `IOTACodeInsightSymbolList`) and invoke the
     IDE's callback. `SetFilter`/`FindIdent` are then answered synchronously
     from that cached array - they are called per keystroke and may never
     round-trip (the constraint clients/rad-studio/SPEC.md documents).
   - `AsyncGotoDefinitionEx` → the existing definition path in
     `PasTreeIdePlugin.GotoDeclaration`'s resolve logic - but returning
     file/line/col to the IDE instead of navigating ourselves: under the
     manager, the IDE navigates and keeps history. This is the migration seam
     the decided endgame needs.
   - Everything the server cannot answer yet - parameter insight, hint text -
     declines honestly (`AllowCodeInsight` says no for those invocations), so
     the IDE shows nothing rather than something wrong.
3. **Registration** - always on (revised 2026-08-21 at the user's call; the
   plan originally gated it behind `PASTREE_CODEINSIGHT=1`, and the gate was
   judged more ceremony than safety for a dev-stage plugin whose recovery
   path is uninstalling it). The IDE's own selection step is the real gate:
   registration alone takes nothing over - the manager only answers once the
   user picks "PasTree" under Tools > Options > Editor > Source > Insight
   Provider, and the same combobox switches back.
4. **Teardown**, per the standing rule: `RemoveCodeInsightManager` before the
   BPL unloads, ordered with the other unregistrations in
   `TIDEWizard.Destroy`.

## Phase C - DONE 2026-08-22

The mouse-notifier Ctrl+Click override and the `cEdMenuCatIdentifier` menu
takeover are deleted (the stepping stone - the override standing down when
PasTree was the selected provider - proved the manager's browse path live
first). The manager is the one navigation path: the IDE draws the
Ctrl+hover underline from our resolver, navigates, and keeps history; the
native "Find Declaration" menu item is back in its native slot and routes
by provider selection like everything else; the one-way-door caveat retired
with the code that carried it. "Find Type Declaration" and "Find
References" are not Code Insight concepts, so they stay ours - now under
the plugin's OWN menu category, cleanly unregistered at unload. The
provider contract cuts both ways and is accepted: selecting DelphiLSP gives
native navigation everywhere, PasTree gives ours everywhere - one combobox,
the whole insight family.

## Deferred polish (TODO)

**Rich row coloring in the RAD viewer** - **delivered 2026-08-22**, one day
after being noted, because step 1 turned out to already exist: the item
carries no signature field, but the project answers a symbol's DECLARED TYPE
on demand (`SymDeclTypeX`/`SubstX`/`XTypeText` - the recipe PasTree's own
demo popup uses, ≤512-item guard included). The seam emits `': <type>'` in
`detail` plus the routine's head word (`ItemHeadWord`, PasTree 0.5.0) in the
item's `data`; the plugin feeds `detail` to `SymbolTypeText` (the glued slot
IS the native layout) and `DrawLine` takes over COLORS only: class word and
punctuation dimmed, type name in the theme-aware blue, the selected row left
in the viewer's own highlight for contrast - which is what the native window
does too.

**Full routine signatures - delivered 2026-08-22, same day:** the parameter
list turned out to need no new engine API either - the declaration's
`nkParams` span read verbatim from the source text (whitespace-collapsed,
capped) IS the signature, so a routine row now reads
`(const AName: string): string` like the native list. The same walk decides
`hasParams`, which rides the item's `data`.

**Tooltip Insight - delivered 2026-08-22** (was queued below): plugin-only,
as predicted - `LspHover` on the Ask pattern, the session strips the
server's markdown to tooltip plain text, `AsyncGetHintText` serves it and
key `#3` stopped declining. The hint position trusts the browse-confirmed
parameter convention; if a tooltip ever describes the neighbor token, that
conversion is the first suspect.

**Auto-parenthesis - delivered 2026-08-22** (was queued below): `Done`
inserts `()` and steps the caret inside when the accepted item's
`hasParams` says so - a parameterless routine stays bare. Two recorded
deviations from the original note: the IDE's own "Auto parenthesis" option
is NOT honored (nothing in ToolsAPI exposes its value - searched), and
parens apply only on keyboard accepts (Enter/Tab), so a future close-key
`(` accept cannot double the paren.

**Parameter insight - plumbing delivered 2026-08-22, real provider later
the same day.** The full chain ships: `textDocument/signatureHelp` on the
no-WaitAnalyzed rule (trigger chars `(` and `,`), the manager's
`AsyncInvokeParameterCodeInsight` + both `IOTACodeInsightParameterList`
views + key `#1` un-declined, and the active argument recounted server-side
per request (`ParamIndex` answers -1 = reinvoke, so it cannot drift). The
provider is PasTree's `CallAt` (0.6.0, its plan §8B): innermost enclosing
call with indexers/grouping parens/casts stepped over, designator resolved
through the overlay+bridge - member calls and freshly typed cross-unit
calls both answer, the two recorded gaps of the interim backward-walk
locator, which was deleted as promised the day `CallAt` landed. Nothing
above the seam moved in the swap.

(Tooltip Insight and auto-parenthesis were queued here and are delivered -
see above.)

**Colored tooltips (noted 2026-08-22, wanted but blocked in ToolsAPI):** the
manager's hint path (`GetHintText`/`AsyncGetHintText`) accepts a bare string
and no custom-draw hook exists for the editor's hint window - the colored
hover the native IDE shows is the new LSP window's private UI, same class as
its bottom key-legend panel. The only route is a hint window of OUR OWN
(mouse-hover via the editor notifier, anchored with `GetCharacterPosPx`,
painted by `DrawColoredSignature`) - roughly a day, and it owns its
positioning/dismissal/theming. Queued behind parameter insight if wanted.

**Intrinsics show no signatures (found live 2026-08-22) - FIXED the same
day.** Compiler-seeded routines (SetLength, Length, Inc, ...) have no
source declaration, so every declaration-span consumer here showed them
bare. PasTree 0.6.0 ships curated display signatures for all 97 seeded
intrinsics plus a takes-arguments flag (its plan §8C), and they flow
through `ItemParamsText`/`ItemHasParams`/`CallAt` - so completion Detail,
signatureHelp and auto-parenthesis all answer for `SetLength(` now, with
all-optional intrinsics (Exit, Halt, Writeln) correctly staying bare.

## Handed to the PasTree plan (deep-review outcome, 2026-08-22)

RESOLVED 2026-08-22: PasTree 0.6.0 shipped the whole ask - public
`ItemParamsText`/`ItemHasParams` (empty `()` answers False, the
auto-parenthesis semantics ours pioneered), `TPasTree.NodeSpanText`, and
`CallAt`. The seam's private copies (`RoutineNodeOf`, `ParamsNodeOf`,
`HasParamChild`, `NodeSpanText`) are deleted; `cMinPasTreeVersion` rose to
0.6.0. The seam keeps only display concerns: the 100-char Detail cap and
`SplitParamLabels` (params text → individual LSP parameter labels).

## Deliberately not in this plan

- **`completionItem/resolve`** - until the provider defers documentation
  loading there is nothing to resolve; advertising it buys latency for
  nothing. **Settled for good on 2026-08-23**, when documentation arrived
  (XMLDoc, PasTree 0.6.3's `ItemDocComment`): it ships with EVERY item
  instead, because the RAD viewer asks a row for its documentation through
  `IOTACodeInsightSymbolList80.GetSymbolDocumentation` - a synchronous
  UI-thread call that may never round-trip - so a resolve pass would serve
  the one client we do not have and leave ours blank. The per-row cost is
  a backward raw-token step that stops immediately for every undocumented
  declaration, i.e. nearly all of them.
- **A word-scan-the-buffer provider** - identifiers harvested textually would
  LOOK scope-aware while ignoring scope, which teaches distrust. The keyword
  provider skirts this by being visibly, unmistakably just the reserved
  words; anything smarter waits for PasTree.
- **`textDocument/signatureHelp`** - same seam, separate feature; it enters
  this plan only after completion itself is real.
- **Incremental reanalysis** - the freshness gap is owned by the PasTree plan;
  this side is already shaped so that neither outcome (fresh-file-parse or
  true incremental) changes the server or plugin code.
