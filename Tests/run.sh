#!/bin/sh
# Unit tests for the assembly Game Assistant helpers, then a check that the
# daemon binary is static and libc-free.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T="${TMPDIR:-/data/data/com.termux/files/home/temp}/raco-asm-tests"
mkdir -p "$T"

clang -O2 "$ROOT/Tests/gameassist_asm_test.c" \
    "$ROOT/Sources/RacoGameAssistantASM.S" \
    -o "$T/gameassist_asm_test"

WA_TEST_DIR="$T" "$T/gameassist_asm_test"

# Daemon binary: no dynamic section entries, no interpreter, no undefined symbols.
BIN="$T/RacoGameAssistantService"
sh "$ROOT/Modular/CompileGameAssistantASM.sh" "$BIN" >/dev/null
NEEDED=$(llvm-readelf -d "$BIN" | grep -c NEEDED || true)
INTERP=$(llvm-readelf -l "$BIN" | grep -c INTERP || true)
echo "BINARY NEEDED=$NEEDED INTERP=$INTERP size=$(wc -c < "$BIN")"
[ "$NEEDED" = 0 ] && [ "$INTERP" = 0 ]
