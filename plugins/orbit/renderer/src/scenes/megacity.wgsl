// MEGACITY: a night city of endless towers seen from an air-traffic lane, in
// fog and rain-haze lit from below. The camera flies sideways along a lane that
// closes on itself; the nine desktops are nine districts along it, each with its
// own palette and a landmark at its centre.
//
// Mechanism: no ray march. The city is a stack of flat layers of towers at
// growing depths (2.5D parallax). A layer is a 1D hashed skyline in world units,
// so near layers sweep past faster than far ones for free. Layers are walked
// near to far and the first tower hit is shaded and fogged; traffic lanes are
// glowing dots on lines between layers. A pixel costs at most a dozen hashes
// for the layers and a few for traffic.

const LANE_STEP: f32 = 80.0;      // world units between desktops along the lane
const LANE_LENGTH: f32 = 720.0;   // nine steps: the lane closes, so position 9 is 0
const LAYER_COUNT: i32 = 12;
const LANDMARK_LAYER: i32 = 8;    // the layer whose skyline carries each district's landmark
const HORIZON: f32 = 0.08;        // where eye level sits on the desk, in desk heights

fn layerDepth(layer: i32) -> f32 { return 4.0 * pow(1.38, f32(layer)); }

// Three hashes from three whole numbers in one pcg3d round.
fn hashes(a: f32, b: f32, c: f32) -> vec3<f32> {
    return vec3<f32>(pcg3d(bitcast<vec3<u32>>(vec3<i32>(floor(vec3<f32>(a, b, c)))))) / 4294967295.0;
}

// A cell index wrapped into 0..count, so the city repeats every LANE_LENGTH.
fn wrapIndex(index: f32, count: f32) -> f32 { return index - count * floor(index / count); }

struct District {
    window: vec3<f32>,    // the colour most lit windows burn
    neon: vec3<f32>,      // this district's signature sign colour
    fogLow: vec3<f32>,    // the glow of the haze from the streets far below
    fogHigh: vec3<f32>,   // the haze at and above eye level
};

fn district(index: i32) -> District {
    switch (index) {
        // 1: sodium streets under teal haze; a pyramid arcology.
        case 0: { return District(vec3(1.0, 0.6, 0.28), vec3(0.1, 0.9, 1.0), vec3(0.05, 0.17, 0.16), vec3(0.012, 0.022, 0.03)); }
        // 2: the magenta pleasure district; a giant hologram.
        case 1: { return District(vec3(0.95, 0.55, 0.85), vec3(1.0, 0.08, 0.55), vec3(0.13, 0.025, 0.11), vec3(0.025, 0.008, 0.03)); }
        // 3: amber smog, like 2049's Las Vegas; a needle spire.
        case 2: { return District(vec3(1.0, 0.55, 0.2), vec3(1.0, 0.42, 0.04), vec3(0.19, 0.08, 0.02), vec3(0.045, 0.02, 0.008)); }
        // 4: cold cyan finance towers; twin towers joined by skybridges.
        case 3: { return District(vec3(0.6, 0.85, 1.0), vec3(0.15, 0.7, 1.0), vec3(0.03, 0.09, 0.17), vec3(0.006, 0.014, 0.032)); }
        // 5: crimson industrial; a stepped ziggurat.
        case 4: { return District(vec3(1.0, 0.42, 0.25), vec3(1.0, 0.08, 0.04), vec3(0.18, 0.035, 0.03), vec3(0.03, 0.008, 0.01)); }
        // 6: toxic green; a needle wearing a ring.
        case 5: { return District(vec3(0.75, 1.0, 0.6), vec3(0.3, 1.0, 0.35), vec3(0.05, 0.15, 0.06), vec3(0.008, 0.022, 0.012)); }
        // 7: violet; a domed senate.
        case 6: { return District(vec3(0.8, 0.65, 1.0), vec3(0.6, 0.25, 1.0), vec3(0.1, 0.05, 0.19), vec3(0.016, 0.01, 0.036)); }
        // 8: white and blue, Coruscant; a monolith slab.
        case 7: { return District(vec3(0.85, 0.9, 1.0), vec3(0.3, 0.5, 1.0), vec3(0.06, 0.08, 0.17), vec3(0.014, 0.02, 0.042)); }
        // 9: gold; a cluster of three spires.
        default: { return District(vec3(1.0, 0.78, 0.42), vec3(1.0, 0.72, 0.18), vec3(0.13, 0.09, 0.035), vec3(0.03, 0.022, 0.01)); }
    }
}

fn blendDistricts(first: District, second: District, amount: f32) -> District {
    return District(mix(first.window, second.window, amount), mix(first.neon, second.neon, amount),
                    mix(first.fogLow, second.fogLow, amount), mix(first.fogHigh, second.fogHigh, amount));
}

// The haze colour at a height on the desk: the street glow rises from below.
fn fogColour(place: District, screenY: f32, worldX: f32, time: f32) -> vec3<f32> {
    let rise = pow(smoothstep(HORIZON + 0.35, -0.6, screenY), 1.6);
    // Slow drifting density so the glow is not a flat gradient.
    let drift = noise3(vec3<f32>(worldX * 0.02 + time * 0.03, screenY * 3.0, time * 0.02));
    return mix(place.fogHigh, place.fogLow * (0.45 + 0.45 * drift), rise);
}

// A blinking aircraft-warning light: slow, and each beacon on its own phase.
fn beacon(offset: vec2<f32>, radius: f32, phase: f32, time: f32) -> f32 {
    let blink = pow(0.5 + 0.5 * sin(time * 1.6 + phase * 6.283), 6.0);
    return exp(-dot(offset, offset) / (radius * radius)) * (0.15 + blink);
}

// Lit windows on a facade, in world units on the facade. Far away the grid is
// smaller than a pixel and would shimmer, so it fades to its average.
fn windows(facade: vec2<f32>, tower: vec3<f32>, place: District, pixelWorld: f32, time: f32) -> vec3<f32> {
    let size = vec2<f32>(0.06, 0.085);
    let cell = floor(facade / size);
    let inner = fract(facade / size);
    let density = 0.06 + 0.4 * tower.y * tower.y;
    let pick = hashes(cell.x + tower.x * 7919.0, cell.y, 31.0);
    // Whole floors are busy or dark together, as offices and housing are, so
    // the facade reads as floors and not as noise.
    let floorBusy = hashes(tower.x * 7919.0, cell.y, 37.0).x;
    let floorDensity = density * select(0.25, 2.2, floorBusy > 0.6);
    // A few windows change state slowly, so the city is lived in.
    let lit = select(0.0, 1.0, pick.x < floorDensity) * select(1.0, 0.0, pick.y < 0.03 && fract(time * 0.05 + pick.z) < 0.5);
    var tint = place.window * (0.6 + 0.8 * pick.z);
    tint = select(tint, vec3<f32>(0.55, 0.75, 1.0), pick.y > 0.85);
    let pane = step(0.18, inner.x) * step(inner.x, 0.82) * step(0.22, inner.y) * step(inner.y, 0.78);
    let detail = lit * pane * tint * 0.9;
    let average = density * 0.37 * place.window * 0.9;
    return mix(detail, average, smoothstep(0.25, 0.9, pixelWorld / size.y));
}

// A district's landmark, in world units about its own centre at the landmark
// layer's depth. Returns colour with alpha 1 where the landmark covers.
fn landmark(kind: i32, x: f32, y: f32, place: District, pixelWorld: f32, time: f32) -> vec4<f32> {
    let facadeDark = vec3<f32>(0.006, 0.007, 0.01);
    var inside = false;
    var colour = facadeDark;
    let absoluteX = abs(x);
    switch (kind) {
        case 0: {
            // Pyramid arcology: rows of lit rooms along its terraces, the face
            // turned to the glow a little brighter than the other.
            let top = 22.0;
            inside = absoluteX < (top - y) * 0.85 && y < top;
            let row = floor(y * 1.3);
            let room = hash3(vec3<f32>(row, floor(x * 1.6), 3.0));
            let terrace = smoothstep(0.72, 0.9, fract(y * 1.3)) * step(0.3, room) * (0.5 + room);
            let face = select(0.6, 1.0, x < 0.0);
            colour = facadeDark * face + place.window * terrace * face * mix(1.1, 0.3, smoothstep(0.3, 1.0, pixelWorld));
            colour += vec3<f32>(1.0, 0.75, 0.45) * 4.0 * exp(-((x * x) + (y - top) * (y - top)) * 0.8);
        }
        case 1: {
            // The plinth the hologram stands on; the figure itself is light,
            // added over whatever is behind it (see hologram).
            inside = absoluteX < 4.0 && y < 2.0;
            colour = facadeDark + place.neon * 1.8 * smoothstep(0.4, 0.0, abs(y - 1.8));
        }
        case 2: {
            // Needle spire: tapering, ringed by amber floors, a beacon at its tip.
            let top = 36.0;
            inside = absoluteX < mix(4.0, 0.15, clamp((y + 10.0) / (top + 10.0), 0.0, 1.0)) && y < top;
            let ring = smoothstep(0.85, 1.0, fract(y * 0.25));
            colour = facadeDark + place.neon * ring * 1.6 + place.window * 0.04;
            colour += vec3<f32>(3.0, 0.15, 0.1) * 4.0 * beacon(vec2<f32>(x, y - top), 0.6, 0.3, time);
        }
        case 3: {
            // Twin towers joined by lit skybridges.
            let towers = abs(absoluteX - 5.0) < 2.6 && y < 24.0;
            let bridge = absoluteX < 5.0 && (abs(y - 8.0) < 0.5 || abs(y - 15.0) < 0.5 || abs(y - 20.0) < 0.4);
            inside = towers || bridge;
            let floors = smoothstep(0.5, 0.9, fract(y * 1.1)) * step(0.4, hash3(vec3<f32>(floor(y * 1.1), floor(x * 1.5), 5.0)));
            colour = facadeDark + place.window * floors * mix(1.2, 0.35, smoothstep(0.4, 1.2, pixelWorld));
            if (bridge) { colour = place.neon * 2.2; }
            colour += vec3<f32>(3.0, 0.15, 0.1) * 3.0 * (beacon(vec2<f32>(x - 5.0, y - 24.3), 0.5, 0.1, time) + beacon(vec2<f32>(x + 5.0, y - 24.3), 0.5, 0.6, time));
        }
        case 4: {
            // Ziggurat: five steps, each lip lined with red light.
            let tier = floor(max(y, 0.0) / 4.0);
            inside = absoluteX < 20.0 - tier * 3.6 && y < 20.0;
            let lip = smoothstep(3.4, 3.95, y - tier * 4.0);
            let room = hash3(vec3<f32>(floor(y * 1.3), floor(x * 1.6), 9.0));
            let rooms = smoothstep(0.72, 0.9, fract(y * 1.3)) * step(0.6, room) * mix(0.8, 0.25, smoothstep(0.3, 1.0, pixelWorld));
            colour = facadeDark + place.neon * lip * 2.0 + place.window * rooms;
        }
        case 5: {
            // A needle wearing a glowing ring.
            let mast = absoluteX < mix(2.4, 0.4, clamp(y / 30.0, 0.0, 1.0)) && y < 30.0;
            let ringPlace = vec2<f32>(x / 9.0, (y - 22.0) / 2.0);
            let ring = abs(length(ringPlace) - 1.0) < 0.12 || (abs(y - 22.0) < 0.7 && absoluteX < 9.0);
            inside = mast || ring;
            colour = facadeDark + place.window * 0.1;
            if (ring && !mast) { colour = place.neon * (1.4 + 0.6 * sin(atan2(ringPlace.y, ringPlace.x) * 8.0 + time * 0.6)); }
        }
        case 6: {
            // A domed senate on a drum, its rim lit.
            let dome = length(vec2<f32>(x / 16.0, (y - 6.0) / 10.0)) < 1.0 && y > 6.0;
            let drum = absoluteX < 16.0 && y <= 6.0;
            inside = dome || drum;
            let rib = smoothstep(0.92, 1.0, fract(atan2(y - 6.0, x) * 4.0));
            colour = facadeDark + place.window * 0.08 + place.neon * (rib * 0.8 * select(0.0, 1.0, dome) + 2.0 * smoothstep(0.35, 0.0, abs(y - 6.0)));
        }
        case 7: {
            // A monolith slab, a single seam of light up its face.
            inside = absoluteX < 9.0 && y < 30.0;
            let seam = smoothstep(0.5, 0.0, absoluteX) * 2.5;
            let floors = smoothstep(0.75, 0.95, fract(y * 0.8)) * 0.25;
            colour = facadeDark + place.neon * seam + place.window * floors;
            colour += vec3<f32>(3.0, 0.15, 0.1) * 3.0 * beacon(vec2<f32>(absoluteX - 8.6, y - 30.3), 0.5, 0.8, time);
        }
        default: {
            // Three gold spires.
            let left = abs(x + 6.0) < mix(2.0, 0.2, clamp(y / 24.0, 0.0, 1.0)) && y < 24.0;
            let middle = absoluteX < mix(2.6, 0.2, clamp(y / 34.0, 0.0, 1.0)) && y < 34.0;
            let right = abs(x - 6.5) < mix(2.0, 0.2, clamp(y / 20.0, 0.0, 1.0)) && y < 20.0;
            inside = left || middle || right;
            let floors = smoothstep(0.7, 0.95, fract(y * 0.7));
            colour = facadeDark + place.window * floors * 0.9;
            colour += vec3<f32>(3.0, 0.15, 0.1) * 3.0 * beacon(vec2<f32>(x, y - 34.2), 0.6, 0.2, time);
        }
    }
    return vec4<f32>(colour, select(0.0, 1.0, inside));
}

// The pleasure district's giant: a standing figure of light, hollow but for
// its rim, scanned and shimmering, in world units at the landmark layer.
fn hologram(x: f32, y: f32, place: District, time: f32) -> vec3<f32> {
    // The silhouette as a half-width at each height: legs, hips, waist,
    // shoulders, neck, then the head as an ellipse.
    var halfWidth = mix(0.5, 2.3, smoothstep(2.0, 9.5, y));
    halfWidth = mix(halfWidth, 1.6, smoothstep(10.0, 12.8, y));
    halfWidth = mix(halfWidth, 2.5, smoothstep(12.8, 15.4, y));
    halfWidth = mix(halfWidth, 0.5, smoothstep(15.6, 16.4, y));
    var edge = halfWidth - abs(x);
    // The gap between the legs.
    if (y < 7.5) { edge = min(edge, abs(x) - mix(0.15, 0.0, smoothstep(5.5, 7.5, y))); }
    let headPlace = (vec2<f32>(x, y) - vec2<f32>(0.15, 18.0)) / vec2<f32>(1.1, 1.45);
    let headEdge = (1.0 - length(headPlace)) * 1.2;
    if (y > 16.4) { edge = headEdge; } else { edge = max(edge, headEdge); }
    edge = select(edge, -1.0, y < 2.0 || y > 19.6);
    // Hollow but for its rim, with a faint fill and a halo outside.
    let body = select(exp(edge * 3.0) * 0.25, 0.25 + 1.2 * smoothstep(0.45, 0.0, edge), edge > 0.0);
    let scan = 0.6 + 0.4 * sin(y * 14.0 - time * 2.0);
    let shimmer = 0.75 + 0.25 * noise3(vec3<f32>(x * 0.7, y * 0.3, time * 0.8));
    let hue = mix(place.neon, vec3<f32>(0.2, 0.75, 1.0), 0.4 + 0.4 * sin(time * 0.2 + y * 0.08));
    return hue * 2.2 * body * scan * shimmer;
}

// One generic tower layer at `depth`: whether this pixel is on a tower, and its
// colour before fog.
fn towerLayer(layer: i32, depth: f32, worldX: f32, worldY: f32, place: District, pixelWorld: f32, time: f32) -> vec4<f32> {
    let along = f32(layer) / f32(LAYER_COUNT - 1);
    // Far towers are wider megastructures; near ones are spaced so the lane
    // the camera flies through stays open.
    let count = max(1.0, round(LANE_LENGTH / (1.6 + 0.16 * depth)));
    let width = LANE_LENGTH / count;
    let shifted = worldX + f32(layer) * 13.7;
    let index = wrapIndex(floor(shifted / width), count);
    let local = shifted - floor(shifted / width) * width;
    let tower = hashes(index, f32(layer), 7.0);
    let shape = hashes(index, f32(layer), 8.0);
    if (tower.x < mix(0.8, 0.08, along)) { return vec4<f32>(0.0); }
    // Heights as angles above eye level: near towers loom off the top of the
    // desk, far ones make a skyline just over the horizon.
    var angle = mix(mix(-0.45, -0.03, along), mix(1.0, 0.17, along), pow(shape.x, 1.4));
    // Towers between the lane and a district's landmark stay below eye level,
    // so each desktop's landmark is framed rather than hidden.
    let cellCentre = (floor(shifted / width) + 0.5) * width - f32(layer) * 13.7;
    let fromStop = abs(cellCentre - round(cellCentre / LANE_STEP) * LANE_STEP) / depth;
    if (layer < LANDMARK_LAYER && fromStop < 0.45) { angle = min(angle, -0.04 - 0.1 * shape.y); }
    let top = angle * depth;
    var halfWidth = width * (0.22 + 0.24 * shape.y);
    let centre = width * 0.5 + (shape.z - 0.5) * (width * 0.5 - halfWidth);
    let x = local - centre;
    // A narrower crown on some towers, and a mast on the tallest.
    let crown = top - depth * 0.06 * (0.5 + shape.y);
    if (tower.z > 0.5 && worldY > crown) { halfWidth *= 0.62; }
    let mastWidth = max(0.03, pixelWorld * 0.7);
    let mastTop = top + depth * 0.05 * tower.z;
    let onMast = tower.z > 0.75 && abs(x) < mastWidth && worldY < mastTop;
    let onBody = abs(x) < halfWidth && worldY < top;
    if (!(onBody || onMast)) { return vec4<f32>(0.0); }

    // Facade: nearly black glass, lit faintly from the street glow below.
    var colour = vec3<f32>(0.006, 0.007, 0.01) + place.fogLow * 0.06 * smoothstep(0.0, -2.0 * depth, worldY);
    colour += windows(vec2<f32>(x + index * 3.1, worldY), tower, place, pixelWorld, time);
    // The edge facing the haze catches a rim of its glow.
    colour += place.fogLow * 0.25 * smoothstep(halfWidth - max(0.05, pixelWorld), halfWidth, abs(x));

    // Neon: a vertical sign of flickering blocks, or a strip up one edge.
    let accentPick = fract(tower.y * 17.0);
    var neon = place.neon;
    if (accentPick > 0.55) { neon = vec3<f32>(1.0, 0.1, 0.6); }
    if (accentPick > 0.75) { neon = vec3<f32>(0.1, 0.85, 1.0); }
    if (accentPick > 0.9) { neon = vec3<f32>(1.0, 0.55, 0.1); }
    let neonKind = fract(tower.x * 29.0 + tower.y * 13.0);
    if (neonKind < 0.18) {
        let edge = smoothstep(max(0.04, pixelWorld * 1.5), 0.0, abs(abs(x) - halfWidth * 0.9));
        colour += neon * 2.2 * edge * step(worldY, crown) * step(crown - depth * (0.1 + 0.3 * shape.z), worldY);
    } else if (neonKind < 0.38) {
        let signHeight = top - depth * (0.08 + 0.2 * shape.x);
        // Tall narrow signs, sized on the desk rather than in the world so a
        // near one is not a billboard and a far one is not a speck.
        let signBox = vec2<f32>(min(halfWidth * 0.3, depth * 0.009), depth * 0.045);
        let signPlace = vec2<f32>(x - halfWidth * 0.5, worldY - signHeight);
        if (abs(signPlace.x) < signBox.x && abs(signPlace.y) < signBox.y) {
            let glyph = hashes(floor(signPlace.x / (signBox.x * 0.67)) + index * 5.0, floor(signPlace.y / (signBox.x * 0.6)), 11.0);
            let flicker = 0.85 + 0.15 * step(0.04, fract(time * 0.23 + tower.y * 5.0));
            colour = mix(neon * 0.25, neon * 2.6, step(0.35, glyph.x)) * flicker;
        }
    }
    // Warning beacons on the tallest roofs and masts.
    if (shape.x > 0.55) {
        let roof = select(top, mastTop, tower.z > 0.75);
        colour += vec3<f32>(3.0, 0.12, 0.08) * 3.0 * beacon(vec2<f32>(x, worldY - roof), max(0.08, pixelWorld * 1.2), tower.x, time);
    }
    return vec4<f32>(colour, 1.0);
}

// Flying traffic: streams of lights along lanes between the layers, headlights
// one way and tail-lights the other. Only lanes nearer than `limit` show.
fn traffic(cameraX: f32, cameraY: f32, point: vec2<f32>, limit: f32, pixelScreen: f32, place: District, time: f32) -> vec3<f32> {
    var light = vec3<f32>(0.0);
    for (var lane = 0; lane < 7; lane++) {
        let depth = 3.4 * pow(1.55, f32(lane)) + 0.7;
        if (depth > limit) { break; }
        let laneHash = hashes(f32(lane), 3.0, 17.0);
        let height = mix(-0.3, 0.12, laneHash.x) * depth;
        let screenY = (height - cameraY) / depth + HORIZON;
        let pixelWorld = pixelScreen * depth;
        let radius = max(0.012, pixelWorld * 1.1);
        if (abs(point.y - screenY) * depth > radius * 6.0 + 0.2) { continue; }
        let worldX = cameraX + point.x * depth;
        let worldY = (point.y - HORIZON) * depth + cameraY;
        for (var direction = 0; direction < 2; direction++) {
            let sign = f32(direction) * 2.0 - 1.0;
            let laneY = height + sign * 0.12;
            let spacing = 0.55;
            let count = round(LANE_LENGTH / spacing);
            let moving = worldX - sign * (1.2 + 0.8 * laneHash.y) * time;
            let index = floor(moving / spacing);
            let car = hashes(wrapIndex(index, count), f32(lane * 2 + direction), 19.0);
            if (car.x < 0.3) { continue; }
            let along = moving - (index + 0.5 + (car.y - 0.5) * 0.5) * spacing;
            let across = worldY - laneY - (car.z - 0.5) * 0.08;
            // Lights are stretched along the lane: a streak, not a dot.
            let shape = exp(-(along * along / (radius * radius * 30.0) + across * across / (radius * radius)));
            let tint = select(vec3<f32>(3.0, 0.25, 0.12), vec3<f32>(2.4, 2.2, 1.9), direction == 0);
            let energy = pow(0.012 / radius, 2.0);
            light += tint * shape * energy * exp(-depth * 0.02);
        }
    }
    return light;
}

fn scene(position: f32, point: vec2<f32>, motion: f32, time: f32) -> vec3<f32> {
    let lanePosition = position - 9.0 * floor(position / 9.0);
    let stop = i32(floor(lanePosition));
    let place = blendDistricts(district(stop), district((stop + 1) % 9), smoothstep(0.0, 1.0, fract(lanePosition)));
    // Mid-switch the craft lifts and the view widens a little: flying, not panning.
    let view = point * (1.0 + 0.06 * motion);
    let cameraX = lanePosition * LANE_STEP;
    let cameraY = 1.2 * motion;
    let pixelScreen = u.pane.w / u.jitter.w * (1.0 + 2.6 * u.view.y);

    var colour = vec3<f32>(0.0);
    var hitDepth = 1.0e6;
    var found = false;
    for (var layer = 0; layer < LAYER_COUNT; layer++) {
        let depth = layerDepth(layer);
        let worldX = cameraX + view.x * depth;
        let worldY = (view.y - HORIZON) * depth + cameraY;
        let pixelWorld = pixelScreen * depth;
        var surface = vec4<f32>(0.0);
        var fogDepth = depth;
        if (layer == LANDMARK_LAYER) {
            let nearest = round(worldX / LANE_STEP);
            let kind = i32(wrapIndex(nearest, 9.0));
            surface = landmark(kind, worldX - nearest * LANE_STEP, worldY, district(kind), pixelWorld, time);
            // Landmarks are lit to be seen through the haze: fogged as if nearer.
            fogDepth = depth * 0.6;
        }
        if (surface.w < 0.5) { surface = towerLayer(layer, depth, worldX, worldY, place, pixelWorld, time); }
        if (surface.w > 0.5) {
            // Fog thickens with distance and toward the streets far below.
            let below = smoothstep(0.0, -1.2 * depth, worldY);
            let fog = 1.0 - exp(-(fogDepth * 0.028 + below * (0.9 + fogDepth * 0.04)));
            colour = mix(surface.rgb, fogColour(place, view.y, worldX, time), fog);
            hitDepth = depth;
            found = true;
            break;
        }
    }
    if (!found) {
        // Sky: the haze over the city, glowing at the horizon, with low cloud
        // lit from beneath by the district.
        let height = view.y - HORIZON;
        let cloud = fbm3(vec3<f32>((cameraX * 0.004 + view.x * 1.2) + time * 0.006, view.y * 3.5, time * 0.01), 3);
        colour = mix(fogColour(place, view.y, cameraX, time), place.fogHigh * 0.25, smoothstep(0.0, 0.45, height));
        colour += place.fogLow * 0.3 * smoothstep(0.35, 0.8, cloud) * exp(-max(height, 0.0) * 3.0);
    }
    // The hologram is light, not a surface, so it adds over whatever stands at
    // or behind its own depth.
    let landmarkDepth = layerDepth(LANDMARK_LAYER);
    if (hitDepth >= landmarkDepth) {
        let worldX = cameraX + view.x * landmarkDepth;
        let nearest = round(worldX / LANE_STEP);
        if (i32(wrapIndex(nearest, 9.0)) == 1) {
            let worldY = (view.y - HORIZON) * landmarkDepth + cameraY;
            colour += hologram(worldX - nearest * LANE_STEP, worldY, district(1), time);
        }
    }
    colour += traffic(cameraX, cameraY, view, hitDepth, pixelScreen, place, time);
    // Rain-haze: fine falling streaks catching the glow, faint.
    let rain = noise3(vec3<f32>(view.x * 260.0 + view.y * 40.0, view.y * 9.0 + time * 9.0, time * 0.5));
    colour += place.fogLow * 0.35 * smoothstep(0.78, 1.0, rain);
    return colour;
}

fn backdrop(point: vec2<f32>, time: f32) -> vec3<f32> {
    let glow = smoothstep(0.6, -0.6, point.y);
    return mix(vec3<f32>(0.004, 0.005, 0.009), vec3<f32>(0.02, 0.035, 0.04), glow);
}
