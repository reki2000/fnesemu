import 'dart:convert';
import 'dart:typed_data';

extension Uint8ListEx on Uint8List {
  List<Uint8List> split(int size) {
    return List.generate(
        length ~/ size, (i) => sublist(i * size, (i + 1) * size));
  }

  String toBase64() {
    return base64.encode(this);
  }

  static Uint8List fromBase64(String base64) {
    return Uint8List.fromList(base64Decode(base64));
  }

  static Uint8List join(List<Uint8List> list) {
    return Uint8List.fromList(
        list.fold(List<int>.empty(growable: true), (acm, l) => acm..addAll(l)));
  }

  static List<Uint8List> ofEmptyList(int count, int size) {
    return List.generate(count, (_) => Uint8List(size));
  }

  int getUint16BE(int index) {
    return this[index] << 8 | this[index + 1];
  }

  int getUint32BE(int index) {
    return this[index] << 24 |
        this[index + 1] << 16 |
        this[index + 2] << 8 |
        this[index + 3];
  }

  int getUint16LE(int index) {
    return this[index + 1] << 8 | this[index];
  }

  int getUint32LE(int index) {
    return this[index + 3] << 24 |
        this[index + 2] << 16 |
        this[index + 1] << 8 |
        this[index + 0];
  }

  void setUint16BE(int index, int value) {
    this[index] = (value >> 8) & 0xff;
    this[index + 1] = value & 0xff;
  }

  void setUint16LE(int index, int value) {
    this[index] = value & 0xff;
    this[index + 1] = (value >> 8) & 0xff;
  }

  void setUint32BE(int index, int value) {
    this[index] = (value >> 24) & 0xff;
    this[index + 1] = (value >> 16) & 0xff;
    this[index + 2] = (value >> 8) & 0xff;
    this[index + 3] = value & 0xff;
  }

  void setUint32LE(int index, int value) {
    this[index] = value & 0xff;
    this[index + 1] = (value >> 8) & 0xff;
    this[index + 2] = (value >> 16) & 0xff;
    this[index + 3] = (value >> 24) & 0xff;
  }
}
