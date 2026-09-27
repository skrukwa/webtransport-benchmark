#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/harness_run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
RESULTS_BASE="$REPO_ROOT/results"
CROSSOVER_DIR="$RESULTS_BASE/crossover"

DURATION=30
CLIENTS=50
SERVER_CORES="2,3,4,5"
CLIENT_CORES="6,7,8,9,10,11,12,13,14,15,16,17"

SWEEP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

read -r -a DELAY_LEVELS <<< "${CROSSOVER_DELAYS:-20ms 50ms}"
LOSS_LEVELS=("0%" "1%" "2%" "5%" "10%")

PROTOS_CROSSOVER_NODE=(ws webtransport-fails-components webtransport-datagram)
PROTOS_CROSSOVER_BUN=(ws webtransport-vmeansdev webtransport-datagram)
PROTOS_CROSSOVER_DENO=(ws webtransport webtransport-datagram)

run_preflight

mkdir -p "$CROSSOVER_DIR"

FAILURES=0

run_one_crossover() {
    local loss="$1" delay="$2" runtime="$3" proto="$4" port="$5"

    local server_cmd
    server_cmd=$(server_cmd_for "$runtime" "$proto")

    local client_proto="$proto"
    local wt_flag=""
    if [[ "$proto" == "webtransport-datagram" ]]; then
        client_proto="webtransport-datagram"; wt_flag="--unstable-net"
    elif [[ "$proto" == webtransport* ]]; then
        client_proto="webtransport"; wt_flag="--unstable-net"
    fi

    local client_cmd="deno run --allow-net --allow-read --allow-write --allow-env --unsafely-ignore-certificate-errors $wt_flag \
        $CLIENT_SCRIPT \
        --target \$SERVER_IP:\$SERVER_PORT \
        --protocol $client_proto \
        --duration $DURATION \
        --clients $CLIENTS \
        --workers $CLIENTS"

    yellow "[crossover] loss=$loss delay=$delay | $runtime $proto (port=$port)"

    if ! RESULTS_DIR="$CROSSOVER_DIR" SERVER_PORT="$port" "$RUN_TEST" \
            --server  "$server_cmd" \
            --client  "$client_cmd" \
            --duration "$DURATION" \
            --loss    "$loss" \
            --delay   "$delay" \
            --port    "$port" \
            --server-cores "$SERVER_CORES" \
            --client-cores "$CLIENT_CORES" \
            --bench-profile crossover \
            --runtime "$runtime" \
            --variant "$proto" \
            --sweep-stamp "$SWEEP_STAMP"; then
        red "  WARN: loss=$loss | $runtime $proto — harness_run_test.sh exited non-zero" >&2
        FAILURES=$(( FAILURES + 1 ))
        return
    fi

    ok "  DONE: loss=$loss | $runtime $proto"
}

CROSSOVER_BASE_PORT=8400

combos_per_level=$(( ${#PROTOS_CROSSOVER_NODE[@]} + ${#PROTOS_CROSSOVER_BUN[@]} + ${#PROTOS_CROSSOVER_DENO[@]} ))
total_runs=$(( ${#DELAY_LEVELS[@]} * ${#LOSS_LEVELS[@]} * combos_per_level ))
yellow "[crossover] Sweep: ${#DELAY_LEVELS[@]} delays x ${#LOSS_LEVELS[@]} loss levels x $combos_per_level combos (WS+WT) = $total_runs runs"
yellow "[crossover] delays=${DELAY_LEVELS[*]} duration=${DURATION}s clients=${CLIENTS} server_cores=${SERVER_CORES} client_cores=${CLIENT_CORES}"
yellow "[crossover] output -> $CROSSOVER_DIR"
echo ""

port_offset=0
for delay in "${DELAY_LEVELS[@]}"; do
    yellow "########## Delay: $delay ##########"

    for loss in "${LOSS_LEVELS[@]}"; do
        yellow "=== Loss level: $loss (delay=$delay) ==="

        for runtime in "${RUNTIMES[@]}"; do
            case "$runtime" in
                node) protos=("${PROTOS_CROSSOVER_NODE[@]}") ;;
                bun)  protos=("${PROTOS_CROSSOVER_BUN[@]}") ;;
                deno) protos=("${PROTOS_CROSSOVER_DENO[@]}") ;;
            esac
            for proto in "${protos[@]}"; do
                port=$(( CROSSOVER_BASE_PORT + port_offset ))
                run_one_crossover "$loss" "$delay" "$runtime" "$proto" "$port"
                port_offset=$(( port_offset + 1 ))
                echo ""
            done
        done

        green "=== Loss level $loss (delay=$delay) COMPLETE ==="
        echo ""
    done
done

green "===================="
green "CROSSOVER SWEEP COMPLETE"
green "===================="
echo "Runs:     $(( port_offset ))"
echo "Failures: $FAILURES"
echo "Results:  $CROSSOVER_DIR/metrics.csv"

if (( FAILURES > 0 )); then
    red "$FAILURES run(s) failed — check logs in $CROSSOVER_DIR/" >&2
    exit 1
fi
