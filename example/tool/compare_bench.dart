// Baseline delta table for gputext benchmark snapshots (pure dart:core, run
// with `dart run tool/compare_bench.dart baseline.json current.json`).
//
// Entries join by (id, engine). Gated metrics: cpu medianMs, frame build.p50
// and raster.p50. With --fail-threshold=N the exit code is 1 when any gated
// metric regressed by more than N percent — CI-friendly.

// This is a CLI tool: stdout IS the interface.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  double? failThreshold;
  final paths = <String>[];
  for (final a in args) {
    if (a.startsWith('--fail-threshold=')) {
      failThreshold = double.parse(a.substring('--fail-threshold='.length));
    } else {
      paths.add(a);
    }
  }
  if (paths.length != 2) {
    stderr.writeln(
      'usage: dart run tool/compare_bench.dart '
      '<baseline.json> <current.json> [--fail-threshold=N]',
    );
    exit(64);
  }
  final base = _load(paths[0]);
  final cur = _load(paths[1]);

  final rows = <List<String>>[];
  var regressions = 0;

  void compare(String metricLabel, num? b, num? c) {
    if (b == null || c == null || b == 0) return;
    final delta = (c - b) / b * 100;
    final flag = failThreshold != null && delta > failThreshold ? ' ⚠' : '';
    if (flag.isNotEmpty) regressions++;
    rows.add([
      metricLabel,
      b.toStringAsFixed(3),
      c.toStringAsFixed(3),
      '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}%$flag',
    ]);
  }

  Map<(String, String), Map<String, dynamic>> index(
    Map<String, dynamic> report,
    String tier,
  ) {
    final out = <(String, String), Map<String, dynamic>>{};
    for (final e in (report[tier] as List? ?? const [])) {
      final m = e as Map<String, dynamic>;
      out[(m['id'] as String? ?? '', m['engine'] as String? ?? '')] = m;
    }
    return out;
  }

  final baseCpu = index(base, 'cpuResults');
  for (final entry in index(cur, 'cpuResults').entries) {
    final b = baseCpu[entry.key];
    if (b == null) continue;
    compare(
      '${entry.key.$1} [${entry.key.$2}] median',
      b['medianMs'] as num?,
      entry.value['medianMs'] as num?,
    );
  }
  final baseFrames = index(base, 'frameResults');
  for (final entry in index(cur, 'frameResults').entries) {
    final b = baseFrames[entry.key];
    if (b == null) continue;
    num? dig(Map<String, dynamic>? m, String outer, String inner) =>
        (m?[outer] as Map<String, dynamic>?)?[inner] as num?;
    compare(
      '${entry.key.$1} [${entry.key.$2}] build p50',
      dig(b, 'build', 'p50Ms'),
      dig(entry.value, 'build', 'p50Ms'),
    );
    compare(
      '${entry.key.$1} [${entry.key.$2}] raster p50',
      dig(b, 'raster', 'p50Ms'),
      dig(entry.value, 'raster', 'p50Ms'),
    );
  }

  if (rows.isEmpty) {
    print('no comparable entries between snapshots');
    return;
  }
  final widths = List.generate(
    4,
    (i) => rows.map((r) => r[i].length).reduce((a, b) => a > b ? a : b),
  );
  final header = ['metric', 'baseline ms', 'current ms', 'Δ'];
  for (var i = 0; i < 4; i++) {
    if (header[i].length > widths[i]) widths[i] = header[i].length;
  }
  String fmt(List<String> r) => [
    r[0].padRight(widths[0]),
    r[1].padLeft(widths[1]),
    r[2].padLeft(widths[2]),
    r[3].padLeft(widths[3]),
  ].join('  ');
  print(fmt(header));
  print(''.padRight(widths.reduce((a, b) => a + b) + 6, '─'));
  for (final r in rows) {
    print(fmt(r));
  }

  if (failThreshold != null && regressions > 0) {
    stderr.writeln(
      '$regressions metric(s) regressed more than $failThreshold%',
    );
    exit(1);
  }
}

Map<String, dynamic> _load(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
