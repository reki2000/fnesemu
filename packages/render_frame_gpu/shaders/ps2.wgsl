struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) index_color: vec3f,
}

@vertex
fn vertex_main(@location(0) position: vec2f,
               @location(1) index_color: vec3f) -> VertexOutput {
  return VertexOutput(vec4f(position, 0.5, 1.0), index_color);
}

@fragment
fn fragment_main(input: VertexOutput) -> @location(0) vec4f {
  return vec4f(input.index_color, 1.0);
}
