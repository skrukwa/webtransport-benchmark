#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/harness_run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
RESULTS_BASE="$REPO_ROOT/results"
PROFILING_DIR="$RESULTS_BASE/profiling"

DURATION=120
CLIENTS=50
SERVER_CORES="2,3,4,5"
CLIENT_CORES="6,7,8,9,10,11,12,13,14,15,16,17"

LOSS="0%"
DELAY="0ms"

SWEEP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

PROFILE_RUNTIMES=(node node                          node                   deno deno         deno                   bun  bun                    bun)
PROFILE_PROTOS=(  ws   webtransport-fails-components  webtransport-datagram  ws   webtransport webtransport-datagram  ws   webtransport-vmeansdev webtransport-datagram)

run_preflight

if ! command -v perf >/dev/null 2>&1; then
    fail "perf not on PATH. Install: apt-get install linux-tools-common linux-tools-\$(uname -r)"
fi
for tool in stackcollapse-perf.pl flamegraph.pl; do
    command -v "$tool" >/dev/null 2>&1 \
        || yellow "[profile] WARN: $tool not on PATH — perf.data will be captured but flamegraph.svg will not render."
done

mkdir -p "$PROFILING_DIR"

FAILURES=0

profile_label() {
    local runtime="$1" proto="$2"
    local rt_name
    case "$runtime" in
        node) rt_name="Node" ;;
        deno) rt_name="Deno" ;;
        bun)  rt_name="Bun" ;;
        *)    rt_name="$runtime" ;;
    esac
    case "$proto" in
        ws)                            echo "$rt_name WebSocket" ;;
        webtransport)                  echo "$rt_name WebTransport (native)" ;;
        webtransport-fails-components) echo "$rt_name WebTransport (fails-components)" ;;
        webtransport-vmeansdev)        echo "$rt_name WebTransport (vmeansdev)" ;;
        webtransport-datagram)         echo "$rt_name WebTransport (datagram)" ;;
        *)                             echo "$rt_name $proto" ;;
    esac
}

run_one_profile() {
    local runtime="$1" proto="$2" port="$3"

    local server_cmd label
    server_cmd=$(server_cmd_for "$runtime" "$proto")
    label=$(profile_label "$runtime" "$proto")

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

    yellow "[profile] ideal | $runtime $proto (port=$port, ${DURATION}s, perf -F 99 -g)"

    if ! RESULTS_DIR="$PROFILING_DIR" SERVER_PORT="$port" "$RUN_TEST" \
            --server  "$server_cmd" \
            --client  "$client_cmd" \
            --duration "$DURATION" \
            --loss    "$LOSS" \
            --delay   "$DELAY" \
            --port    "$port" \
            --server-cores "$SERVER_CORES" \
            --client-cores "$CLIENT_CORES" \
            --profile \
            --label "$label" \
            --bench-profile profiling \
            --runtime "$runtime" \
            --variant "$proto" \
            --sweep-stamp "$SWEEP_STAMP"; then
        red "  WARN: ideal | $runtime $proto — harness_run_test.sh exited non-zero" >&2
        FAILURES=$(( FAILURES + 1 ))
        return
    fi

    ok "  DONE: ideal | $runtime $proto"
}

PROFILING_BASE_PORT=8300

yellow "[profile] Targeted profiling: ${#PROFILE_RUNTIMES[@]} combinations, ideal network only"
yellow "[profile] duration=${DURATION}s clients=${CLIENTS} server_cores=${SERVER_CORES} client_cores=${CLIENT_CORES}"
yellow "[profile] output -> $PROFILING_DIR"
echo ""

port_offset=0
for i in "${!PROFILE_RUNTIMES[@]}"; do
    runtime="${PROFILE_RUNTIMES[$i]}"
    proto="${PROFILE_PROTOS[$i]}"
    port=$(( PROFILING_BASE_PORT + port_offset ))
    run_one_profile "$runtime" "$proto" "$port"
    port_offset=$(( port_offset + 1 ))
    echo ""
done

green "===================="
green "PROFILING COMPLETE"
green "===================="
echo "Runs:     $(( port_offset ))"
echo "Failures: $FAILURES"
echo "Flamegraphs (one per run dir):"
echo "  $PROFILING_DIR/*/flamegraph.svg"

if (( FAILURES > 0 )); then
    red "$FAILURES run(s) failed — check logs in $PROFILING_DIR/" >&2
    exit 1
fi
