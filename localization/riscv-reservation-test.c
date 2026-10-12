#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

static _Alignas(64) uint64_t target_word;
static _Alignas(64) atomic_uint phase;
static unsigned iterations = 100;

static int test_single_cpu_shared_mapping(void)
{
    uint64_t *word;
    uint64_t loaded;
    uint64_t replacement = 9;
    unsigned sc_status;

    word = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (word == MAP_FAILED) {
        perror("mmap");
        return -1;
    }
    *word = 7;
    __asm__ volatile("lr.d %0, 0(%1)"
                     : "=&r"(loaded)
                     : "r"(word)
                     : "memory");
    __asm__ volatile("sc.d %0, %2, 0(%1)"
                     : "=&r"(sc_status)
                     : "r"(word), "r"(replacement)
                     : "memory");
    if (munmap(word, 4096) != 0) {
        perror("munmap");
        return -1;
    }
    return sc_status == 0 ? 0 : -1;
}

static void wait_for_phase(unsigned expected)
{
    while (atomic_load_explicit(&phase, memory_order_acquire) != expected) {
        __asm__ volatile("nop");
    }
}

static void *same_value_store(void *opaque)
{
    const uint64_t value = 7;

    for (unsigned i = 0; i < iterations; i++) {
        wait_for_phase(2 * i + 1);
        __asm__ volatile("sd %1, 0(%0)"
                         :
                         : "r"(&target_word), "r"(value)
                         : "memory");
        atomic_store_explicit(&phase, 2 * i + 2, memory_order_release);
    }
    return opaque;
}

int main(int argc, char **argv)
{
    pthread_t worker;
    unsigned unexpected_successes = 0;

    if (argc == 2) {
        iterations = strtoul(argv[1], NULL, 0);
    }
    if (iterations == 0) {
        return 2;
    }

    if (test_single_cpu_shared_mapping() != 0) {
        fputs("single-CPU LR/SC on shared mapping failed\n", stderr);
        return 1;
    }

    atomic_init(&phase, 0);
    if (pthread_create(&worker, NULL, same_value_store, NULL) != 0) {
        perror("pthread_create");
        return 2;
    }

    for (unsigned i = 0; i < iterations; i++) {
        uint64_t loaded;
        uint64_t replacement = 9;
        unsigned sc_status;

        target_word = 7;
        __asm__ volatile("lr.d %0, 0(%1)"
                         : "=&r"(loaded)
                         : "r"(&target_word)
                         : "memory");
        atomic_store_explicit(&phase, 2 * i + 1, memory_order_release);
        wait_for_phase(2 * i + 2);
        __asm__ volatile("sc.d %0, %2, 0(%1)"
                         : "=&r"(sc_status)
                         : "r"(&target_word), "r"(replacement)
                         : "memory");
        unexpected_successes += sc_status == 0;
    }

    pthread_join(worker, NULL);
    printf("iterations=%u unexpected_sc_success=%u\n",
           iterations, unexpected_successes);
    return unexpected_successes != 0;
}
