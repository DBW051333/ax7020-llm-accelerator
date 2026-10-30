#define _GNU_SOURCE
#include "gateup_runtime.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <pthread.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/file.h>
#include <sys/mman.h>

#define LANES 4
#define TX_BYTES (2u<<20)
#define RX_ROWS 1536
#define CACHE_BYTES (192u<<20)
struct props {uint32_t handle,flags;uint64_t size,paddr;uint32_t domain;};
struct bo {unsigned id;uint32_t pa;void *map;size_t bytes;int allocated;};
struct entry {const void *gate,*up;int rows,k,fmt;size_t gs,us,bytes;unsigned char *data;};
static struct entry cache[32];
static size_t cache_bytes;
static struct bo tx[LANES],rx[LANES];
static volatile uint32_t *regs[LANES];
static void *device,*library;
static unsigned (*alloc_bo)(void*,size_t,int,unsigned);
static void *(*map_bo)(void*,unsigned,int);
static int (*get_props)(void*,unsigned,struct props*),(*sync_bo)(void*,unsigned,int,size_t,size_t);
static void (*free_bo)(void*,unsigned),(*close_device)(void*);
static int initialized,mem_fd=-1,lock_fd=-1,exit_registered;
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static uint64_t calls,misses,macs,dma_ns,backend_ns,pack_ns;
static uint64_t now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000ull+t.tv_nsec;}
static void wr(int i,int off,uint32_t v){regs[i][off/4]=v;}
static uint32_t rd(int i,int off){return regs[i][off/4];}
int gateup_enabled(void){const char *s=getenv("BLITE_GATEUP");return s&&!strcmp(s,"1");}
static void release(struct bo *b){
 if(b->map&&b->map!=MAP_FAILED)munmap(b->map,b->bytes);
 if(b->allocated&&device)free_bo(device,b->id);
 memset(b,0,sizeof(*b));
}
static int allocate(struct bo *b,size_t bytes){
 b->bytes=bytes;b->id=alloc_bo(device,bytes,3,0);
 if(b->id>=0x80000000u)return -1;
 b->allocated=1;b->map=map_bo(device,b->id,1);
 struct props p;
 if(!b->map||b->map==MAP_FAILED||get_props(device,b->id,&p)||p.paddr>UINT32_MAX||(p.paddr&7))return -1;
 b->pa=(uint32_t)p.paddr;return 0;
}
static int reset(void){
 for(int i=0;i<LANES;i++){wr(i,0,4);wr(i,0x30,4);}
 uint64_t end=now()+2000000000ull;
 for(int i=0;i<LANES;i++)while((rd(i,0)|rd(i,0x30))&4)if(now()>end)return -1;
 return 0;
}
static void cleanup(void){
 if(initialized){
  if(reset())fprintf(stderr,"GATEUP shutdown DMA reset failed\n");
  fprintf(stderr,"GATEUP-STATS calls=%llu cache_misses=%llu MACs=%llu dma_ms=%.3f backend_ms=%.3f pack_ms=%.3f cache_MiB=%.3f\n",
   (unsigned long long)calls,(unsigned long long)misses,(unsigned long long)macs,
   dma_ns/1e6,backend_ns/1e6,pack_ns/1e6,cache_bytes/1048576.0);
 }
 for(int j=0;j<32;j++){free(cache[j].data);memset(&cache[j],0,sizeof(cache[j]));}
 cache_bytes=0;
 for(int i=0;i<LANES;i++){
  release(&tx[i]);release(&rx[i]);
  if(regs[i]&&regs[i]!=MAP_FAILED)munmap((void*)regs[i],4096);regs[i]=NULL;
 }
 if(device){close_device(device);device=NULL;}
 if(mem_fd>=0){close(mem_fd);mem_fd=-1;}
 if(lock_fd>=0){close(lock_fd);lock_fd=-1;}
 if(library){dlclose(library);library=NULL;}initialized=0;
}
static int initialize(void){
 if(initialized)return 0;
 lock_fd=open("/tmp/blite-perf.lock",O_CREAT|O_RDWR,0600);
 if(lock_fd<0||flock(lock_fd,LOCK_EX|LOCK_NB)){fprintf(stderr,"GATEUP hardware busy\n");goto fail;}
 library=dlopen("/usr/lib/libxrt_core.so.2",RTLD_NOW|RTLD_GLOBAL);
 if(!library){fprintf(stderr,"GATEUP XRT open: %s\n",dlerror());goto fail;}
 void *(*open_device)(unsigned,const char*,int)=dlsym(library,"xclOpen");
 alloc_bo=dlsym(library,"xclAllocBO");map_bo=dlsym(library,"xclMapBO");
 get_props=dlsym(library,"xclGetBOProperties");sync_bo=dlsym(library,"xclSyncBO");
 free_bo=dlsym(library,"xclFreeBO");close_device=dlsym(library,"xclClose");
 if(!open_device||!alloc_bo||!map_bo||!get_props||!sync_bo||!free_bo||!close_device)goto fail;
 device=open_device(0,NULL,0);if(!device)goto fail;
 mem_fd=open("/dev/mem",O_RDWR|O_SYNC);if(mem_fd<0)goto fail;
 for(int i=0;i<LANES;i++){
  regs[i]=mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_SHARED,mem_fd,0x40400000UL+i*0x10000UL);
  if(regs[i]==MAP_FAILED)goto fail;
  if(allocate(&tx[i],TX_BYTES)||allocate(&rx[i],RX_ROWS*8))goto fail;
 }
 if(reset())goto fail;
 initialized=1;if(!exit_registered){atexit(cleanup);exit_registered=1;}
 fprintf(stderr,"GATEUP enabled: four lanes, paired Q5_0 projections + PL SiLU/mul, CPU down, TX=8MiB\n");return 0;
fail:fprintf(stderr,"GATEUP initialization failed\n");cleanup();return -1;
}
static int finite_half(const void *p){uint16_t h;memcpy(&h,p,2);return ((h>>10)&31)!=31;}
static struct entry *prepare(const void *g,const void *u,int rows,int k,size_t gs,size_t us){
 struct entry *c=NULL;
 for(int j=0;j<32;j++){
  if(cache[j].gate==g&&cache[j].up==u&&cache[j].rows==rows&&cache[j].k==k&&cache[j].fmt==21&&cache[j].gs==gs&&cache[j].us==us)return &cache[j];
  if(!cache[j].data&&!c)c=&cache[j];
 }
 size_t bytes=(size_t)rows*(k/32)*48;
 if(!c||bytes>CACHE_BYTES-cache_bytes)return NULL;
 unsigned char *p=calloc(1,bytes);if(!p)return NULL;
 int nb=k/32;
 for(int r=0;r<rows;r++)for(int phase=0;phase<2;phase++)for(int b=0;b<nb;b++){
  const unsigned char *src=(const unsigned char*)(phase?u:g)+(size_t)r*(phase?us:gs)+b*22;
  if(!finite_half(src)){free(p);return NULL;}
  memcpy(p+(size_t)r*nb*48+(phase*nb+b)*24,src,22);
 }
 *c=(struct entry){g,u,rows,k,21,gs,us,bytes,p};cache_bytes+=bytes;misses++;return c;
}
int gateup_fused(const void *g,const void *u,const void *q8,float *out,int rows,int k,size_t gs,size_t us,const char *name){
 if(!gateup_enabled()||!g||!u||!q8||!out||rows<4||rows>LANES*RX_ROWS||k<=0||k>8192||k%32||
    gs<(size_t)(k/32)*22||us<(size_t)(k/32)*22)return -1;
 int nb=k/32;
 size_t prefix=8+(size_t)nb*40,rowbytes=(size_t)nb*48;
 if(prefix+(size_t)((rows+3)/4)*rowbytes>TX_BYTES)return -1;
 pthread_mutex_lock(&mutex);
 uint64_t start=now(),pack_start=now();int rc=-1;
 if(initialize())goto done;
 struct entry *c=prepare(g,u,rows,k,gs,us);if(!c){fprintf(stderr,"GATEUP pack failed %s\n",name);goto done;}
 pack_ns+=now()-pack_start;
 int first=0,counts[LANES],starts[LANES];
 for(int i=0;i<LANES;i++){
  counts[i]=rows/4+(i<rows%4);starts[i]=first;first+=counts[i];
 }
 for(int b=0;b<nb;b++)
  if(!finite_half((const char*)q8+b*34)){fprintf(stderr,"GATEUP invalid activation\n");goto done;}
 __sync_synchronize();
 /* Arm every receiver before any sender, then pipeline per lane:
  * pack -> cache flush -> MM2S kick, so lane N's host-side memcpy overlaps
  * lane N-1's DMA transfer. Weight bytes never change per layer; the flush
  * cost remains because the shared TX buffer is rewritten each call. */
 for(int i=0;i<LANES;i++){
  wr(i,0x34,0x7000);wr(i,0x30,1);wr(i,0x48,rx[i].pa);wr(i,0x58,counts[i]*8);
 }
 __sync_synchronize();
 uint64_t t=now();
 for(int i=0;i<LANES;i++){
  unsigned char *p=tx[i].map;
  uint64_t header=0x1558ull|((uint64_t)counts[i]<<16)|((uint64_t)nb<<32);memcpy(p,&header,8);
  for(int b=0;b<nb;b++){
   memset(p+8+b*40,0,40);memcpy(p+8+b*40,(const char*)q8+b*34,34);
  }
  memcpy(p+prefix,c->data+(size_t)starts[i]*rowbytes,(size_t)counts[i]*rowbytes);
  if(sync_bo(device,tx[i].id,0,prefix+(size_t)counts[i]*rowbytes,0))goto done;
  wr(i,4,0x7000);wr(i,0,1);wr(i,0x18,tx[i].pa);wr(i,0x28,prefix+(size_t)counts[i]*rowbytes);
 }
 unsigned pending=15;
 while(pending){
  for(int i=0;i<LANES;i++)if(pending&(1u<<i)){
   uint32_t m=rd(i,4),s=rd(i,0x34);
   if((m|s)&0x70){fprintf(stderr,"GATEUP DMA error %s lane%d %08x/%08x\n",name,i,m,s);goto done;}
   if((m&0x1000)&&(s&0x1000))pending&=~(1u<<i);
  }
  if(now()-t>2000000000ull){fprintf(stderr,"GATEUP DMA timeout %s\n",name);goto done;}
 }
 dma_ns+=now()-t;
 for(int i=0;i<LANES;i++){
  if(sync_bo(device,rx[i].id,1,(size_t)counts[i]*8,0))goto done;
  __sync_synchronize();
  if(rd(i,0x58)!=(uint32_t)counts[i]*8){fprintf(stderr,"GATEUP receive length mismatch\n");goto done;}
  for(int r=0;r<counts[i];r++){
   uint32_t bits=(uint32_t)((uint64_t*)rx[i].map)[r];float v;memcpy(&v,&bits,4);
   if(!isfinite(v))goto done;out[starts[i]+r]=v;
  }
 }
 calls++;macs+=(uint64_t)2*rows*k;backend_ns+=now()-start;rc=0;
done:pthread_mutex_unlock(&mutex);return rc;
}
/* Format-12 single-matrix dispatch: Q4_K rows streamed as per-row
 * superblocks (K/256 x 144B) taken straight from the GGUF row layout.
 * Same four-lane split, staging, locking and statistics as gateup_fused. */
static struct entry *prepare12(const void *w,int rows,int k,size_t ws){
 struct entry *c=NULL;
 for(int j=0;j<32;j++){
  if(cache[j].gate==w&&!cache[j].up&&cache[j].rows==rows&&cache[j].k==k&&cache[j].fmt==12)return &cache[j];
  if(!cache[j].data&&!c)c=&cache[j];
 }
 int sbs=k/256;
 size_t rowbytes=(size_t)sbs*144;
 size_t bytes=(size_t)rows*rowbytes;
 if(!c||bytes>CACHE_BYTES-cache_bytes)return NULL;
 unsigned char *p=calloc(1,bytes);if(!p)return NULL;
 for(int r=0;r<rows;r++){
  const unsigned char *src=(const unsigned char*)w+(size_t)r*ws;
  for(int b=0;b<sbs;b++){
   const unsigned char *sbk=src+(size_t)b*144;
   if(!finite_half(sbk)||!finite_half(sbk+2)){free(p);return NULL;}
   memcpy(p+(size_t)r*rowbytes+(size_t)b*144,sbk,144);
  }
 }
 *c=(struct entry){w,NULL,rows,k,12,ws,0,bytes,p};cache_bytes+=bytes;misses++;return c;
}
int gateup_matvec(const void *w,const void *q8,float *out,int rows,int k,size_t ws,const char *name){
 if(!gateup_enabled()||!w||!q8||!out||rows<4||rows>LANES*RX_ROWS||k<=0||k>8192||k%256||
    ws<(size_t)(k/256)*144)return -1;
 int nb=k/32,sbs=k/256;
 size_t prefix=8+(size_t)nb*40,rowbytes=(size_t)sbs*144;
 if(prefix+(size_t)((rows+3)/4)*rowbytes>TX_BYTES)return -1;
 pthread_mutex_lock(&mutex);
 uint64_t start=now();int rc=-1;
 if(initialize())goto done;
 struct entry *c=prepare12(w,rows,k,ws);if(!c){fprintf(stderr,"GATEUP pack failed %s\n",name);goto done;}
 int first=0,counts[LANES],starts[LANES];
 for(int i=0;i<LANES;i++){
  counts[i]=rows/4+(i<rows%4);starts[i]=first;first+=counts[i];
 }
 for(int b=0;b<nb;b++)
  if(!finite_half((const char*)q8+b*34)){fprintf(stderr,"GATEUP invalid activation\n");goto done;}
 __sync_synchronize();
 for(int i=0;i<LANES;i++){
  wr(i,0x34,0x7000);wr(i,0x30,1);wr(i,0x48,rx[i].pa);wr(i,0x58,counts[i]*8);
 }
 __sync_synchronize();
 uint64_t t=now();
 for(int i=0;i<LANES;i++){
  unsigned char *p=tx[i].map;
  uint64_t header=0x1558ull|((uint64_t)12<<8)|((uint64_t)counts[i]<<16)|((uint64_t)nb<<32);
  memcpy(p,&header,8);
  for(int b=0;b<nb;b++){
   memset(p+8+b*40,0,40);memcpy(p+8+b*40,(const char*)q8+b*34,34);
  }
  memcpy(p+prefix,c->data+(size_t)starts[i]*rowbytes,(size_t)counts[i]*rowbytes);
  if(sync_bo(device,tx[i].id,0,prefix+(size_t)counts[i]*rowbytes,0))goto done;
  wr(i,4,0x7000);wr(i,0,1);wr(i,0x18,tx[i].pa);wr(i,0x28,prefix+(size_t)counts[i]*rowbytes);
 }
 __sync_synchronize();
 unsigned pending=15;
 while(pending){
  for(int i=0;i<LANES;i++)if(pending&(1u<<i)){
   uint32_t m=rd(i,4),st=rd(i,0x34);
   if((m|st)&0x70){fprintf(stderr,"GATEUP DMA error %s lane%d %08x/%08x\n",name,i,m,st);goto done;}
   if((m&0x1000)&&(st&0x1000))pending&=~(1u<<i);
  }
  if(now()-t>2000000000ull){fprintf(stderr,"GATEUP DMA timeout %s\n",name);goto done;}
 }
 dma_ns+=now()-t;
 for(int i=0;i<LANES;i++){
  if(sync_bo(device,rx[i].id,1,(size_t)counts[i]*8,0))goto done;
  __sync_synchronize();
  if(rd(i,0x58)!=(uint32_t)counts[i]*8){fprintf(stderr,"GATEUP receive length mismatch\n");goto done;}
  for(int r=0;r<counts[i];r++){
   uint32_t bits=(uint32_t)((uint64_t*)rx[i].map)[r];float v;memcpy(&v,&bits,4);
   if(!isfinite(v))goto done;out[starts[i]+r]=v;
  }
 }
 calls++;macs+=(uint64_t)rows*k;backend_ns+=now()-start;rc=0;
done:pthread_mutex_unlock(&mutex);return rc;
}
