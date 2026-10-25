/*
 * Copyright 2026 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Linux signal probes for native AArch64 and x86_64 through Rosetta.
 * A mapped protection fault must report SEGV_ACCERR. The handler restores
 * permissions so the same write can complete. A blocked fatal self-signal
 * must terminate after sigsuspend unblocks it, as QEMU's fatal-signal path does.
 */
#define _GNU_SOURCE
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/mman.h>
#include <stdint.h>
#include <errno.h>
#include <ucontext.h>


/* Signal handlers need this fixed state to restore the protected mapping. */
static void *fault_page;
static size_t fault_page_size;
static int restore_protection;
static volatile sig_atomic_t fault_count;
static volatile sig_atomic_t fault_code;
static volatile sig_atomic_t fault_error;
static volatile uintptr_t fault_address;
static volatile uintptr_t fault_pc;
static volatile uintptr_t fault_x86err;
static volatile uintptr_t fault_trapno;
static volatile uintptr_t fault_cr2;

static void accerr_handler(int sig, siginfo_t *info, void *context) {
    ucontext_t *uc = context;
    (void)sig;
    fault_count++;
    fault_code = info->si_code;
    fault_address = (uintptr_t)info->si_addr;
#if defined(__x86_64__)
    fault_pc = (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
    fault_x86err = (uintptr_t)uc->uc_mcontext.gregs[REG_ERR];
    fault_trapno = (uintptr_t)uc->uc_mcontext.gregs[REG_TRAPNO];
    fault_cr2 = (uintptr_t)uc->uc_mcontext.gregs[REG_CR2];
#else
    fault_pc = (uintptr_t)uc->uc_mcontext.pc;
    fault_x86err = 0;
    fault_trapno = 0;
    fault_cr2 = fault_address;
#endif
    if (fault_count > 2) _exit(77);
    if (mprotect(fault_page, fault_page_size, restore_protection) != 0) {
        fault_error = errno;
        _exit(78);
    }
}

static int test_accerr(const char *mode) {
    struct sigaction act;
    long page_size = sysconf(_SC_PAGESIZE);
    int protect = PROT_READ;
    if (strncmp(mode, "accerr-rx", 9) == 0) protect = PROT_READ | PROT_EXEC;
    if (strncmp(mode, "accerr-none", 11) == 0) protect = PROT_NONE;
    if (page_size <= 0) return 2;
    fault_page_size = (size_t)page_size;
    restore_protection = PROT_READ | PROT_WRITE | PROT_EXEC;
    fault_page = mmap(NULL, fault_page_size, restore_protection,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (fault_page == MAP_FAILED) { perror("mmap"); return 2; }
    if (strstr(mode, "resident") != NULL) memset(fault_page, 0x42, fault_page_size);
    int mismatch = 0;
    memset(&act, 0, sizeof(act));
    act.sa_sigaction = accerr_handler;
    act.sa_flags = SA_SIGINFO;
    sigemptyset(&act.sa_mask);
    if (sigaction(SIGSEGV, &act, NULL) != 0) { perror("sigaction"); return 2; }
    printf("MAPPING=%p PAGE=%ld PROTECT=%d RESTORE=%d\n", fault_page, page_size, protect, restore_protection);
    fflush(stdout);
    for (int attempt = 1; attempt <= 2; attempt++) {
        if (mprotect(fault_page, fault_page_size, protect) != 0) { perror("mprotect"); return 2; }
        /* Deliberately probe the protected mapping; the handler makes it writable. */
        *(volatile unsigned char *)fault_page = (unsigned char)attempt;
        printf("ATTEMPT=%d COUNT=%d CODE=%d ADDRESS=%p PC=%p ERROR=%d VALUE=%u X86_ERR=%lu WRITE_BIT=%lu TRAPNO=%lu CR2=%p\n", attempt, (int)fault_count, (int)fault_code, (void *)fault_address, (void *)fault_pc, (int)fault_error, (unsigned)*(volatile unsigned char *)fault_page, (unsigned long)fault_x86err, (unsigned long)(fault_x86err & 2U), (unsigned long)fault_trapno, (void *)fault_cr2);
        fflush(stdout);
        if (fault_count != attempt || fault_code != SEGV_ACCERR || fault_address != (uintptr_t)fault_page || fault_error != 0) mismatch = 3;
    }
    if (munmap(fault_page, fault_page_size) != 0) { perror("munmap"); return 2; }
    return mismatch;
}

int main(int argc, char **argv) {
    if (argc > 1 && strncmp(argv[1], "accerr-", 7) == 0) return test_accerr(argv[1]);
    if (argc > 1 && strcmp(argv[1], "pages") == 0) {
        printf("SYSCONF_PAGE=%ld AUXV_PAGE=%lu\n", sysconf(_SC_PAGESIZE), getauxval(AT_PAGESZ));
        return 0;
    }
    struct sigaction act;
    int sig = argc > 2 ? atoi(argv[2]) : SIGSEGV;
    const char *mode = argc > 1 ? argv[1] : "qemu";
    if (strcmp(mode, "qemu") != 0 && strcmp(mode, "blocked") != 0 && strcmp(mode, "unblock-before") != 0) return 2;
    printf("START pid=%ld sig=%d mode=%s\n", (long)getpid(), sig, mode);
    fflush(stdout);
    memset(&act, 0, sizeof(act));
    act.sa_handler = SIG_DFL;
    sigfillset(&act.sa_mask);
    if (sigaction(sig, &act, NULL) != 0) { perror("sigaction"); return 2; }
    if (strcmp(mode, "qemu") != 0 && sigprocmask(SIG_SETMASK, &act.sa_mask, NULL) != 0) { perror("sigprocmask"); return 2; }
    if (strcmp(mode, "unblock-before") == 0) {
        sigset_t one;
        sigemptyset(&one); sigaddset(&one, sig);
        if (sigprocmask(SIG_UNBLOCK, &one, NULL) != 0) { perror("unblock-before"); return 2; }
    }
    if (kill(getpid(), sig) != 0) { perror("kill"); return 2; }
    puts("AFTER_SELF_SIGNAL"); fflush(stdout);
    sigdelset(&act.sa_mask, sig);
    if (sigsuspend(&act.sa_mask) < 0) { perror("sigsuspend"); return 3; }
    return 4;
}
