// Everything the overview decides that is not drawing: which desktops a
// monitor has, which windows are on each, and how big a cell can be.
//
// Kept out of Overview.qml for the reason dev-ports keeps its own: these are the
// parts that are wrong quietly, and a plain function can be checked against a
// captured `hyprctl -j` document without a compositor. tests/overview.test.sh
// does exactly that.

// One document from three `hyprctl -j` calls, read in a single process so the
// monitors, windows and workspaces are one moment's state rather than three.
function parse(raw) {
  try {
    var document = JSON.parse(String(raw || ""))
    return {
      monitors: Array.isArray(document.monitors) ? document.monitors : [],
      clients: Array.isArray(document.clients) ? document.clients : [],
      workspaces: Array.isArray(document.workspaces) ? document.workspaces : [],
      error: ""
    }
  } catch (error) {
    return { monitors: [], clients: [], workspaces: [], error: String(error) }
  }
}

function monitorNamed(state, name) {
  for (var index = 0; index < state.monitors.length; index++)
    if (state.monitors[index].name === name) return state.monitors[index]
  return null
}

// NINE DESKTOPS, ON BANDS TEN WORKSPACES WIDE -- fixed in the library, which
// says why (init.lua).
var DESKTOP_COUNT = 9
var BAND_WIDTH = 10

// A monitor's rectangle on the desk, in the LOGICAL pixels Hyprland positions
// windows in: its pixel size over its scale, turned for a rotated panel.
function logicalRect(monitor) {
  var scale = monitor.scale > 0 ? monitor.scale : 1
  var turned = monitor.transform % 2 === 1
  var width = (turned ? monitor.height : monitor.width) / scale
  var height = (turned ? monitor.width : monitor.height) / scale
  return { x: monitor.x, y: monitor.y, width: width, height: height }
}

// The desk: every monitor's rectangle together.
function deskBox(state) {
  var left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity
  for (var index = 0; index < state.monitors.length; index++) {
    var r = logicalRect(state.monitors[index])
    left = Math.min(left, r.x); top = Math.min(top, r.y)
    right = Math.max(right, r.x + r.width); bottom = Math.max(bottom, r.y + r.height)
  }
  if (left === Infinity) return { x: 0, y: 0, width: 1, height: 1 }
  return { x: left, y: top, width: right - left, height: bottom - top }
}

// THE GRID IS ONE, ACROSS THE WHOLE DESK -- not a grid per monitor. Every
// monitor draws its own part of it, so on two stacked panels the middle row
// crosses the bezel, as one window across the desk would. Each cell is the
// desk's own shape: a miniature of the whole desk on that desktop.
//
// The SAME arithmetic as plugins/orbit's renderer (overviewCell in
// scene.wgsl), in desk pixels: 3 x 3 inside 92% x 86% of the desk, gaps of
// 1.2% of its height, centred. If the two disagree, the orbit scene's
// viewports and these frames slide apart.
function deskGrid(state) {
  var box = deskBox(state)
  var gap = box.height * 0.012
  var aspect = box.width / box.height
  var cellWidth = Math.min((box.width * 0.92 - 2 * gap) / 3, (box.height * 0.86 - 2 * gap) / 3 * aspect)
  var cellHeight = cellWidth / aspect
  var left = (box.width - (3 * cellWidth + 2 * gap)) / 2
  var top = (box.height - (3 * cellHeight + 2 * gap)) / 2
  var cells = []
  for (var index = 0; index < DESKTOP_COUNT; index++) {
    cells.push({
      desktop: index + 1,
      x: left + (index % 3) * (cellWidth + gap),
      y: top + Math.floor(index / 3) * (cellHeight + gap),
      width: cellWidth,
      height: cellHeight
    })
  }
  return { box: box, cells: cells, scale: cellWidth / box.width }
}

// The band a monitor is on, read off the workspace it is showing -- not off
// the workspaces the compositor has put on it, which a laptop off its dock
// piles onto its one panel.
function bandStartOf(monitor) {
  var active = monitor.activeWorkspace ? monitor.activeWorkspace.id : 1
  return active > 0 ? Math.floor((active - 1) / BAND_WIDTH) * BAND_WIDTH : 0
}

// Desktop N's windows on EVERY monitor, placed on the desk: the top panel's in
// the upper part of the cell, the bottom panel's in the lower, where they are.
function windowsOnDesktop(state, desktop) {
  var box = deskBox(state)
  var windows = []
  for (var index = 0; index < state.monitors.length; index++) {
    var on = windowsOn(state, bandStartOf(state.monitors[index]) + desktop)
    for (var w = 0; w < on.length; w++) {
      windows.push({
        client: on[w],
        x: on[w].at[0] - box.x,
        y: on[w].at[1] - box.y,
        width: on[w].size[0],
        height: on[w].size[1]
      })
    }
  }
  return windows
}

// The desk's desktop: the focused monitor's.
function currentDesktop(state) {
  for (var index = 0; index < state.monitors.length; index++) {
    var monitor = state.monitors[index]
    if (!monitor.focused || !monitor.activeWorkspace) continue
    var desktop = ((monitor.activeWorkspace.id - 1) % BAND_WIDTH) + 1
    return desktop > DESKTOP_COUNT ? -1 : desktop
  }
  return -1
}

function windowsOn(state, workspaceId) {
  var windows = []
  for (var index = 0; index < state.clients.length; index++) {
    var client = state.clients[index]
    if (client.workspace && client.workspace.id === workspaceId && client.mapped !== false && client.hidden !== true)
      windows.push(client)
  }
  // Drawn in stacking order: floating windows over tiled ones.
  windows.sort(function(first, second) { return (first.floating ? 1 : 0) - (second.floating ? 1 : 0) })
  return windows
}

// Hyprland's IPC writes an address as `0x5f3a21`; Quickshell's toplevels carry
// it without the prefix.
function toplevelAddress(clientAddress) {
  return String(clientAddress || "").replace(/^0x/, "")
}

// Held panels, as the library publishes them: "<monitor> <desktop>" per line.
// Split at the LAST space, because a monitor name can hold spaces of its own.
function heldPanels(raw) {
  var panels = {}
  var lines = String(raw || "").split("\n")
  for (var index = 0; index < lines.length; index++) {
    var line = lines[index].trim()
    if (line === "") continue
    var gap = line.lastIndexOf(" ")
    var name = gap < 0 ? line : line.substring(0, gap)
    var desktop = gap < 0 ? NaN : parseInt(line.substring(gap + 1), 10)
    panels[name] = isNaN(desktop) ? -1 : desktop
  }
  return panels
}

// What a number key means inside the overview: 1-9 are desktops, and 0 -- the
// key that opened it, with SUPER -- closes it again.
function desktopForKey(text) {
  if (!/^[1-9]$/.test(String(text))) return 0
  return Number(text)
}

function closesOverview(text) {
  return String(text) === "0"
}

if (typeof module !== "undefined") {
  module.exports = {
    parse: parse,
    monitorNamed: monitorNamed,
    logicalRect: logicalRect,
    deskBox: deskBox,
    deskGrid: deskGrid,
    windowsOnDesktop: windowsOnDesktop,
    currentDesktop: currentDesktop,
    windowsOn: windowsOn,
    toplevelAddress: toplevelAddress,
    heldPanels: heldPanels,
    desktopForKey: desktopForKey,
    closesOverview: closesOverview
  }
}
