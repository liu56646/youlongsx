/* Appended to the real target/arm/helper.c. Physical bus, QOM and logging
 * boundaries are modeled; all actual LPAE configuration/permission/fault
 * functions execute. The same fixture is built with each compiler variant.
 */
#ifdef NDEBUG
#error "Assertions must remain enabled"
#endif
#include <time.h>
#include <unistd.h>
static ARMCPU *expected_cpu;
static AddressSpace spaces[2];
static unsigned reads, max_depth, failure_read, fault_kind, table_attributes;
static uint64_t leaf_attributes, trace_digest;
static bool measuring;
static __typeof__(&get_phys_addr_lpae) volatile selected_walk = get_phys_addr_lpae;
int qemu_loglevel;
int qemu_log(const char *fmt, ...) { (void)fmt; return 0; }

Object *object_dynamic_cast_assert(Object *obj, const char *type,
                                  const char *file, int line, const char *func)
{
    (void)file; (void)line; (void)func;
    assert(obj == (Object *)expected_cpu);
    assert(!strcmp(type, TYPE_CPU) || !strcmp(type, TYPE_ARM_CPU));
    return obj;
}

AddressSpace *cpu_get_address_space(CPUState *cpu, int index)
{
    assert(cpu == (CPUState *)expected_cpu && index >= 0 && index < 2);
    return &spaces[index];
}

void g_assertion_message_expr(const char *domain, const char *file, int line,
                              const char *func, const char *expr)
{
    fprintf(stderr, "unexpected assertion %s %s:%d %s %s\n", domain, file, line, func, expr);
    abort();
}

static void digest(uint64_t x)
{
    if (measuring) { return; }
    trace_digest ^= x;
    trace_digest *= UINT64_C(1099511628211);
}

static uint64_t physical_read(AddressSpace *as, hwaddr address, MemTxAttrs attrs,
                              MemTxResult *result, bool big_endian)
{
    ++reads;
    assert(reads <= 8);
    digest(address); digest(as-&spaces[0]); digest(attrs.secure); digest(big_endian);
    *result = reads == failure_read ? (fault_kind ? MEMTX_ERROR : MEMTX_DECODE_ERROR) : MEMTX_OK;
    if (reads < max_depth) {
        return (0x100000 + ((uint64_t)reads << 16)) | 3 | ((uint64_t)table_attributes << 59);
    }
    return UINT64_C(0x40000000) | leaf_attributes;
}

uint64_t address_space_ldq_le(AddressSpace *as, hwaddr address, MemTxAttrs attrs, MemTxResult *result)
{ return physical_read(as, address, attrs, result, false); }
uint64_t address_space_ldq_be(AddressSpace *as, hwaddr address, MemTxAttrs attrs, MemTxResult *result)
{ return physical_read(as, address, attrs, result, true); }

static uint32_t rng = 0x261026;
static uint32_t next(void)
{ rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

static void setup(ARMCPU *cpu, ARMMMUIdx index, bool aa64, bool big, unsigned granule)
{
    memset(&cpu->env, 0, sizeof(cpu->env));
    CPUARMState *env = &cpu->env;
    env->features = (1ULL << ARM_FEATURE_V7) | (1ULL << ARM_FEATURE_V8) |
                    (1ULL << ARM_FEATURE_LPAE) | (1ULL << ARM_FEATURE_EL2) |
                    (1ULL << ARM_FEATURE_EL3);
    if (aa64) { env->features |= 1ULL << ARM_FEATURE_AARCH64; }
    env->aarch64 = aa64;
    env->cp15.scr_el3 = (aa64 ? SCR_RW : 0) | SCR_NS;
    env->cp15.hcr_el2 = aa64 ? HCR_RW : 0; /* no nested S2 in S1 descriptor reads */
    env->pstate = PSTATE_MODE_EL1h;
    cpu->id_aa64mmfr0 = 5;
    for (unsigned el = 1; el < 4; ++el) {
        env->cp15.sctlr_el[el] = big ? SCTLR_EE : 0;
        env->cp15.tcr_el[el].raw_tcr = aa64 ? 16 | (16ULL << 16) : 0;
        if (aa64) {
            env->cp15.tcr_el[el].raw_tcr |= (uint64_t)granule << 14;
            env->cp15.tcr_el[el].raw_tcr |= (uint64_t)(granule == 0 ? 2 : granule == 1 ? 3 : 1) << 30;
        }
        env->cp15.ttbr0_el[el] = 0x100000;
        env->cp15.ttbr1_el[el] = 0x200000;
        env->cp15.mair_el[el] = UINT64_C(0xff440400ff440400);
    }
    env->cp15.vtcr_el2.raw_tcr = aa64 ? 16 | (2 << 6) : 0;
    if (aa64) { env->cp15.vtcr_el2.raw_tcr |= (uint64_t)granule << 14; }
    env->cp15.vttbr_el2 = 0x100000;
    (void)index;
}

static bool walk(ARMCPU *cpu, ARMMMUIdx index, uint64_t address, unsigned access,
                 bool with_cache, uint64_t *physical)
{
    MemTxAttrs tx = {};
    tx.secure = regime_is_secure(&cpu->env, index);
    tx.user = regime_is_user(&cpu->env, index);
    int prot = 0;
    target_ulong size = 0;
    ARMMMUFaultInfo fi = {};
    ARMCacheAttrs cache = {};
    *physical = 0;
    reads = 0;
    bool failed = selected_walk(&cpu->env, address, access, index, physical,
                                    &tx, &prot, &size, &fi, with_cache ? &cache : NULL);
    digest(failed); digest(*physical); digest(prot); digest(size);
    digest(fi.type); digest(fi.level); digest(fi.stage2); digest(fi.s1ptw); digest(fi.ea);
    digest(fi.s2addr); digest(tx.secure); digest(tx.user);
    if (with_cache) { digest(cache.attrs); digest(cache.shareability); }
    return failed;
}

static uint64_t ns(void)
{
    struct timespec ts;
    assert(!clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts));
    return (uint64_t)ts.tv_sec*1000000000+ts.tv_nsec;
}

int main(int argc, char **argv)
{
    alarm(20);
    ARMCPU *cpu = calloc(1, sizeof(*cpu));
    assert(cpu);
    expected_cpu = cpu;
    ((CPUState *)cpu)->env_ptr = &cpu->env;
    max_depth = 4; leaf_attributes = 3 | (1 << 10); failure_read = 0;
    setup(cpu, ARMMMUIdx_S1NSE1, true, false, 0);
    uint64_t physical;
    assert(!walk(cpu, ARMMMUIdx_S1NSE1, 0x1234, MMU_DATA_LOAD, true, &physical));
    assert(physical == 0x40000234 && reads == 4);
    if (argc == 2) {
        measuring = true;
        unsigned iterations = strtoul(argv[1], NULL, 10);
        assert(iterations >= 1000 && iterations <= 10000000);
        for (unsigned i = 0; i < 1000; ++i) {
            assert(!walk(cpu, ARMMMUIdx_S1NSE1, 0x1234, MMU_DATA_LOAD, true, &physical));
        }
        uint64_t start = ns();
        for (unsigned i = 0; i < iterations; ++i) {
            assert(!walk(cpu, ARMMMUIdx_S1NSE1, 0x1234, MMU_DATA_LOAD, true, &physical));
        }
        printf("{\"iterations\":%u,\"cpu_ns_per_walk\":%.3f,\"digest\":\"%016llx\"}\n",
               iterations, (double)(ns()-start)/iterations, (unsigned long long)trace_digest);
    } else {
        assert(argc == 1);
        static const ARMMMUIdx indices[] = {ARMMMUIdx_S1NSE0, ARMMMUIdx_S1NSE1,
            ARMMMUIdx_S1SE0, ARMMMUIdx_S1SE1, ARMMMUIdx_S1E2, ARMMMUIdx_S1E3, ARMMMUIdx_S2NS};
        unsigned successes = 0, failures = 0;
        for (unsigned i = 0; i < 32768; ++i) {
            ARMMMUIdx index = indices[next() % 7];
            bool aa64 = next() & 1;
            unsigned granule = aa64 ? next()%3 : 0;
            setup(cpu, index, aa64, next() & 1, granule);
            /* Exercise EL3 secure mapping decisions and TBI independently. */
            if (next() & 1) { cpu->env.cp15.scr_el3 &= ~SCR_NS; }
            if (aa64 && (next() & 1)) { cpu->env.cp15.tcr_el[1].raw_tcr |= 1ULL << 37; }
            unsigned el = regime_el(&cpu->env, index);
            cpu->env.cp15.sctlr_el[el] |= (next() & 1) ? SCTLR_WXN : 0;
            max_depth = 1+next()%4;
            failure_read = next()%7 == 0 ? 1+next()%4 : 0;
            fault_kind = next() & 1;
            table_attributes = next() & 31;
            leaf_attributes = (next() & 1 ? 3 : 1) | ((uint64_t)(next() & 0x3ff) << 2) |
                              ((uint64_t)(next() & 7) << 52);
            uint64_t va = next();
            if (aa64 && (next() & 1)) { va |= UINT64_C(0xffff000000000000); }
            if (aa64 && (next() & 1)) { va ^= UINT64_C(0xa500000000000000); }
            if (walk(cpu, index, va, next()%3, next() & 1, &physical)) { ++failures; }
            else { ++successes; }
        }
        assert(successes && failures);
        printf("{\"cases\":32768,\"successes\":%u,\"faults\":%u,\"digest\":\"%016llx\"}\n",
               successes, failures, (unsigned long long)trace_digest);
    }
    free(cpu);
    return 0;
}
