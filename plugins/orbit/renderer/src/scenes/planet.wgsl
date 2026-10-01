// PLANET: the ground beneath a station in orbit, looked straight down at.
// Nine desktops are nine stops along the orbit, 40 degrees apart, closing the
// loop. Planet imagery is NASA's, public domain.

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

const FRAME: f32 = 0.6981317;   // 40 degrees of orbit a desktop

// The ground under the orbit, unrolled into one strip: along it is the orbit,
// across it the ground either side. Looking down needs no ray march -- a
// handful of texture reads a pixel.
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

fn scene(position: f32, point: vec2<f32>, motion: f32, time: f32) -> vec3<f32> {
    // Radians of ground per desk height: a stop is 40 degrees across the desk.
    // Mid-flight the view rises a little, so a switch reads as flying.
    let scale = FRAME / u.right.w;
    let s = point * (1.0 + 0.3 * motion);
    return ground((position + 0.5) * FRAME + s.x * scale, s.y * scale, motion * 0.01);
}

fn backdrop(point: vec2<f32>, time: f32) -> vec3<f32> {
    return deepSpace(normalize(vec3<f32>(point, 1.2))) * 0.6;
}
