# Pin

`SUPER + P` pins the window you are in — tiled or floating — and unpins it. A
pinned window **follows you**: change desktop, and it comes along, onto the
same panel, in the same place in the layout. A [held](../../README.md#holding-a-panel)
panel does not change desktop, so a window pinned there stays put with it.

```bash
hyprpeach plugin add pin
```

**You can see which windows are pinned:** a peach border — the same width and
square corners as every other window, and the same whether it has focus or not,
because it is pinned either way. Unpinned, the window has your theme's border
again. Pinning also clears Omarchy's `pop` mark from a window `SUPER + O` once
popped out, which would otherwise keep its corners rounded for good.

**Two keys for two things.** Omarchy's `SUPER + O` does everything at once: it
floats the window, resizes it to 1300 × 900, centres it, and pins it. Its
`SUPER + T` already floats a window. So with pin:

| | |
|---|---|
| `SUPER + T` | float, or tile again (Omarchy's, unchanged) |
| `SUPER + P` | pin, or unpin — tiled or floating |
| `SUPER + O` | nothing — let go |

`SUPER + P` was Omarchy's *pseudo window*, a dwindle-layout setting; pin takes
the key. `hyprpeach plugin remove pin` gives both keys back.

**How it follows.** Not Hyprland's own `pin`, which takes floating windows
only. `SUPER + P` tags the window, and whenever its monitor turns to another
workspace, a tagged window on that monitor is moved there too — without taking
the view with it. The tag lives on the window, so it stays pinned through a
config reload.

**How it is installed.** Pin is keys, and keys live in Hyprland's config, not
the shell: adding it puts a small block in `~/.config/hypr/hyprland.lua` that
loads `pin.lua` from hyprpeach's clone, after your own bindings and after
desktops', so its keys win. Removing it takes the block out again.
