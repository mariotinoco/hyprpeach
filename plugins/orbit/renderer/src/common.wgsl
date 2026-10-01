// What every scene shares: the uniforms, the hashing, the overview's cells, and
// the fragment entry that decides which scene picture a pixel shows.
//
// A SCENE is one file in scenes/, appended to this one, that defines two
// functions and nothing else needs to know about it:
//
//   fn scene(position: f32, point: vec2<f32>, motion: f32, time: f32) -> vec3<f32>
//     The picture for the desk at `position`: desktop N is position N - 1,
//     and between whole numbers the desk is on its way. The scene MUST repeat
//     every 9 so 9 -> 1 is a step forward like any other (the camera steps
//     8.0 -> 9.0, which has to look the same as 0.0). `motion` is 0 at rest
//     and peaks at 1 halfway through a switch. Linear HDR out; the post passes
//     add bloom and tone-map.
//
//     `point` is where on the desk, in SCENE UNITS: the origin at the centre
//     of the home monitor -- the one at eye level, holding workspaces 1-9 --
//     y up, one unit its height (layout.rs). One picture runs across every monitor, the
//     bezels being window frames onto it, but it is COMPOSED for the home
//     monitor: the subject belongs inside u.stage, and the other monitors
//     see what is around it. Across the desks this has to serve, a point can
//     be anywhere from about -4 to 4 across (a laptop between two 4K
//     screens) and -1 to 1.5 up (two stacked panels).
//
//   fn backdrop(point: vec2<f32>, time: f32) -> vec3<f32>
//     What shows between the overview's cells.
//
// Original, written for hyprpeach.

struct Uniforms {
    desk: vec4<f32>,     // x time (s); y position (desktops: N - 1 at desktop N, unbounded); z motion 0..1; w overview open 0/1
    pane: vec4<f32>,     // this monitor in scene units: left, top (y up), width, height
    stage: vec4<f32>,    // the home monitor, the same way: the picture is composed for it
    jitter: vec4<f32>,   // xy sub-pixel jitter; zw internal size
    output: vec4<f32>,   // xy output size; z frame; w history blend
    overscan: vec4<f32>, // xy how far past each edge the drawing runs, as a fraction of the monitor (renderer.rs says why)
};
@group(0) @binding(0) var<uniform> u: Uniforms;

struct VertexOutput { @builtin(position) position: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex fn vs(@builtin(vertex_index) index: u32) -> VertexOutput {
    let corner = vec2<f32>(f32((index << 1u) & 2u), f32(index & 2u));
    var out: VertexOutput;
    out.position = vec4<f32>(corner * 2.0 - 1.0, 0.0, 1.0);
    out.uv = vec2<f32>(corner.x, 1.0 - corner.y);
    return out;
}

const PI: f32 = 3.14159265;
// INTEGER HASHING (pcg3d, Jarzynski and Olano 2020). The usual fract(sin(dot))
// hash loses its low bits on the GPU once coordinates grow, and the stars came
// out in visible swirls and the nebula in rectangles. Every caller passes whole
// numbers -- a cell, or a cell plus an offset -- so the bits are exact.
fn pcg3d(seed: vec3<u32>) -> vec3<u32> {
    var v = seed * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v = v ^ (v >> vec3<u32>(16u));
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}
fn hash3(p: vec3<f32>) -> f32 { return f32(pcg3d(bitcast<vec3<u32>>(vec3<i32>(floor(p)))).x) / 4294967295.0; }
fn noise3(p: vec3<f32>) -> f32 {
    let i = floor(p); let f = fract(p); let s = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash3(i), hash3(i + vec3(1.,0.,0.)), s.x), mix(hash3(i + vec3(0.,1.,0.)), hash3(i + vec3(1.,1.,0.)), s.x), s.y),
               mix(mix(hash3(i + vec3(0.,0.,1.)), hash3(i + vec3(1.,0.,1.)), s.x), mix(hash3(i + vec3(0.,1.,1.)), hash3(i + vec3(1.,1.,1.)), s.x), s.y), s.z);
}
fn fbm3(p0: vec3<f32>, octaves: i32) -> f32 {
    var p = p0; var v = 0.0; var a = 0.5;
    for (var i = 0; i < octaves; i++) { v += a * noise3(p); p = p * 2.03 + 11.0; a *= 0.5; }
    return v;
}

// THE OVERVIEW: a 3 x 3 grid on EVERY MONITOR, in that monitor's own shape --
// plugins/overview/Model.js says why not one across the desk. The SAME
// arithmetic as its monitorGrid, in monitor heights: 3 x 3 inside 92% x 86%,
// gaps of 1.2%, cells in the monitor's aspect, centred.
struct Cell { inside: bool, desktop: i32, local: vec2<f32> };
fn overviewCell(local: vec2<f32>) -> Cell {
    let width = u.pane.z / u.pane.w;
    let gap = 0.012;
    let cellWidth = min((width * 0.92 - 2.0 * gap) / 3.0, (0.86 - 2.0 * gap) / 3.0 * width);
    let cellHeight = cellWidth / width;
    let grid = vec2<f32>(3.0 * cellWidth + 2.0 * gap, 3.0 * cellHeight + 2.0 * gap);
    let p = local * vec2<f32>(width, 1.0) - (vec2<f32>(width, 1.0) - grid) * 0.5;
    let pitch = vec2<f32>(cellWidth + gap, cellHeight + gap);
    let index = floor(p / pitch);
    let within = p - index * pitch;
    var cell: Cell;
    cell.inside = all(index >= vec2<f32>(0.0)) && all(index < vec2<f32>(3.0)) && within.x < cellWidth && within.y < cellHeight;
    cell.desktop = i32(index.y) * 3 + i32(index.x) + 1;
    cell.local = within / vec2<f32>(cellWidth, cellHeight);
    return cell;
}

// A place on this monitor (0..1, y down) as a point in the scene.
fn scenePoint(local: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(u.pane.x + local.x * u.pane.z, u.pane.y - local.y * u.pane.w);
}

@fragment fn fs(input: VertexOutput) -> @location(0) vec4<f32> {
    let drawn = (input.uv * u.jitter.zw + u.jitter.xy) / u.jitter.zw;
    let local = drawn * (1.0 + 2.0 * u.overscan.xy) - u.overscan.xy;
    let time = u.desk.x;
    if (u.desk.w > 0.5) {
        // Every cell, on every monitor, is desktop N as the home monitor sees
        // it at rest -- the composed picture, so all nine read at a glance on
        // any monitor -- cropped to the cell's shape around its centre.
        let cell = overviewCell(local);
        if (cell.inside) {
            let stageCentre = vec2<f32>(u.stage.x + u.stage.z * 0.5, u.stage.y - u.stage.w * 0.5);
            let aspect = u.pane.z / u.pane.w;
            let point = stageCentre + vec2<f32>((cell.local.x - 0.5) * aspect, 0.5 - cell.local.y) * u.stage.w;
            return vec4<f32>(scene(f32(cell.desktop - 1), point, 0.0, time), 1.0);
        }
        return vec4<f32>(backdrop(scenePoint(local), time), 1.0);
    }
    return vec4<f32>(scene(u.desk.y, scenePoint(local), u.desk.z, time), 1.0);
}
