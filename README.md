# QEMU linux-user 构建负载性能分析

本目录是可直接发布到 GitHub 或 Gitee 的完整报告包。建议从
[五个负载汇总](workload-profile-summary.md) 开始阅读，再进入各负载的生成报告和
[xz/cc1 热点源码定位](localization/README.md)。

## 内容

- [五个负载汇总](workload-profile-summary.md)
- [which 完整报告](workloads/which/report.md)
- [xz 完整报告](workloads/xz/report.md)
- [zlib-ng 完整报告](workloads/zlib-ng/report.md)
- [file 完整报告](workloads/file/report.md)
- [lz4 完整报告](workloads/lz4/report.md)
- [QEMU 源码定位和优化方向](localization/README.md)
- [正确性优先原型补丁](localization/patches/riscv-linux-user-multi-cpu-reservation-v1.diff)
- [原型 A/B 和正确性验证](localization/ab-correctness-v2/correctness.md)
- [局部变体定位实验](localization/ab-narrow/comparison.md)

每个 `workloads/<负载>/` 目录包含报告、运行清单、质量检查、计时信息、能力检测，
以及压缩后的完整聚合热点和生命周期数据。

## 未纳入仓库的数据

原始 `samples.jsonl` 合计约 14 GiB，另有 perf 二进制数据。它们保留在采集机器的
`/home/holo/ospp-qemu-optimisation/quprof/profiles/` 中，没有复制进发布包。
这些文件用于重新聚合和底层复查，不影响阅读报告、完整聚合热点、A/B 结果或补丁。

压缩数据可用以下命令读取：

```bash
gzip -cd workloads/xz/hotspots.csv.gz | less
gzip -cd workloads/xz/lifecycle.jsonl.gz | less
```
