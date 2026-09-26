#!/usr/bin/env bash
# hyprpeach installer for Omarchy.
#
# Clones the library at a release, writes a setup() call with YOUR monitors
# already filled in, installs the bar strip, and puts `hyprpeach` on your PATH.
#
# THIS IS ALSO THE UPGRADE PATH. `hyprpeach upgrade` checks out the newest
# release and then runs this file from it, so every step below has to be safe
# to run against a machine that already has hyprpeach on it, not only a clean
# one. Each one says how it manages that.
set -euo pipefail

REPOSITORY="${HYPRPEACH_REPOSITORY:-https://github.com/mariotinoco/hyprpeach}"
TAG="${HYPRPEACH_TAG:-v1.2.0}"
CLONE="${HYPRPEACH_CLONE:-$HOME/.config/hypr/hyprpeach}"
ENTRY="${HYPRPEACH_ENTRY:-$HOME/.config/hypr/hyprland.lua}"
BEGIN="-- >>> hyprpeach >>>"
END="-- <<< hyprpeach <<<"
BINARY_DIRECTORY="${HYPRPEACH_BINARY_DIRECTORY:-$HOME/.local/bin}"

say() { printf '\033[38;5;209m🍑\033[0m %s\n' "$*"; }
# %b, not %s: these messages carry \n so a refusal can say what to do about
# itself on its own line instead of printing a literal backslash-n.
die() { printf '\033[38;5;203m✗\033[0m %b\n' "$*" >&2; exit 1; }

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
  # A clone with edits in it is somebody's work, and the checkout below would
  # throw it away without asking.
  [[ -z $(git -C "$CLONE" status --porcelain) ]] || die \
    "$CLONE has local changes, so upgrading would discard them.\n  Keep them:    git -C $CLONE stash\n  Or drop them: git -C $CLONE checkout ."
  say "updating $CLONE to $TAG"
  # The URL is re-asserted because a clone made by an older install may point
  # somewhere this one does not, and then the fetch below quietly succeeds
  # against the wrong repository.
  git -C "$CLONE" remote set-url origin "$REPOSITORY"
  # --force is load-bearing on an UPGRADE. Without it a release whose tag was
  # ever re-pointed fails the whole fetch with "would clobber existing tag",
  # and because this script runs under `set -e` that takes the upgrade down
  # with it. Measured: it is exactly what stalled a v1.0.0 clone here.
  git -C "$CLONE" fetch --quiet --tags --force origin
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

# `grep -- "$BEGIN"`, with the end-of-options marker, because the marker itself
# starts with `--` and grep otherwise reads it as a flag, fails, and reports no
# match. That failure is invisible in an `if`: the block is simply appended
# again, so every re-run of this installer used to leave one more copy of it in
# hyprland.lua.
#
# Replaced rather than appended, so running this twice leaves one block. Both
# markers have to be there: with only the opening one the awk below would treat
# everything after it as the block and delete the rest of the file.
if grep -qF -- "$BEGIN" "$ENTRY" && ! grep -qF -- "$END" "$ENTRY"; then
  die "$ENTRY has the hyprpeach opening marker but not the closing one.\n  Repair or remove the block by hand, then run this again."
fi

if grep -qF -- "$BEGIN" "$ENTRY"; then
  say "replacing the existing hyprpeach block in hyprland.lua"
  # The FIRST block is replaced and any others are dropped, so this converges on
  # one however many are already there. Versions of this script before 1.1.0
  # could not match their own marker and appended a fresh block on every run, so
  # anybody who installed more than once has a pile of them.
  awk -v b="$BEGIN" -v e="$END" -v repl="$BLOCK" '
    index($0,b){ if (!done) { print repl; done=1 } skip=1; next }
    index($0,e){ skip=0; next }
    !skip' "$ENTRY" > "$ENTRY.hyprpeach.tmp"
  mv "$ENTRY.hyprpeach.tmp" "$ENTRY"
else
  say "appending hyprpeach to hyprland.lua (after your defaults, which is required)"
  printf '\n%s\n' "$BLOCK" >> "$ENTRY"
fi

if command -v omarchy >/dev/null; then
  # `add` on an already-added plugin does nothing, so an upgrade that only ever
  # called `add` left the bar strip on whatever release it was first installed
  # at while the library moved on beneath it. Measured: a clone here sat four
  # releases behind its library that way, and nothing reported it.
  if omarchy plugin list --json 2>/dev/null | jq -e '.[] | select(.id == "hyprpeach.desktops")' >/dev/null 2>&1; then
    say "updating the bar strip"
    # `omarchy plugin update` is a `git merge --ff-only`, so it refuses a clone
    # whose history no longer descends from the remote's -- which is every clone
    # taken before a release was re-tagged onto rewritten history. It reports
    # that and returns non-zero; swallowing it leaves the strip on the old
    # widget for good, with the library updating around it. Reinstalling through
    # omarchy's own commands is the recovery, and it needs no path of ours.
    if ! omarchy plugin update hyprpeach.desktops --yes >/dev/null 2>&1; then
      say "the bar strip could not fast-forward — reinstalling it"
      omarchy plugin remove hyprpeach.desktops --yes >/dev/null 2>&1 || true
      omarchy plugin add "$REPOSITORY" --yes >/dev/null 2>&1 || true
    fi
  else
    say "installing the bar strip"
    omarchy plugin add "$REPOSITORY" --yes >/dev/null 2>&1 || true
  fi
  omarchy plugin enable hyprpeach.desktops --section left >/dev/null 2>&1 || true
  # Both of these are displaced rather than merely unused. `omarchy.workspaces`
  # cannot draw a hyprpeach desk at all. `omarchy.menu` is the widget sitting
  # ahead of the strip in the left section, and the strip is built to LEAD that
  # section: it reaches out to line its first tile up with the edge of a tiled
  # window, which is only the right place to be when nothing is in front of it.
  # The menu stays one keypress away on SUPER, and `omarchy plugin enable
  # omarchy.menu --section left` puts it back.
  omarchy plugin disable omarchy.workspaces >/dev/null 2>&1 || true
  omarchy plugin disable omarchy.menu >/dev/null 2>&1 || true
else
  say "no omarchy command — skipping the bar strip, the library works without it"
fi

# `hyprpeach upgrade` from here on, rather than a trip to the repository to
# find out what the newest tag is called.
#
# COPIED, NOT SYMLINKED. A symlink into the clone is always the command
# belonging to the installed release, which reads well until the clone is
# parked on a release older than the command itself -- then the link dangles
# and `hyprpeach` is "No such file or directory" at exactly the moment someone
# wants to upgrade out of that release. A copy can go stale instead, and a
# stale command that still upgrades you is worth more than a correct one that
# is not there. Every install and every upgrade lays it down again.
if [[ -f $CLONE/bin/hyprpeach ]]; then
  mkdir -p "$BINARY_DIRECTORY"
  install -m 755 "$CLONE/bin/hyprpeach" "$BINARY_DIRECTORY/hyprpeach"
  say "hyprpeach → $BINARY_DIRECTORY/hyprpeach"
fi
case ":$PATH:" in
  *":$BINARY_DIRECTORY:"*) ;;
  *) say "note: $BINARY_DIRECTORY is not on your PATH, so 'hyprpeach' will not be found yet" ;;
esac


hyprctl reload >/dev/null
ERRORS=$(hyprctl configerrors | tr -d '[:space:]')
[[ -z $ERRORS ]] || die "Hyprland reported config errors:\n$(hyprctl configerrors)"

say "done — press SUPER+2, and the whole desk turns."
say "upgrades from here: hyprpeach upgrade"
