#!/usr/bin/env bash
# Runs install.sh and bin/hyprpeach against a sandbox: a bare clone of this
# repository standing in for the remote, a throwaway hyprland.lua, and a
# throwaway PATH directory. Nothing here touches the machine it runs on.
#
# WHY THIS EXISTS. The installer is also the upgrade path, so every step in it
# has to survive a second run -- and the ways it failed to were all invisible
# by reading. The marker grep matched nothing because the marker starts with
# `--` and grep read it as a flag, so the replace branch was dead and every
# re-run appended another setup() block. `fetch --tags` aborted the whole run
# on a re-pointed tag. `plugin add` silently did nothing on an existing
# install, so the bar strip never moved. Each one is a case below.
#
# Run: bash tests/install.test.sh

set -uo pipefail
cd "$(dirname "$0")/.."
REPOSITORY_ROOT=$PWD

failures=0
checks=0

check() {
  checks=$((checks + 1))
  if [[ $2 != "$3" ]]; then
    failures=$((failures + 1))
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$3" "$2"
  fi
}

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

git clone --quiet --bare "$REPOSITORY_ROOT" "$SANDBOX/upstream.git"
printf '%s\n' '-- the user own config' 'hl.config({ general = { border_size = 2 } })' > "$SANDBOX/hyprland.lua"

export HYPRPEACH_REPOSITORY="$SANDBOX/upstream.git"
export HYPRPEACH_CLONE="$SANDBOX/clone"
export HYPRPEACH_ENTRY="$SANDBOX/hyprland.lua"
export HYPRPEACH_BINARY_DIRECTORY="$SANDBOX/bin"

# The newest release the sandbox remote offers, which is whatever this working
# copy is tagged at. Named rather than hardcoded so the test does not have to
# be edited every release.
NEWEST=$(git -C "$SANDBOX/upstream.git" tag --list | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
PREVIOUS=$(git -C "$SANDBOX/upstream.git" tag --list | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 2 | head -n 1)

install_at() { HYPRPEACH_TAG="$1" ./install.sh >/dev/null 2>&1; }
blocks() { grep -cF -- '-- >>> hyprpeach >>>' "$SANDBOX/hyprland.lua"; }

echo "hyprpeach install"

echo
echo "running it twice leaves one block, not two"
install_at "$PREVIOUS"
check "a first install succeeds" "$?" "0"
install_at "$NEWEST"
check "a second run succeeds" "$?" "0"
install_at "$NEWEST"
check "a third run succeeds" "$?" "0"
# The marker starts with `--`; an unguarded grep reads it as a flag, matches
# nothing, and the block is appended again instead of replaced.
check "exactly one hyprpeach block" "$(blocks)" "1"
cp "$SANDBOX/hyprland.lua" "$SANDBOX/entry.before"
install_at "$NEWEST"
diff -q "$SANDBOX/entry.before" "$SANDBOX/hyprland.lua" >/dev/null
check "and a further run changes nothing at all" "$?" "0"
grep -q "the user own config" "$SANDBOX/hyprland.lua"
check "the config it was appended to survives" "$?" "0"

echo
echo "the command lands on PATH and answers"
check "hyprpeach is installed and executable" "$([[ -x $SANDBOX/bin/hyprpeach ]] && echo yes || echo no)" "yes"
"$SANDBOX/bin/hyprpeach" upgrade 2>&1 | grep -q "nothing to do"
check "upgrade is a no-op when already current" "$?" "0"
"$SANDBOX/bin/hyprpeach" version 2>&1 | grep -q "$NEWEST"
check "version names the installed release" "$?" "0"

echo
echo "an upgrade survives what a real clone has been through"
# A tag re-pointed upstream fails a plain `fetch --tags` with "would clobber
# existing tag", and under `set -e` that ends the run. Measured on a real desk.
git -C "$SANDBOX/clone" tag -f "$PREVIOUS" HEAD >/dev/null 2>&1
install_at "$NEWEST"
check "a re-pointed tag does not abort the run" "$?" "0"

echo
echo "it refuses rather than destroys"
echo '-- precious' >> "$SANDBOX/clone/init.lua"
install_at "$NEWEST"
check "a clone with local edits is refused" "$?" "1"
grep -q '^-- precious' "$SANDBOX/clone/init.lua"
check "  ...and the edit is still there" "$?" "0"
git -C "$SANDBOX/clone" checkout --quiet -- init.lua

# With only an opening marker the rewrite would treat the rest of the file as
# the block and delete it.
sed -i '/-- <<< hyprpeach <<</d' "$SANDBOX/hyprland.lua"
install_at "$NEWEST"
check "a half-written block is refused" "$?" "1"
grep -q "the user own config" "$SANDBOX/hyprland.lua"
check "  ...and the file is intact" "$?" "0"

echo
echo "a repository with no releases is reported, not fatal"
# grep matching nothing exits non-zero, pipefail promotes it, and `set -e` used
# to take the command down before it printed anything at all.
# A remote that genuinely has no releases, and a clone of it -- not the
# sandbox remote above, which has plenty.
git init --quiet --bare "$SANDBOX/tagless.git"
git init --quiet -b main "$SANDBOX/tagless"
: > "$SANDBOX/tagless/file"
git -C "$SANDBOX/tagless" add file
git -C "$SANDBOX/tagless" -c user.email=t@t -c user.name=t commit --quiet -m "no releases here"
git -C "$SANDBOX/tagless" remote add origin "$SANDBOX/tagless.git"
git -C "$SANDBOX/tagless" push --quiet origin main
HYPRPEACH_CLONE=$SANDBOX/tagless HYPRPEACH_REPOSITORY=$SANDBOX/tagless.git \
  "$SANDBOX/bin/hyprpeach" version >"$SANDBOX/no-releases.out" 2>&1
check "version exits cleanly with no releases" "$?" "0"
grep -q "no releases found\|could not reach" "$SANDBOX/no-releases.out"
check "  ...and says so" "$?" "0"
grep -qi "fatal:" "$SANDBOX/no-releases.out"
check "  ...without leaking git's own errors" "$?" "1"

echo
if [[ $failures -eq 0 ]]; then
  printf 'PASS  %d checks, 0 failed\n' "$checks"
else
  printf 'FAIL  %d checks, %d failed\n' "$checks" "$failures"
fi
exit $((failures == 0 ? 0 : 1))
