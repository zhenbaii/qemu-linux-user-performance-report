---
Date: 2026-10-28
---
这个报告是关于老师在群里提到的vset_* 家族指令的TB截断问题的实现报告. 实验表明, 阻止TB截断不会带来性能的提升, 反而会恶化. 

因此, 后面针对vset家族指令做了不同的优化方式. 主要是helper的TCG IR化和立即数情况的direct chaining. 

这两个实现都只在user mode下做, 而没有到system mode 做.


PATCH LINK:
TB截断实验: https://github.com/zhenbaii/qemu/tree/research/vset-tb-continuation
direct-chain + TCG IR 实验: https://github.com/zhenbaii/qemu/tree/research/vset-direct-chain-full-ir

BASELINE:
QEMU 官方提交 [`d73149283205645625bfa9fe029cfb68e4c4a9ae`](https://gitlab.com/qemu-project/qemu/-/commit/d73149283205645625bfa9fe029cfb68e4c4a9ae)，提交日期为 2026-10-24。


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

新方案下, 我们不再在立即数场景下不截断TB, 而是依旧截断, 避免旧方案中后继代码重复翻译问题. 根据vtype和AVL是否是立即数:

### vsetvl

保持主线原本的实现, 因为没有立即数可以提供任何额外的信息.

### vsetivli

这种情况下, AVL和vtype都是立即数. 因此, 对于当前TB(包含了vsetivli的这个TB)而言, 其用于查询下一个TB的状态矩阵(PC, flags, cflags, cs_base)是恒定不变的. 理由如下:
   -  不考虑vset家族指令. 在翻译阶段, 如果这个TB中的任何指令存在改变了状态矩阵的情况, 并且这种改变在翻译期间是无法知晓的(比如那些依赖运行时寄存器值的指令), 那么按照QEMU的原则, 是要在那条指令就产生TB截断的. 换句话说, 对于包含了vsetivli的这个TB而言, 其前序指令对状态矩阵的改变是在翻译期就知道的. 而能够进入这个TB, 本身也要求满足这个TB的状态矩阵. 
   - 因此, 在执行到vsetivli后, 在不同的执行流下, 其状态矩阵是固定不变的. 而现在vsetivli对于状态矩阵的改变也是在翻译期间就可以知道的, 因此在执行完这个TB后, 用于检索下一个TB的状态矩阵本身也是恒定不变的.

因此, 对于这个指令, 我们用direct chaining来优化.

### vsetvli

这种情况下, AVL由运行时的寄存器值提供, vtype依旧是立即数. 因此, 我们要按照情况选择合适的优化策略. 

#### `rd == x0 && rs1 == x0`
根据规范, 这是`AVL =  旧 vl`. 因此, 在翻译期无法做任何优化, 回退最原本的上游实现:
```
读取旧 VL
    → helper_vsetvl 处理状态更新
    → 更新 PC
    → lookup，根据真实 CPU 状态选择后继 TB
```

#### `vtype`无效
这个情况下, 下一个TB的状态矩阵也是确定的, 可以采用direct chaining:
```
TCG IR 写回确定状态
    → slot 0
    → 后继 TB
```

#### `rs1 == x0 && rd != x0`
根据规范, 是请求最大VL. 相当于AVL翻译期已知, 因此也是采用direct chaining. 

#### 普通寄存器 AVL
此时, AVL在翻译期间无法知晓. 但是仔细分析可以发现, 对于不同的执行流, 最后对于状态矩阵而言, 最终只会影响到`VL_EQ_MAX`这个状态, 其他状态在翻译期间都是可以确定下来的. 因此, 也是可以采用direct chaining, 不过要用到全部两个slot:
```
运行时计算 VL，写回向量状态
                │
          VL == VLMAX？
           /         \
         是           否
         │            │
       slot 0       slot 1
         │            │
  full-length TB   non-full TB
```

#### vsetvl helper的IR化
如下表:

| 情况                        | 翻译期知道什么            | 当前如何处理            |
| ------------------------- | ------------------ | ----------------- |
| `vsetivli`                | vtype、AVL 都已知      | 提前算出最终结果，IR 只负责写回 |
| `vsetvli rd,x0,…`，`rd≠x0` | vtype 已知，确定请求最大 VL | IR 写入 `VL=VLMAX`  |
| 普通 `vsetvli`，`rs1≠x0`     | vtype 已知，AVL 未知    | IR 在运行时计算 VL 并写回  |
| 上述路径的 vtype 无效            | 无效性在翻译期已知          | IR 写入确定的非法状态      |
| `vsetvli x0,x0,…`         | 依赖旧 VL 和兼容策略       | 保留 helper，优先于上述分类 |
| `vsetvl`                  | vtype 通常来自运行时寄存器   | 保留原本helper        |



### 性能

测试固定 CPU 0、关闭 ASLR，变体预热后轮换执行，输出一致：

| 负载 | direct-chain cycles | full-IR cycles | full-IR instructions |
| --- | ---: | ---: | ---: |
| zlib-ng RVV，五轮 | -1.94% | **-4.97%** | **-5.98%** |
| 长 `cc1`，三轮 | -5.21% | **-7.78%** | **-13.58%** |
