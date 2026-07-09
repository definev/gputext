// Tier A — CPU layout microbenchmarks (Stopwatch, UI thread).
//
// GPUText measures its library APIs directly (flattenSpan → prepareParagraph
// → layoutPreparedLines); the RichText side measures TextPainter, the exact
// engine under RichText. Methodology mirrors pretext/pages/benchmark.ts:
// WARMUP=2 + RUNS measured runs, median-of-runs reported, widths cycled per
// repeat to defeat single-width caching, and numeric sinks accumulated from
// every result so nothing is dead-code-eliminated.
//
// Cold-prepare asymmetry, stated once: gputext's segment-metrics cache is
// cleared per run (debugClearSegmentMetricsFor — pretext clearCache parity),
// but the engine's internal shaping caches under TextPainter cannot be
// cleared, so "cold" slightly favors richtext.

import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import 'package:gputext/gputext.dart';
import 'package:gputext/gputext.dart' as wf;
import 'package:gputext/internal.dart' as wf;

import 'corpus.dart';
import 'report.dart';
import 'stats.dart' show median;

const _widths = [200.0, 250.0, 300.0, 350.0, 400.0];
const _fontSize = 16.0;

/// pretext-shaped bench(): warmup + measured runs; each run executes
/// [sampleRepeats] inner repeats and reports normalized ms per repeat.
/// Yields a frame between runs so the progress UI stays alive.
Future<List<double>> bench(
  void Function(int repeatIndex) fn, {
  int sampleRepeats = 1,
  int warmup = 2,
  int runs = 10,
}) async {
  for (var i = 0; i < warmup; i++) {
    for (var r = 0; r < sampleRepeats; r++) {
      fn(r);
    }
    await SchedulerBinding.instance.endOfFrame;
  }
  final times = <double>[];
  final sw = Stopwatch();
  for (var i = 0; i < runs; i++) {
    sw
      ..reset()
      ..start();
    for (var r = 0; r < sampleRepeats; r++) {
      fn(r);
    }
    sw.stop();
    times.add(sw.elapsedMicroseconds / 1000 / sampleRepeats);
    await SchedulerBinding.instance.endOfFrame;
  }
  return times;
}

class CpuTier {
  CpuTier({
    required this.corpus,
    required this.engine,
    required this.quick,
    this.cjkFont,
    this.cjkFamily = 'BenchCJK',
  });

  final BenchCorpus corpus;
  final GPUTextEngine engine;
  final bool quick;

  /// GPUText-registered CJK font (Arial Unicode); null → zh rows skipped.
  final GPUFont? cjkFont;
  final String cjkFamily;

  int get _count => quick ? 100 : 500;
  int get _runs => quick ? 4 : 10;
  int get _layoutRepeats => quick ? 40 : 200;

  double sink = 0; // consumed by the caller so results stay live

  TextSpan _span(String text, {String family = 'Lato'}) => TextSpan(
    text: text,
    style: TextStyle(
      fontFamily: family,
      fontSize: _fontSize,
      color: const Color(0xFF000000),
    ),
  );

  List<wf.InlineItem> _flatten(String text, {String family = 'Lato'}) {
    final items = flattenSpan(
      _span(text, family: family),
      TextScaler.noScaling,
      engine,
    );
    if (items == null) {
      throw StateError('cpu bench ran before fonts were registered');
    }
    return items;
  }

  Future<void> run(BenchReport report, void Function(String) progress) async {
    final lato = engine.resolveFont('Lato');
    if (lato == null) {
      report.errors.add('cpu tier: Lato not registered');
      return;
    }
    final texts = corpus.commentTexts(_count);

    // --- cpu.prepare_cold ---
    progress('cpu.prepare_cold_$_count');
    final coldWf = await bench((_) {
      debugClearSegmentMetricsFor(lato);
      for (final t in texts) {
        sink += wf.prepareParagraph(_flatten(t)).maxIntrinsicWidth;
      }
    }, runs: _runs);
    report.cpuResults.add(
      cpuResult(
        id: 'cpu.prepare_cold_$_count',
        engine: 'gputext',
        label: 'flatten + prepareParagraph, cold',
        desc:
            'One cold $_count-text batch; segment-metrics cache cleared per '
            'run (engine shaping caches under TextPainter cannot be cleared)',
        path: 'pure',
        runMs: coldWf,
      ),
    );
    final coldRt = await bench((_) {
      for (final t in texts) {
        final p = TextPainter(text: _span(t), textDirection: TextDirection.ltr)
          ..layout(maxWidth: 400);
        sink += p.height;
        p.dispose();
      }
    }, runs: _runs);
    report.cpuResults.add(
      cpuResult(
        id: 'cpu.prepare_cold_$_count',
        engine: 'richtext',
        label: 'fresh TextPainter().layout(400)',
        desc: 'One $_count-text batch, new painter per text',
        path: 'pure',
        runMs: coldRt,
      ),
    );

    // --- cpu.layout_warm ---
    progress('cpu.layout_warm_$_count');
    final prepared = [for (final t in texts) wf.prepareParagraph(_flatten(t))];
    final warmWf = await bench(
      (r) {
        final width = _widths[r % _widths.length];
        final style = wf.ParagraphStyle(maxWidth: width);
        for (final p in prepared) {
          sink += wf.layoutPreparedLines(p, width, style).height;
        }
      },
      sampleRepeats: _layoutRepeats,
      runs: _runs,
    );
    report.cpuResults.add(
      cpuResult(
        id: 'cpu.layout_warm_$_count',
        engine: 'gputext',
        label: 'layoutPreparedLines over prepared batch',
        desc:
            'Hot per-width relayout, widths cycled '
            '${_widths.map((w) => w.round()).join('/')}px, '
            '$_layoutRepeats repeats normalized',
        path: 'pure',
        runMs: warmWf,
      ),
    );
    final painters = [
      for (final t in texts)
        TextPainter(text: _span(t), textDirection: TextDirection.ltr)
          ..layout(maxWidth: _widths.last),
    ];
    final warmRt = await bench(
      (r) {
        final width = _widths[r % _widths.length];
        for (final p in painters) {
          p.layout(maxWidth: width);
          sink += p.height;
        }
      },
      sampleRepeats: _widths.length,
      runs: _runs,
    );
    for (final p in painters) {
      p.dispose();
    }
    report.cpuResults.add(
      cpuResult(
        id: 'cpu.layout_warm_$_count',
        engine: 'richtext',
        label: 'retained TextPainter.layout(w)',
        desc:
            'Relayout at cycled widths on retained painters — the engine has '
            'no prepare/layout split, so this re-breaks from scratch (that '
            'asymmetry is the headline number)',
        path: 'pure',
        runMs: warmRt,
      ),
    );

    // --- cpu.corpus_long ---
    final corpora = <(String, String, String, GPUFont?)>[
      ('gatsby', corpus.gatsby, 'Lato', lato),
      ('zh-zhufu', corpus.zhZhufu, cjkFamily, cjkFont),
      ('mixed-app', corpus.mixedApp, 'Lato', lato),
      (
        'synthetic-long-breakable',
        buildLongBreakableStressText(quick ? 40 : 220),
        'Lato',
        lato,
      ),
    ];
    for (final (id, text, family, font) in corpora) {
      progress('cpu.corpus_long/$id');
      if (font == null) {
        report.cpuResults.add({
          'id': 'cpu.corpus_long/$id',
          'engine': 'gputext',
          'status': 'skipped',
          'desc': 'no gputext font covers this corpus (CJK font unavailable)',
          'path': 'pure',
        });
        continue;
      }
      final corpusRuns = quick ? 3 : 7;
      final coldPrep = await bench(
        (_) {
          debugClearSegmentMetricsFor(font);
          sink += wf
              .prepareParagraph(_flatten(text, family: family))
              .maxIntrinsicWidth;
        },
        warmup: 1,
        runs: corpusRuns,
      );
      final preparedCorpus = wf.prepareParagraph(
        _flatten(text, family: family),
      );
      final hotLayout = await bench(
        (r) {
          final width = _widths[r % _widths.length];
          sink += wf
              .layoutPreparedLines(
                preparedCorpus,
                width,
                wf.ParagraphStyle(maxWidth: width),
              )
              .height;
        },
        sampleRepeats: _layoutRepeats,
        warmup: 1,
        runs: corpusRuns,
      );
      final lineCount = wf
          .layoutPreparedLines(
            preparedCorpus,
            300,
            const wf.ParagraphStyle(maxWidth: 300),
          )
          .lines
          .length;
      report.cpuResults.add(
        cpuResult(
          id: 'cpu.corpus_long/$id',
          engine: 'gputext',
          label: 'full-corpus cold prepare',
          desc: 'chars=${text.length}; hot layout reported separately',
          path: 'pure',
          runMs: coldPrep,
          extra: {'chars': text.length, 'linesAt300': lineCount},
        ),
      );
      report.cpuResults.add(
        cpuResult(
          id: 'cpu.corpus_long/$id.hot',
          engine: 'gputext',
          label: 'full-corpus hot layout',
          desc: 'layoutPreparedLines cycling widths, $_layoutRepeats repeats',
          path: 'pure',
          runMs: hotLayout,
        ),
      );
      final rtPainter = TextPainter(
        text: _span(text, family: family),
        textDirection: TextDirection.ltr,
      );
      final rtCold = await bench(
        (_) {
          // Force a real relayout: alternate an off-cycle width so the painter
          // can't short-circuit on identical constraints.
          rtPainter.layout(maxWidth: 401);
          rtPainter.layout(maxWidth: 400);
          sink += rtPainter.height;
        },
        warmup: 1,
        runs: corpusRuns,
      );
      final rtHot = await bench(
        (r) {
          final width = _widths[r % _widths.length];
          rtPainter.layout(maxWidth: width);
          sink += rtPainter.height;
        },
        sampleRepeats: _widths.length,
        warmup: 1,
        runs: corpusRuns,
      );
      rtPainter.layout(maxWidth: 300);
      final rtLines = rtPainter.computeLineMetrics().length;
      rtPainter.dispose();
      report.cpuResults.add(
        cpuResult(
          id: 'cpu.corpus_long/$id',
          engine: 'richtext',
          label: 'full-corpus TextPainter relayout ×2',
          desc:
              'chars=${text.length}; two layouts per run (no clearable cold '
              'path in the engine)',
          path: 'pure',
          runMs: rtCold,
          extra: {'chars': text.length, 'linesAt300': rtLines},
        ),
      );
      report.cpuResults.add(
        cpuResult(
          id: 'cpu.corpus_long/$id.hot',
          engine: 'richtext',
          label: 'full-corpus TextPainter.layout(w)',
          desc: 'relayout cycling widths (full engine re-break each time)',
          path: 'pure',
          runMs: rtHot,
        ),
      );
    }

    // --- cpu.knuth_plass ---
    progress('cpu.knuth_plass');
    final kpParas = [
      for (final p in corpus.gatsbyParagraphs.take(quick ? 5 : 20))
        wf.prepareParagraph(_flatten(p)),
    ];
    final greedy = await bench(
      (_) {
        for (final p in kpParas) {
          sink += wf
              .layoutPreparedLines(
                p,
                300,
                const wf.ParagraphStyle(
                  maxWidth: 300,
                  align: wf.TextAlign.justify,
                ),
              )
              .height;
        }
      },
      sampleRepeats: 5,
      runs: _runs,
    );
    final kp = await bench(
      (_) {
        for (final p in kpParas) {
          sink += wf
              .layoutPreparedLines(
                p,
                300,
                wf.ParagraphStyle(
                  maxWidth: 300,
                  align: wf.TextAlign.justify,
                  lineBreaker: const wf.KnuthPlassLineBreaker(),
                ),
              )
              .height;
        }
      },
      sampleRepeats: 5,
      runs: _runs,
    );
    report.cpuResults.add(
      cpuResult(
        id: 'cpu.knuth_plass',
        engine: 'gputext',
        label: 'greedy justify, ${kpParas.length} paragraphs',
        desc: 'baseline for the Knuth–Plass row',
        path: 'pure',
        runMs: greedy,
      ),
    );
    report.cpuResults.add(
      cpuResult(
        id: 'cpu.knuth_plass',
        engine: 'gputext-kp',
        label: 'Knuth–Plass justify, ${kpParas.length} paragraphs',
        desc: 'TeX-style optimal fit; Flutter has no counterpart',
        path: 'no-counterpart',
        runMs: kp,
      ),
    );

    // --- cpu.oneshot_vs_split (the _PerfCard number, kept for continuity) ---
    progress('cpu.oneshot_vs_split');
    final perfText = List.filled(
      32,
      'The quick brown zebra jumps over the lazy dog while 12 kg of '
      'well-known state-of-the-art cargo ships to https://windfoil.dev/q?x=1 '
      'and back again without delay. ',
    ).join();
    final perfRuns = _flatten(perfText);
    final perfPrepared = wf.prepareParagraph(perfRuns);
    final split = await bench(
      (r) {
        final width = _widths[r % _widths.length];
        sink += wf
            .layoutPreparedLines(
              perfPrepared,
              width,
              wf.ParagraphStyle(maxWidth: width),
            )
            .height;
      },
      sampleRepeats: 40,
      runs: _runs,
    );
    final oneshot = await bench(
      (r) {
        final width = _widths[r % _widths.length];
        sink += wf
            .breakLines(perfRuns, width, wf.ParagraphStyle(maxWidth: width))
            .height;
      },
      sampleRepeats: 5,
      runs: _runs,
    );
    report.cpuResults.add(
      cpuResult(
        id: 'cpu.oneshot_vs_split',
        engine: 'gputext',
        label: 'prepared relayout vs one-shot re-prepare',
        desc:
            '1000-word paragraph; speedup = oneshot/split medians '
            '(_PerfCard continuity check)',
        path: 'pure',
        runMs: split,
        extra: {
          'oneshotMedianMs': median(oneshot),
          'speedup': median(split) > 0 ? median(oneshot) / median(split) : 0,
        },
      ),
    );

    report.meta['cpuSink'] = sink.round();
  }
}
