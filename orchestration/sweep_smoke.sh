#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/harness_run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
RESULTS_DIR="$REPO_ROOT/results/smoke"
METRICS_CSV="$RESULTS_DIR/metrics.csv"

col_idx() { echo "$1" | tr ',' '\n' | grep -nxF "$2" | head -n1 | cut -d: -f1; }

DURATION=10
CLIENTS=2
MIN_RTT_SAMPLES=10
SERVER_CORES="2,3,4,5"
CLIENT_CORES="6,7,8,9,10,11,12,13,14,15,16,17"

SWEEP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

run_preflight
mkdir -p "$RESULTS_DIR"

run_one() {
    local runtime="$1" proto="$2" port="$3"
    local tag="$runtime $proto"

    yellow "[smoke] === ${tag} (port=${port}) ==="

    local baseline_lines=0
    if [[ -f "$METRICS_CSV" ]]; then
        baseline_lines=$(wc -l < "$METRICS_CSV")
    fi

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
        --duration \$DURATION \
        --clients $CLIENTS \
        --workers $CLIENTS"

    if ! RESULTS_DIR="$RESULTS_DIR" SERVER_PORT="$port" "$RUN_TEST" \
            --server "$server_cmd" \
            --client "$client_cmd" \
            --duration "$DURATION" \
            --loss "0%" \
            --delay "0ms" \
            --port "$port" \
            --server-cores "$SERVER_CORES" \
            --client-cores "$CLIENT_CORES" \
            --bench-profile smoke \
            --runtime "$runtime" \
            --variant "$proto" \
            --sweep-stamp "$SWEEP_STAMP"; then
        fail "${tag}: harness_run_test.sh exited non-zero"
    fi

    local run_dir
    run_dir=$(find "$RESULTS_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n1 | cut -d' ' -f2-)
    [[ -n "$run_dir" && -d "$run_dir" ]] \
        || fail "${tag}: could not locate per-run directory under $RESULTS_DIR"

    [[ -f "$METRICS_CSV" ]] || fail "${tag}: metrics.csv was not created"

    local header expected_header current_lines new_rows
    header=$(head -n1 "$METRICS_CSV")
    expected_header="Timestamp,Profile,Runtime,ProtocolVariant,Protocol,Concurrency,DurationSec,PacketLossPct,DelayMs,Throughput,p50_ms,p95_ms,p99_ms,Errors,Overflows,MeanConnect_ms,DgramSent,DgramTimeouts,DgramTimeoutPct,DgramTimeoutMs,MeanReady_ms"
    [[ "$header" == "$expected_header" ]] \
        || fail "${tag}: metrics.csv header mismatch. got: $header"

    current_lines=$(wc -l < "$METRICS_CSV")
    new_rows=$(( current_lines - baseline_lines ))
    if (( baseline_lines == 0 )); then
        (( new_rows == 2 )) \
            || fail "${tag}: expected 2 new lines (header + row) in fresh metrics.csv, got $new_rows"
    else
        (( new_rows == 1 )) \
            || fail "${tag}: expected exactly 1 new row in metrics.csv, got $new_rows"
    fi

    local last_row protocol_col profile_col runtime_col variant_col expected_proto
    last_row=$(tail -n1 "$METRICS_CSV")
    protocol_col=$(echo "$last_row" | cut -d',' -f"$(col_idx "$header" Protocol)")
    profile_col=$(echo "$last_row"  | cut -d',' -f"$(col_idx "$header" Profile)")
    runtime_col=$(echo "$last_row"  | cut -d',' -f"$(col_idx "$header" Runtime)")
    variant_col=$(echo "$last_row"  | cut -d',' -f"$(col_idx "$header" ProtocolVariant)")
    expected_proto="$proto"
    [[ "$proto" == webtransport* && "$proto" != "webtransport-datagram" ]] && expected_proto="webtransport"
    [[ "$protocol_col" == "$expected_proto" ]] \
        || fail "${tag}: metrics.csv Protocol=$protocol_col, expected $expected_proto"
    [[ "$profile_col" == "smoke"     ]] || fail "${tag}: Profile=$profile_col, expected smoke"
    [[ "$runtime_col" == "$runtime"  ]] || fail "${tag}: Runtime=$runtime_col, expected $runtime"
    [[ "$variant_col" == "$proto"    ]] || fail "${tag}: ProtocolVariant=$variant_col, expected $proto"

    local raw_rtts raw_header raw_samples
    raw_rtts="$run_dir/rtts.csv"
    [[ -f "$raw_rtts" ]] || fail "${tag}: rtts.csv not found at $raw_rtts"

    raw_header=$(head -n1 "$raw_rtts")
    [[ "$raw_header" == "client_id,rtt_ms" ]] \
        || fail "${tag}: rtts.csv header mismatch. got: $raw_header"

    raw_samples=$(( $(wc -l < "$raw_rtts") - 1 ))
    (( raw_samples > MIN_RTT_SAMPLES )) \
        || fail "${tag}: rtts.csv has only $raw_samples samples (expected > $MIN_RTT_SAMPLES)"

    local errors overflows throughput
    errors=$(echo "$last_row"     | cut -d',' -f"$(col_idx "$header" Errors)")
    overflows=$(echo "$last_row"  | cut -d',' -f"$(col_idx "$header" Overflows)")
    throughput=$(echo "$last_row" | cut -d',' -f"$(col_idx "$header" Throughput)")
    local err_tol=0
    case "$proto" in
        long-polling)          err_tol="0.01" ;;
        webtransport-datagram) err_tol="0.02" ;;
    esac
    if [[ "$err_tol" != "0" ]]; then
        awk -v e="$errors" -v n="$raw_samples" -v t="$err_tol" \
            'BEGIN { exit !(n > 0 && (e / n) < t) }' \
            || fail "${tag}: errors=$errors out of $raw_samples samples exceeds the $(awk -v t="$err_tol" 'BEGIN{printf "%g", t*100}')% ${proto} tolerance"
    else
        [[ "$errors" == "0" ]] || fail "${tag}: errors=$errors in clean-network run (expected 0)"
    fi
    [[ "$overflows" == "0" ]] || fail "${tag}: overflows=$overflows (per-client buffer cap exceeded)"
    awk -v t="$throughput" 'BEGIN { exit !(t > 0) }' \
        || fail "${tag}: throughput=$throughput (expected > 0)"

    [[ -s "$run_dir/server.log"         ]] || fail "${tag}: server.log is empty"
    [[ -s "$run_dir/server_pidstat.log" ]] || fail "${tag}: server_pidstat.log is empty"

    ok "PASS: ${tag}  (samples=${raw_samples}, throughput=${throughput} msg/s)"
}

yellow "[smoke] matrix: 18 combinations (node×6, bun×6, deno×6)"
yellow "[smoke] per-run: ${DURATION}s, ${CLIENTS} clients, loss=0%, delay=0ms"
echo ""

port_offset=0
for runtime in "${RUNTIMES[@]}"; do
    case "$runtime" in
        node) protos=("${PROTOCOLS_NODE[@]}") ;;
        bun)  protos=("${PROTOCOLS_BUN[@]}") ;;
        deno) protos=("${PROTOCOLS_DENO[@]}") ;;
    esac
    for proto in "${protos[@]}"; do
        port=$(( BASE_PORT + port_offset ))
        run_one "$runtime" "$proto" "$port"
        port_offset=$(( port_offset + 1 ))
        echo ""
    done
done

green "===================="
green "MATRIX PASSED (all combinations)"
green "===================="
echo "metrics: $METRICS_CSV"
