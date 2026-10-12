# Narrow localization of the RISC-V reservation regression

- Three repetitions per variant; the first four variants used rotated order.
- Both xz and cc1 outputs match across every run and variant.
- Every QEMU binary was built with `-O2` from commit `f9587d4045`.
- Diagnostic variants are not correctness-preserving fixes.

## xz

| Variant | Change | Wall median | Range | Speedup | Cycles | Instructions | Reduction |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `current` | Unmodified QEMU | 22.0126 s | 21.8499–22.2834 s | 1.00x | 110.321 B | 347.183 B | 0.0% |
| `helper-noop` | Keep atomic fallback; make invalidation helper empty | 21.3333 s | 21.2858–21.4146 s | 1.03x | 106.293 B | 342.763 B | 1.3% |
| `store-no-serialize` | Only bypass ordinary-store atomic serialization | 1.9935 s | 1.9788–2.0012 s | 11.04x | 9.898 B | 22.549 B | 93.5% |
| `full-revert` | Reverse the complete reservation correctness commit | 1.8374 s | 1.8309–2.2566 s | 11.98x | 8.994 B | 16.438 B | 95.3% |
| `readonly-shared-serial` | Do not enter parallel context for read-only shared mmap | 1.1390 s | 1.1233–1.1486 s | 19.33x | 5.540 B | 22.214 B | 93.6% |

## cc1

| Variant | Change | Wall median | Range | Speedup | Cycles | Instructions | Reduction |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `current` | Unmodified QEMU | 12.8834 s | 12.8385–12.9677 s | 1.00x | 64.181 B | 168.998 B | 0.0% |
| `helper-noop` | Keep atomic fallback; make invalidation helper empty | 12.5104 s | 12.4680–12.5213 s | 1.03x | 61.993 B | 166.220 B | 1.6% |
| `store-no-serialize` | Only bypass ordinary-store atomic serialization | 2.0719 s | 2.0588–2.1375 s | 6.22x | 10.186 B | 26.356 B | 84.4% |
| `full-revert` | Reverse the complete reservation correctness commit | 1.9629 s | 1.9242–2.0057 s | 6.56x | 9.473 B | 22.921 B | 86.4% |
| `readonly-shared-serial` | Do not enter parallel context for read-only shared mmap | 1.7427 s | 1.7102–1.7454 s | 7.39x | 8.466 B | 25.980 B | 84.6% |
