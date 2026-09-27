#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/harness_run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
OUT_DIR="$REPO_ROOT/results/profiling_symbolized"

BENCH_HOME="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)"
for d in /usr/local/bin "$HOME/.bun/bin" "$HOME/.deno/bin" \
         "$BENCH_HOME/.bun/bin" "$BENCH_HOME/.deno/bin"; do
    [[ -d "$d" ]] && PATH="$d:$PATH"
done
export PATH

MODE="${1:-all}"
case "$MODE" in parity|flame|all) ;; *) fail "MODE must be parity|flame|all (got: $MODE)";; esac
shift $(( $# > 0 ? 1 : 0 ))

CLIENTS=50
SERVER_CORES="2,3,4,5"
CLIENT_CORES="6,7,8,9,10,11,12,13,14,15,16,17"
LOSS="0%"; DELAY="0ms"
PARITY_DURATION=60
FLAME_DURATION=120
PARITY_WARMUP=5
BASE_PORT=8400

if [[ "$#" -gt 0 ]]; then PROTOS=("$@"); else PROTOS=(ws webtransport webtransport-datagram); fi
for _p in "${PROTOS[@]}"; do
    case "$_p" in ws|webtransport|webtransport-datagram) ;;
        *) fail "unknown protocol '$_p' (allowed: ws webtransport webtransport-datagram)";; esac
done

SWEEP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

: "${DENO_BIN:?set DENO_BIN to the from-source deno binary, e.g. DENO_BIN=~/deno-src/target/release/deno}"
[[ -x "$DENO_BIN" ]] || fail "DENO_BIN not executable: $DENO_BIN"
CUST_VER="$("$DENO_BIN" --version 2>/dev/null | head -1 || true)"
[[ "$CUST_VER" == *"2.8.3"* ]] \
    || fail "DENO_BIN must report deno 2.8.3 (matches shipped); got: ${CUST_VER:-<none>}"
if command -v file >/dev/null 2>&1 && file "$DENO_BIN" | grep -q "stripped"; then
    if file "$DENO_BIN" | grep -qv "not stripped"; then
        yellow "[sym] WARN: $DENO_BIN appears STRIPPED — native frames will not symbolize."
    fi
fi

run_preflight
command -v perf >/dev/null 2>&1 || fail "perf not on PATH. Install: apt-get install linux-tools-\$(uname -r)"
for tool in stackcollapse-perf.pl flamegraph.pl; do
    command -v "$tool" >/dev/null 2>&1 \
        || yellow "[sym] WARN: $tool not on PATH — perf.data captured but flamegraph.svg will not render."
done

mkdir -p "$OUT_DIR"

profile_label() {
    case "$1" in
        ws)                    echo "Deno WebSocket (symbolized)" ;;
        webtransport)          echo "Deno WebTransport native (symbolized)" ;;
        webtransport-datagram) echo "Deno WebTransport datagram (symbolized)" ;;
        *)                     echo "Deno $1 (symbolized)" ;;
    esac
}

client_cmd_for_proto() {
    local proto="$1" duration="$2"
    local client_proto="$proto" wt_flag=""
    if [[ "$proto" == "webtransport-datagram" ]]; then
        client_proto="webtransport-datagram"; wt_flag="--unstable-net"
    elif [[ "$proto" == webtransport* ]]; then
        client_proto="webtransport"; wt_flag="--unstable-net"
    fi
    echo "deno run --allow-net --allow-read --allow-write --allow-env --unsafely-ignore-certificate-errors $wt_flag \
        $CLIENT_SCRIPT \
        --target \$SERVER_IP:\$SERVER_PORT \
        --protocol $client_proto \
        --duration $duration \
        --clients $CLIENTS \
        --workers $CLIENTS"
}

server_cmd_build() {
    local proto="$1" build="$2" profile="$3"
    local base; base=$(proto_to_base "$proto")
    local unstable=""; [[ "$proto" == webtransport* ]] && unstable="--unstable-net"
    local bin="deno"; [[ "$build" == "custom" ]] && bin="$DENO_BIN"
    local v8=""; [[ "$profile" == "1" ]] && v8="--v8-flags=--perf-basic-prof,--interpreted-frames-native-stack "
    echo "$bin run ${v8}--allow-net --allow-env --allow-read $unstable $REPO_ROOT/servers/deno/$base.ts"
}

mean_server_cpu() {
    local log="$1"
    [[ -f "$log" ]] || { printf 'NA'; return; }
    awk -v warm="$PARITY_WARMUP" '
        /[AP]M/ && $9 ~ /^[0-9]+(\.[0-9]+)?$/ { n++; if (n > warm) { s += $9; c++ } }
        END { if (c > 0) printf "%.1f", s/c; else printf "NA" }' "$log"
}

throughput_of() {
    local csv="$1" proto="$2"
    [[ -f "$csv" ]] || { printf 'NA'; return; }
    awk -F, -v p="$proto" 'NR>1 && $4==p { v=$10 } END { if (v!="") printf "%s", v; else printf "NA" }' "$csv"
}

pct_delta() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        if (a=="NA"||b=="NA"||a+0==0) { printf "NA"; exit }
        printf "%+.1f%%", 100*(b-a)/a }'
}

server_pidstat_log() {
    local base_dir="$1" proto="$2"
    shopt -s nullglob
    local matches=( "$base_dir/"*"__${proto}__loss0pct__delay0ms"*"/server_pidstat.log" )
    shopt -u nullglob
    [[ ${#matches[@]} -gt 0 ]] && printf '%s' "${matches[-1]}"
}

FAILURES=0
run_cell() {
    local proto="$1" build="$2" profile="$3" duration="$4" port="$5" rdir="$6" label="$7"
    local server_cmd client_cmd
    server_cmd="$(server_cmd_build "$proto" "$build" "$profile")"
    client_cmd="$(client_cmd_for_proto "$proto" "$duration")"
    mkdir -p "$rdir"

    local -a extra=(--runtime deno --variant "$proto" --bench-profile "$([[ $profile == 1 ]] && echo profiling || echo parity)")
    [[ "$profile" == "1" ]] && extra+=(--profile --label "$label")

    yellow "[sym] $build${profile:+/prof=$profile} | deno $proto (port=$port, ${duration}s) -> $(basename "$rdir")"
    if ! RESULTS_DIR="$rdir" SERVER_PORT="$port" "$RUN_TEST" \
            --server "$server_cmd" \
            --client "$client_cmd" \
            --duration "$duration" \
            --loss "$LOSS" --delay "$DELAY" --port "$port" \
            --server-cores "$SERVER_CORES" --client-cores "$CLIENT_CORES" \
            --sweep-stamp "$SWEEP_STAMP" \
            "${extra[@]}"; then
        red "  WARN: deno $proto ($build) — harness exited non-zero" >&2
        FAILURES=$(( FAILURES + 1 ))
        return 1
    fi
    ok "  DONE: deno $proto ($build)"
}

port=$BASE_PORT

if [[ "$MODE" == "parity" || "$MODE" == "all" ]]; then
    yellow "[sym] === PARITY: shipped vs custom deno, ${PARITY_DURATION}s, ideal network ==="
    for build in shipped custom; do
        for proto in "${PROTOS[@]}"; do
            run_cell "$proto" "$build" 0 "$PARITY_DURATION" "$port" "$OUT_DIR/parity_$build" "" || true
            port=$(( port + 1 ))
        done
    done

    echo ""
    green "==================== PARITY RESULTS ===================="
    echo "Ideal network (0% loss, 0ms delay). Throughput=msg/s (client-bound, expect ~equal);"
    echo "server %CPU is the discriminating metric for a CPU-time flamegraph."
    echo ""
    printf "%-24s | %12s %12s %9s | %11s %11s %9s\n" \
        "protocol" "tput_ship" "tput_cust" "d%" "cpu_ship%" "cpu_cust%" "d%"
    printf -- "-------------------------+---------------------------------------+--------------------------------\n"
    for proto in "${PROTOS[@]}"; do
        ts="$(throughput_of "$OUT_DIR/parity_shipped/metrics.csv" "$proto")"
        tc="$(throughput_of "$OUT_DIR/parity_custom/metrics.csv" "$proto")"
        cs="$(mean_server_cpu "$(server_pidstat_log "$OUT_DIR/parity_shipped" "$proto")")"
        cc="$(mean_server_cpu "$(server_pidstat_log "$OUT_DIR/parity_custom" "$proto")")"
        printf "%-24s | %12s %12s %9s | %11s %11s %9s\n" \
            "$proto" "$ts" "$tc" "$(pct_delta "$ts" "$tc")" "$cs" "$cc" "$(pct_delta "$cs" "$cc")"
    done
    echo ""
    echo "Interpretation: if server %CPU deltas are within ~10-15% (custom may be"
    echo "slightly higher from frame pointers), the custom build is representative and"
    echo "its flamegraph is trustworthy."
    green "========================================================"
    echo ""
fi

if [[ "$MODE" == "flame" || "$MODE" == "all" ]]; then
    yellow "[sym] === FLAMEGRAPHS: custom deno, ${FLAME_DURATION}s, perf -F 99 -g ==="
    for proto in "${PROTOS[@]}"; do
        run_cell "$proto" custom 1 "$FLAME_DURATION" "$port" "$OUT_DIR" "$(profile_label "$proto")" || true
        port=$(( port + 1 ))
    done
    echo ""
    green "Flamegraphs (one per run dir):"
    echo "  $OUT_DIR/*__profiling__deno__*/flamegraph.svg"
fi

echo ""
if (( FAILURES > 0 )); then
    red "$FAILURES cell(s) failed — check logs under $OUT_DIR/" >&2
    exit 1
fi
green "profile_deno_symbolized.sh ($MODE) complete."
