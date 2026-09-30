--- hyprpeach 🍑 — an opinionated way for monitors and workspaces to interact.
---
--- THE ONE IDEA. Hyprland cannot show a single workspace on two monitors at
--- once; asked directly, its maintainer's answer was "you can't do that"
--- (Hyprland discussion #10088). So a *desktop* here is not a workspace. A
--- desktop is a SET of workspaces, one pinned to each monitor, and every
--- desktop-level action dispatches once per monitor. Press the key for desktop
--- 3 and every panel shows its own desktop 3, together, always.
---
--- WHAT THIS IS NOT. hyprsplit and split-monitor-workspaces implement the
--- awesome/dwm model, where each monitor browses its own workspaces
--- independently and the number keys move only the focused one. That model is
--- good and this is not a replacement for it. This is the other model: the
--- panels move as one surface. Pick whichever matches how you think about a
--- multi-monitor desk. See README.md for credits and prior art.
---
--- CONVENTIONS. Every function takes a single table, so a call site reads as
--- what it does rather than as a list of positions. `setup` requires only
--- `monitors_bottom_to_top`, because nobody else knows what is on your desk;
--- everything else falls back to DEFAULTS below, which are tuned so that a
--- stock Omarchy or Hyprland keymap keeps working. A name it does not
--- recognise is refused rather than ignored -- an unrecognised field in a Lua
--- table is simply absent, so a typo would otherwise do nothing and say
--- nothing.

local peach = {}

--- Everything `setup` did not have to be told.
---
--- These are tuned for a stock Omarchy/Hyprland keymap: the number row and the
--- TAB chords match what those already bind, so the replacements land on the
--- keys muscle memory expects, and the additions sit on chords checked against
--- Omarchy's defaults. Only `monitors_bottom_to_top` has no sensible default,
--- because nobody else knows what is on your desk.
--- NINE DESKTOPS: A 3 x 3, AND NOT A SETTING.
---
--- The desk is a torus. Columns are bearings around the station, rows are
--- positions around its orbit, and both wrap -- so every step, 3 -> 4 and
--- 9 -> 1 included, is the same move. The overview draws that grid and the
--- orbit scene flies that path; a desk of seven or twelve desktops has neither,
--- so the number is fixed here rather than offered as an option somebody could
--- set and quietly break both. `0` is not a tenth desktop: it opens the overview.
local DESKTOP_COUNT = 9

--- WHY EACH MONITOR'S BAND IS STILL TEN WORKSPACES WIDE. 2.x had ten desktops,
--- so the bottom panel owned workspaces 1-10 and the next one up 11-20. Keeping
--- the band at ten keeps every window's workspace number where it was: the
--- bottom panel's desktop 3 is still workspace 3, the top panel's still 13.
--- The tenth workspace of each band is simply no longer a desktop.
local BAND_WIDTH = 10

local DEFAULTS = {
  --- WHETHER YOUR VIEW FOLLOWS A WINDOW YOU FLING.
  ---
  --- Named after `focus follows mouse`, and true for the same reason: the
  --- pointer of attention should end up where the thing you just acted on is.
  --- Flinging a window to another desktop or another panel is a decision about
  --- where you are going to work next, so the view goes with it.
  ---
  --- Set it false and a fling becomes purely an act of tidying: the window
  --- leaves and you carry on where you are.
  focus_follows_fling = true,

  notify = true,
  unbind_conflicting_defaults = true,

  --- ONE RULE: SUPER MOVES YOU, SUPER+SHIFT MOVES THE WINDOW.
  ---
  --- It holds for both halves of the keyboard, which is the whole of what
  --- there is to learn:
  ---
  ---   SUPER + 1..0          go to that desktop
  ---   SUPER + left/right    go to the desktop beside it
  ---   SUPER + SHIFT + 1..0        fling the window to that desktop
  ---   SUPER + SHIFT + left/right  fling it to the desktop beside this one
  ---   SUPER + SHIFT + up/down     fling it to the panel above or below
  ---
  --- Up and down mean panels because panels are stacked; left and right mean
  --- desktops because desktops are a strip. The gesture is the same in both
  --- directions, so there is nothing to remember beyond the rule.
  ---
  --- THIS DISPLACES STOCK BINDINGS, DELIBERATELY. SUPER + left/right is
  --- directional window focus in stock Omarchy, and SUPER + SHIFT + arrows is
  --- window swapping. They are given up on purpose: on a two-panel desk the
  --- desktop strip is travelled far more often than a window is nudged one
  --- place left. SUPER + up/down is left alone, so directional focus survives
  --- on the axis where the panels are stacked.
  ---
  --- Everything else is `false` -- bound to nothing, and the stock chord
  --- cleared so it cannot split the desk behind your back. Name a chord to
  --- bring any of them back.
  keys = {
    -- Numbers: absolute.
    focus_desktop_modifier          = "SUPER",
    send_window_modifier            = "SUPER + SHIFT",

    -- Arrows: relative.
    previous_desktop_arrow          = "SUPER + LEFT",
    next_desktop_arrow              = "SUPER + RIGHT",
    send_window_to_previous_desktop = "SUPER + SHIFT + LEFT",
    send_window_to_next_desktop     = "SUPER + SHIFT + RIGHT",
    send_window_to_panel_above      = "SUPER + SHIFT + UP",
    send_window_to_panel_below      = "SUPER + SHIFT + DOWN",

    -- Hold the panel under the pointer. Bound by default, unlike the rest of
    -- the additions below, because a held panel is invisible in the keymap and
    -- discoverable only if the key exists.
    toggle_held_panel               = "SUPER + Y",

    -- Every desktop at once, each monitor showing its own. Drawn by the
    -- overview plugin (`hyprpeach plugin add overview`); without it the key
    -- does nothing, which is what SUPER + TAB did here before it existed.
    toggle_overview                 = "SUPER + TAB",

    -- Off. Real capabilities, still callable as `peach.*`; they simply do not
    -- earn a key when the rule above already covers the day.
    send_window_and_follow_modifier = false,
    next_desktop                    = false,
    previous_desktop                = false,
    former_desktop                  = false,
    next_desktop_scroll             = false,
    previous_desktop_scroll         = false,
    swap_panels                     = false,
    gather_rogue_windows            = false,
  },
}

--- The chords stock Hyprland and Omarchy bind to single-dispatch workspace
--- actions.
---
--- Cleared on setup whatever `keys` says, and this is the part that cannot be
--- derived from `keys`: a chord hyprpeach declines to bind is not a chord that
--- falls silent. It is the stock one, still live, still moving a single panel.
--- Turning a hyprpeach binding off has to mean the key does nothing -- not
--- that it quietly goes back to splitting the desk.
local STOCK_NUMBER_ROW_MODIFIERS = { "SUPER", "SUPER + SHIFT", "SUPER + SHIFT + ALT" }
local STOCK_WORKSPACE_CHORDS = {
  "SUPER + TAB", "SUPER + SHIFT + TAB", "SUPER + CTRL + TAB",
  "SUPER + mouse_down", "SUPER + mouse_up",
}

--- Populated by `setup`. Nothing here is written anywhere else.
local state = {
  --- Bottom-to-top. A paired switch walks this BACKWARDS so the bottom panel
  --- switches last and therefore keeps the focus; on a desk with stacked
  --- monitors the bottom one is at eye level.
  bands = nil,
  focus_follows_fling = nil,
  notify = nil,
}

-- ---------------------------------------------------------------------------
-- notification
-- ---------------------------------------------------------------------------

--- Hyprland's own notification, so the library needs no notification daemon and
--- no external command. `text` is the key that carries the message: an unknown
--- key in a Lua options table is not an error, it is simply absent, so a
--- misspelling here would produce a silent empty toast rather than a failure.
local function announce(parameters)
  if not state.notify then return end
  hl.notification.create({ text = "🍑 " .. parameters.text, time = 1400 })
end

-- ---------------------------------------------------------------------------
-- the pairing arithmetic, stated once
-- ---------------------------------------------------------------------------

--- Which band — which monitor, as a 1-based index into `state.bands` — a
--- workspace ID belongs to.
local function band_index_of_workspace(parameters)
  return math.floor((parameters.workspace_id - 1) / BAND_WIDTH) + 1
end

--- The workspace ID that shows `desktop` on the band at `band_index`.
local function workspace_id_for(parameters)
  return state.bands[parameters.band_index].workspace_band_start + parameters.desktop
end

--- The desktop a workspace shows, or nil when that workspace is not part of any
--- band. Special and named workspaces carry IDs <= 0 and a scratchpad has no
--- desktop to bring the other panels to, so nil is the honest answer rather
--- than a plausible-looking 1.
local function desktop_of_workspace(parameters)
  local workspace_id = parameters.workspace_id
  if workspace_id < 1 then return nil end
  if state.bands[band_index_of_workspace({ workspace_id = workspace_id })] == nil then return nil end
  local desktop = ((workspace_id - 1) % BAND_WIDTH) + 1
  if desktop > DESKTOP_COUNT then return nil end
  return desktop
end

-- ---------------------------------------------------------------------------
-- the pinned-window repair
-- ---------------------------------------------------------------------------

--- Put every pinned window back on the workspace its own monitor is showing.
---
--- WHAT GOES WRONG WITHOUT IT. Hyprland re-records a pinned window's workspace
--- every time that window takes focus, as whatever the FOCUSED monitor happens
--- to be showing:
---
---     if (pWindow->m_pinned)
---         pWindow->m_workspace = m_focusMonitor->m_activeWorkspace;
---     -- src/desktop/state/FocusState.cpp, Hyprland 0.56.2
---
--- True on a one-monitor desk and wrong on every other, because the monitor
--- holding the focus need not be the monitor the window is pinned to. It is a
--- bare field write: the window's monitor and its pixels are left alone, so
--- nothing on screen changes and the mismatch is invisible when it happens.
---
--- A PAIRED SWITCH WALKS STRAIGHT INTO IT, because focusing every panel in
--- turn is the whole idea of this library. The panel dispatched first takes
--- the focus, and a pinned window on ANOTHER panel is then picked up by the
--- refocus that follows: with `input:follow_mouse` Hyprland hit-tests under
--- the cursor, and that hit test considers pinned windows from any workspace
--- by design. The window ends up recorded on a workspace belonging to a
--- monitor it is not on.
---
--- THE DAMAGE LANDS ON THE NEXT SWITCH. `CMonitor::changeWorkspace` carries
--- pinned windows along with the workspace they are RECORDED on, so the other
--- panel's switch drags the window physically onto itself. The window flips
--- one monitor up or down, and which way depends on which panel focused it
--- last -- which is why it looks random rather than wrong in one direction.
---
--- Realigning BEFORE a switch is the part that prevents the flip: a pinned
--- window recorded where it actually is gets carried by its own panel, which
--- is the behaviour that was wanted all along. Realigning AFTER one is what
--- keeps every other reader honest -- a bar, `describe`, and this file's own
--- `send_active_window_*`, which all read a window's panel off the workspace
--- it is recorded on.
---
--- `window.monitor` is the half of the pair that can be trusted, because the
--- faulty write touches only the workspace. `follow = false` keeps the repair
--- silent: it corrects a record, it is not a move the user asked for.
---
--- CALLERS READ THE WINDOW THEY MEAN BEFORE CALLING THIS. Repairing a pinned
--- window that currently holds focus hands the focus to whatever sits under
--- it, so "the active window" is not necessarily the same window either side
--- of this call. Read it once, first, and name it explicitly from then on.
local function realign_pinned_windows()
  for _, window in ipairs(hl.get_windows()) do
    if window.pinned and window.monitor ~= nil and window.workspace ~= nil then
      local workspace_its_monitor_shows = window.monitor.active_workspace
      if workspace_its_monitor_shows ~= nil and workspace_its_monitor_shows.id ~= window.workspace.id then
        hl.dispatch(hl.dsp.window.move({
          window = window,
          workspace = tostring(workspace_its_monitor_shows.id),
          follow = false,
        }))
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- held panels
-- ---------------------------------------------------------------------------

--- Where the held panels are written for anything outside Hyprland to read.
---
--- A held panel is state that lives in this file's memory, and the bar strip
--- runs in a different process that cannot see it. That matters more here than
--- it looks: a panel showing a different desktop from its neighbours is exactly
--- what a BUG in this library looks like, so a hold nothing draws is
--- indistinguishable from the thing `describe` exists to catch.
---
--- A flag file watched for changes is Omarchy's own idiom for this -- its shell
--- already reads `window-no-gaps` that way -- so this is that pattern rather
--- than a new one. Under XDG_RUNTIME_DIR because a hold is not a preference: it
--- should last as long as the session and no longer. `setup` rewrites it, so a
--- Hyprland reload clears the file at the same moment it clears the memory and
--- the two cannot drift apart.
local HELD_PANELS_PATH = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hyprpeach-held-panels"

--- One held panel per line: the monitor's name, a space, and the desktop it is
--- holding.
---
--- THE DESKTOP IS PUBLISHED TOO, and that is not redundant. The bar draws its
--- highlight from Quickshell's idea of the workspace, which is reliable for the
--- focused monitor and measurably not for the others -- with the desk on 8 and
--- a panel held on 1, Quickshell reported that panel's active workspace as 8.
--- A held panel is precisely the case where the other monitor's reading is the
--- one that matters, so the number comes from here, where it is known, instead
--- of being asked for somewhere it is guessed.
local function publish_held_panels()
  local file = io.open(HELD_PANELS_PATH, "w")
  if file == nil then return end
  for _, band in ipairs(state.bands) do
    if band.held then
      local monitor = hl.get_monitor(band.monitor)
      local desktop = monitor ~= nil and monitor.active_workspace ~= nil
        and desktop_of_workspace({ workspace_id = monitor.active_workspace.id })
        or nil
      if monitor ~= nil then file:write(monitor.name, " ", tostring(desktop or ""), "\n") end
    end
  end
  file:close()
end

--- Which band a live monitor is, matched by id rather than by selector: the
--- selector is what the config said, the id is what Hyprland ended up with.
local function band_index_of_monitor(parameters)
  for band_index, band in ipairs(state.bands) do
    local monitor = hl.get_monitor(band.monitor)
    if monitor ~= nil and monitor.id == parameters.monitor.id then return band_index end
  end
  return nil
end

--- The desktop the desk is on, read from the lowest panel that still moves.
---
--- With nothing held this is the bottom panel, which is the one that keeps the
--- focus anyway, so it agrees with "the desktop in front of you". It only
--- differs when the panel you are standing on is held -- and stepping relative
--- to a panel that is not going to move is not what anybody means by "next
--- desktop".
local function moving_desktop()
  for band_index = 1, #state.bands do
    local band = state.bands[band_index]
    if not band.held then
      local monitor = hl.get_monitor(band.monitor)
      if monitor ~= nil and monitor.active_workspace ~= nil then
        return desktop_of_workspace({ workspace_id = monitor.active_workspace.id })
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- the public surface
-- ---------------------------------------------------------------------------

--- The desktop currently in front of you, or nil if you are on a special
--- workspace.
function peach.current_desktop()
  return desktop_of_workspace({ workspace_id = hl.get_active_workspace().id })
end

--- Bring EVERY panel to `desktop`.
---
--- Backwards through the bands, so the bottom panel switches last: focus
--- follows whichever half switched most recently. That is also why no
--- "focus this monitor" dispatch is needed anywhere in this file — the
--- workspace switch carries the focus with it, which is the behaviour that
--- makes a single-dispatch SUPER+N feel broken and the thing this library
--- turns to its advantage.
---
--- The pinned-window repair runs before EVERY dispatch, not once before the
--- loop, because the thing it repairs is written asynchronously. Hyprland
--- misrecords a pinned window's workspace from a focus change, and a focus
--- change can arrive from the compositor's own pointer handling between one
--- panel's dispatch and the next -- so a repair taken only at the top of the
--- loop can be stale by the time the second panel switches, and that panel
--- then drags the window onto itself. Repairing before each dispatch closes
--- all but a sub-millisecond window; measured over 272 switches it did not
--- flip once, where the same desk flipped roughly one switch in ninety with
--- the repair taken only once.
---
--- The repair after the loop is for everyone else: a bar, `describe`, and the
--- `send_active_window_*` calls below all read a window's panel off the
--- workspace it is recorded on, and would otherwise read a lie between
--- switches. See `realign_pinned_windows`.
function peach.focus_desktop(parameters)
  for band_index = #state.bands, 1, -1 do
    -- A held panel is simply not dispatched to. That is the whole mechanism:
    -- this loop is the only thing that moves a panel, so declining to run it
    -- for one band leaves that panel exactly where it is, whatever the rest of
    -- the desk does.
    if not state.bands[band_index].held then
      realign_pinned_windows()
      hl.dispatch(hl.dsp.focus({ workspace = tostring(workspace_id_for({ band_index = band_index, desktop = parameters.desktop })) }))
    end
  end
  realign_pinned_windows()
  -- ANNOUNCED, not left to be inferred. Everything that reacts to the desk --
  -- the number on screen, the overview, the orbit scene -- hears this one event
  -- per switch. Reading switches off the focused workspace instead mistook
  -- focus moving between two monitors for a switch whenever they showed
  -- different desktops, which a held panel makes the normal case.
  hl.dispatch(hl.dsp.event("hyprpeach-desktop," .. parameters.desktop))
end

--- Step the desktop by `step`, wrapping at both ends. Lua's `%` is
--- non-negative for a positive divisor, so stepping backwards off desktop 1
--- needs no special case.
function peach.step_desktop(parameters)
  local current = moving_desktop() or peach.current_desktop()
  if current == nil then return end
  peach.focus_desktop({ desktop = ((current - 1 + parameters.step) % DESKTOP_COUNT) + 1 })
end

--- Return to the desktop you were on before this one. Hyprland remembers the
--- last WORKSPACE; the desktop that workspace belonged to is the pair to
--- return to.
function peach.focus_former_desktop()
  local last = hl.get_last_workspace()
  if last == nil then return end
  local desktop = desktop_of_workspace({ workspace_id = last.id })
  if desktop ~= nil then peach.focus_desktop({ desktop = desktop }) end
end

--- Focus a window and bring every panel to the desktop it lives on.
---
--- The desktop is read from the WINDOW rather than from the active workspace,
--- so this is correct for a window on any panel seen from any starting desktop.
--- This is the entry point a status bar or a window switcher wants: the obvious
--- call, `focus({ window })`, follows the window onto its own monitor and says
--- nothing about the others, which splits the panels apart.
---
--- `parameters.window` is anything `hl.get_window` accepts, including the
--- `"address:0x…"` string a bar has to hand.
---
--- The window is read BEFORE the repair; see `realign_pinned_windows`.
function peach.focus_window_with_its_desktop(parameters)
  local window = hl.get_window(parameters.window)
  realign_pinned_windows()
  if window == nil or window.workspace == nil then return end
  local desktop = desktop_of_workspace({ workspace_id = window.workspace.id })
  if desktop ~= nil then peach.focus_desktop({ desktop = desktop }) end
  hl.dispatch(hl.dsp.focus({ window = window }))
end

--- The move both `send_active_window_*` entry points make, on a window named
--- explicitly rather than re-read from the compositor.
---
--- It exists so that "the window whose desktop was measured" and "the window
--- that gets moved" cannot become two different windows. Both callers read the
--- active window once, before the pinned-window repair, and hand it here; a
--- second `get_active_window` after that repair would be a read taken across
--- something that can move focus.
local function send_window_to_desktop(parameters)
  local window = parameters.window
  local band_index = band_index_of_workspace({ workspace_id = window.workspace.id })
  if state.bands[band_index] == nil then return end
  hl.dispatch(hl.dsp.window.move({
    window = window,
    workspace = tostring(workspace_id_for({ band_index = band_index, desktop = parameters.desktop })),
    follow = false,
  }))
  if parameters.follow then
    peach.focus_desktop({ desktop = parameters.desktop })
    hl.dispatch(hl.dsp.focus({ window = window }))
  end
end

--- Send the focused window to `desktop`, keeping it on its own panel.
---
--- The target band is read from the WINDOW, so a window on the top panel moves
--- to the top panel's copy of that desktop. The window changes desktop; it
--- never changes monitor.
---
--- `follow = false` on the move and then following by hand is load-bearing: the
--- move dispatcher's own follow switches the window's monitor and only that one,
--- which is exactly the split this library exists to prevent. The option is
--- spelled `follow`, not `silent` — Hyprland derives silence from it — and
--- because an unknown key is silently absent rather than an error, a
--- misspelling here fails OPEN into the loud behaviour.
---
--- The window is named EXPLICITLY in the move because `focus_desktop` runs
--- afterwards and moves focus: "the active window" is a different window by the
--- end of this function.
---
--- The window is read BEFORE the repair; see `realign_pinned_windows`.
function peach.send_active_window_to_desktop(parameters)
  local window = hl.get_active_window()
  realign_pinned_windows()
  if window == nil or window.workspace == nil then return end
  send_window_to_desktop({ window = window, desktop = parameters.desktop, follow = parameters.follow })
end

--- Fling the focused window to the desktop `step` places along, wrapping.
---
--- Stepped from the WINDOW's own desktop rather than from the active one, so
--- it stays correct for a window on the panel you are not looking at.
---
--- The window is read BEFORE the repair; see `realign_pinned_windows`.
function peach.send_active_window_to_relative_desktop(parameters)
  local window = hl.get_active_window()
  realign_pinned_windows()
  if window == nil or window.workspace == nil then return end
  local desktop = desktop_of_workspace({ workspace_id = window.workspace.id })
  if desktop == nil then return end
  send_window_to_desktop({
    window = window,
    desktop = ((desktop - 1 + parameters.step) % DESKTOP_COUNT) + 1,
    follow = parameters.follow,
  })
end

--- Throw the focused window at the panel `step` positions away (+1 is the next
--- band up), keeping the desktop it is already on.
---
--- Hyprland has no binding for this out of the box: `moveworkspacetomonitor`
--- moves an entire workspace between monitors, which in this model would tear a
--- desktop in half. This moves one window across and leaves both desktops
--- intact. Panels do not wrap — there is no panel above the top one, and
--- silently sending a window to the bottom of the stack would be a surprise.
---
--- The window is read BEFORE the repair; see `realign_pinned_windows`.
function peach.send_active_window_to_panel(parameters)
  local window = hl.get_active_window()
  realign_pinned_windows()
  if window == nil or window.workspace == nil then return end
  local desktop = desktop_of_workspace({ workspace_id = window.workspace.id })
  if desktop == nil then return end
  local target_band_index = band_index_of_workspace({ workspace_id = window.workspace.id }) + parameters.step
  if state.bands[target_band_index] == nil then
    announce({ text = "no panel that way" })
    return
  end
  hl.dispatch(hl.dsp.window.move({
    window = window,
    workspace = tostring(workspace_id_for({ band_index = target_band_index, desktop = desktop })),
    follow = false,
  }))
  -- The desktop does not change, so there is no pair to re-synchronise; the
  -- only question is whether your eyes follow the window to the other panel.
  if parameters.follow then hl.dispatch(hl.dsp.focus({ window = window })) end
end

--- Swap what the panels are showing on the current desktop.
---
--- `swap_monitors` is native to Hyprland now; hyprsplit shipped the idea first
--- as a plugin dispatcher, and it belongs in the desktop model too — "these two
--- windows are on the wrong screens" is a thought you have several times a day.
--- Only meaningful with exactly two panels, which is the shape this is for.
---
--- Pinned windows are realigned first because Hyprland hands a swapped
--- workspace's pinned windows to the other panel by record rather than by
--- position, so a stale record swaps the wrong window.
function peach.swap_panels()
  if #state.bands ~= 2 then
    announce({ text = "swap needs exactly two panels" })
    return
  end
  realign_pinned_windows()
  hl.dispatch(hl.dsp.workspace.swap_monitors({ monitor1 = state.bands[1].monitor, monitor2 = state.bands[2].monitor }))
end

--- Hold the panel under the POINTER where it is, or let it go again.
---
--- A held panel stops answering `focus_desktop`, so the rest of the desk keeps
--- moving and that one screen stays on whatever it was showing -- a reference,
--- a log, a call -- no matter which desktop you switch to.
---
--- Read from the POINTER rather than from the focus, because the gesture is
--- "that screen, the one I am looking at" and your hand is already there. It
--- also means holding a panel does not require focusing it first, which would
--- move the very thing you are trying to leave alone.
---
--- The hold is deliberately not persistent. It lives as long as the session and
--- a Hyprland reload clears it, which is the right default for a mode you can
--- forget you are in: the worst case is that it lapses, not that a panel stays
--- silently stuck across a reboot.
---
--- NO TOAST. The screen it happened to flashes a padlock closing or opening,
--- which is the whole message and is already in the place you are looking. A
--- notification on top of that is the same news twice, in the corner of a
--- different monitor. The one announcement left is for the case where nothing
--- flashes at all, because no panel was found to hold.
function peach.toggle_held_panel()
  local monitor = hl.get_monitor_at_cursor()
  if monitor == nil then return end
  local band_index = band_index_of_monitor({ monitor = monitor })
  if band_index == nil then
    announce({ text = "that screen is not one of the panels" })
    return
  end

  local band = state.bands[band_index]
  band.held = not band.held
  publish_held_panels()
end

--- Open or close the overview on every monitor.
---
--- AN EVENT, NOT A CALL INTO THE SHELL. `omarchy-shell` routes a command to one
--- shell instance, which draws on one monitor, and an overview on one screen of
--- a desk is half an overview. A Hyprland custom event reaches every listener
--- on the event socket, so every monitor opens together. The library says
--- nothing about what is drawn; the overview plugin decides that.
function peach.toggle_overview()
  hl.dispatch(hl.dsp.event("hyprpeach-overview,toggle"))
end

--- Sweep windows stranded outside every band onto the desktop in front of you.
---
--- Unplugging a monitor leaves its windows on workspaces no panel owns, and no
--- binding in this file can reach them — they are simply gone. Taken from
--- hyprsplit's `grab_rogue_windows`, which named a failure mode worth handling.
function peach.gather_rogue_windows()
  local destination = hl.get_active_workspace()
  if destination == nil then return end
  local gathered = 0
  for _, window in ipairs(hl.get_windows()) do
    local workspace = window.workspace
    if workspace ~= nil and workspace.id > 0 and desktop_of_workspace({ workspace_id = workspace.id }) == nil then
      hl.dispatch(hl.dsp.window.move({ window = window, workspace = tostring(destination.id), follow = false }))
      gathered = gathered + 1
    end
  end
  announce({ text = gathered == 0 and "no stranded windows" or ("gathered " .. gathered .. " stranded window(s)") })
end

--- A one-line description of the live pairing, for a bar or a `hyprctl eval`.
--- Reports each panel's desktop and whether the panels agree, which is the one
--- state this model cannot otherwise show: each bar draws its own panel's
--- workspace, so nothing on screen says the panels have drifted apart.
function peach.describe()
  local descriptions = {}
  local desktops = {}
  local held = 0
  for band_index, band in ipairs(state.bands) do
    local monitor = hl.get_monitor(band.monitor)
    local desktop = monitor ~= nil and monitor.active_workspace ~= nil
      and desktop_of_workspace({ workspace_id = monitor.active_workspace.id })
      or nil
    descriptions[#descriptions + 1] = "panel " .. band_index .. " → desktop " .. tostring(desktop)
      .. (band.held and " (held)" or "")
    -- A held panel is EXCLUDED from the agreement test rather than counted as a
    -- disagreement. It is showing a different desktop on purpose, and a split
    -- detector that fires every time somebody uses the feature is a detector
    -- nobody reads by the end of the week.
    if band.held then held = held + 1 else desktops[tostring(desktop)] = true end
  end
  local distinct = 0
  for _ in pairs(desktops) do distinct = distinct + 1 end
  local verdict = distinct > 1 and "  [PANELS DISAGREE]" or "  [paired]"
  if held > 0 then verdict = verdict .. "  " .. held .. " held" end
  return table.concat(descriptions, ", ") .. verdict
end

-- ---------------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------------

local function refuse(parameters)
  error("hyprpeach: " .. parameters.reason .. "\nsee README.md for a complete setup() call", 0)
end

--- Pin every desktop to every panel, permanently.
---
--- `persistent` is the load-bearing word. Without it Hyprland DESTROYS a
--- workspace the moment it empties, and the monitor it was pinned to is
--- forgotten with it — the next switch re-creates it on whichever panel happens
--- to hold focus, so the mapping is not merely arbitrary, it is amnesiac. This
--- is the single most important line in the library and it took measuring a
--- misbehaving desk to find. hyprsplit calls the same thing
--- `persistent_workspaces`.
---
--- `default` brings every panel up on desktop 1 at login.
local function create_workspace_rules()
  for _, band in ipairs(state.bands) do
    for desktop = 1, DESKTOP_COUNT do
      hl.workspace_rule({
        workspace = tostring(band.workspace_band_start + desktop),
        monitor = band.monitor,
        default = desktop == 1,
        persistent = true,
      })
    end
  end
end

--- Unbind the stock single-dispatch bindings this library replaces.
---
--- The number row is bound BY KEYCODE (`code:10` is `1`, `code:19` is `0`) both
--- here and by Hyprland's and Omarchy's defaults, because a keycode survives a
--- keyboard-layout change. An unbind naming `SUPER + 1` matches nothing, leaves
--- the default in place, and then BOTH bindings fire on one press.
local function unbind_conflicting_defaults(parameters)
  -- The number row is bound BY KEYCODE (`code:10` is `1`, `code:19` is `0`)
  -- both here and by the stock configs, because a keycode survives a keyboard
  -- layout change. An unbind naming `SUPER + 1` matches nothing, leaves the
  -- default in place, and then BOTH bindings fire on one press.
  -- The stock number row is TEN keys and there are nine desktops. Clearing
  -- only nine would leave SUPER+0 bound to a flat workspace 10 on one panel,
  -- splitting the desk with nothing to report it; it is cleared with the rest
  -- and bound below to the overview.
  for keyIndex = 1, 10 do
    local keycode = "code:" .. tostring(keyIndex + 9)
    for _, modifier in ipairs(STOCK_NUMBER_ROW_MODIFIERS) do
      hl.unbind(modifier .. " + " .. keycode)
    end
  end
  -- Every one of these is a single dispatch in the stock config, so every one
  -- of them splits the panels apart. `e+1` is the clearest: it walks to the
  -- next workspace that EXISTS, which on a two-panel desk is usually the other
  -- monitor, making the "next workspace" key a monitor hop in disguise.
  for _, chord in ipairs(STOCK_WORKSPACE_CHORDS) do
    hl.unbind(chord)
  end
  -- And whatever this config is about to take, so a hyprpeach binding replaces
  -- the stock one rather than stacking on top of it -- Hyprland runs every
  -- binding on a chord, in order, so two live bindings both fire. The three
  -- modifier entries are prefixes rather than chords and are handled by the
  -- number-row loop above.
  for name, chord in pairs(parameters.keys) do
    if chord and not name:find("_modifier$") then hl.unbind(chord) end
  end
end

local function create_bindings(parameters)
  local keys = parameters.keys

  --- A chord set to `false` is simply not bound. Everything it would have done
  --- stays reachable as a `peach.*` call, so trimming the keymap never removes
  --- a capability -- only a shortcut to it.
  local function bind(chord, action, description)
    if not chord then return end
    hl.bind(chord, action, { description = description })
  end

  local function on_number_row(modifier, keycode)
    if not modifier then return false end
    return modifier .. " + " .. keycode
  end

  for desktop = 1, DESKTOP_COUNT do
    local keycode = "code:" .. tostring(desktop + 9)

    bind(on_number_row(keys.focus_desktop_modifier, keycode), function()
      peach.focus_desktop({ desktop = desktop })
    end, "Focus desktop " .. desktop)

    -- `focus_follows_fling` is read HERE, at press time, so a caller that flips
    -- it at runtime gets the new behaviour without rebinding anything.
    bind(on_number_row(keys.send_window_modifier, keycode), function()
      peach.send_active_window_to_desktop({ desktop = desktop, follow = state.focus_follows_fling })
    end, "Send window to desktop " .. desktop)

    -- Off by default. The escape hatch for whichever way `focus_follows_fling`
    -- is set: this one always takes you along.
    bind(on_number_row(keys.send_window_and_follow_modifier, keycode), function()
      peach.send_active_window_to_desktop({ desktop = desktop, follow = true })
    end, "Send window to desktop " .. desktop .. " and follow it")
  end

  -- `0`, the key after the last desktop, is the whole grid: the overview.
  bind(on_number_row(keys.focus_desktop_modifier, "code:19"), function() peach.toggle_overview() end, "Every desktop at once")

  local function step(amount)
    return function() peach.step_desktop({ step = amount }) end
  end

  local function fling(amount)
    return function()
      peach.send_active_window_to_relative_desktop({ step = amount, follow = state.focus_follows_fling })
    end
  end

  -- SUPER moves you.
  bind(keys.previous_desktop_arrow, step(-1), "Previous desktop")
  bind(keys.next_desktop_arrow, step(1), "Next desktop")
  bind(keys.next_desktop, step(1), "Next desktop")
  bind(keys.previous_desktop, step(-1), "Previous desktop")
  bind(keys.next_desktop_scroll, step(1), "Next desktop")
  bind(keys.previous_desktop_scroll, step(-1), "Previous desktop")
  bind(keys.former_desktop, function() peach.focus_former_desktop() end, "Former desktop")

  -- SUPER + SHIFT moves the window. Left and right along the desktop strip,
  -- up and down between the stacked panels.
  bind(keys.send_window_to_previous_desktop, fling(-1), "Send window to the previous desktop")
  bind(keys.send_window_to_next_desktop, fling(1), "Send window to the next desktop")
  bind(keys.send_window_to_panel_above, function()
    peach.send_active_window_to_panel({ step = 1, follow = state.focus_follows_fling })
  end, "Send window to the panel above")
  bind(keys.send_window_to_panel_below, function()
    peach.send_active_window_to_panel({ step = -1, follow = state.focus_follows_fling })
  end, "Send window to the panel below")

  bind(keys.toggle_held_panel, function() peach.toggle_held_panel() end, "Hold the panel under the pointer")
  bind(keys.toggle_overview, function() peach.toggle_overview() end, "Every desktop at once")
  bind(keys.swap_panels, function() peach.swap_panels() end, "Swap what the panels show")
  bind(keys.gather_rogue_windows, function() peach.gather_rogue_windows() end, "Gather stranded windows")
end

--- Configure hyprpeach and install its workspace rules and bindings.
---
--- ONLY `monitors_bottom_to_top` IS REQUIRED. It is a list of monitor
--- selectors in PHYSICAL order, bottom first; the first entry takes the
--- un-offset band, so on that monitor desktop N is simply workspace N.
--- Everything else falls back to DEFAULTS above, which are tuned so that a
--- stock Omarchy or Hyprland keymap keeps working.
---
--- PREFER `desc:` SELECTORS WITH THE SERIAL. hyprsplit and
--- split-monitor-workspaces assign bands by connector name or monitor ID,
--- which is fine until two monitors are the same model: connector names change
--- when cables move ports, and then the desktops silently swap screens with
--- nothing reporting it. `hyprctl monitors all` prints the full description;
--- the trailing token is the serial.
---
--- `keys` is merged key-by-key, so overriding one chord keeps the rest.
function peach.setup(options)
  options = options or {}
  if options.monitors_bottom_to_top == nil or #options.monitors_bottom_to_top < 1 then
    refuse({ reason = "monitors_bottom_to_top is required: list your monitors in physical order, bottom first" })
  end

  local function chosen(key)
    if options[key] ~= nil then return options[key] end
    return DEFAULTS[key]
  end

  if options.desktop_count ~= nil then
    refuse({ reason = "desktop_count is gone: hyprpeach has nine desktops, a 3 x 3, and SUPER + 0 opens the overview. Remove desktop_count from setup()." })
  end

  state.focus_follows_fling = chosen("focus_follows_fling")
  state.notify = chosen("notify")
  state.bands = {}
  for index, monitor in ipairs(options.monitors_bottom_to_top) do
    state.bands[index] = { monitor = monitor, workspace_band_start = (index - 1) * BAND_WIDTH, held = false }
  end

  -- Merged per key, not wholesale: overriding one chord should not silently
  -- unbind the twelve you did not mention.
  local keys = {}
  for key, value in pairs(DEFAULTS.keys) do keys[key] = value end
  for key, value in pairs(options.keys or {}) do
    if DEFAULTS.keys[key] == nil then
      refuse({ reason = "unknown key in setup().keys: " .. tostring(key) })
    end
    keys[key] = value
  end

  -- Rewritten from nothing held, because that is what `state.bands` above now
  -- says. A reload that cleared the memory and left a stale file behind would
  -- have the bar drawing a lock on a panel that moves.
  publish_held_panels()

  create_workspace_rules()
  if chosen("unbind_conflicting_defaults") then unbind_conflicting_defaults({ keys = keys }) end
  create_bindings({ keys = keys })

  return peach
end

return peach
