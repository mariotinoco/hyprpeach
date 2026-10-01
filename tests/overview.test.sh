#!/usr/bin/env bash
# Runs plugins/overview/Model.js against captured `hyprctl -j` shapes: the one
# grid across the desk, which windows each cell shows and where, and the keys.
# The drawing is QML and is checked on a running desk; this is the part that is
# wrong quietly -- a grid per monitor instead of one, a cell that shows one
# monitor's windows and not the other's, a scaled panel measured in pixels.
#
# Run: bash tests/overview.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."

node - <<'NODE'
const model = require("./plugins/overview/Model.js")
let checks = 0, failures = 0
function check(label, got, want) {
  checks++
  if (JSON.stringify(got) !== JSON.stringify(want)) { failures++; console.log(`  FAIL ${label}\n       want: ${JSON.stringify(want)}\n       got:  ${JSON.stringify(got)}`) }
}
const round = (v) => Math.round(v)

console.log("hyprpeach overview")

// Two 7680 x 2160 panels stacked: the bottom on 1-9, the top on 11-19.
const stacked = model.parse(JSON.stringify({
  monitors: [
    { name: "DP-5", x: 0, y: 0, width: 7680, height: 2160, scale: 1, transform: 0, focused: true, activeWorkspace: { id: 1 } },
    { name: "DP-3", x: 0, y: -2160, width: 7680, height: 2160, scale: 1, transform: 0, focused: false, activeWorkspace: { id: 11 } },
  ],
  clients: [
    { address: "0xa", workspace: { id: 4 }, at: [0, 0], size: [3840, 2160], class: "bottom-left" },
    { address: "0xb", workspace: { id: 14 }, at: [3840, -2160], size: [3840, 2160], class: "top-right" },
    { address: "0xc", workspace: { id: 5 }, at: [0, 0], size: [7680, 2160], class: "elsewhere" },
  ],
  workspaces: [],
}))

console.log("\none grid across the whole desk, not one per monitor")
const grid = model.deskGrid(stacked)
check("the desk is both panels together", grid.box, { x: 0, y: -2160, width: 7680, height: 4320 })
check("nine cells", grid.cells.length, 9)
check("each cell is the desk's own shape", round(grid.cells[0].width / grid.cells[0].height * 9), 16)
check("the grid is centred on the desk", round(grid.cells[0].x + grid.cells[2].x + grid.cells[2].width), 7680)
check("desktop 4 starts the second row, below 1", [grid.cells[3].x, grid.cells[3].y > grid.cells[0].y], [grid.cells[0].x, true])
check("the middle row crosses the bezel, as the desk does", grid.cells[4].y < 2160 && grid.cells[4].y + grid.cells[4].height > 2160, true)
check("it fits the 92% x 86% the renderer draws in", 3 * grid.cells[0].width + 2 * 4320 * 0.012 <= 7680 * 0.92 + 0.01 && 3 * grid.cells[0].height + 2 * 4320 * 0.012 <= 4320 * 0.86 + 0.01, true)

console.log("\na cell is that desktop on every monitor, where it sits")
const four = model.windowsOnDesktop(stacked, 4)
check("desktop 4 has the bottom panel's window and the top panel's", four.map(w => w.client.class).sort(), ["bottom-left", "top-right"])
check("the top panel's window sits in the upper half of the desk", four.find(w => w.client.class === "top-right").y, 0)
check("the bottom panel's in the lower half", four.find(w => w.client.class === "bottom-left").y, 2160)
check("another desktop's windows are not in it", four.some(w => w.client.class === "elsewhere"), false)
check("the desk is on desktop 1", model.currentDesktop(stacked), 1)

console.log("\nscaled and rotated panels are measured as Hyprland places windows")
check("a scale-2 panel is half as large", model.logicalRect({ x: 0, y: 0, width: 3840, height: 2160, scale: 2, transform: 0 }), { x: 0, y: 0, width: 1920, height: 1080 })
check("a panel on its side is tall", model.logicalRect({ x: 0, y: 0, width: 2560, height: 1440, scale: 1, transform: 1 }), { x: 0, y: 0, width: 1440, height: 2560 })

// Three side by side: a Dell, a laptop centred on them, a Dell.
const docked = model.parse(JSON.stringify({
  monitors: [
    { name: "DP-2", x: 0, y: 0, width: 3840, height: 2160, scale: 1, transform: 0, activeWorkspace: { id: 11 } },
    { name: "eDP-1", x: 3840, y: 480, width: 1920, height: 1200, scale: 1, transform: 0, focused: true, activeWorkspace: { id: 1 } },
    { name: "DP-1", x: 5760, y: 0, width: 3840, height: 2160, scale: 1, transform: 0, activeWorkspace: { id: 21 } },
  ],
  clients: [], workspaces: [],
}))
check("three side by side make one wide desk", model.deskBox(docked), { x: 0, y: 0, width: 9600, height: 2160 })
check("  ...and its cells are that wide too", round(model.deskGrid(docked).cells[0].width / model.deskGrid(docked).cells[0].height * 9), 40)

// Off the dock, the Dells' workspaces pile onto the laptop: it draws one band.
const undocked = model.parse(JSON.stringify({
  monitors: [{ name: "eDP-1", x: 0, y: 0, width: 1920, height: 1200, scale: 1, transform: 0, focused: true, activeWorkspace: { id: 4 } }],
  clients: [
    { address: "0xd", workspace: { id: 14 }, at: [0, 0], size: [100, 100], class: "piled from a Dell" },
    { address: "0xe", workspace: { id: 4 }, at: [0, 0], size: [100, 100], class: "the laptop's own" },
  ],
  workspaces: [],
}))
check("undocked, desktop 4 is the laptop's own band", model.windowsOnDesktop(undocked, 4).map(w => w.client.class), ["the laptop's own"])

console.log("\nkeys and held panels")
check("7 is desktop 7", model.desktopForKey("7"), 7)
check("0 is no desktop", model.desktopForKey("0"), 0)
check("  ...it closes the overview, as SUPER + 0 opened it", model.closesOverview("0"), true)
check("a monitor name with spaces survives", model.heldPanels("desc:Samsung Odyssey G95NC 2\n"), { "desc:Samsung Odyssey G95NC": 2 })

console.log(failures === 0 ? `\nPASS  ${checks} checks, 0 failed` : `\nFAIL  ${checks} checks, ${failures} failed`)
process.exit(failures === 0 ? 0 : 1)
NODE
