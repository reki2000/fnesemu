// Shades a fragment of a render frame: texture shading, the offset color,
// fog and the punch-through alpha test.
uniform sampler2D texture_sampler;
uniform sampler2D fog_table;

uniform FragmentInfo {
  // Textured, shading mode, texture alpha, offset.
  vec4 shading;
  // Fog mode, fog scale, punch-through, alpha reference.
  vec4 fog;
  vec4 fog_color;
  vec4 vertex_fog_color;
}
info;

in vec2 v_uv;
in vec4 v_color;
in vec4 v_offset;
in float v_w;

out vec4 frag_color;

float fog_coefficient(float depth) {
  float m = clamp(depth * info.fog.y, 1.0, 255.9999);
  float e = floor(log2(m));
  float position = (m / exp2(e) - 1.0) * 16.0;
  float whole = floor(position);
  float index = e * 16.0 + whole;
  vec2 pair = texture(fog_table, vec2((index + 0.5) / 128.0, 0.5)).rg;
  return mix(pair.r, pair.g, position - whole);
}

void main() {
  vec4 color = v_color;
  if (info.shading.x > 0.5) {
    vec4 t = texture(texture_sampler, v_uv);
    if (info.shading.z < 0.5) {
      t.a = 1.0;
    }
    float mode = info.shading.y;
    if (mode < 0.5) {
      color = t;
    } else if (mode < 1.5) {
      color = vec4(t.rgb * v_color.rgb, t.a);
    } else if (mode < 2.5) {
      color = vec4(mix(v_color.rgb, t.rgb, t.a), v_color.a);
    } else {
      color = t * v_color;
    }
    if (info.shading.w > 0.5) {
      color.rgb = min(color.rgb + v_offset.rgb, vec3(1.0));
    }
  }
  float fog_mode = info.fog.x;
  if (fog_mode < 0.5) {
    color.rgb = mix(color.rgb, info.fog_color.rgb, fog_coefficient(1.0 / v_w));
  } else if (fog_mode < 1.5) {
    if (info.shading.w > 0.5) {
      color.rgb = mix(color.rgb, info.vertex_fog_color.rgb, v_offset.a);
    }
  } else if (fog_mode > 2.5) {
    color = vec4(info.fog_color.rgb, fog_coefficient(1.0 / v_w));
  }
  if (info.fog.z > 0.5) {
    if (color.a * 255.0 < info.fog.w) {
      discard;
    }
    color.a = 1.0;
  }
  frag_color = color;
}
