//! hyprpeach animated-desktops: a scene drawn natively on every monitor's background
//! layer, as one picture across the desk, composed around the home monitor.
//!
//! Wayland layer-shell surfaces (one per output) + wgpu (Vulkan). renderer.rs
//! draws; layout.rs says where each monitor looks from; src/common.wgsl says
//! what a scene is. Hyprland's event socket moves the camera and picks the
//! scene.
//!
//! `hyprpeach-animated-desktops preview <monitors.json> <out.png>` draws a desk that need
//! not be this one -- the JSON is `hyprctl -j monitors` from any machine --
//! so a scene can be seen on layouts nobody here owns.

mod layout;
mod renderer;
mod settings;

use std::{
    io::{BufRead, BufReader},
    os::unix::net::UnixStream,
    path::Path,
    ptr::NonNull,
    sync::mpsc,
    time::Instant,
};

use layout::Monitor;
use raw_window_handle::{RawDisplayHandle, RawWindowHandle, WaylandDisplayHandle, WaylandWindowHandle};
use renderer::{Frame, Renderer, Targets};
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState, FrameCallbackData, Region},
    delegate_registry,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    shell::{
        wlr_layer::{Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler, LayerSurface, LayerSurfaceConfigure},
        WaylandSurface,
    },
};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_output, wl_surface},
    Connection, Proxy, QueueHandle,
};

/// Where the desk is, in desktops, and where it is going.
///
/// Desktop N is position N - 1, and every scene repeats every 9. Every move
/// goes the short way round, so N -> N+1 is always one step forward -- 3 -> 4
/// and 9 -> 1 included -- and no jump is longer than four.
struct Camera {
    position_from: f32,
    position_to: f32,
    started: Instant,
    /// How long a switch takes: the person's speed setting.
    seconds: f32,
}

const DESKTOP_COUNT: f32 = 9.0;

/// The step from `from` to the nearest position that shows the same desktop
/// as `to`: between -4.5 and 4.5.
fn shortest(from: f32, to: f32) -> f32 {
    (to - from + DESKTOP_COUNT * 1.5).rem_euclid(DESKTOP_COUNT) - DESKTOP_COUNT * 0.5
}

impl Camera {
    fn aim(&mut self, desktop: i32, now: Instant) {
        let (position, _) = self.at(now);
        self.position_from = position;
        self.position_to = position + shortest(position, (desktop - 1).rem_euclid(9) as f32);
        self.started = now;
    }

    /// Position, and how hard the camera is moving (0..1).
    fn at(&self, now: Instant) -> (f32, f32) {
        let progress = ((now - self.started).as_secs_f32() / self.seconds).clamp(0.0, 1.0);
        let eased = progress * progress * progress * (progress * (progress * 6.0 - 15.0) + 10.0);
        (self.position_from + (self.position_to - self.position_from) * eased, (progress * std::f32::consts::PI).sin())
    }
}

/// What the rest of hyprpeach, and Hyprland, announce on its event socket.
enum Announcement {
    Desktop(i32),
    Overview(bool),
    /// A monitor came or went: where everything looks from is read again.
    Monitors,
}

struct Panel {
    output: wl_output::WlOutput,
    layer: LayerSurface,
    surface: wgpu::Surface<'static>,
    format: Option<wgpu::TextureFormat>,
    targets: Option<Targets>,
}

struct App {
    registry_state: RegistryState,
    output_state: OutputState,
    compositor: CompositorState,
    layer_shell: LayerShell,
    connection: Connection,
    instance: wgpu::Instance,
    adapter: wgpu::Adapter,
    renderer: Renderer,
    panels: Vec<Panel>,
    /// `hyprctl -j monitors`, read at start and whenever a monitor comes or
    /// goes or the desk switches.
    monitors: Vec<Monitor>,
    started: Instant,
    camera: Camera,
    announcements: mpsc::Receiver<Announcement>,
    overview: bool,
    scene: String,
    settings_checked: Instant,
    settings_modified: Option<std::time::SystemTime>,
    frames: u32,
    last_report: Instant,
}

/// `hyprctl -j monitors`, or nothing if Hyprland is not answering.
fn read_monitors() -> Vec<Monitor> {
    std::process::Command::new("hyprctl")
        .args(["-j", "monitors"])
        .output()
        .ok()
        .and_then(|output| serde_json::from_slice(&output.stdout).ok())
        .unwrap_or_default()
}

/// A number from the environment, for captures: HYPRPEACH_POSITION holds the
/// desk mid-switch, HYPRPEACH_MOTION says how hard it is moving, and so on.
fn environment_number(name: &str) -> Option<f32> {
    std::env::var(name).ok().and_then(|value| value.parse().ok())
}

impl App {
    fn render(&mut self, index: usize, queue_handle: &QueueHandle<Self>) {
        while let Ok(announcement) = self.announcements.try_recv() {
            match announcement {
                Announcement::Desktop(desktop) => {
                    self.monitors = read_monitors();
                    if std::env::var("HYPRPEACH_DESKTOP").is_err() {
                        self.camera.aim(desktop, Instant::now());
                    }
                }
                Announcement::Overview(open) if open != self.overview => {
                    // ABOVE THE WINDOWS WHILE THE OVERVIEW IS OPEN. The overview
                    // leaves its cells see-through for this to show in them, and
                    // on the background layer every app window would sit between.
                    // `Top` is the bar's layer: above windows, below the overview.
                    self.overview = open;
                    for panel in &self.panels {
                        panel.layer.set_layer(if open { Layer::Top } else { Layer::Background });
                    }
                }
                Announcement::Monitors => self.monitors = read_monitors(),
                _ => {}
            }
        }
        let now = Instant::now();
        // THE SETTINGS FILE, looked at once a second: `hyprpeach scene`,
        // `hyprpeach speed` and a hand edit all land the same way, with no
        // message to send and none to miss.
        if now.duration_since(self.settings_checked).as_secs_f32() >= 1.0 {
            self.settings_checked = now;
            let modified = std::fs::metadata(settings::path()).and_then(|metadata| metadata.modified()).ok();
            if modified != self.settings_modified {
                self.settings_modified = modified;
                let settings = settings::read();
                self.camera.seconds = settings.speed.seconds();
                if std::env::var("HYPRPEACH_SCENE").is_err() && settings.scene != self.scene && self.renderer.prepare_scene(&settings.scene) {
                    self.scene = settings.scene;
                }
            }
        }
        let (position, motion) = self.camera.at(now);
        let name = self.output_state.info(&self.panels[index].output).and_then(|info| info.name).unwrap_or_default();
        let Some((panes, stage)) = layout::placements(&self.monitors) else { return };
        // A monitor Hyprland has not reported yet is drawn as the stage until it is.
        let pane = panes.iter().find(|(monitor, _)| *monitor == name).map(|(_, pane)| *pane).unwrap_or(stage);
        let frame = Frame {
            time: environment_number("HYPRPEACH_TIME").unwrap_or((now - self.started).as_secs_f32()),
            position: environment_number("HYPRPEACH_POSITION").unwrap_or(position),
            motion: environment_number("HYPRPEACH_MOTION").unwrap_or(motion),
            overview: self.overview,
            pane,
            stage,
        };

        // EVERY FRAME FRESH. This once drew ten new frames a second and showed
        // the last one again in between, to save power behind a desk of
        // windows; anything that moved on its own then stepped along like a
        // slideshow, which is all anyone saw. A scene is held to costing little
        // enough to draw at the panel's rate.
        let panel = &mut self.panels[index];
        let (Some(format), Some(targets)) = (panel.format, panel.targets.as_mut()) else { return };
        let surface_texture = match panel.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(texture) | wgpu::CurrentSurfaceTexture::Suboptimal(texture) => texture,
            other => { eprintln!("surface: {other:?}"); return; }
        };
        let view = surface_texture.texture.create_view(&Default::default());
        let mut encoder = self.renderer.device.create_command_encoder(&Default::default());
        self.renderer.draw(&mut encoder, &self.scene, targets, &frame, &view, format);
        // Ask for the next frame before presenting: the present commits.
        panel.layer.wl_surface().frame(queue_handle, FrameCallbackData(panel.layer.wl_surface().clone()));
        self.renderer.queue.submit(Some(encoder.finish()));
        self.renderer.queue.present(surface_texture);

        self.frames += 1;
        if self.last_report.elapsed().as_secs_f32() >= 2.0 {
            eprintln!("fps per panel {:.1}", self.frames as f32 / self.last_report.elapsed().as_secs_f32() / self.panels.len().max(1) as f32);
            self.frames = 0;
            self.last_report = Instant::now();
        }
    }
}

impl CompositorHandler for App {
    fn scale_factor_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: i32) {}
    fn transform_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: wl_output::Transform) {}
    fn frame(&mut self, _: &Connection, queue_handle: &QueueHandle<Self>, surface: &wl_surface::WlSurface, _: u32) {
        if let Some(index) = self.panels.iter().position(|panel| panel.layer.wl_surface() == surface) {
            self.render(index, queue_handle);
        }
    }
    fn surface_enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
    fn surface_leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
}

impl OutputHandler for App {
    fn output_state(&mut self) -> &mut OutputState { &mut self.output_state }
    fn new_output(&mut self, _: &Connection, queue_handle: &QueueHandle<Self>, output: wl_output::WlOutput) {
        let surface = self.compositor.create_surface(queue_handle);
        let layer = self.layer_shell.create_layer_surface(queue_handle, surface, Layer::Background, Some("hyprpeach-scene"), Some(&output));
        layer.set_anchor(Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT);
        layer.set_exclusive_zone(-1);
        layer.set_keyboard_interactivity(KeyboardInteractivity::None);
        layer.set_size(0, 0);
        // Never take a click: an empty input region.
        let region = Region::new(&self.compositor).expect("region");
        layer.set_input_region(Some(region.wl_region()));
        layer.commit();
        let display = RawDisplayHandle::Wayland(WaylandDisplayHandle::new(NonNull::new(self.connection.backend().display_ptr() as *mut _).unwrap()));
        let window = RawWindowHandle::Wayland(WaylandWindowHandle::new(NonNull::new(layer.wl_surface().id().as_ptr() as *mut _).unwrap()));
        let surface = unsafe {
            self.instance
                .create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle { raw_display_handle: Some(display), raw_window_handle: window })
                .expect("wgpu surface")
        };
        self.panels.push(Panel { output, layer, surface, format: None, targets: None });
        self.monitors = read_monitors();
    }
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {
        self.monitors = read_monitors();
    }
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, output: wl_output::WlOutput) {
        self.panels.retain(|panel| panel.output != output);
        self.monitors = read_monitors();
    }
}

impl LayerShellHandler for App {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, layer: &LayerSurface) {
        self.panels.retain(|panel| panel.layer.wl_surface() != layer.wl_surface());
    }
    fn configure(&mut self, _: &Connection, queue_handle: &QueueHandle<Self>, layer: &LayerSurface, configure: LayerSurfaceConfigure, _: u32) {
        let Some(index) = self.panels.iter().position(|panel| panel.layer.wl_surface() == layer.wl_surface()) else { return };
        let (width, height) = (configure.new_size.0.max(1), configure.new_size.1.max(1));
        let first = self.panels[index].targets.is_none();
        let resized = self.panels[index].targets.as_ref().map(|targets| (targets.width(), targets.height())) != Some((width, height));
        if resized {
            let capabilities = self.panels[index].surface.get_capabilities(&self.adapter);
            let format = capabilities.formats.iter().copied().find(|format| format.is_srgb()).unwrap_or(capabilities.formats[0]);
            let present_mode = if capabilities.present_modes.contains(&wgpu::PresentMode::Mailbox) { wgpu::PresentMode::Mailbox } else { wgpu::PresentMode::Fifo };
            self.panels[index].surface.configure(&self.renderer.device, &wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format,
                view_formats: vec![format],
                alpha_mode: wgpu::CompositeAlphaMode::Auto,
                width,
                height,
                desired_maximum_frame_latency: 2,
                present_mode,
                color_space: wgpu::SurfaceColorSpace::Auto,
            });
            let targets = self.renderer.build_targets(width, height);
            let panel = &mut self.panels[index];
            panel.format = Some(format);
            panel.targets = Some(targets);
            eprintln!("panel {index}: {width}x{height}, {format:?}, {present_mode:?}");
        }
        if first { self.render(index, queue_handle); }
    }
}

delegate_registry!(App);
impl ProvidesRegistryState for App {
    fn registry(&mut self) -> &mut RegistryState { &mut self.registry_state }
    registry_handlers![OutputState];
}
smithay_client_toolkit::delegate_dispatch2!(App);

/// hyprpeach's announcements, off Hyprland's event socket: the library's
/// `hyprpeach-desktop,N` after every desk switch, the overview's
/// `hyprpeach-overview,open` and `,closed`, and Hyprland's own word that a monitor came or went.
/// Listening to announcements rather than to raw workspace changes is what
/// keeps a focus move from reading as a switch -- the bug 2.1.1 fixed by the
/// same route.
fn listen_to_hyprpeach() -> mpsc::Receiver<Announcement> {
    let (sender, receiver) = mpsc::channel();
    let path = format!(
        "{}/hypr/{}/.socket2.sock",
        std::env::var("XDG_RUNTIME_DIR").unwrap_or_default(),
        std::env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_default()
    );
    std::thread::spawn(move || {
        let Ok(stream) = UnixStream::connect(&path) else { eprintln!("no Hyprland event socket at {path}"); return };
        for line in BufReader::new(stream).lines().map_while(Result::ok) {
            let announcement = if line.starts_with("monitoradded") || line.starts_with("monitorremoved") {
                Some(Announcement::Monitors)
            } else if let Some(event) = line.strip_prefix("custom>>") {
                if let Some(desktop) = event.strip_prefix("hyprpeach-desktop,") {
                    desktop.trim().parse().ok().map(Announcement::Desktop)
                } else {
                    match event.trim() {
                        "hyprpeach-overview,open" => Some(Announcement::Overview(true)),
                        "hyprpeach-overview,closed" => Some(Announcement::Overview(false)),
                        _ => None,
                    }
                }
            } else {
                None
            };
            if let Some(announcement) = announcement {
                if sender.send(announcement).is_err() { return; }
            }
        }
    });
    receiver
}

fn gpu() -> (wgpu::Instance, wgpu::Adapter, wgpu::Device, wgpu::Queue) {
    let instance = wgpu::Instance::new({ let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle(); descriptor.backends = wgpu::Backends::VULKAN; descriptor });
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        ..Default::default()
    }))
    .expect("adapter");
    eprintln!("gpu: {}", adapter.get_info().name);
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: None,
        required_limits: adapter.limits(),
        ..Default::default()
    }))
    .expect("device");
    (instance, adapter, device, queue)
}

/// HYPRPEACH_SCENE_FILE, for writing a scene: that file, read now, in place of
/// the compiled-in scene of the same name -- no rebuild to try a change.
fn scene_file() -> Option<(String, String)> {
    std::env::var("HYPRPEACH_SCENE_FILE").ok().map(|path| {
        let name = Path::new(&path).file_stem().and_then(|stem| stem.to_str()).unwrap_or("file").to_string();
        (name, std::fs::read_to_string(&path).expect("HYPRPEACH_SCENE_FILE"))
    })
}

/// The scene to start on: a file being written, then HYPRPEACH_SCENE, then the
/// settings' choice, then the default -- the first of those that compiles.
fn first_scene(renderer: &mut Renderer, scene_file: &Option<(String, String)>) -> String {
    let candidates = [
        scene_file.as_ref().map(|(name, _)| name.clone()),
        std::env::var("HYPRPEACH_SCENE").ok(),
        Some(settings::read().scene),
        Some(settings::default_scene()),
    ];
    candidates.into_iter().flatten().find(|name| renderer.prepare_scene(name)).expect("not even the default scene compiles")
}

/// The desk described by `monitors_path`, drawn into one PNG the shape of the
/// desk, each monitor where it sits, gaps between them dark. HYPRPEACH_DESKTOP,
/// HYPRPEACH_OVERVIEW, HYPRPEACH_POSITION, HYPRPEACH_MOTION and HYPRPEACH_TIME
/// say what moment; HYPRPEACH_PREVIEW_WIDTH how wide the picture is.
fn preview(monitors_path: &str, output_path: &str) {
    let monitors: Vec<Monitor> = serde_json::from_str(&std::fs::read_to_string(monitors_path).expect("monitors JSON")).expect("`hyprctl -j monitors` JSON");
    let (panes, stage) = layout::placements(&monitors).expect("at least one monitor");
    let (_, _, device, queue) = gpu();
    let file = scene_file();
    let mut renderer = Renderer::new(device, queue, 1.0, file.clone());
    let scene = first_scene(&mut renderer, &file);

    let rectangles: Vec<_> = monitors.iter().map(Monitor::logical).collect();
    let left = rectangles.iter().map(|r| r.left).fold(f32::MAX, f32::min);
    let top = rectangles.iter().map(|r| r.top).fold(f32::MAX, f32::min);
    let right = rectangles.iter().map(|r| r.left + r.width).fold(f32::MIN, f32::max);
    let bottom = rectangles.iter().map(|r| r.top + r.height).fold(f32::MIN, f32::max);
    let factor = environment_number("HYPRPEACH_PREVIEW_WIDTH").unwrap_or(1600.0) / (right - left);
    let mut canvas = image::RgbaImage::from_pixel(((right - left) * factor).ceil() as u32, ((bottom - top) * factor).ceil() as u32, image::Rgba([24, 24, 24, 255]));

    let desktop = environment_number("HYPRPEACH_DESKTOP").unwrap_or(1.0);
    let format = wgpu::TextureFormat::Rgba8UnormSrgb;
    for (rectangle, (_, pane)) in rectangles.iter().zip(&panes) {
        let (width, height) = (((rectangle.width * factor) as u32).max(1), ((rectangle.height * factor) as u32).max(1));
        let mut targets = renderer.build_targets(width, height);
        let texture = renderer.capture_texture(width, height, format);
        let view = texture.create_view(&Default::default());
        let frame = Frame {
            time: environment_number("HYPRPEACH_TIME").unwrap_or(20.0),
            position: environment_number("HYPRPEACH_POSITION").unwrap_or(desktop - 1.0),
            motion: environment_number("HYPRPEACH_MOTION").unwrap_or(0.0),
            overview: std::env::var("HYPRPEACH_OVERVIEW").is_ok(),
            pane: *pane,
            stage,
        };
        // Sixteen jittered frames of the same moment: the history the live
        // desk would have built up.
        for _ in 0..16 {
            let mut encoder = renderer.device.create_command_encoder(&Default::default());
            renderer.draw(&mut encoder, &scene, &mut targets, &frame, &view, format);
            renderer.queue.submit(Some(encoder.finish()));
        }
        let image = renderer.read_back(&texture);
        image::imageops::overlay(&mut canvas, &image, ((rectangle.left - left) * factor) as i64, ((rectangle.top - top) * factor) as i64);
    }
    canvas.save(output_path).expect("save preview");
    eprintln!("preview {output_path}: scene {scene}, {} monitors", monitors.len());
}

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.get(1).map(String::as_str) == Some("preview") {
        let (Some(monitors), Some(output)) = (arguments.get(2), arguments.get(3)) else {
            eprintln!("usage: hyprpeach-animated-desktops preview <monitors.json> <out.png>");
            std::process::exit(2);
        };
        return preview(monitors, output);
    }

    let connection = Connection::connect_to_env().expect("wayland");
    let (globals, mut event_queue) = registry_queue_init(&connection).expect("registry");
    let queue_handle = event_queue.handle();
    let compositor = CompositorState::bind(&globals, &queue_handle).expect("wl_compositor");
    let layer_shell = LayerShell::bind(&globals, &queue_handle).expect("layer shell");
    let (instance, adapter, device, queue) = gpu();
    let scale = environment_number("HYPRPEACH_SCALE").unwrap_or(0.5);
    let file = scene_file();
    let mut renderer = Renderer::new(device, queue, scale, file.clone());
    let scene = first_scene(&mut renderer, &file);

    let monitors = read_monitors();
    let now = Instant::now();
    let mut camera = Camera { position_from: 0.0, position_to: 0.0, started: now, seconds: settings::read().speed.seconds() };
    let desktop = environment_number("HYPRPEACH_DESKTOP").map(|desktop| desktop as i32).unwrap_or_else(|| layout::current_desktop(&monitors));
    camera.aim(desktop, now - std::time::Duration::from_secs(10));

    let mut app = App {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &queue_handle),
        compositor,
        layer_shell,
        connection: connection.clone(),
        instance,
        adapter,
        renderer,
        panels: Vec::new(),
        monitors,
        started: now,
        camera,
        announcements: listen_to_hyprpeach(),
        overview: std::env::var("HYPRPEACH_OVERVIEW").is_ok(),
        scene,
        settings_checked: now,
        settings_modified: std::fs::metadata(settings::path()).and_then(|metadata| metadata.modified()).ok(),
        frames: 0,
        last_report: now,
    };
    loop {
        event_queue.blocking_dispatch(&mut app).expect("dispatch");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The step from one desktop to another, in desktops.
    fn step(from: i32, to: i32) -> f32 {
        let long_ago = Instant::now() - std::time::Duration::from_secs(60);
        let mut camera = Camera { position_from: 0.0, position_to: 0.0, started: long_ago, seconds: 0.8 };
        camera.aim(from, long_ago);
        let (position, _) = camera.at(Instant::now());
        camera.aim(to, Instant::now());
        camera.position_to - position
    }

    #[test]
    fn every_next_desktop_is_one_step_forward() {
        for from in 1..=9 {
            let to = from % 9 + 1;
            assert!((step(from, to) - 1.0).abs() < 1e-4, "{from} -> {to}: {}", step(from, to));
        }
    }

    #[test]
    fn nine_to_one_is_no_different_from_one_to_two() {
        assert!((step(9, 1) - step(1, 2)).abs() < 1e-4);
        assert!((step(3, 4) - step(1, 2)).abs() < 1e-4);
    }

    #[test]
    fn no_jump_is_longer_than_four() {
        for from in 1..=9 {
            for to in 1..=9 {
                assert!(step(from, to).abs() <= 4.0 + 1e-4, "{from} -> {to}: {}", step(from, to));
            }
        }
    }

}
