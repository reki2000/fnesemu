import 'dart:typed_data';

// device information text, as character codes
const dcPeripheralLicense = '\x50\x72\x6f\x64\x75\x63\x65\x64\x20\x42\x79\x20'
    '\x6f\x72\x20\x55\x6e\x64\x65\x72\x20\x4c\x69\x63\x65\x6e\x73\x65\x20\x46'
    '\x72\x6f\x6d\x20\x53\x45\x47\x41\x20\x45\x4e\x54\x45\x52\x50\x52\x49\x53'
    '\x45\x53\x2c\x4c\x54\x44\x2e';

/// A Maple peripheral using canonical wire byte order, independent of host DMA.
abstract interface class DcMapleDevice {
  Uint8List? exchange(Uint8List request, int port);
  void resetDevice();
  void tickMasterClocks(int clocks);
}
