//! Where every monitor sees the scene from.
//!
//! A scene is composed around ONE monitor, the home monitor: the one holding
//! the first band, workspaces 1-9, which the library keeps at eye level (the
//! bottom of two stacked panels, the laptop between two larger screens, the
//! laptop alone). The scene's subject -- a sun on a horizon, a nebula's
//! pillars -- sits on it, and every other monitor sees what is around it: the
//! sky above, the horizon running on to either side. On any layout the
//! picture's centre is where you look, and nothing important falls on a bezel.
//!
//! The monitors come from `hyprctl -j monitors`, in its own shape, so the
//! preview's layout files are that command's output and nothing else.

use serde::Deserialize;

/// One monitor, as `hyprctl -j monitors` reports it.
#[derive(Clone, Debug, Deserialize)]
pub struct Monitor {
    pub name: String,
    /// Top-left on the desk, in logical pixels.
    pub x: f32,
    pub y: f32,
    /// In device pixels: logical size times scale, before any rotation.
    pub width: f32,
    pub height: f32,
    pub scale: f32,
    /// wl_output transform; odd values are a quarter turn, so width and height swap.
    pub transform: u32,
    #[serde(rename = "activeWorkspace")]
    pub active_workspace: Workspace,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Workspace {
    pub id: i32,
}

/// The library's bands are ten workspaces wide; init.lua says why.
const BAND_WIDTH: i32 = 10;

/// A rectangle in logical pixels: left, top, width, height.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rectangle {
    pub left: f32,
    pub top: f32,
    pub width: f32,
    pub height: f32,
}

impl Monitor {
    /// Where Hyprland places windows on it: device pixels over scale, turned
    /// for a rotated panel.
    pub fn logical(&self) -> Rectangle {
        let scale = if self.scale > 0.0 { self.scale } else { 1.0 };
        let turned = self.transform % 2 == 1;
        let (width, height) = if turned { (self.height, self.width) } else { (self.width, self.height) };
        Rectangle { left: self.x, top: self.y, width: width / scale, height: height / scale }
    }

    /// Which band it shows: 0 for workspaces 1-10. A special workspace (id
    /// 0 or less) says nothing about the band, so it sorts last.
    fn band(&self) -> i32 {
        if self.active_workspace.id > 0 { (self.active_workspace.id - 1).div_euclid(BAND_WIDTH) } else { i32::MAX }
    }
}

/// The home monitor: the lowest band, the first listed on a tie.
pub fn home(monitors: &[Monitor]) -> Option<&Monitor> {
    monitors.iter().min_by_key(|monitor| monitor.band())
}

/// The desktop the home monitor is on, 1-9.
pub fn current_desktop(monitors: &[Monitor]) -> i32 {
    let Some(home) = home(monitors) else { return 1 };
    let within = (home.active_workspace.id - 1).rem_euclid(BAND_WIDTH) + 1;
    if within > 9 { 1 } else { within }
}

/// Every monitor in SCENE UNITS: the origin at the home monitor's centre, y
/// up, one unit its height. Measured from the home monitor and not the desk,
/// a scene's subject is the same size on the laptop between two large screens
/// as on the laptop alone, and the screens either side see further out.
///
/// Returns each monitor's name with its rectangle as [left, top, width,
/// height], top being the larger y; and the home monitor's own, the stage.
pub fn placements(monitors: &[Monitor]) -> Option<(Vec<(String, [f32; 4])>, [f32; 4])> {
    let home = home(monitors)?.logical();
    let unit = home.height;
    let centre = (home.left + home.width * 0.5, home.top + home.height * 0.5);
    let place = |rectangle: Rectangle| {
        [(rectangle.left - centre.0) / unit, (centre.1 - rectangle.top) / unit, rectangle.width / unit, rectangle.height / unit]
    };
    let panes = monitors.iter().map(|monitor| (monitor.name.clone(), place(monitor.logical()))).collect();
    Some((panes, place(home)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn monitor(name: &str, x: f32, y: f32, width: f32, height: f32, workspace: i32) -> Monitor {
        Monitor { name: name.into(), x, y, width, height, scale: 1.0, transform: 0, active_workspace: Workspace { id: workspace } }
    }

    fn pane<'a>(placed: &'a (Vec<(String, [f32; 4])>, [f32; 4]), name: &str) -> [f32; 4] {
        placed.0.iter().find(|(n, _)| n == name).unwrap().1
    }

    /// Two 7680 x 2160 panels stacked, the bottom one at eye level.
    fn stacked() -> Vec<Monitor> {
        vec![monitor("DP-3", 0.0, -2160.0, 7680.0, 2160.0, 13), monitor("DP-5", 0.0, 0.0, 7680.0, 2160.0, 3)]
    }

    /// A laptop centred under the middle of two 4K screens either side of it.
    fn laptop_between() -> Vec<Monitor> {
        vec![
            monitor("DP-2", 0.0, 0.0, 3840.0, 2160.0, 12),
            monitor("eDP-1", 3840.0, 480.0, 1920.0, 1200.0, 2),
            monitor("DP-1", 5760.0, 0.0, 3840.0, 2160.0, 22),
        ]
    }

    #[test]
    fn the_bottom_of_two_stacked_panels_is_home() {
        let placed = placements(&stacked()).unwrap();
        assert_eq!(placed.1, [-16.0 / 9.0, 0.5, 32.0 / 9.0, 1.0]);
        assert_eq!(pane(&placed, "DP-3"), [-16.0 / 9.0, 1.5, 32.0 / 9.0, 1.0], "the top panel sees the sky above it");
        assert_eq!(current_desktop(&stacked()), 3);
    }

    #[test]
    fn the_laptop_between_two_screens_is_home_and_the_same_size_as_alone() {
        let placed = placements(&laptop_between()).unwrap();
        assert_eq!(placed.1, [-0.8, 0.5, 1.6, 1.0]);
        assert_eq!(pane(&placed, "DP-2"), [-4.0, 0.9, 3.2, 1.8], "the left screen runs on from the laptop's left edge");
        assert_eq!(pane(&placed, "DP-1"), [0.8, 0.9, 3.2, 1.8]);
        assert_eq!(current_desktop(&laptop_between()), 2);
    }

    #[test]
    fn a_laptop_alone_is_the_whole_stage() {
        let alone = vec![monitor("eDP-1", 0.0, 0.0, 1920.0, 1200.0, 5)];
        assert_eq!(placements(&alone).unwrap().1, [-0.8, 0.5, 1.6, 1.0]);
    }

    #[test]
    fn a_held_panel_or_a_special_workspace_does_not_move_home() {
        let mut desk = stacked();
        desk[1].active_workspace.id = -98;
        assert_eq!(home(&desk).unwrap().name, "DP-3", "a special workspace says nothing about the band");
        let mut desk = laptop_between();
        desk[0].active_workspace.id = 19;
        assert_eq!(home(&desk).unwrap().name, "eDP-1");
    }

    #[test]
    fn a_scaled_or_turned_panel_is_measured_as_windows_are_placed() {
        let mut turned = monitor("HDMI-A-1", 0.0, 0.0, 2560.0, 1440.0, 1);
        turned.transform = 1;
        turned.scale = 2.0;
        assert_eq!(turned.logical(), Rectangle { left: 0.0, top: 0.0, width: 720.0, height: 1280.0 });
    }
}
