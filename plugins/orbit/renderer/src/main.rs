//! hyprpeach orbit: a scene drawn natively on every monitor's background
//! layer, as one window onto one world.
//!
//! Wayland layer-shell surfaces (one per output) + wgpu (Vulkan). Per frame and
//! per monitor: the scene at an internal resolution with sub-pixel jitter,
//! temporal anti-aliasing into a history, a six-level bloom, and a filmic final
//! pass up to the panel. Hyprland's event socket moves the camera and picks
//! the scene; src/common.wgsl says what a scene is.

use std::{
    collections::HashMap,
    io::{BufRead, BufReader},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    ptr::NonNull,
    sync::mpsc,
    time::Instant,
};

use bytemuck::{Pod, Zeroable};
use raw_window_handle::{RawDisplayHandle, RawWindowHandle, WaylandDisplayHandle, WaylandWindowHandle};
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

const HDR: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
const BLOOM_LEVELS: usize = 6;

/// Every scene in src/scenes/, by name, each a complete shader with
/// src/common.wgsl in front of it (build.rs makes the list).
const SCENES: &[(&str, &str)] = include!(concat!(env!("OUT_DIR"), "/scenes.rs"));
/// Shown until someone picks another with `hyprpeach scene <name>`.
const DEFAULT_SCENE: &str = "synthwave";

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Uniforms {
    eye: [f32; 4],
    forward: [f32; 4],
    right: [f32; 4],
    up: [f32; 4],
    pane: [f32; 4],
    sun: [f32; 4],
    jitter: [f32; 4],
    extra: [f32; 4],
    view: [f32; 4],
}

struct Pipelines {
    /// Built the first time each scene is shown, so a scene that fails to
    /// compile costs only itself.
    scenes: HashMap<String, wgpu::RenderPipeline>,
    scene_pipeline_layout: wgpu::PipelineLayout,
    taa: wgpu::RenderPipeline,
    bloom_down: wgpu::RenderPipeline,
    bloom_up: wgpu::RenderPipeline,
    final_pass: Option<(wgpu::TextureFormat, wgpu::RenderPipeline)>,
    scene_layout: wgpu::BindGroupLayout,
    post_layout: wgpu::BindGroupLayout,
    post_pipeline_layout: wgpu::PipelineLayout,
    post_module: wgpu::ShaderModule,
    planet: wgpu::BindGroup,
    sampler: wgpu::Sampler,
}

struct Targets {
    uniform: wgpu::Buffer,
    scene: wgpu::TextureView,
    history: [wgpu::TextureView; 2],
    bloom: Vec<wgpu::TextureView>,
    scene_group: wgpu::BindGroup,
    taa_groups: [wgpu::BindGroup; 2],
    bloom_first: [wgpu::BindGroup; 2],
    bloom_down: Vec<wgpu::BindGroup>,
    bloom_up: Vec<wgpu::BindGroup>,
    final_groups: [wgpu::BindGroup; 2],
}

struct Panel {
    output: wl_output::WlOutput,
    layer: LayerSurface,
    surface: wgpu::Surface<'static>,
    format: Option<wgpu::TextureFormat>,
    width: u32,
    height: u32,
    targets: Option<Targets>,
    frame: u32,
}

/// Where the desk is, in desktops, and where it is going.
///
/// Desktop N is position N - 1, and every scene repeats every 9. Every move
/// goes the short way round, so N -> N+1 is always one step forward -- 3 -> 4
/// and 9 -> 1 included -- and no jump is longer than four.
struct Camera {
    position_from: f32,
    position_to: f32,
    started: Instant,
}

const DESKTOP_COUNT: f32 = 9.0;

/// The step from `from` to the nearest position that shows the same desktop
/// as `to`: between -4.5 and 4.5.
fn shortest(from: f32, to: f32) -> f32 {
    (to - from + DESKTOP_COUNT * 1.5).rem_euclid(DESKTOP_COUNT) - DESKTOP_COUNT * 0.5
}

impl Camera {
    const SECONDS: f32 = 1.6;

    fn aim(&mut self, desktop: i32, now: Instant) {
        let (position, _) = self.at(now);
        self.position_from = position;
        self.position_to = position + shortest(position, (desktop - 1).rem_euclid(9) as f32);
        self.started = now;
    }

    /// Position, and how hard the camera is moving (0..1).
    fn at(&self, now: Instant) -> (f32, f32) {
        let p = ((now - self.started).as_secs_f32() / Self::SECONDS).clamp(0.0, 1.0);
        let e = p * p * p * (p * (p * 6.0 - 15.0) + 10.0);
        (self.position_from + (self.position_to - self.position_from) * e, (p * std::f32::consts::PI).sin())
    }
}

/// What the rest of hyprpeach announces, off Hyprland's event socket.
enum Announcement {
    Desktop(i32),
    Overview(bool),
    Scene(String),
}

struct App {
    registry_state: RegistryState,
    output_state: OutputState,
    compositor: CompositorState,
    layer_shell: LayerShell,
    connection: Connection,
    instance: wgpu::Instance,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipelines: Pipelines,
    panels: Vec<Panel>,
    started: Instant,
    camera: Camera,
    announcements: mpsc::Receiver<Announcement>,
    overview: bool,
    /// The scene on the desk, and its source: compiled in, or read from
    /// HYPRPEACH_SCENE_FILE while one is being written.
    scene: String,
    scene_sources: HashMap<String, String>,
    scale: f32,
    frames: u32,
    last_report: Instant,
}

fn halton(mut index: u32, base: u32) -> f32 {
    let (mut f, mut r) = (1.0f32, 0.0f32);
    while index > 0 {
        f /= base as f32;
        r += f * (index % base) as f32;
        index /= base;
    }
    r
}

fn normalize(v: [f32; 3]) -> [f32; 3] {
    let l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    [v[0] / l, v[1] / l, v[2] / l]
}

/// A texture from disk, scaled to what the GPU allows, with a full mip chain
/// built on the CPU -- the maps are sampled from very far and very near.
fn load_texture(device: &wgpu::Device, queue: &wgpu::Queue, path: &Path, max_dimension: u32, format: wgpu::TextureFormat) -> wgpu::TextureView {
    let started = Instant::now();
    let mut reader = image::ImageReader::open(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    reader.no_limits();
    let mut image = reader.with_guessed_format().expect("format").decode().unwrap_or_else(|error| panic!("{}: {error}", path.display())).to_rgba8();
    if image.width() > max_dimension {
        let height = (image.height() as u64 * max_dimension as u64 / image.width() as u64) as u32;
        image = image::imageops::resize(&image, max_dimension, height, image::imageops::FilterType::Triangle);
    }
    let levels = 32 - image.width().max(image.height()).leading_zeros();
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some(&path.display().to_string()),
        size: wgpu::Extent3d { width: image.width(), height: image.height(), depth_or_array_layers: 1 },
        mip_level_count: levels,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    let mut level_image = image;
    for level in 0..levels {
        let (w, h) = (level_image.width(), level_image.height());
        queue.write_texture(
            wgpu::TexelCopyTextureInfo { texture: &texture, mip_level: level, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            &level_image,
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(4 * w), rows_per_image: Some(h) },
            wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        );
        if level + 1 < levels {
            level_image = image::imageops::resize(&level_image, (w / 2).max(1), (h / 2).max(1), image::imageops::FilterType::Triangle);
        }
    }
    eprintln!("loaded {} in {:.1}s", path.display(), started.elapsed().as_secs_f32());
    texture.create_view(&Default::default())
}

fn render_target(device: &wgpu::Device, width: u32, height: u32) -> wgpu::TextureView {
    device
        .create_texture(&wgpu::TextureDescriptor {
            label: None,
            size: wgpu::Extent3d { width: width.max(1), height: height.max(1), depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: HDR,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        })
        .create_view(&Default::default())
}

fn fullscreen_pipeline(
    device: &wgpu::Device,
    layout: &wgpu::PipelineLayout,
    module: &wgpu::ShaderModule,
    fragment: &str,
    format: wgpu::TextureFormat,
    blend: Option<wgpu::BlendState>,
) -> wgpu::RenderPipeline {
    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some(fragment),
        layout: Some(layout),
        vertex: wgpu::VertexState { module, entry_point: Some("vs"), compilation_options: Default::default(), buffers: &[] },
        primitive: Default::default(),
        depth_stencil: None,
        multisample: Default::default(),
        fragment: Some(wgpu::FragmentState {
            module,
            entry_point: Some(fragment),
            compilation_options: Default::default(),
            targets: &[Some(wgpu::ColorTargetState { format, blend, write_mask: wgpu::ColorWrites::ALL })],
        }),
        multiview_mask: None,
        cache: None,
    })
}

fn texture_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: true }, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false },
        count: None,
    }
}
fn sampler_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry { binding, visibility: wgpu::ShaderStages::FRAGMENT, ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering), count: None }
}
fn uniform_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
        count: None,
    }
}

impl App {
    fn post_group(&self, uniform: &wgpu::Buffer, source: &wgpu::TextureView, history: &wgpu::TextureView) -> wgpu::BindGroup {
        self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.pipelines.post_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(source) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(history) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.pipelines.sampler) },
            ],
        })
    }

    fn build_targets(&self, width: u32, height: u32) -> Targets {
        let (iw, ih) = (((width as f32) * self.scale) as u32, ((height as f32) * self.scale) as u32);
        let uniform = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("uniforms"),
            size: std::mem::size_of::<Uniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let scene = render_target(&self.device, iw, ih);
        let history = [render_target(&self.device, iw, ih), render_target(&self.device, iw, ih)];
        let bloom: Vec<_> = (0..BLOOM_LEVELS).map(|level| render_target(&self.device, iw >> (level + 1), ih >> (level + 1))).collect();
        let scene_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.pipelines.scene_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() }],
        });
        let taa_groups = [self.post_group(&uniform, &scene, &history[1]), self.post_group(&uniform, &scene, &history[0])];
        let bloom_first = [self.post_group(&uniform, &history[0], &history[0]), self.post_group(&uniform, &history[1], &history[1])];
        let bloom_down = (1..BLOOM_LEVELS).map(|level| self.post_group(&uniform, &bloom[level - 1], &bloom[level - 1])).collect();
        let bloom_up = (0..BLOOM_LEVELS - 1).map(|level| self.post_group(&uniform, &bloom[level + 1], &bloom[level + 1])).collect();
        let final_groups = [self.post_group(&uniform, &history[0], &bloom[0]), self.post_group(&uniform, &history[1], &bloom[0])];
        Targets { uniform, scene, history, bloom, scene_group, taa_groups, bloom_first, bloom_down, bloom_up, final_groups }
    }

    /// The desk: every monitor's box together, from xdg-output's logical layout.
    fn desk(&self) -> (f32, f32, f32, f32) {
        let (mut left, mut top, mut right, mut bottom) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
        for panel in &self.panels {
            if let Some(info) = self.output_state.info(&panel.output) {
                let (x, y) = info.logical_position.unwrap_or((0, 0));
                let (w, h) = info.logical_size.unwrap_or((panel.width as i32, panel.height as i32));
                left = left.min(x as f32);
                top = top.min(y as f32);
                right = right.max((x + w) as f32);
                bottom = bottom.max((y + h) as f32);
            }
        }
        (left, top, right - left, bottom - top)
    }

    /// Compiles a scene if it has not been yet. A scene that is unknown or does
    /// not compile is reported and refused, and the desk keeps the one it has.
    fn prepare_scene(&mut self, name: &str) -> bool {
        if self.pipelines.scenes.contains_key(name) { return true; }
        let Some(source) = self.scene_sources.get(name) else {
            eprintln!("no scene called {name}; there are: {}", SCENES.iter().map(|(n, _)| *n).collect::<Vec<_>>().join(", "));
            return false;
        };
        let scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let module = self.device.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some(name), source: wgpu::ShaderSource::Wgsl(source.as_str().into()) });
        let pipeline = fullscreen_pipeline(&self.device, &self.pipelines.scene_pipeline_layout, &module, "fs", HDR, None);
        if let Some(error) = pollster::block_on(scope.pop()) {
            eprintln!("scene {name} does not compile:\n{error}");
            return false;
        }
        self.pipelines.scenes.insert(name.to_string(), pipeline);
        eprintln!("scene: {name}");
        true
    }

    fn render(&mut self, index: usize, qh: &QueueHandle<Self>) {
        while let Ok(announcement) = self.announcements.try_recv() {
            match announcement {
                Announcement::Desktop(desktop) if std::env::var("HYPRPEACH_DESKTOP").is_err() => self.camera.aim(desktop, Instant::now()),
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
                Announcement::Scene(name) => {
                    if self.prepare_scene(&name) {
                        self.scene = name;
                        remember_scene(&self.scene);
                    }
                }
                _ => {}
            }
        }
        let now = Instant::now();
        let time = (now - self.started).as_secs_f32();
        let (position, motion) = self.camera.at(now);
        // For captures of a switch in flight: HYPRPEACH_POSITION holds the desk
        // there, and HYPRPEACH_MOTION says how hard it is moving.
        let position = std::env::var("HYPRPEACH_POSITION").ok().and_then(|v| v.parse().ok()).unwrap_or(position);
        let motion = std::env::var("HYPRPEACH_MOTION").ok().and_then(|v| v.parse().ok()).unwrap_or(motion);

        // EVERY FRAME FRESH. This once drew ten new frames a second and showed
        // the last one again in between, to save power behind a desk of
        // windows; anything that moved on its own -- a planet turning, clouds
        // -- then stepped along like a slideshow, which is all anyone saw. A
        // scene is held to costing little enough to draw at the panel's rate.
        let (desk_left, desk_top, desk_width, desk_height) = self.desk();
        let pane = {
            let panel = &self.panels[index];
            let info = self.output_state.info(&panel.output);
            let (x, y) = info.as_ref().and_then(|i| i.logical_position).unwrap_or((0, 0));
            let (w, h) = info.as_ref().and_then(|i| i.logical_size).unwrap_or((panel.width as i32, panel.height as i32));
            [(x as f32 - desk_left) / desk_height, (y as f32 - desk_top) / desk_height, w as f32 / desk_height, h as f32 / desk_height]
        };
        let format = match self.panels[index].format { Some(format) => format, None => return };
        if self.pipelines.final_pass.as_ref().map(|(f, _)| *f) != Some(format) {
            let pipeline = fullscreen_pipeline(&self.device, &self.pipelines.post_pipeline_layout, &self.pipelines.post_module, "present", format, None);
            self.pipelines.final_pass = Some((format, pipeline));
        }

        let panel = &mut self.panels[index];
        let targets = panel.targets.as_ref().unwrap();
        let (iw, ih) = (((panel.width as f32) * self.scale) as u32, ((panel.height as f32) * self.scale) as u32);
        let i = (panel.frame % 2) as usize;
        let jitter = [halton(panel.frame % 16 + 1, 2) - 0.5, halton(panel.frame % 16 + 1, 3) - 0.5];
        let blend = if panel.frame == 0 { 1.0 } else if motion > 0.02 { 0.45 } else { 0.1 };
        let uniforms = Uniforms {
            eye: [0.0, 0.0, 0.0, time],
            forward: [0.0, 0.0, 0.0, position],
            right: [0.0, 0.0, 0.0, desk_width / desk_height],
            up: [0.0, 0.0, 0.0, motion],
            pane,
            // Near dawn: the sun 8 degrees up.
            sun: {
                let s = normalize([0.98, 0.14, 0.12]);
                [s[0], s[1], s[2], 1.3 + time * 0.0105]
            },
            jitter: [jitter[0], jitter[1], iw as f32, ih as f32],
            extra: [panel.width as f32, panel.height as f32, (panel.frame % 1024) as f32, blend],
            view: [0.0, if self.overview { 1.0 } else { 0.0 }, 0.0, 0.0],
        };
        self.queue.write_buffer(&targets.uniform, 0, bytemuck::bytes_of(&uniforms));

        let frame = match panel.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(frame) | wgpu::CurrentSurfaceTexture::Suboptimal(frame) => frame,
            other => { eprintln!("surface: {other:?}"); return; }
        };
        let view = frame.texture.create_view(&Default::default());
        let mut encoder = self.device.create_command_encoder(&Default::default());
        let pass = |encoder: &mut wgpu::CommandEncoder, target: &wgpu::TextureView, load: wgpu::LoadOp<wgpu::Color>, pipeline: &wgpu::RenderPipeline, groups: &[&wgpu::BindGroup]| {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: None,
                color_attachments: &[Some(wgpu::RenderPassColorAttachment { view: target, depth_slice: None, resolve_target: None, ops: wgpu::Operations { load, store: wgpu::StoreOp::Store } })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(pipeline);
            for (slot, group) in groups.iter().enumerate() { pass.set_bind_group(slot as u32, *group, &[]); }
            pass.draw(0..3, 0..1);
        };
        let clear = wgpu::LoadOp::Clear(wgpu::Color::BLACK);
        {
            let scene = &self.pipelines.scenes[&self.scene];
            pass(&mut encoder, &targets.scene, clear, scene, &[&targets.scene_group, &self.pipelines.planet]);
            pass(&mut encoder, &targets.history[i], clear, &self.pipelines.taa, &[&targets.taa_groups[i]]);
            pass(&mut encoder, &targets.bloom[0], clear, &self.pipelines.bloom_down, &[&targets.bloom_first[i]]);
            for level in 1..BLOOM_LEVELS {
                pass(&mut encoder, &targets.bloom[level], clear, &self.pipelines.bloom_down, &[&targets.bloom_down[level - 1]]);
            }
            for level in (0..BLOOM_LEVELS - 1).rev() {
                pass(&mut encoder, &targets.bloom[level], wgpu::LoadOp::Load, &self.pipelines.bloom_up, &[&targets.bloom_up[level]]);
            }
        }
        pass(&mut encoder, &view, clear, &self.pipelines.final_pass.as_ref().unwrap().1, &[&targets.final_groups[i]]);

        // CAPTURE: the finished picture, whatever is on the screen in front of
        // it. Set HYPRPEACH_CAPTURE to a directory and each panel saves frame
        // HYPRPEACH_CAPTURE_FRAME (default 150) as a PNG, then carries on.
        let capture_frame: u32 = std::env::var("HYPRPEACH_CAPTURE_FRAME").ok().and_then(|v| v.parse().ok()).unwrap_or(150);
        let capture = std::env::var("HYPRPEACH_CAPTURE").ok().filter(|_| panel.frame == capture_frame);
        let mut readback = None;
        if let Some(directory) = capture {
            let texture = self.device.create_texture(&wgpu::TextureDescriptor {
                label: None,
                size: wgpu::Extent3d { width: panel.width, height: panel.height, depth_or_array_layers: 1 },
                mip_level_count: 1, sample_count: 1, dimension: wgpu::TextureDimension::D2,
                format, usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC, view_formats: &[],
            });
            pass(&mut encoder, &texture.create_view(&Default::default()), clear, &self.pipelines.final_pass.as_ref().unwrap().1, &[&targets.final_groups[i]]);
            let row = (panel.width * 4).div_ceil(256) * 256;
            let buffer = self.device.create_buffer(&wgpu::BufferDescriptor { label: None, size: (row * panel.height) as u64, usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
            encoder.copy_texture_to_buffer(
                wgpu::TexelCopyTextureInfo { texture: &texture, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
                wgpu::TexelCopyBufferInfo { buffer: &buffer, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(row), rows_per_image: Some(panel.height) } },
                wgpu::Extent3d { width: panel.width, height: panel.height, depth_or_array_layers: 1 },
            );
            readback = Some((buffer, row, directory));
        }

        // Ask for the next frame before presenting: the present commits.
        panel.layer.wl_surface().frame(qh, FrameCallbackData(panel.layer.wl_surface().clone()));
        self.queue.submit(Some(encoder.finish()));
        self.queue.present(frame);
        if let Some((buffer, row, directory)) = readback {
            let slice = buffer.slice(..);
            slice.map_async(wgpu::MapMode::Read, |_| {});
            let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
            let data = slice.get_mapped_range().expect("mapped capture");
            let mut image = image::RgbaImage::new(panel.width, panel.height);
            for y in 0..panel.height {
                let start = (y * row) as usize;
                image.as_mut()[(y * panel.width * 4) as usize..((y + 1) * panel.width * 4) as usize].copy_from_slice(&data[start..start + (panel.width * 4) as usize]);
            }
            let name = self.output_state.info(&panel.output).and_then(|i| i.name).unwrap_or_else(|| index.to_string());
            let path = format!("{directory}/{name}.png");
            image.save(&path).expect("save capture");
            eprintln!("captured {path}");
        }
        panel.frame += 1;

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
    fn frame(&mut self, _: &Connection, qh: &QueueHandle<Self>, surface: &wl_surface::WlSurface, _: u32) {
        if let Some(index) = self.panels.iter().position(|p| p.layer.wl_surface() == surface) {
            self.render(index, qh);
        }
    }
    fn surface_enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
    fn surface_leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
}

impl OutputHandler for App {
    fn output_state(&mut self) -> &mut OutputState { &mut self.output_state }
    fn new_output(&mut self, _: &Connection, qh: &QueueHandle<Self>, output: wl_output::WlOutput) {
        let surface = self.compositor.create_surface(qh);
        let layer = self.layer_shell.create_layer_surface(qh, surface, Layer::Background, Some("hyprpeach-scene"), Some(&output));
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
        self.panels.push(Panel { output, layer, surface, format: None, width: 0, height: 0, targets: None, frame: 0 });
    }
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, output: wl_output::WlOutput) {
        self.panels.retain(|p| p.output != output);
    }
}

impl LayerShellHandler for App {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, layer: &LayerSurface) {
        self.panels.retain(|p| p.layer.wl_surface() != layer.wl_surface());
    }
    fn configure(&mut self, _: &Connection, qh: &QueueHandle<Self>, layer: &LayerSurface, configure: LayerSurfaceConfigure, _: u32) {
        let Some(index) = self.panels.iter().position(|p| p.layer.wl_surface() == layer.wl_surface()) else { return };
        let (width, height) = (configure.new_size.0.max(1), configure.new_size.1.max(1));
        let first = self.panels[index].targets.is_none();
        if self.panels[index].width != width || self.panels[index].height != height {
            let capabilities = self.panels[index].surface.get_capabilities(&self.adapter);
            let format = capabilities.formats.iter().copied().find(|f| f.is_srgb()).unwrap_or(capabilities.formats[0]);
            let present_mode = if capabilities.present_modes.contains(&wgpu::PresentMode::Mailbox) { wgpu::PresentMode::Mailbox } else { wgpu::PresentMode::Fifo };
            self.panels[index].surface.configure(&self.device, &wgpu::SurfaceConfiguration {
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
            let targets = self.build_targets(width, height);
            let panel = &mut self.panels[index];
            panel.format = Some(format);
            panel.width = width;
            panel.height = height;
            panel.targets = Some(targets);
            panel.frame = 0;
            eprintln!("panel {index}: {width}x{height}, {format:?}, {present_mode:?}");
        }
        if first { self.render(index, qh); }
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
/// `hyprpeach-overview,open` and `,closed`, and `hyprpeach-scene,<name>` from
/// `hyprpeach scene`. Listening to announcements rather
/// than to raw workspace changes is what keeps a focus move from reading as a
/// switch -- the bug 2.1.1 fixed by the same route.
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
            let Some(event) = line.strip_prefix("custom>>") else { continue };
            let announcement = if let Some(desktop) = event.strip_prefix("hyprpeach-desktop,") {
                desktop.trim().parse().ok().map(Announcement::Desktop)
            } else if let Some(scene) = event.strip_prefix("hyprpeach-scene,") {
                Some(Announcement::Scene(scene.trim().to_string()))
            } else {
                match event.trim() {
                    "hyprpeach-overview,open" => Some(Announcement::Overview(true)),
                    "hyprpeach-overview,closed" => Some(Announcement::Overview(false)),
                    _ => None,
                }
            };
            if let Some(announcement) = announcement {
                if sender.send(announcement).is_err() { return; }
            }
        }
    });
    receiver
}

fn active_workspace() -> i32 {
    let output = std::process::Command::new("hyprctl").args(["-j", "activeworkspace"]).output();
    output
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|text| text.split("\"id\":").nth(1).map(|s| s.trim().split(|c: char| !c.is_ascii_digit()).next().unwrap_or("1").to_string()))
        .and_then(|s| s.parse().ok())
        .unwrap_or(1)
}

/// The scene last picked, kept across restarts in
/// $XDG_STATE_HOME/hyprpeach/orbit.json as `{ "scene": "<name>" }`. Written by
/// this program alone, so it is read with a plain search, not a JSON parser.
fn remembered_scene_path() -> PathBuf {
    let state = std::env::var("XDG_STATE_HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/state"));
    state.join("hyprpeach/orbit.json")
}

fn remembered_scene() -> Option<String> {
    let text = std::fs::read_to_string(remembered_scene_path()).ok()?;
    let after = text.split("\"scene\"").nth(1)?;
    after.split('"').nth(1).map(String::from)
}

fn remember_scene(name: &str) {
    let path = remembered_scene_path();
    if let Some(directory) = path.parent() { let _ = std::fs::create_dir_all(directory); }
    let _ = std::fs::write(path, format!("{{ \"scene\": \"{name}\" }}\n"));
}

fn main() {
    let connection = Connection::connect_to_env().expect("wayland");
    let (globals, mut event_queue) = registry_queue_init(&connection).expect("registry");
    let qh = event_queue.handle();
    let compositor = CompositorState::bind(&globals, &qh).expect("wl_compositor");
    let layer_shell = LayerShell::bind(&globals, &qh).expect("layer shell");

    let instance = wgpu::Instance::new({ let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle(); descriptor.backends = wgpu::Backends::VULKAN; descriptor });
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        ..Default::default()
    }))
    .expect("adapter");
    eprintln!("gpu: {}", adapter.get_info().name);
    let limits = adapter.limits();
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: None,
        required_limits: limits.clone(),
        ..Default::default()
    }))
    .expect("device");

    let assets = PathBuf::from(std::env::var("HYPRPEACH_ASSETS").unwrap_or_else(|_| concat!(env!("CARGO_MANIFEST_DIR"), "/assets").into()));
    let largest = limits.max_texture_dimension_2d.min(16384);
    let srgb = wgpu::TextureFormat::Rgba8UnormSrgb;
    let linear = wgpu::TextureFormat::Rgba8Unorm;
    // Laid down by plugins/orbit/prepare, which fetches NASA's originals and
    // scales them once, so starting the renderer never decodes a 21600-pixel map.
    let day = load_texture(&device, &queue, &assets.join("day.jpg"), largest, srgb);
    let night = load_texture(&device, &queue, &assets.join("night.jpg"), largest, srgb);
    let clouds = load_texture(&device, &queue, &assets.join("clouds.png"), largest, linear);
    let height = load_texture(&device, &queue, &assets.join("height.png"), largest, linear);
    let moon = load_texture(&device, &queue, &assets.join("moon.jpg"), largest, srgb);

    let map_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
        address_mode_u: wgpu::AddressMode::Repeat,
        address_mode_v: wgpu::AddressMode::ClampToEdge,
        mag_filter: wgpu::FilterMode::Linear,
        min_filter: wgpu::FilterMode::Linear,
        mipmap_filter: wgpu::MipmapFilterMode::Linear,
        anisotropy_clamp: 16,
        ..Default::default()
    });
    let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
        mag_filter: wgpu::FilterMode::Linear,
        min_filter: wgpu::FilterMode::Linear,
        ..Default::default()
    });

    let scene_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &[uniform_entry(0)] });
    let planet_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: None,
        entries: &[texture_entry(0), texture_entry(1), texture_entry(2), texture_entry(3), texture_entry(4), sampler_entry(5)],
    });
    let planet = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: None,
        layout: &planet_layout,
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&day) },
            wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&night) },
            wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(&clouds) },
            wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::TextureView(&height) },
            wgpu::BindGroupEntry { binding: 4, resource: wgpu::BindingResource::TextureView(&moon) },
            wgpu::BindGroupEntry { binding: 5, resource: wgpu::BindingResource::Sampler(&map_sampler) },
        ],
    });
    let post_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: None,
        entries: &[uniform_entry(0), texture_entry(1), texture_entry(2), sampler_entry(3)],
    });
    let post_module = device.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some("post"), source: wgpu::ShaderSource::Wgsl(include_str!("post.wgsl").into()) });
    let scene_pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &[Some(&scene_layout), Some(&planet_layout)], immediate_size: 0 });
    let post_pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &[Some(&post_layout)], immediate_size: 0 });
    let additive = wgpu::BlendState {
        color: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Add },
        alpha: wgpu::BlendComponent::REPLACE,
    };
    let pipelines = Pipelines {
        scenes: HashMap::new(),
        scene_pipeline_layout,
        taa: fullscreen_pipeline(&device, &post_pipeline_layout, &post_module, "taa", HDR, None),
        bloom_down: fullscreen_pipeline(&device, &post_pipeline_layout, &post_module, "bloomDown", HDR, None),
        bloom_up: fullscreen_pipeline(&device, &post_pipeline_layout, &post_module, "bloomUp", HDR, Some(additive)),
        final_pass: None,
        scene_layout,
        post_layout,
        post_pipeline_layout,
        post_module,
        planet,
        sampler,
    };

    let common = include_str!("common.wgsl");
    let scene_file = std::env::var("HYPRPEACH_SCENE_FILE").ok().map(|path| {
        let name = Path::new(&path).file_stem().and_then(|s| s.to_str()).unwrap_or("file").to_string();
        (name, std::fs::read_to_string(&path).expect("HYPRPEACH_SCENE_FILE"))
    });
    let mut scene_sources: HashMap<String, String> = SCENES.iter().map(|(name, source)| (name.to_string(), format!("{common}\n{source}"))).collect();
    if let Some((name, source)) = &scene_file { scene_sources.insert(name.clone(), format!("{common}\n{source}")); }

    let now = Instant::now();
    let mut camera = Camera { position_from: 0.0, position_to: 0.0, started: now };
    // Where the desk already is: the workspace's place in its band of ten.
    let desktop = std::env::var("HYPRPEACH_DESKTOP").ok().and_then(|v| v.parse().ok()).unwrap_or_else(|| {
        let within = (active_workspace() - 1).rem_euclid(10) + 1;
        if within > 9 { 1 } else { within }
    });
    camera.aim(desktop, now - std::time::Duration::from_secs(10));
    let scale = std::env::var("HYPRPEACH_SCALE").ok().and_then(|s| s.parse().ok()).unwrap_or(0.5f32);

    let mut app = App {
        registry_state: RegistryState::new(&globals),
        output_state: OutputState::new(&globals, &qh),
        compositor,
        layer_shell,
        connection: connection.clone(),
        instance,
        adapter,
        device,
        queue,
        pipelines,
        panels: Vec::new(),
        started: now,
        camera,
        announcements: listen_to_hyprpeach(),
        overview: std::env::var("HYPRPEACH_OVERVIEW").is_ok(),
        scene: String::new(),
        scene_sources,
        scale,
        frames: 0,
        last_report: now,
    };
    // HYPRPEACH_SCENE_FILE, for writing a scene: that file, read now, in place
    // of the compiled-in scene of the same name -- no rebuild to try a change.
    // HYPRPEACH_SCENE picks one by name without remembering it.
    let first = std::env::var("HYPRPEACH_SCENE").ok().or_else(remembered_scene).unwrap_or_else(|| DEFAULT_SCENE.to_string());
    let first = scene_file.as_ref().map(|(name, _)| name.clone()).unwrap_or(first);
    if !app.prepare_scene(&first) && !app.prepare_scene(DEFAULT_SCENE) {
        panic!("not even the default scene compiles");
    }
    app.scene = if app.pipelines.scenes.contains_key(&first) { first } else { DEFAULT_SCENE.to_string() };
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
        let mut camera = Camera { position_from: 0.0, position_to: 0.0, started: long_ago };
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

    #[test]
    fn the_default_scene_is_one_of_the_scenes() {
        assert!(SCENES.iter().any(|(name, _)| *name == DEFAULT_SCENE));
    }
}
