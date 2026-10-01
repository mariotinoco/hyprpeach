import QtQuick
import QtQuick.Layouts
import Quickshell
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

  // NINE DESKTOPS, ON BANDS TEN WORKSPACES WIDE. Both are fixed in the library
  // (init.lua says why): nine is the 3 x 3 the overview and the animated desktops are
  // built on, and ten keeps every workspace number where 2.x put it.
  readonly property int desktopCount: 9
  readonly property int bandWidth: 10
  function desktopOf(workspaceId) {
    if (workspaceId < 1) return -1
    var desktop = ((workspaceId - 1) % root.bandWidth) + 1
    return desktop > root.desktopCount ? -1 : desktop
  }

  // WHETHER THIS PARTICULAR PANEL IS BEING HELD.
  //
  // `SUPER + Y` holds the panel under the pointer: it stops answering desktop
  // switches and stays on whatever it was showing. That is the one state in
  // this model that makes the panels disagree ON PURPOSE, which is also
  // exactly what a bug in the library looks like -- so a hold that nothing
  // draws is indistinguishable from the thing being broken.
  //
  // The state lives in Lua inside Hyprland and this is a different process, so
  // the library publishes the held monitors to a file and this watches it.
  // Omarchy's own shell reads `window-no-gaps` the same way; this is that
  // idiom, not a new one.
  readonly property string screenName: {
    var window = root.QsWindow.window
    return window && window.screen ? String(window.screen.name || "") : ""
  }
  property var heldPanels: ({})
  readonly property bool held: root.screenName !== "" && root.heldPanels[root.screenName] !== undefined
  readonly property int heldDesktop: root.held ? root.heldPanels[root.screenName] : -1

  // "<monitor name> <desktop>" per line. The desktop is carried because a held
  // panel is exactly where Quickshell's per-monitor workspace goes stale.
  function parseHeldPanels(raw) {
    var panels = ({})
    var lines = String(raw || "").split("\n")
    for (var index = 0; index < lines.length; index++) {
      var line = lines[index].trim()
      if (line === "") continue
      var gap = line.lastIndexOf(" ")
      var name = gap < 0 ? line : line.substring(0, gap)
      var desktop = gap < 0 ? -1 : parseInt(line.substring(gap + 1), 10)
      panels[name] = isNaN(desktop) ? -1 : desktop
    }
    return panels
  }

  FileView {
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hyprpeach-held-panels"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.heldPanels = root.parseHeldPanels(text())
    onLoadFailed: root.heldPanels = ({})
  }

  // Every desktop is persistent, so the desktops ARE 1..desktopCount. Deriving
  // the list by scanning the live workspaces instead let it lose an entry for a
  // frame whenever the model was between updates, and a cell that disappears
  // and comes back is the most distracting thing a status bar can do.
  readonly property var desktops: {
    var list = []
    for (var desktop = 1; desktop <= root.desktopCount; desktop++) list.push(desktop)
    return list
  }

  // Windows per desktop, summed across every panel: the question is "is there
  // something on 3", not "is there something on 3 down here".
  readonly property var windowCounts: {
    var counts = ({})
    var values = Hyprland.workspaces.values
    for (var index = 0; index < values.length; index++) {
      var workspace = values[index]
      var desktop = root.desktopOf(workspace.id)
      if (desktop < 1) continue
      counts[desktop] = (counts[desktop] || 0) + workspace.toplevels.values.length
    }
    return counts
  }

  // THIS BAR'S OWN MONITOR, not whichever workspace has the focus.
  //
  // Reading the focused workspace is right exactly while the panels agree, and
  // they are built to — so the difference never showed. A held panel breaks it
  // on purpose: with the pointer resting on a held screen the focus sits there
  // too, and every other bar on the desk would light up the held panel's
  // desktop instead of its own. Each bar answers for the screen it is drawn on.
  // A held panel shows what it is holding; every other panel shows the desk.
  //
  // Reading the focused workspace is right exactly while the panels agree, and
  // they are built to -- so the difference never showed. Holding breaks it on
  // purpose, and the held number cannot be read back out of Quickshell:
  // measured with the desk on 8 and this panel held on 1, Quickshell reported
  // this monitor's active workspace as 8. So the library publishes the number
  // it already knows, and this trusts that.
  function activeDesktop() {
    if (root.held && root.heldDesktop >= 1) return root.heldDesktop
    if (!Hyprland.focusedWorkspace || Hyprland.focusedWorkspace.id < 1) return -1
    return root.desktopOf(Hyprland.focusedWorkspace.id)
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

  // HOW THE STRIP SITS INSIDE THE BAR IS THE BAR'S BUSINESS, NOT HYPRLAND'S.
  //
  // These were all derived from `general:gaps_out`, on the reasoning that the
  // strip should line up with the windows. Across the bar that reasoning is
  // simply wrong -- the tiles centre on the bar, like every other widget -- and
  // it fails at both ends besides, because a window gap is a number a person
  // can set to anything and a bar is 37 pixels wide. At `gaps_out = 0` the
  // tiles filled the bar corner to corner and ran into each other; at 40 the
  // arithmetic went negative and the current tile collapsed to a single dot.
  //
  // Deriving them from the shell's own spacing scale closes both ends at once,
  // and closes them by construction rather than by clamping: the bar and this
  // scale both track the theme's font size, so they move together and there is
  // no value of `gaps_out` that can make a tile vanish or overflow. The numbers
  // below are the ones this desk already had at the default gap, so nothing
  // moves on a stock setup.
  readonly property int tileInset: Style.space(5)

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

  // Across the bar: the bar, less an equal inset on each side.
  readonly property int tileThickness: Math.max(1, root.barSize - 2 * root.tileInset)

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
  // Along the bar, between tiles. Also the shell's scale rather than the window
  // gap: tying it to `gaps_out` stretched the strip down the whole panel on a
  // desk with roomy gaps.
  readonly property int tileSpacing: Style.space(10)

  // CENTRED IN THE BAR, which is not what this measured against at first.
  //
  // The original reasoning was that the bar is transparent, so what an eye sees
  // is the GUTTER -- the bar plus the gap Hyprland leaves between it and the
  // nearest window -- and a tile centred in that gutter is symmetric between
  // the window and the screen edge. That is true, and it is still the wrong
  // answer, because it is not what the eye is comparing against.
  //
  // Every other widget in the bar -- tray, clock, battery, all of them --
  // centres on the BAR. Measured on a 37px bar: they land on x=7661.5 and the
  // gutter-centred strip landed on 7656, so the desktop tiles sat five pixels
  // off from every icon beneath them, down the whole length of the panel. A
  // strip that disagrees with its neighbours reads as broken however
  // defensible the arithmetic behind it is.
  //
  // Split the leftover evenly, and carry the odd pixel on the far side so the
  // two never sum to more than the bar.
  readonly property int crossStart: Math.max(0, Math.floor((root.barSize - root.tileThickness) / 2))
  readonly property int crossEnd: Math.max(0, root.barSize - root.tileThickness - root.crossStart)

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
            : (cell.occupied ? Util.alpha(root.ink, root.held ? 0.07 : 0.14) : "transparent")

          Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
        }

        // THE HELD TILE IS A PADLOCK. Not a number with a mark on it.
        //
        // A badge in the corner was legible as a shape and illegible as a
        // meaning: at a tile's size there is room for one thing, and two things
        // in a 27px square is neither. The tile that is held stops being a
        // number and becomes a lock, which is also the truth -- that desktop is
        // not somewhere this panel can go until you let it go.
        //
        // Drawn rather than set in a font, because there is no icon font here
        // guaranteed to have one and a glyph that turns into a box on somebody
        // else's theme is worse than no mark. Inked in the BAR's colour rather
        // than the strip's, because it lies on the near-solid current tile,
        // which is the one place the ink is inverted.
        Item {
          id: lockMark
          visible: root.held && cell.modelData === root.heldDesktop
          width: Math.round(root.tileThickness * 0.46)
          height: Math.round(width * 1.08)
          anchors.centerIn: parent
          z: 2

          readonly property color mark: cell.current ? root.barBackground : Util.alpha(root.ink, 0.92)

          // Shackle: a ring with its bottom half clipped away.
          Item {
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.round(parent.width * 0.6)
            height: Math.round(parent.height * 0.5)
            clip: true
            Rectangle {
              width: parent.width
              height: parent.height * 2
              radius: width / 2
              color: "transparent"
              border.width: Math.max(1, Math.round(lockMark.width * 0.2))
              border.color: lockMark.mark
            }
          }

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: Math.round(parent.height * 0.55)
            radius: Math.max(1, Math.round(lockMark.width * 0.22))
            color: lockMark.mark
          }
        }

        WidgetButton {
          id: button
          anchors.fill: parent
          bar: root.bar

          // Desktop 10 is drawn as "0" because that is the key you press for
          // it -- the number row runs 1 to 0, not 1 to 10. It also keeps every
          // numeral one character wide, so it sits in a circle instead of
          // straining against one.
          // The held tile carries the lock instead of its numeral.
          text: lockMark.visible ? "" : String(cell.modelData)
          // The invert: on the near-solid tile the numeral drops to the bar's
          // own background, so the pair is one ink with its roles swapped.
          // Empty and occupied are the same ink again, further down.
          // EVERY OTHER DESKTOP GOES QUIET ON A HELD PANEL. They are not
          // places this screen can go while it is held, and drawing them at
          // full strength invites a click that will do nothing to it.
          foreground: cell.current
            ? root.barBackground
            : Util.alpha(root.ink, root.held ? 0.20 : (cell.occupied ? 0.92 : 0.40))
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
