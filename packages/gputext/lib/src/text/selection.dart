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
//
// The query logic lives once, in [ParagraphGeometryBase], over flat
// [PlacedLineGeometry] records. Two providers exist: [ParagraphGeometry]
// derives placements from the live items/lines (needs fonts for kerning),
// and SnapshotParagraphGeometry (selection_snapshot.dart) replays records
// shipped across an isolate boundary.

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

/// Flat placed geometry for one line: source-ranged items in visual order
/// (synthesized ellipsis runs omitted — queries skip them), each text run
/// carrying per-glyph cluster records. This is everything the queries in
/// [ParagraphGeometryBase] read, so it can cross an isolate boundary.
class PlacedLineGeometry {
  const PlacedLineGeometry({
    required this.itemSrcStart,
    required this.itemSrcEnd,
    required this.itemPenStart,
    required this.itemPenEnd,
    required this.itemHasBoundaries,
    required this.itemGlyphStart,
    required this.glyphSrcStart,
    required this.glyphSrcEnd,
    required this.glyphX0,
    required this.glyphX1,
  });

  /// Source range per item (paragraph source-offset space).
  final Int32List itemSrcStart;
  final Int32List itemSrcEnd;

  /// Pen x at the item's start/end (end == the boundary array's tail for
  /// text runs, including any justify stretch).
  final Float64List itemPenStart;
  final Float64List itemPenEnd;

  /// 1 for text runs (glyph records apply), 0 for emoji/placeholder items
  /// (whole-item candidates only).
  final Uint8List itemHasBoundaries;

  /// Prefix offsets into the glyph arrays, length itemCount + 1.
  final Int32List itemGlyphStart;

  /// Per glyph cluster: source range (c0..c1) and the pen x at the
  /// cluster's shaped start/end after full line placement (kern/justify
  /// applied). Interior source boundaries interpolate across [x0, x1].
  final Int32List glyphSrcStart;
  final Int32List glyphSrcEnd;
  final Float64List glyphX0;
  final Float64List glyphX1;

  int get itemCount => itemSrcStart.length;
  int get glyphCount => glyphSrcStart.length;
}

/// Caret/selection queries over placed line geometry. Subclasses supply the
/// per-line data ([placedLineAt] and the line tables); all query logic —
/// hit-testing, caret placement, selection rects — lives here so the live
/// and snapshot-backed geometries answer identically.
abstract class ParagraphGeometryBase {
  /// The paragraph's source text (selection offset space).
  String get plainText;

  int get length => plainText.length;

  int get lineCount;

  double lineTop(int line);
  double lineBottom(int line);

  /// Tight line box (ascent+descent) used for carets and selection rects.
  double lineBoxHeightAt(int line);

  bool lineHardBreakAt(int line);

  /// Source range covered by `line` (trailing spaces included, the '\n'
  /// excluded, like Flutter's line boundaries).
  ({int start, int end}) lineRange(int line) =>
      (start: lineStartAt(line), end: lineEndAt(line));

  int lineStartAt(int line);
  int lineEndAt(int line);

  /// Pen origin of an item-less (blank) line: the alignment offset.
  double lineStartXAt(int line);

  PlacedLineGeometry placedLineAt(int line);

  /// A lower bound for the line containing [dy]: every line before it has
  /// `lineBottom <= dy`. The default (0) keeps the linear scans below exact;
  /// providers with random-access line tables override with a binary search
  /// so hit-testing stays O(log n) on huge documents.
  int firstLineCandidateForY(double dy) => 0;

  /// A lower bound for the line containing source [offset]: every line
  /// before it has `lineEndAt < offset`. Same contract as
  /// [firstLineCandidateForY].
  int firstLineCandidateForOffset(int offset) => 0;

  /// The line whose vertical band contains [dy] (clamped to the edges).
  int lineForY(double dy) {
    if (lineCount == 0) return 0;
    for (var i = firstLineCandidateForY(dy); i < lineCount; i++) {
      if (dy < lineBottom(i)) return i;
    }
    return lineCount - 1;
  }

  /// Nearest source-text boundary to a local point; boundaries inside a
  /// shaped cluster (ligature) are interpolated across its advance.
  SourcePosition positionForOffset(double dx, double dy) {
    if (lineCount == 0 || plainText.isEmpty) {
      return const SourcePosition(0);
    }
    final lineIndex = lineForY(dy);
    final placed = placedLineAt(lineIndex);
    var bestDist = double.infinity;
    var bestOffset = lineStartAt(lineIndex);

    void candidate(double x, int offset) {
      final d = (x - dx).abs();
      if (d < bestDist) {
        bestDist = d;
        bestOffset = offset;
      }
    }

    for (var i = 0; i < placed.itemCount; i++) {
      if (placed.itemHasBoundaries[i] == 0) {
        candidate(placed.itemPenStart[i], placed.itemSrcStart[i]);
        candidate(placed.itemPenEnd[i], placed.itemSrcEnd[i]);
        continue;
      }
      final gEnd = placed.itemGlyphStart[i + 1];
      for (var g = placed.itemGlyphStart[i]; g < gEnd; g++) {
        final c0 = placed.glyphSrcStart[g];
        final c1 = placed.glyphSrcEnd[g];
        final x0 = placed.glyphX0[g];
        final x1 = placed.glyphX1[g];
        candidate(x0, c0);
        final n = c1 - c0;
        for (var t = 1; t < n; t++) {
          candidate(x0 + (x1 - x0) * t / n, c0 + t);
        }
      }
      candidate(placed.itemPenEnd[i], placed.itemSrcEnd[i]);
    }

    final lineEnd = lineEndAt(lineIndex);
    final upstream =
        bestOffset == lineEnd &&
        !lineHardBreakAt(lineIndex) &&
        lineIndex < lineCount - 1;
    return SourcePosition(bestOffset, upstream: upstream);
  }

  /// The line a source [offset] renders on (wrap boundaries stick to the
  /// upper line when [upstream]).
  int lineForOffset(int offset, {required bool upstream}) {
    var chosen = lineCount - 1;
    for (var i = firstLineCandidateForOffset(offset); i < lineCount; i++) {
      if (offset < lineStartAt(i)) {
        // Gap before this line (a consumed newline): belongs to the
        // previous line's end side.
        chosen = i == 0 ? 0 : i - 1;
        break;
      }
      if (offset <= lineEndAt(i)) {
        // Boundary shared with the next line's start (soft wrap): upstream
        // sticks here, downstream falls through to the next line.
        if (offset == lineEndAt(i) &&
            !upstream &&
            i + 1 < lineCount &&
            lineStartAt(i + 1) == offset) {
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
  double xForOffsetInLine(int lineIndex, int offset) =>
      xForOffsetInPlaced(placedLineAt(lineIndex), lineIndex, offset);

  /// [xForOffsetInLine] against an already-fetched [placed] record — the
  /// per-item loops in [boxesForRangeInBand] call this many times per line,
  /// and re-fetching [placedLineAt] each time is what made it hot (on a
  /// banded geometry an uncached line SYNTHESIZES its record per fetch).
  double xForOffsetInPlaced(
    PlacedLineGeometry placed,
    int lineIndex,
    int offset,
  ) {
    double? lastEndX;
    for (var i = 0; i < placed.itemCount; i++) {
      final rangeStart = placed.itemSrcStart[i];
      final rangeEnd = placed.itemSrcEnd[i];
      if (offset <= rangeStart) return placed.itemPenStart[i];
      if (offset >= rangeEnd) {
        lastEndX = placed.itemPenEnd[i];
        continue;
      }
      if (placed.itemHasBoundaries[i] == 0) {
        return placed.itemPenStart[i]; // inside emoji/placeholder → left
      }
      final gEnd = placed.itemGlyphStart[i + 1];
      for (var g = placed.itemGlyphStart[i]; g < gEnd; g++) {
        final c0 = placed.glyphSrcStart[g];
        final c1 = placed.glyphSrcEnd[g];
        if (offset == c0) return placed.glyphX0[g];
        if (offset < c1) {
          // Inside this cluster: interpolate across its advance.
          final n = c1 - c0;
          if (n <= 1) return placed.glyphX0[g];
          return placed.glyphX0[g] +
              (placed.glyphX1[g] - placed.glyphX0[g]) * (offset - c0) / n;
        }
      }
      return placed.itemPenEnd[i];
    }
    if (lastEndX != null) return lastEndX;
    return lineStartXAt(lineIndex);
  }

  /// Caret placement for a source offset (clamped into range).
  CaretMetrics caretAt(int offset, {bool upstream = false}) {
    if (lineCount == 0) return const CaretMetrics(0, 0, 0, 0);
    final o = offset.clamp(0, plainText.length);
    final lineIndex = lineForOffset(o, upstream: upstream);
    final clamped = o.clamp(lineStartAt(lineIndex), lineEndAt(lineIndex));
    return CaretMetrics(
      xForOffsetInLine(lineIndex, clamped),
      lineTop(lineIndex),
      lineBoxHeightAt(lineIndex),
      lineIndex,
    );
  }

  /// Selection rects for a source range: one per intersecting line, split
  /// further when a line mixes LTR/RTL runs (visual gaps).
  List<SelectionRect> boxesForRange(int start, int end) =>
      boxesForRangeInBand(start, end, double.negativeInfinity, double.infinity);

  /// [boxesForRange] restricted to lines whose vertical band intersects
  /// [top, bottom) — what a paint pass needs for its visible window. The
  /// scan is bounded by the offset AND y candidates, so on a table-backed
  /// geometry a huge selection costs only the visible lines.
  List<SelectionRect> boxesForRangeInBand(
    int start,
    int end,
    double top,
    double bottom,
  ) {
    if (start >= end || lineCount == 0) return const [];
    final out = <SelectionRect>[];
    var i = firstLineCandidateForOffset(start);
    if (top.isFinite) {
      final byY = firstLineCandidateForY(top);
      if (byY > i) i = byY;
    }
    for (; i < lineCount; i++) {
      final ls = lineStartAt(i);
      if (ls >= end) break; // line starts are monotone in i
      if (lineTop(i) >= bottom) break; // line tops are monotone in i
      if (lineBottom(i) <= top) continue;
      final le = lineEndAt(i);
      final s = start > ls ? start : ls;
      final e = end < le ? end : le;
      if (s >= e) continue;
      final placed = placedLineAt(i);
      final lineTopPx = lineTop(i);
      final lineBottomPx = lineTopPx + lineBoxHeightAt(i);
      // Per-item rects, then coalesce adjacent same-direction spans so
      // plain LTR lines still yield one box (Flutter parity).
      final parts = <SelectionRect>[];
      for (var p = 0; p < placed.itemCount; p++) {
        final iStart = s > placed.itemSrcStart[p] ? s : placed.itemSrcStart[p];
        final iEnd = e < placed.itemSrcEnd[p] ? e : placed.itemSrcEnd[p];
        if (iStart >= iEnd) continue;
        final x0 = xForOffsetInPlaced(placed, i, iStart);
        final x1 = xForOffsetInPlaced(placed, i, iEnd);
        parts.add(
          SelectionRect(
            x0 < x1 ? x0 : x1,
            lineTopPx,
            x0 < x1 ? x1 : x0,
            lineBottomPx,
          ),
        );
      }
      if (parts.isEmpty) {
        final x0 = xForOffsetInPlaced(placed, i, s);
        final x1 = xForOffsetInPlaced(placed, i, e);
        out.add(
          SelectionRect(
            x0 < x1 ? x0 : x1,
            lineTopPx,
            x0 < x1 ? x1 : x0,
            lineBottomPx,
          ),
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
            lineTopPx,
            next.right > cur.right ? next.right : cur.right,
            lineBottomPx,
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

  /// Bounding box of [boxesForRange] without materializing per-line rects,
  /// or null when the range covers nothing laid out. Table-backed geometries
  /// override this so fragment bounds never walk a huge selection.
  SelectionRect? rangeBounds(int start, int end) {
    SelectionRect? union;
    for (final b in boxesForRange(start, end)) {
      union = union == null
          ? b
          : SelectionRect(
              b.left < union.left ? b.left : union.left,
              b.top < union.top ? b.top : union.top,
              b.right > union.right ? b.right : union.right,
              b.bottom > union.bottom ? b.bottom : union.bottom,
            );
    }
    return union;
  }
}

/// Caret/selection geometry for one laid-out paragraph. Construct per
/// layout; lookups lazily place lines and cache the placements.
class ParagraphGeometry extends ParagraphGeometryBase {
  ParagraphGeometry({
    required this.items,
    required this.para,
    required this.boxWidth,
    required this.align,
  }) {
    // Item start offsets only — the concatenated string itself is built
    // lazily by [plainText]: the isolate worker constructs one of these per
    // table-carrying reflow and never reads the text, so a multi-megabyte
    // document must not pay an O(chars) string build each time.
    _itemStarts = Int32List(items.length + 1);
    var len = 0;
    for (var i = 0; i < items.length; i++) {
      _itemStarts[i] = len;
      len += switch (items[i]) {
        TextRun r => r.originalText.length,
        EmojiItem e => e.originalText.length,
        PlaceholderItem _ => 1,
      };
    }
    _itemStarts[items.length] = len;

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

  @override
  late final String plainText = () {
    final buf = StringBuffer();
    for (final item in items) {
      buf.write(switch (item) {
        TextRun r => r.originalText,
        EmojiItem e => e.originalText,
        PlaceholderItem _ => '￼',
      });
    }
    return buf.toString();
  }();

  /// Total source length without forcing [plainText].
  @override
  int get length => _itemStarts[items.length];

  /// Source code unit at [offset] without forcing [plainText]: binary-search
  /// the owning item, read from its own text.
  int _sourceCodeUnitAt(int offset) {
    var lo = 0;
    var hi = items.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_itemStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final local = offset - _itemStarts[lo];
    return switch (items[lo]) {
      TextRun r => r.originalText.codeUnitAt(local),
      EmojiItem e => e.originalText.codeUnitAt(local),
      PlaceholderItem _ => 0xFFFC,
    };
  }

  late final Int32List _itemStarts;
  late final Float64List _lineTops;
  late final Int32List _lineStarts;
  late final Int32List _lineEnds;
  final _placedCache = <int, List<_PlacedItem>>{};
  final _placedGeometryCache = <int, PlacedLineGeometry>{};

  @override
  int get lineCount => para.lines.length;

  @override
  double lineTop(int line) => _lineTops[line];
  @override
  double lineBottom(int line) => _lineTops[line + 1];

  @override
  double lineBoxHeightAt(int line) =>
      para.lines[line].ascent + para.lines[line].descent;

  @override
  bool lineHardBreakAt(int line) => para.lines[line].hardBreak;

  @override
  int lineStartAt(int line) => _lineStarts[line];
  @override
  int lineEndAt(int line) => _lineEnds[line];

  @override
  double lineStartXAt(int line) =>
      lineAlignOffset(align, boxWidth, para.lines[line]);

  @override
  PlacedLineGeometry placedLineAt(int line) =>
      _placedGeometryCache[line] ??= _toPlacedGeometry(_placeLine(line));

  void _computeLineRanges() {
    final lines = para.lines;
    _lineStarts = Int32List(lines.length);
    _lineEnds = Int32List(lines.length);
    var cursor = 0;
    for (var i = 0; i < lines.length; i++) {
      int? first;
      int? last;
      // Items sit in VISUAL order (an RTL line reverses logical order), so
      // the line's source range is the min/max over its items, not
      // first-item-start..last-item-end.
      for (final item in lines[i].items) {
        final range = _itemRange(item);
        if (range == null) continue;
        first = first == null || range.$1 < first ? range.$1 : first;
        last = last == null || range.$2 > last ? range.$2 : last;
      }
      if (first == null) {
        // Blank line: collapses at the running cursor (just past the
        // previous line's newline).
        first = cursor.clamp(0, length);
        last = first;
      }
      _lineStarts[i] = first;
      _lineEnds[i] = last!;
      // Hard-broken lines consume their '\n' (when one exists — the final
      // line's hard break is the end of text). Read through the items, not
      // [plainText] — building the full string here would defeat its lazy
      // construction.
      cursor =
          lines[i].hardBreak && last < length && _sourceCodeUnitAt(last) == 0x0A
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

  /// Flattens placed items into the query records: ranged items only, with
  /// per-glyph (c0, c1, x0, x1) read from the FINAL boundary array (kern
  /// and justify already applied).
  PlacedLineGeometry _toPlacedGeometry(List<_PlacedItem> placed) {
    var itemCount = 0;
    var glyphCount = 0;
    for (final pi in placed) {
      if (_itemRange(pi.item) == null) continue;
      itemCount++;
      if (pi.boundaries != null) {
        glyphCount += (pi.item as LineRun).shaped.glyphs.length;
      }
    }
    final itemSrcStart = Int32List(itemCount);
    final itemSrcEnd = Int32List(itemCount);
    final itemPenStart = Float64List(itemCount);
    final itemPenEnd = Float64List(itemCount);
    final itemHasBoundaries = Uint8List(itemCount);
    final itemGlyphStart = Int32List(itemCount + 1);
    final glyphSrcStart = Int32List(glyphCount);
    final glyphSrcEnd = Int32List(glyphCount);
    final glyphX0 = Float64List(glyphCount);
    final glyphX1 = Float64List(glyphCount);

    var i = 0;
    var g = 0;
    for (final pi in placed) {
      final range = _itemRange(pi.item);
      if (range == null) continue;
      itemSrcStart[i] = range.$1;
      itemSrcEnd[i] = range.$2;
      itemPenStart[i] = pi.penStart;
      itemPenEnd[i] = pi.penEnd;
      final b = pi.boundaries;
      if (b != null) {
        itemHasBoundaries[i] = 1;
        final run = pi.item as LineRun;
        final source = items[run.itemIndex] as TextRun;
        final base = _itemStarts[run.itemIndex];
        for (final glyph in run.shaped.glyphs) {
          glyphSrcStart[g] =
              base + source.sourceOffsetAt(run.startInItem + glyph.shapedStart);
          glyphSrcEnd[g] =
              base + source.sourceOffsetAt(run.startInItem + glyph.shapedEnd);
          glyphX0[g] = b[glyph.shapedStart];
          glyphX1[g] = b[glyph.shapedEnd];
          g++;
        }
      }
      i++;
      itemGlyphStart[i] = g;
    }
    return PlacedLineGeometry(
      itemSrcStart: itemSrcStart,
      itemSrcEnd: itemSrcEnd,
      itemPenStart: itemPenStart,
      itemPenEnd: itemPenEnd,
      itemHasBoundaries: itemHasBoundaries,
      itemGlyphStart: itemGlyphStart,
      glyphSrcStart: glyphSrcStart,
      glyphSrcEnd: glyphSrcEnd,
      glyphX0: glyphX0,
      glyphX1: glyphX1,
    );
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

  /// Test hook: (penStart, unit boundaries) for each LineRun on a line, in
  /// order — the drift test pins these against emitInstances' glyph x's.
  List<(double, Float64List)> debugPlacedItems(int line) => [
    for (final p in _placeLine(line))
      if (p.boundaries != null) (p.penStart, p.boundaries!),
  ];
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
