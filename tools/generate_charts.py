#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
import pandas as pd
import seaborn as sns
from matplotlib.legend_handler import HandlerTuple
from matplotlib.lines import Line2D

COL_W_IN = 3.27
FONT_PT = 9

plt.rcParams.update({
    "font.size": FONT_PT,
    "axes.titlesize": FONT_PT,
    "axes.labelsize": FONT_PT,
    "xtick.labelsize": FONT_PT,
    "ytick.labelsize": FONT_PT,
    "legend.fontsize": FONT_PT,
    "legend.title_fontsize": FONT_PT,
    "savefig.dpi": 200,
})

REPO_ROOT = Path(__file__).parent.parent
RESULTS_BASE = REPO_ROOT / "results"
PROFILES = ["ideal", "crossover", "burst_loss"]

RUNTIME_PALETTE = {"Node": "#339933", "Deno": "#1A1A1A", "Bun": "#F472B6"}
LOSSMODEL_PALETTE = {"Uniform 5%": "#4c8eda", "Bursty 5% (GE)": "#e05c5c"}

PROTO_LABELS: dict[str, str] = {
    "ws": "WebSocket",
    "sse": "SSE",
    "short-polling": "Short-Polling",
    "long-polling": "Long-Polling",
    "webtransport": "WebTransport (Stream)",
    "webtransport-vmeansdev": "WebTransport (Stream)",
    "webtransport-fails-components": "WebTransport (Stream)",
    "webtransport-datagram": "WebTransport (Datagram)",
}
RUNTIME_LABELS: dict[str, str] = {"node": "Node", "deno": "Deno", "bun": "Bun"}

RUNTIME_ORDER = ["Bun", "Deno", "Node"]

PROTO_ORDER = [
    "WebSocket",
    "SSE",
    "Short-Polling",
    "Long-Polling",
    "WebTransport (Stream)",
    "WebTransport (Datagram)",
]

PROTO_LABELS_SHORT: dict[str, str] = {
    "WebSocket": "WS",
    "SSE": "SSE",
    "Short-Polling": "Short Poll",
    "Long-Polling": "Long Poll",
    "WebTransport (Stream)": "WT Stream",
    "WebTransport (Datagram)": "WT Datagram",
}

def _style_bar_xaxis(ax, x_order: list[str]) -> None:
    ax.set_xticks(range(len(x_order)))
    ax.set_xticklabels([PROTO_LABELS_SHORT.get(p, p) for p in x_order])
    ax.tick_params(axis="x", rotation=30)
    plt.setp(ax.get_xticklabels(), ha="right", rotation_mode="anchor")

def _short_series(label: str) -> str:
    return (
        label.replace("WT Stream", "WT-S")
        .replace("WT Datagram", "WT-D")
        .replace(" (vmeansdev)", "")
        .replace(" (native)", "")
        .replace(" (fails-components)", "")
    )

class _PlainLogFormatter(ticker.LogFormatterSciNotation):

    def __call__(self, x, pos=None):
        return "" if super().__call__(x, pos) == "" else f"{x:,.0f}"

def _format_log_yaxis(ax) -> None:
    ax.yaxis.set_major_formatter(_PlainLogFormatter())
    ax.yaxis.set_minor_formatter(_PlainLogFormatter(labelOnlyBase=False))

def load_all() -> pd.DataFrame:
    frames: list[pd.DataFrame] = []
    for profile in PROFILES:
        metrics_path = RESULTS_BASE / profile / "metrics.csv"
        if not metrics_path.exists():
            print(f"  [warn] missing {metrics_path} — skipping profile '{profile}'")
            continue
        df = pd.read_csv(metrics_path)
        if "Profile" not in df.columns:
            df["Profile"] = profile
        frames.append(df)

    if not frames:
        print("No benchmark data found. Run orchestration/sweep_benchmark.sh first.")
        sys.exit(1)

    raw = pd.concat(frames, ignore_index=True)

    key_cols = [k for k in
                ["Profile", "Runtime", "ProtocolVariant", "PacketLossPct", "DelayMs"]
                if k in raw.columns]
    if key_cols:
        numeric_cols = [c for c in
                        ["Throughput", "p50_ms", "p95_ms", "p99_ms", "Errors",
                         "Overflows", "MeanConnect_ms", "Concurrency", "DurationSec",
                         "DgramSent", "DgramTimeouts", "DgramTimeoutPct",
                         "DgramTimeoutMs", "MeanReady_ms"]
                        if c in raw.columns]
        for c in numeric_cols:
            raw[c] = pd.to_numeric(raw[c], errors="coerce")
        passthrough = [c for c in raw.columns
                       if c not in key_cols + numeric_cols + ["Timestamp"]]
        agg = {c: "mean" for c in numeric_cols}
        agg.update({c: "first" for c in passthrough})
        result = raw.groupby(key_cols, as_index=False, dropna=False).agg(agg)
        counts = (raw.groupby(key_cols, dropna=False)
                  .size().reset_index(name="NumRuns"))
        result = result.merge(counts, on=key_cols, how="left")
    else:
        result = raw

    return _add_labels(result)

def _add_labels(df: pd.DataFrame) -> pd.DataFrame:
    df["RuntimeLabel"] = df["Runtime"].map(RUNTIME_LABELS)
    df["ProtoLabel"] = df["ProtocolVariant"].map(PROTO_LABELS)
    return df

def load_raw_ideal() -> pd.DataFrame:
    path = RESULTS_BASE / "ideal" / "metrics.csv"
    if not path.exists():
        return pd.DataFrame()
    raw = pd.read_csv(path)
    if "Profile" not in raw.columns:
        raw["Profile"] = "ideal"
    raw["Throughput"] = pd.to_numeric(raw["Throughput"], errors="coerce")
    return _add_labels(raw)

def build_run_dir_map(profile: str) -> dict[tuple[str, str], list[Path]]:
    profile_dir = RESULTS_BASE / profile
    if not profile_dir.exists():
        return {}

    collected: dict[tuple[str, str], list[tuple[str, Path]]] = {}
    for meta_path in profile_dir.glob("*/metadata.json"):
        try:
            meta = json.loads(meta_path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        rc = meta.get("client_rc")
        if rc is not None and rc != 0:
            continue
        key = (meta.get("runtime"), meta.get("protocol_variant"))
        ts = str(meta.get("timestamp_start", ""))
        collected.setdefault(key, []).append((ts, meta_path.parent))
    return {k: [p for _, p in sorted(v)] for k, v in collected.items()}

def write_chart_csv(data, out_dir: Path, stem: str) -> None:
    df = data if isinstance(data, pd.DataFrame) else pd.DataFrame(data)
    path = out_dir / f"{stem}.csv"
    df.to_csv(path, index=False)
    print(f"  wrote {path}")

def parse_pidstat(path: Path) -> list[float]:
    cpu_vals: list[float] = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("Linux"):
                continue
            parts = line.split()
            if len(parts) < 9:
                continue
            try:
                cpu_vals.append(float(parts[8]))
            except ValueError:
                continue
    return cpu_vals

def chart_throughput_by_protocol(df: pd.DataFrame, out_dir: Path) -> None:
    ideal = load_raw_ideal()
    ideal = ideal[ideal["Profile"] == "ideal"].copy()
    if ideal.empty:
        print("  [warn] no ideal data — skipping chart 1")
        return

    ideal = ideal[ideal["ProtoLabel"].notna()].copy()

    present_protos = set(ideal["ProtoLabel"].unique())
    x_order = [p for p in PROTO_ORDER if p in present_protos]

    runtime_order = RUNTIME_ORDER

    fig, ax = plt.subplots(figsize=(COL_W_IN, 3.0), layout="constrained")
    sns.barplot(
        data=ideal,
        x="ProtoLabel",
        y="Throughput",
        hue="RuntimeLabel",
        hue_order=[r for r in runtime_order if r in ideal["RuntimeLabel"].unique()],
        order=x_order,
        palette=RUNTIME_PALETTE,
        ax=ax,
        errorbar="sd",
        err_kws={"linewidth": 0.8},
        capsize=0.15,
    )
    ax.set_yscale("log")
    _format_log_yaxis(ax)
    ax.set_xlabel("Protocol Variant")
    ax.set_ylabel("Throughput (msg/s, log scale)")
    _style_bar_xaxis(ax, x_order)
    ax.legend(title="Runtime", ncol=3, loc="lower center",
              bbox_to_anchor=(0.5, 1.0), columnspacing=1.2, handlelength=1.4)
    ax.grid(axis="y", which="both", linestyle="--", alpha=0.4)
    out_path = out_dir / "chart1_throughput_by_protocol.png"
    fig.savefig(out_path)
    plt.close(fig)
    print(f"  wrote {out_path}")

    csv_df = (
        ideal.groupby(["RuntimeLabel", "ProtocolVariant", "Protocol"], as_index=False)
        .agg(Throughput_msg_s=("Throughput", "mean"),
             Throughput_sd=("Throughput", "std"),
             NumRuns=("Throughput", "size"))
        .rename(columns={"RuntimeLabel": "Runtime"})
        .sort_values(["Runtime", "ProtocolVariant"])
    )
    write_chart_csv(csv_df, out_dir, "chart1_throughput_by_protocol")

def chart_connect_time(df: pd.DataFrame, out_dir: Path) -> None:
    ideal = load_raw_ideal()
    if ideal.empty or "MeanConnect_ms" not in ideal.columns:
        print("  [warn] no MeanConnect_ms column in metrics.csv (pre-instrumentation data) — skipping chart 5")
        return

    ideal = ideal[ideal["Profile"] == "ideal"].copy()
    if ideal.empty:
        print("  [warn] no ideal data — skipping chart 5")
        return

    ideal = ideal[ideal["ProtoLabel"].notna()].copy()
    ideal["MeanConnect_ms"] = pd.to_numeric(ideal["MeanConnect_ms"], errors="coerce")
    ideal = ideal[ideal["MeanConnect_ms"].notna()].copy()
    if ideal.empty:
        print("  [warn] no MeanConnect_ms data — skipping chart 5")
        return

    present_protos = set(ideal["ProtoLabel"].unique())
    x_order = [p for p in PROTO_ORDER if p in present_protos]

    runtime_order = RUNTIME_ORDER

    fig, ax = plt.subplots(figsize=(COL_W_IN, 3.0), layout="constrained")
    sns.barplot(
        data=ideal,
        x="ProtoLabel",
        y="MeanConnect_ms",
        hue="RuntimeLabel",
        hue_order=[r for r in runtime_order if r in ideal["RuntimeLabel"].unique()],
        order=x_order,
        palette=RUNTIME_PALETTE,
        ax=ax,
        errorbar="sd",
        err_kws={"linewidth": 0.8},
        capsize=0.15,
    )
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))
    ax.set_xlabel("Protocol Variant")
    ax.set_ylabel("Mean Connection Time (ms)")
    _style_bar_xaxis(ax, x_order)
    ax.legend(title="Runtime", ncol=3, loc="lower center",
              bbox_to_anchor=(0.5, 1.0), columnspacing=1.2, handlelength=1.4)
    ax.grid(axis="y", which="both", linestyle="--", alpha=0.4)
    out_path = out_dir / "chart5_connect_time.png"
    fig.savefig(out_path)
    plt.close(fig)
    print(f"  wrote {out_path}")

    csv_df = (
        ideal[["RuntimeLabel", "ProtocolVariant", "MeanConnect_ms"]]
        .rename(columns={"RuntimeLabel": "Runtime"})
        .sort_values(["Runtime", "ProtocolVariant"])
    )
    write_chart_csv(csv_df, out_dir, "chart5_connect_time")

def chart_cpu_efficiency(df: pd.DataFrame, out_dir: Path) -> None:
    ideal = df[df["Profile"] == "ideal"].copy()
    if ideal.empty:
        print("  [warn] no ideal data — skipping chart 6")
        return

    ideal = ideal[ideal["ProtoLabel"].notna()].copy()

    run_map = build_run_dir_map("ideal")
    if not run_map:
        print("  [warn] no ideal run dirs found — skipping chart 6")
        return

    records: list[dict] = []
    for _, row in ideal.iterrows():
        key = (row["Runtime"], row["ProtocolVariant"])
        run_dirs = run_map.get(key)
        if not run_dirs:
            print(f"  [warn] chart 6: no run dir for {key} — skipping")
            continue

        per_run_cpu: list[float] = []
        for run_dir in run_dirs:
            pidstat_path = run_dir / "server_pidstat.log"
            if not pidstat_path.exists():
                continue
            cpu_vals = parse_pidstat(pidstat_path)
            if cpu_vals:
                per_run_cpu.append(sum(cpu_vals) / len(cpu_vals))

        if not per_run_cpu:
            print(f"  [warn] chart 6: no CPU samples for {key} — skipping")
            continue

        avg_cpu = sum(per_run_cpu) / len(per_run_cpu)
        if avg_cpu <= 0:
            print(f"  [warn] chart 6: avg CPU is {avg_cpu} for {key} — skipping (div-by-zero)")
            continue

        records.append({
            "RuntimeLabel": row["RuntimeLabel"],
            "ProtoLabel": row["ProtoLabel"],
            "ProtocolVariant": row["ProtocolVariant"],
            "Throughput": row["Throughput"],
            "AvgServerCPUPct": avg_cpu,
            "Efficiency": row["Throughput"] / avg_cpu,
            "NumCPURuns": len(per_run_cpu),
        })

    if not records:
        print("  [warn] chart 6: no efficiency data computed — skipping")
        return

    eff = pd.DataFrame(records)

    present_protos = set(eff["ProtoLabel"].unique())
    x_order = [p for p in PROTO_ORDER if p in present_protos]
    runtime_order = RUNTIME_ORDER

    fig, ax = plt.subplots(figsize=(COL_W_IN, 3.0), layout="constrained")
    sns.barplot(
        data=eff,
        x="ProtoLabel",
        y="Efficiency",
        hue="RuntimeLabel",
        hue_order=[r for r in runtime_order if r in eff["RuntimeLabel"].unique()],
        order=x_order,
        palette=RUNTIME_PALETTE,
        ax=ax,
    )
    ax.set_yscale("log")
    _format_log_yaxis(ax)
    ax.set_xlabel("Protocol Variant")
    ax.set_ylabel("Msg/s per 1% CPU (log scale)")
    ax.set_ylim(top=ax.get_ylim()[1] * 1.8)
    _style_bar_xaxis(ax, x_order)
    ax.legend(title="Runtime", ncol=3, loc="lower center",
              bbox_to_anchor=(0.5, 1.0), columnspacing=1.2, handlelength=1.4)
    ax.grid(axis="y", which="both", linestyle="--", alpha=0.4)
    out_path = out_dir / "chart6_cpu_efficiency.png"
    fig.savefig(out_path)
    plt.close(fig)
    print(f"  wrote {out_path}")

    csv_df = (
        eff[["RuntimeLabel", "ProtocolVariant", "Throughput", "AvgServerCPUPct", "Efficiency", "NumCPURuns"]]
        .rename(columns={
            "RuntimeLabel": "Runtime",
            "Throughput": "Throughput_msg_s",
            "Efficiency": "Efficiency_msg_s_per_pct",
        })
        .sort_values(["Runtime", "ProtocolVariant"])
    )
    write_chart_csv(csv_df, out_dir, "chart6_cpu_efficiency")

def chart_crossover(df: pd.DataFrame, out_dir: Path, delay_ms: int = 50) -> None:
    cross = df[df["Profile"] == "crossover"].copy()
    if cross.empty:
        print("  [warn] no crossover data — skipping chart 7 (run orchestration/sweep_crossover.sh)")
        return

    if "DelayMs" in cross.columns:
        cross["DelayMs"] = pd.to_numeric(cross["DelayMs"], errors="coerce")
        cross = cross[cross["DelayMs"] == delay_ms].copy()
    if cross.empty:
        print(f"  [warn] no crossover data at {delay_ms}ms delay — skipping chart 7 ({delay_ms}ms)")
        return

    if "PacketLossPct" not in cross.columns:
        print("  [warn] crossover data has no PacketLossPct column — skipping chart 7")
        return

    cross = cross[cross["ProtoLabel"].notna()].copy()
    cross["PacketLossPct"] = pd.to_numeric(cross["PacketLossPct"], errors="coerce")
    cross = cross[cross["PacketLossPct"].notna()].copy()

    cross = cross[cross["ProtoLabel"].isin(["WebSocket", "WebTransport (Stream)", "WebTransport (Datagram)"])].copy()
    if cross.empty:
        print("  [warn] no usable WS/WebTransport crossover rows — skipping chart 7")
        return

    cross["Series"] = cross["RuntimeLabel"] + " " + cross["ProtoLabel"]
    grouped = (
        cross.groupby(["Series", "RuntimeLabel", "ProtoLabel", "PacketLossPct"])["Throughput"]
        .mean()
        .reset_index()
    )

    fig, ax = plt.subplots(figsize=(COL_W_IN, 3.8), layout="constrained")

    RUNTIME_FILL = {"Deno": "none", "Node": "left", "Bun": "full"}

    DOT_ON_OFF = (1.2, 2.4)
    MERGED_DASH = (1.2, 3.6)

    loss_ticks = sorted(grouped["PacketLossPct"].unique())
    xpos = {v: i for i, v in enumerate(loss_ticks)}
    X = lambda s: s.map(xpos)

    MERGE_TOL_PCT = 2.0

    def spread_pct(piv) -> float:
        return float((100.0 * (piv.max(axis=1) - piv.min(axis=1))
                      / piv.mean(axis=1)).max())

    def runtime_groups(sub) -> list[list[str]]:
        piv = sub.pivot_table(index="PacketLossPct", columns="RuntimeLabel",
                              values="Throughput").dropna(axis=1, how="any")
        order = piv.mean().sort_values().index.tolist()
        if not order:
            return []
        groups, cur = [], [order[0]]
        for rt in order[1:]:
            if spread_pct(piv[cur + [rt]]) <= MERGE_TOL_PCT:
                cur.append(rt)
            else:
                groups.append(cur)
                cur = [rt]
        groups.append(cur)
        return [[r for r in RUNTIME_ORDER if r in g] for g in groups]

    merge_log: list[dict] = []

    def merge(sub, proto, rts):
        m = (sub[sub["RuntimeLabel"].isin(rts)]
             .groupby("PacketLossPct")["Throughput"]
             .agg(["min", "max", "mean"]).reset_index()
             .sort_values("PacketLossPct"))
        spread = spread_pct(
            sub[sub["RuntimeLabel"].isin(rts)]
            .pivot_table(index="PacketLossPct", columns="RuntimeLabel",
                         values="Throughput")) if len(rts) > 1 else 0.0
        merge_log.append({"Protocol": proto, "Runtimes": "+".join(rts),
                          "NRuntimes": len(rts), "MaxSpreadPct": round(spread, 2)})
        if len(rts) > 1:
            print(f"    {proto}: {'+'.join(rts)} merged, spread <= {spread:.2f}%")
        return m

    def series_key(color, dashes, marker, fill):
        return Line2D([0], [0], color=color, linewidth=1.5, markersize=4,
                      linestyle="-" if dashes is None else (0, dashes),
                      marker=marker, fillstyle=fill, markerfacecoloralt="white",
                      markeredgewidth=0.9)

    PROTO_STYLE = {
        "WebSocket":               {"marker": "^", "dashes": None,
                                    "neutral": "#9E9E9E", "z": 1.6, "short": "WS"},
        "WebTransport (Stream)":   {"marker": "o", "dashes": None,
                                    "neutral": "#37474F", "z": 2.5, "short": "WT-S"},
        "WebTransport (Datagram)": {"marker": "s", "dashes": DOT_ON_OFF,
                                    "neutral": "#37474F", "z": 2.5, "short": "WT-D"},
    }

    n_runtimes = grouped["RuntimeLabel"].nunique()
    legend_keys: list[tuple[str, object]] = []

    for proto in ["WebSocket", "WebTransport (Datagram)", "WebTransport (Stream)"]:
        sub = grouped[grouped["ProtoLabel"] == proto]
        if sub.empty:
            continue
        st = PROTO_STYLE[proto]
        for rts in runtime_groups(sub):
            m = merge(sub, proto, rts)
            xs = X(m["PacketLossPct"])

            if len(rts) >= 3 or (len(rts) > 1 and len(rts) == n_runtimes):
                ax.fill_between(xs, m["min"], m["max"], color=st["neutral"],
                                alpha=0.30, linewidth=0, zorder=st["z"] - 0.2)
                if proto == "WebSocket":
                    ax.plot(xs, m["mean"], color=st["neutral"], linewidth=3.0,
                            solid_capstyle="round", zorder=st["z"])
                    ax.plot(xs, m["mean"], color="white", linewidth=0.9,
                            linestyle=(0, (3, 3)), zorder=st["z"] + 0.1)
                    handle = (Line2D([0], [0], color=st["neutral"], linewidth=3.0),
                              Line2D([0], [0], color="white", linewidth=0.9,
                                     linestyle=(0, (3, 3))))
                else:
                    ax.plot(xs, m["mean"], color=st["neutral"],
                            linestyle="-" if st["dashes"] is None else (0, st["dashes"]),
                            marker=st["marker"], markersize=4, linewidth=1.5,
                            markerfacecolor=st["neutral"],
                            markeredgecolor=st["neutral"], markeredgewidth=0.9,
                            zorder=st["z"])
                    handle = series_key(st["neutral"], st["dashes"], st["marker"], "full")
                label = f'{st["short"]}, all {len(rts)}'

            elif len(rts) == 2:
                if st["dashes"] is None:
                    seg = 3.0
                    pattern, period = (seg, seg * (len(rts) - 1)), seg * len(rts)
                else:
                    pattern = MERGED_DASH
                    period = MERGED_DASH[0] + MERGED_DASH[1]
                for i, rt in enumerate(rts):
                    ax.plot(xs, m["mean"], color=RUNTIME_PALETTE.get(rt, "#888888"),
                            linestyle=(i * period / len(rts), pattern),
                            linewidth=1.5, zorder=st["z"])
                ax.plot(xs, m["mean"], linestyle="none", marker=st["marker"],
                        markersize=4, fillstyle="left",
                        markerfacecolor=RUNTIME_PALETTE.get(rts[0], "#888888"),
                        markerfacecoloralt=RUNTIME_PALETTE.get(rts[1], "#888888"),
                        markeredgecolor="#333333", markeredgewidth=0.9,
                        zorder=st["z"] + 0.1)
                handle = Line2D([0], [0], linestyle="none", marker=st["marker"],
                                markersize=5, fillstyle="left",
                                markerfacecolor=RUNTIME_PALETTE.get(rts[0], "#888888"),
                                markerfacecoloralt=RUNTIME_PALETTE.get(rts[1], "#888888"),
                                markeredgecolor="#333333", markeredgewidth=0.9)
                label = f'{"+".join(rts)} {st["short"]}'

            else:
                rt = rts[0]
                g = sub[sub["RuntimeLabel"] == rt].sort_values("PacketLossPct")
                ax.plot(X(g["PacketLossPct"]), g["Throughput"],
                        color=RUNTIME_PALETTE.get(rt, "#888888"),
                        linestyle="-" if st["dashes"] is None else (0, st["dashes"]),
                        marker=st["marker"], linewidth=1.5, markersize=4,
                        fillstyle=RUNTIME_FILL.get(rt, "full"),
                        markerfacecoloralt="white", markeredgewidth=0.9,
                        zorder=st["z"])
                handle = series_key(RUNTIME_PALETTE.get(rt, "#888888"), st["dashes"],
                                    st["marker"], RUNTIME_FILL.get(rt, "full"))
                label = f'{rt} {st["short"]}'

            legend_keys.append((label, handle))

    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))
    ymin = float(ax.dataLim.y0)
    ax.set_ylim(bottom=0.0 if ymin < 200 else np.floor(0.92 * ymin / 50.0) * 50)
    ax.set_xticks([xpos[v] for v in loss_ticks])
    ax.set_xticklabels([f"{int(v) if v == int(v) else v}%" for v in loss_ticks])
    ax.set_xlabel(f"Packet Loss (%) at {delay_ms} ms one-way delay")
    ax.set_ylabel("Throughput (msg/s)")
    ncol = max(1, (len(legend_keys) + 1) // 2)
    top, bottom = legend_keys[:ncol], legend_keys[ncol:]
    for row in (top, bottom):
        row.extend([("", Line2D([0], [0], color="none"))] * (ncol - len(row)))
    keys = [k for pair in zip(top, bottom) for k in pair]
    fig.legend([h for _, h in keys], [lbl for lbl, _ in keys],
               loc="outside upper center", ncol=ncol,
               handlelength=1.4, columnspacing=0.35, handletextpad=0.4,
               handler_map={tuple: HandlerTuple(ndivide=None, pad=0)})
    ax.grid(which="both", linestyle="--", alpha=0.4)
    stem = f"chart7_crossover_{delay_ms}ms"
    out_path = out_dir / f"{stem}.png"
    fig.savefig(out_path)
    plt.close(fig)
    print(f"  wrote {out_path}")

    csv_df = (
        grouped[["RuntimeLabel", "ProtoLabel", "PacketLossPct", "Throughput"]]
        .rename(columns={
            "RuntimeLabel": "Runtime",
            "ProtoLabel": "Protocol",
            "Throughput": "Throughput_msg_s",
        })
        .sort_values(["Runtime", "Protocol", "PacketLossPct"])
    )
    write_chart_csv(csv_df, out_dir, stem)

    write_chart_csv(pd.DataFrame(merge_log), out_dir, f"{stem}_merges")

CDF_RUNS = [
    ("bun",  "ws",                            "Bun WS",                             "#F472B6", "--",  1.1,  0.6),
    ("deno", "ws",                            "Deno WS",                            "#1A1A1A", "--",  1.1,  0.6),
    ("node", "ws",                            "Node WS",                            "#339933", "--",  1.1,  0.6),
    ("bun",  "webtransport-vmeansdev",        "Bun WT Stream (vmeansdev)",          "#F472B6", "-",   1.5,  1.0),
    ("deno", "webtransport",                  "Deno WT Stream (native)",            "#1A1A1A", "-",   1.5,  1.0),
    ("node", "webtransport-fails-components", "Node WT Stream (fails-components)",  "#339933", "-",   1.5,  1.0),
    ("bun",  "webtransport-datagram",         "Bun WT Datagram (vmeansdev)",        "#F472B6", ":",   1.5,  1.0),
    ("deno", "webtransport-datagram",         "Deno WT Datagram (native)",          "#1A1A1A", ":",   1.5,  1.0),
    ("node", "webtransport-datagram",         "Node WT Datagram (fails-components)","#339933", ":",   1.5,  1.0),
]

_RNG = np.random.default_rng(42)
_MAX_RTT_SAMPLES = 200_000
_CDF_XLIM_MS = 4.0

def load_rtts_sampled(rtts_path: Path, max_rows: int = _MAX_RTT_SAMPLES) -> np.ndarray:
    chunks: list[np.ndarray] = []
    for chunk in pd.read_csv(rtts_path, usecols=["rtt_ms"], chunksize=100_000):
        chunks.append(chunk["rtt_ms"].to_numpy(dtype=np.float64))

    all_rtts = np.concatenate(chunks)
    if len(all_rtts) > max_rows:
        all_rtts = _RNG.choice(all_rtts, size=max_rows, replace=False)
    return all_rtts

def chart_latency_cdf(out_dir: Path) -> None:
    run_map = build_run_dir_map("ideal")
    if not run_map:
        print("  [warn] no ideal run dirs found — skipping chart 3")
        return

    fig, ax = plt.subplots(figsize=(COL_W_IN, 3.0), layout="constrained")
    plotted = False
    cdf_records: list[dict] = []

    for runtime, variant, label, color, ls, lw, alpha in CDF_RUNS:
        run_dirs = run_map.get((runtime, variant))
        if not run_dirs:
            print(f"  [warn] chart 3: no run dir for ({runtime}, {variant}) — skipping line")
            continue

        parts: list[np.ndarray] = []
        for run_dir in run_dirs:
            rtts_path = run_dir / "rtts.csv"
            if rtts_path.exists():
                parts.append(load_rtts_sampled(rtts_path))
        if not parts:
            print(f"  [warn] chart 3: no rtts.csv for ({runtime}, {variant}) — skipping line")
            continue

        rtts = np.concatenate(parts)
        if len(rtts) == 0:
            continue
        if len(rtts) > _MAX_RTT_SAMPLES:
            rtts = _RNG.choice(rtts, size=_MAX_RTT_SAMPLES, replace=False)

        rtts_sorted = np.sort(rtts)
        mask = rtts_sorted <= _CDF_XLIM_MS
        x = rtts_sorted[mask]
        y = np.arange(1, len(x) + 1) / len(rtts_sorted)

        ax.plot(x, y, label=label, color=color, linestyle=ls, linewidth=lw, alpha=alpha)
        plotted = True

        if len(x) > 0:
            idx = np.unique(np.linspace(0, len(x) - 1, min(len(x), 300)).astype(int))
            for xi, yi in zip(x[idx], y[idx]):
                cdf_records.append({
                    "Series": label,
                    "RTT_ms": round(float(xi), 4),
                    "CumulativeProbability": round(float(yi), 5),
                })

    if not plotted:
        print("  [warn] chart 3: no data plotted — skipping")
        plt.close(fig)
        return

    ax.set_xlabel("Round-Trip Time (ms)")
    ax.set_ylabel("Cumulative Probability")
    ax.set_ylim(0, 1.02)
    ax.set_xlim(0, _CDF_XLIM_MS)
    handles, labels = ax.get_legend_handles_labels()
    wt_idx = [i for i, l in enumerate(labels) if "WT " in l]
    ws_idx = [i for i, l in enumerate(labels) if "WS" in l]
    ordered_h = [handles[i] for i in wt_idx + ws_idx]
    ordered_l = [_short_series(labels[i]) for i in wt_idx + ws_idx]
    fig.legend(ordered_h, ordered_l, loc="outside upper center", ncol=3,
               handlelength=1.5, columnspacing=1.0, handletextpad=0.5)
    ax.grid(linestyle="--", alpha=0.4)
    out_path = out_dir / "chart3_latency_cdf.png"
    fig.savefig(out_path)
    plt.close(fig)
    print(f"  wrote {out_path}")

    if cdf_records:
        write_chart_csv(cdf_records, out_dir, "chart3_latency_cdf")

def load_concurrency() -> pd.DataFrame:
    path = RESULTS_BASE / "concurrency" / "metrics.csv"
    if not path.exists():
        return pd.DataFrame()
    raw = pd.read_csv(path)
    for c in ["Throughput", "p95_ms", "Concurrency"]:
        if c in raw.columns:
            raw[c] = pd.to_numeric(raw[c], errors="coerce")
    if "Concurrency" not in raw.columns:
        return pd.DataFrame()
    key = ["Runtime", "ProtocolVariant", "Concurrency"]
    g = raw.groupby(key, as_index=False).agg(
        Throughput=("Throughput", "mean"),
        p95_ms=("p95_ms", "mean"),
        NumRuns=("Throughput", "size"),
    )
    return _add_labels(g)

def chart_concurrency_scaling(out_dir: Path) -> None:
    df = load_concurrency()
    if df.empty:
        print("  [warn] no concurrency data — skipping chart 9 (run orchestration/sweep_concurrency.sh)")
        return
    df = df[df["ProtoLabel"].notna() & df["Concurrency"].notna()].copy()
    if df.empty:
        print("  [warn] no usable concurrency rows — skipping chart 9")
        return

    df["ConcLabel"] = df["Concurrency"].map(lambda c: f"{int(c)} clients")
    df["GroupLabel"] = (df["RuntimeLabel"] + "\n"
                        + df["ProtoLabel"].map(lambda p: PROTO_LABELS_SHORT.get(p, p)))

    present_groups = set(df["GroupLabel"])
    x_order = [f"{rt}\n{PROTO_LABELS_SHORT.get(proto, proto)}"
               for proto in PROTO_ORDER for rt in RUNTIME_ORDER
               if f"{rt}\n{PROTO_LABELS_SHORT.get(proto, proto)}" in present_groups]
    conc_order = [f"{int(c)} clients" for c in sorted(df["Concurrency"].unique())]
    palette = dict(zip(conc_order, sns.color_palette("crest", n_colors=len(conc_order))))

    fig, ax = plt.subplots(figsize=(COL_W_IN, 3.0), layout="constrained")
    sns.barplot(data=df, x="GroupLabel", y="Throughput", hue="ConcLabel",
                hue_order=conc_order, order=x_order, palette=palette, ax=ax)
    ax.set_yscale("log")
    _format_log_yaxis(ax)
    ax.set_xlabel("Runtime / Protocol")
    ax.set_ylabel("Throughput (msg/s, log scale)")
    ax.tick_params(axis="x", rotation=30)
    plt.setp(ax.get_xticklabels(), ha="right", rotation_mode="anchor")
    ax.legend(title="Concurrency", ncol=len(conc_order), loc="lower center",
              bbox_to_anchor=(0.5, 1.0))
    ax.grid(axis="y", which="both", linestyle="--", alpha=0.4)
    out_path = out_dir / "chart9_concurrency_scaling.png"
    fig.savefig(out_path)
    plt.close(fig)
    print(f"  wrote {out_path}")

    csv_df = (df[["RuntimeLabel", "ProtocolVariant", "Concurrency", "Throughput", "p95_ms", "NumRuns"]]
              .rename(columns={"RuntimeLabel": "Runtime", "Throughput": "Throughput_msg_s"})
              .sort_values(["Runtime", "ProtocolVariant", "Concurrency"]))
    write_chart_csv(csv_df, out_dir, "chart9_concurrency_scaling")

def chart_burst_vs_uniform(df: pd.DataFrame, out_dir: Path) -> None:
    if "PacketLossPct" not in df.columns or "DelayMs" not in df.columns:
        print("  [warn] burst/uniform data missing PacketLossPct/DelayMs — skipping chart 10")
        return
    sub = df[df["Profile"].isin({"crossover", "burst_loss"})].copy()
    sub["PacketLossPct"] = pd.to_numeric(sub["PacketLossPct"], errors="coerce")
    sub["DelayMs"] = pd.to_numeric(sub["DelayMs"], errors="coerce")
    sub = sub[(sub["PacketLossPct"] == 5) & (sub["DelayMs"] == 50)].copy()
    sub = sub[sub["ProtoLabel"].isin(
        ["WebSocket", "WebTransport (Stream)", "WebTransport (Datagram)"])].copy()
    if sub.empty or set(sub["Profile"].unique()) != {"crossover", "burst_loss"}:
        print("  [warn] chart 10 needs both uniform-5% (crossover) and bursty (burst_loss) at 50ms — skipping")
        return

    model_label = {"crossover": "Uniform 5%", "burst_loss": "Bursty 5% (GE)"}
    sub["LossModel"] = sub["Profile"].map(model_label)
    sub["GroupLabel"] = (sub["RuntimeLabel"] + "\n"
                         + sub["ProtoLabel"].map(lambda p: PROTO_LABELS_SHORT.get(p, p)))

    present_groups = set(sub["GroupLabel"])
    x_order = [f"{rt}\n{PROTO_LABELS_SHORT.get(proto, proto)}"
               for proto in PROTO_ORDER for rt in RUNTIME_ORDER
               if f"{rt}\n{PROTO_LABELS_SHORT.get(proto, proto)}" in present_groups]
    model_order = [model_label[p] for p in ["crossover", "burst_loss"]]

    fig, ax = plt.subplots(figsize=(COL_W_IN, 3.0), layout="constrained")
    sns.barplot(data=sub, x="GroupLabel", y="Throughput", hue="LossModel",
                hue_order=model_order, order=x_order, palette=LOSSMODEL_PALETTE, ax=ax)
    ax.set_yscale("log")
    _format_log_yaxis(ax)
    ax.set_xlabel("Runtime / Protocol")
    ax.set_ylabel("Throughput (msg/s, log scale)")
    ax.tick_params(axis="x", rotation=30)
    plt.setp(ax.get_xticklabels(), ha="right", rotation_mode="anchor")
    ax.legend(title="Loss Model (5% mean, 50ms)", ncol=2, loc="lower center",
              bbox_to_anchor=(0.5, 1.0))
    ax.grid(axis="y", which="both", linestyle="--", alpha=0.4)
    out_path = out_dir / "chart10_burst_vs_uniform.png"
    fig.savefig(out_path)
    plt.close(fig)
    print(f"  wrote {out_path}")

    csv_df = (sub[["RuntimeLabel", "ProtocolVariant", "Profile", "LossModel",
                   "Throughput", "p95_ms", "Errors"]]
              .rename(columns={"RuntimeLabel": "Runtime", "Throughput": "Throughput_msg_s"})
              .sort_values(["Runtime", "ProtocolVariant", "Profile"]))
    write_chart_csv(csv_df, out_dir, "chart10_burst_vs_uniform")

def main() -> None:
    print("Loading benchmark data...")
    df = load_all()
    print(f"  loaded {len(df)} rows across {df['Profile'].nunique()} profile(s)")

    out_dir = RESULTS_BASE / "charts"
    out_dir.mkdir(exist_ok=True)

    print("Generating charts...")
    chart_throughput_by_protocol(df, out_dir)
    chart_latency_cdf(out_dir)
    chart_connect_time(df, out_dir)
    chart_cpu_efficiency(df, out_dir)
    chart_crossover(df, out_dir, delay_ms=50)
    chart_crossover(df, out_dir, delay_ms=20)
    chart_concurrency_scaling(out_dir)
    chart_burst_vs_uniform(df, out_dir)

    print(f"\nDone. Charts in {out_dir}/")

if __name__ == "__main__":
    main()
