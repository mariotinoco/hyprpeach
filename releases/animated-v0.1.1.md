# Omarchy's wallpaper is turned off under the scene

Adding animated now turns off Omarchy's own wallpaper. The scene covers every monitor, so the wallpaper underneath was never seen, but it still used video memory: about 740 MiB on two 7680 × 2160 panels. Removing animated turns the wallpaper back on.

If you already have animated, add it again to turn the wallpaper off:

    hyprpeach plugin add animated

**Fixed:** the scene is always drawn in front of the wallpaper. Before, a monitor could show the plain wallpaper if the two started at the same moment.
