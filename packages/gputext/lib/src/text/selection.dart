// Selection/caret geometry over laid-out paragraphs, VM-pure.
//
// Offsets are in the paragraph's SOURCE text (the concatenation of each
// item's pre-shaping characters, '￼' per placeholder) — what selection
// reports and copy produces — while x positions come from the laid-out
// shaped text. TextRun.sourceMap bridges the two; boundaries that fall
// inside a shaped cluster (the f|i split of a rendered ligature) divide the
// cluster's advance evenly between its source characters.
//
// The per-line pen walk here mirrors emitInstances' walk (alignment via
// lineAlignOffset, justify via justifySpaceExtra, kern → glyph → advance +
// letterSpacing → wordSpacing, kern chain carried across items); a drift
// test pins the two together.

import 'dart:typed_data';

import '../font.dart';
import '../paragraph.dart';

/// Caret placement in layout-local px.
class CaretMetrics {
  const CaretMetrics(this.x, this.top, this.height, this.line);

  final double x;
  final double top;
  final double height;
  final int line;
}

/// One selection highlight rect in layout-local px.
class SelectionRect {
  const SelectionRect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;
}

/// A resolved source-text position: offset plus line affinity (upstream →
/// the boundary belongs to the end of the wrapped line above).
class SourcePosition {
  const SourcePosition(this.offset, {this.upstream = false});

  final int offset;
  final bool upstream;
}

class _PlacedItem {
  _PlacedItem(this.item, this.penStart, this.penEnd, this.boundaries);

  final LineItem item;
  final double penStart;
  final double penEnd;

  /// Pen x at each UTF-16 boundary of a LineRun's shaped text; null for
  /// emoji/placeholder items.
  final Float64List? boundaries;
}

/// Caret/selection geometry for one laid-out paragraph. Construct per
/// layout; lookups lazily place lines and cache the placements.
class ParagraphGeometry {
  ParagraphGeometry({
    required this.items,
    required this.para,
    required this.boxWidth,
    required this.align,
  }) {
    final buf = StringBuffer();
    _itemStarts = Int32List(items.length + 1);
    for (var i = 0; i < items.length; i++) {
      _itemStarts[i] = buf.length;
      buf.write(switch (items[i]) {
        TextRun r => r.originalText,
        EmojiItem e => e.originalText,
        PlaceholderItem _ => '￼',
      });
    }
    _itemStarts[items.length] = buf.length;
    plainText = buf.toString();

    final lines = para.lines;
    _lineTops = Float64List(lines.length + 1);
    for (var i = 0; i < lines.length; i++) {
      _lineTops[i + 1] = _lineTops[i] + lines[i].height;
    }
    _computeLineRanges();
  }

  final List<InlineItem> items;
  final ParagraphLines para;
  final double boxWidth;
  final TextAlign align;

  /// The paragraph's source text (selection offset space).
  late final String plainText;
  late final Int32List _itemStarts;
  late final Float64List _lineTops;
  late final Int32List _lineStarts;
  late final Int32List _lineEnds;
  final _placedCache = <int, List<_PlacedItem>>{};

  int get length => plainText.length;

  double lineTop(int line) => _lineTops[line];
  double lineBottom(int line) => _lineTops[line + 1];

  /// Tight line box (ascent+descent) used for carets and selection rects.
  double _lineBoxHeight(LineMetrics l) => l.ascent + l.descent;

  /// Source range covered by `line` (trailing spaces included, the '\n'
  /// excluded, like Flutter's line boundaries).
  ({int start, int end}) lineRange(int line) =>
      (start: _lineStarts[line], end: _lineEnds[line]);

  void _computeLineRanges() {
    final lines = para.lines;
    _lineStarts = Int32List(lines.length);
    _lineEnds = Int32List(lines.length);
    var cursor = 0;
    for (var i = 0; i < lines.length; i++) {
      int? first;
      int? last;
      for (final item in lines[i].items) {
        final range = _itemRange(item);
        if (range == null) continue;
        first ??= range.$1;
        last = range.$2;
      }
      if (first == null) {
        // Blank line: collapses at the running cursor (just past the
        // previous line's newline).
        first = cursor.clamp(0, plainText.length);
        last = first;
      }
      _lineStarts[i] = first;
      _lineEnds[i] = last!;
      // Hard-broken lines consume their '\n' (when one exists — the final
      // line's hard break is the end of text).
      cursor =
          lines[i].hardBreak &&
              last < plainText.length &&
              plainText.codeUnitAt(last) == 0x0A
          ? last + 1
          : last;
    }
  }

  /// Source range of a line item; null for synthesized runs (ellipsis).
  (int, int)? _itemRange(LineItem item) {
    switch (item) {
      case LineRun run:
        if (run.itemIndex < 0) return null;
        final source = items[run.itemIndex] as TextRun;
        final base = _itemStarts[run.itemIndex];
        return (
          base + source.sourceOffsetAt(run.startInItem),
          base + source.sourceOffsetAt(run.startInItem + run.text.length),
        );
      case LineEmoji e:
        if (e.itemIndex < 0) return null;
        final base = _itemStarts[e.itemIndex];
        return (base, base + e.item.originalText.length);
      case LinePlaceholder p:
        if (p.itemIndex < 0) return null;
        final base = _itemStarts[p.itemIndex];
        return (base, base + 1);
    }
  }

  List<_PlacedItem> _placeLine(int lineIndex) =>
      _placedCache[lineIndex] ??= _placeLineUncached(lineIndex);

  List<_PlacedItem> _placeLineUncached(int lineIndex) {
    final line = para.lines[lineIndex];
    final placed = <_PlacedItem>[];
    var pen = lineAlignOffset(align, boxWidth, line);
    final (spaceExtra, stretchable) = justifySpaceExtra(
      para,
      line,
      boxWidth,
      align,
    );
    var stretched = 0;
    var prevGid = -1;
    GPUFont? prevFont;

    for (final item in line.items) {
      if (item is! LineRun) {
        placed.add(_PlacedItem(item, pen, pen + item.width, null));
        pen += item.width;
        prevGid = -1;
        prevFont = null;
        continue;
      }
      final run = item;
      final scale = run.fontSizePx / run.font.unitsPerEm;
      final shaped = run.shaped;
      final pipe = shaped.pipelineText;
      final b = Float64List(run.text.length + 1);
      b[0] = pen;
      // Fill every UTF-16 boundary; glyphs may skip ZW code points.
      var shapedCursor = 0;
      for (final g in shaped.glyphs) {
        // Boundaries before this glyph stay at the current pen (ZW gaps).
        while (shapedCursor < g.shapedStart && shapedCursor < b.length - 1) {
          shapedCursor++;
          b[shapedCursor] = pen;
        }
        if (shaped.appliesKerning &&
            prevGid >= 0 &&
            identical(prevFont, run.font)) {
          pen += run.font.kerningOfGlyphIds(prevGid, g.glyphId) * scale;
          if (g.shapedStart < b.length) b[g.shapedStart] = pen;
        }
        final startPen = pen;
        pen += g.xAdvance * scale + run.letterSpacingPx;
        if (g.shapedEnd - g.shapedStart == 1 &&
            g.shapedStart < pipe.length &&
            pipe.codeUnitAt(g.shapedStart) == 0x20) {
          pen += run.wordSpacingPx;
        }
        // Interior UTF-16 boundaries of a multi-unit cluster keep startPen
        // so caret interpolation (selection) can divide the advance; only
        // the cluster end advances to [pen].
        final units = g.shapedEnd - g.shapedStart;
        if (units <= 1) {
          if (g.shapedEnd < b.length) b[g.shapedEnd] = pen;
        } else {
          for (
            var u = g.shapedStart + 1;
            u < g.shapedEnd && u < b.length;
            u++
          ) {
            b[u] = startPen; // overwritten by interpolation callers via c0/c1
          }
          if (g.shapedEnd < b.length) b[g.shapedEnd] = pen;
        }
        shapedCursor = g.shapedEnd;
        prevGid = g.glyphId;
        prevFont = run.font;
      }
      while (shapedCursor < run.text.length) {
        shapedCursor++;
        b[shapedCursor] = pen;
      }
      if (run.isSpace && stretched < stretchable) {
        pen += spaceExtra; // justified gap
        b[b.length - 1] = pen;
        stretched++;
      }
      placed.add(_PlacedItem(run, b[0], pen, b));
    }
    return placed;
  }

  int _lineForY(double dy) {
    if (para.lines.isEmpty) return 0;
    for (var i = 0; i < para.lines.length; i++) {
      if (dy < _lineTops[i + 1]) return i;
    }
    return para.lines.length - 1;
  }

  /// Nearest source-text boundary to a local point; boundaries inside a
  /// shaped cluster (ligature) are interpolated across its advance.
  SourcePosition positionForOffset(double dx, double dy) {
    if (para.lines.isEmpty || plainText.isEmpty) {
      return const SourcePosition(0);
    }
    final lineIndex = _lineForY(dy);
    final placed = _placeLine(lineIndex);
    var bestDist = double.infinity;
    var bestOffset = _lineStarts[lineIndex];

    void candidate(double x, int offset) {
      final d = (x - dx).abs();
      if (d < bestDist) {
        bestDist = d;
        bestOffset = offset;
      }
    }

    for (final pi in placed) {
      final range = _itemRange(pi.item);
      if (range == null) continue;
      final b = pi.boundaries;
      if (b == null) {
        candidate(pi.penStart, range.$1);
        candidate(pi.penEnd, range.$2);
        continue;
      }
      final run = pi.item as LineRun;
      final source = items[run.itemIndex] as TextRun;
      final base = _itemStarts[run.itemIndex];
      for (final g in run.shaped.glyphs) {
        final c0 =
            base + source.sourceOffsetAt(run.startInItem + g.shapedStart);
        final c1 = base + source.sourceOffsetAt(run.startInItem + g.shapedEnd);
        final x0 = b[g.shapedStart];
        final x1 = b[g.shapedEnd];
        candidate(x0, c0);
        final n = c1 - c0;
        for (var t = 1; t < n; t++) {
          candidate(x0 + (x1 - x0) * t / n, c0 + t);
        }
      }
      candidate(
        b[b.length - 1],
        base + source.sourceOffsetAt(run.startInItem + run.text.length),
      );
    }

    final lineEnd = _lineEnds[lineIndex];
    final upstream =
        bestOffset == lineEnd &&
        !para.lines[lineIndex].hardBreak &&
        lineIndex < para.lines.length - 1;
    return SourcePosition(bestOffset, upstream: upstream);
  }

  int _lineForOffset(int offset, {required bool upstream}) {
    final lines = para.lines;
    var chosen = lines.length - 1;
    for (var i = 0; i < lines.length; i++) {
      if (offset < _lineStarts[i]) {
        // Gap before this line (a consumed newline): belongs to the
        // previous line's end side.
        chosen = i == 0 ? 0 : i - 1;
        break;
      }
      if (offset <= _lineEnds[i]) {
        // Boundary shared with the next line's start (soft wrap): upstream
        // sticks here, downstream falls through to the next line.
        if (offset == _lineEnds[i] &&
            !upstream &&
            i + 1 < lines.length &&
            _lineStarts[i + 1] == offset) {
          continue;
        }
        chosen = i;
        break;
      }
    }
    return chosen;
  }

  /// X of a source offset within `lineIndex`, snapping into gaps (skipped
  /// soft hyphens) and interpolating inside shaped clusters.
  double _xForOffsetInLine(int lineIndex, int offset) {
    final placed = _placeLine(lineIndex);
    double? lastEndX;
    for (final pi in placed) {
      final range = _itemRange(pi.item);
      if (range == null) continue;
      if (offset <= range.$1) return pi.penStart;
      if (offset >= range.$2) {
        lastEndX = pi.penEnd;
        continue;
      }
      final b = pi.boundaries;
      if (b == null) return pi.penStart; // inside emoji/placeholder → left
      final run = pi.item as LineRun;
      final source = items[run.itemIndex] as TextRun;
      final base = _itemStarts[run.itemIndex];
      for (final g in run.shaped.glyphs) {
        final c0 =
            base + source.sourceOffsetAt(run.startInItem + g.shapedStart);
        final c1 = base + source.sourceOffsetAt(run.startInItem + g.shapedEnd);
        if (offset == c0) return b[g.shapedStart];
        if (offset < c1) {
          // Inside this cluster: interpolate across its advance.
          final n = c1 - c0;
          if (n <= 1) return b[g.shapedStart];
          return b[g.shapedStart] +
              (b[g.shapedEnd] - b[g.shapedStart]) * (offset - c0) / n;
        }
      }
      return b[b.length - 1];
    }
    if (lastEndX != null) return lastEndX;
    return lineAlignOffset(align, boxWidth, para.lines[lineIndex]);
  }

  /// Caret placement for a source offset (clamped into range).
  CaretMetrics caretAt(int offset, {bool upstream = false}) {
    if (para.lines.isEmpty) return const CaretMetrics(0, 0, 0, 0);
    final o = offset.clamp(0, plainText.length);
    final lineIndex = _lineForOffset(o, upstream: upstream);
    final line = para.lines[lineIndex];
    final clamped = o.clamp(_lineStarts[lineIndex], _lineEnds[lineIndex]);
    return CaretMetrics(
      _xForOffsetInLine(lineIndex, clamped),
      _lineTops[lineIndex],
      _lineBoxHeight(line),
      lineIndex,
    );
  }

  /// Test hook: (penStart, unit boundaries) for each LineRun on a line, in
  /// order — the drift test pins these against emitInstances' glyph x's.
  List<(double, Float64List)> debugPlacedItems(int line) => [
    for (final p in _placeLine(line))
      if (p.boundaries != null) (p.penStart, p.boundaries!),
  ];

  /// Selection rects for a source range: one per intersecting line, split
  /// further when a line mixes LTR/RTL runs (visual gaps).
  List<SelectionRect> boxesForRange(int start, int end) {
    if (start >= end || para.lines.isEmpty) return const [];
    final out = <SelectionRect>[];
    for (var i = 0; i < para.lines.length; i++) {
      final ls = _lineStarts[i];
      final le = _lineEnds[i];
      final s = start > ls ? start : ls;
      final e = end < le ? end : le;
      if (s >= e) continue;
      final placed = _placeLine(i);
      final top = _lineTops[i];
      final bottom = top + _lineBoxHeight(para.lines[i]);
      // Per-item rects, then coalesce adjacent same-direction spans so
      // plain LTR lines still yield one box (Flutter parity).
      final parts = <SelectionRect>[];
      for (final pi in placed) {
        final range = _itemRange(pi.item);
        if (range == null) continue;
        final iStart = s > range.$1 ? s : range.$1;
        final iEnd = e < range.$2 ? e : range.$2;
        if (iStart >= iEnd) continue;
        final x0 = _xForOffsetInLine(i, iStart);
        final x1 = _xForOffsetInLine(i, iEnd);
        parts.add(
          SelectionRect(x0 < x1 ? x0 : x1, top, x0 < x1 ? x1 : x0, bottom),
        );
      }
      if (parts.isEmpty) {
        final x0 = _xForOffsetInLine(i, s);
        final x1 = _xForOffsetInLine(i, e);
        out.add(
          SelectionRect(x0 < x1 ? x0 : x1, top, x0 < x1 ? x1 : x0, bottom),
        );
        continue;
      }
      parts.sort((a, b) => a.left.compareTo(b.left));
      var cur = parts.first;
      for (var p = 1; p < parts.length; p++) {
        final next = parts[p];
        // Merge when touching / overlapping (same visual band).
        if (next.left <= cur.right + 0.5) {
          cur = SelectionRect(
            cur.left,
            top,
            next.right > cur.right ? next.right : cur.right,
            bottom,
          );
        } else {
          out.add(cur);
          cur = next;
        }
      }
      out.add(cur);
    }
    return out;
  }
}

/// The word containing `offset` in `text` — UAX#29-lite: runs of
/// letters/digits/underscore are words, whitespace runs are their own
/// "word" (Flutter behavior), CJK ideographs and everything else go
/// character by character.
({int start, int end}) wordRangeIn(String text, int offset) {
  if (text.isEmpty) return (start: 0, end: 0);
  final o = offset.clamp(0, text.length);
  final at = o == text.length ? o - 1 : o;

  int codePointAt(int index) {
    final unit = text.codeUnitAt(index);
    if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < text.length) {
      final low = text.codeUnitAt(index + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
      }
    }
    if (unit >= 0xDC00 && unit <= 0xDFFF && index > 0) {
      return codePointAt(index - 1);
    }
    return unit;
  }

  int cpStart(int index) {
    final unit = text.codeUnitAt(index);
    return (unit >= 0xDC00 && unit <= 0xDFFF && index > 0) ? index - 1 : index;
  }

  int cpLen(int cp) => cp >= 0x10000 ? 2 : 1;

  int classAt(int index) {
    final cp = codePointAt(index);
    if (cp == 0x20 || cp == 0x09 || cp == 0x0A || cp == 0x0D || cp == 0xA0) {
      return 0; // whitespace
    }
    if (isCjkBreakOpportunity(cp)) return 2; // per-character
    if (_isWordCp(cp)) return 1;
    return 3; // punctuation etc: per-character
  }

  final anchor = cpStart(at);
  final cls = classAt(anchor);
  if (cls == 2 || cls == 3) {
    final cp = codePointAt(anchor);
    return (start: anchor, end: anchor + cpLen(cp));
  }
  var start = anchor;
  while (start > 0) {
    final prev = cpStart(start - 1);
    if (classAt(prev) != cls) break;
    start = prev;
  }
  var end = anchor + cpLen(codePointAt(anchor));
  while (end < text.length) {
    if (classAt(end) != cls) break;
    end += cpLen(codePointAt(end));
  }
  return (start: start, end: end);
}

final _wordCpPattern = RegExp(r"[\p{L}\p{M}\p{N}_']", unicode: true);

bool _isWordCp(int cp) => _wordCpPattern.hasMatch(String.fromCharCode(cp));
