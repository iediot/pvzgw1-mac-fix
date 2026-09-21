# PvZ: Garden Warfare (2014) on Apple Silicon

Makes **Plants vs. Zombies: Garden Warfare** (the original, Origin SKU) run under
CrossOver on Apple Silicon — launching, and rendering correctly in a match.

| | |
|---|---|
| Machine | Apple M5 Pro, 24 GB |
| macOS | 27.0 |
| CrossOver | 26.3 (wine-11.0-8726) |
| Game | `v-1.0.3.0`, build 598693, `{"sku":"origin"}` |

```sh
./pvzgw1-fix.sh apply     # everything
./pvzgw1-fix.sh launch
```

`apply` is idempotent and backs up what it touches; `revert` undoes it.

## Status

Plays, and looks correct. Menus, loading screens and matches all render. The
remaining cost is CPU: the fix below makes the game issue roughly 170 GPU
command buffers per frame instead of one, and that submission overhead — not
the rendering — is what limits the framerate. Lowering resolution or in-game
quality changes nothing, because the GPU is only ~55% busy while four CPU cores
are saturated.

## The three problems

### 1. The EA overlay crashes the game

IGO injects trampolines into ~80 DLLs and takes the process down with
`0xc0000005` about fifteen seconds in. Renaming `IGO32.dll`, `IGO64.dll` and
`IGOProxy32.exe` makes injection fail soft.

### 2. D3DMetal dereferences a null render-target view

CrossOver's default backend dies in
`D3D11Texture::GetView(D3D11_RENDER_TARGET_VIEW_DESC const&)+0x27` with a null
`this`. Switching to DXVK (`CX_GRAPHICS_BACKEND=dxvk`) avoids it.

Both of the above are well-trodden; the interesting part is what was underneath.

### 3. Metal refuses to complete the command buffers

With the crashes gone, the game reached the menus and rendered **black in a
match**. The cause:

```
[mvk-error] VK_ERROR_OUT_OF_DEVICE_MEMORY: MTLCommandBuffer "vkQueueSubmit
MTLCommandBuffer on Queue 0-0" execution failed (code 1):
Internal Error (0000010d:Internal Error)
```

Two things make this hard to find:

- **It only appears on stderr.** `PVZ.Main_Win64_Retail_d3d11.log` shows a
  completely clean run while the GPU fails hundreds of times per second.
- **DXVK never finds out.** `vkQueueSubmit` returns success; MoltenVK reports
  the failure asynchronously afterwards. `grep "Command submission failed"` in
  the DXVK log returns **0** while stderr shows thousands.

**Splitting does not prevent the fault — it contains it.** A failed command
buffer loses only the draws it holds. One buffer per frame loses the entire
frame, which is the black screen. One buffer per fragment shader loses only the
draws sharing that shader, which is invisible.

## The fix

A patched DXVK 1.10.3 (`patches/`, prebuilt in `prebuilt/`) that starts a new
command buffer at every fragment-shader change, plus this bottle environment:

```
"CX_GRAPHICS_BACKEND"                                   = "dxvk"
"MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS"              = "1"
"MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE" = "1024"
"MVK_CONFIG_USE_COMMAND_POOLING"                        = "1"
"DXVK_SPLIT_ON_SHADER"                                  = "1"
"DXVK_SPLIT_DRAWS"                                      = "1"
"DXVK_SPLIT_FRAME_MIN"                                  = "80"
```

These have to live in `cxbottle.conf`, not the launch environment: the EA App
spawns the game with `inheritEnv=[false]`.

### Three things that are not obvious

**`MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1` is mandatory.** Without it
MoltenVK merges DXVK's submissions back into a single Metal command buffer, so
the splitting never reaches the GPU. With prefill off, DXVK was measured
flushing **160 times per frame** while Metal received the whole frame as one
buffer. This one variable is the difference between a black screen and correct
rendering, and while it was off, *every* experiment with split granularity
measured nothing.

**Splitting must follow shader changes, not draw counts.** Splitting every 2, 4
or 8 draws produces dead frames; splitting at every fragment-shader change does
not. The requirement is that a command buffer contain **one fragment shader**,
not that it be small. A buffer containing a pipeline switch is what fails.

**`MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE` must be raised.** The default is
64, and at ~170 buffers per frame the render thread stalls waiting on it. Going
to 1024 took the game from unplayable to 50-60fps. (Measured in-flight depth
never exceeds ~20, so the ceiling was a stall, not real pressure.)

**`DXVK_SPLIT_FRAME_MIN=80`** disables splitting in light frames. Menus draw ~72
per frame and break if their passes are split; matches draw 200-900.

## What the fault actually is

Instrumented by replacing `libMoltenVK.dylib` with a shim that re-exports the
real one and swizzles Metal command-buffer creation to request
`MTLCommandBufferErrorOptionEncoderExecutionStatus` (source in `shim/`). What
that showed:

- `MTLCommandBufferErrorDomain` code 1 — `Internal`.
- **No encoder info attached**, even with error options enabled. Metal does not
  attribute the failure to any encoder, so it is not a shader or draw fault.
- Failing buffers ran 0.5-4ms; healthy ones ~0.04ms.
- Many reported failures never executed at all (`gpu=0.00ms`) — they are
  collateral, killed behind a buffer that did fault.
- Even `vkQueuePresentKHR` buffers, which contain almost no work, fail.
- Apple's Metal API Validation *and* GPU Shader Validation run **completely
  clean** while buffers fail. The command stream is well-formed and the GPU
  rejects it anyway.

So: a driver-level internal error, not attributable to any encoder, triggered by
having multiple pipelines in one command buffer.

## Ruled out, with reasons

Recorded so nobody repeats them.

- **Upstream MoltenVK, any version.** DXVK needs `geometryShader` for D3D11
  feature level 10_0+, and Metal has no geometry shader stage on any Apple GPU.
  CrossOver ships a CodeWeavers *fork* that provides it; upstream fails
  `vkCreateDevice` outright. Permanently pinned to their build.
- **DXVK 2.x / 3.x.** Needs features that fork does not expose; fails device
  creation the same way. So no dynamic rendering either.
- **Patching the game.** Origin encrypts `.text` at rest: 19.9 MB containing 18
  rip-relative instructions, and zero cross-references to the assert strings.
- **Blaming a shader.** All 172 fragment shaders were numbered and 86 of them
  skipped entirely (player model, vehicles, whole backgrounds). Fault rate
  unchanged.
- **Every other MoltenVK knob.** Argument buffers, semaphore support style —
  both neutral.
- **Resolution and in-game quality settings.** No effect; the bottleneck is CPU.
- **Pass-boundary-only splitting, hysteresis on the frame gate, pre-draw vs
  post-draw split placement, draw-index bisection.** All neutral or worse.

## Notes

- Launch through the EA App. Running `PVZ.Main_Win64_Retail.exe` directly hands
  off to `Core/ActivationUI.exe` and exits.
- DXVK's HUD `GPU %` is queue-idle time, not hardware. Use
  `ioreg -l | grep "Device Utilization"`.
- The game rewrites `~/Documents/PVZ Garden Warfare/settings/PROF_SAVE_profile`
  on exit and will reset its own resolution; re-check it before comparing runs.
- Fault counts are only comparable when taken at the same camera angle, in a
  match, over a fixed window. Whole-run totals are meaningless.

## Files

```
pvzgw1-fix.sh   apply / revert / status / launch
prebuilt/       patched d3d11.dll + dxgi.dll (drop-in)
patches/        the DXVK source patch
shim/           MoltenVK interposer used to diagnose the fault
HANDOFF.md      full investigation log, including the dead ends
```
