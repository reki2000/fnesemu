in vec2 position;
in vec3 index_color;
out vec3 v_index_color;

void main() {
  gl_Position = vec4(position, 0.5, 1.0);
  v_index_color = index_color;
}
