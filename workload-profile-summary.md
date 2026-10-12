## 总览

| 负载 | wall | cgroup CPU | QEMU 样本 | unknown |
| --- | ---: | ---: | ---: | ---: |
| [which RPM build](workloads/which/report.md) | 564.474s | 未采集 | 189,242 | 11.3% |
| [xz RPM build](workloads/xz/report.md) | 3,400.425s | 11,626.957s | 2,165,478 | 11.4% |
| [zlib-ng RPM build](workloads/zlib-ng/report.md) | 3,668.118s | 8,982.520s | 1,782,657 | 10.0% |
| [file RPM build](workloads/file/report.md) | 1,609.929s | 2,288.162s | 442,448 | 11.1% |
| [lz4 RPM build](workloads/lz4/report.md) | 11,309.682s | 55,126.128s | 9,463,185 | 14.1% |

## which RPM build

#### 工具线索

| 工具 | 占比 |
| --- | ---: |
| `cc1` | 34.6% |
| `lto1` | 21.0% |
| `lto1-ltrans` | 19.6% |
| `rpmbuild` | 12.8% |
| `as` | 2.4% |

#### QEMU 机制

| 机制 | 占比 |
| --- | ---: |
| 查找调度/缓存维护 | 31.2% |
| host 共享运行时 | 23.6% |
| 翻译与生成 | 18.5% |
| unknown | 11.3% |
| helper | 8.0% |
| linux-user syscall/signal/atomic | 7.4% |

#### QEMU 热点符号

| 符号 | 占比 |
| --- | ---: |
| `___pthread_mutex_unlock` | 7.9% |
| `helper_riscv_invalidate_reservations` | 5.8% |
| `tb_tc_cmp` | 5.5% |
| `liveness_pass_1` | 4.9% |
| `g_tree_lookup_node` | 4.4% |

## xz RPM build

#### 工具线索

| 工具 | 占比 |
| --- | ---: |
| `cc1` | 53.2% |
| `rpmbuild` | 12.1% |
| `bash` | 11.6% |
| `xz` | 4.9% |
| `lto1-ltrans` | 4.5% |

#### QEMU 机制

| 机制 | 占比 |
| --- | ---: |
| 查找调度/缓存维护 | 32.4% |
| host 共享运行时 | 25.9% |
| 翻译与生成 | 16.6% |
| unknown | 11.4% |
| linux-user syscall/signal/atomic | 7.1% |
| helper | 6.6% |

#### QEMU 热点符号

| 符号 | 占比 |
| --- | ---: |
| `___pthread_mutex_unlock` | 9.5% |
| `tb_tc_cmp` | 6.0% |
| `helper_riscv_invalidate_reservations` | 5.3% |
| `g_tree_lookup_node` | 4.6% |
| `liveness_pass_1` | 4.4% |

## zlib-ng RPM build

#### 工具线索

| 工具 | 占比 |
| --- | ---: |
| `cc1` | 51.2% |
| `lto1-ltrans` | 22.0% |
| `lto1` | 18.5% |
| `as` | 2.4% |
| `cmake` | 2.0% |

#### QEMU 机制

| 机制 | 占比 |
| --- | ---: |
| 查找调度/缓存维护 | 37.7% |
| host 共享运行时 | 28.6% |
| unknown | 10.0% |
| 翻译与生成 | 9.6% |
| linux-user syscall/signal/atomic | 8.2% |
| helper | 6.1% |

#### QEMU 热点符号

| 符号 | 占比 |
| --- | ---: |
| `___pthread_mutex_unlock` | 12.9% |
| `tb_tc_cmp` | 8.9% |
| `g_tree_lookup_node` | 6.9% |
| `helper_riscv_invalidate_reservations` | 5.5% |
| `cpu_exec` | 4.8% |

## file RPM build

#### 工具线索

| 工具 | 占比 |
| --- | ---: |
| `cc1` | 19.4% |
| `m4` | 16.3% |
| `aclocal` | 12.2% |
| `lto1` | 9.9% |
| `autom4te` | 8.5% |

#### QEMU 机制

| 机制 | 占比 |
| --- | ---: |
| 查找调度/缓存维护 | 32.7% |
| 翻译与生成 | 20.7% |
| host 共享运行时 | 17.5% |
| unknown | 11.1% |
| helper | 9.9% |
| linux-user syscall/signal/atomic | 8.0% |

#### QEMU 热点符号

| 符号 | 占比 |
| --- | ---: |
| `helper_riscv_invalidate_reservations` | 7.7% |
| `helper_lookup_tb_ptr` | 6.6% |
| `___pthread_mutex_unlock` | 5.4% |
| `tb_tc_cmp` | 4.7% |
| `liveness_pass_1` | 4.6% |

## lz4 RPM build

#### 工具线索

| 工具 | 占比 |
| --- | ---: |
| `cc1` | 70.7% |
| `lz4` | 28.4% |
| `as` | 0.3% |
| `rpmbuild` | 0.1% |
| `ld` | 0.1% |

#### QEMU 机制

| 机制 | 占比 |
| --- | ---: |
| host 共享运行时 | 37.3% |
| 查找调度/缓存维护 | 31.3% |
| unknown | 14.1% |
| linux-user syscall/signal/atomic | 6.9% |
| helper | 5.6% |
| 翻译与生成 | 4.8% |

#### QEMU 热点符号

| 符号 | 占比 |
| --- | ---: |
| `___pthread_mutex_unlock` | 11.8% |
| `tb_tc_cmp` | 7.1% |
| `__pthread_cond_wait` | 6.4% |
| `g_tree_lookup_node` | 5.4% |
| `helper_riscv_invalidate_reservations` | 5.0% |
