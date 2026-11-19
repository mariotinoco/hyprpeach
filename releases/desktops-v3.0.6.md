# works with Omarchy 4.5's per-monitor workspaces

**Fixed:** on Omarchy 4.5, windows could vanish. Omarchy now gives each monitor its own numbered workspaces and re-sorts them at login, on every reload and when a monitor connects. On a hyprpeach desk that put a panel on a workspace that is not a desktop, and anything opened there disappeared at the next switch. hyprpeach now turns that re-sorting off, and leaves the rest of Omarchy alone.

**Fixed:** a held panel always shows its padlock. A hold could be on with nothing on screen saying so, and the desk then looked like paired switching had stopped working. The next switch now brings the padlock back.

`SUPER + SHIFT + ALT + arrows` now does nothing. In Omarchy 4.5 it moves one monitor's half of a desktop to the other monitor and renumbers it, which tears the desktop in half.
