// Paragraph layout: styled runs + inline placeholders → wrapped lines
// (metrics only) → glyph instances + placeholder boxes.
//
// Split in two phases, pretext-style (github.com/chenglou/pretext), so
// widget layout stays pure CPU with font metrics only:
//   prepareParagraph()    — width-INDEPENDENT analysis + measurement
//                           (text/prepare.dart): segment the runs, weld
//                           unbreakable clusters, measure once.
//   layoutPreparedLines() — cheap per-width pass: stream the greedy line
//                           walker (text/line_break.dart) and materialize
//                           LineMetrics/LineRun items per line.
//   emitInstances()       — 16-float shader instances + ink bounds +
//                           placeholder boxes. Pass a null GlyphTable for a
//                           metrics-only pen walk (placeholder positioning
//                           at layout time).
// breakLines() is the one-shot prepare+layout convenience; callers that
// relayout the same content at many widths should prepare once and call
// layoutPreparedLines() per width.
//
// This file stays VM-pure (no dart:ui / Flutter imports) so scenes can be
// built headless; InlinePlaceholderAlignment mirrors ui.PlaceholderAlignment.

import 'dart:typed_data';

import 'package:characters/characters.dart';

import 'bands.dart';
import 'font.dart';
import 'layout.dart';
import 'text/analysis.dart' show SegmentBreakKind;
import 'text/inline_items.dart';
import 'text/line_break.dart';
import 'text/line_breaker.dart';
import 'text/prepare.dart';

export 'text/inline_items.dart';
export 'text/line_breaker.dart';
export 'text/prepare.dart' show PreparedParagraph, prepareParagraph;

enum TextAlign { left, center, right, justify }

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

/// Resolves a glyph's band-table entry for a (font, char) pair.
abstract class GlyphTable {
  const GlyphTable();

  GlyphTableEntry? lookup(WindfoilFont font, String ch);

  /// Lookup by raw glyph ID (COLR emoji layers); tables that only key by
  /// character return null.
  GlyphTableEntry? lookupGlyphId(WindfoilFont font, int glyphId) => null;
}

/// Adapter over the single-font table produced by buildGlyphAtlas.
class SingleFontGlyphTable extends GlyphTable {
  const SingleFontGlyphTable(this.font, this.table);

  final WindfoilFont font;
  final Map<String, GlyphTableEntry> table;

  @override
  GlyphTableEntry? lookup(WindfoilFont f, String ch) =>
      identical(f, font) ? table[ch] : null;
}

class ParagraphStyle {
  const ParagraphStyle({
    this.maxWidth = double.infinity,
    this.align = TextAlign.left,
    this.lineHeight = 1.0,
    this.maxLines,
    this.addEllipsis = false,
    this.lineBreaker = LineBreaker.greedy,
  });

  final double maxWidth;
  final TextAlign align;
  final double lineHeight;
  final int? maxLines;
  final bool addEllipsis;

  /// Strategy that chooses where lines end (greedy by default; e.g.
  /// [KnuthPlassLineBreaker] for optimal justified paragraphs). Alignment,
  /// ellipsis, maxLines, and justify space distribution are applied on top
  /// of whatever breaks the strategy returns.
  final LineBreaker lineBreaker;
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
    this.source,
  });

  LineRun.fromRun(TextRun run, this.text, this.width)
      : font = run.font,
        fontSizePx = run.fontSizePx,
        color = run.color,
        letterSpacingPx = run.letterSpacingPx,
        wordSpacingPx = run.wordSpacingPx,
        decoration = run.decoration,
        source = run.source,
        fillRule = run.fillRule;

  String text;
  final WindfoilFont font;
  final double fontSizePx;
  final List<double> color;
  final double letterSpacingPx;
  final double wordSpacingPx;
  final InlineDecoration? decoration;
  final Object? source;
  final FillRule fillRule;
  @override
  double width;

  bool get isSpace => text == ' ';
}

class LineEmoji extends LineItem {
  LineEmoji(this.item);

  final EmojiItem item;

  @override
  double get width => item.width;
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

void _growMetrics(LineMetrics l, TextRun run, double styleLineHeight) {
  var a = _ascenderPx(run.font, run.fontSizePx);
  var d = _descenderPx(run.font, run.fontSizePx);
  var h = _lineHeightPx(run.font, run.fontSizePx, styleLineHeight);
  final hm = run.height;
  if (hm != null && a + d > 0) {
    // TextStyle.height semantics: the run's line extent becomes
    // height*fontSize, split proportionally to the natural ascent/descent.
    final target = hm * run.fontSizePx * styleLineHeight;
    final f = target / (a + d);
    a *= f;
    d *= f;
    h = target;
  }
  if (a > l.ascent) l.ascent = a;
  if (d > l.descent) l.descent = d;
  if (h > l.height) l.height = h;
}

void _growPlaceholderMetrics(LineMetrics l, PlaceholderItem p) {
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

/// Resolve deferred box-relative placeholders and the final line box height.
void _commitLineMetrics(LineMetrics line) {
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
}

/// One-shot prepare + layout. Callers that relayout the same content at many
/// widths (resize) should call [prepareParagraph] once and
/// [layoutPreparedLines] per width instead.
ParagraphLines breakLines(
  List<InlineItem> runs,
  double wrapWidth,
  ParagraphStyle style,
) =>
    layoutPreparedLines(prepareParagraph(runs), wrapWidth, style);

/// The cheap per-width half of the split: stream the line walker over the
/// prepared arrays and materialize LineMetrics. Pure arithmetic + string
/// slicing; no font-table measurement happens here.
ParagraphLines layoutPreparedLines(
  PreparedParagraph prepared,
  double wrapWidth,
  ParagraphStyle style,
) {
  final lines = <LineMetrics>[];
  final maxLines = style.maxLines;
  var exceeded = false;
  final lb = prepared.lineBreak;

  outer:
  for (var ci = 0; ci < lb.chunks.length; ci++) {
    final chunk = lb.chunks[ci];
    // Blank lines ('\n\n') are framework-level; strategies only see chunks
    // with content.
    final ranges = chunk.start == chunk.end
        ? <LineRange>[
            LineRange(
              width: 0,
              startSegment: chunk.start,
              startGrapheme: 0,
              endSegment: chunk.consumedEnd,
              endGrapheme: 0,
              hardBreak: true,
              chunkIndex: ci,
            ),
          ]
        : style.lineBreaker.breakChunk(
            lb,
            ci,
            wrapWidth,
            maxLines: maxLines == null ? null : maxLines - lines.length,
          );
    for (final range in ranges) {
      if (maxLines != null && lines.length >= maxLines) {
        exceeded = true;
        break outer;
      }
      lines.add(_materializeLine(prepared, range, style));
    }
  }

  if (lines.isEmpty) {
    // Empty paragraph: one empty line styled by the last run, like an empty
    // TextField line.
    final line = LineMetrics()..hardBreak = true;
    final styleItem = prepared.fallbackStyleItem;
    if (styleItem >= 0 && prepared.items[styleItem] is TextRun) {
      _growMetrics(
          line, prepared.items[styleItem] as TextRun, style.lineHeight);
    }
    _commitLineMetrics(line);
    lines.add(line);
  }

  var ellipsized = false;
  if (exceeded && style.addEllipsis) {
    _ellipsize(lines.last, wrapWidth);
    ellipsized = true;
  }

  var height = 0.0;
  for (final l in lines) {
    height += l.height;
  }

  return ParagraphLines(
    lines: lines,
    minIntrinsicWidth: prepared.minIntrinsicWidth,
    maxIntrinsicWidth: prepared.maxIntrinsicWidth,
    height: height,
    didExceedMaxLines: exceeded,
    ellipsized: ellipsized,
  );
}

LineMetrics _materializeLine(
  PreparedParagraph p,
  LineRange range,
  ParagraphStyle style,
) {
  final line = LineMetrics()..hardBreak = range.hardBreak;
  final lb = p.lineBreak;

  // The end cursor is exclusive; endGrapheme > 0 means the end segment is
  // partially on this line.
  final lastSeg =
      range.endGrapheme > 0 ? range.endSegment : range.endSegment - 1;

  for (var seg = range.startSegment;
      seg <= lastSeg && seg < p.segmentCount;
      seg++) {
    final kind = lb.kinds[seg];
    if (kind == SegmentBreakKind.hardBreak ||
        kind == SegmentBreakKind.softHyphen ||
        kind == SegmentBreakKind.zeroWidthBreak) {
      continue;
    }
    final pieces = p.segmentPieces[seg];
    if (pieces.isEmpty) continue;

    if (pieces.first.isAtomic) {
      final item = p.items[pieces.first.itemIndex];
      if (item is EmojiItem) {
        line.items.add(LineEmoji(item));
        final a = _ascenderPx(item.font, item.fontSizePx);
        final d = _descenderPx(item.font, item.fontSizePx);
        final h = _lineHeightPx(item.font, item.fontSizePx, style.lineHeight);
        if (a > line.ascent) line.ascent = a;
        if (d > line.descent) line.descent = d;
        if (h > line.height) line.height = h;
      } else if (item is PlaceholderItem) {
        line.items.add(LinePlaceholder(item));
        _growPlaceholderMetrics(line, item);
      }
      continue;
    }

    if (kind == SegmentBreakKind.space || kind == SegmentBreakKind.tab) {
      final ch = kind == SegmentBreakKind.space ? ' ' : '\t';
      for (final piece in pieces) {
        final run = p.items[piece.itemIndex] as TextRun;
        final count = piece.endInSegment - piece.startInSegment;
        final per = count > 0 ? piece.width / count : 0.0;
        for (var k = 0; k < count; k++) {
          line.items.add(LineRun.fromRun(run, ch, per));
        }
        _growMetrics(line, run, style.lineHeight);
      }
      continue;
    }

    // text / glue segments.
    final segText = p.segmentTexts[seg];
    final gStart = seg == range.startSegment ? range.startGrapheme : 0;
    final gEnd = (seg == range.endSegment && range.endGrapheme > 0)
        ? range.endGrapheme
        : -1;

    if (gStart == 0 && gEnd < 0) {
      for (final piece in pieces) {
        final run = p.items[piece.itemIndex] as TextRun;
        line.items.add(LineRun.fromRun(
          run,
          segText.substring(piece.startInSegment, piece.endInSegment),
          piece.width,
        ));
        _growMetrics(line, run, style.lineHeight);
      }
      continue;
    }

    // Partial segment (an overlong word broken mid-segment): slice by
    // grapheme boundaries, grouping consecutive graphemes per piece.
    final offs = p.graphemeEndOffsets[seg]!;
    final adv = lb.graphemeAdvances[seg]!;
    final gLast = gEnd < 0 ? adv.length : gEnd;
    var g = gStart;
    while (g < gLast) {
      final startOff = g == 0 ? 0 : offs[g - 1];
      final piece = pieces.firstWhere(
          (pc) => startOff >= pc.startInSegment && startOff < pc.endInSegment);
      var w = 0.0;
      var end = g;
      while (end < gLast) {
        final so = end == 0 ? 0 : offs[end - 1];
        if (so < piece.startInSegment || so >= piece.endInSegment) break;
        w += adv[end];
        end++;
      }
      final run = p.items[piece.itemIndex] as TextRun;
      line.items.add(
          LineRun.fromRun(run, segText.substring(startOff, offs[end - 1]), w));
      _growMetrics(line, run, style.lineHeight);
      g = end;
    }
  }

  // A soft wrap that lands right after a soft-hyphen segment chose that
  // hyphen: materialize the visible '-' (its width is already in
  // range.width).
  if (!range.hardBreak && range.endGrapheme == 0 && range.endSegment > 0) {
    final shySeg = range.endSegment - 1;
    if (shySeg < p.segmentCount &&
        lb.kinds[shySeg] == SegmentBreakKind.softHyphen) {
      final pieces = p.segmentPieces[shySeg];
      if (pieces.isNotEmpty) {
        final run = p.items[pieces.first.itemIndex] as TextRun;
        line.items.add(LineRun.fromRun(run, '-', lb.widths[shySeg]));
        _growMetrics(line, run, style.lineHeight);
      }
    }
  }

  if (line.items.isEmpty) {
    // Blank line ('\n\n') or invisible-only content: style it like the run
    // that owns the break.
    final styleItem = lb.chunks[range.chunkIndex].styleItemIndex;
    if (styleItem >= 0 && p.items[styleItem] is TextRun) {
      _growMetrics(line, p.items[styleItem] as TextRun, style.lineHeight);
    }
  }

  _commitLineMetrics(line);

  // Trailing spaces don't count toward the alignment box. The walker width
  // includes them (they hang), so strip trailing space items here — this
  // also handles whitespace runs spanning style boundaries.
  var w = range.width;
  for (var i = line.items.length - 1; i >= 0; i--) {
    final item = line.items[i];
    if (item is LineRun && item.isSpace) {
      w -= item.width;
    } else {
      break;
    }
  }
  line.width = w;
  return line;
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
/// removed). Placeholders at the cut are dropped whole. Trimming is
/// grapheme-safe (never splits a surrogate pair or emoji cluster).
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
    if (r is! LineRun || r.text.characters.length <= 1) {
      line.items.removeLast();
      continue;
    }
    r.text = r.text.characters.skipLast(1).toString();
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

/// A text run's rect in layout space, tagged with its source span — the
/// widget layer uses these to dispatch pointer events to span recognizers.
class HitSpanBox {
  const HitSpanBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.source,
  });

  final double left;
  final double top;
  final double width;
  final double height;
  final Object source;

  bool contains(double x, double y) =>
      x >= left && x < left + width && y >= top && y < top + height;
}

class ParagraphInstances {
  ParagraphInstances({
    required this.instances,
    required this.inkBounds,
    this.placeholders = const [],
    this.decorations = const [],
    this.hitBoxes = const [],
  });

  final Float32List instances;

  /// Union of glyph ink boxes in layout space, or null when nothing inked.
  /// Placeholder boxes are NOT included (their widgets paint themselves).
  final LayoutBounds? inkBounds;

  /// Resolved placeholder rects, in logical order of appearance.
  final List<PlaceholderBox> placeholders;

  /// Underline/overline/lineThrough strokes in layout space.
  final List<DecorationLine> decorations;

  /// Per-run rects tagged with their source spans (recognizer hit-testing).
  final List<HitSpanBox> hitBoxes;

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
  final hitBoxes = <HitSpanBox>[];
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
      // May be negative: optimal-fit breakers (Knuth-Plass) compress spaces
      // slightly below natural width, like TeX's shrinkability.
      if (stretchable > 0 && extra != 0 && extra.isFinite) {
        spaceExtra = extra / stretchable;
      }
    }

    final baselineY = y + line.ascent;
    var pen = x + offset;
    String? prev;
    WindfoilFont? prevFont;
    var stretched = 0;

    for (final item in line.items) {
      if (item is LineEmoji) {
        final e = item.item;
        final scale = e.fontSizePx / e.font.unitsPerEm;
        for (final layer in e.layers) {
          final gl = table?.lookupGlyphId(e.font, layer.glyphId);
          if (gl == null) continue;
          final c = layer.color ?? e.textColor;
          final a = c.length > 3 ? c[3] : 1.0;
          out.addAll([
            pen, baselineY, scale, 0.0,
            gl.bbox[0], gl.bbox[1], gl.bbox[2], gl.bbox[3],
            c[0], c[1], c[2], a,
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
        final src = e.source;
        if (src != null && e.width > 0) {
          hitBoxes.add(HitSpanBox(
            left: pen,
            top: y,
            width: e.width,
            height: line.ascent + line.descent,
            source: src,
          ));
        }
        pen += e.width;
        prev = null;
        prevFont = null;
        continue;
      }
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

      final src = run.source;
      if (src != null && pen > penStart) {
        hitBoxes.add(HitSpanBox(
          left: penStart,
          top: y,
          width: pen - penStart,
          height: line.ascent + line.descent,
          source: src,
        ));
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
    hitBoxes: hitBoxes,
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
