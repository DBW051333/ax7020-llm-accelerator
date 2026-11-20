#define _GNU_SOURCE
#include <arm_neon.h>
#include <dlfcn.h>
#include <pthread.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define ROWS 151936u
#define ROW_BYTES 952u
#define TILE_ROWS 7168u
#define CASES 3
#define LANES 4
#define PREFIX_BYTES (8u + ROW_BYTES)
#define TILE_BYTES (TILE_ROWS * ROW_BYTES)
#define MAGIC 0x38444851u
#define MAX_TILES ((ROWS + TILE_ROWS - 1) / TILE_ROWS)

struct properties { uint32_t handle, flags; uint64_t size, paddr; uint32_t domain; };
struct buffer { unsigned id; unsigned char *data; uint32_t address; size_t bytes; int valid; };
struct lane { volatile uint32_t *regs; struct buffer prefix, rx; };
static struct lane lanes[LANES];
static struct buffer weights[MAX_TILES];
static void *device, *library;
static void (*free_bo)(void *, unsigned), (*close_device)(void *);
static unsigned (*alloc_bo)(void *, size_t, int, unsigned);
static void *(*map_bo)(void *, unsigned, int);
static int (*get_props)(void *, unsigned, struct properties *);
static int (*sync_bo)(void *, unsigned, int, size_t, size_t);

static uint64_t ticks(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static int allocate(struct buffer *b, size_t bytes) {
    struct properties prop;
    b->bytes = bytes;
    b->id = alloc_bo(device, bytes, 3, 0);
    if (b->id >= 0x80000000u) return -1;
    b->valid = 1;
    b->data = map_bo(device, b->id, 1);
    if (b->data == MAP_FAILED || !b->data || get_props(device, b->id, &prop) ||
        !prop.paddr || prop.paddr + bytes > (1ULL << 32) || (prop.paddr & 7)) return -1;
    b->address = (uint32_t)prop.paddr;
    return 0;
}

static void release(struct buffer *b) {
    if (b->data && b->data != MAP_FAILED) munmap(b->data, b->bytes);
    if (b->valid) free_bo(device, b->id);
    memset(b, 0, sizeof(*b));
}

static uint32_t reg_read(unsigned lane, unsigned offset) { return lanes[lane].regs[offset/4]; }
static void reg_write(unsigned lane, unsigned offset, uint32_t value) { lanes[lane].regs[offset/4] = value; }

static int reset(unsigned lane) {
    uint64_t deadline = ticks() + 2000000000ULL;
    reg_write(lane, 0, 4);
    while ((reg_read(lane, 0) | reg_read(lane, 0x30)) & 4)
        if (ticks() > deadline) return -1;
    return 0;
}

static void start_tx(unsigned lane, uint32_t address, unsigned size) {
    reg_write(lane, 4, 0x7000);
    reg_write(lane, 0, 1);
    reg_write(lane, 0x18, address);
    __sync_synchronize();
    reg_write(lane, 0x28, size);
}

static int stage(struct buffer *b, const unsigned char *base, unsigned first, unsigned rows) {
    size_t size = (size_t)rows * ROW_BYTES;
    memcpy(b->data, base + (size_t)first * ROW_BYTES, size);
    return sync_bo(device, b->id, 0, size, 0);
}

static int scan(const unsigned port[], unsigned count, struct buffer *input[],
                const unsigned nr[], const unsigned char *activation, uint64_t *elapsed) {
    uint64_t start = ticks();
    for (unsigned j = 0; j < count; j++) {
        unsigned i = port[j];
        struct lane *l = &lanes[i];
        uint32_t header[2] = { MAGIC, nr[j] };
        memcpy(l->prefix.data, header, sizeof(header));
        memcpy(l->prefix.data + sizeof(header), activation, ROW_BYTES);
        if (sync_bo(device, l->prefix.id, 0, PREFIX_BYTES, 0)) return -1;
        reg_write(i, 0x34, 0x7000);
        reg_write(i, 0x30, 1);
        reg_write(i, 0x48, l->rx.address);
        reg_write(i, 0x58, nr[j] * 8);
    }
    for (unsigned j = 0; j < count; j++) {
        unsigned i = port[j];
        start_tx(i, lanes[i].prefix.address, PREFIX_BYTES);
    }
    unsigned launched = 0, finished = 0;
    unsigned all = (1u << count) - 1;
    while (finished != all) {
        for (unsigned j = 0; j < count; j++) {
            unsigned flag = 1u << j, i = port[j];
            if (finished & flag) continue;
            uint32_t tx = reg_read(i, 4), rx = reg_read(i, 0x34);
            if ((tx | rx) & 0x70) {
                fprintf(stderr, "DMA error HP%u tx=%08x rx=%08x\n", i, tx, rx);
                return -1;
            }
            if (!(launched & flag) && (tx & 0x1000)) {
                start_tx(i, input[j]->address, nr[j] * ROW_BYTES);
                launched |= flag;
            } else if ((launched & flag) && (tx & rx & 0x1000)) finished |= flag;
        }
        if (ticks() - start > 3000000000ULL) {
            fprintf(stderr, "DMA timeout started=0x%x done=0x%x\n", launched, finished);
            for (unsigned j=0; j<count; j++) fprintf(stderr, "HP%u status %x/%x\n", port[j], reg_read(port[j],4), reg_read(port[j],0x34));
            return -1;
        }
    }
    for (unsigned j = 0; j < count; j++) {
        unsigned i = port[j];
        if (reg_read(i, 0x58) != nr[j] * 8 ||
            sync_bo(device, lanes[i].rx.id, 1, nr[j] * 8, 0)) return -1;
    }
    __sync_synchronize();
    *elapsed += ticks() - start;
    return 0;
}

static int read_file(const char *path, void *out, size_t len) {
    FILE *file = fopen(path, "rb");
    if (!file) { perror(path); return -1; }
    int ret = fread(out, 1, len, file) == len && fgetc(file) == EOF ? 0 : -1;
    fclose(file);
    return ret;
}

#include "head_cpu.inc"

static int cpu_bench(const unsigned char *weights, unsigned char activation[CASES][ROW_BYTES], float *expected[CASES]) {
    init_fp16_table();
    float *out = malloc(ROWS * sizeof(float));
    if (!out) return -1;
    int rc = 0;
    for (unsigned c=0; c<CASES; c++) {
        struct cpu_job first = {weights,activation[c],out,0,ROWS/2};
        struct cpu_job second = {weights,activation[c],out,ROWS/2,ROWS};
        pthread_t worker;
        uint64_t start = ticks();
        if (pthread_create(&worker,NULL,cpu_worker,&second)) { rc=-1; break; }
        cpu_worker(&first);
        if (pthread_join(worker,NULL)) { rc=-1; break; }
        double elapsed = (ticks()-start)/1e6;
        double max = 0;
        for (unsigned r=0; r<ROWS; r++) {
            double diff = fabs(out[r]-expected[c][r]);
            if (!isfinite(diff)) { rc=-1; break; }
            if (diff>max) max=diff;
        }
        printf("HEAD-CPU case=%u rows=%u threads=2 ms=%.3f max_abs=%.9g\n", c, ROWS, elapsed, max);
        if (max>5e-5) rc=-1;
    }
    free(out);
    return rc;
}

int main(int argc, char **argv) {
    if (argc != 5) { fprintf(stderr, "usage: %s MODEL GGUF_OFFSET FIXTURE_DIR PORT_MASK_OR_CPU\n", argv[0]); return 2; }
    int result = 1, lock = -1, mem = -1, model = -1;
    unsigned char *mapped = MAP_FAILED;
    struct stat file;
    size_t offset = strtoul(argv[2], NULL, 0);
    unsigned mask = strtoul(argv[4], NULL, 0), port[LANES], np = 0;
    unsigned char activation[CASES][ROW_BYTES];
    float *expected[CASES] = {0};
    float observed_top[CASES] = {-INFINITY,-INFINITY,-INFINITY};
    unsigned observed_argmax[CASES] = {0};
    double se[CASES] = {0}, sr[CASES] = {0}, max_abs[CASES] = {0};
    uint64_t dma[CASES] = {0}, combined[CASES] = {0}, staging = 0;
    float *tail = NULL;
    int cpu = !strcmp(argv[4], "cpu");
    if (!cpu && (mask == 0 || mask > 15)) return 2;
    for (unsigned i=0; i<LANES; i++) if (mask & (1u<<i)) port[np++] = i;
    for (unsigned i=0; i<CASES; i++) {
        char path[1024];
        expected[i] = malloc(ROWS * sizeof(float));
        if (!expected[i]) goto done;
        snprintf(path, sizeof(path), "%s/activation%u.q8", argv[3], i);
        if (read_file(path, activation[i], ROW_BYTES)) goto done;
        snprintf(path, sizeof(path), "%s/expected%u.f32", argv[3], i);
        if (read_file(path, expected[i], ROWS * sizeof(float))) goto done;
    }
    model = open(argv[1], O_RDONLY);
    if (model < 0 || fstat(model, &file) || offset > (size_t)file.st_size ||
        (size_t)file.st_size - offset < ROWS * ROW_BYTES) goto done;
    mapped = mmap(NULL, file.st_size, PROT_READ, MAP_PRIVATE, model, 0);
    if (mapped == MAP_FAILED) goto done;
    const unsigned char *raw = mapped + offset;
    if (cpu) { result = cpu_bench(raw,activation,expected) != 0; goto done; }
    lock = open("/tmp/blite-perf.lock", O_CREAT | O_RDWR, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB)) { fprintf(stderr, "board lock busy\n"); goto done; }
    library = dlopen("/usr/lib/libxrt_core.so.2", RTLD_NOW | RTLD_GLOBAL);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); goto done; }
    void *(*open_device)(unsigned,const char*,int) = dlsym(library,"xclOpen");
    alloc_bo = dlsym(library,"xclAllocBO"); map_bo = dlsym(library,"xclMapBO");
    get_props = dlsym(library,"xclGetBOProperties"); sync_bo = dlsym(library,"xclSyncBO");
    free_bo = dlsym(library,"xclFreeBO"); close_device = dlsym(library,"xclClose");
    if (!open_device || !alloc_bo || !map_bo || !get_props || !sync_bo || !free_bo || !close_device) goto done;
    device = open_device(0,NULL,0);
    mem = open("/dev/mem", O_RDWR | O_SYNC);
    if (!device || mem < 0) goto done;
    for (unsigned j=0; j<np; j++) {
        unsigned i = port[j];
        lanes[i].regs = mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_SHARED,mem,0x40400000UL + i*0x10000UL);
        if (lanes[i].regs == MAP_FAILED || reset(i) || allocate(&lanes[i].prefix,4096) ||
            allocate(&lanes[i].rx,TILE_ROWS*8)) goto done;
    }
    unsigned resident = 0;
    int hybrid = getenv("HEAD_HYBRID") != NULL;
    if (hybrid || getenv("HEAD_TRY_FULL_RESIDENT")) {
        while (resident < MAX_TILES) {
            unsigned first = resident*TILE_ROWS, rows = ROWS-first;
            if (rows > TILE_ROWS) rows = TILE_ROWS;
            if (allocate(&weights[resident], rows*ROW_BYTES)) break;
            resident++;
        }
        if (resident != MAX_TILES) {
            printf("CMA_FULL_RESIDENT_UNAVAILABLE tiles=%u/%u\n", resident, MAX_TILES);
            release(&weights[resident]);
            if (!hybrid) {
                for (unsigned i=0; i<resident; i++) release(&weights[i]);
                resident = 0;
            }
        }
    }
    if (hybrid && resident < np) goto done;
    if (!resident) for (unsigned i=0; i<np; i++) if (allocate(&weights[i],TILE_BYTES)) goto done;
    if (resident) {
        uint64_t start = ticks();
        for (unsigned t=0; t<resident; t++) {
            unsigned rows = ROWS-t*TILE_ROWS;
            if (rows > TILE_ROWS) rows = TILE_ROWS;
            if (stage(&weights[t],raw,t*TILE_ROWS,rows)) goto done;
        }
        staging += ticks()-start;
    }
    unsigned pl_rows = resident && resident < MAX_TILES ? resident*TILE_ROWS : ROWS;
    if (pl_rows < ROWS) {
        tail = malloc(ROWS*sizeof(float));
        if (!tail) goto done;
        init_fp16_table();
    }
    uint64_t total_start = ticks();
    // For a resident scan, complete all tiles of an activation before its
    // next activation. For a bounded window, reuse a staged tile three times.
    unsigned passes = resident ? CASES : 1;
    unsigned limit = resident ? resident : MAX_TILES;
    for (unsigned pass=0; pass<passes; pass++) {
        uint64_t pass_start = ticks();
        pthread_t cpu_thread;
        struct cpu_job job = {raw,activation[pass],tail,pl_rows,ROWS};
        if (tail && pthread_create(&cpu_thread,NULL,cpu_worker,&job)) goto done;
        int failed = 0;
        for (unsigned t=0; t<limit && !failed; t+=np) {
            unsigned count = limit-t < np ? limit-t : np;
            unsigned nr[LANES];
            struct buffer *payload[LANES];
            uint64_t start = ticks();
            for (unsigned j=0; j<count; j++) {
                nr[j] = ROWS-(t+j)*TILE_ROWS;
                if (nr[j] > TILE_ROWS) nr[j] = TILE_ROWS;
                payload[j] = &weights[resident ? t+j : j];
                if (!resident && stage(payload[j],raw,(t+j)*TILE_ROWS,nr[j])) { failed=1; break; }
            }
            if (!resident) staging += ticks()-start;
            for (unsigned c=pass; c<(resident ? pass+1 : CASES) && !failed; c++) {
                if (scan(port,count,payload,nr,activation[c],&dma[c])) { failed=1; break; }
                uint64_t compare_start = ticks();
                for (unsigned j=0; j<count; j++) {
                    const uint64_t *rx = (const uint64_t *)lanes[port[j]].rx.data;
                    unsigned first = (t+j)*TILE_ROWS;
                    for (unsigned r=0; r<nr[j]; r++) {
                        uint32_t bits = (uint32_t)rx[r];
                        float value;
                        memcpy(&value,&bits,4);
                        if (!isfinite(value) || rx[r] >> 32) { failed=1; break; }
                        double ref = expected[c][first+r], e = value-ref;
                        se[c] += e*e; sr[c] += ref*ref;
                        if (fabs(e) > max_abs[c]) max_abs[c] = fabs(e);
                        if (value > observed_top[c]) { observed_top[c] = value; observed_argmax[c] = first+r; }
                    }
                }
                // Hybrid wall time includes comparison while the CPU tail may be working.
                if (!tail) pass_start += ticks()-compare_start;
            }
        }
        if (tail && pthread_join(cpu_thread,NULL)) failed=1;
        if (failed) goto done;
        if (resident) combined[pass] = ticks()-pass_start;
        if (tail) for (unsigned r=pl_rows; r<ROWS; r++) {
            float value = tail[r];
            if (!isfinite(value)) goto done;
            double ref = expected[pass][r], e=value-ref;
            se[pass] += e*e; sr[pass] += ref*ref;
            if (fabs(e)>max_abs[pass]) max_abs[pass]=fabs(e);
            if (value>observed_top[pass]) { observed_top[pass]=value; observed_argmax[pass]=r; }
        }
    }
    printf("HEAD_SWEEP cases=%u pl_rows=%u cpu_rows=%u actual_wall_ms=%.3f\n",
           CASES,pl_rows,ROWS-pl_rows,(ticks()-total_start)/1e6);
    result = 0;
    for (unsigned c=0; c<CASES; c++) {
        unsigned target=0;
        for (unsigned r=1; r<ROWS; r++) if (expected[c][r] > expected[c][target]) target=r;
        double l2=sqrt(se[c]/sr[c]);
        printf("HEAD mask=0x%x case=%u rows=%u resident=%s dma_ms=%.3f GBps=%.4f staging_once_ms=%.3f combined_ms=%.3f relative_L2=%.9g max_abs=%.9g argmax=%u/%u\n",
               mask,c,ROWS,tail?"hybrid":resident?"full":"window",dma[c]/1e6,
               (double)(pl_rows*ROW_BYTES)/dma[c],staging/1e6,combined[c]/1e6,l2,max_abs[c],observed_argmax[c],target);
        if (max_abs[c] > 5e-5 || l2 > 1e-5 || observed_argmax[c] != target) result=1;
    }
    if (!result) puts("HEAD-PASS");
done:
    for (unsigned j=0; j<np; j++) {
        unsigned i = port[j];
        if (lanes[i].regs && lanes[i].regs != MAP_FAILED) {
            if (reset(i)) {
                fprintf(stderr,"HP%u DMA did not reset; reprogram overlay before reuse\n",i);
                result=1;
            }
            munmap((void *)lanes[i].regs,4096);
        }
        release(&lanes[i].prefix); release(&lanes[i].rx);
    }
    for (unsigned i=0; i<MAX_TILES; i++) release(&weights[i]);
    free(tail);
    for (unsigned c=0; c<CASES; c++) free(expected[c]);
    if (device) close_device(device);
    if (library) dlclose(library);
    if (mapped != MAP_FAILED) munmap(mapped,file.st_size);
    if (model >= 0) close(model);
    if (mem >= 0) close(mem);
    if (lock >= 0) close(lock);
    if (result) fprintf(stderr,"HEAD-FAIL\n");
    return result;
}
