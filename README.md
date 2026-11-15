# Kurir

A Postman-style API client for the desktop: workspaces, collections, folders, requests, and a
response pane that shows what actually came back. Built with **Zig 0.16** on
[glinlandui](https://github.com/ginwa123/glinlandui) (Cocoa on macOS, Wayland on Linux, portable
and headless in tests) and sending through [kabelweb](https://github.com/ginwa123/kabelweb)'s
libcurl client.

```
Wireframe                          Kurir
┌───────────────┬──────────────────────────────────────────────┐
│ workspace 1/2 │  Request 1                        [ Delete ] │
│ + Collection  │  GET POST PUT PATCH DELETE HEAD OPTIONS       │
│ + Folder      │  [https://api.example.com/v1/items  ] [Send] │
│ + Request     │  Headers | Body                              │
│ Import Export │  ────────────────────────────────────────────│
│               │  Content-Type   application/json      ×      │
│ [ ] Payments  │                                              │
│   [>] Shop    ├──────────────────────────────────────────────┤
│     GET Items │  200 OK   42 ms   1.4 kB   [Body] [Headers]  │
│               │  {                                           │
│               │    "items": [ ... ]                          │
└───────────────┴──────────────────────────────────────────────┘
```

## Run it

Kurir needs its two sibling checkouts, because Zig 0.16 rejects absolute paths in `build.zig.zon`:

```sh
cd ..
git clone https://github.com/ginwa123/glinlandui.git glinlandui
git clone https://github.com/ginwa123/kabelweb.git   kabelweb
cd kurirw

zig build run          # the window
zig build test         # unit + headless E2E (47 tests)
```

`kabelweb`'s client is libcurl-backed, so the build wants a system `libcurl` + OpenSSL (Homebrew's
`curl` and `openssl@3` on macOS). The build probes for them and says which path it chose.

### Where your work is saved

Every edit is written immediately — there is no Save button.

| what | where |
|---|---|
| the document | `$KURIR_HOME/workspaces.json`, else `$HOME/.kurir/workspaces.json` |

```jsonc
{
  "format": "kurir/workspaces@1",
  "workspaces": [
    { "id": "ae6c…", "name": "My Workspace", "collections": [ /* Postman v2.1 collections */ ] }
  ]
}
```

Workspaces are **not** part of the Postman schema, so Kurir owns the wrapper and keeps each
collection inside it byte-for-byte as a Postman v2.1 document.

## Postman round-trip

The hard requirement of the spec is that import and export never lose fields, so a collection is
never converted into a typed struct that has to be able to represent everything: it is kept as a
`std.json.Value` tree (`src/model/postman.zig`) and edited **in place**. What that buys:

- `auth`, `event`, `variable`, `protocolProfileBehavior`, `description`, vendor keys, response
  bodies and anything else Kurir does not understand survive an export untouched.
- A typed view (`RequestView`, `method`, `url`, `headers`, `body`) is built only to *read*.
- A new collection, folder or request is created with the shape the schema asks for
  (`info._postman_id`, `info.schema`, `item[]`, `request.{method,header,url,body}`, `response[]`,
  `body.{mode:"raw", raw, options.raw.language}`).

The URL is written as the full object, not just a string: `raw`, `protocol`, `host[]`, `port`,
`path[]`, `query[]`. A file whose `url` is a plain string still imports.

`zig build test` proves it: a fixture with vendor fields is parsed, mutated, serialized and parsed
again, and every unknown field is asserted present.

## Architecture — MVVM, the same shape as `glinlandui/examples/todo`

```
src/
├── model/            pure data: no widgets, no window, no draw calls
│   ├── postman.zig   Postman v2.1 over std.json.Value — read, mutate, serialize, URL split
│   ├── store.zig     the workspaces wrapper, ids, and the file on disk
│   └── http.zig      one injectable Transport: a real kabelweb client, a fake for tests
├── state.zig         the state as a VALUE: Path, TreeRow, ResponseView, UiState, label helpers
├── view_model.zig    the ONLY writer. Every public fn is an intent; owns the fields and the arenas
├── view.zig          declaration only — boxes, buttons, fields, the tree, the response pane
├── app.zig           the Activity: the store, the theme, the composition. No widget code
├── main.zig          the only `pub fn main`: window, Host, key chain
├── root.zig          the module surface (`@import("kurirw")` is the whole app)
├── theme.zig         the palette: glinlandui `dragon` + one tone per HTTP method
└── e2e_test.zig      the acceptance path, driven headlessly through the real widgets
```

The rules the code keeps:

- **Only `view_model.zig` writes state.** A widget raises an intent (`.{ .f = onSend, .ctx = vm }`);
  the next frame draws whatever the model says.
- **`view.zig` never mutates.** It reads `scope.state` and declares.
- **No widget, no window, no draw call in `model/`.** The models are pure Zig and tested without a
  display, which is why `HTTP` is a `Transport` value and not a global client.
- **No network in any test.** `http.Fake` records the request and answers from a script;
  `Dialogs` does the same for the file panels. The real path is exercised by `zig build smoke`.

## The widgets Kurir had to write itself

- **The collection tree** is a `list` with a custom row: an expand caret, the method as a coloured
  label, then the name, indented by depth.
- **The body editor is the toolkit's field**, not a hand-rolled one: `components.input.Field` with
  `.multiline = true` types a line on Enter, keeps the caret on the line it belongs to (through
  glinlandui's per-line caret ids), and raises `on_submit` on Ctrl/Cmd+Enter, which is what sends.
  Kurir routes no key at all — the engine types into the focused field.
- **The method bar** is seven fixed-width buttons, one tone each, not a dropdown: a method is one
  click, and the colour is the thing you scan for.

## Commands

```sh
zig build                 # the app
zig build run             # the window
zig build test            # unit suite + E2E suite (headless, no display, no network)
zig build test-unit       # unit suite only
zig build smoke           # one REAL request through kabelweb (see below)
zig build zginlint:check   # zero findings or fix it
zig build lines:check      # no .zig file over 3000 lines
zig fmt --check build.zig src
```

`smoke` is how the real transport is proven without a window:

```sh
python3 -m http.server 8099 &
KURIR_SMOKE_URL=http://127.0.0.1:8099/ zig build smoke
KURIR_SMOKE_URL=https://example.com/       zig build smoke   # TLS via libcurl + OpenSSL
KURIR_SMOKE_URL=http://127.0.0.1:1/        zig build smoke   # clear "Connection refused"
```

## What v0.1 does, and what it deliberately does not

Done: workspaces (add / switch / rename / delete), collections, nested folders, requests, the
method bar, URL, header table (with an on/off per header), a raw JSON body, Send, status code,
reason, time, size, pretty-printed body, response headers, import, export, and autosave.

**Limits, on purpose, for v0.1:**

| limit | value | why |
|---|---|---|
| response shown | 256 kB | the body is text runs, not a download |
| request body | 64 kB | one field buffer |
| headers per request | 32 | one field pair each |
| tree rows | 512 | a flat array per frame |
| nesting | 8 levels | `state.Path` is a fixed-depth address |
| send | synchronous, 15 s timeout | see the roadmap |

## Roadmap (PRD §6) and where each lands

1. **Environments and variables** — `model/env.zig` (new) + `{{name}}` expansion in
   `postman.effectiveUrl`; the switcher goes in the sidebar strip, environment JSON in/out reuses
   `Dialogs` and `postman.parseTree`.
2. **Auth tab** — `postman.setAuth` beside `setHeaderKey`, applied in `http.Request` assembly;
   `request.auth` is already preserved by the round-trip.
3. **Params tab** — `postman.urlValue` already splits `query[]`; the table edits it and rebuilds
   `raw`.
4. **Body modes** — `postman.rawBody` is one branch; `form-data` / `urlencoded` / `binary` are
   siblings, and `http.Request` grows a content-type helper.
5. **History** — a ring in `store.zig` beside the wrapper, drawn as a second list in the sidebar.
6. **Saved examples** — `response[]` is already preserved; a store action appends to it.
7. **Tests and scripts** — `event[]` is preserved; a sandbox for assertions is the real work.
8. **Collection variables and descriptions** — `variable[]` and `description` are preserved;
   the UI is a tree-row edit plus a subtitle.
9. **Quality of life** — duplicate (copy a `Value`), drag-to-reorder (list `clicks` and insert),
   search (a filter over `rows`), copy as cURL (`http.Request` → string), cURL / OpenAPI import
   (a parser feeding `postman.newRequest`).
10. **Team features** — needs a backend; kabelweb already ships the server half.

The async send belongs with (1): today the click blocks for the request's duration, because the
toolkit has no cross-thread repaint request. The seam is `Transport` — a worker thread plus
`Window.setAnimating` on macOS, or a polled `Transport.poll`, changes `send` and nothing else.

## Dependencies, and the one local patch

| dep | why |
|---|---|
| `../glinlandui` | the window, the widgets, the headless E2E driver |
| `../kabelweb` | the HTTP client (libcurl): methods, headers, bodies, timeouts, TLS |
| `zginlint` (URL + hash) | the linter behind `zig build zginlint:check` |

**kabelweb patch:** `client.Method` shipped GET/POST/PUT/PATCH/DELETE/HEAD but not `OPTIONS`, which
this spec asks for. `/Users/ginwa/kabelweb/src/client/request.zig` gained `OPTIONS` in the enum,
`parse` and `asString` — three lines, and every verb goes through `CUSTOMREQUEST` so nothing else
changed. If that checkout is refreshed from upstream, re-apply it or OPTIONS stops being selectable.
