/* Actual diskless ARM64 TCG workload, not an Android boot benchmark.
 * Identity-map RAM with real four-level tables; invalidate and repopulate
 * guest TLBs on every iteration, verify all values, print counter timing.
 */
#include <stdint.h>
#include <stddef.h>

static uint64_t l0[512] __attribute__((aligned(4096)));
static uint64_t l1[512] __attribute__((aligned(4096)));
static uint64_t l2[512] __attribute__((aligned(4096)));
static volatile uint64_t data[32*512] __attribute__((aligned(4096)));
static char output[256];
static size_t length;

static void put(const char *s)
{ while (*s) { output[length++] = *s++; } }
static void decimal(uint64_t value)
{
    char digits[24];
    unsigned count = 0;
    do { digits[count++] = '0'+value%10; value /= 10; } while (value);
    while (count) { output[length++] = digits[--count]; }
}

static void emit(void)
{
    output[length] = 0;
    register uint64_t x0 __asm__("x0") = 4;
    register const char *x1 __asm__("x1") = output;
    __asm__ volatile("hlt #0xf000" : "+r"(x0) : "r"(x1) : "memory");
}
static void poweroff(void)
{
    register uint64_t x0 __asm__("x0") = 0x84000008;
    __asm__ volatile("hvc #0" : "+r"(x0) : : "memory");
    for (;;) { __asm__ volatile("wfi"); }
}
static uint64_t counter(void)
{
    uint64_t value;
    __asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(value) : : "memory");
    return value;
}
static void invalidate(void)
{ __asm__ volatile("dsb ishst; tlbi vmalle1; dsb ish; isb" : : : "memory"); }

void guest_main(void)
{
    l0[0] = (uintptr_t)l1 | 3;
    l1[1] = (uintptr_t)l2 | 3;
    for (unsigned i = 0; i < 32; ++i) {
        l2[i] = (0x40000000ULL + ((uint64_t)i << 21)) | (1 << 10) | (3 << 8) | 1;
    }
    uint64_t ttbr = (uintptr_t)l0;
    uint64_t tcr = 16 | (1 << 8) | (1 << 10) | (3 << 12) | (16 << 16) | (1 << 23);
    uint64_t mair = 0xff;
    __asm__ volatile("dsb sy; msr mair_el1, %0; msr tcr_el1, %1; msr ttbr0_el1, %2; isb"
                     : : "r"(mair), "r"(tcr), "r"(ttbr) : "memory");
    invalidate();
    uint64_t control;
    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(control));
    control |= 1 | (1 << 2) | (1 << 12);
    __asm__ volatile("msr sctlr_el1, %0; isb" : : "r"(control) : "memory");
    const unsigned iterations = 8000, pages = 32;
    uint64_t sum = 0, frequency;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frequency));
    uint64_t start = counter();
    for (unsigned i = 0; i < iterations; ++i) {
        invalidate();
        for (unsigned page = 0; page < pages; ++page) {
            uint64_t value = ((uint64_t)i << 32) | page;
            data[page*512] = value;
            uint64_t loaded = data[page*512];
            if (loaded != value) { put("MMU_GUEST_FAIL\n"); emit(); poweroff(); }
            sum += loaded;
        }
    }
    uint64_t ticks = counter()-start;
    uint64_t expected = ((uint64_t)iterations*(iterations-1)/2*pages << 32) +
                        (uint64_t)iterations*(pages*(pages-1)/2);
    if (sum != expected || !frequency || !ticks) {
        put("MMU_GUEST_FAIL\n"); emit(); poweroff();
    }
    put("MMU_GUEST_RESULT {\"iterations\":"); decimal(iterations);
    put(",\"pages\":"); decimal(pages);
    put(",\"ticks\":"); decimal(ticks);
    put(",\"frequency\":"); decimal(frequency);
    put(",\"checksum\":"); decimal(sum);
    put("}\n"); emit(); poweroff();
}
