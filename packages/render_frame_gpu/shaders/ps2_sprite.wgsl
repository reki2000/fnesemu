struct SpriteInfo {
  sizes: vec4f,
  depth: vec4f,
  color: vec4f,
  texture_mode: vec4f,
  blend: vec4f,
  tests: vec4f,
  writes: vec4f,
}

@group(0) @binding(0) var<uniform> info: SpriteInfo;
@group(0) @binding(1) var sprite_input: texture_2d<f32>;
@group(0) @binding(2) var sprite_sampler: sampler;

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) pixel: vec2f,
  @location(1) marker: vec3f,
}

@vertex
fn vertex_main(@location(0) position: vec2f, @location(1) pixel: vec2f,
               @location(2) marker: vec3f) -> VertexOutput {
  return VertexOutput(vec4f(position, 0.5, 1.0), pixel, marker);
}

fn bytes_at(p: vec2i) -> vec4i {
  let uv = (vec2f(p) + 0.5) / info.sizes.zw;
  return vec4i(floor(textureSampleLevel(sprite_input, sprite_sampler, uv, 0.0) * 255.0 + 0.5));
}

fn word(p: vec4i) -> u32 {
  return u32(p.r) | (u32(p.g) << 8u) | (u32(p.b) << 16u) | (u32(p.a) << 24u);
}

fn alpha_passes(a: i32, test: i32, ref_value: i32) -> bool {
  switch test {
    case 0: { return false; }
    case 1: { return true; }
    case 2: { return a < ref_value; }
    case 3: { return a <= ref_value; }
    case 4: { return a == ref_value; }
    case 5: { return a >= ref_value; }
    case 6: { return a > ref_value; }
    default: { return a != ref_value; }
  }
}

fn color_term(mode: i32, src: vec3i, dst: vec3i) -> vec3i {
  return select(select(vec3i(0), dst, mode == 1), src, mode == 0);
}

@fragment
fn fragment_main(input: VertexOutput) -> @location(0) vec4f {
  if (any(input.marker > vec3f(0.0))) {
    return vec4f(input.marker, 1.0);
  }
  var p = vec2i(floor(input.pixel));
  let width = i32(info.sizes.x);
  let height = i32(info.sizes.y);
  let flags = p.x >= width;
  if (flags) { p.x -= width; }
  let th = i32(info.depth.x);
  let ztest = i32(info.depth.y);
  if (ztest == 0) { discard; }
  if (ztest >= 2) {
    let z = u32(info.depth.z) | (u32(info.depth.w) << 16u);
    let old_z = word(bytes_at(p + vec2i(0, th + height)));
    if (z < old_z || (ztest == 3 && z == old_z)) { discard; }
  }

  let map_row = i32(info.sizes.w) - 2;
  let u = i32(word(bytes_at(vec2i(p.x, map_row))));
  let v = i32(word(bytes_at(vec2i(p.y, map_row + 1))));
  let texel = bytes_at(vec2i(u, v));
  let vertex = vec4i(info.color);
  let mode = i32(info.texture_mode.x);
  var src = texel;
  if (mode != 1) {
    src = (texel * vertex) >> vec4u(7);
    if (mode >= 2) {
      src = vec4i(src.rgb + vec3i(vertex.a), texel.a + select(0, vertex.a, mode == 2));
    }
    src = min(src, vec4i(255));
  }
  if (info.texture_mode.y == 0.0) { src.a = vertex.a; }

  let dst = bytes_at(p + vec2i(0, th));
  let date = i32(info.writes.y);
  if (date != 0 && (dst.a >> 7u) != date - 1) { discard; }
  var write_color = 1;
  var write_z = i32(info.writes.z);
  if (!alpha_passes(src.a, i32(info.tests.z), i32(info.tests.w))) {
    let fail = i32(info.writes.x);
    if (fail == 0) { discard; }
    if (fail == 2) { write_color = 0; }
    if (fail != 2) { write_z = 0; }
    if (fail == 3) { write_color = 2; }
  }
  if (flags) {
    return vec4f(vec3f(vec3i(src.a, write_color, write_z)) / 255.0, 1.0);
  }
  var rgb = src.rgb;
  if (info.texture_mode.z != 0.0 &&
      (info.texture_mode.w == 0.0 || src.a >= 128)) {
    let blend = vec4i(info.blend);
    let factor = select(select(i32(info.tests.x), dst.a, blend.z == 1), src.a, blend.z == 0);
    let a = color_term(blend.x, rgb, dst.rgb);
    let b = color_term(blend.y, rgb, dst.rgb);
    let d = color_term(blend.w, rgb, dst.rgb);
    rgb = (((a - b) * vec3i(factor)) >> vec3u(7)) + d;
    rgb = select(rgb & vec3i(255), clamp(rgb, vec3i(0), vec3i(255)), info.tests.y != 0.0);
  }
  return vec4f(vec3f(rgb) / 255.0, 1.0);
}
