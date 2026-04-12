part of 'r3000.dart';

typedef Matrix = (int, int, int, int, int, int, int, int, int);

typedef Vector = (int, int, int);

extension VectorMath on Vector {
  /// Multiplies a vector by a matrix.
  Vector dot(Vector v) => ($1 * v.$1, $2 * v.$2, $3 * v.$3);
  Vector operator *(int s) => ($1 * s, $2 * s, $3 * s);
  Vector operator +(Vector v) => ($1 + v.$1, $2 + v.$2, $3 + v.$3);
  Vector operator -(Vector v) => ($1 - v.$1, $2 - v.$2, $3 - v.$3);
  Vector operator <<(int shift) => ($1 << shift, $2 << shift, $3 << shift);
  Vector operator >>(int shift) => ($1 >> shift, $2 >> shift, $3 >> shift);
}
