#include <sys/stat.h>
#include <stdlib.h>
#include <dispatch/dispatch.h>
#include <mach-o/getsect.h>
#include <dlfcn.h>
#include <stdarg.h>
#import <objc/message.h>
#import <objc/runtime.h>
// Runtime patch for D3DMetal's buffer render-target-view crash.
//
// D3DMetal's CreateRenderTargetView happily accepts a BUFFER resource, but the
// code that later builds the view does:
//
//     dynamic_cast<D3D11Texture*>(resource)   -> NULL for a buffer
//     D3D11Texture::GetView(desc)             -> called on that NULL
//
// It null-checks the *resource* but never the *cast result*. A static patch to
// return NULL stops the crash but only moves it: the caller stores the null
// view and something downstream dereferences it.
//
// So instead we hand back a real (throwaway) MTLTexture. Frostbite's
// render-to-vertex-buffer writes land in the buffer's real bytes, which is exactly
// what DXVK effectively does by dropping them -- and the game renders fine that
// way.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

static void wr(const char *s);
// mirror a formatted line into the fault log as well as stderr
static void gw1_note(const char *fmt, ...) {
  char b[512]; va_list ap; va_start(ap, fmt);
  vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
  wr(b);
}

#define GETVIEW_OFF 0x00d89c
#define CAVE_OFF    0x24c6c4
// GETVIEW_OFF is D3D11Texture::GetView, so the classes that may legitimately
// reach it are the D3D11-layer textures. These use multiple inheritance, so an
// object's vptr points into the MIDDLE of its vtable symbol (observed at
// &__ZTV14D3D11Texture2D + 0x90), not at symbol+0x10. Match on the address
// range spanning D3D11Texture / Texture1D / Texture2D / Texture3D, which are
// contiguous in __DATA_CONST.
#define VT_TEX_LO   0x366f68   // start of __ZTV12D3D11Texture
#define VT_TEX_HI   0x367688   // end of __ZTV14D3D11Texture3D
#define VT_BUF_LO   0x37ecd0   // __ZTV11D3D11Buffer
#define VT_BUF_HI   0x37ee70
#define CLEARRTV_OFF 0x097854  // D3D11DeviceContext::ClearRenderTargetView

static id<MTLTexture> g_dummy = nil;

// Called instead of GetView when the cast produced NULL.
__attribute__((used))
static void *gw1_dummy_view(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    MTLTextureDescriptor *td =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                         width:1 height:1 mipmapped:NO];
    td.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    g_dummy = [dev newTextureWithDescriptor:td];
    gw1_note("GW1D3DM dummy texture %p for buffer RTVs\n", (__bridge void*)g_dummy);
    fflush(stderr);
  });
  return (__bridge void *)g_dummy;
}

static uint8_t *find_d3dmetal(void) {
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const char *n = _dyld_get_image_name(i);
    if (n && strstr(n, "D3DMetal")) {
      fprintf(stderr, "GW1D3DM found %s\n", n);
      return (uint8_t *)_dyld_get_image_header(i);
    }
  }
  return NULL;
}

static bool write_text(void *dst, const void *src, size_t n) {
  vm_address_t page = (vm_address_t)dst & ~(vm_page_size - 1);
  size_t len = ((vm_address_t)dst + n) - page;
  if (vm_protect(mach_task_self(), page, len, false,
                 VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
    return false;
  memcpy(dst, src, n);
  vm_protect(mach_task_self(), page, len, false, VM_PROT_READ | VM_PROT_EXECUTE);
  return true;
}


// ---------------------------------------------------------------------------
// GetView(this, D3DMTextureViewDesc&, DXGI_FORMAT) -> id<MTLTexture>.
// Everything that reaches the cave comes through here so the policy stays in C.
typedef void *(*getview_fn)(void *self, void *desc, uint32_t fmt);
static getview_fn   g_real_getview = NULL;
static uintptr_t    g_vt_lo = 0, g_vt_hi = 0;

void *gw1_getview_thunk(void *self, void *desc, uint32_t fmt) {
  const void *vptr = self ? *(const void **)self : NULL;
  uintptr_t v = (uintptr_t)vptr;
  if (v >= g_vt_lo && v < g_vt_hi && g_real_getview)
    return g_real_getview(self, desc, fmt);

  // Not a D3DMTexture. Report the class once per distinct vtable so we can see
  // what D3DMetal is actually handing us, then substitute the dummy.
  static const void *seen[8]; static int nseen = 0;
  const void *vp = vptr;
  int known = 0;
  for (int i = 0; i < nseen; i++) if (seen[i] == vp) { known = 1; break; }
  if (!known && nseen < 8) {
    seen[nseen++] = vp;
    Dl_info di;
    if (vp && dladdr((void *)vp, &di) && di.dli_sname)
      gw1_note("GW1D3DM GetView on non-texture: this=%p vptr=%p (%s) -> dummy\n",
               self, vp, di.dli_sname);
    else
      gw1_note("GW1D3DM GetView on non-texture: this=%p vptr=%p (unknown) -> dummy\n",
               self, vp);
  }
  return gw1_dummy_view();
}

static void patch_at(uint8_t *base);

// dyld calls this as each image is mapped, before its code can run. Polling
// missed the window: D3DMetal initialises within the first tick.
static void on_image(const struct mach_header *mh, intptr_t slide) {
  (void)slide;
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    if ((const struct mach_header *)_dyld_get_image_header(i) != mh) continue;
    const char *n = _dyld_get_image_name(i);
    if (n && strstr(n, "D3DMetal")) patch_at((uint8_t *)mh);
    return;
  }
}

void gw1_patch_d3dmetal(void) {
  static bool registered = false;
  if (registered) return;
  registered = true;
  // fires for images already loaded AND every future one
  _dyld_register_func_for_add_image(on_image);
}


// ---------------------------------------------------------------------------
// ClearRenderTargetView runs its texture path even when the RTV's resource is
// a buffer: it reads the hazard tracker from *(resource+0x178), which for a
// D3D11Buffer is not a pointer (observed 0x29 -> fault at 0x29+0x2a8=0x2d1).
// Repointing the one call is enough; swapping the vtable slot is not viable --
// the game's device context lives in CrossOver's PE-side d3d11.dll, so the
// only matching slot in __DATA,__const belongs to something else entirely and
// hooking it fed garbage arguments straight into the function.
#define UPDATEUSAGE_CALL 0x0979f4   // call site inside ClearRenderTargetView
#define UPDATEUSAGE_OFF  0x0a3fd8   // D3D11ResourceStorage::HazardTracker::UpdateUsage
#define CRTV_OFF         0x188cc0   // D3D11Device::CreateRenderTargetView
#define CRTV_STOLEN      16         // 7 whole instrs, none RIP-relative
#define CREATETEX2D_OFF  0x1880f0   // D3D11Device::CreateTexture2D


// ---------------------------------------------------------------------------
// Buffer render-target views: D3DMetal has no implementation for them, and
// making the buffer impersonate a texture corrupts it (ClearRenderTargetView
// writes through texture offsets 0x148/0x160 before reading the bogus hazard
// tracker at 0x178). Instead, intercept view CREATION and hand D3DMetal a
// genuine texture it built itself, so every downstream path gets a real object
// with a real tracker.
//
// The surrogate is NOT a throwaway. During its native allocation only, the
// MTLTexture it would have created is replaced by one aliased onto the
// original MTLBuffer's own bytes:
//
//     [buffer newTextureWithDescriptor:linear
//                               offset:FirstElement * 16
//                          bytesPerRow:NumElements  * 16]
//
// so rendering into the view writes straight into the buffer. No copy, no
// compute pass, no readback. D3DMetal's own resource registration, hazard
// tracker and view bookkeeping still run, because the surrounding D3D11
// texture object is genuine.
//
// Clears need one extra step: D3DMetal defers them against the texture, and a
// later read of the original buffer does not know about the pending clear. We
// flush those through D3DMetal's own FlushClears for aliased textures only.
static uintptr_t g_buf_lo = 0, g_buf_hi = 0;   // __ZTV11D3D11Buffer extent
// D3DMetal's D3D11 COM entry points use the WINDOWS x64 ABI (args in
// rcx/rdx/r8/r9), not System V -- they are called directly from PE code. Every
// earlier hook here read rdi/rsi/rdx and got garbage; re-reading those dumps
// under Win64 makes all the arguments plausible. Internal helpers such as
// D3D11Texture::GetView and HazardTracker::UpdateUsage are ordinary System V,
// which is why the call-site guards on those worked.
#define MSABI __attribute__((ms_abi))
typedef int32_t (MSABI *crtv_fn)(void *dev, void *res, const void *desc, void **out);
typedef int32_t (MSABI *crtex_fn)(void *dev, const void *desc, const void *init, void **out);
static crtv_fn   g_crtv_tramp   = NULL;   // relocated prologue + jmp back
static crtex_fn  g_createtex2d  = NULL;

#define RTV_DIM_BUFFER    1
#define RTV_DIM_TEXTURE2D 4
#define BIND_RENDER_TARGET 0x20
#define BIND_SHADER_RESOURCE 0x8
#define METAL_MAX_DIM     16384


static char g_alias_key;
static void (*g_encode_clear)(void*,void*);
static void (*g_flush_clears)(void*,unsigned,void*,size_t,bool);
static void gw1_encode_clear(void *encoder,void *command) {
 id<MTLTexture> texture=(__bridge id<MTLTexture>)(*(void**)((uint8_t*)command+8));
 while(texture.parentTexture)texture=texture.parentTexture;
 bool aliased=objc_getAssociatedObject(texture,&g_alias_key)!=nil;
 g_encode_clear(encoder,command);
 if(aliased)g_flush_clears(encoder,0,NULL,0,true);
}
typedef struct {void *texture,*allocation;} NativeAllocation;
typedef NativeAllocation (*native_create_fn)(void*,void*,uint32_t,bool);
static native_create_fn g_native_create;
static void **(*g_buffer_entry)(void*);
static __thread void *g_alias_buffer;
static __thread NSUInteger g_alias_width,g_alias_offset;
static __thread unsigned g_alias_hits;
static NativeAllocation gw1_native_create(void *dev,void *desc,uint32_t fmt,bool direct) {
 return g_native_create(dev,desc,fmt,direct || g_alias_buffer != NULL);
}
static void *gw1_new_texture(void *dev,SEL sel,void *descriptor) {
 MTLTextureDescriptor *td=(__bridge MTLTextureDescriptor*)descriptor;
 if(g_alias_buffer && td.width==g_alias_width && td.height==1 &&
    td.pixelFormat==MTLPixelFormatRGBA32Float && td.mipmapLevelCount==1 && td.sampleCount==1 && td.arrayLength==1) {
  id<MTLBuffer> b=(__bridge id<MTLBuffer>)g_alias_buffer;
  MTLTextureDescriptor *linear=[td copy];
  linear.textureType=MTLTextureType2D;
  linear.storageMode=b.storageMode;linear.cpuCacheMode=b.cpuCacheMode;
  linear.hazardTrackingMode=b.hazardTrackingMode;linear.allowGPUOptimizedContents=NO;
  id<MTLTexture> t=[b newTextureWithDescriptor:linear offset:g_alias_offset bytesPerRow:g_alias_width*16];
  if(t){objc_setAssociatedObject(t,&g_alias_key,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);++g_alias_hits;gw1_note("GW1ALIAS texture=%p buffer=%p offset=%lu row=%lu\n",(__bridge void*)t,(__bridge void*)t.buffer,(unsigned long)t.bufferOffset,(unsigned long)t.bufferBytesPerRow);return (__bridge_retained void*)t;}
  gw1_note("GW1ALIAS native creation failed\n");
 }
 return ((void *(*)(void*,SEL,void*))objc_msgSend)(dev,sel,descriptor);
}
int32_t MSABI gw1_create_rtv(void *dev, void *res, const void *desc, void **out) {
  uintptr_t vptr = res ? *(uintptr_t *)res : 0;
  int is_buffer = (vptr >= g_buf_lo && vptr < g_buf_hi);
  unsigned dim = desc ? ((const unsigned *)desc)[1] : 0;
  static int seen = 0;
  if (seen < 6) {
    seen++;
    gw1_note("GW1RTV enter dev=%p res=%p vptr=%p buf=%d dim=%u desc=%p\n",
             dev, res, (void *)vptr, is_buffer, dim, desc);
  }

  if (is_buffer && desc && dim == RTV_DIM_BUFFER && g_createtex2d && g_crtv_tramp) {
    unsigned fmt      = ((const unsigned *)desc)[0];
    unsigned elems    = ((const unsigned *)desc)[3];   // Buffer.NumElements
    unsigned width    = elems ? elems : 1;
    unsigned height   = 1;
    // A buffer view can be longer than Metal allows in one dimension; fold it.
    while (width > METAL_MAX_DIM) { width = (width + 1) / 2; height *= 2; }

    unsigned td[11] = {0};
    td[0] = width; td[1] = height; td[2] = 1; td[3] = 1;   // W,H,Mips,ArraySize
    td[4] = fmt;
    td[5] = 1; td[6] = 0;                                   // SampleDesc{1,0}
    td[7] = 0;                                              // USAGE_DEFAULT
    td[8] = BIND_RENDER_TARGET | BIND_SHADER_RESOURCE;
    td[9] = 0; td[10] = 0;

    void *tex = NULL;
    gw1_note("GW1RTV surrogate: calling CreateTexture2D %ux%u fmt=%u (dev=%p)\n",
             width, height, fmt, dev);
    ptrdiff_t top=((ptrdiff_t*)vptr)[-2];
    void *whole=(uint8_t*)res+top;
    void **entry=g_buffer_entry(whole);
    id<MTLBuffer> backing=entry?(__bridge id<MTLBuffer>)entry[0]:nil;
    unsigned first=((const unsigned*)desc)[2];
    NSUInteger offset=(NSUInteger)first*16,bytes=(NSUInteger)elems*16;
    NSUInteger align=backing?[backing.device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatRGBA32Float]:0;
    bool eligible=fmt==2 && elems && elems<=METAL_MAX_DIM && backing && align && offset%align==0 && bytes%align==0 && offset<=backing.length && bytes<=backing.length-offset;
    gw1_note("GW1ALIAS whole=%p buffer=%p first=%u count=%u length=%lu mode=%lu hazards=%lu eligible=%d\n",whole,(__bridge void*)backing,first,elems,(unsigned long)backing.length,(unsigned long)backing.storageMode,(unsigned long)backing.hazardTrackingMode,eligible);
    g_alias_buffer=eligible?(__bridge void*)backing:NULL;g_alias_width=width;g_alias_offset=offset;g_alias_hits=0;
    int32_t hr=g_createtex2d(dev,td,NULL,&tex);
    g_alias_buffer=NULL;
    gw1_note("GW1ALIAS hooks used=%u\n",g_alias_hits);
    gw1_note("GW1RTV CreateTexture2D returned hr=0x%x tex=%p\n", hr, tex);
    if (hr >= 0 && tex) {
      // The surrogate RTV owns this texture; private data retains the original
      // COM buffer so its allocation cannot be recycled while the RTV lives.
      static const uint32_t owner_guid[4]={0x760cee81,0x4f116391,0xe59d3bac,0x832dea42};
      typedef int32_t (MSABI *set_owner_fn)(void*,const void*,void*);
      int32_t owner_hr=((set_owner_fn)(*(void***)tex)[6])(tex,owner_guid,res);
      if(owner_hr<0)gw1_note("GW1ALIAS retain owner failed hr=%x\n",owner_hr);
      unsigned rd[5] = {0};
      rd[0] = fmt; rd[1] = RTV_DIM_TEXTURE2D; rd[2] = 0;    // Texture2D.MipSlice
      gw1_note("GW1RTV calling trampoline with surrogate tex=%p\n", tex);
      int32_t r = g_crtv_tramp(dev, tex, rd, out);
      gw1_note("GW1RTV trampoline returned %d out=%p\n", r, out ? *out : NULL);
      static int once = 0;
      if (!once++)
        gw1_note("GW1D3DM buffer RTV -> surrogate %ux%u fmt=%u elems=%u hr=%d\n",
                 width, height, fmt, elems, r);
      typedef uint32_t (MSABI *release_fn)(void*);
      ((release_fn)(*(void***)tex)[2])(tex);
      return r;
    }
    gw1_note("GW1D3DM surrogate CreateTexture2D failed hr=0x%x (fmt=%u w=%u)\n",
             hr, fmt, width);
  }
  return g_crtv_tramp(dev, res, desc, out);
}

static void patch_at(uint8_t *base) {
  static bool done = false;
  if (done || !base) return;
  done = true;


  static const uint8_t prologue[18]={0x55,0x41,0x57,0x41,0x56,0x41,0x55,0x41,0x54,0x53,0x50,0x89,0xcd,0x89,0xd3,0x49,0x89,0xf7};
  static const uint8_t origcall[6]={0xff,0x15,0x43,0xf6,0x35,0x00};
  if(memcmp(base+0x6c34,prologue,18)||memcmp(base+0x6cc7,origcall,6)){gw1_note("GW1ALIAS incompatible image\n");return;}
  g_buffer_entry=(void**(*)(void*))(base+0x119028);
  uint8_t *tr=base+CAVE_OFF+0xa0;
  uint8_t t0[30];memcpy(t0,prologue,18);t0[18]=0x48;t0[19]=0xb8;
  void *back0=base+0x6c46;memcpy(t0+20,&back0,8);t0[28]=0xff;t0[29]=0xe0;
  if(!write_text(tr,t0,30))return;g_native_create=(native_create_fn)tr;
  uint8_t *stub=base+CAVE_OFF+0xd0;uint8_t j0[12]={0x48,0xb8};
  void *fn0=(void*)&gw1_new_texture;memcpy(j0+2,&fn0,8);j0[10]=0xff;j0[11]=0xe0;
  if(!write_text(stub,j0,12))return;
  uint8_t call0[6]={0xe8,0,0,0,0,0x90};int32_t rel0=(int32_t)(stub-(base+0x6cc7+5));memcpy(call0+1,&rel0,4);
  if(!write_text(base+0x6cc7,call0,6))return;
  uint8_t j1[18];memset(j1,0x90,18);j1[0]=0x48;j1[1]=0xb8;void *fn1=(void*)&gw1_native_create;memcpy(j1+2,&fn1,8);j1[10]=0xff;j1[11]=0xe0;
  if(!write_text(base+0x6c34,j1,18))return;
  static const uint8_t ep[17]={0x55,0x41,0x57,0x41,0x56,0x41,0x55,0x41,0x54,0x53,0x48,0x83,0xec,0x68,0x49,0x89,0xf6};
  if(memcmp(base+0xfa102,ep,17)){gw1_note("GW1ALIAS clear hook signature mismatch\n");return;}
  uint8_t *et=base+CAVE_OFF+0x100;uint8_t eb[29];memcpy(eb,ep,17);eb[17]=0x48;eb[18]=0xb8;
  void *eback=base+0xfa113;memcpy(eb+19,&eback,8);eb[27]=0xff;eb[28]=0xe0;
  if(!write_text(et,eb,29))return;g_encode_clear=(void(*)(void*,void*))et;
  g_flush_clears=(void(*)(void*,unsigned,void*,size_t,bool))(base+0x1478a8);
  uint8_t ej[17];memset(ej,0x90,17);ej[0]=0x48;ej[1]=0xb8;void *ef=(void*)&gw1_encode_clear;memcpy(ej+2,&ef,8);ej[10]=0xff;ej[11]=0xe0;
  if(!write_text(base+0xfa102,ej,17))return;
  gw1_note("GW1ALIAS allocation hooks installed\n");
  uint8_t *cave    = base + CAVE_OFF;
  uint8_t *getview = base + GETVIEW_OFF;

  // The old cave only rejected a NULL `this`. The real fault is a NON-null
  // pointer to an object that is not a D3DMTexture: GetView locks
  // this+0xa8 and libplatform aborts with os_unfair_lock_corruption.
  // So the cave now just jumps to a C thunk that checks the vtable pointer.
  g_real_getview = (getview_fn)getview;
  g_buf_lo       = (uintptr_t)(base + VT_BUF_LO);
  g_buf_hi       = (uintptr_t)(base + VT_BUF_HI);
  g_vt_lo        = (uintptr_t)(base + VT_TEX_LO);
  g_vt_hi        = (uintptr_t)(base + VT_TEX_HI);

  uint8_t code[16]; size_t k = 0;
  code[k++]=0x48; code[k++]=0xB8;                              // movabs rax, thunk
  void *fn = (void*)&gw1_getview_thunk; memcpy(code+k,&fn,8); k+=8;
  code[k++]=0xFF; code[k++]=0xE0;                              // jmp rax

  // second stub: drop the UpdateUsage call when `this` is not a pointer
  uint8_t *cave2 = cave + 0x20;
  uint8_t g[32]; size_t m = 0;
  g[m++]=0x48; g[m++]=0x81; g[m++]=0xFF;                       // cmp rdi, imm32
  g[m++]=0x00; g[m++]=0x00; g[m++]=0x01; g[m++]=0x00;          //   0x10000
  g[m++]=0x72; g[m++]=0x0C;                                    // jb .skip
  g[m++]=0x48; g[m++]=0xB8;                                    // movabs rax, UpdateUsage
  void *uu = (void *)(base + UPDATEUSAGE_OFF); memcpy(g+m,&uu,8); m+=8;
  g[m++]=0xFF; g[m++]=0xE0;                                    // jmp rax
  g[m++]=0xC3;                                                 // .skip: ret
  if (write_text(cave2, g, m)) {
    uint8_t *site = base + UPDATEUSAGE_CALL;
    int32_t rel = (int32_t)((intptr_t)cave2 - (intptr_t)(site + 5));
    uint8_t call[5]; call[0]=0xE8; memcpy(call+1,&rel,4);
    if (write_text(site, call, 5))
      gw1_note("GW1D3DM UpdateUsage call guarded via stub at %p\n", (void *)cave2);
    else
      gw1_note("GW1D3DM FAILED to repoint UpdateUsage call\n");
  }

  // detour CreateRenderTargetView: trampoline holds the stolen prologue
  uint8_t *tramp = cave + 0x60;
  uint8_t t[48]; size_t n = 0;
  memcpy(t, base + CRTV_OFF, CRTV_STOLEN); n = CRTV_STOLEN;
  t[n++]=0x48; t[n++]=0xB8;
  void *back = (void *)(base + CRTV_OFF + CRTV_STOLEN); memcpy(t+n,&back,8); n+=8;
  t[n++]=0xFF; t[n++]=0xE0;
  if (write_text(tramp, t, n)) {
    g_crtv_tramp  = (crtv_fn)tramp;
    g_createtex2d = (crtex_fn)(base + CREATETEX2D_OFF);
    uint8_t jm[CRTV_STOLEN]; size_t j = 0;
    jm[j++]=0x48; jm[j++]=0xB8;
    void *fn2 = (void *)&gw1_create_rtv; memcpy(jm+j,&fn2,8); j+=8;
    jm[j++]=0xFF; jm[j++]=0xE0;
    while (j < CRTV_STOLEN) jm[j++]=0x90;
    if (write_text(base + CRTV_OFF, jm, j))
      gw1_note("GW1D3DM CreateRenderTargetView detoured (trampoline %p)\n", (void *)tramp);
    else
      gw1_note("GW1D3DM FAILED to detour CreateRenderTargetView\n");
  }

  if (write_text(cave, code, k))
    gw1_note("GW1D3DM patched cave at %p (%zu bytes), GetView=%p\n",
            (void*)cave, k, (void*)getview);
  else
    fprintf(stderr, "GW1D3DM FAILED to make cave writable\n");

  // Route D3D11Texture::GetView's three call sites through the cave, in
  // memory. A stock image calls GETVIEW_OFF directly; an image left patched
  // on disk by an earlier build already points at the cave. Accept both and
  // refuse anything else, so this works on a pristine framework, stays
  // idempotent, and never needs the vendor binary modified on disk.
  {
    static const uint32_t sites[3] = { 0x0a25b4, 0x185ef1, 0x186155 };
    int done = 0, already = 0, bad = 0;
    for (int i = 0; i < 3; i++) {
      uint8_t *site = base + sites[i];
      int32_t cur;
      if (site[0] != 0xE8) { bad++; continue; }
      memcpy(&cur, site + 1, 4);
      uintptr_t tgt = (uintptr_t)(site + 5 + cur);
      if (tgt == (uintptr_t)cave)    { already++; continue; }
      if (tgt != (uintptr_t)getview) { bad++; continue; }
      int32_t rel = (int32_t)((intptr_t)cave - (intptr_t)(site + 5));
      uint8_t call[5]; call[0] = 0xE8; memcpy(call + 1, &rel, 4);
      if (write_text(site, call, 5)) done++; else bad++;
    }
    gw1_note("GW1D3DM GetView call sites: %d redirected, %d already, %d unsupported\n",
             done, already, bad);
  }
  fflush(stderr);
}

// ---------------------------------------------------------------------------
// D3DMetal treats the buffer behind a buffer-RTV as if it were a texture and
// sends it texture selectors. MTLBuffer does not implement them, so ObjC throws
// "unrecognized selector" and the process dies. Graft plausible answers onto
// the driver's buffer class so those calls return something sane instead.
//
// Values describe a 1-D RGBA32Float image over the buffer, which is what
// Frostbite's render-to-vertex-buffer actually is.
#import <objc/runtime.h>

static NSUInteger buf_mipmapLevelCount(id self, SEL _cmd)  { (void)self;(void)_cmd; return 1; }
static NSUInteger buf_width(id self, SEL _cmd) {
  (void)_cmd;
  NSUInteger len = [(id<MTLBuffer>)self length];
  NSUInteger w = len / 16;                 // RGBA32Float = 16 bytes/texel
  return w ? w : 1;
}
static NSUInteger buf_height(id self, SEL _cmd)     { (void)self;(void)_cmd; return 1; }
static NSUInteger buf_depth(id self, SEL _cmd)      { (void)self;(void)_cmd; return 1; }
static NSUInteger buf_arrayLength(id self, SEL _cmd){ (void)self;(void)_cmd; return 1; }
static NSUInteger buf_sampleCount(id self, SEL _cmd){ (void)self;(void)_cmd; return 1; }
static NSUInteger buf_pixelFormat(id self, SEL _cmd){ (void)self;(void)_cmd; return MTLPixelFormatRGBA32Float; }
static NSUInteger buf_textureType(id self, SEL _cmd){ (void)self;(void)_cmd; return MTLTextureType1D; }
static NSUInteger buf_usage(id self, SEL _cmd) {
  (void)self;(void)_cmd;
  return MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
}
static BOOL buf_isFramebufferOnly(id self, SEL _cmd) { (void)self;(void)_cmd; return NO; }
static id   buf_parentTexture(id self, SEL _cmd)     { (void)self;(void)_cmd; return nil; }

void gw1_graft_texture_selectors(void) {
  static bool done = false;
  if (done) return;

  Protocol *pbuf = objc_getProtocol("MTLBuffer");
  if (!pbuf) return;

  unsigned n = 0; Class *all = objc_copyClassList(&n);
  if (!all) return;
  int grafted = 0;

  struct { const char *sel; IMP imp; const char *types; } m[] = {
    { "mipmapLevelCount", (IMP)buf_mipmapLevelCount, "Q@:" },
    { "width",            (IMP)buf_width,            "Q@:" },
    { "height",           (IMP)buf_height,           "Q@:" },
    { "depth",            (IMP)buf_depth,            "Q@:" },
    { "arrayLength",      (IMP)buf_arrayLength,      "Q@:" },
    { "sampleCount",      (IMP)buf_sampleCount,      "Q@:" },
    { "pixelFormat",      (IMP)buf_pixelFormat,      "Q@:" },
    { "textureType",      (IMP)buf_textureType,      "Q@:" },
    { "usage",            (IMP)buf_usage,            "Q@:" },
    { "isFramebufferOnly",(IMP)buf_isFramebufferOnly,"B@:" },
    { "parentTexture",    (IMP)buf_parentTexture,    "@@:" },
  };

  for (unsigned i = 0; i < n; i++) {
    Class c = all[i];
    const char *cn = class_getName(c);
    if (strncmp(cn, "AGX", 3) != 0) continue;
    if (!class_conformsToProtocol(c, pbuf)) continue;
    for (size_t k = 0; k < sizeof(m)/sizeof(m[0]); k++) {
      SEL s = sel_registerName(m[k].sel);
      if (class_getInstanceMethod(c, s)) continue;      // already answers it
      if (class_addMethod(c, s, m[k].imp, m[k].types)) grafted++;
    }
    fprintf(stderr, "GW1D3DM grafted texture selectors onto %s\n", cn);
  }
  free(all);
  gw1_note("GW1D3DM %d selector(s) added\n", grafted);
  fflush(stderr);
  done = true;
}

// ---------------------------------------------------------------------------
// Capture the ORIGINAL fault. Frames 10-11 of the Wine backtrace are _sigtramp:
// a native signal arrives, Wine's handler runs, and RtlVirtualUnwind2 then
// faults on a null write and re-enters itself -- so by the time anything is
// printed the real siginfo is gone. Chain in front of Wine's handler, dump the
// machine state, then hand off so behaviour is otherwise unchanged.
#include <signal.h>
#include <sys/ucontext.h>
#include <unistd.h>
#include <dlfcn.h>

static struct sigaction g_prev[NSIG];

#include <fcntl.h>
// Write to a fixed file, not stderr: the game is normally started by the EA
// launcher, where stderr goes somewhere we do not control.

static int g_logfd = -1;
static void wr(const char *s) {
  if (g_logfd >= 0) write(g_logfd, s, strlen(s));
  write(2, s, strlen(s));
}

static void wrx(const char *label, unsigned long long v) {
  static const char *H = "0123456789abcdef";
  char b[32]; int i = 0;
  b[i++] = '0'; b[i++] = 'x';
  int started = 0;
  for (int sh = 60; sh >= 0; sh -= 4) {
    int d = (v >> sh) & 0xf;
    if (d || started || sh == 0) { b[i++] = H[d]; started = 1; }
  }
  b[i] = 0;
  wr(label); wr(b); wr(" ");
}

// dladdr is not async-signal-safe, but the process is already dying and the
// module+offset is the whole point of doing this.
static void wrsym(const char *label, unsigned long long addr) {
  Dl_info di;
  wr(label); wrx("", addr);
  if (addr && dladdr((void *)(uintptr_t)addr, &di) && di.dli_fname) {
    const char *slash = strrchr(di.dli_fname, '/');
    wr("("); wr(slash ? slash + 1 : di.dli_fname);
    if (di.dli_fbase) wrx("+", addr - (unsigned long long)(uintptr_t)di.dli_fbase);
    if (di.dli_sname) { wr(" "); wr(di.dli_sname); }
    wr(") ");
  }
}

// Wine raises SIGSEGV constantly as part of normal operation (guard pages,
// write-watch, PE exception dispatch), and all of that runs in PE code where
// dladdr finds nothing. Only report faults taken inside a real Mach-O image
// that is not one of Wine's own .so units -- i.e. D3DMetal, AGX, Metal.
static int gw1_interesting(unsigned long long rip) {
  Dl_info di;
  if (!rip || !dladdr((void *)(uintptr_t)rip, &di) || !di.dli_fname) return 0;
  size_t n = strlen(di.dli_fname);
  if (n > 3 && !strcmp(di.dli_fname + n - 3, ".so")) return 0;
  return 1;
}

static void gw1_sig(int sig, siginfo_t *si, void *uap) {
  ucontext_t *uc = (ucontext_t *)uap;
  static int reported = 0;
  if (!uc || !uc->uc_mcontext || !gw1_interesting(uc->uc_mcontext->__ss.__rip)
      || reported >= 32)
    goto chain;
  reported++;
  wr("\nGW1SIG ================ native fault ================\n");
  wrx("GW1SIG sig=", (unsigned)sig);
  wrx("code=", (unsigned)(si ? si->si_code : 0));
  wrx("addr=", (unsigned long long)(uintptr_t)(si ? si->si_addr : 0));
  wr("\n");
  {
    x86_thread_state64_t *ss = &uc->uc_mcontext->__ss;
    wrsym("GW1SIG rip=", ss->__rip); wr("\n");
    wrx("GW1SIG rdi=", ss->__rdi); wrx("rsi=", ss->__rsi);
    wrx("rax=", ss->__rax); wrx("rdx=", ss->__rdx); wr("\n");
    wrx("GW1SIG r14=", ss->__r14); wrx("r15=", ss->__r15);
    wrx("rbp=", ss->__rbp); wrx("rsp=", ss->__rsp); wr("\n");
    // walk the native frame-pointer chain; PE frames will look like garbage
    // and terminate the walk, which is fine -- we want the Mach-O side.
    unsigned long long fp = ss->__rbp;
    for (int i = 0; i < 12 && fp > 0x1000 && !(fp & 7); i++) {
      unsigned long long *f = (unsigned long long *)(uintptr_t)fp;
      unsigned long long ret = f[1];
      if (ret < 0x1000) break;
      wr("GW1SIG  #"); wrx("", (unsigned)i); wrsym("", ret); wr("\n");
      unsigned long long nfp = f[0];
      if (nfp <= fp) break;
      fp = nfp;
    }
  }
  wr("GW1SIG ====================================================\n");

chain:
  if (sig > 0 && sig < NSIG) {
    struct sigaction *p = &g_prev[sig];
    if ((p->sa_flags & SA_SIGINFO) && p->sa_sigaction) { p->sa_sigaction(sig, si, uap); return; }
    if (p->sa_handler && p->sa_handler != SIG_DFL && p->sa_handler != SIG_IGN) { p->sa_handler(sig); return; }
  }
  signal(sig, SIG_DFL);
  raise(sig);
}

void gw1_hook_exceptions(void) {
  static bool done = false;
  if (done) return;
  done = true;
  static const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = gw1_sig;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
  sigemptyset(&sa.sa_mask);
  for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++)
    sigaction(sigs[i], &sa, &g_prev[sigs[i]]);
  const char *lp = getenv("GW1_LOG");
  if (lp && *lp) g_logfd = open(lp, O_WRONLY | O_CREAT | O_APPEND, 0644);
  wr("GW1SIG fault reporter armed\n");
  fprintf(stderr, "GW1 fault reporter installed\n");
  fflush(stderr);
}

// ---------------------------------------------------------------------------
__attribute__((constructor))
static void gw1_init(void) {
  // Diagnostics are opt-in. GW1_LOG may name a file, or a directory in which
  // case each process gets its own gw1-<pid>.log; the shim loads into every
  // wine process in the bottle, so per-process files are usually what you want.
  const char *lg = getenv("GW1_LOG");
  if (lg && *lg) {
    char logpath[1024];
    struct stat st;
    if (stat(lg, &st) == 0 && S_ISDIR(st.st_mode))
      snprintf(logpath, sizeof logpath, "%s/gw1-%d.log", lg, getpid());
    else
      snprintf(logpath, sizeof logpath, "%s", lg);
    g_logfd = open(logpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    gw1_note("GW1 buffer-RTV alias shim loaded\n");
  }
  if (getenv("GW1_DEBUG")) gw1_hook_exceptions();
  gw1_patch_d3dmetal();          // arms a dyld callback; fires when D3DMetal loads
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
    // AGX's buffer class only registers once a Metal device exists, so poll.
    for (int i = 0; i < 600; i++) {
      gw1_graft_texture_selectors();
      usleep(100000);
    }
  });
}
