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
| Windows x86_64 | `kurirw-windows-x86_64.zip` | see the Windows note below |

## Windows note

This `.exe` was built on a machine with no curl/openssl development files, so it links a **stub**
libcurl: the app starts, edits, imports and exports, but **Send cannot reach the network** in this
build and reports a failed request instead. A real Windows transport needs a static libcurl
(`vcpkg install curl[openssl]:x64-windows`) — building from source on such a machine works today with
`zig build -Doptimize=ReleaseSafe`.

## Build from source

```sh
git clone https://github.com/ginwa123/kurirw && cd kurirw
zig build --fetch                      # glinlandui + kabelweb, pinned by commit
zig build -Doptimize=ReleaseSafe
./zig-out/bin/kurirw
```

macOS wants `brew install curl openssl@3`; Linux wants the Wayland/EGL/GLES3 + pango stack plus
`libcurl4-openssl-dev` and `libssl-dev`. The exact list is in `.github/workflows/ci.yml`, which builds
and tests all three platforms on every push.
