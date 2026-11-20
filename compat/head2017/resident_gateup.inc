// Same v5 packet bytes, with a persistent DMA BO per layer. It shares the
// lock, device and prefix/RX buffers with the Head and staged Gate/Up paths.
struct resident_layer {
    const void *gate, *up;
    int rows, k;
    size_t gs, us;
    struct bo weights;
};
static struct resident_layer resident_layers[32];
static unsigned resident_count, resident_disabled;
static uint64_t resident_calls, resident_fallback, resident_bytes, resident_prepare_ns;

static void resident_cleanup(void) {
    if (resident_calls || resident_fallback) {
        fprintf(stderr,"RESIDENT-GATEUP calls=%llu fallback=%llu layers=%u weight_MiB=%.3f preload_ms=%.3f\n",
                (unsigned long long)resident_calls,(unsigned long long)resident_fallback,
                resident_count,resident_bytes/1048576.0,resident_prepare_ns/1e6);
    }
    for (unsigned i=0; i<resident_count; i++) release(&resident_layers[i].weights);
}

static struct resident_layer *make_resident(const void *gate, const void *up, int rows,
                                            int k, size_t gs, size_t us) {
    for (unsigned i=0; i<resident_count; i++) {
        struct resident_layer *p=&resident_layers[i];
        if (p->gate==gate && p->up==up && p->rows==rows && p->k==k && p->gs==gs && p->us==us) return p;
    }
    if (resident_count==32 || resident_disabled) return NULL;
    uint64_t start=now();
    int nb=k/32;
    size_t rowbytes=(size_t)nb*48, bytes=(size_t)rows*rowbytes;
    struct resident_layer *p=&resident_layers[resident_count];
    if (allocate(&p->weights,bytes)) {
        release(&p->weights);
        resident_disabled=1;
        fprintf(stderr,"RESIDENT-GATEUP allocation stopped at %u layers; remaining layers use staging\n",resident_count);
        return NULL;
    }
    unsigned char *dst=p->weights.map;
    for (int r=0; r<rows; r++) for (int phase=0; phase<2; phase++) {
        const unsigned char *src=(const unsigned char *)(phase?up:gate)+(size_t)r*(phase?us:gs);
        unsigned char *d=dst+(size_t)r*rowbytes+(size_t)phase*nb*24;
        for (int b=0; b<nb; b++) {
            if (!finite_half(src+b*22)) goto fail;
            memcpy(d+b*24,src+b*22,22);
            d[b*24+22]=d[b*24+23]=0;
        }
    }
    if (sync_bo(device,p->weights.id,0,bytes,0)) goto fail;
    p->gate=gate; p->up=up; p->rows=rows; p->k=k; p->gs=gs; p->us=us;
    resident_count++; resident_bytes+=bytes; misses++;
    uint64_t elapsed=now()-start;
    resident_prepare_ns+=elapsed; pack_ns+=elapsed;
    return p;
fail:
    release(&p->weights);
    return NULL;
}

int gateup_fused(const void *g,const void *u,const void *q8,float *out,int rows,int k,
                 size_t gs,size_t us,const char *name) {
    const char *option=getenv("BLITE_RESIDENT_GATE");
    if (!option || strcmp(option,"1")) return staged_gateup_fused(g,u,q8,out,rows,k,gs,us,name);
    if (!gateup_enabled() || !g || !u || !q8 || !out || rows<4 || rows>LANES*RX_ROWS ||
        k<=0 || k>8192 || k%32 || gs<(size_t)(k/32)*22 || us<(size_t)(k/32)*22) return -1;
    int nb=k/32, rc=-1;
    size_t prefix=8+(size_t)nb*40, rowbytes=(size_t)nb*48;
    for (int b=0; b<nb; b++) if (!finite_half((const unsigned char *)q8+b*34)) return -1;
    if (prefix>TX_BYTES || rowbytes*((rows+3)/4)>=1u<<23) return -1;
    pthread_mutex_lock(&mutex);
    uint64_t start=now();
    if (initialize()) goto done;
    struct resident_layer *layer=make_resident(g,u,rows,k,gs,us);
    if (!layer) {
        resident_fallback++;
        pthread_mutex_unlock(&mutex);
        return staged_gateup_fused(g,u,q8,out,rows,k,gs,us,name);
    }
    unsigned first[LANES], count[LANES], next=0;
    for (unsigned i=0; i<LANES; i++) {
        first[i]=next;
        count[i]=rows/LANES+(i<(unsigned)(rows%LANES));
        next+=count[i];
        unsigned char *p=tx[i].map;
        uint64_t header=0x1558ull|((uint64_t)count[i]<<16)|((uint64_t)nb<<32);
        memcpy(p,&header,8);
        for (int b=0; b<nb; b++) {
            memset(p+8+b*40,0,40);
            memcpy(p+8+b*40,(const unsigned char *)q8+b*34,34);
        }
        if (sync_bo(device,tx[i].id,0,prefix,0)) goto done;
        wr(i,0x34,0x7000); wr(i,0x30,1); wr(i,0x48,rx[i].pa); wr(i,0x58,count[i]*8);
    }
    uint64_t t=now();
    for (unsigned i=0; i<LANES; i++) head_tx(i,tx[i].pa,prefix);
    unsigned launched=0, finished=0, all=(1u<<LANES)-1;
    while (finished!=all) {
        for (unsigned i=0; i<LANES; i++) {
            unsigned bit=1u<<i;
            if (finished&bit) continue;
            uint32_t m=rd(i,4),s=rd(i,0x34);
            if ((m|s)&0x70) {
                fprintf(stderr,"RESIDENT-GATEUP DMA error %s lane=%u tx=%08x rx=%08x\n",name,i,m,s);
                goto done;
            }
            if (!(launched&bit) && (m&0x1000)) {
                head_tx(i,layer->weights.pa+first[i]*rowbytes,count[i]*rowbytes);
                launched|=bit;
            } else if ((launched&bit) && (m&s&0x1000)) finished|=bit;
        }
        if (now()-t>2000000000ull) { fprintf(stderr,"RESIDENT-GATEUP DMA timeout %s\n",name); goto done; }
    }
    dma_ns+=now()-t;
    for (unsigned i=0; i<LANES; i++) {
        if (rd(i,0x58)!=count[i]*8 || sync_bo(device,rx[i].id,1,count[i]*8,0)) goto done;
        const uint64_t *data=rx[i].map;
        __sync_synchronize();
        for (unsigned r=0; r<count[i]; r++) {
            uint32_t bits=(uint32_t)data[r];
            if (data[r]>>32 || (bits&0x7f800000u)==0x7f800000u) goto done;
            memcpy(out+first[i]+r,&bits,4);
        }
    }
    resident_calls++; calls++; macs+=(uint64_t)2*rows*k; backend_ns+=now()-start;
    rc=0;
done:
    pthread_mutex_unlock(&mutex);
    return rc;
}
