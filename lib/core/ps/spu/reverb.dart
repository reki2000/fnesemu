import 'package:fnesemu/util/int.dart';

import 'spu.dart';

class ReverbUint {
  final addr = [0, 0];
  int volume = 0;
  int offset = 0;

  void reset() {
    addr[0] = 0;
    addr[1] = 0;
    volume = 0;
    offset = 0;
  }

  String dump() =>
      "${addr[0].x6},${addr[1].x6} ${offset > 0 ? "o${offset.x6} " : ""}v:${volume.x4}";
}

extension IntVolume on int {
  // apply signed 16-bit volume
  int vol16(int vol) => this * vol >> 15;

  int volClip() => this.clip(-0x8000, 0x7fff);
}

class FirFilter {
  static const bufferSize = 39;
  static const coefficients = [
    -0x0001, 0x0000, 0x0002, 0x0000, -0x000A, 0x0000, 0x0023, 0x0000, //
    -0x0067, 0x0000, 0x010A, 0x0000, -0x0268, 0x0000, 0x0534, 0x0000, //
    -0x0B90, 0x0000, 0x2806, 0x4000, 0x2806, 0x0000, -0x0B90, 0x0000, //
    0x0534, 0x0000, -0x0268, 0x0000, 0x010A, 0x0000, -0x0067, 0x0000, //
    0x0023, 0x0000, -0x000A, 0x0000, 0x0002, 0x0000, -0x0001, //
  ];

  final _buffer = List.filled(bufferSize, 0);
  int _current = 0;

  void push(int value) {
    _buffer[_current] = value;
    _current++;
    if (_current >= bufferSize) {
      _current = 0;
    }
  }

  void clear() {
    _buffer.fillRange(0, bufferSize, 0);
    _current = 0;
  }

  int apply() {
    int filtered = 0;
    int index = _current;
    for (int i = 0; i < coefficients.length; i++) {
      filtered += coefficients[i] * _buffer[index++];
      if (index >= bufferSize) {
        index = 0;
      }
    }
    return filtered ~/ 0x8000;
  }
}

class Reverb {
  final Spu spu;
  Reverb(this.spu);

  void reset() {
    for (final e in [..._apf, ..._comb, ..._ssr, ..._dsr]) {
      e.reset();
    }

    _baseAddr = 0;
    setReverbEnabled(0);
    _inputVolume[0] = _inputVolume[1] = 0x8000;
    outputVolume[0] = outputVolume[1] = 0x8000;

    writeEnabled = false;
    _workAddr = 0;
    _renderL = false;
    _lastOutput[0] = _lastOutput[1] = 0;
    _firFilterInput[0].clear();
    _firFilterInput[1].clear();
  }

  final _apf = [ReverbUint(), ReverbUint()];
  final _comb = [ReverbUint(), ReverbUint(), ReverbUint(), ReverbUint()];
  final _ssr = [ReverbUint(), ReverbUint()];
  final _dsr = [ReverbUint(), ReverbUint()];
  final _inputVolume = [0, 0];

  final reverbEnabled = List.filled(24, false);
  final outputVolume = [0, 0];

  int _baseAddr = 0;
  void setBaseAddr(int value) {
    _baseAddr = _workAddr = value & 0x7ffff;
  }

  int _workAddr = 0;
  bool writeEnabled = false;

  final _firFilterInput = [FirFilter(), FirFilter()];
  final _firFilterOutput = [FirFilter(), FirFilter()];

  bool _renderL = false;

  final _lastOutput = [0, 0];

  int _wrapAddr(int offset) {
    final addr = (_workAddr + offset - _baseAddr) % (0x80000 - _baseAddr);
    return _baseAddr + addr;
  }

  int _readRam(int offset) => spu.readRam16(_wrapAddr(offset)).rel16;

  void _writeRam(int offset, int value) {
    if (writeEnabled) {
      spu.writeRam16(_wrapAddr(offset), value.volClip());
    }
  }

  (int, int) render(int inL, int inR) {
    _firFilterInput[0].push(inL);
    _firFilterInput[1].push(inR);

    int l = 0;
    int r = 0;
    if (_renderL) {
      l = _applyReverb(0, _firFilterInput[0].apply());
    } else {
      r = _applyReverb(1, _firFilterInput[1].apply());

      _workAddr = _wrapAddr(2);
    }

    _renderL = !_renderL;

    _firFilterOutput[0].push(l);
    _firFilterOutput[1].push(r);

    return (
      (_firFilterOutput[0].apply() << 1).vol16(outputVolume[0]),
      (_firFilterOutput[1].apply() << 1).vol16(outputVolume[1]),
    );
  }

  int _applyReverb(int ch, int value) {
    final input = value.vol16(_inputVolume[ch]);

    final vIir = _ssr[0].volume;
    final vWall = _ssr[1].volume;

    final mSame2 = _readRam(_ssr[0].addr[ch].dec2);
    _writeRam(
        _ssr[0].addr[ch],
        (input + _readRam(_ssr[1].addr[ch]).vol16(vWall) - mSame2).vol16(vIir) +
            mSame2);

    final mDiff2 = _readRam(_dsr[0].addr[ch].dec2);
    _writeRam(
        _dsr[0].addr[ch],
        (input + _readRam(_dsr[1].addr[1 - ch]).vol16(vWall) - mDiff2)
                .vol16(vIir) +
            mDiff2);

    int output = 0;

    for (final comb in _comb) {
      output += _readRam(comb.addr[ch]).vol16(comb.volume);
    }

    for (final apf in _apf) {
      final mApf = _readRam(apf.addr[ch] - apf.offset);
      output -= mApf.vol16(apf.volume);
      _writeRam(apf.addr[ch], output);
      output = output.vol16(apf.volume) + mApf;
    }

    return output;
  }

  void setOutputVolume(int ch, int value) {
    outputVolume[ch & 1] = value.rel16;
  }

  int getReverbEnabled() => reverbEnabled.asMap().entries.fold(
        0,
        (acc, entry) => (acc << 1) | (entry.value ? 1 : 0),
      );

  void setReverbEnabled(int value) {
    for (int i = 0; i < reverbEnabled.length; i++, value >>= 1) {
      reverbEnabled[i] = value.bit0;
    }
    // debugLog(dump());
  }

  void write16(int offset, int value) {
    final addr = value.mask16 << 3;
    final volume = value.rel16;
    final _ = switch (offset >> 1 & 0x1f) {
      0x00 => _apf[0].offset = addr,
      0x01 => _apf[1].offset = addr,
      0x02 => _ssr[0].volume = _dsr[0].volume = volume,
      0x03 => _comb[0].volume = volume,
      0x04 => _comb[1].volume = volume,
      0x05 => _comb[2].volume = volume,
      0x06 => _comb[3].volume = volume,
      0x07 => _ssr[1].volume = _dsr[1].volume = volume,
      0x08 => _apf[0].volume = volume,
      0x09 => _apf[1].volume = volume,
      0x0a => _ssr[0].addr[0] = addr,
      0x0b => _ssr[0].addr[1] = addr,
      0x0c => _comb[0].addr[0] = addr,
      0x0d => _comb[0].addr[1] = addr,
      0x0e => _comb[1].addr[0] = addr,
      0x0f => _comb[1].addr[1] = addr,
      0x10 => _ssr[1].addr[0] = addr,
      0x11 => _ssr[1].addr[1] = addr,
      0x12 => _dsr[0].addr[0] = addr,
      0x13 => _dsr[0].addr[1] = addr,
      0x14 => _comb[2].addr[0] = addr,
      0x15 => _comb[2].addr[1] = addr,
      0x16 => _comb[3].addr[0] = addr,
      0x17 => _comb[3].addr[1] = addr,
      0x18 => _dsr[1].addr[0] = addr,
      0x19 => _dsr[1].addr[1] = addr,
      0x1a => _apf[0].addr[0] = addr,
      0x1b => _apf[0].addr[1] = addr,
      0x1c => _apf[1].addr[0] = addr,
      0x1d => _apf[1].addr[1] = value.mask16 << 3,
      0x1e => _inputVolume[0] = volume,
      0x1f => _inputVolume[1] = volume,
      _ => throw "spu: reverb: unreachable offset:${offset.x8}",
    };
  }

  String dump() => "en:${reverbEnabled.map((e) => e ? "E" : "-").join("")} "
      "apf:${_apf.map((f) => f.dump()).join(" ")} "
      "ssr:${_ssr.map((e) => e.dump()).join(" ")} "
      "dsr:${_dsr.map((e) => e.dump()).join(" ")} "
      "comb:${_comb.map((e) => e.dump()).join(" ")} "
      "in:${_inputVolume.map((e) => e.x4).join(",")} "
      "out:${outputVolume.map((e) => e.x4).join(",")}";
}
