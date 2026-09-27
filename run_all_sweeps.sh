#!/usr/bin/env bash
set -uo pipefail

REPEATS="${REPEATS:-10}"
ARCHIVE_OLD="${ARCHIVE_OLD:-1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

BENCH_HOME="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)"
for d in /usr/local/bin "$HOME/.bun/bin" "$HOME/.deno/bin" \
         "$BENCH_HOME/.bun/bin" "$BENCH_HOME/.deno/bin"; do
    [[ -d "$d" ]] && PATH="$d:$PATH"
done
export PATH

if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root (ip netns / tc require CAP_NET_ADMIN). Try: sudo -E $0" >&2
    exit 1
fi

echo "[run-all] runtimes: node=$(command -v node) ($(node --version 2>/dev/null)), deno=$(deno --version 2>/dev/null | head -1), bun=$(bun --version 2>/dev/null)"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p logs

BENCHMARK_SWEEPS=(sweep_benchmark sweep_crossover sweep_concurrency sweep_burst)
PROFILE_DIRS=(ideal high_latency crossover concurrency burst_loss profiling)

if [[ "$ARCHIVE_OLD" == "1" ]]; then
    archive="results/_archive_${ts}"
    moved=0
    for d in "${PROFILE_DIRS[@]}"; do
        if [[ -d "results/$d" ]]; then
            mkdir -p "$archive"
            mv "results/$d" "$archive/"
            moved=1
        fi
    done
    if [[ "$moved" == "1" ]]; then
        echo "[run-all] archived previous results to $archive/ (set ARCHIVE_OLD=0 to keep & append)"
    else
        echo "[run-all] no previous results to archive"
    fi
fi

fails=0
start_epoch="$(date +%s)"
for rep in $(seq 1 "$REPEATS"); do
    for s in "${BENCHMARK_SWEEPS[@]}"; do
        log="logs/${ts}_rep${rep}_${s}.log"
        echo "===== $(date -u +%H:%M:%S) START rep ${rep}/${REPEATS} ${s} -> ${log} ====="
        bash "orchestration/${s}.sh" 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
        if [[ "$rc" -ne 0 ]]; then
            echo "[run-all] WARNING: ${s} (rep ${rep}) exited ${rc} — continuing"
            fails=$((fails + 1))
        fi
        echo "===== $(date -u +%H:%M:%S) END   rep ${rep}/${REPEATS} ${s} (exit ${rc}) ====="
    done
done

log="logs/${ts}_rep1_sweep_profiling.log"
echo "===== $(date -u +%H:%M:%S) START (single) sweep_profiling -> ${log} ====="
bash "orchestration/sweep_profiling.sh" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
if [[ "$rc" -ne 0 ]]; then
    echo "[run-all] WARNING: sweep_profiling exited ${rc} — continuing"
    fails=$((fails + 1))
fi
echo "===== $(date -u +%H:%M:%S) END   (single) sweep_profiling (exit ${rc}) ====="

mins=$(( ($(date +%s) - start_epoch) / 60 ))
echo
echo "[run-all] DONE in ${mins} min — ${REPEATS} repeats of: ${BENCHMARK_SWEEPS[*]}; 1x sweep_profiling"
echo "[run-all] ${fails} sweep invocation(s) reported a non-zero exit (see logs)."
echo "[run-all] logs: logs/${ts}_*.log"
echo "[run-all] next — regenerate charts (averaged across all runs):"
echo "          python3 tools/generate_charts.py"
