// Headless CPU benchmark for the text pipeline's pure-Dart hot paths.
//
// Unlike the app bench (example/lib/bench, which needs a window and a user
// terminal), this runs under the flutter tester with no UI, so it works from
// CI and agent shells:
//
//   cd packages/gputext
//   flutter test benchmark/cpu_bench.dart
//
// Scenarios map 1:1 onto pipeline stages so a change can be attributed:
//   analyze.*   — analyzeText segment analysis (predicates + merge passes)
//   bidi.*      — bidi.itemize (UAX #9 level resolution)
//   prepare.*   — TextRun construction + prepareParagraph, cold metrics
//   layout.*    — layoutPreparedLines at cycled widths (materialize+reorder)
//   emit.*      — emitInstances re-emit (glyph instance floats), with and
//                 without a glyph table
//
// Methodology: warmup, then inner repeats auto-calibrated until one sample
// takes >= targetSampleMs (Stopwatch noise stays < ~1%), then N samples.
// Median + MAD + min reported; numeric sinks keep results live.
//
// A/B protocol (bench file is untracked, so it survives the stash):
//   BENCH_OUT=benchmark/out/improved.json flutter test benchmark/cpu_bench.dart
//   git stash push -- lib/src/paragraph.dart lib/src/text/analysis.dart \
//       lib/src/text/bidi.dart
//   BENCH_OUT=benchmark/out/baseline.json flutter test benchmark/cpu_bench.dart
//   git stash pop
//   BENCH_BASELINE=benchmark/out/baseline.json flutter test benchmark/cpu_bench.dart
//
// A row is flagged significant only when |Δmedian| > 2·(MAD_a + MAD_b).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/engine/shared_atlas.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/paragraph.dart' as wf;
import 'package:gputext/src/text/analysis.dart' as an;
import 'package:gputext/src/text/bidi.dart' as bidi;
import 'package:gputext/src/text/metrics_cache.dart';

const _targetSampleMs = 30.0;
const _samples = 12;
const _warmupSamples = 3;
const _widths = [200.0, 260.0, 320.0, 380.0, 440.0];

double sink = 0;

class BenchResult {
  BenchResult(this.name, this.samplesMs, this.repeats);

  final String name;
  final List<double> samplesMs; // ms per single op invocation
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

BenchResult run(String name, void Function() op) {
  // Warmup: JIT + lazy caches reach steady state before calibration.
  for (var i = 0; i < _warmupSamples; i++) {
    op();
  }
  // Calibrate inner repeats so a sample dwarfs timer noise.
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
  // ignore: avoid_print
  print(
    '  ${name.padRight(28)} '
    '${result.median.toStringAsFixed(3).padLeft(9)} ms  '
    '±${result.mad.toStringAsFixed(3)}  '
    '(min ${result.min.toStringAsFixed(3)}, ×$repeats)',
  );
  return result;
}

// --- corpora ---

List<String> _paragraphsOf(String text, {int minLen = 60}) => text
    .split(RegExp(r'\n\s*\n'))
    .map((p) => p.replaceAll('\n', ' ').trim())
    .where((p) => p.length >= minLen)
    .toList();

/// Port of the app bench's buildLongBreakableStressText, one line per unit:
/// URLs with queries, camel-case cache keys, numeric time windows, ::paths.
List<String> _stressLines(int count) => [
  for (var i = 0; i < count; i++)
    'https://bench.example.com/releases/2026/04/$i/artifact-alpha-beta-'
        'gamma-${i.toRadixString(36)}?build=${1200 + i}&cursor='
        'sha${(0xabcde + i).toRadixString(16)}&channel=stable '
        'cacheKey_v${i}_AlphaBetaGammaDeltaEpsilonZetaEtaThetaIota '
        'metrics pipeline phase ${i % 17} snapshot ${(i * 13) % 97} '
        'window:${(i % 24).toString().padLeft(2, '0')}:'
        '${((i * 7) % 60).toString().padLeft(2, '0')}-'
        '${((i + 5) % 24).toString().padLeft(2, '0')}:'
        '${((i * 11) % 60).toString().padLeft(2, '0')} '
        'module::worker::queue::flush::retry::$i',
];

List<String> _rtlMixedLines(int count) {
  const ar = 'السلام عليكم ورحمة الله وبركاته يا صديقي العزيز';
  const he = 'שלום עולם ברוך הבא לספרייה שלנו';
  return [
    for (var i = 0; i < count; i++)
      'Order #$i placed — $ar — total ${99 + i}.50 USD, note: $he (done).',
  ];
}

void main() {
  test('cpu bench', () async {
    final font = GPUFont.parse(
      File('assets/Lato-Regular.ttf').readAsBytesSync(),
    );
    const bench = '../../example/assets/bench';
    final gatsby = File('$bench/en-gatsby-opening.txt').readAsStringSync();
    final zh = File('$bench/zh-zhufu.txt').readAsStringSync();
    final mixedApp = File('$bench/mixed-app-text.txt').readAsStringSync();

    final gatsbyParas = _paragraphsOf(gatsby).take(50).toList();
    final mixedLines = mixedApp
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .take(120)
        .toList();
    final zhChunks = <String>[
      for (var i = 0; i + 400 <= zh.length && i < 60 * 400; i += 400)
        zh.substring(i, i + 400),
    ];
    final stress = _stressLines(120);
    final rtl = _rtlMixedLines(120);

    wf.TextRun mkRun(String text) => wf.TextRun(
      text: text,
      font: font,
      fontSizePx: 16,
      color: const [0, 0, 0, 1],
    );

    final results = <BenchResult>[];
    // ignore: avoid_print
    print(
      'cpu_bench: ${gatsbyParas.length} paras, ${zhChunks.length} zh '
      'chunks, ${stress.length} stress lines, ${mixedLines.length} mixed',
    );

    // --- analyze: segment analysis (M2 predicates, M3 pass gating) ---
    results.add(
      run('analyze.plain_ascii', () {
        for (final t in gatsbyParas) {
          sink += an.analyzeText(t).length;
        }
      }),
    );
    results.add(
      run('analyze.stress_punct', () {
        for (final t in stress) {
          sink += an.analyzeText(t).length;
        }
      }),
    );
    results.add(
      run('analyze.mixed_app', () {
        for (final t in mixedLines) {
          sink += an.analyzeText(t).length;
        }
      }),
    );
    results.add(
      run('analyze.cjk', () {
        for (final t in zhChunks) {
          sink += an.analyzeText(t).length;
        }
      }),
    );
    results.add(
      run('analyze.rtl_mixed', () {
        for (final t in rtl) {
          sink += an.analyzeText(t).length;
        }
      }),
    );

    // --- bidi: itemize (M4 LTR fast path; RTL guards regression) ---
    results.add(
      run('bidi.itemize_ltr', () {
        for (final t in gatsbyParas) {
          sink += bidi.itemize(t).length;
        }
      }),
    );
    results.add(
      run('bidi.itemize_rtl', () {
        for (final t in rtl) {
          sink += bidi.itemize(t).length;
        }
      }),
    );

    // --- prepare: cold flatten-free pipeline (analysis in context) ---
    results.add(
      run('prepare.cold_plain', () {
        debugClearSegmentMetricsFor(font);
        for (final t in gatsbyParas) {
          sink += wf.prepareParagraph([mkRun(t)]).maxIntrinsicWidth;
        }
      }),
    );
    results.add(
      run('prepare.cold_stress', () {
        debugClearSegmentMetricsFor(font);
        for (final t in stress) {
          sink += wf.prepareParagraph([mkRun(t)]).maxIntrinsicWidth;
        }
      }),
    );

    // --- layout: hot relayout, widths cycled (H2 reorder early-out) ---
    final prepared = [
      for (final t in gatsbyParas) wf.prepareParagraph([mkRun(t)]),
    ];
    var wi = 0;
    results.add(
      run('layout.hot_relayout', () {
        final w = _widths[wi++ % _widths.length];
        final style = wf.ParagraphStyle(maxWidth: w);
        for (final p in prepared) {
          sink += wf.layoutPreparedLines(p, w, style).height;
        }
      }),
    );

    // --- emit: instance emission (H1) ---
    const emitWidth = 400.0;
    final emitStyle = wf.ParagraphStyle(maxWidth: emitWidth);
    final paras = [
      for (final t in gatsbyParas.take(30))
        wf.breakLines([mkRun(t)], emitWidth, emitStyle),
    ];
    final atlas = SharedGlyphAtlas();
    var glyphs = 0;
    for (final para in paras) {
      for (final line in para.lines) {
        for (final item in line.items) {
          if (item is wf.LineRun) {
            atlas.ensureShaped(item.shaped);
            glyphs += item.shaped.glyphs.length;
          }
        }
      }
    }
    // ignore: avoid_print
    print('  (emit corpus: ${paras.length} paragraphs, $glyphs glyphs)');
    results.add(
      run('emit.instances', () {
        for (final para in paras) {
          sink += wf
              .emitInstances(para, emitWidth, wf.TextAlign.left, atlas)
              .glyphCount;
        }
      }),
    );
    results.add(
      run('emit.metrics_only', () {
        for (final para in paras) {
          sink += wf
              .emitInstances(para, emitWidth, wf.TextAlign.left, null)
              .instances
              .length;
        }
      }),
    );

    // --- report ---
    final out = Platform.environment['BENCH_OUT'] ?? 'benchmark/out/bench.json';
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
    print('wrote $out (sink=${sink.round()})');

    final baselinePath = Platform.environment['BENCH_BASELINE'];
    if (baselinePath != null) {
      final base = jsonDecode(
        File(baselinePath).readAsStringSync(),
      ) as Map<String, dynamic>;
      final baseByName = {
        for (final r in base['results'] as List)
          (r as Map<String, dynamic>)['name'] as String: r,
      };
      // ignore: avoid_print
      print('\n== vs baseline $baselinePath ==');
      // ignore: avoid_print
      print(
        '${'scenario'.padRight(28)}${'base ms'.padLeft(10)}'
        '${'new ms'.padLeft(10)}${'Δ'.padLeft(9)}  signif',
      );
      for (final r in results) {
        final b = baseByName[r.name];
        if (b == null) continue;
        final baseMed = (b['medianMs'] as num).toDouble();
        final baseMad = (b['madMs'] as num).toDouble();
        final delta = (r.median - baseMed) / baseMed * 100;
        final significant = (r.median - baseMed).abs() > 2 * (r.mad + baseMad);
        // ignore: avoid_print
        print(
          '${r.name.padRight(28)}'
          '${baseMed.toStringAsFixed(3).padLeft(10)}'
          '${r.median.toStringAsFixed(3).padLeft(10)}'
          '${'${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}%'.padLeft(9)}'
          '  ${significant ? (delta < 0 ? 'faster' : 'SLOWER') : '~noise'}',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
