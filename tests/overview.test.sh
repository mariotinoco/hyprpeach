#!/usr/bin/env bash
# Runs plugins/overview/Model.js against captured `hyprctl -j` shapes: each
# monitor's grid, which windows each cell shows and where, and the keys.
# The drawing is QML and is checked on a running desk; this is the part that is
# wrong quietly -- a cell in the wrong shape for its monitor, a cell showing
# another monitor's windows, a scaled panel measured in pixels.
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

console.log("\na grid on every monitor, in its own shape")
const bottom = model.monitorNamed(stacked, "DP-5")
const top = model.monitorNamed(stacked, "DP-3")
const grid = model.monitorGrid(bottom)
check("nine cells", grid.cells.length, 9)
check("each cell is the monitor's shape, 32:9", round(grid.cells[0].width / grid.cells[0].height * 9), 32)
check("the grid is centred on the monitor", round(grid.cells[0].x + grid.cells[2].x + grid.cells[2].width), 7680)
check("desktop 4 starts the second row, below 1", [grid.cells[3].x, grid.cells[3].y > grid.cells[0].y], [grid.cells[0].x, true])
check("the grid stays on its monitor", grid.cells.every(c => c.y >= 0 && c.y + c.height <= 2160 && c.x >= 0 && c.x + c.width <= 7680), true)
check("it fits the 92% x 86% the renderer draws in", 3 * grid.cells[0].width + 2 * 2160 * 0.012 <= 7680 * 0.92 + 0.01 && 3 * grid.cells[0].height + 2 * 2160 * 0.012 <= 2160 * 0.86 + 0.01, true)

console.log("\na cell is that desktop on its own monitor")
check("the bottom panel's desktop 4 is its own window", model.windowsOnMonitorDesktop(stacked, bottom, 4).map(w => w.client.class), ["bottom-left"])
check("the top panel's desktop 4 is ITS window, from workspace 14", model.windowsOnMonitorDesktop(stacked, top, 4).map(w => w.client.class), ["top-right"])
check("  ...placed in the top panel's own pixels", [model.windowsOnMonitorDesktop(stacked, top, 4)[0].x, model.windowsOnMonitorDesktop(stacked, top, 4)[0].y], [3840, 0])
check("another desktop's windows are not in it", model.windowsOnMonitorDesktop(stacked, bottom, 4).some(w => w.client.class === "elsewhere"), false)
check("the desk is on desktop 1", model.currentDesktop(stacked), 1)

console.log("\nscaled and rotated panels are measured as Hyprland places windows")
check("a scale-2 panel is half as large", model.logicalRect({ x: 0, y: 0, width: 3840, height: 2160, scale: 2, transform: 0 }), { x: 0, y: 0, width: 1920, height: 1080 })
check("a panel on its side is tall", model.logicalRect({ x: 0, y: 0, width: 2560, height: 1440, scale: 1, transform: 1 }), { x: 0, y: 0, width: 1440, height: 2560 })
check("  ...and its cells are tall too", model.monitorGrid({ x: 0, y: 0, width: 2560, height: 1440, scale: 1, transform: 1 }).cells[0].height > model.monitorGrid({ x: 0, y: 0, width: 2560, height: 1440, scale: 1, transform: 1 }).cells[0].width, true)

// A laptop between two larger monitors, lower than them: the desk is a ragged
// strip, and a grid across it would run 40:9 cells over three bezels.
const docked = model.parse(JSON.stringify({
  monitors: [
    { name: "DP-2", x: 0, y: 0, width: 3840, height: 2160, scale: 1, transform: 0, activeWorkspace: { id: 11 } },
    { name: "eDP-1", x: 3840, y: 480, width: 1920, height: 1200, scale: 1, transform: 0, focused: true, activeWorkspace: { id: 1 } },
    { name: "DP-1", x: 5760, y: 0, width: 3840, height: 2160, scale: 1, transform: 0, activeWorkspace: { id: 21 } },
  ],
  clients: [{ address: "0xf", workspace: { id: 3 }, at: [3840, 480], size: [1920, 1200], class: "laptop full" }],
  workspaces: [],
}))
const laptop = model.monitorNamed(docked, "eDP-1")
check("the laptop's cells are the laptop's shape, 16:10", round(model.monitorGrid(laptop).cells[0].width / model.monitorGrid(laptop).cells[0].height * 10), 16)
check("  ...and a Dell's are a Dell's, 16:9", round(model.monitorGrid(model.monitorNamed(docked, "DP-1")).cells[0].width / model.monitorGrid(model.monitorNamed(docked, "DP-1")).cells[0].height * 9), 16)
check("a full-screen laptop window fills its cell", model.windowsOnMonitorDesktop(docked, laptop, 3).map(w => [w.x, w.y, w.width * model.monitorGrid(laptop).scale - model.monitorGrid(laptop).cells[0].width]), [[0, 0, 0]])

// Off the dock, the Dells' workspaces pile onto the laptop: it shows its own band.
const undocked = model.parse(JSON.stringify({
  monitors: [{ name: "eDP-1", x: 0, y: 0, width: 1920, height: 1200, scale: 1, transform: 0, focused: true, activeWorkspace: { id: 4 } }],
  clients: [
    { address: "0xd", workspace: { id: 14 }, at: [0, 0], size: [100, 100], class: "piled from a Dell" },
    { address: "0xe", workspace: { id: 4 }, at: [0, 0], size: [100, 100], class: "the laptop's own" },
  ],
  workspaces: [],
}))
check("undocked, desktop 4 is the laptop's own band", model.windowsOnMonitorDesktop(undocked, model.monitorNamed(undocked, "eDP-1"), 4).map(w => w.client.class), ["the laptop's own"])

console.log("\nkeys and held panels")
check("7 is desktop 7", model.desktopForKey("7"), 7)
check("0 is no desktop", model.desktopForKey("0"), 0)
check("  ...it closes the overview, as SUPER + 0 opened it", model.closesOverview("0"), true)
check("a monitor name with spaces survives", model.heldPanels("desc:Samsung Odyssey G95NC 2\n"), { "desc:Samsung Odyssey G95NC": 2 })

console.log(failures === 0 ? `\nPASS  ${checks} checks, 0 failed` : `\nFAIL  ${checks} checks, ${failures} failed`)
process.exit(failures === 0 ? 0 : 1)
NODE
