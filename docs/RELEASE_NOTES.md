# Kurir

A small, fast desktop app for sending HTTP requests — the everyday Postman job, without the account,
the cloud, or the browser tab.

## Install in one command

macOS and Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/ginwa123/kurirw/main/install.sh | sh
kurirw
```

Windows (PowerShell, no admin):

```powershell
irm https://raw.githubusercontent.com/ginwa123/kurirw/main/install.ps1 | iex
```

Or download the archive for your machine from the assets below and run the binary inside it.

## Assets

| platform | file | notes |
|---|---|---|
| macOS arm64 | `kurirw-macos-arm64.tar.gz` | self-contained: the archive carries the handful of libraries it needs in `lib/`. Unsigned, so the first launch wants right-click → **Open**, or `xattr -d com.apple.quarantine kurirw` |
| Linux x86_64 | `kurirw-linux-x86_64.tar.gz` | built on Ubuntu 24.04, so it wants glibc 2.39+; run it in a Wayland session with the pango/cairo and libcurl runtime libraries installed |
| Windows x86_64 | `kurirw-windows-x86_64.zip` | self-contained: `Send` works over http and https, with TLS through Windows' own certificate store |

## New: drop a row anywhere — beside a row, or inside a folder

- **Every drop is now a real move.** Onto the **top or bottom edge** of a row it takes that slot; onto
  the **middle of a folder or a collection** it goes *inside*, and the container opens to show it. One
  rule, one gesture: the third of the row you let go over is the answer.
- **Cross-folder moves work.** Dragging a request out of one folder and onto a line in another was
  refused before; it now carries the request across, and the sidebar selects what moved so the status
  line can say where it went ("Moved Request 1 into Folder 2").
- **The folder glyph is back**, and a method chip sits where the folder is for a request row, so a
  folder and its contents read as one column.
- **The tree looks the way it did before it became a component:** `v` / `>` carets at twelve points,
  four points of gutter, an accent bar on the selected row, and a slightly heavier label on a
  container.

## New: drag to reorder, and a calmer selection

- **Drag a request or a folder onto a sibling** in the sidebar and it takes that slot. The rule is
  deliberately narrow: siblings reorder among themselves, and dropping into a different folder is
  refused with a message rather than guessed at.
- **Selecting text no longer scrolls the pane.** A drag that starts on text used to scroll the
  response body 1:1 with the pointer, which fought the selection; now it only selects.

## New: a right-click menu on every request

Right-click a request in the sidebar and it offers **Rename**, **Duplicate** and
**Delete** — on the row you clicked, not on whatever happened to be selected.
Rename puts the keyboard in the name field with the whole name selected, so the
first keystroke replaces it; Duplicate makes a real copy (headers, body and all)
named "… copy" and selects it; Delete removes just that row. The menu closes on
Escape, on a click outside, and after an action.

## New: the response body is selectable text

The body used to be a list of drawn lines: readable, but you could not select a
value out of it or copy anything. It is now a read-only text editor — click to
place the caret, drag (or double-click a word) to select, Cmd/Ctrl+A for all of
it, Cmd/Ctrl+C to copy — and typing into it does nothing, because a response is
not something you edit. Works the same on a 4.9 MB answer as on a one-line one:
the pane only draws the lines you can see.

## New: curl in, curl out

- **Import a `curl` command.** Copy one from a terminal, a bug report or a colleague's message, then
  **+ New → From cURL**. The method, URL, headers, body and `-u` credentials become a request named
  after its own URL. Line continuations, quotes, `curl.exe`, `-G`, `-I`, `--json` and the usual noisy
  flags (`-sSL`, `-o`, `--max-time`, …) are all understood.
- **Copy a request as a `curl` command.** The **cURL** button beside Send puts the request you are
  looking at on the clipboard as a single command — method, every enabled header and the body — ready
  to paste into a shell or a bug report.

Both directions are tested: a command becomes a request in the tree, and that request copies back out
to a command that parses back to the same thing.

## Windows: Send works now

The previous Windows build linked a stand-in for the HTTP library, so every request failed. This one
does not: it links a **real, statically compiled libcurl** (curl 8.10.1, built with `zig cc` for
`x86_64-windows-gnu`), with **Schannel** as its TLS backend. That means:

- `https://` uses the Windows certificate store — no OpenSSL DLL to ship, no CA bundle to update.
- The library is inside the `.exe`; there is nothing to install and no DLL to lose.
- CI proves it on a real Windows runner on every push: it starts a local HTTP server and sends a real
  request to it, then sends one to `https://example.com/` — through the same transport the app uses.

## Build from source

```sh
git clone https://github.com/ginwa123/kurirw && cd kurirw
zig build --fetch                      # glinlandui + kabelweb, pinned by commit
zig build -Doptimize=ReleaseFast       # the production binary the releases ship
./zig-out/bin/kurirw
```

macOS wants `brew install curl openssl@3`; Linux wants the Wayland/EGL/GLES3 + pango stack plus
`libcurl4-openssl-dev` and `libssl-dev`. The exact list is in `.github/workflows/ci.yml`, which builds
and tests all three platforms on every push.
