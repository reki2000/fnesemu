uniform sampler2D first_input;
uniform sampler2D second_input;

uniform FeedbackInfo {
  vec4 sizes;
  vec4 region;
  vec4 color_mask;
  vec4 first_marker;
  vec4 second_marker;
} info;

in vec2 v_pixel;
in vec3 v_marker;
out vec4 frag_color;

vec4 byte_sample(sampler2D image, vec2 p, vec2 size) {
  return floor(texture(image, (p + 0.5) / size) * 255.0 + 0.5);
}

bool marker_at(sampler2D image, vec2 size, vec3 marker, bool flip) {
  float y = flip ? 0.0 : size.y - 1.0;
  return all(equal(byte_sample(image, vec2(0.0, y), size), vec4(marker, 255.0)));
}

vec4 result_sample(sampler2D image, vec2 p, vec2 size, bool flip) {
  if (flip) p.y = size.y - 1.0 - p.y;
  return byte_sample(image, p, size);
}

vec4 merge_bytes(vec4 old, vec4 value, vec4 mask) {
  vec4 result = vec4(0.0);
  float bit = 1.0;
  for (int i = 0; i < 8; i++) {
    vec4 keep = mod(floor(mask / bit), 2.0);
    result += bit * mod(floor(mix(value, old, keep) / bit), 2.0);
    bit *= 2.0;
  }
  return result;
}

void main() {
  vec2 p = floor(v_pixel);
  vec2 size = info.sizes.xy, patch_size = info.sizes.zw;
  bool flip_first = !marker_at(first_input, size, info.first_marker.rgb, false);
  bool valid_first = !flip_first || marker_at(first_input, size, info.first_marker.rgb, true);
  if (info.region.w != 0.0) {
    bool flip_second = !marker_at(second_input, size, info.second_marker.rgb, false);
    bool valid_second = !flip_second || marker_at(second_input, size, info.second_marker.rgb, true);
    if (!valid_first || !valid_second) {
      frag_color = vec4(0.0);
      return;
    }
    frag_color = (p.y < info.region.z
        ? result_sample(first_input, p, size, flip_first)
        : result_sample(second_input, p, size, flip_second)) / 255.0;
    return;
  }

  // Store the patch with the same sampling orientation as a CPU upload.
  if (flip_first) p.y = patch_size.y - 1.0 - p.y;
  vec4 old = byte_sample(second_input, p, patch_size);
  vec2 q = p - info.region.xy;
  vec2 tex_size = vec2(info.first_marker.a, info.second_marker.a);
  float width = size.x * 0.5;
  if (!valid_first || any(greaterThanEqual(p, tex_size)) ||
      any(lessThan(q, vec2(0.0))) || q.x >= width || q.y >= info.region.z) {
    frag_color = old / 255.0;
    return;
  }
  vec4 flags = result_sample(first_input, q + vec2(width, 0.0), size, flip_first);
  if (flags.y == 0.0) {
    frag_color = old / 255.0;
    return;
  }
  vec4 value = result_sample(first_input, q, size, flip_first);
  value.a = flags.x;
  if (v_marker.x > 0.0) value.a = mod(value.a, 128.0) + 128.0;
  vec4 mask = info.color_mask;
  if (flags.y == 2.0) mask.a = 255.0;
  frag_color = merge_bytes(old, value, mask) / 255.0;
}
