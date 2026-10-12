#!/usr/bin/env bash
set -euo pipefail

locale_name=${1:-C.UTF-8}
iterations=${2:-1}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace_root=$(cd -- "${script_dir}/../.." && pwd)
rootfs=/var/tmp/build-root/riscv64-riscv64/.mount
qemu=${REPLAY_QEMU:-${workspace_root}/qemu/build-static/qemu-riscv64}
cc1=${rootfs}/usr/lib64/gcc/riscv64-openruyi-linux/16/cc1
source_file=${workspace_root}/research/user-mode-perf/probe.c

for ((run = 1; run <= iterations; run++)); do
    LC_ALL=${locale_name} "${qemu}" -L "${rootfs}" "${cc1}" \
        -quiet \
        -isystem "${rootfs}/usr/lib64/gcc/riscv64-openruyi-linux/16/include" \
        -isystem "${rootfs}/usr/lib64/gcc/riscv64-openruyi-linux/16/include-fixed" \
        -isystem "${rootfs}/usr/include" \
        -D_REENTRANT "${source_file}" \
        -quiet -march=rva23u64 -mabi=lp64d -O2 -fno-omit-frame-pointer \
        -o "/tmp/quprof-cc1-${locale_name}-${run}.s"
done
