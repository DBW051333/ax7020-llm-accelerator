#include "para_mac.h"
#include "ggml-cpu.h"
#define GGML_COMMON_DECL_C
#include "ggml-common.h"
#include <arm_neon.h>

enum { PARA_ROWS=896, PARA_BLOCKS=19, PARA_WIDTH=4864, PARA_GROUPS=12,
       PARA_LANE_ROWS=PARA_ROWS/LANES, PARA_TX=PARA_LANE_ROWS*PARA_BLOCKS*136,
       PARA_RX=PARA_LANE_ROWS*PARA_BLOCKS*8 };

struct para_scale { float d, dmin; uint8_t mins[8]; };
struct para_group {
    const block_q4_K *owner;
    struct bo weights;
    struct para_scale *scale;
};
static struct para_group para_groups[PARA_GROUPS];
static struct bo para_rx[LANES];
static unsigned para_count, para_calls, para_fallbacks, para_differences, para_values;
static uint64_t para_preload, para_dma, para_reduce;

int para_mac_enabled(void) {
    const char *mode=getenv("BLITE_PARA_MAC");
    return mode && !strcmp(mode,"1");
}

static void para_cleanup(void) {
    if (para_calls || para_fallbacks)
        fprintf(stderr,"PARA-MAC calls=%u fallback=%u groups=%u preload_ms=%.3f dma_ms=%.3f reduce_ms=%.3f values=%u differences=%u\n",
                para_calls,para_fallbacks,para_count,para_preload/1e6,para_dma/1e6,para_reduce/1e6,
                para_values,para_differences);
    for (unsigned i=0;i<para_count;++i) {
        release(&para_groups[i].weights);
        free(para_groups[i].scale);
    }
    for (unsigned i=0;i<LANES;++i) release(&para_rx[i]);
}

static struct para_group *para_cache(const block_q4_K *weight) {
    for (unsigned i=0;i<para_count;++i)
        if (para_groups[i].owner==weight) return &para_groups[i];
    if (para_count==PARA_GROUPS) return NULL;
    const uint64_t start=now();
    struct para_group *group=&para_groups[para_count];
    if (allocate(&group->weights,LANES*PARA_TX)) {
        release(&group->weights);
        return NULL;
    }
    group->scale=malloc(PARA_ROWS*PARA_BLOCKS*sizeof(*group->scale));
    if (!group->scale) { release(&group->weights); return NULL; }
    uint8_t *packet=group->weights.map;
    for (unsigned i=0;i<PARA_ROWS*PARA_BLOCKS;++i,packet+=136) {
        const block_q4_K *b=weight+i;
        struct para_scale *s=group->scale+i;
        s->d=ggml_fp16_to_fp32(b->d);
        s->dmin=ggml_fp16_to_fp32(b->dmin);
        for (unsigned j=0;j<4;++j) {
            packet[j]=b->scales[j]&63;
            packet[j+4]=(b->scales[j+8]&15)|((b->scales[j]>>6)<<4);
            s->mins[j]=b->scales[j+4]&63;
            s->mins[j+4]=(b->scales[j+8]>>4)|((b->scales[j+4]>>6)<<4);
            const uint8x16_t a=vld1q_u8(b->qs+32*j);
            const uint8x16_t z=vld1q_u8(b->qs+32*j+16);
            const uint8x16x2_t split=vuzpq_u8(a,z);
            const uint8x16_t low=vorrq_u8(vandq_u8(split.val[0],vdupq_n_u8(15)),vshlq_n_u8(split.val[1],4));
            const uint8x16_t high=vorrq_u8(vshrq_n_u8(split.val[0],4),vandq_u8(split.val[1],vdupq_n_u8(240)));
            vst1q_u8(packet+8+32*j,low);
            vst1q_u8(packet+24+32*j,high);
        }
    }
    if (sync_bo(device,group->weights.id,0,LANES*PARA_TX,0)) {
        release(&group->weights);
        free(group->scale);
        return NULL;
    }
    group->owner=weight;
    ++para_count;
    para_preload+=now()-start;
    return group;
}

static int para_stream(const struct bo *weights,const block_q8_K *act) {
    const unsigned prefix=8+PARA_WIDTH;
    const uint64_t magic=0x3143414d3451ull, start=now();
    for (unsigned i=0;i<LANES;++i) {
        uint8_t *dst=tx[i].map;
        memcpy(dst,&magic,8);
        for (unsigned b=0;b<PARA_BLOCKS;++b) memcpy(dst+8+b*256,act[b].qs,256);
        if (sync_bo(device,tx[i].id,0,prefix,0)) return -1;
        wr(i,0x34,0x7000); wr(i,0x30,1); wr(i,0x48,para_rx[i].pa); wr(i,0x58,PARA_RX);
    }
    for (unsigned i=0;i<LANES;++i) head_tx(i,tx[i].pa,prefix);
    unsigned launched=0, finished=0;
    while (finished!=(1u<<LANES)-1) {
        for (unsigned i=0;i<LANES;++i) {
            const unsigned bit=1u<<i;
            if (finished&bit) continue;
            const unsigned m=rd(i,4), s=rd(i,0x34);
            if ((m|s)&0x70) return -1;
            if (!(launched&bit) && (m&0x1000)) {
                head_tx(i,weights->pa+i*PARA_TX,PARA_TX);
                launched|=bit;
            } else if ((launched&bit) && (m&s&0x1000)) finished|=bit;
        }
        if (now()-start>2000000000ull) return -1;
    }
    for (unsigned i=0;i<LANES;++i)
        if (rd(i,0x58)!=PARA_RX || sync_bo(device,para_rx[i].id,1,PARA_RX,0)) return -1;
    return 0;
}

// Preserve the A9 Q4_K reference's per-block scale, correction and sum order.
__attribute__((optimize("no-associative-math")))
static float para_row(const int32_t *result,const struct para_scale *scale,
                      const block_q8_K *act,const int16x8_t *xsum) {
    float sum=0;
    for (unsigned b=0;b<PARA_BLOCKS;++b) {
        const int16x8_t mins=vreinterpretq_s16_u16(vmovl_u8(vld1_u8(scale[b].mins)));
        const int32x4_t products=vmlal_s16(vmull_s16(vget_low_s16(xsum[b]),vget_low_s16(mins)),
                                         vget_high_s16(xsum[b]),vget_high_s16(mins));
        const int32x2_t pair=vadd_s32(vget_low_s32(products),vget_high_s32(products));
        const int correction=vget_lane_s32(vpadd_s32(pair,pair),0);
        const float d=act[b].d*scale[b].d;
        const float offset=(scale[b].dmin*correction)*act[b].d;
        const float block=d*result[2*b]-offset;
        sum+=block;
    }
    return sum;
}

int para_mac_run(const void *weight,const void *activation,float *out) {
    const block_q8_K *act=activation;
    int rc=-1;
    pthread_mutex_lock(&mutex);
    if (initialize()) goto done;
    struct para_group *group=para_cache(weight);
    if (!group) { rc=1; goto done; }
    for (unsigned i=0;i<LANES;++i)
        if (!para_rx[i].allocated && allocate_flags(&para_rx[i],PARA_RX,1u<<24)) {
            release(&para_rx[i]);
            rc=1;
            goto done;
        }
    const uint64_t start=now();
    if (para_stream(&group->weights,act)) goto done;
    const uint64_t reduce=now();
    para_dma+=reduce-start;
    int16x8_t xsum[PARA_BLOCKS];
    for (unsigned b=0;b<PARA_BLOCKS;++b)
        xsum[b]=vcombine_s16(vpadd_s16(vld1_s16(act[b].bsums),vld1_s16(act[b].bsums+4)),
                            vpadd_s16(vld1_s16(act[b].bsums+8),vld1_s16(act[b].bsums+12)));
    for (unsigned i=0;i<LANES;++i)
        for (unsigned r=0;r<PARA_LANE_ROWS;++r) {
            unsigned row=i*PARA_LANE_ROWS+r;
            const int32_t *result=para_rx[i].map;
            out[row]=para_row(result+r*PARA_BLOCKS*2,group->scale+row*PARA_BLOCKS,act,xsum);
        }
    para_reduce+=now()-reduce;
    const char *verify=getenv("BLITE_PARA_VERIFY");
    if (verify && !strcmp(verify,"1")) {
        const block_q4_K *source=weight;
        const struct ggml_type_traits_cpu *type=ggml_get_type_traits_cpu(GGML_TYPE_Q4_K);
        for (unsigned r=0;r<PARA_ROWS;++r) {
            float reference;
            type->vec_dot(PARA_WIDTH,&reference,0,source+r*PARA_BLOCKS,0,act,0,1);
            if (memcmp(&reference,out+r,sizeof(reference))) {
                if (!para_differences) fprintf(stderr,"PARA-FIRST row=%u ref=%a result=%a\n",r,reference,out[r]);
                ++para_differences;
            }
            ++para_values;
        }
    }
    ++para_calls;
    rc=0;
done:
    if (rc>0) ++para_fallbacks;
    pthread_mutex_unlock(&mutex);
    return rc;
}
