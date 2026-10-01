// The scene: the ground beneath a station in orbit, looked straight down at,
// through ONE window the size of the desk -- every monitor draws its own slice.
// Original, written for hyprpeach. Planet imagery is NASA's, public domain.

struct Uniforms {
    eye: vec4<f32>,      // xyz camera (km, planet at origin); w time (s)
    forward: vec4<f32>,  // w: where along the orbit the camera is (radians, decreasing ahead)
    right: vec4<f32>,    // w: desk width in desk heights
    up: vec4<f32>,       // w: how hard the camera is moving, 0..1
    pane: vec4<f32>,     // this monitor on the desk: x, y (top-left, y down), width, height
    sun: vec4<f32>,      // xyz direction to the sun; w planet spin (radians)
    jitter: vec4<f32>,   // xy sub-pixel jitter; zw internal size
    extra: vec4<f32>,    // xy output size; z frame; w history blend
    view: vec4<f32>,     // x unused; y overview open 0/1; z unused; w orbit position of desktop 1 (radians)
};
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(1) @binding(0) var dayMap: texture_2d<f32>;
@group(1) @binding(1) var nightMap: texture_2d<f32>;
@group(1) @binding(2) var cloudMap: texture_2d<f32>;
@group(1) @binding(3) var heightMap: texture_2d<f32>;
@group(1) @binding(4) var moonMap: texture_2d<f32>;
@group(1) @binding(5) var mapSampler: sampler;

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

// The globe's own frame: tilted so mid-latitudes pass under the station, and
// spinning fast on purpose.
fn toGlobe(v: vec3<f32>) -> vec3<f32> {
    let tilt = -0.9; let spin = u.sun.w;
    let m = vec3<f32>(v.x, v.y * cos(tilt) - v.z * sin(tilt), v.y * sin(tilt) + v.z * cos(tilt));
    return vec3<f32>(m.x * cos(spin) - m.z * sin(spin), m.y, m.x * sin(spin) + m.z * cos(spin));
}
fn globeUv(g: vec3<f32>) -> vec2<f32> { return vec2<f32>(atan2(g.z, g.x) / (2.0 * PI) + 0.5, 0.5 - asin(clamp(g.y, -1.0, 1.0)) / PI); }
fn elevation(g: vec3<f32>) -> f32 { return textureSampleLevel(heightMap, mapSampler, globeUv(g), 0.0).r; }

fn deepSpace(d: vec3<f32>) -> vec3<f32> {
    var col = vec3<f32>(0.0);
    for (var i = 0; i < 3; i++) {
        let scale = 700.0 + f32(i) * 900.0;
        let q = d * scale;
        let cell = floor(q);
        let h = hash3(cell + f32(i) * 13.0);
        let spot = cell + 0.2 + 0.6 * vec3<f32>(hash3(cell + 1.0), hash3(cell + 2.0), hash3(cell + 3.0));
        let core = exp(-dot(q - spot, q - spot) * 9.0);
        let star = step(0.992, h) * core * (0.4 + 6.0 * pow(fract(h * 91.0), 5.0));
        col += star * mix(vec3<f32>(0.6, 0.75, 1.0), vec3<f32>(1.0, 0.8, 0.6), fract(h * 37.0));
    }
    let band = exp(-pow(dot(d, normalize(vec3<f32>(0.3, 0.9, -0.3))) * 3.2, 2.0));
    let n = fbm3(d * 3.0, 6);
    let wisps = pow(fbm3(d * 6.0 + n, 5), 2.2);
    col += band * (vec3<f32>(0.10, 0.07, 0.13) * n + vec3<f32>(0.35, 0.16, 0.14) * wisps) * 0.35;
    return col;
}

// THE ORBIT. Nine desktops are nine stops along one orbit, 40 degrees apart,
// desktop N+1 ahead of N and 9 round to 1.
const FRAME: f32 = 0.6981317;   // 40 degrees

// THE OVERVIEW: the orbit's strip line-wrapped onto the WHOLE DESK, three frames a line
// -- so 3's right edge runs on into 4's left, and 9's back into 1's. Laid out
// in desk coordinates, the same arithmetic as plugins/overview: every monitor
// draws its own part of the one grid, not a grid of its own.
struct Cell { inside: bool, desktop: i32, local: vec2<f32> };
fn overviewCell(desk: vec2<f32>) -> Cell {
    let width = u.right.w;
    let gap = 0.012;
    let cellWidth = min((width * 0.92 - 2.0 * gap) / 3.0, (0.86 - 2.0 * gap) / 3.0 * width);
    let cellHeight = cellWidth / width;
    let grid = vec2<f32>(3.0 * cellWidth + 2.0 * gap, 3.0 * cellHeight + 2.0 * gap);
    let p = desk - (vec2<f32>(width, 1.0) - grid) * 0.5;
    let pitch = vec2<f32>(cellWidth + gap, cellHeight + gap);
    let index = floor(p / pitch);
    let within = p - index * pitch;
    var cell: Cell;
    cell.inside = all(index >= vec2<f32>(0.0)) && all(index < vec2<f32>(3.0)) && within.x < cellWidth && within.y < cellHeight;
    cell.desktop = i32(index.y) * 3 + i32(index.x) + 1;
    cell.local = within / vec2<f32>(cellWidth, cellHeight);
    return cell;
}

// THE PLANE: the ground under the station's orbit, unrolled into one strip.
// Along the strip is the orbit -- nine stops, 40 degrees apart, closing on
// itself -- and across it, the ground either side. Desktop N looks straight
// down at stop N; the overview is the whole strip, line-wrapped into three.
// Looking down needs no ray march: a handful of texture reads a pixel.
const ORBIT_INCLINATION: f32 = 0.9;   // radians; carries the strip across latitudes

// The point on the planet at `along` the orbit and `across` it (radians).
fn groundPoint(along: f32, across: f32) -> vec3<f32> {
    let e1 = vec3<f32>(1.0, 0.0, 0.0);
    let e2 = vec3<f32>(0.0, cos(ORBIT_INCLINATION), sin(ORBIT_INCLINATION));
    let normal = cross(e1, e2);
    return normalize(cos(across) * (cos(along) * e1 + sin(along) * e2) + sin(across) * normal);
}

fn ground(along: f32, across: f32, cloudShift: f32) -> vec3<f32> {
    let n = groundPoint(along, across);
    let g = toGlobe(n);
    let uv = globeUv(g);
    let sunUp = dot(n, u.sun.xyz);
    // Relief from the elevation's slope, lit by the sun.
    let east = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), g));
    let north = cross(g, east);
    let e = 0.0006;
    let h0 = elevation(g);
    let relief = normalize(g - 10.0 * ((elevation(normalize(g + east * e)) - h0) * east + (elevation(normalize(g + north * e)) - h0) * north));
    let light = max(dot(relief, toGlobe(u.sun.xyz)), 0.0);
    var albedo = textureSample(dayMap, mapSampler, uv).rgb;
    let luminance = dot(albedo, vec3<f32>(0.3, 0.59, 0.11));
    albedo = max(mix(vec3<f32>(luminance), albedo, 1.25), vec3<f32>(0.0));
    let day = smoothstep(-0.05, 0.15, sunUp);
    // Clouds sit higher than the ground, so they slide a little further when
    // the view moves -- the depth in a transition -- and shade the ground
    // beneath them a little away from the sun.
    let cloudPoint = toGlobe(groundPoint(along + cloudShift, across));
    let cloud = smoothstep(0.25, 0.85, textureSample(cloudMap, mapSampler, globeUv(cloudPoint)).r);
    let shadowPoint = toGlobe(groundPoint(along + cloudShift - 0.004, across + 0.003));
    let shadow = smoothstep(0.25, 0.85, textureSample(cloudMap, mapSampler, globeUv(shadowPoint)).r);
    var col = albedo * (0.02 + 1.6 * light * day) * (1.0 - 0.55 * shadow * day);
    // Night: city lights, and a terminator that glows as it crosses.
    let night = textureSample(nightMap, mapSampler, uv).rgb;
    col += pow(night, vec3<f32>(1.5)) * vec3<f32>(1.0, 0.7, 0.38) * 4.0 * (1.0 - day) * (1.0 - 0.6 * cloud);
    col += vec3<f32>(1.0, 0.45, 0.2) * exp(-pow(sunUp / 0.06, 2.0)) * 0.12;
    let cloudLight = vec3<f32>(0.96, 0.97, 1.0) * (0.02 + 1.2 * day * (0.5 + 0.5 * max(sunUp, 0.0)));
    col = mix(col, cloudLight, cloud * 0.92);
    // The air between: a thin blue veil, thicker toward the strip's edges where
    // the view is more oblique.
    col = mix(col, vec3<f32>(0.18, 0.35, 0.75) * (0.03 + 0.5 * day), 0.05 + 0.6 * across * across);
    return col;
}

@fragment fn fs(input: VertexOutput) -> @location(0) vec4<f32> {
    let pixel = input.uv * u.jitter.zw + u.jitter.xy;
    let local = pixel / u.jitter.zw;
    let desk = u.pane.xy + local * u.pane.zw;
    let width = u.right.w;
    // Radians of ground per desk-height unit: a stop is 40 degrees of orbit
    // across the whole desk.
    let scale = FRAME / width;
    let moving = u.up.w;
    let along = u.view.w - u.forward.w + FRAME * 0.5;

    if (u.view.y > 0.5) {
        let cell = overviewCell(desk);
        if (cell.inside) {
            let s = vec2<f32>((cell.local.x - 0.5) * width, 0.5 - cell.local.y);
            let stop = (f32(cell.desktop) - 0.5) * FRAME;
            return vec4<f32>(ground(stop + s.x * scale, s.y * scale, 0.0), 1.0);
        }
        return vec4<f32>(deepSpace(normalize(vec3<f32>(desk.x - width * 0.5, 0.5 - desk.y, 1.2))) * 0.6, 1.0);
    }

    // The live desk: the ground beneath this stop. Mid-flight the view rises a
    // little, so a switch reads as flying, not sliding.
    let s = vec2<f32>(desk.x - width * 0.5, 0.5 - desk.y) * (1.0 + 0.3 * moving);
    return vec4<f32>(ground(along + s.x * scale, s.y * scale, moving * 0.01), 1.0);
}
