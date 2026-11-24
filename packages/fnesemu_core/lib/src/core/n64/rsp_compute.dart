import 'dart:typed_data';

import '../../compute_sink.dart';

class N64RspCompute {
  static const maxVertices = 80;
  static const maxTriangles = 128;
  static const stateWords = 84;
  static const vertexWords = 10;
  static const polygonWords = 91;
  static const triangleBase = stateWords + maxVertices * vertexWords;
  static const polygonBase = maxVertices * vertexWords;
  static const _inputWords = triangleBase + maxTriangles * 3;
  static const _outputWords = polygonBase + maxTriangles * polygonWords;

  N64RspCompute(ComputeSink sink)
      : _program = sink.program(
          _shader, ['transformVertices', 'clipTriangles'],
          const [
            ComputeBinding(ComputeBindingKind.readOnlyStorage, _inputWords * 4),
            ComputeBinding(ComputeBindingKind.storage, _outputWords * 4),
          ],
          paramStride: 0, maxDispatches: 2);

  final ComputeProgram _program;
  final words = Uint32List(_inputWords);
  late final values = Float32List.view(words.buffer);
  final _output = Uint32List(_outputWords);
  late final result = Float32List.view(_output.buffer);
  final _dispatch = Uint32List.fromList([0, 0, 1, 1, 1, 0, 1, 1]);
  static final _noParams = Uint32List(0);

  void prepare(int vertices, int triangles) {
    words[0] = vertices;
    words[1] = triangles;
    _dispatch[1] = (vertices + 63) ~/ 64;
    _dispatch[5] = (triangles + 63) ~/ 64;
    _program
      ..write(0, 0, words, 0, triangleBase + triangles * 3)
      ..run(_dispatch, 2, _noParams, wait: false)
      ..read(1, 0, Uint32List.sublistView(
          _output, 0, polygonBase + triangles * polygonWords));
  }

  void dispose() => _program.dispose();

  static const _shader = '''
const verticesAt = ${stateWords}u;
const trianglesAt = ${triangleBase}u;
const polygonsAt = ${polygonBase}u;
const vertexWords = ${vertexWords}u;
const polygonWords = ${polygonWords}u;
''' r'''
@group(0) @binding(0) var<storage, read> commands: array<u32>;
@group(0) @binding(1) var<storage, read_write> output: array<f32>;

struct Vertex {
  clip: vec4<f32>,
  rgba: vec4<f32>,
  st: vec2<f32>,
}

fn number(at: u32) -> f32 { return bitcast<f32>(commands[at]); }

fn vector(at: u32) -> vec4<f32> {
  return vec4<f32>(number(at), number(at + 1u), number(at + 2u), number(at + 3u));
}

fn writeVertex(at: u32, vertex: Vertex) {
  for (var i = 0u; i < 4u; i++) {
    output[at + i] = vertex.clip[i];
    output[at + 4u + i] = vertex.rgba[i];
  }
  output[at + 8u] = vertex.st.x;
  output[at + 9u] = vertex.st.y;
}

fn readVertex(index: u32) -> Vertex {
  let at = index * vertexWords;
  return Vertex(
      vec4<f32>(output[at], output[at + 1u], output[at + 2u], output[at + 3u]),
      vec4<f32>(output[at + 4u], output[at + 5u], output[at + 6u], output[at + 7u]),
      vec2<f32>(output[at + 8u], output[at + 9u]));
}

@compute @workgroup_size(64)
fn transformVertices(@builtin(global_invocation_id) id: vec3<u32>) {
  if (id.x >= commands[0]) { return; }
  let at = verticesAt + id.x * vertexWords;
  let point = vector(at);
  let clip = point.x * vector(4u) + point.y * vector(8u) +
      point.z * vector(12u) + vector(16u);
  var rgba = vector(at + 4u);
  if (commands[2] != 0u) {
    let signedColor = select(rgba.rgb, rgba.rgb - 256.0, rgba.rgb >= vec3<f32>(128.0));
    let n = signedColor * (1.0 / 127.0);
    let direction = n.x * vector(20u).xyz + n.y * vector(24u).xyz +
        n.z * vector(28u).xyz;
    var normal = vec3<f32>(0.0);
    let distance = length(direction);
    if (distance > 0.0) { normal = direction / distance; }
    let lights = commands[3];
    let ambient = 32u + lights * 6u;
    var light = vector(ambient).xyz;
    for (var i = 0u; i < lights; i++) {
      let base = 32u + i * 6u;
      let dir = vec3<f32>(number(base + 3u), number(base + 4u), number(base + 5u));
      light += vector(base).xyz * max(0.0, dot(normal, dir));
    }
    rgba = vec4<f32>(light, rgba.a);
  }
  writeVertex(id.x * vertexWords,
      Vertex(clip, rgba, vec2<f32>(number(at + 8u), number(at + 9u))));
}

fn distanceFromPlane(clip: vec4<f32>, plane: u32) -> f32 {
  return clip.w + select(clip[plane / 2u], -clip[plane / 2u], (plane & 1u) != 0u);
}

@compute @workgroup_size(64)
fn clipTriangles(@builtin(global_invocation_id) id: vec3<u32>) {
  if (id.x >= commands[1]) { return; }
  let src = trianglesAt + id.x * 3u;
  let dst = polygonsAt + id.x * polygonWords;
  var vertices: array<Vertex, 9>;
  var clipped: array<Vertex, 9>;
  for (var i = 0u; i < 3u; i++) { vertices[i] = readVertex(commands[src + i]); }
  var count = 3u;
  for (var plane = 0u; plane < 6u && count >= 3u; plane++) {
    var kept = 0u;
    for (var i = 0u; i < count; i++) {
      let a = vertices[i];
      let b = vertices[(i + 1u) % count];
      let da = distanceFromPlane(a.clip, plane);
      let db = distanceFromPlane(b.clip, plane);
      if (da >= 0.0) {
        clipped[kept] = a;
        kept++;
      }
      if ((da < 0.0 && db > 0.0) || (da > 0.0 && db < 0.0)) {
        let f = da / (da - db);
        clipped[kept] = Vertex(
            a.clip + (b.clip - a.clip) * f,
            a.rgba + (b.rgba - a.rgba) * f,
            a.st + (b.st - a.st) * f);
        kept++;
      }
    }
    vertices = clipped;
    count = kept;
  }
  output[dst] = f32(count);
  for (var i = 0u; i < count; i++) {
    writeVertex(dst + 1u + i * vertexWords, vertices[i]);
  }
}
''';
}
