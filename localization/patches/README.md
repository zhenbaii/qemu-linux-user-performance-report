# RISC-V linux-user reservation 优化实验补丁

固定保留的补丁：

- `riscv-linux-user-multi-cpu-reservation-v1.diff`
- 基准 QEMU 提交：`f9587d4045c67cd0d8d8bdcd5d0bb5b6b395b63c`
- SHA-256：`7c0104245c11d1d94ebc3a1f55457ccc27156e42caadf23abe8809658a70c971`

补丁增加 `CF_MULTI_CPU`，把“存在共享映射”和“进程内存在多个 guest CPU”
区分开。RISC-V reservation 相关 store 仅在确实存在多个 guest CPU 时进入
atomic 单步执行路径。它是本地研究原型，没有应用到主 QEMU 工作树。

## 查看和应用

```bash
cd /home/holo/ospp-qemu-optimisation/qemu
git apply --check ../research/xz-localization/patches/riscv-linux-user-multi-cpu-reservation-v1.diff
git apply ../research/xz-localization/patches/riscv-linux-user-multi-cpu-reservation-v1.diff
```

若要从未提交的工作树中移除它：

```bash
git apply -R ../research/xz-localization/patches/riscv-linux-user-multi-cpu-reservation-v1.diff
```

## 已完成的验证

- 定向 LR/SC 测试：当前版和原型各 10,000 次，无非预期 SC 成功；完整回退版
  负对照 100 次全部暴露错误。
- QEMU `riscv64-linux-user` TCG 测试：45/45 通过。
- 固定 CPU、三轮 A/B：xz 10.96x，`cc1` 6.10x，所有输出匹配。

完整验证记录位于
[`../ab-correctness-v2/correctness.md`](../ab-correctness-v2/correctness.md)，性能报告位于
同目录的 [`comparison.md`](../ab-correctness-v2/comparison.md)。

该补丁仍需补充多个 guest hart、fork 后状态、长期 LR/SC 压力测试和跨进程共享
映射测试。依据 QEMU 的 AI 内容政策，它只作为本地实验和设计证据保留，不应直接
用于上游贡献。
