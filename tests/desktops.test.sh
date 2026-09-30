#!/usr/bin/env bash
# Runs plugins/desktops/Switches.js against the focus sequences that matter:
# which changes of focused workspace flash the desktop number, and which do not.
# The flash itself is QML and is checked on a running desk; this is the decision.
#
# Run: bash tests/desktops.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."

node - <<'NODE'
const { observe } = require("./plugins/desktops/Switches.js")
let checks = 0, failures = 0
function check(label, got, want) {
  checks++
  if (JSON.stringify(got) !== JSON.stringify(want)) { failures++; console.log(`  FAIL ${label}\n       want: ${JSON.stringify(want)}\n       got:  ${JSON.stringify(got)}`) }
}
// Two panels banded like hyprpeach: bottom DP-5 on 1-10, top DP-3 on 11-20.
function run(start, events) {
  let state = start, flashes = []
  for (const [monitorName, workspaceId] of events) {
    const result = observe(state, { monitorName, workspaceId, bandStride: 10 })
    state = result.state
    flashes.push(result.flash)
  }
  return { state, flashes }
}
const paired = { workspaceByMonitor: { "DP-5": 1, "DP-3": 11 }, desktop: 1 }

console.log("hyprpeach desktops")
console.log("\na paired switch flashes once")
check("top then bottom move to desktop 2", run(paired, [["DP-3", 12], ["DP-5", 2]]).flashes, [true, false])
check("and the desk is on desktop 2", run(paired, [["DP-3", 12], ["DP-5", 2]]).state.desktop, 2)

console.log("\nmoving between monitors is not a switch")
check("focus moves top and back on a paired desk", run(paired, [["DP-3", 11], ["DP-5", 1]]).flashes, [false, false])

// The bug: top held on 1, bottom moved on to 3, the mouse goes back and forth.
const held = { workspaceByMonitor: { "DP-5": 3, "DP-3": 11 }, desktop: 3 }
check("into the held panel and out again, repeatedly", run(held, [["DP-3", 11], ["DP-5", 3], ["DP-3", 11], ["DP-5", 3]]).flashes, [false, false, false, false])
check("and the desk stays on 3", run(held, [["DP-3", 11], ["DP-5", 3]]).state.desktop, 3)

console.log("\na switch with one panel held still flashes, once")
check("only the free panel moves", run(held, [["DP-5", 4]]).flashes, [true])
check("focus then visits the held panel quietly", run(held, [["DP-5", 4], ["DP-3", 11]]).flashes, [true, false])

console.log("\nwhat it cannot know, it does not announce")
check("a monitor never seen before", run({ workspaceByMonitor: {}, desktop: 1 }, [["DP-3", 14]]).flashes, [false])
check("a special workspace", run(paired, [["DP-5", -98]]).flashes, [false])

console.log(failures === 0 ? `\nPASS  ${checks} checks, 0 failed` : `\nFAIL  ${checks} checks, ${failures} failed`)
process.exit(failures === 0 ? 0 : 1)
NODE
