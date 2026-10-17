/* Android device regression test for the LD_PRELOAD scheduling policy.
 * Run with the rebuilt libsigfix.so in LD_PRELOAD; repeat with
 * VMHOST_PIN_MODE=legacy and VMHOST_PIN_CPUS=0.
 */
#define _GNU_SOURCE
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake = PTHREAD_COND_INITIALIZER;
static int done;

static void *worker(void *unused) {
    (void)unused;
    pthread_mutex_lock(&lock);
    while (!done) pthread_cond_wait(&wake, &lock);
    pthread_mutex_unlock(&lock);
    return NULL;
}

int main(void) {
    cpu_set_t initial, fast;
    assert(sched_getaffinity(0, sizeof(initial), &initial) == 0);
    CPU_ZERO(&fast);
    long freq[CPU_SETSIZE] = {0}, best = 0;
    for (int i = 0; i < CPU_SETSIZE; ++i) {
        if (!CPU_ISSET(i, &initial)) continue;
        char path[128];
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
        FILE *fp = fopen(path, "r");
        if (fp) {
            if (fscanf(fp, "%ld", &freq[i]) == 1 && freq[i] > best) best = freq[i];
            fclose(fp);
        }
    }
    assert(best > 0);
    for (int i = 0; i < CPU_SETSIZE; ++i) {
        if (freq[i] == best && CPU_ISSET(i, &initial)) CPU_SET(i, &fast);
    }
    const char *mask = getenv("VMHOST_PIN_CPUS");
    const char *mode = getenv("VMHOST_PIN_MODE");
    const int balanced = !mask && (!mode || strcmp(mode, "legacy") != 0);
    const char *names[] = {"CPU 0/TCG", "CPU 1/TCG", "IO worker", "ALL CPUs/TCG"};
    pthread_t threads[4];
    for (int i = 0; i < 4; ++i) {
        assert(pthread_create(&threads[i], NULL, worker, NULL) == 0);
        assert(pthread_setname_np(threads[i], names[i]) == 0);
        cpu_set_t actual;
        assert(sched_getaffinity(pthread_gettid_np(threads[i]), sizeof(actual), &actual) == 0);
        const cpu_set_t *expected = balanced && (i == 0 || i == 3) ? &fast : &initial;
        assert(CPU_EQUAL(&actual, expected));
        printf("%s: %d allowed cores OK\n", names[i], CPU_COUNT(&actual));
    }
    cpu_set_t after;
    assert(sched_getaffinity(0, sizeof(after), &after) == 0);
    assert(CPU_EQUAL(&initial, &after));
    pthread_mutex_lock(&lock);
    done = 1;
    pthread_cond_broadcast(&wake);
    pthread_mutex_unlock(&lock);
    for (int i = 0; i < 4; ++i) assert(pthread_join(threads[i], NULL) == 0);
    puts("affinity policy: PASS");
    return 0;
}
