# Orbit

Your desk as the windows of a station in low orbit. Behind your desktops, a
planet turns beneath you — NASA's imagery of the Earth under a physically
scattered atmosphere, real-time, with clouds, sun glint on the oceans and city
lights on the night side — seen as one continuous view across every monitor,
each one a pane of the same window.

```bash
hyprpeach plugin add orbit
```

It needs [desktops](../../README.md#more-plugins). The first add builds the
renderer (a few minutes) and fetches the planet (about 85 MB).

## The desk is a torus

Nine desktops, a 3 × 3. **Columns are bearings** around the station, 120°
apart; **rows are positions along its orbit**, 120° apart. Both wrap, so every
step is the same move:

- **1 → 2 → 3** turns right, a third of the way round each time.
- **3 → 4**, and **9 → 1**, turn right and move a third of the way along the
  orbit — no wilder than any other step, and the wrap closes rather than flips.
- A jump turns the short way on both, so nothing ever swings more than 120°.

Moving along the orbit moves the sun: **row 1 is day, row 2 a low golden sun on
the terminator, row 3 the night side**, city lights and the green airglow on
the limb.

## In the overview

`SUPER + TAB` or `SUPER + 0` shows the grid as it is: each cell is its
desktop's viewport, and the three in a row are three 120° slices of one ring —
the coastline leaving the right edge of one cell enters the left of the next.
Between them, the universe they look into.

## Cost

It idles at ten fresh frames a second, re-presenting the last one in between,
and draws every frame only while moving or with the overview open. Measured on
two 7680 × 2160 panels with an RTX 5090: about 8% of the GPU at rest. On
integrated graphics it is untested; `HYPRPEACH_SCALE` (default `0.5`) is the
internal resolution.

## What it is

A native renderer — Rust and [wgpu](https://wgpu.rs), in `renderer/` — drawn
on each monitor's background layer. Per frame: single scattering through the
atmosphere (Rayleigh and Mie), the planet with exaggerated relief and GGX ocean
glint, temporal anti-aliasing, a six-level bloom, and a filmic tone curve. The
service in `Orbit.qml` keeps it running and rebuilds it when an update changes
its source; `prepare` does the building and fetching.

Built files live outside the plugin: the program and imagery in
`~/.local/share/hyprpeach/orbit`, the build in `~/.cache/hyprpeach`. Removing
the plugin leaves them; delete those two folders to reclaim the space.

## Imagery

All NASA, public domain: Blue Marble Next Generation (day), Black Marble 2016
(night lights), the cloud composite, GEBCO elevation via NASA Earth
Observatory, and the LRO colour Moon from NASA's Scientific Visualization
Studio.
