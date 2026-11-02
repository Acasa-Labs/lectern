#!/bin/sh
# Builds Lectern for Apple silicon and Intel and joins them into one binary, whose path it prints.
# Each chip is built on its own with SwiftPM's native build system: the newer one (a two-chip build,
# and the default from Swift 6.4) fails on SwiftTerm's build plugin, for Intel or on older Xcode.
set -e
cd "$(dirname "$0")/.."

for arch in arm64 x86_64; do
    swift build -c release --arch "$arch" --build-system native >&2
done
OUT=".build/universal"
mkdir -p "$OUT"
lipo -create -output "$OUT/Lectern" \
    "$(swift build -c release --arch arm64 --build-system native --show-bin-path)/Lectern" \
    "$(swift build -c release --arch x86_64 --build-system native --show-bin-path)/Lectern"
echo "$OUT/Lectern"
