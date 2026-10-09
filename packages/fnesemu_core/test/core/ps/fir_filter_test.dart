import 'package:fnesemu_core/core/ps/spu/reverb.dart';
import 'package:test/test.dart';

void main() {
  test('FIR impulse preserves the fixed 39-tap response', () {
    const expectedResponse = [
      -0x0001, 0x0000, 0x0002, 0x0000, -0x000A, 0x0000, 0x0023, 0x0000, //
      -0x0067, 0x0000, 0x010A, 0x0000, -0x0268, 0x0000, 0x0534, 0x0000, //
      -0x0B90, 0x0000, 0x2806, 0x4000, 0x2806, 0x0000, -0x0B90, 0x0000, //
      0x0534, 0x0000, -0x0268, 0x0000, 0x010A, 0x0000, -0x0067, 0x0000, //
      0x0023, 0x0000, -0x000A, 0x0000, 0x0002, 0x0000, -0x0001, //
    ];
    final filter = FirFilter();
    for (var i = 0; i < expectedResponse.length; i++) {
      filter.push(i == 0 ? 0x8000 : 0);
      expect(filter.apply(), expectedResponse[i], reason: 'tap $i');
    }
    filter.push(0);
    expect(filter.apply(), 0);
  });

  test('sparse FIR matches full convolution through wraparound and clear', () {
    final filter = FirFilter();
    final history = List<int>.filled(FirFilter.bufferSize, 0);
    var nextWrite = 0;
    for (var i = 0; i < 300; i++) {
      if (i == 137) {
        filter.clear();
        history.fillRange(0, history.length, 0);
        nextWrite = 0;
      }
      final sample = (i * 1237 & 0xffff) - 0x8000;
      history[nextWrite] = sample;
      nextWrite = (nextWrite + 1) % history.length;
      filter.push(sample);
      var fullConvolution = 0;
      for (var tap = 0; tap < FirFilter.coefficients.length; tap++) {
        fullConvolution += FirFilter.coefficients[tap] *
            history[(nextWrite + tap) % history.length];
      }
      expect(filter.apply(), fullConvolution ~/ 0x8000, reason: 'sample $i');
    }
  });
}
