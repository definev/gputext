// SelectionArea / SelectableRegion integration and render-object geometry
// APIs: drag selection, double-click word select, keyboard select-all, and
// copy content that round-trips ligatures back to source characters.

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:windfoil_flutter/src/engine/engine.dart';
import 'package:windfoil_flutter/src/font.dart';
import 'package:windfoil_flutter/src/widgets/rich_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    Windfoil.instance.registerFont(
      'Lato',
      WindfoilFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync()),
    );
  });

  const style = TextStyle(fontFamily: 'Lato', fontSize: 20);

  Widget host(Widget child, {ValueChanged<SelectedContent?>? onChanged}) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SelectionArea(
              onSelectionChanged: onChanged,
              child: child,
            ),
          ),
        ),
      );

  group('render object geometry APIs', () {
    testWidgets('position/caret/boxes/word/line boundaries', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: WindfoilRichText(
              text: const TextSpan(text: 'hello world', style: style)),
        ),
      ));
      final render = tester.renderObject(find.byType(WindfoilRichText))
          as RenderWindfoilParagraph;
      expect(render.plainText, 'hello world');

      final caret4 = render.getOffsetForCaret(
          const TextPosition(offset: 4), Rect.zero);
      final pos = render.getPositionForOffset(caret4 + const Offset(0.1, 2));
      expect(pos.offset, 4);

      final boxes = render.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 5));
      expect(boxes, hasLength(1));
      expect(boxes.single.left, lessThan(boxes.single.right));

      expect(render.getWordBoundary(const TextPosition(offset: 8)),
          const TextRange(start: 6, end: 11));
      expect(render.getLineBoundary(const TextPosition(offset: 3)),
          const TextRange(start: 0, end: 11));
      expect(render.getFullHeightForCaret(const TextPosition(offset: 0)),
          greaterThan(0));
    });
  });

  group('SelectionArea', () {
    testWidgets('mouse drag selects and reports content', (tester) async {
      SelectedContent? content;
      await tester.pumpWidget(host(
        WindfoilRichText(
            text: const TextSpan(text: 'hello world', style: style)),
        onChanged: (c) => content = c,
      ));
      final render = tester.renderObject(find.byType(WindfoilRichText))
          as RenderWindfoilParagraph;
      Offset globalCaret(int offset) => render.localToGlobal(
          render.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
              const Offset(0, 10));

      final gesture = await tester.startGesture(globalCaret(0),
          kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(globalCaret(5));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(content?.plainText, 'hello');
    });

    testWidgets('selection copies SOURCE text through ligatures',
        (tester) async {
      SelectedContent? content;
      await tester.pumpWidget(host(
        WindfoilRichText(
            text: const TextSpan(text: 'first offer', style: style)),
        onChanged: (c) => content = c,
      ));
      final render = tester.renderObject(find.byType(WindfoilRichText))
          as RenderWindfoilParagraph;
      // The rendered text is ligated (fi, ff → single clusters) but source
      // offsets and copied content must be the original characters.
      expect(render.plainText, 'first offer');

      Offset globalCaret(int offset) => render.localToGlobal(
          render.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
              const Offset(0, 10));
      final gesture = await tester.startGesture(globalCaret(0),
          kind: PointerDeviceKind.mouse);
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
      await tester.pumpWidget(host(
        WindfoilRichText(
            text: const TextSpan(text: 'alpha beta gamma', style: style)),
        onChanged: (c) => content = c,
      ));
      final render = tester.renderObject(find.byType(WindfoilRichText))
          as RenderWindfoilParagraph;
      final betaMid = render.localToGlobal(
          render.getOffsetForCaret(const TextPosition(offset: 8), Rect.zero) +
              const Offset(1, 10));

      final gesture = await tester.startGesture(betaMid,
          kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 80));
      await gesture.down(betaMid);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(content?.plainText, 'beta');
    });

    testWidgets('keyboard select-all crosses WidgetSpan children',
        (tester) async {
      SelectedContent? content;
      await tester.pumpWidget(host(
        WindfoilRichText(
          text: const TextSpan(style: style, children: [
            TextSpan(text: 'before '),
            WidgetSpan(child: Text('chip', style: style)),
            TextSpan(text: ' after'),
          ]),
        ),
        onChanged: (c) => content = c,
      ));
      // Click to focus the selection region, then Ctrl+A.
      await tester.tapAt(tester.getCenter(find.byType(SelectionArea)),
          kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(content?.plainText, contains('before'));
      expect(content?.plainText, contains('chip'));
      expect(content?.plainText, contains('after'));
    });

    testWidgets('selection highlight paints rects', (tester) async {
      await tester.pumpWidget(host(
        WindfoilRichText(
            text: const TextSpan(text: 'hello world', style: style)),
      ));
      final render = tester.renderObject(find.byType(WindfoilRichText))
          as RenderWindfoilParagraph;
      Offset globalCaret(int offset) => render.localToGlobal(
          render.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
              const Offset(0, 10));
      final gesture = await tester.startGesture(globalCaret(1),
          kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(globalCaret(9));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      // The paragraph paints at least one selection rect.
      expect(render.debugNeedsPaint, isFalse);
      expect(
        find.byType(WindfoilRichText),
        paints..rect(),
      );
    });
  });
}
