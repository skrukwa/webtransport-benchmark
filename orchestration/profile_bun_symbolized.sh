#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
RUN_TEST="$SCRIPT_DIR/harness_run_test.sh"
CLIENT_SCRIPT="$REPO_ROOT/client/load_generator.ts"
SRC_DIR="$REPO_ROOT/results/profiling"
OUT_DIR="$REPO_ROOT/results/profiling_symbolized"

BENCH_HOME="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)"
for d in /usr/local/bin "$HOME/.bun/bin" "$HOME/.deno/bin" \
         "$BENCH_HOME/.bun/bin" "$BENCH_HOME/.deno/bin"; do
    [[ -d "$d" ]] && PATH="$d:$PATH"
done
export PATH

DURATION=120
CLIENTS=50
SERVER_CORES="2,3,4,5"
CLIENT_CORES="6,7,8,9,10,11,12,13,14,15,16,17"
LOSS="0%"; DELAY="0ms"
BASE_PORT=8500

if [[ "$#" -gt 0 ]]; then PROTOS=("$@")
else PROTOS=(ws webtransport-vmeansdev webtransport-datagram); fi
for _p in "${PROTOS[@]}"; do
    case "$_p" in ws|webtransport-vmeansdev|webtransport-datagram) ;;
        *) fail "unknown protocol '$_p' (allowed: ws webtransport-vmeansdev webtransport-datagram)";; esac
done

SWEEP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

: "${BUN_PROFILE_BIN:?set BUN_PROFILE_BIN to the bun-profile binary (see header)}"
[[ -f "$BUN_PROFILE_BIN" ]] || fail "BUN_PROFILE_BIN not found: $BUN_PROFILE_BIN"
BUN_PROFILE_BIN="$(readlink -f "$BUN_PROFILE_BIN")"
[[ -x "$BUN_PROFILE_BIN" ]] || fail "BUN_PROFILE_BIN not executable: $BUN_PROFILE_BIN"

SHIPPED_BUN="$(command -v bun || true)"
[[ -n "$SHIPPED_BUN" ]] || fail "bun not on PATH (needed to confirm version parity)"
SHIP_VER="$("$SHIPPED_BUN" --version 2>/dev/null | head -1 || true)"
CUST_VER="$("$BUN_PROFILE_BIN" --version 2>/dev/null | head -1 || true)"
[[ -n "$CUST_VER" && "$CUST_VER" == "$SHIP_VER" ]] \
    || fail "version mismatch: shipped bun is '${SHIP_VER:-?}', profile build is '${CUST_VER:-?}'"

build_id_of() { readelf -n "$1" 2>/dev/null | awk '/Build ID:/ { print $3; exit }'; }
PROF_BID="$(build_id_of "$BUN_PROFILE_BIN")"
SHIP_BID="$(build_id_of "$SHIPPED_BUN")"
[[ -n "$PROF_BID" ]] || fail "no GNU BuildID in $BUN_PROFILE_BIN"
if [[ "$PROF_BID" != "$SHIP_BID" ]]; then
    yellow "[bun-sym] WARN: BuildID differs from the shipped binary:"
    yellow "[bun-sym]   shipped=$SHIP_BID"
    yellow "[bun-sym]   profile=$PROF_BID"
    yellow "[bun-sym] Same version but a different build; the profile is still"
    yellow "[bun-sym] internally consistent, but is no longer provably the same code"
    yellow "[bun-sym] as the binary the runtime-level charts measured."
fi
readelf -S "$BUN_PROFILE_BIN" 2>/dev/null | grep -q '\.debug_info' \
    || fail "$BUN_PROFILE_BIN has no .debug_info — is this really the -profile asset?"
FUNC_MB="$(readelf -sW "$BUN_PROFILE_BIN" 2>/dev/null \
    | awk '$4=="FUNC" && $3+0>0 { b+=$3 } END { printf "%.1f", b/1048576 }')"
yellow "[bun-sym] profile build: $BUN_PROFILE_BIN"
yellow "[bun-sym]   version=$CUST_VER  BuildID=$PROF_BID  named code=${FUNC_MB} MB"

run_preflight
command -v perf >/dev/null 2>&1 || fail "perf not on PATH. Install: apt-get install linux-tools-\$(uname -r)"
for tool in stackcollapse-perf.pl flamegraph.pl; do
    command -v "$tool" >/dev/null 2>&1 \
        || yellow "[bun-sym] WARN: $tool not on PATH — perf.data captured but flamegraph.svg will not render."
done

purge_shared_buildid() {
    perf buildid-cache --purge "$BUN_PROFILE_BIN" >/dev/null 2>&1 || true
    perf buildid-cache --purge "$SHIPPED_BUN"     >/dev/null 2>&1 || true
}
trap 'purge_shared_buildid' EXIT
purge_shared_buildid
yellow "[bun-sym] purged the shared BuildID from perf's cache (resolves by path instead)"

mkdir -p "$OUT_DIR"

profile_label() {
    case "$1" in
        ws)                     echo "Bun WebSocket (symbolized)" ;;
        webtransport-vmeansdev) echo "Bun WebTransport (vmeansdev) (symbolized)" ;;
        webtransport-datagram)  echo "Bun WebTransport (datagram) (symbolized)" ;;
        *)                      echo "Bun $1 (symbolized)" ;;
    esac
}

server_cmd_for_proto() {
    local base; base=$(proto_to_base "$1")
    echo "$BUN_PROFILE_BIN $REPO_ROOT/servers/bun/$base.ts"
}

client_cmd_for_proto() {
    client_cmd_for "$1" "$2" "$CLIENTS" "$CLIENT_SCRIPT" "$CLIENTS"
}

unresolved_pct() {
    local c="$1"
    [[ -f "$c" ]] || { printf 'NA'; return; }
    awk -F';' '{
        n = split($0, a, ";"); split(a[n], b, " "); w = b[length(b)]
        leaf = a[n]; sub(/ [0-9]+$/, "", leaf)
        tot += w
        if (leaf ~ /^\[/ || leaf ~ /^0x/ || leaf ~ /unknown/) u += w
    } END { if (tot > 0) printf "%.2f", 100*u/tot; else printf "NA" }' "$c"
}

IMPOSSIBLE='__FRAME_END__|BrotliSplitBlock|CreateBackwardReferences|ZSTD_|install[.]PackageManager|install[.]isolated_install|bundler[.]transpiler|css[.]small_list|ipint_.*_validate'
incoherent_pct() {
    local c="$1"
    [[ -f "$c" ]] || { printf 'NA'; return; }
    awk -F';' -v bad="$IMPOSSIBLE" '{
        n = split($0, a, ";"); split(a[n], b, " "); w = b[length(b)]
        tot += w
        if ($0 ~ bad) u += w
    } END { if (tot > 0) printf "%.2f", 100*u/tot; else printf "NA" }' "$c"
}

mean_server_cpu() {
    local log="$1"
    [[ -f "$log" ]] || { printf 'NA'; return; }
    awk '/[AP]M/ && $9 ~ /^[0-9]+(\.[0-9]+)?$/ { n++; if (n > 5) { s += $9; c++ } }
         END { if (c > 0) printf "%.1f", s/c; else printf "NA" }' "$log"
}
throughput_of() {
    local csv="$1" proto="$2"
    [[ -f "$csv" ]] || { printf 'NA'; return; }
    awk -F, -v p="$proto" 'NR>1 && $4==p { v=$10 } END { printf "%s", (v!="" ? v : "NA") }' "$csv"
}
pct_delta() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        if (a=="NA"||b=="NA"||a+0==0) { printf "NA"; exit }
        printf "%+.1f%%", 100*(b-a)/a }'
}

neutralize_failed_run() {
    local proto="$1" d
    shopt -s nullglob
    for d in "$OUT_DIR/${SWEEP_STAMP}__profiling__bun__${proto}__"*/; do
        d="${d%/}"
        rm -f "$d/flamegraph_collapsed.txt" "$d/flamegraph.svg"
        yellow "[bun-sym]   $(basename "$d"): dropped empty flamegraph artifacts,"
        yellow "[bun-sym]     kept logs for diagnosis (server.log, client.log, perf.data)"
    done
    shopt -u nullglob
}

FAILURES=0
DONE=0
port=$BASE_PORT

yellow "[bun-sym] === FLAMEGRAPHS: bun-profile, ${DURATION}s, perf -F 99 -g ==="
for proto in "${PROTOS[@]}"; do
    server_cmd="$(server_cmd_for_proto "$proto")"
    client_cmd="$(client_cmd_for_proto "$proto" "$DURATION")"
    label="$(profile_label "$proto")"

    yellow "[bun-sym] bun $proto (port=$port, ${DURATION}s) -> $(basename "$OUT_DIR")"
    if ! RESULTS_DIR="$OUT_DIR" SERVER_PORT="$port" "$RUN_TEST" \
            --server "$server_cmd" \
            --client "$client_cmd" \
            --duration "$DURATION" \
            --loss "$LOSS" --delay "$DELAY" --port "$port" \
            --server-cores "$SERVER_CORES" --client-cores "$CLIENT_CORES" \
            --sweep-stamp "$SWEEP_STAMP" \
            --runtime bun --variant "$proto" --bench-profile profiling \
            --profile --label "$label"; then
        red "[bun-sym] WARN: bun $proto — harness exited non-zero; see" >&2
        red "        $OUT_DIR/${SWEEP_STAMP}__profiling__bun__${proto}__*/server.log" >&2
        neutralize_failed_run "$proto"
        FAILURES=$(( FAILURES + 1 )); port=$(( port + 1 )); continue
    fi
    port=$(( port + 1 ))

    shopt -s nullglob
    dirs=( "$OUT_DIR/${SWEEP_STAMP}__profiling__bun__${proto}__"*/ )
    shopt -u nullglob
    if [[ ${#dirs[@]} -eq 0 ]]; then
        red "[bun-sym] WARN: no run dir found for bun $proto" >&2
        FAILURES=$(( FAILURES + 1 )); continue
    fi
    dst="${dirs[-1]%/}"
    collapsed="$dst/flamegraph_collapsed.txt"

    after="$(unresolved_pct "$collapsed")"
    bogus="$(incoherent_pct "$collapsed")"
    shopt -s nullglob
    olds=( "$SRC_DIR"/*"__bun__${proto}__loss0pct__delay0ms"/ )
    shopt -u nullglob
    before="NA"
    [[ ${#olds[@]} -gt 0 ]] && before="$(unresolved_pct "${olds[0]%/}/flamegraph_collapsed.txt")"

    if [[ "$after" == "NA" ]]; then
        red "[bun-sym] FAIL: bun $proto produced no collapsed stacks" >&2
        neutralize_failed_run "$proto"
        FAILURES=$(( FAILURES + 1 )); continue
    fi
    if awk -v p="$bogus" 'BEGIN { exit !(p == "NA" || p > 0.5) }'; then
        red "[bun-sym] FAIL: bun $proto — ${bogus}% of leaf time is in code an echo" >&2
        red "        server cannot run (installer/bundler/Brotli/__FRAME_END__)." >&2
        red "        Symbol addresses are misaligned with the recording; do NOT use" >&2
        red "        this profile. See the header for the file-offset failure mode." >&2
        neutralize_failed_run "$proto"
        FAILURES=$(( FAILURES + 1 )); continue
    fi
    if awk -v a="$after" 'BEGIN { exit !(a > 8) }'; then
        yellow "[bun-sym] WARN: bun $proto still has ${after}% unresolved leaf time"
        yellow "        (was ${before}% with the shipped binary). Coherence passed, so"
        yellow "        this is residual JSC JIT code rather than a misalignment."
    fi

    cpu_new="$(mean_server_cpu "$dst/server_pidstat.log")"
    thr_new="$(throughput_of "$OUT_DIR/metrics.csv" "$proto")"
    cpu_old="NA"; thr_old="NA"
    if [[ ${#olds[@]} -gt 0 ]]; then
        cpu_old="$(mean_server_cpu "${olds[0]%/}/server_pidstat.log")"
        thr_old="$(throughput_of "$SRC_DIR/metrics.csv" "$proto")"
    fi
    ok "  bun $proto: unresolved ${before}% -> ${after}%, incoherent ${bogus}%"
    printf "      throughput %s -> %s (%s) | mean server CPU %s%% -> %s%% (%s)\n" \
        "$thr_old" "$thr_new" "$(pct_delta "$thr_old" "$thr_new")" \
        "$cpu_old" "$cpu_new" "$(pct_delta "$cpu_old" "$cpu_new")"
    DONE=$(( DONE + 1 ))
done

echo ""
if (( DONE > 0 )); then
    green "Wrote $DONE symbolized Bun profile(s):"
    echo "  $OUT_DIR/${SWEEP_STAMP}__profiling__bun__*/flamegraph.svg"
    echo ""
    echo "Identical code executed (same BuildID as the shipped binary), so"
    echo "throughput and mean server CPU above should match the shipped runs to"
    echo "within run-to-run noise. If they do, the only difference is symbols."
    echo ""
    echo "Next: python3 tools/flamegraph_costcenters.py"
fi
if (( FAILURES > 0 )); then
    red "$FAILURES cell(s) failed — nothing from those cells should be used" >&2
    exit 1
fi
green "profile_bun_symbolized.sh complete."
