// After the scene: temporal accumulation, bloom, and the picture you see.
// Original, written for hyprpeach.

// The same as common.wgsl's, which says what each field is.
struct Uniforms { desk: vec4<f32>, pane: vec4<f32>, stage: vec4<f32>, jitter: vec4<f32>, output: vec4<f32>, overscan: vec4<f32> };
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var source: texture_2d<f32>;
@group(0) @binding(2) var history: texture_2d<f32>;
@group(0) @binding(3) var linearSampler: sampler;

struct VertexOutput { @builtin(position) position: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex fn vs(@builtin(vertex_index) index: u32) -> VertexOutput {
    let corner = vec2<f32>(f32((index << 1u) & 2u), f32(index & 2u));
    var out: VertexOutput;
    out.position = vec4<f32>(corner * 2.0 - 1.0, 0.0, 1.0);
    out.uv = vec2<f32>(corner.x, 1.0 - corner.y);
    return out;
}

// TEMPORAL ANTI-ALIASING. Every frame the scene is drawn a fraction of a pixel
// off from the last; blending frames into a history resolves detail no single
// frame has. The history is clamped to what this frame's neighbourhood could
// plausibly be, which is what keeps moving things from ghosting.
@fragment fn taa(input: VertexOutput) -> @location(0) vec4<f32> {
    let size = vec2<f32>(textureDimensions(source));
    let texel = 1.0 / size;
    let current = textureSampleLevel(source, linearSampler, input.uv, 0.0).rgb;
    var low = current; var high = current;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let c = textureSampleLevel(source, linearSampler, input.uv + vec2<f32>(f32(x), f32(y)) * texel, 0.0).rgb;
            low = min(low, c); high = max(high, c);
        }
    }
    let previous = clamp(textureSampleLevel(history, linearSampler, input.uv, 0.0).rgb, low, high);
    return vec4<f32>(mix(previous, current, u.output.w), 1.0);
}

// BLOOM, down: a 13-tap filter per level (Jimenez 2014), which stays stable as
// small bright things move -- the sun glint, the elevator's climbers.
@fragment fn bloomDown(input: VertexOutput) -> @location(0) vec4<f32> {
    let texel = 1.0 / vec2<f32>(textureDimensions(source));
    let uv = input.uv;
    let a = textureSampleLevel(source, linearSampler, uv + texel * vec2(-2., -2.), 0.0).rgb;
    let b = textureSampleLevel(source, linearSampler, uv + texel * vec2( 0., -2.), 0.0).rgb;
    let c = textureSampleLevel(source, linearSampler, uv + texel * vec2( 2., -2.), 0.0).rgb;
    let d = textureSampleLevel(source, linearSampler, uv + texel * vec2(-2.,  0.), 0.0).rgb;
    let e = textureSampleLevel(source, linearSampler, uv, 0.0).rgb;
    let f = textureSampleLevel(source, linearSampler, uv + texel * vec2( 2.,  0.), 0.0).rgb;
    let g = textureSampleLevel(source, linearSampler, uv + texel * vec2(-2.,  2.), 0.0).rgb;
    let h = textureSampleLevel(source, linearSampler, uv + texel * vec2( 0.,  2.), 0.0).rgb;
    let i = textureSampleLevel(source, linearSampler, uv + texel * vec2( 2.,  2.), 0.0).rgb;
    let j = textureSampleLevel(source, linearSampler, uv + texel * vec2(-1., -1.), 0.0).rgb;
    let k = textureSampleLevel(source, linearSampler, uv + texel * vec2( 1., -1.), 0.0).rgb;
    let l = textureSampleLevel(source, linearSampler, uv + texel * vec2(-1.,  1.), 0.0).rgb;
    let m = textureSampleLevel(source, linearSampler, uv + texel * vec2( 1.,  1.), 0.0).rgb;
    var col = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    // Keep one fireflied pixel from blooming into a disc on the first level.
    col = min(col, vec3<f32>(60.0));
    return vec4<f32>(col, 1.0);
}

// BLOOM, up: a tent filter from the smaller level, added onto the larger one.
@fragment fn bloomUp(input: VertexOutput) -> @location(0) vec4<f32> {
    let texel = 1.0 / vec2<f32>(textureDimensions(source));
    let uv = input.uv;
    var col = textureSampleLevel(source, linearSampler, uv, 0.0).rgb * 4.0;
    col += (textureSampleLevel(source, linearSampler, uv + texel * vec2(-1., 0.), 0.0).rgb
          + textureSampleLevel(source, linearSampler, uv + texel * vec2( 1., 0.), 0.0).rgb
          + textureSampleLevel(source, linearSampler, uv + texel * vec2( 0., -1.), 0.0).rgb
          + textureSampleLevel(source, linearSampler, uv + texel * vec2( 0., 1.), 0.0).rgb) * 2.0;
    col += textureSampleLevel(source, linearSampler, uv + texel * vec2(-1., -1.), 0.0).rgb
         + textureSampleLevel(source, linearSampler, uv + texel * vec2( 1., -1.), 0.0).rgb
         + textureSampleLevel(source, linearSampler, uv + texel * vec2(-1.,  1.), 0.0).rgb
         + textureSampleLevel(source, linearSampler, uv + texel * vec2( 1.,  1.), 0.0).rgb;
    return vec4<f32>(col / 16.0, 1.0);
}

// AgX-style filmic curve: highlights desaturate toward white the way film does,
// instead of clipping to flat primaries.
fn filmic(x: vec3<f32>) -> vec3<f32> {
    let a = x * (x * 2.51 + 0.03);
    let b = x * (x * 2.43 + 0.59) + 0.14;
    return clamp(a / b, vec3<f32>(0.0), vec3<f32>(1.0));
}

// The picture: the resolved scene, upscaled to the panel, bloom laid over it,
// exposed, tone-mapped, a whisper of grain. `history` here is the bloom.
@fragment fn present(input: VertexOutput) -> @location(0) vec4<f32> {
    // Only the monitor itself: the overscan around it was drawn for the bloom.
    let inner = (input.uv + u.overscan.xy) / (1.0 + 2.0 * u.overscan.xy);
    let scene = textureSampleLevel(source, linearSampler, inner, 0.0).rgb;
    let bloom = textureSampleLevel(history, linearSampler, inner, 0.0).rgb;
    var col = mix(scene, bloom, 0.07);
    col = filmic(col * 0.75);
    let grain = fract(sin(dot(input.uv * u.output.xy + u.output.z, vec2<f32>(12.9898, 78.233))) * 43758.5453) - 0.5;
    col += grain * 0.006;
    return vec4<f32>(col, 1.0);   // the surface is sRGB: the hardware encodes
}
