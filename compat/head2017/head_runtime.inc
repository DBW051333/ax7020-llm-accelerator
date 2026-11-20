// Included in the v5 runtime translation unit to share the board lock,
// DMA registers, prefix BOs and XRT device.
#include <arm_neon.h>
#define ROWS 151936u
#define ROW_BYTES 952u
#define TILE_ROWS 7168u
#define HEAD_TILES ((ROWS + TILE_ROWS - 1) / TILE_ROWS)
#define HEAD_PREFIX (8u + ROW_BYTES)
#include "head_cpu.inc"

static struct bo head_weight[HEAD_TILES], head_rx[4];
static const void *head_owner;
static unsigned head_resident, head_rows;
static uint64_t head_calls, head_dma_ns, head_total_ns, head_prepare_ns;

int head_enabled(void) {
    const char *value = getenv("BLITE_HEAD");
    return value && !strcmp(value, "1");
}

static void head_cleanup(void) {
    if (head_calls || head_prepare_ns) {
        fprintf(stderr,"HEAD-STATS calls=%llu pl_rows=%u cpu_rows=%u dma_ms=%.3f apply_ms=%.3f preload_ms=%.3f\n",
                (unsigned long long)head_calls,head_rows,ROWS-head_rows,
                head_dma_ns/1e6,head_total_ns/1e6,head_prepare_ns/1e6);
    }
    for (unsigned i=0; i<HEAD_TILES; i++) release(&head_weight[i]);
    for (unsigned i=0; i<4; i++) release(&head_rx[i]);
    head_owner=NULL;
    head_resident=0;
    head_rows=0;
}

static unsigned tile_rows(unsigned tile) {
    unsigned count=ROWS-tile*TILE_ROWS;
    return count<TILE_ROWS ? count : TILE_ROWS;
}

static int prepare_head(const unsigned char *weight) {
    if (head_owner==weight) return 0;
    if (head_owner) {
        fprintf(stderr,"HEAD weight owner changed in the same process\n");
        return -1;
    }
    uint64_t start=now();
    init_fp16_table();
    for (unsigned i=0; i<4; i++) {
        if (allocate(&head_rx[i],TILE_ROWS*8)) goto fail;
    }
    for (unsigned tile=0; tile<HEAD_TILES; tile++) {
        size_t size=(size_t)tile_rows(tile)*ROW_BYTES;
        struct bo *b=&head_weight[tile];
        if (allocate(b,size)) { release(b); break; }
        memcpy(b->map,weight+(size_t)tile*TILE_ROWS*ROW_BYTES,size);
        if (sync_bo(device,b->id,0,size,0)) goto fail;
        ++head_resident;
        head_rows+=tile_rows(tile);
    }
    if (head_resident<4) goto fail;
    head_owner=weight;
    head_prepare_ns=now()-start;
    fprintf(stderr,"HEAD-RESIDENT tiles=%u/%u fpga_rows=%u cpu_rows=%u\n",
            head_resident,HEAD_TILES,head_rows,ROWS-head_rows);
    return 0;
fail:
    fprintf(stderr,"HEAD could not allocate its minimum DMA buffers\n");
    head_cleanup();
    return -1;
}

static void head_tx(unsigned lane, uint32_t addr, unsigned bytes) {
    wr(lane,4,0x7000);
    wr(lane,0,1);
    wr(lane,0x18,addr);
    __sync_synchronize();
    wr(lane,0x28,bytes);
}

static int head_group(unsigned tile, unsigned count, const void *activation, float *out) {
    uint64_t start=now();
    for (unsigned i=0; i<count; i++) {
        unsigned n=tile_rows(tile+i);
        uint32_t header[2]={0x38444851u,n};
        memcpy(tx[i].map,header,8);
        memcpy((char *)tx[i].map+8,activation,ROW_BYTES);
        if (sync_bo(device,tx[i].id,0,HEAD_PREFIX,0)) return -1;
        wr(i,0x34,0x7000);
        wr(i,0x30,1);
        wr(i,0x48,head_rx[i].pa);
        wr(i,0x58,n*8);
    }
    for (unsigned i=0; i<count; i++) head_tx(i,tx[i].pa,HEAD_PREFIX);
    unsigned launched=0, finished=0, all=(1u<<count)-1;
    while (finished!=all) {
        for (unsigned i=0; i<count; i++) {
            unsigned bit=1u<<i;
            if (finished&bit) continue;
            uint32_t m=rd(i,4),s=rd(i,0x34);
            if ((m|s)&0x70) {
                fprintf(stderr,"HEAD DMA error lane=%u tx=%08x rx=%08x\n",i,m,s);
                return -1;
            }
            if (!(launched&bit) && (m&0x1000)) {
                head_tx(i,head_weight[tile+i].pa,tile_rows(tile+i)*ROW_BYTES);
                launched|=bit;
            } else if ((launched&bit) && (m&s&0x1000)) finished|=bit;
        }
        if (now()-start>3000000000ull) { fprintf(stderr,"HEAD DMA timeout\n"); return -1; }
    }
    for (unsigned i=0; i<count; i++) {
        unsigned rows=tile_rows(tile+i);
        if (rd(i,0x58)!=rows*8 || sync_bo(device,head_rx[i].id,1,rows*8,0)) return -1;
        const uint64_t *in=head_rx[i].map;
        float *dst=out+(size_t)(tile+i)*TILE_ROWS;
        __sync_synchronize();
        for (unsigned r=0; r<rows; r++) {
            uint32_t bits=(uint32_t)in[r];
            if (in[r]>>32 || (bits&0x7f800000u)==0x7f800000u) return -1;
            memcpy(dst+r,&bits,4);
        }
    }
    head_dma_ns+=now()-start;
    return 0;
}

int head_apply(const void *weight,const void *activation,float *out) {
    int rc=-1;
    pthread_mutex_lock(&mutex);
    if (initialize() || prepare_head(weight)) goto done;
    uint64_t start=now();
    pthread_t worker;
    struct cpu_job job={weight,activation,out,head_rows,ROWS};
    int has_tail=head_rows<ROWS;
    if (has_tail && pthread_create(&worker,NULL,cpu_worker,&job)) goto done;
    rc=0;
    for (unsigned tile=0; tile<head_resident; tile+=4) {
        unsigned count=head_resident-tile<4?head_resident-tile:4;
        if (head_group(tile,count,activation,out)) { rc=-1; break; }
    }
    if (has_tail && pthread_join(worker,NULL)) rc=-1;
    head_total_ns+=now()-start;
    if (!rc) ++head_calls;
done:
    pthread_mutex_unlock(&mutex);
    return rc;
}
