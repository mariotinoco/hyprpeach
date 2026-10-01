// NEBULA: drifting through the inside of a vast emission nebula, in Hubble and
// JWST colour. Each desktop is a different region of it, with its own colouring
// and its own landmark -- backlit pillars, a young star cluster, a dust lane,
// a blown shell -- so desktop 1 and desktop 5 are told apart at a glance.
//
// No ray marching; two kinds of layer, each a few octaves of 2D-sliced noise:
//  * THE FAR NEBULA: one picture per region, too far away for a desktop's
//    worth of flight to move it. A switch cross-fades from one region's picture
//    to the next while both swell toward the viewer.
//  * NEAR PLANES of thin gas, dust and stars, standing at fixed places along
//    the line of flight. The camera flies one unit forward per desktop, so a
//    switch carries it through four of them: near ones swell and stream past,
//    far ones barely move, and the stars on them streak briefly at the peak.
// The flight closes on itself: the planes' places and identities repeat every
// nine units of flight, so position 9.0 is position 0.0.

const NEBULA_PILLARS: i32 = 0;
const NEBULA_CLUSTER: i32 = 1;
const NEBULA_LANE: i32 = 2;
const NEBULA_SHELL: i32 = 3;
const NEBULA_CLIFFS: i32 = 4;

// One region of the nebula: what a desktop looks out on.
struct Region {
    core: vec3<f32>,    // the hot ionised gas nearest the landmark
    outer: vec3<f32>,   // the cooler gas toward the edges of the view
    dust: vec3<f32>,    // the reddened light that dust lets through or scatters
    centre: vec2<f32>,  // where on the desk the landmark sits, desk heights
    kind: i32,          // which landmark: NEBULA_PILLARS, _CLUSTER, _LANE, _SHELL, _CLIFFS
    lean: f32,          // radians: the tilt of a lane or of the pillars
};

// The nine regions, in the order the flight visits them. Neighbours differ in
// both hue and landmark so that no two adjacent desktops read alike.
fn region(index: i32) -> Region {
    switch index {
        // Pillars of Creation: teal oxygen above amber-brown columns.
        case 0: { return Region(vec3<f32>(0.20, 0.85, 0.80), vec3<f32>(0.90, 0.48, 0.16), vec3<f32>(0.55, 0.25, 0.10), vec2<f32>(0.10, 0.22), NEBULA_PILLARS, 0.08); }
        // A young blue cluster carving a magenta hydrogen cloud.
        case 1: { return Region(vec3<f32>(1.00, 0.25, 0.55), vec3<f32>(0.30, 0.16, 0.70), vec3<f32>(0.50, 0.10, 0.20), vec2<f32>(-0.35, 0.05), NEBULA_CLUSTER, 0.0); }
        // Gold gas split by one great dark lane.
        case 2: { return Region(vec3<f32>(1.00, 0.66, 0.26), vec3<f32>(0.60, 0.20, 0.08), vec3<f32>(0.45, 0.20, 0.06), vec2<f32>(0.20, -0.05), NEBULA_LANE, 0.55); }
        // A blown shell: an oxygen-green ring rimmed in hydrogen red.
        case 3: { return Region(vec3<f32>(0.20, 0.90, 0.60), vec3<f32>(0.95, 0.16, 0.12), vec3<f32>(0.40, 0.10, 0.08), vec2<f32>(0.25, 0.02), NEBULA_SHELL, 0.0); }
        // Cosmic Cliffs: an orange ridge under a blue sky.
        case 4: { return Region(vec3<f32>(0.30, 0.55, 1.00), vec3<f32>(1.00, 0.45, 0.15), vec3<f32>(0.60, 0.28, 0.10), vec2<f32>(-0.20, 0.35), NEBULA_CLIFFS, -0.06); }
        // A Pleiades-like cluster in blue reflection haze.
        case 5: { return Region(vec3<f32>(0.40, 0.62, 1.00), vec3<f32>(0.08, 0.16, 0.45), vec3<f32>(0.20, 0.20, 0.35), vec2<f32>(0.30, 0.08), NEBULA_CLUSTER, 0.0); }
        // Rose-crimson gas with a lane sloping the other way.
        case 6: { return Region(vec3<f32>(1.00, 0.30, 0.32), vec3<f32>(0.45, 0.08, 0.35), vec3<f32>(0.50, 0.12, 0.10), vec2<f32>(-0.15, 0.0), NEBULA_LANE, -0.45); }
        // A violet shell around a hot white dwarf, cyan at its heart.
        case 7: { return Region(vec3<f32>(0.30, 0.80, 1.00), vec3<f32>(0.62, 0.28, 1.00), vec3<f32>(0.30, 0.12, 0.40), vec2<f32>(-0.30, -0.02), NEBULA_SHELL, 0.0); }
        // An old gold globular cluster in teal gas.
        default: { return Region(vec3<f32>(1.00, 0.82, 0.55), vec3<f32>(0.10, 0.45, 0.48), vec3<f32>(0.35, 0.25, 0.12), vec2<f32>(0.05, 0.05), NEBULA_CLUSTER, 0.0); }
    }
}

fn rotated(vector: vec2<f32>, angle: f32) -> vec2<f32> {
    let cosine = cos(angle); let sine = sin(angle);
    return vec2<f32>(cosine * vector.x - sine * vector.y, sine * vector.x + cosine * vector.y);
}

fn starTint(seed: f32) -> vec3<f32> {
    // Blue-white through to orange, weighted toward white: real colour, not paint.
    return mix(vec3<f32>(0.70, 0.80, 1.00), vec3<f32>(1.00, 0.80, 0.58), seed * seed);
}

// A field of faint stars, one chance per cell, too small to need neighbours.
// `cellSize` in desk heights; `chance` the share of cells that hold one.
fn starField(point: vec2<f32>, cellSize: f32, chance: f32, seed: f32, radius: f32) -> vec3<f32> {
    let grid = point / cellSize;
    let cell = floor(grid);
    let roll = hash3(vec3<f32>(cell, seed));
    if (roll > chance) { return vec3<f32>(0.0); }
    let spot = (cell + 0.2 + 0.6 * vec2<f32>(hash3(vec3<f32>(cell, seed + 1.0)), hash3(vec3<f32>(cell, seed + 2.0)))) * cellSize;
    let offset = point - spot;
    let strength = roll / chance;
    // Most stars are faint and a few are bright: the steep power gives that.
    let brightness = 0.04 + 2.5 * pow(strength, 14.0);
    return starTint(fract(strength * 37.0)) * brightness * exp(-dot(offset, offset) / (radius * radius));
}

// A few bright foreground stars a region, with the four diffraction spikes of
// a telescope's secondary-mirror vanes -- thin and faint, or they read as toys.
fn brightStars(point: vec2<f32>, seed: f32) -> vec3<f32> {
    let cellSize = 0.42;
    let cell = floor(point / cellSize);
    var light = vec3<f32>(0.0);
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let neighbour = cell + vec2<f32>(f32(x), f32(y));
            let roll = hash3(vec3<f32>(neighbour, seed + 40.0));
            if (roll > 0.22) { continue; }
            let spot = (neighbour + 0.15 + 0.7 * vec2<f32>(hash3(vec3<f32>(neighbour, seed + 41.0)), hash3(vec3<f32>(neighbour, seed + 42.0)))) * cellSize;
            let offset = point - spot;
            let strength = 0.4 + roll / 0.22;
            let distanceSquared = dot(offset, offset);
            let core = exp(-distanceSquared / 0.0000016) * 6.0 + exp(-distanceSquared / 0.00008) * 0.25;
            let spikeLength = 0.05 * strength;
            let thickness = 0.0005;
            let spikes = exp(-abs(offset.x) / spikeLength) * exp(-offset.y * offset.y / (thickness * thickness))
                       + exp(-abs(offset.y) / spikeLength) * exp(-offset.x * offset.x / (thickness * thickness));
            light += starTint(fract(roll * 53.0)) * strength * (core + spikes * 0.35);
        }
    }
    return light;
}

// The outline of a pillar region's columns, or a cliff region's ridge, as a
// rough signed distance in desk heights (negative inside). `local` is measured
// from the bottom of the desk, x across and y up, already leaned.
fn landmarkShape(local: vec2<f32>, kind: i32, seed: f32) -> f32 {
    if (kind == NEBULA_CLIFFS) {
        // One ragged ridge: a few sines are enough, the noise erodes it later.
        let ridge = 0.32 + 0.10 * sin(local.x * 3.1 + seed) + 0.05 * sin(local.x * 7.3 + seed * 2.0) + 0.025 * sin(local.x * 17.0);
        return (local.y - ridge) * 0.7;
    }
    // Three columns tapering out of a dust bank, each swelling into a head.
    var outline = local.y - 0.08 - 0.04 * sin(local.x * 5.0 + seed);
    for (var column = 0; column < 3; column++) {
        let pick = f32(column) * 3.1 + seed;
        let height = 0.40 + 0.45 * hash3(vec3<f32>(pick, 1.0, 5.0));
        let width = 0.06 + 0.05 * hash3(vec3<f32>(pick, 2.0, 5.0));
        let base = (f32(column) - 1.0) * 0.45 + (hash3(vec3<f32>(pick, 3.0, 5.0)) - 0.5) * 0.2;
        let rise = clamp(local.y / height, 0.0, 1.0);
        let middle = base + 0.08 * sin(local.y * 3.0 + pick) * rise;
        let halfWidth = width * (1.0 - 0.6 * rise) + width * 0.35 * exp(-pow((rise - 0.9) / 0.12, 2.0));
        let side = abs(local.x - middle) - halfWidth;
        let cap = length(vec2<f32>(local.x - middle, max(local.y - height, 0.0))) - halfWidth;
        outline = min(outline, select(side, cap, local.y > height));
    }
    return outline;
}

// The far nebula of one region, as seen from its desktop at rest.
fn farNebula(point: vec2<f32>, index: i32, time: f32) -> vec3<f32> {
    let place = region(index);
    let seed = f32(index) * 9.17 + 3.0;
    // Ambient life: the gas evolves in place (the noise's third axis) rather
    // than sliding, so each region keeps its composition all day.
    let evolve = time * 0.004;
    let warp = vec2<f32>(fbm3(vec3<f32>(point * 1.1, seed + evolve), 2),
                         fbm3(vec3<f32>(point * 1.1 + 5.2, seed + 2.7 + evolve), 2)) - 0.5;
    let warped = point + warp * 0.9;
    let density = fbm3(vec3<f32>(warped * 1.8, seed + 7.0 + evolve), 6);
    let fromCentre = point - place.centre;
    let reach = length(fromCentre);
    // The landmark's own light: the stars that ionise the gas around it.
    let glow = exp(-reach * reach / 0.22);

    let gas = smoothstep(0.36, 0.70, density);
    // Bright rims where the density crosses its middle: the shock fronts and
    // ionisation fronts that make a Hubble picture look sculpted.
    let front = pow(1.0 - abs(density * 2.0 - 1.0), 16.0);
    let heat = clamp(glow * 1.2 + (density - 0.5) * 0.9, 0.0, 1.0);
    let tint = mix(place.outer, place.core, heat);
    var colour = tint * (gas * gas * (0.05 + 0.65 * glow) + front * 0.10 * (0.25 + glow));
    colour += place.core * glow * glow * 0.06;
    colour += vec3<f32>(0.010, 0.012, 0.022);

    // Dust: patchy everywhere, and one great lane in a lane region.
    let dustNoise = fbm3(vec3<f32>(rotated(warped, place.lean) * vec2<f32>(3.6, 2.2) + 1.7, seed + 13.0 + evolve), 4);
    var absorb = smoothstep(0.50, 0.74, dustNoise) * 0.8;
    if (place.kind == NEBULA_LANE) {
        let across = dot(fromCentre, vec2<f32>(-sin(place.lean), cos(place.lean))) + (dustNoise - 0.5) * 0.4;
        absorb = max(absorb, exp(-across * across / 0.010) * 0.97);
    }
    // Fewer stars where the gas is thin: a uniform field reads as noise.
    var stars = starField(point, 0.0055, 0.12 + 0.35 * gas, seed + 60.0, 0.0006);
    colour = colour * (1.0 - absorb) + place.dust * absorb * gas * 0.025;

    if (place.kind == NEBULA_PILLARS || place.kind == NEBULA_CLIFFS) {
        // A body of dense dust standing in front of the bright gas. Its shape
        // is analytic and cheap; its edge is eroded by two scales of noise,
        // which is what turns a silhouette into a pillar.
        let local = rotated(point - vec2<f32>(place.centre.x, -0.5), place.lean);
        let towardLight = rotated(normalize(place.centre - point + vec2<f32>(0.0, 0.001)), place.lean);
        let shape = landmarkShape(local, place.kind, seed);
        // Which way the surface faces: a step toward the light that leaves the
        // body means this edge is the lit one.
        let facing = clamp((landmarkShape(local + towardLight * 0.02, place.kind, seed) - shape) / 0.02, 0.0, 1.0);
        let fray = fbm3(vec3<f32>(point * 7.0, seed + 29.0 + evolve), 3);
        let fine = fbm3(vec3<f32>(point * 26.0, seed + 31.0), 2);
        let outline = shape + (fray - 0.5) * 0.15 + (fine - 0.5) * 0.05;
        let inside = smoothstep(0.003, -0.003, outline);
        let skin = exp(min(outline, 0.0) / 0.007) * inside * facing;
        let boil = exp(-max(outline, 0.0) / 0.018) * (1.0 - inside) * facing;
        let light = 0.35 + glow;
        let deep = exp(min(outline, 0.0) / 0.10);
        let texture = smoothstep(0.35, 0.75, fine * 0.5 + fray * 0.7 - 0.1);
        var body = place.dust * (0.006 + 0.16 * texture * deep * (0.15 + facing)) * light;
        if (place.kind == NEBULA_CLIFFS) { body = place.outer * (0.010 + 0.30 * texture * deep * (0.4 + facing)) * light; }
        colour = mix(colour, body, inside)
               + mix(place.outer, place.core, 0.35) * skin * light * 0.6
               + place.core * boil * 0.10 * light;
        absorb = max(absorb, inside);
    }
    if (place.kind == NEBULA_SHELL) {
        // A bubble blown by one hot star's wind: the gas inside swept out, the
        // swept-up gas a thin, broken skin brightest on one side. A filled
        // glowing disc would read as a planet, which this is not.
        let radius = 0.34;
        colour *= mix(0.07, 1.0, smoothstep(radius * 0.6, radius * 1.05, reach));
        let shellDistance = reach - radius + (density - 0.5) * 0.12;
        let shell = exp(-shellDistance * shellDistance / 0.0005);
        let broken = smoothstep(0.38, 0.62, density) * (0.35 + 0.65 * smoothstep(-0.6, 1.0, dot(fromCentre / max(reach, 0.001), vec2<f32>(0.6, 0.8))));
        let edge = mix(place.core, place.outer, smoothstep(-0.02, 0.03, shellDistance));
        colour += edge * shell * broken * (0.35 + 1.2 * front);
        colour += vec3<f32>(0.85, 0.92, 1.0) * exp(-reach * reach / 0.000004) * 6.0;
    }
    if (place.kind == NEBULA_CLUSTER) {
        // Hundreds of young stars packed into a knot, and the unresolved
        // light of the rest as a soft glow.
        let crowd = exp(-reach * reach / 0.035);
        stars += starField(point, 0.009, 0.08 + 0.75 * crowd, seed + 80.0, 0.0008) * (0.5 + 2.5 * crowd);
        // Its brightest members, few and strong, so the knot reads even small.
        stars += starField(point, 0.03, 0.55 * crowd, seed + 90.0, 0.0012) * 4.0 * crowd;
        colour += mix(vec3<f32>(0.75, 0.85, 1.0), place.core, 0.4) * (crowd * 0.20 + exp(-reach * reach / 0.004) * 0.35);
    }
    colour += stars * (1.0 - absorb);
    colour += brightStars(point, seed);
    return colour;
}

const NEBULA_SPACING: f32 = 0.25;     // units of flight between near planes
const NEBULA_PLANES: i32 = 6;         // planes in view: 1.5 units deep
const NEBULA_SLOTS: f32 = 36.0;       // planes a lap: 9 desktops / spacing

// The stars standing on one near plane, streaked during a switch. A star's
// trail runs from it back toward the centre of the view, since flying forward
// pushes everything outward; so a pixel can only be reached by a star in its
// own cell or the next one outward, and only those four cells are looked at.
fn planeStars(point: vec2<f32>, depth: f32, identity: f32, motion: f32) -> vec3<f32> {
    let scale = 22.0;
    let planeCoordinate = point * depth * scale;
    let cell = floor(planeCoordinate);
    let outward = select(vec2<f32>(-1.0), vec2<f32>(1.0), planeCoordinate >= vec2<f32>(0.0));
    let reach = select(0, 1, motion > 0.02);
    // Screen speed of a star is its distance from the centre over its depth.
    let streak = min(motion * motion * 0.07 / depth, 0.9);
    let radius = 0.0008;
    var light = vec3<f32>(0.0);
    for (var y = 0; y <= reach; y++) {
        for (var x = 0; x <= reach; x++) {
            let neighbour = cell + outward * vec2<f32>(f32(x), f32(y));
            let roll = hash3(vec3<f32>(neighbour, identity * 7.0 + 101.0));
            if (roll > 0.30) { continue; }
            let jitter = vec2<f32>(hash3(vec3<f32>(neighbour, identity * 7.0 + 102.0)), hash3(vec3<f32>(neighbour, identity * 7.0 + 103.0)));
            let starPlace = neighbour + 0.15 + 0.7 * jitter;
            let head = starPlace / (depth * scale);
            // The trail never reaches past the next cell, or it would be cut off.
            var tail = head * streak;
            let tailLength = length(tail);
            let longest = 0.9 / (depth * scale);
            if (tailLength > longest) { tail = tail * (longest / tailLength); }
            let fromTail = point - (head - tail);
            let along = clamp(dot(fromTail, tail) / max(dot(tail, tail), 1e-12), 0.0, 1.0);
            let gap = fromTail - tail * along;
            let strength = roll / 0.30;
            let brightness = (0.05 + 1.6 * pow(strength, 10.0)) * (1.0 + 0.6 / (depth + 0.2));
            // A streak spreads the same light over its length, brightest at the head.
            let spread = radius / (radius + length(tail) * 0.25) * mix(1.0, 0.2 + 0.8 * along, min(streak * 4.0, 1.0));
            light += starTint(fract(strength * 29.0)) * brightness * spread * exp(-dot(gap, gap) / (radius * radius));
        }
    }
    return light;
}

fn scene(position: f32, point: vec2<f32>, motion: f32, time: f32) -> vec3<f32> {
    let wrapped = position - 9.0 * floor(position / 9.0);
    let index = floor(wrapped);
    let progress = smoothstep(0.25, 0.75, wrapped - index);
    let current = i32(index) % 9;
    let next = (current + 1) % 9;

    // The far picture: the region being left swells and fades, the next one
    // grows in from further off. Each is drawn only while it shows.
    var colour = vec3<f32>(0.0);
    if (progress < 0.999) { colour += farNebula(point / (1.0 + 1.4 * progress), current, time) * (1.0 - progress); }
    if (progress > 0.001) { colour += farNebula(point * (1.0 + 0.7 * (1.0 - progress)), next, time) * progress; }

    // The near planes, back to front. Their places along the flight are
    // whole multiples of the spacing; a plane's identity is its slot in the
    // lap, so the plane passed at 8.75 is the one ahead again at -0.25.
    let first = floor(wrapped / NEBULA_SPACING) + 1.0;
    for (var i = NEBULA_PLANES - 1; i >= 0; i--) {
        let slot = first + f32(i);
        let depth = slot * NEBULA_SPACING - wrapped;
        let identity = slot - NEBULA_SLOTS * floor(slot / NEBULA_SLOTS);
        let fade = smoothstep(0.0, 0.35, depth) * smoothstep(f32(NEBULA_PLANES) * NEBULA_SPACING, 1.05, depth);
        // The gas takes the colour of the region it stands in.
        let along = identity * NEBULA_SPACING;
        let home = i32(floor(along)) % 9;
        let blend = smoothstep(0.5, 1.0, fract(along));
        let tint = mix(mix(region(home).outer, region(home).core, 0.4), mix(region((home + 1) % 9).outer, region((home + 1) % 9).core, 0.4), blend);
        let offset = vec2<f32>(hash3(vec3<f32>(identity, 1.0, 0.0)), hash3(vec3<f32>(identity, 2.0, 0.0))) * 50.0;
        let cloud = fbm3(vec3<f32>(point * depth * 2.4 + offset, identity * 1.7), 3);
        if (i32(identity) % 2 == 0) {
            colour += tint * smoothstep(0.52, 0.85, cloud) * 0.07 * fade;
        } else {
            colour *= 1.0 - smoothstep(0.52, 0.80, cloud) * 0.55 * fade;
        }
        colour += planeStars(point, depth, identity, motion) * fade;
    }
    return colour;
}

fn backdrop(point: vec2<f32>, time: f32) -> vec3<f32> {
    let haze = fbm3(vec3<f32>(point * 1.5, 5.0 + time * 0.003), 3);
    return vec3<f32>(0.006, 0.007, 0.014) + vec3<f32>(0.02, 0.012, 0.03) * haze * haze
         + starField(point, 0.007, 0.3, 211.0, 0.0006) * 0.5;
}
