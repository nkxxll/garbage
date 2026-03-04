#!/usr/bin/env bash

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LLISP="$REPO_ROOT/zig-out/bin/llisp"
FIXTURES="$REPO_ROOT/tests/fixtures"

# Build first
echo "Building llisp..."
zig build -p "$REPO_ROOT/zig-out" 2>&1
echo ""

if [[ ! -x "$LLISP" ]]; then
    echo -e "${RED}Error: $LLISP not found. Build failed?${RESET}"
    exit 1
fi

GC_BACKENDS=("none" "mark-sweep" "memory-pool")
fixture="$FIXTURES/gc_stress_heavy.schm"

for gc in "${GC_BACKENDS[@]}"; do
    out=$(hyperfine --warmup 0 --runs 5 "$LLISP --gc=$gc $fixture 2>/dev/null 1>/dev/null")
    echo "$out"
done
