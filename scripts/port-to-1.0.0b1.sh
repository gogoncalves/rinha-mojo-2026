#!/usr/bin/env bash
# Mechanical search-replace pass to migrate the 0.x-style source
# files to Mojo 1.0.0b1 idioms. NOT a complete fix - manual edits
# are still required for:
#   - register_passable("trivial")  → conformance to TrivialRegisterPassable trait
#   - SIMD method .bitcast/.max     → bitcast/max free functions from std.memory / builtin
#   - external_call("foo", ...)     → @extern("foo") def foo(...) abi("c") -> Ret: ...
#   - UnsafePointer[T].alloc(n)     → libc_malloc(n).bitcast[T]()
#   - StaticTuple                    → InlineArray or hand-rolled lookup
#   - String indexing  v[0]         → v.unsafe_ptr()[0]  (UInt8)
#
# Usage:  ./scripts/port-to-1.0.0b1.sh src/main.mojo
set -euo pipefail

FILE="${1:?usage: $0 path/to/file.mojo}"

# In-place edits, BSD/macOS-compatible (sed -i '').
SED_INPLACE=(sed -i '')

# Lexical-but-safe substitutions:
"${SED_INPLACE[@]}" 's/^alias /comptime /'                                   "$FILE"
"${SED_INPLACE[@]}" 's/^    alias /    comptime /'                           "$FILE"
"${SED_INPLACE[@]}" 's/^fn /def /'                                           "$FILE"
"${SED_INPLACE[@]}" 's/^    fn /    def /'                                   "$FILE"
"${SED_INPLACE[@]}" 's/@parameter$/comptime/'                                "$FILE"
"${SED_INPLACE[@]}" 's/    @parameter$/    comptime/'                        "$FILE"
"${SED_INPLACE[@]}" 's/        @parameter$/        comptime/'                "$FILE"
"${SED_INPLACE[@]}" 's/UnsafePointer\[\([A-Za-z0-9_]*\)\]/UnsafePointer[\1, origin=MutExternalOrigin]/g' "$FILE"

echo "Mechanical pass done on $FILE."
echo "Remaining manual edits required:"
echo "  - @register_passable(\"trivial\")  →  struct S(TrivialRegisterPassable):"
echo "  - external_call(\"foo\", ...)      →  @extern(\"foo\") def foo(...) abi(\"c\")"
echo "  - SIMD value.bitcast[...]         →  bitcast[...](value)"
echo "  - SIMD value.max(other)           →  max(value, other)"
echo "  - UnsafePointer[T].alloc(n)       →  libc_malloc(n).bitcast[T]()"
echo "  - StaticTuple                      →  InlineArray or table"
