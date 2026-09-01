# The XMLDoc demo (VS Code)

A three-file project whose only job is to show what the server does with
`///` documentation, in an editor that renders markdown properly. The RAD
Studio side shows the same text in a plain hint window; VS Code is where you
can see whether the *rendering* is right.

## Run it

1. `build.bat` in the repository root, so `out\pastree-server.exe` is current.
2. Open **this folder** (`clients\vscode\demo`) in VS Code - not the repository
   root, because `.vscode\settings.json` here is what points the server at
   `XmlDocDemo.dpr`.
3. The extension must be installed (`clients\vscode`, or its `.vsix`). Its
   version equals the server's; a mismatch in the "PasTree LSP" Output channel
   means one of the two was not rebuilt.
4. Open `XmlDocDemo.dpr` and hover the identifiers in `begin...end`.

The paths in `settings.json` are absolute and assume `c:\Repos\pastree-lsp` -
edit them if the checkout lives elsewhere. The server's own log lands in
`pastree-lsp.log` beside the project (git-ignored).

## What to look at

| Hover this | What it demonstrates |
|---|---|
| `Greet` | the full set: summary, parameters, returns, raises - each its own block |
| its `AName` param text | a param written across three source lines collapses to one paragraph |
| `TGreeter` | a type's own block, and `<c>`/`<seealso>` reduced to their text |
| `TPersonName` | summary **and** remarks, in the renderer's fixed order |
| `EscapesAndOddities` | `&lt;` `&amp;` unescaped, and a bare `<` left as prose |
| `UntaggedDoc` | a block with no tags at all is the summary |
| `DocAboveAnAttribute` | an attribute between the doc and the declaration is stepped over |
| `ThisIsNotDocumented` | a blank line breaks attachment - this one has NO docs, on purpose |
| `CAnswer` | a const documents like anything else |
| `GGreeter.` (completion) | `documentation` rides with every row, not only with hovers |

## Where the pieces live

- Rendering: [`source/PasLsp.XmlDoc.pas`](../../../source/PasLsp.XmlDoc.pas) -
  raw `///` run in, display text out. No markdown emphasis anywhere, because
  the RAD client shows the same string in a plain hint window.
- The raw block comes from PasTree (`DeclDocComment`, plan §8D); the engine
  deliberately does no XML at all.
- Pinned by `clients\rad-studio\tests\LspClientSmoke.dpr`, sections 5b and 5c.
