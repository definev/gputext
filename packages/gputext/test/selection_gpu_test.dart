// Selection over worker-backed views with a real worker isolate + real GPU:
// drag-select in SliverGPUText / GPUTextView, then scroll and resize — the
// reported content, the doc-space highlight rects, and the actually painted
// highlight must all survive. Needs
// `flutter test --enable-impeller --enable-flutter-gpu` (like
// sliver_gpu_text_test.dart); without the flags the surface probe fails and
// the first reflow never lands.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/lowlevel.dart' hide TextAlign, TextDirection;
import 'package:gputext/src/lowlevel/gpu_text_view.dart'
    show RenderSliverGPUText;

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

/// Number of distinct vertical line bands covered by highlight rects.
int _bandCount(List<Rect> rects) {
  final sorted = [...rects]..sort((a, b) => a.top.compareTo(b.top));
  var bands = 0;
  double? lastTop;
  for (final r in sorted) {
    if (lastTop == null || (r.top - lastTop).abs() > 0.5) {
      bands++;
      lastTop = r.top;
    }
  }
  return bands;
}

const _highlight = Color(0xFF00C853); // opaque green, unmistakable

/// Rows (in image pixels) that contain at least [minRun] green-ish pixels.
Set<int> _greenRows(ByteData data, int width, int height, {int minRun = 4}) {
  final rows = <int>{};
  for (var y = 0; y < height; y++) {
    var run = 0;
    for (var x = 0; x < width; x++) {
      final o = (y * width + x) * 4;
      final r = data.getUint8(o);
      final g = data.getUint8(o + 1);
      final b = data.getUint8(o + 2);
      final greenish = g > 140 && g > r + 60 && g > b + 60;
      run = greenish ? run + 1 : 0;
      if (run >= minRun) {
        rows.add(y);
        break;
      }
    }
  }
  return rows;
}

/// Contiguous row bands from a set of rows.
List<(int, int)> _bands(Set<int> rows) {
  final sorted = rows.toList()..sort();
  final out = <(int, int)>[];
  int? start;
  int? prev;
  for (final y in sorted) {
    if (prev == null || y > prev + 2) {
      if (start != null) out.add((start, prev!));
      start = y;
    }
    prev = y;
  }
  if (start != null) out.add((start, prev!));
  return out;
}

void main() {
  testWidgets('sliver: highlight survives scroll and resize', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    final metrics = <GPUTextMetrics>[];
    final text = List.generate(
      80,
      (i) => 'Line $i of the sliver document with some words.',
    ).join('\n');
    final doc = GPUTextDocument.rich(
      'doc-sel',
      TextSpan(text: text, style: const TextStyle(fontSize: 16)),
      fontIdResolver: (_) => 'lato',
    );

    SelectedContent? content;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionArea(
          onSelectionChanged: (c) => content = c,
          child: CustomScrollView(
            controller: scroll,
            slivers: [
              SliverGPUText(
                controller: controller,
                document: doc,
                onMetrics: metrics.add,
              ),
            ],
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics.isNotEmpty, reason: 'first reflow');
    await tester.pump();

    final render = tester.renderObject<RenderSliverGPUText>(
      find.byType(SliverGPUText),
    );

    // Drag-select lines ~1..5 with incremental mouse moves.
    final gesture = await tester.startGesture(
      const Offset(10, 25),
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    for (final y in [45.0, 65.0, 85.0, 105.0]) {
      await gesture.moveTo(Offset(320, y));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final rects0 = render.debugSelectionRects;
    final content0 = content?.plainText;
    expect(content0, isNotNull);
    final lines0 = '\n'.allMatches(content0!).length + 1;
    expect(
      _bandCount(rects0),
      lines0,
      reason: 'initial highlight must cover every selected line',
    );

    // Scroll down and back up — doc-space rects must be identical.
    scroll.jumpTo(400);
    await tester.pumpAndSettle();
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(content?.plainText, content0, reason: 'content after scroll');
    expect(
      render.debugSelectionRects,
      rects0,
      reason: 'rects changed after scroll',
    );

    // Resize the window width — a reflow round trip. Content and per-line
    // coverage must survive (hard-broken lines: same line count).
    final reflowsBefore = metrics.length;
    tester.view.physicalSize = const Size(680, 600);
    await tester.pump();
    await _pumpUntil(
      tester,
      () => metrics.length > reflowsBefore,
      reason: 'reflow after resize',
    );
    await tester.pumpAndSettle();
    expect(content?.plainText, content0, reason: 'content after resize');
    final rects1 = render.debugSelectionRects;
    expect(
      _bandCount(rects1),
      lines0,
      reason: 'highlight lines missing after resize',
    );

    // Scroll again at the new width.
    scroll.jumpTo(300);
    await tester.pumpAndSettle();
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(
      content?.plainText,
      content0,
      reason: 'content after scroll at new width',
    );
    expect(
      _bandCount(render.debugSelectionRects),
      lines0,
      reason: 'highlight lines missing after scroll at new width',
    );
  });

  testWidgets('view: highlight survives outer scroll and resize', (
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
      80,
      (i) => 'Row $i of the view document with some words.',
    ).join('\n');
    final doc = GPUTextDocument.rich(
      'view-sel',
      TextSpan(text: text, style: const TextStyle(fontSize: 16)),
      fontIdResolver: (_) => 'lato',
    );

    SelectedContent? content;
    var width = 500.0;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setOuter = setState;
              return Center(
                child: SizedBox(
                  width: width,
                  height: 400,
                  child: SelectionArea(
                    onSelectionChanged: (c) => content = c,
                    // The view is a pure widget — the scroll view around it
                    // provides the scrolling the old internal mode had.
                    child: SingleChildScrollView(
                      child: GPUTextView(
                        controller: controller,
                        document: doc,
                        onMetrics: metrics.add,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics.isNotEmpty, reason: 'first reflow');
    await tester.pump();

    final viewTopLeft = tester.getTopLeft(find.byType(GPUTextView));
    // The view's State class is private; debugSelectionRects is reached
    // dynamically.
    final state = tester.state(find.byType(GPUTextView)) as dynamic;

    final gesture = await tester.startGesture(
      viewTopLeft + const Offset(10, 12),
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    for (final y in [30.0, 50.0, 70.0, 90.0]) {
      await gesture.moveTo(viewTopLeft + Offset(300, y));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final rects0 = List<Rect>.from(state.debugSelectionRects as List);
    final content0 = content?.plainText;
    expect(content0, isNotNull);
    final lines0 = '\n'.allMatches(content0!).length + 1;
    expect(
      _bandCount(rects0),
      lines0,
      reason: 'initial highlight must cover every selected line',
    );

    // Outer scroll: wheel down then back.
    final center = tester.getCenter(find.byType(SingleChildScrollView));
    final pointer = TestPointer(2, PointerDeviceKind.mouse);
    pointer.hover(center);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 400)));
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -400)));
    await tester.pumpAndSettle();
    expect(content?.plainText, content0, reason: 'content after scroll');
    expect(
      List<Rect>.from(state.debugSelectionRects as List),
      rects0,
      reason: 'rects changed after outer scroll',
    );

    // Width change through the widget tree.
    final reflowsBefore = metrics.length;
    setOuter(() => width = 420);
    await tester.pump();
    await _pumpUntil(
      tester,
      () => metrics.length > reflowsBefore,
      reason: 'reflow after resize',
    );
    await tester.pumpAndSettle();
    expect(content?.plainText, content0, reason: 'content after resize');
    expect(
      _bandCount(List<Rect>.from(state.debugSelectionRects as List)),
      lines0,
      reason: 'highlight lines missing after resize',
    );
  });

  testWidgets('sliver: selection works on a doc far past the old snapshot '
      'budget', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    final metrics = <GPUTextMetrics>[];
    // ~340k source chars (over the 250k full-snapshot budget): under the
    // old design this document was silently not selectable at all.
    final text = List.generate(
      8000,
      (i) => 'Huge line $i of the stress document body text.',
    ).join('\n');
    expect(text.length, greaterThan(250000));
    final doc = GPUTextDocument.rich(
      'doc-huge',
      TextSpan(text: text, style: const TextStyle(fontSize: 16)),
      fontIdResolver: (_) => 'lato',
    );

    SelectedContent? content;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionArea(
          onSelectionChanged: (c) => content = c,
          child: CustomScrollView(
            controller: scroll,
            slivers: [
              SliverGPUText(
                controller: controller,
                document: doc,
                onMetrics: metrics.add,
              ),
            ],
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics.isNotEmpty, reason: 'first reflow');
    await tester.pumpAndSettle();

    final render = tester.renderObject<RenderSliverGPUText>(
      find.byType(SliverGPUText),
    );

    // Drag-select a few lines at the top.
    final gesture = await tester.startGesture(
      const Offset(10, 25),
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    for (final y in [45.0, 65.0, 85.0]) {
      await gesture.moveTo(Offset(300, y));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    // Let the detail band land and refine the selection.
    await _pumpUntil(
      tester,
      () => content?.plainText != null,
      reason: 'selection content',
    );
    await tester.pumpAndSettle();

    final content0 = content?.plainText;
    expect(content0, isNotNull);
    expect(content0, contains('line 1 of the stress'));
    final lines0 = '\n'.allMatches(content0!).length + 1;
    expect(
      _bandCount(render.debugSelectionRects),
      lines0,
      reason: 'every selected line highlighted on the huge doc',
    );

    // Deep scroll away and back — the selection must survive, and detail
    // prefetch for the far band must not disturb it.
    scroll.jumpTo(80000);
    await tester.pumpAndSettle();
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(content?.plainText, content0, reason: 'content after deep scroll');
    expect(
      _bandCount(render.debugSelectionRects),
      lines0,
      reason: 'highlight after deep scroll',
    );

    // Keyboard select-all across ~340k chars: content must be the full
    // source text, delivered from main-isolate specs (nothing shipped).
    await tester.tapAt(const Offset(400, 300), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(content?.plainText, text, reason: 'select-all copies full source');
  });

  testWidgets('view: selection on a huge doc stays band-limited', (
    tester,
  ) async {
    // GPUTextView is content-sized: its selection underlay spans the WHOLE
    // document, so the visible band must come from the raster slice. A
    // regression here made detail prefetch request the entire document per
    // paint (and, past the detail-cache cap, loop forever re-fetching) —
    // this doc is deliberately larger than the cap so that loop would hang
    // the settle below.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    final metrics = <GPUTextMetrics>[];
    final text = List.generate(
      6000,
      (i) => 'View line $i of the large document body.',
    ).join('\n');
    final doc = GPUTextDocument.rich(
      'view-huge',
      TextSpan(text: text, style: const TextStyle(fontSize: 16)),
      fontIdResolver: (_) => 'lato',
    );

    SelectedContent? content;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionArea(
          onSelectionChanged: (c) => content = c,
          child: SingleChildScrollView(
            controller: scroll,
            child: GPUTextView(
              controller: controller,
              document: doc,
              onMetrics: metrics.add,
            ),
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics.isNotEmpty, reason: 'first reflow');
    await tester.pumpAndSettle();

    // Drag-select a few lines near the top; the band fetch must stay small
    // and the selection must land char-accurately once detail arrives.
    final gesture = await tester.startGesture(
      const Offset(10, 8),
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    for (final y in [30.0, 50.0, 70.0]) {
      await gesture.moveTo(Offset(280, y));
      await tester.pump();
    }
    await gesture.up();
    await _pumpUntil(
      tester,
      () => content?.plainText != null,
      reason: 'selection content',
    );
    // Give any (bounded) detail merges a chance to land, then require the
    // frame pipeline to go quiet — an unbounded prefetch loop never does.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 20),
    );
    expect(content!.plainText, contains('line 1 of the large'));

    // Scroll far and back with the selection held — must stay responsive
    // and identical.
    final content0 = content?.plainText;
    scroll.jumpTo(40000);
    await tester.pumpAndSettle();
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(content?.plainText, content0, reason: 'content after deep scroll');
  });

  testWidgets('view: highlight follows scroll into newly revealed lines', (
    tester,
  ) async {
    // The view's selection underlay records band-limited rects behind a
    // RepaintBoundary; when the raster slice moves with scroll, revealed
    // lines must get their highlight re-recorded. A regression left the old
    // band's picture in place — scrolled-to text showed no highlight.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    final metrics = <GPUTextMetrics>[];
    final text = List.generate(
      300,
      (i) => 'Scroll line $i of the selected document.',
    ).join('\n');
    final doc = GPUTextDocument.rich(
      'view-scroll-hl',
      TextSpan(text: text, style: const TextStyle(fontSize: 16)),
      fontIdResolver: (_) => 'lato',
    );

    final boundaryKey = GlobalKey();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          textSelectionTheme: const TextSelectionThemeData(
            selectionColor: _highlight,
          ),
        ),
        home: RepaintBoundary(
          key: boundaryKey,
          child: SelectionArea(
            child: SingleChildScrollView(
              controller: scroll,
              child: GPUTextView(
                controller: controller,
                document: doc,
                onMetrics: metrics.add,
              ),
            ),
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics.isNotEmpty, reason: 'first reflow');
    await tester.pumpAndSettle();

    // Focus the region and select everything.
    await tester.tapAt(const Offset(400, 300), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    Future<int> paintedBandCount() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      ui.Image? image;
      await tester.runAsync(() async {
        image = await boundary.toImage(pixelRatio: 1.0);
      });
      final data = (await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      final rows = _greenRows(data, image!.width, image!.height);
      image!.dispose();
      return _bands(rows).length;
    }

    // Baseline: the visible top of the select-all paints per-line bands.
    final bands0 = await paintedBandCount();
    expect(bands0, greaterThanOrEqualTo(10), reason: 'baseline highlight');

    // Scroll far past the initial raster slice (several viewports): the
    // slice moves and the revealed lines must paint their highlight too.
    scroll.jumpTo(4000);
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final bandsScrolled = await paintedBandCount();
    expect(
      bandsScrolled,
      greaterThanOrEqualTo(10),
      reason: 'scrolled-to lines must keep their highlight',
    );

    // Scroll back to the top. This band's detail is already cached (no
    // merge, no incidental repaint) — the underlay must still re-record
    // rects for it when the slice moves back.
    scroll.jumpTo(0);
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final bandsBack = await paintedBandCount();
    expect(
      bandsBack,
      greaterThanOrEqualTo(10),
      reason: 'scrolling back must restore the highlight on cached lines',
    );
  });

  testWidgets('sliver highlight paints every visible selected line', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2.0; // like a real macOS window
    tester.view.physicalSize = const Size(1600, 1200); // 800x600 logical
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    final metrics = <GPUTextMetrics>[];
    final text = List.generate(
      80,
      (i) => 'Line $i of the sliver document with some words.',
    ).join('\n');
    final doc = GPUTextDocument.rich(
      'doc-px',
      TextSpan(text: text, style: const TextStyle(fontSize: 16)),
      fontIdResolver: (_) => 'lato',
    );

    final boundaryKey = GlobalKey();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          textSelectionTheme: const TextSelectionThemeData(
            selectionColor: _highlight,
          ),
        ),
        home: RepaintBoundary(
          key: boundaryKey,
          child: SelectionArea(
            child: CustomScrollView(
              controller: scroll,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  sliver: SliverGPUText(
                    controller: controller,
                    document: doc,
                    onMetrics: metrics.add,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics.isNotEmpty, reason: 'first reflow');
    await tester.pump();

    final render = tester.renderObject<RenderSliverGPUText>(
      find.byType(SliverGPUText),
    );

    // Select lines ~0..7 (top of the doc, below the 16px padding).
    final gesture = await tester.startGesture(
      const Offset(30, 22),
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    for (var y = 40.0; y <= 170.0; y += 20.0) {
      await gesture.moveTo(Offset(330, y));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final selectedLines = render.debugSelectionRects.length;
    expect(selectedLines, greaterThanOrEqualTo(6));

    Future<Set<int>> paintedRows() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      ui.Image? image;
      await tester.runAsync(() async {
        image = await boundary.toImage(pixelRatio: 1.0);
      });
      final data = (await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      final rows = _greenRows(data, image!.width, image!.height);
      image!.dispose();
      return rows;
    }

    // Baseline: every selected line paints a band.
    final bands0 = _bands(await paintedRows());
    expect(
      bands0.length,
      selectedLines,
      reason: 'baseline: painted bands != selected lines',
    );

    // Scroll down a little so the selection is PARTIALLY off-screen; every
    // still-visible selected line must keep its painted band.
    scroll.jumpTo(60);
    await tester.pumpAndSettle();
    final bandsPartial = _bands(await paintedRows());
    expect(
      bandsPartial.length,
      greaterThanOrEqualTo(selectedLines - 4),
      reason: 'partial scroll: visible selected lines lost their highlight',
    );

    // Scroll far away and back — full coverage must return.
    scroll.jumpTo(600);
    await tester.pumpAndSettle();
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    final bands1 = _bands(await paintedRows());
    expect(
      bands1.length,
      selectedLines,
      reason: 'after scroll away+back: painted bands != selected lines',
    );

    // Resize the window; wait for the reflow; coverage must return.
    final reflowsBefore = metrics.length;
    tester.view.physicalSize = const Size(1360, 1200); // 680x600 logical
    await tester.pump();
    await _pumpUntil(
      tester,
      () => metrics.length > reflowsBefore,
      reason: 'reflow after resize',
    );
    await tester.pumpAndSettle();
    final bands2 = _bands(await paintedRows());
    expect(
      bands2.length,
      selectedLines,
      reason: 'after resize: painted bands != selected lines',
    );
  });
}
