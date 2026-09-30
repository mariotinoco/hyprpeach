#!/usr/bin/env bash
# Runs plugins/overview/Model.js against captured `hyprctl -j` shapes: which
# desktops a monitor has, which windows sit on each, and how the grid is laid
# out. The drawing is QML and is checked on a running desk; this is the part
# that is wrong quietly -- a grid that squashes a 32:9 panel, a top monitor
# whose desktops are numbered 11 to 20, a held panel whose name has spaces in it.
#
# Run: bash tests/overview.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."

node - <<'NODE'
const model = require("./plugins/overview/Model.js")
let checks = 0, failures = 0
function check(label, got, want) {
  checks++
  const same = JSON.stringify(got) === JSON.stringify(want)
  if (!same) { failures++; console.log(`  FAIL ${label}\n       want: ${JSON.stringify(want)}\n       got:  ${JSON.stringify(got)}`) }
}

console.log("hyprpeach overview")

// Two panels the way hyprpeach bands them: 1-10 on the bottom, 11-20 on top.
const workspaces = []
for (let id = 1; id <= 20; id++) workspaces.push({ id, monitor: id <= 10 ? "DP-5" : "DP-3" })
workspaces.push({ id: -98, monitor: "DP-5", name: "special:scratchpad" })
const state = model.parse(JSON.stringify({
  monitors: [{ name: "DP-5", x: 0, y: 0, width: 7680, height: 2160, activeWorkspace: { id: 1 } },
             { name: "DP-3", x: 0, y: -2160, width: 7680, height: 2160, activeWorkspace: { id: 13 } }],
  clients: [
    { address: "0xa", workspace: { id: 13 }, at: [10, -2150], size: [7600, 2100], floating: true, class: "foot" },
    { address: "0xb", workspace: { id: 13 }, at: [10, -2150], size: [3000, 2100], floating: false, class: "chrome" },
    { address: "0xc", workspace: { id: 1 }, at: [10, 10], size: [100, 100], hidden: true, class: "grouped" },
  ],
  workspaces,
}))

console.log("\na monitor's desktops are the band it is showing")
const top = model.desktopsOf(state, "DP-3")
check("the top panel has nine desktops", top.length, 9)
check("its desktop 1 is workspace 11", top[0], { desktop: 1, workspaceId: 11 })
check("its desktop 9 is workspace 19", top[8], { desktop: 9, workspaceId: 19 })
check("the bottom panel's are 1 to 9", model.desktopsOf(state, "DP-5").map(d => d.workspaceId), [1,2,3,4,5,6,7,8,9])

// Three monitors side by side: a Dell, a laptop centred on them, a Dell. The
// laptop sorts first -- it sits lower -- and holds 1-10; the Dells, left then
// right, hold 11-20 and 21-30.
const docked = model.parse(JSON.stringify({
  monitors: [{ name: "DP-2", x: 0, y: 0, width: 3840, height: 2160, activeWorkspace: { id: 14 } },
             { name: "eDP-1", x: 3840, y: 480, width: 1920, height: 1200, activeWorkspace: { id: 4 } },
             { name: "DP-1", x: 5760, y: 0, width: 3840, height: 2160, activeWorkspace: { id: 24 } }],
  clients: [], workspaces: [],
}))
check("three side by side: the right Dell draws 21-29", model.desktopsOf(docked, "DP-1").map(d => d.workspaceId)[0], 21)
check("  ...and its desktop 4 is workspace 24", model.desktopsOf(docked, "DP-1")[3], { desktop: 4, workspaceId: 24 })

// Off the dock, the Dells' workspaces land on the laptop. It still draws one
// band -- the ten the number keys reach -- not thirty cells.
const undockedWorkspaces = []
for (let id = 1; id <= 30; id++) undockedWorkspaces.push({ id, monitor: "eDP-1" })
const undocked = model.parse(JSON.stringify({
  monitors: [{ name: "eDP-1", x: 0, y: 0, width: 1920, height: 1200, activeWorkspace: { id: 4 } }],
  clients: [], workspaces: undockedWorkspaces,
}))
check("undocked, the laptop still draws nine", model.desktopsOf(undocked, "eDP-1").length, 9)
check("  ...and they are 1 to 9", model.desktopsOf(undocked, "eDP-1")[8], { desktop: 9, workspaceId: 9 })

console.log("\nwindows are drawn tiled first, floating on top")
check("a desktop's windows, floating last", model.windowsOn(state, 13).map(w => w.class), ["chrome", "foot"])
check("a window hidden in a group is not drawn", model.windowsOn(state, 1).length, 0)
check("an address matches Quickshell's toplevels without 0x", model.toplevelAddress("0x62f0615475f0"), "62f0615475f0")

console.log("\nthe grid is 3 x 3, each cell the monitor's shape")
const wide = model.gridFor({ width: 7065, height: 1857, gap: 26, aspect: 7680 / 2160 })
check("on 32:9 panels it is 3 x 3", [wide.columns, wide.rows], [3, 3])
check("  ...and the cells are 32:9", Math.round(wide.cellWidth / wide.cellHeight * 9), 32)
const laptop = model.gridFor({ width: 1766, height: 1032, gap: 13, aspect: 1920 / 1200 })
check("on a 16:10 laptop the cells are 16:10", Math.round(laptop.cellWidth / laptop.cellHeight * 10), 16)
check("the grid fits the area it is given", 3 * wide.cellWidth + 2 * 26 <= 7065 && 3 * wide.cellHeight + 2 * 26 <= 1857, true)
check("a full row is not moved", model.cellPlace({ index: 4, count: 9, columns: 3 }), { row: 1, column: 1 })

console.log("\nkeys and held panels")
check("7 is desktop 7", model.desktopForKey("7"), 7)
check("0 is no desktop", model.desktopForKey("0"), 0)
check("  ...it closes the overview, as SUPER + 0 opened it", model.closesOverview("0"), true)
check("9 does not close it", model.closesOverview("9"), false)
check("a letter is no desktop", model.desktopForKey("q"), 0)
check("a monitor name with spaces survives", model.heldPanels("desc:Samsung Odyssey G95NC 2\n"), { "desc:Samsung Odyssey G95NC": 2 })
check("an empty file holds nothing", model.heldPanels(""), {})

console.log(failures === 0 ? `\nPASS  ${checks} checks, 0 failed` : `\nFAIL  ${checks} checks, ${failures} failed`)
process.exit(failures === 0 ? 0 : 1)
NODE
