// Selection over the worker path, GPU-less: the shared SelectableTextFragment
// driven through the Selectable event API against a decoded
// SnapshotParagraphGeometry (exactly what a worker-backed view holds), plus a
// headless GPUTextView-in-SelectionArea smoke test (no flutter_gpu here — the
// full drag flow over real worker views is in selection_gpu_test.dart).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show MaterialApp, SelectionArea;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/lowlevel.dart';
import 'package:gputext/src/engine/engine.dart';
import 'package:gputext/src/paragraph.dart' as wf;
import 'package:gputext/src/widgets/selectable_fragment.dart';

class _FakeHost implements GPUSelectableTextHost {
  _FakeHost(this.geometry);

  wf.ParagraphGeometryBase? geometry;
  int repaints = 0;

  @override
  wf.ParagraphGeometryBase? get selectionGeometry => geometry;
  @override
  ui.TextDirection get selectionTextDirection => ui.TextDirection.ltr;
  @override
  Size get selectionSize => const Size(400, 200);
  @override
  Matrix4 selectionTransformTo(RenderObject? ancestor) => Matrix4.identity();
  @override
  bool get selectionPaintReady => true;
  @override
  void markSelectionPaintDirty() => repaints++;
  @override
  Color? get selectionHighlightColor => const Color(0x662196F3);
}

void main() {
  late GPUFont font;

  setUpAll(() {
    font = GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync());
    GPUText.instance.registerFont('Lato', font);
  });

  wf.TextRun run(String text) => wf.TextRun(
    text: text,
    font: font,
    fontSizePx: 16,
    color: const [0, 0, 0, 1],
  );

  /// Snapshot geometry round-tripped through the wire codec — what a
  /// worker-backed view decodes from a reflow reply.
  wf.SnapshotParagraphGeometry snapshotOfItems(
    List<wf.InlineItem> items, {
    double width = 400,
  }) {
    final para = wf.breakLines(
      items,
      width,
      wf.ParagraphStyle(maxWidth: width),
    );
    final live = wf.ParagraphGeometry(
      items: items,
      para: para,
      boxWidth: width,
      align: wf.TextAlign.left,
    );
    return wf.SnapshotParagraphGeometry.decode(wf.encodeGeometrySnapshot(live));
  }

  wf.SnapshotParagraphGeometry snapshotOf(String text, {double width = 400}) =>
      snapshotOfItems([run(text)], width: width);

  group('SelectableTextFragment over snapshot geometry', () {
    test('edge drag selects between source boundaries', () {
      final g = snapshotOf('hello world');
      final host = _FakeHost(g);
      final f = SelectableTextFragment(
        host,
        TextRange(start: 0, end: g.plainText.length),
      );

      final x0 = g.caretAt(0).x;
      final x5 = g.caretAt(5).x;
      final y = g.lineTop(0) + 2;
      f.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forStart(globalPosition: Offset(x0, y)),
      );
      f.dispatchSelectionEvent(
        SelectionEdgeUpdateEvent.forEnd(globalPosition: Offset(x5, y)),
      );

      expect(f.getSelectedContent()?.plainText, 'hello');
      expect(f.value.status, SelectionStatus.uncollapsed);
      expect(f.value.selectionRects, isNotEmpty);
      expect(f.value.startSelectionPoint, isNotNull);
      expect(f.value.endSelectionPoint, isNotNull);
      expect(host.repaints, greaterThan(0));

      f.dispatchSelectionEvent(const ClearSelectionEvent());
      expect(f.getSelectedContent(), isNull);
      expect(f.value.status, SelectionStatus.none);
      f.dispose();
    });

    test('word selection snaps to word boundaries', () {
      final g = snapshotOf('hello world');
      final f = SelectableTextFragment(
        _FakeHost(g),
        TextRange(start: 0, end: g.plainText.length),
      );
      final xMidWorld = (g.caretAt(7).x + g.caretAt(8).x) / 2;
      f.dispatchSelectionEvent(
        SelectWordSelectionEvent(
          globalPosition: Offset(xMidWorld, g.lineTop(0) + 2),
        ),
      );
      expect(f.getSelectedContent()?.plainText, 'world');
      f.dispose();
    });

    test('select-all covers the fragment range', () {
      final g = snapshotOf('aaa bbb ccc', width: 45);
      expect(g.lineCount, greaterThan(1));
      final f = SelectableTextFragment(
        _FakeHost(g),
        TextRange(start: 0, end: g.plainText.length),
      );
      f.dispatchSelectionEvent(const SelectAllSelectionEvent());
      expect(f.getSelectedContent()?.plainText, 'aaa bbb ccc');
      // One highlight rect per wrapped line.
      expect(f.value.selectionRects.length, g.lineCount);
      f.dispose();
    });

    test('events before geometry arrives degrade; rects appear on arrival', () {
      final host = _FakeHost(null);
      final f = SelectableTextFragment(
        host,
        const TextRange(start: 0, end: 11),
      );
      // No geometry yet (worker snapshot in flight): selecting records
      // offsets but reports none/empty and copy yields nothing.
      f.dispatchSelectionEvent(const SelectAllSelectionEvent());
      expect(f.value.status, SelectionStatus.none);
      expect(f.value.selectionRects, isEmpty);
      expect(f.getSelectedContent(), isNull);

      // Snapshot lands: same source offsets, real rects and content.
      host.geometry = snapshotOf('hello world');
      f.didChangeParagraphLayout();
      expect(f.value.status, SelectionStatus.uncollapsed);
      expect(f.value.selectionRects, isNotEmpty);
      expect(f.getSelectedContent()?.plainText, 'hello world');
      f.dispose();
    });

    test('drag edge routes across a placeholder split', () {
      // 'hello ' + inline widget + 'world' → two fragments around the '￼'.
      // The region delegate walks fragments in screen order, moving an edge
      // while a fragment answers next/previous; each fragment must judge the
      // pointer against ITS OWN text bounds (not the whole paragraph box) or
      // the edge can never cross the placeholder. Emulate the delegate's walk
      // for a drag from 'hello' into 'world'.
      final g = snapshotOfItems([
        run('hello '),
        const wf.PlaceholderItem(
          index: 0,
          width: 24,
          height: 12,
          alignment: wf.InlinePlaceholderAlignment.middle,
        ),
        run('world'),
      ]);
      expect(g.plainText, 'hello ￼world');
      expect(g.placeholderOffsets, [6]);
      final host = _FakeHost(g);
      final f1 = SelectableTextFragment(
        host,
        const TextRange(start: 0, end: 6),
      );
      final f2 = SelectableTextFragment(
        host,
        const TextRange(start: 7, end: 12),
      );

      final y = g.lineTop(0) + 2;
      final start = Offset(g.caretAt(0).x, y);
      final end = Offset(g.caretAt(10).x, y); // between 'wor' and 'ld'

      expect(
        f1.dispatchSelectionEvent(
          SelectionEdgeUpdateEvent.forStart(globalPosition: start),
        ),
        SelectionResult.end,
      );
      // End edge past f1's own text: cede forward, clamped to f1's end.
      expect(
        f1.dispatchSelectionEvent(
          SelectionEdgeUpdateEvent.forEnd(globalPosition: end),
        ),
        SelectionResult.next,
      );
      expect(f1.getSelectedContent()?.plainText, 'hello ');

      // The delegate hands both edges to f2: the start edge sits before its
      // text (previous, clamped to f2's start), the end edge lands inside.
      expect(
        f2.dispatchSelectionEvent(
          SelectionEdgeUpdateEvent.forStart(globalPosition: start),
        ),
        SelectionResult.previous,
      );
      expect(
        f2.dispatchSelectionEvent(
          SelectionEdgeUpdateEvent.forEnd(globalPosition: end),
        ),
        SelectionResult.end,
      );
      expect(f2.getSelectedContent()?.plainText, 'wor');
      f1.dispose();
      f2.dispose();
    });

    test('fragment range clamps selection (placeholder split)', () {
      final g = snapshotOf('hello world');
      final f = SelectableTextFragment(
        _FakeHost(g),
        const TextRange(start: 6, end: 11), // just 'world'
      );
      f.dispatchSelectionEvent(const SelectAllSelectionEvent());
      expect(f.getSelectedContent()?.plainText, 'world');
      expect(f.contentLength, 5);
      expect(
        f.getSelection(),
        isA<SelectedContentRange>()
            .having((r) => r.startOffset, 'start', 0)
            .having((r) => r.endOffset, 'end', 5),
      );
      f.dispose();
    });
  });

  test('boxesForRange covers every selected line across wrap widths '
      '(worker items)', () {
    // Worker-built items (HarfBuzz shaping) with a placeholder, swept over
    // wrap widths: every line intersecting the selection range must yield a
    // highlight rect from the decoded snapshot's boxesForRange.
    final shaper = loadHarfBuzzShaper();
    expect(shaper, isNotNull, reason: 'HarfBuzz must load for this test');
    const text1 =
        'SliverGPUText lays the whole document out on the worker isolate ';
    const text2 =
        'and rasters only the visible band while scrolling. Inline widgets '
        'ride along as placeholders. Second sentence with more text to wrap '
        'across lines and exercise soft wrapping thoroughly.\n\n'
        'A hard break paragraph follows here with enough words to wrap at '
        'narrow widths too, plus emoji 😀 and a ligature offline effort.';
    final specs = <GPUInlineSpec>[
      const GPUTextRunSpec(
        text: text1,
        fontId: 'lato',
        fontSizePx: 16,
        color: [0, 0, 0, 1],
      ),
      const GPUPlaceholderSpec(
        index: 0,
        width: 58,
        height: 32,
        alignment: wf.InlinePlaceholderAlignment.middle,
      ),
      const GPUTextRunSpec(
        text: text2,
        fontId: 'lato',
        fontSizePx: 16,
        color: [0, 0, 0, 1],
      ),
    ];
    final fonts = {'lato': font};
    final problems = <String>[];
    for (var width = 120.0; width <= 800.0; width += 7.0) {
      final items = buildRunItems(specs, fonts, shaper);
      final para = wf.breakLines(
        items,
        width,
        wf.ParagraphStyle(maxWidth: width),
      );
      final live = wf.ParagraphGeometry(
        items: items,
        para: para,
        boxWidth: width,
        align: wf.TextAlign.left,
      );
      final g = wf.SnapshotParagraphGeometry.decode(
        wf.encodeGeometrySnapshot(live),
      );
      final n = g.plainText.length;
      for (final (a, b) in [(0, n), (10, n - 10)]) {
        final rects = g.boxesForRange(a, b);
        for (var line = 0; line < g.lineCount; line++) {
          final ls = g.lineStartAt(line);
          final le = g.lineEndAt(line);
          final s = a > ls ? a : ls;
          final e = b < le ? b : le;
          if (s >= e) continue; // no selected content on this line
          final top = g.lineTop(line);
          final bottom = top + g.lineBoxHeightAt(line);
          final hasRect = rects.any(
            (r) =>
                r.top < bottom - 0.1 &&
                r.bottom > top + 0.1 &&
                r.right > r.left,
          );
          if (!hasRect) {
            problems.add(
              'width=$width range=($a,$b) line=$line src=[$ls,$le) '
              'sel=[$s,$e) text="${g.plainText.substring(s, e)}"',
            );
          }
        }
      }
    }
    expect(problems, isEmpty, reason: problems.take(20).join('\n'));
  });

  testWidgets('GPUTextView under SelectionArea builds (headless or GPU)', (
    tester,
  ) async {
    final controller = (await tester.runAsync(GPUTextViewController.spawn))!;
    addTearDown(controller.dispose);
    await tester.runAsync(
      () => controller.registerFont(
        'lato',
        File('assets/Lato-Regular.ttf').readAsBytesSync(),
      ),
    );
    const doc = GPUTextDocument(
      id: 'doc',
      runs: [
        GPUTextRunSpec(
          text: 'some selectable text',
          fontId: 'lato',
          fontSizePx: 16,
          color: [0, 0, 0, 1],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionArea(
          child: SizedBox(
            width: 300,
            height: 200,
            child: GPUTextView(controller: controller, document: doc),
          ),
        ),
      ),
    );
    // Headless the view degrades (no surface, no reflow); with
    // --enable-flutter-gpu the reflow really runs. Either way selection
    // wiring must not throw or register mid-build. Let the surface probe and
    // any deferred registrar callbacks settle.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('SliverGPUText under SelectionArea builds (headless or GPU)', (
    tester,
  ) async {
    final controller = (await tester.runAsync(GPUTextViewController.spawn))!;
    addTearDown(controller.dispose);
    await tester.runAsync(
      () => controller.registerFont(
        'lato',
        File('assets/Lato-Regular.ttf').readAsBytesSync(),
      ),
    );
    const doc = GPUTextDocument(
      id: 'sliver-doc',
      runs: [
        GPUTextRunSpec(
          text: 'sliver selectable text',
          fontId: 'lato',
          fontSizePx: 16,
          color: [0, 0, 0, 1],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionArea(
          child: CustomScrollView(
            slivers: [SliverGPUText(controller: controller, document: doc)],
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });
}
