# Working in this repository

`README.md` is what the product does, `SPEC.md` the protocol side,
`clients/rad-studio/SPEC.md` the ToolsAPI side, `docs/diagnosing.md` the
procedures for symptoms that have already cost an investigation. This file is
the rules that apply to every change.

Every rule here is here because breaking it was silent. Keep the reasons when
editing this file - a rule with no reason gets "fixed" back.

## Do not commit until Alex has tested it

**Build, report, stop.** The commit waits for Alex to run it in a real IDE.
Exception: an explicitly autonomous session ("work autonomously", a scheduled
run), where committing is part of finishing.

Green builds do not cover the half of this product that lives inside RAD
Studio. On 2026-09-02 three defects passed a full build and were found by Alex
opening a project and clicking - and each had already been committed as fixed.

## English, plain hyphens, `local/` for working papers

**Everything written into this repository is in English** - specs, READMEs,
commit messages, comments, log lines. Conversation is in whatever language
suits; artifacts are not, because they outlive it and the next reader may be a
stranger or a future session.

**Only the plain hyphen `-`. Never an em dash (U+2014) or en dash (U+2013)**,
anywhere. They are non-ASCII, and `dcc32` on a legacy code page, `cmd.exe` and
the diff tools each render them differently. Sweep before committing:

```bash
git ls-files | xargs grep -l -e "$(printf '\342\200\224')" -e "$(printf '\342\200\223')"
```

Exactly one file must come back: `clients/rad-studio/tests/VersionSmoke.dpr`,
where the em dash is a test INPUT - the multi-byte character the encoding
checks are built on. (The bytes come from `printf` so this file stays ASCII;
`grep -P` refuses to run in Git Bash's C locale here.)

**Working documents go in `local/`, which is ignored** - audits, plans,
in-flight notes, logs sent in by users. A finished conclusion belongs in a
tracked document; the working paper that produced it does not. Same convention
in PasTree.

## Line endings: CRLF for everything Delphi and cmd.exe read

**`.pas`, `.dpr`, `.dpk`, `.inc`, `.dproj`, `.dfm`, `.bat` are CRLF. Docs
(`.md`, `LICENSE`) and the VS Code client (`.json`, `.js`, `.ts`) are LF.**
Declared in `.gitattributes`, identically in PasTree - keep the two in step.

A rule for **tools, not just people**: in Git Bash, `sed -i` and `perl -0pi`
READ through the crlf layer and WRITE without it, so an in-place edit converts
a whole Delphi source to LF even when the substitution touches no line ending -
and the index is LF for everything, so no diff ever shows it. RAD Studio then
re-saves its way and the next diff is the entire file instead of three lines.
`cmd.exe` can genuinely misparse an LF-only `.bat`, and every build goes
through one.

Two hooks catch it, both copied from PasTree:

- `.claude/hooks/eol-crlf.sh` restores CRLF after every Bash/Write/Edit
  (wired in `.claude/settings.json`).
- `.githooks/pre-commit` refuses a commit carrying such a file. Enable per
  clone: `git config core.hooksPath .githooks`.

Neither replaces looking - every `eol=crlf` row must read `w/crlf`:

```bash
git ls-files --eol | awk -F'\t' '$1 ~ /w[/]lf/ && $1 ~ /eol=crlf/ { print $2 }'
```

## One product, two halves, one version

The server (`pastree-server.exe`, Win64) and the package (`clients/rad-studio`,
Win32 designtime BPL) are one deliverable sharing `PasTreeLspVersion` in
`source/PasLsp.ProductVersion.pas`. The package checks at the handshake that
the server reports the *same* version; a difference means one binary was not
rebuilt.

**Bump the PATCH in every commit**, mechanically - MINOR for a substantial
change - and `clients/vscode/package.json` in the same edit, since nothing
compiles that file and it has drifted forty commits behind before. PasTree
follows the same rule for its own `PasTreeVersion`. Skipping the bump defeats
the mismatch check.

`cMinPasTreeVersion` in `source/PasLsp.Version.pas` is the floor for the
sibling PasTree. Raise it when a change depends on a library fix whose absence
would be silent rather than a compile error.

## Building

```
build.bat
```

Builds the server, the package and all five harnesses, then runs them. **It
must end with `all built, all harnesses passed`; anything else is a real
failure.** Use it rather than building halves separately - the version check
only means something if one build produces both.

- **RAD Studio must be closed.** A running IDE holds the `.bpl`, its LSP
  session holds `pastree-server.exe`; either gives a confusing "could not
  create output file".
- Requires `../object-pascal-tree` as a sibling. That checkout may be under
  edit by another session - check `git status` there before touching it, and
  never `git add -A`.
- After a rebuild, **restart the IDE** rather than Uninstall/Install; hot
  reload is unreliable and the symptom is a change that appears not to work.
- **Every `.dcu` goes to `out\dcu\win32` or `out\dcu\win64`**, never next to a
  source: the same units compile for both platforms and the names collide. A
  new compilation needs `-N0` (or `DCC_DcuOutput`) pointing there. A stray
  `.dcu` beside a `.pas` means something was built outside the scripts.
- The IDE builds this server differently from `build.bat` - see
  `docs/diagnosing.md` if it works one way and not the other.

## The package's one hard invariant

`clients/rad-studio` links `rtl, vcl, designide` and exactly two units from
outside its directory - `PasLsp.ProductVersion` and `PasLsp.SourceText`, both
dependency-free by construction. **It must never link PasTree**: it is a
32-bit designtime package and PasTree is Win64-only, which is the whole reason
the analysis runs out of process. `tests/VersionSmoke` is the tripwire - a
Win32 program over both shared units, so it stops compiling if either gains a
dependency. A third shared unit is a real decision, not a convenience.

## Two traps in code that look like other bugs

**An empty scope has no lists.** `TSemaScope.Symbols` and `.Names` are lazy and
legally `nil`, so `LScope.Symbols.Count` is an access violation rather than an
empty loop. Check for `nil` before iterating any scope container, and cover a
new model-walking handler with a harness request - an uncovered
`documentSymbol` shipped this crash to a user on 2026-08-23.

**Assume a BOM.** Delphi writes UTF-8-with-BOM by default, so a leading BOM is
the common case and never content. Never hand-roll it: go through
`source/PasLsp.SourceText.pas` (`StripLeadingBom`, `TryReadTextNoBom`,
`FileHoldsText`), and put new rules about incoming text in that unit rather
than in a caller. Its header has the full story - one BOM made `IdentAt`
resolve nothing anywhere in a file while the log said only `no identifier at`.

## Where the answers are

- A failure a user reports: `pastree-lsp.log`, beside the `.dproj`. Then
  `docs/diagnosing.md`.
- Why the analysis is shaped as it is: `SPEC.md`. Do not re-derive it.
- Why the IDE half is shaped as it is: `clients/rad-studio/SPEC.md` and its
  `README.md`, which record the experiments that failed.
