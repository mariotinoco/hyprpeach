import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// A big number, in the middle of every screen, when the desktop changes.
//
// It watches the compositor rather than listening for a keybinding, so it fires
// for every way a desktop can change — the keyboard, a click in the bar, a
// script — and hyprpeach needs to know nothing about it.
//
// Visual only: the layer-shell input region is left empty, so this never eats a
// click even while it is on screen.
Item {
  id: root

  // WHICH PANELS ARE BEING HELD, AND ON WHAT.
  //
  // A held panel does not move when the desk does, so on that screen the big
  // number would otherwise announce a desktop it is not showing -- the single
  // most confusing thing this overlay could do. It shows the number that is
  // STAYING, with a padlock, which is also the reminder that `SUPER + Y` will
  // let it go.
  //
  // Published by the library because this is a different process from the Lua
  // that knows it; the desktop is carried with the name because Quickshell's
  // per-monitor workspace is stale for anything but the focused screen.
  property var heldPanels: ({})

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

  // PRIMED BY THE FIRST READ, NOT BY THE FIRST CHANGE.
  //
  // Whether a panel is held has to arrive from disk, so on login it arrives as
  // a CHANGE -- and a per-panel "ignore the first one" guard then swallows the
  // first real toggle of any panel that happened not to be held at startup,
  // which is every panel, the first time. Exactly the trap the desktop number
  // fell into above, reached from the other direction.
  //
  // Assigning `heldPanels` re-evaluates the delegates' `held` synchronously, so
  // setting this AFTER the assignment lets the initial load pass through
  // unannounced and every later one ring.
  property bool heldPanelsReady: false

  FileView {
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hyprpeach-held-panels"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.heldPanels = root.parseHeldPanels(text())
      root.heldPanelsReady = true
    }
    onLoadFailed: {
      root.heldPanels = ({})
      root.heldPanelsReady = true
    }
  }

  property int holdMilliseconds: 350
  // A fraction of the screen's VERTICAL size, so it scales proportionally from
  // a 1080p laptop to a 2160-tall ultrawide. Height rather than the short edge,
  // because on an ultrawide the two are the same number and on a portrait
  // monitor the height is still what a reader's eye measures against.
  property real sizeFraction: 0.13
  // Alpha on the NUMERAL, not on the whole item. Fading the item would ghost
  // the outline with the fill and lose exactly the contrast the outline is
  // there to provide; giving the fill its own alpha and keeping the outline
  // firmer leaves the number legible while you still see straight through it.
  property real fillOpacity: 0.45
  property real outlineOpacity: 0.85

  property bool opened: false
  property int desktop: -1
  property int fadeMilliseconds: 200

  // A DESK SWITCH IS ANNOUNCED BY THE LIBRARY, ONCE, AND THIS LISTENS.
  //
  // It used to be inferred from the focused workspace, and focus moves for
  // reasons that are not switches: with one panel held, the monitors show
  // different desktops, so the mouse crossing between them read as a switch
  // and flashed a number when nothing had moved. peach.focus_desktop fires
  // `hyprpeach-desktop,N` after every paired switch -- however it was asked
  // for: a key, a click on the strip, a script -- and only then.
  //
  // NOT WHILE THE OVERVIEW IS OPEN. A switch made there -- a cell, or a
  // number key pressed over the grid -- is one you watched happen: the
  // overview closes onto the desktop you chose, and a number over it is noise.
  // The overview announces itself open and closed; a switch arrives while it
  // still counts as open, because it closes on that same switch.
  property bool overviewOpen: false

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "custom") return
      var data = String(event.data || "")
      if (data === "hyprpeach-overview,open") { root.overviewOpen = true; return }
      if (data === "hyprpeach-overview,closed") { root.overviewOpen = false; return }
      if (data.indexOf("hyprpeach-desktop,") !== 0) return
      if (root.overviewOpen) return
      var next = parseInt(data.substring("hyprpeach-desktop,".length), 10)
      if (!(next > 0)) return
      root.desktop = next
      root.opened = true
      hideTimer.restart()
    }
  }

  Timer {
    id: hideTimer
    interval: root.holdMilliseconds
    onTriggered: root.opened = false
  }


  // One overlay per screen. A single PanelWindow lands on one monitor, which
  // on a paired desk is exactly the wrong answer: both panels just moved, so
  // both should say so. Whichever screen you happen to be looking at has the
  // number on it.
  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: panel
        required property var modelData

        screen: modelData

        // A SMALL SURFACE, MAPPED ONCE AND KEPT.
        //
        // This was a full-screen layer: sixteen megapixels a side, created and
        // destroyed on every switch. The surface itself mapped in a few
        // milliseconds either way -- measured -- but the first frame had a
        // whole screen to composite and a 280px outlined glyph to rasterise
        // before anything appeared, and both of those land on a compositor
        // already busy drawing the windows of the desktop you just arrived at.
        // Which is why it lagged going to a busy desktop and not to an empty
        // one.
        //
        // Sized to the numeral instead. With no anchors a layer surface is
        // centred, which is where this wants to be anyway.
        //
        // MAPPED ONCE AND KEPT, which is where the speed came from.
        //
        // Creating the surface per switch costs a layer-shell configure
        // roundtrip, and it is most of the latency: measured at the pixels,
        // ~98ms mapping each time against ~64ms when the surface is already
        // up, and the unmapped case is bimodal -- sometimes 30ms, sometimes
        // 98ms, depending on whether the second monitor's roundtrip happens to
        // pipeline behind the first. Steady is worth as much as fast here; a
        // flash that arrives at an unpredictable time is what reads as sluggish.
        //
        // The cost is a surface that sits on the overlay layer for the session.
        // It is 450x450, transparent, and its input region is empty, so it
        // neither draws nor swallows a click -- the full-screen version of this
        // was up for half a second on every switch for a whole afternoon of
        // testing without ever eating one. It does mean the compositor has one
        // more surface to consider above a fullscreen window; set `visible` to
        // `root.opened || numeral.opacity > 0` to go back to mapping on demand.
        // Sized from THIS panel's screen, not from the first one. A single
        // figure for every monitor puts a 1080p-sized numeral on a 4K panel
        // beside it, or the reverse, on any desk whose screens differ.
        readonly property int glyphSize: Math.max(48, Math.round(
          (panel.screen ? panel.screen.height : 1080) * root.sizeFraction))
        readonly property int glyphBox: Math.round(panel.glyphSize * 1.6)

        // This screen, not the focused one: holding is per panel, and the whole
        // point is that this panel differs from the rest of the desk.
        readonly property string screenName: panel.screen ? String(panel.screen.name || "") : ""
        readonly property bool held: panel.screenName !== "" && root.heldPanels[panel.screenName] !== undefined

        // HOLDING AND RELEASING GET THEIR OWN FLASH, on the screen it happened
        // to. Changing desktop announces itself on every screen that moved; the
        // one thing that never announced itself was the act that stops a screen
        // moving at all, which is also the one you most want confirmed, because
        // it is silent and it is a mode you can forget you are in.
        //
        // Closed when it takes hold, open when it lets go, so the two presses
        // of the same key do not look alike.
        property bool lockOpened: false
        property bool lockClosing: false

        onHeldChanged: {
            // Nothing flashes for the state the session started in.
            if (!root.heldPanelsReady) return
            panel.lockClosing = panel.held
            panel.lockOpened = true
            lockTimer.restart()
        }

        Timer {
            id: lockTimer
            interval: root.holdMilliseconds
            onTriggered: panel.lockOpened = false
        }

        implicitWidth: panel.glyphBox
        implicitHeight: panel.glyphBox
        visible: true
        color: "transparent"
        WlrLayershell.namespace: "hyprpeach-desktop-osd"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        // Visual only: an empty input region, so a surface that is always up
        // never eats a click.
        mask: Region {}

        Text {
          id: numeral
          anchors.centerIn: parent
          text: root.desktop > 0 ? String(root.desktop) : ""

          color: Util.alpha(Color.foreground, root.fillOpacity)
          font.family: Style.font.family
          font.bold: true
          font.pixelSize: panel.glyphSize

          // An outline in the background colour holds against a light, dark or
          // busy wallpaper, which a drop shadow does not.
          style: Text.Outline
          styleColor: Util.alpha(Color.background, root.outlineOpacity)

          // Rasterised once into a texture and then composited, rather than
          // re-drawn from outlines every frame it is up.
          layer.enabled: true

          // A HELD PANEL SAYS NOTHING. It did not move, so it has no news, and a
          // number flashing on a screen that stayed put is this overlay
          // contradicting itself. The padlock on the bar strip is the standing
          // answer; a flash is for changes.
          //
          // No fade in: on something this brief a ramp reads as lag. Straight
          // up at full size, and only the exit is animated.
          opacity: (root.opened && !panel.held) ? 1 : 0
          Behavior on opacity {
            NumberAnimation { duration: root.opened ? 0 : root.fadeMilliseconds; easing.type: Easing.OutCubic }
          }
        }

        // The padlock that says a screen has just been held, or just let go.
        //
        // On a backing plate for the same reason the numeral carries an
        // outline: drawn shapes have nothing to hold them against a light
        // wallpaper, a dark one, or a photograph. Same size and place as the
        // number, because it is the same kind of announcement.
        Rectangle {
          id: lockFlash
          visible: panel.lockOpened || opacity > 0
          anchors.centerIn: parent

          readonly property int mark: Math.round(panel.glyphSize * 0.52)
          width: Math.round(mark * 1.45)
          height: Math.round(mark * 1.45)
          radius: Math.round(width * 0.26)
          color: Util.alpha(Color.background, root.outlineOpacity)

          opacity: panel.lockOpened ? 1 : 0
          Behavior on opacity {
            NumberAnimation { duration: panel.lockOpened ? 0 : root.fadeMilliseconds; easing.type: Easing.OutCubic }
          }

          Item {
            anchors.centerIn: parent
            width: lockFlash.mark
            height: Math.round(lockFlash.mark * 1.06)

            // Shackle. Closed, it sits centred over the body; open, it is
            // hinged off to one side and lifted clear, which is the difference
            // an eye reads before it reads anything else.
            Item {
              anchors.top: parent.top
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.horizontalCenterOffset: panel.lockClosing ? 0 : Math.round(parent.width * 0.30)
              width: Math.round(parent.width * 0.58)
              height: Math.round(parent.height * 0.46)
              clip: true
              Rectangle {
                width: parent.width
                height: parent.height * 2
                radius: width / 2
                color: "transparent"
                border.width: Math.max(2, Math.round(lockFlash.mark * 0.14))
                border.color: Color.foreground
              }
            }

            Rectangle {
              anchors.bottom: parent.bottom
              width: parent.width
              height: Math.round(parent.height * 0.54)
              radius: Math.max(2, Math.round(lockFlash.mark * 0.15))
              color: Color.foreground
            }
          }
        }
      }
    }
  }
}