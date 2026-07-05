import 'dart:io';
import 'dart:ui' as ui show PlaceholderAlignment;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:windfoil_flutter/src/engine/engine.dart';
import 'package:windfoil_flutter/src/engine/shared_atlas.dart';
import 'package:windfoil_flutter/src/font.dart';
import 'package:windfoil_flutter/src/layout.dart' show measureText;
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

  test('justify stretches spaces on wrapped lines only', () {
    // 'aa bb' fits the wrap width; 'cc' wraps to a hard last line.
    final wAA = measureText('aa', font, 16);
    final wBB = measureText('bb', font, 16);
    final wSpace = measureText(' ', font, 16);
    final wrapW = wAA + wSpace + wBB + 2;
    final para = wf.breakLines([run('aa bb cc')], wrapW,
        wf.ParagraphStyle(maxWidth: wrapW, align: wf.TextAlign.justify));
    expect(para.lines.length, 2);
    expect(para.lines[0].hardBreak, isFalse);
    expect(para.lines[1].hardBreak, isTrue);

    final atlas = SharedGlyphAtlas()..ensureGlyphs(font, 'abc');
    final emitted =
        wf.emitInstances(para, wrapW, wf.TextAlign.justify, atlas);
    // First glyph of 'bb' (3rd glyph overall) starts at wrapW - width('bb').
    final bbX = emitted.instances[2 * 16];
    expect(bbX, closeTo(wrapW - wBB, 0.5));
  });

  test('TextStyle.height multiplier sets the line extent', () {
    final normal = wf.breakLines(
        [run('hello')], double.infinity, const wf.ParagraphStyle());
    final doubled = wf.breakLines([
      wf.TextRun(
        text: 'hello',
        font: font,
        fontSizePx: 16,
        color: const [0, 0, 0, 1],
        height: 2,
      ),
    ], double.infinity, const wf.ParagraphStyle());
    expect(doubled.height, closeTo(32, 0.001));
    expect(doubled.height, greaterThan(normal.height));
    final l = doubled.lines.single;
    expect(l.ascent + l.descent, closeTo(32, 0.001));
  });

  test('decorations emit per-kind strokes with sane geometry', () {
    final decorated = wf.TextRun(
      text: 'deco text',
      font: font,
      fontSizePx: 20,
      color: const [0, 0, 0, 1],
      decoration: const wf.InlineDecoration(
        underline: true,
        lineThrough: true,
        color: [1, 0, 0, 1],
        thickness: 2,
      ),
    );
    final para = wf.breakLines(
        [decorated], double.infinity, const wf.ParagraphStyle());
    final emitted = wf.emitInstances(para, 500, wf.TextAlign.left, null);
    final under = emitted.decorations.where((d) => !d.aboveText).toList();
    final over = emitted.decorations.where((d) => d.aboveText).toList();
    expect(under, isNotEmpty);
    expect(over, isNotEmpty);
    final baseline = para.lines.single.ascent;
    for (final d in under) {
      expect(d.y, greaterThan(baseline)); // underline below baseline
      expect(d.color[0], 1); // decorationColor red
      expect(d.width, greaterThan(0));
    }
    for (final d in over) {
      expect(d.y, lessThan(baseline)); // strike above baseline
    }
    // Segments tile the whole text: total decorated width ≈ line width.
    final totalUnder = under.fold<double>(0, (w, d) => w + d.width);
    expect(totalUnder, closeTo(para.lines.single.width, 0.5));
  });

  test('wordSpacing widens spaces', () {
    final spaced = wf.TextRun(
      text: 'a b c',
      font: font,
      fontSizePx: 16,
      color: const [0, 0, 0, 1],
      wordSpacingPx: 10,
    );
    final wide =
        wf.breakLines([spaced], double.infinity, const wf.ParagraphStyle());
    final narrow =
        wf.breakLines([run('a b c')], double.infinity, const wf.ParagraphStyle());
    expect(wide.lines.single.width - narrow.lines.single.width,
        closeTo(20, 0.001));
  });

  test('astral characters map to .notdef instead of vanishing', () {
    expect(font.advanceOf('🌚'), greaterThan(0));
    final para = wf.breakLines(
        [run('🌚a')], double.infinity, const wf.ParagraphStyle());
    // One notdef advance + one 'a' — not two surrogate halves.
    expect(
        para.lines.single.width,
        closeTo(
            (font.advanceOf('🌚') + font.advanceOf('a')) * 16 / font.unitsPerEm,
            0.5));
  });

  test('engine resolves nearest weight/style variant', () {
    final engine = Windfoil.instance;
    engine.registerFont('VarTest', font);
    engine.registerFont('VarTest', font, weight: FontWeight.w700);
    final regular = engine.resolveFont('VarTest');
    final bold = engine.resolveFont('VarTest', weight: FontWeight.w700);
    final heavy = engine.resolveFont('VarTest', weight: FontWeight.w900);
    expect(regular, isNotNull);
    expect(bold, isNotNull);
    expect(identical(heavy, bold), isTrue); // nearest weight wins
  });

  test('GPOS pair kerning is read (supersedes the legacy kern table)', () {
    expect(font.kerningOf('A', 'V'), lessThan(0));
    expect(font.kerningOf('T', 'o'), lessThan(0));
    expect(font.kerningOf('L', 'T'), lessThan(0));
    expect(font.kerningOf('a', 'b'), 0);
  });

  test('basic ligatures substitute when the font maps them', () {
    if (!font.hasGlyph('ﬁ')) return;
    expect(applyBasicLigatures('first', font), 'ﬁrst');
    expect(applyBasicLigatures('flow', font), 'ﬂow');
    expect(applyBasicLigatures('nope', font), 'nope');
  });

  test('hyphens create break opportunities', () {
    final wellW = measureText('well-', font, 16);
    final para = wf.breakLines(
        [run('well-known')], wellW + 1, wf.ParagraphStyle(maxWidth: wellW + 1));
    expect(para.lines.length, 2);
    expect((para.lines[0].items.last as wf.LineRun).text, 'well-');
    expect((para.lines[1].items.first as wf.LineRun).text, 'known');
  });

  test('flattenSpan maps decorations, height, and wordSpacing', () {
    Windfoil.instance.registerFont('Lato', font);
    final items = flattenSpan(
      const TextSpan(
        style: TextStyle(
          fontFamily: 'Lato',
          fontSize: 16,
          height: 1.5,
          wordSpacing: 4,
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.wavy,
          decorationColor: Color(0xFF00FF00),
          decorationThickness: 2,
        ),
        text: 'x',
      ),
      TextScaler.noScaling,
      Windfoil.instance,
    );
    final r = items!.single as wf.TextRun;
    expect(r.height, 1.5);
    expect(r.wordSpacingPx, 4);
    final d = r.decoration!;
    expect(d.underline, isTrue);
    expect(d.style, wf.InlineDecorationStyle.wavy);
    expect(d.thickness, 2);
    expect(d.color![1], closeTo(1, 1e-6));
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
