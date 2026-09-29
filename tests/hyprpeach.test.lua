--- Runs init.lua against a stubbed `hl`, so the pairing arithmetic and the
--- dispatch ORDER can be checked without a compositor. Every case here is a
--- mistake that is easy to make and silent when made.
--
-- Run: lua tests/hyprpeach.test.lua

package.path = "./?/init.lua;./?.lua;" .. package.path

local failures, checks = 0, 0

local function check(parameters)
  checks = checks + 1
  if parameters.got ~= parameters.want then
    failures = failures + 1
    print(string.format("  FAIL %s\n       want: %s\n       got:  %s", parameters.label, tostring(parameters.want), tostring(parameters.got)))
  end
end

--- A fresh stub compositor. `dispatched` records every dispatch in order,
--- which is the only way to catch a paired switch that fires in the wrong one.
local function stub_hyprland(parameters)
  local recorder = { dispatched = {}, rules = {}, bound = {}, actions = {}, unbound = {}, notifications = {}, active_window_reads = 0, written = {} }

  -- The held-panel state is published to a file for the bar strip to watch, so
  -- writes are captured here rather than landing in the running session's
  -- runtime directory -- a test suite that puts a lock on a real bar has done
  -- something worse than fail. Reads fall through, because the README check
  -- below opens real files.
  local open_file = io.open
  io.open = function(path, mode)
    if mode ~= "w" then return open_file(path, mode) end
    local parts = {}
    return {
      write = function(_, ...) for _, part in ipairs({ ... }) do parts[#parts + 1] = part end end,
      close = function() recorder.written[path] = table.concat(parts) end,
    }
  end
  local active_window = parameters.active_window
  local active_workspace = parameters.active_workspace

  _G.hl = {
    -- A move is APPLIED, not just recorded: a window that has been moved is on
    -- the workspace it was moved to. Without that, a repair that runs twice and
    -- corrects nothing the second time reads here as a repair that fires twice.
    dispatch = function(descriptor)
      recorder.dispatched[#recorder.dispatched + 1] = descriptor
      if descriptor.kind == "move" and type(descriptor.options.window) == "table" then
        descriptor.options.window.workspace = { id = tonumber(descriptor.options.workspace) }
      end
    end,
    bind = function(keys, action, options)
      recorder.bound[keys] = options and options.description or true
      recorder.actions[keys] = action
    end,
    unbind = function(keys) recorder.unbound[#recorder.unbound + 1] = keys end,
    workspace_rule = function(rule) recorder.rules[#recorder.rules + 1] = rule end,
    get_active_window = function()
      recorder.active_window_reads = recorder.active_window_reads + 1
      return active_window
    end,
    get_active_workspace = function() return active_workspace end,
    get_last_workspace = function() return parameters.last_workspace end,
    get_windows = function() return parameters.windows or {} end,
    get_window = function(selector) return selector end,
    get_monitor = function(name) return (parameters.monitors or {})[name] end,
    get_monitor_at_cursor = function() return parameters.monitor_at_cursor end,
    notification = { create = function(note) recorder.notifications[#recorder.notifications + 1] = note.text end },
    dsp = {
      focus = function(options) return { kind = "focus", options = options } end,
      window = { move = function(options) return { kind = "move", options = options } end },
      workspace = { swap_monitors = function(options) return { kind = "swap", options = options } end },
    },
  }
  return recorder
end

local BOTTOM, TOP = "desc:BOTTOM-SERIAL", "desc:TOP-SERIAL"

local function fresh_peach(parameters)
  package.loaded.hyprpeach = nil
  local recorder = stub_hyprland(parameters)
  local peach = dofile("init.lua")
  peach.setup({
    monitors_bottom_to_top = { BOTTOM, TOP },
    focus_follows_fling = parameters.focus_follows_fling,
    notify = false,
    keys = parameters.keys,
  })
  return peach, recorder
end

print("hyprpeach")

-- --------------------------------------------------------------------------
print("\nsetup refuses what it cannot honour")
do
  stub_hyprland({})
  local peach = dofile("init.lua")

  -- Only the monitors have no sensible default: nobody else knows what is on
  -- your desk. Everything else falls back, so a first setup is one line.
  local ok, message = pcall(function() peach.setup({}) end)
  check({ label = "setup with no monitors is refused", got = ok, want = false })
  check({ label = "and says which key it wanted", got = message:find("monitors_bottom_to_top", 1, true) ~= nil, want = true })

  -- A typo in a chord name would otherwise bind nothing and report nothing.
  local typo = pcall(function()
    peach.setup({ monitors_bottom_to_top = { BOTTOM }, keys = { next_dektop = "SUPER + TAB" } })
  end)
  check({ label = "an unknown key name is refused, not ignored", got = typo, want = false })
end

-- --------------------------------------------------------------------------
print("\nworkspace rules pin every desktop to every panel")
do
  local _, recorder = fresh_peach({})
  check({ label = "2 panels x 10 desktops = 20 rules", got = #recorder.rules, want = 20 })
  check({ label = "bottom desktop 1 is workspace 1", got = recorder.rules[1].workspace, want = "1" })
  check({ label = "  ...on the bottom monitor", got = recorder.rules[1].monitor, want = BOTTOM })
  check({ label = "  ...and is the default", got = recorder.rules[1].default, want = true })
  check({ label = "bottom desktop 2 is NOT default", got = recorder.rules[2].default, want = false })
  check({ label = "top desktop 1 is workspace 11", got = recorder.rules[11].workspace, want = "11" })
  check({ label = "  ...on the top monitor", got = recorder.rules[11].monitor, want = TOP })
  check({ label = "top desktop 10 is workspace 20", got = recorder.rules[20].workspace, want = "20" })
  -- Without this an emptied workspace is destroyed and forgets its monitor.
  check({ label = "every rule is persistent", got = recorder.rules[7].persistent, want = true })
end

-- --------------------------------------------------------------------------
print("\nthe band is as wide as the desktop count, because it holds one each")
do
  -- There used to be a separate stride, which could be set smaller than the
  -- count and would then silently overlap two monitors' bands. A band holds
  -- exactly one workspace per desktop, so the two were always the same number
  -- and one of them could only ever be wrong.
  package.loaded.hyprpeach = nil
  local recorder = stub_hyprland({})
  local peach = dofile("init.lua")
  peach.setup({ monitors_bottom_to_top = { BOTTOM, TOP }, desktop_count = 4, notify = false })
  check({ label = "4 desktops on 2 panels = 8 rules", got = #recorder.rules, want = 8 })
  check({ label = "bottom band is 1-4", got = recorder.rules[4].workspace, want = "4" })
  check({ label = "top band starts right after, at 5", got = recorder.rules[5].workspace, want = "5" })
  check({ label = "  ...on the top monitor", got = recorder.rules[5].monitor, want = TOP })
  check({ label = "top band ends at 8", got = recorder.rules[8].workspace, want = "8" })
end

-- --------------------------------------------------------------------------
print("\nthe number row is unbound BY KEYCODE")
do
  local _, recorder = fresh_peach({})
  local unbound = table.concat(recorder.unbound, " ")
  -- An unbind naming "SUPER + 1" matches nothing, leaves the default in place,
  -- and then BOTH bindings fire on one press.
  check({ label = "desktop 1 unbinds code:10", got = unbound:find("SUPER + code:10", 1, true) ~= nil, want = true })
  -- Ten keys cleared even with eight desktops, or SUPER+9 stays bound to a
  -- flat workspace and splits the desk.
  check({ label = "the 9 and 0 keys are cleared too", got = unbound:find("SUPER + code:19", 1, true) ~= nil, want = true })
  check({ label = "no unbind names a bare digit", got = unbound:find("SUPER %+ %d") == nil, want = true })
  check({ label = "the monitor-hopping TAB is unbound", got = unbound:find("SUPER + TAB", 1, true) ~= nil, want = true })
  check({ label = "desktop 1 is bound", got = recorder.bound["SUPER + code:10"], want = "Focus desktop 1" })
end

-- --------------------------------------------------------------------------
print("\nSUPER moves you, SUPER+SHIFT moves the window")
do
  local _, recorder = fresh_peach({})

  -- The whole of what there is to learn, asserted.
  check({ label = "SUPER+1 goes to a desktop", got = recorder.bound["SUPER + code:10"], want = "Focus desktop 1" })
  check({ label = "SUPER+left goes to the one beside it", got = recorder.bound["SUPER + LEFT"], want = "Previous desktop" })
  check({ label = "SUPER+right too", got = recorder.bound["SUPER + RIGHT"], want = "Next desktop" })

  check({ label = "SUPER+SHIFT+1 flings a window there", got = recorder.bound["SUPER + SHIFT + code:10"], want = "Send window to desktop 1" })
  check({ label = "and the tenth desktop is on code:19", got = recorder.bound["SUPER + code:19"], want = "Focus desktop 10" })
  check({ label = "SUPER+SHIFT+left flings it one along", got = recorder.bound["SUPER + SHIFT + LEFT"], want = "Send window to the previous desktop" })
  check({ label = "SUPER+SHIFT+right too", got = recorder.bound["SUPER + SHIFT + RIGHT"], want = "Send window to the next desktop" })

  -- Up and down mean PANELS, because the panels are stacked.
  check({ label = "SUPER+SHIFT+up flings it a panel up", got = recorder.bound["SUPER + SHIFT + UP"], want = "Send window to the panel above" })
  check({ label = "SUPER+SHIFT+down, a panel down", got = recorder.bound["SUPER + SHIFT + DOWN"], want = "Send window to the panel below" })

  -- Directional window focus survives on the axis the panels are stacked on.
  check({ label = "SUPER+up is left to the compositor", got = recorder.bound["SUPER + UP"], want = nil })
  check({ label = "SUPER+down as well", got = recorder.bound["SUPER + DOWN"], want = nil })
  check({
    label = "  ...and neither is unbound",
    got = table.concat(recorder.unbound, " "):find("SUPER + UP", 1, true) == nil,
    want = true,
  })
end

-- --------------------------------------------------------------------------
print("\na window flung sideways lands on the next desktop, same panel")
do
  -- Top panel, desktop 5 (workspace 15). One step along is desktop 6, and the
  -- window must stay on the top panel: workspace 16, not 6.
  local peach, recorder = fresh_peach({ active_window = { workspace = { id = 15 } } })
  peach.send_active_window_to_relative_desktop({ step = 1, follow = false })
  check({ label = "top desktop 5 -> top desktop 6 (16)", got = recorder.dispatched[1].options.workspace, want = "16" })

  -- And it wraps, from the window's own desktop.
  local wrap, wrap_recorder = fresh_peach({ active_window = { workspace = { id = 10 } } })
  wrap.send_active_window_to_relative_desktop({ step = 1, follow = false })
  check({ label = "bottom desktop 10 wraps to desktop 1", got = wrap_recorder.dispatched[1].options.workspace, want = "1" })
end

-- --------------------------------------------------------------------------
print("\na chord set to false is skipped, but the stock one still goes")
do
  local _, recorder = fresh_peach({})
  -- Off by default: worth having, not worth a key.
  check({ label = "swap_panels is not bound by default", got = recorder.bound["SUPER + CTRL + S"], want = nil })
  check({ label = "gather is not bound by default", got = recorder.bound["SUPER + CTRL + G"], want = nil })

  -- Declining a shortcut must not mean inheriting the stock binding's bug: the
  -- conflicting default is removed whether or not hyprpeach takes the chord.
  local peach = package.loaded.hyprpeach
  local _ = peach
  local trimmed, trimmed_recorder = fresh_peach({ keys = { previous_desktop_arrow = false } })
  local __ = trimmed
  check({ label = "a false chord binds nothing", got = trimmed_recorder.bound["SUPER + LEFT"], want = nil })
  check({
    label = "  ...and stock SUPER+TAB is cleared regardless",
    got = table.concat(trimmed_recorder.unbound, " "):find("SUPER + TAB", 1, true) ~= nil,
    want = true,
  })
end

-- --------------------------------------------------------------------------
print("\nfocus_desktop moves every panel, bottom LAST")
do
  local peach, recorder = fresh_peach({})
  peach.focus_desktop({ desktop = 3 })
  check({ label = "one dispatch per panel", got = #recorder.dispatched, want = 2 })
  -- Focus follows whichever half switched last, and eye level is the bottom
  -- panel. Reverse these two lines and your focus lands on the wrong screen
  -- every single time.
  check({ label = "top panel (13) switches first", got = recorder.dispatched[1].options.workspace, want = "13" })
  check({ label = "bottom panel (3) switches last", got = recorder.dispatched[2].options.workspace, want = "3" })
end

-- --------------------------------------------------------------------------
print("\nsending a window keeps it on its own panel")
do
  -- A window on the TOP panel: workspace 15 is top's desktop 5.
  local peach, recorder = fresh_peach({ active_window = { workspace = { id = 15 } } })
  peach.send_active_window_to_desktop({ desktop = 2, follow = false })
  check({ label = "a top-panel window goes to top's desktop 2 (12)", got = recorder.dispatched[1].options.workspace, want = "12" })
  -- The move dispatcher's own follow switches the window's monitor and only
  -- that one, which is the split the whole library exists to prevent.
  check({ label = "the move itself never follows", got = recorder.dispatched[1].options.follow, want = false })
  check({ label = "follow=false dispatches nothing else", got = #recorder.dispatched, want = 1 })

  local bottom_peach, bottom_recorder = fresh_peach({ active_window = { workspace = { id = 5 } } })
  bottom_peach.send_active_window_to_desktop({ desktop = 2, follow = false })
  check({ label = "a bottom-panel window goes to bottom's desktop 2", got = bottom_recorder.dispatched[1].options.workspace, want = "2" })
end

-- --------------------------------------------------------------------------
print("\nfocus_follows_fling decides whether your eyes follow")
do
  -- Named after `focus follows mouse`: the pointer of attention ends up where
  -- the thing you just acted on is.
  local peach, recorder = fresh_peach({ active_window = { workspace = { id = 5 } } })
  peach.send_active_window_to_desktop({ desktop = 7, follow = false })
  check({ label = "not following is one dispatch: the move", got = #recorder.dispatched, want = 1 })

  local following, follow_recorder = fresh_peach({ active_window = { workspace = { id = 5 } } })
  following.send_active_window_to_desktop({ desktop = 7, follow = true })
  -- move, then both panels, then re-focus the window it just sent.
  check({ label = "following = move + 2 panels + refocus", got = #follow_recorder.dispatched, want = 4 })
  check({ label = "  ...and ends on the window", got = follow_recorder.dispatched[4].options.window ~= nil, want = true })
end

-- --------------------------------------------------------------------------
print("\nthe send bindings read the config field, not a mode")
do
  -- Default off: the plain send does not follow, and the ALT variant does.
  local _, recorder = fresh_peach({ active_window = { workspace = { id = 5 } } })
  check({ label = "plain send is bound", got = recorder.bound["SUPER + SHIFT + code:12"], want = "Send window to desktop 3" })
  -- Off by default now: the rule covers the day without it.
  check({ label = "the follow escape hatch is off by default", got = recorder.bound["SUPER + SHIFT + ALT + code:12"], want = nil })
  -- ...but the stock binding on that chord is still cleared, or it would go on
  -- moving windows to flat workspaces behind your back.
  check({
    label = "  ...and stock SUPER+SHIFT+ALT+3 is cleared anyway",
    got = table.concat(recorder.unbound, " "):find("SUPER + SHIFT + ALT + code:12", 1, true) ~= nil,
    want = true,
  })

  -- Press the key for real. This is the whole point of the change: out of the
  -- box, sending a window must NOT drag your view along with it.
  recorder.actions["SUPER + SHIFT + code:12"]()
  -- BY DEFAULT the view goes with the window: move, both panels, refocus.
  check({ label = "BY DEFAULT a fling takes the view along", got = #recorder.dispatched, want = 4 })
  check({ label = "  ...starting with the move", got = recorder.dispatched[1].kind, want = "move" })
  check({ label = "  ...to bottom desktop 3", got = recorder.dispatched[1].options.workspace, want = "3" })
  check({ label = "  ...and ending on the window", got = recorder.dispatched[4].options.window ~= nil, want = true })

  -- Opting out makes a fling pure tidying.
  local opted, opted_recorder = fresh_peach({ active_window = { workspace = { id = 5 } }, focus_follows_fling = false })
  local _ = opted
  opted_recorder.actions["SUPER + SHIFT + code:12"]()
  check({ label = "focus_follows_fling = false leaves you put", got = #opted_recorder.dispatched, want = 1 })
end

-- --------------------------------------------------------------------------
print("\nthrowing a window at the other panel keeps its desktop")
do
  -- Bottom panel, desktop 5 (workspace 5) -> top panel, still desktop 5 (15).
  local peach, recorder = fresh_peach({ active_window = { workspace = { id = 5 } } })
  peach.send_active_window_to_panel({ step = 1, follow = false })
  check({ label = "bottom desktop 5 -> top desktop 5 (15)", got = recorder.dispatched[1].options.workspace, want = "15" })

  -- There is no panel above the top one, and wrapping to the bottom would be a
  -- surprise, so this does nothing rather than something clever.
  local top_peach, top_recorder = fresh_peach({ active_window = { workspace = { id = 15 } } })
  top_peach.send_active_window_to_panel({ step = 1, follow = false })
  check({ label = "off the top of the stack does nothing", got = #top_recorder.dispatched, want = 0 })
end

-- --------------------------------------------------------------------------
print("\ndesktops wrap, special workspaces are left alone")
do
  local peach, recorder = fresh_peach({ active_workspace = { id = 1 } })
  peach.step_desktop({ step = -1 })
  -- Lua's % is non-negative for a positive divisor, so this needs no special case.
  check({ label = "stepping back off desktop 1 wraps to 10", got = recorder.dispatched[2].options.workspace, want = "10" })

  local wrap_peach, wrap_recorder = fresh_peach({ active_workspace = { id = 10 } })
  wrap_peach.step_desktop({ step = 1 })
  check({ label = "stepping past desktop 10 wraps to 1", got = wrap_recorder.dispatched[2].options.workspace, want = "1" })

  -- A scratchpad has no desktop to bring the other panels to.
  local special_peach, special_recorder = fresh_peach({ active_workspace = { id = -99 } })
  special_peach.step_desktop({ step = 1 })
  check({ label = "a special workspace dispatches nothing", got = #special_recorder.dispatched, want = 0 })
  check({ label = "and has no desktop", got = special_peach.current_desktop(), want = nil })
end

-- --------------------------------------------------------------------------
print("\na pinned window is realigned onto the panel it is actually on")
do
  -- Hyprland re-records a pinned window's workspace as whatever the FOCUSED
  -- monitor is showing every time the window takes focus, which on a
  -- multi-panel desk is routinely another panel's workspace. It writes the
  -- field and nothing else, so the window stays where it is and the mismatch
  -- is invisible -- until the next switch of THAT panel carries the window
  -- physically onto it. See `realign_pinned_windows` in init.lua.
  local bottom_monitor = { id = 1, active_workspace = { id = 3 } }
  local top_monitor    = { id = 0, active_workspace = { id = 13 } }

  -- Pinned, sitting on the bottom panel, but recorded on the top panel's
  -- desktop 3. One more switch and the top panel takes it away.
  local stranded_pinned = { pinned = true, monitor = bottom_monitor, workspace = { id = 13 } }
  local settled_pinned  = { pinned = true, monitor = top_monitor, workspace = { id = 13 } }
  local ordinary_window = { pinned = false, monitor = top_monitor, workspace = { id = 3 } }

  local peach, recorder = fresh_peach({
    windows = { stranded_pinned, settled_pinned, ordinary_window },
    active_workspace = { id = 3 },
  })
  peach.focus_desktop({ desktop = 3 })

  local moves = {}
  for _, descriptor in ipairs(recorder.dispatched) do
    if descriptor.kind == "move" then moves[#moves + 1] = descriptor end
  end
  -- Once. The repair after the loop finds nothing left to correct, which is
  -- the property that lets it be called from every entry point without
  -- thinking about whether another one already ran.
  check({ label = "the misrecorded pinned window is moved once", got = #moves, want = 1 })
  check({ label = "  ...onto the workspace ITS OWN monitor shows", got = moves[1].options.workspace, want = "3" })
  check({ label = "  ...and it is the misrecorded one", got = moves[1].options.window, want = stranded_pinned })
  -- follow = false: this corrects a record, it is not a move anyone asked for.
  check({ label = "  ...silently", got = moves[1].options.follow, want = false })
  -- The pinned window already on the panel it is recorded on is not touched;
  -- neither is the unpinned one, which Hyprland never misrecords.
  check({ label = "the settled pinned window stays put", got = settled_pinned.workspace.id, want = 13 })
  check({ label = "the unpinned window stays put", got = ordinary_window.workspace.id, want = 3 })

  -- ORDER IS THE WHOLE FIX. The repair has to land BEFORE a panel dispatches,
  -- because it is that dispatch which drags a misrecorded pinned window onto
  -- the wrong monitor. Repairing only afterwards would tidy the record up one
  -- switch too late, every time.
  check({ label = "the repair runs BEFORE the first panel dispatch", got = recorder.dispatched[1].kind, want = "move" })
  check({ label = "  ...then the top panel", got = recorder.dispatched[2].options.workspace, want = "13" })
  check({ label = "  ...then the bottom panel, which keeps the focus", got = recorder.dispatched[3].options.workspace, want = "3" })
  check({ label = "and nothing else is dispatched", got = #recorder.dispatched, want = 3 })

  -- The repair is taken before EVERY dispatch, not once before the loop: the
  -- misrecording is written by a focus change, and one can arrive from the
  -- compositor's own pointer handling between one panel's dispatch and the
  -- next. A window that goes stale mid-loop must still be caught.
  local went_stale = { pinned = true, monitor = bottom_monitor, workspace = { id = 3 } }
  local peach_two, second = fresh_peach({ windows = { went_stale }, active_workspace = { id = 3 } })
  local recording_dispatch = _G.hl.dispatch
  _G.hl.dispatch = function(descriptor)
    -- Misrecord it the moment the TOP panel has switched, the way a stray focus
    -- from the compositor's pointer handling would.
    if #second.dispatched == 0 then went_stale.workspace = { id = 13 } end
    recording_dispatch(descriptor)
  end
  peach_two.focus_desktop({ desktop = 3 })

  -- It has to be corrected BEFORE the bottom panel dispatches. Correcting it
  -- afterwards tidies the record but the panel has already taken the window.
  check({ label = "top panel switches first", got = second.dispatched[1].options.workspace, want = "13" })
  check({ label = "a window misrecorded mid-loop is caught BEFORE the next panel", got = second.dispatched[2].kind, want = "move" })
  check({ label = "  ...back onto the workspace its own monitor shows", got = second.dispatched[2].options.workspace, want = "3" })
  check({ label = "  ...and only then does the bottom panel switch", got = second.dispatched[3].options.workspace, want = "3" })
end

-- --------------------------------------------------------------------------
print("\nwindows already where they belong are left alone")
do
  local bottom_monitor = { id = 1, active_workspace = { id = 3 } }
  local top_monitor    = { id = 0, active_workspace = { id = 13 } }
  local peach, recorder = fresh_peach({
    windows = {
      { pinned = true,  monitor = bottom_monitor, workspace = { id = 3 } },
      { pinned = true,  monitor = top_monitor,    workspace = { id = 13 } },
      -- Not pinned, so Hyprland never misrecords it and it must not be swept
      -- up: an unpinned window on another panel's workspace is a window the
      -- user deliberately sent there.
      { pinned = false, monitor = bottom_monitor, workspace = { id = 13 } },
      -- A pinned window can be reported mid-teardown with neither half of the
      -- pair; nil is not a workspace to move it to.
      { pinned = true,  monitor = nil,            workspace = { id = 3 } },
      { pinned = true,  monitor = bottom_monitor, workspace = nil },
    },
    active_workspace = { id = 3 },
  })
  peach.focus_desktop({ desktop = 3 })
  check({ label = "nothing is moved", got = #recorder.dispatched, want = 2 })
  check({ label = "  ...only the two panels are switched", got = recorder.dispatched[1].kind, want = "focus" })
end

-- --------------------------------------------------------------------------
print("\nthe active window is read once, never across the pinned-window repair")
do
  -- The repair can hand focus to whatever sits under a pinned window it moves,
  -- so "the active window" is not necessarily the same window either side of
  -- it. A second read would let the window whose desktop was measured and the
  -- window actually moved come apart -- rarely, silently, and only when a
  -- pinned window happens to hold the focus.
  local monitor = { id = 1, active_workspace = { id = 3 } }
  local active = { pinned = true, monitor = monitor, workspace = { id = 13 } }
  local peach, recorder = fresh_peach({
    active_window = active,
    windows = { active },
    active_workspace = { id = 3 },
    focus_follows_fling = false,
  })

  peach.send_active_window_to_relative_desktop({ step = 1, follow = false })
  check({ label = "stepping sideways reads the active window once", got = recorder.active_window_reads, want = 1 })

  local _, direct = fresh_peach({ active_window = active, windows = { active }, active_workspace = { id = 3 } })
  peach.send_active_window_to_desktop({ desktop = 4, follow = false })
  check({ label = "and so does sending it to a numbered desktop", got = direct.active_window_reads, want = 1 })
end

-- --------------------------------------------------------------------------
print("\nstranded windows are rescued, paired windows are not touched")
do
  local windows = {
    { workspace = { id = 5 } },    -- bottom desktop 5, fine
    { workspace = { id = 15 } },   -- top desktop 5, fine
    { workspace = { id = 47 } },   -- outside every band: a monitor went away
    { workspace = { id = -3 } },   -- special: not stranded, deliberately elsewhere
  }
  local peach, recorder = fresh_peach({ windows = windows, active_workspace = { id = 2 } })
  peach.gather_rogue_windows()
  check({ label = "only the stranded window is moved", got = #recorder.dispatched, want = 1 })
  check({ label = "onto the desktop in front of you", got = recorder.dispatched[1].options.workspace, want = "2" })
end

-- --------------------------------------------------------------------------
print("\ndescribe() names a split the bars cannot show")
do
  local monitors = {
    [BOTTOM] = { active_workspace = { id = 5 } },
    [TOP] = { active_workspace = { id = 15 } },
  }
  local peach = fresh_peach({ monitors = monitors })
  check({ label = "matching desktops read as paired", got = peach.describe():find("[paired]", 1, true) ~= nil, want = true })

  monitors[TOP] = { active_workspace = { id = 17 } }
  local split_peach = fresh_peach({ monitors = monitors })
  check({ label = "a split is called out loudly", got = split_peach.describe():find("PANELS DISAGREE", 1, true) ~= nil, want = true })
end

-- --------------------------------------------------------------------------
print("\na held panel stops answering, and the rest of the desk carries on")
do
  -- Holding is the one thing here that makes the panels disagree on PURPOSE,
  -- so it has to be exactly as surgical as it claims: the held band is not
  -- dispatched to, and every other band still is.
  local bottom = { id = 1, name = "BOTTOM", active_workspace = { id = 3 } }
  local top    = { id = 0, name = "TOP", active_workspace = { id = 13 } }
  local monitors = { [BOTTOM] = bottom, [TOP] = top }

  local peach, recorder = fresh_peach({ monitors = monitors, monitor_at_cursor = top, active_workspace = { id = 3 } })
  peach.focus_desktop({ desktop = 4 })
  check({ label = "with nothing held, both panels are dispatched", got = #recorder.dispatched, want = 2 })

  peach.toggle_held_panel()
  -- No toast: the screen it happened to flashes a padlock, and a notification
  -- on top of that is the same news twice on a different monitor.
  check({ label = "holding says nothing in the corner", got = #recorder.notifications, want = 0 })
  local baseline = #recorder.dispatched
  peach.focus_desktop({ desktop = 5 })
  local moved = {}
  for index = baseline + 1, #recorder.dispatched do
    if recorder.dispatched[index].kind == "focus" then moved[#moved + 1] = recorder.dispatched[index].options.workspace end
  end
  check({ label = "the held panel is not dispatched to", got = #moved, want = 1 })
  check({ label = "  ...and the panel that moved is the other one", got = moved[1], want = "5" })

  peach.toggle_held_panel()
  baseline = #recorder.dispatched
  peach.focus_desktop({ desktop = 6 })
  local again = 0
  for index = baseline + 1, #recorder.dispatched do
    if recorder.dispatched[index].kind == "focus" then again = again + 1 end
  end
  check({ label = "releasing puts it back in the loop", got = again, want = 2 })
end

-- --------------------------------------------------------------------------
print("\nwhat is held is published, because the bar cannot see Lua state")
do
  local bottom = { id = 1, name = "BOTTOM", active_workspace = { id = 3 } }
  local top    = { id = 0, name = "TOP", active_workspace = { id = 13 } }
  local peach, recorder = fresh_peach({
    monitors = { [BOTTOM] = bottom, [TOP] = top }, monitor_at_cursor = top, active_workspace = { id = 3 },
  })
  local path
  for written_path in pairs(recorder.written) do path = written_path end
  check({ label = "setup publishes, so a reload cannot leave a stale lock drawn", got = path ~= nil, want = true })
  check({ label = "  ...and publishes nothing held", got = recorder.written[path], want = "" })

  peach.toggle_held_panel()
  -- Name AND desktop: the bar knows its screen by name, and the desktop cannot
  -- be read back out of Quickshell for a monitor that is not focused.
  check({ label = "holding publishes the monitor name and the desktop it holds", got = recorder.written[path], want = "TOP 3\n" })

  peach.toggle_held_panel()
  check({ label = "releasing publishes empty again", got = recorder.written[path], want = "" })
end

-- --------------------------------------------------------------------------
print("\nholding is reported, not mistaken for a split")
do
  local bottom = { id = 1, name = "BOTTOM", active_workspace = { id = 3 } }
  local top    = { id = 0, name = "TOP", active_workspace = { id = 17 } }
  local monitors = { [BOTTOM] = bottom, [TOP] = top }
  local peach = fresh_peach({ monitors = monitors, monitor_at_cursor = top, active_workspace = { id = 3 } })

  check({ label = "an unexplained split is still called out", got = peach.describe():find("PANELS DISAGREE", 1, true) ~= nil, want = true })
  peach.toggle_held_panel()
  local held = peach.describe()
  check({ label = "a held panel is not a disagreement", got = held:find("PANELS DISAGREE", 1, true) == nil, want = true })
  check({ label = "  ...it is named as held", got = held:find("(held)", 1, true) ~= nil, want = true })
  check({ label = "  ...and counted", got = held:find("1 held", 1, true) ~= nil, want = true })
end

-- --------------------------------------------------------------------------
print("\nstepping ignores the panel that is not going to move")
do
  -- Standing on a held panel showing desktop 3 while the desk is on 5, "next
  -- desktop" means 6, not 4.
  local bottom = { id = 1, name = "BOTTOM", active_workspace = { id = 5 } }
  local top    = { id = 0, name = "TOP", active_workspace = { id = 13 } }
  local monitors = { [BOTTOM] = bottom, [TOP] = top }
  local peach, recorder = fresh_peach({ monitors = monitors, monitor_at_cursor = top, active_workspace = { id = 13 } })
  peach.toggle_held_panel()
  local baseline = #recorder.dispatched
  peach.step_desktop({ step = 1 })
  local target
  for index = baseline + 1, #recorder.dispatched do
    if recorder.dispatched[index].kind == "focus" then target = recorder.dispatched[index].options.workspace end
  end
  check({ label = "stepping reads the desk, not the held panel", got = target, want = "6" })
end

-- --------------------------------------------------------------------------
print("\nthe README documents exactly the chords the code defines")
do
  local function names_in(path, from, to)
    local file = assert(io.open(path, "r"))
    local contents = file:read("*a")
    file:close()
    local section = contents:match(from .. "(.-)" .. to) or ""
    local found = {}
    for name in section:gmatch("([%a_]+)%s+=%s+[\"f]") do found[name] = true end
    return found
  end

  -- A README that drifts from the defaults is worse than no README: every
  -- name in it is something a reader will paste into their own config.
  local code = names_in("init.lua", "  keys = {", "  },")
  local docs = names_in("README.md", "  keys = {", "  },")
  local missing, extra = {}, {}
  for name in pairs(code) do if not docs[name] then missing[#missing + 1] = name end end
  for name in pairs(docs) do if not code[name] then extra[#extra + 1] = name end end
  table.sort(missing)
  table.sort(extra)
  check({ label = "no chord is undocumented", got = table.concat(missing, ","), want = "" })
  check({ label = "no documented chord is invented", got = table.concat(extra, ","), want = "" })
end

print(string.format("\n%s  %d checks, %d failed", failures == 0 and "PASS" or "FAIL", checks, failures))
os.exit(failures == 0 and 0 or 1)
