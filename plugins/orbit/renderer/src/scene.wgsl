// The scene: low orbit over a living planet, seen through ONE window the size
// of the desk -- every monitor draws its own slice of the same camera.
// Original, written for hyprpeach. Planet imagery is NASA's, public domain.

struct Uniforms {
    eye: vec4<f32>,      // xyz camera (km, planet at origin); w time (s)
    forward: vec4<f32>,  // xyz; w motion 0..1
    right: vec4<f32>,    // xyz; w desk width in desk heights
    up: vec4<f32>,       // xyz; w focal length in desk heights
    pane: vec4<f32>,     // this monitor on the desk: x, y (top-left, y down), width, height
    sun: vec4<f32>,      // xyz direction to the sun; w planet spin (radians)
    jitter: vec4<f32>,   // xy sub-pixel jitter; zw internal size
    extra: vec4<f32>,    // xy output size; z frame; w history blend
    view: vec4<f32>,     // x orbit position (radians); y overview open 0/1; z altitude (km); w bearing of column 1 (radians)
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
const R: f32 = 6360.0;         // planet radius, km
const TOP: f32 = 6460.0;       // top of the atmosphere
const RELIEF: f32 = 26.0;      // Everest, lifted three times over
const CLOUDS: f32 = 6371.0;    // the cloud deck
const BETA_R: vec3<f32> = vec3<f32>(5.8e-3, 13.5e-3, 33.1e-3);
const BETA_M: f32 = 21e-3;
const HEIGHT_R: f32 = 8.0;
const HEIGHT_M: f32 = 1.2;
const SUN_POWER: f32 = 14.0;

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

fn sphere(origin: vec3<f32>, d: vec3<f32>, radius: f32) -> vec2<f32> {
    let b = dot(origin, d); let c = dot(origin, origin) - radius * radius; let h = b * b - c;
    if (h < 0.0) { return vec2<f32>(-1.0, -1.0); }
    let s = sqrt(h);
    return vec2<f32>(-b - s, -b + s);
}

// The globe's own frame: tilted so mid-latitudes pass under the station, and
// spinning fast on purpose.
fn toGlobe(v: vec3<f32>) -> vec3<f32> {
    let tilt = -0.9; let spin = u.sun.w;
    let m = vec3<f32>(v.x, v.y * cos(tilt) - v.z * sin(tilt), v.y * sin(tilt) + v.z * cos(tilt));
    return vec3<f32>(m.x * cos(spin) - m.z * sin(spin), m.y, m.x * sin(spin) + m.z * cos(spin));
}
fn fromGlobe(g: vec3<f32>) -> vec3<f32> {
    let tilt = -0.9; let spin = u.sun.w;
    let m = vec3<f32>(g.x * cos(spin) + g.z * sin(spin), g.y, -g.x * sin(spin) + g.z * cos(spin));
    return vec3<f32>(m.x, m.y * cos(tilt) + m.z * sin(tilt), -m.y * sin(tilt) + m.z * cos(tilt));
}
fn globeUv(g: vec3<f32>) -> vec2<f32> { return vec2<f32>(atan2(g.z, g.x) / (2.0 * PI) + 0.5, 0.5 - asin(clamp(g.y, -1.0, 1.0)) / PI); }
fn elevation(g: vec3<f32>) -> f32 { return textureSampleLevel(heightMap, mapSampler, globeUv(g), 0.0).r; }

// Air density at a point, Rayleigh and Mie.
fn density(p: vec3<f32>) -> vec2<f32> {
    let h = max(length(p) - R, 0.0);
    return vec2<f32>(exp(-h / HEIGHT_R), exp(-h / HEIGHT_M));
}

// How much sunlight survives from the sun to point p.
fn sunTransmittance(p: vec3<f32>) -> vec3<f32> {
    let s = u.sun.xyz;
    if (sphere(p, s, R - 1.0).x > 0.0) { return vec3<f32>(0.0); }   // the planet is in the way
    let exit = sphere(p, s, TOP).y;
    let steps = 6;
    let ds = exit / f32(steps);
    var depth = vec2<f32>(0.0);
    for (var i = 0; i < steps; i++) { depth += density(p + s * (f32(i) + 0.5) * ds) * ds; }
    return exp(-(BETA_R * depth.x + vec3<f32>(BETA_M * 1.1 * depth.y)));
}

// Single scattering along the ray from t0 to t1: the light the air itself
// sends toward the eye, and how much of what lies behind gets through.
struct Scatter { light: vec3<f32>, transmittance: vec3<f32> };
fn scatter(origin: vec3<f32>, d: vec3<f32>, t0: f32, t1: f32) -> Scatter {
    let steps = 16;
    let ds = (t1 - t0) / f32(steps);
    let mu = dot(d, u.sun.xyz);
    let phaseR = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
    let g = 0.76;
    let phaseM = 3.0 / (8.0 * PI) * ((1.0 - g * g) * (1.0 + mu * mu)) / ((2.0 + g * g) * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
    var depth = vec2<f32>(0.0);
    var sumR = vec3<f32>(0.0);
    var sumM = vec3<f32>(0.0);
    for (var i = 0; i < steps; i++) {
        let p = origin + d * (t0 + (f32(i) + 0.5) * ds);
        let rho = density(p) * ds;
        depth += rho;
        let toEye = exp(-(BETA_R * depth.x + vec3<f32>(BETA_M * 1.1 * depth.y)));
        let fromSun = sunTransmittance(p);
        sumR += rho.x * toEye * fromSun;
        sumM += rho.y * toEye * fromSun;
    }
    var out: Scatter;
    out.light = SUN_POWER * (sumR * BETA_R * phaseR + sumM * BETA_M * phaseM);
    out.transmittance = exp(-(BETA_R * depth.x + vec3<f32>(BETA_M * 1.1 * depth.y)));
    return out;
}

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

// GGX: the microfacet reflection modern engines use; what turns a flat ocean
// into a glittering path of sun.
fn ggx(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, roughness: f32, f0: f32) -> f32 {
    let h = normalize(v + l);
    let a = roughness * roughness; let a2 = a * a;
    let nh = max(dot(n, h), 0.0); let nv = max(dot(n, v), 1e-3); let nl = max(dot(n, l), 0.0);
    let dd = nh * nh * (a2 - 1.0) + 1.0;
    let D = a2 / (PI * dd * dd);
    let k = a / 2.0;
    let G = (nv / (nv * (1.0 - k) + k)) * (nl / (nl * (1.0 - k) + k));
    let F = f0 + (1.0 - f0) * pow(1.0 - max(dot(v, h), 0.0), 5.0);
    return D * G * F / (4.0 * nv) ;   // already multiplied by n.l
}

fn shadeSurface(p: vec3<f32>, d: vec3<f32>) -> vec3<f32> {
    let n = normalize(p);
    let g = toGlobe(n);
    let uv = globeUv(g);
    let sunG = toGlobe(u.sun.xyz);
    // Relief: the elevation's slope, exaggerated, lights the ranges.
    let east = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), g));
    let north = cross(g, east);
    let e = 0.0009;
    let h0 = elevation(g);
    let he = elevation(normalize(g + east * e));
    let hn = elevation(normalize(g + north * e));
    let reliefG = normalize(g - 14.0 * ((he - h0) * east + (hn - h0) * north));
    let reliefLight = max(dot(reliefG, sunG), 0.0);

    var albedo = textureSample(dayMap, mapSampler, uv).rgb;
    let luminance = dot(albedo, vec3<f32>(0.3, 0.59, 0.11));
    albedo = max(mix(vec3<f32>(luminance), albedo, 1.3), vec3<f32>(0.0));      // a touch more vivid than life
    albedo = mix(albedo, vec3<f32>(0.9, 0.92, 0.95), smoothstep(0.45, 0.62, h0));
    let land = step(0.003, h0);
    let sunT = sunTransmittance(p);
    let sunUp = dot(n, u.sun.xyz);
    // Clouds cast their shadow a little away from the sun.
    let shadowPoint = normalize(p + u.sun.xyz * (CLOUDS - R) / max(sunUp, 0.08));
    let shadow = smoothstep(0.25, 0.8, textureSampleLevel(cloudMap, mapSampler, globeUv(toGlobe(shadowPoint)), 0.0).r);
    var col = albedo / PI * SUN_POWER * sunT * reliefLight * (1.0 - 0.6 * shadow);
    col += albedo * vec3<f32>(0.03, 0.05, 0.09) * smoothstep(-0.2, 0.3, sunUp);   // skylight
    // The ocean: GGX glint on wind-roughened water, sky reflected at grazing angles.
    if (land < 0.5) {
        let ripples = vec3<f32>(fbm3(p * 0.9, 3) - 0.5, 0.0, fbm3(p * 0.9 + 7.0, 3) - 0.5) * 0.06;
        let wn = normalize(n + ripples);
        col += SUN_POWER * sunT * ggx(wn, -d, u.sun.xyz, 0.22, 0.02) * (1.0 - 0.8 * shadow);
        let fresnel = 0.02 + 0.98 * pow(1.0 - max(dot(-d, n), 0.0), 5.0);
        col += vec3<f32>(0.25, 0.45, 0.9) * 0.35 * fresnel * smoothstep(-0.1, 0.3, sunUp);
    }
    // City lights where it is night.
    // Night: city lights, warm and bright enough to read from orbit, and a
    // faint cold moonlight on everything else so the night side has a shape.
    let darkness = 1.0 - smoothstep(-0.12, 0.06, sunUp);
    let night = textureSample(nightMap, mapSampler, uv).rgb;
    col += pow(night, vec3<f32>(1.5)) * vec3<f32>(1.0, 0.7, 0.38) * 5.0 * darkness * (1.0 - 0.7 * shadow);
    col += albedo * vec3<f32>(0.010, 0.013, 0.022) * darkness;
    return col;
}

fn shadeCloud(p: vec3<f32>, cover: f32) -> vec3<f32> {
    let n = normalize(p);
    let sunUp = dot(n, u.sun.xyz);
    let lit = SUN_POWER * sunTransmittance(p) * (0.35 + 0.65 * max(sunUp, 0.0)) * 0.22;
    let moonlit = vec3<f32>(0.018, 0.022, 0.034) * (1.0 - smoothstep(-0.12, 0.06, sunUp));
    return vec3<f32>(0.95, 0.96, 1.0) * lit * (0.8 + 0.2 * cover) + vec3<f32>(0.006, 0.008, 0.012) + moonlit;
}

fn megastructures(origin: vec3<f32>, d: vec3<f32>, limit: f32) -> vec3<f32> {
    var col = vec3<f32>(0.0);
    let axis = fromGlobe(vec3<f32>(0.0, 1.0, 0.0));
    let ringRadius = R + 1600.0;
    let denom = dot(d, axis);
    if (abs(denom) > 1e-4) {
        let along = -dot(origin, axis) / denom;
        if (along > 0.0 && along < limit) {
            let q = origin + d * along;
            let off = abs(length(q) - ringRadius);
            let band = smoothstep(9.0, 4.0, off);
            let angle = atan2(dot(q, fromGlobe(vec3<f32>(0.0, 0.0, 1.0))), dot(q, fromGlobe(vec3<f32>(1.0, 0.0, 0.0))));
            let windows = step(0.55, fract(angle * 1400.0 / (2.0 * PI)));
            let lit = max(dot(normalize(q), u.sun.xyz), 0.0);
            let shadowed = select(1.0, 0.0, sphere(q, u.sun.xyz, R).x > 0.0);
            col += band * (vec3<f32>(0.5, 0.52, 0.58) * (0.02 + 3.0 * lit * shadowed) + vec3<f32>(0.6, 0.9, 1.0) * windows * 1.5);
        }
    }
    // A space elevator from the equator up to the ring, climbers on the tether.
    let base = fromGlobe(vec3<f32>(1.0, 0.0, 0.0)) * R;
    let top = fromGlobe(vec3<f32>(1.0, 0.0, 0.0)) * ringRadius;
    let ba = top - base; let oa = origin - base;
    let w = cross(d, ba);
    let lineDistance = abs(dot(oa, normalize(w)));
    let s = dot(cross(oa, d), w) / dot(w, w);
    let rayT = dot(cross(oa, ba), w) / dot(w, w);
    if (s > 0.0 && s < 1.0 && rayT > 0.0 && rayT < limit) {
        let width = 0.6 + rayT * 0.0004;
        col += vec3<f32>(0.8, 0.9, 1.0) * smoothstep(width, 0.0, lineDistance) * 2.0;
        col += vec3<f32>(1.0, 0.5, 0.3) * step(0.985, fract(s * 30.0 - u.eye.w * 0.2)) * smoothstep(width * 3.0, 0.0, lineDistance) * 8.0;
    }
    return col;
}

fn moon(origin: vec3<f32>, d: vec3<f32>) -> vec4<f32> {
    let centre = normalize(vec3<f32>(-0.55, 0.28, 0.78)) * 60000.0;
    let hit = sphere(origin - centre, d, 3200.0);
    if (hit.x < 0.0) { return vec4<f32>(0.0); }
    let n = normalize(origin + d * hit.x - centre);
    let albedo = textureSample(moonMap, mapSampler, globeUv(n)).rgb;
    return vec4<f32>(albedo * SUN_POWER * 0.08 * max(dot(n, u.sun.xyz), 0.0), 1.0);
}

// THE STATION'S ORBIT. The station itself never moves in this shader's world:
// it sits above the planet's north point, and moving along its orbit is the
// universe -- planet, sun, Moon, ring -- turning the other way about the orbit's
// axis. Rotating the ray into the universe's frame is all it takes.
fn orbitFrame(v: vec3<f32>, position: f32) -> vec3<f32> {
    let c = cos(position); let s = sin(position);
    return vec3<f32>(v.x * c - v.y * s, v.x * s + v.y * c, v.z);
}

// THE OVERVIEW'S GRID, IN THIS PANEL'S PIXELS -- the same arithmetic as
// plugins/overview/Model.js gridFor and Overview.qml, so the cells land exactly
// under the overview's frames: 3 x 3 in 92% x 86% of the panel, gaps of 1.2%
// of its height, each cell the panel's own shape, centred.
struct Cell { inside: bool, column: i32, row: i32, local: vec2<f32>, size: vec2<f32> };
fn overviewCell(pixel: vec2<f32>, size: vec2<f32>) -> Cell {
    let gap = round(size.y * 0.012);
    let aspect = size.x / size.y;
    let cellWidth = floor(min((size.x * 0.92 - 2.0 * gap) / 3.0, (size.y * 0.86 - 2.0 * gap) / 3.0 * aspect));
    let cellHeight = floor(cellWidth / aspect);
    let grid = vec2<f32>(3.0 * cellWidth + 2.0 * gap, 3.0 * cellHeight + 2.0 * gap);
    let corner = (size - grid) * 0.5;
    let p = pixel - corner;
    let pitch = vec2<f32>(cellWidth + gap, cellHeight + gap);
    let index = floor(p / pitch);
    let within = p - index * pitch;
    var cell: Cell;
    cell.inside = all(index >= vec2<f32>(0.0)) && all(index < vec2<f32>(3.0)) && within.x < cellWidth && within.y < cellHeight;
    cell.column = i32(index.x);
    cell.row = i32(index.y);
    cell.local = within / vec2<f32>(cellWidth, cellHeight);
    cell.size = vec2<f32>(cellWidth, cellHeight);
    return cell;
}

// Desktop (column, row) is bearing `column` and orbit position `row`.
// Columns step RIGHT: the next desktop's view sits to the right of this one's,
// so a row of cells joins edge to edge into one 360-degree ring.
const STEP: f32 = 2.0943951;   // 120 degrees
fn bearingOf(column: i32) -> f32 { return u.view.w - f32(column) * STEP; }
fn orbitOf(row: i32) -> f32 { return f32(row) * STEP; }

// A cell's view: a cylindrical slice 120 degrees wide, so its left and right
// edges are exactly the neighbouring cells' right and left edges.
fn cellRay(cell: Cell) -> vec3<f32> {
    let altitude = u.view.z;
    let dip = acos(R / (R + altitude));
    let yaw = bearingOf(cell.column) - (cell.local.x - 0.5) * STEP;
    let height = STEP * cell.size.y / cell.size.x;
    // Tipped so the horizon sits a little above the middle: a cell is wide and
    // short, and the planet is what it is for.
    let pitch = -dip - 0.05 + (0.5 - cell.local.y) * height;
    return vec3<f32>(cos(pitch) * cos(yaw), sin(pitch), cos(pitch) * sin(yaw));
}

struct Sample { colour: vec3<f32> };

// Everything the camera sees along one ray, in the universe's frame.
fn look(origin: vec3<f32>, d: vec3<f32>) -> vec3<f32> {
    var groundT = -1.0;
    let shell = sphere(origin, d, R + RELIEF);
    if (shell.y > 0.0) {
        let core = sphere(origin, d, R);
        var end = shell.y;
        if (core.x > 0.0) { end = min(end, core.x + 0.5); }
        let start = max(shell.x, 0.0);
        let stepLength = (end - start) / 40.0;
        var t = start; var previous = start; var hit = false;
        for (var i = 0; i < 40; i++) {
            let p = origin + d * t;
            let r = length(p);
            if (r - R < elevation(toGlobe(p / r)) * RELIEF) { hit = true; break; }
            previous = t; t += stepLength;
        }
        if (hit) {
            var low = previous; var high = t;
            for (var i = 0; i < 5; i++) {
                let middle = 0.5 * (low + high);
                let p = origin + d * middle;
                let r = length(p);
                if (r - R < elevation(toGlobe(p / r)) * RELIEF) { high = middle; } else { low = middle; }
            }
            groundT = high;
        } else if (core.x > 0.0) {
            // The flat sea is thinner than a step near the horizon: a ray the
            // relief march stepped over still meets the planet.
            groundT = core.x;
        }
    }

    let atmosphere = sphere(origin, d, TOP);
    var col = vec3<f32>(0.0);
    if (groundT > 0.0) {
        let p = origin + d * groundT;
        var surface = shadeSurface(p, d);
        let cloudHit = sphere(origin, d, CLOUDS);
        if (cloudHit.x > 0.0 && cloudHit.x < groundT) {
            let cp = origin + d * cloudHit.x;
            let cover = smoothstep(0.22, 0.85, textureSampleLevel(cloudMap, mapSampler, globeUv(toGlobe(normalize(cp))), 0.0).r);
            surface = mix(surface, shadeCloud(cp, cover), cover * 0.95);
        }
        let air = scatter(origin, d, max(atmosphere.x, 0.0), groundT);
        col = surface * air.transmittance + air.light;
    } else {
        var behind = deepSpace(d);
        let mo = moon(origin, d);
        behind = mix(behind, mo.rgb, mo.a);
        let sunDot = max(dot(d, u.sun.xyz), 0.0);
        behind += vec3<f32>(1.0, 0.96, 0.9) * smoothstep(0.99995, 0.99998, sunDot) * 400.0;
        if (atmosphere.y > 0.0) {
            let air = scatter(origin, d, max(atmosphere.x, 0.0), atmosphere.y);
            col = behind * air.transmittance + air.light;
        } else {
            col = behind;
        }
    }
    // AIRGLOW: on the night side, the thin green line that traces the limb in
    // every photograph taken from orbit at night -- oxygen glowing about 95 km
    // up. Drawn where the ray passes closest to that height and the air there
    // is in darkness.
    let along = -dot(origin, d);
    if (along > 0.0 && (groundT < 0.0 || along < groundT)) {
        let closest = origin + d * along;
        let height = length(closest) - R;
        let dark = 1.0 - smoothstep(-0.15, 0.1, dot(normalize(closest), u.sun.xyz));
        col += vec3<f32>(0.25, 0.95, 0.45) * exp(-pow((height - 95.0) / 3.5, 2.0)) * 0.1 * dark;
    }
    col += megastructures(origin, d, select(1e9, groundT, groundT > 0.0));
    return col;
}

@fragment fn fs(input: VertexOutput) -> @location(0) vec4<f32> {
    // This pixel, jittered for temporal anti-aliasing.
    let pixel = input.uv * u.jitter.zw + u.jitter.xy;
    let local = pixel / u.jitter.zw;
    let eye = u.eye.xyz;

    if (u.view.y > 0.5) {
        let cell = overviewCell(local * u.extra.xy, u.extra.xy);
        if (cell.inside) {
            // A viewport: this desktop's slice of its orbit position's ring.
            let position = orbitOf(cell.row);
            return vec4<f32>(look(orbitFrame(eye, position), orbitFrame(cellRay(cell), position)), 1.0);
        }
        // Between the viewports, the universe they look into: the planet and
        // its ring from far out, dimmed so the viewports lead.
        let s = vec2<f32>(local.x - 0.5, 0.5 - local.y) * vec2<f32>(u.extra.x / u.extra.y, 1.0);
        let far = vec3<f32>(0.0, 9000.0, -30000.0);
        let forward = normalize(-far);
        let right = normalize(cross(vec3<f32>(0.0, 1.0, 0.0), forward));
        let up = cross(forward, right);
        let d = normalize(forward * 1.4 + right * s.x + up * s.y);
        return vec4<f32>(look(orbitFrame(far, u.view.x), orbitFrame(d, u.view.x)) * 0.3, 1.0);
    }

    // The live view: ONE window the size of the desk, this panel a slice of it.
    let desk = u.pane.xy + local * u.pane.zw;
    let s = vec2<f32>(desk.x - u.right.w * 0.5, 0.5 - desk.y);
    let d = normalize(u.forward.xyz * u.up.w + u.right.xyz * s.x + u.up.xyz * s.y);
    return vec4<f32>(look(orbitFrame(eye, u.view.x), orbitFrame(d, u.view.x)), 1.0);
}
