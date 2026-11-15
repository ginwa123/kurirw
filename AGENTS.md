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
5. **MVVM is the law.** Only `view_model.zig` writes state; `view.zig` declares and raises intents;
   `app.zig` holds no widget code; `main.zig` is the only `pub fn main`.
6. **The models are pure.** Nothing under `src/model/` may import a widget, a window, or a draw
   call. That is what lets every rule in them be tested without a display.

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
src/model/        postman.zig, store.zig, http.zig — pure data, pure Zig
src/state.zig     the state as a value + label helpers
src/view_model.zig  the only writer: intents, the arenas, the input fields
src/view.zig      declaration only
src/app.zig       store + theme + start() + content()
src/main.zig      window + Host + key chain
src/e2e_test.zig  the acceptance path, headless
```

## Rules that are easy to get wrong

- **A JSON string must be owned by the document arena.** `postman.setString`, `urlValue` and the
  `new*` constructors copy every string they are given (`own`). Skipping that copy leaks a dangling
  slice into the document, and `persist()` then serializes freed memory — which `std.json` reports
  as an array of bytes, not as a crash.
- **`std.json.ObjectMap` is unmanaged.** Every mutation takes an allocator, and it must be the
  document arena, never `gpa`. Mutating a *copy* of the map drops the size/len bookkeeping.
- **`view_arena` is reset on every rebuild.** Anything the frame points at must be allocated from it
  after the reset, or be borrowed from `doc_arena`. Intents run **before** the frame, so a reset in
  an intent is safe.
- **A click context must outlive the declare.** `RowScope` / `HeaderScope` / `LineScope` are stack
  values passed to a `box`, whose children callback runs synchronously — that is fine. A callback
  registered with `click_registry` must point at model-owned memory (`vm.header_ctxs`), never at a
  declare-time stack value.
- **Element ids must be unique per frame.** `frame.elementId(prefix, i)` for anything per-row.
  A duplicate id is invisible in review and shows up as a Clay `duplicate_id` log line, which fails
  every test that reaches it.
- **Hairlines land on the device grid.** A focused text field draws a 1-px caret at
  `box.x + pad + measure(prefix)`; a fractional `box.x` (an auto-width button before the field)
  trips `glinlandui audit: hairline_off_grid`, which is an error log and fails the suite. Give the
  widgets before a field a fixed width (the method bar is `56` each for exactly this reason).
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
