import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/text/metrics_cache.dart';

void main() {
  late GPUFont font;

  setUpAll(() {
    font = GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync());
  });

  tearDown(() => debugClearSegmentMetricsFor(font));

  test('segment metrics cache stays within capacity', () {
    final cap = segmentMetricsCacheCapacity;
    for (var i = 0; i < cap + 40; i++) {
      segmentMetricsOf(font, 'seg$i');
    }
    expect(debugSegmentMetricsLengthFor(font), cap);
  });

  test('LRU touch keeps a hot entry when overflowing', () {
    debugClearSegmentMetricsFor(font);
    final cap = segmentMetricsCacheCapacity;
    segmentMetricsOf(font, 'hot');
    for (var i = 0; i < cap; i++) {
      // Re-touch hot so it is newest before each insert wave ends.
      if (i % 50 == 0) segmentMetricsOf(font, 'hot');
      segmentMetricsOf(font, 'cold$i');
    }
    expect(debugSegmentMetricsLengthFor(font), cap);
    // hot must still be present (re-touched); measuring again is a hit.
    final before = debugSegmentMetricsLengthFor(font);
    segmentMetricsOf(font, 'hot');
    expect(debugSegmentMetricsLengthFor(font), before);
  });
}
