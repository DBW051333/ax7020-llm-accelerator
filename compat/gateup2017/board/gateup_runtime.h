#ifndef GATEUP_RUNTIME_H
#define GATEUP_RUNTIME_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
int gateup_enabled(void);
int gateup_fused(const void *gate,const void *up,const void *q8,float *out,
                 int rows,int k,size_t gate_stride,size_t up_stride,const char *name);
/* Format-12 Q4_K single-matrix dispatch (rows x K, row stride ws bytes). */
int gateup_matvec(const void *w,const void *q8,float *out,
                  int rows,int k,size_t wstride,const char *name);
#ifdef __cplusplus
}
#endif
#endif
