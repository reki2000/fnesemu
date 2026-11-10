uniform sampler2D sprite_input;

uniform SpriteInfo {
  vec4 sizes;
  vec4 depth;
  vec4 color;
  vec4 texture_mode;
  vec4 blend;
  vec4 tests;
  vec4 writes;
  vec4 tex_geometry;
  vec4 geometry_mode;
  vec4 pos_a;
  vec4 uv_a;
  vec4 col_a;
  vec4 pos_b;
  vec4 uv_b;
  vec4 col_b;
  vec4 pos_c;
  vec4 uv_c;
  vec4 col_c;
  vec4 tex_bounds;
  vec4 fog;
  vec4 sprite_uv;
  vec4 frame_options;
  vec4 dither0;
  vec4 dither1;
  vec4 dither2;
  vec4 dither3;
  vec4 mip;
  vec4 mip_filter;
} info;

in vec2 v_pixel;
in vec3 v_marker;
out vec4 frag_color;

vec4 bytes_at(vec2 p) {
  return floor(texture(sprite_input, (p + 0.5) / info.sizes.zw) * 255.0 + 0.5);
}

// The GLES backend can use GLSL ES 1.00. Splitting the depth into
// halfwords keeps comparisons exact without integer bit operations.
float halfword(vec2 bytes) {
  return bytes.x + bytes.y * 256.0;
}

bool alpha_passes(float a, float test, float ref_value) {
  if (test == 0.0) return false;
  if (test == 1.0) return true;
  if (test == 2.0) return a < ref_value;
  if (test == 3.0) return a <= ref_value;
  if (test == 4.0) return a == ref_value;
  if (test == 5.0) return a >= ref_value;
  if (test == 6.0) return a > ref_value;
  return a != ref_value;
}

vec3 color_term(float mode, vec3 src, vec3 dst) {
  return mode == 0.0 ? src : (mode == 1.0 ? dst : vec3(0.0));
}

float edge(vec2 a, vec2 b, vec2 p) {
  vec2 d = b - a, q = p - a;
  return d.x * q.y - d.y * q.x;
}

bool covered(float e, vec2 d, float orientation) {
  vec2 side = d * orientation;
  return e * orientation > 0.0 ||
      (e == 0.0 && (side.y < 0.0 || (side.y == 0.0 && side.x > 0.0)));
}

float region_repeat(float coordinate, float mask, float fix) {
  float result = 0.0;
  float bit = 1.0;
  for (int i = 0; i < 10; i++) {
    float c = mod(floor(coordinate / bit), 2.0);
    float m = mod(floor(mask / bit), 2.0);
    float f = mod(floor(fix / bit), 2.0);
    result += max(c * m, f) * bit;
    bit *= 2.0;
  }
  return result;
}

vec2 wrap_uv(vec2 uv, float scale) {
  vec2 size = max(floor(info.tex_geometry.xy * scale), 1.0);
  vec2 mode = vec2(mod(info.tex_geometry.z, 4.0), floor(info.tex_geometry.z / 4.0));
  vec2 lo = mix(vec2(0.0), floor(info.tex_bounds.xy * scale), step(vec2(2.0), mode));
  vec2 hi = mix(size - 1.0, floor(info.tex_bounds.zw * scale), step(vec2(2.0), mode));
  vec2 region = mix(lo, min(uv, hi), step(lo, uv));
  vec2 result = mix(mod(uv, size), region, step(vec2(1.0), mode));
  if (mode.x == 3.0) result.x = region_repeat(uv.x, info.tex_bounds.x, info.tex_bounds.z);
  if (mode.y == 3.0) result.y = region_repeat(uv.y, info.tex_bounds.y, info.tex_bounds.w);
  return result;
}

vec4 sample_level(vec2 uv, float level, bool linear) {
  float scale = exp2(-level);
  float offset = 0.0;
  for (int i = 0; i < 6; i++) {
    if (float(i) < level) offset += max(floor(info.tex_geometry.y * exp2(-float(i))), 1.0);
  }
  vec2 row = vec2(0.0, offset);
  uv *= scale;
  if (!linear) return bytes_at(wrap_uv(floor(uv), scale) + row);
  vec2 base = floor(uv - 0.5);
  vec2 f = uv - 0.5 - base;
  vec4 c00 = bytes_at(wrap_uv(base, scale) + row);
  vec4 c10 = bytes_at(wrap_uv(base + vec2(1.0, 0.0), scale) + row);
  vec4 c01 = bytes_at(wrap_uv(base + vec2(0.0, 1.0), scale) + row);
  vec4 c11 = bytes_at(wrap_uv(base + 1.0, scale) + row);
  return floor(mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y) + 0.5);
}

vec4 sample_texture(vec2 uv, float q) {
  float lod = info.mip.z;
  if (info.mip.x != 0.0 && info.mip.y != 0.0 && q != 0.0) {
    lod -= log2(abs(q)) * info.mip.y;
  }
  if (info.mip.x == 0.0 || lod <= 0.0) {
    return sample_level(uv, 0.0, info.tex_geometry.w != 0.0);
  }
  float filter_mode = info.mip_filter.x;
  bool linear = filter_mode == 1.0 || filter_mode >= 4.0;
  float top = min(lod, info.mip.w);
  if (filter_mode != 3.0 && filter_mode != 5.0) {
    return sample_level(uv, floor(top + 0.5), linear);
  }
  float level = floor(top);
  float frac = top - level;
  vec4 c0 = sample_level(uv, level, linear);
  if (frac == 0.0 || level >= info.mip.w) return c0;
  return floor(mix(c0, sample_level(uv, level + 1.0, linear), frac) + 0.5);
}

void main() {
  if (any(greaterThan(v_marker, vec3(0.0)))) {
    frag_color = vec4(v_marker, 1.0);
    return;
  }
  vec2 p = floor(v_pixel);
  float width = info.sizes.x, height = info.sizes.y;
  float plane = p.x >= width * 2.0 ? 2.0 : (p.x >= width ? 1.0 : 0.0);
  p.x -= plane * width;
  bool flags = plane == 1.0;
  float th = info.depth.x, ztest = info.depth.y;
  float zlow = info.depth.z, zhigh = info.depth.w;
  vec4 vertex = info.color;
  vec2 triangle_uv = vec2(0.0);
  float fog = info.uv_b.z;
  float lod_q = 1.0;
  bool triangle = info.writes.w != 0.0;
  if (triangle) {
    vec2 a = info.pos_a.xy, b = info.pos_b.xy, c = info.pos_c.xy;
    float area = edge(a, b, c);
    if (area == 0.0) discard;
    float orientation = sign(area);
    vec2 sample_point = p * 16.0;
    float ea = edge(b, c, sample_point);
    float eb = edge(c, a, sample_point);
    float ec = edge(a, b, sample_point);
    if (!covered(ea, c - b, orientation) ||
        !covered(eb, a - c, orientation) ||
        !covered(ec, b - a, orientation)) discard;
    vec3 w = vec3(ea, eb, ec) / area;
    float za = info.pos_a.z;
    float delta = w.y * (info.pos_b.z - za) + w.z * (info.pos_c.z - za);
    float z = clamp(za + floor(delta + 0.5), 0.0, info.geometry_mode.z);
    zhigh = floor(z / 65536.0);
    zlow = z - zhigh * 65536.0;
    vertex = info.geometry_mode.y != 0.0 ?
        floor(info.col_a * w.x + info.col_b * w.y + info.col_c * w.z + 0.5) : info.col_c;
    fog = floor(dot(w, vec3(info.uv_a.z, info.uv_b.z, info.uv_c.z)) + 0.5);
    triangle_uv = info.uv_a.xy * w.x + info.uv_b.xy * w.y + info.uv_c.xy * w.z;
    if (info.geometry_mode.x == 0.0) {
      float q = dot(w, vec3(info.pos_a.w, info.pos_b.w, info.pos_c.w));
      lod_q = q;
      if (q == 0.0) q = 1.0;
      triangle_uv = clamp(triangle_uv / q * info.tex_geometry.xy, -32768.0, 32768.0);
    }
  }
  if (ztest == 0.0) discard;
  if (ztest >= 2.0) {
    vec4 old_z = bytes_at(p + vec2(0.0, th + height));
    float low = halfword(old_z.rg), high = halfword(old_z.ba);
    if (zhigh < high ||
        (zhigh == high &&
            (zlow < low || (ztest == 3.0 && zlow == low)))) discard;
  }

  float map_row = info.sizes.w - 2.0;
  float u = halfword(bytes_at(vec2(p.x, map_row)).rg);
  float v = halfword(bytes_at(vec2(p.y, map_row + 1.0)).rg);
  float mode = info.texture_mode.x;
  vec4 texel = vertex;
  if (mode >= 0.0) {
    if (triangle) {
      texel = sample_texture(triangle_uv, lod_q);
    } else if (info.tex_geometry.w != 0.0) {
      vec2 weight = (p * 16.0 + info.sprite_uv.zw) / info.sprite_uv.xy;
      texel = sample_texture(mix(info.uv_a.xy, info.uv_b.xy, weight), 1.0);
    } else {
      texel = bytes_at(vec2(u, v));
    }
  }
  vec4 src = texel;
  if (mode >= 0.0 && mode != 1.0) {
    src = floor(texel * vertex / 128.0);
    if (mode >= 2.0) {
      src.rgb += vertex.a;
      src.a = texel.a + (mode == 2.0 ? vertex.a : 0.0);
    }
    src = min(src, vec4(255.0));
  }
  if (info.texture_mode.y == 0.0) src.a = vertex.a;

  if (info.fog.w != 0.0) src.rgb = floor((fog * src.rgb + (255.0 - fog) * info.fog.xyz) / 256.0);

  vec4 dst = bytes_at(p + vec2(0.0, th));
  float date = info.writes.y;
  if (date != 0.0 && floor(dst.a / 128.0) != date - 1.0) discard;
  float write_color = 1.0, write_z = info.writes.z;
  if (!alpha_passes(src.a, info.tests.z, info.tests.w)) {
    float fail = info.writes.x;
    if (fail == 0.0) discard;
    if (fail == 2.0) write_color = 0.0;
    if (fail != 2.0) write_z = 0.0;
    if (fail == 3.0) write_color = 2.0;
  }
  if (plane == 2.0) {
    frag_color = vec4(vec3(mod(zlow, 256.0), floor(zlow / 256.0), zhigh) / 255.0, 1.0);
    return;
  }
  if (flags) {
    frag_color = vec4(vec3(src.a, write_color, write_z) / 255.0, 1.0);
    return;
  }
  if (info.texture_mode.z != 0.0 &&
      (info.texture_mode.w == 0.0 || src.a >= 128.0)) {
    vec4 blend = info.blend;
    float factor = blend.z == 0.0 ? src.a : (blend.z == 1.0 ? dst.a : info.tests.x);
    vec3 a = color_term(blend.x, src.rgb, dst.rgb);
    vec3 b = color_term(blend.y, src.rgb, dst.rgb);
    vec3 d = color_term(blend.w, src.rgb, dst.rgb);
    src.rgb = floor((a - b) * factor / 128.0) + d;
    src.rgb = info.tests.y != 0.0 ? clamp(src.rgb, 0.0, 255.0) : mod(src.rgb, 256.0);
  }
  if (info.frame_options.z != 0.0) {
    vec2 d = mod(p + info.frame_options.xy, 4.0);
    vec4 row = d.y == 0.0 ? info.dither0 : (d.y == 1.0 ? info.dither1 : (d.y == 2.0 ? info.dither2 : info.dither3));
    float delta = d.x == 0.0 ? row.x : (d.x == 1.0 ? row.y : (d.x == 2.0 ? row.z : row.w));
    src.rgb += delta;
    src.rgb = info.tests.y != 0.0 ? clamp(src.rgb, 0.0, 255.0) : mod(src.rgb, 256.0);
  }
  frag_color = vec4(src.rgb / 255.0, 1.0);
}
