// SelectionArea / SelectableRegion integration and render-object geometry
// APIs: drag selection, double-click word select, keyboard select-all, and
// copy content that round-trips ligatures back to source characters.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent, SelectedContent;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/engine/engine.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/widgets/rich_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    GPUText.instance.registerFont(
      'Lato',
      GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync()),
    );
  });

  const style = TextStyle(fontFamily: 'Lato', fontSize: 20);

  Widget host(Widget child, {ValueChanged<SelectedContent?>? onChanged}) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SelectionArea(onSelectionChanged: onChanged, child: child),
          ),
        ),
      );

  group('render object geometry APIs', () {
    testWidgets('position/caret/boxes/word/line boundaries', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: GPURichText(
              text: const TextSpan(text: 'hello world', style: style),
            ),
          ),
        ),
      );
      final render =
          tester.renderObject(find.byType(GPURichText)) as RenderGPUParagraph;
      expect(render.plainText, 'hello world');

      final caret4 = render.getOffsetForCaret(
        const TextPosition(offset: 4),
        Rect.zero,
      );
      final pos = render.getPositionForOffset(caret4 + const Offset(0.1, 2));
      expect(pos.offset, 4);

      final boxes = render.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 5),
      );
      expect(boxes, hasLength(1));
      expect(boxes.single.left, lessThan(boxes.single.right));

      expect(
        render.getWordBoundary(const TextPosition(offset: 8)),
        const TextRange(start: 6, end: 11),
      );
      expect(
        render.getLineBoundary(const TextPosition(offset: 3)),
        const TextRange(start: 0, end: 11),
      );
      expect(
        render.getFullHeightForCaret(const TextPosition(offset: 0)),
        greaterThan(0),
      );
    });
  });

  group('SelectionArea', () {
    testWidgets('mouse drag selects and reports content', (tester) async {
      SelectedContent? content;
      await tester.pumpWidget(
        host(
          GPURichText(
            text: const TextSpan(text: 'hello world', style: style),
          ),
          onChanged: (c) => content = c,
        ),
      );
      final render =
          tester.renderObject(find.byType(GPURichText)) as RenderGPUParagraph;
      Offset globalCaret(int offset) => render.localToGlobal(
        render.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
            const Offset(0, 10),
      );

      final gesture = await tester.startGesture(
        globalCaret(0),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(globalCaret(5));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(content?.plainText, 'hello');
    });

    testWidgets('mouse drag crosses a WidgetSpan', (tester) async {
      // Text split by an inline widget registers one fragment per side; the
      // drag edge must route past the placeholder (each fragment cedes on
      // its OWN bounds) or the selection can never reach the second half.
      SelectedContent? content;
      await tester.pumpWidget(
        host(
          GPURichText(
            text: const TextSpan(
              style: style,
              children: [
                TextSpan(text: 'hello '),
                WidgetSpan(child: SizedBox(width: 24, height: 12)),
                TextSpan(text: ' world'),
              ],
            ),
          ),
          onChanged: (c) => content = c,
        ),
      );
      final render =
          tester.renderObject(find.byType(GPURichText)) as RenderGPUParagraph;
      expect(render.plainText, 'hello \u{FFFC} world');
      Offset globalCaret(int offset) => render.localToGlobal(
        render.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
            const Offset(0, 10),
      );

      final gesture = await tester.startGesture(
        globalCaret(0),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await tester.pump();
      // Incremental moves, like a real drag: the edge lands inside the first
      // fragment and must be handed forward from there (a single jump would
      // let the delegate hit-test the far fragment directly and hide a
      // routing bug).
      // End strictly inside the paragraph box (mid-'world'), not at its right
      // edge — an edge-of-box endpoint routes forward even without
      // per-fragment bounds and would mask the bug.
      await gesture.moveTo(globalCaret(3));
      await tester.pump();
      await gesture.moveTo(globalCaret(11));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(content?.plainText, 'hello  wor');
    });

    testWidgets('selection copies SOURCE text through ligatures', (
      tester,
    ) async {
      SelectedContent? content;
      await tester.pumpWidget(
        host(
          GPURichText(
            text: const TextSpan(text: 'first offer', style: style),
          ),
          onChanged: (c) => content = c,
        ),
      );
      final render =
          tester.renderObject(find.byType(GPURichText)) as RenderGPUParagraph;
      // The rendered text is ligated (fi, ff → single clusters) but source
      // offsets and copied content must be the original characters.
      expect(render.plainText, 'first offer');

      Offset globalCaret(int offset) => render.localToGlobal(
        render.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
            const Offset(0, 10),
      );
      final gesture = await tester.startGesture(
        globalCaret(0),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(globalCaret(11));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(content?.plainText, 'first offer');
    });

    testWidgets('double click selects a word', (tester) async {
      SelectedContent? content;
      await tester.pumpWidget(
        host(
          GPURichText(
            text: const TextSpan(text: 'alpha beta gamma', style: style),
          ),
          onChanged: (c) => content = c,
        ),
      );
      final render =
          tester.renderObject(find.byType(GPURichText)) as RenderGPUParagraph;
      final betaMid = render.localToGlobal(
        render.getOffsetForCaret(const TextPosition(offset: 8), Rect.zero) +
            const Offset(1, 10),
      );

      final gesture = await tester.startGesture(
        betaMid,
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 80));
      await gesture.down(betaMid);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(content?.plainText, 'beta');
    });

    testWidgets('keyboard select-all crosses WidgetSpan children', (
      tester,
    ) async {
      SelectedContent? content;
      await tester.pumpWidget(
        host(
          GPURichText(
            text: const TextSpan(
              style: style,
              children: [
                TextSpan(text: 'before '),
                WidgetSpan(child: Text('chip', style: style)),
                TextSpan(text: ' after'),
              ],
            ),
          ),
          onChanged: (c) => content = c,
        ),
      );
      // Click to focus the selection region, then Ctrl+A.
      await tester.tapAt(
        tester.getCenter(find.byType(SelectionArea)),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(content?.plainText, contains('before'));
      expect(content?.plainText, contains('chip'));
      expect(content?.plainText, contains('after'));
    });

    testWidgets('selection survives scroll and width change', (tester) async {
      // The selection is stored as source offsets, so scrolling paragraphs
      // out of the cache extent and rewrapping at a new width must not
      // change the reported content.
      SelectedContent? content;
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var width = 500.0;
      late StateSetter setOuterState;

      Widget build() => MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setOuterState = setState;
              return Center(
                child: SizedBox(
                  width: width,
                  height: 400,
                  child: SelectionArea(
                    onSelectionChanged: (c) => content = c,
                    child: ListView(
                      controller: scroll,
                      scrollCacheExtent: const ScrollCacheExtent.pixels(
                        2000, // keep items alive while scrolled
                      ),
                      children: [
                        for (var i = 0; i < 8; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: GPURichText(
                              text: TextSpan(
                                text:
                                    'Paragraph $i: the quick brown fox jumps '
                                    'over the lazy dog near the river bank '
                                    'and keeps going for a while longer.',
                                style: style,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      final paras = tester
          .renderObjectList(find.byType(GPURichText))
          .cast<RenderGPUParagraph>()
          .toList();
      Offset caretGlobal(RenderGPUParagraph r, int offset) => r.localToGlobal(
        r.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
            const Offset(0, 10),
      );

      // Drag from paragraph 0 into paragraph 2 with incremental moves.
      final gesture = await tester.startGesture(
        caretGlobal(paras[0], 13),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(caretGlobal(paras[0], 40));
      await tester.pump();
      await gesture.moveTo(caretGlobal(paras[1], 30));
      await tester.pump();
      await gesture.moveTo(caretGlobal(paras[2], 25));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final before = content?.plainText;
      expect(before, isNotNull);
      expect(before, contains('Paragraph 1'));

      // Scroll down and back; the selection must not change.
      scroll.jumpTo(600);
      await tester.pumpAndSettle();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        content?.plainText,
        before,
        reason: 'selection changed after scroll',
      );

      // Now resize: relayout rewraps every paragraph.
      setOuterState(() => width = 380);
      await tester.pumpAndSettle();
      expect(
        content?.plainText,
        before,
        reason: 'selection changed after width resize',
      );

      // And scroll once more at the new width.
      scroll.jumpTo(300);
      await tester.pumpAndSettle();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        content?.plainText,
        before,
        reason: 'selection changed after scroll at new width',
      );
    });

    testWidgets('selection highlight paints rects', (tester) async {
      await tester.pumpWidget(
        host(
          GPURichText(
            text: const TextSpan(text: 'hello world', style: style),
          ),
        ),
      );
      final render =
          tester.renderObject(find.byType(GPURichText)) as RenderGPUParagraph;
      Offset globalCaret(int offset) => render.localToGlobal(
        render.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
            const Offset(0, 10),
      );
      final gesture = await tester.startGesture(
        globalCaret(1),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(globalCaret(9));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      // The paragraph paints at least one selection rect.
      expect(render.debugNeedsPaint, isFalse);
      expect(find.byType(GPURichText), paints..rect());
    });
  });
}
