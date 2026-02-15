#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LLISP="$REPO_ROOT/zig-out/bin/llisp"
FIXTURES="$REPO_ROOT/tests/fixtures"
SNAPSHOTS="$REPO_ROOT/tests/snapshots"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

usage() {
    echo "Usage: $0 [--update]"
    echo ""
    echo "  --update   Regenerate all snapshot files from current output"
    echo "  (default)  Compare current output against saved snapshots"
    exit 1
}

UPDATE=0
if [[ "${1:-}" == "--update" ]]; then
    UPDATE=1
elif [[ -n "${1:-}" ]]; then
    usage
fi

# Build first
echo "Building llisp..."
zig build -p "$REPO_ROOT/zig-out" 2>&1
echo ""

if [[ ! -x "$LLISP" ]]; then
    echo -e "${RED}Error: $LLISP not found. Build failed?${RESET}"
    exit 1
fi

mkdir -p "$SNAPSHOTS"

passed=0
failed=0
updated=0
errors=0

for fixture in "$FIXTURES"/*.schm "$FIXTURES"/*.scm; do
    [[ -e "$fixture" ]] || continue
    name="$(basename "$fixture")"
    snap="$SNAPSHOTS/${name}.expected"

    if ! actual=$("$LLISP" "$fixture" 2>&1); then
        echo -e "${RED}RUNTIME ERROR${RESET} $name"
        echo "  $actual"
        ((errors++)) || true
        continue
    fi

    if [[ "$UPDATE" -eq 1 ]]; then
        echo "$actual" > "$snap"
        echo -e "${YELLOW}UPDATED${RESET}  $name"
        ((updated++)) || true
        continue
    fi

    if [[ ! -f "$snap" ]]; then
        echo -e "${YELLOW}MISSING${RESET}  $name  (run with --update to create)"
        ((failed++)) || true
        continue
    fi

    expected=$(<"$snap")

    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}PASS${RESET}    $name"
        ((passed++)) || true
    else
        echo -e "${RED}FAIL${RESET}    $name"
        diff --color=always <(echo "$expected") <(echo "$actual") | sed 's/^/  /'
        ((failed++)) || true
    fi
done

echo ""
if [[ "$UPDATE" -eq 1 ]]; then
    echo "Updated $updated snapshot(s)."
else
    echo "Results: $passed passed, $failed failed, $errors error(s)"
    [[ "$failed" -eq 0 && "$errors" -eq 0 ]] || exit 1
fi
