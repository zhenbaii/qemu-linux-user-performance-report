---
Date: 2026-10-28
---
这个报告是关于老师在群里提到的vset_* 家族指令的TB截断问题的实现报告.

旧 continuation 实验: https://github.com/zhenbaii/qemu/tree/research/vset-tb-continuation

当前 direct-chain + TCG IR 实验: https://github.com/zhenbaii/qemu/tree/research/vset-direct-chain-full-ir

## 原始上游实现

在原本的QEMU上游实现中, 针对vset_* 家族指令的实现是比较保守的. 通过梳理QEMU的源码树, 可以得到如下的链路:
```
Guest executes vsetvli / vsetivli / vsetvl
        │
        ▼
trans_vset*
        │
        ▼
do_vsetvl()
        │
        ├── gen_helper_vsetvl(...)
        │       └── 生成运行时 helper 调用
        │
        ├── gen_update_pc(...)
        │
        ├── lookup_and_goto_ptr(...)
        │
        └── s->base.is_jmp = DISAS_NORETURN
                │
                ▼
          当前 TB 被强制结束
                │
════════════════╪════════════════ 运行时
                │
                ▼
       执行 helper_vsetvl()
                │
                ▼
更新 env->vl / env->vtype / env->vstart / env->vill
                │
                ▼
       离开当前 TB
                │
                ▼
       TB lookup / dispatch
                │
                ▼
根据新的 vector state 找到/生成下一个 TB
                │
                ▼
重新初始化 DisasContext
                │
                ▼
继续执行 vset* 后面的 guest 指令
```

上游对待vsetvli, vsetivli, vsetvl是一视同仁的, 都在翻译到这三条指令时截断当前TB, 


## patch思路

在规范中, 这三条指令的定义和操作数的形式可以由下表给出:

| 指令             | 拆解                        | 含义                             |
| -------------- | ------------------------- | ------------------------------ |
| **`vsetvl`**   | `vset` + `vl`             | `vtype` 来自**寄存器**, AVL同理       |
| **`vsetvli`**  | `vset` + `vl` + `i`       | `vtype` 是**立即数**, AVL为寄存器      |
| **`vsetivli`** | `vset` + `i` + `vl` + `i` | **AVL 是立即数**，`vtype` 也是**立即数** |

对于`vsetvl`, 没什么好说的, 在翻译期是得不到任何额外信息的, 因为都是运行时的寄存器决定的. 

而对于后面两条指令就不同了. 后面的两条指令中, `vtype`永远是立即数, 而AVL则可能是立即数, 也可能是寄存器表示. 而立即数是翻译期就可以知道的. 

因此, 对于立即数场景, 我们其实可以不用去截断TB, 回到lookup中动态获取最新状态后查询下一个TB, 而是可以直接继续翻译下去, 这就可能带来潜在的lookup开销的降低. 

因此, 补丁的思路就是, 对于存在立即数的场景, 即除了vsetvl之外的两个指令, 不去截断TB, 而选择继续翻译下去, 从而可以省去一部分的exit + lookup开销.

## 实现补丁

- QEMU基线: [`d731492832`](https://github.com/zhenbaii/qemu/commit/d73149283205645625bfa9fe029cfb68e4c4a9ae), 2026-10-24
- 实验分支: [`research/vset-tb-continuation`](https://github.com/zhenbaii/qemu/tree/research/vset-tb-continuation)
- 完整diff与三提交列表: [`d731492832...ea7e2e6312`](https://github.com/zhenbaii/qemu/compare/d73149283205645625bfa9fe029cfb68e4c4a9ae...ea7e2e63123b588286dcb1e263a5c6558a460598)

三个提交分别完成:

1. 提取并共享vtype decoder;
2. 让立即数vtype场景可以继续当前TB;
3. 修复动态AVL可能导致的后继TB stale chaining.

该分支用于本地性能研究和复现实验, 不作为可直接提交上游的版本.

## 实验结果

| 方案                   | 长 `cc1` cycles | zlib-ng RVV cycles |
| -------------------- | -------------- | ------------------ |
| vsetvli + `vsetivli` | 未重测            | +2.93%             |
| `vsetivli-only`      | **+7.79%**     | **+7.87%**         |

第一个方案指的就是两个指令都不去做TB截断, 而第二个方案则仅针对AVL和vtype都是立即数的场景不做截断. 结果都是引入了性能的倒退. 初步分析原因如下.


原始的干净基线在vset_* 家族指令处统一做exit + lookup, 使得不同的trace都到达这个lookup时, 如果他们此时的状态是一致的, 则都可以共享同一个后续TB:
```
入口状态 A 的 TB ─┐
入口状态 B 的 TB ─┼─ vsetivli ─→ 共享的后继 TB
入口状态 C 的 TB ─┘
```

而我们现在的实现, 就导致了vset_* 这条指令处不发生TB截断, 从而导致不同的trace到达这条指令后, 都各自继续囊括了这条指令后面的, 截止到下一个TB开始前的所有指令, 从而导致了大量指令被重复翻译缓存:
```
入口状态 A 的 TB：vsetivli + 后继代码
入口状态 B 的 TB：vsetivli + 后继代码
入口状态 C 的 TB：vsetivli + 后继代码
```

这是已经直接观察到的一项回退机制：它会改变翻译到 host 后的代码量和布局。现有数据
还不能在 I-cache、uop cache、寄存器压力和依赖停顿之间给出唯一的微架构归因。

另外，动态 AVL continuation 还有两个结构性代价：translator 把
`vl_eq_vlmax` 保守置为 false，使同一 TB 内后续 vector 指令可能失去 GVEC 快径；修复
动态出口 key 时引入的 sticky `outgoing_tb_key_dynamic` 会让 TB 后续的直接跳转和循环
回边也退回动态 lookup。

上表两行来自不同时间、不同候选范围的实验，`vsetvli + vsetivli` 的长 `cc1` 也没有在
那一轮重测，不能按“放行指令越多就必然越慢”直接做单调比较。性能计数使用宿主机
`perf stat` 的 `cycles:u`，不是 guest `rdcycle`。重复翻译则由 `-d in_asm/-d out_asm`
直接验证：候选少 31 个 TB，但多 130 个重复 guest 指令实例、129 行 host 指令和
8,453 字节输出汇编。

因此, 关于删除 TB 边界的 continuation 方案不再继续推进. 后续换成保留边界、对有限
后继 key 做 direct chaining，并进一步尝试消除 helper。

## 替代方案：保留 TB 边界的 direct chain + TCG IR

新方案仍在 `vset*` 后结束当前 TB，因此不同来源可以共享同一个后继 TB。区别在于：

- `vsetivli` 的 AVL/vtype 全部已知，使用一个 jump slot；
- `vsetvli` 的 vtype 已知，动态 AVL 只会让后继 key 的 `VL_EQ_VLMAX` 二选一，因此
  根据运行时 `vl == vlmax` 选择两个 jump slot；
- `vsetvli x0,x0` 和寄存器 vtype 的 `vsetvl` 保留原动态 lookup；
- 在 user-mode 下，将安全的立即数 vtype 路径从 `helper_vsetvl` 改为等价 TCG IR，
  直接更新 `vtype/vl/vstart/vill/rd`；system-mode 不变。

这样既保留了后继 TB 共享，也不会把 `vl_eq_vlmax=false` 的保守状态传播到后继 vector
指令。实现基于同一干净提交 `d731492832`，最终提交为 `a814a8ee55`。

### 正确性

- 14 组 vector 状态矩阵、2048 个 vtype × 7 个 AVL 全部一致；
- 非法 vtype、fault/resume 和动态 AVL 后继 key 测试一致；
- clean/candidate 的状态矩阵 TB 数同为 59，确认没有 continuation；
- `vsetivli` Trace 从 1003 降为 5；动态 `vsetvli` Trace 从 3005 降为 1010，两个
  jump slot 都实际建立链接。

### 性能

测试固定 CPU 0、关闭 ASLR，变体预热后轮换执行，输出一致：

| 负载 | direct-chain cycles | full-IR cycles | full-IR instructions |
| --- | ---: | ---: | ---: |
| zlib-ng RVV，五轮 | -1.94% | **-4.97%** | **-5.98%** |
| 长 `cc1`，三轮 | -5.21% | **-7.78%** | **-13.58%** |

full IR 相对已经保留 helper 的 direct-chain，zlib-ng 和长 `cc1` 又分别降低 3.08% 和
2.71% cycles。长 `cc1` 的一轮机制 profile 中，`helper_vsetvl` 从 2.37% 降到
0.01%，`helper_lookup_tb_ptr` 从 14.28% 降到 12.90%，说明热的立即数 vtype helper
路径确实被 IR 取代。profile 用于解释机制，性能结论以多轮 `perf stat` 为准。

当前判断是：这个替代方案值得继续扩大真实构建负载和 host 配置验证。它仍是本地
linux-user 研究实现；如需向 QEMU 上游推进，应由开发者依据实验结论独立重写并审查。

实现分支与完整 diff：

- [`research/vset-direct-chain-full-ir`](https://github.com/zhenbaii/qemu/tree/research/vset-direct-chain-full-ir)
- [`d731492832...a814a8ee55`](https://github.com/zhenbaii/qemu/compare/d73149283205645625bfa9fe029cfb68e4c4a9ae...a814a8ee55)
