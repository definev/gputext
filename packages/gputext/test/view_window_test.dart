// GPUTextView is a pure (non-scrolling) widget that sizes to its content.
// Inside an ancestor scrollable it rasterizes only the visible slice (plus
// overscan), synced from the ancestor ScrollPosition — GPU memory stays
// constant no matter how long the document is. Needs
// `flutter test --enable-impeller --enable-flutter-gpu` (like
// sliver_gpu_text_test.dart); without the flags the surface probe fails and
// the first reflow never lands.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
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

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  String? reason,
}) async {
  for (var i = 0; i < 600 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: reason ?? 'condition not reached');
}

void main() {
  testWidgets('sizes to content and windows the raster to the visible slice', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    // ~700 rows at 16px/1.3 ≈ 14.5k logical px — far beyond one texture.
    final metrics = <GPUTextMetrics>[];
    final text = List.generate(
      700,
      (i) => 'Row $i of a document far taller than one GPU texture.',
    ).join('\n');
    final doc = GPUTextDocument.rich(
      'tall-windowed',
      TextSpan(text: text, style: const TextStyle(fontSize: 16)),
      fontIdResolver: (_) => 'lato',
    );

    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          controller: scroll,
          child: GPUTextView(
            controller: controller,
            document: doc,
            onMetrics: metrics.add,
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics.isNotEmpty, reason: 'first reflow');
    await tester.pump();

    // The widget hugs the laid-out content height.
    final docH = metrics.last.size.height;
    expect(docH, greaterThan(8192.0));
    expect(
      tester.getSize(find.byType(GPUTextView)).height,
      moreOrLessEquals(docH, epsilon: 0.5),
    );

    // ONE sliding GPU window (private type — match by name), rasterized at
    // the visible slice + overscan, never the whole document.
    dynamic window() => tester.allRenderObjects.singleWhere(
      (r) => r.runtimeType.toString() == '_RenderGpuWindowImage',
    );
    expect(window().debugHasImage as bool, isTrue);
    final firstWindowH = (window().debugWindowLogicalSize as Size).height;
    expect(
      firstWindowH,
      lessThan(2000.0),
      reason: 'window must be viewport + overscan, not the document',
    );

    // Hysteresis: scrolling inside the overscan band leaves the window
    // stationary in document space — no GPU re-raster at all.
    final inBand = window().debugRasterCount as int;
    for (var i = 0; i < 10; i++) {
      scroll.jumpTo(scroll.offset + 10);
      await tester.pump();
    }
    expect(
      window().debugRasterCount as int,
      inBand,
      reason: 'in-band scrolling must not re-raster',
    );

    // Leaving the band recenters the window: exactly one re-raster.
    final beforeExit = window().debugRasterCount as int;
    scroll.jumpTo(scroll.offset + 3000);
    await tester.pump();
    expect(
      window().debugRasterCount as int,
      beforeExit + 1,
      reason: 'a band exit is one recenter, one raster',
    );

    // The far end is reachable through the outer scrollable: the slice syncs
    // from the ancestor ScrollPosition and re-rasters at the new offset.
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(scroll.offset, greaterThan(docH - 601));
    expect(window().debugHasImage as bool, isTrue);
    expect(
      (window().debugWindowLogicalSize as Size).height,
      lessThan(2000.0),
      reason: 'window stays slice-sized after a deep jump',
    );

    // Fling-like travel: 60 ticks × 40px = 2400px. The band recenters every
    // ~half-overscan of travel, so the raster count stays an order of
    // magnitude below the tick count (the pre-hysteresis behavior was one
    // raster per tick).
    final beforeFling = window().debugRasterCount as int;
    for (var i = 0; i < 60; i++) {
      scroll.jumpTo(scroll.offset - 40);
      await tester.pump();
    }
    final flingRasters = (window().debugRasterCount as int) - beforeFling;
    expect(
      flingRasters,
      greaterThanOrEqualTo(1),
      reason: '2400px of travel must leave the original band',
    );
    expect(
      flingRasters,
      lessThanOrEqualTo(12),
      reason: 'rasters scale with band exits, not scroll ticks',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('content shrink under an out-of-range scroll offset does not '
      'build during layout', (tester) async {
    // Regression: isScrollingNotifier flips INSIDE the ancestor viewport's
    // performLayout when a content-extent change begins a ballistic
    // activity (applyContentDimensions → applyNewDimensions → goBallistic).
    // The view's scrolling listener used to publish a new paint slice
    // synchronously, and the slice ValueListenableBuilder's setState then
    // threw "Build scheduled during frame" and mutated the LayoutBuilder
    // under the still-laying-out viewport (chat demo: pressing reset/stop
    // while scrolled to the bottom of a streamed turn).
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    final metrics = <GPUTextMetrics>[];
    // Distinct ids: same-id non-streaming docs are contract-equivalent and
    // skip the worker round trip entirely.
    GPUTextDocument makeDoc(String id, String prefix) => GPUTextDocument.rich(
      id,
      TextSpan(
        text: List.generate(
          200,
          (i) => '$prefix $i of a tall streamed reply.',
        ).join('\n'),
        style: const TextStyle(fontSize: 16),
      ),
      fontIdResolver: (_) => 'lato',
    );
    var doc = makeDoc('shrink-under-scroll', 'Row');

    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var siblingH = 3000.0;
    late StateSetter setSibling;
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          controller: scroll,
          // Spring-back physics (macOS/iOS): an out-of-range idle position
          // makes goBallistic(0) begin a real activity. Clamping physics
          // would silently clamp instead and never flip the notifier.
          physics: const BouncingScrollPhysics(),
          child: StatefulBuilder(
            builder: (context, setState) {
              setSibling = setState;
              return Column(
                children: [
                  SizedBox(height: siblingH),
                  GPUTextView(
                    controller: controller,
                    document: doc,
                    onMetrics: metrics.add,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics.isNotEmpty, reason: 'first reflow');
    await tester.pump();

    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    expect(scroll.offset, greaterThan(2000.0));

    // Record the scheduler phase at every scrolling-state flip so the
    // dangerous precondition — a flip during persistentCallbacks — is
    // asserted, not assumed.
    final flipPhases = <SchedulerPhase>[];
    scroll.position.isScrollingNotifier.addListener(() {
      flipPhases.add(SchedulerBinding.instance.schedulerPhase);
    });

    // 1. Send a reflow (new doc id → full worker round trip). The reply
    //    cannot land yet: isolate messages only flow inside runAsync.
    setSibling(() => doc = makeDoc('shrink-under-scroll-2', 'Edited'));
    await tester.pump(Duration.zero);

    // 2. Overscroll past the end: the spring-back ballistic begins
    //    (isScrolling true). No pump — the viewport stays dirty from the
    //    offset change and the forcePixels correction flag stays armed.
    scroll.jumpTo(scroll.position.maxScrollExtent + 400);
    expect(scroll.position.isScrollingNotifier.value, isTrue);

    // 3. Let the worker reply land in real async time, still frame-frozen:
    //    the ancestor is "scrolling", so the metrics PARK for the idle
    //    transition (delivering setState mid-fling would kill the fling).
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(metrics, hasLength(1), reason: 'reflow #2 must park mid-fling');
    expect(scroll.position.isScrollingNotifier.value, isTrue,
        reason: 'the spring must still be live when the reply lands');

    // 4. One frame: the viewport's performLayout consumes the correction
    //    flag, RangeMaintaining clamps the frozen spring's pixels back in
    //    range, and Ballistic.applyNewDimensions → goBallistic(0) → goIdle
    //    flips isScrollingNotifier INSIDE layout — which delivers the
    //    parked metrics (setState) and republishes the paint slice.
    await tester.pump(Duration.zero);
    expect(
      flipPhases,
      contains(SchedulerPhase.persistentCallbacks),
      reason: 'precondition: the scrolling flip must happen mid-layout '
          '(otherwise this test exercises nothing)',
    );
    expect(tester.takeException(), isNull);

    // The deferred delivery must land cleanly after the frame.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(metrics, hasLength(2), reason: 'parked metrics must deliver');
    expect(scroll.offset, lessThanOrEqualTo(scroll.position.maxScrollExtent));
  });

  testWidgets('re-weaves text when a sizeless GPUWidgetSpan child resizes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    // The sizeless span's child grows on demand; the trailing sized span sits
    // right after it on the same line, so its left edge tracks the grown width.
    final widthN = ValueNotifier<double>(40);
    addTearDown(widthN.dispose);
    const autoKey = Key('auto-span');
    const trailerKey = Key('trailer-span');
    final metrics = <GPUTextMetrics>[];

    final doc = GPUTextDocument.rich(
      'view-resize-span',
      TextSpan(
        style: const TextStyle(fontSize: 16),
        children: [
          const TextSpan(text: 'A '),
          GPUWidgetSpan(
            child: ValueListenableBuilder<double>(
              valueListenable: widthN,
              builder: (_, wv, _) => SizedBox(
                key: autoKey,
                width: wv,
                height: 24,
                child: const ColoredBox(color: Color(0xFFDDCC77)),
              ),
            ),
          ),
          GPUWidgetSpan(
            size: const Size(30, 24),
            child: const SizedBox(
              key: trailerKey,
              child: ColoredBox(color: Color(0xFF88CCEE)),
            ),
          ),
          const TextSpan(text: ' end.'),
        ],
      ),
      fontIdResolver: (_) => 'lato',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: GPUTextView(
            controller: controller,
            document: doc,
            onMetrics: metrics.add,
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics.isNotEmpty, reason: 'first reflow');
    await tester.pump();

    // The child measured at its natural 40px width; the trailer sits after it.
    expect(
      tester.getSize(find.byKey(autoKey)).width,
      moreOrLessEquals(40, epsilon: 0.01),
    );
    final trailerLeft0 = tester.getTopLeft(find.byKey(trailerKey)).dx;
    expect(trailerLeft0, greaterThan(40));

    // Grow the hosted widget: the re-measure must re-kick the reflow so the
    // trailer shifts right by the width delta — robust auto-size, not frozen
    // at the first measured size.
    widthN.value = 100;
    await _pumpUntil(
      tester,
      () =>
          (tester.getSize(find.byKey(autoKey)).width - 100).abs() < 0.01 &&
          (tester.getTopLeft(find.byKey(trailerKey)).dx - (trailerLeft0 + 60))
                  .abs() <
              1.0,
      reason: 'trailer must shift by the grown width',
    );

    expect(
      tester.getTopLeft(find.byKey(trailerKey)).dx,
      moreOrLessEquals(trailerLeft0 + 60, epsilon: 1.0),
    );
    expect(tester.takeException(), isNull);
  });
}
