# Animated Desktops

A living scene behind your desktops: nine places in one world, one for each
desktop, drawn in real time as one picture across every monitor. Switching
desktops flies you from one to the next.

```bash
hyprpeach plugin add animated-desktops
```

It needs [desktops](../../README.md#more-plugins). The first add builds the
renderer, which takes a few minutes.

## Scenes

```bash
hyprpeach scene              # the scenes, and which is in effect
hyprpeach scene nebula       # show another
hyprpeach speed snappy       # calm, quick (the default) or snappy switches
```

**synthwave** (the default) — a neon grid running to a banded sun. Each
desktop is its own hour of the night with its own landmark on the horizon:
wireframe mountains, pyramids, a city skyline, a ring gate, a ringed planet,
red spires, an aurora, palms under a crescent, an eclipse. A switch is a surge
forward along the grid while the next landmark rises out of the haze.

**nebula** — drifting inside an emission nebula. Each desktop is its own
region: dust pillars, a young cluster, a dust lane, a bubble, a cliff of gas.
A switch is a flight forward through the gas, near clouds streaming past and
the stars streaking.

Every desktop looks different from every other, so you know which one you are
on without reading a number, and the overview's nine cells are nine places
rather than nine copies of a wallpaper.

## Speed

A switch takes the same time however far it goes — 2 → 8 as long as 2 → 3,
covering more ground. **quick** (0.8 s) is the default; **snappy** (0.45 s) is
for when the move is in the way of the work; **calm** (1.6 s) is for watching
it.

Both settings live in `~/.config/hyprpeach/animated-desktops.json`. The two
commands write it; you can edit it by hand too, against
[settings.schema.json](settings.schema.json). Either way it takes effect within
a second.

## On your monitors

The picture is composed around **the monitor at eye level** — the one holding
desktops 1–9 — and the rest of the desk sees what is around it:

- **Two panels stacked:** the scene's subject on the bottom panel, the sky
  going on up through the top one.
- **A laptop between two larger screens:** the subject on the laptop, the
  horizon running on across both screens either side.
- **Two screens side by side:** the subject on the first, the second a wing.
- **A laptop on its own:** the whole of it.

Bezels are window frames onto one picture: a line that leaves one monitor
enters the next where it would.

## In the overview

`SUPER + 0` shows all nine desktops on every monitor, a 3 × 3 in that
monitor's shape. Each cell is that desktop's scene as your eye-level monitor
sees it, still moving, with that monitor's windows laid over it.

## Cost

Every frame is drawn fresh at the monitor's rate, at half resolution with
temporal anti-aliasing to recover the detail. Measured on two 7680 × 2160
panels with an RTX 5090: 60 fps per panel for each scene. Integrated graphics
is untested; `HYPRPEACH_SCALE` (default `0.5`) sets the internal resolution.

## What it is

A native renderer — Rust and [wgpu](https://wgpu.rs), in `renderer/` — drawn
on each monitor's background layer. A scene is one shader in
`renderer/src/scenes/`; `renderer/src/common.wgsl` says what it has to define.
The service in `AnimatedDesktops.qml` keeps the renderer running and rebuilds it when an
update changes its source; `prepare` does the building.

To see a scene on a desk you do not have, give the renderer that desk's
`hyprctl -j monitors`:

```bash
~/.local/share/hyprpeach/animated-desktops/hyprpeach-animated-desktops preview monitors.json desk.png
```

`renderer/layouts/` holds the four desks above.

The program lives in `~/.local/share/hyprpeach/animated-desktops` and the build in
`~/.cache/hyprpeach`. Removing the plugin leaves them; delete those two folders
to reclaim the space.
