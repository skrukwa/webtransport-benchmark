#!/usr/bin/env bash
set -euo pipefail

NS_SERVER="ns_server"
NS_CLIENT="ns_client"
VETH_SERVER="veth_s"
VETH_CLIENT="veth_c"
SERVER_IP="10.0.0.1"
CLIENT_IP="10.0.0.2"
SUBNET_PREFIX="30"
SERVER_PORT="${SERVER_PORT:-8080}"

DURATION=30
LOSS="0%"
LOSS_SPEC=""
DELAY="0ms"
SERVER_CMD=""
CLIENT_CMD=""
SERVER_CORES=""
CLIENT_CORES=""
PROFILE=0
LABEL=""
BENCH_PROFILE=""
RUNTIME=""
VARIANT=""
SWEEP_STAMP=""
PIDSTAT_INTERVAL=1
RESULTS_DIR="${RESULTS_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results"}"

usage() {
    cat >&2 <<EOF
Usage: $0 --server "<cmd>" --client "<cmd>" [options]

Required:
  --server CMD       Command to launch the echo server (runs in ns_server).
  --client CMD       Command to launch the load generator (runs in ns_client).

Options:
  --duration SECS      Test duration in seconds (default: ${DURATION}).
  --loss PCT           tc netem packet loss, e.g. "1%" (default: ${LOSS}).
  --loss-spec SPEC     Full netem loss expression, overriding --loss's model, e.g.
                       "gemodel 1.05% 20%" for bursty Gilbert-Elliott loss. --loss
                       still supplies the NOMINAL rate recorded in metrics/metadata
                       (PacketLossPct) so bursty runs line up with uniform ones.
  --delay MS           tc netem one-way delay, e.g. "20ms" (default: ${DELAY}).
  --port PORT          Server port (default: ${SERVER_PORT}).
  --server-cores LIST  taskset -c list for the server process, e.g. "0" (default: unpinned).
  --client-cores LIST  taskset -c list for the client process, e.g. "1,2" (default: unpinned).
  --profile            Wrap the server in 'perf record -F 99 -g' and, after the run,
                       render \$RUN_DIR/flamegraph.svg from the captured perf.data.
  --label TEXT         Descriptive label used as the flamegraph title (with --profile),
                       e.g. "Node WebTransport (fails-components)". Falls back to a
                       generic title if omitted.
  --bench-profile NAME Self-describing profile tag (ideal|high_latency|crossover|
                       concurrency|burst_loss|profiling|smoke). Embedded in metrics.csv + metadata.json.
  --runtime NAME       Runtime under test (node|deno|bun). Embedded as a data dimension.
  --variant NAME       Full protocol variant (e.g. webtransport-fails-components).
  --sweep-stamp STAMP  Shared UTC stamp from the calling sweep, used as the run-dir name
                       PREFIX so all dirs from one command group together. Falls back to
                       this run's own start stamp when omitted (standalone runs).
  -h, --help           Show this message.

Environment exported to children:
  SERVER_IP, CLIENT_IP, SERVER_PORT, and (for the client) the self-describing
  RUN_PROFILE, RUN_RUNTIME, RUN_VARIANT, RUN_LOSS_PCT, RUN_DELAY_MS.
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)        SERVER_CMD="$2";    shift 2 ;;
        --client)        CLIENT_CMD="$2";    shift 2 ;;
        --duration)      DURATION="$2";      shift 2 ;;
        --loss)          LOSS="$2";          shift 2 ;;
        --loss-spec)     LOSS_SPEC="$2";     shift 2 ;;
        --delay)         DELAY="$2";         shift 2 ;;
        --port)          SERVER_PORT="$2";   shift 2 ;;
        --server-cores)  SERVER_CORES="$2";  shift 2 ;;
        --client-cores)  CLIENT_CORES="$2";  shift 2 ;;
        --profile)       PROFILE=1;          shift 1 ;;
        --label)         LABEL="$2";         shift 2 ;;
        --bench-profile) BENCH_PROFILE="$2"; shift 2 ;;
        --runtime)       RUNTIME="$2";       shift 2 ;;
        --variant)       VARIANT="$2";       shift 2 ;;
        --sweep-stamp)   SWEEP_STAMP="$2";   shift 2 ;;
        -h|--help)       usage 0 ;;
        *)               echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ -z "$SERVER_CMD" || -z "$CLIENT_CMD" ]] && usage 1
[[ $EUID -eq 0 ]] || { echo "Must be run as root." >&2; exit 1; }

mkdir -p "$RESULTS_DIR"

LOSS_PCT="${LOSS%\%}"
DELAY_MS="${DELAY%ms}"
TAG_PROFILE="${BENCH_PROFILE:-standalone}"
TAG_RUNTIME="${RUNTIME:-unknown}"
TAG_VARIANT="${VARIANT:-unknown}"
RUN_PROTOCOL=""
RUN_CONCURRENCY=""
[[ "$CLIENT_CMD" =~ --protocol[[:space:]]+([a-z-]+) ]] && RUN_PROTOCOL="${BASH_REMATCH[1]}"
[[ "$CLIENT_CMD" =~ --clients[[:space:]]+([0-9]+) ]]   && RUN_CONCURRENCY="${BASH_REMATCH[1]}"

RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PREFIX_STAMP="${SWEEP_STAMP:-$RUN_STAMP}"
RUN_TAG="${PREFIX_STAMP}__${TAG_PROFILE}__${TAG_RUNTIME}__${TAG_VARIANT}__loss${LOSS_PCT}pct__delay${DELAY_MS}ms"
RUN_DIR="$RESULTS_DIR/$RUN_TAG"
_n=0
while [[ -e "$RUN_DIR" ]]; do
    _n=$(( _n + 1 ))
    RUN_DIR="$RESULTS_DIR/${RUN_TAG}__r${_n}"
done
RUN_TAG="$(basename "$RUN_DIR")"
mkdir -p "$RUN_DIR"

SERVER_PID=""
SERVER_CHILD_PID=""
CLIENT_PID=""
PIDSTAT_PID=""
CLIENT_PIDSTAT_PID=""
CLIENT_RC=""

NETEM_SERVER_SENT=0;  NETEM_SERVER_DROPPED=0
NETEM_CLIENT_SENT=0;  NETEM_CLIENT_DROPPED=0
observed_loss_pct() {
    awk -v s="$1" -v d="$2" \
        'BEGIN { t = s + d; if (t > 0) printf "%.2f", (d / t) * 100; else printf "0" }'
}
capture_netem_stats() {
    [[ -z "${RUN_DIR:-}" || ! -d "$RUN_DIR" ]] && return 0
    local ns dev out line
    for spec in "$NS_SERVER:$VETH_SERVER:netem_server.txt:SERVER" \
                "$NS_CLIENT:$VETH_CLIENT:netem_client.txt:CLIENT"; do
        IFS=: read -r ns dev out side <<<"$spec"
        ip netns exec "$ns" tc -s qdisc show dev "$dev" \
            > "$RUN_DIR/$out" 2>/dev/null || true
        line=$(awk '
            /Sent/ {
                sent = 0; dropped = 0
                for (i = 1; i <= NF; i++) {
                    if ($i == "pkt")              sent    = $(i-1) + 0
                    if ($i ~ /^\(dropped$/)       dropped = $(i+1) + 0
                }
                printf "%d %d", sent, dropped; exit
            }' "$RUN_DIR/$out" 2>/dev/null)
        local sent="${line%% *}" dropped="${line##* }"
        [[ -z "$sent"    || ! "$sent"    =~ ^[0-9]+$ ]] && sent=0
        [[ -z "$dropped" || ! "$dropped" =~ ^[0-9]+$ ]] && dropped=0
        eval "NETEM_${side}_SENT=$sent; NETEM_${side}_DROPPED=$dropped"
    done
    local s_loss c_loss
    s_loss=$(observed_loss_pct "$NETEM_SERVER_SENT" "$NETEM_SERVER_DROPPED")
    c_loss=$(observed_loss_pct "$NETEM_CLIENT_SENT" "$NETEM_CLIENT_DROPPED")
    echo "[netem] observed loss: server=${s_loss}% (${NETEM_SERVER_DROPPED}/$((NETEM_SERVER_SENT + NETEM_SERVER_DROPPED))) client=${c_loss}% (${NETEM_CLIENT_DROPPED}/$((NETEM_CLIENT_SENT + NETEM_CLIENT_DROPPED))) | configured=${LOSS} delay=${DELAY}" >&2
}

write_metadata() {
    local profiled_json="false" perf_json="null" flame_json="null"
    [[ "$PROFILE" -eq 1 ]] && profiled_json="true"
    [[ -f "$RUN_DIR/perf.data"      ]] && perf_json="\"perf.data\""
    [[ -f "$RUN_DIR/flamegraph.svg" ]] && flame_json="\"flamegraph.svg\""
    local rc_json="null"
    [[ -n "$CLIENT_RC" ]] && rc_json="$CLIENT_RC"
    printf '%s\n' "{
  \"schema_version\": 1,
  \"run_tag\": \"${RUN_TAG}\",
  \"timestamp_start\": \"${RUN_STAMP}\",
  \"sweep_stamp\": \"${SWEEP_STAMP}\",
  \"profile\": \"${TAG_PROFILE}\",
  \"runtime\": \"${TAG_RUNTIME}\",
  \"protocol\": \"${RUN_PROTOCOL}\",
  \"protocol_variant\": \"${TAG_VARIANT}\",
  \"packet_loss_pct\": ${LOSS_PCT:-0},
  \"delay_ms\": ${DELAY_MS:-0},
  \"netem\": {
    \"configured_loss\": \"${LOSS}\",
    \"configured_loss_spec\": \"${LOSS_SPEC}\",
    \"configured_delay\": \"${DELAY}\",
    \"server_sent_pkt\": ${NETEM_SERVER_SENT:-0},
    \"server_dropped_pkt\": ${NETEM_SERVER_DROPPED:-0},
    \"server_observed_loss_pct\": $(observed_loss_pct "${NETEM_SERVER_SENT:-0}" "${NETEM_SERVER_DROPPED:-0}"),
    \"client_sent_pkt\": ${NETEM_CLIENT_SENT:-0},
    \"client_dropped_pkt\": ${NETEM_CLIENT_DROPPED:-0},
    \"client_observed_loss_pct\": $(observed_loss_pct "${NETEM_CLIENT_SENT:-0}" "${NETEM_CLIENT_DROPPED:-0}")
  },
  \"duration_sec\": ${DURATION},
  \"concurrency\": ${RUN_CONCURRENCY:-0},
  \"server_port\": ${SERVER_PORT},
  \"server_cmd\": \"${SERVER_CMD}\",
  \"server_cores\": \"${SERVER_CORES}\",
  \"client_cores\": \"${CLIENT_CORES}\",
  \"profiled\": ${profiled_json},
  \"client_rc\": ${rc_json},
  \"files\": {
    \"server_log\": \"server.log\",
    \"client_log\": \"client.log\",
    \"server_pidstat\": \"server_pidstat.log\",
    \"client_pidstat\": \"client_pidstat.log\",
    \"rtts\": \"rtts.csv\",
    \"connects\": \"connects.csv\",
    \"netem_server\": \"netem_server.txt\",
    \"netem_client\": \"netem_client.txt\",
    \"perf_data\": ${perf_json},
    \"flamegraph\": ${flame_json}
  }
}" > "$RUN_DIR/metadata.json"
}

cleanup() {
    local ec=$?
    set +e
    echo "[cleanup] tearing down..." >&2

    [[ -n "$CLIENT_PID"         ]] && kill -TERM "$CLIENT_PID"         2>/dev/null
    [[ -n "$SERVER_PID"         ]] && kill -TERM "$SERVER_PID"         2>/dev/null
    [[ -n "$PIDSTAT_PID"        ]] && kill -TERM "$PIDSTAT_PID"        2>/dev/null
    [[ -n "$CLIENT_PIDSTAT_PID" ]] && kill -TERM "$CLIENT_PIDSTAT_PID" 2>/dev/null
    [[ -n "$SERVER_CHILD_PID"   ]] && kill -TERM "$SERVER_CHILD_PID"   2>/dev/null
    wait 2>/dev/null

    capture_netem_stats

    if [[ "${PROFILE:-0}" -eq 1 && -f "${PERF_DATA:-}" ]]; then
        echo "[cleanup] perf.data found; rendering flamegraph..." >&2
        local COLLAPSED="$RUN_DIR/flamegraph_collapsed.txt"
        if perf script -i "$PERF_DATA" --demangle \
                | stackcollapse-perf.pl > "$COLLAPSED" 2>"$RUN_DIR/flamegraph.err"; then
            local TOTAL_SAMPLES
            TOTAL_SAMPLES=$(grep -oE '\([0-9]+ samples\)' "$SERVER_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+')
            TOTAL_SAMPLES="${TOTAL_SAMPLES:-unknown}"

            local fg_title_args=()
            if [[ -n "${LABEL:-}" ]]; then
                fg_title_args=(--title "$LABEL - Server CPU" \
                               --subtitle "perf -F99 -g | loss=${LOSS} delay=${DELAY} | n=${TOTAL_SAMPLES} samples | ${RUN_TAG}")
            fi
            if flamegraph.pl "${fg_title_args[@]}" --hash --minwidth 1 \
                    --countname "samples (perf -F99)" \
                    "$COLLAPSED" > "$RUN_DIR/flamegraph.svg" 2>>"$RUN_DIR/flamegraph.err"; then
                echo "[cleanup] wrote $RUN_DIR/flamegraph.svg" >&2
                rm -f "$RUN_DIR/flamegraph.err"
            else
                echo "[cleanup] WARN: flamegraph.pl failed; see $RUN_DIR/flamegraph.err" >&2
                rm -f "$RUN_DIR/flamegraph.svg"
            fi
        else
            echo "[cleanup] WARN: perf script/stackcollapse-perf.pl failed; see $RUN_DIR/flamegraph.err" >&2
        fi

        if [[ "$PROFILE" -eq 1 && ( "$RUNTIME" == "node" || "$RUNTIME" == "deno" ) \
                && -n "$SERVER_CHILD_PID" ]]; then
            rm -f "/tmp/perf-${SERVER_CHILD_PID}.map"
        fi
    fi

    [[ -d "${RUN_DIR:-}" ]] && write_metadata

    ip netns del "$NS_SERVER" 2>/dev/null
    ip netns del "$NS_CLIENT" 2>/dev/null
    ip link del "$VETH_SERVER" 2>/dev/null
    ip link del "$VETH_CLIENT" 2>/dev/null

    exit "$ec"
}
trap cleanup EXIT INT TERM

echo "[setup] creating namespaces and veth pair..." >&2

ip netns del "$NS_SERVER" 2>/dev/null || true
ip netns del "$NS_CLIENT" 2>/dev/null || true
ip link  del "$VETH_SERVER" 2>/dev/null || true
ip link  del "$VETH_CLIENT" 2>/dev/null || true

ip netns add "$NS_SERVER"
ip netns add "$NS_CLIENT"

ip link add "$VETH_SERVER" type veth peer name "$VETH_CLIENT"
ip link set "$VETH_SERVER" netns "$NS_SERVER"
ip link set "$VETH_CLIENT" netns "$NS_CLIENT"

ip -n "$NS_SERVER" addr add "${SERVER_IP}/${SUBNET_PREFIX}" dev "$VETH_SERVER"
ip -n "$NS_CLIENT" addr add "${CLIENT_IP}/${SUBNET_PREFIX}" dev "$VETH_CLIENT"

ip -n "$NS_SERVER" link set "$VETH_SERVER" up
ip -n "$NS_CLIENT" link set "$VETH_CLIENT" up
ip -n "$NS_SERVER" link set lo up
ip -n "$NS_CLIENT" link set lo up

NETEM_LOSS_ARGS=(loss "$LOSS")
if [[ -n "$LOSS_SPEC" ]]; then
    NETEM_LOSS_ARGS=(loss $LOSS_SPEC)
fi
echo "[setup] applying netem: delay=${DELAY} ${NETEM_LOSS_ARGS[*]} (nominal loss=${LOSS}, both directions)" >&2
ip netns exec "$NS_SERVER" tc qdisc add dev "$VETH_SERVER" root netem \
    delay "$DELAY" "${NETEM_LOSS_ARGS[@]}"
ip netns exec "$NS_CLIENT" tc qdisc add dev "$VETH_CLIENT" root netem \
    delay "$DELAY" "${NETEM_LOSS_ARGS[@]}"

if ! ip netns exec "$NS_CLIENT" ping -c5 -W2 "$SERVER_IP" >/dev/null; then
    echo "[setup] sanity ping failed (0/5 replies); aborting." >&2
    exit 1
fi

export SERVER_IP CLIENT_IP SERVER_PORT
SERVER_LOG="$RUN_DIR/server.log"
CLIENT_LOG="$RUN_DIR/client.log"
PIDSTAT_LOG="$RUN_DIR/server_pidstat.log"

PERF_DATA="$RUN_DIR/perf.data"
PERF_PREFIX=()
if [[ "$PROFILE" -eq 1 ]]; then
    PERF_PREFIX=(perf record -F 99 -g -o "$PERF_DATA" --)
fi

if [[ "$PROFILE" -eq 1 && "$RUNTIME" == "node" ]]; then
    SERVER_CMD="node --perf-basic-prof --interpreted-frames-native-stack ${SERVER_CMD#node }"
fi
if [[ "$PROFILE" -eq 1 && "$RUNTIME" == "deno" ]]; then
    SERVER_CMD="${SERVER_CMD/#deno run /deno run --v8-flags=--perf-basic-prof,--interpreted-frames-native-stack }"
fi

echo "[run] cpu pinning: server=${SERVER_CORES:-any} client=${CLIENT_CORES:-any}" >&2
[[ "$PROFILE" -eq 1 ]] && echo "[run] profiling enabled: perf record -F 99 -g -> $PERF_DATA" >&2
[[ "$PROFILE" -eq 1 && ( "$RUNTIME" == "node" || "$RUNTIME" == "deno" ) ]] \
    && echo "[run] V8 JIT symbol-map flags injected for $RUNTIME" >&2
echo "[run] launching server in $NS_SERVER -> $SERVER_LOG" >&2
if [[ -n "$SERVER_CORES" ]]; then
    taskset -c "$SERVER_CORES" ip netns exec "$NS_SERVER" env \
        SERVER_IP="$SERVER_IP" SERVER_PORT="$SERVER_PORT" \
        "${PERF_PREFIX[@]}" bash -c "$SERVER_CMD" >"$SERVER_LOG" 2>&1 &
else
    ip netns exec "$NS_SERVER" env \
        SERVER_IP="$SERVER_IP" SERVER_PORT="$SERVER_PORT" \
        "${PERF_PREFIX[@]}" bash -c "$SERVER_CMD" >"$SERVER_LOG" 2>&1 &
fi
SERVER_PID=$!

sleep 1

if [[ "$PROFILE" -eq 1 ]]; then
    SERVER_CHILD_PID="$(pgrep -P "$SERVER_PID" 2>/dev/null | head -n1 || true)"
fi

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[run] server failed to start; see $SERVER_LOG" >&2
    exit 1
fi

PIDSTAT_TARGET="$SERVER_PID"
[[ "$PROFILE" -eq 1 && -n "$SERVER_CHILD_PID" ]] && PIDSTAT_TARGET="$SERVER_CHILD_PID"
echo "[run] starting pidstat (interval=${PIDSTAT_INTERVAL}s) -> $PIDSTAT_LOG" >&2
pidstat -h -r -u -p "$PIDSTAT_TARGET" "$PIDSTAT_INTERVAL" >"$PIDSTAT_LOG" 2>&1 &
PIDSTAT_PID=$!

echo "[run] launching client in $NS_CLIENT for ${DURATION}s -> $CLIENT_LOG" >&2
if [[ -n "$CLIENT_CORES" ]]; then
    taskset -c "$CLIENT_CORES" ip netns exec "$NS_CLIENT" env \
        SERVER_IP="$SERVER_IP" CLIENT_IP="$CLIENT_IP" SERVER_PORT="$SERVER_PORT" \
        DURATION="$DURATION" RESULTS_DIR="$RUN_DIR" \
        RUN_PROFILE="$BENCH_PROFILE" RUN_RUNTIME="$RUNTIME" RUN_VARIANT="$VARIANT" \
        RUN_LOSS_PCT="$LOSS_PCT" RUN_DELAY_MS="$DELAY_MS" \
        bash -c "$CLIENT_CMD" >"$CLIENT_LOG" 2>&1 &
else
    ip netns exec "$NS_CLIENT" env \
        SERVER_IP="$SERVER_IP" CLIENT_IP="$CLIENT_IP" SERVER_PORT="$SERVER_PORT" \
        DURATION="$DURATION" RESULTS_DIR="$RUN_DIR" \
        RUN_PROFILE="$BENCH_PROFILE" RUN_RUNTIME="$RUNTIME" RUN_VARIANT="$VARIANT" \
        RUN_LOSS_PCT="$LOSS_PCT" RUN_DELAY_MS="$DELAY_MS" \
        bash -c "$CLIENT_CMD" >"$CLIENT_LOG" 2>&1 &
fi
CLIENT_PID=$!

CLIENT_PIDSTAT_LOG="$RUN_DIR/client_pidstat.log"
echo "[run] starting client pidstat (interval=${PIDSTAT_INTERVAL}s) -> $CLIENT_PIDSTAT_LOG" >&2
pidstat -h -r -u -p "$CLIENT_PID" "$PIDSTAT_INTERVAL" >"$CLIENT_PIDSTAT_LOG" 2>&1 &
CLIENT_PIDSTAT_PID=$!

wait "$CLIENT_PID"
CLIENT_RC=$?

kill -TERM "$CLIENT_PIDSTAT_PID" 2>/dev/null
wait "$CLIENT_PIDSTAT_PID" 2>/dev/null || true
CLIENT_PIDSTAT_PID=""

if [[ -f "$CLIENT_PIDSTAT_LOG" ]]; then
    CORE_COUNT=1
    if [[ -n "$CLIENT_CORES" ]]; then
        CORE_COUNT=$(echo "$CLIENT_CORES" | tr ',' '\n' | wc -l)
    fi
    THRESHOLD=$(awk -v c="$CORE_COUNT" 'BEGIN { printf "%d", c * 90 }')

    AVG_CPU=$(awk '
        /^#/      { next }
        /^[0-9]/  { if ($9+0 > 0) { sum += $9; n++ } }
        END       { if (n > 0) printf "%.1f", sum/n; else print "0" }
    ' "$CLIENT_PIDSTAT_LOG")

    PEAK_CPU=$(awk '
        /^#/      { next }
        /^[0-9]/  { if ($9+0 > max) max = $9 }
        END       { printf "%.1f", max+0 }
    ' "$CLIENT_PIDSTAT_LOG")

    if awk -v avg="$AVG_CPU" -v peak="$PEAK_CPU" -v thr="$THRESHOLD" \
            'BEGIN { exit !(avg >= thr || peak >= thr) }'; then
        echo "" >&2
        echo "╔══════════════════════════════════════════════════════════════════╗" >&2
        echo "║  !! WARNING: CLIENT CPU SATURATION DETECTED                   !!" >&2
        echo "║  avg=${AVG_CPU}%  peak=${PEAK_CPU}%  threshold=${THRESHOLD}% (${CORE_COUNT} core(s) x 90%)" >&2
        echo "║  The load generator may be the bottleneck.                      ║" >&2
        echo "║  Benchmark data for this run may be INVALID.                    ║" >&2
        echo "╚══════════════════════════════════════════════════════════════════╝" >&2
        echo "" >&2
    else
        echo "[run] client cpu ok: avg=${AVG_CPU}% peak=${PEAK_CPU}% (threshold=${THRESHOLD}%)" >&2
    fi
fi

echo "[run] client exited rc=$CLIENT_RC; results in $RUN_DIR" >&2
exit "$CLIENT_RC"
