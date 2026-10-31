import 'dart:typed_data';

import 'fault.dart';

/// Functional closed-volume parity and planar masks, System Architecture §§3.4.5, 3.7.8–9.
/// Coplanar comparisons, parameter packing and raster precision need hardware validation.
class DcGpuModifier {
  DcGpuModifier({required this.readWord, required this.culled});
  final int Function(int) readWord;
  final bool Function(double, int) culled;
  final _float = ByteData(4);

  double _number(int address) {
    _float.setUint32(0, readWord(address), Endian.little);
    final value = _float.getFloat32(0, Endian.little);
    if (!value.isFinite) {
      throw const DcUnsupported('CORE nonfinite modifier coordinate');
    }
    return value;
  }

  Uint8List evaluate(int objectList, int parameterBase, int originX,
      int originY, Float64List depth, double sampleOffset,
      {Uint8List? active}) {
    final area = Uint8List(1024), parity = Uint8List(1024);
    final visited = <int>{};
    var unfinished = false;
    for (var address = objectList;; address += 4) {
      if (!visited.add(address)) {
        throw const DcUnsupported('CORE cyclic modifier object list');
      }
      final pointer = readWord(address);
      if (pointer >> 29 == 7) {
        if (pointer & 0x10000000 != 0) {
          if (unfinished) {
            throw const DcUnsupported(
                'CORE modifier volume has no last polygon');
          }
          return area;
        }
        address = (pointer & 0xfffffc) - 4;
        continue;
      }
      final kind = pointer >> 29;
      if ((kind != 4 && kind != 5) || pointer & 0x01e00000 != 0) {
        throw const DcUnsupported(
            'CORE modifier requires XYZ-only triangle/quad arrays');
      }
      var parameter = parameterBase + (pointer & 0x1fffff) * 4;
      final count = ((pointer >> 25) & 15) + 1;
      for (var object = 0; object < count; object++) {
        final isp = readWord(parameter), instruction = isp >> 29;
        if (instruction > 2) {
          throw const DcUnsupported(
              'CORE reserved modifier volume instruction');
        }
        final vertices = [
          for (var i = 0; i < 3; i++)
            _Point(
                _number(parameter + 12 + i * 12),
                _number(parameter + 16 + i * 12),
                _number(parameter + 20 + i * 12))
        ];
        final determinant =
            _edge(vertices[0], vertices[1], vertices[2].x, vertices[2].y);
        if (!determinant.isFinite) {
          throw const DcUnsupported('CORE modifier determinant overflow');
        }
        if (!culled(determinant, isp)) {
          _triangle(vertices, vertices, parity, depth, originX, originY,
              sampleOffset, active);
          if (kind == 5) {
            final d =
                _Point(_number(parameter + 48), _number(parameter + 52), 0);
            final quad = [...vertices, d];
            for (var i = 1; i < 4; i++) {
              final e = quad[i], f = quad[(i + 1) & 3], g = quad[(i + 2) & 3];
              if (_edge(e, f, g.x, g.y) * determinant.sign < 0) {
                throw const DcUnsupported(
                    'CORE concave/crossed modifier quad is unverified');
              }
            }
            _triangle([vertices[0], vertices[2], d], vertices, parity, depth,
                originX, originY, sampleOffset, active);
          }
        }
        unfinished = true;
        if (instruction != 0) {
          for (var pixel = 0; pixel < 1024; pixel++) {
            // Outside Last retains the previous area only outside this volume.
            area[pixel] = instruction == 1
                ? area[pixel] | parity[pixel]
                : area[pixel] & (parity[pixel] ^ 1);
          }
          parity.fillRange(0, 1024, 0);
          unfinished = false;
        }
        // Modifier records use the generic three-word header and XYZ-only vertices.
        parameter += (3 + (kind == 5 ? 4 : 3) * 3) * 4;
      }
    }
  }

  double _edge(_Point a, _Point b, double x, double y) =>
      (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
  bool _topLeft(_Point a, _Point b) => b.y < a.y || (b.y == a.y && b.x > a.x);

  void _triangle(
      List<_Point> vertices,
      List<_Point> plane,
      Uint8List parity,
      Float64List depth,
      int originX,
      int originY,
      double offset,
      Uint8List? active) {
    var a = vertices[0], b = vertices[1];
    final c = vertices[2];
    var determinant = _edge(a, b, c.x, c.y);
    if (determinant == 0) return;
    if (determinant < 0) {
      final first = a;
      a = b;
      b = first;
      determinant = -determinant;
    }
    final pa = plane[0], pb = plane[1], pc = plane[2];
    final planeArea = _edge(pa, pb, pc.x, pc.y);
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        final index = y * 32 + x;
        if (active != null && active[index] == 0) continue;
        final px = originX + x + offset, py = originY + y + offset;
        final ea = _edge(b, c, px, py),
            eb = _edge(c, a, px, py),
            ec = _edge(a, b, px, py);
        if (ea < 0 ||
            eb < 0 ||
            ec < 0 ||
            (ea == 0 && !_topLeft(b, c)) ||
            (eb == 0 && !_topLeft(c, a)) ||
            (ec == 0 && !_topLeft(a, b))) {
          continue;
        }
        final wa = _edge(pb, pc, px, py) / planeArea;
        final wb = _edge(pc, pa, px, py) / planeArea;
        final z = pa.z * wa + pb.z * wb + pc.z * (1 - wa - wb);
        if (!z.isFinite) {
          throw const DcUnsupported('CORE modifier depth overflow');
        }
        // Equal-depth behavior is a functional GEq policy pending hardware measurements.
        if (z >= depth[index]) parity[index] ^= 1;
      }
    }
  }
}

class _Point {
  const _Point(this.x, this.y, this.z);
  final double x, y, z;
}
