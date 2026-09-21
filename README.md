# Plants vs. Zombies: Garden Warfare on Apple Silicon

Runs the 2014 Origin/EA release under CrossOver on Apple Silicon, on
CrossOver's native **D3DMetal** backend — no DXVK, no MoltenVK translation of
the game's rendering, and no modified game files.

```sh
./pvzgw1-fix.sh apply
./pvzgw1-fix.sh launch
```

Requires CrossOver with the Apple GPTK backend, the Xcode command line tools
(for `clang`), and an existing bottle with the game installed.

## What is actually broken, and what this fixes

### 1. The EA in-game overlay crashes the game

The overlay injects trampolines into around eighty DLLs and the process dies
on launch with `STATUS_ACCESS_VIOLATION`. The fix renames the four IGO
binaries. Nothing else in EA Desktop is touched, and `revert` puts them back.

### 2. D3DMetal does not implement buffer render-target views

Frostbite renders particle state into a *buffer* — a `R32G32B32A32_FLOAT`
view, the render-to-vertex-buffer idiom. D3DMetal's RTV constructor
`dynamic_cast`s the resource to `D3D11Texture` and runs the texture path on
it, which misreads the object three ways:

| symptom | cause |
|---|---|
| `os_unfair_lock_corruption` abort | `GetView` locks `this+0xa8`, which on a buffer is not a lock |
| null-ish read at `0x2d1` | `ClearRenderTargetView` reads a hazard tracker from `resource+0x178`, where a buffer keeps its bind flags (`0x29`) |
| `unrecognized selector` | the driver's `MTLBuffer` is sent texture selectors |

`src/gw1_d3dmetal.m` patches D3DMetal **in memory** as it loads. Apple's
binary on disk is never modified.

The view gets a genuine D3D11 texture, so D3DMetal's own hazard tracking,
residency and view bookkeeping all still work. Only the *native allocation*
inside that texture is substituted, for a texture aliased onto the original
buffer's bytes:

```objc
[buffer newTextureWithDescriptor:linear
                          offset:FirstElement * 16
                     bytesPerRow:NumElements  * 16]
```

Rendering into the view therefore writes directly into the buffer — no copy,
no compute pass, no readback. Clears need one extra step, because D3DMetal
defers them against the texture and a later read of the buffer does not know
about the pending clear; those are flushed through D3DMetal's own
`FlushClears`, for aliased textures only.

A calling-convention detail matters throughout: D3DMetal's **D3D11 COM entry
points use the Windows x64 ABI** (`rcx/rdx/r8/r9`) because PE code calls them
directly, while its internal C++ helpers are System V. Hooks that get this
wrong receive plausible-looking garbage.

## Verifying it

```sh
./pvzgw1-fix.sh test
```

Builds the shim and a standalone x86_64 D3DMetal harness that creates buffer
RTVs, clears and draws into them, and reads the **original buffer** back
through a staging copy, checking every float. It covers 6144 and 16128
element views, a non-zero `FirstElement` (checking the untouched prefix and
suffix), and alternating clear/draw iterations. The harness loads the shim
only inside its own process, so it never disturbs an installed one.

`tests/check_wine.c` is the same idea through CrossOver's builtin `d3d11`.

## Commands

| command | effect |
|---|---|
| `apply` | overlay fix, build and install the patch, set the backend and DLL overrides |
| `status` | what is currently in place |
| `test` | build and run the buffer-RTV readback test |
| `revert` | restore stock MoltenVK, overlay, overrides and backend |
| `launch` | start the game |

`BOTTLE=name` selects a bottle other than `gw1`. `GW1_LOG=/some/dir` turns on
diagnostics; each process writes `gw1-<pid>.log` there. Diagnostics are off
by default.

## Things worth knowing

- The patch ships as a replacement `libMoltenVK.dylib` that re-exports the
  real one, because that is what gets loaded into every wine process. That
  path is **shared by all bottles**, and a CrossOver update will replace it —
  re-run `apply` afterwards. `revert` restores the original.
- The offsets in `src/gw1_d3dmetal.m` are specific to one build of D3DMetal.
  Every patch site is validated against its expected bytes before anything is
  written, and unrecognised images are refused rather than corrupted.
- Apple's D3DMetal is not redistributed here, and nothing in this repository
  needs it to be modified on disk.

## Known limitation

Some **smoke effects** flicker on and off at certain viewpoints: moving
closer makes the effect disappear, moving back makes it reappear, and
standing on the boundary makes it alternate. It is a clean binary on/off with
no dropped frames, and it affects a small number of effects.

The buffer render-target path measures clean while this is happening:

- every buffer RTV the game creates is successfully aliased onto its buffer
  (no unaliased fallbacks, no allocation failures)
- the aliased allocation never goes stale — 21,504 checks of the buffer's
  current storage entry against what was aliased, zero divergence
- clears and draws reach the original buffer, verified by readback
- a GPU-only probe with no CPU synchronisation in the loop shows no gross
  ordering failure between writes through the view and later reads
- no faults and no Metal errors

The cause is **not established**. The behaviour is equally consistent with a
game-side visibility or fade threshold oscillating at its boundary, which
would also occur on Windows, and no Windows reference was available to
compare against. It is recorded here as an open, minor issue rather than
attributed to this patch.
