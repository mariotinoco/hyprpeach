import QtQuick
import Quickshell
import Quickshell.Io

// Keeps the animated renderer running behind the desk.
//
// The scene is drawn by a native program (renderer/, Rust and wgpu) rather
// than in QML: temporal anti-aliasing and bloom need history buffers and a
// chain of passes the shell's shaders do not have. This service is only its keeper -- it brings the build up to date
// when an update moved the source on, starts it, restarts it if it falls over,
// and publishes whether it is running for the overview to read.
Item {
  id: root

  readonly property string pluginDirectory: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string dataDirectory: Quickshell.env("HOME") + "/.local/share/hyprpeach/animated"
  property int failures: 0

  // `--if-stale`: returns at once when the build matches the source. After an
  // `omarchy plugin update` it does not, and this rebuilds before starting.
  Process {
    id: prepare
    running: true
    command: [root.pluginDirectory + "/prepare", "--if-stale"]
    stderr: StdioCollector { id: prepareErrors; waitForEnd: true }
    // Started either way: a rebuild that fails -- no Rust any more, a broken
    // toolchain -- leaves the last good build in place, and an old scene
    // behind the desk beats none. With no build at all, the renderer fails to
    // start and the backoff below gives up on it.
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("hyprpeach animated: prepare failed; starting the last build:", prepareErrors.text)
      renderer.running = true
    }
  }

  Process {
    id: renderer
    command: [root.dataDirectory + "/hyprpeach-animated"]
    onRunningChanged: {
      marker.setText(renderer.running ? "running\n" : "")
      if (renderer.running) steady.restart()
      else steady.stop()
    }
    // A renderer that falls over is started again, backing off, and given up
    // on after five tries in a row rather than spinning a GPU driver bug into
    // a loop.
    onExited: {
      root.failures++
      if (root.failures < 5) restart.start()
      else console.warn("hyprpeach animated: the renderer keeps stopping; giving up until the shell restarts")
    }
  }

  // IN A ROW: a minute running clears the count, so a monitor unplugged now
  // and then over days of uptime is never the fifth strike.
  Timer {
    id: steady
    interval: 60000
    onTriggered: root.failures = 0
  }

  Timer {
    id: restart
    interval: 2000 * root.failures
    onTriggered: renderer.running = true
  }

  // Whether the scene is behind the desk: the overview reads it, and leaves its
  // cells see-through for the renderer to draw the viewports in.
  FileView {
    id: marker
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hyprpeach-animated"
    printErrors: false
  }

  Component.onDestruction: marker.setText("")
}
