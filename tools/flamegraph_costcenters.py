#!/usr/bin/env python3
from __future__ import annotations

import collections
import csv
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PROFILING = REPO / "results" / "profiling"
SYMBOLIZED = REPO / "results" / "profiling_symbolized"
OUT = REPO / "tables"

CELLS = {
    "node": {"ws": "ws", "wtstream": "webtransport-fails-components", "wtdgram": "webtransport-datagram"},
    "deno": {"ws": "ws", "wtstream": "webtransport", "wtdgram": "webtransport-datagram"},
    "bun":  {"ws": "ws", "wtstream": "webtransport-vmeansdev", "wtdgram": "webtransport-datagram"},
}

RUNTIME_ORDER = ["node", "deno", "bun"]
PROTO_ORDER = ["ws", "wtstream", "wtdgram"]

KERNEL = "kernel (syscall/softirq)"
QUIC = "QUIC engine"
TOKIO = "async runtime (tokio)"
JS = "JS engine + JIT"
GC = "garbage collection"
TLSREC = "TLS record layer"
CRYPTO = "TLS crypto (AEAD)"
BINDINGS = "runtime bindings/ops"
LIBC = "libc (alloc + other)"
UNSYM = "unsymbolized runtime"
LOGGING = "tracing/log filtering"
OTHER = "unclassified"

KERNEL_ENTRY = re.compile(
    r"^(entry_SYSCALL|entry_SYSENTER|entry_INT80|syscall_return|"
    r"asm_|error_entry|irq_entries_start|__irqentry|common_interrupt|sysvec_|"
    r"do_softirq|__do_softirq|handle_softirqs|xen_hypercall)"
)

LOG_ANCESTOR = re.compile(r"(tracing::span|tracing4span|log::Log|CliLogger|env_filter)")

LEAF_RULES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"^\["), UNSYM),
    (re.compile(r"(ConcurrentMarking|MarkingVisitor|MarkCompact|MinorMS|Scavenger|"
                r"Sweeper|IncrementalMarking|Heap::|GCTracer|CollectGarbage|"
                r"RecordWrite|WriteBarrier|FreeList|"
                r"MarkedSpace|MarkedBlock|SlotVisitor|ConservativeRoots|"
                r"BlockDirectory|IsoSubspace|MarkingConstraint|WeakSet|"
                r"forEachWeakInParallel)"), GC),
    (re.compile(r"(^JS:|^Builtins_|^LazyCompile|^Interpreter|^Stub:|^RegExp|"
                r"v8::|v8impl::|v8__)"), JS),
    (re.compile(r"(JSC::|^llint_|^ipint_|^vmEntryTo|sanitizeStackForVM|"
                r"Bun__JSValue__call|jsc\.event_loop\.drainMicrotasks)"), JS),
    (re.compile(r"(quiche|quic::|quinn|wtransport|absl|halfsiphash|SIPHASH|"
                r"\bnative::|\d+native(13|7|6)[a-z_]|session_registry)"), QUIC),
    (re.compile(r"(tokio|futures_util|futures_core|crossbeam|parking_lot|"
                r"\bmio::|dashmap|lock_contended)"), TOKIO),
    (re.compile(r"(^tls_|^tls1|^tls13_|^ssl3|^ssl_|^SSL_|^WPACKET|^PACKET_|^BIO_|"
                r"^ossl_|^OPENSSL|^ERR_|^RAND_|^EVP_|^X509|^ASN1|^d2i_|^i2d_|"
                r"rustls|deframer|zeroize|"
                r"bssl::(tls|dtls|ssl|do_seal_record|do_open_record))"), TLSREC),
    (re.compile(r"(aes|AES|gcm|GCM|chacha|poly1305|sha1|sha256|sha512|SHA1|SHA256|"
                r"SHA512|ring_core|aws_lc|^BN_|^EC_|^ec_|x25519|curve25519|"
                r"^md5|hmac|HMAC|CRYPTO_)"), CRYPTO),
    (re.compile(r"(napi|Napi|node::|^uv__|^uv_|deno_core|deno_websocket|deno_|"
                r"fastwebsockets|simdutf|WTF::|rusty_v8|"
                r"^uWS::|^uws_sys\.|^us_socket|^us_internal|^us_loop|^us_poll|"
                r"^us_new|^us_create|^us_timer|^jsc\.|^bun\.|^webcore\.|WebCore::)"),
     BINDINGS),
    (re.compile(r"^(malloc|free|cfree|realloc|calloc|_int_malloc|_int_free|"
                r"_int_realloc|malloc_consolidate|unlink_chunk|sysmalloc|arena_|"
                r"tcache|_mid_memalign|memalign|operator new|operator delete|"
                r"_Znwm|_Znam|_ZdlPv|_ZdaPv|__libc_malloc|__libc_free)"), LIBC),
    (re.compile(r"^(__|_)?(mem|str|printf|vsnprintf|vfprintf|snprintf|itoa|pthread|"
                r"libc|GI_|lll_|futex|clock_|gettime|errno|send|recv|read|write|"
                r"epoll|ioctl|fcntl|close|open|poll|select|sigaction|dl_|"
                r"tls_get_addr|cxa|Unwind|gnu_|inet_pton|inet_ntop|qsort|bsearch)"), LIBC),
]

def classify(frames: list[str]) -> str:
    for f in frames:
        if KERNEL_ENTRY.match(f):
            return KERNEL
    leaf = frames[-1]
    for pattern, bucket in LEAF_RULES:
        if pattern.search(leaf):
            return bucket
    if any(LOG_ANCESTOR.search(f) for f in frames):
        return LOGGING
    return OTHER

def find_run(runtime: str, protocol: str) -> Path:
    base = SYMBOLIZED if runtime in ("deno", "bun") else PROFILING
    matches = []
    for d in sorted(base.iterdir()):
        parts = d.name.split("__")
        if (d.is_dir() and len(parts) > 3 and parts[2] == runtime
                and parts[3] == protocol and (d / "flamegraph_collapsed.txt").exists()):
            matches.append(d)
    if not matches:
        raise SystemExit(f"no collapsed stacks for {runtime}/{protocol}")
    return matches[0]

def mean_server_cpu(run: Path) -> float:
    vals = []
    for line in (run / "server_pidstat.log").read_text().splitlines():
        parts = line.split()
        if len(parts) > 9 and parts[0][:1].isdigit():
            try:
                vals.append(float(parts[8]))
            except ValueError:
                pass
    steady = [v for v in vals if v > 5]
    if not steady:
        raise SystemExit(f"no steady-state pidstat samples in {run}")
    return sum(steady) / len(steady)

def throughput_table() -> dict[tuple[str, str], float]:
    thr = {}
    for base in (PROFILING, SYMBOLIZED):
        path = base / "metrics.csv"
        if not path.exists():
            continue
        for row in csv.DictReader(path.open()):
            thr[(row["Runtime"], row["ProtocolVariant"])] = float(row["Throughput"])
    return thr

def analyse(run: Path) -> tuple[dict[str, float], dict[str, float]]:
    buckets: collections.Counter = collections.Counter()
    threads: collections.Counter = collections.Counter()
    total = 0
    for line in (run / "flamegraph_collapsed.txt").read_text().splitlines():
        if not line.strip():
            continue
        stack, _, weight = line.rpartition(" ")
        n = int(weight)
        total += n
        frames = stack.split(";")
        buckets[classify(frames)] += n
        threads[frames[0]] += n
    return ({k: 100 * v / total for k, v in buckets.items()},
            {k: 100 * v / total for k, v in threads.most_common()})

ROW_ORDER = [KERNEL, QUIC, TOKIO, JS, GC, TLSREC, CRYPTO, BINDINGS, LOGGING,
             LIBC, UNSYM, OTHER]
TEX_LABEL = {
    KERNEL: r"Kernel",
    QUIC: r"QUIC engine",
    TOKIO: r"\texttt{tokio}",
    JS: r"JS engine + JIT",
    GC: r"Garbage collection",
    TLSREC: r"TLS record layer",
    CRYPTO: r"TLS crypto",
    BINDINGS: r"Bindings/ops",
    LOGGING: r"Log filtering",
    LIBC: r"\texttt{libc}",
    UNSYM: r"Unsymbolized",
    OTHER: r"Unclassified",
}
ALWAYS_KEEP = {CRYPTO, OTHER}
KEEP_THRESHOLD = 1.5

def main() -> None:
    thr = throughput_table()
    cells: dict[tuple[str, str], dict] = {}

    for runtime in RUNTIME_ORDER:
        for proto in PROTO_ORDER:
            variant = CELLS[runtime][proto]
            run = find_run(runtime, variant)
            shares, threads = analyse(run)
            cpu = mean_server_cpu(run)
            tput = thr[(runtime, variant)]
            cells[(runtime, proto)] = {
                "run": run.name,
                "cpu_pct": cpu,
                "throughput": tput,
                "us_per_msg": cpu * 1e4 / tput,
                "shares": shares,
                "threads": threads,
            }

    order = [(rt, p) for rt in RUNTIME_ORDER for p in PROTO_ORDER]

    print(f"{'cell':16} {'msg/s':>9} {'CPU%':>6} {'us/msg':>7}  top cost centers (exclusive %)")
    for key in order:
        c = cells[key]
        top = ", ".join(f"{k.split(' (')[0]} {v:.0f}"
                        for k, v in sorted(c["shares"].items(), key=lambda kv: -kv[1])[:5])
        print(f"{key[0] + '/' + key[1]:16} {c['throughput']:9,.0f} {c['cpu_pct']:6.1f} "
              f"{c['us_per_msg']:7.1f}  {top}")

    worst = max(cells[k]["shares"].get(OTHER, 0.0) for k in order)
    gate = "PASS" if worst < 10 else "FAIL"
    print(f"\nunclassified leaf weight: worst cell {worst:.2f}%  [<10% gate: {gate}]")

    print("\nper-message CPU, and the same runtime's WebSocket as the baseline:")
    for runtime in RUNTIME_ORDER:
        ws = cells[(runtime, "ws")]["us_per_msg"]
        print(f"  {runtime:5} ws       {ws:6.1f} us/msg")
        for proto in ("wtstream", "wtdgram"):
            c = cells[(runtime, proto)]
            print(f"  {runtime:5} {proto:9}{c['us_per_msg']:6.1f} us/msg  ({c['us_per_msg'] / ws:.2f}x WS)")

    print("\nstream-vs-datagram per-message deltas, by cost center (us/msg):")
    for runtime in RUNTIME_ORDER:
        s, d = cells[(runtime, "wtstream")], cells[(runtime, "wtdgram")]
        total = d["us_per_msg"] - s["us_per_msg"]
        print(f"  {runtime}: datagram - stream = {total:+.1f} us/msg")
        deltas = []
        for b in ROW_ORDER:
            dv = (d["us_per_msg"] * d["shares"].get(b, 0) / 100
                  - s["us_per_msg"] * s["shares"].get(b, 0) / 100)
            if abs(dv) >= 1.0:
                deltas.append((dv, b))
        for dv, b in sorted(deltas, key=lambda t: -abs(t[0])):
            share = 100 * dv / total if total else 0
            print(f"      {dv:+6.1f}  ({share:+5.0f}% of the gap)  {b}")

    print("\nthread-name shares:")
    for runtime in RUNTIME_ORDER:
        for proto in PROTO_ORDER:
            t = cells[(runtime, proto)]["threads"]
            named = ", ".join(f"{k} {v:.1f}%" for k, v in list(t.items())[:3])
            print(f"  {runtime}/{proto:9} {named}")

    OUT.mkdir(parents=True, exist_ok=True)
    csv_path = OUT / "table_costcenters.csv"
    with csv_path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["Runtime", "Protocol", "Run", "Throughput", "MeanCPUPct", "CPUusPerMsg"]
                   + [f"pct_{b}" for b in ROW_ORDER]
                   + [f"usPerMsg_{b}" for b in ROW_ORDER])
        for runtime, proto in order:
            c = cells[(runtime, proto)]
            pcts = [c["shares"].get(b, 0.0) for b in ROW_ORDER]
            w.writerow([runtime, proto, c["run"], f"{c['throughput']:.3f}",
                        f"{c['cpu_pct']:.2f}", f"{c['us_per_msg']:.3f}"]
                       + [f"{p:.3f}" for p in pcts]
                       + [f"{c['us_per_msg'] * p / 100:.3f}" for p in pcts])
    print(f"\nwrote {csv_path.relative_to(REPO)}")

    def fmt(key: tuple[str, str], bucket: str) -> str:
        v = cells[key]["shares"].get(bucket, 0.0)
        if v == 0.0:
            return "--"
        return r"$<$1" if v < 0.5 else f"{v:.0f}"

    rows = [b for b in ROW_ORDER
            if b in ALWAYS_KEEP or max(cells[k]["shares"].get(b, 0.0) for k in order) >= KEEP_THRESHOLD]
    dropped = [b for b in ROW_ORDER if b not in rows]

    lines = [
        r"\begin{tabular}{@{}l rrr rrr rrr@{}}",
        r"  \toprule",
        r"  & \multicolumn{3}{c}{Node.js} & \multicolumn{3}{c}{Deno} & \multicolumn{3}{c}{Bun} \\",
        r"  \cmidrule(lr){2-4} \cmidrule(lr){5-7} \cmidrule(lr){8-10}",
        r"  Cost center & WS & St & Dg & WS & St & Dg & WS & St & Dg \\",
        r"  \midrule",
    ]
    for bucket in rows:
        lines.append(f"  {TEX_LABEL[bucket]} & "
                     + " & ".join(fmt(k, bucket) for k in order) + r" \\")
    lines.append(r"  \midrule")
    lines.append(r"  \textbf{CPU $\mu$s/msg} & "
                 + " & ".join(f"{cells[k]['us_per_msg']:.1f}" for k in order) + r" \\")
    lines += [r"  \bottomrule", r"\end{tabular}"]

    tex_path = OUT / "table_costcenters.tex"
    tex_path.write_text("\n".join(lines) + "\n")
    print(f"wrote {tex_path.relative_to(REPO)}"
          + (f"  (rows below {KEEP_THRESHOLD}% omitted: {', '.join(dropped)})" if dropped else ""))

if __name__ == "__main__":
    main()
