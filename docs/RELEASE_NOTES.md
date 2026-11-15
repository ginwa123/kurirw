# Kurir 0.1.0

A lightweight Postman-style API client: workspaces, collections, folders and requests, sent through
libcurl, stored as Postman Collection v2.1 JSON.

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

Or download the archive for your machine from the Assets below and run the binary inside it.

## Assets

| platform | file | notes |
|---|---|---|
| Linux x86_64 | `kurirw-linux-x86_64.tar.gz` | needs a Wayland session and the pango/cairo + libcurl runtime libraries |
| macOS arm64 | `kurirw-macos-arm64.tar.gz` | unsigned; on first launch use right-click → Open, or `xattr -d com.apple.quarantine kurirw` |
| Windows x86_64 | `kurirw-windows-x86_64.zip` | see the Windows note below |

## Windows note

The Windows build compiles and links against a **stub libcurl**, because the Windows runner has no
curl/openssl development files and the repository carries no vendored Windows archive. The app runs,
edits, imports and exports; **Send does not reach the network in this build** and reports a failed
request instead. A real Windows transport needs a static libcurl (vcpkg `curl[openssl]:x64-windows-static`)
and is the next piece of work. Building from source on a machine with vcpkg installed already works:
`zig build -Doptimize=ReleaseSafe`.

## Build from source

```sh
git clone https://github.com/ginwa123/kurirw && cd kurirw
zig build --fetch          # glinlandui + kabelweb, pinned by commit
zig build -Doptimize=ReleaseSafe
./zig-out/bin/kurirw
```

Linux needs the Wayland/EGL/GLES3 + pango stack and `wayland-scanner`; macOS needs
`brew install curl openssl@3`. The full list is in `.github/workflows/ci.yml`, which builds and tests
all three platforms on every push.
