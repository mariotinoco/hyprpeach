import QtQuick

// Pin is keys, not anything on screen: its work is pin.lua, which
// `hyprpeach plugin add pin` loads from hyprland.lua. Omarchy loads a plugin
// only through an entry point, and a service that draws nothing is the kind
// that puts nothing on the bar -- so this is that, and empty.
Item {}
