#include "gateup_runtime.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
static float half(const void *p){
 uint16_t h;memcpy(&h,p,2);int e=(h>>10)&31;float m=(float)(h&1023);
 float v=e?ldexpf(1.0f+m/1024.0f,e-15):ldexpf(m,-24);return h&0x8000?-v:v;
}
static double dot(const unsigned char *w,const unsigned char *a,int k){
 double y=0;
 for(int s=0;s<k/32;s++){
  uint32_t high;memcpy(&high,w+s*22+2,4);int sum=0;
  for(int j=0;j<32;j++){
   int q=((w[s*22+6+j%16]>>(j>=16?4:0))&15)|(((high>>j)&1)<<4);
   sum+=(q-16)*(int)(int8_t)a[s*34+2+j];
  }
  y+=(double)half(w+s*22)*half(a+s*34)*sum;
 }
 return y;
}
int main(int argc,char **argv){
 if(argc!=2){fprintf(stderr,"usage: test_gateup gate-up-raw.bin\n");return 2;}
 int rows=4864,k=896,nb=k/32;size_t stride=(size_t)nb*22,bytes=rows*stride;
 unsigned char *g=malloc(bytes),*u=malloc(bytes),*a=calloc(nb,34);
 float *out=malloc(rows*4);
 if(!g||!u||!a||!out)return 2;
 FILE *f=fopen(argv[1],"rb");if(!f)return 2;
 if(fread(g,1,bytes,f)!=bytes||fread(u,1,bytes,f)!=bytes||fgetc(f)!=EOF)return 2;fclose(f);
 double worst=0;
 for(int test=0;test<8;test++){
  for(int s=0;s<nb;s++){
   uint16_t d=test==2?1:0x2400;memcpy(a+s*34,&d,2);
   for(int j=0;j<32;j++)a[s*34+2+j]=test==0||test==7?0:(uint8_t)((test==1?j*13+s*7:test*31+j*17+s*11)%255-127);
  }
  if(gateup_fused(g,u,a,out,rows,k,stride,stride,"real-blk0"))return 1;
  double se=0,sr=0,maxabs=0;
  for(int r=0;r<rows;r++){
   float gate=(float)dot(g+(size_t)r*stride,a,k),up=(float)dot(u+(size_t)r*stride,a,k);
   float reference=(gate/(1.0f+expf(-gate)))*up;
   double diff=(double)out[r]-reference;se+=diff*diff;sr+=(double)reference*reference;
   if(fabs(diff)>maxabs)maxabs=fabs(diff);
  }
  double rel=sr?sqrt(se/sr):sqrt(se);if(rel>worst)worst=rel;
  printf("REAL-GATEUP case=%d relative_L2=%.9g max_abs=%.9g\n",test,rel,maxabs);
  if(!isfinite(rel)||rel>1e-4||(test==0&&se!=0)||(test==7&&se!=0))return 1;
 }
 for(int i=0;i<100;i++)if(gateup_fused(g,u,a,out,rows,k,stride,stride,"fresh-zero"))return 1;
 for(int r=0;r<rows;r++)if(out[r]!=0)return 1;
 printf("REAL-GATEUP-PASS worst_relative_L2=%.9g repeat_zero=100\n",worst);
 free(g);free(u);free(a);free(out);return 0;
}
