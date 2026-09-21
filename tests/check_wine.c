#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>
#define C(x) do{HRESULT h=(x);if(FAILED(h)){printf("FAIL %s=%lx\n",#x,h);return 2;}}while(0)
int main(void){setbuf(stdout,NULL);ID3D11Device*d;ID3D11DeviceContext*c;D3D_FEATURE_LEVEL fl;C(D3D11CreateDevice(NULL,1,NULL,0,NULL,0,7,&d,&fl,&c));
D3D11_BUFFER_DESC bd={0};bd.ByteWidth=6144*16;bd.BindFlags=0x29;void*z=calloc(6144,16);D3D11_SUBRESOURCE_DATA init={z,0,0};ID3D11Buffer*b,*s;ID3D11RenderTargetView*v;
C(ID3D11Device_CreateBuffer(d,&bd,&init,&b));D3D11_RENDER_TARGET_VIEW_DESC vd={0};vd.Format=2;vd.ViewDimension=1;vd.Buffer.NumElements=6144;C(ID3D11Device_CreateRenderTargetView(d,(ID3D11Resource*)b,&vd,&v));bd.Usage=3;bd.BindFlags=0;bd.CPUAccessFlags=0x20000;C(ID3D11Device_CreateBuffer(d,&bd,NULL,&s));
float col[4]={1,2,3,4};ID3D11DeviceContext_ClearRenderTargetView(c,v,col);ID3D11DeviceContext_CopyResource(c,(ID3D11Resource*)s,(ID3D11Resource*)b);D3D11_MAPPED_SUBRESOURCE m;C(ID3D11DeviceContext_Map(c,(ID3D11Resource*)s,0,1,0,&m));unsigned bad=0;for(unsigned i=0;i<6144*4;i++)if(((float*)m.pData)[i]!=col[i%4])bad++;printf("Wine buffer RTV: mismatches=%u\n",bad);return bad?3:0;}
