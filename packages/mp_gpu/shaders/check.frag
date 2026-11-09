// Shades a fragment with the texture.
uniform sampler2D image;

uniform Info {
  vec4 color;
}
info;

in vec2 v_uv;

out vec4 frag_color;

void main() {
  frag_color = texture(image, v_uv) * info.color;
}
