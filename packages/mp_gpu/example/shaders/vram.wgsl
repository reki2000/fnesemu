// The shaders of probe.vert and vram.frag in WGSL, for WebGPU. The texel is
// read with textureLoad, by its integer position.

struct VramInfo {
  size: vec4f,
}

@group(0) @binding(0) var<uniform> info: VramInfo;
@group(0) @binding(1) var vram: texture_2d<f32>;
@group(0) @binding(2) var vram_sampler: sampler;

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
  var x = u32(v.uv.x);
  var y = u32(v.uv.y);
  var address = 0u;
  for (var i = 0u; i < 11u; i++) {
    address |= ((x >> i) & 1u) << (2u * i);
    address |= ((y >> i) & 1u) << (2u * i + 1u);
  }
  address += u32(info.size.z);
  let width = u32(info.size.x);
  return textureLoad(vram, vec2u(address % width, address / width), 0);
}
