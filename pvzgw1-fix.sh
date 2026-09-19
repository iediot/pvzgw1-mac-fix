#!/usr/bin/env bash
#
# pvzgw1-fix.sh — make Plants vs. Zombies: Garden Warfare (2014, Origin SKU)
# run under CrossOver on Apple Silicon macOS.
#
# Two independent crashes are fixed:
#
#   1. EA in-game overlay (IGO) injection.
#      IGO injects trampoline hooks into ~80 DLLs in the game process,
#      including winevulkan.dll. Under CrossOver this takes the process
#      down with STATUS_ACCESS_VIOLATION (0xc0000005) and no usable
#      backtrace. Fixed by renaming the IGO binaries so injection fails
#      soft and the overlay is simply absent.
#
#   2. D3DMetal null render-target-view.
#      With CX_GRAPHICS_BACKEND=d3dmetal the game dies in:
#
#        D3D11Texture::GetView(D3D11_RENDER_TARGET_VIEW_DESC const&)+0x27
#        movq 0x40(%r12), %rax        ; r12 = 0x0
#
#      i.e. D3DMetal dereferences a null `this` while resolving a render
#      target view. That is a defect in Apple's DX11->Metal layer, not in
#      the game. Fixed by routing DX11 through DXVK (Vulkan -> MoltenVK)
#      instead, which CrossOver ships.
#
# Usage:
#   ./pvzgw1-fix.sh apply     # apply both fixes (idempotent)
#   ./pvzgw1-fix.sh revert    # restore stock settings
#   ./pvzgw1-fix.sh status    # show what is currently applied
#   ./pvzgw1-fix.sh launch    # start the game through the EA App
#
# Override the bottle name with:  BOTTLE="Some Other Bottle" ./pvzgw1-fix.sh apply

set -euo pipefail

BOTTLE="${BOTTLE:-EA App}"
CROSSOVER="${CROSSOVER:-/Applications/CrossOver.app}"

BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
BOTTLE_CONF="$BOTTLE_DIR/cxbottle.conf"
DRIVE_C="$BOTTLE_DIR/drive_c"
WINE="$CROSSOVER/Contents/SharedSupport/CrossOver/bin/wine"
WINESERVER="$CROSSOVER/Contents/SharedSupport/CrossOver/bin/wineserver"

# PvZ GW1 Origin content id, used for the origin2:// launch URL.
CONTENT_ID="1011216"

# The graphics backend we want. d3dmetal is CrossOver's default and is the
# one that crashes; dxvk is the working path for this title.
WANT_BACKEND="dxvk"

# IGO binaries live under a versioned EA Desktop directory:
#   Program Files/Electronic Arts/EA Desktop/<version>/EA Desktop/
EA_ROOT="$DRIVE_C/Program Files/Electronic Arts/EA Desktop"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
info() { printf '%s==>%s %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$OFF" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$OFF"; }

preflight() {
  [ -d "$CROSSOVER" ]   || die "CrossOver not found at $CROSSOVER"
  [ -x "$WINE" ]        || die "CrossOver wine loader missing: $WINE"
  [ -d "$BOTTLE_DIR" ]  || die "Bottle '$BOTTLE' not found at $BOTTLE_DIR"
  [ -f "$BOTTLE_CONF" ] || die "Bottle config missing: $BOTTLE_CONF"
}

# Stop the bottle so cxbottle.conf changes are picked up on next launch and
# no process is holding the IGO DLLs open.
stop_bottle() {
  if pgrep -f "EADesktop.exe|PVZ.Main_Win64_Retail.exe" >/dev/null 2>&1; then
    info "Shutting down the bottle"
    WINEPREFIX="$BOTTLE_DIR" "$WINESERVER" -k >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------- fix 1: IGO

igo_dir() {
  # Echo the versioned EA Desktop binary directory, or nothing if absent.
  # find, not a glob: "Program Files" has a space in it.
  local d
  d="$(find "$EA_ROOT" -mindepth 2 -maxdepth 2 -type d -name 'EA Desktop' 2>/dev/null | head -1)"
  [ -n "$d" ] || return 1
  printf '%s' "$d"
}

igo_disable() {
  local dir f n=0
  dir="$(igo_dir)" || { warn "EA Desktop directory not found; skipping overlay fix"; return 0; }
  for f in IGO32.dll IGO64.dll IGOProxy32.exe IGOProxy64.exe; do
    if [ -f "$dir/$f" ]; then
      mv "$dir/$f" "$dir/$f.disabled"
      note "disabled $f"
      n=$((n + 1))
    fi
  done
  if [ "$n" -gt 0 ]; then
    info "EA in-game overlay disabled ($n file(s))"
  else
    info "EA in-game overlay already disabled"
  fi
}

igo_enable() {
  local dir f n=0
  dir="$(igo_dir)" || return 0
  for f in IGO32.dll IGO64.dll IGOProxy32.exe IGOProxy64.exe; do
    if [ -f "$dir/$f.disabled" ]; then
      mv "$dir/$f.disabled" "$dir/$f"
      note "restored $f"
      n=$((n + 1))
    fi
  done
  [ "$n" -gt 0 ] && info "EA in-game overlay restored ($n file(s))" \
                 || info "EA in-game overlay already enabled"
}

igo_status() {
  local dir
  dir="$(igo_dir)" || { echo "overlay: EA Desktop not found"; return; }
  if [ -f "$dir/IGO64.dll.disabled" ] && [ ! -f "$dir/IGO64.dll" ]; then
    echo "overlay: disabled  (fix applied)"
  else
    echo "overlay: ENABLED   (will crash the game)"
  fi
}

# ------------------------------------------------- fix 2: graphics backend

backend_current() {
  sed -n 's/^"CX_GRAPHICS_BACKEND" = "\(.*\)"$/\1/p' "$BOTTLE_CONF" | tail -1
}

backend_set() {
  local want="$1" cur
  cur="$(backend_current || true)"

  if [ "$cur" = "$want" ]; then
    info "Graphics backend already '$want'"
    return 0
  fi

  cp "$BOTTLE_CONF" "$BOTTLE_CONF.pvzfix.bak"
  note "backed up cxbottle.conf -> cxbottle.conf.pvzfix.bak"

  if [ -n "$cur" ]; then
    sed -i '' "s/^\"CX_GRAPHICS_BACKEND\" = \".*\"\$/\"CX_GRAPHICS_BACKEND\" = \"$want\"/" "$BOTTLE_CONF"
  else
    # No key present: append under the [EnvironmentVariables] section.
    if grep -q '^\[EnvironmentVariables\]' "$BOTTLE_CONF"; then
      sed -i '' "s/^\(\[EnvironmentVariables\]\)\$/\1\n\"CX_GRAPHICS_BACKEND\" = \"$want\"/" "$BOTTLE_CONF"
    else
      printf '\n[EnvironmentVariables]\n"CX_GRAPHICS_BACKEND" = "%s"\n' "$want" >> "$BOTTLE_CONF"
    fi
  fi

  info "Graphics backend: ${cur:-<unset>} -> $want"
}

backend_revert() {
  if [ -f "$BOTTLE_CONF.pvzfix.bak" ]; then
    mv "$BOTTLE_CONF.pvzfix.bak" "$BOTTLE_CONF"
    info "Restored original cxbottle.conf (backend: $(backend_current || echo unset))"
  else
    warn "No backup found; leaving cxbottle.conf as-is (backend: $(backend_current || echo unset))"
  fi
}

# ------------------------------------------------------------------ actions

do_apply() {
  preflight
  stop_bottle
  igo_disable
  backend_set "$WANT_BACKEND"
  echo
  info "Done. Launch with:  $0 launch"
  note "(or just press Play in the EA App)"
}

do_revert() {
  preflight
  stop_bottle
  igo_enable
  backend_revert
  echo
  info "Reverted to stock CrossOver settings."
}

do_status() {
  preflight
  echo "bottle:  $BOTTLE_DIR"
  echo "backend: $(backend_current || echo '<unset>')  (want: $WANT_BACKEND)"
  igo_status
}

do_launch() {
  preflight
  local ea
  ea="$(igo_dir)" || die "EA Desktop not found in bottle"
  info "Launching PvZ: Garden Warfare via the EA App"
  "$WINE" --bottle "$BOTTLE" --no-wait \
    "$(printf 'C:\\Program Files\\Electronic Arts\\EA Desktop\\%s\\EA Desktop\\EADesktop.exe' \
        "$(basename "$(dirname "$ea")")")" \
    -ls=LaunchHelper \
    "-launchHelperArgument=origin2://game/launch/?offerIds=$CONTENT_ID" \
    >/dev/null 2>&1
  note "EA App is starting; the game follows in ~10s."
}

case "${1:-apply}" in
  apply)  do_apply  ;;
  revert) do_revert ;;
  status) do_status ;;
  launch) do_launch ;;
  *) die "usage: $0 {apply|revert|status|launch}" ;;
esac
