// GPUTextBlocksView block-level media: a GPUWidgetBlock mounts its Flutter
// widget between GPU-text paragraphs, is measured (or fixed-height), and its
// height flows into the shared virtualizer (contributing to laidOut and to the
// block tops). Needs `flutter test --enable-impeller --enable-flutter-gpu`
// (like blocks_view_stale_keep_test.dart); without the flags the surface probe
// fails and the view shows its fallback (no blocks mount).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/lowlevel.dart' hide TextAlign, TextDirection;

Future<GPUTextViewController> _spawnController(WidgetTester tester) async {
  final controller = (await tester.runAsync(GPUTextViewController.spawn))!;
  final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
  await tester.runAsync(
    () => controller.registerFont('lato', Uint8List.fromList(bytes)),
  );
  return controller;
}

/// Real-async wait: isolate replies resolve inside runAsync windows; pump
/// applies the setState/markNeedsPaint they schedule.
Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 600 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'condition not reached before timeout');
}

GPUTextDocument _text(int i) => GPUTextDocument.rich(
  'p$i',
  TextSpan(
    text: 'Paragraph $i — the quick brown fox jumps over the lazy dog.',
    style: const TextStyle(fontSize: 16),
  ),
  fontIdResolver: (_) => 'lato',
);

void main() {
  testWidgets('GPUWidgetBlock mounts, measures, and counts toward laidOut', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    var laidOut = -1;
    // Interleave two media blocks — one fixed-height, one measured — among GPU
    // text paragraphs. All fit in the viewport + cache window, so all lay out.
    final blocks = <GPUBlock>[
      _text(0),
      GPUWidgetBlock(
        id: 'fixed',
        height: 120,
        builder: (_) => Container(
          key: const ValueKey('fixed-child'),
          color: const Color(0xFF334155),
        ),
      ),
      _text(1),
      GPUWidgetBlock(
        id: 'measured',
        builder: (_) =>
            const SizedBox(key: ValueKey('measured-child'), height: 200),
      ),
      _text(2),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: GPUTextBlocksView(
          controller: controller,
          blocks: blocks,
          onLaidOutChanged: (n, _) => laidOut = n,
        ),
      ),
    );

    // Text blocks lay out via worker reflow; the measured widget block via
    // main-isolate measure; the fixed-height widget block immediately. Every
    // block counts toward laidOut.
    await _pumpUntil(tester, () => laidOut == blocks.length);

    // Both media widgets are mounted as real Flutter children (in the scroll
    // content, hit-testable through the transparent glyph overlay).
    expect(find.byKey(const ValueKey('fixed-child')), findsOneWidget);
    expect(find.byKey(const ValueKey('measured-child')), findsOneWidget);

    // Fixed-height block reserves exactly its height; the measured block lays
    // out to its intrinsic height (200) — proving the measure path ran.
    expect(
      tester.getSize(find.byKey(const ValueKey('fixed-child'))).height,
      moreOrLessEquals(120, epsilon: 0.5),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('measured-child'))).height,
      moreOrLessEquals(200, epsilon: 0.5),
    );

    // Height flows into the tops: the measured block (200 tall) sits above the
    // fixed block (120 tall) in content coords, and the paragraph after the
    // measured block sits below its bottom — i.e. tops account for measured
    // widget heights, not a zero/estimate placeholder.
    final measuredTop = tester
        .getTopLeft(find.byKey(const ValueKey('measured-child')))
        .dy;
    final fixedTop = tester
        .getTopLeft(find.byKey(const ValueKey('fixed-child')))
        .dy;
    expect(measuredTop, greaterThan(fixedTop));
  });
}
