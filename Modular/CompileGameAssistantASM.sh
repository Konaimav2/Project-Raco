#!/bin/sh
# Builds the assembly Game Assistant daemon: static, no crt, no libc.
# RacoGameAssistant.c stays untouched; this replaces only the built binary.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="${1:-$ROOT/Modules/CoreSys/RacoGameAssistantService}"
# Tool overrides let the NDK build (CompileCusingNDK.sh) use its own toolchain.
CC="${CC:-clang}"
NM="${NM:-llvm-nm}"
STRIP="${STRIP:-llvm-strip}"
READELF="${READELF:-llvm-readelf}"

"$CC" --target=aarch64-linux-android24 \
    -nostdlib -static -fuse-ld=lld \
    -Wl,-e,_start -Wl,--gc-sections -Wl,--build-id=none \
    -o "$OUT" \
    "$ROOT/Sources/RacoGameAssistantASMMain.S" \
    "$ROOT/Sources/RacoGameAssistantASM.S"

# Check symbols before strip removes the table.
if [ -n "$("$NM" -u "$OUT")" ]; then
    echo "error: undefined symbols in $OUT:" >&2; "$NM" -u "$OUT" >&2; exit 1
fi
"$STRIP" "$OUT"

# Refuse to hand out a binary that still leans on a dynamic loader or libc.
if "$READELF" -d "$OUT" | grep -q NEEDED; then
    echo "error: $OUT has NEEDED entries" >&2; exit 1
fi
if "$READELF" -l "$OUT" | grep -q INTERP; then
    echo "error: $OUT has a PT_INTERP" >&2; exit 1
fi
echo "built $OUT"
