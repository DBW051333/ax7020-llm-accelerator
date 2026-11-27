#ifdef GGML_USE_GATEUP
#include "para_mac.h"

static bool para_shape(const ggml_tensor *w,const ggml_tensor *x) {
    unsigned layer;
    int suffix=0;
    return para_mac_enabled() && x->type==GGML_TYPE_F32 && w->type==GGML_TYPE_Q4_K &&
           ggml_is_contiguous(w) && ggml_is_contiguous(x) &&
           x->ne[0]==4864 && x->ne[1]==1 && x->ne[2]==1 && x->ne[3]==1 &&
           w->ne[0]==4864 && w->ne[1]==896 && w->ne[2]==1 && w->ne[3]==1 &&
           sscanf(w->name,"blk.%u%n",&layer,&suffix)==1 && suffix>0 &&
           !strcmp(w->name+suffix,".ffn_down.weight");
}

static void para_compute(ggml_tensor *dst,const ggml_tensor *x,const ggml_tensor *w,
                         const ggml_tensor *,int ith,int,void *) {
    if (ith!=0) return;
    alignas(16) unsigned char q8[19*292];
    GGML_ASSERT(sizeof(q8)==ggml_row_size(GGML_TYPE_Q8_K,4864));
    ggml_get_type_traits_cpu(GGML_TYPE_Q8_K)->from_float((const float *)x->data,q8,4864);
    float *out=(float *)dst->data;
    const int rc=para_mac_run(w->data,q8,out);
    if (rc<0) GGML_ABORT("Para-MAC DMA failed");
    if (!rc) return;
    const auto dot=ggml_get_type_traits_cpu(GGML_TYPE_Q4_K)->vec_dot;
    for (unsigned r=0;r<896;++r) dot(4864,out+r,0,(const char *)w->data+r*w->nb[1],0,q8,0,1);
}
#endif
