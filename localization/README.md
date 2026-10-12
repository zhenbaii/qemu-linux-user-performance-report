# xz 构建热点的 QEMU 源码定位

> 持久化的正确性优先实验补丁保存在
> `patches/riscv-linux-user-multi-cpu-reservation-v1.diff`，应用方法和校验信息见
> `patches/README.md`。

## 结论

当前最值得优先研究的不是 `tb_tc_cmp`、GLib `GTree` 或 pthread mutex 本身，而是下面两个模块的交互：

1. `linux-user/mmap.c:target_mmap()`：任意非 `MAP_PRIVATE` 的成功映射都会调用 `begin_parallel_context()`，包括 `PROT_READ | MAP_SHARED` 的只读 locale/gconv cache。
2. `target/riscv/tcg/` 的 reservation 维护：提交 `5089493e45d3`（`linux-user/riscv: invalidate reservations after stores`）让 `CF_PARALLEL` 下的每条普通 RISC-V store 先通过 `helper_exit_atomic` 退出 TB，再由 `cpu_exec_step_atomic()` 串行重执行一条 guest 指令。

在此次复现中，`cc1` 读取 `/usr/lib64/gconv/gconv-modules.cache` 时建立一个只读 `MAP_SHARED` 映射。这个映射让单线程进程永久进入 `CF_PARALLEL`，随后所有普通 store 都付出 atomic fallback、TB 状态恢复、TB 区间树查找和全局互斥开销。

因此可以把第一处优化目标定位为：

> **RISC-V linux-user 的 reservation/store 串行化策略，尤其是它与 `linux-user` 共享映射触发 `CF_PARALLEL` 的条件之间的关系。**

这比直接优化 `tb_tc_cmp()` 或互斥锁更接近根因。

## 从完整 xz 构建得到的线索

完整报告位于 [`../workloads/xz/report.md`](../workloads/xz/report.md)。构建成功，wall time 为 3400.425 秒，共记录 2,165,478 个已确认的 QEMU 样本，lost 为 0。

| 观察项 | 结果 |
| --- | ---: |
| `cc1` 占全部 QEMU period | 53.2% |
| 查找、调度与缓存维护 | 32.4% |
| host 共享运行时 | 25.9% |
| `___pthread_mutex_unlock` self | 9.5% |
| `tb_tc_cmp` self | 6.0% |
| `helper_riscv_invalidate_reservations` self | 5.3% |
| `g_tree_lookup_node` self | 4.6% |

排名靠前的多个 `cc1` 进程都呈现相近的机制分布，说明它不是某一个源文件的偶然特征。最大的单个 `cc1` 实例在编译 `test_index.c`，约占整次构建 QEMU period 的 8%。

`period` 是硬件事件权重，不应直接解释为墙钟时间；它在这里用于选择值得隔离的负载和函数。

## 可重复的隔离实验

### 一条命令完成多轮 A/B 对比

下面的命令会以交替顺序运行当前版和局部回退版 QEMU，各做 5 轮 `which`、xz 压缩和 `cc1`，检查输出一致性，并在最后打印 Markdown 汇总表：

```bash
cd /home/holo/ospp-qemu-optimisation
./research/xz-localization/compare-qemu-ab.sh 5
```

结果保存在 `research/xz-localization/ab-runs/<时间>/comparison.md`，逐轮数据在同目录的 `results.csv`，原始计数在 `raw/`。脚本会检查两版 QEMU 都以 `-O2` 编译。需要固定 CPU 时可以使用：

```bash
CPUSET=2-5 ./research/xz-localization/compare-qemu-ab.sh 5
```

如果已经准备好自己修改后的 QEMU，可以跳过自动回退构建：

```bash
BASELINE_QEMU=/path/to/before/qemu-riscv64 \
CANDIDATE_QEMU=/path/to/after/qemu-riscv64 \
CANDIDATE_LABEL=optimized \
./research/xz-localization/compare-qemu-ab.sh 5
```

### 单独重放 cc1

`replay-cc1.sh` 直接通过 QEMU 运行构建根中的 RISC-V `cc1`，编译固定的 `probe.c`。它适合反复采样，不需要重新执行约 57 分钟的完整 RPM 构建：

```bash
cd /home/holo/ospp-qemu-optimisation
./research/xz-localization/replay-cc1.sh C.UTF-8 1
```

也可以选择另一个 QEMU 二进制：

```bash
REPLAY_QEMU=/path/to/qemu-riscv64 \
  ./research/xz-localization/replay-cc1.sh C.UTF-8 1
```

同一输入的早期探索结果如下。数字为 `perf stat -r 3` 的均值：

| QEMU / guest locale | task-clock | cycles:u | instructions:u | 相对当前 C.UTF-8 |
| --- | ---: | ---: | ---: | ---: |
| 当前 QEMU / `C.UTF-8` | 12,913 ms | 63.79 B | 168.93 B | 1.00x |
| 当前 QEMU / `C` | 1,779 ms | 8.62 B | 25.93 B | 0.138x |
| 局部回退 `5089493e45d3` / `C.UTF-8` | 1,931 ms | 9.48 B | 22.93 B | 0.150x |

当前版本与回退版本生成的汇编文件完全相同：

```text
f9c89e259336a9e719e6fb30f2ab93f58a81a694ef126b00ce6f7f70bf50cd75
```

回退版在这次探索中误用了 `-O0`，而当前版是 `-O2`，因此不能把表中的 6.7 倍当作严格的版本性能比。`-O0` 回退版仍远快于 `-O2` 当前版，加上同一当前二进制的 locale 对照，足以支持触发链定位；正式数值应以 `compare-qemu-ab.sh` 生成的同配置、多轮交替结果为准。

这不是建议回退该提交。该提交在多个 guest hart 共享内存时修复 LR/SC reservation 的正确性问题。回退实验只用于确认新路径是性能差异的来源，并为后续设计保留正确性的优化方案提供因果证据。三组早期原始计数分别保存在 `current-C.UTF8-stat.txt`、`current-C-stat.txt` 和 `reverted-C.UTF8-stat.txt`。

## 触发条件

当前 QEMU、`C.UTF-8` 的 guest syscall trace 中有：

```text
openat(..., "/usr/lib64/gconv/gconv-modules.cache", O_RDONLY|O_CLOEXEC) = 3
mmap(NULL, 27012, PROT_READ, MAP_SHARED, 3, 0) = ...
```

对应证据保存在 `cc1.strace`。`LC_ALL=C` 的 `cc1-C.strace` 没有 `MAP_SHARED`，也没有 guest `clone()`；两次编译输出一致。这表明本例并非真正的多线程 guest 负载，触发器是 locale 初始化产生的只读共享映射。

源码链路如下：

```text
guest cc1
  -> mmap(PROT_READ | MAP_SHARED, gconv-modules.cache)
  -> linux-user/mmap.c:target_mmap()
  -> begin_parallel_context()
  -> TB flush，并永久设置 CF_PARALLEL
  -> target/riscv/tcg/...:gen_store()
  -> gen_riscv_reservation_serialize()
  -> helper_exit_atomic()
  -> cpu_loop_exit_atomic()
  -> cpu_restore_state()
  -> tcg_tb_lookup()
  -> GTree 查找 + mutex
  -> cpu_exec_step_atomic()
  -> start_exclusive()，串行重执行一条 guest 指令
  -> helper_riscv_invalidate_reservations()
```

关键源码位置：

| 位置 | 作用 |
| --- | --- |
| `linux-user/mmap.c:1012-1019` | 任意非 private 映射进入 parallel context |
| `linux-user/user-internals.h:181-191` | flush TB 并设置 `CF_PARALLEL` |
| `target/riscv/tcg/translate.c:1148-1156` | parallel TB 中生成 `helper_exit_atomic` |
| `target/riscv/tcg/insn_trans/trans_rvi.c.inc:530-535` | 每个普通 scalar store 都先走 serialize 判断 |
| `target/riscv/tcg/insn_trans/trans_rvi.c.inc:524-525` | store 后生成 reservation invalidation helper |
| `target/riscv/tcg/op_helper.c:306-329` | 扫描 CPU 列表并清除重叠 reservation |
| `accel/tcg/cpu-exec.c:552-580` | exclusive 区间内单步重执行 atomic 指令 |
| `tcg/region.c:248-261` | 状态恢复时通过带锁区间树反查 TB |

## 调用图证据

当前 QEMU 的 DWARF callgraph 有 2675 个样本，lost 为 0。主要 self 热点为：

| 函数 | self cycles |
| --- | ---: |
| `helper_riscv_invalidate_reservations` | 8.68% |
| `cpu_restore_state_from_tb` | 7.88% |
| `tb_tc_cmp` | 7.44% |
| `___pthread_mutex_unlock` | 6.92% |
| `g_tree_lookup_node` | 5.38% |

这些平坦热点实际属于同一条调用链。`helper_exit_atomic` 的 inclusive 占比为 28.23%，其中：

```text
helper_exit_atomic                         28.23%
  cpu_loop_exit_atomic                    27.68%
    cpu_loop_exit_restore                 27.37%
      cpu_restore_state                   27.06%
        tcg_tb_lookup                     18.10%
          q_tree_lookup / g_tree_lookup   12.75%
            tb_tc_cmp                      7.33%
```

完整文本在 `current-flat.txt` 和 `current-atomic-callchain.txt`，原始数据在 `cc1-callgraph.data`。

在 `LC_ALL=C` 对照中，`helper_exit_atomic` 消失，`tb_tc_cmp` 降至约 0.3%，而且只出现在正常 TB 插入路径。热点转为 `liveness_pass_1`、`helper_lookup_tb_ptr` 和 `tcg_gen_code` 等正常翻译工作。对应数据在 `locale-C-flat.txt` 和 `cc1-C-callgraph.data`。

## 建议的优化顺序

### 局部变体已经确认主次关系

在 `narrow-runs/20261011-142545` 中，五个同为 `-O2` 的版本各运行三轮；xz 和 `cc1` 的每次输出均完全一致。结果如下：

| 诊断变体 | xz 加速 | cc1 加速 | xz 指令减少 | cc1 指令减少 |
| --- | ---: | ---: | ---: | ---: |
| 仅把 reservation helper 变为空函数 | 1.03x | 1.03x | 1.3% | 1.6% |
| 仅绕过普通 store 的 atomic serialize | 11.04x | 6.22x | 93.5% | 84.4% |
| 完整回退 reservation 提交 | 11.98x | 6.56x | 95.3% | 86.4% |
| 只读 shared mmap 不触发 `CF_PARALLEL` | 19.33x | 7.39x | 93.6% | 84.6% |

这把首要性能责任缩小到了普通 store 中的 `gen_riscv_reservation_serialize()`。helper 内的 CPU 列表扫描只有约 1%～2% 的指令成本；平坦报告中它看起来很热，是因为 atomic fallback 让它被极高频率地执行。

只读 mmap 变体比完整回退还快，说明即使移除 RISC-V reservation 提交，`CF_PARALLEL` 本身仍会让 TCG 使用成本更高的并行执行路径。最终设计可以重点研究：reservation 串行化是否必须复用这个同时表示“本进程有多个 guest hart”和“存在 shared mapping”的通用标志，或者是否需要区分两种进入并行模式的原因。

完整数据见 [`ab-narrow/comparison.md`](ab-narrow/comparison.md)，三个最小诊断改动和完整回退也以 `.diff` 文件保存在同一目录。

### 保留正确性的第一版原型

[`ab-correctness-v2`](ab-correctness-v2/) 保存了一个本地实验原型。它不改变共享映射触发 `CF_PARALLEL` 的现有逻辑，而是增加 `CF_MULTI_CPU`，仅在 linux-user 真正创建第二个 guest CPU 后让 RISC-V store 进入 reservation 串行化路径。若共享映射已经提前使进程进入 parallel context，第一次创建额外 CPU 时会在 exclusive 区域内刷新旧 TB 并完成状态升级。

固定 CPU 0、1 MiB xz 输入、三轮交替 A/B 的中位数结果为：xz 10.96x、`cc1` 6.10x，输出均匹配；`which` 为 0.98x。针对性 LR/SC 测试在当前版和原型上各执行 10,000 次均无错误，完整回退版作为负对照则 100 次全部暴露原缺陷。QEMU 自带 riscv64 linux-user TCG 测试 45/45 通过。

具体改动见 `correctness-preserving-prototype.diff`，测试过程与尚未覆盖的边界见 `correctness.md`。这仍是验证设计方向的原型，不代表已经满足上游提交所需的完整正确性论证。

### 1. 先消除“没有真实并行需求，却让所有 store 串行重执行”的情况

优化设计需要同时考虑两处状态：何时进入 `CF_PARALLEL`，以及 RISC-V reservation 在哪些 store 上真正需要跨 hart 失效。这是收益最大的方向。

不能简单把条件改成 `MAP_SHARED && PROT_WRITE` 后就结束，因为只读 shared mapping 仍可能被外部进程修改，也可能随后通过 `mprotect()` 变为可写。较稳妥的设计应明确处理：

- 第二个 guest hart 创建时必须进入并行模式；
- guest 可写 shared mapping、后续 `mprotect()` 和外部共享写入的语义；
- LR/SC reservation 跨 guest hart 的失效仍须正确；
- 从 serial 转 parallel 时已有 TB 必须失效或重译。

### 2. 再降低 reservation 维护本身的成本

如果真实多线程或真实共享写入场景仍然很热，再研究 `helper_riscv_invalidate_reservations()` 的 CPU 列表扫描、每条普通 store 都调用 helper，以及 reservation 元数据组织。完整构建中它有 5.3% self，占比足以成为第二阶段目标。

### 3. 暂不优先优化 `tb_tc_cmp`、GTree 和 mutex

它们在本例中主要由 `helper_exit_atomic -> cpu_restore_state -> tcg_tb_lookup` 放大。触发条件消失后，`tb_tc_cmp` 从 7.44% 降到约 0.3%。直接优化树比较或互斥锁可能改善症状，但上限明显低于减少 atomic fallback 次数。

## 下一步验证矩阵

优化方案完成后，至少跑以下四类用例：

| 用例 | 目的 |
| --- | --- |
| 单线程 + `C.UTF-8` + 只读 `MAP_SHARED` | 本次性能回归必须消失 |
| 单线程 + 可写 `MAP_SHARED` | 检查共享写入语义 |
| 两个 guest pthread/hart 对同一地址做 LR/SC | 检查 reservation 正确性 |
| 完整 xz RPM 构建 | 确认隔离收益能转化为端到端收益，且构建结果正确 |

先用 `replay-cc1.sh` 做快速迭代；确认 callgraph 中 `helper_exit_atomic`、`cpu_restore_state` 和 `tcg_tb_lookup` 不再被普通 store 放大后，再跑完整构建。不要只看 wall time，也要比较 `cycles:u`、`instructions:u`、输出哈希，以及 correctness 测试。

## 结论边界

隔离程序比完整 xz 构建简单，但它使用同一个 RISC-V `cc1` 和相同 QEMU，完整构建中多个高耗时 `cc1` 的热点形状也一致。locale 对照隔离了 `MAP_SHARED` 触发条件，局部回退又隔离了 reservation 提交，二者共同支持上述定位。

本目录内容用于本地性能调查。根据 QEMU 仓库的代码来源规则，这里的 AI 辅助分析和文字不应直接作为上游贡献；实际优化实现和提交说明应由贡献者独立完成。
