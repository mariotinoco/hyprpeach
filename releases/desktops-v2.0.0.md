# Multi-Monitor Desktops, as a plugin you add

The desktops are now one plugin in the hyprpeach collection, added with `hyprpeach plugin add desktops` and removed with `hyprpeach plugin remove desktops`. Removing them takes hyprpeach back out of your Hyprland config and puts Omarchy's own workspaces and menu widgets back.

Adding them again re-reads your monitors, so run it after you change them.

The keymap, `setup()` options and `peach.*` functions are unchanged. It is a major version because of how it installs: the library now loads from the Omarchy plugin, not `~/.config/hypr/hyprpeach`.
