// Whether a change of focused workspace is a desktop switch worth announcing.
//
// Kept out of DesktopOsd.qml so it can be checked without a compositor:
// tests/desktops.test.sh runs it against the sequences that matter.
//
// THE FOCUSED WORKSPACE CHANGES FOR TWO DIFFERENT REASONS, and only one of them
// is news. A monitor showing a new workspace is a switch. The focus moving to a
// monitor that is still showing what it showed before is not -- and on a desk
// where one panel is HELD, the monitors show different desktops, so a plain
// mouse move between them used to read as a switch and flash a number when
// nothing had moved.
//
// So each monitor's last workspace is remembered, and an event for a monitor
// that is still on it is a focus move: nothing flashes, nothing changes.
// A held panel needs no case of its own: hyprpeach never switches it, so every
// event for it is a focus move.

function desktopFor(workspaceId, bandStride) {
  return workspaceId < 1 ? -1 : ((workspaceId - 1) % bandStride) + 1
}

// state:      { workspaceByMonitor: { name: id }, desktop: number }
// parameters: { monitorName, workspaceId, bandStride }
// returns:    { state, flash }
function observe(state, parameters) {
  var desktop = desktopFor(parameters.workspaceId, parameters.bandStride)
  if (desktop < 1 || !parameters.monitorName) return { state: state, flash: false }

  var known = state.workspaceByMonitor[parameters.monitorName]
  var workspaceByMonitor = {}
  for (var name in state.workspaceByMonitor) workspaceByMonitor[name] = state.workspaceByMonitor[name]
  workspaceByMonitor[parameters.monitorName] = parameters.workspaceId

  // Focus moved onto a monitor that did not change -- or onto one never seen
  // before, where there is no telling whether it changed. Either way, not news.
  if (known === undefined || known === parameters.workspaceId)
    return { state: { workspaceByMonitor: workspaceByMonitor, desktop: state.desktop }, flash: false }

  // This monitor switched. A paired switch is one of these per panel, all
  // landing on the same desktop, so only the first one flashes.
  return {
    state: { workspaceByMonitor: workspaceByMonitor, desktop: desktop },
    flash: desktop !== state.desktop
  }
}

if (typeof module !== "undefined") module.exports = { observe: observe, desktopFor: desktopFor }
