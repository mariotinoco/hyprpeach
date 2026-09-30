#!/usr/bin/env bash
# DEPRECATED since 2.0.0. hyprpeach is an Omarchy plugin collection now:
#
#   omarchy plugin add https://github.com/mariotinoco/hyprpeach --enable
#   ~/.config/omarchy/plugins/hyprpeach/bin/hyprpeach plugin add desktops
#
# This file stays because it is the bridge from 1.x. A 1.x `hyprpeach upgrade`
# checks out the newest release and runs ITS install.sh -- this one -- so it
# does the two commands above and nothing else, and a 1.x machine arrives on
# the plugin with the desktops it already had, without anybody reading a
# migration guide first. It also keeps an old `curl ... | bash` link working.
#
# Every step is safe to run again, because an upgrade is a second run.
set -euo pipefail

REPOSITORY="${HYPRPEACH_REPOSITORY:-https://github.com/mariotinoco/hyprpeach}"
PLUGINS="$HOME/.config/omarchy/plugins"
PLUGIN="$PLUGINS/hyprpeach"
# Where 1.x installed the bar strip: the whole repository, cloned under the id
# the strip had then. In 2.x that id belongs to the desktops plugin, a link to
# plugins/desktops inside $PLUGIN -- which has no .git of its own, so a .git
# there is always the 1.x clone.
FIRST_GENERATION_PLUGIN="$PLUGINS/hyprpeach.desktops"

say() { printf '\033[38;5;209m🍑\033[0m %s\n' "$*"; }
die() { printf '\033[38;5;203m✗\033[0m %b\n' "$*" >&2; exit 1; }

# Inside a function for the reason bin/hyprpeach explains: 1.x runs this from a
# clone it has just checked out, and Omarchy's update below may rewrite files
# under a running shell.
main() {
  command -v omarchy >/dev/null || die "hyprpeach 2 is an Omarchy plugin, and there is no omarchy command here"
  say "install.sh is deprecated — hyprpeach is an Omarchy plugin now, and this hands over to Omarchy"

  if [[ -d $FIRST_GENERATION_PLUGIN/.git ]]; then
    say "retiring the 1.x bar strip clone"
    omarchy plugin remove hyprpeach.desktops --yes >/dev/null
  fi

  if [[ -d $PLUGIN/.git ]]; then
    # The URL is re-asserted first. A clone whose origin is anywhere else --
    # a path that no longer exists, a mirror that stopped moving -- either
    # fails the fetch or succeeds against the wrong history, and the second
    # is silent: Omarchy reports the plugin up to date on old code.
    git -C "$PLUGIN" remote set-url origin "$REPOSITORY"
    say "updating hyprpeach"
    # `omarchy plugin update` is a `git merge --ff-only`, so it refuses a clone
    # whose history does not descend from the remote's. Reinstalling through
    # Omarchy's own commands is the recovery.
    if ! omarchy plugin update hyprpeach --yes >/dev/null; then
      say "hyprpeach could not fast-forward — reinstalling it"
      omarchy plugin remove hyprpeach --yes >/dev/null
      omarchy plugin add "$REPOSITORY" --yes >/dev/null
    fi
  else
    say "adding hyprpeach"
    omarchy plugin add "$REPOSITORY" --yes >/dev/null
  fi
  # `add --yes` does not enable, and the service is what keeps `hyprpeach` on
  # PATH from here on.
  omarchy plugin enable hyprpeach >/dev/null

  [[ -x $PLUGIN/bin/hyprpeach ]] || die "the plugin at $PLUGIN has no bin/hyprpeach — is it hyprpeach 2?"
  exec "$PLUGIN/bin/hyprpeach" plugin add desktops
}

main "$@"
