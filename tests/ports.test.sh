#!/usr/bin/env bash
# Runs plugins/ports/listening-ports against a sandbox: a fake `ss` earlier on PATH
# feeding it captured output, and, for the signal half, a listener this test
# starts and is the only thing that ever signals. Nothing here touches a process
# it did not create.
#
# WHY THIS EXISTS. Everything in that script is wrong QUIETLY.
#
# The socket lines are fed to it by a program it does not control, and the field
# it most needs is the one `ss` will not escape: the process name is the kernel's
# 15-character `comm`, printed inside quotes with whatever punctuation happened
# to be in it. The line that broke the first parser was real, off this desk, and
# it was the line for the dev server the whole widget exists to find:
#
#     users:(("next-server (v1",pid=2388920,fd=22))
#
# A parser that splits on parentheses reads that as a row with no pid — the panel
# shows the port, greys the stop button out, and looks like it is working.
#
# The fold is the same shape of failure the other way: 23 of this desk's 33
# listening ports were ephemeral, so a range read wrongly either buries the one
# row anybody wanted or hides it.
#
# And `signal` has to refuse. A pid that has been recycled since the panel drew
# it is a different process with the same number, and killing it succeeds.
#
# Run: bash tests/ports.test.sh

set -uo pipefail
cd "$(dirname "$0")/.."
REPOSITORY_ROOT=$PWD
READER="$REPOSITORY_ROOT/plugins/ports/listening-ports"

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
mkdir -p "$SANDBOX/bin"

# The fake `ss`. It answers the tcp query from one fixture and the udp query from
# another, chosen the way the real one does — by which flag it was passed.
cat > "$SANDBOX/bin/ss" <<'FAKE'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in
  --tcp) cat "$SS_FIXTURE_TCP"; exit 0 ;;
  --udp) cat "$SS_FIXTURE_UDP"; exit 0 ;;
  esac
done
exit 0
FAKE
chmod 755 "$SANDBOX/bin/ss"
export PATH="$SANDBOX/bin:$PATH"

# Captured verbatim from `ss --tcp --listening --numeric --processes --extended
# --no-header` on the desk this was written on, trimmed to the interesting rows.
# Do not tidy these lines. Every oddity in them is a case:
#
#   next-server (v1   a space and an unmatched `(` inside the quoted comm
#   :53 with uid:974  another user's socket -- port visible, pid not
#   :22 with no uid:  root's socket, because the kernel omits uid for 0
#   :3002 twice       one process holding one port on two addresses
#   43117             inside the ephemeral range
cat > "$SANDBOX/tcp.fixture" <<'FIXTURE'
LISTEN 0      511    127.0.0.1:3002 0.0.0.0:* users:(("next-server (v1",pid=2388920,fd=22)) uid:1000 ino:85206391 sk:104d cgroup:/user.slice/user-1000.slice/user@1000.service/app.slice/app-Hyprland-xdg\x2dterminal\x2dexec-c6b058d8.scope <->
LISTEN 0      511            *:3002 *:*       users:(("next-server (v1",pid=2388920,fd=23)) uid:1000 ino:85206392 sk:104e cgroup:/user.slice/user-1000.slice/user@1000.service/app.slice/app-Hyprland-xdg\x2dterminal\x2dexec-c6b058d8.scope <->
LISTEN 0      4096  127.0.0.54:53   0.0.0.0:* uid:974 ino:27809 sk:1001 cgroup:/system.slice/systemd-resolved.service <->
LISTEN 0      128      0.0.0.0:22   0.0.0.0:* ino:1088644 sk:6001 cgroup:/system.slice/sshd.service <->
LISTEN 0      128    127.0.0.1:43117 0.0.0.0:* users:(("python3",pid=999001,fd=3)) uid:1000 ino:9 sk:9 cgroup:/user.slice/user-1000.slice <->
LISTEN 0      4096       [::1]:631  [::]:*    ino:35013 sk:1005 cgroup:/system.slice/system-cups.slice/cups.service <->
FIXTURE

cat > "$SANDBOX/udp.fixture" <<'FIXTURE'
UNCONN 0 0    0.0.0.0:5353 0.0.0.0:* ino:5 sk:5 cgroup:/system.slice/avahi-daemon.service <->
UNCONN 0 0 224.0.0.251:5353 0.0.0.0:* users:(("chrome",pid=999002,fd=81)) uid:1000 ino:6 sk:6 cgroup:/user.slice/user-1000.slice <->
FIXTURE

export SS_FIXTURE_TCP="$SANDBOX/tcp.fixture"
export SS_FIXTURE_UDP="$SANDBOX/udp.fixture"

read_fixture() { "$READER" list; }
field() { read_fixture | jq -r "$1"; }

# `refusal <args...>` captures what the script SAID, separately from what it
# EXITED with.
#
# The obvious `"$READER" signal ... 2>&1 | grep -q ...` cannot express this
# under `set -o pipefail`: the refusal exits non-zero on purpose, pipefail
# promotes that over grep's verdict, and the check fails on a message that
# matched perfectly. Three of these read green for the wrong reason before this
# existed.
refusal() { "$READER" "$@" 2>&1; }

echo "hyprpeach ports"

echo
echo 'it reads the socket list `ss` actually prints'
read_fixture > "$SANDBOX/out.json"
jq -e . "$SANDBOX/out.json" >/dev/null 2>&1
check "the output is JSON" "$?" "0"
# Six tcp rows collapse to five records (3002 appears twice for one pid) plus
# two udp rows.
check "one record per protocol+port+pid" "$(field '.records | length')" "7"

echo
echo "a comm with a space and an unmatched paren in it still carries its pid"
# `ss` truncates comm at 15 characters and escapes nothing, so the name for
# "next-server (v15.2.4)" arrives as `next-server (v1`. A parser that splits on
# punctuation loses the pid here and the panel silently cannot stop it.
check "the name survives verbatim" \
  "$(field '.records[] | select(.port==3002) | .processName')" "next-server (v1"
check "  ...and so does the pid" \
  "$(field '.records[] | select(.port==3002) | .processId | tostring')" "2388920"
check "  ...so the row is stoppable" \
  "$(field '.records[] | select(.port==3002) | .isStoppable | tostring')" "true"

echo
echo "one process on one port at two addresses is one row, at the wider address"
# Whether the port answers from the network is the one fact about it that can
# hurt you, so a `*` row must win over a `127.0.0.1` row for the same pid.
check "3002 appears once" "$(field '[.records[] | select(.port==3002)] | length')" "1"
check "  ...bound to the wider address" \
  "$(field '.records[] | select(.port==3002) | .address')" "*"
check "  ...and reported as network-reachable" \
  "$(field '.records[] | select(.port==3002) | .isNetworkReachable | tostring')" "true"

echo
echo "a port whose pid is hidden is still named, and is never offered for killing"
# Without root the kernel prints no users:(...) for another user's socket. The
# cgroup is what keeps the row meaningful; `isStoppable` false is what keeps it
# honest.
check "sshd's port has no pid" "$(field '.records[] | select(.port==22) | .processId | tostring')" "0"
check "  ...but is named by its unit" "$(field '.records[] | select(.port==22) | .unitName')" "sshd.service"
check "  ...and cannot be stopped" "$(field '.records[] | select(.port==22) | .isStoppable | tostring')" "false"
# uid: absent means root, because the kernel omits the field for uid 0.
check "  ...and belongs to root" "$(field '.records[] | select(.port==22) | .ownerUserId | tostring')" "0"
check "another user's resolver is attributed too" \
  "$(field '.records[] | select(.port==53) | .unitName')" "systemd-resolved.service"
check "  ...and is not stoppable either" \
  "$(field '.records[] | select(.port==53) | .isStoppable | tostring')" "false"
# A user-slice cgroup ends in a scope naming the terminal it was launched from,
# which tells nobody anything; only a *.service is kept.
check "a user scope is not mistaken for a unit" \
  "$(field '.records[] | select(.port==3002) | .unitName')" ""

echo
echo "/etc/services is believed below 1024 and nowhere above it"
# Trusting the whole file labelled this desk's Next.js server `exlm-agent`, which
# is an IANA registration and not what is running. A confidently wrong name is
# worse than a blank one.
check "22 reads as ssh" "$(field '.records[] | select(.port==22) | .portName')" "ssh"
check "631 reads as ipp" "$(field '.records[] | select(.port==631) | .portName')" "ipp"
check "3002 reads as nothing" "$(field '.records[] | select(.port==3002) | .portName')" ""

echo
echo "the ephemeral range is read off the kernel, not assumed"
LOW=$(cut -f1 /proc/sys/net/ipv4/ip_local_port_range)
check "43117 is inside this kernel's range" \
  "$(field '.records[] | select(.port==43117) | .isEphemeral | tostring')" \
  "$([[ 43117 -ge $LOW ]] && echo true || echo false)"
check "3002 is not" "$(field '.records[] | select(.port==3002) | .isEphemeral | tostring')" "false"

echo
echo "udp is read as well as tcp, and the two do not collide"
check "both protocols are present" \
  "$(field '[.records[] | .protocol] | unique | join(",")')" "tcp,udp"
check "5353 has a listed and an unlisted owner" \
  "$(field '[.records[] | select(.port==5353)] | length')" "2"

echo
echo "a dev server is placed in the checkout it is running from"
# THE FACT A DEVELOPER OPENS THIS FOR. "workerd on 8797" does not say which of
# five worktrees left it running; the branch does. So this builds a real
# repository, a real linked worktree beside it, and parks real processes inside
# each -- the reader finds them through /proc/<pid>/cwd exactly as it finds a
# dev server, and nothing about the lookup is stubbed.
REPOSITORY="$SANDBOX/source/acme"
WORKTREE="$SANDBOX/worktrees/acme/login-form"
git init --quiet -b main "$REPOSITORY"
git -C "$REPOSITORY" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m init
git -C "$REPOSITORY" worktree add --quiet -b acme/login-form "$WORKTREE" main
mkdir -p "$WORKTREE/web" "$SANDBOX/not-a-repository"

# Output goes nowhere, or the backgrounded sleep keeps the `$(...)` capturing
# its pid open, the substitution waits the full 30 seconds for it -- and the
# reader then looks up a process that has already exited.
park() { ( cd "$1" && exec sleep 30 ) >/dev/null 2>&1 & echo $!; }
IN_WORKTREE=$(park "$WORKTREE/web")
IN_CHECKOUT=$(park "$REPOSITORY")
OUTSIDE=$(park "$SANDBOX/not-a-repository")
for pid in "$IN_WORKTREE" "$IN_CHECKOUT" "$OUTSIDE"; do
  for _ in $(seq 1 50); do [[ -e /proc/$pid/cwd ]] && break; sleep 0.05; done
done

OWN_USER_ID=$(id -u)
cat > "$SANDBOX/dev.fixture" <<FIXTURE
LISTEN 0 511 127.0.0.1:4100 0.0.0.0:* users:(("sleep",pid=$IN_WORKTREE,fd=3)) uid:$OWN_USER_ID ino:1 sk:1 cgroup:/user.slice <->
LISTEN 0 511 127.0.0.1:4200 0.0.0.0:* users:(("sleep",pid=$IN_CHECKOUT,fd=3)) uid:$OWN_USER_ID ino:2 sk:2 cgroup:/user.slice <->
LISTEN 0 511 127.0.0.1:4300 0.0.0.0:* users:(("sleep",pid=$OUTSIDE,fd=3)) uid:$OWN_USER_ID ino:3 sk:3 cgroup:/user.slice <->
FIXTURE
: > "$SANDBOX/empty.fixture"
dev_field() { SS_FIXTURE_TCP="$SANDBOX/dev.fixture" SS_FIXTURE_UDP="$SANDBOX/empty.fixture" "$READER" list | jq -r "$1"; }

check "a process in a worktree names the repository" \
  "$(dev_field '.records[] | select(.port==4100) | .repositoryName')" "acme"
check "  ...the worktree" "$(dev_field '.records[] | select(.port==4100) | .worktreeName')" "login-form"
check "  ...the branch" "$(dev_field '.records[] | select(.port==4100) | .branchName')" "acme/login-form"
check "  ...and where in the tree it runs" "$(dev_field '.records[] | select(.port==4100) | .projectPath')" "web"
# The repository is named by where its objects live. Named by the checkout
# instead, a worktree's repository came out as "login-form".
check "a plain checkout names the repository too" \
  "$(dev_field '.records[] | select(.port==4200) | .repositoryName')" "acme"
check "  ...with no worktree" "$(dev_field '.records[] | select(.port==4200) | .worktreeName')" ""
check "  ...on its own branch" "$(dev_field '.records[] | select(.port==4200) | .branchName')" "main"
check "  ...at the top of the tree" "$(dev_field '.records[] | select(.port==4200) | .projectPath')" ""
check "a process outside any checkout is not a dev server" \
  "$(dev_field '.records[] | select(.port==4300) | .repositoryName')" ""
kill "$IN_WORKTREE" "$IN_CHECKOUT" "$OUTSIDE" 2>/dev/null
wait "$IN_WORKTREE" "$IN_CHECKOUT" "$OUTSIDE" 2>/dev/null

echo
echo "the panel draws dev ports, one per line, and nothing else"
# The first version listed every socket and said 17 on a desk running four
# servers, with the one anybody wanted between cups and Discord. Model.js is
# where that is decided, and it is plain JavaScript, so it runs here without a
# compositor. Skipped, loudly, where there is no node to run it.
if command -v node >/dev/null; then
  cat > "$SANDBOX/model.json" <<'RECORDS'
{"records": [
 {"protocol":"tcp","port":22,"isNetworkReachable":true,"portName":"ssh","processId":0,"processName":"","commandLine":"","unitName":"sshd.service","isEphemeral":false,"isStoppable":false,"repositoryName":"","worktreeName":"","branchName":"","projectPath":""},
 {"protocol":"tcp","port":3002,"isNetworkReachable":true,"portName":"","processId":10,"processName":"next-server (v1","commandLine":"next-server (v15.5.24)","isEphemeral":false,"isStoppable":true,"repositoryName":"acme","worktreeName":"login-form","branchName":"acme/login-form","projectPath":"web"},
 {"protocol":"tcp","port":9233,"isNetworkReachable":false,"portName":"","processId":11,"processName":"workerd","commandLine":"workerd serve","isEphemeral":false,"isStoppable":true,"repositoryName":"acme","worktreeName":"login-form","branchName":"acme/login-form","projectPath":"api"},
 {"protocol":"tcp","port":8797,"isNetworkReachable":false,"portName":"","processId":11,"processName":"workerd","commandLine":"workerd serve","isEphemeral":false,"isStoppable":true,"repositoryName":"acme","worktreeName":"login-form","branchName":"acme/login-form","projectPath":"api"},
 {"protocol":"tcp","port":40000,"isNetworkReachable":false,"portName":"","processId":11,"processName":"workerd","commandLine":"workerd serve","isEphemeral":true,"isStoppable":true,"repositoryName":"acme","worktreeName":"login-form","branchName":"acme/login-form","projectPath":"api"},
 {"protocol":"tcp","port":1337,"isNetworkReachable":true,"portName":"","processId":12,"processName":"bun","commandLine":"bun run","isEphemeral":false,"isStoppable":true,"repositoryName":"harness","worktreeName":"","branchName":"main","projectPath":""},
 {"protocol":"udp","port":5353,"isNetworkReachable":false,"portName":"","processId":20,"processName":"chrome","commandLine":"chrome","isEphemeral":false,"isStoppable":true,"repositoryName":"","worktreeName":"","branchName":"","projectPath":""},
 {"protocol":"tcp","port":27036,"isNetworkReachable":true,"portName":"","processId":30,"processName":"steam","commandLine":"steam","isEphemeral":false,"isStoppable":true,"repositoryName":"","worktreeName":"","branchName":"","projectPath":""}
]}
RECORDS
  node -e '
    const M = require(process.argv[1])
    const records = M.parse(require("fs").readFileSync(process.argv[2], "utf8")).records
    const drawn = M.sections(records)
    const port = (number) => drawn.rows.find((row) => row.port === number)
    console.log(JSON.stringify({
      headings: drawn.sections.map((section) => section.heading).join(" | "),
      caption: drawn.sections[0].caption,
      plainCaption: drawn.sections[1].caption,
      ports: drawn.rows.map((row) => row.port).join(","),
      rowIndexes: drawn.rows.map((row) => row.rowIndex).join(","),
      workerdRows: drawn.rows.filter((row) => row.processName === "workerd").length,
      workerdDetail: M.rowPath(port(8797)) + "|" + M.rowReach(port(8797)) + "|" + M.rowTrail(port(8797)),
      topPath: M.rowPath(port(1337)),
      nextName: M.rowName(port(3002)),
      nodeName: M.rowName({ processName: "node-MainThread", commandLine: "/usr/bin/node server.js" }),
      dot: M.barSummary(records).hasDevelopmentPort,
      emptyDot: M.barSummary([records[0], records[6]]).hasDevelopmentPort,
      tooltip: M.barTooltip(M.barSummary(records)),
      emptyTooltip: M.barTooltip(M.barSummary([])),
      confirm: M.confirmMessage(port(8797), "TERM")
    }))
  ' "$REPOSITORY_ROOT/plugins/ports/Model.js" "$SANDBOX/model.json" > "$SANDBOX/model.out"
  model() { jq -r "$1" "$SANDBOX/model.out"; }

  # Only dev ports: not sshd (not yours), not Chrome or Steam (no checkout),
  # not 40000 (ephemeral). Every one of those was a row once.
  check "only dev ports, in port order within a checkout" "$(model '.ports')" "3002,8797,9233,1337"
  check "checkouts sorted by name" "$(model '.headings')" "acme · login-form | harness"
  # A worktree named for its branch does not print the branch again: the same
  # words on two lines read as a glitch. A branch the heading cannot tell you --
  # `main` under a plain checkout -- is printed, from its codepoint because the
  # glyph is private-use and has vanished once as a pasted literal.
  check "  ...a worktree named for its branch does not repeat it" "$(model '.caption')" ""
  check "  ...a branch the heading cannot tell you is shown" "$(model '.plainCaption')" "$(printf ' main')"
  # workerd holds two chosen ports: two rows, so the port column stays a column.
  check "one port per row" "$(model '.workerdRows')" "2"
  check "  ...each saying where in the tree it runs" "$(model '.workerdDetail')" "api/|local|pid 11"
  check "  ...and the top of a checkout is ./" "$(model '.topPath')" "./"
  # One index per row, in drawing order, because the keyboard cursor walks them.
  check "rows are numbered in the order they are drawn" "$(model '.rowIndexes')" "0,1,2,3"
  # The kernel cut `next-server (v15.5.24)` to `next-server (v1`; the process's
  # own title has the rest. A 15-character name whose title is an argv path is
  # a genuinely short name and stays as it is.
  check "a name the kernel truncated is completed from the title" "$(model '.nextName')" "next-server (v15.5.24)"
  check "  ...but an argv is never mistaken for a title" "$(model '.nodeName')" "node-MainThread"
  # The bar answers yes or no, not how many.
  check "the bar dot is on when a dev port is open" "$(model '.dot')" "true"
  check "  ...and off when only apps and system services are" "$(model '.emptyDot')" "false"
  check "  ...with the count kept for the tooltip" "$(model '.tooltip')" "4 dev ports open"
  check "  ...which says so plainly when there is nothing" "$(model '.emptyTooltip')" "No dev servers running"
  check "the question names the one port it would close" "$(model '.confirm')" "Stop workerd (pid 11) on port 8797?"
else
  echo "  SKIP node not found — Model.js was not exercised"
fi

echo
echo "signal refuses before it acts"
check "a non-numeric pid" "$("$READER" signal notapid python3 TERM >/dev/null 2>&1; echo $?)" "2"
check "a signal that is not TERM or KILL" "$("$READER" signal 999001 python3 HUP >/dev/null 2>&1; echo $?)" "2"
# Killing pid 1 ends the session and killing pid 0 signals a whole process
# group; neither is ever what a row in this panel means.
check "pid 1" "$("$READER" signal 1 systemd TERM >/dev/null 2>&1; echo $?)" "2"
check "pid 0" "$("$READER" signal 0 anything TERM >/dev/null 2>&1; echo $?)" "2"
check "  ...and says why" \
  "$(refusal signal 1 systemd TERM | grep -c 'this panel will stop')" "1"

echo
echo "signal refuses a pid that is no longer the process it was told about"
# THE CASE THIS WHOLE GUARD EXISTS FOR. The panel polls, the reader looks, the
# reader clicks; in between, the process can exit and the kernel can hand its
# number to something else. This test uses a live process it started and lies
# about its name, which is exactly what a recycled pid looks like from here.
cat > "$SANDBOX/listener.py" <<'LISTENER'
import socket, sys, time
listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(1)
sys.stderr.write("ready\n")
sys.stderr.flush()
time.sleep(30)
LISTENER
python3 "$SANDBOX/listener.py" 2>/dev/null &
LISTENER_PID=$!
# Wait for it to exist rather than sleeping a guessed interval.
for _ in $(seq 1 50); do [[ -r /proc/$LISTENER_PID/comm ]] && break; sleep 0.05; done
check "the test's own listener is running" "$([[ -r /proc/$LISTENER_PID/comm ]] && echo yes || echo no)" "yes"

"$READER" signal "$LISTENER_PID" "some-other-process" TERM >/dev/null 2>&1
check "a name that does not match is refused" "$?" "1"
check "  ...naming what it found instead" \
  "$(refusal signal "$LISTENER_PID" "some-other-process" TERM | grep -c "is now 'python3'")" "1"
check "  ...and the process is untouched" "$([[ -r /proc/$LISTENER_PID/comm ]] && echo yes || echo no)" "yes"

echo
echo "and signals it when the name does match"
"$READER" signal "$LISTENER_PID" python3 TERM >/dev/null 2>&1
check "the matching name is accepted" "$?" "0"
for _ in $(seq 1 50); do [[ -r /proc/$LISTENER_PID/comm ]] || break; sleep 0.05; done
check "  ...and the listener is gone" "$([[ -r /proc/$LISTENER_PID/comm ]] && echo yes || echo no)" "no"
wait "$LISTENER_PID" 2>/dev/null
check "a second attempt reports it gone" \
  "$(refusal signal "$LISTENER_PID" python3 TERM | grep -c 'no longer running')" "1"

echo
if [[ $failures -eq 0 ]]; then
  printf 'PASS  %d checks, 0 failed\n' "$checks"
else
  printf 'FAIL  %d checks, %d failed\n' "$checks" "$failures"
fi
exit $((failures == 0 ? 0 : 1))
