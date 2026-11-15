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
