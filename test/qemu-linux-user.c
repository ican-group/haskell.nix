/*
 * Copyright 2026 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group.
 * SPDX-License-Identifier: Apache-2.0
 *
 * AArch64 Linux guest for QEMU's code-page unprotect and fatal-signal paths.
 * Run "smc" for a writable code page; "readonly" and "unmapped" must fault.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if !defined(__aarch64__)
#error This guest fixture requires AArch64.
#endif

#define WRITERS 4
#define ROUNDS 256

struct writer {
    pthread_barrier_t *barrier;
    volatile uint32_t *word;
};

static void *write_code_page(void *argument)
{
    struct writer *writer = argument;
    for (uint32_t round = 0; round < ROUNDS; ++round) {
        pthread_barrier_wait(writer->barrier);
        *writer->word = round;
        pthread_barrier_wait(writer->barrier);
    }
    return NULL;
}

/* Concurrent stores to separate words in a translated code page must all
 * succeed, including when another thread has already restored write access. */
static int concurrent_writes(void *page, int (*entry)(void))
{
    pthread_barrier_t barrier;
    pthread_t threads[WRITERS];
    struct writer writers[WRITERS];
    if (pthread_barrier_init(&barrier, NULL, WRITERS + 1) != 0) return 2;
    for (size_t index = 0; index < WRITERS; ++index) {
        writers[index].barrier = &barrier;
        writers[index].word = (uint32_t *)((char *)page + 1024) + index;
        if (pthread_create(&threads[index], NULL, write_code_page, &writers[index]) != 0) {
            return 2;
        }
    }
    int result = 0;
    for (size_t round = 0; round < ROUNDS; ++round) {
        /* The preceding writes invalidate this translation. Executing it
         * again makes QEMU protect the page before the next group of stores. */
        if (entry() != 1) result = 4;
        pthread_barrier_wait(&barrier);
        pthread_barrier_wait(&barrier);
    }
    for (size_t index = 0; index < WRITERS; ++index) {
        if (pthread_join(threads[index], NULL) != 0) result = 2;
        if (*writers[index].word != ROUNDS - 1) result = 5;
    }
    pthread_barrier_destroy(&barrier);
    printf("CONCURRENT_WRITERS=%d ROUNDS=%d RESULT=%d\n", WRITERS, ROUNDS, result);
    return result;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "smc";
    const uint32_t first[] = { UINT32_C(0x52800020), UINT32_C(0xd65f03c0) };
    const uint32_t second[] = { UINT32_C(0x52800040), UINT32_C(0xd65f03c0) };
    long page_size = sysconf(_SC_PAGESIZE);
    int (*entry)(void);
    void *page;

    if (page_size <= 0) return 2;
    page = mmap(NULL, (size_t)page_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED) { perror("mmap"); return 2; }
    printf("MODE=%s PAGE=%p PAGE_SIZE=%ld\n", mode, page, page_size);
    fflush(stdout);

    if (strcmp(mode, "readonly") == 0) {
        if (mprotect(page, (size_t)page_size, PROT_READ) != 0) { perror("mprotect"); return 2; }
        /* This deliberate write must produce a real protection fault. */
        memcpy(page, first, sizeof(first));
        return 3;
    }
    if (strcmp(mode, "unmapped") == 0) {
        if (munmap(page, (size_t)page_size) != 0) { perror("munmap"); return 2; }
        /* This deliberate write must produce a real missing-mapping fault. */
        memcpy(page, first, sizeof(first));
        return 3;
    }
    if (strcmp(mode, "smc") != 0 && strcmp(mode, "concurrent") != 0) return 2;

    memcpy(page, first, sizeof(first));
    __builtin___clear_cache(page, (char *)page + sizeof(first));
    /* Linux executable mappings use the same representation for code pointers. */
    _Static_assert(sizeof(entry) == sizeof(page), "code pointer size");
    memcpy(&entry, &page, sizeof(entry));
    int before = entry();
    printf("BEFORE=%d\n", before);
    fflush(stdout);
    if (before != 1) return 4;

    if (strcmp(mode, "concurrent") == 0) {
        int result = concurrent_writes(page, entry);
        if (munmap(page, (size_t)page_size) != 0) return 2;
        return result;
    }

    /* QEMU has translated this page and must unprotect it for this write. */
    memcpy(page, second, sizeof(second));
    __builtin___clear_cache(page, (char *)page + sizeof(second));
    int after = entry();
    printf("AFTER=%d\n", after);
    if (munmap(page, (size_t)page_size) != 0) { perror("munmap"); return 2; }
    return after == 2 ? 0 : 5;
}
