# Working in this repository

`README.md` is what the product does, `SPEC.md` is the protocol-side
specification, `clients/rad-studio/SPEC.md` the ToolsAPI-side one. This file is
the short list of things that are easy to get wrong and expensive to rediscover.

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

- **RAD Studio must be closed.** A running IDE holds the `.bpl`; its live LSP
  session holds `pastree-server.exe`. Either one produces a confusing
  "could not create output file".
- Requires `../object-pascal-tree` checked out as a sibling (the server links
  PasTree; the package must never).
- After a rebuild, **restart the IDE** rather than Uninstall/Install — see
  `clients/rad-studio/README.md`; hot-reload of this package is not reliable and
  the symptom is a change that appears not to work.

## Expected test result

`LspClientSmoke` fails exactly two checks, both about a Cyrillic literal. That
is the known ANSI-vs-UTF-8 decode split documented in `SPEC.md`, it predates the
repository merge, and it is **not** a regression. Everything else passes. A run
that fails only those two is green in practice; anything else is new.

## Diagnosing "Ctrl+Click did nothing"

The editor only ever says `no identifier/declaration resolved at cursor`. The
real reason is in **`pastree-lsp.log`, in the same folder as the `.dproj` being
analyzed** (stderr beside it). It carries the search paths, every unit in the
closure with the full path of the file chosen for it, every diagnostic, and both
ends of every navigation. Read it before suspecting the resolver — the last two
failures of this kind were a search-path problem and a stale binary, neither of
which was visible from the editor.

## The package's one hard invariant

`clients/rad-studio` links `rtl, vcl, designide` and exactly one unit from
outside its directory: `PasLsp.ProductVersion`, which is dependency-free by
construction. **It must never link PasTree** — it is a 32-bit designtime
package and PasTree is Win64-only, which is the entire reason the analysis runs
out of process. `tests/VersionSmoke` is the tripwire: a Win32 program over the
shared version unit, so it stops compiling if that unit ever gains a
dependency.
