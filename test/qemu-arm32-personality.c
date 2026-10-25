/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group */

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/personality.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

static void require(int condition, const char *message)
{
    if (!condition) {
        (void)fprintf(stderr, "personality regression: %s\n", message);
        exit(EXIT_FAILURE);
    }
}

static uint32_t query(void)
{
    int value = personality(UINT32_MAX);
    require(value != -1, "query failed");
    return (uint32_t)value;
}

static void change(uint32_t before, uint32_t after)
{
    require((uint32_t)personality(after) == before, "setter lost previous value");
    require(query() == after, "query lost domain or upper flags");
}

static void *thread_personality(void *opaque)
{
    const uint32_t *inherited = opaque;
    require(inherited != NULL, "missing thread argument");
    require(query() == *inherited, "thread did not inherit personality");
    change(*inherited, *inherited ^ UNAME26);
    return NULL;
}

int main(void)
{
    uint32_t initial = query();
    uint32_t flags = initial ^ UNAME26;
    uint32_t linux_domain = (initial & ~(uint32_t)PER_MASK) | PER_LINUX;
    struct utsname name;
    pthread_t thread;
    pid_t child;
    int status;

    /* Bionic makes the first PER_LINUX32 call before main. */
    require((initial & PER_MASK) == PER_LINUX32, "Bionic startup domain lost");
    change(initial, flags);
    require(uname(&name) == 0, "uname failed");
    require(!(flags & UNAME26) || strncmp(name.release, "2.6.", 4) == 0,
            "UNAME26 was not applied by the host kernel");
    change(flags, initial);

    require(pthread_create(&thread, NULL, thread_personality, &initial) == 0,
            "pthread_create failed");
    require(pthread_join(thread, NULL) == 0, "pthread_join failed");
    require(query() == initial, "thread changed parent personality");

    child = fork();
    require(child >= 0, "fork failed");
    if (child == 0) {
        require(query() == initial, "child did not inherit personality");
        change(initial, linux_domain);
        _exit(EXIT_SUCCESS);
    }
    require(waitpid(child, &status, 0) == child, "waitpid failed");
    require(WIFEXITED(status) && WEXITSTATUS(status) == EXIT_SUCCESS,
            "child personality checks failed");
    require(query() == initial, "child changed parent personality");

    change(initial, linux_domain);
    change(linux_domain, initial);
    require(puts("ARM32_PERSONALITY_PASS") >= 0, "writing result failed");
    return EXIT_SUCCESS;
}
