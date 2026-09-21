# MoltenVK interposer

Diagnostic tool. Not needed to play — it exists because nothing else could see
what was happening.

MoltenVK reports only `Internal Error (0000010d)` and DXVK never learns a
submission failed. Metal *can* say which encoder faulted, but only if the
command buffer was created with `MTLCommandBufferErrorOptionEncoderExecutionStatus`,
and MoltenVK creates those buffers, not us.

`DYLD_INSERT_LIBRARIES` is stripped (hardened runtime, no
`allow-dyld-environment-variables`), so instead this builds a dylib that takes
the place of `libMoltenVK.dylib`, **re-exports the real one**, and swizzles
Metal command-buffer creation on the driver's own queue class.

```sh
CO=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver
cp "$CO/lib64/libMoltenVK.dylib" ./libMoltenVK_real.dylib
install_name_tool -id "@rpath/libMoltenVK_real.dylib" ./libMoltenVK_real.dylib

clang -arch x86_64 -dynamiclib -fobjc-arc -O1 \
  -isysroot "$(xcrun --show-sdk-path)" \
  -framework Foundation -framework Metal \
  -install_name "@rpath/libMoltenVK.dylib" \
  -Wl,-reexport_library,./libMoltenVK_real.dylib \
  -o libMoltenVK.dylib shim.m

sudo cp libMoltenVK_real.dylib libMoltenVK.dylib "$CO/lib64/"
sudo codesign -s - --force "$CO/lib64/libMoltenVK_real.dylib"
sudo codesign -s - --force "$CO/lib64/libMoltenVK.dylib"
```

Restore by copying the original `libMoltenVK.dylib` back and deleting
`libMoltenVK_real.dylib`. **Keep a copy of the original first.**

It prints, per failing buffer: GPU duration, buffers in flight, the render
passes it contained (attachment size/format/count), and any encoder info Metal
attaches. Healthy buffers are sampled periodically for comparison.

Two traps worth knowing, both of which produced wrong conclusions before being
found:

- **Swizzle only the driver classes** (`AGX*`). The `MTLTools` and `MTL3On4`
  wrapper classes forward `commandBufferWithDescriptor:` through a selector the
  real device does not implement; hooking them throws
  `NSInvalidArgumentException` and kills the process.
- **Reset per-buffer state at creation.** With
  `MVK_CONFIG_USE_COMMAND_POOLING=1` Metal command buffers are pooled and
  reused, so an associated object accumulates across frames and makes every
  buffer look like it contains the whole frame.
