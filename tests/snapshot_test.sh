#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LLISP="$REPO_ROOT/zig-out/bin/llisp"
FIXTURES="$REPO_ROOT/tests/fixtures"
SNAPSHOTS="$REPO_ROOT/tests/snapshots"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

usage() {
    echo "Usage: $0 [--update | --bench]"
    echo ""
    echo "  --update   Regenerate all snapshot files from current output"
    echo "  --bench    Benchmark each fixture (wall time, CPU time, peak memory)"
    echo "  (default)  Compare current output against saved snapshots"
    exit 1
}

MODE="test"
if [[ "${1:-}" == "--update" ]]; then
    MODE="update"
elif [[ "${1:-}" == "--bench" ]]; then
    MODE="bench"
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

GC_BACKENDS=("none" "mark-sweep" "memory-pool")

# --- Benchmark mode ---
if [[ "$MODE" == "bench" ]]; then
    printf "\n${BOLD}%-30s %-12s %10s %10s %10s %12s${RESET}\n" \
        "FIXTURE" "GC" "REAL (s)" "USER (s)" "SYS (s)" "PEAK MEM"
    printf '%.0s-' {1..88}; echo ""

    for gc in "${GC_BACKENDS[@]}"; do
        for fixture in "$FIXTURES"/*.schm "$FIXTURES"/*.scm; do
            [[ -e "$fixture" ]] || continue
            name="$(basename "$fixture")"

            time_out=$( /usr/bin/time -l "$LLISP" --gc="$gc" "$fixture" 2>&1 1>/dev/null ) || true

            real=$(echo "$time_out" | awk '/real/{print $1}')
            user=$(echo "$time_out" | awk '/user/{print $1}')
            sys=$(echo "$time_out"  | awk '/sys/{print $1}')
            peak_bytes=$(echo "$time_out" | awk '/maximum resident set size/{print $1}')

            if [[ -n "$peak_bytes" ]]; then
                peak_kb=$(( peak_bytes / 1024 ))
                if (( peak_kb >= 1024 )); then
                    peak_human="$(awk "BEGIN{printf \"%.1f MB\", $peak_kb/1024}")"
                else
                    peak_human="${peak_kb} KB"
                fi
            else
                peak_human="n/a"
            fi

            printf "%-30s %-12s %10s %10s %10s %12s\n" \
                "$name" "$gc" "${real:-n/a}" "${user:-n/a}" "${sys:-n/a}" "$peak_human"
        done
    done

    echo ""
    exit 0
fi

# --- Snapshot test / update mode ---
passed=0
failed=0
updated=0
errors=0

for gc in "${GC_BACKENDS[@]}"; do
    echo "--- GC backend: $gc ---"
    for fixture in "$FIXTURES"/*.schm "$FIXTURES"/*.scm; do
        [[ -e "$fixture" ]] || continue
        name="$(basename "$fixture")"
        snap="$SNAPSHOTS/${name}.expected"

        if ! actual=$("$LLISP" --gc="$gc" "$fixture" 2>&1); then
            echo -e "${RED}RUNTIME ERROR${RESET} [$gc] $name"
            echo "  $actual"
            ((errors++)) || true
            continue
        fi

        if [[ "$MODE" == "update" ]]; then
            # Only write snapshots once (from the first backend)
            if [[ "$gc" == "${GC_BACKENDS[0]}" ]]; then
                echo "$actual" > "$snap"
                echo -e "${YELLOW}UPDATED${RESET}  $name"
                ((updated++)) || true
            fi
            continue
        fi

        if [[ ! -f "$snap" ]]; then
            echo -e "${YELLOW}MISSING${RESET}  [$gc] $name  (run with --update to create)"
            ((failed++)) || true
            continue
        fi

        expected=$(<"$snap")

        if [[ "$actual" == "$expected" ]]; then
            echo -e "${GREEN}PASS${RESET}    [$gc] $name"
            ((passed++)) || true
        else
            echo -e "${RED}FAIL${RESET}    [$gc] $name"
            diff --color=always <(echo "$expected") <(echo "$actual") | sed 's/^/  /'
            ((failed++)) || true
        fi
    done
    echo ""
done

if [[ "$MODE" == "update" ]]; then
    echo "Updated $updated snapshot(s)."
else
    echo "Results: $passed passed, $failed failed, $errors error(s)"
    [[ "$failed" -eq 0 && "$errors" -eq 0 ]] || exit 1
fi
