"""Generate opt-in diagnostics from the immutable, already patched upstream tree."""
from pathlib import Path

root = Path(__file__).resolve().parents[3]
src = root / 'build/upstream/llama.cpp-dafae66cc242eb766797194d3c85c5e502625623'
out = root / 'build/logits-diagnosis2017/source'
out.mkdir(parents=True, exist_ok=True)

main = (src / 'examples/main/main.cpp').read_text(encoding='utf8')
needle = '            const llama_token id = common_sampler_sample(smpl, ctx, -1);'
assert main.count(needle) == 1
replacement = r'''            // Diagnostic only: preserve raw logits before the sampler touches them.
            static FILE * diag_logits = nullptr, * diag_tokens = nullptr, * diag_forced = nullptr;
            static bool diag_initialized = false;
            if (!diag_initialized) {
                diag_initialized = true;
                const char * prefix = getenv("BLITE_DIAG_PREFIX");
                if (prefix) {
                    diag_logits = fopen((std::string(prefix)+".logits").c_str(), "wb");
                    diag_tokens = fopen((std::string(prefix)+".tokens").c_str(), "w");
                    if (!diag_logits || !diag_tokens) GGML_ABORT("diagnostic output open failed");
                }
                const char * force = getenv("BLITE_DIAG_FORCE");
                if (force) {
                    diag_forced = fopen(force,"r");
                    if (!diag_forced) GGML_ABORT("forced token input open failed");
                }
            }
            if (diag_logits) {
                uint32_t size = llama_n_vocab(model);
                if (fwrite(&size,4,1,diag_logits)!=1 ||
                    fwrite(llama_get_logits_ith(ctx,-1),4,size,diag_logits)!=size)
                    GGML_ABORT("logits write failed");
                fflush(diag_logits);
            }
            llama_token id = common_sampler_sample(smpl, ctx, -1);
            const llama_token sampled = id;
            if (diag_forced && fscanf(diag_forced,"%d",&id)!=1)
                GGML_ABORT("forced token sequence exhausted");
            if (diag_tokens) {
                fprintf(diag_tokens,"%d %d\n",sampled,id);
                fflush(diag_tokens);
            }'''
(out / 'main.cpp').write_text(main.replace(needle,replacement),encoding='utf8')

cpu = (src / 'ggml/src/ggml-cpu/ggml-cpu.c').read_text(encoding='utf8')
helper = r'''
#ifdef GGML_USE_BLITE
// One record per eligible Q4 matvec; both paths use the same quantized input format.
static void blite_diag_trace(const struct ggml_tensor *w, const struct ggml_tensor *x,
                            struct ggml_tensor *y, const void *q8) {
    const char *path = getenv("BLITE_DIAG_TRACE");
    const char *substitute = getenv("BLITE_DIAG_USE_REF");
    if (!path && !substitute) return;
    int rows=(int)w->ne[1], k=(int)w->ne[0];
    float *ref=malloc(rows*sizeof(float));
    if (!ref) GGML_ABORT("diagnostic allocation failed");
    for(int r=0;r<rows;r++) type_traits_cpu[w->type].vec_dot(k,&ref[r],0,
        (const char*)w->data+r*w->nb[1],0,q8,0,1);
    if(path) {
        FILE *f=fopen(path,"ab");
        uint32_t h[4]={(uint32_t)strlen(w->name),(uint32_t)k,(uint32_t)rows,
                      (uint32_t)ggml_row_size(GGML_TYPE_Q8_K,k)};
        if(!f || x->type!=GGML_TYPE_F32) GGML_ABORT("diagnostic trace open/type failed");
        if(fwrite(h,4,4,f)!=4 || fwrite(w->name,1,h[0],f)!=h[0] ||
           fwrite(x->data,4,k,f)!=(size_t)k || fwrite(q8,1,h[3],f)!=h[3] ||
           fwrite(y->data,4,rows,f)!=(size_t)rows || fwrite(ref,4,rows,f)!=(size_t)rows)
            GGML_ABORT("diagnostic trace write failed");
        fclose(f);
    }
    // Explicit causal experiment, never a production fallback or an acceptance pass.
    if(substitute && !strcmp(substitute,"1")) memcpy(y->data,ref,rows*sizeof(float));
    free(ref);
}
#endif

'''
needle='static void ggml_compute_forward_mul_mat(\n'
assert cpu.count(needle)==1
cpu=cpu.replace(needle,helper+needle)
needle='        ggml_barrier(params->threadpool);\n        if (profile_matvec && ith == 0) blite_profile_record'
assert cpu.count(needle)==1
cpu=cpu.replace(needle,'''        ggml_barrier(params->threadpool);
        if (ith == 0) blite_diag_trace(src0,src1,dst,
            src1->type==vec_dot_type ? src1->data : params->wdata);
        ggml_barrier(params->threadpool);
        if (profile_matvec && ith == 0) blite_profile_record''')
needle='#ifdef GGML_USE_BLITE\n    if (profile_matvec) {'
assert cpu.count(needle)==1
cpu=cpu.replace(needle,'''#ifdef GGML_USE_BLITE
    if(ne11==1 && ne12==1 && ne13==1 && ne02==1 && ne03==1 &&
       src0->type==GGML_TYPE_Q4_K && blite_supported((int)ne01,(int)ne00) &&
       (getenv("BLITE_DIAG_TRACE") || getenv("BLITE_DIAG_USE_REF"))) {
        ggml_barrier(params->threadpool);
        if(ith==0) blite_diag_trace(src0,src1,dst,
            src1->type==vec_dot_type ? src1->data : params->wdata);
        ggml_barrier(params->threadpool);
    }
    if (profile_matvec) {''')
(out / 'ggml-cpu.c').write_text(cpu,encoding='utf8')
print(out)
