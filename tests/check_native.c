#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define W __attribute__((ms_abi))
typedef int32_t HR;
typedef HR(W *Create)(void*,unsigned,void*,unsigned,const unsigned*,unsigned,unsigned,void**,unsigned*,void**);
typedef HR(W *CreateBuffer)(void*,void*,void*,void**);
typedef HR(W *CreateView)(void*,void*,void*,void**);
typedef HR(W *CreateShader)(void*,void*,size_t,void*,void**);
typedef void(W *SetShader)(void*,void*,void*,unsigned);
typedef void(W *SetTargets)(void*,unsigned,void**,void*);
typedef void(W *SetViewport)(void*,unsigned,void*);
typedef void(W *SetTopology)(void*,unsigned);
typedef void(W *Draw)(void*,unsigned,unsigned);
typedef void(W *Clear)(void*,void*,const float*);
typedef void(W *Copy)(void*,void*,void*);
typedef HR(W *Map)(void*,void*,unsigned,unsigned,unsigned,void*);
typedef void(W *Unmap)(void*,void*,unsigned);
typedef unsigned(W *Release)(void*);
#define VT(o,n,T) ((T)(*(void***)(o))[n])
#define CHECK(x) do {HR h=(x);if(h<0){printf("FAIL %s=%x\n",#x,h);return 2;}}while(0)
static void *blob(const char *path,size_t*n){FILE*f=fopen(path,"rb");if(!f)return NULL;fseek(f,0,SEEK_END);*n=ftell(f);rewind(f);void*b=malloc(*n);fread(b,1,*n,f);fclose(f);return b;}
int main(int argc,char**argv){
 setbuf(stdout,NULL);if(argc<2)return 2;
 void*shim=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!shim){puts(dlerror());return 2;}
 void*lib=dlopen("/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal",RTLD_NOW|RTLD_LOCAL);if(!lib){puts(dlerror());return 2;}
 Create create=(Create)dlsym(lib,"D3D11CreateDevice");void*dev=NULL,*ctx=NULL;unsigned fl;
 CHECK(create(NULL,1,NULL,0,NULL,0,7,&dev,&fl,&ctx));
 void*vs=NULL,*ps=NULL;size_t len;void*b=blob(".gw1-effects-work/draw.vs.cso",&len);if(!b){puts("missing shaders");return 2;}
 CHECK(VT(dev,12,CreateShader)(dev,b,len,NULL,&vs));free(b);
 b=blob(".gw1-effects-work/draw.ps.cso",&len);if(!b)return 2;
 CHECK(VT(dev,15,CreateShader)(dev,b,len,NULL,&ps));free(b);
 VT(ctx,11,SetShader)(ctx,vs,NULL,0);VT(ctx,9,SetShader)(ctx,ps,NULL,0);VT(ctx,24,SetTopology)(ctx,4);
 unsigned counts[]={6144,16128,6144},starts[]={0,0,16};
 for(unsigned test=0;test<3;test++) {
  unsigned count=counts[test],first=starts[test],total=count+first+16;
  unsigned bd[6]={total*16,0,0x29,0,0,0};float*zeros=calloc(total,16);struct {void*p;unsigned pitch,slice;} init={zeros,0,0};
  void*buf=NULL,*rtv=NULL,*staging=NULL;CHECK(VT(dev,3,CreateBuffer)(dev,bd,&init,&buf));free(zeros);
  unsigned vd[5]={2,1,first,count,0};CHECK(VT(dev,9,CreateView)(dev,buf,vd,&rtv));
  bd[1]=3;bd[2]=0;bd[3]=0x20000;CHECK(VT(dev,3,CreateBuffer)(dev,bd,NULL,&staging));
  for(unsigned frame=0;frame<6;frame++) {
   float color[4]={(float)frame+1,2,3,4};VT(ctx,50,Clear)(ctx,rtv,color);
   if(frame&1){float viewport[6]={0,0,count,1,0,1};VT(ctx,44,SetViewport)(ctx,1,viewport);VT(ctx,33,SetTargets)(ctx,1,&rtv,NULL);VT(ctx,13,Draw)(ctx,3,0);VT(ctx,33,SetTargets)(ctx,0,NULL,NULL);}
   VT(ctx,47,Copy)(ctx,staging,buf);struct {void*p;unsigned row,depth;} m={0};CHECK(VT(ctx,14,Map)(ctx,staging,0,1,0,&m));
   float*v=m.p;unsigned bad=0;
   for(unsigned i=0;i<total*4;i++){float want=i<first*4||i>=(first+count)*4?0:(frame&1)?7+(i%4):color[i%4];if(v[i]!=want){if(bad++<2)printf("at %u got %g want %g\n",i,v[i],want);}}
   VT(ctx,15,Unmap)(ctx,staging,0);printf("count=%u first=%u frame=%u %s mismatches=%u\n",count,first,frame,(frame&1)?"draw":"clear",bad);if(bad)return 3;
  }
  VT(rtv,2,Release)(rtv);VT(staging,2,Release)(staging);VT(buf,2,Release)(buf);
 }
 puts("PASS: clears and shader draws reach original buffers; view boundaries preserved");return 0;
}
