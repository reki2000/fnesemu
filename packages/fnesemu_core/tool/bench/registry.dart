// The registry of the benchmark cores of tool/bench.dart.
//
// A new core adds one file under tool/bench/ and one entry here.
import 'dc.dart' as dc;
import 'gba.dart' as gba;
import 'n64.dart' as n64;
import 'ps.dart' as ps;
import 'ps2.dart' as ps2;
import 'workload.dart';

/// Every benchmark core by name, with the workloads of the core by name.
final benchCores = <String, Map<String, BenchWorkload>>{
  'ps': ps.psWorkloads,
  'n64': n64.n64Workloads,
  'ps2': ps2.ps2Workloads,
  'dc': dc.dcWorkloads,
  'gba': gba.gbaWorkloads,
};
