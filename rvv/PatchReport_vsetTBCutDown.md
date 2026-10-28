---
Date: 2026-10-28
---
这个报告是关于老师在群里提到的vset_* 家族指令的TB截断问题的实现报告.

patch: https://github.com/qemu/qemu/compare/master...zhenbaii:qemu:research/vset-tb-continuation

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

这个或许是引发性能倒退的最大原因, 这种结构的不用可能会导致翻译到host后的代码也不同.

因此, 关于这个TB截断的优化, 目前可能不作为后续推进. 或许可以换个思路: 对于立即数的场景, 做direct chaining, 而不是去做lookup. 目前正在尝试这个. 

