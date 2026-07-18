// Wire codec for selection geometry, VM-pure.
//
// [encodeGeometrySnapshot] flattens a live [ParagraphGeometry] — placing
// every line — into ONE flat ByteBuffer of typed regions, and
// [SnapshotParagraphGeometry.decode] wraps that buffer in zero-copy views
// that answer every [ParagraphGeometryBase] query bit-identically WITHOUT
// items, lines, or fonts. This is how the isolate worker ships selection
// geometry to the main isolate: the buffer crosses as one
// TransferableTypedData alongside the drawable it was derived from.
//
// All x/y values stay Float64 so snapshot answers are exactly the live
// geometry's answers (a parity test pins them); the payload is roughly
// 24 B per glyph + 2 B per source char, only built when requested.

import 'dart:typed_data';

import '../paragraph.dart';

const int _kSnapshotVersion = 1;

/// Byte offsets of the snapshot's typed regions, derived from the header
/// counts. Layout order (each region's alignment satisfied by the previous
/// region's element size): 64-byte Int32 header, Float64s, Int32s, Uint16
/// plainText, Uint8 flags.
class _Regions {
  _Regions(this.lines, this.items, this.glyphs, this.textUnits, this.holes) {
    var cursor = 64; // Int32x16 header
    f64Start = cursor;
    cursor +=
        8 * ((lines + 1) + lines + lines + items + items + glyphs + glyphs);
    i32Start = cursor;
    cursor +=
        4 *
        (lines +
            lines +
            (lines + 1) +
            items +
            items +
            (items + 1) +
            glyphs +
            glyphs +
            holes);
    u16Start = cursor;
    cursor += 2 * textUnits;
    u8Start = cursor;
    cursor += lines + items;
    totalBytes = cursor;
  }

  final int lines;
  final int items;
  final int glyphs;
  final int textUnits;
  final int holes;

  late final int f64Start;
  late final int i32Start;
  late final int u16Start;
  late final int u8Start;
  late final int totalBytes;
}

/// Encodes [g] into the snapshot wire format, forcing placement of every
/// line (one pen walk, comparable to an emit pass).
ByteBuffer encodeGeometrySnapshot(ParagraphGeometry g) {
  final lineCount = g.lineCount;
  final placed = [for (var i = 0; i < lineCount; i++) g.placedLineAt(i)];
  var itemCount = 0;
  var glyphCount = 0;
  for (final p in placed) {
    itemCount += p.itemCount;
    glyphCount += p.glyphCount;
  }

  // Placeholder source offsets (one '￼' each) — the main isolate splits
  // selectable fragments at these, mirroring RenderGPUParagraph.
  final placeholderOffsets = <int>[];
  var srcCursor = 0;
  for (final item in g.items) {
    switch (item) {
      case TextRun r:
        srcCursor += r.originalText.length;
      case EmojiItem e:
        srcCursor += e.originalText.length;
      case PlaceholderItem _:
        placeholderOffsets.add(srcCursor);
        srcCursor += 1;
    }
  }

  final text = g.plainText;
  final r = _Regions(
    lineCount,
    itemCount,
    glyphCount,
    text.length,
    placeholderOffsets.length,
  );
  final bytes = Uint8List(r.totalBytes);
  final buffer = bytes.buffer;

  final header = Int32List.view(buffer, 0, 16);
  header[0] = _kSnapshotVersion;
  header[1] = lineCount;
  header[2] = itemCount;
  header[3] = glyphCount;
  header[4] = text.length;
  header[5] = placeholderOffsets.length;

  var f = r.f64Start;
  Float64List f64(int length) {
    final view = Float64List.view(buffer, f, length);
    f += length * 8;
    return view;
  }

  var i4 = r.i32Start;
  Int32List i32(int length) {
    final view = Int32List.view(buffer, i4, length);
    i4 += length * 4;
    return view;
  }

  final lineTops = f64(lineCount + 1);
  final lineBoxHeights = f64(lineCount);
  final lineStartX = f64(lineCount);
  final itemPenStart = f64(itemCount);
  final itemPenEnd = f64(itemCount);
  final glyphX0 = f64(glyphCount);
  final glyphX1 = f64(glyphCount);

  final lineStarts = i32(lineCount);
  final lineEnds = i32(lineCount);
  final lineItemStart = i32(lineCount + 1);
  final itemSrcStart = i32(itemCount);
  final itemSrcEnd = i32(itemCount);
  final itemGlyphStart = i32(itemCount + 1);
  final glyphSrcStart = i32(glyphCount);
  final glyphSrcEnd = i32(glyphCount);
  final holes = i32(placeholderOffsets.length);

  final plainText = Uint16List.view(buffer, r.u16Start, text.length);
  final lineHardBreak = Uint8List.view(buffer, r.u8Start, lineCount);
  final itemHasBoundaries = Uint8List.view(
    buffer,
    r.u8Start + lineCount,
    itemCount,
  );

  var iBase = 0;
  var gBase = 0;
  for (var line = 0; line < lineCount; line++) {
    lineTops[line] = g.lineTop(line);
    lineBoxHeights[line] = g.lineBoxHeightAt(line);
    lineStartX[line] = g.lineStartXAt(line);
    lineStarts[line] = g.lineStartAt(line);
    lineEnds[line] = g.lineEndAt(line);
    lineHardBreak[line] = g.lineHardBreakAt(line) ? 1 : 0;
    lineItemStart[line] = iBase;

    final p = placed[line];
    for (var k = 0; k < p.itemCount; k++) {
      itemSrcStart[iBase + k] = p.itemSrcStart[k];
      itemSrcEnd[iBase + k] = p.itemSrcEnd[k];
      itemPenStart[iBase + k] = p.itemPenStart[k];
      itemPenEnd[iBase + k] = p.itemPenEnd[k];
      itemHasBoundaries[iBase + k] = p.itemHasBoundaries[k];
      itemGlyphStart[iBase + k] = gBase + p.itemGlyphStart[k];
    }
    for (var k = 0; k < p.glyphCount; k++) {
      glyphSrcStart[gBase + k] = p.glyphSrcStart[k];
      glyphSrcEnd[gBase + k] = p.glyphSrcEnd[k];
      glyphX0[gBase + k] = p.glyphX0[k];
      glyphX1[gBase + k] = p.glyphX1[k];
    }
    iBase += p.itemCount;
    gBase += p.glyphCount;
  }
  lineItemStart[lineCount] = iBase;
  itemGlyphStart[itemCount] = gBase;
  if (lineCount > 0) lineTops[lineCount] = g.lineBottom(lineCount - 1);

  for (var k = 0; k < text.length; k++) {
    plainText[k] = text.codeUnitAt(k);
  }
  for (var k = 0; k < placeholderOffsets.length; k++) {
    holes[k] = placeholderOffsets[k];
  }
  return buffer;
}

/// Selection geometry decoded from a snapshot buffer: zero-copy typed views,
/// same query answers as the live [ParagraphGeometry] it was encoded from.
class SnapshotParagraphGeometry extends ParagraphGeometryBase {
  SnapshotParagraphGeometry._({
    required this.plainText,
    required this.placeholderOffsets,
    required this._lineTops,
    required this._lineBoxHeights,
    required this._lineStartX,
    required this._itemPenStart,
    required this._itemPenEnd,
    required this._glyphX0,
    required this._glyphX1,
    required this._lineStarts,
    required this._lineEnds,
    required this._lineItemStart,
    required this._itemSrcStart,
    required this._itemSrcEnd,
    required this._itemGlyphStart,
    required this._glyphSrcStart,
    required this._glyphSrcEnd,
    required this._lineHardBreak,
    required this._itemHasBoundaries,
  });

  factory SnapshotParagraphGeometry.decode(ByteBuffer buffer) {
    final header = Int32List.view(buffer, 0, 16);
    if (header[0] != _kSnapshotVersion) {
      throw StateError(
        'geometry snapshot version ${header[0]} != $_kSnapshotVersion',
      );
    }
    final r = _Regions(header[1], header[2], header[3], header[4], header[5]);

    var f = r.f64Start;
    Float64List f64(int length) {
      final view = Float64List.view(buffer, f, length);
      f += length * 8;
      return view;
    }

    var i4 = r.i32Start;
    Int32List i32(int length) {
      final view = Int32List.view(buffer, i4, length);
      i4 += length * 4;
      return view;
    }

    return SnapshotParagraphGeometry._(
      lineTops: f64(r.lines + 1),
      lineBoxHeights: f64(r.lines),
      lineStartX: f64(r.lines),
      itemPenStart: f64(r.items),
      itemPenEnd: f64(r.items),
      glyphX0: f64(r.glyphs),
      glyphX1: f64(r.glyphs),
      lineStarts: i32(r.lines),
      lineEnds: i32(r.lines),
      lineItemStart: i32(r.lines + 1),
      itemSrcStart: i32(r.items),
      itemSrcEnd: i32(r.items),
      itemGlyphStart: i32(r.items + 1),
      glyphSrcStart: i32(r.glyphs),
      glyphSrcEnd: i32(r.glyphs),
      placeholderOffsets: i32(r.holes),
      plainText: String.fromCharCodes(
        Uint16List.view(buffer, r.u16Start, r.textUnits),
      ),
      lineHardBreak: Uint8List.view(buffer, r.u8Start, r.lines),
      itemHasBoundaries: Uint8List.view(buffer, r.u8Start + r.lines, r.items),
    );
  }

  @override
  final String plainText;

  /// Source offsets of the paragraph's placeholders ('￼' each) — where the
  /// main isolate splits selectable fragments.
  final Int32List placeholderOffsets;

  final Float64List _lineTops;
  final Float64List _lineBoxHeights;
  final Float64List _lineStartX;
  final Float64List _itemPenStart;
  final Float64List _itemPenEnd;
  final Float64List _glyphX0;
  final Float64List _glyphX1;
  final Int32List _lineStarts;
  final Int32List _lineEnds;
  final Int32List _lineItemStart;
  final Int32List _itemSrcStart;
  final Int32List _itemSrcEnd;
  final Int32List _itemGlyphStart;
  final Int32List _glyphSrcStart;
  final Int32List _glyphSrcEnd;
  final Uint8List _lineHardBreak;
  final Uint8List _itemHasBoundaries;
  final _lineCache = <int, PlacedLineGeometry>{};

  @override
  int get lineCount => _lineStarts.length;

  @override
  int firstLineCandidateForY(double dy) {
    // First line with bottom > dy (bottoms = _lineTops[i + 1], monotone).
    var lo = 0;
    var hi = lineCount - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_lineTops[mid + 1] > dy) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  @override
  int firstLineCandidateForOffset(int offset) {
    // First line with lineEnd >= offset (ends are monotone).
    var lo = 0;
    var hi = lineCount - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_lineEnds[mid] >= offset) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  @override
  double lineTop(int line) => _lineTops[line];
  @override
  double lineBottom(int line) => _lineTops[line + 1];

  @override
  double lineBoxHeightAt(int line) => _lineBoxHeights[line];

  @override
  bool lineHardBreakAt(int line) => _lineHardBreak[line] != 0;

  @override
  int lineStartAt(int line) => _lineStarts[line];
  @override
  int lineEndAt(int line) => _lineEnds[line];

  @override
  double lineStartXAt(int line) => _lineStartX[line];

  @override
  PlacedLineGeometry placedLineAt(int line) =>
      _lineCache[line] ??= _sliceLine(line);

  PlacedLineGeometry _sliceLine(int line) {
    final i0 = _lineItemStart[line];
    final i1 = _lineItemStart[line + 1];
    final g0 = _itemGlyphStart[i0];
    final g1 = _itemGlyphStart[i1];
    // Rebase the glyph prefix to line-local indices (glyph arrays below are
    // subviews starting at g0).
    final localGlyphStart = Int32List(i1 - i0 + 1);
    for (var k = 0; k <= i1 - i0; k++) {
      localGlyphStart[k] = _itemGlyphStart[i0 + k] - g0;
    }
    return PlacedLineGeometry(
      itemSrcStart: Int32List.sublistView(_itemSrcStart, i0, i1),
      itemSrcEnd: Int32List.sublistView(_itemSrcEnd, i0, i1),
      itemPenStart: Float64List.sublistView(_itemPenStart, i0, i1),
      itemPenEnd: Float64List.sublistView(_itemPenEnd, i0, i1),
      itemHasBoundaries: Uint8List.sublistView(_itemHasBoundaries, i0, i1),
      itemGlyphStart: localGlyphStart,
      glyphSrcStart: Int32List.sublistView(_glyphSrcStart, g0, g1),
      glyphSrcEnd: Int32List.sublistView(_glyphSrcEnd, g0, g1),
      glyphX0: Float64List.sublistView(_glyphX0, g0, g1),
      glyphX1: Float64List.sublistView(_glyphX1, g0, g1),
    );
  }
}
