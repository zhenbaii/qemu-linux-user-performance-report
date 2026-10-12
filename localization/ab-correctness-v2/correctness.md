# 正确性验证记录

## 原型语义

原型保留 `CF_PARALLEL` 对共享映射的现有含义，另外用 `CF_MULTI_CPU`
表示当前 linux-user 进程已经创建第二个 guest CPU。RISC-V reservation
相关指令只有在 `CF_MULTI_CPU` 下才通过 `cpu_exec_step_atomic()` 串行执行。

当共享映射已经提前设置 `CF_PARALLEL` 时，第一次创建线程会短暂进入 QEMU
exclusive 区域，刷新不含 `CF_MULTI_CPU` 的旧 TB，再设置新标志。这个转换只在
第一次创建额外 guest CPU 时发生。

## 针对性 LR/SC 测试

测试源码与二进制分别为：

- [`../riscv-reservation-test.c`](../riscv-reservation-test.c)
- [`../riscv-reservation-test-riscv64`](../riscv-reservation-test-riscv64)

测试先在单 CPU、可写匿名 `MAP_SHARED` 映射上执行一次 LR/SC，确认 SC 成功；
随后创建第二个线程，主线程 LR 后由工作线程对同一地址写入相同数值，主线程的
SC 必须失败。

| QEMU | 迭代 | 非预期 SC 成功 | 结果 |
| --- | ---: | ---: | --- |
| 当前版 | 10,000 | 0 | 通过 |
| `CF_MULTI_CPU` 原型 | 10,000 | 0 | 通过 |
| 完整回退 `5089493e45d3` 的负对照 | 100 | 100 | 按预期失败 |

负对照证明这个测试可以捕获 `5089493e45d3` 所修复的“相同数值 store 未使另一
hart reservation 失效”问题。

## QEMU 测试集

在静态 `riscv64-linux-user` 构建目录执行 `make check-tcg`：

```text
Ok:                 45
Expected Fail:       0
Fail:                0
Unexpected Pass:     0
Skipped:             0
Timeout:             0
```

覆盖的现有用例包括 `testthread`、`threadcount`、`munmap-pthread`、
`vma-pthread`、`test-mmap` 与完整的基础 riscv64 linux-user TCG 测试。
完整 Meson 输出保存在同目录的 `check-tcg-testlog.txt`。

## 性能和输出验证

`comparison.md` 是固定 CPU 0、1 MiB xz 输入、每个版本三轮且交替顺序的结果。
`which`、`xz` 和 `cc1` 的输出在每轮 A/B 中均匹配：

| 负载 | 加速 | 指令减少 |
| --- | ---: | ---: |
| `which` | 0.98x | 0.1% |
| `xz` | 10.96x | 93.5% |
| `cc1` | 6.10x | 84.4% |

## 仍需验证的边界

这是用于证明优化方向的本地原型，还不能仅凭这些测试认定适合上游。继续设计时
至少需要补充更全面的 LR/SC 压力测试、多个并发 guest hart、fork 后状态，以及
可写文件 `MAP_SHARED` 和外部进程修改共享页的语义检查。
