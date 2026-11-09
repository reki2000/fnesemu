// The shaders of frame.vert and frame.frag in WGSL, for WebGPU. Keep them in
// step with the GLSL sources.

struct FrameInfo {
  // Width and height in pixels, the scale of the depth into 0 to 1 and the
  // smallest depth used for w.
  viewport: vec4f,
}

struct FragmentInfo {
  // Textured, shading mode, texture alpha, offset.
  shading: vec4f,
  // Fog mode, fog scale, punch-through, alpha reference.
  fog: vec4f,
  fog_color: vec4f,
  vertex_fog_color: vec4f,
}

@group(0) @binding(0) var<uniform> frame_info: FrameInfo;
@group(0) @binding(1) var<uniform> info: FragmentInfo;
@group(0) @binding(2) var texture_image: texture_2d<f32>;
@group(0) @binding(3) var texture_sampler: sampler;
@group(0) @binding(4) var fog_image: texture_2d<f32>;
@group(0) @binding(5) var fog_sampler: sampler;

// Positions are in pixels with y down, and the depth is the reciprocal of w.
struct Vertex {
  @location(0) position: vec3f,
  @location(1) uv: vec2f,
  @location(2) color: vec4f,
  @location(3) offset: vec4f,
}

struct Varyings {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
  @location(1) color: vec4f,
  @location(2) offset: vec4f,
  @location(3) w: f32,
}

@vertex
fn vertex_main(v: Vertex) -> Varyings {
  // A depth near zero would make w huge; a floor keeps the clip space
  // finite and only changes the perspective of triangles that reach it.
  let w = 1.0 / max(v.position.z, frame_info.viewport.w);
  let ndc = vec2f(v.position.x / frame_info.viewport.x * 2.0 - 1.0,
                  1.0 - v.position.y / frame_info.viewport.y * 2.0);
  let depth = clamp(v.position.z * frame_info.viewport.z, 0.000001, 0.999);
  var out: Varyings;
  out.position = vec4f(ndc * w, depth * w, w);
  out.uv = v.uv;
  out.color = v.color;
  out.offset = v.offset;
  // Interpolated with perspective, w gives back the depth of the fragment.
  out.w = w;
  return out;
}

fn fog_coefficient(depth: f32) -> f32 {
  let m = clamp(depth * info.fog.y, 1.0, 255.9999);
  let e = floor(log2(m));
  let position = (m / exp2(e) - 1.0) * 16.0;
  let whole = floor(position);
  let index = e * 16.0 + whole;
  let pair = textureSampleLevel(fog_image, fog_sampler,
                                vec2f((index + 0.5) / 128.0, 0.5), 0.0).rg;
  return mix(pair.r, pair.g, position - whole);
}

@fragment
fn fragment_main(v: Varyings) -> @location(0) vec4f {
  var color = v.color;
  if (info.shading.x > 0.5) {
    var t = textureSampleLevel(texture_image, texture_sampler, v.uv, 0.0);
    if (info.shading.z < 0.5) {
      t.a = 1.0;
    }
    let mode = info.shading.y;
    if (mode < 0.5) {
      color = t;
    } else if (mode < 1.5) {
      color = vec4f(t.rgb * v.color.rgb, t.a);
    } else if (mode < 2.5) {
      color = vec4f(mix(v.color.rgb, t.rgb, t.a), v.color.a);
    } else {
      color = t * v.color;
    }
    if (info.shading.w > 0.5) {
      color = vec4f(min(color.rgb + v.offset.rgb, vec3f(1.0)), color.a);
    }
  }
  let fog_mode = info.fog.x;
  if (fog_mode < 0.5) {
    color = vec4f(mix(color.rgb, info.fog_color.rgb, fog_coefficient(1.0 / v.w)),
                  color.a);
  } else if (fog_mode < 1.5) {
    if (info.shading.w > 0.5) {
      color = vec4f(mix(color.rgb, info.vertex_fog_color.rgb, v.offset.a),
                    color.a);
    }
  } else if (fog_mode > 2.5) {
    color = vec4f(info.fog_color.rgb, fog_coefficient(1.0 / v.w));
  }
  if (info.fog.z > 0.5) {
    // The test compares 8-bit alphas; rounding keeps an alpha of 1.0 from
    // failing a reference of 255.
    if (floor(color.a * 255.0 + 0.5) < info.fog.w) {
      discard;
    }
    color.a = 1.0;
  }
  return color;
}
