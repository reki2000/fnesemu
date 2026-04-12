// a circular buffer with fixed size
class CircularBuffer {
  final int size;
  final List<int> _buffer;
  int _current = 0;

  CircularBuffer(this.size) : _buffer = List.filled(size, 0);

  void push(int value) {
    _buffer[_current] = value;
    _current = (_current + 1) % size;
  }

  void clear() {
    _buffer.fillRange(0, size, 0);
    _current = 0;
  }

  int operator [](int index) {
    return _buffer[(_current + size - index) % size];
  }
}
