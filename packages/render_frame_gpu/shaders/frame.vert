// Places a vertex of a render frame. Positions are in pixels with y down,
// and the depth is the reciprocal of w.
uniform FrameInfo {
  // Width and height in pixels, the scale of the depth into 0 to 1 and the
  // smallest depth used for w.
  vec4 viewport;
}
frame_info;

in vec3 position;
in vec2 uv;
in vec4 color;
in vec4 offset;

out vec2 v_uv;
out vec4 v_color;
out vec4 v_offset;
out float v_w;

void main() {
  // A depth near zero would make w huge; a floor keeps the clip space
  // finite and only changes the perspective of triangles that reach it.
  float w = 1.0 / max(position.z, frame_info.viewport.w);
  vec2 ndc = vec2(position.x / frame_info.viewport.x * 2.0 - 1.0,
                  1.0 - position.y / frame_info.viewport.y * 2.0);
  float depth = clamp(position.z * frame_info.viewport.z, 0.000001, 0.999);
  gl_Position = vec4(ndc * w, depth * w, w);
  v_uv = uv;
  v_color = color;
  v_offset = offset;
  // Interpolated with perspective, w gives back the depth of the fragment.
  v_w = w;
}
