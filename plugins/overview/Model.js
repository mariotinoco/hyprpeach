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
// says why (init.lua). The overview is the 3 x 3 those nine make.
var DESKTOP_COUNT = 9
var BAND_WIDTH = 10

// A MONITOR'S DESKTOPS ARE THE BAND IT IS SHOWING.
//
// The band is read off the workspace the monitor is showing, NOT off the
// workspaces the compositor has put on it: take a laptop off its dock and the
// external monitors' workspaces pile onto the laptop's panel, and counting
// those would draw three bands' worth of cells. The grid is always one band:
// exactly the desktops the number keys reach.
function desktopsOf(state, monitorName) {
  var monitor = monitorNamed(state, monitorName)
  var active = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : 1
  var bandStart = active > 0 ? Math.floor((active - 1) / BAND_WIDTH) * BAND_WIDTH : 0
  var desktops = []
  for (var desktop = 1; desktop <= DESKTOP_COUNT; desktop++)
    desktops.push({ desktop: desktop, workspaceId: bandStart + desktop })
  return desktops
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

// THE GRID IS 3 x 3, the desk's own shape: columns are bearings around the
// station, rows are positions along its orbit. Each cell keeps the MONITOR's
// shape -- `aspect` is the monitor's, passed in, because width and height here
// are only the area the grid may fill, and a cell cut to the area's shape clips
// the bottom off every window in it.
function gridFor(parameters) {
  var widthPerCell = (parameters.width - 2 * parameters.gap) / 3
  var heightPerCell = (parameters.height - 2 * parameters.gap) / 3
  var cellWidth = Math.min(widthPerCell, heightPerCell * parameters.aspect)
  return { columns: 3, rows: 3, cellWidth: Math.floor(cellWidth), cellHeight: Math.floor(cellWidth / parameters.aspect) }
}

// WHERE A CELL GOES, WITH A SHORT LAST ROW CENTRED. Ten desktops in a 4 x 3
// grid leave two in the last row; pushed left, they read as a grid with holes
// in it rather than as the end of a list. Columns are fractional for exactly
// that row.
function cellPlace(parameters) {
  var row = Math.floor(parameters.index / parameters.columns)
  var inRow = Math.min(parameters.columns, parameters.count - row * parameters.columns)
  var column = parameters.index % parameters.columns + (parameters.columns - inRow) / 2
  return { row: row, column: column }
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
    desktopsOf: desktopsOf,
    windowsOn: windowsOn,
    toplevelAddress: toplevelAddress,
    gridFor: gridFor,
    cellPlace: cellPlace,
    heldPanels: heldPanels,
    desktopForKey: desktopForKey,
    closesOverview: closesOverview
  }
}
