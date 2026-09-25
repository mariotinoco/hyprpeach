#!/usr/bin/env bash
# hyprpeach installer for Omarchy.
#
# Clones the library at a release, writes a setup() call with YOUR monitors
# already filled in, and installs the bar strip. Safe to run twice: the block
# it writes is fenced by markers and replaced rather than appended.
set -euo pipefail

REPOSITORY="${HYPRPEACH_REPOSITORY:-https://github.com/mariotinoco/hyprpeach}"
TAG="${HYPRPEACH_TAG:-v1.0.0}"
CLONE="$HOME/.config/hypr/hyprpeach"
ENTRY="$HOME/.config/hypr/hyprland.lua"
BEGIN="-- >>> hyprpeach >>>"
END="-- <<< hyprpeach <<<"

say() { printf '\033[38;5;209m🍑\033[0m %s\n' "$*"; }
die() { printf '\033[38;5;203m✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v hyprctl >/dev/null || die "hyprctl not found — is Hyprland installed?"
command -v jq      >/dev/null || die "jq not found — install it with: omarchy pkg add jq"
[[ -f $ENTRY ]]               || die "no $ENTRY — this expects Hyprland's Lua config"
hyprctl monitors -j >/dev/null 2>&1 || die "Hyprland is not running, so its monitors cannot be read"

# The monitors, in physical order with the bottom one first. Sorted by y
# descending because y grows downward, and matched by EDID description rather
# than connector name: DP-3 and DP-5 swap when cables move ports, and two
# monitors of one model would then quietly trade desktops.
MONITORS=$(hyprctl monitors -j | jq -r 'sort_by(-.y) | .[] | "    \"desc:\(.description)\","')
[[ -n $MONITORS ]] || die "no monitors reported"
say "found $(wc -l <<<"$MONITORS") monitor(s), bottom first:"
sed 's/^/  /' <<<"$MONITORS"

if [[ -d $CLONE/.git ]]; then
  say "updating $CLONE to $TAG"
  git -C "$CLONE" fetch --quiet --tags origin
else
  say "cloning $REPOSITORY into $CLONE"
  git clone --quiet "$REPOSITORY" "$CLONE"
fi
git -C "$CLONE" checkout --quiet --detach "$TAG"

BLOCK=$(cat <<LUA
$BEGIN
-- Hyprland's Lua path looks for name.lua, not name/init.lua.
package.path = os.getenv("HOME") .. "/.config/hypr/?/init.lua;" .. package.path
require("hyprpeach").setup({
  monitors_bottom_to_top = {
$MONITORS
  },
})
$END
LUA
)

if grep -qF "$BEGIN" "$ENTRY"; then
  say "replacing the existing hyprpeach block in hyprland.lua"
  awk -v b="$BEGIN" -v e="$END" -v repl="$BLOCK" '
    index($0,b){skip=1; print repl; next}
    index($0,e){skip=0; next}
    !skip' "$ENTRY" > "$ENTRY.hyprpeach.tmp"
  mv "$ENTRY.hyprpeach.tmp" "$ENTRY"
else
  say "appending hyprpeach to hyprland.lua (after your defaults, which is required)"
  printf '\n%s\n' "$BLOCK" >> "$ENTRY"
fi

if command -v omarchy >/dev/null; then
  say "installing the bar strip"
  omarchy plugin add "$REPOSITORY" --yes >/dev/null 2>&1 || true
  omarchy plugin enable hyprpeach.desktops --section left >/dev/null 2>&1 || true
  omarchy plugin disable omarchy.workspaces >/dev/null 2>&1 || true
else
  say "no omarchy command — skipping the bar strip, the library works without it"
fi

hyprctl reload >/dev/null
ERRORS=$(hyprctl configerrors | tr -d '[:space:]')
[[ -z $ERRORS ]] || die "Hyprland reported config errors:\n$(hyprctl configerrors)"

say "done — press SUPER+2, and the whole desk turns."
