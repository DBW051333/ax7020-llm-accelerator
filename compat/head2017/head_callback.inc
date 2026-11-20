#ifdef GGML_USE_GATEUP
static void head_compute(struct ggml_tensor *dst,const struct ggml_tensor *x,
                         const struct ggml_tensor *w,const struct ggml_tensor *,
                         int ith,int nth,void *userdata) {
    (void)nth; (void)userdata;
    if (ith!=0) return;
    alignas(16) unsigned char activation[952];
    ggml_get_type_traits_cpu(GGML_TYPE_Q8_0)->from_float((const float *)x->data,activation,896);
    if (head_apply(w->data,activation,(float *)dst->data))
        GGML_ABORT("LM Head accelerator failed; reload the combined overlay before retrying");
}
#endif
