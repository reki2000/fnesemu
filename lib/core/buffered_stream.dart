// ...existing code...
import 'dart:async';

class BufferedStreamController<T> {
  T? _lastValue;
  final _controller = StreamController<T>.broadcast();

  Stream<T> get stream async* {
    if (_lastValue != null) {
      yield _lastValue!;
    }
    yield* _controller.stream;
  }

  void add(T event) {
    _lastValue = event;
    _controller.add(event);
  }
}
