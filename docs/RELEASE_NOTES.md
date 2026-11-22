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

## Fixed: the scrollbar takes a click on its track

Clicking the bar beside the pill did nothing, so the only way through a long body was to grab the pill or
wheel over the content. A press anywhere on the bar now **jumps the pane so the pill lands under the
pointer**, and keeps sliding it while you hold and drag — clamped at both ends, so a click past the end
just goes to the end.

The bar also has a visible **groove** now, and the toolkit draws it from the theme, so it follows the
palette instead of being a colour each screen had to remember to set.

## New: a Pre-req and a Post-res script on every request

The request editor has a **Scripts** tab with two phases, the way Postman's does, in a small Lua-flavoured
language written for this app — no JavaScript engine, no browser, no download:

```lua
local jsonData = pm.response.json()
-- Set the token as a variable
pm.environment.set("token", jsonData.access_token)
print("Access Token: " .. jsonData.access_token)
```

- `local`, `if … then … elseif … else … end`, `..` to join text, `a.b` / `a["k"]` / `a[0]` into the answer,
  `+ - * /` and the usual comparisons.
- `pm.response.json()`, `.text()`, `.code`, `.headers.get(name)`; `pm.environment.get/.set`,
  `pm.variables.get`, and `pm.globals` (the same store); `print()` and `console.log()`.
- A variable lands in the **active workspace environment**, is created when it is new, and is written to
  `environment.json` at once — so the next request can send `{{token}}`.
- **Pre-req** runs before the request leaves; if it cannot run, the send stops with the line that failed.
  **Post-res** runs on the answer and never hides it; what `print` said sits under the field, and the
  status line says what the run did ("Post-res script set 1 variable in Dev.").
- Loops and function definitions are out of scope on purpose, and a script that uses them says so on its
  own line instead of quietly doing nothing.

## New: colour emoji

An emoji the UI font does not carry — 😀 👍 🎉 — is now drawn as the **colour image** its font has, instead of an empty
box. The toolkit reads all three ways a font stores one (Segoe UI Emoji's COLR/CPAL layers, Noto Color Emoji's embedded
PNGs, Apple Color Emoji's sbix records), falls back to the platform's emoji face only for a codepoint the text face has
no glyph for, and measures it at its own width so nothing overlaps.

- A request named `grin 😀 party 🎉` shows both emoji in colour in the sidebar, the tab and the title field.
- Text that the app's face *does* have stays monochrome: `→`, `·` and a plain `❤` are not hijacked by the emoji font.
- Windows draws them today (D3D11, one untinted quad per emoji). macOS and Linux still draw the mask path — their text
  paths rasterise a whole run rather than per glyph — so there the box stays until that backend lands.

## Fixed: a Windows-pasted body no longer ends every line in an empty box

A body pasted from Windows ends its lines `\r\n`, and the editor drew the carriage return along with the text. The
font has no glyph for it, so every line ended in one tofu box. A line now ends **before** the CR: it is still in the
text, it is just not painted, and the caret and the selection agree with what is on screen.

## New: the request body and a JSON response are coloured like code

The **Body** tab and the response pane are one component now — a **CodeEditor**: the same text field as before, plus
the rules of the language it is showing. Keys, strings, numbers, `true` / `false` / `null` and punctuation each get
their own tone, so a nested answer reads as structure instead of a wall of text.

- Editing is unchanged: click, select, **Shift+click**, Ctrl/Cmd+Z, copy, and the caret are all the same field's.
- The colouring follows the text as it is typed — a half-written body is coloured too, not only a valid one.
- Only JSON is coloured. An HTML or plain-text answer stays the colour of the text, because rules that do not apply
  should not be painted.
- A megabyte body is scanned once when it changes, never once per frame.

## Fixed: the Windows binary starts on every machine, not just the one that built it

The 0.1.19 Windows zip could exit the moment it was run, with **0xC000001D** (illegal instruction):
Zig had compiled it for the CPU of the runner that produced it, and that runner had vector
instructions the downloading machine does not. Release builds now pass `-Dcpu=baseline`, so the
archive is built for the oldest CPU each platform promises instead of the one that happened to
compile it.

If 0.1.19 would not start for you, install again — 0.1.20 is the same code with a portable binary.

## Fixed: Shift+click extends a selection in every text field

Clicking in a field placed the caret, and a second click **with Shift held** replaced it instead of
extending the run — so the one gesture everyone uses to select up to another point did nothing. Both
halves of a click had to learn about Shift:

- The press keeps the caret's anchor when Shift is held and the field already owns the keyboard,
  instead of re-anchoring at the new point.
- The release (the click itself) extends to the clicked point instead of collapsing the run it had
  just made.
- Shift+arrows, Shift+Home/End and Shift+Ctrl+arrow already worked, and are now pinned by tests so
  they stay working.

A plain click still collapses the selection, and a Shift+click on a field that does not yet have the
keyboard just places the caret.

## Fixed: the installer now says which version it installed, and a release always matches its tag

`releases/latest` had been pointing at **v0.1.13** while the code kept moving, because one platform leg of a
tag run went past the job's 30-minute limit and the publish job was skipped — so `curl … | sh` kept
reinstalling an old build and nothing said so. Now:

- The release legs have an hour, Homebrew's slow self-update is off, and a tag whose binary disagrees with
  the tag number fails the build instead of shipping.
- Both installers resolve the tag **before** downloading and print it, and then run
  `<install dir>/kurirw --version` — so the last line of an install is the version you actually have.
- `kurirw --version` answers without opening a window, which is what that check reads.
- On Windows the installer refuses to unpack over a running `kurirw.exe` (a locked file) instead of
  leaving a half-installed folder behind.


## Assets

| platform | file | notes |
|---|---|---|
| macOS arm64 | `kurirw-macos-arm64.tar.gz` | self-contained: the archive carries the handful of libraries it needs in `lib/`. Unsigned, so the first launch wants right-click → **Open**, or `xattr -d com.apple.quarantine kurirw` |
| Linux x86_64 | `kurirw-linux-x86_64.tar.gz` | built on Ubuntu 24.04, so it wants glibc 2.39+; run it in a Wayland session with the pango/cairo and libcurl runtime libraries installed |
| Windows x86_64 | `kurirw-windows-x86_64.zip` | self-contained: `Send` works over http and https, with TLS through Windows' own certificate store |

## New: right-click a text field for Cut, Copy, Paste and Select All

Every input in the app — the URL bar, a header value, the body editor, and the response body itself — now
raises a card of its own on a right click:

- **Cut, Copy, Paste, Select All**, always, in that order, so the one thing a text control must have never
  depends on the app remembering to wire it.
- **A right click takes the caret where it landed** and keeps a selection it landed inside, so you can select
  a run, right-click it and Copy without losing the highlight first.
- **The response body keeps all four rows** but Cut and Paste are dimmed: a response is not something you edit.

The component stays app-agnostic: a field's `menu` adds rows after those four, and the app is told which of
its OWN rows was picked, so Kurir can grow the card without the toolkit knowing what "Format JSON" means.

## Fixed: dragging the divider no longer scrolls the result body

The 6 pt line between the editor and the response resized the panes — and also scrolled the body under it, in
steps, so the answer appeared to jump. A body field is as tall as its whole content, so its box reaches above
the scroll viewport, and a press on the line looked like a press on its text: the caret followed the pointer and
the pane chased the caret. A press now only counts where the text actually shows, a drag belongs to whatever
grabbed it, and a reveal only follows a caret moved while no button is held.

## Fixed: the body no longer goes blank when you scroll away from the caret

Click in the body (which puts the caret on that line) and then scroll: the pane used to keep drawing the lines
around the CARET instead of the lines around the VIEWPORT, so a 5 MB answer looked empty with a few stray lines
at the top edge. The editor now draws the lines you are looking at, and only pulls the caret's own line in on
the frame that has to scroll it into view.

## Fixed: scrolling away from a selection no longer snaps back

Selecting text in the response body and then scrolling used to fight itself: the pane jumped back to the top
on the next frame, because a focused editor asked to keep its caret on screen every frame. That reveal now
runs only when the caret actually moves, so the wheel wins until you type or click again.

## Fixed: the response body stays in its pane, and scrolls under the trackpad

A big answer used to paint its text over the sidebar and past the window edge, and the pane refused to
scroll while the pointer was over the body. Both were engine bugs, both are fixed in the toolkit rather
than worked around here:

- **Nested clips now intersect.** A text field wraps its own value in a clip that is as wide as its
  content and as tall as every line, and the renderer used to *replace* the scroll box's clip with it —
  so the lines the pane draws just outside the viewport (and every line a sideways scroll had pushed
  left) landed on the sidebar. A clip now narrows the clip around it, on every backend.
- **A clip no longer swallows the wheel.** Every clip element counts as a scroll container, so the
  field's horizontal-only clip was taking the vertical wheel and dropping it. The wheel now goes to the
  deepest container that can actually move, which is the pane.

Right-click the body and **Inspect element** still shows it is the same read-only field; nothing in
Kurir changed shape.

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
