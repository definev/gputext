// SliverGPUText integration: real worker isolate + real GPU rasterization.
// Needs `flutter test --enable-impeller --enable-flutter-gpu` (like
// surface_tiling_test.dart); without the flags the surface probe fails and the
// sliver stays empty.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/lowlevel.dart' hide TextAlign, TextDirection;
import 'package:gputext/src/lowlevel/gpu_text_view.dart'
    show RenderSliverGPUText, RenderSliverGPUTextBlocks;

Future<GPUTextViewController> _spawnController(WidgetTester tester) async {
  final controller = (await tester.runAsync(GPUTextViewController.spawn))!;
  final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
  await tester.runAsync(
    () => controller.registerFont('lato', Uint8List.fromList(bytes)),
  );
  return controller;
}

/// Real-async wait: isolate replies and the surface probe resolve inside
/// runAsync windows; pump applies the markNeedsLayout they schedule (and
/// flushes fake-zone await continuations — work kicked from layout advances
/// roughly one await per cycle, hence the generous iteration cap).
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
  testWidgets('reports document extent, rasterizes, and scrolls', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    final metrics = <GPUTextMetrics>[];
    final text = List.generate(
      300,
      (i) => 'Line $i of the sliver document.',
    ).join('\n');
    GPUTextDocument doc() => GPUTextDocument.rich(
      'doc-1',
      TextSpan(text: text, style: const TextStyle(fontSize: 16)),
      fontIdResolver: (_) => 'lato',
    );

    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    Widget app(GPUTextDocument document) => MaterialApp(
      home: CustomScrollView(
        controller: scroll,
        slivers: [
          SliverGPUText(
            controller: controller,
            document: document,
            onMetrics: metrics.add,
          ),
        ],
      ),
    );

    await tester.pumpWidget(app(doc()));
    await _pumpUntil(tester, () => metrics.isNotEmpty);
    await tester.pump(); // apply the post-reflow markNeedsLayout

    final sliver =
        tester.renderObject(find.byType(SliverGPUText)) as RenderSliverGPUText;
    final contentH = metrics.single.size.height;
    expect(contentH, greaterThan(600));
    expect(sliver.geometry!.scrollExtent, contentH);
    expect(sliver.geometry!.paintExtent, 600);
    expect(sliver.debugHasWindow, isTrue);

    // The rasterized strip covers the visible range (plus viewport cache).
    var (top, height) = sliver.debugWindowStrip;
    expect(top, 0);
    expect(height, greaterThanOrEqualTo(600));
    expect(height, lessThan(contentH)); // virtualized, not the whole doc

    // Scroll to the middle: extent is honest, the strip follows.
    final mid = (contentH / 2).floorToDouble();
    scroll.jumpTo(mid);
    await tester.pump();
    (top, height) = sliver.debugWindowStrip;
    expect(top, lessThanOrEqualTo(mid));
    expect(top + height, greaterThanOrEqualTo(mid + 600));
    expect(tester.takeException(), isNull);

    // An equivalent rebuilt document (same id + style) skips the reflow.
    await tester.pumpWidget(app(doc()));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(metrics, hasLength(1));
  });

  testWidgets('taps on a hitTag span dispatch recognizer and onSpanTap', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    var linkTaps = 0;
    final recognizer = TapGestureRecognizer()..onTap = () => linkTaps++;
    addTearDown(recognizer.dispose);
    final spanTaps = <String>[];
    var laidOut = false;

    final doc = GPUTextDocument.rich(
      'doc-links',
      TextSpan(
        style: const TextStyle(fontSize: 16),
        children: [
          TextSpan(text: 'Tap this link now', recognizer: recognizer),
          const TextSpan(text: '\nAnd some plain text below.'),
        ],
      ),
      fontIdResolver: (_) => 'lato',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            SliverGPUText(
              controller: controller,
              document: doc,
              onMetrics: (_) => laidOut = true,
              onSpanTap: (tag, span) => spanTaps.add(tag),
            ),
          ],
        ),
      ),
    );
    await _pumpUntil(tester, () => laidOut);
    await tester.pump();

    // Inside the first line (the link run).
    await tester.tapAt(const Offset(20, 8));
    await tester.pump();
    expect(linkTaps, 1);
    expect(spanTaps, hasLength(1));

    // Plain text far below the link claims nothing.
    await tester.tapAt(const Offset(20, 40));
    await tester.pump();
    expect(linkTaps, 1);
    expect(spanTaps, hasLength(1));
  });

  testWidgets('hosts GPUWidgetSpan children: laid out, tappable, scrolling', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    var buttonTaps = 0;
    var laidOut = false;
    const sizedKey = Key('sized-span');
    const autoKey = Key('auto-span');

    final doc = GPUTextDocument.rich(
      'doc-widgets',
      TextSpan(
        style: const TextStyle(fontSize: 16),
        children: [
          const TextSpan(text: 'Before '),
          GPUWidgetSpan(
            size: const Size(120, 28),
            child: GestureDetector(
              key: sizedKey,
              onTap: () => buttonTaps++,
              child: const ColoredBox(color: Color(0xFF88CCEE)),
            ),
          ),
          const TextSpan(text: ' between '),
          // Sizeless: measured under loose constraints during layout, then
          // the document reflows once with the real 90x30 box.
          const GPUWidgetSpan(
            child: SizedBox(
              key: autoKey,
              width: 90,
              height: 30,
              child: ColoredBox(color: Color(0xFFDDCC77)),
            ),
          ),
          TextSpan(
            text:
                ' after.\n${List.generate(200, (i) => 'Filler line $i.').join('\n')}',
          ),
        ],
      ),
      fontIdResolver: (_) => 'lato',
    );

    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          controller: scroll,
          slivers: [
            SliverGPUText(
              controller: controller,
              document: doc,
              onMetrics: (_) => laidOut = true,
            ),
          ],
        ),
      ),
    );
    await _pumpUntil(tester, () => laidOut);
    await tester.pump();

    // Both children are laid out to their placeholder boxes on the top line.
    // Boxes round-trip the worker as float32 — compare with tolerance.
    final sizedBox = tester.getRect(find.byKey(sizedKey));
    expect(sizedBox.width, moreOrLessEquals(120, epsilon: 0.01));
    expect(sizedBox.height, moreOrLessEquals(28, epsilon: 0.01));
    expect(sizedBox.top, greaterThanOrEqualTo(0));
    expect(sizedBox.top, lessThan(60));
    final autoSize = tester.getSize(find.byKey(autoKey));
    expect(autoSize.width, moreOrLessEquals(90, epsilon: 0.01));
    expect(autoSize.height, moreOrLessEquals(30, epsilon: 0.01));
    expect(
      tester.getTopLeft(find.byKey(autoKey)).dx,
      greaterThan(sizedBox.right),
    );

    // Children are real render children: taps route through the sliver's
    // paint transform into the widget.
    await tester.tap(find.byKey(sizedKey));
    await tester.pump();
    expect(buttonTaps, 1);

    // They ride the scroll with the glyphs.
    scroll.jumpTo(10);
    await tester.pump();
    expect(
      tester.getRect(find.byKey(sizedKey)).top,
      moreOrLessEquals(sizedBox.top - 10, epsilon: 0.01),
    );
  });

  testWidgets('coerces softWrap:false to wrapping (sliver is 1D)', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    GPUTextMetrics? metrics;
    final doc = GPUTextDocument.rich(
      'doc-nowrap',
      TextSpan(
        text: List.generate(120, (i) => 'word$i').join(' '),
        style: const TextStyle(fontSize: 16),
      ),
      fontIdResolver: (_) => 'lato',
      style: const GPUTextLayoutStyle(lineHeight: 1.3, softWrap: false),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            SliverGPUText(
              controller: controller,
              document: doc,
              onMetrics: (m) => metrics = m,
            ),
          ],
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics != null);

    // Without coercion this is one ~5000px line; wrapped it is many lines no
    // wider than the sliver's cross-axis extent.
    expect(metrics!.lineCount, greaterThan(1));
    expect(metrics!.size.width, lessThanOrEqualTo(800.5));
  });

  List<GPUTextDocument> makeBlocks(int n) => [
    for (var i = 0; i < n; i++)
      GPUTextDocument.rich(
        'blk-$i',
        TextSpan(
          text: 'Block $i — the quick brown fox jumps over the lazy dog.',
          style: const TextStyle(fontSize: 16),
        ),
        fontIdResolver: (_) => 'lato',
      ),
  ];

  testWidgets('SliverGPUTextBlocks: estimated extent, lazy layout, deep jump', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    var laidOut = 0;
    final blocks = makeBlocks(400);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    Widget app(List<GPUTextDocument> b) => MaterialApp(
      home: CustomScrollView(
        controller: scroll,
        slivers: [
          SliverGPUTextBlocks(
            controller: controller,
            blocks: b,
            estimateHeight: (_, _) => 18,
            onLaidOutChanged: (n, _) => laidOut = n,
          ),
        ],
      ),
    );

    await tester.pumpWidget(app(blocks));
    final sliver = tester.renderObject(
      find.byType(SliverGPUTextBlocks),
    ) as RenderSliverGPUTextBlocks;

    // Extent is available synchronously from the estimates — before the
    // worker or the GPU pipeline have even resolved.
    expect(sliver.geometry!.scrollExtent, 400 * 18.0);

    // Only the window near the viewport is laid out (~viewport + cache at
    // ~21px real heights ≈ 90 blocks; wait for a healthy chunk of it).
    await _pumpUntil(tester, () => laidOut >= 40 && sliver.debugHasWindow);
    expect(laidOut, lessThan(400), reason: 'layout must stay lazy');
    final extentAfter = sliver.geometry!.scrollExtent;
    expect(extentAfter, isNot(400 * 18.0)); // real heights mixed in

    // Jump deep: blocks there lay out on demand, extent stays honest.
    final before = laidOut;
    scroll.jumpTo(extentAfter * 0.6);
    await _pumpUntil(tester, () => laidOut > before);
    expect(laidOut, lessThan(400));
    expect(sliver.debugHasWindow, isTrue);
    expect(tester.takeException(), isNull);

    // A rebuilt but equivalent list keeps every cache (a reset would zero
    // the laid-out counter).
    final kept = sliver.debugLaidOutCount;
    await tester.pumpWidget(app(makeBlocks(400)));
    await tester.pump();
    expect(sliver.debugLaidOutCount, greaterThanOrEqualTo(kept));
  });

  testWidgets('SliverGPUTextBlocks corrects scroll offset as estimates '
      'above the viewport resolve', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    var laidOut = 0;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          controller: scroll,
          slivers: [
            SliverGPUTextBlocks(
              controller: controller,
              blocks: makeBlocks(300),
              // Deliberately far below the ~21px real height so the
              // estimate→real fixup above the viewport is large.
              estimateHeight: (_, _) => 10,
              onLaidOutChanged: (n, _) => laidOut = n,
            ),
          ],
        ),
      ),
    );

    // Land mid-list while everything above is still a 10px estimate.
    scroll.jumpTo(600);
    await tester.pump();

    // Blocks above the viewport roughly double in height as they lay out;
    // the sliver reports the deltas as SliverGeometry.scrollOffsetCorrection,
    // so the offset climbs with them instead of the content jumping.
    await _pumpUntil(tester, () => scroll.offset > 700);
    expect(laidOut, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('SliverGPUTextBlocks keeps a stale strip through a width '
      'resize instead of blanking', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    var laidOut = 0;
    final blocks = makeBlocks(120);
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            SliverGPUTextBlocks(
              controller: controller,
              blocks: blocks,
              onLaidOutChanged: (n, _) => laidOut = n,
            ),
          ],
        ),
      ),
    );
    final sliver = tester.renderObject(
      find.byType(SliverGPUTextBlocks),
    ) as RenderSliverGPUTextBlocks;
    // Settle until the strip is complete (every block it covers is live) —
    // only a complete strip is kept across the resize.
    await _pumpUntil(
      tester,
      () =>
          sliver.debugHasWindow &&
          sliver.debugWindowComplete &&
          !sliver.debugWindowIsStale &&
          laidOut > 0,
    );

    // Shrink the window. The width invalidation drops every live block; the
    // next frame has nothing fresh to composite (the worker round trip is
    // still in flight), so the previously rendered strip must be KEPT on
    // screen — stale-but-visible, never blank.
    laidOut = 0;
    tester.view.physicalSize = const Size(640, 600);
    await tester.pump(); // relayout at the new width — no isolate replies yet
    expect(sliver.debugHasWindow, isTrue);
    expect(
      sliver.debugWindowIsStale,
      isTrue,
      reason: 'the old-width strip must be kept, not blanked',
    );

    // Once the visible blocks re-lay out at 640, the fresh strip replaces it.
    await _pumpUntil(tester, () => laidOut > 0 && !sliver.debugWindowIsStale);
    expect(sliver.debugHasWindow, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('strip renders into the bucketed texture sub-rect '
      '(viewport-confined, padding untouched)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    var laidOut = false;
    final doc = GPUTextDocument.rich(
      'doc-bucket',
      TextSpan(
        text: List.generate(100, (i) => 'Bucket line $i.').join('\n'),
        style: const TextStyle(fontSize: 16),
      ),
      fontIdResolver: (_) => 'lato',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            SliverGPUText(
              controller: controller,
              document: doc,
              onMetrics: (_) => laidOut = true,
            ),
          ],
        ),
      ),
    );
    // skipOffstage: pre-reflow the sliver has zero geometry, which the
    // viewport reports as offstage — the default finder would miss it.
    final sliver = tester.renderObject(
      find.byType(SliverGPUText, skipOffstage: false),
    ) as RenderSliverGPUText;
    await _pumpUntil(tester, () => laidOut && sliver.debugHasWindow);

    final img = sliver.debugWindowImage!;
    final src = sliver.debugWindowSrc;
    // The backing texture is allocated in 256-px buckets, so it is larger
    // than the strip; the strip lives in the top-left src sub-rect.
    expect(img.width % 256, 0);
    expect(img.height % 256, 0);
    expect(src.width, 800); // doc width at dpr 1
    expect(img.width, greaterThan(src.width.toInt()));
    expect(src.height, lessThanOrEqualTo(img.height.toDouble()));

    final data = (await tester.runAsync(() => img.toByteData()))!;
    bool inkAt(int x, int y) => data.getUint8((y * img.width + x) * 4 + 3) != 0;
    // Glyph coverage must land at the TOP-LEFT of the content sub-rect (the
    // first text line starts at doc-space y≈0 and the strip starts at 0) —
    // a mis-oriented or mis-scaled viewport would leave this region empty.
    var contentInk = false;
    for (var y = 0; y < 64 && !contentInk; y++) {
      for (var x = 0; x < src.width.toInt() && !contentInk; x += 2) {
        if (inkAt(x, y)) contentInk = true;
      }
    }
    expect(
      contentInk,
      isTrue,
      reason: 'glyphs must render inside the viewport sub-rect',
    );
    // The bucket padding right of the content must be untouched (transparent
    // clear + clip-space culling keep draws inside the viewport).
    var paddingInk = false;
    for (var y = 0; y < img.height && !paddingInk; y += 5) {
      for (
        var x = src.width.toInt() + 1;
        x < img.width && !paddingInk;
        x += 3
      ) {
        if (inkAt(x, y)) paddingInk = true;
      }
    }
    expect(
      paddingInk,
      isFalse,
      reason: 'nothing may render outside the viewport sub-rect',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('SliverGPUText re-wraps across a rapid double resize '
      '(superseded reflow results still apply)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    final metrics = <GPUTextMetrics>[];
    final doc = GPUTextDocument.rich(
      'doc-resize',
      TextSpan(
        text: List.generate(
          200,
          (i) => 'Line $i of the resizing document.',
        ).join('\n'),
        style: const TextStyle(fontSize: 16),
      ),
      fontIdResolver: (_) => 'lato',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            SliverGPUText(
              controller: controller,
              document: doc,
              onMetrics: metrics.add,
            ),
          ],
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics.isNotEmpty);

    // Two width changes on consecutive frames: the second reflow request
    // starts before the first result lands, so the first arrives
    // "superseded". It must still apply (it is newer than the screen), and
    // the LAST width must win — under the old epoch gate a continuous resize
    // discarded every arriving result until input paused.
    tester.view.physicalSize = const Size(640, 600);
    await tester.pump();
    tester.view.physicalSize = const Size(700, 600);
    await tester.pump();
    await _pumpUntil(
      tester,
      () => metrics.isNotEmpty && (metrics.last.size.width - 700).abs() < 0.5,
    );

    final sliver =
        tester.renderObject(find.byType(SliverGPUText)) as RenderSliverGPUText;
    expect(sliver.debugHasWindow, isTrue);
    expect(sliver.geometry!.scrollExtent, metrics.last.size.height);
    expect(tester.takeException(), isNull);
  });
}
