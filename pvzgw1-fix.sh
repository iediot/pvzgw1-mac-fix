#!/usr/bin/env bash
#
# pvzgw1-fix.sh — run Plants vs. Zombies: Garden Warfare (2014, Origin SKU)
# under CrossOver on Apple Silicon.
#
# Three separate problems, fixed in order of discovery:
#
#   1. EA in-game overlay (IGO) crashes the game on launch.
#      It injects trampolines into ~80 DLLs and takes the process down with
#      STATUS_ACCESS_VIOLATION. Fixed by renaming the IGO binaries.
#
#   2. D3DMetal dereferences a null render-target view.
#      CrossOver's default backend crashes in D3D11Texture::GetView. Fixed by
#      using DXVK instead.
#
#   3. Metal refuses to complete the GPU command buffers, so frames are
#      discarded and the game renders black in a match.
#      This is the real bug and the rest of this script is about it. Metal
#      reports only "Internal Error (0000010d)" and DXVK never learns the
#      submission failed, so its own log looks perfectly clean.
#
#      The fix is a patched DXVK that starts a new command buffer at every
#      fragment-shader change, so a failure destroys only the draws sharing
#      that shader instead of the whole frame. See README.md.
#
# Usage:
#   ./pvzgw1-fix.sh apply     # everything below, idempotent
#   ./pvzgw1-fix.sh status    # what is currently in place
#   ./pvzgw1-fix.sh revert    # back to stock
#   ./pvzgw1-fix.sh launch    # start the game through the EA App
#
# Override the bottle with:  BOTTLE="Some Bottle" ./pvzgw1-fix.sh apply

set -euo pipefail

BOTTLE="${BOTTLE:-gw1}"
CROSSOVER="${CROSSOVER:-/Applications/CrossOver.app}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
BOTTLE_CONF="$BOTTLE_DIR/cxbottle.conf"
DRIVE_C="$BOTTLE_DIR/drive_c"
WINE="$CROSSOVER/Contents/SharedSupport/CrossOver/bin/wine"
WINESERVER="$CROSSOVER/Contents/SharedSupport/CrossOver/bin/wineserver"
EA_ROOT="$DRIVE_C/Program Files/Electronic Arts/EA Desktop"
CONTENT_ID="1011216"

# ---------------------------------------------------------------- the config
#
# Every one of these was measured. The two that matter most:
#
#   MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1
#     Without this MoltenVK merges DXVK's submissions back into one Metal
#     command buffer, so the splitting below never reaches the GPU and has no
#     effect whatsoever. This single variable is the difference between "black
#     screen" and "renders perfectly".
#
#   DXVK_SPLIT_ON_SHADER=1
#     Split at every fragment-shader change. Splitting on a fixed draw count
#     instead (every 4, 8, 25...) does NOT work: what matters is that a command
#     buffer contains only one fragment shader, not that it is small.
#
declare -a ENV_KEYS=(
  CX_GRAPHICS_BACKEND
  MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS
  MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE
  MVK_CONFIG_USE_COMMAND_POOLING
  DXVK_SPLIT_ON_SHADER
  DXVK_SPLIT_DRAWS
  DXVK_SPLIT_FRAME_MIN
)
declare -a ENV_VALS=(
  dxvk
  1
  1024   # default is 64; at ~170 buffers/frame the render thread stalls on it
  1
  1
  1
  80     # only split in frames over 80 draws: menus are ~72 and must not split
)

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
info() { printf '%s==>%s %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$OFF" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$OFF"; }

preflight() {
  [ -d "$CROSSOVER" ]  || die "CrossOver not found at $CROSSOVER"
  [ -x "$WINE" ]       || die "CrossOver wine loader missing: $WINE"
  [ -d "$BOTTLE_DIR" ] || die "Bottle '$BOTTLE' not found at $BOTTLE_DIR"
  [ -f "$BOTTLE_CONF" ]|| die "Bottle config missing: $BOTTLE_CONF"
}

# Stop only THIS bottle. wineserver acts on WINEPREFIX, so the guard must be a
# per-prefix check -- a bare pgrep would also match other bottles and killing
# those can abort an unrelated download.
stop_bottle() {
  if WINEPREFIX="$BOTTLE_DIR" "$WINESERVER" -k0 >/dev/null 2>&1; then
    info "Shutting down bottle '$BOTTLE'"
    WINEPREFIX="$BOTTLE_DIR" "$WINESERVER" -k >/dev/null 2>&1 || true
  else
    note "bottle '$BOTTLE' already idle"
  fi
}

game_dir() {
  find "$DRIVE_C/Program Files/EA Games" -maxdepth 1 -type d \
       -name "Plants vs Zombies Garden Warfare" 2>/dev/null | head -1
}

ea_dir() {
  find "$EA_ROOT" -mindepth 2 -maxdepth 2 -type d -name 'EA Desktop' 2>/dev/null | head -1
}

# ------------------------------------------------------------- fix 1: overlay

igo_disable() {
  local dir f n=0
  dir="$(ea_dir)" || { warn "EA Desktop not found; skipping overlay fix"; return 0; }
  [ -n "$dir" ] || { warn "EA Desktop not found; skipping overlay fix"; return 0; }
  for f in IGO32.dll IGO64.dll IGOProxy32.exe IGOProxy64.exe; do
    [ -f "$dir/$f" ] && { mv "$dir/$f" "$dir/$f.disabled"; note "disabled $f"; n=$((n+1)); }
  done
  [ "$n" -gt 0 ] && info "EA overlay disabled ($n file(s))" || info "EA overlay already disabled"
}

igo_enable() {
  local dir f n=0
  dir="$(ea_dir)"; [ -n "$dir" ] || return 0
  for f in IGO32.dll IGO64.dll IGOProxy32.exe IGOProxy64.exe; do
    [ -f "$dir/$f.disabled" ] && { mv "$dir/$f.disabled" "$dir/$f"; n=$((n+1)); }
  done
  [ "$n" -gt 0 ] && info "EA overlay restored ($n file(s))" || info "EA overlay already enabled"
}

# --------------------------------------------------- fix 2+3: env + patched dxvk

env_current() { sed -n "s/^\"$1\" = \"\(.*\)\"\$/\1/p" "$BOTTLE_CONF" | tail -1; }

# These must live in cxbottle.conf, not the launch environment: the EA App
# spawns the game with inheritEnv=[false], so exported variables never arrive.
env_set() {
  local key="$1" want="$2" cur
  cur="$(env_current "$key" || true)"
  [ "$cur" = "$want" ] && return 0
  if [ -n "$cur" ]; then
    sed -i '' "s/^\"$key\" = \".*\"\$/\"$key\" = \"$want\"/" "$BOTTLE_CONF"
  elif grep -q '^\[EnvironmentVariables\]' "$BOTTLE_CONF"; then
    sed -i '' "s/^\(\[EnvironmentVariables\]\)\$/\1\n\"$key\" = \"$want\"/" "$BOTTLE_CONF"
  else
    printf '\n[EnvironmentVariables]\n"%s" = "%s"\n' "$key" "$want" >> "$BOTTLE_CONF"
  fi
  note "$key = $want   (was ${cur:-unset})"
}

config_set() {
  [ -f "$BOTTLE_CONF.pvzfix.bak" ] || {
    cp "$BOTTLE_CONF" "$BOTTLE_CONF.pvzfix.bak"
    note "backed up cxbottle.conf"
  }
  local i
  for i in "${!ENV_KEYS[@]}"; do env_set "${ENV_KEYS[$i]}" "${ENV_VALS[$i]}"; done
  info "Bottle environment configured"
}

dxvk_install() {
  local gd; gd="$(game_dir)"
  [ -n "$gd" ] || { warn "Game directory not found; skipping DXVK install"; return 0; }

  if [ ! -f "$HERE/prebuilt/d3d11.dll" ]; then
    warn "prebuilt/d3d11.dll missing -- build it from patches/ (see README)"
    return 0
  fi

  # App-local DLLs override the system ones for this process only.
  local f
  for f in d3d11.dll dxgi.dll; do
    [ -f "$HERE/prebuilt/$f" ] || continue
    if [ -f "$gd/$f" ] && [ ! -f "$gd/$f.stock" ]; then
      cp "$gd/$f" "$gd/$f.stock"
      note "kept original $f as $f.stock"
    fi
    cp "$HERE/prebuilt/$f" "$gd/$f"
  done
  info "Patched DXVK installed next to the game"

  cat > "$gd/dxvk.conf" <<'CONF'
dxvk.logLevel     = none
dxgi.syncInterval = 0
dxgi.maxFrameRate = 60
CONF
  note "wrote dxvk.conf (60fps cap; remove maxFrameRate to uncap)"
}

dxvk_remove() {
  local gd f; gd="$(game_dir)"; [ -n "$gd" ] || return 0
  for f in d3d11.dll dxgi.dll; do
    if [ -f "$gd/$f.stock" ]; then mv "$gd/$f.stock" "$gd/$f"
    else rm -f "$gd/$f"; fi
  done
  rm -f "$gd/dxvk.conf"
  info "Removed app-local DXVK"
}

dxvk_check() {
  local gd; gd="$(game_dir)"
  if [ -z "$gd" ] || [ ! -f "$gd/d3d11.dll" ]; then
    warn "No app-local d3d11.dll -- the game will render black in a match."
  elif [ -n "$(strings "$gd/d3d11.dll" 2>/dev/null | grep -m1 DXVK_SPLIT_ON_SHADER || true)" ]; then
    info "Patched DXVK present"
  else
    warn "app-local d3d11.dll is NOT the patched build -- black screen in match."
  fi
}

# ------------------------------------------------------------------- actions

do_apply() {
  preflight; stop_bottle
  igo_disable
  config_set
  dxvk_install
  dxvk_check
  echo; info "Done. Launch with: $0 launch"
}

do_revert() {
  preflight; stop_bottle
  igo_enable
  dxvk_remove
  if [ -f "$BOTTLE_CONF.pvzfix.bak" ]; then
    mv "$BOTTLE_CONF.pvzfix.bak" "$BOTTLE_CONF"; info "Restored original cxbottle.conf"
  else
    warn "No cxbottle.conf backup found; leaving as-is"
  fi
  echo; info "Reverted to stock."
}

do_status() {
  preflight
  echo "bottle: $BOTTLE_DIR"
  local i k v cur
  for i in "${!ENV_KEYS[@]}"; do
    k="${ENV_KEYS[$i]}"; v="${ENV_VALS[$i]}"; cur="$(env_current "$k" || true)"
    printf '  %-52s %-6s (want %s)\n' "$k" "${cur:-unset}" "$v"
  done
  local dir; dir="$(ea_dir)"
  if [ -n "$dir" ] && [ -f "$dir/IGO64.dll.disabled" ] && [ ! -f "$dir/IGO64.dll" ]; then
    echo "  overlay: disabled (good)"
  else
    echo "  overlay: ENABLED (will crash the game)"
  fi
  dxvk_check
}

do_launch() {
  preflight
  local ea ver; ea="$(ea_dir)"; [ -n "$ea" ] || die "EA Desktop not found"
  ver="$(basename "$(dirname "$ea")")"
  info "Launching PvZ: Garden Warfare"
  "$WINE" --bottle "$BOTTLE" --no-wait \
    "$(printf 'C:\\Program Files\\Electronic Arts\\EA Desktop\\%s\\EA Desktop\\EADesktop.exe' "$ver")" \
    -ls=LaunchHelper "-launchHelperArgument=origin2://game/launch/?offerIds=$CONTENT_ID" \
    >/dev/null 2>&1
  note "EA App starting; the game follows in ~20s."
}

case "${1:-apply}" in
  apply)  do_apply  ;;
  revert) do_revert ;;
  status) do_status ;;
  launch) do_launch ;;
  *) die "usage: $0 {apply|revert|status|launch}" ;;
esac
