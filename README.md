# PasTree LSP

Object Pascal code intelligence out of process, built on
[PasTree](https://github.com/SkliarOleksandr/object-pascal-tree). One product,
three pieces: a Win64 analysis server speaking the
[Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
over JSON-RPC 2.0, a RAD Studio IDE package, and a VS Code extension - both
clients of the same server and the same protocol.

## The server (`pastree-server.exe`)

- Analyzes an Object Pascal project (`.dproj`/`.dpr`) out of process and
  answers standard LSP requests over it: go to definition/declaration,
  find references, the decl-impl toggle, outline, hover, diagnostics,
  completion, signature help, rename, workspace symbol search, and more.
- Runs an edit through incremental reanalysis of the one changed module
  instead of rebuilding the whole closure, whenever the change qualifies.

**Install / requirements**

- Delphi 12+ (Win64 target), and the PasTree repo checked out as a sibling:
  `..\object-pascal-tree`, at `cMinPasTreeVersion` or newer.
- `build.bat` at the repository root builds the server (and the RAD Studio
  package and test harnesses in the same pass - one script produces both
  halves of the product, which is what makes the version-equality check
  between them meaningful). RAD Studio must be closed while it runs.
- No separate install step: `pastree-server.exe` lands in `out\` and is run
  by whichever client is configured to find it.

**Status / docs**

Phases 1-2 of the protocol are complete and exercised live; most of phase 3
has landed too. Full protocol coverage, architecture, key decisions and their
costs, and the incremental-reanalysis mechanism are in
[SPEC.md](SPEC.md).

## The RAD Studio IDE package (`clients/rad-studio/`)

- A thin LSP client over ToolsAPI, replacing RAD Studio's own DelphiLSP-based
  navigation with the server's answers.
- Ships Find References, Go to Declaration/Ctrl+Click, the decl-impl toggle,
  rename, class completion (Ctrl+Shift+C: missing bodies and property
  accessors), prototype sync, and block completion - each with its own
  on/off switch in Tools > PasTree > Settings.

**Install / requirements**

- Built by the same `build.bat` as the server (Win32 designtime BPL).
- The IDE must be pointed at a `pastree-server.exe`: either
  `setx PASTREE_LSP_SERVER "C:\path\to\out\pastree-server.exe"` (picked up on
  the next IDE start - the usual development setup), or copy the exe next to
  the package's own `.bpl` (no restart needed, picked up on the next request).
- Restart RAD Studio after every rebuild of the package - hot reload
  (Uninstall/Install) is unreliable here; see
  [docs/diagnosing.md](docs/diagnosing.md).

**Status / docs**

Working and confirmed in a running IDE; most features are verified against a
real multi-thousand-unit project, not only the harnesses. What each ToolsAPI
surface could still present, and what it would cost, is in
[clients/rad-studio/SPEC.md](clients/rad-studio/SPEC.md); what the package
does today, file by file, is in
[clients/rad-studio/README.md](clients/rad-studio/README.md).

## The VS Code extension (`clients/vscode/`)

- A standard LSP client (`vscode-languageclient`) for the `objectpascal`
  language, plus statement-skeleton snippets and the `editor.formatOnType`
  default that block completion needs.
- Proof that the protocol is genuinely editor-agnostic, not just shaped
  around the RAD Studio client's needs.

**Install / requirements**

- `cd clients/vscode && npm install && npx vsce package` produces a `.vsix`;
  install it into VS Code from there. Requires Node.js and the server binary
  built separately (`build.bat` at the repository root) - the extension does
  not bundle or build it.
- Point the `pastree.serverPath` setting (or the relevant `pastree.*` config)
  at the built `pastree-server.exe` and at the target project.

**Status / docs**

Verified live against the demo project's 197-unit closure: go-to-definition,
find-all-references, outline, hover and diagnostics all work. Syntax
colouring (no TextMate grammar or `semanticTokens` yet) is the known gap.
Extension-specific notes are in [clients/vscode/SPEC.md](clients/vscode/SPEC.md).

## Requirements at a glance

- Windows, Delphi 12+ (Win64 target) to build the server and the RAD Studio
  package.
- The PasTree repo checked out as a sibling: `..\object-pascal-tree`.
- Node.js only if building the VS Code extension.

## More

- [SPEC.md](SPEC.md) - the protocol-side specification: architecture, why the
  analysis runs out of process, versioning policy, full protocol coverage,
  key decisions, and what the log contains.
- [clients/rad-studio/SPEC.md](clients/rad-studio/SPEC.md) - the ToolsAPI-side
  specification.
- [clients/vscode/SPEC.md](clients/vscode/SPEC.md) - the VS Code extension's
  own specification.
- [docs/diagnosing.md](docs/diagnosing.md) - procedures for symptoms that have
  already cost an investigation.
