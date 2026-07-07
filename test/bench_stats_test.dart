import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/bench/report.dart';
import 'package:gputext/bench/stats.dart';

void main() {
  group('stats', () {
    test('percentile interpolates and clamps', () {
      final xs = [4.0, 1.0, 3.0, 2.0]; // sorted: 1 2 3 4
      expect(percentile(xs, 0), 1.0);
      expect(percentile(xs, 100), 4.0);
      expect(percentile(xs, 50), 2.5);
      expect(median([5.0]), 5.0);
      expect(median(<double>[]), 0.0);
    });

    test('mean/std/countOver', () {
      final xs = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0];
      expect(mean(xs), 5.0);
      expect(std(xs), 2.0); // classic population-σ example
      expect(countOver(xs, 4.5), 4);
      expect(std([3.0]), 0.0);
    });

    test('DistStats.of summarizes and serializes', () {
      final d = DistStats.of([1.0, 2.0, 3.0, 4.0, 100.0]);
      expect(d.count, 5);
      expect(d.p50, 3.0);
      expect(d.max, 100.0);
      final json = d.toJson();
      expect(json['count'], 5);
      expect(json['p50Ms'], 3.0);
      expect(json['maxMs'], 100.0);
    });
  });

  group('report', () {
    test('cpu/frame result shape and JSON round-trip', () {
      final report = BenchReport()
        ..meta['os'] = 'test'
        ..cpuResults.add(cpuResult(
          id: 'cpu.x',
          engine: 'gputext',
          label: 'x',
          desc: 'd',
          path: 'pure',
          runMs: [1.0, 2.0, 3.0],
          extra: {'sink': 42},
        ))
        ..frameResults.add(frameResult(
          id: 'frame.y',
          engine: 'richtext',
          label: 'y',
          desc: 'd',
          path: 'pure',
          buildMs: [1.0, 20.0],
          rasterMs: [2.0, 40.0],
          totalMs: [3.0, 60.0],
          partial: false,
          counters: {'cacheHits': 7},
        ));
      final decoded =
          jsonDecode(jsonEncode(report.toJson())) as Map<String, dynamic>;
      expect(decoded['status'], 'ready');
      expect(decoded['schema'], benchSchema);
      final cpu = (decoded['cpuResults'] as List).single as Map;
      expect(cpu['medianMs'], 2.0);
      expect(cpu['sink'], 42);
      final frame = (decoded['frameResults'] as List).single as Map;
      expect(frame['jank17'], 1);
      expect(frame['jank34'], 1);
      expect((frame['counters'] as Map)['cacheHits'], 7);
      expect((frame['build'] as Map)['count'], 2);
    });

    test('error status when errors recorded', () {
      final report = BenchReport()..errors.add('boom');
      expect(report.toJson()['status'], 'error');
    });

    test('chunk emission reassembles byte-exactly', () {
      final json = jsonEncode({
        'blob': List.generate(4000, (i) => 'item-$i'),
      });
      expect(json.length, greaterThan(12000)); // spans >2 chunks
      final lines = chunkReportLines(json);
      expect(lines.first, 'GPUBENCH:BEGIN v1');
      expect(lines.last, 'GPUBENCH:END bytes=${json.length}');
      for (final l in lines.sublist(1, lines.length - 1)) {
        expect(l.length, lessThanOrEqualTo('GPUBENCH:J:'.length + 6000));
      }
      expect(reassembleChunks(lines), json);
      // Interleaved non-marker noise (flutter run logs) is ignored.
      expect(reassembleChunks(['noise', ...lines, 'flutter: done']), json);
    });
  });
}
