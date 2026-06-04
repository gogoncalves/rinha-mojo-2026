#include <stdio.h>
#include <unistd.h>
#include <stddef.h>

void trace_init(void) {
    setvbuf(stderr, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);
}

void trace_msg(const char *s, long n) {
    if (n <= 0) return;
    (void)write(2, s, (size_t)n);
    (void)write(2, "\n", 1);
}
