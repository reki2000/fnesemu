// The WGSL program of dc_compute.dart: the pixel pipeline of DcGpuRender
// (gpu_render.dart), DcGpuTexture (gpu_texture.dart), DcGpuFog
// (gpu_fog.dart) and DcGpuModifier (gpu_modifier.dart) on the records of
// gpu_render_record.dart. Edit it here; there is no other copy.
import 'dc_compute.dart';

const dcComputeShader = '''
// One job is a run of region entries of one tile, of which every entry but
// the first keeps the tile of the one before it. A job runs in 16
// workgroups of 64 threads, one thread per pixel of the tile. A thread
// keeps the color, depth and secondary color of its pixel in registers and
// runs the lists of each entry over them in the order of DcGpuRender._tile.

const REC = ${recordWords}u;
const MOD = ${modifierWords}u;
const ENT = ${entryWords}u;
const TEX = ${textureWords}u;
const G_FOG = 1024u;
const G_C = 1152u;
const T_OFF = ${textureOffset}u;
const E_OFF = ${entryOffset}u;
const J_OFF = ${jobOffset}u;

// error codes, as the messages of dc_compute.dart
const E_DEPTH = 1u;
const E_SHADE_DIV = 2u;
const E_UV_DIV = 3u;
const E_SOURCE = 4u;
const E_DEST = 5u;
const E_VRAM = 6u;
const E_CLAMP = 7u;
const E_COORD = 8u;
const E_FOOTPRINT = 9u;
const E_MOD_DEPTH = 10u;
const E_SHADE_DEPTH = 11u;
const E_SUPER_DIV = 12u;

struct Params {
  a: vec4u,
}

@group(0) @binding(0) var<storage, read> vram: array<u32>;
@group(0) @binding(1) var<storage, read> rec: array<u32>;
@group(0) @binding(2) var<storage, read> mods: array<u32>;
@group(0) @binding(3) var<storage, read> tab: array<u32>;
// the tiles of the slots, and then the error code of each entry
@group(0) @binding(4) var<storage, read_write> outc: array<u32>;
@group(0) @binding(5) var<uniform> P: Params;

// the pixel: color, depth, secondary color and whether it is valid
var<private> pc: u32;
var<private> pd: f32;
var<private> ps: u32;
var<private> pv: bool;
var<private> err: u32;
// the sample offsets of ISP, shading and textures
var<private> ispOff: f32;
var<private> pixOff: f32;
var<private> texOff: f32;
var<private> px: u32;
var<private> py: u32;

fn fail(code: u32) {
  if (err == 0u) { err = code; }
}

fn finite(v: f32) -> bool {
  return (bitcast<u32>(v) & 0x7f800000u) != 0x7f800000u;
}

fn recf(i: u32) -> f32 { return bitcast<f32>(rec[i]); }
fn modw(i: u32) -> f32 { return bitcast<f32>(mods[i]); }
fn tabf(i: u32) -> f32 { return bitcast<f32>(tab[i]); }

// Dart's round: half away from zero
fn roundAway(v: f32) -> f32 {
  return sign(v) * floor(abs(v) + 0.5);
}

fn pl(at: u32, x: f32, y: f32) -> f32 {
  return recf(at) * x + recf(at + 1u) * y + recf(at + 2u);
}

fn edgeTest(e: f32, topLeft: bool) -> bool {
  return !(e < 0.0) && !(e == 0.0 && !topLeft);
}

fn covers(r: u32) -> bool {
  let bb = rec[r + 5u];
  if (px < (bb & 255u) || px >= ((bb >> 8u) & 255u) ||
      py < ((bb >> 16u) & 255u) || py >= (bb >> 24u)) {
    return false;
  }
  let x = f32(px) + ispOff;
  let y = f32(py) + ispOff;
  let fl = rec[r + 4u];
  return edgeTest(pl(r + 6u, x, y), (fl & 0x100u) != 0u) &&
      edgeTest(pl(r + 9u, x, y), (fl & 0x200u) != 0u) &&
      edgeTest(pl(r + 12u, x, y), (fl & 0x400u) != 0u);
}

// the ISP depth of a covered pixel
fn ispDepth(r: u32) -> f32 {
  return pl(r + 15u, f32(px) + ispOff, f32(py) + ispOff);
}

fn channel(c: u32, s: u32) -> u32 { return (c >> s) & 255u; }

fn shadowColor(c: u32) -> u32 {
  let s = tab[G_C + 8u] & 255u;
  var result = c & 0xff000000u;
  for (var sh = 0u; sh < 24u; sh += 8u) {
    result |= ((channel(c, sh) * s) >> 8u) << sh;
  }
  return result;
}

fn gouraud(ca: u32, cb: u32, cc: u32, pb: f32, pc: f32) -> u32 {
  if (ca == cb && cb == cc) { return ca; }
  var wb = 0u;
  var wc = 0u;
  if (pb > 0.0) { wb = u32(min(pb * 65536.0 + 0.5, 131072.0)); }
  if (pc > 0.0) { wc = u32(min(pc * 65536.0 + 0.5, 131072.0)); }
  wb = min(wb, 65536u);
  wc = min(wc, 65536u - wb);
  let wa = 65536u - wb - wc;
  var result = 0u;
  for (var sh = 0u; sh < 32u; sh += 8u) {
    result |= ((channel(ca, sh) * wa + channel(cb, sh) * wb +
        channel(cc, sh) * wc + 32768u) >> 16u) << sh;
  }
  return result;
}

fn colorAt(ca: u32, cb: u32, cc: u32, pa: f32, pb: f32, pc: f32,
    plane: bool) -> u32 {
  if (ca == cb && cb == cc) { return cc; }
  if (!plane || (pa >= 0.0 && pb >= 0.0 && pc >= 0.0)) {
    return gouraud(ca, cb, cc, pb, pc);
  }
  var result = 0u;
  for (var sh = 0u; sh < 32u; sh += 8u) {
    let v = floor(f32(channel(ca, sh)) * pa + f32(channel(cb, sh)) * pb +
        f32(channel(cc, sh)) * pc + 0.5);
    result |= u32(clamp(v, 0.0, 255.0)) << sh;
  }
  return result;
}

// ---- textures (DcGpuTexture) ----

struct Tex {
  w: u32,
  h: u32,
  stride: u32,
  fmt: u32,
  base: u32,
  sel: u32,
  fl: u32,
  maxLevel: u32,
  adjust: f32,
  filterMode: u32,
}

const TW_TWIDDLED = 1u;
const TW_MIP = 2u;
const TW_VQ = 4u;
const TW_CLAMP_U = 8u;
const TW_CLAMP_V = 16u;
const TW_FLIP_U = 32u;
const TW_FLIP_V = 64u;
const TW_BILINEAR = 128u;
const TW_SUPER = 256u;
const TW_TRILINEAR = 512u;

fn loadTex(i: u32) -> Tex {
  let t = T_OFF + i * TEX;
  return Tex(tab[t], tab[t + 1u], tab[t + 2u], tab[t + 3u], tab[t + 4u],
      tab[t + 5u], tab[t + 6u], tab[t + 7u], tabf(t + 8u), tab[t + 9u]);
}

fn rgbOffset(e: u32) -> u32 {
  var a = array<u32, 11>(6u, 8u, 0x10u, 0x30u, 0xb0u, 0x2b0u, 0xab0u,
      0x2ab0u, 0xaab0u, 0x2aab0u, 0xaaab0u);
  return a[min(e, 10u)];
}

fn paletteOffset(e: u32) -> u32 {
  var a = array<u32, 11>(3u, 4u, 8u, 0x18u, 0x58u, 0x158u, 0x558u,
      0x1558u, 0x5558u, 0x15558u, 0x55558u);
  return a[min(e, 10u)];
}

fn vqOffset(e: u32) -> u32 {
  var a = array<u32, 11>(0u, 1u, 2u, 6u, 0x16u, 0x56u, 0x156u, 0x556u,
      0x1556u, 0x5556u, 0x15556u);
  return a[min(e, 10u)];
}

// a byte of the 64-bit texture space
fn tbyte(a: u32) -> u32 {
  if (a >= 0x800000u) {
    fail(E_VRAM);
    return 0u;
  }
  let o = (a & 3u) | ((a >> 1u) & 0x3ffffcu) | ((a & 4u) << 20u);
  return (vram[o >> 2u] >> ((o & 3u) * 8u)) & 255u;
}

fn expand(c: u32, bits: u32, repeat: bool) -> u32 {
  if (bits == 1u) { return c * 255u; }
  let shifted = c << (8u - bits);
  if (repeat) { return shifted | (c >> (2u * bits - 8u)); }
  return shifted;
}

fn decode16(v: u32, format: u32, repeat: bool) -> u32 {
  if (format == 3u) { return v; }
  if (format == 1u) {
    return 0xff000000u | (expand((v >> 11u) & 31u, 5u, repeat) << 16u) |
        (expand((v >> 5u) & 63u, 6u, repeat) << 8u) |
        expand(v & 31u, 5u, repeat);
  }
  if (format == 2u) {
    return (expand((v >> 12u) & 15u, 4u, repeat) << 24u) |
        (expand((v >> 8u) & 15u, 4u, repeat) << 16u) |
        (expand((v >> 4u) & 15u, 4u, repeat) << 8u) |
        expand(v & 15u, 4u, repeat);
  }
  return (expand((v >> 15u) & 1u, 1u, repeat) << 24u) |
      (expand((v >> 10u) & 31u, 5u, repeat) << 16u) |
      (expand((v >> 5u) & 31u, 5u, repeat) << 8u) |
      expand(v & 31u, 5u, repeat);
}

fn paletteColor(i: u32) -> u32 {
  return decode16(tab[i & 1023u], tab[G_C], true);
}

fn spread(v: u32) -> u32 {
  var x = v & 0x3ffu;
  x = (x | (x << 8u)) & 0x00ff00ffu;
  x = (x | (x << 4u)) & 0x0f0f0f0fu;
  x = (x | (x << 2u)) & 0x33333333u;
  x = (x | (x << 1u)) & 0x55555555u;
  return x;
}

fn texIndex(t: Tex, x: u32, y: u32, lw: u32, lh: u32) -> u32 {
  if ((t.fl & TW_TWIDDLED) == 0u) { return y * t.stride + x; }
  let bits = min(countTrailingZeros(lw), countTrailingZeros(lh));
  let mask = (1u << bits) - 1u;
  return spread(y & mask) | (spread(x & mask) << 1u) |
      (((x | y) >> bits) << (bits * 2u));
}

fn yuvColor(y: u32, u: u32, v: u32) -> u32 {
  let du = i32(u) - 128;
  let dv = i32(v) - 128;
  let iy = i32(y);
  let r = clamp((iy * 8 + 11 * dv) / 8, 0, 255);
  let g = clamp((iy * 32 - 11 * du - 22 * dv) / 32, 0, 255);
  let b = clamp((iy * 32 + 55 * du) / 32, 0, 255);
  return 0xff000000u | (u32(r) << 16u) | (u32(g) << 8u) | u32(b);
}

fn endpoint(v: u32) -> f32 {
  return select(f32(v), 256.0, v == 255u);
}

fn bumpColor(sr: u32, params: u32) -> u32 {
  let pi = 3.14159265358979;
  let s = endpoint((sr >> 8u) & 255u) * pi / 512.0;
  let r = endpoint(sr & 255u) * (2.0 * pi / 256.0);
  let q = endpoint(params & 255u) * (2.0 * pi / 256.0);
  let k1 = f32((params >> 24u) & 255u);
  let k2 = f32((params >> 16u) & 255u);
  let k3 = f32((params >> 8u) & 255u);
  let a = clamp(roundAway(k1 + k2 * sin(s) + k3 * cos(s) * cos(r - q)),
      0.0, 255.0);
  return (u32(a) << 24u) | 0x00ffffffu;
}

fn decodeTexel(t: Tex, x: u32, y: u32, level: u32, bump: u32) -> u32 {
  let w = max(t.w >> level, 1u);
  let h = max(t.h >> level, 1u);
  let exponent = t.maxLevel - level;
  let mip = (t.fl & TW_MIP) != 0u;
  let vq = (t.fl & TW_VQ) != 0u;
  let index = texIndex(t, x, y, w, h);
  var palOff = 0u;
  if (mip) { palOff = paletteOffset(exponent); }
  if (vq && (t.fmt == 5u || t.fmt == 6u)) {
    var bits = 3u;
    if (t.fmt == 5u) { bits = 4u; }
    let code = tbyte(t.base + 0x800u + (index >> bits));
    let local = index & ((1u << bits) - 1u);
    var at = local;
    if (t.fmt == 5u) { at = local / 2u; }
    let value = tbyte(t.base + code * 8u + at);
    var entry = value;
    if (t.fmt == 5u) { entry = (value >> ((local & 1u) * 4u)) & 15u; }
    return paletteColor(t.sel + entry);
  }
  if (t.fmt == 5u) {
    let nibble = index + palOff;
    let packed = tbyte(t.base + nibble / 2u);
    return paletteColor(t.sel + ((packed >> ((nibble & 1u) * 4u)) & 15u));
  }
  if (t.fmt == 6u) {
    return paletteColor(t.sel + tbyte(t.base + palOff + index));
  }
  if (t.fmt == 3u) {
    if (mip && w == 1u) {
      let a = t.base + rgbOffset(0u);
      return decode16(tbyte(a) | (tbyte(a + 1u) << 8u), 1u, true);
    }
    var first = t.base;
    if (mip) { first += rgbOffset(exponent); }
    let left = first + texIndex(t, x & ~1u, y, w, h) * 2u;
    let right = first + texIndex(t, (x & ~1u) + 1u, y, w, h) * 2u;
    var ya = left;
    if ((x & 1u) != 0u) { ya = right; }
    return yuvColor(tbyte(ya + 1u), tbyte(left), tbyte(right));
  }
  var address: u32;
  if (vq) {
    var vqo = 0u;
    if (mip) { vqo = vqOffset(exponent); }
    var sub = index & 3u;
    if (mip && w == 1u) { sub = 3u; }
    address = t.base + tbyte(t.base + 0x800u + vqo + (index >> 2u)) * 8u +
        sub * 2u;
  } else {
    var ro = 0u;
    if (mip) { ro = rgbOffset(exponent); }
    address = t.base + ro + index * 2u;
  }
  let value = tbyte(address) | (tbyte(address + 1u) << 8u);
  if (t.fmt == 4u) { return bumpColor(value, bump); }
  var format = t.fmt;
  if (format == 7u) { format = 0u; }
  return decode16(value, format, (t.fl & TW_TWIDDLED) != 0u);
}

fn coordinate(value: i32, size: u32, clampIt: bool, flip: bool) -> u32 {
  if (clampIt) { return u32(clamp(value, 0, i32(size) - 1)); }
  let v = bitcast<u32>(value);
  if (!flip) { return v & (size - 1u); }
  let m = v & (size * 2u - 1u);
  return select(m, size * 2u - m - 1u, m >= size);
}

fn texPosition(value: f32, size: u32, clampIt: bool, flip: bool) -> f32 {
  let v = value * f32(size);
  if (v >= 0.0 && v < f32(size - 1u)) { return v; }
  if (!finite(v)) {
    fail(E_COORD);
    return 0.0;
  }
  if (clampIt) {
    let last = f32(size - 1u);
    return select(select(v, last, v > last), 0.0, v < 0.0);
  }
  var m = f32(size);
  if (flip) { m = f32(size * 2u); }
  var r = v - m * floor(v / m);
  if (r >= m) { r -= m; }
  if (r < 0.0) { r = 0.0; }
  return r;
}

fn level(t: Tex, footprint: f32) -> u32 {
  if (!finite(footprint) || footprint < 0.0) {
    fail(E_FOOTPRINT);
    return 0u;
  }
  if ((t.fl & TW_MIP) == 0u) { return 0u; }
  var value = footprint * t.adjust;
  if (value >= f32(t.w)) { return t.maxLevel; }
  var l = 0u;
  if (value >= 256.0) {
    value *= 0.00390625;
    l = 8u;
  }
  if (value >= 16.0) {
    value *= 0.0625;
    l += 4u;
  }
  if (value >= 4.0) {
    value *= 0.25;
    l += 2u;
  }
  if (value >= 2.0) { l += 1u; }
  return min(l, t.maxLevel);
}

fn selectLevel(t: Tex, footprint: f32) -> u32 {
  let l = level(t, footprint);
  var selected = l;
  if ((t.fl & TW_TRILINEAR) != 0u && t.filterMode == 3u) {
    selected = min(l + 1u, t.maxLevel);
  }
  if ((t.fl & TW_SUPER) != 0u && selected > 0u) { selected -= 1u; }
  return selected;
}

fn passWeight(t: Tex, footprint: f32) -> f32 {
  if ((t.fl & TW_TRILINEAR) == 0u) { return 1.0; }
  let l = level(t, footprint);
  var fraction = 0.0;
  if (l != t.maxLevel) {
    fraction = clamp(footprint * t.adjust / f32(1u << l) - 1.0, 0.0, 1.0);
  }
  if (t.filterMode == 2u) { return 1.0 - fraction; }
  return fraction;
}

fn applyPassWeight(c: u32, weight: f32) -> u32 {
  if (weight == 1.0) { return c; }
  var result = 0u;
  for (var sh = 0u; sh < 32u; sh += 8u) {
    let v = i32(f32(channel(c, sh)) * weight + 0.5);
    result |= u32(clamp(v, 0, 255)) << sh;
  }
  return result;
}

fn footprint(t: Tex, duDx: f32, dvDx: f32, duDy: f32, dvDy: f32) -> f32 {
  let ux = duDx * f32(t.w);
  let vx = dvDx * f32(t.h);
  let uy = duDy * f32(t.w);
  let vy = dvDy * f32(t.h);
  let x = ux * ux + vx * vx;
  let y = uy * uy + vy * vy;
  return sqrt(max(x, y));
}

fn sample1(t: Tex, u: f32, v: f32, fp: f32, bump: u32) -> u32 {
  if (!finite(u) || !finite(v)) {
    fail(E_COORD);
    return 0u;
  }
  var l = 0u;
  if ((t.fl & TW_MIP) != 0u) { l = selectLevel(t, fp); }
  let w = max(t.w >> l, 1u);
  let h = max(t.h >> l, 1u);
  let cu = (t.fl & TW_CLAMP_U) != 0u;
  let cv = (t.fl & TW_CLAMP_V) != 0u;
  let fu = (t.fl & TW_FLIP_U) != 0u;
  let fv = (t.fl & TW_FLIP_V) != 0u;
  let x = texPosition(u, w, cu, fu);
  let y = texPosition(v, h, cv, fv);
  let left = i32(x);
  let top = i32(y);
  let x0 = coordinate(left, w, cu, fu);
  let y0 = coordinate(top, h, cv, fv);
  // The texels are read in a loop, so that the read is compiled once.
  let bilinear = (t.fl & TW_BILINEAR) != 0u;
  var x1 = x0;
  var y1 = y0;
  if (bilinear) {
    x1 = coordinate(left + 1, w, cu, fu);
    y1 = coordinate(top + 1, h, cv, fv);
  }
  // the weights of the columns, and the sums of the two rows
  let fx = u32((x - f32(left)) * 256.0 + 0.5);
  let fy = u32((y - f32(top)) * 256.0 + 0.5);
  var upper = vec4u(0u);
  var lower = vec4u(0u);
  var texel = 0u;
  let n = select(1u, 4u, bilinear);
  for (var k = 0u; k < n; k++) {
    texel = decodeTexel(t, select(x0, x1, (k & 1u) != 0u),
        select(y0, y1, (k & 2u) != 0u), l, bump);
    let weighted = vec4u(channel(texel, 0u), channel(texel, 8u),
        channel(texel, 16u), channel(texel, 24u)) *
        select(256u - fx, fx, (k & 1u) != 0u);
    if (k < 2u) {
      upper += weighted;
    } else {
      lower += weighted;
    }
  }
  if (!bilinear) { return texel; }
  let rows = (((upper + 128u) >> vec4u(8u)) * (256u - fy) +
      ((lower + 128u) >> vec4u(8u)) * fy + 128u) >> vec4u(8u);
  let c = rows & vec4u(255u);
  return c.x | (c.y << 8u) | (c.z << 16u) | (c.w << 24u);
}

fn shadeTex(color: u32, texelIn: u32, offset: u32, tsp: u32) -> u32 {
  var texel = texelIn;
  if ((tsp & 0x80000u) != 0u) { texel |= 0xff000000u; }
  let alpha = texel >> 24u;
  let mode = (tsp >> 6u) & 3u;
  let tr = channel(texel, 16u);
  let tg = channel(texel, 8u);
  let tb = channel(texel, 0u);
  var r: u32;
  var g: u32;
  var b: u32;
  var a: u32;
  if (mode == 0u) {
    r = tr;
    g = tg;
    b = tb;
    a = alpha;
  } else {
    let cr = channel(color, 16u);
    let cg = channel(color, 8u);
    let cb = channel(color, 0u);
    let ca = color >> 24u;
    if (mode == 2u) {
      let inverse = 255u - alpha;
      r = (tr * alpha + cr * inverse + 127u) / 255u;
      g = (tg * alpha + cg * inverse + 127u) / 255u;
      b = (tb * alpha + cb * inverse + 127u) / 255u;
      a = ca;
    } else {
      r = (cr * tr + 127u) / 255u;
      g = (cg * tg + 127u) / 255u;
      b = (cb * tb + 127u) / 255u;
      if (mode == 1u) {
        a = alpha;
      } else {
        a = (ca * alpha + 127u) / 255u;
      }
    }
  }
  if (offset != 0u) {
    r = min(r + channel(offset, 16u), 255u);
    g = min(g + channel(offset, 8u), 255u);
    b = min(b + channel(offset, 0u), 255u);
  }
  return (a << 24u) | (r << 16u) | (g << 8u) | b;
}

// ---- fog and color clamp (DcGpuFog) ----

fn fogCoefficient(depth: f32) -> f32 {
  let scaled = depth * tabf(G_C + 3u);
  var mantissa = 255.9999;
  if (scaled < 255.9999) { mantissa = select(1.0, scaled, scaled > 1.0); }
  var index = 0u;
  if (mantissa >= 16.0) {
    mantissa *= 0.0625;
    index = 64u;
  }
  if (mantissa >= 4.0) {
    mantissa *= 0.25;
    index += 32u;
  }
  if (mantissa >= 2.0) {
    mantissa *= 0.5;
    index += 16u;
  }
  let pos = (mantissa - 1.0) * 16.0;
  let whole = u32(pos);
  index += whole;
  let fraction = pos - f32(whole);
  let pair = tab[G_FOG + min(index, 127u)];
  return f32(pair >> 8u) * (1.0 - fraction) + f32(pair & 255u) * fraction;
}

fn fog(colorIn: u32, depth: f32, offset: u32, tsp: u32, hasOffset: bool) -> u32 {
  var color = colorIn;
  if ((tsp & 0x200000u) != 0u) {
    if (tab[G_C + 6u] != 0u) { fail(E_CLAMP); }
    let lo = tab[G_C + 4u];
    let hi = tab[G_C + 5u];
    var clamped = 0u;
    for (var sh = 0u; sh < 32u; sh += 8u) {
      clamped |= clamp(channel(color, sh), channel(lo, sh), channel(hi, sh)) << sh;
    }
    color = clamped;
  }
  let mode = (tsp >> 22u) & 3u;
  if (mode == 2u || (mode == 1u && !hasOffset)) { return color; }
  var coefficient: f32;
  var fogColor: u32;
  if (mode == 1u) {
    coefficient = f32(offset >> 24u);
    fogColor = tab[G_C + 2u];
  } else {
    coefficient = fogCoefficient(depth);
    fogColor = tab[G_C + 1u];
  }
  if (mode == 3u) {
    return (u32(roundAway(coefficient)) << 24u) | fogColor;
  }
  if (coefficient == 0.0) { return color; }
  if (coefficient == 255.0) {
    return (color & 0xff000000u) | (fogColor & 0xffffffu);
  }
  let w = u32(coefficient * (256.0 / 255.0) + 0.5);
  var result = color & 0xff000000u;
  for (var sh = 0u; sh < 24u; sh += 8u) {
    result |= (((channel(color, sh) * (256u - w) + channel(fogColor, sh) * w +
        128u) >> 8u) & 255u) << sh;
  }
  return result;
}

// ---- shading of a fragment (the general loop of DcGpuRender._triangle) ----

fn shade(r: u32, shadowOn: bool) -> u32 {
  let isp = rec[r];
  let tsp = rec[r + 1u];
  let fl = rec[r + 4u];
  if ((tsp & 0x02000000u) != 0u) { return 0u; }
  let sx = f32(px) + pixOff;
  let sy = f32(py) + pixOff;
  let sd = pl(r + 15u, sx, sy);
  if (!finite(sd)) {
    fail(E_SHADE_DEPTH);
    return 0u;
  }
  var color = rec[r + 35u];
  var off = rec[r + 38u];
  if ((isp & 0x00800000u) != 0u) {
    if (sd == 0.0) {
      fail(E_SHADE_DIV);
      return 0u;
    }
    let inverse = 1.0 / sd;
    let pa = pl(r + 24u, sx, sy) * inverse;
    let pb = pl(r + 27u, sx, sy) * inverse;
    let pc3 = pl(r + 30u, sx, sy) * inverse;
    let plane = (fl & 32u) != 0u;
    color = colorAt(rec[r + 33u], rec[r + 34u], rec[r + 35u], pa, pb, pc3, plane);
    off = colorAt(rec[r + 36u], rec[r + 37u], rec[r + 38u], pa, pb, pc3, plane);
  }
  if (shadowOn) {
    color = shadowColor(color);
    off = shadowColor(off);
  }
  if ((tsp & 0x100000u) == 0u) { color |= 0xff000000u; }
  let ti = rec[r + 2u];
  let textured = ti != 0xffffffffu;
  var fp = 1.0;
  var t: Tex;
  if (textured) {
    t = loadTex(ti);
    let tx = f32(px) + texOff;
    let ty = f32(py) + texOff;
    let den = pl(r + 15u, tx, ty);
    if (den == 0.0) {
      fail(E_UV_DIV);
      return 0u;
    }
    let inverse = 1.0 / den;
    let u = pl(r + 18u, tx, ty) * inverse;
    let v = pl(r + 21u, tx, ty) * inverse;
    if ((t.fl & TW_MIP) != 0u) {
      let square = inverse * inverse;
      fp = footprint(t, recf(r + 39u) * square, recf(r + 40u) * square,
          recf(r + 41u) * square, recf(r + 42u) * square);
    }
    // Supersampling takes four samples, else one, in a loop, so that the
    // sample is compiled once.
    let supersample = (t.fl & TW_SUPER) != 0u;
    var texel = 0u;
    var sum = vec4u(0u);
    let n = select(1u, 4u, supersample);
    for (var k = 0u; k < n; k++) {
      var su = u;
      var sv = v;
      if (k != 0u) {
        let qx = tx + select(0.0, 0.5, k != 2u);
        let qy = ty + select(0.0, 0.5, k != 1u);
        let divisor = pl(r + 15u, qx, qy);
        if (divisor == 0.0) {
          fail(E_SUPER_DIV);
          return 0u;
        }
        su = pl(r + 18u, qx, qy) / divisor;
        sv = pl(r + 21u, qx, qy) / divisor;
      }
      texel = sample1(t, su, sv, fp, off);
      sum += vec4u(channel(texel, 0u), channel(texel, 8u),
          channel(texel, 16u), channel(texel, 24u));
    }
    if (supersample) {
      sum = (sum + 2u) / 4u;
      texel = sum.x | (sum.y << 8u) | (sum.z << 16u) | (sum.w << 24u);
    }
    color = shadeTex(color, texel, select(off, 0u, t.fmt == 4u), tsp);
  }
  let fogDepth = select(sd, recf(r + 43u), (fl & 64u) != 0u);
  color = fog(color, fogDepth, off, tsp,
      textured && (isp & 0x01000000u) != 0u);
  if (textured && (t.fl & TW_TRILINEAR) != 0u) {
    color = applyPassWeight(color, passWeight(t, fp));
  }
  return color;
}

fn shadowOf(r: u32, mask: u32) -> bool {
  let fl = rec[r + 4u];
  if ((fl & 16u) == 0u || (tab[G_C + 8u] & 0x100u) == 0u) { return false; }
  let area = (fl >> 2u) & 3u;
  if (area == 0u) { return mask != 0u; }
  return area == 2u;
}

// the material area of a record, or -1
fn materialArea(r: u32) -> i32 {
  return i32(rec[r + 4u] & 3u) - 1;
}

// ---- the tile buffers ----

fn store(color: u32, tsp: u32) {
  if ((tsp & 0x01000000u) != 0u) {
    ps = color;
    pv = true;
  } else {
    pc = color;
  }
}

fn sourceColor(color: u32, tsp: u32) -> u32 {
  if ((tsp & 0x02000000u) != 0u) {
    if (!pv) { fail(E_SOURCE); }
    return ps;
  }
  return color;
}

fn factor(inst: u32, other: u32, sa: u32, da: u32) -> u32 {
  switch (inst) {
    case 0u: { return 0u; }
    case 1u: { return 255u; }
    case 2u: { return other; }
    case 3u: { return 255u - other; }
    case 4u: { return sa; }
    case 5u: { return 255u - sa; }
    case 6u: { return da; }
    default: { return 255u - da; }
  }
}

fn blend(s: u32, d: u32, tsp: u32) -> u32 {
  let si = (tsp >> 29u) & 7u;
  let di = (tsp >> 26u) & 7u;
  if (si == 1u && di == 0u) { return s; }
  let sa = s >> 24u;
  let da = d >> 24u;
  var result = 0u;
  for (var sh = 0u; sh < 32u; sh += 8u) {
    let src = channel(s, sh);
    let dst = channel(d, sh);
    let sum = (src * factor(si, dst, sa, da) + dst * factor(di, src, sa, da) +
        127u) / 255u;
    result |= min(sum, 255u) << sh;
  }
  return result;
}

fn composite(color: u32, tsp: u32) {
  let source = sourceColor(color, tsp);
  var destination = pc;
  if ((tsp & 0x01000000u) != 0u) {
    let sf = (tsp >> 29u) & 7u;
    let df = (tsp >> 26u) & 7u;
    if ((df != 0u || ((0xccu >> sf) & 1u) != 0u) && !pv) { fail(E_DEST); }
    destination = select(0u, ps, pv);
  }
  store(blend(source, destination, tsp), tsp);
}

fn depthPass(mode: u32, z: f32, previous: f32) -> bool {
  switch (mode) {
    case 0u: { return false; }
    case 1u: { return z < previous; }
    case 2u: { return z == previous; }
    case 3u: { return z <= previous; }
    case 4u: { return z > previous; }
    case 5u: { return z != previous; }
    case 6u: { return z >= previous; }
    default: { return true; }
  }
}

// ---- the lists of an entry ----

fn background(e: u32, mask: u32) {
  pd = tabf(e + 14u);
  pv = false;
  pc = 0u;
  let first = tab[e + 2u];
  let count = tab[e + 3u];
  for (var i = 0u; i < count; i++) {
    let r = (first + i) * REC;
    let fl = rec[r + 4u];
    let tsp = rec[r + 1u];
    let area = materialArea(r);
    if (area >= 0 && mask != u32(area)) { continue; }
    if ((fl & 128u) != 0u) {
      let shadow = (fl & 16u) != 0u;
      store(select(rec[r + 33u], rec[r + 34u],
          shadow && area < 0 && mask != 0u), tsp);
    } else {
      store(shade(r, shadowOf(r, mask)), tsp);
    }
  }
}

// the depths of the opaque list alone, as the first visibility pass
fn opaqueDepths(e: u32) {
  let first = tab[e + 4u];
  let count = tab[e + 5u];
  for (var i = 0u; i < count; i++) {
    let r = (first + i) * REC;
    if (!covers(r)) { continue; }
    let z = ispDepth(r);
    if (!finite(z)) {
      fail(E_DEPTH);
      continue;
    }
    if (materialArea(r) > 0) { continue; }
    let isp = rec[r];
    if (!depthPass(isp >> 29u, z, pd)) { continue; }
    if ((isp & 0x04000000u) == 0u) { pd = z; }
  }
}

// the opaque list or a presorted translucent list
fn ordered(first: u32, count: u32, mask: u32) {
  for (var i = 0u; i < count; i++) {
    let r = (first + i) * REC;
    if (!covers(r)) { continue; }
    let z = ispDepth(r);
    if (!finite(z)) {
      fail(E_DEPTH);
      continue;
    }
    let area = materialArea(r);
    if (area >= 0 && mask != u32(area)) { continue; }
    let isp = rec[r];
    if (!depthPass(isp >> 29u, z, pd)) { continue; }
    composite(shade(r, shadowOf(r, mask)), rec[r + 1u]);
    if ((isp & 0x04000000u) == 0u) { pd = z; }
  }
}

fn punch(e: u32, mask: u32) {
  let first = tab[e + 6u];
  let count = tab[e + 7u];
  let reference = tab[G_C + 9u];
  var found = false;
  var cz = 0.0;
  var cc = 0u;
  var cr = 0u;
  for (var i = 0u; i < count; i++) {
    let r = (first + i) * REC;
    if (!covers(r)) { continue; }
    let z = ispDepth(r);
    if (!finite(z)) {
      fail(E_DEPTH);
      continue;
    }
    let area = materialArea(r);
    if (area >= 0 && mask != u32(area)) { continue; }
    if (!(z >= pd)) { continue; }
    if (found && z < cz) { continue; }
    let color = shade(r, shadowOf(r, mask));
    if ((sourceColor(color, rec[r + 1u]) >> 24u) < reference) { continue; }
    found = true;
    cz = z;
    cc = color;
    cr = r;
  }
  if (!found) { return; }
  let tsp = rec[cr + 1u];
  store(sourceColor(cc, tsp) | 0xff000000u, tsp);
  if ((rec[cr] & 0x04000000u) == 0u) { pd = cz; }
}

// the modifier area of the volumes of the list at [depth]
fn modifierArea(first: u32, count: u32, depth: f32) -> u32 {
  var area = 0u;
  var parity = 0u;
  let x = f32(px) + ispOff;
  let y = f32(py) + ispOff;
  for (var i = 0u; i < count; i++) {
    let m = (first + i) * MOD;
    let fl = mods[m];
    if ((fl & 1u) != 0u) {
      let bb = mods[m + 1u];
      if (px >= (bb & 255u) && px < ((bb >> 8u) & 255u) &&
          py >= ((bb >> 16u) & 255u) && py < (bb >> 24u)) {
        let e0 = modw(m + 2u) * x + modw(m + 3u) * y + modw(m + 4u);
        let e1 = modw(m + 5u) * x + modw(m + 6u) * y + modw(m + 7u);
        let e2 = modw(m + 8u) * x + modw(m + 9u) * y + modw(m + 10u);
        if (edgeTest(e0, (fl & 0x100u) != 0u) &&
            edgeTest(e1, (fl & 0x200u) != 0u) &&
            edgeTest(e2, (fl & 0x400u) != 0u)) {
          let z = modw(m + 11u) * x + modw(m + 12u) * y + modw(m + 13u);
          if (!finite(z)) { fail(E_MOD_DEPTH); }
          if (z >= depth) { parity ^= 1u; }
        }
      }
    }
    let close = (fl >> 1u) & 3u;
    if (close == 1u) {
      area |= parity;
      parity = 0u;
    } else if (close == 2u) {
      area &= parity ^ 1u;
      parity = 0u;
    }
  }
  return area;
}

const MAX_FRAGMENTS = 16u;

// the sorted fragments of each thread of a workgroup: depth, order and
// record, MAX_FRAGMENTS per thread from slot * MAX_FRAGMENTS
var<workgroup> fz: array<f32, 1024>;
var<workgroup> fo: array<i32, 1024>;
var<workgroup> fr: array<u32, 1024>;
var<private> slot: u32;

// The translucent fragment of a record, if it covers the pixel in front of
// the opaque depth.
fn fragment(r: u32, opaqueDepth: f32, modified: bool, z: ptr<function, f32>) -> bool {
  if (!covers(r)) { return false; }
  *z = ispDepth(r);
  if (!finite(*z)) {
    fail(E_DEPTH);
    return false;
  }
  if (!modified && materialArea(r) > 0) { return false; }
  return *z >= opaqueDepth;
}

// The material of a layer of fragments of one order: the first whose
// modifier area tag is 0 or matches [mask].
fn chooses(r: u32, mask: u32) -> bool {
  let fl = rec[r + 4u];
  var tag = fl & 3u;
  if (tag == 0u) { tag = (fl >> 2u) & 3u; }
  return tag == 0u || tag == mask + 1u;
}

// Auto-sorted translucent fragments, composited in ascending depth and
// order. With [modified], the modifier area of each layer chooses its
// material. The fragments of a pixel are sorted in registers; a pixel with
// more of them peels one layer per pass.
fn sorted(e: u32, modified: bool) {
  let first = tab[e + 8u];
  let count = tab[e + 9u];
  let opaqueDepth = pd;
  let s0 = slot * MAX_FRAGMENTS;
  var n = 0u;
  var overflow = false;
  for (var i = 0u; i < count; i++) {
    let r = (first + i) * REC;
    var z: f32;
    if (!fragment(r, opaqueDepth, modified, &z)) { continue; }
    if (n == MAX_FRAGMENTS) {
      overflow = true;
      break;
    }
    // Stable insertion: a fragment goes after those with an equal key.
    let o = bitcast<i32>(rec[r + 3u]);
    var k = s0 + n;
    while (k > s0 && (fz[k - 1u] > z || (fz[k - 1u] == z && fo[k - 1u] > o))) {
      fz[k] = fz[k - 1u];
      fo[k] = fo[k - 1u];
      fr[k] = fr[k - 1u];
      k--;
    }
    fz[k] = z;
    fo[k] = o;
    fr[k] = r;
    n++;
  }
  if (overflow) {
    peeled(e, modified, opaqueDepth);
    return;
  }
  let end = s0 + n;
  var k = s0;
  while (k < end) {
    let z = fz[k];
    let o = fo[k];
    var chosen = fr[k];
    var any = true;
    if (modified) {
      let mask = modifierArea(tab[e + 12u], tab[e + 13u], z);
      any = false;
      for (var j = k; j < end && fz[j] == z && fo[j] == o; j++) {
        if (chooses(fr[j], mask)) {
          chosen = fr[j];
          any = true;
          break;
        }
      }
    }
    // the rest of the layer
    var next = k + 1u;
    while (next < end && fz[next] == z && fo[next] == o) { next++; }
    k = next;
    if (!any) { continue; }
    composite(shade(chosen, shadowOf(chosen, 0u)), rec[chosen + 1u]);
    if ((rec[chosen] & 0x04000000u) == 0u) { pd = z; }
  }
}

// [sorted] one layer per pass, for pixels with many fragments.
fn peeled(e: u32, modified: bool, opaqueDepth: f32) {
  let first = tab[e + 8u];
  let count = tab[e + 9u];
  var started = false;
  var lz = 0.0;
  var lo = 0;
  for (var layer = 0u; layer <= count; layer++) {
    var found = false;
    var bz = 0.0;
    var bo = 0;
    var br = 0u;
    for (var i = 0u; i < count; i++) {
      let r = (first + i) * REC;
      var z: f32;
      if (!fragment(r, opaqueDepth, modified, &z)) { continue; }
      let o = bitcast<i32>(rec[r + 3u]);
      if (started && !(z > lz || (z == lz && o > lo))) { continue; }
      if (!found || z < bz || (z == bz && o < bo)) {
        found = true;
        bz = z;
        bo = o;
        br = r;
      }
    }
    if (!found) { return; }
    started = true;
    lz = bz;
    lo = bo;
    var chosen = br;
    var shadowOn = shadowOf(br, 0u);
    if (modified) {
      let mask = modifierArea(tab[e + 12u], tab[e + 13u], bz);
      var any = false;
      for (var i = 0u; i < count; i++) {
        let r = (first + i) * REC;
        if (bitcast<i32>(rec[r + 3u]) != bo || !covers(r) || ispDepth(r) != bz) {
          continue;
        }
        if (chooses(r, mask)) {
          chosen = r;
          any = true;
          break;
        }
      }
      if (!any) { continue; }
      shadowOn = shadowOf(chosen, 0u);
    }
    composite(shade(chosen, shadowOn), rec[chosen + 1u]);
    if ((rec[chosen] & 0x04000000u) == 0u) { pd = bz; }
  }
}

// The steps of a region entry, 4 bits each from bit 0, so that each list
// pass is called from one place.
const S_BACKGROUND = 1u;
const S_DEPTHS = 2u;
const S_PUNCH_FIRST = 3u;
const S_MASKS = 4u;
const S_BACKGROUND_MASKED = 5u;
const S_OPAQUE = 6u;
const S_PUNCH = 7u;
const S_PRESORTED = 8u;
const S_SORTED = 9u;
const S_SORTED_MODIFIED = 10u;

fn runEntry(index: u32, pixel: u32) {
  let e = E_OFF + index * ENT;
  let flags = tab[e];
  err = 0u;
  let modified = (flags & 4u) != 0u;
  var steps = 0u;
  var n = 0u;
  if ((flags & 1u) != 0u) {
    steps |= S_BACKGROUND << (n * 4u);
    n++;
  }
  if (modified) {
    // The opaque and punch-through depths choose the modifier area of the
    // pixel; the pixel then returns to the background.
    steps |= (S_DEPTHS | (S_PUNCH_FIRST << 4u) | (S_MASKS << 8u)) << (n * 4u);
    n += 3u;
    if ((flags & 2u) != 0u) {
      steps |= S_BACKGROUND_MASKED << (n * 4u);
      n++;
    }
  }
  steps |= (S_OPAQUE | (S_PUNCH << 4u)) << (n * 4u);
  n += 2u;
  let mode = (flags >> 3u) & 3u;
  if (mode != 0u) {
    steps |= (S_PRESORTED - 1u + mode) << (n * 4u);
    n++;
  }
  var mask = 0u;
  var backgroundMask = 0u;
  var color = 0u;
  var depth = 0.0;
  var secondary = 0u;
  var valid = false;
  for (var i = 0u; i < n; i++) {
    let op = (steps >> (i * 4u)) & 15u;
    if (op == S_BACKGROUND || op == S_BACKGROUND_MASKED) {
      background(e, select(0u, backgroundMask, op == S_BACKGROUND_MASKED));
    } else if (op == S_DEPTHS) {
      color = pc;
      depth = pd;
      secondary = ps;
      valid = pv;
      opaqueDepths(e);
    } else if (op == S_PUNCH_FIRST || op == S_PUNCH) {
      punch(e, select(0u, mask, op == S_PUNCH));
    } else if (op == S_MASKS) {
      mask = modifierArea(tab[e + 10u], tab[e + 11u], pd);
      if ((flags & 2u) != 0u) {
        backgroundMask = modifierArea(tab[e + 10u], tab[e + 11u], depth);
      }
      pc = color;
      pd = depth;
      ps = secondary;
      pv = valid;
    } else if (op == S_OPAQUE || op == S_PRESORTED) {
      let list = select(4u, 8u, op == S_PRESORTED);
      ordered(tab[e + list], tab[e + list + 1u],
          select(mask, 0u, op == S_PRESORTED));
    } else {
      sorted(e, op == S_SORTED_MODIFIED);
    }
  }
  if ((flags & 32u) != 0u) { outc[tab[e + 1u] * 1024u + pixel] = pc; }
  // one of the codes of the pixels that failed
  if (err != 0u) { outc[P.a.y * 1024u + index] = err; }
}

@compute @workgroup_size(64)
fn tile(@builtin(workgroup_id) wg: vec3u,
    @builtin(local_invocation_id) lid: vec3u) {
  let job = wg.y;
  if (job >= P.a.x) { return; }
  let pixel = wg.x * 64u + lid.x;
  slot = lid.x;
  px = pixel & 31u;
  py = pixel >> 5u;
  let control = tab[G_C + 7u];
  ispOff = select(0.0, 0.5, (control & 1u) != 0u);
  pixOff = select(0.0, 0.5, (control & 2u) != 0u);
  texOff = select(0.0, 0.5, (control & 4u) != 0u);
  pc = 0u;
  pd = 0.0;
  ps = 0u;
  pv = false;
  let first = tab[J_OFF + job * 2u];
  let count = tab[J_OFF + job * 2u + 1u];
  for (var k = 0u; k < count; k++) {
    runEntry(first + k, pixel);
  }
}
''';
