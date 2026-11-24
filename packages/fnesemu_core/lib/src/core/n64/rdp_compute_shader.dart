const n64RdpMaxDraws = 1024;
const n64RdpDepthCapacity = 640 * 576;
const n64RdpTileSeedOffset = 4 * 1024 * 1024;

// The draw paths use the same TMEM layout and pixel formats as N64Graphics.
const n64RdpComputeShader = '''
const drawLimit = ${n64RdpMaxDraws}u;
const residentDepthPixels = ${n64RdpDepthCapacity}u;
const tileSeedOffset = ${n64RdpTileSeedOffset}u;
''' r'''
const tileWords = 3u + (drawLimit + 31u) / 32u;

struct Params {
  rect: vec4<u32>, // Row words, height, destination pixel bytes, parity or combiner offset plus one.
  // Packed fill or triangle color, or copy format, size, palette and flags (IA palette and flip).
  texture: vec4<u32>,
  offsets: vec4<u32>, // Output, TMEM, draw data, and mode.
  bounds: vec4<u32>, // Left, top and width in pixels, depth flags and clear index.
}

@group(0) @binding(0) var<storage, read> input: array<u32>;
@group(0) @binding(1) var<storage, read_write> output: array<u32>;
struct Draws {
  params: array<Params, drawLimit>,
  jobs: array<u32>,
}

@group(0) @binding(2) var<storage, read> draws: Draws;
@group(0) @binding(3) var<storage, read> tiles: array<u32>;
@group(0) @binding(4) var<storage, read_write> residentPlanes: array<u32>;

// Each copy stores packed TMEM followed by its S and T offset tables.
const tmemWords = 1024u;

fn fillWord(params: Params) -> u32 {
  // Return the guest's big-endian bytes for a bulk copy to RDRAM.
  let pixel = reverseBytes(params.texture.x);
  return select(pixel, rotateHalves(pixel), params.rect.z == 2u && params.rect.w != 0u);
}

fn rotateHalves(word: u32) -> u32 {
  return (word << 16u) | (word >> 16u);
}

fn reverseBytes(word: u32) -> u32 {
  return rotateHalves(((word & 0x00ff00ffu) << 8u) | ((word & 0xff00ff00u) >> 8u));
}

fn tmem(base: u32, at: u32) -> u32 {
  let byte = at & 4095u;
  let word = input[base + (byte >> 2u)];
  return (word >> ((byte & 3u) * 8u)) & 255u;
}

fn rgba16(value: u32) -> vec4<f32> {
  let rgb = vec3<u32>((value >> 11u) & 31u, (value >> 6u) & 31u, (value >> 1u) & 31u);
  return vec4<f32>(vec3<f32>(rgb) * (255.0 / 31.0), f32((value & 1u) * 255u));
}

fn ia16(value: u32) -> vec4<f32> {
  return vec4<f32>(vec3<f32>(f32(value >> 8u)), f32(value & 255u));
}

fn texel(params: Params, s: u32, t: u32) -> vec4<f32> {
  let base = params.offsets.y;
  let at = (s & 4095u) + t;
  let size = params.texture.y;
  var value = tmem(base, at);
  if (size == 0u) {
    value = select(value >> 4u, value, (s & 4096u) != 0u) & 15u;
  }
  if (size >= 2u) {
    value = (value << 8u) | tmem(base, at + 1u);
  }
  switch params.texture.x {
    case 0u: {
      if (size == 3u) {
        return vec4<f32>(vec4<u32>(value >> 8u, value & 255u, tmem(base, at + 2u), tmem(base, at + 3u)));
      }
      return rgba16(value);
    }
    case 2u: {
      let index = value + select(0u, params.texture.z * 16u, size == 0u);
      let entry = 2048u + index * 8u;
      let color = (tmem(base, entry) << 8u) | tmem(base, entry + 1u);
      if ((params.texture.w & 1u) != 0u) { return ia16(color); }
      return rgba16(color);
    }
    case 3u: {
      if (size == 2u) { return ia16(value); }
      if (size == 1u) {
        return vec4<f32>(vec3<f32>(f32((value >> 4u) * 17u)), f32((value & 15u) * 17u));
      }
      let intensity = f32(value >> 1u) * (255.0 / 7.0);
      return vec4<f32>(vec3<f32>(intensity), f32((value & 1u) * 255u));
    }
    default: {
      return vec4<f32>(f32(value * select(1u, 17u, size == 0u)));
    }
  }
}

fn copyTexel(params: Params, x: u32, y: u32) -> vec4<f32> {
  let flip = (params.texture.w & 2u) != 0u;
  let s = input[params.offsets.y + tmemWords + select(x, y, flip)];
  let t = input[params.offsets.z + select(y, x, flip)];
  return texel(params, s, t);
}

fn packColor(rgb: vec3<u32>, size: u32) -> u32 {
  if (size == 4u) {
    return (rgb.r << 24u) | (rgb.g << 16u) | (rgb.b << 8u) | 255u;
  }
  return ((rgb.r >> 3u) << 11u) | ((rgb.g >> 3u) << 6u) | ((rgb.b >> 3u) << 1u) | 1u;
}

fn copyPixel(params: Params, x: u32, y: u32) -> u32 {
  let c = vec4<u32>(floor(copyTexel(params, x, y) + 0.5));
  return select(0u, packColor(c.rgb, params.rect.z), c.a != 0u);
}

fn blendColor(c: vec4<u32>, dst: u32, size: u32) -> vec3<u32> {
  let inverse = 255u - c.a;
  if (size == 4u) {
    let rgb = vec3<u32>(dst >> 24u, (dst >> 16u) & 255u, (dst >> 8u) & 255u);
    return (c.rgb * c.a + rgb * inverse + 127u) / 255u;
  }
  // Destination RGB555 channels are unrounded 8-bit values scaled by 255/31.
  let rgb = vec3<u32>((dst >> 11u) & 31u, (dst >> 6u) & 31u, (dst >> 1u) & 31u);
  return (c.rgb * (31u * c.a) + rgb * (255u * inverse) + 3952u) / 7905u;
}

fn edge(base: u32, x: i32, y: i32) -> i32 {
  return bitcast<i32>(input[base]) * x + bitcast<i32>(input[base + 1u]) * y +
      bitcast<i32>(input[base + 2u]);
}

fn triangleCovered(base: u32, x: i32, y: i32) -> bool {
  return edge(base, x, y) >= 0 && edge(base + 3u, x, y) >= 0 &&
      edge(base + 6u, x, y) >= 0;
}

fn textureCoord(base: u32, x: i32, y: i32, reciprocal: i32) -> i32 {
  var n = edge(base, x, y);
  var d = reciprocal;
  let shift = bitcast<i32>(input[base + 3u]);
  if (shift >= 0) {
    n <<= u32(shift);
  } else {
    d <<= u32(-shift);
  }
  let fixed = n / d - select(0, 1, n < 0 && n % d != 0);
  var coord = (fixed - bitcast<i32>(input[base + 4u])) >> 2u;
  let flags = input[base + 6u];
  if ((flags & 2u) != 0u) {
    coord = clamp(coord, 0, i32(input[base + 5u]));
  }
  let mask = flags >> 2u;
  if (mask != 0u) {
    let period = i32(1u << mask);
    let mirror = (flags & 1u) != 0u && (coord & period) != 0;
    coord &= period - 1;
    if (mirror) { coord = period - 1 - coord; }
  }
  return coord;
}

fn trianglePixel(params: Params, x: i32, y: i32, dst: u32) -> vec2<u32> {
  let base = params.offsets.z;
  if (!triangleCovered(base, x, y)) { return vec2<u32>(0u); }
  if (params.offsets.w == 2u) { return vec2<u32>(params.texture.x, 1u); }
  if (params.offsets.w == 4u) {
    return shadeTexel(params, vec4<f32>(255.0), dst, x, y);
  }
  let q = edge(base + 29u, x, y);
  let s = textureCoord(base + 13u, x, y, q);
  let t = textureCoord(base + 20u, x, y, q);
  var tmemX = u32(s / 2);
  if (params.texture.y != 0u) {
    tmemX = u32(s) << (params.texture.y - 1u);
  }
  let horizontal = (tmemX + input[base + 27u]) & 4095u;
  let vertical = (u32(t) & 4095u) * input[base + 28u];
  let texelS = horizontal | ((u32(s) & 1u) << 12u);
  return shadeTexel(params, texel(params, texelS, vertical), dst, x, y);
}

fn unpackColor(word: u32) -> vec4<f32> {
  return vec4<f32>(vec4<u32>(word >> 24u, (word >> 16u) & 255u,
                             (word >> 8u) & 255u, word & 255u));
}

fn backgroundTexel(params: Params, x: u32, y: u32) -> vec4<f32> {
  let offsets = params.offsets.z;
  let at = input[offsets + x] + input[offsets + params.bounds.z + y];
  let value = reverseBytes(input[params.offsets.y + (at >> 2u)]);
  if (params.texture.y == 3u) { return unpackColor(value); }
  return rgba16(select(value & 65535u, value >> 16u, (at & 2u) == 0u));
}

fn shadePlane(base: u32, x: i32, y: i32) -> f32 {
  return ldexp(f32(edge(base, x, y)), bitcast<i32>(input[base + 3u]));
}

fn combineColor(base: u32, tex: vec4<f32>, x: i32, y: i32,
                vertexShade: vec4<f32>, hasVertexShade: bool) -> vec4<f32> {
  var shade = unpackColor(input[base + 3u]);
  let firstPlane = base + 5u;
  if (hasVertexShade) {
    shade = vertexShade;
  } else if (input[base + 4u] != 0u) {
    shade = vec4<f32>(shadePlane(firstPlane, x, y), shadePlane(firstPlane + 4u, x, y),
        shadePlane(firstPlane + 8u, x, y), shadePlane(firstPlane + 12u, x, y));
  }
  // The host's selectors address pairs of lanes of these RGBA registers.
  var regs = array<vec4<f32>, 7>(vec4<f32>(0.0), tex,
      unpackColor(input[base + 1u]), shade, unpackColor(input[base + 2u]),
      vec4<f32>(0.0), vec4<f32>(255.0));
  for (var cycle = 0u; cycle < input[base]; cycle++) {
    let p = base + 21u + cycle * 9u;
    let a = regs[input[p] >> 1u].rgb;
    let b = regs[input[p + 1u] >> 1u].rgb;
    let c = regs[input[p + 2u] >> 1u];
    let d = regs[input[p + 3u] >> 1u].rgb;
    let rgb = (a - b) * select(c.aaa, c.rgb, input[p + 4u] != 0u) * (1.0 / 255.0) + d;
    let aa = regs[input[p + 5u] >> 1u].a;
    let ab = regs[input[p + 6u] >> 1u].a;
    let ac = regs[input[p + 7u] >> 1u].a;
    let ad = regs[input[p + 8u] >> 1u].a;
    regs[0] = clamp(vec4<f32>(rgb, (aa - ab) * ac * (1.0 / 255.0) + ad),
                    vec4<f32>(0.0), vec4<f32>(255.0));
  }
  return regs[0];
}

fn shadeTexel(params: Params, c: vec4<f32>, dst: u32, x: i32, y: i32) -> vec2<u32> {
  return shadePixel(params, c, dst, x, y, vec4<f32>(0.0), false);
}

fn shadePixel(params: Params, c: vec4<f32>, dst: u32, x: i32, y: i32,
              vertexShade: vec4<f32>, hasVertexShade: bool) -> vec2<u32> {
  if (params.rect.w == 0u) {
    let rounded = vec4<u32>(floor(c + 0.5));
    if (rounded.a == 0u) { return vec2<u32>(0u); }
    var rgb = rounded.rgb;
    if ((params.texture.w & 4u) != 0u && rounded.a < 255u) {
      rgb = blendColor(rounded, dst, params.rect.z);
    }
    return vec2<u32>(packColor(rgb, params.rect.z), 1u);
  }

  let color = combineColor(params.rect.w - 1u, c, x, y, vertexShade, hasVertexShade);
  if (color.a < 1.0) { return vec2<u32>(0u); }
  var rgb = color.rgb;
  if ((params.texture.w & 4u) != 0u && color.a < 255.0) {
    var old: vec3<f32>;
    if (params.rect.z == 4u) {
      old = unpackColor(dst).rgb;
    } else {
      old = rgba16(dst).rgb;
    }
    let alpha = color.a * (1.0 / 255.0);
    rgb = rgb * alpha + old * (1.0 - alpha);
  }
  let rounded = rgb + 0.5;
  return vec2<u32>(packColor(vec3<u32>(clamp(floor(rounded), vec3<f32>(0.0),
                                           vec3<f32>(255.0))), params.rect.z), 1u);
}

// These helpers share one byte-addressed image for the source and
// destination, including pixels that straddle storage words.
fn readBackgroundWord(address: u32, bytes: u32) -> u32 {
  var color = 0u;
  for (var i = 0u; i < bytes; i++) {
    let at = address + i;
    let word = output[1u + (at >> 2u)];
    color = (color << 8u) | ((word >> ((at & 3u) * 8u)) & 255u);
  }
  return color;
}

fn writeBackgroundWord(address: u32, bytes: u32, color: u32) {
  for (var i = 0u; i < bytes; i++) {
    let at = address + i;
    let index = 1u + (at >> 2u);
    let shift = (at & 3u) * 8u;
    let channel = (color >> ((bytes - 1u - i) * 8u)) & 255u;
    output[index] = (output[index] & ~(255u << shift)) | (channel << shift);
  }
}

@compute @workgroup_size(1)
fn drawAliasedBackground() {
  let params = draws.params[0];
  let width = params.bounds.z;
  let texelBytes = select(2u, 4u, params.texture.y == 3u);
  let pixelBytes = params.rect.z;
  let first = output[0];
  // Keep in step with the host dispatch count. A single invocation
  // processes each chunk, so every read sees earlier writes.
  let end = min(width * params.rect.y, first + 4096u);
  for (var i = first; i < end; i++) {
    let x = i % width;
    let y = i / width;
    let dst = params.offsets.x + y * params.rect.x + x * pixelBytes;
    if (dst + pixelBytes > params.offsets.y) { continue; }
    let table = params.offsets.z;
    let src = input[table + x] + input[table + width + y];
    let texelWord = readBackgroundWord(src, texelBytes);
    let tex = select(rgba16(texelWord), unpackColor(texelWord), texelBytes == 4u);
    var old = 0u;
    if ((params.texture.w & 4u) != 0u) { old = readBackgroundWord(dst, pixelBytes); }
    let pixel = shadeTexel(params, tex, old, i32(x), i32(y));
    if (pixel.y == 1u) { writeBackgroundWord(dst, pixelBytes, pixel.x); }
  }
  output[0] = end;
}

fn inputFloat(at: u32) -> f32 { return bitcast<f32>(input[at]); }

fn inputVector(at: u32) -> vec4<f32> {
  return vec4<f32>(inputFloat(at), inputFloat(at + 1u),
      inputFloat(at + 2u), inputFloat(at + 3u));
}

fn projectedEdge(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
  let d = p - a;
  let axis = b - a;
  return d.x * axis.y - d.y * axis.x;
}

fn projectedCoordinate(value: f32, base: u32, axis: u32) -> i32 {
  var coord = i32(floor(value * inputFloat(base + 32u + axis) -
      inputFloat(base + 30u + axis)));
  let flags = input[base + 36u + axis];
  if ((flags & 2u) != 0u) { coord = clamp(coord, 0, i32(input[base + 34u + axis])); }
  let mask = flags >> 2u;
  if (mask != 0u) {
    let period = i32(1u << mask);
    let mirror = (flags & 1u) != 0u && (coord & period) != 0;
    coord &= period - 1;
    if (mirror) { coord = period - 1 - coord; }
  }
  return coord;
}

// Translate the stored depth between the host's binary64 depth plane and
// the shader's f32 interpolation. Both representations fit in the tile.
fn floatDepth(depth: vec2<u32>) -> f32 {
  let hi = depth.y;
  let biased = (hi >> 20u) & 0x7ffu;
  if (biased == 0x7ffu) {
    let fraction = (hi & 0xfffffu) | depth.x;
    return bitcast<f32>((hi & 0x80000000u) | 0x7f800000u |
        select(0u, 0x400000u, fraction != 0u));
  }
  let exponent = i32(biased) - 1023;
  if (exponent < -126) { return 0.0; }
  let sign = select(1.0, -1.0, (hi & 0x80000000u) != 0u);
  let mantissa = f32(0x100000u | (hi & 0xfffffu)) * (1.0 / 1048576.0) +
      f32(depth.x) * (1.0 / 4503599627370496.0);
  return sign * ldexp(mantissa, exponent);
}

fn storeDepth(value: f32) -> vec2<u32> {
  let word = bitcast<u32>(value);
  let biased = (word >> 23u) & 255u;
  let fraction = word & 0x7fffffu;
  if (biased == 255u) {
    return vec2<u32>(0u, (word & 0x80000000u) | 0x7ff00000u |
        select(0u, 0x80000u, fraction != 0u));
  }
  let mag = i32(fraction | select(0u, 0x800000u, biased != 0u));
  let signed = select(mag, -mag, (word & 0x80000000u) != 0u);
  return depthBits(signed, i32(max(1u, biased)) - 150);
}

// Invert storeDepth for batches whose depth writes all came from f32.
fn packProjectedDepth(depth: vec2<u32>) -> u32 {
  let sign = depth.y & 0x80000000u;
  let biased = (depth.y >> 20u) & 0x7ffu;
  let fraction = ((depth.y & 0xfffffu) << 3u) | (depth.x >> 29u);
  if (biased == 0u) { return sign; }
  if (biased == 0x7ffu) { return sign | 0x7f800000u | fraction; }
  let exponent = i32(biased) - 896;
  if (exponent <= 0) { return sign | ((0x800000u | fraction) >> u32(1 - exponent)); }
  return sign | (u32(exponent) << 23u) | fraction;
}

fn shadeProjected(params: Params, x: u32, y: u32, previous: TilePixel,
                  flags: u32) -> TilePixel {
  if (x < params.bounds.x || y < params.bounds.y) { return previous; }
  let dx = x - params.bounds.x;
  let dy = y - params.bounds.y;
  if (dx >= params.bounds.z || dy >= params.rect.y) { return previous; }

  let base = params.offsets.z;
  let a = inputVector(base);
  let b = inputVector(base + 10u);
  let c = inputVector(base + 20u);
  let point = vec2<f32>(f32(dx), f32(dy)) + 0.5;
  let area = projectedEdge(c.xy, a.xy, b.xy);
  if (abs(area) < 1e-8) { return previous; }
  let weights = vec3<f32>(projectedEdge(point, b.xy, c.xy),
      projectedEdge(point, c.xy, a.xy), projectedEdge(point, a.xy, b.xy)) / area;
  if (any(weights < vec3<f32>(0.0))) { return previous; }

  let z = c.z + weights.x * (a.z - c.z) + weights.y * (b.z - c.z);
  if ((flags & 1u) != 0u) {
    let old = floatDepth(previous.depth);
    if ((flags & 4u) != 0u) {
      let slope = ((a.z - c.z) * vec2<f32>(c.y - b.y, b.x - c.x) +
          (b.z - c.z) * vec2<f32>(a.y - c.y, c.x - a.x)) / area;
      if (abs(z - old) > 1.0 + abs(slope.x) + abs(slope.y)) { return previous; }
    } else if (z > old) {
      return previous;
    }
  }

  var tex = vec4<f32>(255.0);
  if ((params.texture.w & 8u) == 0u) {
    let q = c.w + weights.x * (a.w - c.w) + weights.y * (b.w - c.w);
    if (q == 0.0) { return previous; }
    let st0 = inputVector(base + 4u).xy;
    let st1 = inputVector(base + 14u).xy;
    let st2 = inputVector(base + 24u).xy;
    let st = (st2 + weights.x * (st0 - st2) + weights.y * (st1 - st2)) / q;
    let s = projectedCoordinate(st.x, base, 0u);
    let t = projectedCoordinate(st.y, base, 1u);
    var column = u32(s / 2);
    if (params.texture.y != 0u) { column = u32(s) << (params.texture.y - 1u); }
    let horizontal = ((column + input[base + 38u]) & 4095u) | ((u32(s) & 1u) << 12u);
    tex = texel(params, horizontal, u32(t) * input[base + 39u]);
  }
  var shade = vec4<f32>(255.0);
  if (params.rect.w != 0u) {
    let shade2 = inputVector(base + 26u);
    shade = shade2 + weights.x * (inputVector(base + 6u) - shade2) +
        weights.y * (inputVector(base + 16u) - shade2);
  }
  let pixel = shadePixel(params, tex, previous.color, i32(dx), i32(dy), shade, true);
  if (pixel.y == 0u) { return previous; }
  if ((flags & 2u) == 0u) { return TilePixel(pixel.x, previous.writes | 1u, previous.depth); }
  return TilePixel(pixel.x, previous.writes | 3u, storeDepth(z));
}

@compute @workgroup_size(64)
fn drawBatch(@builtin(global_invocation_id) id: vec3<u32>,
             @builtin(workgroup_id) group: vec3<u32>) {
  let params = draws.params[draws.jobs[group.x]];
  let index = id.x - params.offsets.x;
  let width = params.rect.x;
  if (index >= width * params.rect.y) { return; }
  if (params.offsets.w == 0u) {
    output[id.x] = fillWord(params);
  } else if (params.offsets.w == 1u) {
    output[id.x] = copyPixel(params, index % width, index / width);
  } else if (params.offsets.w == 7u) {
    let x = index % width;
    let y = index / width;
    output[id.x] = shadeTexel(params, backgroundTexel(params, x, y), 0u, i32(x), i32(y)).x;
  } else {
    output[id.x] = trianglePixel(params, i32(index % width), i32(index / width), 0u).x;
  }
}
// The second component records coverage separately from color because a
// fill of zero still overwrites the destination.
fn tilePixel(params: Params, x: u32, y: u32, dst: u32) -> vec2<u32> {
  if (x < params.bounds.x || y < params.bounds.y) { return vec2<u32>(0u); }
  let dx = x - params.bounds.x;
  let dy = y - params.bounds.y;
  if (dx >= params.bounds.z || dy >= params.rect.y) { return vec2<u32>(0u); }
  if (params.offsets.w == 0u) {
    let value = params.texture.x;
    return vec2<u32>(select(value, value >> 16u,
                           params.rect.z == 2u && (x & 1u) == 0u), 1u);
  }
  if (params.offsets.w == 1u) {
    return shadeTexel(params, copyTexel(params, dx, dy), dst, i32(dx), i32(dy));
  }
  if (params.offsets.w == 6u) {
    return shadeTexel(params, vec4<f32>(255.0), dst, i32(dx), i32(dy));
  }
  if (params.offsets.w == 7u) {
    return shadeTexel(params, backgroundTexel(params, dx, dy), dst, i32(dx), i32(dy));
  }
  return trianglePixel(params, i32(dx), i32(dy), dst);
}

fn resolveOverwrite(tile: u32, x: u32, y: u32) -> vec2<u32> {
  // Find the latest covered draw when the batch has no destination reads.
  var groups = tiles[tile + 2u];
  while (groups != 0u) {
    let word = firstLeadingBit(groups);
    groups &= ~(1u << word);
    var mask = tiles[tile + 3u + word];
    while (mask != 0u) {
      let bit = firstLeadingBit(mask);
      mask &= ~(1u << bit);
      let result = tilePixel(draws.params[word * 32u + bit], x, y, 0u);
      if (result.y != 0u) { return result; }
    }
  }
  return vec2<u32>(0u);
}

// Build the binary64 representation of an exact signed dyadic value.
fn depthBits(value: i32, exponent: i32) -> vec2<u32> {
  if (value == 0) { return vec2<u32>(0u); }
  let mag = u32(abs(value));
  let msb = firstLeadingBit(mag);
  var lo = 0u;
  var fraction = 0u;
  if (msb > 20u) {
    lo = mag << (52u - msb);
    fraction = mag >> (msb - 20u);
  } else {
    fraction = mag << (20u - msb);
  }
  let sign = select(0u, 0x80000000u, value < 0);
  let biased = u32(exponent + i32(msb) + 1023);
  return vec2<u32>(lo, sign | (biased << 20u) | (fraction & 0xfffffu));
}

fn greaterDepth(candidate: vec2<u32>, stored: vec2<u32>) -> bool {
  let magnitude = stored.y & 0x7fffffffu;
  let otherMagnitude = candidate.y & 0x7fffffffu;
  if (magnitude > 0x7ff00000u || (magnitude == 0x7ff00000u && stored.x != 0u) ||
      otherMagnitude > 0x7ff00000u ||
      (otherMagnitude == 0x7ff00000u && candidate.x != 0u)) {
    return false;
  }
  if ((candidate.y | candidate.x | magnitude | stored.x) == 0u) {
    return false;
  }
  let negative = (candidate.y & 0x80000000u) != 0u;
  let otherNegative = (stored.y & 0x80000000u) != 0u;
  if (negative != otherNegative) { return otherNegative; }
  if (negative) {
    return candidate.y < stored.y || (candidate.y == stored.y && candidate.x < stored.x);
  }
  return candidate.y > stored.y || (candidate.y == stored.y && candidate.x > stored.x);
}

struct TilePixel {
  color: u32,
  writes: u32, // Bit 0 writes color, bit 1 writes depth.
  depth: vec2<u32>,
}

const clearedDepth = vec2<u32>(0u, 0x7ff00000u);
const residentColorBase = residentDepthPixels * 3u;

fn resolveOrdered(tile: u32, x: u32, y: u32, dst: u32, depth: vec2<u32>,
                  lastClear: u32) -> TilePixel {
  var result = TilePixel(dst, 0u, depth);
  var clear = 0u;
  var groups = tiles[tile + 2u];
  while (groups != 0u) {
    let word = firstTrailingBit(groups);
    groups &= groups - 1u;
    var mask = tiles[tile + 3u + word];
    while (mask != 0u) {
      let bit = firstTrailingBit(mask);
      mask &= mask - 1u;
      let params = draws.params[word * 32u + bit];
      let nextClear = params.bounds.w >> 3u;
      if (nextClear != clear) {
        result.depth = clearedDepth;
        result.writes &= ~2u;
        clear = nextClear;
      }
      let flags = params.bounds.w & 7u;
      if (params.offsets.w == 5u) {
        result = shadeProjected(params, x, y, result, flags);
        continue;
      }
      var z = vec2<u32>(0u);
      if (flags != 0u) {
        if (x < params.bounds.x || y < params.bounds.y) { continue; }
        let dx = i32(x - params.bounds.x);
        let dy = i32(y - params.bounds.y);
        if (u32(dx) >= params.bounds.z || u32(dy) >= params.rect.y) { continue; }
        if (!triangleCovered(params.offsets.z, dx, dy)) { continue; }
        let base = params.offsets.z + 9u;
        z = depthBits(edge(base, dx, dy), bitcast<i32>(input[base + 3u]));
        if ((flags & 1u) != 0u && greaterDepth(z, result.depth)) { continue; }
      }
      let pixel = tilePixel(params, x, y, result.color);
      if (pixel.y == 0u) { continue; }
      if ((flags & 2u) != 0u) {
        result.depth = z;
        result.writes |= 2u;
      }
      result.color = pixel.x;
      result.writes |= 1u;
    }
  }
  // The final clear can follow the last draw that touched this tile.
  if (clear != lastClear) { result.writes &= ~2u; }
  return result;
}

@compute @workgroup_size(64)
fn drawTiles(@builtin(local_invocation_index) lane: u32,
             @builtin(workgroup_id) group: vec3<u32>) {
  let tile = 3u + group.x * tileWords;
  let x = tiles[tile] + (lane & 7u);
  let y = tiles[tile + 1u] + (lane >> 3u);
  let index = group.x * 64u + lane;
  let flags = tiles[0];
  let transferFlags = tiles[2];
  let depthWords = (transferFlags >> 2u) & 3u;
  let loadColor = (transferFlags & 1u) != 0u;
  let loadDepth = (transferFlags & 2u) != 0u;
  let packed = (flags & 0x8000u) != 0u;
  let resident = (flags & 0x10000u) != 0u;
  let colorWords = select(2u, 1u, packed);
  let outIndex = index * (colorWords + depthWords);
  let depthAt = outIndex + colorWords;
  let seedAt = tileSeedOffset + index * (u32(loadColor) + select(0u, 2u, loadDepth));
  let stride = (flags >> 17u) & 4095u;
  let planePixel = y * stride + x;
  let residentDepthAt = planePixel * 3u;
  let depthEpoch = tiles[1];
  let hasResidentPixel = resident && x < stride && planePixel < residentDepthPixels;
  let cacheColor = (flags & 0x20000000u) != 0u;
  let readCachedColor = (flags & 0x40000000u) != 0u;
  let colorAt = residentColorBase + planePixel;
  let hasColorPixel = x < stride && colorAt < arrayLength(&residentPlanes);
  var result = vec2<u32>(0u);
  if ((flags & 15u) != 0u) {
    var dst = 0u;
    var z = clearedDepth;
    if ((flags & 1u) != 0u) {
      if (readCachedColor && hasColorPixel) {
        dst = residentPlanes[colorAt];
      } else if (loadColor) {
        if ((transferFlags & 16u) != 0u) {
          let colors = reverseBytes(input[tileSeedOffset + (index >> 1u)]);
          dst = select(colors >> 16u, colors & 65535u, (index & 1u) != 0u);
        } else {
          dst = input[seedAt];
        }
      }
    }
    if (hasResidentPixel && residentPlanes[residentDepthAt + 2u] == depthEpoch) {
      z = vec2<u32>(residentPlanes[residentDepthAt], residentPlanes[residentDepthAt + 1u]);
    } else if (loadDepth) {
      let at = seedAt + u32(loadColor);
      z = vec2<u32>(input[at], input[at + 1u]);
    }
    let ordered = resolveOrdered(tile, x, y, dst, z, (flags >> 4u) & 2047u);
    result = vec2<u32>(ordered.color, ordered.writes);
    if ((ordered.writes & 2u) != 0u) {
      if (depthWords == 1u) {
        output[depthAt] = packProjectedDepth(ordered.depth);
      } else if (depthWords == 2u) {
        output[depthAt] = ordered.depth.x;
        output[depthAt + 1u] = ordered.depth.y;
      }
      if (hasResidentPixel) {
        residentPlanes[residentDepthAt] = ordered.depth.x;
        residentPlanes[residentDepthAt + 1u] = ordered.depth.y;
        residentPlanes[residentDepthAt + 2u] = depthEpoch;
      }
    }
  } else {
    result = resolveOverwrite(tile, x, y);
  }
  if (cacheColor && hasColorPixel && ((result.y | flags) & 1u) != 0u) {
    residentPlanes[colorAt] = select(result.x, result.x & 65535u, packed);
  }
  if (packed) {
    output[outIndex] = (result.x & 65535u) | (result.y << 16u);
  } else {
    output[outIndex] = result.x;
    output[outIndex + 1u] = result.y;
  }
}
''';
