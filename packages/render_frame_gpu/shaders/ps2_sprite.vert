in vec2 position;
in vec2 pixel;
in vec3 marker;

out vec2 v_pixel;
out vec3 v_marker;

void main() {
  gl_Position = vec4(position, 0.5, 1.0);
  v_pixel = pixel;
  v_marker = marker;
}
