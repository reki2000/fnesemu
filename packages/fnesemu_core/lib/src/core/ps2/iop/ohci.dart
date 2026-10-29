/// The USB host controller of the IOP at 0x1f801600, an OpenHCI controller
/// (OpenHCI specification 1.0a) with nothing connected to its ports.
///
/// The registers answer as the specification describes so that a driver can
/// reset the controller and find empty ports. No frames are run, so the
/// controller raises no interrupts and processes no transfer descriptors.
class Ohci {
  static const base = 0x1f801600, end = 0x1f801660;

  static const _revision = 0x00, _commandStatus = 0x08;
  static const _interruptStatus = 0x0c, _interruptEnable = 0x10;
  static const _interruptDisable = 0x14, _fmInterval = 0x34;
  static const _fmRemaining = 0x38, _fmNumber = 0x3c, _lsThreshold = 0x44;
  static const _rhDescriptorA = 0x48, _rhStatus = 0x50;
  static const _rhPort1 = 0x54, _rhPort2 = 0x58;

  /// HcCommandStatus HostControllerReset
  static const _hcr = 1;

  /// the number of downstream ports in HcRhDescriptorA
  static const _ports = 2;

  final _regs = List<int>.filled((end - base) >> 2, 0);

  static bool handles(int address) => address >= base && address < end;

  Ohci() {
    reset();
  }

  /// the reset values of the specification
  void reset() {
    _regs.fillRange(0, _regs.length, 0);
    _set(_revision, 0x10);
    _set(_fmInterval, 0x2edf);
    _set(_lsThreshold, 0x628);
    _set(_rhDescriptorA, _ports);
  }

  int _get(int offset) => _regs[offset >> 2];

  void _set(int offset, int value) => _regs[offset >> 2] = value & 0xffffffff;

  int read(int address) {
    final offset = (address - base) & ~3;
    return switch (offset) {
      _interruptDisable => _get(_interruptEnable),
      _fmRemaining || _fmNumber => 0,
      // no device is connected, so every status bit of a port is clear
      _rhPort1 || _rhPort2 || _rhStatus => 0,
      _ => _get(offset),
    };
  }

  void write(int address, int value) {
    final offset = (address - base) & ~3;
    switch (offset) {
      case _revision || _fmRemaining || _fmNumber || _rhDescriptorA:
        break; // read only
      case _commandStatus:
        // the reset completes at once and leaves the other bits as written
        if (value & _hcr != 0) reset();
        _set(offset, _get(offset) | (value & ~_hcr));
      case _interruptStatus:
        _set(offset, _get(offset) & ~value);
      case _interruptEnable:
        _set(offset, _get(offset) | value);
      case _interruptDisable:
        _set(_interruptEnable, _get(_interruptEnable) & ~value);
      case _rhStatus || _rhPort1 || _rhPort2:
        break; // nothing to power or connect
      default:
        _set(offset, value);
    }
  }
}
