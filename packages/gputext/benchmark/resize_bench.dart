// Headless resize-width benchmark (real GPU path). Replicates the app bench's
// frame.reflow_width scenario — 20 left-aligned paragraphs in a column whose
// width oscillates 240↔420 px — at the render-object level, and A/Bs the
// byte-identical render-skip fast path against the old always-re-render path.
//
//   cd packages/gputext
//   flutter test --enable-impeller --enable-flutter-gpu benchmark/resize_bench.dart
//
// Reports, per arm, the offscreen renders that actually ran, the renders the
// fast path skipped, and the wall time of the pump (build+layout+paint, i.e.
// the CPU frame cost including GPU command encoding). The GPU path only runs
// when the tester has Impeller+flutter_gpu; without them renders stays 0 and
// only the CPU-side accounting is meaningful.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';

const _paras = 20;
const _warmup = 30;
const _measure = 180;

List<String> _paragraphsOf(String text, {int minLen = 60}) => text
    .split(RegExp(r'\n\s*\n'))
    .map((p) => p.replaceAll('\n', ' ').trim())
    .where((p) => p.length >= minLen)
    .toList();

void main() {
  testWidgets('reflow_width render-count A/B', (tester) async {
    final engine = GPUText.instance;
    engine.registerFont(
      'Lato',
      GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync()),
    );

    final gatsby = File(
      '../../example/assets/bench/en-gatsby-opening.txt',
    ).readAsStringSync();
    // Match the app bench's commentTexts(): sentence-split, 20–400 chars — the
    // exact corpus frame.reflow_width feeds its 20 paragraphs.
    final sentences = <String>[
      for (final p in _paragraphsOf(gatsby))
        for (final s in p.split(RegExp(r'(?<=[.!?]) ')))
          if (s.trim().length > 20 && s.trim().length < 400) s.trim(),
    ];
    expect(sentences.length, greaterThanOrEqualTo(_paras));

    const style = TextStyle(
      inherit: false,
      fontFamily: 'Lato',
      fontSize: 14,
      color: Color(0xFF000000),
    );

    Widget build(double width, {required bool gpu}) => MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _paras; i++)
                  if (gpu)
                    GPURichText(
                      text: TextSpan(
                        text: sentences[i % sentences.length],
                        style: style,
                      ),
                    )
                  else
                    RichText(
                      text: TextSpan(
                        text: sentences[i % sentences.length],
                        style: style,
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );

    double widthAt(int tick) => 330 + 90 * math.sin(tick * 2 * math.pi / 120);

    Future<(int, int, double)> sweep({
      required bool gpu,
      bool disableSkip = false,
    }) async {
      RenderGPUParagraph.debugDisableRenderSkip = disableSkip;
      for (var t = 0; t < _warmup; t++) {
        await tester.pumpWidget(build(widthAt(t), gpu: gpu));
      }
      RenderGPUParagraph.debugSurfaceRenders = 0;
      RenderGPUParagraph.debugSurfaceRenderSkips = 0;
      final sw = Stopwatch()..start();
      for (var t = _warmup; t < _warmup + _measure; t++) {
        await tester.pumpWidget(build(widthAt(t), gpu: gpu));
      }
      sw.stop();
      return (
        RenderGPUParagraph.debugSurfaceRenders,
        RenderGPUParagraph.debugSurfaceRenderSkips,
        sw.elapsedMicroseconds / 1000,
      );
    }

    // Interleave the arms and take the best (min) wall of two passes each, so a
    // one-off GC/JIT hiccup in a single pass doesn't skew the comparison.
    final offA = await sweep(gpu: true, disableSkip: true);
    final onA = await sweep(gpu: true);
    final rtA = await sweep(gpu: false);
    final offB = await sweep(gpu: true, disableSkip: true);
    final onB = await sweep(gpu: true);
    final rtB = await sweep(gpu: false);
    RenderGPUParagraph.debugDisableRenderSkip = false;

    double best(double a, double b) => math.min(a, b);
    final off = (offA.$1, offA.$2, best(offA.$3, offB.$3));
    final on = (onA.$1, onA.$2, best(onA.$3, onB.$3));
    final rtWall = best(rtA.$3, rtB.$3);

    String line(String tag, (int, int, double) r) =>
        '$tag renders=${r.$1.toString().padLeft(5)}  '
        'skips=${r.$2.toString().padLeft(5)}  '
        'pumpWall=${r.$3.toStringAsFixed(1).padLeft(8)} ms';
    final cut = off.$1 == 0 ? 0.0 : 100 * (off.$1 - on.$1) / off.$1;
    final faster = off.$3 == 0 ? 0.0 : 100 * (off.$3 - on.$3) / off.$3;
    final vsRt = rtWall == 0 ? 0.0 : 100 * (rtWall - on.$3) / rtWall;

    // ignore: avoid_print
    print(
      '\n== reflow_width · $_paras paragraphs · $_measure frames (best of 2) ==\n'
      '${line("gputext OFF :", off)}\n'
      '${line("gputext ON  :", on)}\n'
      'RichText     : pumpWall=${rtWall.toStringAsFixed(1).padLeft(8)} ms\n'
      'offscreen renders eliminated by fast path: ${cut.toStringAsFixed(1)}%\n'
      'gputext frame-cost improvement (ON vs OFF): ${faster.toStringAsFixed(1)}%\n'
      'gputext ON vs RichText pump wall-clock: '
      '${vsRt >= 0 ? "-" : "+"}${vsRt.abs().toStringAsFixed(1)}% '
      '(${vsRt >= 0 ? "gputext faster" : "RichText faster"})',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
