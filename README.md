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

Phase 1 skeleton works end-to-end: stdio framing, `initialize`/`shutdown`/
`exit`, full-sync `didOpen`/`didChange`/`didClose` (overlay buffers with
versions), and `textDocument/definition` over an analyzed project closure.
Build with `build.bat` (dcc64); smoke-tested by feeding a framed session to
`out\pastree-server.exe` and checking the definition locations.

The full specification — architecture, protocol phases, key
decisions and their costs, order of work — is in [SPEC.md](SPEC.md).

The PasTree-side prerequisites (versioned overlay buffers and mid-pass
cancellation in the analysis) landed in the PasTree repo on 2026-08-16.

## Why out-of-process

- Large projects need more address space than a 32-bit IDE can offer —
  analysis of a multi-thousand-unit project runs comfortably only on Win64.
- An analyzer crash must not take the IDE down.
- The same executable serves editor-agnostic LSP clients for free.

## Requirements

- Delphi 12+ (Win64 target)
- The PasTree repo checked out as a sibling: `..\object-pascal-tree`
