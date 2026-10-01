#!/bin/bash
# Build ViewTreeProbe.dylib — iOS-Simulator dylib that dumps the app's own
# UIView hierarchy on request, without a debugger attach.
#
# Loaded into simulator-launched apps via DYLD_INSERT_LIBRARIES, armed by
# `SimctlSimulatorInjection` alongside the other injected dylibs (they share
# the variable — see `InjectedDylibs`).
#
# House pattern of VirtualMotion/VirtualNetwork: one ObjC source set, fat
# build, linker-adhoc signing that is NEVER re-applied post-build.
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=ViewTreeProbe.dylib

# Fat, so it works on both Apple silicon and Intel hosts. The
# `-target …-simulator` triple is what stamps Mach-O LC_BUILD_VERSION
# platform=7 (iOS-Simulator), which the simulator's dyld requires.
build_slice() {
    local arch="$1"
    xcrun clang \
        -arch "$arch" \
        -isysroot "$SDK" \
        -target "${arch}-apple-ios17.0-simulator" \
        -dynamiclib \
        -framework Foundation \
        -framework UIKit \
        -fobjc-arc \
        -Wall \
        -install_name "@rpath/${OUT}" \
        -Wl,-adhoc_codesign \
        -Wl,-headerpad_max_install_names \
        -I Sources \
        -o "ViewTreeProbe.${arch}.dylib" \
        Sources/ViewTreeProbe.m
}

# Fat by default, so one dylib serves both Apple silicon and Intel hosts.
# `BAGUETTE_INJECTED_ARCHS` narrows that to a single slice, which is what
# Homebrew needs (`brew audit` rejects universal binaries). One slice skips
# `lipo` — the slice *is* the product.
ARCHS=${BAGUETTE_INJECTED_ARCHS:-"arm64 x86_64"}

SLICES=()
for arch in $ARCHS; do
    build_slice "$arch"
    SLICES+=("${OUT%.dylib}.${arch}.dylib")
done

if [ "${#SLICES[@]}" -eq 1 ]; then
    mv "${SLICES[0]}" "$OUT"
else
    xcrun lipo -create "${SLICES[@]}" -output "$OUT"
    rm "${SLICES[@]}"
fi

# Modern `ld` ad-hoc signs each slice with the `linker-signed` flag set, and
# `lipo -create` preserves those signatures. iOS 26+ simulator dyld accepts
# `linker-signed` adhoc but REJECTS a post-build `codesign --force --sign -`
# with `code:codesigning(3) invalid-page(2)`. So we deliberately do NOT
# re-sign here — same rule as VirtualCamera/build.sh.

echo "Built: $(pwd)/$OUT"
codesign -dv "$OUT" 2>&1 | grep -E "Format|CodeDirectory|Signature" | head -3
