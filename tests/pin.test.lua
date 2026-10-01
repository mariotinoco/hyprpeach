--- Runs plugins/pin/pin.lua against a stubbed `hl`: which keys it takes, what
--- SUPER + P does to a window -- tiled as much as floating -- and where a
--- pinned window goes when its monitor turns. A window that fails to follow, or
--- follows onto the wrong panel, looks exactly like one nobody pinned.
--
-- Run: lua tests/pin.test.lua

local failures, checks = 0, 0

local function check(parameters)
  checks = checks + 1
  if parameters.got ~= parameters.want then
    failures = failures + 1
    print(string.format("  FAIL %s\n       want: %s\n       got:  %s", parameters.label, tostring(parameters.want), tostring(parameters.got)))
  end
end

--- A stub compositor with one active window (or none),--- A stub compositor: windows with tags, monitors and workspaces, recording
--- what the plugin binds, unbinds and dispatches, and keeping the handler it
--- registers for `workspace.active` so a monitor turning can be played to it.
local BOTTOM, TOP = { id = 1 }, { id = 2 }

local function load_pin(parameters)
  local recorder = { bound = {}, unbound = {}, dispatched = {}, notifications = {}, handlers = {}, rules = {} }
  _G.hl = {
    get_active_window = function() return parameters.active end,
    get_windows = function() return parameters.windows or {} end,
    bind = function(chord, action, options) recorder.bound[chord] = { action = action, description = options.description } end,
    unbind = function(chord) recorder.unbound[#recorder.unbound + 1] = chord end,
    on = function(event, handler) recorder.handlers[event] = handler end,
    window_rule = function(rule) recorder.rules[#recorder.rules + 1] = rule end,
    dispatch = function(descriptor) recorder.dispatched[#recorder.dispatched + 1] = descriptor end,
    dsp = { window = {
      tag = function(arguments) return { kind = "tag", window = arguments.window, tag = arguments.tag } end,
      move = function(arguments) return { kind = "move", window = arguments.window, workspace = arguments.workspace, follow = arguments.follow } end,
    } },
    notification = { create = function(note) recorder.notifications[#recorder.notifications + 1] = note.text end },
  }
  dofile("plugins/pin/pin.lua")
  return recorder
end

local function window(parameters)
  return { address = parameters.address, floating = parameters.floating, tags = parameters.tags or {}, monitor = parameters.monitor, workspace = { id = parameters.workspace } }
end

print("hyprpeach pin")

print("\nthe keys")
do
  local recorder = load_pin({ active = nil })
  check({ label = "SUPER + P is the pin", got = recorder.bound["SUPER + P"] ~= nil, want = true })
  check({ label = "  ...described for Omarchy's key list", got = recorder.bound["SUPER + P"].description:find("follows you", 1, true) ~= nil, want = true })
  check({ label = "Omarchy's SUPER + O is let go", got = table.concat(recorder.unbound, ","):find("SUPER + O", 1, true) ~= nil, want = true })
  check({ label = "SUPER + P's pseudo window is unbound before it is taken", got = table.concat(recorder.unbound, ","):find("SUPER + P", 1, true) ~= nil, want = true })
  check({ label = "nothing else is bound", got = (function() local count = 0; for _ in pairs(recorder.bound) do count = count + 1 end; return count end)(), want = 1 })
  recorder.bound["SUPER + P"].action()
  check({ label = "with no window, SUPER + P does nothing", got = #recorder.dispatched + #recorder.notifications, want = 0 })
end

print("\na pinned window looks pinned")
do
  local recorder = load_pin({ active = nil })
  local rule = recorder.rules[1] or { match = {} }
  check({ label = "one rule, on the pin's own tag", got = #recorder.rules == 1 and rule.match.tag, want = "hyprpeach-pinned" })
  check({ label = "  ...giving it a border of its own", got = type(rule.border_color) == "string" and rule.border_color:find("ffb38a", 1, true) ~= nil, want = true })
  local focused, unfocused = (rule.border_color or ""):match("^(.-deg)%s+(.-deg)$")
  check({ label = "  ...the same focused or not: it is pinned either way", got = focused ~= nil and focused == unfocused, want = true })
  check({ label = "  ...in colour only: the theme's width, not a heavier line", got = rule.border_size, want = nil })
end

print("\nSUPER + P")
do
  local tiled = load_pin({ active = window({ address = "0x123", floating = false }) })
  tiled.bound["SUPER + P"].action()
  check({ label = "pins a TILED window", got = tiled.dispatched[1] and tiled.dispatched[1].tag, want = "+hyprpeach-pinned" })
  check({ label = "  ...that window, by address", got = tiled.dispatched[1] and tiled.dispatched[1].window, want = "address:0x123" })
  check({ label = "  ...without a word", got = #tiled.notifications, want = 0 })

  local floating = load_pin({ active = window({ address = "0xabc", floating = true }) })
  floating.bound["SUPER + P"].action()
  check({ label = "pins a floating window the same way", got = floating.dispatched[1] and floating.dispatched[1].tag, want = "+hyprpeach-pinned" })

  local pinned = load_pin({ active = window({ address = "0xdef", floating = false, tags = { "default-opacity*", "hyprpeach-pinned" } }) })
  pinned.bound["SUPER + P"].action()
  check({ label = "unpins a pinned one", got = pinned.dispatched[1] and pinned.dispatched[1].tag, want = "-hyprpeach-pinned" })
  check({ label = "  ...and touches no other tag of its own", got = #pinned.dispatched, want = 1 })

  local popped = load_pin({ active = window({ address = "0x777", floating = false, tags = { "hyprpeach-pinned", "pop" } }) })
  popped.bound["SUPER + P"].action()
  check({ label = "a window SUPER + O once popped loses Omarchy's pop tag, and its rounded corners", got = popped.dispatched[2] and popped.dispatched[2].tag, want = "-pop" })
end

print("\na pinned window follows its monitor")
do
  local recorder = load_pin({ windows = {
    window({ address = "0x1", tags = { "hyprpeach-pinned" }, monitor = BOTTOM, workspace = 1 }),
    window({ address = "0x2", tags = {}, monitor = BOTTOM, workspace = 1 }),
    window({ address = "0x3", tags = { "hyprpeach-pinned" }, monitor = TOP, workspace = 11 }),
  } })
  check({ label = "it listens for a monitor turning", got = recorder.handlers["workspace.active"] ~= nil, want = true })
  recorder.handlers["workspace.active"]({ id = 2, monitor = BOTTOM })
  check({ label = "the bottom panel turns to 2: its pinned window goes too", got = #recorder.dispatched == 1 and recorder.dispatched[1].window, want = "address:0x1" })
  check({ label = "  ...to workspace 2", got = recorder.dispatched[1] and recorder.dispatched[1].workspace, want = "2" })
  check({ label = "  ...without taking the view with it", got = recorder.dispatched[1] and recorder.dispatched[1].follow, want = false })
  check({ label = "an unpinned window stays, and the top panel's pinned one is not pulled down", got = #recorder.dispatched, want = 1 })

  local already = load_pin({ windows = { window({ address = "0x1", tags = { "hyprpeach-pinned" }, monitor = BOTTOM, workspace = 2 }) } })
  already.handlers["workspace.active"]({ id = 2, monitor = BOTTOM })
  check({ label = "a pinned window already there is left alone", got = #already.dispatched, want = 0 })
end

if failures == 0 then
  print(string.format("\nPASS  %d checks, 0 failed", checks))
else
  print(string.format("\nFAIL  %d checks, %d failed", checks, failures))
  os.exit(1)
end
