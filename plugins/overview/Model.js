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

// A MONITOR'S DESKTOPS ARE THE BAND IT IS SHOWING.
//
// hyprpeach gives each monitor a band of `desktopCount` workspaces -- 1-10 on
// the first, 11-20 on the second -- and desktop N is the Nth workspace of the
// band. The band is read off the workspace the monitor is showing, NOT off the
// workspaces the compositor has put on it: take a laptop off its dock and the
// external monitors' workspaces pile onto the laptop's panel, and counting
// those would draw three bands' worth of cells, numbered past the keys. The
// grid is always one band: exactly the desktops the number keys reach.
function desktopsOf(state, monitorName, desktopCount) {
  var monitor = monitorNamed(state, monitorName)
  var active = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : 1
  var bandStart = active > 0 ? Math.floor((active - 1) / desktopCount) * desktopCount : 0
  var desktops = []
  for (var desktop = 1; desktop <= desktopCount; desktop++)
    desktops.push({ desktop: desktop, workspaceId: bandStart + desktop })
  return desktops
}

// The count setup() published, one number on a line; ten, the library's own
// default, when there is nothing to read.
function desktopCount(raw) {
  var count = parseInt(String(raw || "").trim(), 10)
  return count > 0 ? count : 10
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

// THE GRID THAT GIVES EACH CELL THE MOST ROOM, AT THE MONITOR'S OWN SHAPE.
//
// A cell is a picture of the screen, so it keeps the screen's aspect ratio. A
// 3x3 grid made for 16:9 squashes a 32:9 panel into slivers; the right grid
// depends on the panel. Every column count is tried and the one with the widest
// cell wins -- ten desktops come out 4 x 3 on a 32:9 panel and on 16:9 alike.
// Ties go to more columns, which reads left to right the way the desktop keys
// do.
//
// `aspect` is the MONITOR's, passed in rather than read off width and height:
// those are the area the grid may fill, which is not the screen's shape, and a
// cell cut to the area's shape clips the bottom off every window in it.
function gridFor(parameters) {
  var aspect = parameters.aspect
  var best = { columns: 1, rows: parameters.count, cellWidth: 0, cellHeight: 0 }
  for (var columns = parameters.count; columns >= 1; columns--) {
    var rows = Math.ceil(parameters.count / columns)
    var widthPerCell = (parameters.width - (columns - 1) * parameters.gap) / columns
    var heightPerCell = (parameters.height - (rows - 1) * parameters.gap) / rows
    var cellWidth = Math.min(widthPerCell, heightPerCell * aspect)
    if (cellWidth > best.cellWidth + 0.5)
      best = { columns: columns, rows: rows, cellWidth: Math.floor(cellWidth), cellHeight: Math.floor(cellWidth / aspect) }
  }
  return best
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

// The desktop a number key means. 1-9 are themselves and 0 is ten, the way the
// desktop keys and the bar strip already count.
function desktopForKey(text) {
  if (!/^[0-9]$/.test(String(text))) return 0
  return text === "0" ? 10 : Number(text)
}

if (typeof module !== "undefined") {
  module.exports = {
    parse: parse,
    monitorNamed: monitorNamed,
    desktopsOf: desktopsOf,
    desktopCount: desktopCount,
    windowsOn: windowsOn,
    toplevelAddress: toplevelAddress,
    gridFor: gridFor,
    cellPlace: cellPlace,
    heldPanels: heldPanels,
    desktopForKey: desktopForKey
  }
}
