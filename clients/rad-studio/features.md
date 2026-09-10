# What the RAD Studio plugin does

Everything below is one designtime package (`PasTreeIdePlugin.bpl`) talking to
`pastree-server.exe` over LSP. No analysis runs inside the IDE and no request
blocks the main thread: a command returns immediately and its result arrives on
a later main-thread turn, which is why answers can land after the caret has
moved. Every feature that replaces or adds to a native command has its own
on/off switch in **Tools > PasTree > Settings**.

The last section covers the features that are only reachable when you select
**PasTree** as the Insight Provider under Tools > Options > Editor > Source.

## Navigation

### Find Type Declaration

An editor local-menu command that jumps to the declaration of the identifier
under the caret, resolved by PasTree rather than by DelphiLSP. It handles the
three identities the server distinguishes - a symbol, a unit name in a `uses`
clause, and a compiler builtin - and reports plainly when the caret is not on
anything resolvable. The jump is history-aware, so Alt+Left and Alt+Right walk
back and forward through it like any other IDE navigation.

### Ctrl+Click navigation

Ctrl+Click on an identifier navigates to its declaration through the same
resolver as the menu command. It is a mouse hook on the editor, so it works
whatever the selected Insight Provider is - which is the point: RAD Studio gates
part of its editor UI on DelphiLSP being the provider, and this gives those
users PasTree navigation without giving up that slot. When PasTree *is* the
selected provider the hook stands down on its own, because the IDE's own click
chain already resolves through the plugin and two resolvers on one click would
make two history entries.

### Declaration/implementation toggle (Ctrl+Shift+Up/Down)

Jumps between a routine's interface declaration and its implementation body, and
back. It is the plugin's own resolver rather than the IDE's, so it follows the
same closure the rest of the analysis sees, including routines the native toggle
loses track of. Switched off, the keystroke is handed straight back to the IDE
and you get the native behaviour with nothing to unbind.

### The Find All submenu

Seven searches under one editor-menu entry, "Find All": References, Overrides,
Implementations, Descendants, Assignments, Creations, Destructions. All of them
run across the whole project group - not just the open unit and not just the
active project - and each reports into a Messages tab of its own, shaped alike:
one row per hit showing the source line in your live editor syntax colors with
the match highlighted, navigable on double-click, Enter and F8/Shift+F8, and a
title that counts the units searched so "did it only look at this file?" has an
answer on screen.

The items are greyed per caret, the way PasTree's own demo greys them: opening
the menu asks the server which of the seven apply where the caret is, with a
short time budget. If the server is busy or not up yet, every item stays
enabled and a wrong pick answers with a one-line message instead. One switch
on the Navigation tab of the settings covers the whole submenu.

#### References

Every use of the symbol under the caret, grouped by file: one header row per
file with a hit count, then the hits. The snippet text comes from the same
snapshot the server analyzed, so unsaved buffers still line up.

#### Overrides

With the caret on a class method, its whole VMT chain: the declaration that
introduced the slot, every override below it, any `reintroduce` (labelled as
such so it is not mistaken for an override) and any message handler. Call sites
are deliberately not rows - this is a hierarchy, not a reference search. On a
class property the same command answers the property's redeclaration chain
instead, since a bare `property Items;` republishing an inherited property is
the same property.

#### Implementations

With the caret on an interface method, every class that lists that interface.
A class that satisfies the method through an ancestor is reported on the
*ancestor's* declaration - the code that actually runs - with the listing class
named beside it. With the caret on the interface's own name, the answer is the
classes listing it, one row each. A class that lists an interface *extending*
this one is not a row: the interfaces below one are Descendants' answer, and
that class is Implementations' answer asked on the child.

#### Descendants

With the caret on a class or interface name, every type below it - and the tab
shows it as a tree: the type itself at the top, each descendant nested under
its direct ancestor, to any depth, every row naming its unit and line. For an
interface the rows are the interfaces extending it; the classes implementing
it are Implementations' answer.

#### Assignments

With the caret on a variable, field, parameter or a property with a `write`
specifier, every place it is written: the left side of `:=`, the counter of a
`for`, through a member chain or an index. The declaration is pinned first, as
in the References tab. A `var`/`out` argument and `Inc`/`Dec` are not rows yet.

#### Creations and Destructions

With the caret on a class name: every `TFoo.Create(...)` constructing exactly
that class, and every `X.Free`, `X.Destroy` or `FreeAndNil(X)` where X is
declared as exactly that class. Both are about the static type, so an instance
created through a descendant, or freed through an ancestor-typed variable or by
an owner, is not a row.

### IDE Insight symbol search (Ctrl+.)

Adds a "PasTree symbols" category to the IDE Insight search box, holding every
unit-level symbol and struct member of the analyzed closure. Picking a result
jumps to its declaration through the plugin's history-aware navigation. The
index is prefetched in the background and refreshed on a throttle, so the very
first Ctrl+. after the IDE starts may show nothing from PasTree - opening the
dialog is what kicks the prefetch off.

## Editing

### Rename (Ctrl+Shift+E)

Renames a routine, type, field, variable or parameter across the project,
applying the server's plan as text edits in the open buffers. Afterwards it
lists every edit it made in a Messages tab shaped like Find References, except
each line shows the source line *as it now reads* - because a rename that
touched fourteen places is otherwise indistinguishable from one that touched the
wrong fourteen. The new name is asked for through the server's `prepareRename`,
not read off the caret, so a dotted unit name is offered whole rather than one
segment of it.

Renaming a *unit* is deliberately refused with a message pointing at the Project
Manager. The server produces a correct plan for it, but the IDE performs a
rename of its own as soon as a changed `unit` clause is saved, and the two
collide in a different way on every run. Compiler builtins and `uses` spellings
the analysis has no rule for are refused the same way, in the server's own
words.

### Class completion (Ctrl+Shift+C)

Generates the missing implementation bodies for declared methods and property
accessors, replacing the native command rather than sitting beside it. Unlike
the native one, it also covers free routines declared in a unit's interface
section, and it is not gated on the Insight Provider selection. The edits are
applied as one undoable step and the caret lands on the empty body line of the
first routine generated; ordinary outcomes such as "nothing to implement" go to
the log rather than to the Build tab, which is read for compiler errors.

### Prototype sync

Runs as the first half of Ctrl+Shift+C: the signature under the caret is
mirrored onto the routine's other half, so an edited declaration and its
implementation stay in step. It is one gesture and one switch with class
completion on purpose - the two are the same thought from either end, one
writing a missing body and the other keeping an existing pair aligned. The edit
is a single undoable replacement, and the server decides what "mirrored" means,
including when to refuse.

### Block completion

Pressing Enter after an unclosed block opener inserts the matching closer on the
following line, cascading where the server's rules say it should. The decision
is a standard `textDocument/onTypeFormatting` request, so the IDE behaves the
same way the VS Code client does. The answer is dropped rather than misapplied
if you keep typing while it is in flight, and Enter itself is never swallowed -
if the IDE's own block completion is enabled in Editor Options, both would
insert, and this is the one with an off switch.

## Diagnostics and feedback

### Live error squiggles

Errors and warnings from the analysis are painted as wavy underlines directly in
the code editor, drawn by the plugin because the IDE answers editor error
queries natively and cannot be displaced. They follow the server's
`publishDiagnostics`, so they appear when the analysis lands and vanish when it
comes back clean, with no polling.

### Idle document sync

Everything you type is pushed to the server after a short pause in typing, which
is what makes the squiggles live rather than save-fresh. Only the buffers the
editor reported as modified are re-read on a pause - reading an editor buffer
costs about 15 ms per module whatever its size, so re-reading every open unit
was visible as a busy cursor on slower machines. The complete pass still runs in
front of any request, where completeness actually matters.

### Wait dialog for slow commands

Find References and Rename can sit for seconds on a project whose analysis is
still cold, so both show the IDE's own wait dialog while they run. It is the
IDE's dialog rather than an hourglass cursor because the answer is delivered on
the main thread - blocking that thread to wait for it would deadlock, and the
wait dialog's own message loop keeps delivering.

### Project log

The server writes `<project>-pastree-lsp.log` beside the `.dproj`, one per
project, and its stderr goes into the same file. It is the only place the real
reason for a failed navigation appears, since the editor can only say that
nothing resolved. "Advanced logging" adds the full configuration inventory -
every search path, define, namespace and unit alias the analysis was handed -
plus main-thread timing lines for each stage of the document sync, for
diagnosing a sluggish editor.

### IDE crash log

A vectored exception handler records every access violation in the IDE process,
on any thread, to `pastree-ide-crash.log` next to the project log. Each block
holds the faulting address, the address it tried to touch, and the return
addresses up the stack resolved to module plus offset - which is the difference
between "somewhere in the plugin" and one line of one unit. It only observes:
the IDE's own handling of the fault is unchanged, and faults the IDE swallows
silently are recorded just the same. This one is not gated by the logging
switch.

### Settings dialog and splash line

Tools > PasTree > Settings holds every switch above, on three tabs - Navigation,
Editing, Diagnostics - and is themed through the IDE's own theming services, so
it is not a bright form in a dark IDE. It also shows the compiled-in version and
the loaded BPL's own file timestamp, which together answer "is the package the
IDE loaded the one I just built?". The same question gets an earlier answer on
the startup splash screen, where the plugin adds one line naming itself and its
version.

### One server per project, configured from the `.dproj`

The plugin starts one server per open project and hands it the `.dproj`
verbatim, so main source, search paths, defines, namespaces and unit aliases all
come from the project file, evaluated with the same MSBuild logic the command
line tools use. What the project file cannot supply - the RTL, VCL and ToolsAPI
sources and every third-party library on the IDE's Search and Browsing paths -
is read out of the IDE and passed alongside. Switching the active project,
platform or build configuration restarts the server with fresh options, which
costs the next navigation a restart and nothing else.

## Through the Code Insight Manager

These are the features RAD Studio routes through whichever Insight Provider is
selected. They are inactive until you pick **PasTree** under
Tools > Options > Editor > Source > Insight Provider, and switching back to
DelphiLSP is the same combobox. Registration alone takes nothing over - the
manager only answers once it is selected - and that selection is the step people
most often miss.

Note the trade this asks for: RAD Studio gates part of its own editor UI on
DelphiLSP being the selected provider, which is exactly why Ctrl+Click
navigation above exists as an independent feature with its own switch.

### Code completion

Ctrl+Space and as-you-type completion answered from PasTree's own analysis of
the project closure, via `textDocument/completion`. The list is fetched once per
invocation and then filtered synchronously as you keep typing, because the IDE
calls the filter per keystroke on the main thread and a round trip there is not
allowed. Each entry carries its type text, class text and documentation for the
viewer to display.

### Browse (Ctrl+Click as the provider)

When PasTree is the provider, the IDE's own Ctrl+hover underline and Ctrl+Click
navigation resolve through the plugin. The difference from the standalone
Ctrl+Click hook is who does the work afterwards: here the plugin returns the
target and the IDE navigates and keeps the history itself, which is the better
arrangement of the two.

### Tooltip insight (hover)

Hovering an identifier shows the server's `textDocument/hover` answer as the
editor's own tooltip, reduced to plain text. That is the declaration of the
symbol under the pointer as PasTree resolved it, which is not necessarily what
the IDE's own parser would have said about the same word.

### Parameter insight

Ctrl+Shift+Space, and typing `(` or `,` inside a call, show the parameter hints
for the routine being called, from `textDocument/signatureHelp`. Overloads are
offered as the multiple entries the IDE's parameter viewer expects. The active
argument is recounted by the server on every request rather than tracked
client-side, so the emboldened parameter cannot drift out of step with the text.
