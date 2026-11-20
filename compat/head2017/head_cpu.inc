// Same raw blocks and two Cortex-A9 cores for an independent Head-only reference.
static float fp16_table[65536];
struct cpu_job {
    const unsigned char *weights, *activation;
    float *result;
    unsigned first, end;
};

static uint16_t load16(const unsigned char *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static void *cpu_worker(void *argument) {
    const struct cpu_job *job = argument;
    float xscale[28];
    int8x16_t x[28][2];
    for (unsigned b=0; b<28; b++) {
        const unsigned char *p = job->activation + b*34;
        xscale[b] = fp16_table[load16(p)];
        x[b][0] = vld1q_s8((const int8_t *)p+2);
        x[b][1] = vld1q_s8((const int8_t *)p+18);
    }
    for (unsigned r=job->first; r<job->end; r++) {
        float sum = 0;
        const unsigned char *row = job->weights + (size_t)r * ROW_BYTES;
        for (unsigned b=0; b<28; b++) {
            const unsigned char *p = row + 34*b;
            int8x16_t a = vld1q_s8((const int8_t *)p+2);
            int8x16_t c = vld1q_s8((const int8_t *)p+18);
            int32x4_t total = vpaddlq_s16(vmull_s8(vget_low_s8(a),vget_low_s8(x[b][0])));
            total = vpadalq_s16(total,vmull_s8(vget_high_s8(a),vget_high_s8(x[b][0])));
            total = vpadalq_s16(total,vmull_s8(vget_low_s8(c),vget_low_s8(x[b][1])));
            total = vpadalq_s16(total,vmull_s8(vget_high_s8(c),vget_high_s8(x[b][1])));
            int32x2_t halves = vadd_s32(vget_low_s32(total),vget_high_s32(total));
            int32_t dot = vget_lane_s32(vpadd_s32(halves,halves),0);
            sum += (float)dot * (fp16_table[load16(p)] * xscale[b]);
        }
        job->result[r] = sum;
    }
    return NULL;
}

static void init_fp16_table(void) {
    for (unsigned i=0; i<65536; i++) {
        unsigned exp = (i>>10)&31, mantissa = i&1023;
        float value = exp ? ldexpf(1024+mantissa,(int)exp-25) : ldexpf(mantissa,-24);
        fp16_table[i] = (i>>15) ? -value : value;
    }
}
