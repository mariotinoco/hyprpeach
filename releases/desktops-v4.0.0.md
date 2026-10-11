# a flung window leaves, and you stay where you are

`focus_follows_fling` now defaults to `false`. `SUPER + SHIFT` with a number, `←` `→` or `↑` `↓` moves the window and leaves your view on the desktop and panel you were on.

Set `focus_follows_fling = true` in `setup()` to have your view go with the window, as it did before. `send_window_and_follow_modifier` is still there for a second chord that always follows, whichever way the option is set.
