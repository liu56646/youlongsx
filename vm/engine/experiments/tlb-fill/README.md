# Exact TLB fill experiment — rejected for performance

This candidate preserves the four full/per-bank invalidation buffer clears,
every byte and all locks, atomics and jump-cache invalidations. It only tries
cached ARM64 paired SIMD stores instead of the platform memset for eligible
aligned buffers. It is not the earlier failed bank-skipping algorithm.

The real cputlb.c functions passed 512 differential state checks and 363
buffer-boundary/guard-page cases on the phone. Scheduling/locks are modeled
in these standalone checks; this is not a complete VM concurrency test.

Three ABBA rounds in each of four standalone workloads found no useful
improvement. Full clear: 2264.062 to 2266.328 ns median CPU time. A single
bank: 1554.3685 to 1554.6155 ns. Mixed masks were about 0.67% faster, and
the post-clear access workload about 0.13% slower. These tiny differences do
not justify integrating the candidate. **Do not enable or ship as a speedup.**

The main TCG build does not apply this experiment. `VMHOST_TLB_TEMPORAL=1`
only opts in when using its separate experimental executable. All original
QEMU sources/objects and APKs remain unchanged.

Sources: `tlb_fill.h`, `patch_tlb_fill.py`, `test_flush.c`, `build_candidate.py`.
[Sanitized measurements](validation-results.json) preserve the check counts and timing samples.
The SIMD register convention follows the [Arm AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst);
performance claims are based solely on the recorded phone measurements.
