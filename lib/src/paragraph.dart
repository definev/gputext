// Paragraph layout: styled runs + inline placeholders → wrapped lines
// (metrics only) → glyph instances + placeholder boxes.
//
// Split in two phases so widget layout stays pure CPU with font metrics only:
//   breakLines()    — greedy word-wrap, per-line hhea metrics, intrinsic widths.
//   emitInstances() — 16-float shader instances + ink bounds + placeholder
//                     boxes. Pass a null GlyphTable for a metrics-only pen
//                     walk (placeholder positioning at layout time).
// layoutParagraph() is the one-shot convenience the demo scene uses.
//
// This file stays VM-pure (no dart:ui / Flutter imports) so scenes can be
// built headless; InlinePlaceholderAlignment mirrors ui.PlaceholderAlignment.

import 'dart:typed_data';

import 'bands.dart';
import 'font.dart';
import 'layout.dart';

enum TextAlign { left, center, right, justify }

/// Mirror of ui.TextDecorationStyle (VM-pure).
enum InlineDecorationStyle { solid, doubleLine, dotted, dashed, wavy }

/// Which decoration guides a run draws, and how.
class InlineDecoration {
  const InlineDecoration({
    this.underline = false,
    this.overline = false,
    this.lineThrough = false,
    this.color,
    this.style = InlineDecorationStyle.solid,
    this.thickness = 1,
  });

  final bool underline;
  final bool overline;
  final bool lineThrough;

  /// RGBA 0..1; null → the run's text color.
  final List<double>? color;
  final InlineDecorationStyle style;

  /// Multiplier on the font's decoration thickness.
  final double thickness;

  bool get isActive => underline || overline || lineThrough;
}

/// One resolved decoration stroke in layout space; `y` is the stroke center.
class DecorationLine {
  const DecorationLine({
    required this.x,
    required this.y,
    required this.width,
    required this.thickness,
    required this.color,
    required this.style,
    required this.aboveText,
  });

  final double x;
  final double y;
  final double width;
  final double thickness;
  final List<double> color;
  final InlineDecorationStyle style;

  /// lineThrough paints over the glyphs; under/overline paint beneath them.
  final bool aboveText;
}

/// Mirror of ui.PlaceholderAlignment (kept local so this file has no
/// dart:ui dependency).
enum InlinePlaceholderAlignment {
  baseline,
  aboveBaseline,
  belowBaseline,
  top,
  middle,
  bottom,
}

/// Resolves a glyph's band-table entry for a (font, char) pair.
abstract class GlyphTable {
  GlyphTableEntry? lookup(WindfoilFont font, String ch);
}

/// Adapter over the single-font table produced by buildGlyphAtlas.
class SingleFontGlyphTable implements GlyphTable {
  const SingleFontGlyphTable(this.font, this.table);

  final WindfoilFont font;
  final Map<String, GlyphTableEntry> table;

  @override
  GlyphTableEntry? lookup(WindfoilFont f, String ch) =>
      identical(f, font) ? table[ch] : null;
}

/// One inline content item: a styled text run or an embedded-widget
/// placeholder.
sealed class InlineItem {
  const InlineItem();
}

class TextRun extends InlineItem {
  const TextRun({
    required this.text,
    required this.font,
    required this.fontSizePx,
    required this.color,
    this.letterSpacingPx = 0,
    this.wordSpacingPx = 0,
    this.height,
    this.decoration,
    this.fillRule = FillRule.nonzero,
  });

  final String text;
  final WindfoilFont font;
  final double fontSizePx;
  final List<double> color;
  final double letterSpacingPx;
  final double wordSpacingPx;

  /// Line-height multiplier (TextStyle.height semantics): when set, the run
  /// contributes height*fontSizePx of line extent, distributed between
  /// ascent and descent proportionally to the font's natural metrics.
  final double? height;

  final InlineDecoration? decoration;
  final FillRule fillRule;
}

/// An inline widget's reserved box: unbreakable, contributes to line metrics
/// per its alignment. `index` is the placeholder's preorder position in the
/// span tree (matches WidgetSpan.extractFromInlineSpan child order).
class PlaceholderItem extends InlineItem {
  const PlaceholderItem({
    required this.index,
    required this.width,
    required this.height,
    required this.alignment,
    this.baselineOffset,
  });

  final int index;
  final double width;
  final double height;
  final InlinePlaceholderAlignment alignment;

  /// Distance from the placeholder's top to its baseline; only meaningful for
  /// [InlinePlaceholderAlignment.baseline] (falls back to height).
  final double? baselineOffset;
}

class ParagraphStyle {
  const ParagraphStyle({
    this.maxWidth = double.infinity,
    this.align = TextAlign.left,
    this.lineHeight = 1.0,
    this.maxLines,
    this.addEllipsis = false,
  });

  final double maxWidth;
  final TextAlign align;
  final double lineHeight;
  final int? maxLines;
  final bool addEllipsis;
}

sealed class LineItem {
  double get width;
}

class LineRun extends LineItem {
  LineRun({
    required this.text,
    required this.font,
    required this.fontSizePx,
    required this.color,
    required this.letterSpacingPx,
    required this.fillRule,
    required this.width,
    this.wordSpacingPx = 0,
    this.decoration,
  });

  LineRun.fromRun(TextRun run, this.text, this.width)
      : font = run.font,
        fontSizePx = run.fontSizePx,
        color = run.color,
        letterSpacingPx = run.letterSpacingPx,
        wordSpacingPx = run.wordSpacingPx,
        decoration = run.decoration,
        fillRule = run.fillRule;

  String text;
  final WindfoilFont font;
  final double fontSizePx;
  final List<double> color;
  final double letterSpacingPx;
  final double wordSpacingPx;
  final InlineDecoration? decoration;
  final FillRule fillRule;
  @override
  double width;

  bool get isSpace => text == ' ';
}

class LinePlaceholder extends LineItem {
  LinePlaceholder(this.item);

  final PlaceholderItem item;

  @override
  double get width => item.width;
}

class LineMetrics {
  final items = <LineItem>[];
  double width = 0; // trailing spaces excluded (alignment box width)
  double ascent = 0;
  double descent = 0;
  double height = 0; // baseline-to-baseline advance to the next line

  /// True when the line ends at a '\n' or the end of the paragraph (justify
  /// never stretches these).
  bool hardBreak = false;

  /// top/middle/bottom placeholders, resolved against the final text metrics
  /// when the line is committed.
  final _deferred = <PlaceholderItem>[];
}

class ParagraphLines {
  ParagraphLines({
    required this.lines,
    required this.minIntrinsicWidth,
    required this.maxIntrinsicWidth,
    required this.height,
    required this.didExceedMaxLines,
    required this.ellipsized,
  });

  final List<LineMetrics> lines;
  final double minIntrinsicWidth; // widest single word / placeholder
  final double maxIntrinsicWidth; // widest unwrapped (hard-break) line
  final double height;
  final bool didExceedMaxLines;
  final bool ellipsized;

  /// Distance from the paragraph top to the first baseline.
  double get firstBaseline => lines.isEmpty ? 0 : lines.first.ascent;
}

double _measure(WindfoilFont font, String text, double sizePx, double ls) {
  if (text.isEmpty) return 0;
  return measureText(text, font, sizePx) + ls * text.runes.length;
}

double _lineHeightPx(WindfoilFont font, double sizePx, double lineHeight) {
  final m = font.verticalMetrics;
  return (m.ascender - m.descender + m.lineGap) /
      font.unitsPerEm *
      sizePx *
      lineHeight;
}

double _ascenderPx(WindfoilFont font, double sizePx) =>
    font.verticalMetrics.ascender / font.unitsPerEm * sizePx;

double _descenderPx(WindfoilFont font, double sizePx) =>
    -font.verticalMetrics.descender / font.unitsPerEm * sizePx;

List<String> _splitWords(String text) {
  final words = <String>[];
  final buf = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch == '\n' || ch == ' ') {
      if (buf.isNotEmpty) words.add(buf.toString());
      words.add(ch);
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  if (buf.isNotEmpty) words.add(buf.toString());
  return words;
}

ParagraphLines breakLines(
  List<InlineItem> runs,
  double wrapWidth,
  ParagraphStyle style,
) {
  final lines = <LineMetrics>[];
  var line = LineMetrics();
  var lineWidth = 0.0; // includes trailing spaces
  var minIntrinsic = 0.0;
  var maxIntrinsic = 0.0;
  var hardLineWidth = 0.0; // current unwrapped (hard-break) segment width
  TextRun? current; // style source for empty-line metrics

  void growMetrics(LineMetrics l, TextRun run) {
    var a = _ascenderPx(run.font, run.fontSizePx);
    var d = _descenderPx(run.font, run.fontSizePx);
    var h = _lineHeightPx(run.font, run.fontSizePx, style.lineHeight);
    final hm = run.height;
    if (hm != null && a + d > 0) {
      // TextStyle.height semantics: the run's line extent becomes
      // height*fontSize, split proportionally to the natural ascent/descent.
      final target = hm * run.fontSizePx * style.lineHeight;
      final f = target / (a + d);
      a *= f;
      d *= f;
      h = target;
    }
    if (a > l.ascent) l.ascent = a;
    if (d > l.descent) l.descent = d;
    if (h > l.height) l.height = h;
  }

  void growPlaceholderMetrics(LineMetrics l, PlaceholderItem p) {
    switch (p.alignment) {
      case InlinePlaceholderAlignment.baseline:
        final a = p.baselineOffset ?? p.height;
        if (a > l.ascent) l.ascent = a;
        final d = p.height - a;
        if (d > l.descent) l.descent = d;
      case InlinePlaceholderAlignment.aboveBaseline:
        if (p.height > l.ascent) l.ascent = p.height;
      case InlinePlaceholderAlignment.belowBaseline:
        if (p.height > l.descent) l.descent = p.height;
      case InlinePlaceholderAlignment.top:
      case InlinePlaceholderAlignment.middle:
      case InlinePlaceholderAlignment.bottom:
        l._deferred.add(p); // needs the line's final text metrics
    }
  }

  void commitLine({bool hard = false}) {
    line.hardBreak = hard;
    // Box-relative placeholders grow the line box only if they don't fit.
    for (final p in line._deferred) {
      final box = line.ascent + line.descent;
      switch (p.alignment) {
        case InlinePlaceholderAlignment.top:
          if (p.height > box) line.descent = p.height - line.ascent;
        case InlinePlaceholderAlignment.bottom:
          if (p.height > box) line.ascent = p.height - line.descent;
        case InlinePlaceholderAlignment.middle:
          final extra = p.height - box;
          if (extra > 0) {
            line.ascent += extra / 2;
            line.descent += extra / 2;
          }
        default:
          break;
      }
    }
    final box = line.ascent + line.descent;
    if (box > line.height) line.height = box;

    // Trailing spaces don't count toward the alignment box.
    var w = lineWidth;
    for (var i = line.items.length - 1; i >= 0; i--) {
      final item = line.items[i];
      if (item is LineRun && item.isSpace) {
        w -= item.width;
      } else {
        break;
      }
    }
    line.width = w;
    final cur = current;
    if (line.items.isEmpty && cur != null) growMetrics(line, cur);
    lines.add(line);
    line = LineMetrics();
    lineWidth = 0.0;
  }

  for (final item in runs) {
    if (item is PlaceholderItem) {
      final w = item.width;
      hardLineWidth += w;
      if (w > minIntrinsic) minIntrinsic = w;
      if (lineWidth + w > wrapWidth && line.items.isNotEmpty) {
        commitLine();
      }
      line.items.add(LinePlaceholder(item));
      lineWidth += w;
      growPlaceholderMetrics(line, item);
      continue;
    }
    final run = item as TextRun;
    current = run;
    for (final word in _splitWords(run.text)) {
      if (word == '\n') {
        commitLine(hard: true);
        if (hardLineWidth > maxIntrinsic) maxIntrinsic = hardLineWidth;
        hardLineWidth = 0.0;
        continue;
      }
      if (word == ' ') {
        final w =
            _measure(run.font, ' ', run.fontSizePx, run.letterSpacingPx) +
                run.wordSpacingPx;
        hardLineWidth += w;
        if (lineWidth + w > wrapWidth && line.items.isNotEmpty) {
          commitLine();
          continue; // drop the space at the wrap point
        }
        line.items.add(LineRun.fromRun(run, ' ', w));
        lineWidth += w;
        growMetrics(line, run);
        continue;
      }
      final w = _measure(run.font, word, run.fontSizePx, run.letterSpacingPx);
      hardLineWidth += w;
      if (w > minIntrinsic) minIntrinsic = w;
      if (lineWidth + w > wrapWidth && line.items.isNotEmpty) {
        commitLine();
      }
      line.items.add(LineRun.fromRun(run, word, w));
      lineWidth += w;
      growMetrics(line, run);
    }
  }
  if (line.items.isNotEmpty || lines.isEmpty) commitLine(hard: true);
  if (hardLineWidth > maxIntrinsic) maxIntrinsic = hardLineWidth;

  final maxLines = style.maxLines;
  final exceeded = maxLines != null && lines.length > maxLines;
  final kept = exceeded ? lines.sublist(0, maxLines) : lines;

  var ellipsized = false;
  if (exceeded && style.addEllipsis && kept.isNotEmpty) {
    _ellipsize(kept.last, wrapWidth);
    ellipsized = true;
  }

  var height = 0.0;
  for (final l in kept) {
    height += l.height;
  }

  return ParagraphLines(
    lines: kept,
    minIntrinsicWidth: minIntrinsic,
    maxIntrinsicWidth: maxIntrinsic,
    height: height,
    didExceedMaxLines: exceeded,
    ellipsized: ellipsized,
  );
}

/// Baseline-to-baseline line advance for a font/size (public: widgets use it
/// to give empty text a sensible height).
double lineExtentOf(WindfoilFont font, double sizePx, [double lineHeight = 1]) =>
    _lineHeightPx(font, sizePx, lineHeight);

/// Public entry to [_ellipsize] (used for softWrap:false + ellipsis overflow).
void ellipsizeLine(LineMetrics line, double maxWidth) =>
    _ellipsize(line, maxWidth);

/// Trim the line's tail and append an ellipsis in the last text run's style
/// so the line fits `maxWidth` (best effort — a lone ellipsis is never
/// removed). Placeholders at the cut are dropped whole.
void _ellipsize(LineMetrics line, double maxWidth) {
  final lastRun = line.items.whereType<LineRun>().lastOrNull;
  if (lastRun == null && line.items.isEmpty) return;
  final font = lastRun?.font;
  if (font == null) {
    // Placeholder-only line: drop trailing placeholders until it fits.
    while (line.items.length > 1 &&
        line.items.fold<double>(0, (w, i) => w + i.width) > maxWidth) {
      line.items.removeLast();
    }
    line.width = line.items.fold<double>(0, (w, i) => w + i.width);
    return;
  }
  final ell = font.hasGlyph('…') ? '…' : '...';
  final ellRun = LineRun(
    text: ell,
    font: font,
    fontSizePx: lastRun!.fontSizePx,
    color: lastRun.color,
    letterSpacingPx: lastRun.letterSpacingPx,
    fillRule: lastRun.fillRule,
    width: _measure(font, ell, lastRun.fontSizePx, lastRun.letterSpacingPx),
    wordSpacingPx: lastRun.wordSpacingPx,
    decoration: lastRun.decoration,
  );

  double total() =>
      line.items.fold<double>(0, (w, r) => w + r.width) + ellRun.width;

  while (line.items.isNotEmpty && total() > maxWidth) {
    final r = line.items.last;
    if (r is! LineRun || r.text.length <= 1) {
      line.items.removeLast();
      continue;
    }
    r.text = r.text.substring(0, r.text.length - 1);
    r.width = _measure(r.font, r.text, r.fontSizePx, r.letterSpacingPx);
  }
  // Strip a trailing space left at the cut.
  while (line.items.isNotEmpty) {
    final r = line.items.last;
    if (r is LineRun && r.isSpace) {
      line.items.removeLast();
    } else {
      break;
    }
  }
  line.items.add(ellRun);
  line.width = line.items.fold<double>(0, (w, r) => w + r.width);
}

/// An inline placeholder's resolved rect in layout space.
class PlaceholderBox {
  const PlaceholderBox({
    required this.index,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final int index;
  final double left;
  final double top;
  final double width;
  final double height;
}

class ParagraphInstances {
  ParagraphInstances({
    required this.instances,
    required this.inkBounds,
    this.placeholders = const [],
    this.decorations = const [],
  });

  final Float32List instances;

  /// Union of glyph ink boxes in layout space, or null when nothing inked.
  /// Placeholder boxes are NOT included (their widgets paint themselves).
  final LayoutBounds? inkBounds;

  /// Resolved placeholder rects, in logical order of appearance.
  final List<PlaceholderBox> placeholders;

  /// Underline/overline/lineThrough strokes in layout space.
  final List<DecorationLine> decorations;

  int get glyphCount => instances.length ~/ floatsPerInstance;
}

/// Walk the pen across `para`'s lines. With a [table], emits glyph instances;
/// with `table == null` this is a metrics-only walk that still resolves
/// placeholder boxes (used at widget-layout time, before any GPU work).
ParagraphInstances emitInstances(
  ParagraphLines para,
  double boxWidth,
  TextAlign align,
  GlyphTable? table, {
  double x = 0,
  double top = 0,
}) {
  final out = <double>[];
  final placeholders = <PlaceholderBox>[];
  final decorations = <DecorationLine>[];
  var y = top;
  var inkMinX = double.infinity, inkMinY = double.infinity;
  var inkMaxX = -double.infinity, inkMaxY = -double.infinity;

  for (final line in para.lines) {
    final offset = switch (align) {
      TextAlign.left || TextAlign.justify => 0.0,
      TextAlign.center => (boxWidth - line.width) * 0.5,
      TextAlign.right => boxWidth - line.width,
    };

    // Justify: distribute the leftover width across non-trailing spaces.
    // Hard-broken and ellipsized last lines keep their natural spacing.
    var spaceExtra = 0.0;
    var stretchable = 0;
    if (align == TextAlign.justify &&
        !line.hardBreak &&
        !(para.ellipsized && identical(line, para.lines.last))) {
      var end = line.items.length;
      while (end > 0) {
        final it = line.items[end - 1];
        if (it is LineRun && it.isSpace) {
          end--;
        } else {
          break;
        }
      }
      for (var i = 0; i < end; i++) {
        final it = line.items[i];
        if (it is LineRun && it.isSpace) stretchable++;
      }
      final extra = boxWidth - line.width;
      if (stretchable > 0 && extra > 0 && extra.isFinite) {
        spaceExtra = extra / stretchable;
      }
    }

    final baselineY = y + line.ascent;
    var pen = x + offset;
    String? prev;
    WindfoilFont? prevFont;
    var stretched = 0;

    for (final item in line.items) {
      if (item is LinePlaceholder) {
        final p = item.item;
        final h = p.height;
        final boxTop = switch (p.alignment) {
          InlinePlaceholderAlignment.baseline =>
            baselineY - (p.baselineOffset ?? h),
          InlinePlaceholderAlignment.aboveBaseline => baselineY - h,
          InlinePlaceholderAlignment.belowBaseline => baselineY,
          InlinePlaceholderAlignment.top => y,
          InlinePlaceholderAlignment.bottom =>
            y + line.ascent + line.descent - h,
          InlinePlaceholderAlignment.middle =>
            y + (line.ascent + line.descent - h) / 2,
        };
        placeholders.add(PlaceholderBox(
          index: p.index,
          left: pen,
          top: boxTop,
          width: p.width,
          height: h,
        ));
        pen += p.width;
        prev = null;
        prevFont = null;
        continue;
      }
      final run = item as LineRun;
      final scale = run.fontSizePx / run.font.unitsPerEm;
      final rule = run.fillRule == FillRule.evenOdd ? 1.0 : 0.0;
      final color = run.color;
      final a = color.length > 3 ? color[3] : 1.0;
      final penStart = pen;
      for (final rune in run.text.runes) {
        if (isZeroWidthCodePoint(rune)) continue;
        final ch = String.fromCharCode(rune);
        if (prev != null && identical(prevFont, run.font)) {
          pen += run.font.kerningOf(prev, ch) * scale;
        }
        final gl = table?.lookup(run.font, ch);
        if (gl != null) {
          out.addAll([
            pen, baselineY, scale, rule,
            gl.bbox[0], gl.bbox[1], gl.bbox[2], gl.bbox[3],
            color[0], color[1], color[2], a,
            gl.rowBase.toDouble(), gl.bandCount.toDouble(), gl.y0, gl.invH,
          ]);
          final gx0 = pen + gl.bbox[0] * scale;
          final gx1 = pen + gl.bbox[2] * scale;
          final gy0 = baselineY + gl.bbox[1] * scale;
          final gy1 = baselineY + gl.bbox[3] * scale;
          if (gx0 < inkMinX) inkMinX = gx0;
          if (gx1 > inkMaxX) inkMaxX = gx1;
          if (gy0 < inkMinY) inkMinY = gy0;
          if (gy1 > inkMaxY) inkMaxY = gy1;
        }
        pen += run.font.advanceOf(ch) * scale + run.letterSpacingPx;
        if (ch == ' ') pen += run.wordSpacingPx;
        prev = ch;
        prevFont = run.font;
      }
      if (run.isSpace && stretched < stretchable) {
        pen += spaceExtra; // justified gap, covered by decorations below
        stretched++;
      }

      final deco = run.decoration;
      if (deco != null && deco.isActive && pen > penStart) {
        final m = run.font.decorationMetrics;
        final decoColor = deco.color ?? run.color;
        void addLine(double yCenter, double thickness, bool aboveText) {
          decorations.add(DecorationLine(
            x: penStart,
            y: yCenter,
            width: pen - penStart,
            thickness: thickness * deco.thickness,
            color: decoColor,
            style: deco.style,
            aboveText: aboveText,
          ));
        }

        final underTh = m.underlineThickness * scale;
        if (deco.underline) {
          // underlinePosition is Y-up (negative below baseline) → Y-down.
          addLine(baselineY - m.underlinePosition * scale + underTh / 2,
              underTh, false);
        }
        if (deco.overline) {
          addLine(
              baselineY - _ascenderPx(run.font, run.fontSizePx) + underTh / 2,
              underTh,
              false);
        }
        if (deco.lineThrough) {
          addLine(baselineY - m.strikeoutPosition * scale,
              m.strikeoutSize * scale, true);
        }
      }
    }
    y += line.height;
  }

  return ParagraphInstances(
    instances: Float32List.fromList(out),
    inkBounds: inkMinX.isFinite
        ? LayoutBounds(
            minX: inkMinX, minY: inkMinY, maxX: inkMaxX, maxY: inkMaxY)
        : null,
    placeholders: placeholders,
    decorations: decorations,
  );
}

/// One-shot convenience: wrap against style.maxWidth, align against it too,
/// and return flat instances + the block's layout bounds (demo-scene shape).
LayoutResult layoutParagraph(
  List<InlineItem> runs,
  GlyphTable table,
  ParagraphStyle style, {
  required double x,
  required double top,
}) {
  final para = breakLines(runs, style.maxWidth, style);
  final emitted = emitInstances(para, style.maxWidth, style.align, table,
      x: x, top: top);
  var maxRight = x;
  for (final line in para.lines) {
    final offset = switch (style.align) {
      TextAlign.left || TextAlign.justify => 0.0,
      TextAlign.center => (style.maxWidth - line.width) * 0.5,
      TextAlign.right => style.maxWidth - line.width,
    };
    final right = x + offset + line.width;
    if (right > maxRight) maxRight = right;
  }
  return LayoutResult(
    instances: emitted.instances.toList(),
    bounds: LayoutBounds(
        minX: x, minY: top, maxX: maxRight, maxY: top + para.height),
  );
}

LayoutResult mergeLayouts(List<LayoutResult> parts) {
  final instances = <double>[];
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = -double.infinity;
  var maxY = -double.infinity;
  for (final part in parts) {
    instances.addAll(part.instances);
    minX = minX < part.bounds.minX ? minX : part.bounds.minX;
    minY = minY < part.bounds.minY ? minY : part.bounds.minY;
    maxX = maxX > part.bounds.maxX ? maxX : part.bounds.maxX;
    maxY = maxY > part.bounds.maxY ? maxY : part.bounds.maxY;
  }
  return LayoutResult(
    instances: instances,
    bounds: LayoutBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY),
  );
}
