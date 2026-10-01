// SYNTHWAVE: a neon grid floor running to a banded sun, flown over forever.
// Nine desktops are nine stops along one closed track, each with its own sky
// and its own landmark on the horizon -- mountains, a pyramid, a city, a ring,
// a ringed planet, spires, an aurora, palms under a crescent, an eclipse.
//
// Mechanism: no geometry and no marching. The floor is one ray-plane hit with
// analytically filtered lines; everything beyond it sits at the horizon, so it
// is drawn flat on the sky plane (`q`: the view ray divided by its depth, the
// horizon at y = 0) as cheap 2D shapes. A switch is a surge of 30 grid cells
// along the floor while the next stop's horizon grows out of the haze.

const STEP_CELLS: f32 = 30.0;       // grid cells travelled per desktop; whole, so 9 stops close without a seam
const EYE_HEIGHT: f32 = 3.0;        // in grid cells; sets how many cells span the screen's foot (about ten)
// The picture is measured in STAGE HEIGHTS from the home monitor's centre
// (scene() says why), so every constant below means the same on every desk.
const HORIZON: f32 = 0.06;          // stage heights above its centre: the floor fills the lower half, the sun and landmark sit in the upper
const FOCAL: f32 = 1.0;             // stage heights; about 85 degrees across a 16:9 stage
const STAGE_TOP: f32 = 0.38;        // sky-plane height a landmark stays under: the stage's top (0.44) less the bar and a breath of sky
const TRAIL_PERIOD: f32 = 90.0;     // cells between repeats of a light trail; divides 9 * STEP_CELLS so the wrap is seamless

struct Palette {
    zenith: vec3<f32>,
    sky: vec3<f32>,
    horizon: vec3<f32>,
    sunTop: vec3<f32>,
    sunBottom: vec3<f32>,
    grid: vec3<f32>,
    accent: vec3<f32>,
    sun: vec3<f32>,        // x across, y height above the horizon, z radius (sky-plane units)
};

fn makePalette(zenith: vec3<f32>, sky: vec3<f32>, horizon: vec3<f32>, sunTop: vec3<f32>, sunBottom: vec3<f32>,
               grid: vec3<f32>, accent: vec3<f32>, sun: vec3<f32>) -> Palette {
    var palette: Palette;
    palette.zenith = zenith; palette.sky = sky; palette.horizon = horizon;
    palette.sunTop = sunTop; palette.sunBottom = sunBottom;
    palette.grid = grid; palette.accent = accent; palette.sun = sun;
    return palette;
}

// Each stop's time of night. Colours are linear; the sun and grid run a little
// over 1 so bloom picks them out and nothing else.
fn stopPalette(stop: i32) -> Palette {
    switch stop {
        case 1: { // pyramid: amber dusk over dunes
            return makePalette(vec3(0.020, 0.008, 0.030), vec3(0.32, 0.07, 0.05), vec3(1.00, 0.36, 0.10),
                vec3(1.6, 1.25, 0.45), vec3(1.4, 0.30, 0.12), vec3(1.4, 0.45, 0.10), vec3(1.6, 0.85, 0.30), vec3(-0.18, 0.15, 0.15));
        }
        case 2: { // city: blue hour, a red sun almost gone
            return makePalette(vec3(0.004, 0.006, 0.030), vec3(0.04, 0.05, 0.22), vec3(0.65, 0.12, 0.35),
                vec3(1.4, 0.35, 0.25), vec3(1.0, 0.06, 0.18), vec3(0.15, 0.75, 1.40), vec3(1.2, 0.75, 0.40), vec3(0.0, 0.07, 0.19));
        }
        case 3: { // ring: violet, the sun framed by a gate
            return makePalette(vec3(0.010, 0.004, 0.040), vec3(0.16, 0.04, 0.34), vec3(0.80, 0.22, 0.75),
                vec3(1.5, 0.95, 1.10), vec3(1.2, 0.20, 0.65), vec3(1.30, 0.20, 1.20), vec3(0.30, 1.10, 1.60), vec3(0.0, 0.15, 0.10));
        }
        case 4: { // planet: deep night, the sun long set
            return makePalette(vec3(0.002, 0.008, 0.020), vec3(0.02, 0.08, 0.16), vec3(0.08, 0.35, 0.45),
                vec3(0.0), vec3(0.0), vec3(0.10, 1.10, 1.10), vec3(0.40, 1.10, 1.20), vec3(0.0, -1.0, 0.1));
        }
        case 5: { // spires: crimson, a swollen dying sun
            return makePalette(vec3(0.012, 0.002, 0.004), vec3(0.20, 0.02, 0.03), vec3(0.85, 0.12, 0.06),
                vec3(1.3, 0.35, 0.12), vec3(0.9, 0.05, 0.06), vec3(1.40, 0.18, 0.10), vec3(1.6, 0.20, 0.10), vec3(-0.30, 0.13, 0.24));
        }
        case 6: { // aurora: green night, a small pale sun
            return makePalette(vec3(0.002, 0.012, 0.020), vec3(0.02, 0.10, 0.12), vec3(0.20, 0.45, 0.42),
                vec3(1.3, 1.5, 1.4), vec3(0.6, 1.2, 0.9), vec3(0.20, 1.30, 0.70), vec3(0.40, 1.40, 0.90), vec3(0.25, 0.05, 0.07));
        }
        case 7: { // palms: pastel vaporwave, a crescent rising
            return makePalette(vec3(0.05, 0.04, 0.16), vec3(0.32, 0.18, 0.48), vec3(1.00, 0.55, 0.62),
                vec3(1.6, 1.30, 0.55), vec3(1.4, 0.40, 0.70), vec3(0.20, 1.00, 1.30), vec3(1.0, 0.9, 1.1), vec3(0.0, 0.20, 0.20));
        }
        case 8: { // eclipse: near black, a dark sun in a corona
            return makePalette(vec3(0.004, 0.000, 0.006), vec3(0.06, 0.005, 0.04), vec3(0.42, 0.03, 0.18),
                vec3(0.004, 0.0, 0.006), vec3(0.004, 0.0, 0.006), vec3(1.40, 0.10, 0.60), vec3(1.6, 0.35, 0.80), vec3(0.0, 0.22, 0.13));
        }
        default: { // home: the classic magenta dusk and its wireframe range
            return makePalette(vec3(0.008, 0.004, 0.030), vec3(0.20, 0.03, 0.22), vec3(0.95, 0.20, 0.55),
                vec3(1.5, 0.85, 0.12), vec3(1.4, 0.12, 0.45), vec3(1.30, 0.20, 1.10), vec3(0.20, 1.10, 1.40), vec3(0.0, 0.17, 0.18));
        }
    }
}

fn mixPalette(a: Palette, b: Palette, amount: f32) -> Palette {
    return makePalette(mix(a.zenith, b.zenith, amount), mix(a.sky, b.sky, amount), mix(a.horizon, b.horizon, amount),
        mix(a.sunTop, b.sunTop, amount), mix(a.sunBottom, b.sunBottom, amount), mix(a.grid, b.grid, amount),
        mix(a.accent, b.accent, amount), mix(a.sun, b.sun, amount));
}

// 1D value noise: two hashes a sample, where noise3 costs eight. The horizon
// is all silhouettes, and silhouettes only need one dimension.
fn noise1(x: f32, seed: f32) -> f32 {
    let cell = floor(x); let f = fract(x); let s = f * f * (3.0 - 2.0 * f);
    return mix(hash3(vec3<f32>(cell, seed, 7.0)), hash3(vec3<f32>(cell + 1.0, seed, 7.0)), s);
}
fn ridgeNoise(x: f32, seed: f32) -> f32 {
    let first = 1.0 - abs(2.0 * noise1(x, seed) - 1.0);
    return 0.55 * first * first + 0.28 * noise1(x * 2.3, seed + 1.0) + 0.12 * noise1(x * 5.1, seed + 2.0) + 0.05 * noise1(x * 11.7, seed + 3.0);
}

// Coverage of a line `distance` from its centre, `halfWidth` thick, both in
// sky-plane units, with `soft` the pixel (or the reflection's blur).
fn stroke(distance: f32, halfWidth: f32, soft: f32) -> f32 {
    return 1.0 - smoothstep(halfWidth - soft, halfWidth + soft, abs(distance));
}

// THE SKY: gradient, horizon glow, and the banded sun. `soft` widens every
// edge, so the floor's reflection can ask for the same sky, blurred.
fn skyColour(palette: Palette, q: vec2<f32>, soft: f32, time: f32) -> vec3<f32> {
    let height = max(q.y, 0.0);
    // Indigo overhead, the stop's colour lower down, and the horizon's own
    // colour only in a thin band: a bright sky behind windows is a glaring one.
    var colour = mix(palette.horizon * 0.55, palette.sky * 0.6, smoothstep(0.0, 0.10, height));
    colour = mix(colour, palette.zenith, smoothstep(0.08, 0.45, height));
    // Warmth pooled under the sun, where the light comes through the most air.
    colour += palette.sunTop * 0.10 * exp(-abs(q.x - palette.sun.x) * 2.2) * exp(-height * 9.0);
    // The sun: a disc whose lower half is cut by bands that thicken toward the
    // horizon and sink slowly, with a heat shimmer along its foot.
    let sunCentre = palette.sun.xy;
    let radius = palette.sun.z;
    let shimmer = 0.0025 * sin(q.y * 140.0 + time * 2.3) * smoothstep(0.08, 0.0, q.y);
    let offset = vec2<f32>(q.x + shimmer, q.y) - sunCentre;
    let along = offset.y / radius;                       // -1 at the sun's foot, 1 at its crown
    let disc = 1.0 - smoothstep(radius - soft, radius + soft, length(offset));
    let bandPhase = fract(along * 5.5 + time * 0.06);
    let gap = clamp(0.25 - along * 0.35, 0.0, 0.62) * step(along, 0.25);
    let bandSoft = soft * 5.5 / radius;
    let band = smoothstep(gap - bandSoft, gap + bandSoft, bandPhase);
    let body = mix(palette.sunBottom, palette.sunTop, smoothstep(-0.9, 0.8, along));
    colour = mix(colour, body, disc * band);
    // Glow: a halo around the disc and a broad warm band along the horizon.
    let distance = length(offset);
    colour += palette.sunBottom * (0.22 * exp(-max(distance - radius, 0.0) * 14.0) + 0.04 * exp(-max(distance - radius, 0.0) * 4.0));
    colour += palette.horizon * 0.25 * exp(-height * 30.0);
    return colour;
}

fn stars(q: vec2<f32>, time: f32) -> vec3<f32> {
    var light = vec3<f32>(0.0);
    for (var layer = 0; layer < 2; layer++) {
        let spacing = 0.016 + f32(layer) * 0.01;
        let cell = floor(q / spacing);
        let seed = vec3<f32>(cell, f32(layer) * 17.0 + 3.0);
        let chance = hash3(seed);
        let spot = (cell + 0.2 + 0.6 * vec2<f32>(hash3(seed + 1.0), hash3(seed + 2.0))) * spacing;
        let size = 0.0009 + 0.0007 * hash3(seed + 4.0);
        let core = exp(-dot(q - spot, q - spot) / (size * size));
        let twinkle = 0.65 + 0.35 * sin(time * (1.0 + 2.0 * hash3(seed + 5.0)) + chance * 40.0);
        let tint = mix(vec3<f32>(0.70, 0.80, 1.00), vec3<f32>(1.00, 0.75, 0.85), hash3(seed + 6.0));
        light += step(0.80, chance) * core * twinkle * tint * (0.25 + 1.2 * pow(hash3(seed + 7.0), 4.0));
    }
    // Stars are faint where the horizon glow would wash them out anyway.
    return light * smoothstep(0.04, 0.22, q.y);
}

// A wireframe range: dark fill, lines that follow the slope, a neon crest.
fn mountains(base: vec3<f32>, q: vec2<f32>, height: f32, seed: f32, line: vec3<f32>, fill: vec3<f32>, soft: f32) -> vec3<f32> {
    if (q.y > height * 1.3 + 0.02) { return base; }
    // A far range first, pale with haze, so the near one has something behind it.
    let farCrest = height * 0.75 * (0.3 + 0.9 * ridgeNoise(q.x * 5.0 + seed * 7.3, seed + 40.0));
    var colour = mix(base, mix(base, fill, 0.45), 1.0 - smoothstep(farCrest - soft, farCrest + soft, q.y));
    colour += line * 0.25 * stroke(q.y - farCrest, 0.0008, soft);
    // A valley in the middle so the range frames the sun rather than hiding it.
    let rugged = ridgeNoise(q.x * 3.4 + seed * 3.1, seed);
    let crest = height * (0.08 + 1.25 * rugged * rugged) * mix(0.35, 1.0, smoothstep(0.05, 0.6, abs(q.x)));
    colour += line * 0.35 * exp(-max(q.y - crest, 0.0) / 0.006) * step(crest, q.y);
    let inside = 1.0 - smoothstep(crest - soft, crest + soft, q.y);
    let contour = q.y / max(crest, 0.001) * 6.0;
    let contourLine = stroke(fract(contour + 0.5) - 0.5, 0.05, soft * 6.0 / max(crest, 0.001) + 0.02);
    let rib = stroke(fract(q.x / 0.05 + 0.5) - 0.5, 0.025, soft / 0.05 + 0.02);
    let wire = max(contourLine * smoothstep(0.0, 0.01, crest), rib) * 0.35;
    let body = fill + line * wire;
    colour = mix(colour, body, inside);
    colour += line * 1.3 * stroke(q.y - crest, 0.0012, soft);
    return colour;
}

// Sky-plane signed distance to a segment, for drawn edges.
fn segmentDistance(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    let pa = p - a; let ba = b - a;
    return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

fn pyramid(base: vec3<f32>, q: vec2<f32>, centre: f32, halfWidth: f32, height: f32, palette: Palette, soft: f32, time: f32) -> vec3<f32> {
    let apex = vec2<f32>(centre, height);
    let ridgeFoot = vec2<f32>(centre + halfWidth * 0.22, 0.0);
    let profile = height * (1.0 - abs(q.x - centre) / halfWidth);
    let inside = 1.0 - smoothstep(profile - soft, profile + soft, q.y);
    // Two faces: the one toward the sun catches its light, the other is night.
    let ridgeAt = mix(ridgeFoot.x, apex.x, q.y / height);
    let litFace = select(0.0, 1.0, q.x < ridgeAt);
    let face = mix(vec3<f32>(0.010, 0.004, 0.012), palette.sunBottom * 0.10, litFace * 0.8);
    var colour = mix(base, face, inside);
    let edges = min(min(segmentDistance(q, vec2<f32>(centre - halfWidth, 0.0), apex), segmentDistance(q, vec2<f32>(centre + halfWidth, 0.0), apex)),
                    segmentDistance(q, ridgeFoot, apex));
    colour += palette.accent * 1.1 * stroke(edges, 0.0012, soft);
    // A beam from the capstone, the Luxor way, flickering a little.
    let beam = exp(-abs(q.x - centre) / (0.0016 + soft)) * step(height, q.y) * exp(-(q.y - height) * 1.5);
    colour += palette.accent * beam * (0.9 + 0.1 * sin(time * 7.0));
    return colour;
}

fn city(base: vec3<f32>, q: vec2<f32>, palette: Palette, soft: f32, time: f32) -> vec3<f32> {
    // Searchlights from downtown, sweeping slowly: they rise past the stage
    // into whatever sky a desk has above it, where the city has nothing else.
    var lights = vec3<f32>(0.0);
    for (var index = 0; index < 2; index++) {
        let foot = vec2<f32>(select(-0.42, -0.20, index == 1), 0.12);
        let angle = 0.32 * sin(time * (0.11 + 0.04 * f32(index)) + f32(index) * 2.4);
        let direction = vec2<f32>(sin(angle), cos(angle));
        let relative = q - foot;
        let along = dot(relative, direction);
        let aside = abs(relative.x * direction.y - relative.y * direction.x);
        let beam = exp(-aside / (0.004 + 0.02 * max(along, 0.0))) * step(0.0, along) * exp(-along * 0.9);
        lights += vec3<f32>(0.35, 0.55, 0.90) * beam * 0.10;
    }
    if (q.y > 0.36) { return base + lights; }
    let width = 0.032;
    let column = floor(q.x / width);
    let seed = hash3(vec3<f32>(column, 2.0, 5.0));
    // Taller toward a downtown left of the sun, with a few needles.
    let downtown = exp(-pow((q.x + 0.35) / 0.45, 2.0)) + 0.5 * exp(-pow((q.x - 0.55) / 0.3, 2.0));
    var top = 0.015 + (0.03 + 0.20 * downtown) * pow(seed, 1.6);
    top += step(0.93, hash3(vec3<f32>(column, 9.0, 1.0))) * 0.08 * downtown;
    let local = q.x / width - column;
    let margin = 0.06 + 0.1 * hash3(vec3<f32>(column, 4.0, 4.0));
    let inColumn = smoothstep(margin - soft / width, margin + soft / width, local) * (1.0 - smoothstep(1.0 - margin - soft / width, 1.0 - margin + soft / width, local));
    // A second row behind, lower and hazier, fills the gaps between towers.
    let backColumn = floor(q.x / (width * 0.7) + 0.5);
    let backTop = 0.02 + 0.09 * downtown * hash3(vec3<f32>(backColumn, 3.0, 8.0));
    var colour = mix(base, mix(base, palette.sky * 0.4, 0.7), 1.0 - smoothstep(backTop - soft, backTop + soft, q.y));
    let inside = inColumn * (1.0 - smoothstep(top - soft, top + soft, q.y));
    // Windows: a lattice where some cells are lit, warm or cool.
    let window = vec2<f32>(q.x / 0.004, q.y / 0.0055);
    let windowCell = floor(window);
    let windowHash = hash3(vec3<f32>(windowCell, column));
    let windowShape = step(0.3, fract(window.x)) * step(0.35, fract(window.y));
    let lit = step(0.80, windowHash) * windowShape * smoothstep(0.004, 0.0, soft);
    let windowColour = mix(vec3<f32>(1.0, 0.65, 0.30), vec3<f32>(0.40, 0.85, 1.10), step(0.93, windowHash)) * 0.55;
    let facade = vec3<f32>(0.006, 0.006, 0.020) + windowColour * lit + palette.horizon * 0.10 * smoothstep(0.06, 0.0, q.y);
    colour = mix(colour, facade, inside);
    // Red aircraft lights on the tallest.
    colour += vec3<f32>(1.6, 0.1, 0.1) * step(0.13, top) * inColumn * exp(-pow((q.y - top - 0.004) / 0.0025, 2.0)) * exp(-pow((local - 0.5) / 0.15, 2.0));
    return colour + lights * (1.0 - inside);
}

fn ring(base: vec3<f32>, q: vec2<f32>, palette: Palette, soft: f32, time: f32) -> vec3<f32> {
    // Its crown under STAGE_TOP: a gate cut by the stage's edge reads as an
    // arc, not a ring, and the overview's cells show only the stage.
    let centre = vec2<f32>(0.0, 0.15);
    let offset = q - centre;
    let distance = length(offset);
    let outer = 0.225; let inner = 0.195;
    let body = (1.0 - smoothstep(outer - soft, outer + soft, distance)) * smoothstep(inner - soft, inner + soft, distance);
    // Lit from within: the inner rim is hot, the outer a cold edge.
    let angle = atan2(offset.y, offset.x);
    let segment = stroke(fract(angle * 36.0 / (2.0 * PI) + 0.5) - 0.5, 0.06, 0.04);
    var colour = mix(base, vec3<f32>(0.012, 0.008, 0.025) + palette.accent * 0.05 * segment, body);
    colour += palette.accent * 1.4 * stroke(distance - inner, 0.0014, soft);
    colour += palette.accent * 0.4 * stroke(distance - outer, 0.0008, soft);
    // A running light chasing round the inner rim.
    let chase = pow(0.5 + 0.5 * cos(angle - time * 0.6), 30.0);
    colour += palette.accent * 2.0 * chase * stroke(distance - inner - 0.006, 0.002, soft);
    // A haze of its light filling the gate.
    colour += palette.accent * 0.05 * (1.0 - smoothstep(inner - 0.05, inner, distance)) * smoothstep(0.0, inner, distance);
    return colour;
}

fn planet(base: vec3<f32>, q: vec2<f32>, palette: Palette, soft: f32, time: f32) -> vec3<f32> {
    let centre = vec2<f32>(0.42, 0.27);
    let radius = 0.15;
    let offset = q - centre;
    // The ring plane, tilted: its near half passes in front of the globe.
    let tilt = 0.32;
    let ringSpace = vec2<f32>(offset.x * cos(tilt) + offset.y * sin(tilt), -offset.x * sin(tilt) + offset.y * cos(tilt));
    let ringRadius = length(ringSpace * vec2<f32>(1.0, 4.2));
    let ringBand = smoothstep(0.20, 0.205, ringRadius) * (1.0 - smoothstep(0.30, 0.305, ringRadius));
    let ringDetail = 0.55 + 0.45 * noise1(ringRadius * 160.0, 3.0);
    let ringColour = vec3<f32>(0.55, 0.65, 0.70) * ringDetail * 0.35;
    var colour = base;
    colour = mix(colour, ringColour, ringBand * 0.85 * step(0.0, ringSpace.y));
    let distance = length(offset);
    let disc = 1.0 - smoothstep(radius - soft, radius + soft, distance);
    // Banded, lit from below-left by a sun under the horizon.
    let sphere = vec3<f32>(offset / radius, sqrt(max(1.0 - dot(offset, offset) / (radius * radius), 0.0)));
    let light = max(dot(sphere, normalize(vec3<f32>(-0.7, -0.45, 0.55))), 0.0);
    let latitude = ringSpace.y / radius;
    let bands = noise1(latitude * 9.0 + 0.6 * noise1(ringSpace.x / radius * 3.0 + time * 0.02, 5.0), 4.0);
    let surface = mix(vec3<f32>(0.10, 0.45, 0.55), vec3<f32>(0.55, 0.30, 0.55), bands) * (0.04 + 0.9 * light);
    colour = mix(colour, surface, disc);
    // Atmosphere rim and the ring's shadow on the globe.
    colour += vec3<f32>(0.2, 0.8, 1.0) * 0.5 * stroke(distance - radius, 0.002, soft + 0.003) * (0.3 + light);
    colour = mix(colour, ringColour, ringBand * 0.85 * step(ringSpace.y, 0.0));
    return colour;
}

fn spires(base: vec3<f32>, q: vec2<f32>, palette: Palette, soft: f32, time: f32) -> vec3<f32> {
    var colour = base;
    for (var index = 0; index < 4; index++) {
        let seed = f32(index);
        let centre = select(select(select(-0.62, 0.66, index == 3), -0.12, index == 2), 0.30, index == 1);
        // The tallest stops just under STAGE_TOP so its beacon shows on any
        // stage; what was its height above that is its searchlight now.
        let height = select(select(select(0.24, 0.18, index == 3), 0.31, index == 2), STAGE_TOP - 0.01, index == 1);
        let footWidth = select(0.035, 0.06, index == 1);
        // Tapered, with setbacks: the width narrows in steps up the tower.
        let rise = clamp(q.y / height, 0.0, 1.0);
        let setback = floor(rise * 5.0) / 5.0;
        let halfWidth = footWidth * (1.0 - 0.75 * setback) * (1.0 - 0.15 * rise);
        let inside = (1.0 - smoothstep(halfWidth - soft, halfWidth + soft, abs(q.x - centre))) * (1.0 - smoothstep(height - soft, height + soft, q.y));
        let light = stroke(fract(q.y * 90.0 + seed) - 0.5, 0.06, soft * 90.0 + 0.02) * step(0.5, noise1(q.y * 40.0, seed + 11.0));
        let face = vec3<f32>(0.008, 0.002, 0.004) + palette.accent * 0.10 * light * (1.0 - rise)
                 + palette.horizon * 0.10 * smoothstep(0.08, 0.0, q.y);
        colour = mix(colour, face, inside);
        colour += palette.accent * 0.9 * stroke(abs(q.x - centre) - halfWidth, 0.0008, soft) * step(q.y, height);
        // A beacon at each tip, breathing out of step with the others.
        let beacon = exp(-dot(q - vec2<f32>(centre, height + 0.006), q - vec2<f32>(centre, height + 0.006)) / 0.00002);
        colour += vec3<f32>(2.0, 0.25, 0.15) * beacon * (0.4 + 0.6 * pow(0.5 + 0.5 * sin(time * 1.7 + seed * 2.1), 3.0));
    }
    // A beam straight up from the tallest, the line that carries the eye from
    // the stage into the panel above it, pulsing slowly as if transmitting.
    let beamFoot = STAGE_TOP;
    let beam = exp(-abs(q.x - 0.30) / (0.0018 + soft)) * smoothstep(beamFoot - 0.004, beamFoot + 0.01, q.y) * exp(-(q.y - beamFoot) * 0.9);
    colour += palette.accent * beam * (0.55 + 0.25 * sin(time * 0.8 - q.y * 6.0));
    return colour;
}

fn aurora(base: vec3<f32>, q: vec2<f32>, soft: f32, time: f32) -> vec3<f32> {
    if (q.y < 0.08) { return base; }
    // Curtains: a wandering lower edge, rays combed upward from it.
    let wander = noise1(q.x * 1.6 + time * 0.03, 21.0);
    let edge = 0.16 + 0.10 * wander + 0.03 * noise1(q.x * 6.0 - time * 0.05, 22.0);
    let above = q.y - edge;
    let rays = 0.4 + 0.6 * noise1(q.x * 55.0 + wander * 8.0 + time * 0.15, 23.0);
    let curtain = smoothstep(-0.004, 0.006, above) * exp(-max(above, 0.0) * 7.0) * rays;
    let strength = smoothstep(0.2, 0.7, noise1(q.x * 0.9 - time * 0.02, 24.0));
    let tint = mix(vec3<f32>(0.15, 1.0, 0.45), vec3<f32>(0.75, 0.20, 0.85), smoothstep(0.0, 0.18, above));
    return base + tint * curtain * strength * 0.75;
}

fn palms(base: vec3<f32>, q: vec2<f32>, palette: Palette, soft: f32, time: f32) -> vec3<f32> {
    var colour = base;
    // A crescent moon: a disc with a disc taken out of it.
    let moon = vec2<f32>(-0.48, 0.33);
    let lit = (1.0 - smoothstep(0.055 - soft, 0.055 + soft, length(q - moon)))
            * smoothstep(0.050 - soft, 0.050 + soft, length(q - moon - vec2<f32>(0.022, 0.012)));
    colour = mix(colour, vec3<f32>(1.3, 1.15, 1.2), lit);
    colour += vec3<f32>(0.5, 0.4, 0.6) * 0.15 * exp(-length(q - moon) * 18.0);
    // Palms either side: a leaning trunk and a crown of drooping fronds.
    for (var index = 0; index < 3; index++) {
        let side = select(select(1.0, -1.0, index == 1), 0.78, index == 2);
        let foot = vec2<f32>(side * select(0.72, 0.55, index == 2), 0.0);
        let height = select(0.26, 0.17, index == 2);
        let lean = -sign(side) * 0.06;
        let sway = 0.004 * sin(time * 0.7 + f32(index));
        let rise = clamp(q.y / height, 0.0, 1.0);
        let trunkX = foot.x + (lean + sway) * rise * rise;
        let trunk = stroke(q.x - trunkX, 0.0045 * (1.0 - 0.4 * rise), soft) * step(q.y, height);
        let crown = vec2<f32>(foot.x + lean + sway, height);
        var frond = 0.0;
        for (var leaf = 0; leaf < 6; leaf++) {
            // Three fronds to a side, arching up then hanging; never straight
            // up, where a curve written as height-over-across has no answer.
            let toward = select(-1.0, 1.0, leaf >= 3);
            let rank = f32(leaf % 3);
            let reach = (0.075 + 0.025 * rank) * toward;
            let lift = 0.030 - 0.012 * rank;
            let droop = 0.055 + 0.03 * rank;
            let along = (q.x - crown.x) / reach;
            let curveY = crown.y + 2.0 * lift * along - (lift + droop) * along * along;
            // Leaflets: the blade's edge combed into a saw along its length.
            let blade = 0.0055 * sin(PI * clamp(along, 0.0, 1.0)) * (0.55 + 0.45 * fract(along * 13.0));
            frond = max(frond, stroke(q.y - curveY, blade, soft) * step(0.0, along) * step(along, 1.0));
        }
        colour = mix(colour, vec3<f32>(0.02, 0.01, 0.04), max(trunk, frond));
    }
    return colour;
}

fn eclipse(base: vec3<f32>, q: vec2<f32>, palette: Palette, soft: f32, time: f32) -> vec3<f32> {
    let offset = q - palette.sun.xy;
    let distance = length(offset);
    let radius = palette.sun.z;
    let angle = atan2(offset.y, offset.x);
    // Streamers: the corona combed outward, slowly turning.
    let streamers = 0.35 + 0.65 * noise1(angle * 6.0 / PI + time * 0.02, 31.0) * noise1(angle * 17.0 / PI - time * 0.03, 32.0) * 1.6;
    let outside = max(distance - radius, 0.0);
    // The long streamers fade over a whole stage height: on a desk with a
    // panel above, the corona climbs into it instead of stopping at the bezel.
    var colour = base + palette.accent * (exp(-outside * 40.0) * 0.6 + exp(-outside * 9.0) * 0.25 * streamers
                                          + exp(-outside * 2.2) * 0.05 * streamers * streamers) * step(radius, distance);
    colour += vec3<f32>(1.8, 1.4, 1.6) * stroke(distance - radius, 0.0009, soft);
    // A diamond-ring bead where the last of the sun shows past the moon.
    let bead = q - (palette.sun.xy + radius * vec2<f32>(cos(0.8), sin(0.8)));
    colour += vec3<f32>(2.0, 1.7, 1.8) * exp(-dot(bead, bead) / 0.00003);
    return colour;
}

// Everything beyond the floor at one stop: its landmark and its range.
fn horizonLayer(stop: i32, base: vec3<f32>, q: vec2<f32>, palette: Palette, soft: f32, time: f32) -> vec3<f32> {
    let fill = palette.zenith * 0.6 + vec3<f32>(0.004, 0.002, 0.008);
    switch stop {
        case 1: {
            var colour = mountains(base, q, 0.035, 2.0, palette.accent * 0.3, fill + palette.horizon * 0.04, soft);
            colour = pyramid(colour, q, 0.42, 0.40, 0.31, palette, soft, time);
            return pyramid(colour, q, 0.86, 0.20, 0.15, palette, soft, time);
        }
        case 2: {
            let colour = mountains(base, q, 0.07, 3.0, palette.sky * 0.4, mix(base, palette.sky * 0.3, 0.6), soft);
            return city(colour, q, palette, soft, time);
        }
        case 3: {
            let colour = ring(base, q, palette, soft, time);
            return mountains(colour, q, 0.08, 4.0, palette.grid * 0.8, fill, soft);
        }
        case 4: {
            let colour = planet(base, q, palette, soft, time);
            return mountains(colour, q, 0.10, 5.0, palette.accent * 0.7, fill, soft);
        }
        case 5: {
            let colour = mountains(base, q, 0.05, 6.0, palette.accent * 0.5, fill, soft);
            return spires(colour, q, palette, soft, time);
        }
        case 6: {
            let colour = aurora(base, q, soft, time);
            return mountains(colour, q, 0.19, 7.0, palette.accent, fill, soft);
        }
        case 7: {
            let colour = mountains(base, q, 0.05, 8.0, palette.grid * 0.6, palette.sky * 0.25, soft);
            return palms(colour, q, palette, soft, time);
        }
        case 8: {
            let colour = eclipse(base, q, palette, soft, time);
            return mountains(colour, q, 0.11, 9.0, palette.accent * 0.8, fill, soft);
        }
        default: {
            return mountains(base, q, 0.14, 1.0, palette.accent, fill, soft);
        }
    }
}

// The whole distance at a point of the sky plane, for the two stops either
// side of the camera: the stop being left grows and fades as it is passed,
// the next one rises out of the haze from smaller.
fn beyond(q: vec2<f32>, stopA: i32, stopB: i32, progress: f32, palette: Palette, soft: f32, time: f32) -> vec3<f32> {
    let sky = skyColour(palette, q, soft, time);
    let reveal = smoothstep(0.1, 0.9, progress);
    let nearScale = 1.0 + 0.9 * progress;
    var colour = horizonLayer(stopA, sky, q / nearScale, stopPalette(stopA), soft / nearScale, time);
    // Only mid-switch is there a second stop to draw; at rest this is skipped.
    if (reveal > 0.0) {
        let farScale = 0.6 + 0.4 * progress;
        let next = horizonLayer(stopB, sky, q / farScale, stopPalette(stopB), soft / farScale, time);
        colour = mix(colour, next, reveal);
    }
    return colour;
}

// Coverage of grid lines along one axis of cells, filtered for the pixel's
// footprint `footprint` (cells) so the distance converges to the lines' average
// instead of shimmering. `smear` widens them along the travel at speed.
fn gridLines(coordinate: f32, footprint: f32, halfWidth: f32, smear: f32) -> f32 {
    let distance = abs(fract(coordinate + 0.5) - 0.5);
    let drawnWidth = max(max(halfWidth, footprint * 0.75), smear);
    let core = 1.0 - smoothstep(drawnWidth - footprint * 0.5, drawnWidth + footprint * 0.5, distance);
    let energy = halfWidth / drawnWidth;               // a thin far line is dimmer, not fatter
    let glow = exp(-distance / 0.05) * 0.18 * (halfWidth / max(halfWidth, smear));
    let resolved = core * energy + glow * (1.0 - smoothstep(0.1, 0.4, footprint));
    return mix(resolved, 2.0 * halfWidth + 0.02, smoothstep(0.25, 0.6, footprint));
}

// THE HIGH SKY: what a monitor above the stage sees -- the upper panel of a
// stacked pair, the tops of two tall screens beside a laptop. It is quieter
// than the stage on purpose (the eye belongs below it) but not empty: night
// deepening with height, a milky way across it, a meteor now and then, and
// for some stops the upper reaches of their landmark. All of it fades in
// between 0.3 and 0.6, so the stage's own sky -- and the overview's cells --
// stay as composed. Only the sky branch calls it; the floor's reflection never
// looks this high.
fn highLandmark(stop: i32, base: vec3<f32>, q: vec2<f32>, palette: Palette, time: f32) -> vec3<f32> {
    switch stop {
        case 3: {
            // The gate's builders: an orbital ring arching over the whole sky,
            // too high to cross the stage, with one light running round it.
            let centre = vec2<f32>(0.0, -0.25);
            let radii = vec2<f32>(2.7, 1.40);
            let offset = (q - centre) / radii;
            let distance = (length(offset) - 1.0) * radii.y;
            let angle = atan2(offset.y, offset.x);
            let segment = 0.6 + 0.4 * stroke(fract(angle * 60.0 / PI + 0.5) - 0.5, 0.35, 0.1);
            var colour = base + palette.accent * (0.45 * exp(-abs(distance) / 0.0018) * segment + 0.035 * exp(-abs(distance + 0.025) / 0.03));
            let chase = pow(0.5 + 0.5 * cos(angle - 1.2 - 0.25 * sin(time * 0.05)), 400.0);
            return colour + palette.accent * 2.0 * chase * exp(-abs(distance) / 0.003);
        }
        case 4: {
            // The planet's moons, high up, lit from the same low sun.
            var colour = base;
            for (var index = 0; index < 2; index++) {
                let centre = select(vec2<f32>(-0.95, 0.88), vec2<f32>(1.25, 1.18), index == 1);
                let radius = select(0.042, 0.022, index == 1);
                let offset = q - centre;
                let disc = 1.0 - smoothstep(radius - 0.0015, radius + 0.0015, length(offset));
                let sphere = vec3<f32>(offset / radius, sqrt(max(1.0 - dot(offset, offset) / (radius * radius), 0.0)));
                let light = max(dot(sphere, normalize(vec3<f32>(-0.7, -0.45, 0.55))), 0.0);
                let surface = vec3<f32>(0.35, 0.45, 0.50) * (0.02 + 0.8 * light) * (0.8 + 0.2 * noise1(offset.x / radius * 4.0 + offset.y / radius * 9.0, 60.0 + f32(index)));
                colour = mix(colour, surface, disc);
            }
            return colour;
        }
        case 6: {
            // A second, higher aurora: thinner, slower, more violet.
            // Its foot folds and wanders far more than the low one's, so it
            // reads as drapery rather than a stripe ruled across the panel.
            let fold = noise1(q.x * 1.4 + time * 0.02, 51.0);
            let edge = 0.62 + 0.26 * fold + 0.07 * noise1(q.x * 3.1 - time * 0.04, 52.0);
            let above = q.y - edge;
            let rays = 0.35 + 0.65 * noise1(q.x * 38.0 + fold * 6.0 + time * 0.1, 53.0);
            let curtain = smoothstep(-0.02, 0.03, above) * exp(-max(above, 0.0) * 6.0) * rays;
            let strength = smoothstep(0.3, 0.85, noise1(q.x * 1.1 - time * 0.015, 54.0));
            let tint = mix(vec3<f32>(0.15, 0.9, 0.5), vec3<f32>(0.6, 0.25, 0.9), smoothstep(0.0, 0.3, above));
            return base + tint * curtain * strength * 0.35;
        }
        default: { return base; }
    }
}

fn upperSky(base: vec3<f32>, q: vec2<f32>, stopA: i32, stopB: i32, progress: f32, palette: Palette, time: f32) -> vec3<f32> {
    let altitude = smoothstep(0.30, 0.60, q.y);
    var colour = base * mix(1.0, 0.6, smoothstep(0.5, 1.4, q.y));
    // The milky way: a tilted band of cloud split by a dark dust lane.
    let bandOffset = q.y - (0.98 + 0.20 * q.x + 0.05 * sin(q.x * 1.3));
    let profile = exp(-bandOffset * bandOffset / (0.18 * 0.18));
    if (profile > 0.02) {
        let cloud = fbm3(vec3<f32>(q * 2.6, time * 0.01), 4);
        let lane = smoothstep(0.4, 0.7, noise3(vec3<f32>(q.x * 1.6, bandOffset * 8.0 + 3.0, 5.0 + time * 0.006)))
                 * exp(-pow((bandOffset + 0.02) / 0.06, 2.0));
        let glow = profile * (0.3 + 1.2 * cloud * cloud) * (1.0 - 0.75 * lane);
        let tint = mix(vec3<f32>(0.55, 0.50, 0.80), palette.sky * 1.8 + vec3<f32>(0.10), 0.35);
        colour += tint * glow * 0.075 * altitude;
        // Its dust of faint stars, too fine to count.
        let spacing = 0.006;
        let cell = floor(q / spacing);
        let seed = vec3<f32>(cell, 71.0);
        let spot = (cell + 0.2 + 0.6 * vec2<f32>(hash3(seed + 1.0), hash3(seed + 2.0))) * spacing;
        let core = exp(-dot(q - spot, q - spot) / (0.0007 * 0.0007));
        colour += vec3<f32>(0.8, 0.8, 1.0) * core * step(1.0 - 0.6 * profile * (0.5 + cloud), hash3(seed)) * 0.35 * altitude;
    }
    // A meteor every six seconds or so, somewhere high, gone in under one.
    let period = 6.0;
    let epoch = floor(time / period);
    let elapsed = time - epoch * period;
    if (elapsed < 0.8) {
        let start = vec2<f32>(mix(-1.6, 1.6, hash3(vec3<f32>(epoch, 61.0, 1.0))), mix(0.7, 1.3, hash3(vec3<f32>(epoch, 61.0, 2.0))));
        let heading = normalize(vec2<f32>(select(-0.85, 0.85, hash3(vec3<f32>(epoch, 61.0, 3.0)) > 0.5), -0.5));
        let relative = q - (start + heading * elapsed * 0.9);
        let behind = -dot(relative, heading);
        let aside = abs(relative.x * heading.y - relative.y * heading.x);
        let streak = exp(-pow(aside / 0.0012, 2.0)) * step(0.0, behind) * exp(-behind / 0.10) * (1.0 - elapsed / 0.8);
        colour += vec3<f32>(1.3, 1.2, 1.4) * streak * altitude;
    }
    // The stops' high landmarks, crossing over and swelling as a switch
    // passes them, the same as the horizon's. Faded in with altitude like
    // everything else here: the orbital ring dips below 0.3 out past the
    // stage's edges, and on the screens beside a laptop it was cut off there
    // along a ruled line.
    let reveal = smoothstep(0.1, 0.9, progress);
    let sky = colour;
    colour = mix(sky, highLandmark(stopA, sky, q / (1.0 + 0.9 * progress), stopPalette(stopA), time), altitude);
    if (reveal > 0.0) {
        let next = mix(sky, highLandmark(stopB, sky, q / (0.6 + 0.4 * progress), stopPalette(stopB), time), altitude);
        colour = mix(colour, next, reveal);
    }
    return colour;
}

fn scene(position: f32, point: vec2<f32>, motion: f32, time: f32) -> vec3<f32> {
    let place = position - floor(position / 9.0) * 9.0;      // 0..9, so 9.0 is 0.0
    let stopA = i32(floor(place)) % 9;
    let stopB = (stopA + 1) % 9;
    let progress = fract(place);
    let palette = mixPalette(stopPalette(stopA), stopPalette(stopB), smoothstep(0.1, 0.9, progress));

    // The camera: a level pinhole, the field of view kicking wider and the eye
    // dipping toward the floor at the peak of a surge.
    let focal = FOCAL * (1.0 - 0.18 * motion);
    // THE FRAME: scene units are home-monitor heights from its centre
    // (layout.rs), so the floor, sun and landmark are composed for that
    // monitor on every desk. The other monitors are one projection with it:
    // the horizon and the floor run on across them without a seam, and on a
    // laptop between two large screens they see much wider.
    let framed = point;
    let q = vec2<f32>(framed.x, framed.y - HORIZON) / focal;
    let soft = max(fwidth(q.y), 1e-5);

    // The floor: a ray-plane hit. Depth and across, in grid cells.
    let eyeHeight = EYE_HEIGHT * (1.0 - 0.10 * motion);
    let depth = eyeHeight / max(-q.y, 1e-4);
    let across = q.x * depth;
    // Travel: whole cells per stop, plus a slow drift kept small for precision.
    let drift = time * 1.2 - floor(time * 1.2 / TRAIL_PERIOD) * TRAIL_PERIOD;
    let travel = place * STEP_CELLS;
    let along = travel + drift + depth;
    // Derivatives come before any branch, where every pixel takes them.
    let acrossFootprint = fwidth(across);
    let depthFootprint = fwidth(depth);

    if (q.y > 0.0) {
        var colour = beyond(q, stopA, stopB, progress, palette, soft, time) + stars(q, time);
        if (q.y > 0.3) { colour = upperSky(colour, q, stopA, stopB, progress, palette, time); }
        colour += palette.horizon * 0.25 * motion * exp(-q.y * 30.0);    // the horizon flares as you surge
        return colour;
    }

    // Speed smears the cross lines along the travel: half a frame's worth, a
    // film camera's shutter. A whole frame floods the floor into one colour.
    let smear = STEP_CELLS * motion * 0.008;
    let lines = gridLines(across, acrossFootprint, 0.02, 0.0) + gridLines(along, depthFootprint, 0.02, smear);

    // Light trails: vehicles on a few lanes, each a hot head and a fading tail.
    let lane = round(across / 4.0);
    let laneHash = hash3(vec3<f32>(lane, 41.0, 3.0));
    let heading = select(-1.0, 1.0, laneHash > 0.5);
    let speed = 8.0 + 14.0 * fract(laneHash * 13.0);
    let travelled = speed * time / TRAIL_PERIOD;
    let headZ = (travelled - floor(travelled) + fract(laneHash * 7.0)) * TRAIL_PERIOD;
    let behind = fract(heading * (headZ - along) / TRAIL_PERIOD) * TRAIL_PERIOD;
    let tailLength = 10.0 + 8.0 * fract(laneHash * 29.0);
    let tail = select(0.0, pow(1.0 - behind / tailLength, 2.5), behind < tailLength);
    let trailWidth = gridLines(across / 4.0, acrossFootprint / 4.0, 0.012, 0.0) * step(0.4, fract(laneHash * 91.0));
    let trailColour = select(palette.accent, vec3<f32>(1.6, 0.35, 0.15), fract(laneHash * 53.0) > 0.6);
    let trail = trailColour * trailWidth * tail * 2.2;

    // Gloss: the distance mirrored in the floor, stretched downward and
    // blurred, strongest at grazing angles as a real sheen is.
    let mirrored = vec2<f32>(q.x, -q.y * 0.8);
    let reflection = beyond(mirrored, stopA, stopB, progress, palette, soft * 3.0 + 0.004, time);
    let grazing = exp(q.y * 24.0);
    // Whole waves per trail period, so the drift's wrap leaves no seam in it.
    let ripple = 0.85 + 0.15 * sin(along * 2.0 * PI * 13.0 / TRAIL_PERIOD) * sin(along * 2.0 * PI * 5.0 / TRAIL_PERIOD + 1.0);
    var colour = palette.zenith * 0.3 + reflection * (0.02 + 0.40 * grazing) * ripple;
    // The sun's own path on the floor: a streak narrowing toward the viewer.
    let path = exp(-abs(q.x - palette.sun.x) / (0.02 + 0.10 * palette.sun.z * exp(q.y * 6.0))) * exp(q.y * 5.0);
    colour += palette.sunBottom * 0.10 * path * step(0.0, palette.sun.y) * ripple;
    colour += palette.grid * lines * 0.9 + trail;
    // Haze toward the horizon, in its colour.
    let haze = 1.0 - exp(-depth * 0.006);
    colour = mix(colour, palette.horizon * 0.30 + palette.sunBottom * 0.05, haze * 0.85);
    colour += palette.horizon * 0.25 * motion * exp(q.y * 30.0);
    return colour;
}

fn backdrop(point: vec2<f32>, time: f32) -> vec3<f32> {
    // The overview's surround: the night above the grid, nearly black, with a
    // faint glow from below and a few stars.
    let glow = exp(-(point.y + 0.5) * 3.0) * vec3<f32>(0.05, 0.01, 0.05);
    return vec3<f32>(0.006, 0.003, 0.014) + glow + stars(point + vec2<f32>(0.0, 0.3), time) * 0.4;
}
