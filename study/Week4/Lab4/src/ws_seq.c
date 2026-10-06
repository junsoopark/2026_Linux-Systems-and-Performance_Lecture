#include "lab.h"

/* [study 추가] Q1.2 검증용: ws_demo와 같은 pointer chase지만 다음 line이 항상 i+1 (순차 접근).
 * usage: ws_seq [min_kb] [max_kb] [accesses_per_size] */

int main(int argc, char **argv) {
    long min_kb = argc > 1 ? atol(argv[1]) : 16, max_kb = argc > 2 ? atol(argv[2]) : 65536;
    long accesses = argc > 3 ? atol(argv[3]) : 20000000;
    printf("pid=%d  size_kb  ns_per_access   (sequential pointer chase, 64-byte stride)\n", (int)getpid());
    for (long kb = min_kb; kb <= max_kb; kb *= 2) {
        uint32_t n = (uint32_t)(kb * 1024 / 64);
        char *buf = aligned_alloc(64, (size_t)n * 64);
        if (!buf) {
            die("alloc");
        }
        for (uint32_t i = 0; i < n; i++) {
            *(uint32_t *)(buf + (size_t)i * 64) = (i + 1) % n; /* KEY next line is always adjacent */
        }
        uint32_t p = 0;
        uint64_t t0 = now_ns();
        for (long i = 0; i < accesses; i++) {
            p = *(uint32_t *)(buf + (size_t)p * 64); /* still a dependent load */
        }
        uint64_t t1 = now_ns();
        printf("%8ld  %8.2f%s\n", kb, (double)(t1 - t0) / accesses, p == 0xFFFFFFFF ? " " : "");
        fflush(stdout);
        free(buf);
    }
    return 0;
}
