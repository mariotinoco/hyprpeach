<div align="center">

# 🍑 hyprpeach

**An opinionated way for monitors and workspaces to interact.**

*Your monitors are one desk, not two computers. Press a key, the whole desk turns.*

<br>

[![Hyprland](https://img.shields.io/badge/Hyprland-%E2%89%A5%200.55-46D9FF?style=flat-square&labelColor=1F2430)](https://hypr.land)
[![Lua](https://img.shields.io/badge/library-Lua-7A7ADB?style=flat-square&labelColor=1F2430)](#install)
[![QML](https://img.shields.io/badge/bar%20strip-QML,%20optional-3E8E6E?style=flat-square&labelColor=1F2430)](#the-bar-strip)
[![Dependencies](https://img.shields.io/badge/dependencies-none-FF8A5B?style=flat-square&labelColor=1F2430)](#install)
[![License](https://img.shields.io/badge/license-MIT-6E7681?style=flat-square&labelColor=1F2430)](LICENSE)

<br>

[**How it works**](#how-it-works) · [**Just install it**](#yeah-yeah-whatever--gimme-the-install-command-for-omarchy) · [**The keymap**](#the-keymap) · [**More plugins**](#more-plugins) · [**Upgrading**](#upgrading) · [**Pinning**](#pinning-a-release) · [**From 1.x**](#from-1x-installsh) · [**The bar strip**](#the-bar-strip) · [**API**](#api) · [**Prior art**](#prior-art)

</div>

<br>

## How it works

<div align="center">
<img src="docs/hyprpeach.svg" alt="A desktop is a set of workspaces, one pinned to every monitor. Pressing super+2 moves every panel to its own desktop 2 at once, instead of teleporting focus to whichever monitor happened to own workspace 2." width="100%">
</div>

Hyprland cannot show one workspace on two monitors at once — asked directly, its maintainer's answer was [*"you can't do that"*](https://github.com/hyprwm/Hyprland/discussions/10088).

So stop trying. **A desktop is a _set_ of workspaces**, one pinned to each monitor, and every desktop action dispatches once per monitor. Press `super+3` and both panels turn together, always.

<br>

## Yeah yeah whatever — gimme the install command for omarchy

```bash
omarchy plugin add https://github.com/mariotinoco/hyprpeach --enable
~/.config/omarchy/plugins/hyprpeach/bin/hyprpeach plugin add desktops
```

hyprpeach is a small collection of Omarchy plugins for a desk with more than one monitor, installed as **one plugin** from Omarchy's own plugin manager. Installing it adds nothing to your bar; you pick what goes there. The second line adds [the desktops](#how-it-works): it reads your monitors out of `hyprctl`, writes the `setup()` call into `hyprland.lua` with them already filled in — bottom panel first, matched by EDID serial — puts [the strip](#the-bar-strip) on the bar, [moves two widgets out of its way](#what-adding-desktops-changes), and reloads.

From then on it is just `hyprpeach`, which the plugin keeps on your `PATH`. See [what else there is](#more-plugins) with `hyprpeach plugin list`.

<details>
<summary>Running a stranger's code, you say</summary>

<br>

Fair. `omarchy plugin add` asks before it clones and shows you the URL, and it runs nothing — it only clones. So read the clone at `~/.config/omarchy/plugins/hyprpeach` before you add anything from it; [`bin/hyprpeach`](bin/hyprpeach) is the whole of what `plugin add` does.

Or skip it entirely — [Install](#install) is the desktops library by hand, and it is not long.

</details>

<br>

## The keymap

<div align="center">
<img src="docs/keymap.svg" alt="One rule: SUPER moves your view, SUPER plus SHIFT moves the window. Numbers are absolute and arrows are relative; left and right mean desktops, up and down mean panels." width="100%">
</div>

Nothing else to learn. `SUPER + ↑ ↓` is left alone, so directional window focus survives on the axis the panels are stacked on. Your view follows a window you fling.

<br>

## Install

*The desktops library by hand, on any Hyprland. On Omarchy, [the two lines above](#yeah-yeah-whatever--gimme-the-install-command-for-omarchy) do all of this.*

Works on **any Hyprland ≥ 0.55** — plain Arch, Omarchy, NixOS, whatever runs the compositor. Hyprland 0.55 is where Lua became a first-class config language, which is all this needs: no compiler, no `hyprpm`, no daemon, nothing to install beside it.

```bash
git clone --branch v3.0.0 https://github.com/mariotinoco/hyprpeach ~/.config/hypr/hyprpeach
```

**Clone a tag, not a branch.** A release cannot change under you, and upgrading stays a decision you make rather than one that happens the next time you pull. Leave `--branch` off to track `main` and take what comes; upgrade later with `git fetch --tags && git checkout v3.0.0`.

Then in your Hyprland Lua config, **after** whatever binds your number row:

```lua
-- Hyprland's Lua path looks for `name.lua`, not `name/init.lua`, so a cloned
-- directory needs this line before it can be required.
package.path = os.getenv("HOME") .. "/.config/hypr/?/init.lua;" .. package.path

require("hyprpeach").setup({
  -- The only required option: your monitors in PHYSICAL order, bottom first.
  -- The first one takes the un-offset band, so on it desktop N is workspace N.
  -- These serials are made up; `hyprctl monitors all` prints yours. Two of one
  -- model is the case worth showing, because then the serial is the only thing
  -- telling them apart.
  monitors_bottom_to_top = {
    "desc:Samsung Electric Company Odyssey G95NC HNTX000001",  -- bottom
    "desc:Samsung Electric Company Odyssey G95NC HNTW000002",  -- top
  },

  -- Everything below is a default. Delete any line to keep it.
  focus_follows_fling         = true,  -- your view lands with a window you fling
  notify                      = true,  -- a toast for actions with no on-screen result
  unbind_conflicting_defaults = true,  -- clear stock bindings that move one panel

  -- Merged chord by chord, so overriding one keeps the rest. An unknown name
  -- is refused rather than ignored, and `false` frees a key outright: nothing
  -- is bound, the stock binding is still cleared, and the matching `peach.*`
  -- function stays callable.
  keys = {
    focus_desktop_modifier          = "SUPER",
    send_window_modifier            = "SUPER + SHIFT",
    previous_desktop_arrow          = "SUPER + LEFT",
    next_desktop_arrow              = "SUPER + RIGHT",
    send_window_to_previous_desktop = "SUPER + SHIFT + LEFT",
    send_window_to_next_desktop     = "SUPER + SHIFT + RIGHT",
    send_window_to_panel_above      = "SUPER + SHIFT + UP",
    send_window_to_panel_below      = "SUPER + SHIFT + DOWN",
    toggle_held_panel               = "SUPER + Y",
    toggle_overview                 = "SUPER + TAB",  -- does nothing without the overview plugin

    send_window_and_follow_modifier = false,  -- always follows, whatever the flag says
    next_desktop                    = false,
    previous_desktop                = false,
    former_desktop                  = false,
    next_desktop_scroll             = false,
    previous_desktop_scroll         = false,
    swap_panels                     = false,
    gather_rogue_windows            = false,
  },
})
```

> [!IMPORTANT]
> Order matters. `setup` clears the stock single-dispatch bindings before installing its own, and an unbind cannot remove a binding that does not exist yet. On Omarchy that means after `require("default.hypr.omarchy")`.

> [!TIP]
> **Use `desc:` selectors with the serial, not `DP-3`.** Connector names change when cables move ports, and on two monitors of the same model your desktops would silently swap screens with nothing reporting it. `hyprctl monitors all` prints the full description — the trailing token is the serial.

### What adding desktops changes

On Omarchy, `hyprpeach plugin add desktops` also does this, each through Omarchy's own commands so each is undone the same way:

```bash
omarchy plugin disable omarchy.workspaces
omarchy plugin disable omarchy.menu
omarchy bar position left
```

The bar goes **vertical** because the strip is a column of nine cells: on a horizontal bar they spend width competing with the clock and the tray, and a desk this model is for is wide. It is the one line here that is a preference rather than a consequence — `omarchy bar position top` (or `bottom`, or `right`) puts it back, and only adding desktops again will move it.

Both widgets are displaced rather than merely unused. `omarchy.workspaces` [cannot draw a hyprpeach desk](#the-bar-strip) at all. `omarchy.menu` is the widget ahead of the strip in the left section, and the strip is built to lead it — it reaches out to line its first tile up with the edge of a tiled window, which is only the right place to be when nothing sits in front of it. The menu is still one keypress away on `SUPER`.

`hyprpeach plugin remove desktops` takes the block back out of `hyprland.lua` and puts both widgets back. It leaves the bar where it is, because where it was before is not recorded anywhere.

Adding desktops again re-reads your monitors, so it is also what to run after you change them.

<br>

## More plugins

hyprpeach is **one plugin** in Omarchy's registry, carrying several. Add the ones you want, in any combination — all of them, one, or none:

```console
$ hyprpeach plugin list
🍑 hyprpeach 3.0.0
  🍑 desktops     3.0.0    added            Multi-Monitor Desktops
  🌱 dev-ports    0.1.0    not added        Local Ports
  🌱 overview     0.2.0    not added        Desktop Overview

$ hyprpeach plugin add dev-ports
$ hyprpeach plugin remove desktops
```

| Plugin | |
|---|---|
| [**desktops**](#how-it-works) — Multi-Monitor Desktops | A desktop that spans every monitor and turns as one: the library, [the bar strip](#the-bar-strip), and the overlay. Two monitors, three, one [held](#holding-a-panel) while the rest move. |
| [**overview**](plugins/overview/README.md) — Desktop Overview | `SUPER + TAB` shows every desktop at once, on every monitor, live — a video playing on another desktop keeps playing in its cell. Pick one and the whole desk turns. Needs desktops. |
| [**dev-ports**](plugins/dev-ports/README.md) — Local Ports | An anchor on the bar that grows a red dot while a dev server is listening. One port per line, grouped by the git repository, worktree and branch it runs from, and one confirmed click to stop it. |

**They update with hyprpeach.** `add` links the plugin's folder inside hyprpeach's clone into Omarchy's plugins folder, rather than copying it out, so the one `omarchy plugin update` that moves hyprpeach moves every plugin you added from it. There is nothing else to keep current, and nothing that can fall behind.

Each has its own version and its own release notes — `dev-ports-v0.1.0` beside hyprpeach's `v2.0.0` — so you can see what changed in the piece you use. What you install is always the set that shipped together.

It is done this way because Omarchy installs one plugin per repository and reads one bar widget per plugin: separate widgets need separate plugin folders, and a repository per widget would split one project across several.

To take hyprpeach off entirely, remove what you added, then hyprpeach itself:

```bash
hyprpeach plugin remove desktops
hyprpeach plugin remove dev-ports
omarchy plugin remove hyprpeach
```

<br>

---

<br>

## Upgrading

```bash
hyprpeach upgrade
```

That is Omarchy's own `omarchy plugin update hyprpeach`, followed by a Hyprland reload — the reload because Hyprland keeps running the desktops library it loaded until it reloads its config, and a new one on disk changes nothing until then. `omarchy plugin update` on its own is fine too; reload afterwards with `hyprctl reload`. Every plugin you [added](#more-plugins) comes along either way.

Omarchy updates a plugin to the newest commit on `main`. Code only reaches `main` as a release, so that is the newest release — plus, at most, documentation written since.

### Pinning a release

**Omarchy has no pinning of its own.** `omarchy plugin add` clones the default branch, and `omarchy plugin update` fast-forwards to the newest commit on it. So a pin is a git checkout of a release tag inside the clone:

```bash
git -C ~/.config/omarchy/plugins/hyprpeach checkout --quiet --detach v3.0.0
hyprctl reload
```

That pins the whole collection: a hyprpeach release fixes the version of every plugin in it, and there is no mixing `desktops` from one release with `dev-ports` from another.

**`omarchy plugin update` undoes a pin.** A detached checkout still fast-forwards, and a bare `omarchy plugin update` updates every git plugin you have. So for installs described as code, make the pin the last step, every time it runs:

```bash
[[ -d ~/.config/omarchy/plugins/hyprpeach ]] || omarchy plugin add https://github.com/mariotinoco/hyprpeach --yes
omarchy plugin enable hyprpeach
git -C ~/.config/omarchy/plugins/hyprpeach fetch --quiet --tags --force origin
git -C ~/.config/omarchy/plugins/hyprpeach checkout --quiet --detach v3.0.0
~/.config/omarchy/plugins/hyprpeach/bin/hyprpeach plugin add desktops
~/.config/omarchy/plugins/hyprpeach/bin/hyprpeach plugin add dev-ports
```

Every line is safe to run again. What a version promises:

| Version | Moves when |
|---|---|
| **hyprpeach** `vX.Y.Z` | **Major**: a plugin is removed, renamed or has a major release, or how hyprpeach installs changes. **Minor**: a plugin is added or has a minor release. **Patch**: anything else. |
| **a plugin** `<name>-vX.Y.Z` | Semantic versioning against what that plugin does for you. For desktops: a changed chord, `peach.*` signature or `setup()` option is major. |

Tags are never moved once published, so a pin means the same code for as long as it exists.

### From 1.x (`install.sh`)

1.x installed with a `curl … | bash` script that cloned the library to `~/.config/hypr/hyprpeach` and added the bar strip beside it as its own clone. **2.0.0 is one Omarchy plugin** that Omarchy keeps current, with the desktops as one plugin in it. The keymap and the `peach.*` API did not change.

The move is one command, the same one as always:

```bash
hyprpeach upgrade
```

The 1.x command fetches 2.0.0 and runs its `install.sh`, which is now only a bridge: it retires the 1.x bar strip clone, installs hyprpeach through Omarchy, and adds desktops from it. That rewrites the hyprpeach block in `hyprland.lua` to load the library from the plugin, and replaces the copied `hyprpeach` command with a link that follows every update. Everything you had, you still have.

Then add whatever else you want — the new one in 2.0.0 is dev-ports:

```bash
hyprpeach plugin list
hyprpeach plugin add dev-ports
```

One thing is left for you, because it may not only be hyprpeach's: the 1.x library clone. Once nothing of your own requires it,

```bash
rm -rf ~/.config/hypr/hyprpeach
```

<details>
<summary>By hand, if the 1.x command is gone</summary>

<br>

```bash
omarchy plugin remove hyprpeach.desktops --yes
omarchy plugin add https://github.com/mariotinoco/hyprpeach --enable
~/.config/omarchy/plugins/hyprpeach/bin/hyprpeach plugin add desktops
rm -rf ~/.config/hypr/hyprpeach
```

</details>

`install.sh` stays through 2.x as that bridge, so an old `curl … | bash` link still lands on the plugin. It is deprecated, and nothing new goes into it.

<br>

## What you get

|  | Stock Hyprland | 🍑 hyprpeach |
|---|---|---|
| `super+N` | Teleports focus to whichever monitor owns workspace N | Every panel moves to **its own** desktop N |
| Where a workspace lives | Whichever monitor had focus when it was born | Pinned to one monitor, by **EDID serial** |
| An emptied workspace | **Destroyed** — and forgets its monitor | Persists. Always there, always the same screen |
| `super+←` `→` | Focuses a window one place over | Steps the whole desk one desktop, both panels, wrapping |
| Sending a window to another screen | No binding — `moveworkspacetomonitor` moves the *whole workspace* | One window crosses; both desktops stay intact |
| Unplugging a monitor | Its windows are stranded where no key can reach them | `gather_rogue_windows` sweeps them back |
| Flinging a window away | No single-key way to cross screens at all | One key per direction, and your view lands with it |
| Keeping one screen still | Only per-window, and [not for tiled windows at all](#holding-a-panel) | `SUPER + Y` holds a whole panel where it is |
| A pinned window | Flips a monitor up or down, seemingly at random, as you change desktop | Stays on the panel you pinned it to |

<br>

### Why a pinned window used to wander

Hyprland re-records a pinned window's workspace every time that window takes focus, as whatever the *focused* monitor is showing — true on a one-monitor desk, and wrong on every other, because the monitor holding the focus need not be the monitor the window is pinned to. It writes the field and nothing else, so the window does not move and the mismatch is invisible.

A paired switch focuses every panel in turn, so it walks straight into it: the panel that switches first takes the focus, and a pinned window on *another* panel is picked up by the refocus that follows. The window is now recorded on a workspace belonging to a monitor it is not on — and the next time *that* panel changes desktop, Hyprland carries the window along with the workspace it is recorded on, dragging it physically onto the wrong screen. Which way it goes depends on which panel focused it last, which is why it looks random.

hyprpeach puts every pinned window back on the workspace its own monitor is showing before each panel switch, so a pinned window is carried by its own panel — and again afterwards, so anything reading the compositor between switches reads the truth.

<br>

## Holding a panel

`SUPER + Y` holds the panel **under your pointer** where it is. The rest of the desk keeps moving; that one screen stays on whatever it was showing, whichever desktop you switch to. Press it again to let go.

It reads the pointer rather than the focus because the gesture is *that screen, the one I am looking at* — and focusing a panel in order to hold it would move the very thing you are trying to leave alone.

**There is no way to do this with window pinning.** Hyprland refuses to pin a tiled window outright — `pin` is for floating windows, which is why Omarchy's `SUPER + O` floats a window before it pins it. A screen full of tiles cannot be pinned one window at a time, so holding belongs to whatever owns the panels, which is this.

A hold lasts as long as the session and a Hyprland reload clears it. That is deliberate for a mode you can forget you are in: the worst case is that it lapses, not that a screen stays silently stuck.

The bar strip draws a lock on a held panel, and `describe()` says which panels are held rather than reporting them as a split — a detector that fires every time you use a feature is one nobody reads.

On a held panel the bar strip **becomes a padlock**: the tile it is holding stops being a number, and every other desktop goes quiet — they are not places that screen can go until you let it go. At a tile's size there is room for one thing, and a number with a mark on it was two.

**Holding and releasing flash on the screen it happened to** — a padlock closing, a padlock opening — the same way changing desktop flashes a number. It is the one act that makes a screen stop answering, which makes it the one most worth confirming.

**The big number does not flash on a held screen.** It did not move, so it has no news; a number appearing on a screen that stayed put is the overlay contradicting itself. The padlock in the bar is the standing answer, readable whenever you look rather than for a third of a second.

<br>

## Bindings

**hyprpeach adds five chords** — `SUPER + SHIFT + arrows`, and `SUPER + Y` to [hold a panel](#holding-a-panel). Everything else on the keymap is a chord your compositor already binds, taken over so it means the same thing on every panel; a workspace binding hyprpeach *ignores* is a binding that splits your desk.

### What this displaces

Stock Omarchy bindings, given up on purpose: on a two-panel desk the desktop strip is travelled far more often than a window is nudged one place left.

| Chord | Was | Now |
|---|---|---|
| `SUPER + ←` `→` | Focus left / right window | Previous / next desktop |
| `SUPER + SHIFT + ←` `→` | Swap window left / right | Fling window one desktop along |
| `SUPER + SHIFT + ↑` `↓` | Swap window up / down | Fling window to the panel above / below |

**`SUPER + ↑` `↓` is left alone**, so directional window focus survives on the axis where the panels are stacked.

### Off by default

`SUPER + SHIFT + TAB`, `SUPER + CTRL + TAB`, `SUPER + scroll` and `SUPER + SHIFT + ALT + 1…9` are bound to nothing — the table above already covers the day. Name a chord for any of them in [`keys`](#install) to bring it back.

> [!IMPORTANT]
> Their **stock** bindings are cleared regardless, and so is the whole ten-key number row even when you have fewer desktops. A chord hyprpeach declines to bind is not a chord that falls silent — it is the stock one, still live, still moving a single panel.

<br>

## API

Everything is callable from your own config, and from `hyprctl eval` — which matters, because a paired switch is *two* dispatches and `hyprctl dispatch` is a wrapper for exactly one.

```lua
local peach = require("hyprpeach")
```

| Function | |
|---|---|
| `peach.focus_desktop({ desktop })` | Bring every panel to that desktop |
| `peach.current_desktop()` | The desktop in front of you, or `nil` on a special workspace |
| `peach.step_desktop({ step })` | Step by ±N, wrapping at both ends |
| `peach.focus_former_desktop()` | Back to the previous desktop |
| `peach.focus_window_with_its_desktop({ window })` | **For status bars.** Focus a window *and* bring every panel to the desktop it lives on |
| `peach.send_active_window_to_desktop({ desktop, follow })` | Move a window between desktops, keeping its panel |
| `peach.send_active_window_to_relative_desktop({ step, follow })` | Fling it ±N desktops along, wrapping, from the window's own desktop |
| `peach.send_active_window_to_panel({ step, follow })` | Move a window between panels, keeping its desktop |
| `peach.swap_panels()` | Swap what the two panels show |
| `peach.gather_rogue_windows()` | Rescue windows stranded outside every band |
| `peach.toggle_overview()` | Open or close [the overview](plugins/overview/README.md) on every monitor |
| `peach.describe()` | One line of live state, and whether the panels agree |

### Wiring up a status bar

A bar's window list almost certainly dispatches `focus({ window })`, which follows the window onto *its* monitor and says nothing about the others — splitting your panels apart. Point it here instead:

```bash
hyprctl eval 'require("hyprpeach").focus_window_with_its_desktop({ window = "address:0x5f3a21" })'
```

### Catching a split

The panels disagreeing is the one state this model cannot show you: each bar draws its own panel's workspace, so nothing on screen says they have drifted apart. `describe()` is how you find out.

```console
$ hyprctl eval 'return require("hyprpeach").describe()'
panel 1 → desktop 5, panel 2 → desktop 5  [paired]
```

<br>

## The bar strip

*Omarchy only. Everything above works without it.*

Omarchy's own `omarchy.workspaces` widget cannot draw a hyprpeach desk. It filters to `id > 0 && id <= 10`, so a second monitor's band is invisible to it — every bar on every screen draws the *first* monitor's workspaces. And clicking one dispatches a single focus, splitting the pair the moment you touch the mouse.

The replacement lives in `plugins/desktops/`, and `hyprpeach plugin add desktops` [puts it on your bar](#yeah-yeah-whatever--gimme-the-install-command-for-omarchy).

### On a desk with no window gaps

Every measure in the strip is derived from Hyprland's `general:gaps_out`, because the point is to line the tiles up with the windows. Set it to `0` and there is no gutter left to line up with, so the strip falls back to the shell's own smallest spacing for the things you can see — the inset, the gap between tiles, the clearance from the screen edge — and stops reaching past the bar's own padding to meet a window edge that is not there. A desk that does use gaps is unaffected.

<br>

### The strip

Three states that differ in **shape**, not only in brightness — so you can rank them from peripheral vision, across a very wide panel, without reading them:

| | Looks like | Means |
|---|---|---|
| **Current** | bar-coloured numeral on a near-solid tile | the desktop you are on |
| **Occupied** | bright numeral on a faint tile | has windows on it |
| **Empty** | faint numeral, no tile | nothing there |

All three are **the same ink at three alphas**, and the ink is plain white or plain black — whichever contrasts with the bar — rather than a colour out of the theme.

A themed accent was tried first and does not survive contact with real themes. `Color.bar.active` is an arbitrary hue: on one theme a clean pink, on the next a muddy red on cream, and on a third so close to the bar background that the three states collapse into one. Neutral ink cannot clash, because it is defined *against the surface it sits on* — the widget measures the bar's Rec. 709 luminance and picks the side that contrasts.

The marks are **rounded tiles, not circles**. A circle has to clear its own diagonal, so it wastes the corners of every cell and pushes the strip longer than it needs to be; a tile fills the cell and packs tighter.

<details>
<summary><b>How the strip is positioned</b></summary>

<br>

The bar is transparent, so there is no painted bar to be centred inside — its width has no edges an eye can see. What *is* visible is the **gutter**: the bar plus the gap Hyprland leaves between it and the nearest window. The strip is inset by exactly one window gap from both sides of that gutter, which is what "centred" means here. Measuring against the bar instead left the tiles 5px from the screen edge and 15px from the window, which read as shoved against the edge.

The first tile starts where a tiled window's **content** starts — the window gap, plus the border drawn inside it. A window's frame begins at the gap, but the border sits on top of that and is thin and usually a different colour, so the inner edge is the one an eye reads as "the top of the window". Aligning to the frame measures correct and looks wrong by exactly the border width. Since the bar pads its own ends further in than that, the strip reaches back out past that padding — the leading margin is often negative.

Tiles are one window gap apart, the same measure as everything else here.

These come from `Style.gapsOut`, the shell's own reading of Hyprland's `general:gaps_out`, re-read when the compositor changes — **it stores half the compositor's value**, so the real gap is twice it — plus `general:border_size`, which the shell does not read, so the widget reads it once at startup itself.

Every term is an integer of logical pixels — `Style.gapsOut * 2`, `Style.space(8)`, `barSize` — so the sums are exact at any font base size rather than accumulating a rounding error per step.

> [!NOTE]
> The tiles keep a proportional corner radius rather than `Style.cornerRadius`. That token mirrors `decoration:rounding`, which is `0` on plenty of setups — matching it would make the tiles square.

There are **nine desktops, a 3 × 3**, and `SUPER + 0` is not a tenth: it opens [the overview](plugins/overview/README.md), the whole grid at once. The number is fixed rather than a setting, because the overview and the orbit scene are both built on that grid.

<br>

</details>

<details>
<summary><b>How the overlay works</b></summary>

<br>

When the desktop changes, a large numeral flashes in the middle of the screen and fades out. It is there to be glanced at, not read — with a desk this wide it is easy to lose track of where you are, and a number you catch out of the corner of your eye is faster than finding the bar.

It appears on **every screen at once**, because on a paired desk every panel just moved — whichever monitor you happen to be looking at has the number on it. It watches the **compositor**, not a keybinding, so it fires however the desktop changed — keyboard, a click in the bar, a script. hyprpeach knows nothing about it.

The numeral is translucent, with an outline in the theme's background colour kept firmer than the fill — so you see straight through it and it still reads over a light wallpaper, a dark one, or a busy one.

The alpha is on the numeral rather than on the window: fading the whole item would ghost the outline along with the fill and lose exactly the contrast the outline exists to provide.

> [!NOTE]
> A paired switch is one dispatch *per panel*, so the focused workspace changes once per monitor for a single keypress. The overlay compares **desktops**, not workspace IDs, which is what keeps it to one flash per press instead of one per screen.

The surface is visual only — its layer-shell input region is empty, so it never eats a click even while it is on screen.

It appears with no fade at all. On something this brief a ramp reads as lag: by the time a fade and a spring had settled, most of the hold was already spent. Only the exit is animated. The surface is sized to the numeral rather than to the screen, and the glyph is cached as a texture rather than re-drawn from outlines, so there is as little as possible between the keypress and the pixels.

<br>


> [!IMPORTANT]
> The bar widget hot-reloads on save. **The overlay does not** — it is a `keepLoaded` panel, so the shell holds its instance and a stale QML cache survives even `omarchy-shell shell rescanPlugins`. After editing it, run `omarchy restart shell`.

> [!NOTE]
> Omarchy "plugins" are Quickshell **bar** plugins, a different extension point from Hyprland's Lua config. On Omarchy the whole repository is installed as one plugin: the shell loads `plugins/desktops/`, and Hyprland loads `init.lua` out of the same clone. One repository, because they are one idea and they ship together.

<br>

</details>

## Nothing to compile

Hyprland 0.55 made Lua a first-class config language, and everything the library needs — workspace rules, keybindings, dispatchers, live window and monitor queries — is reachable from it. So there is no `hyprpm` plugin here: native code linked against a compositor's internals breaks on **every** release until someone rebuilds it, and this is a file you clone once. hyprsplit and split-monitor-workspaces both reached the same conclusion and moved to Lua; this started there.

> [!NOTE]
> The optional bar strip *is* an "Omarchy plugin", which is a different thing entirely — a [Quickshell](https://quickshell.org) QML widget for Omarchy's status bar, not compiled code inside the compositor. It is QML that hot-reloads, and nothing about it changes the paragraph above. Skip it and hyprpeach works exactly the same.

<br>

## Prior art

This library owes a great deal to work done in the open, and the debts are specific.

### [hyprsplit](https://github.com/shezdy/hyprsplit) — *shezdy*

The direct ancestor, and the better starting point if you want the other model.

- **`persistent_workspaces`** — the single most important line in this library. Without persistence Hyprland destroys an emptied workspace and the monitor it was pinned to is forgotten with it, so the mapping is not merely arbitrary, it is *amnesiac*. hyprsplit named this and made it an option; `hyprpeach` makes it unconditional, because there is no version of this model that works without it.
- **`grab_rogue_windows`** — named a failure mode that is easy to not think about until it costs you: unplug a monitor and its windows sit on workspaces no keybinding can reach. Reimplemented here as `gather_rogue_windows`.
- **`monitor_priority`** — the idea of reserving a deterministic band of workspace IDs per monitor. `hyprpeach` keys those bands to EDID serials rather than names, which is a *difference*, not an improvement in judgement: hyprsplit's choice is the right one when your monitors are distinguishable.
- **`swap_monitors`** — hyprsplit shipped this as a dispatcher first. It is native to Hyprland now, and `peach.swap_panels()` is a thin wrapper that knows which two monitors you meant.

### [split-monitor-workspaces](https://github.com/zjeffer/split-monitor-workspaces) — *zjeffer, originally Duckonaut*

The original awesome/dwm-like workspaces for Hyprland, and the project that established per-monitor workspace bands as a thing Hyprland users want. It also pioneered detecting a tiling plugin at runtime and deferring to its dispatchers — a good idea `hyprpeach` does not yet implement.

### [pyprland](https://github.com/hyprland-community/pyprland)

Its `shift_monitors` plugin rotates workspaces across every screen in one command — the first place I saw the insight that a multi-monitor action should be *one* user-level gesture that fans out, rather than N gestures the user has to sequence.

### [Hyprland](https://github.com/hyprwm/Hyprland) — *vaxerski and contributors*

For the Lua config API this is built on, and for a straight answer about what the compositor will not do, which is worth more than a workaround.

> **The difference in one sentence:** hyprsplit and split-monitor-workspaces give each monitor its **own independent** set of workspaces, where `super+N` moves only the screen you are looking at. `hyprpeach` binds the monitors **together** into one desk that turns as a unit. Both are correct; they are answers to different questions about what a second monitor is *for*. If you want independent screens, use hyprsplit — it is mature, well-tested and does that job properly.

<br>

## License

[MIT](LICENSE).
