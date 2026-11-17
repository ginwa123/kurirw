# AGENTS.md — kurirw

Rules for anyone (human or agent) changing Kurir.

## The non-negotiables

1. **macOS works first.** Before a change is called done, `zig build` and `zig build test` must pass
   **here**. Do not describe a build as working unless you ran it and saw it exit 0.
2. **The linter is zginlint.** `zig build zginlint:check` must report **zero findings** — no
   baseline, no suppression.
3. **A comment block is at most ONE line.** As many single-line comments as you like; a blank line
   or a line of code ends a block. This includes `//!` and `///`.
4. **No `.zig` file may exceed 3000 lines.** Split the module instead of growing the file.
5. **MVVM is the law.** Only a `view_model.zig` writes state; a `screen.zig` declares and raises
   intents; `app.zig` holds no widget code; `main.zig` is the only `pub fn main`.
6. **`data/` and `domain/` are pure.** Nothing under them imports a widget, a window, or a draw call.
   That is what lets every rule in them be tested without a display.
7. **A panel imports the shell, never another panel.** What two panels share is
   `ui/shell/session.zig`; the shell imports the panels. That is the direction that keeps it a DAG.

## Verify before you report

```sh
zig build                  # the app + the smoke CLI
zig build test             # unit + headless E2E
zig build zginlint:check   # 0 findings
zig build lines:check      # no .zig over 3000 lines
zig fmt --check build.zig src
```

## Layout

```
src/di/container.zig               every dependency, built once (path, FileStore, client, dialogs, theme)
src/domain/repository/workspace.zig  the document vtable: load, save
src/domain/usecase/                send_request, import_collection, export_collection
src/data/{model,remote,local,repository}/  postman, kabelweb, the file, the dialogs, the FileStore
src/ui/shell/                      session, view_model, screen, scope, widgets, actions
src/ui/{sidebar,editor,response}/  view_model.zig (state + intents) + screen.zig (declaration)
src/ui/state.zig                      the state as a value + label helpers
src/app.zig, src/main.zig          the Activity and the entry point
src/font.zig                       the embedded face (Source Sans 3), installed before the first frame
src/e2e_test.zig                   the acceptance path, headless
```

## Rules that are easy to get wrong

- **A JSON string must be owned by the document arena.** `postman.setString`, `urlValue` and the
  `new*` constructors copy every string they are given (`own`). Skipping that copy leaks a dangling
  slice into the document, and `persist()` then serializes freed memory — which `std.json` reports
  as an array of bytes, not as a crash.
- **A write is `Session.persist`, not `Session.commit`.** `commit()` marks the selected path unsaved and
  rebuilds the snapshot; only `vm.save()` (Ctrl/Cmd+S, or "Save and quit") writes the file. A test that
  reloads the document must call `vm.save()` first, and the tree's dot is `TreeRow.dirty`.
- **`std.json.ObjectMap` is unmanaged.** Every mutation takes an allocator, and it must be the
  document arena, never `gpa`. Mutating a *copy* of the map drops the size/len bookkeeping.
- **The ViewModel must not move after `start()`.** Each panel holds `*Session`, and each field's
  callback holds a pointer into its panel. The store keeps it in place; the unit harness allocates it.
  A by-value copy leaves every panel writing into a document nobody reads.
- **`view_arena` is reset once per snapshot.** Anything the frame points at must be allocated from it
  after the reset, or be borrowed from `doc_arena`. The snapshot runs in `uiState()`, before the frame.
- **A click context must outlive the declare.** `RowScope` / `HeaderScope` / `LineScope` are stack
  values passed to a `box`, whose children callback runs synchronously — that is fine. A callback
  registered with `click_registry` must point at model-owned memory (`vm.editor.header_ctxs`), never
  at a declare-time stack value.
- **A row's click context lives in a fixed array on the panel** (`vm.sidebar.row_ctxs[512]`). A click is
  dispatched on a later frame than the one that registered it, so an `ArrayList` of contexts would move
  and leave the registered pointer on freed memory. The tree hands each row's context menu
  `&row_ctxs[i]`, and the panel builds those menus in its snapshot.
- **A menu card is as wide as its anchor.** `+ New` is 84 points wide with four short labels and the
  workspace menu hangs from the whole header row; a card anchored to a 26-point button clips its rows.
- **Element ids must be unique per frame.** `frame.elementId(prefix, i)` for anything per-row.
  A duplicate id is invisible in review and shows up as a Clay `duplicate_id` log line, which fails
  every test that reaches it.
- **A box read mid-declare does not exist yet.** An element's `bounding_box` is only real once the layout
  closes, so a component that needs its own geometry asks for it: `scroll.revealAfterLayout(id, target)`
  queues the reveal and `Host` applies it right after `endLayout`. Reading `frame.bounds` inside the
  declare of the same frame returns null or a zero box.
- **A caret is a floating bar, which a scroll's clip cannot cut.** A multiline field draws its caret only
  while the caret's line is inside the viewport (`input.caretLineOnScreen`), or the bar paints over the
  pane below.
- **The panes' sizes are the widgets'.** `components.sidebar` owns the sidebar's width and
  `components.split` owns the response's height; both mutate during the declare, so `uiState()` refreshes
  `sidebar_width` / `response_h` after the frame instead of `snapshot()` before it. Read them during the
  declare (`vm.responseHeight()`), or the pane lags a frame behind the pointer.
- **The left panel's width is the widget's, not the model's.** `components.sidebar` owns it (`vm.sidebar.state`)
  and mutates it during the declare, so `UiState.sidebar_width` is refreshed in `uiState()`, not in `snapshot()`.
  The panel's content is pinned to that width (`.w = .fixed(width)`) because a `.grow` column inside it is
  widened by text metrics — which pushes a toolbar button's centre under the grab line and trips
  `glinlandui audit: hit_target_not_self`.
- **A cross-frame gesture needs the Driver's pointer bookkeeping.** `frame.ptr_down` / `ptr_press_x` are set by
  the platform adapters AND by `testing.Driver`'s press/move/release helpers; without them a drag in an E2E
  test reports `ptr_down == false` and silently does nothing.
- **Hairlines land on the device grid.** A focused text field draws a 1-px caret at
  `box.x + pad + measure(prefix)`; a fractional `box.x` (an auto-width button before the field)
  trips `glinlandui audit: hairline_off_grid`, which is an error log and fails the suite. Give the
  widgets before a field a fixed width (the method bar is `56` each for exactly this reason).
- **The font has Latin-1 and arrows, not geometric shapes.** `▾`, `▸` and `▼` render as tofu boxes; the
  tree and the method dropdown use `v` / `>` for exactly this reason, and the "gear" is `...`. There is no
  icon font, so an icon is DRAWN: a folder is a 5x2 tab over a 12x8 body. A border does not follow a
  corner radius here, so a ring (a magnifier) cannot be drawn at all — use a hint instead of a shape that
  would read as a missing glyph. Check a glyph in a screenshot before shipping it.
- **The face is the app's, not the toolkit's.** `font.zig` embeds Source Sans 3 and installs it through
  `glinlandui.text.installFaceBytes`; a new binary entry point that skips `font.install` draws IBM Plex Mono,
  and the widths it measures are a different layout, so the E2E has to install it too (it does, in `boot`).
- **The response body is never truncated**, and the pane never declares one text run per line of it: the lines
  are indexed in `data/model/body.zig` and only the viewport's range is drawn (top spacer, lines, bottom spacer).
  Re-indenting a megabyte happens on the request's own thread, not the frame's.
- **Nothing long runs on the frame thread.** A request goes through `data/remote/request_job.zig`
  (`std.Io.concurrent` + an atomic `finished`), never a direct `perform` in an intent. A test that sends
  must `settle()`: the answer arrives on a later frame. The real window's pump is `setAnimating`, wired in
  `main.zig`; headless, the pump is a no-op and the driver's frames do the polling.
- **Tests never touch the network.** `http.Fake` answers requests, `Dialogs` answers the file
  panels. `zig build smoke` is the only place a socket is opened.
- **`build.zig` is linted too.** A comment in it that spells a banned pattern (a bare
  `catch unreachable`, `std.log.warn`) is a finding. Describe the rule, do not quote the code.

## kabelweb

`client.Method` has no `OPTIONS` upstream; this repo relies on a three-line addition in
`../kabelweb/src/client/request.zig` (enum member, `parse`, `asString`). Re-apply it if that
checkout is refreshed.

## Commits

One logical change per commit, and the message says *why*. Anything that needs more than one line
of comment belongs in the commit body or the README.
