#define GGML_COMMON_DECL_C
#include "ggml-common.h"
#include "ggml-cpu-quants.h"
#include "ggml-cpu.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { ROWS = 896, BLOCKS = 19, REPEATS = 20, Q5_BLOCKS = 28 };
static uint32_t state = 20771;

static uint32_t next(void) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

static void random_bytes(void * storage, size_t size) {
    uint8_t * bytes = storage;
    for (size_t i = 0; i < size; ++i) bytes[i] = next() & 255;
}

static double ms(void) {
    struct timespec stamp;
    clock_gettime(CLOCK_MONOTONIC, &stamp);
    return stamp.tv_sec * 1000.0 + stamp.tv_nsec / 1000000.0;
}

int main(int argc, char ** argv) {
    if (argc != 2) return 1;
    FILE * out = fopen(argv[1], "wb");
    block_q4_K * q4 = malloc(ROWS * BLOCKS * sizeof(*q4));
    block_q6_K * q6 = malloc(ROWS * BLOCKS * sizeof(*q6));
    block_q5_0 * q5 = malloc(ROWS * Q5_BLOCKS * sizeof(*q5));
    if (!out || !q4 || !q6 || !q5) return 2;

    ggml_cpu_init();
    random_bytes(q4, ROWS * BLOCKS * sizeof(*q4));
    random_bytes(q6, ROWS * BLOCKS * sizeof(*q6));
    for (unsigned i = 0; i < ROWS*BLOCKS; ++i) {
        q4[i].d = 0x2800 + i % 2048;
        q4[i].dmin = 0x2400 + i % 2048;
        q6[i].d = 0xa800 + i % 2048;
    }
    memset(q4[0].qs, 255, sizeof(q4[0].qs));
    memset(q6[0].ql, 0, sizeof(q6[0].ql));
    memset(q6[0].qh, 0, sizeof(q6[0].qh));
    block_q8_K x[BLOCKS];
    for (int i = 0; i < BLOCKS; ++i) {
        for (int j = 0; j < QK_K; ++j) x[i].qs[j] = i ? (int)(next() & 255) - 128 : -128;
        for (int j = 0; j < QK_K/16; ++j) {
            x[i].bsums[j] = 0;
            for (int k = 0; k < 16; ++k) x[i].bsums[j] += x[i].qs[j*16 + k];
        }
        x[i].d = (i - 9.5f) / 1024;
    }

    float values[ROWS];
    double start = ms();
    for (int rep = 0; rep < REPEATS; ++rep)
        for (int row = 0; row < ROWS; ++row)
            ggml_vec_dot_q4_K_q8_K(BLOCKS*QK_K, &values[row], 0, q4+row*BLOCKS, 0, x, 0, 1);
    printf("Q4_K rows=%d mean_ms=%.4f\n", ROWS, (ms()-start)/REPEATS);
    if (fwrite(values, sizeof(float), ROWS, out) != ROWS) return 3;

    start = ms();
    for (int rep = 0; rep < REPEATS; ++rep)
        for (int row = 0; row < ROWS; ++row)
            ggml_vec_dot_q6_K_q8_K(BLOCKS*QK_K, &values[row], 0, q6+row*BLOCKS, 0, x, 0, 1);
    printf("Q6_K rows=%d mean_ms=%.4f\n", ROWS, (ms()-start)/REPEATS);
    if (fwrite(values, sizeof(float), ROWS, out) != ROWS) return 3;

    block_q8_0 x5[Q5_BLOCKS];
    random_bytes(q5, ROWS * Q5_BLOCKS * sizeof(*q5));
    random_bytes(x5, sizeof(x5));
    for (unsigned i = 0; i < ROWS * Q5_BLOCKS; ++i) q5[i].d = 0x2800 + i % 2048;
    for (unsigned i = 0; i < Q5_BLOCKS; ++i) x5[i].d = 0x2400 + i % 2048;
    start = ms();
    for (int rep = 0; rep < REPEATS; ++rep)
        for (int row = 0; row < ROWS; ++row)
            ggml_vec_dot_q5_0_q8_0(Q5_BLOCKS*QK5_0, &values[row], 0, q5+row*Q5_BLOCKS, 0, x5, 0, 1);
    printf("Q5_0 rows=%d mean_ms=%.4f\n", ROWS, (ms()-start)/REPEATS);
    if (fwrite(values, sizeof(float), ROWS, out) != ROWS || fclose(out)) return 3;

    free(q4);
    free(q6);
    free(q5);
    return 0;
}
