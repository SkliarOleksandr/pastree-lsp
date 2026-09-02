# PasTree LSP - VS Code client specification

Status: 2026-09-02, draft with little content yet - the extension is a thin
LSP client and most of its story lives in the root [SPEC.md](../../SPEC.md)
(the protocol) and `extension.js` (the wiring). This file is where its own
decisions accumulate as it grows past that.

Companion to the repository root's [SPEC.md](../../SPEC.md) (protocol
coverage, versioning policy, architecture) and
[clients/rad-studio/SPEC.md](../rad-studio/SPEC.md) (the sibling client's
capability spec). This document owns only what is specific to the VS Code
extension.

## Versioning

Shares one version with the server and the RAD Studio package -
`PasTreeLspVersion` in `../../source/PasLsp.ProductVersion.pas`, mirrored into
`package.json`'s `version` field on every bump (nothing compiles that file, so
it has drifted before - see the root SPEC's Versioning section for the policy
and why the patch component exists).

## What it configures

`contributes.configuration` (`pastree.*` in `package.json`) is the whole
surface today:

- `serverPath`, `projectFile`, `platform`, `config` - how to find and start
  the server and which project to analyze.
- `logFile`, `logUnits`, `logDetail` - the same logging knobs the RAD Studio
  Settings dialog exposes; see the root SPEC's "What the log contains".
- `moduleRedoLimit` - the incremental-analysis ceiling; 0 keeps PasTree's
  measured default (128).
- `searchPaths`, `defines` - extra values appended after the project's own.

`configurationDefaults` turns on `editor.formatOnType` for `[objectpascal]`,
which block completion (`textDocument/onTypeFormatting`) needs to fire at
all - VS Code sends nothing on `\n` otherwise.

## Status

**Verified live** against the demo project's 197-unit closure: go-to-definition,
find-all-references, outline, hover and diagnostics.

**Shipped alongside the extension, not through LSP:** a `snippets` contribution
for statement skeletons (`while`/`for`/...), added 2026-08-31 as VS Code's
answer to block completion not covering bare headers - deliberately a
template, not a protocol feature.

**Not done:**

- **Syntax colouring.** VS Code has no built-in highlighter for
  `objectpascal`, so XMLDoc and code fences render in grey. Two candidate
  fixes are in the root SPEC's Tier 2 list: a TextMate grammar (fast, cosmetic)
  and `textDocument/semanticTokens` (the real fix, resolver-backed). Neither
  is implemented.
- **Marketplace packaging.** The extension ships today as a locally-built
  `.vsix` (`private: true` in `package.json`); it is not published.
- Everything else in the root SPEC's Tier 2/3 lists that is not
  RAD-Studio-specific applies here too, once the server answers it.

## Building

```
cd clients/vscode
npm install
npx vsce package
```

Produces `pastree-vscode-<version>.vsix`. Requirements: Node.js, and the
server binary built separately (`build.bat` at the repository root) - the
extension does not bundle or build it. Point `pastree.serverPath` at the built
`pastree-server.exe`, or rely on the extension's own default lookup (see
`extension.js`) if one is configured.
