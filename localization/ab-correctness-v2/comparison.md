# QEMU linux-user A/B comparison

- QEMU commit: `f9587d4045c67cd0d8d8bdcd5d0bb5b6b395b63c`
- Repetitions per variant: 3
- Baseline: `current` (`2b2c5d33a2db637e9a052ab3369dcb410be44ff37c149dd29737cea1decdd5b7`)
- Candidate: `multi-cpu-flag-v2` (`416929f40054b00c76965041b9f3e821ca059e52d70b83ff70e943fad5598785`)
- Order alternates A/B then B/A; each workload is warmed once per variant.
- All outputs match within each workload.

| Workload | Baseline wall median | Candidate wall median | Speedup | Baseline cycles | Candidate cycles | Instruction reduction |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `which` | 0.0241 s | 0.0246 s | 0.98x | 0.055 B | 0.056 B | 0.1% |
| `xz` | 21.7233 s | 1.9813 s | 10.96x | 109.004 B | 9.891 B | 93.5% |
| `cc1` | 12.6872 s | 2.0799 s | 6.10x | 63.495 B | 10.308 B | 84.4% |

The candidate is experimental. Matching workload outputs do not replace targeted correctness testing. Per-run measurements are in `results.csv`, and raw perf output is under `raw/`.
