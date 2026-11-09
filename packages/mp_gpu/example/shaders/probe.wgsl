// The shaders of probe.vert and probe.frag in WGSL, for WebGPU.

struct Info {
  color: vec4f,
}

@group(0) @binding(0) var<uniform> info: Info;
@group(0) @binding(1) var image: texture_2d<f32>;
@group(0) @binding(2) var image_sampler: sampler;

struct Vertex {
  @location(0) position: vec2f,
  @location(1) uv: vec2f,
}

struct Varyings {
  @builtin(position) position: vec4f,
  @location(0) uv: vec2f,
}

@vertex
fn vertex_main(v: Vertex) -> Varyings {
  var out: Varyings;
  out.position = vec4f(v.position, 0.5, 1.0);
  out.uv = v.uv;
  return out;
}

@fragment
fn fragment_main(v: Varyings) -> @location(0) vec4f {
  return textureSampleLevel(image, image_sampler, v.uv, 0.0) * info.color;
}
