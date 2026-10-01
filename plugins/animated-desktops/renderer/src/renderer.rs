//! The drawing, with no window system in it: the live desk draws into each
//! monitor's surface through this, and `preview` into plain textures.
//!
//! Per frame and per monitor: the scene at an internal resolution with
//! sub-pixel jitter, temporal anti-aliasing into a history, a six-level bloom,
//! and a filmic pass up to the output.

use std::collections::HashMap;

use bytemuck::{Pod, Zeroable};

pub const HDR: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
const BLOOM_LEVELS: usize = 6;

/// OVERSCAN: every monitor is drawn this far past each edge, as a fraction of
/// its height, and only the monitor itself is shown. Bloom spreads light about
/// a tenth of a monitor's height; drawn to the edge and no further, a bright
/// patch near a bezel glowed on its own side and stopped dead at the bezel,
/// a visible step between two stacked panels. With the margin, each side
/// blooms from what lies across the bezel too, and the two meet.
const OVERSCAN: f32 = 0.1;

/// Every scene in src/scenes/, by name, each with src/common.wgsl in front of
/// it (build.rs makes the list).
pub const SCENES: &[(&str, &str)] = include!(concat!(env!("OUT_DIR"), "/scenes.rs"));

/// The same fields, in the same order, as `Uniforms` in common.wgsl and
/// post.wgsl, which say what each one means.
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct Uniforms {
    pub desk: [f32; 4],
    pub pane: [f32; 4],
    pub stage: [f32; 4],
    pub jitter: [f32; 4],
    pub output: [f32; 4],
    pub overscan: [f32; 4],
}

/// What one frame of one monitor shows.
pub struct Frame {
    pub time: f32,
    pub position: f32,
    pub motion: f32,
    pub overview: bool,
    /// This monitor and the home monitor, in scene units (layout.rs).
    pub pane: [f32; 4],
    pub stage: [f32; 4],
}

/// One monitor's render targets, sized to its output.
pub struct Targets {
    uniform: wgpu::Buffer,
    scene: wgpu::TextureView,
    history: [wgpu::TextureView; 2],
    bloom: Vec<wgpu::TextureView>,
    scene_group: wgpu::BindGroup,
    taa_groups: [wgpu::BindGroup; 2],
    bloom_first: [wgpu::BindGroup; 2],
    bloom_down: Vec<wgpu::BindGroup>,
    bloom_up: Vec<wgpu::BindGroup>,
    present_groups: [wgpu::BindGroup; 2],
    width: u32,
    height: u32,
    internal_width: u32,
    internal_height: u32,
    /// The margin drawn past each edge, in internal pixels.
    margin: u32,
    /// Frames drawn since these targets were made: the TAA jitter sequence,
    /// and whether there is a history yet.
    pub frame: u32,
}

pub struct Renderer {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    scene_layout: wgpu::BindGroupLayout,
    scene_pipeline_layout: wgpu::PipelineLayout,
    post_layout: wgpu::BindGroupLayout,
    post_pipeline_layout: wgpu::PipelineLayout,
    post_module: wgpu::ShaderModule,
    sampler: wgpu::Sampler,
    taa: wgpu::RenderPipeline,
    bloom_down: wgpu::RenderPipeline,
    bloom_up: wgpu::RenderPipeline,
    /// The last pass, one per output format.
    present: HashMap<wgpu::TextureFormat, wgpu::RenderPipeline>,
    /// Built the first time each scene is shown, so a scene that fails to
    /// compile costs only itself.
    scenes: HashMap<String, wgpu::RenderPipeline>,
    /// Compiled in, or read from HYPRPEACH_SCENE_FILE while one is being written.
    scene_sources: HashMap<String, String>,
    /// The internal resolution, as a fraction of the output's.
    scale: f32,
}

fn halton(mut index: u32, base: u32) -> f32 {
    let (mut fraction, mut result) = (1.0f32, 0.0f32);
    while index > 0 {
        fraction /= base as f32;
        result += fraction * (index % base) as f32;
        index /= base;
    }
    result
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

impl Renderer {
    /// `scene_file`: a scene's name and source to use in place of the
    /// compiled-in one of that name.
    pub fn new(device: wgpu::Device, queue: wgpu::Queue, scale: f32, scene_file: Option<(String, String)>) -> Self {
        let common = include_str!("common.wgsl");
        let mut scene_sources: HashMap<String, String> = SCENES.iter().map(|(name, source)| (name.to_string(), format!("{common}\n{source}"))).collect();
        if let Some((name, source)) = scene_file {
            scene_sources.insert(name, format!("{common}\n{source}"));
        }
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let scene_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &[uniform_entry(0)] });
        let post_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &[uniform_entry(0), texture_entry(1), texture_entry(2), sampler_entry(3)],
        });
        let post_module = device.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some("post"), source: wgpu::ShaderSource::Wgsl(include_str!("post.wgsl").into()) });
        let scene_pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &[Some(&scene_layout)], immediate_size: 0 });
        let post_pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &[Some(&post_layout)], immediate_size: 0 });
        let additive = wgpu::BlendState {
            color: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Add },
            alpha: wgpu::BlendComponent::REPLACE,
        };
        let taa = fullscreen_pipeline(&device, &post_pipeline_layout, &post_module, "taa", HDR, None);
        let bloom_down = fullscreen_pipeline(&device, &post_pipeline_layout, &post_module, "bloomDown", HDR, None);
        let bloom_up = fullscreen_pipeline(&device, &post_pipeline_layout, &post_module, "bloomUp", HDR, Some(additive));
        Renderer {
            device,
            queue,
            scene_layout,
            scene_pipeline_layout,
            post_layout,
            post_pipeline_layout,
            post_module,
            sampler,
            taa,
            bloom_down,
            bloom_up,
            present: HashMap::new(),
            scenes: HashMap::new(),
            scene_sources,
            scale,
        }
    }

    /// Compiles a scene if it has not been yet. A scene that is unknown or does
    /// not compile is reported and refused, and the desk keeps the one it has.
    pub fn prepare_scene(&mut self, name: &str) -> bool {
        if self.scenes.contains_key(name) {
            return true;
        }
        let Some(source) = self.scene_sources.get(name) else {
            eprintln!("no scene called {name}; there are: {}", SCENES.iter().map(|(n, _)| *n).collect::<Vec<_>>().join(", "));
            return false;
        };
        let scope = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let module = self.device.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some(name), source: wgpu::ShaderSource::Wgsl(source.as_str().into()) });
        let pipeline = fullscreen_pipeline(&self.device, &self.scene_pipeline_layout, &module, "fs", HDR, None);
        if let Some(error) = pollster::block_on(scope.pop()) {
            eprintln!("scene {name} does not compile:\n{error}");
            return false;
        }
        self.scenes.insert(name.to_string(), pipeline);
        eprintln!("scene: {name}");
        true
    }

    fn post_group(&self, uniform: &wgpu::Buffer, source: &wgpu::TextureView, history: &wgpu::TextureView) -> wgpu::BindGroup {
        self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.post_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(source) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(history) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.sampler) },
            ],
        })
    }

    pub fn build_targets(&self, width: u32, height: u32) -> Targets {
        let (visible_width, visible_height) = ((((width as f32) * self.scale) as u32).max(1), (((height as f32) * self.scale) as u32).max(1));
        let margin = (visible_height as f32 * OVERSCAN).round() as u32;
        let (internal_width, internal_height) = (visible_width + 2 * margin, visible_height + 2 * margin);
        let uniform = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("uniforms"),
            size: std::mem::size_of::<Uniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let scene = render_target(&self.device, internal_width, internal_height);
        let history = [render_target(&self.device, internal_width, internal_height), render_target(&self.device, internal_width, internal_height)];
        let bloom: Vec<_> = (0..BLOOM_LEVELS).map(|level| render_target(&self.device, internal_width >> (level + 1), internal_height >> (level + 1))).collect();
        let scene_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.scene_layout,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: uniform.as_entire_binding() }],
        });
        let taa_groups = [self.post_group(&uniform, &scene, &history[1]), self.post_group(&uniform, &scene, &history[0])];
        let bloom_first = [self.post_group(&uniform, &history[0], &history[0]), self.post_group(&uniform, &history[1], &history[1])];
        let bloom_down = (1..BLOOM_LEVELS).map(|level| self.post_group(&uniform, &bloom[level - 1], &bloom[level - 1])).collect();
        let bloom_up = (0..BLOOM_LEVELS - 1).map(|level| self.post_group(&uniform, &bloom[level + 1], &bloom[level + 1])).collect();
        let present_groups = [self.post_group(&uniform, &history[0], &bloom[0]), self.post_group(&uniform, &history[1], &bloom[0])];
        Targets {
            uniform, scene, history, bloom, scene_group, taa_groups, bloom_first, bloom_down, bloom_up, present_groups,
            width, height, internal_width, internal_height, margin, frame: 0,
        }
    }

    /// Records one frame of `scene` into `encoder`, ending in `output`.
    pub fn draw(&mut self, encoder: &mut wgpu::CommandEncoder, scene: &str, targets: &mut Targets, frame: &Frame, output: &wgpu::TextureView, format: wgpu::TextureFormat) {
        if !self.present.contains_key(&format) {
            let pipeline = fullscreen_pipeline(&self.device, &self.post_pipeline_layout, &self.post_module, "present", format, None);
            self.present.insert(format, pipeline);
        }
        let index = (targets.frame % 2) as usize;
        let sequence = targets.frame % 16 + 1;
        // A switch blends the history away fast, so motion does not smear;
        // at rest it accumulates, which is what resolves the fine detail.
        let blend = if targets.frame == 0 { 1.0 } else if frame.motion > 0.02 { 0.45 } else { 0.1 };
        let uniforms = Uniforms {
            desk: [frame.time, frame.position, frame.motion, if frame.overview { 1.0 } else { 0.0 }],
            pane: frame.pane,
            stage: frame.stage,
            jitter: [halton(sequence, 2) - 0.5, halton(sequence, 3) - 0.5, targets.internal_width as f32, targets.internal_height as f32],
            output: [targets.width as f32, targets.height as f32, (targets.frame % 1024) as f32, blend],
            overscan: [
                targets.margin as f32 / (targets.internal_width - 2 * targets.margin) as f32,
                targets.margin as f32 / (targets.internal_height - 2 * targets.margin) as f32,
                0.0,
                0.0,
            ],
        };
        self.queue.write_buffer(&targets.uniform, 0, bytemuck::bytes_of(&uniforms));

        let pass = |encoder: &mut wgpu::CommandEncoder, target: &wgpu::TextureView, load: wgpu::LoadOp<wgpu::Color>, pipeline: &wgpu::RenderPipeline, group: &wgpu::BindGroup| {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: None,
                color_attachments: &[Some(wgpu::RenderPassColorAttachment { view: target, depth_slice: None, resolve_target: None, ops: wgpu::Operations { load, store: wgpu::StoreOp::Store } })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(pipeline);
            pass.set_bind_group(0, group, &[]);
            pass.draw(0..3, 0..1);
        };
        let clear = wgpu::LoadOp::Clear(wgpu::Color::BLACK);
        pass(encoder, &targets.scene, clear, &self.scenes[scene], &targets.scene_group);
        pass(encoder, &targets.history[index], clear, &self.taa, &targets.taa_groups[index]);
        pass(encoder, &targets.bloom[0], clear, &self.bloom_down, &targets.bloom_first[index]);
        for level in 1..BLOOM_LEVELS {
            pass(encoder, &targets.bloom[level], clear, &self.bloom_down, &targets.bloom_down[level - 1]);
        }
        for level in (0..BLOOM_LEVELS - 1).rev() {
            pass(encoder, &targets.bloom[level], wgpu::LoadOp::Load, &self.bloom_up, &targets.bloom_up[level]);
        }
        pass(encoder, output, clear, &self.present[&format], &targets.present_groups[index]);
        targets.frame += 1;
    }

    /// A texture `draw` can end in and `read_back` can read: for captures.
    pub fn capture_texture(&self, width: u32, height: u32, format: wgpu::TextureFormat) -> wgpu::Texture {
        self.device.create_texture(&wgpu::TextureDescriptor {
            label: None,
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        })
    }

    /// The pixels of a capture texture, as RGBA, after everything submitted.
    /// A BGRA texture comes back swapped into RGBA.
    pub fn read_back(&self, texture: &wgpu::Texture) -> image::RgbaImage {
        let (width, height) = (texture.width(), texture.height());
        let row = (width * 4).div_ceil(256) * 256;
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor { label: None, size: (row * height) as u64, usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
        let mut encoder = self.device.create_command_encoder(&Default::default());
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo { texture, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            wgpu::TexelCopyBufferInfo { buffer: &buffer, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(row), rows_per_image: Some(height) } },
            wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
        );
        self.queue.submit(Some(encoder.finish()));
        let slice = buffer.slice(..);
        slice.map_async(wgpu::MapMode::Read, |_| {});
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
        let data = slice.get_mapped_range().expect("mapped capture");
        let swapped = matches!(texture.format(), wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Bgra8UnormSrgb);
        let mut image = image::RgbaImage::new(width, height);
        for y in 0..height {
            for x in 0..width {
                let at = (y * row + x * 4) as usize;
                let pixel = [data[at], data[at + 1], data[at + 2], data[at + 3]];
                image.put_pixel(x, y, image::Rgba(if swapped { [pixel[2], pixel[1], pixel[0], 255] } else { [pixel[0], pixel[1], pixel[2], 255] }));
            }
        }
        image
    }
}

impl Targets {
    pub fn width(&self) -> u32 { self.width }
    pub fn height(&self) -> u32 { self.height }
}
