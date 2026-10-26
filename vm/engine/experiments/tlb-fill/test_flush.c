/* Appended to the real patched cputlb.c, with unused functions discarded.
 * Scheduling/locks are modeled. Actual TLB/victim/jump-cache bytes, reset
 * fields and pending-flush atomics are compared between the two paths.
 */
#ifdef NDEBUG
#error "Assertions must be enabled"
#endif
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

bool tcg_allowed = true;
bool target_page_bits_decided = true;
int target_page_bits = 12;
static unsigned lock_depth, locks, unlocks;
void tb_lock(void) { assert(lock_depth++ == 0); ++locks; }
void tb_unlock(void) { assert(lock_depth-- == 1); ++unlocks; }
bool qemu_cpu_is_self(CPUState *cpu) { (void)cpu; return true; }
void async_run_on_cpu(CPUState *cpu, run_on_cpu_func fn, run_on_cpu_data data)
{ fn(cpu, data); }
void tb_flush_jmp_cache(CPUState *cpu, target_ulong page)
{ (void)cpu; (void)page; }

static uint32_t random_state = 0x101026;
static uint32_t random_word(void)
{
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
}

static void initialize(ARMCPU *arm)
{
    memset(arm, 0, sizeof(*arm));
    CPUState *cpu = (CPUState *)arm;
    cpu->env_ptr = &arm->env;
    unsigned char *p = (unsigned char *)&arm->env;
    for (size_t i = 0; i < sizeof(arm->env); ++i) { p[i] = random_word(); }
    for (unsigned i = 0; i < TB_JMP_CACHE_SIZE; ++i) {
        cpu->tb_jmp_cache[i] = (void *)(uintptr_t)(0x100000 + i*16);
    }
}

static void equivalent(ARMCPU *a, ARMCPU *b)
{
    assert(!memcmp(&a->env, &b->env, sizeof(a->env)));
    CPUState *x = (CPUState *)a, *y = (CPUState *)b;
    assert(!memcmp(x->tb_jmp_cache, y->tb_jmp_cache, sizeof(x->tb_jmp_cache)));
    assert(x->pending_tlb_flush == y->pending_tlb_flush);
    assert(!lock_depth && locks == unlocks);
}

static void check_bounds(void)
{
    size_t page = sysconf(_SC_PAGESIZE), bytes = page*20;
    unsigned char *p = mmap(NULL, bytes+page*2, PROT_READ|PROT_WRITE,
                            MAP_ANONYMOUS|MAP_PRIVATE, -1, 0);
    assert(p != MAP_FAILED);
    assert(!mprotect(p, page, PROT_NONE));
    assert(!mprotect(p+page+bytes, page, PROT_NONE));
    unsigned char *base = p+page;
    const size_t sizes[] = {0, 1, 31, 127, 128, 129, 255, 256, 2048, 8192, 65536};
    for (unsigned offset = 0; offset < 32; ++offset) {
        for (unsigned i = 0; i < sizeof(sizes)/sizeof(sizes[0]); ++i) {
            size_t n = sizes[i];
            memset(base, 0x5a, bytes);
            vmhost_tlb_fill_ff(base+offset, n);
            for (size_t j = 0; j < bytes; ++j) {
                assert(base[j] == (j >= offset && j < offset+n ? 255 : 0x5a));
            }
        }
    }
    /* Eligible stores end exactly at a protected page. */
    for (unsigned i = 0; i < sizeof(sizes)/sizeof(sizes[0]); ++i) {
        memset(base, 0x5a, bytes);
        vmhost_tlb_fill_ff(base+bytes-sizes[i], sizes[i]);
    }
    assert(!munmap(p, bytes+page*2));
}

static uint64_t nanos(clockid_t clock)
{
    struct timespec ts;
    assert(!clock_gettime(clock, &ts));
    return (uint64_t)ts.tv_sec*1000000000 + ts.tv_nsec;
}

static uint64_t exercise(ARMCPU *arm, unsigned kind, unsigned iterations)
{
    CPUState *cpu = (CPUState *)arm;
    uint64_t checksum = 0;
    for (unsigned i = 0; i < iterations; ++i) {
        if (kind == 1) {
            tlb_flush_by_mmuidx_async_work(cpu, RUN_ON_CPU_HOST_INT(1));
        } else if (kind == 2) {
            tlb_flush_by_mmuidx_async_work(cpu, RUN_ON_CPU_HOST_INT((i & 1) ? 5 : 255));
        } else {
            tlb_flush_nocheck(cpu);
        }
        if (kind == 3) {
            /* Model accesses after invalidation, not merely an empty store loop.
             * Only a working-set approximation; not guest workload timing. */
            for (unsigned slot = 0; slot < 16; ++slot) {
                CPUTLBEntry *entry = &arm->env.tlb_table[i & 1][slot*13];
                entry->addr_read = (uint64_t)slot << 12;
                entry->addend = i;
                checksum += *(volatile target_ulong *)&entry->addr_read;
            }
        }
    }
    return checksum;
}

int main(int argc, char **argv)
{
    alarm(30);
    ARMCPU *a = calloc(1, sizeof(*a)), *b = calloc(1, sizeof(*b));
    assert(a && b);
    if (argc == 1) {
        check_bounds();
        for (unsigned trial = 0; trial < 512; ++trial) {
            initialize(a);
            memcpy(b, a, sizeof(*b));
            ((CPUState *)b)->env_ptr = &b->env;
            unsigned mask = random_word() & ALL_MMUIDX_BITS;
            unsigned before = locks;
            vmhost_tlb_temporal = false;
            if (trial & 1) { tlb_flush_by_mmuidx_async_work((CPUState *)a, RUN_ON_CPU_HOST_INT(mask)); }
            else { tlb_flush_nocheck((CPUState *)a); }
            vmhost_tlb_temporal = true;
            if (trial & 1) { tlb_flush_by_mmuidx_async_work((CPUState *)b, RUN_ON_CPU_HOST_INT(mask)); }
            else { tlb_flush_nocheck((CPUState *)b); }
            equivalent(a, b);
            assert(locks-before == 2);
        }
        printf("{\"passed\":true,\"differential_flushes\":512,\"buffer_boundary_cases\":363,"
               "\"main_bytes\":%zu,\"victim_bytes\":%zu,\"bank_bytes\":%zu,"
               "\"main_alignment_mod16\":%zu}\n", sizeof(a->env.tlb_table),
               sizeof(a->env.tlb_v_table), sizeof(a->env.tlb_table[0]),
               (size_t)((uintptr_t)a->env.tlb_table & 15));
    } else {
        assert(argc == 2);
        unsigned iterations = strtoul(argv[1], NULL, 10);
        assert(iterations >= 100 && iterations <= 100000);
        initialize(a);
        for (unsigned kind = 0; kind < 4; ++kind) {
            for (unsigned run = 0; run < 12; ++run) {
                /* Three complete ABBA rounds in one pinned process. */
                vmhost_tlb_temporal = (run % 4 == 1 || run % 4 == 2);
                exercise(a, kind, 64);
                uint64_t start = nanos(CLOCK_MONOTONIC), cpu = nanos(CLOCK_THREAD_CPUTIME_ID);
                uint64_t checksum = exercise(a, kind, iterations);
                cpu = nanos(CLOCK_THREAD_CPUTIME_ID)-cpu;
                uint64_t elapsed = nanos(CLOCK_MONOTONIC)-start;
                printf("{\"kind\":%u,\"run\":%u,\"temporal\":%s,\"iterations\":%u,"
                       "\"wall_ns_per_flush\":%.3f,\"cpu_ns_per_flush\":%.3f,\"checksum\":%llu}\n",
                       kind, run, vmhost_tlb_temporal ? "true" : "false", iterations,
                       (double)elapsed/iterations, (double)cpu/iterations,
                       (unsigned long long)checksum);
            }
        }
    }
    free(a); free(b);
    return 0;
}
