import 'dart:io';
import 'dart:ui' as ui show PlaceholderAlignment;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:windfoil_flutter/src/engine/engine.dart';
import 'package:windfoil_flutter/src/engine/shared_atlas.dart';
import 'package:windfoil_flutter/src/font.dart';
import 'package:windfoil_flutter/src/paragraph.dart' as wf;
import 'package:windfoil_flutter/src/widgets/span_flattener.dart';

void main() {
  late WindfoilFont font;

  setUpAll(() {
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    font = WindfoilFont.parse(bytes);
  });

  wf.TextRun run(String text, {double size = 16}) => wf.TextRun(
        text: text,
        font: font,
        fontSizePx: size,
        color: const [0, 0, 0, 1],
      );

  test('wraps greedily and reports intrinsic widths', () {
    final para = wf.breakLines(
        [run('aaa bbb ccc ddd')], 60, const wf.ParagraphStyle(maxWidth: 60));
    expect(para.lines.length, greaterThan(1));
    for (final line in para.lines) {
      expect(line.width, lessThanOrEqualTo(60.01));
    }
    expect(para.minIntrinsicWidth, greaterThan(0));
    expect(para.minIntrinsicWidth, lessThanOrEqualTo(para.maxIntrinsicWidth));

    final unwrapped = wf.breakLines(
        [run('aaa bbb ccc ddd')], double.infinity, const wf.ParagraphStyle());
    expect(unwrapped.lines.length, 1);
    expect(unwrapped.maxIntrinsicWidth,
        closeTo(unwrapped.lines.single.width, 0.01));
  });

  test('maxLines truncates; ellipsis appended within the wrap width', () {
    final para = wf.breakLines(
      [run('aaa bbb ccc ddd eee fff ggg')],
      60,
      const wf.ParagraphStyle(maxWidth: 60, maxLines: 2, addEllipsis: true),
    );
    expect(para.lines.length, 2);
    expect(para.didExceedMaxLines, isTrue);
    expect(para.ellipsized, isTrue);
    expect((para.lines.last.items.last as wf.LineRun).text, anyOf('…', '...'));
    expect(para.lines.last.width, lessThanOrEqualTo(60.01));
  });

  test('hard newlines produce empty lines with nonzero height', () {
    final para =
        wf.breakLines([run('a\n\nb')], double.infinity, const wf.ParagraphStyle());
    expect(para.lines.length, 3);
    expect(para.lines[1].items, isEmpty);
    expect(para.lines[1].height, greaterThan(0));
    expect(para.height,
        closeTo(para.lines.fold<double>(0, (h, l) => h + l.height), 1e-9));
  });

  test('trailing spaces are excluded from the alignment width', () {
    final spaced = wf.breakLines(
        [run('ab   ')], double.infinity, const wf.ParagraphStyle());
    final bare =
        wf.breakLines([run('ab')], double.infinity, const wf.ParagraphStyle());
    expect(spaced.lines.single.width, closeTo(bare.lines.single.width, 1e-6));
  });

  test('emitInstances aligns against the box width and reports ink bounds',
      () {
    final atlas = SharedGlyphAtlas();
    atlas.ensureGlyphs(font, 'ab');
    final para =
        wf.breakLines([run('ab')], double.infinity, const wf.ParagraphStyle());
    final left = wf.emitInstances(para, 200, wf.TextAlign.left, atlas);
    final center = wf.emitInstances(para, 200, wf.TextAlign.center, atlas);
    final right = wf.emitInstances(para, 200, wf.TextAlign.right, atlas);
    expect(left.glyphCount, 2);
    final lineW = para.lines.single.width;
    expect(center.inkBounds!.minX - left.inkBounds!.minX,
        closeTo((200 - lineW) / 2, 0.5));
    expect(right.inkBounds!.maxX, lessThanOrEqualTo(200.01));
    // Ink stays within one line of vertical extent.
    expect(left.inkBounds!.maxY - left.inkBounds!.minY,
        lessThanOrEqualTo(para.lines.single.height * 1.5));
  });

  test('atlas growth keeps earlier entries stable', () {
    final atlas = SharedGlyphAtlas();
    atlas.ensureGlyphs(font, 'ab');
    final a1 = atlas.lookup(font, 'a')!;
    final gen1 = atlas.generation;
    atlas.ensureGlyphs(font, 'xyz…');
    expect(atlas.generation, greaterThan(gen1));
    final a2 = atlas.lookup(font, 'a')!;
    expect(identical(a1, a2), isTrue);
    expect(atlas.lookup(font, '…'), isNotNull);
    // Re-ensuring known glyphs must not grow the atlas.
    final gen2 = atlas.generation;
    atlas.ensureGlyphs(font, 'abxyz');
    expect(atlas.generation, gen2);
  });

  test('placeholders wrap as unbreakable boxes and set line metrics', () {
    final items = <wf.InlineItem>[
      run('aa '),
      const wf.PlaceholderItem(
        index: 0,
        width: 50,
        height: 30,
        alignment: wf.InlinePlaceholderAlignment.baseline,
        baselineOffset: 24,
      ),
      run(' bb'),
    ];
    final para =
        wf.breakLines(items, double.infinity, const wf.ParagraphStyle());
    expect(para.lines.length, 1);
    expect(para.lines.single.ascent, greaterThanOrEqualTo(24));
    expect(para.lines.single.descent, greaterThanOrEqualTo(6));

    final emitted = wf.emitInstances(para, 400, wf.TextAlign.left, null);
    expect(emitted.placeholders.single.index, 0);
    final baselineY = para.lines.single.ascent;
    expect(emitted.placeholders.single.top, closeTo(baselineY - 24, 1e-6));
    expect(emitted.placeholders.single.width, 50);

    // A narrow wrap width forces the placeholder onto its own line.
    final wrapped =
        wf.breakLines(items, 55, const wf.ParagraphStyle(maxWidth: 55));
    expect(wrapped.lines.length, greaterThanOrEqualTo(2));
    // Tall middle-aligned placeholder grows the line box.
    final tall = wf.breakLines([
      run('x'),
      const wf.PlaceholderItem(
        index: 0,
        width: 10,
        height: 60,
        alignment: wf.InlinePlaceholderAlignment.middle,
      ),
    ], double.infinity, const wf.ParagraphStyle());
    expect(tall.lines.single.ascent + tall.lines.single.descent,
        greaterThanOrEqualTo(60));
  });

  test('flattenSpan maps PlaceholderSpans to indexed placeholder items', () {
    Windfoil.instance.registerFont('Lato', font);
    final items = flattenSpan(
      const TextSpan(
        style: TextStyle(fontFamily: 'Lato', fontSize: 16),
        children: [
          TextSpan(text: 'a'),
          WidgetSpan(child: SizedBox(width: 5, height: 5)),
          TextSpan(text: 'b'),
          WidgetSpan(
            alignment: ui.PlaceholderAlignment.middle,
            child: SizedBox(width: 5, height: 5),
          ),
        ],
      ),
      TextScaler.noScaling,
      Windfoil.instance,
      placeholderDimensions: const [
        PlaceholderDimensions(
            size: Size(20, 10), alignment: ui.PlaceholderAlignment.bottom),
        PlaceholderDimensions(
            size: Size(30, 12), alignment: ui.PlaceholderAlignment.middle),
      ],
    );
    expect(items, isNotNull);
    final placeholders = items!.whereType<wf.PlaceholderItem>().toList();
    expect(placeholders.length, 2);
    expect(placeholders[0].index, 0);
    expect(placeholders[0].width, 20);
    expect(placeholders[1].index, 1);
    expect(placeholders[1].alignment, wf.InlinePlaceholderAlignment.middle);
  });

  test('flattenSpan applies the style cascade and text scaling', () {
    Windfoil.instance.registerFont('Lato', font);
    final runs = flattenSpan(
      const TextSpan(
        style: TextStyle(
            fontFamily: 'Lato', fontSize: 20, color: Color(0xFF112233)),
        children: [
          TextSpan(text: 'a'),
          TextSpan(text: 'b', style: TextStyle(fontSize: 30)),
        ],
      ),
      const TextScaler.linear(2),
      Windfoil.instance,
    );
    expect(runs, isNotNull);
    expect(runs!.length, 2);
    final r0 = runs[0] as wf.TextRun;
    final r1 = runs[1] as wf.TextRun;
    expect(r0.fontSizePx, 40);
    expect(r1.fontSizePx, 60);
    expect(r0.color[0], closeTo(0x11 / 255, 1e-6));
    expect(r1.color[2], closeTo(0x33 / 255, 1e-6));
    expect(identical(r0.font, font), isTrue);
  });
}
