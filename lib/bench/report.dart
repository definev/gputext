// Benchmark report assembly and transport.
//
// The macOS app is sandboxed (com.apple.security.app-sandbox in both
// entitlement files), so results leave the process on stdout: a marker
// protocol tool/run_bench.sh greps back out of `flutter run` output.
//
//   GPUBENCH:BEGIN v1
//   GPUBENCH:J:<≤6000-char slice of compact JSON>   (repeated)
//   GPUBENCH:END bytes=<total JSON length>
//
// Schema id: gputext-bench/v1. Entry shape mirrors the TS harness
// snapshots in /pretext/benchmarks (label/ms/desc) extended per tier; every
// entry carries {id, engine, label, desc, path} where path is one of
// pure | hybrid | cache-disabled | no-counterpart.

import 'dart:convert';

import 'stats.dart';

const benchSchema = 'gputext-bench/v1';
const _chunkSize = 6000;

class BenchReport {
  final Map<String, Object?> meta = {};
  final List<Map<String, Object?>> cpuResults = [];
  final List<Map<String, Object?>> frameResults = [];
  final List<Map<String, Object?>> memoryResults = [];
  final List<Map<String, Object?>> visualResults = [];
  final List<String> errors = [];

  Map<String, Object?> toJson() => {
        'status': errors.isEmpty ? 'ready' : 'error',
        'schema': benchSchema,
        'meta': meta,
        'cpuResults': cpuResults,
        'frameResults': frameResults,
        'memoryResults': memoryResults,
        'visualResults': visualResults,
        if (errors.isNotEmpty) 'errors': errors,
      };
}

Map<String, Object?> cpuResult({
  required String id,
  required String engine,
  required String label,
  required String desc,
  required String path,
  required List<double> runMs,
  Map<String, Object?> extra = const {},
}) =>
    {
      'id': id,
      'engine': engine,
      'label': label,
      'desc': desc,
      'path': path,
      'runs': runMs.length,
      'medianMs': median(runMs),
      'p90Ms': percentile(runMs, 90),
      'meanMs': mean(runMs),
      'stdMs': std(runMs),
      ...extra,
    };

Map<String, Object?> frameResult({
  required String id,
  required String engine,
  required String label,
  required String desc,
  required String path,
  required List<double> buildMs,
  required List<double> rasterMs,
  required List<double> totalMs,
  required bool partial,
  Map<String, Object?> counters = const {},
  Map<String, Object?> extra = const {},
}) =>
    {
      'id': id,
      'engine': engine,
      'label': label,
      'desc': desc,
      'path': path,
      'frames': totalMs.length,
      'partial': partial,
      'build': DistStats.of(buildMs).toJson(),
      'raster': DistStats.of(rasterMs).toJson(),
      'total': DistStats.of(totalMs).toJson(),
      'jank17': countOver(totalMs, 17),
      'jank34': countOver(totalMs, 34),
      'counters': counters,
      ...extra,
    };

/// Split compact JSON into marker lines (pure so tests can round-trip it).
List<String> chunkReportLines(String json) => [
      'GPUBENCH:BEGIN v1',
      for (var i = 0; i < json.length; i += _chunkSize)
        'GPUBENCH:J:${json.substring(i, i + _chunkSize > json.length ? json.length : i + _chunkSize)}',
      'GPUBENCH:END bytes=${json.length}',
    ];

/// Reassemble what chunkReportLines produced (used by tests; the shell
/// runner does the same with sed + tr).
String reassembleChunks(Iterable<String> lines) => lines
    .where((l) => l.startsWith('GPUBENCH:J:'))
    .map((l) => l.substring('GPUBENCH:J:'.length))
    .join();

void emitReport(BenchReport report) {
  final json = jsonEncode(report.toJson());
  // print (not debugPrint): debugPrint throttles and can drop lines; every
  // marker line must reach `flutter run` stdout intact.
  for (final line in chunkReportLines(json)) {
    // ignore: avoid_print
    print(line);
  }
}

/// Human-readable comparison table printed before the marker block, so
/// interactive runs are interpretable without the compare tool.
String summaryTable(BenchReport report) {
  final b = StringBuffer();
  b.writeln('── gputext bench summary ──');
  if (report.cpuResults.isNotEmpty) {
    b.writeln('CPU (median ms/batch):');
    for (final r in _paired(report.cpuResults)) {
      b.writeln('  ${r.padded}');
    }
  }
  if (report.frameResults.isNotEmpty) {
    b.writeln('Frames (build p50/p90 · raster p50/p90 ms):');
    for (final r in report.frameResults) {
      final build = r['build'] as Map<String, Object?>;
      final raster = r['raster'] as Map<String, Object?>;
      b.writeln('  ${(r['id'] as String).padRight(24)}'
          '${(r['engine'] as String).padRight(10)}'
          'b ${_fmt(build['p50Ms'])}/${_fmt(build['p90Ms'])}  '
          'r ${_fmt(raster['p50Ms'])}/${_fmt(raster['p90Ms'])}  '
          'jank17 ${r['jank17']}'
          '${r['partial'] == true ? '  PARTIAL' : ''}');
    }
  }
  for (final r in report.memoryResults) {
    b.writeln('  mem ${r['id']} ${r['engine'] ?? ''}: '
        'rssΔ ${_mb(r['rssDeltaBytes'])} atlas ${_mb(r['atlasGpuBytes'])} '
        'images ${_mb(r['imageBytes'])}');
  }
  for (final r in report.visualResults) {
    b.writeln('  vis ${r['id']}: meanAbsDiff ${r['meanAbsDiff']} '
        'rmse ${r['rmse']} >8/255 ${r['pctPixelsOver8']}%');
  }
  if (report.errors.isNotEmpty) {
    b.writeln('ERRORS:');
    for (final e in report.errors) {
      b.writeln('  $e');
    }
  }
  return b.toString();
}

class _PairRow {
  _PairRow(this.padded);
  final String padded;
}

Iterable<_PairRow> _paired(List<Map<String, Object?>> rows) sync* {
  for (final r in rows) {
    yield _PairRow('${(r['id'] as String).padRight(24)}'
        '${(r['engine'] as String).padRight(10)}'
        '${_fmt(r['medianMs'])} (p90 ${_fmt(r['p90Ms'])})');
  }
}

String _fmt(Object? v) =>
    v is num ? (v < 0.01 ? '<0.01' : v.toStringAsFixed(2)) : '$v';

String _mb(Object? v) =>
    v is num ? '${(v / (1024 * 1024)).toStringAsFixed(1)}MB' : '-';
