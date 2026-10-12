/// Native decoders supply their address, encoded instruction and mnemonic.
/// The code column has a fixed width for each CPU, including padding for short
/// instructions. No instruction bytes are truncated.
String formatDisasm(String address, String code, String mnemonic,
    {required int codeWidth}) {
  if (code.length > codeWidth) {
    throw ArgumentError.value(code, 'code', 'exceeds $codeWidth columns');
  }
  return '$address: ${code.padRight(codeWidth)} ${mnemonic.trim()}';
}
