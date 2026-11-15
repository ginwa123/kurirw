#!/bin/sh
# Kurir — install the latest release in one command.
#
#   curl -fsSL https://raw.githubusercontent.com/ginwa123/kurirw/main/install.sh | sh
#
# It downloads the archive for this machine from the latest GitHub release, unpacks it, and puts
# `kurirw` in ${KURIR_INSTALL_DIR:-$HOME/.local/bin}. No sudo, no build, no Docker.
# Set KURIR_VERSION=v0.1.0 to pin a release instead of taking the latest.
set -eu

repo="ginwa123/kurirw"
version="${KURIR_VERSION:-latest}"
dest="${KURIR_INSTALL_DIR:-$HOME/.local/bin}"

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

os=$(uname -s 2>/dev/null || echo unknown)
cpu=$(uname -m 2>/dev/null || echo unknown)

case "$os" in
    Darwin) platform="macos" ;;
    Linux) platform="linux" ;;
    *) die "Kurir ships macOS and Linux binaries here; on $os build it with 'zig build'." ;;
esac

case "$cpu" in
    arm64 | aarch64) arch="arm64" ;;
    x86_64 | amd64) arch="x86_64" ;;
    *) die "unknown CPU '$cpu'." ;;
esac

# The asset names the release publishes. An Intel Mac build does not exist yet: say so instead of
# downloading nothing and failing on tar.
if [ "$platform" = "macos" ] && [ "$arch" != "arm64" ]; then
    die "no Intel macOS build yet — build it with 'zig build -Doptimize=ReleaseSafe'."
fi
if [ "$platform" = "linux" ] && [ "$arch" != "x86_64" ]; then
    die "no $arch Linux build yet — build it with 'zig build -Doptimize=ReleaseSafe'."
fi

asset="kurirw-$platform-$arch.tar.gz"
if [ "$version" = "latest" ]; then
    url="https://github.com/$repo/releases/latest/download/$asset"
else
    url="https://github.com/$repo/releases/download/$version/$asset"
fi

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t kurir)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

say "Kurir: downloading $asset"
curl -fsSL "$url" -o "$tmp/$asset" || die "could not download $url"

# GNU tar and bsdtar both read .tar.gz; macOS ships bsdtar.
tar -xzf "$tmp/$asset" -C "$tmp" || die "could not unpack $asset"

# An archive may carry runtime libraries next to the binary (the macOS build bundles curl + openssl),
# so the whole payload is copied, not just the executable.
mkdir -p "$dest" || die "could not create $dest"
cp "$tmp/kurirw" "$dest/kurirw" || die "could not write $dest/kurirw"
chmod 755 "$dest/kurirw"
if [ -d "$tmp/lib" ]; then
    mkdir -p "$dest/lib"
    cp "$tmp/lib/"* "$dest/lib/" || die "could not write $dest/lib"
fi

say ""
say "installed  $dest/kurirw"

case ":$PATH:" in
    *":$dest:"*) ;;
    *)
        say ""
        say "note: $dest is not on your PATH. Add it with one of these:"
        say "      echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc   # zsh"
        say "      echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc  # bash"
        ;;
esac

say ""
say "run it with:  $dest/kurirw"
