# Working in this repository

`README.md` is what the product does, `SPEC.md` is the protocol-side
specification, `clients/rad-studio/SPEC.md` the ToolsAPI-side one. This file is
the short list of things that are easy to get wrong and expensive to rediscover.

## Line endings: CRLF for everything Delphi and cmd.exe read

**A `.pas`, `.dpr`, `.dpk`, `.inc`, `.dproj`, `.dfm` or `.bat` in a working copy
is CRLF. Docs (`.md`, `LICENSE`) and the VS Code client (`.json`, `.js`, `.ts`)
are LF.** Declared in `.gitattributes`, in this repo and identically in PasTree
(`../object-pascal-tree`) — keep the two files in step.

This is a rule for **tools and scripts, not just people**: a `sed -i`, a
heredoc, or any editor writing "just a newline" produces LF, and nothing
complains at the time. RAD Studio then re-saves the file its own way on the
first edit, and the next diff is the whole file instead of the three lines that
changed — which is how real changes get lost in review. `cmd.exe` is worse than
cosmetic: it is the one interpreter here that can genuinely misparse an LF-only
`.bat`, and every build goes through one.

Both repositories were renormalized on 2026-08-20, and the drift was *not*
confined to recently-touched files — `PasTree.Parser.pas`, the whole `demo/`
directory and several harnesses had been LF for a while. To check a repository:

```bash
git ls-files --eol
```

Every line's `w/` must match its `attr/`; `i/` is LF for everything, which is
correct — normalization happens in the repository, `eol=` decides the working
copy.

## One product, two halves, one version

The server (`pastree-server.exe`, Win64) and the RAD Studio package
(`clients/rad-studio`, Win32 designtime BPL) are one deliverable. They share
`PasTreeLspVersion` in `source/PasLsp.ProductVersion.pas`, and the package
checks at the LSP handshake that the server reports the *same* version — any
difference means one binary on disk was not rebuilt.

**Bump the PATCH of `PasTreeLspVersion` in every commit**, mechanically. Minor
for a substantial change. PasTree (`../object-pascal-tree`) follows the same
rule for its own independent `PasTreeVersion`. The reasoning is in `SPEC.md`;
the thing to remember is that skipping the bump defeats the mismatch check.

## Building

```
build.bat
```

builds the server, the package and all four harnesses, then runs the harnesses.
Use it rather than building halves separately — the equality check above only
means something if a normal build produces both from the same commit.

**Every `.dcu` goes to `out\dcu\win32` or `out\dcu\win64`, never next to a
source.** Same in the PasTree repo (`tests\build.bat` there builds and runs all
13 suites). It is intermediate output nothing reads between runs, so that one
directory is safe to delete and the one thing to leave out of a backup — and
keeping it out of `source\` means a stray `.dcu` next to a `.pas` is a signal
that something was built outside the scripts. Add a new compilation? Give it
`-N0` (or `DCC_DcuOutput` in a `.dproj`) pointing there, with the platform
subdirectory: the same units compile both ways and the names collide.

- **RAD Studio must be closed.** A running IDE holds the `.bpl`; its live LSP
  session holds `pastree-server.exe`. Either one produces a confusing
  "could not create output file".
- Requires `../object-pascal-tree` checked out as a sibling (the server links
  PasTree; the package must never).
- After a rebuild, **restart the IDE** rather than Uninstall/Install — see
  `clients/rad-studio/README.md`; hot-reload of this package is not reliable and
  the symptom is a change that appears not to work.

## Expected test result

**All four harnesses pass. `build.bat` ends with `all built, all harnesses
passed`, and anything else is a real failure.**

Until 2026-08-20 this section said the opposite: `LspClientSmoke` was expected to
fail exactly two checks about a Cyrillic literal, the known ANSI-vs-UTF-8 decode
split. That is now fixed at the root, in PasTree — a preamble-less source whose
bytes are valid UTF-8 decodes as UTF-8, so the analysis and the editor finally
read the same text (`cMinPasTreeVersion` is pinned at the PasTree version where
that landed, so an older sibling checkout fails loudly instead of quietly
shifting columns). If those two checks ever come back, the first thing to check
is which PasTree the server was built against, not the resolver.

## Diagnosing "the analysis got slow"

**If it got slow WHILE TYPING, the question is not how fast a rebuild is — it
is why there was a rebuild at all.** Since 0.17.0 an ordinary edit re-analyzes
one module (tens of ms to ~1.5 s); a closure rebuild per keystroke is the fast
path not firing, and it is silent — every answer stays correct. Grep
`pastree-lsp.log` for `analysis started:`:

- `incremental, one module (...)` — fired. If it is then followed by
  `incremental refused ... (module=refused:<reason>)`, PasTree declined and the
  reason names itself; `too-many-consumers(N>L)` is tunable with the
  `moduleRedoLimit` initializationOption, the rest are library decisions.
- `full rebuild` on a single-file edit — the server never offered it the fast
  path. That decision is `SingleChangedDoc`, and the cause is always the same
  shape: something made the inputs look like more than one changed document.

Everything below is about a slow REBUILD, which is a different question.

**First suspect: `System.NeverSleepOnMMThreadContention := True` is missing.** It
is the first statement in `pastree-server.dpr` and it must stay there — PasTree
parses across cores, and without it Delphi's memory manager sleeps on allocation
contention, so the workers wait instead of working. Dropping it cost 4.5x on a
3757-unit project (70 s vs 15 s). The fingerprint, and the reason this is worth
a section rather than a comment:

- **CPU time goes DOWN while wall time goes up** — threads waiting, not
  computing. Check with `Get-Process pastree-server` (`TotalProcessorTime` vs
  elapsed); one running thread among thirty asleep is the tell.
- **`intf` and `full` inflate, `cross` does not** — the `stages` field of the
  `analysis done` line in `pastree-lsp.log`. The damage lands on the
  allocation-heavy stages.

To compare against the library directly, run the same closure in-process:
`tools\out64\PasTreeSemaProject.exe <project>.dproj -dproj -p:<platform>
-studio:<bds>` plus one `-L<path>` per search path from the log's own `path`
lines. Matching stage numbers mean the server is fine and the analysis is simply
that expensive; a server 3x worse than in-process means the host, not PasTree.
The reasoning is in `SPEC.md`; do not re-derive it.

Ruled out by measurement, so do not start there: out-of-process overhead (nil —
in-process is the same 15 s) and Debug-vs-Release (~2%, inside noise; the server
carries no debug-only directives).

## Diagnosing "Ctrl+Click did nothing"

The editor only ever says `no identifier/declaration resolved at cursor`. The
real reason is in **`pastree-lsp.log`, in the same folder as the `.dproj` being
analyzed** (stderr beside it). It carries the search paths, every diagnostic
with the unit it belongs to, and both ends of every navigation. Read it before
suspecting the resolver — the last two failures of this kind were a
search-path problem and a stale binary, neither of which was visible from the
editor.

**For a search-path problem specifically, turn the unit inventory on** —
`logUnits` in the initializationOptions (`pastree.logUnits` in VS Code) or
`PASTREE_LSP_LOG_UNITS=1`. It logs one `unit x <- path` line per unit, which is
the only thing that answers "which of several copies on the search path won?",
and it is off by default because it is hundreds of lines per rebuild.

## The package's one hard invariant

`clients/rad-studio` links `rtl, vcl, designide` and exactly two units from
outside its directory — `PasLsp.ProductVersion` and `PasLsp.SourceText`, both
dependency-free by construction. **It must never link PasTree** — it is a
32-bit designtime package and PasTree is Win64-only, which is the entire reason
the analysis runs out of process. `tests/VersionSmoke` is the tripwire: a Win32
program over both shared units, so it stops compiling if either one ever gains
a dependency. Adding a third shared unit is a real decision, not a convenience:
each one is a way for PasTree to get in.

## Reading the analysis model: an empty scope has no lists

**`TSemaScope.Symbols` and `.Names` are created lazily and are legally `nil`**
— the model builds them when the first symbol is declared into the scope, so a
scope that never got one has neither. `LScope.Symbols.Count` on such a scope is
an access violation, not an empty loop, and the symptom is remote from the
cause: on 2026-08-23 every `textDocument/documentSymbol` in a session came back
as `EAccessViolation` (the editor showed "Request failed", the outline was
simply gone). Check for `nil` before iterating any scope container, and cover a
new model-walking handler with at least one harness request — that crash
reached a user because `documentSymbol` had no coverage at all
(`LspClientSmoke` section 5d-bis now exists for exactly this).

## Reading source text: assume a BOM

**Any `.pas`/`.dpr` may start with a BOM, and a BOM is never content.** Delphi
writes UTF-8-with-BOM by default, so this is the common case, not an edge one.
Never hand-roll the handling: go through `source/PasLsp.SourceText.pas` —
`StripLeadingBom` for text arriving from a client, `TryReadTextNoBom` for a file
on disk, `FileHoldsText` to ask whether a file holds a buffer's text. New rules
about incoming text belong in that unit, not in the caller.

Both halves link it, so a fix lands once. The reason it exists is that the same
BOM bug was fixed locally in three separate layers before it was fixed once, and
the symptom is silent and total: one leading U+FEFF in `didOpen` text made
`IdentAt` resolve nothing anywhere in the file — not just line 1 — while the log
said only `no identifier at ...`, which reads exactly like a resolver bug. The
unit header has the full story; `tests/VersionSmoke` pins the behaviour and
`LspClientSmoke` section 4b pins the server end of it.
