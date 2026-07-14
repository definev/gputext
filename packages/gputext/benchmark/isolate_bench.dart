// Headless benchmark for the opt-in low-level API (package:gputext/lowlevel):
// the layout/display split (GPUTextLayout) and background-isolate layout
// (GPUTextWorker). Runs under the flutter tester, no window required:
//
//   cd packages/gputext
//   flutter test benchmark/isolate_bench.dart
//
// What it measures and why it matters:
//
//   split.cold_full    — prepare + reflow + emit from scratch, per paragraph.
//                        The cost a naive "relayout every frame" pays.
//   split.reflow_only  — reuse the prepared paragraph, re-break at a new width.
//                        The resize cost once phase 1 is amortized.
//   split.reemit_only  — reuse the laid-out lines, re-emit the instance buffer.
//                        The per-frame recolor / animate cost.
//     => reflow_only and reemit_only should each be a fraction of cold_full;
//        that delta is the value of separating layout from display.
//
//   main.layout_block  — lay out N paragraphs inline on THIS (UI) isolate.
//                        This is a hard UI-thread stall of that many ms.
//   worker.layout_wall — lay out the same N via a warm GPUTextWorker and
//                        transfer the buffers back. Wall-clock includes the
//                        isolate hop + zero-copy transfer, but the UI isolate
//                        stall is ~0 (just the awaits). The point is not that
//                        wall-clock is smaller — it's that the UI thread is
//                        free while this runs.
//
// Async rows report median wall-ms over a handful of samples (no inner-repeat
// calibration — each op already dwarfs timer noise).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/engine/shared_atlas.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/lowlevel/gpu_text_layout.dart';
import 'package:gputext/src/lowlevel/gpu_text_worker.dart';
import 'package:gputext/src/paragraph.dart' as wf;
import 'package:gputext/src/text/shaper.dart' show TextShaper;

const _targetSampleMs = 30.0;
const _samples = 12;
const _warmupSamples = 3;
const _asyncSamples = 8;
const _asyncWarmup = 2;
const _widths = [200.0, 260.0, 320.0, 380.0, 440.0];
const _emitWidth = 400.0;

double sink = 0;

class BenchResult {
  BenchResult(this.name, this.samplesMs, this.repeats);

  final String name;
  final List<double> samplesMs;
  final int repeats;

  double get median => _median(samplesMs);
  double get mad => _mad(samplesMs);
  double get min => samplesMs.reduce(math.min);

  Map<String, Object> toJson() => {
    'name': name,
    'medianMs': median,
    'madMs': mad,
    'minMs': min,
    'repeats': repeats,
    'samples': samplesMs,
  };
}

double _median(List<double> xs) {
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

double _mad(List<double> xs) {
  final m = _median(xs);
  return _median([for (final x in xs) (x - m).abs()]);
}

void _report(BenchResult r) {
  // ignore: avoid_print
  print(
    '  ${r.name.padRight(24)} '
    '${r.median.toStringAsFixed(3).padLeft(9)} ms  '
    '±${r.mad.toStringAsFixed(3)}  '
    '(min ${r.min.toStringAsFixed(3)}, ×${r.repeats})',
  );
}

BenchResult run(String name, void Function() op) {
  for (var i = 0; i < _warmupSamples; i++) {
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
  final result = BenchResult(name, samples, repeats);
  _report(result);
  return result;
}

Future<BenchResult> runAsync(String name, Future<void> Function() op) async {
  for (var i = 0; i < _asyncWarmup; i++) {
    await op();
  }
  final samples = <double>[];
  final sw = Stopwatch();
  for (var i = 0; i < _asyncSamples; i++) {
    sw
      ..reset()
      ..start();
    await op();
    sw.stop();
    samples.add(sw.elapsedMicroseconds / 1000);
  }
  final result = BenchResult(name, samples, 1);
  _report(result);
  return result;
}

// --- corpus ---

List<String> _paragraphsOf(String text, {int minLen = 60}) => text
    .split(RegExp(r'\n\s*\n'))
    .map((p) => p.replaceAll('\n', ' ').trim())
    .where((p) => p.length >= minLen)
    .toList();

/// Inline mirror of GPUTextWorker._runLayout, for the UI-thread-stall baseline.
/// Uses the same shared shaping ([buildRunItems] + [shaper]) as the worker so
/// the two paths are directly comparable.
int _layoutInline(String text, GPUFont font, TextShaper? shaper) {
  final specs = [
    GPUTextRunSpec(
      text: text,
      fontId: 'lato',
      fontSizePx: 16,
      color: const [0, 0, 0, 1],
    ),
  ];
  final items = buildRunItems(specs, {'lato': font}, shaper);
  final style = wf.ParagraphStyle(maxWidth: _emitWidth, align: wf.TextAlign.left);
  final prepared = wf.prepareParagraph(items);
  final lines = wf.layoutPreparedLines(prepared, _emitWidth, style);
  final atlas = SharedGlyphAtlas();
  for (final line in lines.lines) {
    for (final item in line.items) {
      if (item is wf.LineRun) atlas.ensureShaped(item.shaped);
    }
  }
  return wf.emitInstances(lines, _emitWidth, wf.TextAlign.left, atlas).glyphCount;
}

void main() {
  test('isolate bench', () async {
    final latoBytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    final font = GPUFont.parse(latoBytes);
    // Match the worker's shaping so the main baseline is comparable.
    final shaper = loadHarfBuzzShaper();
    const bench = '../../example/assets/bench';
    final gatsby = File('$bench/en-gatsby-opening.txt').readAsStringSync();
    final paras = _paragraphsOf(gatsby).take(40).toList();

    wf.TextRun mkRun(String text) => wf.TextRun(
      text: text,
      font: font,
      fontSizePx: 16,
      color: const [0, 0, 0, 1],
    );

    // A shared atlas pre-populated with every corpus glyph, so emit() resolves
    // real geometry rather than short-circuiting on a miss.
    final atlas = SharedGlyphAtlas();
    for (final t in paras) {
      final lines = wf.breakLines(
        [mkRun(t)],
        _emitWidth,
        wf.ParagraphStyle(maxWidth: _emitWidth),
      );
      for (final line in lines.lines) {
        for (final item in line.items) {
          if (item is wf.LineRun) atlas.ensureShaped(item.shaped);
        }
      }
    }

    final style = wf.ParagraphStyle(maxWidth: _emitWidth);
    final results = <BenchResult>[];
    // ignore: avoid_print
    print('isolate_bench: ${paras.length} paragraphs\n');

    // --- split: layout once, display many ---

    results.add(
      run('split.cold_full', () {
        for (final t in paras) {
          final layout = GPUTextLayout.compute([mkRun(t)])..reflow(_emitWidth, style);
          sink += layout.emit(atlas).glyphCount;
        }
      }),
    );

    // Amortize phase 1 across ops: prepare each paragraph once, reflow per op.
    final prepared = [for (final t in paras) GPUTextLayout.compute([mkRun(t)])];
    var wi = 0;
    results.add(
      run('split.reflow_only', () {
        final w = _widths[wi++ % _widths.length];
        final s = wf.ParagraphStyle(maxWidth: w);
        for (final layout in prepared) {
          sink += layout.reflow(w, s).height;
        }
      }),
    );

    // Amortize phases 1 + 2: reflow each once, re-emit per op (recolor case).
    final reflowed = [
      for (final t in paras) GPUTextLayout.compute([mkRun(t)])..reflow(_emitWidth, style),
    ];
    results.add(
      run('split.reemit_only', () {
        for (final layout in reflowed) {
          sink += layout.emit(atlas).glyphCount;
        }
      }),
    );

    // --- isolate: UI-thread stall vs off-thread wall-clock ---

    const workerCount = 20;
    final workerParas = paras.take(workerCount).toList();

    results.add(
      run('main.layout_block', () {
        for (final t in workerParas) {
          sink += _layoutInline(t, font, shaper);
        }
      }),
    );

    final worker = await GPUTextWorker.spawn();
    await worker.registerFont('lato', Uint8List.fromList(latoBytes));

    GPUTextLayoutRequest reqOf(String t) => GPUTextLayoutRequest(
      runs: [GPUTextRunSpec(text: t, fontId: 'lato', fontSizePx: 16)],
      maxWidth: _emitWidth,
    );

    // Sanity: the worker must produce the same glyph count as the main path.
    final probe = await worker.layout(reqOf(workerParas.first));
    final mainGlyphs = _layoutInline(workerParas.first, font, shaper);
    expect(
      probe.glyphCount,
      mainGlyphs,
      reason: 'worker glyph count must match the main-isolate layout',
    );
    expect(probe.materialize().length, probe.glyphCount * 16);

    results.add(
      await runAsync('worker.layout_wall', () async {
        final out = await Future.wait([
          for (final t in workerParas) worker.layout(reqOf(t)),
        ]);
        for (final o in out) {
          sink += o.materialize().length;
        }
      }),
    );

    // --- reflow: the width-drag case (prepare once, reflow at cycled widths).
    // reflow.full ships the outline atlas every time; reflow.atlas_skip ships
    // it once and only the instance buffer thereafter.
    final bigDoc = <GPUInlineSpec>[
      GPUTextRunSpec(
        text: workerParas.join('\n\n'),
        fontId: 'lato',
        fontSizePx: 16,
      ),
    ];
    await worker.prepareDoc('bench', bigDoc);

    // Inline baseline: the SAME layout+emit on the main isolate, no round-trip.
    // reflow.worker minus reflow.inline == the isolate tax (scheduling + the
    // TransferableTypedData move machinery), NOT payload copying.
    final bigItems = buildRunItems(bigDoc, {'lato': font}, shaper);
    final bigPrepared = wf.prepareParagraph(bigItems);
    final bigAtlas = SharedGlyphAtlas();
    bandRunItems(bigAtlas, bigItems);
    var iw = 0;
    results.add(
      run('reflow.inline', () {
        final w = _widths[iw++ % _widths.length];
        final lines = wf.layoutPreparedLines(
          bigPrepared,
          w,
          wf.ParagraphStyle(maxWidth: w),
        );
        sink += wf.emitInstances(lines, w, wf.TextAlign.left, bigAtlas).glyphCount;
      }),
    );

    var rw = 0;
    results.add(
      await runAsync('reflow.full', () async {
        final w = _widths[rw++ % _widths.length];
        final d = await worker.reflowDoc('bench', w, includeAtlas: true);
        sink += d.materialize().length + d.materializeCurves().length;
      }),
    );
    await worker.reflowDoc('bench', _widths.first); // warm the atlas once
    rw = 0;
    results.add(
      await runAsync('reflow.atlas_skip', () async {
        final w = _widths[rw++ % _widths.length];
        final d = await worker.reflowDoc('bench', w, includeAtlas: false);
        sink += d.materialize().length;
      }),
    );

    worker.dispose();

    // --- derived read-out ---
    final block = results.firstWhere((r) => r.name == 'main.layout_block').median;
    final wall = results.firstWhere((r) => r.name == 'worker.layout_wall').median;
    final cold = results.firstWhere((r) => r.name == 'split.cold_full').median;
    final reemit = results.firstWhere((r) => r.name == 'split.reemit_only').median;
    // ignore: avoid_print
    print(
      '\n  split win:  re-emit is ${(cold / reemit).toStringAsFixed(1)}x '
      'cheaper than a cold full layout',
    );
    // ignore: avoid_print
    print(
      '  isolate:    $workerCount paragraphs cost '
      '${block.toStringAsFixed(1)}ms of UI-thread stall inline, '
      'vs ${wall.toStringAsFixed(1)}ms wall-clock OFF the UI thread',
    );
    // Use min (the clean floor) — async wall-clock medians jitter heavily.
    final inline = results.firstWhere((r) => r.name == 'reflow.inline').min;
    final full = results.firstWhere((r) => r.name == 'reflow.full').min;
    final lite = results.firstWhere((r) => r.name == 'reflow.atlas_skip').min;
    // ignore: avoid_print
    print(
      '  reflow(min): inline ${inline.toStringAsFixed(2)}ms · '
      'worker atlas-skip ${lite.toStringAsFixed(2)}ms · '
      'worker full-atlas ${full.toStringAsFixed(2)}ms — all the same order; '
      'the layout+emit compute dominates, isolate overhead is small.',
    );
    // ignore: avoid_print
    print(
      '  transfer:   all buffers already MOVE zero-copy '
      '(TransferableTypedData) — no payload copy to eliminate. The one extra '
      'copy was the atlas (Float32List.fromList); atlas-skip removes it after '
      'the first reflow. Residual isolate cost is per-message scheduling, '
      'which transferable data cannot change.',
    );

    // --- report + optional baseline compare ---
    final out =
        Platform.environment['BENCH_OUT'] ?? 'benchmark/out/isolate.json';
    File(out)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'timestamp': DateTime.now().toIso8601String(),
          'sink': sink,
          'results': [for (final r in results) r.toJson()],
        }),
      );
    // ignore: avoid_print
    print('\nwrote $out (sink=${sink.round()})');

    final baselinePath = Platform.environment['BENCH_BASELINE'];
    if (baselinePath != null) {
      final base =
          jsonDecode(File(baselinePath).readAsStringSync()) as Map<String, dynamic>;
      final baseByName = {
        for (final r in base['results'] as List)
          (r as Map<String, dynamic>)['name'] as String: r,
      };
      // ignore: avoid_print
      print('\n== vs baseline $baselinePath ==');
      for (final r in results) {
        final b = baseByName[r.name];
        if (b == null) continue;
        final baseMed = (b['medianMs'] as num).toDouble();
        final baseMad = (b['madMs'] as num).toDouble();
        final delta = (r.median - baseMed) / baseMed * 100;
        final significant = (r.median - baseMed).abs() > 2 * (r.mad + baseMad);
        // ignore: avoid_print
        print(
          '${r.name.padRight(24)}'
          '${baseMed.toStringAsFixed(3).padLeft(10)}'
          '${r.median.toStringAsFixed(3).padLeft(10)}'
          '${'${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}%'.padLeft(9)}'
          '  ${significant ? (delta < 0 ? 'faster' : 'SLOWER') : '~noise'}',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
