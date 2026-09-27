#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/harness_run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
RESULTS_BASE="$REPO_ROOT/results"
BURST_DIR="$RESULTS_BASE/burst_loss"

DURATION=30
CLIENTS=50
SERVER_CORES="2,3,4,5"
CLIENT_CORES="6,7,8,9,10,11,12,13,14,15,16,17"

DELAY="50ms"
NOMINAL_LOSS="5%"
LOSS_SPEC="gemodel 1.05% 20%"

SWEEP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

run_preflight
mkdir -p "$BURST_DIR"

FAILURES=0

run_one_burst() {
    local runtime="$1" proto="$2" port="$3"

    local server_cmd client_cmd
    server_cmd=$(server_cmd_for "$runtime" "$proto")
    client_cmd=$(client_cmd_for "$proto" "$DURATION" "$CLIENTS" "$CLIENT_SCRIPT")

    yellow "[burst] loss='$LOSS_SPEC' (nominal $NOMINAL_LOSS) delay=$DELAY | $runtime $proto (port=$port)"

    if ! RESULTS_DIR="$BURST_DIR" SERVER_PORT="$port" "$RUN_TEST" \
            --server  "$server_cmd" \
            --client  "$client_cmd" \
            --duration "$DURATION" \
            --loss    "$NOMINAL_LOSS" \
            --loss-spec "$LOSS_SPEC" \
            --delay   "$DELAY" \
            --port    "$port" \
            --server-cores "$SERVER_CORES" \
            --client-cores "$CLIENT_CORES" \
            --bench-profile burst_loss \
            --runtime "$runtime" \
            --variant "$proto" \
            --sweep-stamp "$SWEEP_STAMP"; then
        red "  WARN: $runtime $proto — harness_run_test.sh exited non-zero" >&2
        FAILURES=$(( FAILURES + 1 ))
        return
    fi

    ok "  DONE: $runtime $proto"
}

BURST_BASE_PORT=8600

combos=$(( ${#PROTOCOLS_NODE[@]} + ${#PROTOCOLS_BUN[@]} + ${#PROTOCOLS_DENO[@]} ))
yellow "[burst] Sweep: $combos runtime+protocol combos under bursty loss '$LOSS_SPEC' at $DELAY"
yellow "[burst] nominal=$NOMINAL_LOSS duration=${DURATION}s clients=${CLIENTS} server_cores=${SERVER_CORES} client_cores=${CLIENT_CORES}"
yellow "[burst] output -> $BURST_DIR"
echo ""

port_offset=0
for runtime in "${RUNTIMES[@]}"; do
    case "$runtime" in
        node) protos=("${PROTOCOLS_NODE[@]}") ;;
        bun)  protos=("${PROTOCOLS_BUN[@]}") ;;
        deno) protos=("${PROTOCOLS_DENO[@]}") ;;
    esac
    for proto in "${protos[@]}"; do
        port=$(( BURST_BASE_PORT + port_offset ))
        run_one_burst "$runtime" "$proto" "$port"
        port_offset=$(( port_offset + 1 ))
        echo ""
    done
done

green "===================="
green "BURST-LOSS SWEEP COMPLETE"
green "===================="
echo "Runs:     $(( port_offset ))"
echo "Failures: $FAILURES"
echo "Results:  $BURST_DIR/metrics.csv"

if (( FAILURES > 0 )); then
    red "$FAILURES run(s) failed — check logs in $BURST_DIR/" >&2
    exit 1
fi
