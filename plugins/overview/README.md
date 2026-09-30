# Desktop Overview

Every desktop at once, on every monitor. `SUPER + TAB` opens it on all your
screens together; each screen shows a grid of **its own** desktops, with live
pictures of the windows on them. Pick one and the whole desk turns to it.

```bash
hyprpeach plugin add overview
```

It needs [desktops](../../README.md#more-plugins), which is what turns the desk,
so add that first.

- **Click** a desktop, or press its **number** (`0` is ten), to go there.
- **Esc**, `SUPER + TAB` again, or a click between desktops closes it.
- The current desktop is outlined. A [held](../../README.md#holding-a-panel)
  screen says so, and stays where it is while the rest move.

Each screen shows the desktops the number keys reach, and only those — so on a
laptop taken off its dock, where the other screens' workspaces pile onto the
one panel left, it still shows ten, not thirty.

The grid is worked out from each monitor's shape, so every desktop is drawn at
its screen's own proportions: ten desktops on a 32:9 panel come out four
across, three down, without squashing the picture.

## Live, even on desktops you are not on

A video playing on a desktop you are not looking at **keeps playing in its
cell**. Hyprland does not draw a workspace nobody is looking at, so there is no
picture of a hidden desktop to take — but it will export any single window,
visible or not, so each desktop is your wallpaper with every window's own live
picture laid on it at its real position. An app that stops drawing while it is
hidden shows the last frame it drew.

Built and tested on two 7680 × 2160 panels on Hyprland 0.56.2. Not there yet:
arrow keys to move between desktops, and dragging a window from one desktop to
another.

## Prior art

[hyprexpo](https://github.com/hyprwm/hyprland-plugins) by vaxerski and the
Hyprland contributors is the overview most Hyprland desks use, and the look this
one starts from. It is a compiled plugin that thinks in workspaces, one monitor
at a time; this one is QML and thinks in desktops, every monitor at once.
