# nine desktops, and SUPER + 0 for the whole grid

Nine desktops, a 3 × 3, fixed. `SUPER + 1` to `SUPER + 9` are the desktops and `SUPER + 0` opens the overview. `desktop_count` is no longer accepted by `setup()`.

Every workspace keeps its number from 2.x, so no window moves on upgrade; only desktop 10 stops being a desktop.

The desktop number on screen now appears exactly when the desk switches, announced by the library itself, and never when the mouse merely crosses between monitors showing different desktops — which a held screen makes the normal case.
