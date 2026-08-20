# PasTree LSP

Object Pascal code intelligence out of process, built on
[PasTree](https://github.com/SkliarOleksandr/object-pascal-tree): one Win64
executable (`pastree-server.exe`) speaking the
[Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
over JSON-RPC 2.0, plus the clients that ship with it.

It serves two kinds of clients with the same protocol:

- **the RAD Studio IDE package** (`clients/rad-studio/`) — a thin LSP client
  over ToolsAPI, replacing the IDE's own DelphiLSP-based navigation;
- **standard editors** — VS Code (`clients/vscode/`), Neovim, anything with an
  LSP client.

## Layout

```
pastree-server.dpr, source/       the server (Win64)
source/PasLsp.ProductVersion.pas  one version for the server and both clients
source/PasLsp.SourceText.pas      BOM and buffer-vs-file rules, shared likewise
clients/rad-studio/               the RAD Studio designtime package + its tests
clients/vscode/                   the VS Code extension (also a .vsix)
build.bat                         builds everything and runs the harnesses
out/                              build output; out/dcu/{win32,win64} is throwaway
SPEC.md                           the protocol-side specification
clients/rad-studio/SPEC.md        the ToolsAPI-side specification
```

The RAD Studio package lived in its own repository (`pastree-ide-plugin`) until
2026-08-20 and was merged here with its history. The reason is the dependency
shape: the server is useful without that package, the package is useless
without the server, and they are always deployed as a pair. Two repositories
gave the pair two version numbers and therefore a way for them to disagree —
which they did, silently, until a human read a version string out of the IDE's
Build tab. One repository makes that an equality check. `clients/vscode` was
already here, so the layout is unchanged in kind: a server and its clients.

**One invariant to protect.** The RAD Studio package must keep linking nothing
but `rtl, vcl, designide` and the two dependency-free shared units,
`PasLsp.ProductVersion` and `PasLsp.SourceText`. It is a 32-bit designtime BPL;
PasTree is Win64-only, and that constraint is the whole reason the analysis runs
out of process. Now that the package sits in the same repository as
PasTree-dependent code, adding "just one" PasTree unit to it is an easy mistake
to make and would undo the move. `VersionSmoke` fails to build if either shared
unit ever grows a dependency, which is the alarm for the most likely version of
that mistake.

## Status

Phases 1 and 2 are complete and exercised live.

**Protocol**

| Request / notification | Notes |
|---|---|
| `initialize` / `initialized` / `shutdown` / `exit` | project config via `initializationOptions` (`.dproj` or `.dpr`, platform, config, extra search paths and defines, log file) |
| `textDocument/didOpen` / `didChange` / `didClose` | incremental sync; open documents become versioned overlay buffers, and the disk file is never read for them |
| `textDocument/definition` | where the name under the cursor is declared |
| `textDocument/references` | the three-identity model: symbol / unit / compiler builtin |
| `textDocument/implementation`, `textDocument/declaration` | the Pascal decl-impl toggle |
| `textDocument/documentSymbol` | the unit outline, types with their members |
| `textDocument/hover` | the declaration under the cursor |
| `textDocument/publishDiagnostics` | for open documents, after each analysis |
| `workspace/didChangeWatchedFiles` | the client watches, the server decides whether a rebuild is due |
| `$/cancelRequest` | honored (−32800), noted by a dedicated stdin reader thread |
| `$/progress` + `window/workDoneProgress/create` | server-initiated progress for the background analysis |
| `window/logMessage`, `window/showMessage` | server trouble the user can act on |
| `textDocument/typeDefinition` | the type of the thing under the cursor, across units |
| `textDocument/documentHighlight` | occurrences within the current file |

**Behaviour** — analysis runs on a background session, debounced so a typing
burst costs one build; a document event only schedules a rebuild when the text
really differs from what was analyzed; a result whose buffer versions went
stale mid-build is swapped in and immediately rebuilt; and a client that dies
without closing stdin is noticed by the liveness watchdog.

Verified against VS Code (`clients/vscode`, also installable as a VSIX):
go-to-definition, find-all-references, outline, hover and diagnostics all work
live against the demo project's 197-unit closure.

The full specification — architecture, protocol phases, key
decisions and their costs, order of work — is in [SPEC.md](SPEC.md).

The PasTree-side prerequisites (versioned overlay buffers and mid-pass
cancellation in the analysis) landed in the PasTree repo on 2026-08-16.

## Why out-of-process

- Large projects need more address space than a 32-bit IDE can offer —
  analysis of a multi-thousand-unit project runs comfortably only on Win64.
- An analyzer crash must not take the IDE down.
- The same executable serves editor-agnostic LSP clients for free.

## Versions

**One version for the whole product** — the server and every client in
`clients/` — in `source/PasLsp.ProductVersion.pas`. Patch bump per commit, minor
for a substantial change; see [SPEC.md](SPEC.md) for the policy and why the
patch component exists. PasTree keeps its own independent version, and is the
one dependency this product states a minimum against
(`cMinPasTreeVersion` in `PasLsp.Version.pas`, checked at startup — PasTree is
linked into this exe, so a stale sibling checkout should fail loudly instead of
producing quietly wrong answers).

```
pastree-server --version          -> pastree-lsp-server 0.5.0 (PasTree 0.2.1, built 2026-08-20 13:15)
initialize response, serverInfo   -> {"name":"pastree-lsp-server","version":"0.5.0","pastreeVersion":"0.2.1"}
first line of the log             -> the --version banner
IDE Build tab                     -> package 0.5.0, built ... / server ready: pastree-lsp-server 0.5.0 (PasTree 0.2.1)
```

Both numbers are reported everywhere on purpose: "the server is 0.5.0" does not
tell you whether the resolver fix you are chasing is in it, and that fix lives
in PasTree. `pastreeVersion` is this server's own addition to `serverInfo`;
conforming clients ignore members they do not know.

**A version mismatch between the two halves means a stale binary, not an
incompatibility.** Both are built from one commit by `build.bat`, so the RAD
Studio client checks the server's reported version for *equality* with its own
and warns in the Build tab when they differ. That is a stricter check than the
"at least version X" it replaced — and a necessary one: the loose check failed
to notice a fresh package running against the previous day's exe, because the
stale exe still satisfied the minimum.

## Building

`build.bat` builds all of it — server (Win64), RAD Studio package (Win32), the
four test harnesses — and runs the harnesses. **RAD Studio must be closed**: a
running IDE holds the `.bpl`, and a live LSP session holds
`pastree-server.exe`.

One script for both halves is deliberate. The failure it prevents is exactly a
half-rebuild, and the equality check above only means something if a normal
build produces both halves from the same commit.

## What the log contains

`PASTREE_LSP_LOG`, or the `logFile` initializationOption (which wins). Per
completed analysis it writes the **parse record**: every unit in the closure
with the full path of the file that was picked for it, and every diagnostic -
not only the open documents' (those are what `publishDiagnostics` sends, which
is the right scope for squiggles and the wrong one for debugging: an `F1027` on
a unit nobody has open is exactly what breaks navigation in the file they do
have open). The configuration block lists the search paths themselves, not just
how many.

Every navigation line names **both ends**:

```
definition: PasTreeDemo.Main.pas(133,11) 'TArray' -> System.pas(589,3)
```

A line that gave only the target could not be checked - `TArray` resolving into
`System.Generics.Collections` looks reasonable until you know the click was on
`TArray<T>`, which belongs in `System.pas`.

## Requirements

- Delphi 12+ (Win64 target)
- The PasTree repo checked out as a sibling: `..\object-pascal-tree`, at
  `cMinPasTreeVersion` or newer
