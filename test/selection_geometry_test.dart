// VM tests for the selection/caret geometry core: cluster maps through
// shaping, position↔offset round trips, ligature caret interpolation,
// justify-aware boxes, word/line boundaries, and paint-walk drift pinning.

import 'dart:io';

import 'package:flutter/widgets.dart' show TextScaler, TextSpan, TextStyle;
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/engine/engine.dart';
import 'package:gputext/src/engine/shared_atlas.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/paragraph.dart' as wf;
import 'package:gputext/src/widgets/span_flattener.dart';

void main() {
  late GPUFont font;

  setUpAll(() {
    font = GPUFont.parse(
        File('assets/Lato-Regular.ttf').readAsBytesSync());
    GPUText.instance.registerFont('Lato', font);
  });

  wf.TextRun run(String text, {double size = 16, double letterSpacing = 0}) =>
      wf.TextRun(
        text: text,
        font: font,
        fontSizePx: size,
        color: const [0, 0, 0, 1],
        letterSpacingPx: letterSpacing,
      );

  wf.ParagraphGeometry geometryOf(
    List<wf.InlineItem> items, {
    double width = double.infinity,
    wf.TextAlign align = wf.TextAlign.left,
    double boxWidth = 400,
  }) {
    final para = wf.breakLines(
        items, width, wf.ParagraphStyle(maxWidth: width, align: align));
    return wf.ParagraphGeometry(
        items: items, para: para, boxWidth: boxWidth, align: align);
  }

  group('cluster maps', () {
    test('shaping keeps identity for plain text', () {
      final (shaped, map) = font.applyFeaturesMapped('hello');
      expect(shaped, 'hello');
      expect(map, isNull);
    });

    test('ligatures map back to their source characters', () {
      final (shaped, map) = font.applyFeaturesMapped('first');
      // fi ligated into one cluster (a 2-unit PUA proxy).
      expect(shaped.runes.length, lessThan('first'.runes.length));
      expect(map, isNotNull);
      expect(map![0], 0);
      expect(map[shaped.length], 'first'.length);
      // The ligature's shaped boundary after the cluster maps to source 2.
      final ligUnits = shaped.runes.first >= 0x10000 ? 2 : 1;
      expect(map[ligUnits], 2);
    });

    test('flattener produces sourceText for ligated runs', () {
      final items = flattenSpan(
        const TextSpan(
            text: 'first',
            style: TextStyle(fontFamily: 'Lato', fontSize: 16)),
        TextScaler.noScaling,
        GPUText.instance,
      )!;
      final r = items.single as wf.TextRun;
      expect(r.originalText, 'first');
      expect(r.text, isNot('first'));
      expect(r.sourceOffsetAt(r.text.length), 5);
    });
  });

  group('position and caret', () {
    test('round-trips every boundary of a plain run', () {
      final g = geometryOf([run('hello world')]);
      expect(g.plainText, 'hello world');
      for (var o = 0; o <= g.length; o++) {
        final caret = g.caretAt(o);
        final pos = g.positionForOffset(caret.x, caret.top + 1);
        expect(pos.offset, o, reason: 'offset $o');
      }
    });

    test('caret x is monotonic and clicks snap to nearest boundary', () {
      final g = geometryOf([run('abc')]);
      final x0 = g.caretAt(0).x;
      final x1 = g.caretAt(1).x;
      final x2 = g.caretAt(2).x;
      expect(x1, greaterThan(x0));
      expect(x2, greaterThan(x1));
      // Clicking just left of x1 midpointward picks 1.
      expect(g.positionForOffset(x1 - 0.4, 5).offset, 1);
      // Clicking far past the end clamps to the last boundary.
      expect(g.positionForOffset(1000, 5).offset, 3);
      expect(g.positionForOffset(-1000, 5).offset, 0);
    });

    test('ligature carets divide the cluster advance', () {
      // Shape 'fi' into a single ligature glyph, then expect a caret
      // between f and i at half the ligature advance.
      final items = flattenSpan(
        const TextSpan(
            text: 'fi', style: TextStyle(fontFamily: 'Lato', fontSize: 16)),
        TextScaler.noScaling,
        GPUText.instance,
      )!;
      final r = items.single as wf.TextRun;
      expect(r.text.runes.length, 1, reason: 'expected a single lig cluster');
      final g = geometryOf(items);
      expect(g.plainText, 'fi');
      final x0 = g.caretAt(0).x;
      final x1 = g.caretAt(1).x;
      final x2 = g.caretAt(2).x;
      expect(x1, closeTo((x0 + x2) / 2, 0.01));
      // And clicking at 1/4 of the cluster selects boundary 1's side.
      expect(g.positionForOffset(x0 + (x2 - x0) * 0.4, 5).offset, 1);
      expect(g.positionForOffset(x0 + (x2 - x0) * 0.1, 5).offset, 0);
    });

    test('soft-wrapped line ends report upstream affinity', () {
      final g = geometryOf([run('aaa bbb')], width: 40, boxWidth: 40);
      expect(g.para.lines.length, 2);
      final endOfFirst = g.lineRange(0).end;
      final pos = g.positionForOffset(1000, g.lineTop(0) + 1);
      expect(pos.offset, endOfFirst);
      expect(pos.upstream, isTrue);
      // Same offset, both affinities → different lines.
      expect(g.caretAt(endOfFirst, upstream: true).line, 0);
      expect(g.caretAt(g.lineRange(1).start).line, 1);
    });
  });

  group('boxes and boundaries', () {
    test('boxesForRange tiles a single line', () {
      final g = geometryOf([run('hello')]);
      final boxes = g.boxesForRange(1, 4);
      expect(boxes, hasLength(1));
      expect(boxes.single.left, closeTo(g.caretAt(1).x, 0.01));
      expect(boxes.single.right, closeTo(g.caretAt(4).x, 0.01));
      expect(g.boxesForRange(2, 2), isEmpty);
    });

    test('boxesForRange spans wrapped lines', () {
      final g = geometryOf([run('aaa bbb ccc')], width: 45, boxWidth: 45);
      expect(g.para.lines.length, greaterThan(1));
      final boxes = g.boxesForRange(0, g.length);
      expect(boxes.length, g.para.lines.length);
      for (var i = 0; i < boxes.length; i++) {
        expect(boxes[i].top, closeTo(g.lineTop(i), 0.01));
        expect(boxes[i].right, greaterThan(boxes[i].left));
      }
    });

    test('newlines separate line ranges without being selectable-in-line',
        () {
      final g = geometryOf([run('ab\ncd')]);
      expect(g.para.lines.length, 2);
      expect(g.lineRange(0), (start: 0, end: 2));
      expect(g.lineRange(1), (start: 3, end: 5));
      // The caret for the newline offset itself sits at the end of line 0.
      expect(g.caretAt(2).line, 0);
      expect(g.caretAt(3).line, 1);
    });

    test('word ranges: words, whitespace runs, punctuation, CJK', () {
      const text = "don't stop 木木 now!";
      expect(wf.wordRangeIn(text, 2), (start: 0, end: 5)); // don't
      expect(wf.wordRangeIn(text, 5), (start: 5, end: 6)); // the space
      expect(wf.wordRangeIn(text, 7), (start: 6, end: 10)); // stop
      expect(wf.wordRangeIn(text, 11), (start: 11, end: 12)); // 木 (one)
      expect(wf.wordRangeIn(text, 16), (start: 14, end: 17)); // now
      expect(wf.wordRangeIn(text, 17), (start: 17, end: 18)); // !
    });
  });

  group('paint-walk drift pinning', () {
    test('geometry boundaries equal emitted glyph x positions', () {
      // Mixed sizes + justify + letterSpacing, wrapped: the geometry pen
      // walk must produce exactly the x positions paint uses.
      final items = <wf.InlineItem>[
        run('Veni vidi vici ', size: 16),
        run('AV To WA ', size: 24, letterSpacing: 1.5),
        run('the quick brown fox', size: 13),
      ];
      const width = 150.0;
      const align = wf.TextAlign.justify;
      final para = wf.breakLines(items, width,
          const wf.ParagraphStyle(maxWidth: width, align: align));
      final atlas = SharedGlyphAtlas();
      for (final i in items) {
        atlas.ensureGlyphs((i as wf.TextRun).font, i.text);
      }
      final emitted = wf.emitInstances(para, width, align, atlas);
      final g = wf.ParagraphGeometry(
          items: items, para: para, boxWidth: width, align: align);

      // Reconstruct expected glyph x's from geometry boundaries, in order.
      final expected = <double>[];
      for (var li = 0; li < para.lines.length; li++) {
        var itemPos = 0;
        for (final item in para.lines[li].items) {
          if (item is! wf.LineRun) continue;
          final placed = g.debugPlacedItems(li)[itemPos];
          final b = placed.$2;
          var u = 0;
          for (final rune in item.text.runes) {
            final units = rune >= 0x10000 ? 2 : 1;
            if (!isZeroWidthCodePoint(rune) &&
                rune != 0x20 &&
                atlas.lookup(item.font, String.fromCharCode(rune)) != null) {
              expected.add(b[u]);
            }
            u += units;
          }
          itemPos++;
        }
      }
      final actual = <double>[
        for (var k = 0; k < emitted.glyphCount; k++)
          emitted.instances[k * 16],
      ];
      expect(actual.length, expected.length);
      for (var k = 0; k < actual.length; k++) {
        // Instances are Float32; tolerate single-precision truncation only.
        expect(actual[k], closeTo(expected[k], 1e-3), reason: 'glyph $k');
      }
    });
  });
}
