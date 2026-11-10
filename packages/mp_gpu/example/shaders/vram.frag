// Keep in step with vram.wgsl. Reads one texel of a video memory image per
// pixel, at an address that interleaves the bits of x and y, as a twiddled
// texture does. The texture holds the image as 32-bit words, row by row.
//
// The GLES backend runs fragment shaders with mediump floats, whose whole
// numbers are exact only up to 2048, and impellerc drops a default
// precision. The address is an int, which is highp, and the texture
// position is declared highp.
uniform sampler2D vram;

uniform VramInfo {
  // The width and the height of the image in words, and the first word.
  vec4 size;
}
info;

in highp vec2 v_uv;

out vec4 frag_color;

void main() {
  // v_uv holds the pixel position.
  int x = int(v_uv.x), y = int(v_uv.y);
  int address = 0, bit = 1;
  for (int i = 0; i < 11; i++) {
    address += (x - x / 2 * 2) * bit;
    bit *= 2;
    address += (y - y / 2 * 2) * bit;
    bit *= 2;
    x /= 2;
    y /= 2;
  }
  address += int(info.size.z);
  int width = int(info.size.x);
  int row = address / width;
  int column = address - row * width;
  highp vec2 position = (vec2(float(column), float(row)) + 0.5) / info.size.xy;
  frag_color = texture(vram, position);
}
