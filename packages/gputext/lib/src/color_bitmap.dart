// Color-bitmap glyph tables — the raster half of color-font support.
//
// gputext's main pipeline renders monochrome coverage from quadratic outlines,
// which handles COLR v0 (layered vectors) but NOT the two raster formats the
// real platform emoji fonts ship in:
//   * sbix  — Apple Color Emoji: one PNG per glyph per strike (ppem size).
//   * CBDT/CBLC — Google Noto Color Emoji (legacy Android): PNG per glyph,
//                 indexed by CBLC size/index subtables into the CBDT blob.
//
// Both store the glyph as an embedded PNG at a fixed strike ppem. This file
// parses the tables and hands back the raw PNG bytes plus placement in the
// strike's pixel space; decoding + atlasing lives in the color atlas (Phase 2).
//
// Placement is normalized across both formats to a baseline-relative, y-up box
// in strike pixels so the emit layer converts to em by dividing by [ppem]:
//   left(px)   = bearingX
//   top(px)    = bearingY            // top edge above the baseline (y-up)
//   right(px)  = bearingX + width
//   bottom(px) = bearingY - height
//
// Everything here is defensive: a structural surprise for one glyph yields null
// for that glyph (tofu / delegation fallback) rather than throwing, and the
// top-level parse is wrapped by the caller in font.dart.

import 'dart:typed_data';

/// One color-bitmap glyph: the embedded image bytes plus placement in the
/// strike's pixel space (see file header for the coordinate convention).
class BitmapGlyph {
  const BitmapGlyph({
    required this.bytes,
    required this.format,
    required this.ppem,
    required this.width,
    required this.height,
    required this.bearingX,
    required this.bearingY,
    required this.advance,
  });

  /// Encoded image bytes — a zero-copy view into the font. Almost always PNG
  /// (see [format]); the color atlas decodes it with the platform codec.
  final Uint8List bytes;

  /// Graphic type: `'png '`, `'jpg '`, or `'tiff'` (sbix) / synthesized `'png '`
  /// for CBDT PNG image formats. Consumers should handle non-PNG gracefully.
  final String format;

  /// Pixels-per-em of the strike this image came from — the atlas keys on this
  /// so every requested font size that resolves to the same strike shares one
  /// decoded entry.
  final int ppem;

  final int width; // image pixel dimensions
  final int height;
  final double bearingX; // px, glyph origin → left edge (x-right)
  final double bearingY; // px, baseline → top edge (y-up)
  final double advance; // px, horizontal advance (0 for sbix → use shaped)

  bool get isPng => format == 'png ';
}

/// A source of color-bitmap glyphs backed by one font table (sbix or CBDT).
abstract class BitmapGlyphSource {
  /// Strike ppem sizes available, ascending. Empty means no usable strikes.
  List<int> get strikePpems;

  /// The strike ppem [glyphFor] would resolve for [targetPpem]: the smallest
  /// strike ≥ target, else the largest available. Exposed so the atlas can
  /// build its cache key before decoding.
  int chooseStrike(double targetPpem) {
    final ppems = strikePpems;
    for (final p in ppems) {
      if (p >= targetPpem) return p;
    }
    return ppems.last;
  }

  /// The bitmap for [glyphId] at the strike nearest (≥ if possible)
  /// [targetPpem], or null if this glyph has no bitmap in a usable strike.
  BitmapGlyph? glyphFor(int glyphId, {required double targetPpem});
}

/// Width/height from a PNG's IHDR without decoding it — signature (8) + chunk
/// length (4) + "IHDR" (4), then width and height as big-endian u32.
/// Null when [bytes] is not a PNG or is too short.
(int width, int height)? pngSize(Uint8List bytes, int start, int end) {
  if (end - start < 24) return null;
  // 89 50 4E 47 0D 0A 1A 0A
  if (bytes[start] != 0x89 ||
      bytes[start + 1] != 0x50 ||
      bytes[start + 2] != 0x4E ||
      bytes[start + 3] != 0x47) {
    return null;
  }
  final d = ByteData.sublistView(bytes, start + 16, start + 24);
  return (d.getUint32(0, Endian.big), d.getUint32(4, Endian.big));
}

// ===========================================================================
// sbix — Apple Color Emoji
// ===========================================================================

/// Parsed sbix strikes. Glyph offsets are read lazily per lookup so large
/// fonts (thousands of glyphs × many strikes) don't materialize every offset.
class SbixTable implements BitmapGlyphSource {
  SbixTable._(this._data, this._numGlyphs, this._strikes);

  final ByteData _data;
  final int _numGlyphs;
  // Ascending by ppem: (ppem, absolute byte offset of the Strike record).
  final List<({int ppem, int offset})> _strikes;

  @override
  late final List<int> strikePpems = [for (final s in _strikes) s.ppem];

  /// Parse the `sbix` table at [offset]. Returns null when there are no usable
  /// strikes. Throws only on truncation past the table (caller guards).
  static SbixTable? parse(ByteData data, int offset, int numGlyphs) {
    // uint16 version, uint16 flags, uint32 numStrikes, uint32 strikeOffsets[].
    final numStrikes = data.getUint32(offset + 4, Endian.big);
    if (numStrikes == 0) return null;
    final strikes = <({int ppem, int offset})>[];
    for (var i = 0; i < numStrikes; i++) {
      final so = data.getUint32(offset + 8 + i * 4, Endian.big);
      final strikeStart = offset + so;
      final ppem = data.getUint16(strikeStart, Endian.big);
      if (ppem <= 0) continue;
      strikes.add((ppem: ppem, offset: strikeStart));
    }
    if (strikes.isEmpty) return null;
    strikes.sort((a, b) => a.ppem.compareTo(b.ppem));
    return SbixTable._(data, numGlyphs, strikes);
  }

  @override
  int chooseStrike(double targetPpem) {
    for (final s in _strikes) {
      if (s.ppem >= targetPpem) return s.ppem;
    }
    return _strikes.last.ppem;
  }

  @override
  BitmapGlyph? glyphFor(int glyphId, {required double targetPpem}) {
    if (glyphId < 0 || glyphId >= _numGlyphs) return null;
    // Try the chosen strike, then fall outward: a glyph may be absent from one
    // strike but present in others (sbix allows sparse strikes).
    final chosen = chooseStrike(targetPpem);
    final order = <({int ppem, int offset})>[
      for (final s in _strikes)
        if (s.ppem == chosen) s,
      for (final s in _strikes.reversed)
        if (s.ppem != chosen) s,
    ];
    for (final strike in order) {
      final g = _glyphInStrike(strike, glyphId, 0);
      if (g != null) return g;
    }
    return null;
  }

  BitmapGlyph? _glyphInStrike(
    ({int ppem, int offset}) strike,
    int glyphId,
    int depth,
  ) {
    if (depth > 4) return null; // 'dupe' cycle guard
    // Strike: uint16 ppem, uint16 ppi, uint32 glyphDataOffsets[numGlyphs+1].
    final glyphOffBase = strike.offset + 4;
    final start = _data.getUint32(glyphOffBase + glyphId * 4, Endian.big);
    final end = _data.getUint32(glyphOffBase + (glyphId + 1) * 4, Endian.big);
    if (end <= start) return null; // no data for this glyph in this strike
    final rec = strike.offset + start;
    // Glyph record: int16 originOffsetX, int16 originOffsetY, uint32 graphicType.
    final ox = _data.getInt16(rec, Endian.big);
    final oy = _data.getInt16(rec + 2, Endian.big);
    final tag = String.fromCharCodes([
      _data.getUint8(rec + 4),
      _data.getUint8(rec + 5),
      _data.getUint8(rec + 6),
      _data.getUint8(rec + 7),
    ]);
    if (tag == 'dupe') {
      final dup = _data.getUint16(rec + 8, Endian.big);
      return _glyphInStrike(strike, dup, depth + 1);
    }
    final payloadStart = rec + 8;
    final payloadEnd = strike.offset + end;
    if (payloadEnd <= payloadStart) return null;
    final bytes = Uint8List.sublistView(_data);
    final size = pngSize(bytes, payloadStart, payloadEnd);
    if (size == null) return null; // non-PNG (jpg/tiff) — not supported yet
    // sbix originOffset is the graphic's bottom-left from the glyph origin
    // (y-up); convert to our top-edge convention.
    return BitmapGlyph(
      bytes: Uint8List.sublistView(_data, payloadStart, payloadEnd),
      format: tag,
      ppem: strike.ppem,
      width: size.$1,
      height: size.$2,
      bearingX: ox.toDouble(),
      bearingY: oy.toDouble() + size.$2,
      advance: 0, // sbix carries no advance; emit uses the shaped advance
    );
  }
}

// ===========================================================================
// CBDT / CBLC — Google Noto Color Emoji (legacy Android)
// ===========================================================================

class _CbdtStrike {
  _CbdtStrike(this.ppem, this.subTables);
  final int ppem;
  final List<_CbdtIndexSub> subTables;
}

class _CbdtIndexSub {
  _CbdtIndexSub({
    required this.first,
    required this.last,
    required this.indexFormat,
    required this.imageFormat,
    required this.imageDataOffset,
    required this.headerOffset,
  });
  final int first; // first glyph id covered (inclusive)
  final int last; // last glyph id covered (inclusive)
  final int indexFormat; // 1 (u32 offsets) or 3 (u16 offsets)
  final int imageFormat; // 17 (small metrics) or 18 (big metrics)
  final int imageDataOffset; // into CBDT
  final int headerOffset; // absolute offset of the indexSubHeader
}

/// Parsed CBLC size/index tables plus a handle to the CBDT image blob.
class CbdtTable implements BitmapGlyphSource {
  CbdtTable._(this._data, this._cbdt, this._strikes);

  final ByteData _data;
  final int _cbdt; // CBDT table offset
  final List<_CbdtStrike> _strikes; // ascending by ppem

  @override
  late final List<int> strikePpems = [for (final s in _strikes) s.ppem];

  /// Parse CBLC at [cblc] alongside the CBDT blob at [cbdt]. Null when no
  /// usable size table is present.
  static CbdtTable? parse(ByteData data, int cblc, int cbdt) {
    // CBLC: uint16 major, uint16 minor, uint32 numSizes.
    final numSizes = data.getUint32(cblc + 4, Endian.big);
    if (numSizes == 0) return null;
    final strikes = <_CbdtStrike>[];
    var o = cblc + 8;
    for (var s = 0; s < numSizes; s++, o += 48) {
      // bitmapSizeTable (48 bytes).
      final idxArrOff = data.getUint32(o, Endian.big);
      final numIdxSub = data.getUint32(o + 8, Endian.big);
      final ppemX = data.getUint8(o + 44);
      if (ppemX <= 0) continue;
      final arrBase = cblc + idxArrOff;
      final subs = <_CbdtIndexSub>[];
      for (var k = 0; k < numIdxSub; k++) {
        // indexSubTableArray entry (8 bytes).
        final e = arrBase + k * 8;
        final first = data.getUint16(e, Endian.big);
        final last = data.getUint16(e + 2, Endian.big);
        final addOff = data.getUint32(e + 4, Endian.big);
        final hdr = arrBase + addOff; // indexSubHeader
        final indexFormat = data.getUint16(hdr, Endian.big);
        final imageFormat = data.getUint16(hdr + 2, Endian.big);
        final imageDataOffset = data.getUint32(hdr + 4, Endian.big);
        subs.add(
          _CbdtIndexSub(
            first: first,
            last: last,
            indexFormat: indexFormat,
            imageFormat: imageFormat,
            imageDataOffset: imageDataOffset,
            headerOffset: hdr,
          ),
        );
      }
      if (subs.isNotEmpty) strikes.add(_CbdtStrike(ppemX, subs));
    }
    if (strikes.isEmpty) return null;
    strikes.sort((a, b) => a.ppem.compareTo(b.ppem));
    return CbdtTable._(data, cbdt, strikes);
  }

  @override
  int chooseStrike(double targetPpem) {
    for (final s in _strikes) {
      if (s.ppem >= targetPpem) return s.ppem;
    }
    return _strikes.last.ppem;
  }

  @override
  BitmapGlyph? glyphFor(int glyphId, {required double targetPpem}) {
    final chosen = chooseStrike(targetPpem);
    // Chosen strike first, then the rest largest-first as an availability
    // fallback (subset strikes may not cover every glyph).
    final order = <_CbdtStrike>[
      for (final s in _strikes)
        if (s.ppem == chosen) s,
      for (final s in _strikes.reversed)
        if (s.ppem != chosen) s,
    ];
    for (final strike in order) {
      final g = _glyphInStrike(strike, glyphId);
      if (g != null) return g;
    }
    return null;
  }

  BitmapGlyph? _glyphInStrike(_CbdtStrike strike, int glyphId) {
    for (final sub in strike.subTables) {
      if (glyphId < sub.first || glyphId > sub.last) continue;
      final idx = glyphId - sub.first;
      // sbitOffset of this glyph within the imageData block; length is the gap
      // to the next entry (0 ⇒ absent).
      final int sbit;
      final int nextSbit;
      final body = sub.headerOffset + 8; // past indexSubHeader
      switch (sub.indexFormat) {
        case 1: // uint32 offsets[count+1]
          sbit = _data.getUint32(body + idx * 4, Endian.big);
          nextSbit = _data.getUint32(body + (idx + 1) * 4, Endian.big);
        case 3: // uint16 offsets[count+1]
          sbit = _data.getUint16(body + idx * 2, Endian.big);
          nextSbit = _data.getUint16(body + (idx + 1) * 2, Endian.big);
        default:
          return null; // formats 2/4/5 unsupported for now
      }
      if (nextSbit <= sbit) return null;
      final g = _cbdt + sub.imageDataOffset + sbit;
      return _decodeCbdtGlyph(g, sub.imageFormat, strike.ppem);
    }
    return null;
  }

  BitmapGlyph? _decodeCbdtGlyph(int g, int imageFormat, int ppem) {
    // Image formats 17 (smallGlyphMetrics) and 18 (bigGlyphMetrics) both carry
    // self-describing metrics, then uint32 dataLen, then PNG.
    final int height;
    final int width;
    final int bearingX;
    final int bearingY;
    final int advance;
    final int dataLen;
    final int pngStart;
    switch (imageFormat) {
      case 17: // smallGlyphMetrics (5) + dataLen (4) + PNG
        height = _data.getUint8(g);
        width = _data.getUint8(g + 1);
        bearingX = _data.getInt8(g + 2);
        bearingY = _data.getInt8(g + 3);
        advance = _data.getUint8(g + 4);
        dataLen = _data.getUint32(g + 5, Endian.big);
        pngStart = g + 9;
      case 18: // bigGlyphMetrics (8) + dataLen (4) + PNG
        height = _data.getUint8(g);
        width = _data.getUint8(g + 1);
        bearingX = _data.getInt8(g + 2);
        bearingY = _data.getInt8(g + 3);
        advance = _data.getUint8(g + 4);
        dataLen = _data.getUint32(g + 8, Endian.big);
        pngStart = g + 12;
      default:
        return null; // format 19 (metrics-in-CBLC) unsupported for now
    }
    if (dataLen <= 0) return null;
    final bytes = Uint8List.sublistView(_data);
    if (pngSize(bytes, pngStart, pngStart + dataLen) == null) return null;
    // CBDT bearingY is already the top edge above the baseline (y-up).
    return BitmapGlyph(
      bytes: Uint8List.sublistView(_data, pngStart, pngStart + dataLen),
      format: 'png ',
      ppem: ppem,
      width: width,
      height: height,
      bearingX: bearingX.toDouble(),
      bearingY: bearingY.toDouble(),
      advance: advance.toDouble(),
    );
  }
}

/// Parse whichever color-bitmap table a font carries (sbix preferred, then
/// CBDT/CBLC). Returns null when the font has none or parsing fails.
BitmapGlyphSource? parseBitmapGlyphs({
  required ByteData data,
  required int numGlyphs,
  int? sbixOffset,
  int? cblcOffset,
  int? cbdtOffset,
}) {
  try {
    if (sbixOffset != null) {
      final t = SbixTable.parse(data, sbixOffset, numGlyphs);
      if (t != null) return t;
    }
    if (cblcOffset != null && cbdtOffset != null) {
      return CbdtTable.parse(data, cblcOffset, cbdtOffset);
    }
  } catch (_) {
    // Malformed color tables → monochrome / delegation fallback.
  }
  return null;
}
