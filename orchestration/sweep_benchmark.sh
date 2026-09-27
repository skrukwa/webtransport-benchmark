#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/harness_run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
RESULTS_BASE="$REPO_ROOT/results"

DURATION=30
CLIENTS=50
SERVER_CORES="2,3,4,5"
CLIENT_CORES="6,7,8,9,10,11,12,13,14,15,16,17"

SWEEP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

PROFILE_NAMES=(ideal      high_latency)
PROFILE_LOSS=( "0%"       "0%"        )
PROFILE_DELAY=("0ms"      "50ms"      )

run_preflight

FAILURES=0

run_one_benchmark() {
    local profile="$1" loss="$2" delay="$3" runtime="$4" proto="$5" port="$6"
    local profile_dir="$RESULTS_BASE/$profile"

    mkdir -p "$profile_dir"

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

    yellow "[bench] $profile | $runtime $proto (port=$port, loss=$loss, delay=$delay)"

    if ! RESULTS_DIR="$profile_dir" SERVER_PORT="$port" "$RUN_TEST" \
            --server  "$server_cmd" \
            --client  "$client_cmd" \
            --duration "$DURATION" \
            --loss    "$loss" \
            --delay   "$delay" \
            --port    "$port" \
            --server-cores "$SERVER_CORES" \
            --client-cores "$CLIENT_CORES" \
            --bench-profile "$profile" \
            --runtime "$runtime" \
            --variant "$proto" \
            --sweep-stamp "$SWEEP_STAMP"; then
        red "  WARN: $profile | $runtime $proto — harness_run_test.sh exited non-zero" >&2
        FAILURES=$(( FAILURES + 1 ))
        return
    fi

    ok "  DONE: $profile | $runtime $proto"
}

BENCHMARK_BASE_PORT=8200

yellow "[bench] Starting full sweep: ${#PROFILE_NAMES[@]} profiles x 18 combos = $(( ${#PROFILE_NAMES[@]} * 18 )) runs"
yellow "[bench] duration=${DURATION}s  clients=${CLIENTS}  server_cores=${SERVER_CORES}  client_cores=${CLIENT_CORES}"
echo ""

port_offset=0
for pi in "${!PROFILE_NAMES[@]}"; do
    profile="${PROFILE_NAMES[$pi]}"
    loss="${PROFILE_LOSS[$pi]}"
    delay="${PROFILE_DELAY[$pi]}"

    yellow "=== Profile: $profile (loss=$loss, delay=$delay) ==="

    for runtime in "${RUNTIMES[@]}"; do
        case "$runtime" in
            node) protos=("${PROTOCOLS_NODE[@]}") ;;
            bun)  protos=("${PROTOCOLS_BUN[@]}") ;;
            deno) protos=("${PROTOCOLS_DENO[@]}") ;;
        esac
        for proto in "${protos[@]}"; do
            port=$(( BENCHMARK_BASE_PORT + port_offset ))
            run_one_benchmark "$profile" "$loss" "$delay" "$runtime" "$proto" "$port"
            port_offset=$(( port_offset + 1 ))
            echo ""
        done
    done

    green "=== Profile $profile COMPLETE ==="
    echo ""
done

green "===================="
green "SWEEP COMPLETE"
green "===================="
echo "Runs:     $(( port_offset ))"
echo "Failures: $FAILURES"
echo "Results:"
for name in "${PROFILE_NAMES[@]}"; do
    echo "  $RESULTS_BASE/$name/metrics.csv"
done

if (( FAILURES > 0 )); then
    red "$FAILURES run(s) failed — check logs in $RESULTS_BASE/" >&2
    exit 1
fi
