#!/usr/bin/env bash
set -euo pipefail

rounds=${1:-5}
if ! [[ ${rounds} =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 [positive-round-count]" >&2
    exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd -- "${script_dir}/../.." && pwd)
qemu_repo=${workspace}/qemu
rootfs=${ROOTFS:-/var/tmp/build-root/riscv64-riscv64/.mount}
baseline_qemu=${BASELINE_QEMU:-${qemu_repo}/build-static/qemu-riscv64}
candidate_qemu=${CANDIDATE_QEMU:-}
baseline_label=${BASELINE_LABEL:-current}
candidate_label=${CANDIDATE_LABEL:-revert-5089493e45d3}
cpu_set=${CPUSET:-}
xz_mib=${XZ_MIB:-4}
timestamp=$(date +%Y%m%d-%H%M%S)
result_dir=${RESULT_DIR:-${script_dir}/ab-runs/${timestamp}}
raw_dir=${result_dir}/raw
output_dir=${result_dir}/outputs
input_dir=${result_dir}/inputs
temp_root=
candidate_worktree=

mkdir -p "${raw_dir}" "${output_dir}" "${input_dir}"

for label in "${baseline_label}" "${candidate_label}"; do
    if ! [[ ${label} =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "labels may contain only letters, numbers, underscores and hyphens" >&2
        exit 2
    fi
done

for command_name in git ninja perf python3 sha256sum taskset; do
    command -v "${command_name}" >/dev/null || {
        echo "missing command: ${command_name}" >&2
        exit 2
    }
done

for guest_file in \
    usr/bin/which \
    usr/bin/xz \
    usr/lib64/gcc/riscv64-openruyi-linux/16/cc1; do
    if [[ ! -x ${rootfs}/${guest_file} ]]; then
        echo "missing guest executable: ${rootfs}/${guest_file}" >&2
        exit 2
    fi
done

cleanup() {
    if [[ -n ${candidate_worktree} && -d ${candidate_worktree} ]]; then
        git -C "${qemu_repo}" worktree remove --force "${candidate_worktree}" \
            >/dev/null 2>&1 || true
    fi
    if [[ -n ${temp_root} && -d ${temp_root} ]]; then
        rmdir "${temp_root}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

build_default_pair() {
    local head candidate_build translate_command

    if [[ -n $(git -C "${qemu_repo}" status --porcelain) ]]; then
        echo "QEMU source tree is dirty; use explicit BASELINE_QEMU and CANDIDATE_QEMU" >&2
        exit 2
    fi

    echo "Building baseline QEMU..."
    ninja -C "${qemu_repo}/build-static" qemu-riscv64
    baseline_qemu=${qemu_repo}/build-static/qemu-riscv64

    translate_command=$(ninja -C "${qemu_repo}/build-static" -t commands qemu-riscv64 \
        | awk '/target_riscv_tcg_translate.c.o/ && !found { print; found = 1 }')
    if [[ ${translate_command} != *" -O2 "* ]]; then
        echo "baseline QEMU is not built with -O2" >&2
        exit 2
    fi

    head=$(git -C "${qemu_repo}" rev-parse HEAD)
    if ! git -C "${qemu_repo}" merge-base --is-ancestor \
        5089493e45d3be2bae9ffd2a22186f57b0cabe3f "${head}"; then
        echo "commit 5089493e45d3 is not an ancestor of ${head}" >&2
        exit 2
    fi

    temp_root=$(mktemp -d /tmp/quprof-qemu-ab.XXXXXX)
    candidate_worktree=${temp_root}/candidate
    git -C "${qemu_repo}" worktree add --detach "${candidate_worktree}" "${head}"
    git -C "${candidate_worktree}" revert --no-commit \
        5089493e45d3be2bae9ffd2a22186f57b0cabe3f

    candidate_build=${candidate_worktree}/build-static
    mkdir -p "${candidate_build}"
    (
        cd "${candidate_build}"
        ../configure --target-list=riscv64-linux-user --static --disable-docs
        ninja qemu-riscv64
    )
    candidate_qemu=${candidate_build}/qemu-riscv64

    translate_command=$(ninja -C "${candidate_build}" -t commands qemu-riscv64 \
        | awk '/target_riscv_tcg_translate.c.o/ && !found { print; found = 1 }')
    if [[ ${translate_command} != *" -O2 "* ]]; then
        echo "candidate QEMU is not built with -O2" >&2
        exit 2
    fi
}

if [[ -z ${candidate_qemu} ]]; then
    build_default_pair
fi

for qemu_binary in "${baseline_qemu}" "${candidate_qemu}"; do
    if [[ ! -x ${qemu_binary} ]]; then
        echo "QEMU is not executable: ${qemu_binary}" >&2
        exit 2
    fi
done

if [[ -n ${cpu_set} ]]; then
    taskset -c "${cpu_set}" true
fi

python3 - "${input_dir}/xz-input.bin" "${xz_mib}" <<'PY'
import pathlib
import random
import sys

path = pathlib.Path(sys.argv[1])
size = int(sys.argv[2]) * 1024 * 1024
rng = random.Random(0x51554D55)
path.write_bytes(rng.randbytes(size))
PY

source_file=${workspace}/research/user-mode-perf/probe.c
cc1=${rootfs}/usr/lib64/gcc/riscv64-openruyi-linux/16/cc1
xz_input=${input_dir}/xz-input.bin
hash_file=${result_dir}/hashes.tsv
printf 'workload\tvariant\trun\tsha256\n' > "${hash_file}"

run_workload() {
    local workload=$1 variant=$2 qemu_binary=$3 run_number=$4 measured=$5
    local artifact stat_file stdout_file
    local -a prefix command

    artifact=${output_dir}/${workload}.${variant}.${run_number}.out
    stat_file=${raw_dir}/${workload}.${variant}.${run_number}.stat
    stdout_file=${output_dir}/${workload}.${variant}.${run_number}.stdout

    if [[ -n ${cpu_set} ]]; then
        prefix=(taskset -c "${cpu_set}")
    else
        prefix=()
    fi

    case ${workload} in
        which)
            command=("${prefix[@]}" "${qemu_binary}" -L "${rootfs}"
                     "${rootfs}/usr/bin/which" sh)
            ;;
        xz)
            command=("${prefix[@]}" "${qemu_binary}" -L "${rootfs}"
                     "${rootfs}/usr/bin/xz" -T1 -6 -c "${xz_input}")
            ;;
        cc1)
            command=("${prefix[@]}" "${qemu_binary}" -L "${rootfs}" "${cc1}"
                     -quiet
                     -isystem "${rootfs}/usr/lib64/gcc/riscv64-openruyi-linux/16/include"
                     -isystem "${rootfs}/usr/lib64/gcc/riscv64-openruyi-linux/16/include-fixed"
                     -isystem "${rootfs}/usr/include"
                     -D_REENTRANT "${source_file}"
                     -quiet -march=rva23u64 -mabi=lp64d -O2
                     -fno-omit-frame-pointer -o "${artifact}")
            ;;
        *)
            echo "unknown workload: ${workload}" >&2
            exit 2
            ;;
    esac

    if [[ ${measured} == yes ]]; then
        echo "${workload}: run ${run_number}/${rounds}, ${variant}"
        if [[ ${workload} == cc1 ]]; then
            LC_ALL=C perf stat -x, --no-big-num -o "${stat_file}" \
                -e duration_time,task-clock,cycles:u,instructions:u -- \
                env LC_ALL=C.UTF-8 PATH=/usr/bin:/bin "${command[@]}" \
                > "${stdout_file}"
        else
            LC_ALL=C perf stat -x, --no-big-num -o "${stat_file}" \
                -e duration_time,task-clock,cycles:u,instructions:u -- \
                env LC_ALL=C.UTF-8 PATH=/usr/bin:/bin "${command[@]}" \
                > "${artifact}"
        fi
        printf '%s\t%s\t%s\t%s\n' \
            "${workload}" "${variant}" "${run_number}" \
            "$(sha256sum "${artifact}" | awk '{print $1}')" >> "${hash_file}"
    else
        if [[ ${workload} == cc1 ]]; then
            env LC_ALL=C.UTF-8 PATH=/usr/bin:/bin "${command[@]}" \
                > "${stdout_file}"
        else
            env LC_ALL=C.UTF-8 PATH=/usr/bin:/bin "${command[@]}" \
                > "${artifact}"
        fi
        rm -f "${artifact}" "${stdout_file}"
    fi
}

for workload in which xz cc1; do
    echo "Warming ${workload}..."
    run_workload "${workload}" "${baseline_label}" "${baseline_qemu}" warm no
    run_workload "${workload}" "${candidate_label}" "${candidate_qemu}" warm no

    for ((run = 1; run <= rounds; run++)); do
        run_id=$(printf '%02d' "${run}")
        if ((run % 2 == 1)); then
            run_workload "${workload}" "${baseline_label}" \
                "${baseline_qemu}" "${run_id}" yes
            run_workload "${workload}" "${candidate_label}" \
                "${candidate_qemu}" "${run_id}" yes
        else
            run_workload "${workload}" "${candidate_label}" \
                "${candidate_qemu}" "${run_id}" yes
            run_workload "${workload}" "${baseline_label}" \
                "${baseline_qemu}" "${run_id}" yes
        fi
    done
done

baseline_sha=$(sha256sum "${baseline_qemu}" | awk '{print $1}')
candidate_sha=$(sha256sum "${candidate_qemu}" | awk '{print $1}')
head=$(git -C "${qemu_repo}" rev-parse HEAD)

python3 - "${result_dir}" "${baseline_label}" "${candidate_label}" \
    "${baseline_sha}" "${candidate_sha}" "${head}" "${rounds}" <<'PY'
import csv
import pathlib
import statistics
import sys

result_dir = pathlib.Path(sys.argv[1])
baseline = sys.argv[2]
candidate = sys.argv[3]
baseline_sha = sys.argv[4]
candidate_sha = sys.argv[5]
head = sys.argv[6]
rounds = int(sys.argv[7])

def read_stat(path):
    values = {}
    with path.open(newline="") as stream:
        for row in csv.reader(line for line in stream if not line.startswith("#")):
            if len(row) < 3 or not row[0].strip():
                continue
            try:
                value = float(row[0])
            except ValueError:
                continue
            values[row[2]] = value
    return {
        "wall_seconds": values["duration_time"] / 1_000_000_000,
        "task_clock_ms": values["task-clock"],
        "cycles": values["cycles:u"],
        "instructions": values["instructions:u"],
    }

rows = []
for path in sorted((result_dir / "raw").glob("*.stat")):
    workload, variant, run, _ = path.name.split(".", 3)
    row = {"workload": workload, "variant": variant, "run": int(run)}
    row.update(read_stat(path))
    row["ipc"] = row["instructions"] / row["cycles"]
    rows.append(row)

with (result_dir / "results.csv").open("w", newline="") as stream:
    fields = ["workload", "variant", "run", "wall_seconds",
              "task_clock_ms", "cycles", "instructions", "ipc"]
    writer = csv.DictWriter(stream, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)

hashes = {}
with (result_dir / "hashes.tsv").open() as stream:
    next(stream)
    for line in stream:
        workload, variant, run, digest = line.rstrip("\n").split("\t")
        hashes.setdefault(workload, set()).add(digest)

bad_hashes = {workload: values for workload, values in hashes.items()
              if len(values) != 1}
if bad_hashes:
    raise SystemExit(f"output mismatch: {bad_hashes}")

def median(workload, variant, field):
    return statistics.median(
        row[field] for row in rows
        if row["workload"] == workload and row["variant"] == variant
    )

lines = [
    "# QEMU linux-user A/B comparison",
    "",
    f"- QEMU commit: `{head}`",
    f"- Repetitions per variant: {rounds}",
    f"- Baseline: `{baseline}` (`{baseline_sha}`)",
    f"- Candidate: `{candidate}` (`{candidate_sha}`)",
    "- Order alternates A/B then B/A; each workload is warmed once per variant.",
    "- All outputs match within each workload.",
    "",
    "| Workload | Baseline wall median | Candidate wall median | Speedup | "
    "Baseline cycles | Candidate cycles | Instruction reduction |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
]

for workload in ("which", "xz", "cc1"):
    b_wall = median(workload, baseline, "wall_seconds")
    c_wall = median(workload, candidate, "wall_seconds")
    b_cycles = median(workload, baseline, "cycles")
    c_cycles = median(workload, candidate, "cycles")
    b_inst = median(workload, baseline, "instructions")
    c_inst = median(workload, candidate, "instructions")
    speedup = b_wall / c_wall
    inst_reduction = (1 - c_inst / b_inst) * 100
    lines.append(
        f"| `{workload}` | {b_wall:.4f} s | {c_wall:.4f} s | "
        f"{speedup:.2f}x | {b_cycles / 1e9:.3f} B | "
        f"{c_cycles / 1e9:.3f} B | {inst_reduction:.1f}% |"
    )

if candidate.startswith("revert-"):
    candidate_note = (
        "The candidate reverses a correctness fix and is only a performance "
        "bound; it is not a proposed fix."
    )
else:
    candidate_note = (
        "The candidate is experimental. Matching workload outputs do not "
        "replace targeted correctness testing."
    )

lines.extend([
    "",
    candidate_note + " Per-run measurements are in `results.csv`, and raw "
    "perf output is under `raw/`.",
    "",
])

(result_dir / "comparison.md").write_text("\n".join(lines))
PY

rm -rf "${output_dir}"

echo
echo "Result: ${result_dir}/comparison.md"
cat "${result_dir}/comparison.md"
