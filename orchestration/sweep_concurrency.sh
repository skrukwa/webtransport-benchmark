#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/harness_run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
RESULTS_BASE="$REPO_ROOT/results"
CONCURRENCY_DIR="$RESULTS_BASE/concurrency"

DURATION=30
SERVER_CORES="2,3,4,5"
CLIENT_CORES="6,7,8,9,10,11,12,13,14,15,16,17"

LOSS="0%"
DELAY="0ms"

CLIENTS_LEVELS=(50 100)

BASE_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

run_preflight
mkdir -p "$CONCURRENCY_DIR"

FAILURES=0

run_one_concurrency() {
    local clients="$1" runtime="$2" proto="$3" port="$4" stamp="$5"

    local server_cmd client_cmd
    server_cmd=$(server_cmd_for "$runtime" "$proto")
    client_cmd=$(client_cmd_for "$proto" "$DURATION" "$clients" "$CLIENT_SCRIPT")

    yellow "[concurrency] clients=$clients | $runtime $proto (port=$port)"

    if ! RESULTS_DIR="$CONCURRENCY_DIR" SERVER_PORT="$port" "$RUN_TEST" \
            --server  "$server_cmd" \
            --client  "$client_cmd" \
            --duration "$DURATION" \
            --loss    "$LOSS" \
            --delay   "$DELAY" \
            --port    "$port" \
            --server-cores "$SERVER_CORES" \
            --client-cores "$CLIENT_CORES" \
            --bench-profile concurrency \
            --runtime "$runtime" \
            --variant "$proto" \
            --sweep-stamp "$stamp"; then
        red "  WARN: clients=$clients | $runtime $proto — harness_run_test.sh exited non-zero" >&2
        FAILURES=$(( FAILURES + 1 ))
        return
    fi

    ok "  DONE: clients=$clients | $runtime $proto"
}

CONCURRENCY_BASE_PORT=8500

combos=$(( ${#PROTOCOLS_NODE[@]} + ${#PROTOCOLS_BUN[@]} + ${#PROTOCOLS_DENO[@]} ))
total_runs=$(( ${#CLIENTS_LEVELS[@]} * combos ))
yellow "[concurrency] Sweep: ${#CLIENTS_LEVELS[@]} client levels x $combos combos = $total_runs runs (ideal network)"
yellow "[concurrency] levels=${CLIENTS_LEVELS[*]} duration=${DURATION}s server_cores=${SERVER_CORES} client_cores=${CLIENT_CORES}"
yellow "[concurrency] output -> $CONCURRENCY_DIR"
echo ""

port_offset=0
for clients in "${CLIENTS_LEVELS[@]}"; do
    stamp="${BASE_STAMP}-c${clients}"
    yellow "=== Concurrency level: $clients clients ==="

    for runtime in "${RUNTIMES[@]}"; do
        case "$runtime" in
            node) protos=("${PROTOCOLS_NODE[@]}") ;;
            bun)  protos=("${PROTOCOLS_BUN[@]}") ;;
            deno) protos=("${PROTOCOLS_DENO[@]}") ;;
        esac
        for proto in "${protos[@]}"; do
            port=$(( CONCURRENCY_BASE_PORT + port_offset ))
            run_one_concurrency "$clients" "$runtime" "$proto" "$port" "$stamp"
            port_offset=$(( port_offset + 1 ))
            echo ""
        done
    done

    green "=== Concurrency level $clients COMPLETE ==="
    echo ""
done

green "===================="
green "CONCURRENCY SWEEP COMPLETE"
green "===================="
echo "Runs:     $(( port_offset ))"
echo "Failures: $FAILURES"
echo "Results:  $CONCURRENCY_DIR/metrics.csv"

if (( FAILURES > 0 )); then
    red "$FAILURES run(s) failed — check logs in $CONCURRENCY_DIR/" >&2
    exit 1
fi
