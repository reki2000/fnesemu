// A compute GS: the 4 MiB local memory is a storage buffer, and the steps of
// lib/compute_gs.dart draw into it in order. The pixel pipeline follows
// GsRaster of the core (packages/fnesemu_core/lib/src/core/ps2/gs/
// gs_raster.dart) step by step, so that a frame can be compared with it.
//
// Entry points, one per step kind:
//   setup     per primitive: bounds and edges into setups
//   raster    one 16x16 tile per workgroup: the primitives of a batch in
//             order, the frame and depth of the pixel kept in registers
//   clut      CLUT versions from descriptors
//   upload    host to local transfer words into pixels
//   copy      local to local transfer from the snapshot
//   snapshot  pages of vram into snap
//
// The constants below match lib/compute_gs.dart.

const PRIM_WORDS = 28u;
const SETUP_WORDS = 12u;

// state words
const S_FBP = 0u;
const S_FPAGES = 1u;
const S_FPSM = 2u;
const S_FCOLOR = 3u;
const S_FBMSK = 4u;
const S_FBA = 5u;
const S_ZBP = 6u;
const S_ZPAGES = 7u;
const S_ZPSM = 8u;
const S_ZMSK = 9u;
const S_ZMAX = 10u;
const S_OFX = 11u;
const S_OFY = 12u;
const S_SX0 = 13u;
const S_SX1 = 14u;
const S_SY0 = 15u;
const S_SY1 = 16u;
const S_TEST = 17u;
const S_ALPHA = 18u;
const S_FIX = 19u;
const S_PABE = 20u;
const S_COLCLAMP = 21u;
const S_DTHE = 22u;
const S_DIMX_LO = 23u;
const S_DIMX_HI = 24u;
const S_FOGCOL = 25u;
const S_TPSM = 27u;
const S_TCOLOR = 28u;
const S_TCC = 29u;
const S_TFX = 30u;
const S_CLUTPSM = 31u;
const S_CLUTOFF = 32u;
const S_WMS = 33u;
const S_WMT = 34u;
const S_MINU = 35u;
const S_MAXU = 36u;
const S_MINV = 37u;
const S_MAXV = 38u;
const S_LINEAR = 39u;
const S_TA0 = 40u;
const S_TA1 = 41u;
const S_AEM = 42u;
const S_LCM = 43u;
const S_MIPMAP = 44u;
const S_MXL = 45u;
const S_MMIN = 46u;
const S_L = 47u;
const S_K = 48u;
const S_MIPTBP = 49u;
const S_MIPPAGES = 56u;
const S_MIPTW = 63u;
const S_MIPTH = 70u;

// prim header bits
const KIND_TRIANGLE = 1u;
const KIND_SPRITE = 2u;
const KIND_POINT = 3u;

const CT32 = 0x00u;
const CT24 = 0x01u;
const CT16 = 0x02u;
const CT16S = 0x0au;
const T8 = 0x13u;
const T4 = 0x14u;
const T8H = 0x1bu;
const T4HL = 0x24u;
const T4HH = 0x2cu;
const Z32 = 0x30u;
const Z24 = 0x31u;
const Z16 = 0x32u;
const Z16S = 0x3au;

struct Params {
  a: vec4u,
  b: vec4u,
  c: vec4u,
  d: vec4u,
}

@group(0) @binding(0) var<storage, read_write> vram: array<atomic<u32>>;
@group(0) @binding(1) var<storage, read_write> snap: array<u32>;
@group(0) @binding(2) var<storage, read> prims: array<u32>;
@group(0) @binding(3) var<storage, read_write> setups: array<u32>;
@group(0) @binding(4) var<storage, read> data: array<u32>;
@group(0) @binding(5) var<storage, read_write> cluts: array<u32>;
@group(0) @binding(6) var<uniform> P: Params;

// ---- local memory layout (GsMemory.unitIndex) ----

fn is16(psm: u32) -> bool {
  return psm == CT16 || psm == CT16S || psm == Z16 || psm == Z16S;
}

fn x_bits(psm: u32) -> u32 {
  if (psm == T8 || psm == T4) { return 7u; }
  return 6u;
}

fn y_bits(psm: u32) -> u32 {
  if (is16(psm) || psm == T8) { return 6u; }
  if (psm == T4) { return 7u; }
  return 5u;
}

fn unit_shift(psm: u32) -> u32 {
  if (is16(psm)) { return 1u; }
  if (psm == T8) { return 2u; }
  if (psm == T4) { return 3u; }
  return 0u;
}

// the blocks of a 32-bit page, 8 columns by 4 rows
fn blk32(c: u32, r: u32) -> u32 {
  return (c & 1u) | ((r & 1u) << 1u) | (((c >> 1u) & 1u) << 2u) |
      (((r >> 1u) & 1u) << 3u) | (((c >> 2u) & 1u) << 4u);
}

fn col32(x: u32, y: u32) -> u32 {
  return ((x >> 1u) & 3u) * 4u + (y & 1u) * 2u + (x & 1u);
}

// the word of pixel (x, y) of a 32-bit page at block 0
fn page32(x: u32, y: u32) -> u32 {
  return blk32((x >> 3u) & 7u, (y >> 3u) & 3u) * 64u + ((y >> 1u) & 3u) * 16u +
      col32(x & 7u, y & 1u);
}

fn col8(x: u32, y: u32) -> u32 {
  let cx = select(x, x ^ 4u, (y & 2u) != 0u);
  return (cx & 1u) * 4u + ((cx >> 1u) & 1u) * 16u + ((cx >> 2u) & 1u) * 32u +
      ((cx >> 3u) & 1u) * 2u + (y & 1u) * 8u + ((y >> 1u) & 1u);
}

// the unit of pixel (x, y) inside a page of the format
fn in_page(psm: u32, x: u32, y: u32) -> u32 {
  let z = psm >= Z32;
  if (is16(psm)) {
    let r = (y >> 3u) & 7u;
    let c = (x >> 4u) & 3u;
    var block: u32;
    if (psm == CT16S || psm == Z16S) {
      block = (r & 1u) | (((r >> 1u) & 1u) << 3u) | (((r >> 2u) & 1u) << 2u) |
          ((c & 1u) << 1u) | (((c >> 1u) & 1u) << 4u);
    } else {
      block = (r & 1u) | (c << 1u) | ((r >> 1u) << 3u);
    }
    if (z) { block ^= 24u; }
    let cx = x & 15u;
    let column = ((cx & 1u) << 1u) | (((cx >> 1u) & 1u) << 3u) |
        (((cx >> 2u) & 1u) << 4u) | ((cx >> 3u) & 1u) | ((y & 1u) << 2u);
    return block * 128u + ((y >> 1u) & 3u) * 32u + column;
  }
  if (psm == T8) {
    let block = blk32((x >> 4u) & 7u, (y >> 4u) & 3u);
    let column = (y >> 2u) & 3u;
    let cx = select((x & 15u) ^ 4u, x & 15u, (column & 1u) == 0u);
    return block * 256u + column * 64u + col8(cx, y & 3u);
  }
  if (psm == T4) {
    let lx = x & 127u;
    let ly = y & 127u;
    let swap = select(4u, 0u, (((ly + 2u) >> 2u) & 1u) == 0u);
    let cx = ((ly & ~15u) >> 1u) | ((lx + swap) & 7u);
    let cy = ((lx & ~31u) >> 2u) | ((((ly & ~3u) >> 1u) + (ly & 1u)) & 7u);
    let word = page32(cx, cy);
    return (word * 4u + ((lx >> 3u) & 3u)) * 2u + ((ly >> 1u) & 1u);
  }
  var block = blk32((x >> 3u) & 7u, (y >> 3u) & 3u);
  if (z) { block ^= 24u; }
  return block * 64u + ((y >> 1u) & 3u) * 16u + col32(x & 7u, y & 1u);
}

// GsLayout.index: the unit of pixel (x, y) of a buffer at block bp with
// pages pages in a row
fn unit_index(psm: u32, bp: u32, pages: u32, x: u32, y: u32) -> u32 {
  let xb = x_bits(psm);
  let yb = y_bits(psm);
  let page = (y >> yb) * pages + (x >> xb);
  return ((bp * 64u + page * 2048u) << unit_shift(psm)) +
      in_page(psm, x & ((1u << xb) - 1u), y & ((1u << yb) - 1u));
}

fn word_at(i: u32, from_snap: bool) -> u32 {
  if (from_snap) { return snap[i & 0xfffffu]; }
  return atomicLoad(&vram[i & 0xfffffu]);
}

// GsMemory.readAt
fn read_unit(psm: u32, i: u32, from_snap: bool) -> u32 {
  switch (psm) {
    case 0x00u, 0x30u: { return word_at(i, from_snap); }
    case 0x01u, 0x31u: { return word_at(i, from_snap) & 0xffffffu; }
    case 0x1bu: { return word_at(i, from_snap) >> 24u; }
    case 0x24u: { return (word_at(i, from_snap) >> 24u) & 15u; }
    case 0x2cu: { return word_at(i, from_snap) >> 28u; }
    case 0x13u: { return (word_at(i >> 2u, from_snap) >> ((i & 3u) * 8u)) & 0xffu; }
    case 0x14u: {
      let b = (word_at(i >> 3u, from_snap) >> (((i >> 1u) & 3u) * 8u)) & 0xffu;
      return select(b >> 4u, b & 15u, (i & 1u) == 0u);
    }
    default: { return (word_at(i >> 1u, from_snap) >> ((i & 1u) * 16u)) & 0xffffu; }
  }
}

fn merge_word(i: u32, mask: u32, value: u32) {
  let w = i & 0xfffffu;
  atomicAnd(&vram[w], ~mask);
  atomicOr(&vram[w], value & mask);
}

// GsMemory.writeAt
fn write_unit(psm: u32, i: u32, value: u32) {
  switch (psm) {
    case 0x00u, 0x30u: { atomicStore(&vram[i & 0xfffffu], value); }
    case 0x01u, 0x31u: { merge_word(i, 0xffffffu, value); }
    case 0x1bu: { merge_word(i, 0xff000000u, value << 24u); }
    case 0x24u: { merge_word(i, 0x0f000000u, value << 24u); }
    case 0x2cu: { merge_word(i, 0xf0000000u, value << 28u); }
    case 0x13u: {
      let s = (i & 3u) * 8u;
      merge_word(i >> 2u, 0xffu << s, (value & 0xffu) << s);
    }
    case 0x14u: {
      let s = ((i >> 1u) & 3u) * 8u + (i & 1u) * 4u;
      merge_word(i >> 3u, 15u << s, (value & 15u) << s);
    }
    default: {
      let s = (i & 1u) * 16u;
      merge_word(i >> 1u, 0xffffu << s, (value & 0xffffu) << s);
    }
  }
}

// ---- setup ----

fn vx(w: u32) -> i32 { return i32(w & 0xffffu); }
fn vy(w: u32) -> i32 { return i32(w >> 16u); }

fn top_left(dx: i32, dy: i32) -> bool { return (dy == 0 && dx > 0) || dy < 0; }

fn st(state: u32, k: u32) -> u32 { return data[state + k]; }

fn empty(o: u32) {
  setups[o] = 0xffffffffu;
  setups[o + 1u] = 0u;
}

@compute @workgroup_size(64)
fn setup(@builtin(global_invocation_id) g: vec3u) {
  let i = P.a.x + g.x;
  if (g.x >= P.a.y) { return; }
  let p = i * PRIM_WORDS;
  let o = i * SETUP_WORDS;
  let kind = prims[p] & 0xffu;
  let state = prims[p + 1u];
  let ofx = i32(st(state, S_OFX));
  let ofy = i32(st(state, S_OFY));
  let sx0 = i32(st(state, S_SX0));
  let sx1 = i32(st(state, S_SX1));
  let sy0 = i32(st(state, S_SY0));
  let sy1 = i32(st(state, S_SY1));
  if (kind == KIND_POINT) {
    let x = (vx(prims[p + 3u]) - ofx) >> 4u;
    let y = (vy(prims[p + 3u]) - ofy) >> 4u;
    if (x < sx0 || x > sx1 || y < sy0 || y > sy1) { empty(o); return; }
    setups[o] = u32(x) | (u32(y) << 16u);
    setups[o + 1u] = setups[o];
    return;
  }
  if (kind == KIND_SPRITE) {
    let x0 = vx(prims[p + 3u]) - ofx;
    let y0 = vy(prims[p + 3u]) - ofy;
    let x1 = vx(prims[p + 11u]) - ofx;
    let y1 = vy(prims[p + 11u]) - ofy;
    let left = min(x0, x1);
    let right = max(x0, x1);
    let top = min(y0, y1);
    let bottom = max(y0, y1);
    if (right == left || bottom == top) { empty(o); return; }
    let px0 = max((left + 15) >> 4u, sx0);
    let py0 = max((top + 15) >> 4u, sy0);
    let px1 = min((right - 1) >> 4u, sx1);
    let py1 = min((bottom - 1) >> 4u, sy1);
    if (px0 > px1 || py0 > py1) { empty(o); return; }
    setups[o] = u32(px0) | (u32(py0) << 16u);
    setups[o + 1u] = u32(px1) | (u32(py1) << 16u);
    setups[o + 2u] = bitcast<u32>(left);
    setups[o + 3u] = bitcast<u32>(top);
    setups[o + 4u] = bitcast<u32>(right);
    setups[o + 5u] = bitcast<u32>(bottom);
    return;
  }
  var ax = vx(prims[p + 3u]) - ofx;
  var ay = vy(prims[p + 3u]) - ofy;
  var bx = vx(prims[p + 11u]) - ofx;
  var by = vy(prims[p + 11u]) - ofy;
  var cx = vx(prims[p + 19u]) - ofx;
  var cy = vy(prims[p + 19u]) - ofy;
  let ext = max(max(max(ax, bx), cx) - min(min(ax, bx), cx),
      max(max(ay, by), cy) - min(min(ay, by), cy));
  // larger triangles overflow the 32-bit edge values; lib/compute_gs.dart
  // leaves them out
  if (ext >= 32768) { empty(o); return; }
  var area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
  if (area == 0) { empty(o); return; }
  var order = 0u | (1u << 2u) | (2u << 4u);
  if (area < 0) {
    let tx = bx;
    let ty = by;
    bx = cx;
    by = cy;
    cx = tx;
    cy = ty;
    order = 0u | (2u << 2u) | (1u << 4u);
    area = -area;
  }
  let minx = max(min(ax, min(bx, cx)) >> 4u, sx0);
  let maxx = min((max(ax, max(bx, cx)) + 15) >> 4u, sx1);
  let miny = max(min(ay, min(by, cy)) >> 4u, sy0);
  let maxy = min((max(ay, max(by, cy)) + 15) >> 4u, sy1);
  if (minx > maxx || miny > maxy) { empty(o); return; }
  setups[o] = u32(minx) | (u32(miny) << 16u);
  setups[o + 1u] = u32(maxx) | (u32(maxy) << 16u);
  setups[o + 2u] = bitcast<u32>(ax);
  setups[o + 3u] = bitcast<u32>(ay);
  setups[o + 4u] = bitcast<u32>(bx);
  setups[o + 5u] = bitcast<u32>(by);
  setups[o + 6u] = bitcast<u32>(cx);
  setups[o + 7u] = bitcast<u32>(cy);
  setups[o + 8u] = u32(area);
  setups[o + 9u] = select(0u, 1u, top_left(bx - ax, by - ay)) |
      select(0u, 2u, top_left(cx - bx, cy - by)) |
      select(0u, 4u, top_left(ax - cx, ay - cy));
  setups[o + 10u] = order;
}

// ---- 64-bit helpers for the depth ----

fn mul_wide(a: u32, b: u32) -> vec2u {
  let a0 = a & 0xffffu;
  let a1 = a >> 16u;
  let b0 = b & 0xffffu;
  let b1 = b >> 16u;
  let p00 = a0 * b0;
  let p01 = a0 * b1;
  let p10 = a1 * b0;
  let p11 = a1 * b1;
  let mid = (p00 >> 16u) + (p01 & 0xffffu) + (p10 & 0xffffu);
  return vec2u((p00 & 0xffffu) | (mid << 16u),
      p11 + (p01 >> 16u) + (p10 >> 16u) + (mid >> 16u));
}

fn add_wide(a: vec2u, b: vec2u) -> vec2u {
  let lo = a.x + b.x;
  return vec2u(lo, a.y + b.y + select(0u, 1u, lo < a.x));
}

// floor(n / d + 0.5) for n.y < d < 2^31
fn div_round(n: vec2u, d: u32) -> u32 {
  var r = n.y;
  var q = 0u;
  for (var i = 31i; i >= 0i; i--) {
    r = (r << 1u) | ((n.x >> u32(i)) & 1u);
    q = q << 1u;
    if (r >= d) {
      r -= d;
      q |= 1u;
    }
  }
  return q + select(0u, 1u, r * 2u >= d);
}

// ---- pixel pipeline (GsRaster._pixel) ----

struct Frag {
  z: u32,
  r: i32,
  g: i32,
  b: i32,
  a: i32,
  f: i32,
  s: f32,
  t: f32,
  q: f32,
  u: f32,
  v: f32,
}

struct Level {
  tbp: u32,
  pages: u32,
  tw: u32,
  th: u32,
  minu: i32,
  maxu: i32,
  minv: i32,
  maxv: i32,
}

fn clamp8(v: i32) -> i32 { return clamp(v, 0, 255); }

fn round_up(v: f32) -> i32 { return i32(floor(v + 0.5)); }

fn finite(v: f32) -> f32 {
  if (v != v) { return 0.0; }
  return clamp(v, -32768.0, 32768.0);
}

fn wrap(c: i32, mode: u32, size: i32, minv: i32, maxv: i32) -> u32 {
  switch (mode) {
    case 0u: { return u32(c & (size - 1)); }
    case 1u: { return u32(clamp(c, 0, size - 1)); }
    case 2u: { return u32(select(select(c, maxv, c > maxv), minv, c < minv)); }
    default: { return u32((c & minv) | maxv); }
  }
}

// GsRaster._color
fn color(state: u32, psm: u32, raw: u32) -> u32 {
  let aem = st(state, S_AEM) != 0u;
  let ta0 = st(state, S_TA0);
  let ta1 = st(state, S_TA1);
  if (psm == CT32) { return raw; }
  if (psm == CT24) {
    let rgb = raw & 0xffffffu;
    return rgb | (select(ta0, 0u, aem && rgb == 0u) << 24u);
  }
  let alpha = select(select(ta0, ta1, (raw & 0x8000u) != 0u), 0u,
      aem && (raw & 0x7fffu) == 0u);
  return ((raw & 31u) << 3u) | (((raw >> 5u) & 31u) << 11u) |
      (((raw >> 10u) & 31u) << 19u) | (alpha << 24u);
}

fn is_indexed(psm: u32) -> bool {
  return psm == T8 || psm == T8H || psm == T4 || psm == T4HL || psm == T4HH;
}

// GsRaster._texel
fn texel(state: u32, from_snap: bool, version: u32, l: Level, u: u32,
    v: u32) -> u32 {
  let tpsm = st(state, S_TPSM);
  let i = unit_index(tpsm, l.tbp, l.pages, u, v);
  if (tpsm == CT32) { return word_at(i, from_snap); }
  let raw = read_unit(tpsm, i, from_snap);
  if (is_indexed(tpsm)) {
    let entry = (st(state, S_CLUTOFF) + raw) & 511u;
    return color(state, st(state, S_CLUTPSM), cluts[version * 512u + entry]);
  }
  return color(state, st(state, S_TCOLOR), raw);
}

fn mix4(c00: u32, c10: u32, c01: u32, c11: u32, fu: f32, fv: f32,
    shift: u32) -> u32 {
  let a = f32((c00 >> shift) & 0xffu);
  let b = f32((c10 >> shift) & 0xffu);
  let c = f32((c01 >> shift) & 0xffu);
  let d = f32((c11 >> shift) & 0xffu);
  let m = (a * (1.0 - fu) + b * fu) * (1.0 - fv) + (c * (1.0 - fu) + d * fu) * fv;
  return u32(round_up(m)) << shift;
}

fn bilinear(c00: u32, c10: u32, c01: u32, c11: u32, fu: f32, fv: f32) -> u32 {
  return mix4(c00, c10, c01, c11, fu, fv, 0u) | mix4(c00, c10, c01, c11, fu, fv, 8u) |
      mix4(c00, c10, c01, c11, fu, fv, 16u) | mix4(c00, c10, c01, c11, fu, fv, 24u);
}

// GsRaster._sample on level l
fn sample(state: u32, from_snap: bool, version: u32, l: Level, u: f32, v: f32,
    linear: bool) -> u32 {
  let size = 1i << l.tw;
  let height = 1i << l.th;
  let wms = st(state, S_WMS);
  let wmt = st(state, S_WMT);
  if (!linear) {
    return texel(state, from_snap, version, l,
        wrap(i32(floor(u)), wms, size, l.minu, l.maxu),
        wrap(i32(floor(v)), wmt, height, l.minv, l.maxv));
  }
  let u0 = i32(floor(u - 0.5));
  let v0 = i32(floor(v - 0.5));
  let fu = u - 0.5 - f32(u0);
  let fv = v - 0.5 - f32(v0);
  let ua = wrap(u0, wms, size, l.minu, l.maxu);
  let ub = wrap(u0 + 1, wms, size, l.minu, l.maxu);
  let va = wrap(v0, wmt, height, l.minv, l.maxv);
  let vb = wrap(v0 + 1, wmt, height, l.minv, l.maxv);
  let c00 = texel(state, from_snap, version, l, ua, va);
  let c10 = texel(state, from_snap, version, l, ub, va);
  let c01 = texel(state, from_snap, version, l, ua, vb);
  let c11 = texel(state, from_snap, version, l, ub, vb);
  if (c00 == c10 && c00 == c01 && c00 == c11) { return c00; }
  return bilinear(c00, c10, c01, c11, fu, fv);
}

fn level(state: u32, n: u32) -> Level {
  var l: Level;
  l.tbp = st(state, S_MIPTBP + n);
  l.pages = st(state, S_MIPPAGES + n);
  l.tw = st(state, S_MIPTW + n);
  l.th = st(state, S_MIPTH + n);
  l.minu = i32(st(state, S_MINU));
  l.maxu = i32(st(state, S_MAXU));
  l.minv = i32(st(state, S_MINV));
  l.maxv = i32(st(state, S_MAXV));
  if (n > 0u) {
    if (st(state, S_WMS) == 2u) {
      l.minu >>= n;
      l.maxu >>= n;
    }
    if (st(state, S_WMT) == 2u) {
      l.minv >>= n;
      l.maxv >>= n;
    }
  }
  return l;
}

fn sample_level(state: u32, from_snap: bool, version: u32, n: u32, u: f32,
    v: f32, linear: bool) -> u32 {
  let scale = 1.0 / f32(1u << n);
  return sample(state, from_snap, version, level(state, n), u * scale,
      v * scale, linear);
}

// GsRaster._texture without the texture function
fn texture(state: u32, attrs: u32, from_snap: bool, version: u32,
    fr: Frag) -> u32 {
  let l0 = level(state, 0u);
  var u: f32;
  var v: f32;
  let fst = (attrs & 0x100u) != 0u;
  if (fst) {
    u = fr.u;
    v = fr.v;
  } else {
    let q = select(fr.q, 1.0, fr.q == 0.0);
    u = finite(fr.s / q * f32(1u << l0.tw));
    v = finite(fr.t / q * f32(1u << l0.th));
  }
  let linear = st(state, S_LINEAR) != 0u;
  if (st(state, S_MIPMAP) == 0u) {
    return sample(state, from_snap, version, l0, u, v, linear);
  }
  let k = bitcast<f32>(st(state, S_K));
  var lod: f32;
  if (st(state, S_LCM) != 0u) {
    lod = k;
  } else {
    let q = select(abs(fr.q), 1.0, fst);
    lod = select(-log2(q) * f32(1u << st(state, S_L)) + k, k, q == 0.0);
  }
  if (lod <= 0.0) { return sample(state, from_snap, version, l0, u, v, linear); }
  let mmin = st(state, S_MMIN);
  let mxl = st(state, S_MXL);
  let min_linear = mmin == 1u || mmin >= 4u;
  if (mmin < 2u || mxl == 0u) {
    return sample(state, from_snap, version, l0, u, v, min_linear);
  }
  let blend = mmin == 3u || mmin == 5u;
  let top = select(lod, f32(mxl), lod > f32(mxl));
  if (!blend) {
    return sample_level(state, from_snap, version, u32(floor(top + 0.5)), u, v,
        min_linear);
  }
  let n = u32(floor(top));
  let c0 = sample_level(state, from_snap, version, n, u, v, min_linear);
  let frac = top - f32(n);
  if (frac == 0.0 || n >= mxl) { return c0; }
  let c1 = sample_level(state, from_snap, version, n + 1u, u, v, min_linear);
  return bilinear(c0, c1, c0, c1, frac, 0.0);
}

fn alpha_passes(atst: u32, a: i32, aref: i32) -> bool {
  switch (atst) {
    case 0u: { return false; }
    case 1u: { return true; }
    case 2u: { return a < aref; }
    case 3u: { return a <= aref; }
    case 4u: { return a == aref; }
    case 5u: { return a >= aref; }
    case 6u: { return a > aref; }
    default: { return a != aref; }
  }
}

fn blend_channel(alpha: u32, cs: i32, cd: i32, coef: i32, clamp_on: bool) -> i32 {
  let sa = alpha & 3u;
  let sb = (alpha >> 2u) & 3u;
  let sd = (alpha >> 6u) & 3u;
  let pa = select(select(0, cd, sa == 1u), cs, sa == 0u);
  let pb = select(select(0, cd, sb == 1u), cs, sb == 0u);
  let pd = select(select(0, cd, sd == 1u), cs, sd == 0u);
  let v = (((pa - pb) * coef) >> 7u) + pd;
  return select(v & 0xff, clamp8(v), clamp_on);
}

fn pixel(state: u32, attrs: u32, from_snap: bool, version: u32, x: u32, y: u32,
    fr: Frag, fval: ptr<function, u32>, zval: ptr<function, u32>,
    fdirty: ptr<function, bool>, zdirty: ptr<function, bool>) {
  let z = min(fr.z, st(state, S_ZMAX));
  let test = st(state, S_TEST);
  if (((test >> 16u) & 1u) != 0u) {
    let ztst = (test >> 17u) & 3u;
    if (ztst == 0u) { return; }
    if (ztst >= 2u) {
      let zold = *zval;
      if (select(z <= zold, z < zold, ztst == 2u)) { return; }
    }
  }
  var r = fr.r;
  var g = fr.g;
  var b = fr.b;
  var a = fr.a;
  if ((attrs & 0x10u) != 0u) {
    let t = texture(state, attrs, from_snap, version, fr);
    let tr = i32(t & 0xffu);
    let tg = i32((t >> 8u) & 0xffu);
    let tb = i32((t >> 16u) & 0xffu);
    let ta = i32(t >> 24u);
    let tcc = st(state, S_TCC) != 0u;
    switch (st(state, S_TFX)) {
      case 0u: {
        r = clamp8((tr * r) >> 7u);
        g = clamp8((tg * g) >> 7u);
        b = clamp8((tb * b) >> 7u);
        a = select(a, clamp8((ta * a) >> 7u), tcc);
      }
      case 1u: {
        r = tr;
        g = tg;
        b = tb;
        a = select(a, ta, tcc);
      }
      case 2u: {
        r = clamp8(((tr * r) >> 7u) + a);
        g = clamp8(((tg * g) >> 7u) + a);
        b = clamp8(((tb * b) >> 7u) + a);
        a = select(a, clamp8(ta + a), tcc);
      }
      default: {
        r = clamp8(((tr * r) >> 7u) + a);
        g = clamp8(((tg * g) >> 7u) + a);
        b = clamp8(((tb * b) >> 7u) + a);
        a = select(a, ta, tcc);
      }
    }
  }
  if ((attrs & 0x20u) != 0u) {
    let fc = st(state, S_FOGCOL);
    let f = fr.f;
    r = (f * r + (255 - f) * i32(fc & 0xffu)) >> 8u;
    g = (f * g + (255 - f) * i32((fc >> 8u) & 0xffu)) >> 8u;
    b = (f * b + (255 - f) * i32((fc >> 16u) & 0xffu)) >> 8u;
  }
  var write_color = true;
  var write_z = st(state, S_ZMSK) == 0u;
  var keep_alpha = false;
  if ((test & 1u) != 0u &&
      !alpha_passes((test >> 1u) & 7u, a, i32((test >> 4u) & 0xffu))) {
    switch ((test >> 12u) & 3u) {
      case 0u: { return; }
      case 1u: { write_z = false; }
      case 2u: { write_color = false; }
      default: {
        write_z = false;
        keep_alpha = true;
      }
    }
  }
  let fcolor = st(state, S_FCOLOR);
  let fraw = *fval;
  if (((test >> 14u) & 1u) != 0u && fcolor != CT24) {
    let bit = select((fraw >> 15u) & 1u, fraw >> 31u, fcolor == CT32);
    if ((bit != 0u) != (((test >> 15u) & 1u) != 0u)) { return; }
  }
  if (write_z) {
    *zval = z;
    *zdirty = true;
  }
  if (!write_color) { return; }
  let alpha = st(state, S_ALPHA);
  if ((attrs & 0x40u) != 0u && (st(state, S_PABE) == 0u || (a & 0x80) != 0)) {
    var dr: i32;
    var dg: i32;
    var db: i32;
    var da: i32;
    if (fcolor == CT16 || fcolor == CT16S) {
      dr = i32((fraw & 31u) << 3u);
      dg = i32(((fraw >> 5u) & 31u) << 3u);
      db = i32(((fraw >> 10u) & 31u) << 3u);
      da = select(0, 0x80, ((fraw >> 15u) & 1u) != 0u);
    } else {
      dr = i32(fraw & 0xffu);
      dg = i32((fraw >> 8u) & 0xffu);
      db = i32((fraw >> 16u) & 0xffu);
      da = select(i32(fraw >> 24u), 0x80, fcolor == CT24);
    }
    let sc = (alpha >> 4u) & 3u;
    let coef = select(select(i32(st(state, S_FIX)), da, sc == 1u), a, sc == 0u);
    let on = st(state, S_COLCLAMP) != 0u;
    r = blend_channel(alpha, r, dr, coef, on);
    g = blend_channel(alpha, g, dg, coef, on);
    b = blend_channel(alpha, b, db, coef, on);
  }
  if ((st(state, S_DTHE) & 1u) != 0u && (fcolor == CT16 || fcolor == CT16S)) {
    let shift = (y & 3u) * 16u + (x & 3u) * 4u;
    let bits = select((st(state, S_DIMX_HI) >> (shift - 32u)) & 7u,
        (st(state, S_DIMX_LO) >> shift) & 7u, shift < 32u);
    let d = select(i32(bits), i32(bits) - 8, bits >= 4u);
    let on = st(state, S_COLCLAMP) != 0u;
    r = select((r + d) & 0xff, clamp8(r + d), on);
    g = select((g + d) & 0xff, clamp8(g + d), on);
    b = select((b + d) & 0xff, clamp8(b + d), on);
  }
  let rr = u32(r & 0xff);
  let gg = u32(g & 0xff);
  let bb = u32(b & 0xff);
  let aa = u32(a & 0xff);
  let fbmsk = st(state, S_FBMSK);
  let fba = st(state, S_FBA) != 0u;
  var packed: u32;
  var mask: u32;
  if (fcolor == CT16 || fcolor == CT16S) {
    packed = (rr >> 3u) | ((gg >> 3u) << 5u) | ((bb >> 3u) << 10u) |
        ((aa >> 7u) << 15u);
    if (fba) { packed |= 0x8000u; }
    mask = fbmsk & 0xffffu;
    if (keep_alpha) { mask |= 0x8000u; }
  } else if (fcolor == CT24) {
    packed = rr | (gg << 8u) | (bb << 16u);
    mask = fbmsk & 0xffffffu;
  } else {
    packed = rr | (gg << 8u) | (bb << 16u) | (aa << 24u);
    if (fba) { packed |= 0x80000000u; }
    mask = fbmsk;
    if (keep_alpha) { mask |= 0xff000000u; }
  }
  *fval = (fraw & mask) | (packed & ~mask);
  *fdirty = true;
}

// ---- raster ----

fn channel(c: u32, k: u32) -> i32 { return i32((c >> (k * 8u)) & 0xffu); }

// the fragment of primitive i at pixel (x, y), or false when it misses
fn fragment(i: u32, x: u32, y: u32, fr: ptr<function, Frag>) -> bool {
  let o = i * SETUP_WORDS;
  let mn = setups[o];
  let mx = setups[o + 1u];
  if (x < (mn & 0xffffu) || x > (mx & 0xffffu) || y < (mn >> 16u) ||
      y > (mx >> 16u)) {
    return false;
  }
  let p = i * PRIM_WORDS;
  let kind = prims[p] & 0xffu;
  let attrs = prims[p] >> 8u;
  if (kind == KIND_POINT) {
    let v = p + 3u;
    (*fr).z = prims[v + 1u];
    let c = prims[v + 2u];
    (*fr).r = channel(c, 0u);
    (*fr).g = channel(c, 1u);
    (*fr).b = channel(c, 2u);
    (*fr).a = channel(c, 3u);
    (*fr).f = i32(prims[v + 3u]);
    (*fr).u = f32(prims[v + 4u] & 0xffffu) / 16.0;
    (*fr).v = f32(prims[v + 4u] >> 16u) / 16.0;
    (*fr).s = bitcast<f32>(prims[v + 5u]);
    (*fr).t = bitcast<f32>(prims[v + 6u]);
    (*fr).q = bitcast<f32>(prims[v + 7u]);
    return true;
  }
  if (kind == KIND_SPRITE) {
    let a = p + 3u;
    let b = p + 11u;
    let left = bitcast<i32>(setups[o + 2u]);
    let top = bitcast<i32>(setups[o + 3u]);
    let width = bitcast<i32>(setups[o + 4u]) - left;
    let height = bitcast<i32>(setups[o + 5u]) - top;
    (*fr).z = prims[b + 1u];
    let c = prims[b + 2u];
    (*fr).r = channel(c, 0u);
    (*fr).g = channel(c, 1u);
    (*fr).b = channel(c, 2u);
    (*fr).a = channel(c, 3u);
    (*fr).f = i32(prims[b + 3u]);
    if ((attrs & 0x10u) != 0u) {
      let kx = i32(x) * 16 - left;
      let ky = i32(y) * 16 - top;
      if ((attrs & 0x100u) != 0u) {
        // the texel coordinate in exact arithmetic, kept in the float
        let au = i32(prims[a + 4u] & 0xffffu);
        let bu = i32(prims[b + 4u] & 0xffffu);
        let av = i32(prims[a + 4u] >> 16u);
        let bv = i32(prims[b + 4u] >> 16u);
        let nu = au * width + (bu - au) * kx;
        let nv = av * height + (bv - av) * ky;
        let fu = f32(nu) / f32(16 * width);
        let fv = f32(nv) / f32(16 * height);
        let iu = f32(nu / (16 * width));
        let iv = f32(nv / (16 * height));
        (*fr).u = clamp(fu, iu, iu + 0.99999);
        (*fr).v = clamp(fv, iv, iv + 0.99999);
      } else {
        let tx = f32(kx) / f32(width);
        let ty = f32(ky) / f32(height);
        let as_ = bitcast<f32>(prims[a + 5u]);
        let bs = bitcast<f32>(prims[b + 5u]);
        let at = bitcast<f32>(prims[a + 6u]);
        let bt = bitcast<f32>(prims[b + 6u]);
        (*fr).s = as_ + (bs - as_) * tx;
        (*fr).t = at + (bt - at) * ty;
        (*fr).q = bitcast<f32>(prims[b + 7u]);
      }
    }
    return true;
  }
  let ax = bitcast<i32>(setups[o + 2u]);
  let ay = bitcast<i32>(setups[o + 3u]);
  let bx = bitcast<i32>(setups[o + 4u]);
  let by = bitcast<i32>(setups[o + 5u]);
  let cx = bitcast<i32>(setups[o + 6u]);
  let cy = bitcast<i32>(setups[o + 7u]);
  let qx = i32(x) * 16;
  let qy = i32(y) * 16;
  let eab = (bx - ax) * (qy - ay) - (by - ay) * (qx - ax);
  let ebc = (cx - bx) * (qy - by) - (cy - by) * (qx - bx);
  let eca = (ax - cx) * (qy - cy) - (ay - cy) * (qx - cx);
  if (eab < 0 || ebc < 0 || eca < 0) { return false; }
  let tl = setups[o + 9u];
  if ((eab == 0 && (tl & 1u) == 0u) || (ebc == 0 && (tl & 2u) == 0u) ||
      (eca == 0 && (tl & 4u) == 0u)) {
    return false;
  }
  let area = setups[o + 8u];
  let order = setups[o + 10u];
  let va = p + 3u + (order & 3u) * 8u;
  let vb = p + 3u + ((order >> 2u) & 3u) * 8u;
  let vc = p + 3u + ((order >> 4u) & 3u) * 8u;
  let wa = u32(ebc);
  let wb = u32(eca);
  let wc = u32(eab);
  (*fr).z = div_round(add_wide(add_wide(mul_wide(prims[va + 1u], wa),
      mul_wide(prims[vb + 1u], wb)), mul_wide(prims[vc + 1u], wc)), area);
  let inv = 1.0 / f32(area);
  let fa = f32(wa) * inv;
  let fb = f32(wb) * inv;
  let fc = f32(wc) * inv;
  if ((attrs & 0x08u) != 0u) {
    let ca = prims[va + 2u];
    let cb = prims[vb + 2u];
    let cc = prims[vc + 2u];
    (*fr).r = round_up(f32(channel(ca, 0u)) * fa + f32(channel(cb, 0u)) * fb +
        f32(channel(cc, 0u)) * fc);
    (*fr).g = round_up(f32(channel(ca, 1u)) * fa + f32(channel(cb, 1u)) * fb +
        f32(channel(cc, 1u)) * fc);
    (*fr).b = round_up(f32(channel(ca, 2u)) * fa + f32(channel(cb, 2u)) * fb +
        f32(channel(cc, 2u)) * fc);
    (*fr).a = round_up(f32(channel(ca, 3u)) * fa + f32(channel(cb, 3u)) * fb +
        f32(channel(cc, 3u)) * fc);
  } else {
    // the colour of the last vertex as issued
    let c = prims[p + 3u + 16u + 2u];
    (*fr).r = channel(c, 0u);
    (*fr).g = channel(c, 1u);
    (*fr).b = channel(c, 2u);
    (*fr).a = channel(c, 3u);
  }
  if ((attrs & 0x20u) != 0u) {
    (*fr).f = round_up(f32(prims[va + 3u]) * fa + f32(prims[vb + 3u]) * fb +
        f32(prims[vc + 3u]) * fc);
  }
  if ((attrs & 0x10u) != 0u) {
    if ((attrs & 0x100u) != 0u) {
      (*fr).u = (f32(prims[va + 4u] & 0xffffu) * fa +
          f32(prims[vb + 4u] & 0xffffu) * fb +
          f32(prims[vc + 4u] & 0xffffu) * fc) / 16.0;
      (*fr).v = (f32(prims[va + 4u] >> 16u) * fa + f32(prims[vb + 4u] >> 16u) * fb +
          f32(prims[vc + 4u] >> 16u) * fc) / 16.0;
    } else {
      (*fr).s = bitcast<f32>(prims[va + 5u]) * fa +
          bitcast<f32>(prims[vb + 5u]) * fb + bitcast<f32>(prims[vc + 5u]) * fc;
      (*fr).t = bitcast<f32>(prims[va + 6u]) * fa +
          bitcast<f32>(prims[vb + 6u]) * fb + bitcast<f32>(prims[vc + 6u]) * fc;
      (*fr).q = bitcast<f32>(prims[va + 7u]) * fa +
          bitcast<f32>(prims[vb + 7u]) * fb + bitcast<f32>(prims[vc + 7u]) * fc;
    }
  }
  return true;
}

var<workgroup> scan: array<u32, 256>;
var<workgroup> list: array<u32, 256>;

// P.a: first primitive, count, tile x, tile y
// P.b: frame bp, pages, psm, uses depth
// P.c: depth bp, pages, psm
@compute @workgroup_size(16, 16)
fn raster(@builtin(workgroup_id) wg: vec3u,
    @builtin(local_invocation_id) lid: vec3u,
    @builtin(local_invocation_index) li: u32) {
  let tx = P.a.z + wg.x * 16u;
  let ty = P.a.w + wg.y * 16u;
  let x = tx + lid.x;
  let y = ty + lid.y;
  let fpsm = P.b.z;
  let fi = unit_index(fpsm, P.b.x, P.b.y, x, y);
  var fval = read_unit(fpsm, fi, false);
  var fdirty = false;
  let uses_z = P.b.w != 0u;
  let zpsm = P.c.z;
  var zi = 0u;
  var zval = 0u;
  var zdirty = false;
  if (uses_z) {
    zi = unit_index(zpsm, P.c.x, P.c.y, x, y);
    zval = read_unit(zpsm, zi, false);
  }
  let first = P.a.x;
  let count = P.a.y;
  for (var base = 0u; base < count; base += 256u) {
    let i = first + base + li;
    var f = 0u;
    if (base + li < count) {
      let mn = setups[i * SETUP_WORDS];
      let mx = setups[i * SETUP_WORDS + 1u];
      f = select(0u, 1u, (mn & 0xffffu) <= tx + 15u && (mx & 0xffffu) >= tx &&
          (mn >> 16u) <= ty + 15u && (mx >> 16u) >= ty);
    }
    scan[li] = f;
    workgroupBarrier();
    for (var off = 1u; off < 256u; off <<= 1u) {
      var v = scan[li];
      if (li >= off) { v += scan[li - off]; }
      workgroupBarrier();
      scan[li] = v;
      workgroupBarrier();
    }
    if (f == 1u) { list[scan[li] - 1u] = i; }
    let total = workgroupUniformLoad(&scan[255]);
    for (var k = 0u; k < total; k++) {
      let prim = list[k];
      var fr: Frag;
      if (fragment(prim, x, y, &fr)) {
        let p = prim * PRIM_WORDS;
        pixel(prims[p + 1u], prims[p] >> 8u, (prims[p] & 0x1000000u) != 0u,
            prims[p + 2u], x, y, fr, &fval, &zval, &fdirty, &zdirty);
      }
    }
    workgroupBarrier();
  }
  if (fdirty) { write_unit(fpsm, fi, fval); }
  if (zdirty) { write_unit(zpsm, zi, zval); }
}

// ---- CLUT ----

// P.a: first version, versions, descriptor offset, base version
// A descriptor is 1 << 31 | psm << 24 | unit index to read the local memory,
// or 0 to copy the entry of the base version.
@compute @workgroup_size(256)
fn clut(@builtin(workgroup_id) wg: vec3u,
    @builtin(local_invocation_index) li: u32) {
  let n = wg.x;
  for (var half = 0u; half < 2u; half++) {
    let e = li + half * 256u;
    let d = data[P.a.z + n * 512u + e];
    var value: u32;
    if ((d >> 31u) != 0u) {
      value = read_unit((d >> 24u) & 0x3fu, d & 0xffffffu, false);
    } else {
      value = cluts[P.a.w * 512u + e];
    }
    cluts[((P.a.x + n) & 2047u) * 512u + e] = value;
  }
}

// ---- transfers ----

// P.a: psm, bp, bw, x | y << 16
// P.b: width, pixels, data offset, bits per pixel
@compute @workgroup_size(256)
fn upload(@builtin(global_invocation_id) g: vec3u) {
  let w = P.b.x;
  let n = g.x + g.y * 65535u * 256u;
  if (n >= P.b.y) { return; }
  let bits = P.b.w;
  let bit = n * bits;
  let lo = data[P.b.z + (bit >> 5u)];
  var value = lo >> (bit & 31u);
  if ((bit & 31u) + bits > 32u) {
    value |= data[P.b.z + (bit >> 5u) + 1u] << (32u - (bit & 31u));
  }
  if (bits < 32u) { value &= (1u << bits) - 1u; }
  let psm = P.a.x;
  let pages = select(P.a.z, (P.a.z + 1u) >> 1u, x_bits(psm) == 7u);
  let x = ((P.a.w & 0xffffu) + n % w) & 0x7ffu;
  let y = ((P.a.w >> 16u) + n / w) & 0x7ffu;
  write_unit(psm, unit_index(psm, P.a.y, pages, x, y), value);
}

fn read_snap(psm: u32, i: u32) -> u32 { return read_unit(psm, i, true); }

// P.a: source psm, bp, bw, x | y << 16
// P.b: destination psm, bp, bw, x | y << 16
// P.c: width, height
@compute @workgroup_size(256)
fn copy(@builtin(global_invocation_id) g: vec3u) {
  let w = P.c.x;
  let n = g.x + g.y * 65535u * 256u;
  if (n >= w * P.c.y) { return; }
  let i = n % w;
  let j = n / w;
  let spsm = P.a.x;
  let spages = select(P.a.z, (P.a.z + 1u) >> 1u, x_bits(spsm) == 7u);
  let sx = ((P.a.w & 0xffffu) + i) & 0x7ffu;
  let sy = ((P.a.w >> 16u) + j) & 0x7ffu;
  let value = read_snap(spsm, unit_index(spsm, P.a.y, spages, sx, sy));
  let dpsm = P.b.x;
  let dpages = select(P.b.z, (P.b.z + 1u) >> 1u, x_bits(dpsm) == 7u);
  let dx = ((P.b.w & 0xffffu) + i) & 0x7ffu;
  let dy = ((P.b.w >> 16u) + j) & 0x7ffu;
  write_unit(dpsm, unit_index(dpsm, P.b.y, dpages, dx, dy), value);
}

// P.a: page list offset, pages; one workgroup per page
@compute @workgroup_size(256)
fn snapshot(@builtin(workgroup_id) wg: vec3u,
    @builtin(local_invocation_index) li: u32) {
  let page = data[P.a.x + wg.x] & 511u;
  for (var k = 0u; k < 8u; k++) {
    let w = page * 2048u + k * 256u + li;
    snap[w] = atomicLoad(&vram[w]);
  }
}
