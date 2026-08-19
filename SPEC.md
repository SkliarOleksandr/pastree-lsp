# PasTree LSP Server — specification

Status: draft, 2026-08-15. This is the design agreed before any code exists.

## Goal

One out-of-process analysis server, `pastree-server.exe` (Win64), that speaks
the Language Server Protocol (JSON-RPC 2.0). It serves two kinds of clients
with the SAME protocol:

1. the RAD Studio IDE plugin (`c:\Repos\pastree-ide-plugin`), reduced to a
   thin LSP client over ToolsAPI;
2. standard editors — VS Code, Neovim, anything with an LSP client.

We deliberately do NOT build a private RPC for the plugin first and LSP later:
that is the same protocol written twice. LSP is the native protocol from day
one; the plugin is just its first client.

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

## Protocol scope

### Phase 1 — one feature end-to-end

- transport: stdio (named pipe as a fallback option for the IDE)
- `initialize` / `initialized` / `shutdown` / `exit`
- `textDocument/didOpen`, `didChange` (full sync first), `didClose`
- `textDocument/definition`

### Phase 2 — parity with the current plugin

- `textDocument/references` (the three-identity model: symbol / unit /
  builtin, as in the PasTree Find References work)
- incremental `didChange`
- `$/cancelRequest` honored end-to-end (requires PasTree cancellation)

### Phase 3 — beyond the plugin

- `textDocument/publishDiagnostics` — error-tolerant mode is the default,
  exactly as in the library; strict member checks stay opt-in via server
  configuration, mirroring the existing switch chain
- `textDocument/documentSymbol`, `hover`
- custom methods under `pastree/…` for anything LSP cannot express
  (e.g. a uses-graph query) — additive, never required by standard clients

### Explicit non-goals (for now)

- completion, rename, formatting, semantic tokens
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

1. (PasTree repo) overlay buffers + cancellation in the facade.
2. Server skeleton: JSON-RPC loop, lifecycle, didOpen/didChange, `definition`.
3. LSP client layer in the IDE plugin; move Goto Declaration onto it.
4. `references`; retire the in-process analysis path in the plugin.
5. `publishDiagnostics` from the error-tolerant analysis.
6. Validate with VS Code as a second client — the proof that no IDE-specific
   assumption leaked into the protocol.

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
