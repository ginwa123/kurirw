# Kurir

A small, fast desktop app for sending HTTP requests — the everyday Postman job, without the
account, the cloud, or the browser tab.

![Kurir](docs/screenshot.png)

## What it does

- **Organise your requests.** Workspaces → collections → folders → requests. Switch workspace with one
  click, collapse a folder, find a request by typing part of its name or URL.
- **Send and read.** Pick a method (GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS), paste a URL, add
  headers and a JSON body, press Send. You get the status, the time, the size, the pretty-printed body
  and the response headers — and the last answer for each endpoint is kept while you look elsewhere.
- **It never freezes.** A request runs on its own thread, so the window keeps drawing while a slow
  server answers.
- **Your work is saved as you go.** No Save button, no "unsaved changes" dialog.
- **It speaks Postman.** Export a collection as Postman Collection v2.1, or import a real Postman file
  without losing the fields Kurir does not understand.

## Install

macOS and Linux, one command:

```sh
curl -fsSL https://raw.githubusercontent.com/ginwa123/kurirw/main/install.sh | sh
kurirw
```

Windows, one command (PowerShell, no admin):

```powershell
irm https://raw.githubusercontent.com/ginwa123/kurirw/main/install.ps1 | iex
```

Either installer fetches the right binary for your machine from the
[latest release](https://github.com/ginwa123/kurirw/releases/latest) and puts it on your PATH. You can
also download the archive yourself and run the binary inside it.

> macOS note: the build is not signed yet, so the first launch needs right-click → **Open**, or
> `xattr -d com.apple.quarantine kurirw`.
>
> Windows note: the Windows build cannot reach the network *yet* (it links a stand-in for the HTTP
> library, because the build machine has no Windows curl). Editing, importing and exporting work;
> sending is the next piece of work. Building it yourself with `vcpkg` installed gives you a working one.

## First five minutes

1. Press **+ New → Collection** on the left, name it anything.
2. Press **+ New → Request**, then paste a URL — try `https://jsonplaceholder.typicode.com/todos/1`.
3. Press **Send**. The response appears in the pane below; drag the line above it to make the pane
   bigger.
4. Switch to **Body** to type a JSON payload, or **+ Header** to add a header. Ctrl/Cmd+Enter sends
   from the body editor.
5. **+ New → Import** takes a Postman collection file. The `...` next to the workspace name exports one.

## Where your work is kept

One JSON file, written on every change:

| | |
|---|---|
| default | `~/.kurir/workspaces.json` |
| if `KURIR_HOME` is set | `$KURIR_HOME/workspaces.json` |

Back it up, `git init` it, or copy it to another machine — it is a plain file, and the collections
inside it are ordinary Postman v2.1 documents.

## Build it yourself

You need [Zig 0.16](https://ziglang.org/download/) and nothing else to start: the two libraries Kurir
uses are pinned in `build.zig.zon` and fetched for you.

```sh
git clone https://github.com/ginwa123/kurirw
cd kurirw
zig build run      # open the window
zig build test     # 75 tests: the model, the file, the UI, and a headless end-to-end run
```

System libraries, per platform:

- **macOS** — `brew install curl openssl@3`
- **Linux** — the Wayland/EGL/GLES3 + pango stack, plus `libcurl4-openssl-dev` and `libssl-dev`
  (the exact list is in `.github/workflows/ci.yml`)
- **Windows** — nothing to install for a build; for a *working HTTP client* you also want
  `vcpkg install curl[openssl]:x64-windows`

Every push runs the same three-platform CI: build, the full test suite, the linters, and a ReleaseSafe
binary for each platform. A `v*` tag publishes those binaries as a release.

## How it is built

Zig 0.16, with the user interface on [glinlandui](https://github.com/ginwa123/glinlandui) — a small
retained-mode toolkit with its own Cocoa, Wayland and Win32 backends — and HTTP through
[kabelweb](https://github.com/ginwa123/kabelweb)'s libcurl client. The code is split the way the UI is
(sidebar / editor / response, each with its own view model and screen) and the document layer never
imports a widget, which is what lets the whole thing be tested headlessly.

Architecture, the Postman round-trip rules, the widget choices and the known limitations live in
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## License

MIT.
