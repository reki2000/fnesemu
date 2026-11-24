// The WGSL program of ge_compute.dart: the fragment pipeline of PspGeRaster
// on the video memory in a storage buffer. Edit it here; there is no other
// copy.

const pspGeComputeShader = r'''
// A compute GE: the 2 MiB video memory is a storage buffer. The pixel
// pipeline follows PspGeRaster of the core (packages/fnesemu_core/lib/src/
// core/psp/ge.dart) step by step, so that a frame can be compared with it.
//
// Entry points:
//   raster  one 16x16 tile per workgroup: the primitives that the host
//           binned into the tile, in order; each thread owns two
//           horizontal pixels, and keeps their color and depth in
//           registers until the end
//   copy    a block transfer into video memory, one destination word per
//           thread
//
// The constants below match ge_compute.dart.

const PRIM_WORDS = 36u;
const V0 = 6u;
const V1 = 16u;
const V2 = 26u;

const T_TRIANGLE = 0u;
const T_SPRITE = 1u;
const T_POINT = 2u;
const T_CLEAR = 3u;

// state words
const S_FLAGS = 0u;
const S_TEXFUNC = 1u;
const S_ENV = 2u;
const S_ATEST = 3u;
const S_STEST = 4u;
const S_SOPS = 5u;
const S_ZFUNC = 6u;
const S_BLEND = 7u;
const S_FIXA = 8u;
const S_FIXB = 9u;
const S_KEEP = 10u;
const S_TEXBASE = 11u;
const S_TEXW = 12u;
const S_TEXH = 13u;
const S_PITCH = 14u;
const S_TEXFMT = 15u;
const S_WRAP = 16u;
const S_CLUT = 17u;
const S_PALBASE = 18u;
const S_PALCOUNT = 19u;
const S_USCALE = 20u;
const S_VSCALE = 21u;
const S_UOFF = 22u;
const S_VOFF = 23u;

// S_FLAGS bits
const F_TEXTURED = 1u;
const F_ATEST = 2u;
const F_STENCIL = 4u;
const F_ZTEST = 8u;
const F_ZWRITE = 16u;
const F_BLEND = 32u;
const F_THROUGH = 64u;
const F_TEXSCALE = 128u;
const F_LINEAR = 256u;
const F_SWIZZLE = 512u;
const F_TEXRGBA = 1024u;
const F_TEXVRAM = 2048u;

const VRAM_MASK = 0x1fffffu;

struct Params {
  a: vec4u,
  b: vec4u,
  c: vec4u,
  d: vec4u,
}

@group(0) @binding(0) var<storage, read_write> vram: array<u32>;
@group(0) @binding(1) var<storage, read> prims: array<u32>;
@group(0) @binding(2) var<storage, read> data: array<u32>;
@group(0) @binding(3) var<uniform> P: Params;

// ---- memory ----

fn vram8(at: u32) -> u32 {
  let a = at & VRAM_MASK;
  return (vram[a >> 2u] >> ((a & 3u) * 8u)) & 0xffu;
}

fn vram16(at: u32) -> u32 {
  let a = at & VRAM_MASK;
  return (vram[a >> 2u] >> ((a & 2u) * 8u)) & 0xffffu;
}

fn data8(at: u32) -> u32 {
  return (data[at >> 2u] >> ((at & 3u) * 8u)) & 0xffu;
}

fn data16(at: u32) -> u32 {
  return (data[at >> 2u] >> ((at & 2u) * 8u)) & 0xffffu;
}

fn tex8(st: u32, at: u32) -> u32 {
  if ((data[st + S_FLAGS] & F_TEXVRAM) != 0u) { return vram8(at); }
  return data8(at);
}

fn tex16(st: u32, at: u32) -> u32 {
  if ((data[st + S_FLAGS] & F_TEXVRAM) != 0u) { return vram16(at); }
  return data16(at);
}

fn tex32(st: u32, at: u32) -> u32 {
  if ((data[st + S_FLAGS] & F_TEXVRAM) != 0u) {
    return vram[(at & VRAM_MASK) >> 2u];
  }
  return data[at >> 2u];
}

// ---- colors ----

fn expand16(v: u32, format: u32) -> u32 {
  switch (format) {
    case 0u: {
      let r5 = v & 0x1fu;
      let g6 = (v >> 5u) & 0x3fu;
      let b5 = (v >> 11u) & 0x1fu;
      return 0xff000000u | ((r5 << 3u) | (r5 >> 2u)) |
          (((g6 << 2u) | (g6 >> 4u)) << 8u) |
          (((b5 << 3u) | (b5 >> 2u)) << 16u);
    }
    case 1u: {
      let r5 = v & 0x1fu;
      let g5 = (v >> 5u) & 0x1fu;
      let b5 = (v >> 10u) & 0x1fu;
      let a = select(0u, 0xff000000u, (v & 0x8000u) != 0u);
      return a | ((r5 << 3u) | (r5 >> 2u)) |
          (((g5 << 3u) | (g5 >> 2u)) << 8u) |
          (((b5 << 3u) | (b5 >> 2u)) << 16u);
    }
    case 2u: {
      let r = v & 0xfu;
      let g = (v >> 4u) & 0xfu;
      let b = (v >> 8u) & 0xfu;
      let a = (v >> 12u) & 0xfu;
      return (((a << 4u) | a) << 24u) | ((r << 4u) | r) |
          (((g << 4u) | g) << 8u) | (((b << 4u) | b) << 16u);
    }
    default: {
      return v;
    }
  }
}

fn unpack(rgba: u32) -> vec4f {
  return vec4f(f32(rgba & 0xffu), f32((rgba >> 8u) & 0xffu),
      f32((rgba >> 16u) & 0xffu), f32(rgba >> 24u)) / 255.0;
}

// Dart's round of a value that is not negative
fn round_up(v: f32) -> u32 {
  return u32(floor(v + 0.5));
}

fn byte_of(v: f32) -> u32 {
  return round_up(clamp(v, 0.0, 1.0) * 255.0);
}

fn encode_bytes(format: u32, ri: u32, gi: u32, bi: u32, ai: u32) -> u32 {
  switch (format) {
    case 0u: {
      return (ri >> 3u) | ((gi >> 2u) << 5u) | ((bi >> 3u) << 11u);
    }
    case 1u: {
      return (ri >> 3u) | ((gi >> 3u) << 5u) | ((bi >> 3u) << 10u) |
          select(0u, 0x8000u, ai >= 128u);
    }
    case 2u: {
      return (ri >> 4u) | ((gi >> 4u) << 4u) | ((bi >> 4u) << 8u) |
          ((ai >> 4u) << 12u);
    }
    default: {
      return ri | (gi << 8u) | (bi << 16u) | (ai << 24u);
    }
  }
}

fn encode(format: u32, c: vec4f) -> u32 {
  return encode_bytes(format, byte_of(c.x), byte_of(c.y), byte_of(c.z),
      byte_of(c.w));
}

fn decode(format: u32, raw: u32) -> vec4f {
  if (format == 3u) { return unpack(raw); }
  return unpack(expand16(raw, format));
}

fn alpha_mask(format: u32) -> u32 {
  switch (format) {
    case 1u: { return 0x8000u; }
    case 2u: { return 0xf000u; }
    case 3u: { return 0xff000000u; }
    default: { return 0u; }
  }
}

fn stencil_of(format: u32, raw: u32) -> u32 {
  switch (format) {
    case 1u: { return (raw >> 15u) & 1u; }
    case 2u: { return (raw >> 12u) & 0xfu; }
    case 3u: { return (raw >> 24u) & 0xffu; }
    default: { return 0u; }
  }
}

fn stencil8(format: u32, raw: u32) -> u32 {
  switch (format) {
    case 1u: { return stencil_of(format, raw) * 0xffu; }
    case 2u: { return stencil_of(format, raw) * 0x11u; }
    default: { return stencil_of(format, raw); }
  }
}

fn stencil_raw(format: u32, value: u32) -> u32 {
  switch (format) {
    case 1u: { return value << 15u; }
    case 2u: { return value << 12u; }
    case 3u: { return value << 24u; }
    default: { return 0u; }
  }
}

fn stencil_op(st: u32, format: u32, op: u32, raw: u32) -> u32 {
  let value = stencil_of(format, raw);
  var bits = 0u;
  switch (format) {
    case 1u: { bits = 1u; }
    case 2u: { bits = 4u; }
    case 3u: { bits = 8u; }
    default: { bits = 0u; }
  }
  let top = (1u << bits) - 1u;
  switch (op) {
    case 1u: { return 0u; }
    case 2u: { return ((data[st + S_STEST] >> 8u) & 0xffu) >> (8u - bits); }
    case 3u: { return top - value; }
    case 4u: { return select(top, value + 1u, value < top); }
    case 5u: { return select(0u, value - 1u, value > 0u); }
    default: { return value; }
  }
}

fn compare(func: u32, value: u32, reference: u32) -> bool {
  switch (func) {
    case 0u: { return false; }
    case 1u: { return true; }
    case 2u: { return value == reference; }
    case 3u: { return value != reference; }
    case 4u: { return value < reference; }
    case 5u: { return value <= reference; }
    case 6u: { return value > reference; }
    default: { return value >= reference; }
  }
}

fn blend_factor(factor: u32, other: f32, src_a: f32, dst_a: f32, fixed: u32,
    channel: u32) -> f32 {
  switch (factor) {
    case 0u: { return other; }
    case 1u: { return 1.0 - other; }
    case 2u: { return src_a; }
    case 3u: { return 1.0 - src_a; }
    case 4u: { return dst_a; }
    case 5u: { return 1.0 - dst_a; }
    case 6u: { return 2.0 * src_a; }
    case 7u: { return max(0.0, 1.0 - 2.0 * src_a); }
    case 8u: { return 2.0 * dst_a; }
    case 9u: { return max(0.0, 1.0 - 2.0 * dst_a); }
    case 10u: { return f32((fixed >> (channel * 8u)) & 0xffu) / 255.0; }
    default: { return 1.0; }
  }
}

fn blend_channel(st: u32, src: f32, dst: f32, src_a: f32, dst_a: f32,
    channel: u32) -> f32 {
  let mode = data[st + S_BLEND];
  let op = (mode >> 8u) & 7u;
  if (op == 3u) { return min(src, dst); }
  if (op == 4u) { return max(src, dst); }
  let sf = blend_factor(mode & 0xfu, dst, src_a, dst_a, data[st + S_FIXA],
      channel);
  let df = blend_factor((mode >> 4u) & 0xfu, src, src_a, dst_a,
      data[st + S_FIXB], channel);
  switch (op) {
    case 1u: { return clamp(src * sf - dst * df, 0.0, 1.0); }
    case 2u: { return clamp(dst * df - src * sf, 0.0, 1.0); }
    case 5u: { return abs(src - dst); }
    default: { return clamp(src * sf + dst * df, 0.0, 1.0); }
  }
}

// ---- textures ----

fn texel_offset(x: u32, y: u32, pitch: u32, bpp: u32, swizzled: bool) -> u32 {
  let pitch_bytes = pitch * bpp;
  if (swizzled) {
    let block_pitch = max(pitch_bytes, 16u);
    let byte_x = x * bpp;
    return (y >> 3u) * (block_pitch << 3u) + ((byte_x >> 4u) << 7u) +
        ((y & 7u) << 4u) + (byte_x & 15u);
  }
  return y * pitch_bytes + x * bpp;
}

fn wrap(c: i32, size: i32, clamped: bool) -> u32 {
  if (clamped) { return u32(clamp(c, 0, size - 1)); }
  return u32(((c % size) + size) % size);
}

fn texel(st: u32, xi: i32, yi: i32) -> vec4f {
  let tw = i32(data[st + S_TEXW]);
  let th = i32(data[st + S_TEXH]);
  let w = data[st + S_WRAP];
  let x = wrap(xi, tw, (w & 0xffu) == 1u);
  let y = wrap(yi, th, ((w >> 8u) & 0xffu) == 1u);
  let format = data[st + S_TEXFMT];
  let pitch = data[st + S_PITCH];
  let base = data[st + S_TEXBASE];
  let swizzled = (data[st + S_FLAGS] & F_SWIZZLE) != 0u;
  var rgba = 0xffffffffu;
  if (format >= 4u && format <= 7u) {
    var index = 0u;
    switch (format) {
      case 5u: { index = tex8(st, base + texel_offset(x, y, pitch, 1u, swizzled)); }
      case 6u: { index = tex16(st, base + texel_offset(x, y, pitch, 2u, swizzled)); }
      case 7u: { index = tex32(st, base + texel_offset(x, y, pitch, 4u, swizzled)); }
      default: {
        let byte = tex8(st, base + texel_offset(x >> 1u, y, pitch >> 1u, 1u,
            swizzled));
        index = select(byte >> 4u, byte & 0xfu, (x & 1u) == 0u);
      }
    }
    let clut = data[st + S_CLUT];
    let shift = (clut >> 2u) & 0x1fu;
    let mask = (clut >> 8u) & 0xffu;
    let start = (clut >> 16u) & 0xffu;
    let count = data[st + S_PALCOUNT];
    var at = ((index >> shift) & mask) + start;
    if (count == 0u) {
      rgba = 0u;
    } else {
      if (at >= count) { at = count - 1u; }
      rgba = data[data[st + S_PALBASE] + at];
    }
  } else if (format == 3u) {
    rgba = tex32(st, base + texel_offset(x, y, pitch, 4u, swizzled));
  } else if (format <= 2u) {
    rgba = expand16(tex16(st, base + texel_offset(x, y, pitch, 2u, swizzled)),
        format);
  }
  return unpack(rgba);
}

fn sample(st: u32, su: f32, sv: f32, inv_w: f32) -> vec4f {
  let flags = data[st + S_FLAGS];
  var u = su;
  var v = sv;
  if (inv_w != 0.0 && inv_w != 1.0) {
    u = u / inv_w;
    v = v / inv_w;
  }
  var tu = u;
  var tv = v;
  if ((flags & F_TEXSCALE) != 0u) {
    tu = u * bitcast<f32>(data[st + S_USCALE]) + bitcast<f32>(data[st + S_UOFF]);
    tv = v * bitcast<f32>(data[st + S_VSCALE]) + bitcast<f32>(data[st + S_VOFF]);
  }
  if ((flags & F_THROUGH) == 0u) {
    tu = tu * f32(data[st + S_TEXW]);
    tv = tv * f32(data[st + S_TEXH]);
  }
  if ((flags & F_LINEAR) == 0u) {
    return texel(st, i32(floor(tu)), i32(floor(tv)));
  }
  let x = tu - 0.5;
  let y = tv - 0.5;
  let x0 = floor(x);
  let y0 = floor(y);
  let fx = x - x0;
  let fy = y - y0;
  let xi = i32(x0);
  let yi = i32(y0);
  let c00 = texel(st, xi, yi);
  let c10 = texel(st, xi + 1, yi);
  let c01 = texel(st, xi, yi + 1);
  let c11 = texel(st, xi + 1, yi + 1);
  return (c00 * (1.0 - fx) + c10 * fx) * (1.0 - fy) +
      (c01 * (1.0 - fx) + c11 * fx) * fy;
}

// ---- the fragment pipeline ----

// one pixel of a draw: the color in the frame buffer format, the depth,
// and whether each changed
struct Pixel {
  color: u32,
  depth: u32,
  color_dirty: bool,
  depth_dirty: bool,
}

struct Fragment {
  color: vec4f,
  z: f32,
  su: f32,
  sv: f32,
  inv_w: f32,
}

fn write_stencil(st: u32, format: u32, p: ptr<function, Pixel>, op: u32) {
  let dst = (*p).color;
  let alpha = alpha_mask(format);
  let out = (dst & ~alpha) | stencil_raw(format, stencil_op(st, format, op, dst));
  let keep = data[st + S_KEEP];
  (*p).color = (dst & keep) | (out & ~keep);
  (*p).color_dirty = true;
}

fn shade(st: u32, format: u32, f: Fragment, p: ptr<function, Pixel>) {
  let flags = data[st + S_FLAGS];
  var c = f.color;
  if ((flags & F_TEXTURED) != 0u) {
    let t = sample(st, f.su, f.sv, f.inv_w);
    let func = data[st + S_TEXFUNC];
    let rgba = (flags & F_TEXRGBA) != 0u;
    let env = unpack(data[st + S_ENV] | 0xff000000u);
    switch (func) {
      case 0u: {
        c = vec4f(c.xyz * t.xyz, select(c.w, c.w * t.w, rgba));
      }
      case 1u: {
        if (rgba) {
          c = vec4f(c.xyz * (1.0 - t.w) + t.xyz * t.w, c.w);
        } else {
          c = vec4f(t.xyz, c.w);
        }
      }
      case 2u: {
        c = vec4f(c.xyz * (1.0 - t.xyz) + env.xyz * t.xyz,
            select(c.w, c.w * t.w, rgba));
      }
      case 3u: {
        c = vec4f(t.xyz, select(c.w, t.w, rgba));
      }
      case 4u: {
        c = vec4f(min(vec3f(1.0), c.xyz + t.xyz), select(c.w, c.w * t.w, rgba));
      }
      default: {}
    }
  }
  if ((flags & F_ATEST) != 0u) {
    let test = data[st + S_ATEST];
    let reference = (test >> 8u) & 0xffu;
    let mask = (test >> 16u) & 0xffu;
    let value = round_up(c.w * 255.0) & mask;
    if (!compare(test & 7u, value, reference & mask)) { return; }
  }
  let dst = (*p).color;
  let stencil_on = (flags & F_STENCIL) != 0u;
  if (stencil_on) {
    let test = data[st + S_STEST];
    let reference = (test >> 8u) & 0xffu;
    let mask = (test >> 16u) & 0xffu;
    if (!compare(test & 7u, reference & mask, stencil8(format, dst) & mask)) {
      write_stencil(st, format, p, data[st + S_SOPS] & 7u);
      return;
    }
  }
  let z = u32(clamp(floor(f.z + 0.5), 0.0, 65535.0));
  if ((flags & F_ZTEST) != 0u) {
    if (!compare(data[st + S_ZFUNC] & 7u, z, (*p).depth)) {
      if (stencil_on) {
        write_stencil(st, format, p, (data[st + S_SOPS] >> 8u) & 7u);
      }
      return;
    }
  }
  var out = encode(format, c);
  if ((flags & F_BLEND) != 0u) {
    let d = decode(format, dst);
    out = encode(format, vec4f(
        blend_channel(st, c.x, d.x, c.w, d.w, 0u),
        blend_channel(st, c.y, d.y, c.w, d.w, 1u),
        blend_channel(st, c.z, d.z, c.w, d.w, 2u),
        blend_channel(st, c.w, d.w, c.w, d.w, 3u)));
  }
  let alpha = alpha_mask(format);
  var stencil = dst & alpha;
  if (stencil_on) {
    stencil = stencil_raw(format,
        stencil_op(st, format, (data[st + S_SOPS] >> 16u) & 7u, dst));
  }
  out = (out & ~alpha) | stencil;
  let keep = data[st + S_KEEP];
  (*p).color = (dst & keep) | (out & ~keep);
  (*p).color_dirty = true;
  if ((flags & F_ZWRITE) != 0u) {
    (*p).depth = z;
    (*p).depth_dirty = true;
  }
}

fn pf(i: u32) -> f32 {
  return bitcast<f32>(prims[i]);
}

// Draws primitive [pi] at pixel (x, y) into [p].
fn draw(pi: u32, format: u32, x: u32, y: u32, p: ptr<function, Pixel>) {
  let at = pi * PRIM_WORDS;
  let xi = i32(x);
  let yi = i32(y);
  if (xi < i32(prims[at + 2u]) || yi < i32(prims[at + 3u]) ||
      xi >= i32(prims[at + 4u]) || yi >= i32(prims[at + 5u])) {
    return;
  }
  let kind = prims[at];
  if (kind == T_CLEAR) {
    let color = prims[at + V0];
    let cleared = prims[at + V0 + 2u];
    let full = select(0xffffu, 0xffffffffu, format == 3u);
    if (cleared == full) {
      (*p).color = color;
      (*p).color_dirty = true;
    } else if (cleared != 0u) {
      (*p).color = ((*p).color & ~cleared) | (color & cleared);
      (*p).color_dirty = true;
    }
    if ((prims[at + V0 + 3u] & 4u) != 0u) {
      (*p).depth = prims[at + V0 + 1u];
      (*p).depth_dirty = true;
    }
    return;
  }
  let st = prims[at + 1u];
  var f: Fragment;
  if (kind == T_TRIANGLE) {
    let ax = pf(at + V0);
    let ay = pf(at + V0 + 1u);
    let bx = pf(at + V1);
    let by = pf(at + V1 + 1u);
    let cx = pf(at + V2);
    let cy = pf(at + V2 + 1u);
    let px = f32(x) + 0.5;
    let py = f32(y) + 0.5;
    let denom = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
    if (denom == 0.0) { return; }
    let w0 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / denom;
    let w1 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / denom;
    let w2 = 1.0 - w0 - w1;
    if (w0 < 0.0 || w1 < 0.0 || w2 < 0.0) { return; }
    let w = vec3f(w0, w1, w2);
    f.z = dot(w, vec3f(pf(at + V0 + 2u), pf(at + V1 + 2u), pf(at + V2 + 2u)));
    f.su = dot(w, vec3f(pf(at + V0 + 3u), pf(at + V1 + 3u), pf(at + V2 + 3u)));
    f.sv = dot(w, vec3f(pf(at + V0 + 4u), pf(at + V1 + 4u), pf(at + V2 + 4u)));
    f.inv_w = dot(w, vec3f(pf(at + V0 + 5u), pf(at + V1 + 5u), pf(at + V2 + 5u)));
    f.color = vec4f(
        dot(w, vec3f(pf(at + V0 + 6u), pf(at + V1 + 6u), pf(at + V2 + 6u))),
        dot(w, vec3f(pf(at + V0 + 7u), pf(at + V1 + 7u), pf(at + V2 + 7u))),
        dot(w, vec3f(pf(at + V0 + 8u), pf(at + V1 + 8u), pf(at + V2 + 8u))),
        dot(w, vec3f(pf(at + V0 + 9u), pf(at + V1 + 9u), pf(at + V2 + 9u))));
  } else if (kind == T_SPRITE) {
    // V0: a.x, a.y, a.su, a.sv, the spans; V1: b
    let ax = pf(at + V0);
    let ay = pf(at + V0 + 1u);
    f.su = pf(at + V0 + 2u) +
        (pf(at + V1 + 3u) - pf(at + V0 + 2u)) * (f32(x) + 0.5 - ax) / pf(at + V0 + 4u);
    f.sv = pf(at + V0 + 3u) +
        (pf(at + V1 + 4u) - pf(at + V0 + 3u)) * (f32(y) + 0.5 - ay) / pf(at + V0 + 5u);
    f.z = pf(at + V1 + 2u);
    f.inv_w = 1.0;
    f.color = vec4f(pf(at + V1 + 6u), pf(at + V1 + 7u), pf(at + V1 + 8u),
        pf(at + V1 + 9u));
  } else {
    f.z = pf(at + V0 + 2u);
    f.su = pf(at + V0 + 3u);
    f.sv = pf(at + V0 + 4u);
    f.inv_w = pf(at + V0 + 5u);
    f.color = vec4f(pf(at + V0 + 6u), pf(at + V0 + 7u), pf(at + V0 + 8u),
        pf(at + V0 + 9u));
  }
  shade(st, format, f, p);
}

// P.a: fb byte address, fb width, fb format, z byte address
// P.b: z width, uses depth, tile table word offset, max y
// P.c: tile count
// The tile table holds tile x, tile y, list offset and count per tile.
@compute @workgroup_size(8, 16)
fn raster(@builtin(workgroup_id) wg: vec3u,
    @builtin(local_invocation_id) lid: vec3u) {
  let index = wg.x + wg.y * 65535u;
  if (index >= P.c.x) { return; }
  let tile = P.b.z + index * 4u;
  let x = data[tile] * 16u + lid.x * 2u;
  let y = data[tile + 1u] * 16u + lid.y;
  let list = data[tile + 2u];
  let count = data[tile + 3u];
  let fb = P.a.x;
  let fbw = P.a.y;
  let format = P.a.z;
  let zw = P.b.x;
  let uses_depth = P.b.y != 0u;
  if (x >= fbw || y >= P.b.w) { return; }
  var p0: Pixel;
  var p1: Pixel;
  var cat = 0u;
  if (format == 3u) {
    cat = ((fb + (y * fbw + x) * 4u) & VRAM_MASK) >> 2u;
    p0.color = vram[cat];
    p1.color = vram[(cat + 1u) & (VRAM_MASK >> 2u)];
  } else {
    cat = ((fb + (y * fbw + x) * 2u) & VRAM_MASK) >> 2u;
    let word = vram[cat];
    p0.color = word & 0xffffu;
    p1.color = word >> 16u;
  }
  var zat = 0u;
  if (uses_depth) {
    zat = ((P.a.w + (y * zw + x) * 2u) & VRAM_MASK) >> 2u;
    let word = vram[zat];
    p0.depth = word & 0xffffu;
    p1.depth = word >> 16u;
  }
  for (var i = 0u; i < count; i++) {
    let pi = data[list + i];
    draw(pi, format, x, y, &p0);
    draw(pi, format, x + 1u, y, &p1);
  }
  if (p0.color_dirty || p1.color_dirty) {
    if (format == 3u) {
      if (p0.color_dirty) { vram[cat] = p0.color; }
      if (p1.color_dirty) { vram[(cat + 1u) & (VRAM_MASK >> 2u)] = p1.color; }
    } else {
      vram[cat] = (p0.color & 0xffffu) | (p1.color << 16u);
    }
  }
  if (uses_depth && (p0.depth_dirty || p1.depth_dirty)) {
    vram[zat] = (p0.depth & 0xffffu) | (p1.depth << 16u);
  }
}

// P.a: destination byte offset of the first line, destination pitch bytes,
//      line bytes, lines
// P.b: source byte address of the first line, source pitch bytes, whether
//      the source is in video memory (else in data), words
// P.c: the first destination word
@compute @workgroup_size(64)
fn copy(@builtin(global_invocation_id) gid: vec3u,
    @builtin(num_workgroups) groups: vec3u) {
  let k = gid.x + gid.y * groups.x * 64u;
  if (k >= P.b.w) { return; }
  let word_at = (P.c.x + k) * 4u;
  let index = (word_at & VRAM_MASK) >> 2u;
  var word = vram[index];
  for (var j = 0u; j < 4u; j++) {
    let at = word_at + j;
    if (at < P.a.x) { continue; }
    let rel = at - P.a.x;
    let line = rel / P.a.y;
    let column = rel % P.a.y;
    if (line >= P.a.w || column >= P.a.z) { continue; }
    let source = P.b.x + line * P.b.y + column;
    var byte = 0u;
    if (P.b.z != 0u) {
      byte = vram8(source);
    } else {
      byte = data8(source);
    }
    word = (word & ~(0xffu << (j * 8u))) | (byte << (j * 8u));
  }
  vram[index] = word;
}
''';
