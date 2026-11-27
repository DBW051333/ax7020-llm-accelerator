#pragma once
#ifdef __cplusplus
extern "C" {
#endif
int para_mac_enabled(void);
int para_mac_run(const void *weight,const void *activation,float *out);
#ifdef __cplusplus
}
#endif
