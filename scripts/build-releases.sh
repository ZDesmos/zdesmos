#!/bin/sh
# Cross-compiles zdms for every architecture zdesmos-package supports
# (src/core/arch.zig), naming each output to match Architecture.toString()
# exactly -- e.g. "zdms-x86_64", "zdms-aarch64-musl" -- so install.sh's
# architecture detection can find the right one without guessing.
#
# Usage: ./scripts/build-releases.sh [output-dir]
# Requires: zig (whatever version this project currently targets -- see
# build.zig.zon's minimum_zig_version). Run from the project root.

set -eu

out_dir="${1:-releases}"
mkdir -p "$out_dir"

# name -> zig target triple. Run `zig targets` if any of these don't
# match what your zig accepts -- target triple naming has shifted between
# Zig versions, and this wasn't verified against a compiler.
#
# KNOWN GAP: armv6l and armv7l both map to the generic "arm-linux-*"
# triple below, which produces the *same* binary for both -- Zig
# distinguishes v6 from v7 via an explicit -Dcpu=<model> flag (e.g.
# something like -Dcpu=arm1176jzf_s for v6, cortex_a7 for v7), but I
# can't give you the exact model strings without a compiler to check
# `zig targets` against. If you actually need both, run `zig targets`
# yourself and add -Dcpu=<model> to those two lines below.
targets="
x86_64:x86_64-linux-gnu
x86_64-musl:x86_64-linux-musl
aarch64:aarch64-linux-gnu
aarch64-musl:aarch64-linux-musl
i686:x86-linux-gnu
armv7l:arm-linux-gnueabihf
armv7l-musl:arm-linux-musleabihf
armv6l:arm-linux-gnueabihf
armv6l-musl:arm-linux-musleabihf
"

for entry in $targets; do
  name="${entry%%:*}"
  triple="${entry#*:}"
  echo "==> $name ($triple)"
  zig build -Doptimize=ReleaseFast -Dtarget="$triple" --prefix "$out_dir/$name-build"
  cp "$out_dir/$name-build/bin/zdms" "$out_dir/zdms-$name"
  rm -rf "$out_dir/$name-build"
done

echo
echo "Built binaries in $out_dir/:"
ls -la "$out_dir"/zdms-*

echo
echo "Checksums (paste these into your release notes / a checksums.txt):"
sha256sum "$out_dir"/zdms-* 2>/dev/null || shasum -a 256 "$out_dir"/zdms-*
