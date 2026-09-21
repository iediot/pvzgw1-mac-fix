#!/usr/bin/env bash
#
# pvzgw1-fix.sh — run Plants vs. Zombies: Garden Warfare (2014, Origin SKU)
# under CrossOver on Apple Silicon, on the native D3DMetal backend.
#
# Two independent problems sit between a stock install and a working game.
#
#   1. The EA in-game overlay (IGO) kills the process on launch. It injects
#      trampolines into ~80 DLLs and the game goes down with
#      STATUS_ACCESS_VIOLATION. Fixed by renaming the IGO binaries.
#
#   2. D3DMetal does not implement buffer render-target views. Frostbite
#      renders particle state into a buffer (R32G32B32A32_FLOAT), and
#      D3DMetal's RTV constructor casts the resource to D3D11Texture and uses
#      the texture path on it. That misreads the object in three ways: it
#      locks this+0xa8 as an os_unfair_lock, it reads a hazard tracker from
#      resource+0x178 (which on a buffer holds the bind flags), and it sends
#      the driver's MTLBuffer texture selectors it does not implement.
#
#      src/gw1_d3dmetal.m fixes this at runtime. It gives the RTV a genuine
#      D3D11 texture, but substitutes an MTLTexture aliased onto the original
#      MTLBuffer's own bytes, so rendering into the view writes into the
#      buffer with no copy and no compute pass. See README.md.
#
# The patch dylib replaces CrossOver's libMoltenVK.dylib and re-exports the
# real one. That path is shared by every bottle, and a CrossOver update will
# replace it — re-run 'apply' afterwards. Apple's D3DMetal binary is never
# modified on disk; all of its patching happens in memory at load.
#
# Usage:
#   ./pvzgw1-fix.sh apply     # everything below, idempotent
#   ./pvzgw1-fix.sh status    # what is currently in place
#   ./pvzgw1-fix.sh test      # build and run the buffer-RTV readback test
#   ./pvzgw1-fix.sh revert    # back to stock
#   ./pvzgw1-fix.sh launch    # start the game
#
# Override the bottle with:  BOTTLE="Some Bottle" ./pvzgw1-fix.sh apply
# Diagnostics:               GW1_LOG=/tmp/gw1logs ./pvzgw1-fix.sh launch

set -euo pipefail

BOTTLE="${BOTTLE:-gw1}"
CROSSOVER="${CROSSOVER:-/Applications/CrossOver.app}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
BOTTLE_CONF="$BOTTLE_DIR/cxbottle.conf"
USER_REG="$BOTTLE_DIR/user.reg"
CX_LIB="$CROSSOVER/Contents/SharedSupport/CrossOver/lib64"
CX_BIN="$CROSSOVER/Contents/SharedSupport/CrossOver/bin"

MVK="$CX_LIB/libMoltenVK.dylib"
MVK_REAL="$CX_LIB/libMoltenVK_real.dylib"
D3DMETAL="$CX_LIB/apple_gptk/external/D3DMetal.framework/Versions/A/D3DMetal"
SRC="$HERE/src/gw1_d3dmetal.m"
MARKER="_gw1_create_rtv"          # exported only by our shim

EXE="PVZ.Main_Win64_Retail.exe"
GAME_WIN="C:\\Program Files\\EA Games\\Plants vs Zombies Garden Warfare"

if [ -t 1 ]; then
  GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  GRN=""; YEL=""; RED=""; DIM=""; OFF=""
fi
info() { printf '%s==>%s %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$OFF" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$OFF"; }

preflight() {
  [ -d "$CROSSOVER" ]   || die "CrossOver not found at $CROSSOVER"
  [ -d "$BOTTLE_DIR" ]  || die "bottle '$BOTTLE' not found"
  [ -f "$BOTTLE_CONF" ] || die "no cxbottle.conf in bottle '$BOTTLE'"
}

stop_bottle() {
  "$CX_BIN/wineserver" --bottle "$BOTTLE" -k >/dev/null 2>&1 || true
  sleep 2
  pkill -f "$EXE" >/dev/null 2>&1 || true
  pkill -f "EADesktop.exe|EACefSubProcess.exe|EALaunchHelper.exe" >/dev/null 2>&1 || true
  sleep 1
}

game_dir() {
  local d="$BOTTLE_DIR/drive_c/Program Files/EA Games/Plants vs Zombies Garden Warfare"
  [ -d "$d" ] && printf '%s' "$d"
}

# EA Desktop installs into a versioned subdirectory, so locate the directory
# that actually holds the overlay binaries rather than the first "EA Desktop"
# path that turns up.
ea_dir() {
  local f
  f="$(find "$BOTTLE_DIR/drive_c/Program Files/Electronic Arts" \
        \( -name 'IGO64.dll' -o -name 'IGO64.dll.disabled' \) 2>/dev/null | head -1)"
  [ -n "$f" ] && printf '%s' "$(dirname "$f")"
}

# Identify files by their exported symbols, not by size.
is_our_shim() { [ -f "$1" ] && nm -gU "$1" 2>/dev/null | grep -q "$MARKER"; }
is_moltenvk() { [ -f "$1" ] && nm -gU "$1" 2>/dev/null | grep -q "vkCreateInstance"; }

# ------------------------------------------------------------- fix 1: overlay

igo_disable() {
  local dir n=0 f
  dir="$(ea_dir)" || true
  [ -n "${dir:-}" ] || { warn "EA Desktop not found; skipping overlay fix"; return 0; }
  for f in IGO32.dll IGO64.dll IGOProxy32.exe IGOProxy64.exe; do
    [ -f "$dir/$f" ] && { mv "$dir/$f" "$dir/$f.disabled"; n=$((n+1)); }
  done
  [ "$n" -gt 0 ] && info "EA overlay disabled ($n file(s))" || info "EA overlay already disabled"
}

igo_enable() {
  local dir n=0 f
  dir="$(ea_dir)" || true
  [ -n "${dir:-}" ] || return 0
  for f in IGO32.dll IGO64.dll IGOProxy32.exe IGOProxy64.exe; do
    [ -f "$dir/$f.disabled" ] && { mv "$dir/$f.disabled" "$dir/$f"; n=$((n+1)); }
  done
  [ "$n" -gt 0 ] && info "EA overlay restored ($n file(s))" || info "EA overlay already enabled"
}

# ------------------------------------------------- bottle configuration

env_current() { sed -n "s/^\"$1\" = \"\(.*\)\"\$/\1/p" "$BOTTLE_CONF" | tail -1; }

env_set() {
  python3 - "$BOTTLE_CONF" "$1" "$2" <<'PY'
import sys
path, key, val = sys.argv[1:4]
enc = dict(encoding="utf-8", errors="surrogateescape")
lines = open(path, **enc).read().split("\n")
line, out, done = '"%s" = "%s"' % (key, val), [], False
for l in lines:
    if l.startswith('"%s" = ' % key):
        if not done: out.append(line); done = True
        continue
    out.append(l)
if not done:
    for i, l in enumerate(out):
        if l.strip() == "[EnvironmentVariables]":
            out.insert(i + 1, line); done = True; break
if not done:
    out += ["", "[EnvironmentVariables]", line]
open(path, "w", **enc).write("\n".join(out))
PY
}

env_unset() {
  python3 - "$BOTTLE_CONF" "$1" <<'PY'
import sys
path, key = sys.argv[1:3]
enc = dict(encoding="utf-8", errors="surrogateescape")
lines = open(path, **enc).read().split("\n")
open(path, "w", **enc).write("\n".join(
    l for l in lines if not l.startswith('"%s" = ' % key)))
PY
}

# DXVK needed native d3d11/dxgi. D3DMetal needs the builtin ones, and a
# leftover "native" override with no DLL present fails with 0x7e.
dll_overrides() {
  python3 - "$USER_REG" "$EXE" "$1" <<'PY'
import sys
path, exe, mode = sys.argv[1:4]
enc = dict(encoding="utf-8", errors="surrogateescape")
s = open(path, **enc).read()
head = r"[Software\\Wine\\AppDefaults\\%s\\DllOverrides]" % exe
i = s.find(head)
if mode == "stock":
    if i != -1:
        j = s.find("\n[", i + 1)
        s = s[:i] + (s[j + 1:] if j != -1 else "")
else:
    block = head + "\n" + '"d3d11"="builtin"\n"dxgi"="builtin"\n'
    if i == -1:
        s = s.rstrip("\n") + "\n\n" + block
    else:
        j = s.find("\n[", i + 1)
        s = s[:i] + block + ("\n" + s[j + 1:] if j != -1 else "")
open(path, "w", **enc).write(s)
PY
}

# Any app-local DXVK from an earlier setup shadows the builtin DLLs.
dxvk_park() {
  local dir n=0 f; dir="$(game_dir)" || true; [ -n "${dir:-}" ] || return 0
  for f in d3d11.dll dxgi.dll; do
    [ -f "$dir/$f" ] && { mv "$dir/$f" "$dir/$f.dxvk-parked"; n=$((n+1)); }
  done
  [ "$n" -gt 0 ] && info "parked app-local DXVK ($n file(s))" || true
}

dxvk_unpark() {
  local dir n=0 f; dir="$(game_dir)" || true; [ -n "${dir:-}" ] || return 0
  for f in d3d11.dll dxgi.dll; do
    [ -f "$dir/$f.dxvk-parked" ] && { mv "$dir/$f.dxvk-parked" "$dir/$f"; n=$((n+1)); }
  done
  [ "$n" -gt 0 ] && info "restored app-local DXVK ($n file(s))" || true
}

# ------------------------------------------------- fix 2: the D3DMetal patch

shim_install() {
  [ -f "$SRC" ]      || die "missing $SRC"
  [ -f "$D3DMETAL" ] || die "D3DMetal not found — this CrossOver has no Apple GPTK backend"
  command -v clang >/dev/null || die "clang not found — install the Xcode command line tools"

  # Keep a genuine stock MoltenVK aside, identified by its symbols so we can
  # never mistake one of our own shims for it.
  if is_our_shim "$MVK_REAL"; then
    die "$MVK_REAL is a patch build, not stock MoltenVK — reinstall CrossOver to recover"
  fi
  if [ ! -f "$MVK_REAL" ]; then
    if is_our_shim "$MVK"; then
      die "libMoltenVK.dylib is already a patch build and no stock copy was kept — reinstall CrossOver"
    fi
    is_moltenvk "$MVK" || die "libMoltenVK.dylib does not look like MoltenVK"
    cp "$MVK" "$MVK_REAL"
    install_name_tool -id "@rpath/libMoltenVK_real.dylib" "$MVK_REAL" 2>/dev/null || true
    info "kept the stock MoltenVK as libMoltenVK_real.dylib"
  fi
  is_moltenvk "$MVK_REAL" || die "$MVK_REAL does not export MoltenVK symbols"

  local tmp; tmp="$(mktemp -t gw1shim)"; tmp="$tmp.dylib"
  clang -arch x86_64 -dynamiclib -O2 -fobjc-arc -o "$tmp" "$SRC" \
    -framework Foundation -framework Metal \
    -Wl,-reexport_library,"$MVK_REAL" \
    -install_name "@rpath/libMoltenVK.dylib" || die "build failed"
  is_our_shim "$tmp" || die "built dylib is missing its marker symbol"
  cp "$tmp" "$MVK"; rm -f "$tmp"
  info "buffer-RTV patch installed"
}

shim_remove() {
  if is_our_shim "$MVK_REAL"; then
    warn "$MVK_REAL is a patch build; refusing to restore it as stock MoltenVK"
    return 0
  fi
  if [ -f "$MVK_REAL" ]; then
    mv "$MVK_REAL" "$MVK"
    install_name_tool -id "@rpath/libMoltenVK.dylib" "$MVK" 2>/dev/null || true
    info "stock MoltenVK restored"
  else
    info "stock MoltenVK already in place"
  fi
}

# D3DMetal is patched in memory, but an older build of this project patched it
# on disk. Report that, because it changes nothing at runtime but means the
# framework no longer matches Apple's shipped bytes.
d3dmetal_disk_state() {
  python3 - "$D3DMETAL" <<'PY'
import sys, struct
f = open(sys.argv[1], 'rb').read()
CAVE, GETVIEW = 0x24c6c4, 0x00d89c
tg = []
for site in (0x0a25b4, 0x185ef1, 0x186155):
    b = f[site:site+5]
    tg.append(site + 5 + struct.unpack('<i', b[1:5])[0] if b[:1] == b'\xe8' else None)
if all(t == GETVIEW for t in tg):
    print("stock")
elif all(t == CAVE for t in tg):
    print("patched-on-disk")
else:
    print("unrecognised")
PY
}

# ------------------------------------------------------------------- actions

do_apply() {
  preflight
  stop_bottle
  igo_disable
  shim_install
  dxvk_park
  dll_overrides builtin
  env_set "CX_GRAPHICS_BACKEND" "d3dmetal"
  local k
  for k in DXVK_SPLIT_DRAWS DXVK_SPLIT_FRAME_MIN DXVK_SPLIT_ON_SHADER \
           DXVK_SPLIT_PASS_MIN DXVK_FRAME_RATE WINEDEBUG; do
    env_unset "$k"
  done
  info "done — launch with:  ./pvzgw1-fix.sh launch"
  [ "$(d3dmetal_disk_state)" = "stock" ] || \
    note "note: D3DMetal on disk was modified by an older build; harmless, patching is in memory"
}

do_revert() {
  preflight
  stop_bottle
  igo_enable
  shim_remove
  dxvk_unpark
  dll_overrides stock
  env_unset "CX_GRAPHICS_BACKEND"
  info "reverted to stock"
}

do_status() {
  preflight
  echo "bottle:    $BOTTLE"
  echo "backend:   $(env_current CX_GRAPHICS_BACKEND || true)"
  if is_our_shim "$MVK"; then echo "patch:     installed"
  else echo "patch:     NOT installed"; fi
  if is_moltenvk "$MVK_REAL"; then echo "stock mvk: kept aside (ok)"
  elif [ -f "$MVK_REAL" ]; then echo "stock mvk: PRESENT BUT NOT MOLTENVK"
  else echo "stock mvk: not kept aside"; fi
  echo "D3DMetal:  $(d3dmetal_disk_state) on disk"
  local dir; dir="$(ea_dir)" || true
  if [ -n "${dir:-}" ] && [ -f "$dir/IGO64.dll.disabled" ] && [ ! -f "$dir/IGO64.dll" ]; then
    echo "overlay:   disabled (good)"
  else
    echo "overlay:   ENABLED (will crash the game)"
  fi
}

# Build and run the buffer-RTV readback test against the current source. It
# loads the shim only inside its own process; the installed one is untouched.
do_test() {
  local t="$HERE/tests" out="$HERE/.testbuild"
  [ -f "$t/check_native.c" ] || die "missing tests/check_native.c"
  [ -f "$t/draw.vs.cso" ] && [ -f "$t/draw.ps.cso" ] || \
    die "missing tests/draw.vs.cso and tests/draw.ps.cso — build them with tests/compile_shaders.c"
  mkdir -p "$out"
  clang -arch x86_64 -dynamiclib -O2 -fobjc-arc -o "$out/shim.dylib" "$SRC" \
    -framework Foundation -framework Metal \
    -Wl,-reexport_library,"$MVK_REAL" \
    -install_name "@rpath/libMoltenVK.dylib" || die "shim build failed"
  clang -arch x86_64 -o "$out/check_native" "$t/check_native.c" \
    -Wl,-rpath,"$CX_LIB" -Wl,-rpath,"$CX_LIB/apple_gptk/external" || die "test build failed"
  # check_native looks for its fixtures under .gw1-effects-work/
  local stage; stage="$(mktemp -d)"; mkdir -p "$stage/.gw1-effects-work"
  cp "$t/draw.vs.cso" "$t/draw.ps.cso" "$stage/.gw1-effects-work/"
  ( cd "$stage" && "$out/check_native" "$out/shim.dylib" ) | tail -5
  rm -rf "$stage"
}

do_launch() {
  preflight
  local dir; dir="$(game_dir)" || true
  [ -n "${dir:-}" ] || die "game not found in bottle '$BOTTLE'"
  is_our_shim "$MVK" || warn "patch is not installed — run 'apply' first"
  info "launching"
  "$CX_BIN/wine" --bottle "$BOTTLE" --wait-children \
    --workdir "$GAME_WIN" "$GAME_WIN\\$EXE" >/dev/null 2>&1 &
  note "started; the EA App may take a moment"
}

case "${1:-apply}" in
  apply)  do_apply  ;;
  revert) do_revert ;;
  status) do_status ;;
  test)   do_test   ;;
  launch) do_launch ;;
  *) die "usage: $0 {apply|status|test|revert|launch}" ;;
esac
