# PasTree LSP Server

An out-of-process language server for Object Pascal, built on
[PasTree](https://github.com/SkliarOleksandr/object-pascal-tree): one Win64
executable (`pastree-server.exe`) speaking the
[Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
over JSON-RPC 2.0.

It serves two kinds of clients with the same protocol:

- the RAD Studio IDE plugin
  ([pastree-ide-plugin](https://github.com/SkliarOleksandr/pastree-ide-plugin)),
  reduced to a thin LSP client over ToolsAPI;
- standard editors — VS Code, Neovim, anything with an LSP client.

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

`PasLsp.Version.pas` holds this server's semver and `cMinPasTreeVersion`, the
oldest sibling PasTree checkout it works with. The check runs at startup rather
than being a comment, because PasTree is linked into this exe: a stale sibling
checkout otherwise turns into wrong answers instead of a clear failure.

Both numbers are reported in three places, deliberately - the answer to "does
this build have the fix I need" is usually the PasTree one, not the server's:

```
pastree-server --version          -> pastree-lsp-server 0.4.1 (PasTree 0.2.1, built 2026-08-20 12:40)
initialize response, serverInfo   -> {"name":"pastree-lsp-server","version":"0.4.1","pastreeVersion":"0.2.1"}
first line of the log             -> the --version banner
```

`pastreeVersion` is this server's own addition to `serverInfo`; conforming
clients ignore members they do not know.

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
