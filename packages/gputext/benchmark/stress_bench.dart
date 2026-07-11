// Headless replica of the widget_demo _stressTab per-frame cost, split by
// pipeline stage, so the RichText-vs-GPURichText fps gap can be attributed.
//
//   cd packages/gputext
//   flutter test benchmark/stress_bench.dart
//
// The stress tab oscillates the card width every frame, so each of the 12
// cards relayouts per tick. Because the feed span has WidgetSpans
// (childCount > 0) AND recognizers, RenderGPUParagraph._prepareCacheKey()
// returns null and the engine's flatten+prepare cache is bypassed — the
// full flattenSpan (per-rune fallback + bidi + HarfBuzz shape) and
// prepareParagraph re-run on every performLayout. This bench measures what
// that costs vs the width-dependent work (break + emit) that legitimately
// must re-run per frame.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/gputext.dart';
import 'package:gputext/src/engine/shared_atlas.dart';
import 'package:gputext/src/paragraph.dart' as wf;

const _samples = 12;
const _warmup = 3;
const _targetSampleMs = 30.0;

double sink = 0;

double _median(List<double> xs) {
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

double run(String name, void Function() op) {
  for (var i = 0; i < _warmup; i++) {
    op();
  }
  var repeats = 1;
  final sw = Stopwatch();
  while (true) {
    sw
      ..reset()
      ..start();
    for (var r = 0; r < repeats; r++) {
      op();
    }
    sw.stop();
    if (sw.elapsedMicroseconds >= _targetSampleMs * 1000 || repeats >= 4096) {
      break;
    }
    repeats *= 2;
  }
  final samples = <double>[];
  for (var i = 0; i < _samples; i++) {
    sw
      ..reset()
      ..start();
    for (var r = 0; r < repeats; r++) {
      op();
    }
    sw.stop();
    samples.add(sw.elapsedMicroseconds / 1000 / repeats);
  }
  final med = _median(samples);
  // ignore: avoid_print
  print('  ${name.padRight(30)} ${med.toStringAsFixed(3).padLeft(9)} ms/op '
      '(×$repeats)');
  return med;
}

/// The demo's _feedItemSpan, styles and placeholder structure intact.
TextSpan feedSpan({TapGestureRecognizer? mention, TapGestureRecognizer? thread}) {
  const ink = Color(0xFF1A1A1A);
  const blue = Color(0xFF14508C);
  Widget box() => const SizedBox(width: 10, height: 10);
  return TextSpan(
    style: const TextStyle(fontFamily: 'Lato', fontSize: 15, color: ink),
    children: [
      WidgetSpan(alignment: PlaceholderAlignment.middle, child: box()),
      const TextSpan(text: ' '),
      TextSpan(
        text: '@nora',
        style: const TextStyle(
          color: blue,
          fontWeight: FontWeight.w700,
          decoration: TextDecoration.underline,
          decorationColor: blue,
        ),
        recognizer: mention,
      ),
      const TextSpan(text: ' '),
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: box(),
      ),
      const TextSpan(text: ' reviewed '),
      TextSpan(
        text: 'PR #1842',
        style: const TextStyle(
          color: blue,
          decoration: TextDecoration.underline,
        ),
        recognizer: thread,
      ),
      const TextSpan(text: ' — the '),
      const TextSpan(
        text: 'prepare-cache',
        style: TextStyle(
          fontFamily: 'Courier',
          fontSize: 13,
          backgroundColor: Color(0x33214568),
        ),
      ),
      const TextSpan(
        text:
            ' hit rate on the shared-grid scenario is back above 99%, and '
            'the emoji ZWJ path no longer disables layout for the whole '
            'paragraph. Nice catch on the ',
      ),
      WidgetSpan(alignment: PlaceholderAlignment.middle, child: box()),
      const TextSpan(text: ' chip alignment. '),
      WidgetSpan(alignment: PlaceholderAlignment.middle, child: box()),
      WidgetSpan(alignment: PlaceholderAlignment.middle, child: box()),
      const TextSpan(text: ' '),
      WidgetSpan(alignment: PlaceholderAlignment.middle, child: box()),
      const TextSpan(text: '  ·  '),
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: box(),
      ),
    ],
  );
}

// Realistic placeholder dims (avatar, chips, image box, chips).
final _dims = <PlaceholderDimensions>[
  const PlaceholderDimensions(
      size: Size(28, 28), alignment: PlaceholderAlignment.middle),
  const PlaceholderDimensions(
      size: Size(72, 18),
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      baselineOffset: 14),
  const PlaceholderDimensions(
      size: Size(58, 18), alignment: PlaceholderAlignment.middle),
  const PlaceholderDimensions(
      size: Size(34, 18), alignment: PlaceholderAlignment.middle),
  const PlaceholderDimensions(
      size: Size(28, 18), alignment: PlaceholderAlignment.middle),
  const PlaceholderDimensions(
      size: Size(40, 48), alignment: PlaceholderAlignment.middle),
  const PlaceholderDimensions(
      size: Size(48, 18),
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      baselineOffset: 14),
];

void main() {
  test('stress tab per-frame cost', () {
    final engine = GPUText.instance;
    final lato =
        GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync());
    engine.registerFont('Lato', lato);
    // ignore: avoid_print
    print('shaper: ${engine.shaper.runtimeType}');

    final span = feedSpan();

    // The demo's width oscillation: 260..360 px triangle wave.
    final widths = [
      for (var t = 0; t < 16; t++)
        260 + 100 * (1 - ((t * 133 % 2000) / 1000 - 1).abs()),
    ];
    var wi = 0;
    double nextWidth() => widths[wi++ % widths.length];

    // Stage 1: flattenSpan — per-rune fallback resolve + bidi + HB shape.
    final flatten = run('flatten (fallback+bidi+shape)', () {
      final items = flattenSpan(
        span,
        TextScaler.noScaling,
        engine,
        placeholderDimensions: _dims,
      );
      sink += items!.length;
    });

    // Stage 2: prepareParagraph — segment analysis + measurement.
    final items = flattenSpan(
      span,
      TextScaler.noScaling,
      engine,
      placeholderDimensions: _dims,
    )!;
    final prepare = run('prepare (analyze+measure)', () {
      sink += wf.prepareParagraph(items).maxIntrinsicWidth;
    });

    // Stage 3: line breaking at the oscillating width (width-dependent;
    // this is the part RichText/SkParagraph also re-runs each frame).
    final prepared = wf.prepareParagraph(items);
    final brk = run('break (layoutPreparedLines)', () {
      final w = nextWidth();
      sink += wf
          .layoutPreparedLines(prepared, w, wf.ParagraphStyle(maxWidth: w))
          .height;
    });

    // Stage 4+5: instance emission. The render object emits TWICE per frame
    // when the span has children/recognizers: once at layout time with a
    // null table (hit boxes + placeholder positions), once at paint time
    // against the atlas.
    final para = wf.layoutPreparedLines(
        prepared, 320, wf.ParagraphStyle(maxWidth: 320));
    final atlas = SharedGlyphAtlas();
    for (final line in para.lines) {
      for (final item in line.items) {
        if (item is wf.LineRun) atlas.ensureShaped(item.shaped);
      }
    }
    final emitMetrics = run('emit metrics-only (layout)', () {
      sink +=
          wf.emitInstances(para, 320, wf.TextAlign.left, null).hitBoxes.length;
    });
    final emitAtlas = run('emit with atlas (paint)', () {
      sink += wf.emitInstances(para, 320, wf.TextAlign.left, atlas).glyphCount;
    });

    const cards = 12;
    final widthDependent = brk + emitMetrics + emitAtlas;
    final cacheBypassed = flatten + prepare;
    // ignore: avoid_print
    print('''
per card per frame:
  width-dependent (unavoidable): ${widthDependent.toStringAsFixed(3)} ms
  cache-bypassed (flatten+prepare): ${cacheBypassed.toStringAsFixed(3)} ms
per frame ×$cards cards:
  width-dependent: ${(widthDependent * cards).toStringAsFixed(2)} ms
  cache-bypassed:  ${(cacheBypassed * cards).toStringAsFixed(2)} ms
  TOTAL current:   ${((widthDependent + cacheBypassed) * cards).toStringAsFixed(2)} ms
  (frame budget at 60fps: 16.67 ms — Dart UI thread share is less)
sink=$sink''');
    expect(sink, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
