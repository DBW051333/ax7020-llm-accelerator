#ifdef GGML_USE_GATEUP
// Called only for the explicitly selected Q5_0 single-column FFN graph.
static void gateup_compute(struct ggml_tensor *dst,const struct ggml_tensor *x,
                          const struct ggml_tensor *gate,const struct ggml_tensor *up,
                          int ith,int nth,void *userdata) {
    (void)nth;(void)userdata;
    if(ith!=0)return;
    const int k=(int)x->ne[0],rows=(int)gate->ne[1];
    GGML_ASSERT(x->type==GGML_TYPE_F32 && ggml_is_contiguous(x));
    const auto *q5=ggml_get_type_traits_cpu(GGML_TYPE_Q5_0);
    const auto *q8=ggml_get_type_traits_cpu(GGML_TYPE_Q8_0);
    std::vector<unsigned char> activation(ggml_row_size(GGML_TYPE_Q8_0,k));
    q8->from_float((const float*)x->data,activation.data(),k);
    if(gateup_fused(gate->data,up->data,activation.data(),(float*)dst->data,
                    rows,k,gate->nb[1],up->nb[1],gate->name))
        GGML_ABORT("Gate/Up hardware failure for %s; no CPU fallback",gate->name);
    const char *verify=getenv("BLITE_GATEUP_VERIFY");
    if(verify && !strcmp(verify,"1")) {
        double se=0,sr=0,max_abs=0;
        for(int r=0;r<rows;r++) {
            float g,u;
            q5->vec_dot(k,&g,0,(const char*)gate->data+r*gate->nb[1],0,activation.data(),0,1);
            q5->vec_dot(k,&u,0,(const char*)up->data+r*up->nb[1],0,activation.data(),0,1);
            float reference=(g/(1.0f+expf(-g)))*u;
            double diff=(double)((float*)dst->data)[r]-reference;
            se+=diff*diff;sr+=(double)reference*reference;
            max_abs=std::max(max_abs,fabs(diff));
        }
        double relative=sr>0?sqrt(se/sr):sqrt(se);
        fprintf(stderr,"GATEUP-VERIFY %s relative_L2=%.9g max_abs=%.9g\n",gate->name,relative,max_abs);
        if(!std::isfinite(relative)||relative>1e-4)
            GGML_ABORT("Gate/Up fused numerical verification failed for %s",gate->name);
    }
}

// Format-12 Q4_K Down projection dispatch (full_source stage 1).
static void gateup_down_compute(struct ggml_tensor *dst,const struct ggml_tensor *x,
                                const struct ggml_tensor *w,const struct ggml_tensor *,
                                int ith,int nth,void *userdata) {
    (void)nth;(void)userdata;
    if(ith!=0)return;
    const int k=(int)x->ne[0],rows=(int)dst->ne[1];
    GGML_ASSERT(x->type==GGML_TYPE_F32 && ggml_is_contiguous(x));
    const auto *q8=ggml_get_type_traits_cpu(GGML_TYPE_Q8_0);
    const auto *q4=ggml_get_type_traits_cpu(GGML_TYPE_Q4_K);
    std::vector<unsigned char> activation(ggml_row_size(GGML_TYPE_Q8_0,k));
    q8->from_float((const float*)x->data,activation.data(),k);
    if(gateup_matvec(w->data,activation.data(),(float*)dst->data,
                     rows,k,w->nb[1],w->name))
        GGML_ABORT("Down hardware failure for %s; no CPU fallback",w->name);
    const char *verify=getenv("BLITE_GATEUP_VERIFY");
    if(verify && !strcmp(verify,"1")) {
        double se=0,sr=0,max_abs=0;
        for(int r=0;r<rows;r++) {
            float reference;
            q4->vec_dot(k,&reference,0,(const char*)w->data+r*w->nb[1],0,activation.data(),0,1);
            double diff=(double)((float*)dst->data)[r]-reference;
            se+=diff*diff;sr+=(double)reference*reference;
            max_abs=std::max(max_abs,fabs(diff));
        }
        double relative=sr>0?sqrt(se/sr):sqrt(se);
        fprintf(stderr,"GATEUP-DOWN-VERIFY %s relative_L2=%.9g max_abs=%.9g\n",w->name,relative,max_abs);
        if(!std::isfinite(relative)||relative>1e-4)
            GGML_ABORT("Down numerical verification failed for %s",w->name);
    }
}
#endif
