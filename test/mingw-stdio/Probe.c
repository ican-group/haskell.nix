#define __USE_MINGW_ANSI_STDIO 1
/* Exercise MinGW's ISO formatter even when the target defaults to UCRT. */
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <wchar.h>

#ifndef _WIN32
#error This regression must use the Windows CRT.
#endif

_Static_assert(sizeof(wchar_t) == 2, "Windows wide-character ABI required");

static bool check_capacity(const char *name, size_t capacity,
                           bool expect_success) {
    if (name == NULL) {
        return false;
    }

    enum { BUFFER_CAPACITY = 8, EXPECTED_LENGTH = 5 };
    const wchar_t expected[] = L"ab:cd";
    const wchar_t sentinel = (wchar_t)0x5a5a;
    wchar_t output[BUFFER_CAPACITY];
    wmemset(output, sentinel, BUFFER_CAPACITY);

    int result = swprintf(output, capacity, L"%ls:%ls", L"ab", L"cd");
    bool bounded = true;
    for (size_t i = capacity; i < BUFFER_CAPACITY; ++i) {
        bounded = bounded && output[i] == sentinel;
    }
    bool passed = bounded && (expect_success
        ? result == EXPECTED_LENGTH
          && wmemcmp(output, expected, EXPECTED_LENGTH) == 0
          && output[EXPECTED_LENGTH] == L'\0'
        : result < 0);
    /* Do not require particular truncated contents or termination. */
    printf("%s capacity=%zu result=%d bounded=%d pass=%d\n",
           name, capacity, result, bounded, passed);
    return passed;
}

int main(void) {
    bool exact = check_capacity("exact", 6, true);
    bool spare = check_capacity("spare", 7, true);
    bool small = check_capacity("too-small", 5, false);
    if (!exact || !spare || !small) {
        return 1;
    }
    puts("MINGW_STDIO_EXACT_FIT_PASS");
    return 0;
}
