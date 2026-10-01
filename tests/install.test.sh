#!/usr/bin/env bash
# Runs install.sh and bin/hyprpeach the way a machine meets them -- through
# Omarchy's own plugin scripts -- inside a sandbox HOME.
#
# NOTHING HERE MAY REACH THE MACHINE IT RUNS ON, and once something did. The 1.x
# version of this test redirected its paths but ran the real `omarchy` under the
# real HOME, so the installer's reinstall-the-bar-strip step replaced the
# tester's own plugin with a clone of this sandbox, whose origin was a temporary
# directory deleted a second later. The bar kept running that clone's code, and
# `omarchy plugin update` could never move it again.
#
# So HOME is the sandbox, `omarchy-shell` and `hyprctl` are fakes that record what
# they were asked, and the guard below refuses to run a single case unless those
# fakes are what the scripts will find. Omarchy's plugin scripts -- add, update,
# remove, validate, catalog -- run FOR REAL: they touch nothing outside
# $HOME/.config/omarchy/plugins, and a fake of them is how a test comes to assert
# something the real thing would not do. The last case checks the real HOME is
# as it was.
#
# Run: bash tests/install.test.sh

set -uo pipefail
cd "$(dirname "$0")/.."
REPOSITORY_ROOT=$PWD
REAL_HOME=$HOME

failures=0
checks=0

check() {
  checks=$((checks + 1))
  if [[ $2 != "$3" ]]; then
    failures=$((failures + 1))
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$3" "$2"
  fi
}

OMARCHY_PLUGIN_ADD=$(command -v omarchy-plugin-add) || { echo "needs Omarchy's plugin scripts on PATH"; exit 1; }
OMARCHY_BINARIES=$(dirname "$(readlink -f "$OMARCHY_PLUGIN_ADD")")

# What the real HOME looks like before, so the last case can say it is unchanged.
real_home_snapshot() {
  ls -la --full-time "$REAL_HOME/.config/omarchy/plugins/" 2>&1
  ls -la --full-time "$REAL_HOME/.local/bin/hyprpeach" "$REAL_HOME/.config/hypr/hyprland.lua" 2>&1
  local clone
  for clone in hyprpeach hyprpeach.desktops; do
    git -C "$REAL_HOME/.config/omarchy/plugins/$clone" rev-parse HEAD 2>&1
    git -C "$REAL_HOME/.config/omarchy/plugins/$clone" remote get-url origin 2>&1
  done
}
REAL_HOME_BEFORE=$(real_home_snapshot)

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
LOG="$SANDBOX/calls.log"
: > "$LOG"

# ---------------------------------------------------------------- the fakes

FAKES="$SANDBOX/fakes"
mkdir -p "$FAKES"

# `omarchy` is only a dispatcher, so the fake dispatches too: the plugin verbs to
# Omarchy's real scripts, the rest -- enable, disable, bar position, all of which
# change the RUNNING SHELL's configuration -- recorded and answered `ok`.
cat > "$FAKES/omarchy" <<'FAKE'
#!/usr/bin/env bash
printf 'omarchy %s\n' "$*" >> "$HYPRPEACH_TEST_LOG"
case "$1 ${2:-}" in
  "plugin add"|"plugin update"|"plugin remove"|"plugin validate")
    verb=$2; shift 2; exec "omarchy-plugin-$verb" "$@" ;;
  "plugin list") exec omarchy-shell shell listPlugins ;;
  *) exit 0 ;;
esac
FAKE

# The shell's IPC. `listPlugins` answers from the plugins folder the way the
# shell's own scan does, following links, and skipping hidden backups.
cat > "$FAKES/omarchy-shell" <<'FAKE'
#!/usr/bin/env bash
printf 'omarchy-shell %s\n' "$*" >> "$HYPRPEACH_TEST_LOG"
case "${2:-}" in
  listPlugins)
    find -L "$HOME/.config/omarchy/plugins" -mindepth 2 -maxdepth 2 -name manifest.json \
      ! -path "*/.*/*" -exec jq -c '{id: .id, enabled: false}' {} + 2>/dev/null | jq -s . ;;
  *) echo ok ;;
esac
FAKE

cat > "$FAKES/hyprctl" <<'FAKE'
#!/usr/bin/env bash
printf 'hyprctl %s\n' "$*" >> "$HYPRPEACH_TEST_LOG"
case "${1:-}" in
  monitors)
    if [[ -f $HOME/monitors.json ]]; then cat "$HOME/monitors.json"; else
    echo '[{"name":"DP-5","x":0,"y":0,"description":"Example Panel Bottom 0001"},{"name":"DP-3","x":0,"y":-2160,"description":"Example Panel Top 0002"}]'; fi ;;
  configerrors) echo "" ;;
esac
FAKE
# animated-desktops' prepare builds with cargo. The fake makes the file cargo would make,
# so the rest of the step runs for real: the stamp, the install, the skip when
# nothing changed.
cat > "$FAKES/cargo" <<'FAKE'
#!/usr/bin/env bash
printf 'cargo %s\n' "$*" >> "$HYPRPEACH_TEST_LOG"
while (( $# )); do [[ $1 == --target-dir ]] && target=$2; shift; done
mkdir -p "$target/release" && printf '#!/bin/sh\n' > "$target/release/hyprpeach-animated-desktops" && chmod +x "$target/release/hyprpeach-animated-desktops"
FAKE
chmod +x "$FAKES"/*

export HYPRPEACH_TEST_LOG="$LOG"
# The XDG directories default to under HOME, which is the sandbox's; one set
# in the environment would point a command straight at the real machine.
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME
export PATH="$FAKES:$OMARCHY_BINARIES:$PATH"
git_quietly() { git -c user.name=test -c user.email=test@example.invalid -c advice.detachedHead=false "$@"; }

# A fresh HOME, with $HOME/.local/bin on PATH the way Omarchy puts it there.
use_home() {
  export HOME="$SANDBOX/$1"
  mkdir -p "$HOME/.config/hypr" "$HOME/.local/bin"
  printf '%s\n' '-- the user own config' 'hl.config({ general = { border_size = 2 } })' > "$HOME/.config/hypr/hyprland.lua"
  export PATH="$HOME/.local/bin:$FAKES:$OMARCHY_BINARIES:${PATH#*"$OMARCHY_BINARIES:"}"
}

use_home guard
for name in omarchy omarchy-shell hyprctl cargo; do
  [[ $(command -v "$name") == "$FAKES/$name" ]] || { echo "REFUSING TO RUN: $name resolves to $(command -v "$name"), not the fake"; exit 1; }
done
[[ $HOME == "$SANDBOX"/* ]] || { echo "REFUSING TO RUN: HOME is $HOME"; exit 1; }
[[ -z ${XDG_CONFIG_HOME:-} ]] || { echo "REFUSING TO RUN: XDG_CONFIG_HOME is $XDG_CONFIG_HOME"; exit 1; }

# ---------------------------------------------------------------- the remote

# The WORKING TREE, committed in a scratch clone -- not HEAD -- so the test runs
# what is about to be committed rather than what already was.
git_quietly clone --quiet "$REPOSITORY_ROOT" "$SANDBOX/work"
git -C "$SANDBOX/work" rm -rq --cached . >/dev/null
find "$SANDBOX/work" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
while IFS= read -r -d '' path; do
  [[ -e $REPOSITORY_ROOT/$path ]] && cp -a --parents "$path" "$SANDBOX/work/" 2>/dev/null
done < <(cd "$REPOSITORY_ROOT" && git ls-files -z --cached --others --exclude-standard)
git -C "$SANDBOX/work" add -A
git_quietly -C "$SANDBOX/work" commit --quiet --allow-empty -m "the working tree"
# Newer than any real release, so a 1.x `hyprpeach upgrade` chooses it.
git_quietly -C "$SANDBOX/work" tag -a v999.0.0 -m v999.0.0
git clone --quiet --bare "$SANDBOX/work" "$SANDBOX/upstream.git"
UPSTREAM="$SANDBOX/upstream.git"
UPSTREAM_HEAD=$(git -C "$UPSTREAM" rev-parse HEAD)

plugins_directory() { echo "$HOME/.config/omarchy/plugins"; }
blocks() { grep -cF -- '-- >>> hyprpeach >>>' "$HOME/.config/hypr/hyprland.lua"; }
called() { grep -cxF -- "$1" "$LOG"; }
link_of() { readlink "$(plugins_directory)/$1"; }
# Not `grep -q`: it stops reading at the first match, the list takes a SIGPIPE
# on its next row, and pipefail reports the pipeline failed -- for every row
# but the last.
listed() { hyprpeach plugin list 2>&1 | grep -E "^  $1 +$2 +[0-9.]+ +$3" >/dev/null && echo yes || echo no; }

echo "hyprpeach install"

# ---------------------------------------------------------------- 1.x → 2

echo
echo "a 1.x machine runs 'hyprpeach upgrade' and arrives on the collection, desktops added"
use_home first-generation
# Exactly what 1.x left: the library clone at its release, the command COPIED
# onto PATH, a block in hyprland.lua loading the library from that clone, and
# the whole repository cloned as the bar strip's plugin, hyprpeach.desktops.
# That clone is in the state the machine this was written on was really found
# in -- a commit the remote never had, an origin that no longer exists -- with
# a dev-ports link into it from a pre-release 2.
git clone --quiet "$UPSTREAM" "$HOME/.config/hypr/hyprpeach"
git_quietly -C "$HOME/.config/hypr/hyprpeach" checkout --quiet --detach v1.3.0
git -C "$UPSTREAM" show v1.3.0:bin/hyprpeach > "$HOME/.local/bin/hyprpeach"
chmod +x "$HOME/.local/bin/hyprpeach"
cat >> "$HOME/.config/hypr/hyprland.lua" <<'LUA'

-- >>> hyprpeach >>>
-- Hyprland's Lua path looks for name.lua, not name/init.lua.
package.path = os.getenv("HOME") .. "/.config/hypr/?/init.lua;" .. package.path
require("hyprpeach").setup({
  monitors_bottom_to_top = {
    "desc:Example Panel Bottom 0001",
  },
})
-- <<< hyprpeach <<<

-- >>> hyprpeach >>>
-- A second copy, as 1.0.0's installer left on every re-run.
-- <<< hyprpeach <<<
LUA
git clone --quiet "$UPSTREAM" "$SANDBOX/vanished"
git_quietly -C "$SANDBOX/vanished" reset --quiet --hard v1.3.0
git_quietly -C "$SANDBOX/vanished" commit --quiet --allow-empty -m "a commit the remote never had"
mkdir -p "$(plugins_directory)"
git clone --quiet "$SANDBOX/vanished" "$(plugins_directory)/hyprpeach.desktops"
rm -rf "$SANDBOX/vanished"
ln -s hyprpeach.desktops/plugins/dev-ports "$(plugins_directory)/hyprpeach.dev-ports"
: > "$LOG"

HYPRPEACH_REPOSITORY="$UPSTREAM" hyprpeach upgrade > "$SANDBOX/upgrade.out" 2>&1
check "the 1.x upgrade succeeds" "$?" "0"
PLUGIN="$(plugins_directory)/hyprpeach"
check "the 1.x strip clone is retired through Omarchy" "$(called 'omarchy plugin remove hyprpeach.desktops --yes')" "1"
check "hyprpeach is cloned from the repository" "$(git -C "$PLUGIN" remote get-url origin)" "$UPSTREAM"
check "on the remote's newest commit" "$(git -C "$PLUGIN" rev-parse HEAD)" "$UPSTREAM_HEAD"
check "and enabled, so its service keeps the command on PATH" "$(called 'omarchy plugin enable hyprpeach')" "1"
check "desktops is added, as a link into the collection" "$(link_of hyprpeach.desktops)" "hyprpeach/plugins/desktops"
check "hyprpeach on PATH is now a link into the plugin" "$(readlink -f "$HOME/.local/bin/hyprpeach")" "$(readlink -f "$PLUGIN")/bin/hyprpeach"
check "exactly one hyprpeach block, however many 1.x left" "$(blocks)" "1"
grep -qF '/.config/omarchy/plugins/hyprpeach/init.lua' "$HOME/.config/hypr/hyprland.lua"
check "the block loads the library from the plugin" "$?" "0"
grep -qF '/.config/hypr/?/init.lua' "$HOME/.config/hypr/hyprland.lua"
check "and no longer from the 1.x clone" "$?" "1"
grep -qF '"desc:Example Panel Top 0002",' "$HOME/.config/hypr/hyprland.lua"
check "the block names the monitors Hyprland reports" "$?" "0"
grep -q "the user own config" "$HOME/.config/hypr/hyprland.lua"
check "the config it was written into survives" "$?" "0"
check "Omarchy's workspaces widget is disabled" "$(called 'omarchy plugin disable omarchy.workspaces')" "1"
check "Omarchy's menu widget is disabled" "$(called 'omarchy plugin disable omarchy.menu')" "1"
check "the bar goes to the left" "$(called 'omarchy bar position left')" "1"
check "Hyprland is reloaded" "$(called 'hyprctl reload')" "1"
grep -qF "rm -rf $HOME/.config/hypr/hyprpeach" "$SANDBOX/upgrade.out"
check "it says the 1.x clone can go, and does not remove it" "$?$([[ -d $HOME/.config/hypr/hyprpeach ]] && echo kept)" "0kept"
check "a plugin linked into the retired clone is listed as broken" "$(listed ❔ dev-ports 'a broken link')" "yes"
hyprpeach plugin add dev-ports >/dev/null 2>&1
check "and adding it again repairs it" "$(link_of hyprpeach.dev-ports)" "hyprpeach/plugins/dev-ports"

echo
echo "adding desktops again re-reads the monitors and changes nothing else"
cp "$HOME/.config/hypr/hyprland.lua" "$SANDBOX/entry.before"
hyprpeach plugin add desktops > "$SANDBOX/again.out" 2>&1
check "adding it again succeeds" "$?" "0"
grep -q "already added" "$SANDBOX/again.out"
check "and says it already was" "$?" "0"
diff -q "$SANDBOX/entry.before" "$HOME/.config/hypr/hyprland.lua" >/dev/null
check "and leaves hyprland.lua byte for byte" "$?" "0"

echo
echo "the block loads the library once, whoever loads it first"
# Stands in for a config that required the library before this block ran. The
# block must hand setup() that same copy -- and must not dofile a second one,
# which here would fail loudly, because this HOME has no plugin.
sed -n '/^-- >>> hyprpeach >>>$/,/^-- <<< hyprpeach <<<$/p' "$HOME/.config/hypr/hyprland.lua" > "$SANDBOX/block.lua"
cat > "$SANDBOX/runner.lua" <<'LUA'
local calls = 0
package.loaded.hyprpeach = { setup = function() calls = calls + 1 end }
dofile(arg[1])
io.write(calls)
LUA
HOME="$SANDBOX/nowhere" lua "$SANDBOX/runner.lua" "$SANDBOX/block.lua" > "$SANDBOX/lua.out" 2>&1 </dev/null
check "an already-loaded hyprpeach is the one set up" "$(cat "$SANDBOX/lua.out")" "1"

# ---------------------------------------------------------------- registry install

echo
echo "installed from Omarchy, hyprpeach adds nothing until asked"
use_home registry
: > "$LOG"
omarchy plugin add "$UPSTREAM" --yes >/dev/null 2>&1
check "omarchy plugin add accepts the repository, plugins folder and all" "$?" "0"
PLUGIN="$(plugins_directory)/hyprpeach"
omarchy plugin enable hyprpeach >/dev/null
# What the service runs when the shell loads it.
"$PLUGIN/bin/hyprpeach" link-command >/dev/null 2>&1
check "the service puts hyprpeach on PATH" "$(readlink -f "$HOME/.local/bin/hyprpeach")" "$(readlink -f "$PLUGIN")/bin/hyprpeach"
check "desktops is not added" "$(listed 🌱 desktops 'not added')" "yes"
check "dev-ports is not added" "$(listed 🌱 dev-ports 'not added')" "yes"
check "and Hyprland's config is untouched" "$(blocks)" "0"

echo
echo "plugins come and go at will: 0, 1, 2, 1, 0, 1"
: > "$LOG"
hyprpeach plugin add dev-ports >/dev/null 2>&1
check "dev-ports alone is added" "$(link_of hyprpeach.dev-ports)" "hyprpeach/plugins/dev-ports"
check "it is enabled in its manifest's own section" "$(called 'omarchy plugin enable hyprpeach.dev-ports')" "1"
check "the shell is asked to rescan" "$(called 'omarchy-shell shell rescanPlugins')" "1"
omarchy-plugin-catalog | jq -e 'any(.[]; .id == "hyprpeach.dev-ports")' >/dev/null
check "Omarchy's own catalog finds it through the link" "$?" "0"
check "and Hyprland's config is still untouched" "$(blocks)" "0"
hyprpeach plugin add dev-ports >/dev/null 2>&1
check "adding it again does not enable it a second time" "$(called 'omarchy plugin enable hyprpeach.dev-ports')" "1"
hyprpeach plugin add desktops >/dev/null 2>&1
check "desktops is added beside it" "$(listed 🍑 desktops added)" "yes"
check "and writes exactly one block" "$(blocks)" "1"
hyprpeach plugin remove desktops > "$SANDBOX/remove.out" 2>&1
check "desktops is removed" "$?$(link_of hyprpeach.desktops)" "0"
check "its block is gone from hyprland.lua" "$(blocks)" "0"
grep -q "the user own config" "$HOME/.config/hypr/hyprland.lua"
check "and the rest of hyprland.lua is still there" "$?" "0"
check "Omarchy's workspaces widget is put back" "$(called 'omarchy plugin enable omarchy.workspaces')" "1"
check "and its menu, where Omarchy ships it" "$(called 'omarchy plugin enable omarchy.menu --section left')" "1"
check "dev-ports stays added" "$(listed 🍑 dev-ports added)" "yes"
check "the plugin inside the clone is untouched" "$([[ -f $PLUGIN/plugins/desktops/Desktops.qml ]] && echo there || echo gone)" "there"
hyprpeach plugin remove dev-ports >/dev/null 2>&1
check "with both removed, neither is listed as added" "$(listed 🌱 desktops 'not added')$(listed 🌱 dev-ports 'not added')" "yesyes"
check "and the clone is still clean" "$(git -C "$PLUGIN" status --porcelain | wc -l)" "0"
hyprpeach plugin add desktops >/dev/null 2>&1
check "desktops comes back" "$(link_of hyprpeach.desktops)$(blocks)" "hyprpeach/plugins/desktops1"

echo
echo "three monitors side by side: the laptop first, then the rest left to right"
# A laptop docked between two screens and centred on them, listed in the order
# Hyprland happened to give -- right Dell first -- to show the order written does
# not depend on it.
cat > "$HOME/monitors.json" <<'JSON'
[{"name":"DP-1","x":5760,"y":0,"description":"Example Dell Right"},
 {"name":"eDP-1","x":3840,"y":480,"description":"Example Laptop"},
 {"name":"DP-2","x":0,"y":0,"description":"Example Dell Left"}]
JSON
hyprpeach plugin add desktops >/dev/null 2>&1
check "the monitors are written laptop, left, right" "$(grep -o 'Example [A-Za-z ]*' "$HOME/.config/hypr/hyprland.lua" | tr '\n' ',')" "Example Laptop,Example Dell Left,Example Dell Right,"
rm "$HOME/monitors.json"
hyprpeach plugin add desktops >/dev/null 2>&1

echo
echo "a plugin that needs another is refused without it, and holds on to it"
# overview's manifest says it requires desktops: it switches desktops through
# the library desktops puts in Hyprland, and without it every click is a no-op.
hyprpeach plugin remove desktops >/dev/null 2>&1
hyprpeach plugin add overview > "$SANDBOX/requires.out" 2>&1
check "overview without desktops is refused" "$?" "1"
grep -q "hyprpeach plugin add desktops" "$SANDBOX/requires.out"
check "and the refusal says what to add first" "$?" "0"
check "nothing was linked" "$([[ -L $(plugins_directory)/hyprpeach.overview ]] && echo linked || echo none)" "none"
hyprpeach plugin add desktops >/dev/null 2>&1
hyprpeach plugin add overview >/dev/null 2>&1
check "with desktops added, overview is" "$(link_of hyprpeach.overview)" "hyprpeach/plugins/overview"
hyprpeach plugin remove desktops > "$SANDBOX/requires.out" 2>&1
check "desktops cannot be removed out from under it" "$?" "1"
grep -q "hyprpeach plugin remove overview" "$SANDBOX/requires.out"
check "and the refusal says what to remove first" "$?" "0"
check "desktops is still added" "$(link_of hyprpeach.desktops)$(blocks)" "hyprpeach/plugins/desktops1"
hyprpeach plugin remove overview >/dev/null 2>&1
check "overview comes off on its own" "$([[ -L $(plugins_directory)/hyprpeach.overview ]] && echo linked || echo none)" "none"

echo
echo "a plugin that builds is prepared before it is linked, and only when stale"
: > "$LOG"
# What an earlier build left: the planet scene's NASA imagery.
mkdir -p "$HOME/.local/share/hyprpeach/animated-desktops/assets" && echo map > "$HOME/.local/share/hyprpeach/animated-desktops/assets/day.jpg"
hyprpeach plugin add animated-desktops > "$SANDBOX/animated-desktops.out" 2>&1
check "adding animated-desktops succeeds" "$?" "0"
check "it is linked" "$(link_of hyprpeach.animated-desktops)" "hyprpeach/plugins/animated-desktops"
check "its renderer was built once" "$(grep -c '^cargo build' "$LOG")" "1"
check "  ...and installed where its service runs it" "$([[ -x $HOME/.local/share/hyprpeach/animated-desktops/hyprpeach-animated-desktops ]] && echo yes)" "yes"
check "an earlier build's planet imagery is cleared away" "$([[ -e $HOME/.local/share/hyprpeach/animated-desktops/assets ]] && echo left || echo gone)" "gone"
: > "$LOG"
"$PLUGIN/plugins/animated-desktops/prepare" --if-stale
check "starting again with nothing changed builds nothing" "$(grep -c '^cargo' "$LOG")" "0"
echo "// changed" >> "$SANDBOX/work/plugins/animated-desktops/renderer/src/main.rs"
git_quietly -C "$SANDBOX/work" commit --quiet -am "the renderer changed"
git -C "$SANDBOX/work" push --quiet "$UPSTREAM" "HEAD:$(git -C "$UPSTREAM" symbolic-ref --short HEAD)"
omarchy plugin update hyprpeach --yes >/dev/null 2>&1
"$PLUGIN/plugins/animated-desktops/prepare" --if-stale >/dev/null 2>&1
check "after an update changes the renderer, it is rebuilt" "$(grep -c '^cargo build' "$LOG")" "1"

echo
echo "animated-desktops settings are the schema's choices, written to one file"
SETTINGS="$HOME/.config/hyprpeach/animated-desktops.json"
check "with no file, the default speed is in effect" "$(hyprpeach speed | grep -c 'quick  (in effect)')" "1"
hyprpeach speed snappy >/dev/null 2>&1
check "a speed is written to the settings file" "$(jq -r .speed "$SETTINGS")" "snappy"
check "  ...pointing an editor at its schema" "$(jq -r '."$schema"' "$SETTINGS")" "$PLUGIN/plugins/animated-desktops/settings.schema.json"
hyprpeach speed warp > "$SANDBOX/speed.out" 2>&1
check "a speed the schema does not offer is refused" "$?" "1"
check "  ...and the file is left as it was" "$(jq -r .speed "$SETTINGS")" "snappy"
hyprpeach scene nebula >/dev/null 2>&1
check "a scene is written beside the speed, not over it" "$(jq -r '.scene + " " + .speed' "$SETTINGS")" "nebula snappy"
check "the scene list marks the one in effect" "$(hyprpeach scene | grep -c 'nebula  (in effect)')" "1"

hyprpeach plugin remove animated-desktops >/dev/null 2>&1
check "animated-desktops comes off" "$([[ -L $(plugins_directory)/hyprpeach.animated-desktops ]] && echo linked || echo none)" "none"

echo
echo "one Omarchy update moves the plugins with it"
# Nothing of a plugin's is fetched or copied: the collection moves, and the link
# already points at where it moved.
hyprpeach plugin add dev-ports >/dev/null 2>&1
BRANCH=$(git -C "$UPSTREAM" symbolic-ref --short HEAD)
jq '.version = "9.9.9"' "$SANDBOX/work/plugins/dev-ports/manifest.json" > "$SANDBOX/manifest.json"
mv "$SANDBOX/manifest.json" "$SANDBOX/work/plugins/dev-ports/manifest.json"
git_quietly -C "$SANDBOX/work" commit --quiet -am "dev-ports 9.9.9"
git -C "$SANDBOX/work" push --quiet "$UPSTREAM" "HEAD:$BRANCH"
omarchy plugin update hyprpeach --yes >/dev/null 2>&1
check "Omarchy's update succeeds, and validates the clone with plugins inside it" "$?" "0"
check "the added plugin is the new version" "$(jq -r .version "$(plugins_directory)/hyprpeach.dev-ports/manifest.json")" "9.9.9"

echo
echo "install.sh re-points a clone whose origin is somewhere stale"
# The other half of the vanished origin above. A remote that EXISTS but is
# behind -- an old mirror, a fork -- fails nothing: Omarchy's update fetches it,
# finds nothing new, and reports the plugin up to date on code the repository
# moved past.
git clone --quiet --bare "$UPSTREAM" "$SANDBOX/stale-mirror.git"
git -C "$SANDBOX/stale-mirror.git" update-ref "refs/heads/$BRANCH" "$UPSTREAM_HEAD"
git -C "$PLUGIN" remote set-url origin "$SANDBOX/stale-mirror.git"
git -C "$PLUGIN" reset --quiet --hard "$UPSTREAM_HEAD"
HYPRPEACH_REPOSITORY="$UPSTREAM" bash "$REPOSITORY_ROOT/install.sh" >/dev/null 2>&1
check "install.sh succeeds" "$?" "0"
check "and hyprpeach is on the repository's newest commit, not the mirror's" "$(git -C "$PLUGIN" rev-parse HEAD)" "$(git -C "$UPSTREAM" rev-parse HEAD)"
check "without retiring a desktops that is already the 2.x link" "$(link_of hyprpeach.desktops)" "hyprpeach/plugins/desktops"

echo
echo "install.sh reinstalls a clone that cannot fast-forward"
# Diverged, not merely ahead: a clone AHEAD of the remote fast-forwards to
# itself and Omarchy calls that up to date.
git -C "$PLUGIN" reset --quiet --hard "$UPSTREAM_HEAD"
git_quietly -C "$PLUGIN" commit --quiet --allow-empty -m "a commit the remote never had"
: > "$LOG"
HYPRPEACH_REPOSITORY="$UPSTREAM" bash "$REPOSITORY_ROOT/install.sh" >/dev/null 2>&1
check "install.sh succeeds" "$?" "0"
check "hyprpeach was removed and added again through Omarchy" "$(called 'omarchy plugin remove hyprpeach --yes')$(called "omarchy plugin add $UPSTREAM --yes")" "11"
check "and is on the repository's newest commit" "$(git -C "$PLUGIN" rev-parse HEAD)" "$(git -C "$UPSTREAM" rev-parse HEAD)"
check "the plugins linked into it resolve again" "$(jq -r .id "$(plugins_directory)/hyprpeach.dev-ports/manifest.json")" "hyprpeach.dev-ports"

echo
echo "a copied plugin folder is replaced by the link, and kept"
rm "$(plugins_directory)/hyprpeach.dev-ports"
cp -r "$PLUGIN/plugins/dev-ports" "$(plugins_directory)/hyprpeach.dev-ports"
hyprpeach plugin add dev-ports >/dev/null 2>&1
check "adding over a copy succeeds" "$?" "0"
check "the copy became the link" "$(link_of hyprpeach.dev-ports)" "hyprpeach/plugins/dev-ports"
check "the copy is backed up, hidden from the shell's scan" "$(find "$(plugins_directory)" -maxdepth 1 -name '.hyprpeach.dev-ports.bak.*' | wc -l)" "1"

echo
echo "refusals"
hyprpeach plugin add nonexistent > "$SANDBOX/refusal.out" 2>&1
check "an unknown plugin is refused" "$?" "1"
grep -q "dev-ports" "$SANDBOX/refusal.out"
check "and the refusal names the ones there are" "$?" "0"
"$REPOSITORY_ROOT/bin/hyprpeach" plugin add dev-ports > "$SANDBOX/refusal.out" 2>&1
check "a checkout that is not the installed plugin is refused" "$?" "1"
grep -q "installed at" "$SANDBOX/refusal.out"
check "and says where the installed one is" "$?" "0"

echo
echo "the command on PATH is only ever replaced when it is hyprpeach's"
rm "$HOME/.local/bin/hyprpeach"
printf '#!/bin/sh\necho somebody else\n' > "$HOME/.local/bin/hyprpeach"
"$PLUGIN/bin/hyprpeach" link-command >/dev/null 2>&1
check "somebody else's hyprpeach is left alone" "$(tail -n 1 "$HOME/.local/bin/hyprpeach")" "echo somebody else"
rm "$HOME/.local/bin/hyprpeach"
ln -s "$SANDBOX/gone/bin/hyprpeach" "$HOME/.local/bin/hyprpeach"
"$PLUGIN/bin/hyprpeach" link-command >/dev/null 2>&1
check "a link that no longer resolves is replaced" "$(readlink -f "$HOME/.local/bin/hyprpeach")" "$(readlink -f "$PLUGIN")/bin/hyprpeach"

# ---------------------------------------------------------------- the machine

echo
echo "and the machine running this is exactly as it was"
check "the real HOME's plugins, command, config and clones are unchanged" "$(real_home_snapshot)" "$REAL_HOME_BEFORE"

echo
if (( failures == 0 )); then
  echo "PASS  $checks checks, 0 failed"
else
  echo "FAIL  $checks checks, $failures failed"
  exit 1
fi
