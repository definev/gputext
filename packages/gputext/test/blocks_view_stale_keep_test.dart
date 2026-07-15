// GPUTextBlocksView width-resize stale-keep: a resize drops every per-width
// drawable, and until the worker re-syncs the window there is nothing fresh to
// composite — the previously rendered window must stay on screen (stretched),
// never a blank frame. Box-view twin of the SliverGPUTextBlocks stale-strip
// test. Needs `flutter test --enable-impeller --enable-flutter-gpu` (like
// sliver_gpu_text_test.dart); without the flags the surface probe fails.
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

void main() {
  testWidgets('GPUTextBlocksView keeps the old window through a width '
      'resize instead of blanking', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    var laidOut = 0;
    final blocks = [
      for (var i = 0; i < 60; i++)
        GPUTextDocument.rich(
          'blk-$i',
          TextSpan(
            text: 'Block $i — the quick brown fox jumps over the lazy dog.',
            style: const TextStyle(fontSize: 16),
          ),
          fontIdResolver: (_) => 'lato',
        ),
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

    // The composited window lives in a private leaf render object; reach it
    // by runtime type and read its public-named test hook dynamically.
    RenderObject windowImage() => tester.renderObject(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_GpuWindowImage',
      ),
    );
    bool hasImage() => (windowImage() as dynamic).debugHasImage as bool;
    Size windowLogical() =>
        (windowImage() as dynamic).debugWindowLogicalSize as Size;
    final state =
        tester.state(find.byType(GPUTextBlocksView)) as dynamic; // private type
    bool keepStale() => state.debugKeepStaleWindow as bool;

    // Settle: blocks live and a window rendered at 800.
    await _pumpUntil(tester, () => laidOut > 0 && hasImage());
    expect(keepStale(), isFalse);
    final preResize = windowLogical();
    expect(preResize.width, greaterThan(0));

    // Shrink the window. The width invalidation drops every live block; the
    // next frame has nothing fresh to composite (the worker round trip is
    // still in flight), so the pre-resize window must be KEPT on screen.
    laidOut = 0;
    tester.view.physicalSize = const Size(640, 600);
    await tester.pump(); // relayout at the new width — no isolate replies yet
    expect(keepStale(), isTrue, reason: 'resize must arm stale-keep');
    expect(
      hasImage(),
      isTrue,
      reason: 'the old-width window must be kept, not blanked',
    );
    // The kept window still reports its render-time size: paint draws it at
    // that natural scale (clipped), NOT stretched into the new box — a
    // stretch would skew the glyphs.
    expect(
      windowLogical(),
      preResize,
      reason: 'stale window must keep its render-time scale (no skew)',
    );

    // Once blocks re-lay out at 640, a fresh composite replaces it (the
    // keep flag drops on the first fresh render) at the new size.
    await _pumpUntil(tester, () => laidOut > 0 && !keepStale());
    expect(hasImage(), isTrue);
    await _pumpUntil(tester, () => windowLogical() != preResize);
    expect(tester.takeException(), isNull);
  });
}
