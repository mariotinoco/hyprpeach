import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A bar button that answers "what is on 3002", and lets you stop it.
//
// WHY THIS IS A SEPARATE PLUGIN AND NOT A SECOND WIDGET IN hyprpeach.desktops.
//
// Omarchy's registry keys plugins by manifest id and reads exactly one bar
// widget out of each: `entryPointUrl(manifest, "barWidget")` takes a single path
// string, and the third-party scan is `for sub in "$dir"/*/` — one manifest per
// directory, one directory per id (shell/services/PluginRegistry.qml, Omarchy
// quattro). First-party plugins may carry sibling `*.manifest.json` files
// because their scan runs `find -mindepth 2 -maxdepth 3`; a user plugin's scan
// does not. So a repository that wants two bar widgets ships two plugin
// directories: this one lives at plugins/dev-ports inside the hyprpeach clone, and
// `hyprpeach plugin add dev-ports` links it into Omarchy's plugins folder.
//
// Folding it into the desktops widget instead is worse than it looks. That
// widget's geometry exists to make its FIRST tile meet the edge of a tiled
// window — it is built to lead its section — so anything hung off its end sits
// inside arithmetic that was never about it, and it would inherit
// `defaultSection: left` when the thing this belongs beside is the network
// widget on the right.
//
// WHAT IT READS, AND WHY THAT IS A SUBPROCESS: see listening-ports, beside this file.
Panel {
  id: root
  moduleName: "hyprpeach.dev-ports"
  ipcTarget: "hyprpeach.dev-ports"
  manageIpc: false

  // THE MODEL AND THE LAST ERROR ARE KEPT SEPARATELY, AND A FAILURE KEEPS THE
  // ROWS.
  //
  // The reader is looking at a list and about to click one of its rows.
  // Replacing the list with an error message moves that row out from under the
  // pointer and takes the pid they had just read with it. So a failed refresh
  // leaves the previous records standing and puts the reason in the status line.
  property var records: []
  property string lastError: ""
  property string actionStatus: ""
  property bool reading: false


  property int cursorRow: 0
  property bool cursorActive: false

  // The record a confirmation is open about, and which signal it is about.
  //
  // A COPY OF THE RECORD, NOT AN INDEX INTO THE LIST. The poll keeps running
  // while the question is on screen, so an index would be a question about
  // whichever process had moved into that slot by the time it was answered.
  property var pendingRecord: null
  property string pendingSignal: ""
  readonly property bool confirming: root.pendingRecord !== null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  // One glyph for the bar and the panel it opens: see the bar button below.
  readonly property string anchorGlyph: "\u{F0031}"

  // THE THEME'S OWN COLOURS, READ FROM THE THEME.
  //
  // The shell keeps five colours -- foreground, background, accent, urgent,
  // muted -- which is enough to draw a panel and not enough to draw one you can
  // read at a glance. The theme itself names a full palette in colors.toml, so
  // this reads it the way Color.qml reads that file, and every colour below
  // follows a theme switch instead of being a hex code chosen on one desk.
  //
  // Each role falls back to a colour the shell does keep, so a theme that names
  // none of these still draws, just more quietly.
  property var palette: ({})
  function paletteColor(name, fallback) {
    var value = root.palette[name]
    return value ? value : fallback
  }
  readonly property color portColor: paletteColor("yellow", Color.accent)
  readonly property color headingColor: paletteColor("blue", Color.accent)
  readonly property color branchColor: paletteColor("magenta", Color.accent)
  readonly property color pathColor: paletteColor("cyan", root.foreground)
  readonly property color networkColor: paletteColor("green", root.foreground)
  readonly property color alertColor: paletteColor("red", Color.urgent)

  function parsePalette(raw) {
    var colours = ({})
    var pattern = /^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6,8})"/gm
    var match
    while ((match = pattern.exec(String(raw || ""))) !== null) colours[match[1]] = match[2]
    return colours
  }

  FileView {
    id: paletteFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.palette = root.parsePalette(text())
    onLoadFailed: root.palette = ({})
  }

  // A theme switch replaces the directory rather than editing the file in it,
  // which a watch on the old path can miss. The shell's own accent changes when
  // the theme does, so that is the signal to read again.
  Connections {
    target: Color
    function onAccentChanged() { paletteFile.reload() }
  }
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var grouped: Model.sections(root.records)
  readonly property var visibleRecords: root.grouped.rows
  readonly property var summary: Model.barSummary(root.records)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // FOUR SECONDS WHILE THE PANEL IS OPEN, THIRTY WHILE IT IS NOT.
  //
  // Every refresh is an `ss`, a walk of /proc and a `git rev-parse` per
  // checkout. This used to poll only while the panel was open, which was right
  // for a count and is wrong for a notification dot: a dot that appears only
  // once you have opened the panel to look is a dot that has told you nothing.
  // Thirty seconds is slow enough to cost nothing -- under three thousand
  // spawns a day -- and fast enough that a server you started is marked before
  // you have gone looking for it.
  //
  // Four seconds while open, because this is also the list you watch after
  // pressing stop, and a row that lingers for thirty reads as the stop having
  // failed.
  Timer {
    interval: root.opened ? 4000 : 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()

  onOpenedChanged: {
    if (opened) {
      root.cursorActive = false
      root.actionStatus = ""
      if (panelFlick) panelFlick.contentY = 0
      root.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      root.cancelPending()
    }
  }

  function refresh() {
    if (root.reading) return
    root.reading = true
    reader.running = true
  }

  // THE SCRIPT IS FOUND RELATIVE TO THIS FILE, NOT LOOKED UP ON PATH.
  //
  // A plugin is a directory the shell was handed, and its own files are the only
  // ones it can be sure of. Resolving `listening-ports` through PATH would run
  // whatever happens to be first on the PATH of a shell process started at
  // login — which is both wrong and worth not doing in a widget whose other
  // subcommand sends signals.
  readonly property string readerPath: Qt.resolvedUrl("listening-ports").toString().replace(/^file:\/\//, "")

  Process {
    id: reader
    command: ["python3", root.readerPath, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parse(text)
        if (parsed.error) {
          root.lastError = "could not read the socket list: " + parsed.error
          return
        }
        root.lastError = ""
        root.records = parsed.records
        root.clampCursor()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.lastError = text.trim()
    }
    // Cleared here rather than in onStreamFinished: a command that fails to
    // start produces no stdout at all, and a `reading` flag that only clears on
    // output would wedge the panel on its first bad refresh.
    onExited: function(exitCode) {
      root.reading = false
      if (exitCode !== 0 && root.lastError === "")
        root.lastError = "listening-ports exited " + exitCode
    }
  }

  // --- stopping a process -------------------------------------------------

  // NOTHING IS SIGNALLED WITHOUT A SECOND, SEPARATE ACT.
  //
  // One click arms a question, the question names the process and the pid it is
  // about, and answering it is the only path to a signal. Enter on a row opens
  // that question rather than acting, because this list is navigable by keyboard
  // and a list you arrow through is a list you will arrow through while looking
  // somewhere else.
  function askToStop(record, signalName) {
    if (!record || !record.isStoppable) return
    root.pendingRecord = record
    root.pendingSignal = signalName
    // Cancel, always, and set rather than bound: ConfirmDialog assigns its own
    // `selectedIndex` on hover, which would break a binding the first time the
    // pointer crossed a button and leave the two disagreeing. One owner, written
    // once per question.
    //
    // Cancel because the key that opens the question must not also answer it —
    // Enter arms the dialog with the cursor on Cancel, so a second Enter cancels.
    confirmStop.selectedIndex = 0
  }

  function cancelPending() {
    root.pendingRecord = null
    root.pendingSignal = ""
  }

  function confirmPending() {
    var record = root.pendingRecord
    var signalName = root.pendingSignal
    root.cancelPending()
    if (!record) return
    // The name travels with the pid, and listening-ports refuses unless /proc
    // still agrees — the guard against this pid having been recycled between the
    // poll that drew the row and this click.
    signaller.lastRecord = record
    signaller.lastSignal = signalName
    signaller.command = ["python3", root.readerPath, "signal",
                         String(record.processId), String(record.processName), signalName]
    signaller.running = true
  }

  Process {
    id: signaller
    property var lastRecord: null
    property string lastSignal: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.actionStatus = text.trim()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.actionStatus = text.trim()
    }
    onExited: function(exitCode) { settleTimer.restart() }
  }

  // SIGTERM IS A REQUEST, SO THE PANEL HAS TO SAY WHETHER IT WAS GRANTED.
  //
  // A process that ignores SIGTERM stays in the list, and without this the panel
  // reports "sent SIGTERM to 2782876" and then simply looks broken. Measured
  // against a listener holding SIG_IGN on SIGTERM: the row was still there a
  // second later, and Force removed it.
  //
  // The delay is because the answer is not available immediately either way — a
  // process that catches the signal to shut down cleanly needs a moment, and a
  // refresh fired at once would always report that it had ignored it.
  Timer {
    id: settleTimer
    interval: 700
    onTriggered: {
      root.refresh()
      if (signaller.lastSignal === "TERM" && signaller.lastRecord
          && root.stillListening(signaller.lastRecord))
        root.actionStatus = Model.rowName(signaller.lastRecord)
          + " ignored the request — Force (f) will stop it"
    }
  }

  function stillListening(record) {
    for (var index = 0; index < root.records.length; index++) {
      if (root.records[index].processId === record.processId
          && root.records[index].port === record.port) return true
    }
    return false
  }

  // --- cursor -------------------------------------------------------------

  function clampCursor() {
    var count = root.visibleRecords.length
    root.cursorRow = count === 0 ? 0 : Math.max(0, Math.min(root.cursorRow, count - 1))
  }

  function moveCursor(horizontal, vertical) {
    root.cursorActive = true
    if (vertical === 0) return
    root.cursorRow = Math.max(0, Math.min(root.visibleRecords.length - 1, root.cursorRow + vertical))
  }

  function selectedRecord() {
    if (root.visibleRecords.length === 0) return null
    return root.visibleRecords[Math.max(0, Math.min(root.cursorRow, root.visibleRecords.length - 1))]
  }

  function setCursorRow(index) {
    root.cursorActive = true
    root.cursorRow = index
  }

  // Called by the row that has just taken the cursor, rather than looked up from
  // here. Rows live in two Repeaters under two headers, so there is no index the
  // panel could map back to an item; the item that knows it is current is the
  // one in a position to say where it is.
  function scrollIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item || !item.parent) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maximum = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maximum, bottom + margin - panelFlick.height)
    })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function summary(): string { return Model.barTooltip(root.summary) }
    // Deliberately absent: a route that signals a process. This panel's whole
    // safety story is that a kill needs a person to read a name and answer a
    // question about it; an IPC verb that skips both is a different feature
    // wearing this one's name.
  }

  // --- bar button ---------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // AN ANCHOR, AND A DOT WHEN SOMETHING IS MOORED.
    //
    // md-anchor, U+F0031, written as an escape: private-use glyphs pasted as
    // literals have already vanished once in this widget's history.
    //
    // CHECKED BY RENDERING IT, not by asking whether the font has the
    // codepoint. The first choice, U+F002B, is present in the font and is
    // Material's "alpha" -- the bar drew an α with a red dot on it. Existence is
    // not identity; the only check that tells you which glyph you have is
    // drawing it and looking.
    //
    // Dimmed when nothing is running, so an empty anchor reads as "nothing here"
    // from across the room rather than needing the dot's absence noticed.
    text: root.anchorGlyph
    slotSize: Style.bar.iconSlot
    foreground: root.summary.hasDevelopmentPort ? root.foreground : Util.alpha(root.foreground, 0.45)
    tooltipText: Model.barTooltip(root.summary)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }

    // THE DOT, NOT A COUNT: see Model.barSummary.
    //
    // At the top-right of the glyph's 16px optical canvas, the corner a chat
    // app's unread mark sits in, with a ring of the bar's own colour cut round
    // it so it reads as sitting ON the icon rather than as a smudge touching it.
    Rectangle {
      visible: root.summary.hasDevelopmentPort
      readonly property real corner: Style.bar.iconCanvas * 0.36
      width: Math.max(6, Math.round(Style.bar.iconCanvas * 0.44))
      height: width
      radius: width / 2
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: corner
      anchors.verticalCenterOffset: -corner
      color: root.alertColor
      border.width: Math.max(1, Math.round(width * 0.22))
      border.color: Color.bar.background
    }
  }

  // --- panel --------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    // ONE KEY CATCHER, WHICH ALSO DRIVES THE CONFIRMATION.
    //
    // ConfirmDialog ships its own `handleKey`, but reaching it would mean a
    // second `Keys.onPressed` — and declaring one on this object replaces
    // PanelKeyCatcher's rather than adding to it, which silently takes every key
    // in the panel with it. So the dialog is driven through the signals that are
    // already here: left/right pick a button, enter answers, escape cancels.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(horizontal, vertical) {
        if (root.confirming) {
          if (horizontal !== 0) confirmStop.selectedIndex = confirmStop.selectedIndex === 0 ? 1 : 0
          return
        }
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(horizontal, vertical)
      }
      onActivateRequested: {
        if (root.confirming) {
          if (confirmStop.selectedIndex === 0) root.cancelPending()
          else root.confirmPending()
          return
        }
        if (root.cursorActive) root.askToStop(root.selectedRecord(), "TERM")
      }
      onDeleteRequested: if (!root.confirming && root.cursorActive) root.askToStop(root.selectedRecord(), "TERM")
      onCloseRequested: root.confirming ? root.cancelPending() : root.close()
      onTabRequested: function(direction) { if (!root.confirming) root.switchPanel(direction) }
      onTextKey: function(character) {
        if (root.confirming) return
        var lowered = String(character).toLowerCase()
        if (lowered === "r") root.refresh()
        // Force is its own key, and it opens its own question. There is no
        // keystroke anywhere that escalates from TERM to KILL by itself.
        else if (lowered === "f" && root.cursorActive) root.askToStop(root.selectedRecord(), "KILL")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // PanelHero loads `iconComponent` and `trailingControl` through a
          // Loader of its own, and inside those `root` resolves to PanelHero
          // rather than to this panel — Omarchy's dropbox plugin records the
          // same surprise and works around it the same way. Everything they need
          // is reached through this wrapper's id instead.
          Item {
            id: heroHost
            width: parent.width
            implicitHeight: hero.implicitHeight

            readonly property color foreground: root.foreground
            readonly property string fontFamily: root.fontFamily
            readonly property string anchorGlyph: root.anchorGlyph
            function refresh() { root.refresh() }

            PanelHero {
              id: hero
              width: parent.width
              // "Local", because the question it answers is what is running on
              // THIS machine -- and "Ports" alone sits beside a network widget
              // that is about something else entirely.
              title: "Local Ports"
              foreground: root.foreground
              fontFamily: root.fontFamily

              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: heroHost.anchorGlyph
                  color: heroHost.foreground
                  font.family: heroHost.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: "Refresh (r)"
                  foreground: heroHost.foreground
                  fontFamily: heroHost.fontFamily
                  onClicked: heroHost.refresh()
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.actionStatus !== "" || root.lastError !== ""
            width: parent.width
            text: root.actionStatus !== "" ? root.actionStatus : root.lastError
            color: root.lastError !== "" && root.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.visibleRecords.length === 0
            width: parent.width
            text: "No dev servers running."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          // One section per checkout. See Model.sections for why that is the
          // whole list.
          Repeater {
            model: root.grouped.sections
            PortGroup {
              required property var modelData
              heading: modelData.heading
              caption: modelData.caption
              groupRecords: modelData.rows
            }
          }
        }
      }

      ConfirmDialog {
        id: confirmStop
        anchors.fill: parent
        z: 10
        opened: root.confirming
        message: root.confirming ? Model.confirmMessage(root.pendingRecord, root.pendingSignal) : ""
        confirmText: root.pendingSignal === "KILL" ? "Force" : "Stop"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelPending()
        onConfirmed: root.confirmPending()
      }
    }
  }

  component PortGroup: Column {
    id: portGroup
    property string heading: ""
    property string caption: ""
    property var groupRecords: []

    visible: groupRecords.length > 0
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    // The checkout, in the theme's blue, with the branch in magenta beneath it
    // when the heading has not already said it. Coloured so a panel with three
    // checkouts in it reads as three blocks before any of it is read as words.
    Column {
      width: parent.width
      spacing: Style.space(1)
      leftPadding: Style.space(2)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: portGroup.heading
        color: root.headingColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideMiddle
      }

      Text {
        textFormat: Text.PlainText
        visible: portGroup.caption !== ""
        width: parent.width
        text: portGroup.caption
        color: root.branchColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(2)

      Repeater {
        model: portGroup.groupRecords
        PortRow {
          required property var modelData
          width: portGroup.width
          record: modelData
          rowIndex: modelData.rowIndex
        }
      }
    }
  }

  // Every port number in a column of the same width, so a list of them reads
  // down as a column and the eye can run along it looking for the one it
  // remembers. Measured once, off the widest a port can be.
  TextMetrics {
    id: portMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    font.bold: true
    text: "00000"
  }

  component PortRow: CursorSurface {
    id: portRow
    property var record: null
    property int rowIndex: 0
    readonly property string refusal: portRow.record ? Model.stopRefusal(portRow.record) : ""
    readonly property bool reachable: portRow.record ? portRow.record.isNetworkReachable : false

    hasCursor: root.cursorActive && root.cursorRow === portRow.rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    onHasCursorChanged: if (hasCursor) root.scrollIntoView(portRow)

    // ONE MOUSE AREA FOR THE WHOLE ROW.
    //
    // A second, overlapping hover-enabled MouseArea for the tooltip takes the
    // hover events away from the one underneath it, and the cursor then stops
    // following the pointer -- so the tooltip hangs off this one.
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursorRow(portRow.rowIndex)
      // Clicking the row selects it and nothing more. The stop button is the
      // only thing on this row that can arm a kill, so a misplaced click while
      // scanning the list cannot start one.
      onClicked: root.setCursorRow(portRow.rowIndex)
    }

    PanelToolTip {
      visible: rowMouse.containsMouse && !root.confirming
      text: portRow.record ? Model.rowTooltip(portRow.record) : ""
      fontFamily: root.fontFamily
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      // REACH, AS A SHAPE AND A COLOUR.
      //
      // Filled green means the port answers from the network -- the one fact
      // about a port that can hurt you. A ring means this machine only. The
      // shape carries it on its own, so a theme whose green sits close to its
      // foreground still reads.
      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Style.space(8)
        implicitHeight: Style.space(8)
        radius: width / 2
        color: portRow.reachable ? root.networkColor : "transparent"
        border.width: portRow.reachable ? 0 : Math.max(1, Style.space(1))
        border.color: Util.alpha(root.foreground, 0.4)
      }

      Text {
        textFormat: Text.PlainText
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Math.ceil(portMetrics.width)
        text: portRow.record ? String(portRow.record.port) : ""
        color: root.portColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: portRow.record ? Model.rowName(portRow.record) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        // Three pieces in three colours rather than one string: where in the
        // checkout (cyan), whether it answers from the network (green, or
        // dim when it does not), and the pid, dim, for the one time you need it.
        RowLayout {
          Layout.fillWidth: true
          spacing: 0

          Text {
            textFormat: Text.PlainText
            Layout.maximumWidth: rowContent.width * 0.6
            text: portRow.record ? Model.rowPath(portRow.record) : ""
            color: root.pathColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
          Text {
            textFormat: Text.PlainText
            text: portRow.record ? "  " + Model.rowReach(portRow.record) : ""
            color: portRow.reachable ? root.networkColor : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: portRow.record ? "  " + Model.rowTrail(portRow.record) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      PanelActionButton {
        iconText: "󰅙"
        // Why it is off, in words. A greyed-out button with nothing to say reads
        // as this panel being broken rather than as the kernel declining.
        tooltipText: portRow.refusal !== "" ? portRow.refusal : "Stop this process (enter)"
        enabled: portRow.record ? portRow.record.isStoppable : false
        foreground: root.foreground
        hoverColor: root.alertColor
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.askToStop(portRow.record, "TERM")
      }
    }
  }
}
