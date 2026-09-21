// Replaces libMoltenVK.dylib, re-exports the real one, and swizzles Metal
// command-buffer creation so every buffer is created with
// MTLCommandBufferErrorOptionEncoderExecutionStatus. That makes Metal attach
// MTLCommandBufferEncoderInfo to the error, which says WHICH encoder faulted
// and whether it faulted itself or was merely affected by another failure.
// MoltenVK only prints the opaque "Internal Error (0000010d)".
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdatomic.h>

static const void *kDescKey = &kDescKey;

static atomic_int g_reported    = 0;
static atomic_int g_outstanding = 0;   // created but not yet completed
static atomic_int g_ok          = 0;
static atomic_int g_fail        = 0;
static atomic_int g_peak        = 0;
static atomic_int g_collateral  = 0;

static const char *stateName(MTLCommandEncoderErrorState s) {
  switch (s) {
    case MTLCommandEncoderErrorStateUnknown:   return "Unknown";
    case MTLCommandEncoderErrorStateCompleted: return "Completed";
    case MTLCommandEncoderErrorStateAffected:  return "Affected";
    case MTLCommandEncoderErrorStatePending:   return "Pending";
    case MTLCommandEncoderErrorStateFaulted:   return "FAULTED";
    default: return "?";
  }
}

static void reportIfFailed(id<MTLCommandBuffer> cb) {
  int out = atomic_fetch_sub(&g_outstanding, 1) - 1;
  double dur = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;   // ms on GPU
  NSError *err = cb.error;

  if (!err) {
    int n = atomic_fetch_add(&g_ok, 1);
    // Periodic baseline so failures can be compared against healthy buffers.
    if ((n % 400) == 0) {
      NSString *w = objc_getAssociatedObject(cb, kDescKey);
      fprintf(stderr, "GW1MTL ok   gpu=%.2fms passes=%s\n",
              dur, w ? w.UTF8String : "(none)");
    }
    return;
  }

  atomic_fetch_add(&g_fail, 1);
  // gpu>0 means the buffer actually executed and faulted: the genuine failure.
  // gpu==0 means it never ran -- collateral, killed behind the real one.
  bool ran = dur > 0.0001;
  if (!ran) { atomic_fetch_add(&g_collateral, 1); return; }
  if (atomic_fetch_add(&g_reported, 1) > 60) return;
  NSString *what = objc_getAssociatedObject(cb, kDescKey);
  fprintf(stderr, "GW1MTL REALFAULT gpu=%.2fms passes=%s\n",
          dur, what ? what.UTF8String : "(none recorded)");
  // Cap output; the fault repeats hundreds of times a second.
  if (atomic_fetch_add(&g_reported, 1) > 40) return;

  fprintf(stderr, "GW1MTL ===== command buffer failed =====\n");
  fprintf(stderr, "GW1MTL label=%s status=%ld domain=%s code=%ld\n",
          cb.label ? cb.label.UTF8String : "(none)",
          (long)cb.status, err.domain.UTF8String, (long)err.code);
  fprintf(stderr, "GW1MTL desc=%s\n", err.localizedDescription.UTF8String);

  NSArray *infos = err.userInfo[MTLCommandBufferEncoderInfoErrorKey];
  if (!infos) {
    fprintf(stderr, "GW1MTL (no encoder info attached)\n");
  } else {
    for (id<MTLCommandBufferEncoderInfo> i in infos) {
      fprintf(stderr, "GW1MTL   encoder '%s' state=%s\n",
              i.label ? i.label.UTF8String : "(none)",
              stateName(i.errorState));
      for (NSString *sp in i.debugSignposts)
        fprintf(stderr, "GW1MTL       signpost: %s\n", sp.UTF8String);
    }
  }
  fflush(stderr);
}

// Describe a render pass: attachment sizes/formats tell us which stage of the
// frame this is (gbuffer, shadow map, lighting, post, UI).
static IMP g_origRenderEnc = NULL;

static id hooked_renderEncoder(id self, SEL _cmd, MTLRenderPassDescriptor *rp) {
  NSMutableString *acc = objc_getAssociatedObject(self, kDescKey);
  if (!acc) {
    acc = [NSMutableString string];
    objc_setAssociatedObject(self, kDescKey, acc, OBJC_ASSOCIATION_RETAIN);
  }
  @try {
    id<MTLTexture> c0 = rp.colorAttachments[0].texture;
    id<MTLTexture> d  = rp.depthAttachment.texture;
    int ncol = 0;
    for (int i = 0; i < 8; i++) if (rp.colorAttachments[i].texture) ncol++;
    [acc appendFormat:@"[%dx%d col=%d fmt=%lu depth=%d] ",
        c0 ? (int)c0.width : (d ? (int)d.width : 0),
        c0 ? (int)c0.height : (d ? (int)d.height : 0),
        ncol, c0 ? (unsigned long)c0.pixelFormat : 0UL, d != nil];
  } @catch (...) {}
  return ((id(*)(id, SEL, id))g_origRenderEnc)(self, _cmd, rp);
}

static IMP g_origCommandBuffer   = NULL;   // -commandBuffer
static IMP g_origUnretained      = NULL;   // -commandBufferWithUnretainedReferences
static IMP g_origWithDescriptor  = NULL;   // -commandBufferWithDescriptor:

// Build via descriptor so Metal attaches encoder info, whichever entry point
// MoltenVK actually calls.
static id makeInstrumented(id self, BOOL retained) {
  MTLCommandBufferDescriptor *d = [MTLCommandBufferDescriptor new];
  d.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
  d.retainedReferences = retained;
  id<MTLCommandBuffer> cb = ((id(*)(id, SEL, id))objc_msgSend)(
      self, @selector(commandBufferWithDescriptor:), d);
  if (cb) {
    objc_setAssociatedObject(cb, kDescKey, [NSMutableString string],
                             OBJC_ASSOCIATION_RETAIN);
    int o = atomic_fetch_add(&g_outstanding, 1) + 1;
    int pk = atomic_load(&g_peak);
    while (o > pk && !atomic_compare_exchange_weak(&g_peak, &pk, o)) {}
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) { reportIfFailed(done); }];
  }
  return cb;
}

static id hooked_commandBuffer(id self, SEL _cmd) {
  id cb = makeInstrumented(self, YES);
  return cb ?: ((id(*)(id, SEL))g_origCommandBuffer)(self, _cmd);
}

static id hooked_unretained(id self, SEL _cmd) {
  id cb = makeInstrumented(self, NO);
  return cb ?: ((id(*)(id, SEL))g_origUnretained)(self, _cmd);
}

// If MoltenVK passes its own descriptor, force the error option onrather than
// replacing it, so we keep whatever else it asked for.
static id hooked_withDescriptor(id self, SEL _cmd, MTLCommandBufferDescriptor *d) {
  @try { d.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus; } @catch (...) {}
  id<MTLCommandBuffer> cb =
      ((id(*)(id, SEL, id))g_origWithDescriptor)(self, _cmd, d);
  if (cb) {
    objc_setAssociatedObject(cb, kDescKey, [NSMutableString string],
                             OBJC_ASSOCIATION_RETAIN);
    int o = atomic_fetch_add(&g_outstanding, 1) + 1;
    int pk = atomic_load(&g_peak);
    while (o > pk && !atomic_compare_exchange_weak(&g_peak, &pk, o)) {}
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) { reportIfFailed(done); }];
  }
  return cb;
}

static void trySwizzle(void) {
  static bool done = false;
  if (done) return;
  unsigned n = 0;
  Class *all = objc_copyClassList(&n);
  if (!all) return;
  Protocol *p = objc_getProtocol("MTLCommandQueue");
  for (unsigned i = 0; i < n && p; i++) {
    Class c = all[i];
    if (!class_conformsToProtocol(c, p)) continue;
    // ONLY the real driver queue. The MTLTools / MTL3On4 wrapper classes
    // forward commandBufferWithDescriptor: through a selector the underlying
    // device does not implement, which throws NSInvalidArgumentException and
    // kills the process (it took down the EA App's OpenGL-on-Metal renderer).
    const char *cn = class_getName(c);
    if (strncmp(cn, "AGX", 3) != 0) continue;

    Method md = class_getInstanceMethod(c, @selector(commandBufferWithDescriptor:));
    if (!md) continue;

    Method m1 = class_getInstanceMethod(c, @selector(commandBuffer));
    Method m2 = class_getInstanceMethod(c, @selector(commandBufferWithUnretainedReferences));

    if (m1) {
      if (!g_origCommandBuffer) g_origCommandBuffer = method_getImplementation(m1);
      method_setImplementation(m1, (IMP)hooked_commandBuffer);
    }
    if (m2) {
      if (!g_origUnretained) g_origUnretained = method_getImplementation(m2);
      method_setImplementation(m2, (IMP)hooked_unretained);
    }
    if (!g_origWithDescriptor) g_origWithDescriptor = method_getImplementation(md);
    method_setImplementation(md, (IMP)hooked_withDescriptor);

    fprintf(stderr, "GW1MTL swizzled %s (commandBuffer=%d unretained=%d descriptor=1)\n",
            class_getName(c), m1 != NULL, m2 != NULL);

    // also hook render-encoder creation on the matching command buffer class
    Protocol *pcb = objc_getProtocol("MTLCommandBuffer");
    unsigned n2 = 0; Class *all2 = objc_copyClassList(&n2);
    for (unsigned j = 0; j < n2 && pcb; j++) {
      Class cb2 = all2[j];
      if (strncmp(class_getName(cb2), "AGX", 3) != 0) continue;
      if (!class_conformsToProtocol(cb2, pcb)) continue;
      Method mr = class_getInstanceMethod(cb2, @selector(renderCommandEncoderWithDescriptor:));
      if (!mr) continue;
      if (!g_origRenderEnc) g_origRenderEnc = method_getImplementation(mr);
      method_setImplementation(mr, (IMP)hooked_renderEncoder);
      fprintf(stderr, "GW1MTL hooked renderCommandEncoder on %s\n", class_getName(cb2));
    }
    if (all2) free(all2);
    fflush(stderr);
    done = true;
  }
  free(all);
}

__attribute__((constructor))
static void gw1_init(void) {
  fprintf(stderr, "GW1MTL shim loaded\n"); fflush(stderr);
  // Driver queue classes only register once a Metal device is created, so poll.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
    for (int i = 0; i < 600; i++) { trySwizzle(); usleep(100000); }
  });
}
