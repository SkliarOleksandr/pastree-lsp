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
  the server and which project to analyze. A relative `projectFile` is
  resolved against the first workspace folder, so a workspace's own
  `.vscode/settings.json` can name it portably. **Without `projectFile` the
  open files are the analysis roots and nothing in their `uses` resolves** -
  every unit an F1027 - so when the workspace contains a `.dproj` the
  extension warns at activation and offers the setting (2026-09-03, after a
  live run where the symptom looked like a search-path bug).
- `ideLibraryPaths` (default on), `ideVersion` - the IDE's Library paths
  and Environment Variables, read from the registry by `ide.js` and handed
  to the server as extra `searchPaths` and as `libraryPaths`. This is what
  the RAD Studio package gets from ToolsAPI (`GetIDELibraryPaths`) and an
  editor has to fetch itself: the RTL/VCL SOURCE is on the IDE's Browsing
  Path and on no project search path, and third-party libraries reach the
  Search Path through IDE-only `$(macro)` overrides. `ide.js` also seeds the
  server process with rsvars.bat's `BDS`/`BDSLIB`/... variables so a
  `.dproj`'s `$(BDS)`-relative paths expand. Keep `ide.js` in step with
  `GetIDELibraryPaths`: a difference is a unit that resolves in one client
  and not the other. Measured on this machine: 139 paths for Win32.
- `logFile`, `logUnits`, `logDetail` - the same logging knobs the RAD Studio
  Settings dialog exposes; see the root SPEC's "What the log contains". No
  `logFile` means no file log at all - the `pastree-lsp.log` beside a
  `.dproj` is the RAD Studio session's, not this one's.
- `moduleRedoLimit` - the incremental-analysis ceiling; 0 keeps PasTree's
  measured default (128).
- `searchPaths`, `defines` - extra values appended after the project's own
  (and, for paths, before the IDE's).

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

**Syntax colouring, added 2026-09-03**, in two layers that split the work by
who knows what:

- **The TextMate grammar** (`syntaxes/objectpascal.tmLanguage.json`, scope
  `source.pascal`) paints what a lexer can know: comments, `{$...}`
  directives, strings (`''` escapes, `#nn` codes, `^A`, `'''` multiline),
  numbers (`$hex`, `%bin`, `_` separators), the 64 reserved words of spec
  B.4.1 and the routine/type name at a declaration. It paints while the user
  types, before any server answer, and it is what colours the ```pascal
  fence in the server's own hover card - the language contributes `pascal`
  and `delphi` as aliases so that fence name resolves here.

  The directive words (spec B.4.2) are contextual and the grammar treats
  them so, because `var dynamic: Integer;` is legal and must NOT light up:
  routine directives only after `;` or `)`, visibility words only at the
  start of a line and not followed by `:`/`=`/`,`, property specifiers only
  inside a `property ... ;` span (plus a bare `default;` after it). Known
  misses: a directive word on a continuation line, and `TA = TB` aliases,
  which are left to the semantic layer so a `CName = OtherConst` line is not
  coloured as a type.

  Identifiers are deliberately unscoped: a regex cannot tell a field from a
  local from a type, and guessing wrong is worse than grey.

- **`textDocument/semanticTokens`** (full + range, standard token types
  only, so no `semanticTokenScopes` map is needed) colours every identifier
  by what the server resolved it to, and greys `$IFDEF`'d-out lines as
  `comment`. `vscode-languageclient` registers the provider from the
  capability; `extension.js` has nothing to add. The root SPEC's Implemented
  table has the legend, and the reason there is no delta form.

`language-configuration.json` carries the comment markers, brackets and
auto-closing pairs, and `$REGION` folding. No `indentationRules`: block
completion (`onTypeFormatting`) already re-indents the caret line and places
the caret, and a second indenter would fight it.

**Not done:**

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
