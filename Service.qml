import QtQuick
import Quickshell.Io

// hyprpeach itself, as Omarchy loads it: nothing on screen.
//
// The repository is one plugin in Omarchy's registry and a collection of them
// in practice -- each under plugins/, added with `hyprpeach plugin add`. This
// root has to be a plugin for Omarchy to install and update the collection at
// all, and a service is the kind that draws nothing, so installing hyprpeach
// puts nothing on the bar until you choose what should be there.
//
// Its one job: `hyprpeach` ON PATH, FOR AN INSTALL NO INSTALLER OF OURS RAN.
// `omarchy plugin add` clones and runs nothing, so the command a person needs
// next would exist only at a path they would have to be told. The command
// links itself; it does nothing when the link is already right, and it never
// takes a file that is not hyprpeach's. bin/hyprpeach says exactly what it
// will and will not replace.
Item {
  Process {
    running: true
    command: [Qt.resolvedUrl("bin/hyprpeach").toString().replace(/^file:\/\//, ""), "link-command"]
  }
}
