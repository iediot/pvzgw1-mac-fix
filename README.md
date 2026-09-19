# PvZ: Garden Warfare (2014) on Apple Silicon macOS

Makes **Plants vs. Zombies: Garden Warfare** (the original, Origin SKU) run under
CrossOver on Apple Silicon.

Verified on:

| | |
|---|---|
| Machine | Apple M5 Pro, 24 GB |
| macOS | 27.0 (26A428) |
| CrossOver | 26.3 (wine-11.0-8726) |
| Bottle | `EA App` (win10_64) |
| Game | `v-1.0.3.0`, build 598693, `{"sku":"origin"}` |

## Quick start

```sh
./pvzgw1-fix.sh apply     # apply both fixes
./pvzgw1-fix.sh launch    # start the game
```

`apply` is idempotent, backs up what it touches, and `revert` undoes it.

```sh
./pvzgw1-fix.sh status    # what's currently applied
./pvzgw1-fix.sh revert    # back to stock
```

## What was actually wrong

Two separate crashes, stacked. The game is fully installed and its DRM is fine —
the Origin activation log says `License signature is good.` — so neither problem
is about licensing or a bad install.

### 1. EA in-game overlay takes the process down

EA's overlay (IGO) injects itself into the game and rewrites the import tables of
roughly eighty DLLs, allocating trampolines in each. From
`drive_c/ProgramData/EA Desktop/Logs/IGO_PVZ_*.log`:

```
PreAllocateTrampolines: winevulkan.dll, 00006FFFEBAD0000 ...
PreAllocateTrampolines: xinput1_4.dll, 00007FF001D50000 ...
Starting ReHookWaitThread...
InjectHook::CreateProcessWHook (null) winedbg --auto 3296 7504
```

That last line is Wine's crash handler being spawned — the game died at ~18s with
`0xc0000005` and no usable backtrace. It hooks `winevulkan.dll` even though the
bottle is not using Vulkan, which is a good hint at how well this path is tested
under Wine.

**Fix:** rename `IGO32.dll`, `IGO64.dll`, `IGOProxy32.exe` to `*.disabled`.
Injection fails soft and the overlay is simply absent. You lose the Shift+F1
overlay; nothing else.

### 2. D3DMetal dereferences a null render-target-view

With the overlay gone the crash became legible, and moved one layer down:

```
Unhandled exception: page fault on read access to 0x0000000000000040

=>0 D3D11Texture::GetView(D3D11_RENDER_TARGET_VIEW_DESC const&)+0x27  in d3dmetal
    movq 0x40(%r12), %rax        ; r12 = 0x0000000000000000
```

`r12` is the `this` pointer and it is null, so reading field `+0x40` faults at
address `0x40`. This is inside **D3DMetal**, Apple's DX11→Metal translation layer
that CrossOver uses by default (`CX_GRAPHICS_BACKEND=d3dmetal`). Frostbite asks
for a render target view of a texture D3DMetal never built, and D3DMetal does not
check before dereferencing. Nothing the game or the bottle can do about it.

**Fix:** switch the bottle to **DXVK** (DX11 → Vulkan → MoltenVK → Metal), which
CrossOver already ships at
`CrossOver.app/Contents/SharedSupport/CrossOver/lib/dxvk/x86_64-windows`:

```
"CX_GRAPHICS_BACKEND" = "dxvk"
```

in `cxbottle.conf` under `[EnvironmentVariables]`.

This has to go in `cxbottle.conf` rather than the launch environment, because the
EA App spawns the game with `inheritEnv=[false]` — visible in `EADesktop.log`:

```
[PROCESS] exe=[...PVZ.Main_Win64_Retail.exe], breakaway=[true], inheritEnv=[false]
```

so an env var exported around the launch command never reaches the game.

## Notes

- **Launch through the EA App**, not by running the `.exe` directly. Running
  `PVZ.Main_Win64_Retail.exe` yourself hands off to `Core/ActivationUI.exe`
  (`opened using SMOID 104`) and exits. `./pvzgw1-fix.sh launch` fires the
  `origin2://game/launch/?offerIds=1011216` URL the way the client does.
- The EA App logs `Failed to create IGO graphics context, error: [unsupported
  graphics API: [1]]` for its own window. Harmless — that is the App's overlay
  surface, not the game.
- Render settings live in `~/Documents/PVZ Garden Warfare/settings/PROF_SAVE_profile`.
  Delete that file to make the game redetect the display.
- `cxbottle.conf.original` in this directory is the stock pre-fix config, kept
  for reference.

## Prior art, and what's actually new here

Neither lever is undocumented. Both are well-trodden:

- **Renaming the IGO DLLs** is a standard Proton/Wine fix, documented on the
  [EA Forums](https://answers.ea.com/t5/Technical-Issues/Guide-disable-the-Origin-Overlay-on-the-Steam-version-of-the/td-p/11123982),
  [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=2559210175) and
  ProtonDB.
- **`CX_GRAPHICS_BACKEND`** is an official CodeWeavers setting with a GUI toggle:
  [Advanced Settings in CrossOver Mac 26](https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26).
  You can flip it in CrossOver's own UI instead of editing `cxbottle.conf`; this
  script edits the file so the change is scriptable and revertible.

What this repo adds is the **title-specific diagnosis** — the actual faulting
instruction in D3DMetal for this game, which is what turns "try DXVK, maybe?"
into a known cause — and a single idempotent command that applies and reverts
both fixes together.

### Alternative methods

**Overlay, without renaming files.** Add to
`drive_c/users/crossover/AppData/Local/Electronic Arts/EA Desktop/user_<id>.ini`:

```ini
user.igoenabled=0
```

This survives EA App self-updates, which **restore renamed DLLs** — so if the
overlay crash returns after an EA App update, re-run `apply`, or use this instead.

**Backend, without editing the config.** CrossOver → bottle → Advanced Settings
→ set the graphics backend to DXVK. Same effect as this script's config edit.

## Scope and caveats

- Verified on exactly one machine (see the table above). Untested elsewhere.
- This is **Garden Warfare 1**. Garden Warfare 2 reportedly does not run on Mac
  at all due to EA anti-cheat added post-launch; nothing here changes that.
- Disabling the overlay means no Shift+F1 in-game EA overlay. The game is
  otherwise complete, and DRM is untouched and still works.

## Files

```
pvzgw1-fix.sh          apply / revert / status / launch
cxbottle.conf.original stock bottle config, before any changes
```
