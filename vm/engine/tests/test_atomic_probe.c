/* Verify the native operations required by CONFIG_ATOMIC64/128 on Android. */
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

static uint64_t counter64;
static unsigned __int128 counter128 __attribute__((aligned(16)));
#ifndef TEST_ITERATIONS
#define TEST_ITERATIONS 100000
#endif
enum { THREADS = 4, ITERATIONS = TEST_ITERATIONS };

static void *increment(void *unused)
{
    (void)unused;
    for (unsigned i = 0; i < ITERATIONS; ++i) {
        __atomic_fetch_add(&counter64, 1, __ATOMIC_SEQ_CST);
        unsigned __int128 old = __atomic_load_n(&counter128, __ATOMIC_RELAXED);
        while (!__atomic_compare_exchange_n(&counter128, &old, old + 1, 0,
                                           __ATOMIC_SEQ_CST, __ATOMIC_RELAXED)) {}
    }
    return NULL;
}

int main(void)
{
    assert(__atomic_always_lock_free(sizeof(counter64), &counter64));
    assert(__atomic_always_lock_free(sizeof(counter128), &counter128));
    pthread_t threads[THREADS];
    for (unsigned i = 0; i < THREADS; ++i)
        assert(pthread_create(&threads[i], NULL, increment, NULL) == 0);
    for (unsigned i = 0; i < THREADS; ++i)
        assert(pthread_join(threads[i], NULL) == 0);
    assert(__atomic_load_n(&counter64, __ATOMIC_SEQ_CST) == THREADS * ITERATIONS);
    assert(__atomic_load_n(&counter128, __ATOMIC_SEQ_CST) == THREADS * ITERATIONS);
    const unsigned __int128 wide = ((unsigned __int128)0x123456789abcdef0ULL << 64)
                                   | 0xfedcba9876543210ULL;
    __atomic_store_n(&counter128, wide, __ATOMIC_SEQ_CST);
    assert(__atomic_load_n(&counter128, __ATOMIC_SEQ_CST) == wide);
    puts("PASS: lock-free 64/128-bit atomics, concurrent increments, full-width load/store");
    return 0;
}
