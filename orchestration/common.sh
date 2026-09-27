#!/usr/bin/env bash
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUNTIMES=(node deno bun)
PROTOCOLS_NODE=(ws sse short-polling long-polling webtransport-fails-components webtransport-datagram)
PROTOCOLS_BUN=(ws sse short-polling long-polling webtransport-vmeansdev webtransport-datagram)
PROTOCOLS_DENO=(ws sse short-polling long-polling webtransport webtransport-datagram)
BASE_PORT=8080

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
fail()   { red "FAIL: $*" >&2; exit 1; }
ok()     { green "OK:   $*"; }

proto_to_base() {
    case "$1" in
        ws)                            echo "websocket" ;;
        sse)                           echo "sse" ;;
        short-polling)                 echo "short-polling" ;;
        long-polling)                  echo "long-polling" ;;
        webtransport)                  echo "webtransport" ;;
        webtransport-fails-components) echo "webtransport-fails-components" ;;
        webtransport-vmeansdev)        echo "webtransport-vmeansdev" ;;
        webtransport-datagram)         echo "webtransport-datagram" ;;
    esac
}

check_sources() {
    local runtime="$1" ext="$2"
    shift 2
    for proto in "$@"; do
        local base path
        base=$(proto_to_base "$proto")
        path="$REPO_ROOT/servers/$runtime/$base.$ext"
        [[ -f "$path" ]] || fail "server source missing: $path"
    done
}

server_cmd_for() {
    local runtime="$1" proto="$2"
    local base
    base=$(proto_to_base "$proto")
    case "$runtime" in
        node) echo "node $REPO_ROOT/servers/node/$base.js" ;;
        deno)
            if [[ "$proto" == "webtransport" || "$proto" == "webtransport-datagram" ]]; then
                echo "deno run --allow-net --allow-env --allow-read --unstable-net $REPO_ROOT/servers/deno/$base.ts"
            else
                echo "deno run --allow-net --allow-env --allow-read $REPO_ROOT/servers/deno/$base.ts"
            fi
            ;;
        bun) echo "bun $REPO_ROOT/servers/bun/$base.ts" ;;
    esac
}

client_cmd_for() {
    local proto="$1" duration="$2" clients="$3" client_script="$4" workers="${5:-0}"
    (( workers > 0 )) || workers="$clients"
    local client_proto="$proto" wt_flag=""
    if [[ "$proto" == "webtransport-datagram" ]]; then
        client_proto="webtransport-datagram"; wt_flag="--unstable-net"
    elif [[ "$proto" == webtransport* ]]; then
        client_proto="webtransport"; wt_flag="--unstable-net"
    fi
    echo "deno run --allow-net --allow-read --allow-write --allow-env --unsafely-ignore-certificate-errors $wt_flag \
        $client_script \
        --target \$SERVER_IP:\$SERVER_PORT \
        --protocol $client_proto \
        --duration $duration \
        --clients $clients \
        --workers $workers"
}

run_preflight() {
    [[ $EUID -eq 0 ]] || fail "must be run as root (ip netns / tc require CAP_NET_ADMIN)"

    [[ -x "${RUN_TEST:?}" ]]      || fail "harness_run_test.sh not found or not executable: $RUN_TEST"
    [[ -f "${CLIENT_SCRIPT:?}" ]] || fail "load_generator.ts not found: $CLIENT_SCRIPT"

    for bin in node deno bun pidstat taskset; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            case "$bin" in
                deno)    fail "deno not on PATH. Install: curl -fsSL https://deno.land/install.sh | sh" ;;
                bun)     fail "bun not on PATH. Install: curl -fsSL https://bun.sh/install | bash" ;;
                node)    fail "node not on PATH. Install Node.js >= 20." ;;
                pidstat) fail "pidstat not on PATH. Install: apt-get install sysstat" ;;
                taskset) fail "taskset not on PATH. Install: apt-get install util-linux" ;;
            esac
        fi
    done

    check_sources node js "${PROTOCOLS_NODE[@]}"
    check_sources bun  ts "${PROTOCOLS_BUN[@]}"
    check_sources deno ts "${PROTOCOLS_DENO[@]}"

    if [[ ! -d "$REPO_ROOT/servers/node/node_modules/ws" ]]; then
        fail "ws not installed. Run: (cd $REPO_ROOT/servers/node && npm install)"
    fi
    if [[ ! -d "$REPO_ROOT/servers/node/node_modules/@fails-components/webtransport" ]]; then
        fail "@fails-components/webtransport not installed in node. Run: (cd $REPO_ROOT/servers/node && npm install)"
    fi
    if [[ ! -d "$REPO_ROOT/servers/bun/node_modules/@webtransport-bun" ]]; then
        fail "@webtransport-bun/webtransport not installed. Run: (cd $REPO_ROOT/servers/bun && bun install)"
    fi

    [[ -f "$REPO_ROOT/servers/cert.pem" && -f "$REPO_ROOT/servers/key.pem" ]] \
        || fail "servers/cert.pem or key.pem missing. Run: $REPO_ROOT/servers/gen_cert.sh"
    if command -v openssl >/dev/null 2>&1 \
            && ! openssl x509 -checkend 0 -noout -in "$REPO_ROOT/servers/cert.pem" >/dev/null 2>&1; then
        yellow "WARN: servers/cert.pem is expired (tolerated, but consider: $REPO_ROOT/servers/gen_cert.sh)"
    fi

    ok "pre-flight checks passed (node, deno, bun, pidstat, cert, all server sources)"
}
