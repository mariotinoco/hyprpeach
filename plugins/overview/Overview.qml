import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model

// Every desktop at once: a 3 x 3 grid on every monitor.
//
// SUPER + TAB or SUPER + 0 fires a Hyprland custom event (peach.toggle_overview
// in init.lua), and every shell instance hears it, so every monitor opens
// together. Each monitor shows the nine desktops as they are on IT -- Model.js
// says why that, and not one grid across the desk -- and choosing one turns the
// whole desk through the same peach.focus_desktop the number keys use.
//
// WHY THE WINDOWS ARE CAPTURED ONE BY ONE. Hyprland does not render a
// workspace nobody is looking at, so there is no picture of a hidden desktop to
// take. It will export any single window, visible or not, through
// hyprland-toplevel-export, which Quickshell's ScreencopyView speaks; so a cell
// is the wallpaper with each window's own picture laid on it at its real
// position. Measured on Hyprland 0.56.2: a terminal on a hidden workspace comes
// back with content. An application that stops drawing while hidden shows its
// last frame, which is the right picture of where you left it.
Item {
  id: root

  property bool opened: false
  property var state: ({ monitors: [], clients: [], workspaces: [], error: "" })
  property var heldPanels: ({})

  readonly property string backgroundPath: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"

  function toggle() {
    if (root.opened) root.close()
    else reader.running = true
  }

  function close() {
    root.opened = false
  }
  onOpenedChanged: root.announce()

  function focusDesktop(desktop) {
    if (desktop < 1) return
    focuser.command = ["hyprctl", "eval", "require(\"hyprpeach\").focus_desktop({ desktop = " + desktop + " })"]
    focuser.running = true
    root.close()
  }

  function toplevelFor(clientAddress) {
    var address = Model.toplevelAddress(clientAddress)
    var values = Hyprland.toplevels.values
    for (var index = 0; index < values.length; index++)
      if (values[index].address === address) return values[index]
    return null
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "custom" && event.data === "hyprpeach-overview,toggle") root.toggle()
    }
  }

  // READ FRESH ON EVERY OPEN, in one process, so the monitors, windows and
  // workspaces drawn are one moment's state. Quickshell's own per-monitor
  // active workspace goes stale for a monitor that does not have focus, and
  // the whole point of this view is the monitors you are not looking at.
  Process {
    id: reader
    command: ["sh", "-c", "printf '{\"monitors\":'; hyprctl -j monitors; printf ',\"clients\":'; hyprctl -j clients; printf ',\"workspaces\":'; hyprctl -j workspaces; printf '}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.state = Model.parse(text)
        root.opened = root.state.error === ""
      }
    }
  }

  Process { id: focuser }

  // OPEN AND CLOSED, ANNOUNCED -- for the animated-desktops renderer, which draws each
  // desktop's viewport in the cells this leaves see-through, and has to know
  // when to rise above the windows to do it. SUPER + TAB only says "toggle";
  // this overview is what knows which way it went, and closes on keys and
  // clicks the library never sees.
  //
  // ALWAYS THE STATE AS IT IS NOW, never a queue of what it was. One process
  // announces at a time; a change while it runs is caught when it finishes
  // and announced then. A dropped "closed" would leave the scene above every
  // window, and two processes racing could land "open" after "closed".
  property string announced: "closed"
  Process {
    id: announcer
    onExited: root.announce()
  }
  function announce() {
    var state = root.opened ? "open" : "closed"
    if (announcer.running || state === root.announced) return
    root.announced = state
    announcer.command = ["hyprctl", "eval", "hl.dispatch(hl.dsp.event(\"hyprpeach-overview," + state + "\"))"]
    announcer.running = true
  }

  // Whether the animated desktops are behind the desk (plugins/animated-desktops writes this).
  // With it, the cells are windows onto the universe rather than onto the
  // wallpaper: no scrim, no picture, only the frames and the live windows.
  property bool animated: false
  FileView {
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hyprpeach-animated-desktops"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.animated = text().trim() === "running"
    onLoadFailed: root.animated = false
  }

  // Held panels, as the library publishes them: "<monitor> <desktop>" lines.
  FileView {
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hyprpeach-held-panels"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.heldPanels = Model.heldPanels(text())
    }
    onLoadFailed: root.heldPanels = ({})
  }

  readonly property int current: Model.currentDesktop(root.state)

  Variants {
    model: Quickshell.screens

    delegate: Component {
      PanelWindow {
        id: panel
        required property var modelData
        screen: modelData

        readonly property var monitor: Model.monitorNamed(root.state, panel.screen ? String(panel.screen.name || "") : "")
        readonly property var grid: panel.monitor ? Model.monitorGrid(panel.monitor) : ({ cells: [], scale: 1 })

        visible: root.opened
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "hyprpeach-overview"
        WlrLayershell.layer: WlrLayer.Overlay
        // EXCLUSIVE ON EVERY MONITOR, not only the one you opened it from.
        // While any layer surface holds the keyboard exclusively, Hyprland
        // hit-tests the pointer against those surfaces alone and hands it to
        // the first of them when none is under the cursor
        // (src/managers/input/InputManager.cpp, 0.56.2). With one exclusive
        // monitor, every other monitor's overview could be seen and not
        // touched. The keyboard lands on one of them; each handles the keys.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        Rectangle {
          anchors.fill: parent
          color: root.animated ? "transparent" : Util.alpha(Color.background, 0.94)
        }

        // A click on the space between cells closes it, the way a click off
        // any popup does.
        MouseArea {
          anchors.fill: parent
          onClicked: root.close()
        }

        Item {
          anchors.fill: parent
          focus: true
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || Model.closesOverview(event.text)) { root.close(); event.accepted = true; return }
            var desktop = Model.desktopForKey(event.text)
            if (desktop > 0) { root.focusDesktop(desktop); event.accepted = true }
          }
        }

        Repeater {
          model: panel.grid.cells

          delegate: Item {
            id: cell
            required property var modelData
            readonly property bool current: cell.modelData.desktop === root.current
            readonly property var windows: root.opened && panel.monitor ? Model.windowsOnMonitorDesktop(root.state, panel.monitor, cell.modelData.desktop) : []

            x: cell.modelData.x
            y: cell.modelData.y
            width: cell.modelData.width
            height: cell.modelData.height

            Rectangle {
              id: frame
              anchors.fill: parent
              radius: Math.round(cell.height * 0.02)
              color: root.animated ? "transparent" : Color.background
              clip: true

              Image {
                visible: !root.animated
                anchors.fill: parent
                source: Util.fileUrl(root.backgroundPath)
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(cell.width, cell.height)
                asynchronous: true
                cache: true
                opacity: 0.8
              }

              Repeater {
                model: cell.windows
                delegate: Item {
                  id: thumbnail
                  required property var modelData
                  readonly property var toplevel: root.opened ? root.toplevelFor(thumbnail.modelData.client.address) : null
                  x: thumbnail.modelData.x * panel.grid.scale
                  y: thumbnail.modelData.y * panel.grid.scale
                  width: Math.max(1, thumbnail.modelData.width * panel.grid.scale)
                  height: Math.max(1, thumbnail.modelData.height * panel.grid.scale)

                  // Until a frame arrives, or if one never does: the window's
                  // class, where the window is, so the layout still reads.
                  Rectangle {
                    anchors.fill: parent
                    visible: !view.hasContent
                    color: Util.alpha(Color.foreground, 0.08)
                    border.color: Util.alpha(Color.foreground, 0.25)
                    Text {
                      anchors.centerIn: parent
                      width: parent.width - 8
                      elide: Text.ElideRight
                      horizontalAlignment: Text.AlignHCenter
                      text: thumbnail.modelData.client.class || ""
                      color: Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Math.max(9, Math.min(parent.height * 0.18, 18))
                    }
                  }

                  // LIVE, AND IT MUST STAY LIVE. A video playing on a desktop
                  // you are not on keeps playing here -- measured, and the
                  // best thing this view does. `live` is what asks for every
                  // new frame rather than the first; do not trade it for a
                  // still to save work without seeing what it costs.
                  ScreencopyView {
                    id: view
                    anchors.fill: parent
                    captureSource: thumbnail.toplevel ? thumbnail.toplevel.wayland : null
                    live: root.opened
                    constraintSize: Qt.size(thumbnail.width, thumbnail.height)
                  }
                }
              }
            }

            // The border is drawn over the pictures, not under them, or a
            // window filling the desktop would hide which cell is current.
            Rectangle {
              anchors.fill: parent
              radius: frame.radius
              color: "transparent"
              border.width: cell.current ? Math.max(3, Math.round(cell.height * 0.006)) : (hover.containsMouse ? 2 : 1)
              border.color: cell.current ? Color.foreground
                : Util.alpha(Color.foreground, hover.containsMouse ? 0.7 : 0.25)
            }

            Text {
              anchors { left: parent.left; bottom: parent.bottom; margins: Math.round(cell.height * 0.04) }
              text: String(cell.modelData.desktop)
              color: Color.foreground
              style: Text.Outline
              styleColor: Util.alpha(Color.background, 0.8)
              font.family: Style.font.family
              font.bold: true
              font.pixelSize: Math.round(cell.height * 0.12)
            }

            MouseArea {
              id: hover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.focusDesktop(cell.modelData.desktop)
            }
          }
        }
      }
    }
  }
}
