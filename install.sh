#!/bin/sh
# Installs zdms by downloading the right prebuilt binary from a GitHub
# release and dropping it in /usr/local/bin -- a system-wide location, on
# purpose: zdms needs root for almost everything it does (it writes to
# install_root="/", /var/lib/zdms, /var/cache/zdms by default), so
# installing it somewhere only $USER's PATH sees it means `sudo zdms`
# fails with "command not found" the moment someone actually uses it,
# since sudo's PATH does not include a regular user's ~/.local/bin.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ZDesmos/zdesmos/main/install.sh | sh
#
# Env overrides:
#   ZDMS_REPO      GitHub "owner/repo" to fetch releases from
#                  (default: ZDesmos/zdesmos)
#   ZDMS_VERSION   release tag to install (default: latest)
#   ZDMS_INSTALL_DIR  where to place the binary (default: /usr/local/bin)
#   ZDMS_BASE_URL  fetch "$ZDMS_BASE_URL/zdms-<arch>" instead of a GitHub
#                  release -- for local testing, e.g. against
#                  `python3 -m http.server` serving a directory that has
#                  a file named zdms-x86_64 (or whatever your arch is):
#                    ZDMS_BASE_URL=http://localhost:8080 ./install.sh

set -eu

repo="${ZDMS_REPO:-ZDesmos/zdesmos}"
version="${ZDMS_VERSION:-latest}"
install_dir="${ZDMS_INSTALL_DIR:-/usr/local/bin}"
base_url="${ZDMS_BASE_URL:-}"

# --- detect architecture, matching src/core/arch.zig's Architecture enum ---

case "$(uname -s)" in
  Linux) ;;
  *) echo "zdms only supports Linux (spec: TARGET: Linux)." >&2; exit 1 ;;
esac

machine="$(uname -m)"
case "$machine" in
  x86_64|amd64) base_arch="x86_64" ;;
  aarch64|arm64) base_arch="aarch64" ;;
  i686|i386) base_arch="i686" ;;
  armv7l) base_arch="armv7l" ;;
  armv6l) base_arch="armv6l" ;;
  *)
    echo "Unrecognized architecture '$machine'." >&2
    echo "zdesmos-package builds for: aarch64, aarch64-musl, armv6l," >&2
    echo "armv6l-musl, armv7l, armv7l-musl, i686, x86_64, x86_64-musl." >&2
    exit 1
    ;;
esac

# musl vs glibc: presence of a musl dynamic linker, or "musl" in ldd's
# own version banner, is the standard tell.
libc="gnu"
if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
  libc="musl"
elif ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
  libc="musl"
fi

if [ "$libc" = "musl" ]; then
  arch="${base_arch}-musl"
else
  arch="$base_arch"
fi

echo "Detected: $arch"

# --- download ---

if [ -n "$base_url" ]; then
  url="${base_url%/}/zdms-$arch"
elif [ "$version" = "latest" ]; then
  url="https://github.com/$repo/releases/latest/download/zdms-$arch"
else
  url="https://github.com/$repo/releases/download/$version/zdms-$arch"
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

echo "Downloading $url"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url" -o "$tmp_file"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$url" -O "$tmp_file"
else
  echo "Need curl or wget to download zdms." >&2
  exit 1
fi
chmod +x "$tmp_file"

# Escalate with sudo only for the final move, only if actually needed --
# running the whole script as root (e.g. inside a container) skips this.
if [ -w "$install_dir" ] || { [ ! -e "$install_dir" ] && mkdir -p "$install_dir" 2>/dev/null; }; then
  mv "$tmp_file" "$install_dir/zdms"
elif command -v sudo >/dev/null 2>&1; then
  echo "$install_dir needs root to write to -- you may be prompted for your password."
  sudo mkdir -p "$install_dir"
  sudo mv "$tmp_file" "$install_dir/zdms"
  sudo chmod 755 "$install_dir/zdms"
else
  echo "Cannot write to $install_dir and no sudo available." >&2
  echo "Re-run with ZDMS_INSTALL_DIR set to a writable directory instead." >&2
  exit 1
fi
trap - EXIT

echo "Installed to $install_dir/zdms"

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    echo
    echo "$install_dir isn't on your PATH. Add this to your shell's rc file:"
    echo "  export PATH=\"$install_dir:\$PATH\""
    ;;
esac

"$install_dir/zdms" --version
