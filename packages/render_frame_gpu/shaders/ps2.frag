in vec3 v_index_color;
out vec4 frag_color;

void main() {
  frag_color = vec4(v_index_color, 1.0);
}
