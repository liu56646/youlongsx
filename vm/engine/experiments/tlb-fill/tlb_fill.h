#ifndef VMHOST_TLB_FILL_H
#define VMHOST_TLB_FILL_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* Exact byte-for-byte invalidation, not an MMU-bank skipping policy.
 * Use cached paired SIMD stores only on the aligned, fixed-size buffers for
 * which this candidate is intended. Other buffers retain libc semantics.
 * Android arm64 provides SIMD; v0 is caller-saved under AAPCS64.
 */
static inline void vmhost_tlb_fill_ff(void *destination, size_t bytes)
{
#if defined(__aarch64__)
    if (bytes && !(bytes & 127) && !((uintptr_t)destination & 7)) {
        unsigned char *p = destination;
        size_t remaining = bytes;
        __asm__ volatile(
            "movi v0.16b, #255\n"
            "1:\n"
            "stp q0, q0, [%[p], #0]\n"
            "stp q0, q0, [%[p], #32]\n"
            "stp q0, q0, [%[p], #64]\n"
            "stp q0, q0, [%[p], #96]\n"
            "add %[p], %[p], #128\n"
            "subs %[n], %[n], #128\n"
            "b.ne 1b\n"
            : [p] "+&r" (p), [n] "+&r" (remaining)
            : : "v0", "cc", "memory");
        return;
    }
#endif
    memset(destination, 255, bytes);
}
#endif
