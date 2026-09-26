import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Desktop indicators for hyprpeach.
//
// Omarchy's own omarchy.workspaces widget cannot show a hyprpeach desk, for two
// reasons that are easy to miss. It filters to `id > 0 && id <= 10`, so a second
// monitor's band (11-20) is invisible to it — every bar on every screen draws the
// FIRST monitor's workspaces. And clicking one dispatches a single
// `hl.dsp.focus({ workspace })`, which moves one panel and leaves the other
// behind, splitting the pair the moment you use the mouse.
//
// This widget draws DESKTOPS rather than workspace IDs, reads them from the
// monitor this particular bar is on, and clicks through to hyprpeach so both
// panels move together.
//
// THREE STATES, AND THEY DIFFER IN SHAPE, NOT ONLY IN COLOUR:
//
//   empty     a faint numeral, no tile
//   occupied  a brighter numeral on a faint tile
//   current   a bar-coloured numeral on a near-solid tile
//
// ALL THREE ARE THE SAME INK AT DIFFERENT ALPHAS, and the ink is plain white
// or plain black -- whichever contrasts with the bar -- rather than a colour
// from the theme.
//
// A themed accent was tried first and does not survive contact with real
// themes. `Color.bar.active` is an arbitrary hue: on one theme it is a clean
// pink, on the next a muddy red on cream, and on a third it is so close to the
// bar background that the three states collapse into one. Neutral ink cannot
// clash, because it is defined against the surface it sits on.
//
// Nothing -> outline -> filled is a progression you can rank without reading
// it, and it survives a theme whose accent is nearly the same brightness as
// its foreground. Two filled shapes at different alphas did not: across a
// 7680-wide panel they read as the same thing twice.
BarWidget {
  id: root
  moduleName: "hyprpeach.desktops"

  // HOW WIDE EACH MONITOR'S BAND IS, WHICH IS THE DESKTOP COUNT.
  //
  // Counted rather than configured: hyprpeach makes every desktop persistent,
  // so a monitor's workspaces are exactly its desktops, and a setting would be
  // a second place for that number to go stale -- which it did, drawing ten
  // cells for an eight-desktop desk.
  //
  // Only believed when every monitor agrees. hyprpeach gives each monitor the
  // same number of workspaces, always, so a reading where they differ is a
  // model caught half-updated rather than a new desktop count. Trusting those
  // readings made cells appear and vanish mid-switch.
  property int bandStride: 10

  function refreshBandStride() {
    var perMonitor = ({})
    var values = Hyprland.workspaces.values
    for (var index = 0; index < values.length; index++) {
      var workspace = values[index]
      if (workspace.id < 1 || !workspace.monitor) continue
      var name = workspace.monitor.name
      perMonitor[name] = (perMonitor[name] || 0) + 1
    }

    var agreed = -1
    for (var key in perMonitor) {
      if (agreed < 0) agreed = perMonitor[key]
      else if (perMonitor[key] !== agreed) return   // half-updated; keep what we had
    }
    if (agreed > 0) root.bandStride = agreed
  }

  Component.onCompleted: root.refreshBandStride()

  Connections {
    target: Hyprland.workspaces
    function onValuesChanged() { root.refreshBandStride() }
  }

  // Every desktop is persistent, so the desktops ARE 1..bandStride. Deriving
  // the list by scanning the live workspaces instead let it lose an entry for a
  // frame whenever the model was between updates, and a cell that disappears
  // and comes back is the most distracting thing a status bar can do.
  readonly property var desktops: {
    var list = []
    for (var desktop = 1; desktop <= root.bandStride; desktop++) list.push(desktop)
    return list
  }

  // Windows per desktop, summed across every panel: the question is "is there
  // something on 3", not "is there something on 3 down here".
  readonly property var windowCounts: {
    var counts = ({})
    var values = Hyprland.workspaces.values
    for (var index = 0; index < values.length; index++) {
      var workspace = values[index]
      if (workspace.id < 1) continue
      var desktop = ((workspace.id - 1) % root.bandStride) + 1
      counts[desktop] = (counts[desktop] || 0) + workspace.toplevels.values.length
    }
    return counts
  }

  function activeDesktop() {
    if (!Hyprland.focusedWorkspace || Hyprland.focusedWorkspace.id < 1) return -1
    return ((Hyprland.focusedWorkspace.id - 1) % root.bandStride) + 1
  }

  // `hyprctl eval`, NOT `hyprctl dispatch`. Dispatch wraps its argument in
  // hl.dispatch() and demands a single dispatcher; a paired switch is one
  // dispatch per panel, so dispatch rejects it outright.
  function focusDesktop(desktop) {
    if (!root.bar) return
    root.bar.run("hyprctl eval " + Util.shellQuote("require(\"hyprpeach\").focus_desktop({ desktop = " + desktop + " })"))
  }

  // Ink chosen against the bar, not against the theme's palette: white on a
  // dark bar, black on a light one. Rec. 709 luminance, which weights green
  // the way an eye does -- a plain average calls mid greens dark and picks the
  // wrong ink on exactly the themes that were already marginal.
  readonly property color barBackground: Color.bar.background
  readonly property real barLuminance:
    0.2126 * root.barBackground.r + 0.7152 * root.barBackground.g + 0.0722 * root.barBackground.b
  readonly property color ink: root.barLuminance < 0.5 ? "#ffffff" : "#000000"

  // Whitespace around the strip as a whole, so it reads as its own block
  // rather than as more of whatever widget sits next to it.
  // GEOMETRY, DERIVED RATHER THAN DIALLED IN.
  //
  // The bar is transparent, so there is no painted bar to be centred inside --
  // its 37 logical pixels have no edges an eye can see. What is visible is the
  // GUTTER: the bar, plus the gap Hyprland leaves between the bar and the
  // nearest window. That gutter is `barSize + windowGap` across, and a tile
  // inset by exactly one window gap from both of its sides is symmetric to
  // look at. Measuring against the bar instead put the tile 5px from the screen
  // edge and 15px from the window, which read as shoved against the edge.
  //
  // `Style.gapsOut` is the shell's own reading of Hyprland's
  // `general:gaps_out`, re-read when the compositor changes -- but it stores
  // HALF the value, so the real gap is twice it.
  //
  // Every term below is an integer of logical pixels, so the sums are exact at
  // any font base size rather than accumulating a rounding error per step.
  readonly property string barPosition: root.bar ? root.bar.position : "top"
  readonly property int windowGap: Style.gapsOut * 2
  readonly property int barEndPadding: Style.space(8)

  // WHEN HYPRLAND DRAWS NO GAP AT ALL.
  //
  // Every measure below is derived from the window gap, because the whole point
  // is to line the strip up with the windows. Set `general:gaps_out = 0` and
  // there is no gutter left to line up with -- and because one number feeds all
  // of them, they do not degrade one at a time, they collapse together. Tiles
  // grow to the full thickness of the bar, the spacing between them goes to
  // nothing so the three states run together into one block, and the leading
  // margin turns negative and reaches back over whatever widget sits before the
  // strip.
  //
  // So the measures that exist to be SEEN fall back to the shell's own smallest
  // comfortable spacing, and the one that exists to ALIGN stops at zero rather
  // than reaching past the bar's own padding into its neighbour. A desk that
  // does use gaps is unaffected: there the window gap is already the larger
  // number and the leading margin is already positive.
  readonly property int visibleGap: root.windowGap > 0 ? root.windowGap : Style.space(4)

  // Hyprland's border width. A window's FRAME starts at the window gap, but its
  // border sits on top of that and the content starts inside it -- and the
  // inner edge is the one an eye reads as "the top of the window", because the
  // border is thin and usually a different colour. Aligning to the frame
  // measured correct and looked wrong by exactly this much.
  //
  // The shell reads gaps and rounding for itself but not this, so it is read
  // here the same way -- once, at startup, off hyprctl.
  property int windowBorder: 2

  Process {
    running: true
    command: ["hyprctl", "-j", "getoption", "general:border_size"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          if (parsed && typeof parsed.int === "number" && parsed.int >= 0) root.windowBorder = parsed.int
        } catch (error) {
          // Leave the default. A strip two pixels out is better than no strip.
        }
      }
    }
  }

  // Across the bar: the gutter is barSize + windowGap, less a windowGap each
  // side, which leaves exactly this.
  readonly property int tileThickness: Math.max(1, root.barSize - root.visibleGap)

  // Along the bar: the first tile starts where a tiled window's CONTENT starts
  // -- the gap, plus the border drawn inside it. The bar pads its own ends
  // further in than that, so this is often negative: the strip reaches back out
  // past the bar's padding to meet the window.
  //
  // Never negative: past the bar's own padding there is no window edge to meet,
  // only the widget before the strip, and reaching into it is what put the
  // strip under Omarchy's menu button on a gapless desk.
  readonly property int leadingGap: Math.max(0, root.windowGap + root.windowBorder - root.barEndPadding)
  readonly property int trailingGap: root.barEndPadding
  // One window gap between tiles, the same measure as everything else here.
  readonly property int tileSpacing: root.visibleGap

  // Which side of the bar the screen edge is on. The tile sits a window gap
  // clear of that edge and flush with the bar's inner side.
  readonly property bool screenEdgeAtStart: root.barPosition === "left" || root.barPosition === "top"
  readonly property int crossStart: root.screenEdgeAtStart ? root.visibleGap : 0
  readonly property int crossEnd: root.screenEdgeAtStart ? 0 : root.visibleGap

  implicitWidth: root.vertical ? root.barSize : grid.implicitWidth + root.leadingGap + root.trailingGap
  implicitHeight: root.vertical ? grid.implicitHeight + root.leadingGap + root.trailingGap : root.barSize

  GridLayout {
    id: grid
    anchors.fill: parent
    // Along the bar: leading/trailing. Across it: one window gap clear of the
    // screen edge, nothing on the inner side.
    anchors.topMargin: root.vertical ? root.leadingGap : root.crossStart
    anchors.bottomMargin: root.vertical ? root.trailingGap : root.crossEnd
    anchors.leftMargin: root.vertical ? root.crossStart : root.leadingGap
    anchors.rightMargin: root.vertical ? root.crossEnd : root.trailingGap
    columns: root.vertical ? 1 : Math.max(1, root.desktops.length)
    columnSpacing: root.vertical ? 0 : root.tileSpacing
    rowSpacing: root.vertical ? root.tileSpacing : 0

    Repeater {
      model: root.desktops

      Item {
        id: cell
        required property int modelData

        // Across every panel: a desktop is occupied if anything is on it.
        readonly property int windowCount: root.windowCounts[modelData] || 0
        readonly property bool occupied: windowCount > 0
        readonly property bool current: root.activeDesktop() === modelData

        implicitWidth: root.vertical ? root.tileThickness : root.tileThickness
        implicitHeight: root.tileThickness

        Rectangle {
          id: tile
          anchors.centerIn: parent
          // Rounded tiles rather than circles: a circle has to clear its own
          // diagonal, so it wastes the corners of every cell and forces the
          // strip longer than it needs to be. A tile fills the cell and packs.
          width: cell.width
          height: cell.height
          radius: Math.round(Math.min(width, height) * 0.3)

          // One ink, three alphas. Nothing, a hint, and all but solid.
          color: cell.current
            ? Util.alpha(root.ink, 0.92)
            : (cell.occupied ? Util.alpha(root.ink, 0.14) : "transparent")

          Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
        }

        WidgetButton {
          id: button
          anchors.fill: parent
          bar: root.bar

          // Desktop 10 is drawn as "0" because that is the key you press for
          // it -- the number row runs 1 to 0, not 1 to 10. It also keeps every
          // numeral one character wide, so it sits in a circle instead of
          // straining against one.
          text: cell.modelData === 10 ? "0" : String(cell.modelData)
          // The invert: on the near-solid tile the numeral drops to the bar's
          // own background, so the pair is one ink with its roles swapped.
          // Empty and occupied are the same ink again, further down.
          foreground: cell.current
            ? root.barBackground
            : Util.alpha(root.ink, cell.occupied ? 0.92 : 0.40)
          useActiveColor: false
          opacity: 1

          horizontalMargin: 0
          verticalPadding: 0
          fixedWidth: root.tileThickness
          fixedHeight: root.tileThickness

          tooltipText: cell.current
            ? ("Desktop " + cell.modelData + " — here")
            : (cell.occupied
                ? ("Desktop " + cell.modelData + " — " + cell.windowCount + (cell.windowCount === 1 ? " window" : " windows"))
                : ("Desktop " + cell.modelData + " — empty"))

          Behavior on opacity { NumberAnimation { duration: 140 } }

          onPressed: function() { root.focusDesktop(cell.modelData) }
        }
      }
    }
  }
}
