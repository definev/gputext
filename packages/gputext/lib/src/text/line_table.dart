// Tiered selection geometry for worker-backed views, VM-pure.
//
// The full geometry snapshot (selection_snapshot.dart) is O(glyphs) and made
// large single documents unselectable (the worker declined it above a source
// budget). This file replaces it for the single-document views with two much
// smaller wire pieces:
//
//  * [encodeLineTable] — O(lines), ~29 B per line: enough to hit-test to a
//    line, place endpoint carets/handles, and paint exact full-line
//    highlight rects at any document size. Rides every reflow reply while
//    selection is enabled.
//  * [encodeLineBand] — per-line glyph/item detail (the same records a
//    snapshot carries) for a REQUESTED range of lines only. The main isolate
//    prefetches the visible band; everything the pointer can touch answers
//    char-exact, everything else degrades to proportional interpolation
//    until its band arrives.
//
// [BandedDocGeometry] combines the two behind the shared
// [ParagraphGeometryBase] query surface: cached lines answer bit-identically
// to a snapshot; uncached lines answer from a synthetic one-glyph placement
// spanning the line (linear interpolation across its advance). plainText is
// NOT shipped at all — the main isolate derives it from the document specs
// it already owns.

import 'dart:typed_data';

import '../paragraph.dart';

const int _kLineTableVersion = 1;
const int _kLineBandVersion = 1;

/// Encodes the O(lines) table for [g]: line tops (cumulative), tight box
/// heights, alignment start x / visual end x (justify stretch included),
/// source ranges, and hard-break flags. All positions stay Float64 so table
/// answers are exactly the live geometry's answers (the same parity
/// contract the snapshot codec keeps). No pen walk — everything reads the
/// break result.
ByteBuffer encodeLineTable(ParagraphGeometry g) {
  final n = g.lineCount;
  final lines = g.para.lines;

  const headerBytes = 32; // Int32 x8
  final f64Start = headerBytes;
  final i32Start = f64Start + 8 * ((n + 1) + 3 * n);
  final u8Start = i32Start + 4 * (2 * n);
  final bytes = Uint8List(u8Start + n);
  final buffer = bytes.buffer;

  final header = Int32List.view(buffer, 0, 8);
  header[0] = _kLineTableVersion;
  header[1] = n;

  final tops = Float64List.view(buffer, f64Start, n + 1);
  final heights = Float64List.view(buffer, f64Start + 8 * (n + 1), n);
  final startX = Float64List.view(buffer, f64Start + 8 * (2 * n + 1), n);
  final endX = Float64List.view(buffer, f64Start + 8 * (3 * n + 1), n);
  final srcStart = Int32List.view(buffer, i32Start, n);
  final srcEnd = Int32List.view(buffer, i32Start + 4 * n, n);
  final hardBreak = Uint8List.view(buffer, u8Start, n);

  for (var i = 0; i < n; i++) {
    tops[i] = g.lineTop(i);
    heights[i] = g.lineBoxHeightAt(i);
    final sx = g.lineStartXAt(i);
    startX[i] = sx;
    final line = lines[i];
    // Visual end: advance width plus any justify stretch plus the hanging
    // trailing spaces (line.width excludes them, the pen walk does not) —
    // so full-line highlight rects match the painted pens without a glyph
    // walk.
    final (spaceExtra, stretchable) = justifySpaceExtra(
      g.para,
      line,
      g.boxWidth,
      g.align,
    );
    var trailing = 0.0;
    for (var k = line.items.length - 1; k >= 0; k--) {
      final item = line.items[k];
      if (item is LineRun && item.isSpace) {
        trailing += item.width;
      } else {
        break;
      }
    }
    endX[i] = sx + line.width + spaceExtra * stretchable + trailing;
    srcStart[i] = g.lineStartAt(i);
    srcEnd[i] = g.lineEndAt(i);
    hardBreak[i] = g.lineHardBreakAt(i) ? 1 : 0;
  }
  if (n > 0) tops[n] = g.lineBottom(n - 1);
  return buffer;
}

/// Zero-copy views over an [encodeLineTable] buffer.
class LineTable {
  factory LineTable.decode(ByteBuffer buffer) {
    final header = Int32List.view(buffer, 0, 8);
    if (header[0] != _kLineTableVersion) {
      throw StateError(
        'line table version ${header[0]} != $_kLineTableVersion',
      );
    }
    final n = header[1];
    const f64Start = 32;
    final i32Start = f64Start + 8 * ((n + 1) + 3 * n);
    final u8Start = i32Start + 4 * (2 * n);
    return LineTable._(
      tops: Float64List.view(buffer, f64Start, n + 1),
      heights: Float64List.view(buffer, f64Start + 8 * (n + 1), n),
      startX: Float64List.view(buffer, f64Start + 8 * (2 * n + 1), n),
      endX: Float64List.view(buffer, f64Start + 8 * (3 * n + 1), n),
      srcStart: Int32List.view(buffer, i32Start, n),
      srcEnd: Int32List.view(buffer, i32Start + 4 * n, n),
      hardBreak: Uint8List.view(buffer, u8Start, n),
    );
  }

  LineTable._({
    required this.tops,
    required this.heights,
    required this.startX,
    required this.endX,
    required this.srcStart,
    required this.srcEnd,
    required this.hardBreak,
  }) {
    var minX = double.infinity;
    var maxX = double.negativeInfinity;
    for (var i = 0; i < startX.length; i++) {
      if (startX[i] < minX) minX = startX[i];
      if (endX[i] > maxX) maxX = endX[i];
    }
    globalMinStartX = startX.isEmpty ? 0 : minX;
    globalMaxEndX = endX.isEmpty ? 0 : maxX;
  }

  final Float64List tops; // length lineCount + 1
  final Float64List heights;
  final Float64List startX;
  final Float64List endX;
  final Int32List srcStart;
  final Int32List srcEnd;
  final Uint8List hardBreak;

  /// Horizontal document bounds — the coarse middle of a huge selection.
  late final double globalMinStartX;
  late final double globalMaxEndX;

  int get lineCount => srcStart.length;
}

/// Encodes glyph/item placement records for lines [first, last) of [g] —
/// the same per-line data a full snapshot carries, without text or holes.
/// The worker places only these lines (cached on its live geometry, so
/// repeat fetches are cheap).
ByteBuffer encodeLineBand(ParagraphGeometry g, int first, int last) {
  final placed = [for (var i = first; i < last; i++) g.placedLineAt(i)];
  var itemCount = 0;
  var glyphCount = 0;
  for (final p in placed) {
    itemCount += p.itemCount;
    glyphCount += p.glyphCount;
  }
  final n = placed.length;

  const headerBytes = 32;
  final f64Start = headerBytes;
  final i32Start = f64Start + 8 * (2 * itemCount + 2 * glyphCount);
  final u8Start =
      i32Start +
      4 * ((n + 1) + 2 * itemCount + (itemCount + 1) + 2 * glyphCount);
  final bytes = Uint8List(u8Start + itemCount);
  final buffer = bytes.buffer;

  final header = Int32List.view(buffer, 0, 8);
  header[0] = _kLineBandVersion;
  header[1] = first;
  header[2] = n;
  header[3] = itemCount;
  header[4] = glyphCount;

  var f = f64Start;
  Float64List f64(int length) {
    final view = Float64List.view(buffer, f, length);
    f += length * 8;
    return view;
  }

  var i4 = i32Start;
  Int32List i32(int length) {
    final view = Int32List.view(buffer, i4, length);
    i4 += length * 4;
    return view;
  }

  final itemPenStart = f64(itemCount);
  final itemPenEnd = f64(itemCount);
  final glyphX0 = f64(glyphCount);
  final glyphX1 = f64(glyphCount);
  final lineItemStart = i32(n + 1);
  final itemSrcStart = i32(itemCount);
  final itemSrcEnd = i32(itemCount);
  final itemGlyphStart = i32(itemCount + 1);
  final glyphSrcStart = i32(glyphCount);
  final glyphSrcEnd = i32(glyphCount);
  final itemHasBoundaries = Uint8List.view(buffer, u8Start, itemCount);

  var iBase = 0;
  var gBase = 0;
  for (var k = 0; k < n; k++) {
    final p = placed[k];
    lineItemStart[k] = iBase;
    for (var j = 0; j < p.itemCount; j++) {
      itemSrcStart[iBase + j] = p.itemSrcStart[j];
      itemSrcEnd[iBase + j] = p.itemSrcEnd[j];
      itemPenStart[iBase + j] = p.itemPenStart[j];
      itemPenEnd[iBase + j] = p.itemPenEnd[j];
      itemHasBoundaries[iBase + j] = p.itemHasBoundaries[j];
      itemGlyphStart[iBase + j] = gBase + p.itemGlyphStart[j];
    }
    for (var j = 0; j < p.glyphCount; j++) {
      glyphSrcStart[gBase + j] = p.glyphSrcStart[j];
      glyphSrcEnd[gBase + j] = p.glyphSrcEnd[j];
      glyphX0[gBase + j] = p.glyphX0[j];
      glyphX1[gBase + j] = p.glyphX1[j];
    }
    iBase += p.itemCount;
    gBase += p.glyphCount;
  }
  lineItemStart[n] = iBase;
  itemGlyphStart[itemCount] = gBase;
  return buffer;
}

/// Decodes an [encodeLineBand] buffer into per-line placement records.
(int first, List<PlacedLineGeometry> lines) decodeLineBand(ByteBuffer buffer) {
  final header = Int32List.view(buffer, 0, 8);
  if (header[0] != _kLineBandVersion) {
    throw StateError('line band version ${header[0]} != $_kLineBandVersion');
  }
  final first = header[1];
  final n = header[2];
  final itemCount = header[3];
  final glyphCount = header[4];

  const f64Start = 32;
  final i32Start = f64Start + 8 * (2 * itemCount + 2 * glyphCount);

  var f = f64Start;
  Float64List f64(int length) {
    final view = Float64List.view(buffer, f, length);
    f += length * 8;
    return view;
  }

  var i4 = i32Start;
  Int32List i32(int length) {
    final view = Int32List.view(buffer, i4, length);
    i4 += length * 4;
    return view;
  }

  final itemPenStart = f64(itemCount);
  final itemPenEnd = f64(itemCount);
  final glyphX0 = f64(glyphCount);
  final glyphX1 = f64(glyphCount);
  final lineItemStart = i32(n + 1);
  final itemSrcStart = i32(itemCount);
  final itemSrcEnd = i32(itemCount);
  final itemGlyphStart = i32(itemCount + 1);
  final glyphSrcStart = i32(glyphCount);
  final glyphSrcEnd = i32(glyphCount);
  final itemHasBoundaries = Uint8List.view(buffer, i4, itemCount);

  final lines = <PlacedLineGeometry>[];
  for (var k = 0; k < n; k++) {
    final i0 = lineItemStart[k];
    final i1 = lineItemStart[k + 1];
    final g0 = itemGlyphStart[i0];
    final g1 = itemGlyphStart[i1];
    final localGlyphStart = Int32List(i1 - i0 + 1);
    for (var j = 0; j <= i1 - i0; j++) {
      localGlyphStart[j] = itemGlyphStart[i0 + j] - g0;
    }
    lines.add(
      PlacedLineGeometry(
        itemSrcStart: Int32List.sublistView(itemSrcStart, i0, i1),
        itemSrcEnd: Int32List.sublistView(itemSrcEnd, i0, i1),
        itemPenStart: Float64List.sublistView(itemPenStart, i0, i1),
        itemPenEnd: Float64List.sublistView(itemPenEnd, i0, i1),
        itemHasBoundaries: Uint8List.sublistView(itemHasBoundaries, i0, i1),
        itemGlyphStart: localGlyphStart,
        glyphSrcStart: Int32List.sublistView(glyphSrcStart, g0, g1),
        glyphSrcEnd: Int32List.sublistView(glyphSrcEnd, g0, g1),
        glyphX0: Float64List.sublistView(glyphX0, g0, g1),
        glyphX1: Float64List.sublistView(glyphX1, g0, g1),
      ),
    );
  }
  return (first, lines);
}

/// Selection geometry for a worker-backed single document: an O(lines)
/// [LineTable] that always answers, plus per-line placement detail merged in
/// as bands arrive. Lines with detail answer exactly like a full snapshot;
/// lines without answer from a synthetic single-glyph placement spanning
/// the line (hit-tests and carets interpolate proportionally across it).
class BandedDocGeometry extends ParagraphGeometryBase {
  BandedDocGeometry({
    required this.plainText,
    required this.placeholderOffsets,
    required LineTable table,
    required this.generation,
  }) : _t = table;

  @override
  final String plainText;

  /// Source offsets of the document's placeholders ('￼' each) — where the
  /// host splits selectable fragments. Derived on the MAIN isolate from the
  /// document specs, not shipped.
  final Int32List placeholderOffsets;

  /// The worker layout generation this table (and any detail bands merged
  /// into it) describes. Bands from other generations must not be applied.
  final int generation;

  final LineTable _t;
  final _detail = <int, PlacedLineGeometry>{};

  /// Detail cache ceiling (lines). Bands are ~100 lines; this comfortably
  /// holds every band a scroll session touches without growing unbounded.
  static const int detailCacheCap = 4096;

  @override
  int get lineCount => _t.lineCount;

  @override
  double lineTop(int line) => _t.tops[line];
  @override
  double lineBottom(int line) => _t.tops[line + 1];

  @override
  double lineBoxHeightAt(int line) => _t.heights[line];

  @override
  bool lineHardBreakAt(int line) => _t.hardBreak[line] != 0;

  @override
  int lineStartAt(int line) => _t.srcStart[line];
  @override
  int lineEndAt(int line) => _t.srcEnd[line];

  @override
  double lineStartXAt(int line) => _t.startX[line];

  @override
  int firstLineCandidateForY(double dy) {
    var lo = 0;
    var hi = lineCount - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_t.tops[mid + 1] > dy) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo < 0 ? 0 : lo;
  }

  @override
  int firstLineCandidateForOffset(int offset) {
    var lo = 0;
    var hi = lineCount - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_t.srcEnd[mid] >= offset) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo < 0 ? 0 : lo;
  }

  @override
  PlacedLineGeometry placedLineAt(int line) =>
      _detail[line] ?? _syntheticCache[line] ?? _synthetic(line);

  /// Synthetic records memoized per line: the paint/query loops fetch the
  /// same uncached line many times per frame, and re-allocating six typed
  /// arrays each time dominated profiles. Bounded; superseded entries are
  /// dropped when real detail for the line merges.
  final _syntheticCache = <int, PlacedLineGeometry>{};
  static const int _syntheticCacheCap = 512;

  /// Whether every line in [first, last) has exact detail cached.
  bool hasDetailFor(int first, int last) {
    for (var i = first; i < last; i++) {
      if (!_detail.containsKey(i)) return false;
    }
    return true;
  }

  /// Merge a detail band (an [encodeLineBand] payload for THIS generation).
  /// Returns the number of lines merged.
  int applyDetailBand(ByteBuffer buffer) {
    final (first, lines) = decodeLineBand(buffer);
    for (var k = 0; k < lines.length; k++) {
      final line = first + k;
      if (line < 0 || line >= lineCount) continue;
      _syntheticCache.remove(line); // real detail supersedes the synthetic
      _detail.remove(line); // re-insert → newest in iteration order
      _detail[line] = lines[k];
    }
    while (_detail.length > detailCacheCap) {
      _detail.remove(_detail.keys.first);
    }
    return lines.length;
  }

  /// Line-granular placement for a line with no detail yet: one pseudo item
  /// with one glyph cluster spanning the line's source range across
  /// [startX, endX] — hit-tests and carets interpolate linearly across it.
  PlacedLineGeometry _synthetic(int line) {
    final built = _buildSynthetic(line);
    while (_syntheticCache.length >= _syntheticCacheCap) {
      _syntheticCache.remove(_syntheticCache.keys.first);
    }
    _syntheticCache[line] = built;
    return built;
  }

  PlacedLineGeometry _buildSynthetic(int line) {
    final ls = _t.srcStart[line];
    final le = _t.srcEnd[line];
    if (le <= ls) {
      // Blank line: no items, queries resolve to the line start.
      return PlacedLineGeometry(
        itemSrcStart: Int32List(0),
        itemSrcEnd: Int32List(0),
        itemPenStart: Float64List(0),
        itemPenEnd: Float64List(0),
        itemHasBoundaries: Uint8List(0),
        itemGlyphStart: Int32List(1),
        glyphSrcStart: Int32List(0),
        glyphSrcEnd: Int32List(0),
        glyphX0: Float64List(0),
        glyphX1: Float64List(0),
      );
    }
    final sx = _t.startX[line];
    final ex = _t.endX[line];
    return PlacedLineGeometry(
      itemSrcStart: Int32List(1)..[0] = ls,
      itemSrcEnd: Int32List(1)..[0] = le,
      itemPenStart: Float64List(1)..[0] = sx,
      itemPenEnd: Float64List(1)..[0] = ex,
      itemHasBoundaries: Uint8List(1)..[0] = 1,
      itemGlyphStart: Int32List(2)
        ..[0] = 0
        ..[1] = 1,
      glyphSrcStart: Int32List(1)..[0] = ls,
      glyphSrcEnd: Int32List(1)..[0] = le,
      glyphX0: Float64List(1)..[0] = sx,
      glyphX1: Float64List(1)..[0] = ex,
    );
  }

  /// Fragment bounds without walking the selection: edge lines answer
  /// through [placedLineAt] (exact with detail, proportional without);
  /// middle lines read the table when the span is small and fall back to
  /// the document's horizontal bounds when it is huge.
  @override
  SelectionRect? rangeBounds(int start, int end) {
    if (start >= end || lineCount == 0) return null;
    final first = lineForOffset(start, upstream: false);
    final last = lineForOffset(end, upstream: true);
    final top = lineTop(first);
    final bottom = lineTop(last) + lineBoxHeightAt(last);

    double left;
    double right;
    if (first == last) {
      final x0 = xForOffsetInLine(
        first,
        start.clamp(lineStartAt(first), lineEndAt(first)),
      );
      final x1 = xForOffsetInLine(
        first,
        end.clamp(lineStartAt(first), lineEndAt(first)),
      );
      left = x0 < x1 ? x0 : x1;
      right = x0 < x1 ? x1 : x0;
    } else {
      final xs = xForOffsetInLine(
        first,
        start.clamp(lineStartAt(first), lineEndAt(first)),
      );
      final xe = xForOffsetInLine(
        last,
        end.clamp(lineStartAt(last), lineEndAt(last)),
      );
      left = xs < _t.startX[last] ? xs : _t.startX[last];
      right = xe > _t.endX[first] ? xe : _t.endX[first];
      if (last - first <= 64) {
        for (var i = first + 1; i < last; i++) {
          if (_t.startX[i] < left) left = _t.startX[i];
          if (_t.endX[i] > right) right = _t.endX[i];
        }
      } else {
        if (_t.globalMinStartX < left) left = _t.globalMinStartX;
        if (_t.globalMaxEndX > right) right = _t.globalMaxEndX;
      }
    }
    if (right < left) {
      final t = left;
      left = right;
      right = t;
    }
    return SelectionRect(left, top, right, bottom);
  }
}
