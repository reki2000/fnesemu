import 'runtime.dart';

bool get supported => false;

JitRuntime? create(int ctxWords, int addrMask, JitRead read, JitWrite write) =>
    null;
