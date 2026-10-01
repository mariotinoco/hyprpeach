--- hyprpeach pin: SUPER + P pins the window you are in, tiled or floating, and
--- unpins it. A pinned window FOLLOWS: whenever its monitor turns to another
--- workspace, it is moved there too, so it is on every desktop you go to.
---
--- TWO KEYS FOR TWO THINGS. Omarchy's SUPER + O does both at once -- floats
--- the window, resizes it to 1300 x 900, centres it and pins it -- and its
--- SUPER + T already floats. So SUPER + T floats, SUPER + P pins, and SUPER + O
--- is let go. SUPER + P was Omarchy's "pseudo window"; this takes the key.
---
--- NOT HYPRLAND'S OWN PIN. `pin` only takes floating windows -- a tiled one is
--- ignored without a word -- so a tag marks the window instead, and the move
--- is made here. A tag lives on the window in the compositor, not in this
--- file, so a pinned window stays pinned across a config reload, which runs
--- this file again from the top.
---
--- On its own monitor only: a window pinned on one panel stays on that panel,
--- and a held panel, which does not turn, keeps its pinned window where it is.
---
--- Loaded by the block `hyprpeach plugin add pin` writes, after Omarchy's
--- bindings and after desktops', so these are bound last and win.

local TAG = "hyprpeach-pinned"


local function has_tag(window, wanted)
  for _, tag in ipairs(window.tags or {}) do
    if tag == wanted then return true end
  end
  return false
end

local function is_pinned(window)
  return has_tag(window, TAG)
end

--- OMARCHY'S `pop` TAG GOES TOO. SUPER + O tags the window it pops out, and
--- Omarchy rounds the corners of anything so tagged; only a second SUPER + O
--- takes the tag off. With SUPER + O let go, a window popped before pin was
--- added would keep rounded corners for good -- and beside the square border
--- of everything else, a pinned one looked like a different kind of window.
local function toggle_pin()
  local window = hl.get_active_window()
  if window == nil then return end
  local address = "address:" .. window.address
  hl.dispatch(hl.dsp.window.tag({ window = address, tag = (is_pinned(window) and "-" or "+") .. TAG }))
  if has_tag(window, "pop") then
    hl.dispatch(hl.dsp.window.tag({ window = address, tag = "-pop" }))
  end
end

--- Every pinned window on the monitor that just turned goes to the workspace
--- it turned to. Silently: the view stays where the switch put it.
local function follow(workspace)
  if workspace == nil or workspace.monitor == nil then return end
  for _, window in ipairs(hl.get_windows()) do
    if is_pinned(window)
      and window.monitor ~= nil and window.monitor.id == workspace.monitor.id
      and window.workspace ~= nil and window.workspace.id ~= workspace.id then
      hl.dispatch(hl.dsp.window.move({ window = "address:" .. window.address, workspace = tostring(workspace.id), follow = false }))
    end
  end
end

--- A PINNED WINDOW LOOKS PINNED: a peach border, the way the desktop strip
--- shows a held panel by a padlock rather than a toast. The colour alone: the
--- same width and square corners as every other window, so it reads as the
--- same window, marked -- not a different kind of one. A rule on the tag, so the border comes and goes with
--- SUPER + P and needs no window found or repainted here -- Omarchy does the
--- same for its `pop` tag. Unpinned, the window is the theme's again.
---
--- THE SAME FOCUSED OR NOT. Pinned is a fact about the window, not about
--- where the mouse is: a border that dimmed when focus left would say the
--- pin had gone with it. Peach into rose, at full strength, both ways.
hl.window_rule({
  match = { tag = TAG },
  border_color = "rgb(ffb38a) rgb(ff6f91) 45deg rgb(ffb38a) rgb(ff6f91) 45deg",
})

hl.unbind("SUPER + O")
hl.unbind("SUPER + P")
hl.bind("SUPER + P", toggle_pin, { description = "Pin window (follows you across desktops)" })
hl.on("workspace.active", follow)
