#define COBJMACROS
#include <windows.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <string.h>
int main(void){
 const char *srcs[]={"float4 main(uint v:SV_VertexID):SV_Position { float2 p=float2((v<<1)&2,v&2); return float4(p*float2(2,-2)+float2(-1,1),0,1);}","float4 main():SV_Target {return float4(7,8,9,10);}"};
 const char *profiles[]={"vs_5_0","ps_5_0"},*files[]={"draw.vs.cso","draw.ps.cso"};
 for(int i=0;i<2;i++){ID3DBlob*b=NULL,*err=NULL;HRESULT h=D3DCompile(srcs[i],strlen(srcs[i]),NULL,NULL,NULL,"main",profiles[i],0,0,&b,&err);if(FAILED(h)){printf("compile failed %lx %s\n",h,err?(char*)ID3D10Blob_GetBufferPointer(err):"");return 1;}FILE*f=fopen(files[i],"wb");if(!f)return 2;fwrite(ID3D10Blob_GetBufferPointer(b),1,ID3D10Blob_GetBufferSize(b),f);fclose(f);}puts("shaders compiled");return 0;
}
