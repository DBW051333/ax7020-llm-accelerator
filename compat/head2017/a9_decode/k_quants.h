// Included before the pinned ggml K-quant kernels, on ARMv7 NEON only.
// Gather integer products in 16-bit lanes before widening. Q4 uses at
// most four products of magnitude 15*128 per lane. Centered Q6 uses two
// products of magnitude 32*128 per lane.
static inline int32x4_t a9_dot16(int8x16_t w, int8x16_t x) {
    const int16x8_t products = vmlal_s8(vmull_s8(vget_low_s8(w), vget_low_s8(x)),
                                        vget_high_s8(w), vget_high_s8(x));
    return vpaddlq_s16(products);
}

static inline int32x4_t a9_dot32(int8x16_t w0, int8x16_t w1, const int8_t * x) {
    const int8x16_t x0 = vld1q_s8(x);
    const int8x16_t x1 = vld1q_s8(x + 16);
    int16x8_t products = vmull_s8(vget_low_s8(w0), vget_low_s8(x0));
    products = vmlal_s8(products, vget_high_s8(w0), vget_high_s8(x0));
    products = vmlal_s8(products, vget_low_s8(w1), vget_low_s8(x1));
    products = vmlal_s8(products, vget_high_s8(w1), vget_high_s8(x1));
    return vpaddlq_s16(products);
}

// Match the pinned ARMv7 binary's FP32 evaluation order under -funsafe-math-optimizations.
__attribute__((optimize("no-associative-math")))
static float a9_q4_k(int nb, const block_q4_K * restrict x, const block_q8_K * restrict y) {
    const uint8x16_t mask = vdupq_n_u8(15);
    float sum = 0;
    for (int i = 0; i < nb; ++i) {
        const float d = y[i].d * GGML_FP16_TO_FP32(x[i].d);
        const float dmin = GGML_FP16_TO_FP32(x[i].dmin);
        uint32_t packed[4];
        memcpy(packed, x[i].scales, 12);
        packed[3] = ((packed[2] >> 4) & 0x0f0f0f0f) | (((packed[1] >> 6) & 0x03030303) << 4);
        const uint32_t mins_low = packed[1] & 0x3f3f3f3f;
        packed[1] = (packed[2] & 0x0f0f0f0f) | (((packed[0] >> 6) & 0x03030303) << 4);
        packed[0] &= 0x3f3f3f3f;
        packed[2] = mins_low;
        const uint8_t * scales = (const uint8_t *)packed;

        const int16x8_t xsum = vpaddq_s16(vld1q_s16(y[i].bsums), vld1q_s16(y[i].bsums + 8));
        const int16x8_t mins = vreinterpretq_s16_u16(vmovl_u8(vld1_u8(scales + 8)));
        const int32x4_t correction = vmlal_s16(vmull_s16(vget_low_s16(xsum), vget_low_s16(mins)),
                                                 vget_high_s16(xsum), vget_high_s16(mins));
        const float correction_term = (dmin * vaddvq_s32(correction)) * y[i].d;

        int32x4_t scaled = vdupq_n_s32(0);
        for (int j = 0; j < 4; ++j) {
            const uint8x16_t a = vld1q_u8(x[i].qs + 32*j);
            const uint8x16_t b = vld1q_u8(x[i].qs + 32*j + 16);
            const int8_t * q8 = y[i].qs + 64*j;
            const int32x4_t low = a9_dot32(vreinterpretq_s8_u8(vandq_u8(a, mask)),
                                           vreinterpretq_s8_u8(vandq_u8(b, mask)), q8);
            const int32x4_t high = a9_dot32(vreinterpretq_s8_u8(vshrq_n_u8(a, 4)),
                                            vreinterpretq_s8_u8(vshrq_n_u8(b, 4)), q8 + 32);
            scaled = vmlaq_n_s32(scaled, low, scales[2*j]);
            scaled = vmlaq_n_s32(scaled, high, scales[2*j + 1]);
        }
        const float block = d * vaddvq_s32(scaled) - correction_term;
        sum += block;
    }
    return sum;
}

static inline int32x4_t a9_q5_block(const block_q5_0 * weight, const block_q8_0 * act) {
    uint32_t high_bits;
    memcpy(&high_bits, weight->qh, sizeof(high_bits));
    const uint8x8_t octets = vreinterpret_u8_u32(vdup_n_u32(high_bits));
    const uint8x8_t pattern = vreinterpret_u8_u64(vcreate_u64(UINT64_C(0x8040201008040201)));
    const uint8x16_t high_mask0 = vcombine_u8(vtst_u8(vdup_lane_u8(octets, 0), pattern),
                                              vtst_u8(vdup_lane_u8(octets, 1), pattern));
    const uint8x16_t high_mask1 = vcombine_u8(vtst_u8(vdup_lane_u8(octets, 2), pattern),
                                              vtst_u8(vdup_lane_u8(octets, 3), pattern));
    const uint8x16_t nibbles = vld1q_u8(weight->qs);
    const uint8x16_t bias = vdupq_n_u8(16);
    const int8x16_t low = vreinterpretq_s8_u8(
        vsubq_u8(vandq_u8(nibbles, vdupq_n_u8(15)), vbicq_u8(bias, high_mask0)));
    const int8x16_t high = vreinterpretq_s8_u8(
        vsubq_u8(vshrq_n_u8(nibbles, 4), vbicq_u8(bias, high_mask1)));
    return a9_dot32(low, high, act->qs);
}

// Recover the centered Q6 value before the multiply. This incorporates
// the original -32*bsums correction into the exact integer dot product.
static inline int32x4_t a9_q6_group(uint8x16_t low, uint8x16_t high, const int8_t * x) {
    const uint8x16_t packed = vorrq_u8(low, high);
    const int8x16_t w = vsubq_s8(vreinterpretq_s8_u8(packed), vdupq_n_s8(32));
    return a9_dot16(w, vld1q_s8(x));
}

static float a9_q6_k(int nb, const block_q6_K * restrict x, const block_q8_K * restrict y) {
    const uint8x16_t mask = vdupq_n_u8(15);
    const uint8x16_t hi_mask = vdupq_n_u8(48);
    float sum = 0;
    for (int i = 0; i < nb; ++i) {
        int32x4_t scaled = vdupq_n_s32(0);
        for (int j = 0; j < 2; ++j) {
            const uint8_t * lo = x[i].ql + j*64;
            const uint8_t * hi = x[i].qh + j*32;
            const int8_t * q8 = y[i].qs + j*128;
            const int8_t * scales = x[i].scales + j*8;
            for (int k = 0; k < 2; ++k) {
                const uint8x16_t a = vld1q_u8(lo + 16*k);
                const uint8x16_t b = vld1q_u8(lo + 32 + 16*k);
                const uint8x16_t h = vld1q_u8(hi + 16*k);
                const int8_t * target = q8 + 16*k;
                const int32x4_t d0 = a9_q6_group(vandq_u8(a, mask), vandq_u8(vshlq_n_u8(h, 4), hi_mask), target);
                const int32x4_t d1 = a9_q6_group(vandq_u8(b, mask), vandq_u8(vshlq_n_u8(h, 2), hi_mask), target + 32);
                const int32x4_t d2 = a9_q6_group(vshrq_n_u8(a, 4), vandq_u8(h, hi_mask), target + 64);
                const int32x4_t d3 = a9_q6_group(vshrq_n_u8(b, 4), vshrq_n_u8(vandq_u8(h, vdupq_n_u8(192)), 2), target + 96);
                scaled = vmlaq_n_s32(scaled, d0, scales[k]);
                scaled = vmlaq_n_s32(scaled, d1, scales[2 + k]);
                scaled = vmlaq_n_s32(scaled, d2, scales[4 + k]);
                scaled = vmlaq_n_s32(scaled, d3, scales[6 + k]);
            }
        }
        const float d = GGML_FP16_TO_FP32(x[i].d);
        sum += d * y[i].d * vaddvq_s32(scaled);
    }
    return sum;
}
