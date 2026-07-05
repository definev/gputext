import 'dart:typed_data';

enum FillRule { nonzero, evenOdd }

/// Substitute the common Latin ligatures (ffi, ffl, fi, fl) with their
/// precomposed compatibility code points when the font maps them — a
/// pragmatic GSUB-'liga' subset that rides the existing cmap pipeline.
/// Callers should skip this when letterSpacing != 0 (typographic rule).
String applyBasicLigatures(String text, WindfoilFont font) {
  var out = text;
  if (out.contains('ffi') && font.hasGlyph('ﬃ')) {
    out = out.replaceAll('ffi', 'ﬃ');
  }
  if (out.contains('ffl') && font.hasGlyph('ﬄ')) {
    out = out.replaceAll('ffl', 'ﬄ');
  }
  if (out.contains('fi') && font.hasGlyph('ﬁ')) {
    out = out.replaceAll('fi', 'ﬁ');
  }
  if (out.contains('fl') && font.hasGlyph('ﬂ')) {
    out = out.replaceAll('fl', 'ﬂ');
  }
  return out;
}

/// CJK code points that permit a line break between adjacent characters
/// (UAX#14-lite: ideographs, kana, hangul, full-width forms; no kinsoku).
bool isCjkBreakOpportunity(int cp) =>
    (cp >= 0x2E80 && cp <= 0x9FFF) ||
    (cp >= 0xAC00 && cp <= 0xD7AF) ||
    (cp >= 0xF900 && cp <= 0xFAFF) ||
    (cp >= 0xFF00 && cp <= 0xFFEF) ||
    (cp >= 0x20000 && cp <= 0x2FA1F);

/// Zero-width/invisible code points the layout engine skips entirely:
/// ZWSP/ZWNJ/ZWJ, variation selectors, and the BOM/ZWNBSP.
bool isZeroWidthCodePoint(int cp) =>
    cp == 0x200B ||
    cp == 0x200C ||
    cp == 0x200D ||
    (cp >= 0xFE00 && cp <= 0xFE0F) ||
    cp == 0xFEFF;

class VerticalMetrics {
  const VerticalMetrics({
    required this.ascender,
    required this.descender,
    required this.lineGap,
  });

  final double ascender;
  final double descender;
  final double lineGap;
}

/// Decoration guide positions in font units, Y-up as stored in the font:
/// underlinePosition is typically negative (below the baseline),
/// strikeoutPosition positive (above it).
class DecorationMetrics {
  const DecorationMetrics({
    required this.underlinePosition,
    required this.underlineThickness,
    required this.strikeoutPosition,
    required this.strikeoutSize,
  });

  final double underlinePosition;
  final double underlineThickness;
  final double strikeoutPosition;
  final double strikeoutSize;
}

class GlyphOutline {
  const GlyphOutline({
    required this.quads,
    required this.advance,
    required this.bbox,
  });

  final List<double> quads;
  final double advance;
  final List<double> bbox;
}

class _TableRecord {
  _TableRecord(this.tag, this.offset, this.length);
  final String tag;
  final int offset;
  final int length;
}

class _ByteReader {
  _ByteReader(this.bytes);

  final ByteData bytes;
  var _pos = 0;

  int get position => _pos;

  void seek(int pos) => _pos = pos;

  int readU8() {
    final v = bytes.getUint8(_pos);
    _pos += 1;
    return v;
  }

  int readI8() {
    final v = bytes.getInt8(_pos);
    _pos += 1;
    return v;
  }

  int readU16() {
    final v = bytes.getUint16(_pos, Endian.big);
    _pos += 2;
    return v;
  }

  int readI16() {
    final v = bytes.getInt16(_pos, Endian.big);
    _pos += 2;
    return v;
  }

  int readU32() {
    final v = bytes.getUint32(_pos, Endian.big);
    _pos += 4;
    return v;
  }

  int readI32() {
    final v = bytes.getInt32(_pos, Endian.big);
    _pos += 4;
    return v;
  }

  int readF2Dot14() {
    final raw = readI16();
    return raw;
  }

  double readFixed() {
    final v = readI32();
    return v / 65536.0;
  }
}

class WindfoilFont {
  WindfoilFont._({
    required this.unitsPerEm,
    required this.verticalMetrics,
    required this.decorationMetrics,
    required this._bytes,
    required this._tables,
    required this._numGlyphs,
    required this._indexToLocFormat,
    required this._cmap,
    required this._advances,
    required this._lsbs,
    required this._glyphOffsets,
    required this._kern,
    required List<_PairPosSub> gposKern,
    _ColrData? colr,
  })  : _gposKern = gposKern,
        _colr = colr;

  final int unitsPerEm;
  final VerticalMetrics verticalMetrics;
  final DecorationMetrics decorationMetrics;
  final ByteData _bytes;
  final Map<String, _TableRecord> _tables;
  final int _numGlyphs;
  final int _indexToLocFormat;
  final Map<int, int> _cmap;
  final List<double> _advances;
  final List<double> _lsbs;
  final List<int> _glyphOffsets;
  final Map<(int, int), double> _kern;
  final List<_PairPosSub> _gposKern;
  final _ColrData? _colr;

  static WindfoilFont parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final r = _ByteReader(data);
    final scalerType = r.readU32();
    if (scalerType != 0x00010000 && scalerType != 0x74727565) {
      throw FormatException('Unsupported font scaler type: $scalerType');
    }
    final numTables = r.readU16();
    r.readU16(); // searchRange
    r.readU16(); // entrySelector
    r.readU16(); // rangeShift

    final tables = <String, _TableRecord>{};
    for (var i = 0; i < numTables; i++) {
      final tag = String.fromCharCodes([
        r.readU8(),
        r.readU8(),
        r.readU8(),
        r.readU8(),
      ]);
      r.readU32(); // checksum
      final offset = r.readU32();
      final length = r.readU32();
      tables[tag] = _TableRecord(tag, offset, length);
    }

    int tableOffset(String tag) {
      final t = tables[tag];
      if (t == null) throw FormatException('Missing table $tag');
      return t.offset;
    }

    r.seek(tableOffset('head'));
    r.readFixed(); // version
    r.readFixed(); // fontRevision
    r.readU32(); // checksumAdjustment
    r.readU32(); // magicNumber
    r.readU16(); // flags
    final unitsPerEm = r.readU16();
    r.readU64(); // created
    r.readU64(); // modified
    r.readI16(); // xMin
    r.readI16(); // yMin
    r.readI16(); // xMax
    r.readI16(); // yMax
    r.readU16(); // macStyle
    r.readU16(); // lowestRecPPEM
    r.readI16(); // fontDirectionHint
    final indexToLocFormat = r.readI16();
    r.readI16(); // glyphDataFormat

    r.seek(tableOffset('hhea'));
    r.readFixed(); // version
    final ascender = r.readI16().toDouble();
    final descender = r.readI16().toDouble();
    final lineGap = r.readI16().toDouble();
    r.readU16(); // advanceWidthMax
    r.readI16(); // minLeftSideBearing
    r.readI16(); // minRightSideBearing
    r.readI16(); // xMaxExtent
    r.readI16(); // caretSlopeRise
    r.readI16(); // caretSlopeRun
    r.readI16(); // caretOffset
    for (var i = 0; i < 4; i++) r.readI16();
    r.readI16(); // metricDataFormat
    final numOfLongHorMetrics = r.readU16();

    r.seek(tableOffset('maxp'));
    r.readFixed(); // version
    final numGlyphs = r.readU16();

    // Decoration guides: post (underline) + OS/2 (strikeout), with sensible
    // em-relative fallbacks when a table is missing or degenerate.
    var underlinePos = -0.075 * unitsPerEm;
    var underlineThick = 0.05 * unitsPerEm;
    final post = tables['post'];
    if (post != null) {
      r.seek(post.offset + 8); // version(4) + italicAngle(4)
      final pos = r.readI16().toDouble();
      final thick = r.readI16().toDouble();
      if (thick > 0) {
        underlinePos = pos;
        underlineThick = thick;
      }
    }
    var strikeSize = underlineThick;
    var strikePos = 0.25 * unitsPerEm;
    final os2 = tables['OS/2'];
    if (os2 != null) {
      r.seek(os2.offset + 26); // ...ySuperscriptYOffset | yStrikeoutSize
      final size = r.readI16().toDouble();
      final pos = r.readI16().toDouble();
      if (size > 0) {
        strikeSize = size;
        strikePos = pos;
      }
    }

    final cmap = _parseCmap(data, tableOffset('cmap'));
    final (advances, lsbs) = _parseHmtx(
      data,
      tableOffset('hmtx'),
      numGlyphs,
      numOfLongHorMetrics,
    );
    final glyphOffsets = _parseLoca(
      data,
      tableOffset('loca'),
      numGlyphs,
      indexToLocFormat,
    );
    final kern = tables.containsKey('kern')
        ? _parseKern(data, tableOffset('kern'))
        : <(int, int), double>{};
    var gposKern = const <_PairPosSub>[];
    if (tables.containsKey('GPOS')) {
      try {
        gposKern = _parseGposKern(data, tableOffset('GPOS'));
      } catch (_) {
        gposKern = const []; // malformed GPOS → legacy kern only
      }
    }
    _ColrData? colr;
    if (tables.containsKey('COLR') && tables.containsKey('CPAL')) {
      try {
        colr = _ColrData.parse(
            data, tableOffset('COLR'), tableOffset('CPAL'));
      } catch (_) {
        colr = null; // malformed color tables → monochrome glyphs only
      }
    }

    return WindfoilFont._(
      unitsPerEm: unitsPerEm,
      verticalMetrics: VerticalMetrics(
        ascender: ascender,
        descender: descender,
        lineGap: lineGap,
      ),
      decorationMetrics: DecorationMetrics(
        underlinePosition: underlinePos,
        underlineThickness: underlineThick,
        strikeoutPosition: strikePos,
        strikeoutSize: strikeSize,
      ),
      bytes: data,
      tables: tables,
      numGlyphs: numGlyphs,
      indexToLocFormat: indexToLocFormat,
      cmap: cmap,
      advances: advances,
      lsbs: lsbs,
      glyphOffsets: glyphOffsets,
      kern: kern,
      gposKern: gposKern,
      colr: colr,
    );
  }

  static Map<int, int> _parseCmap(ByteData data, int offset) {
    final r = _ByteReader(data)..seek(offset);
    r.readU16(); // version
    final numSubtables = r.readU16();
    final subtables = <({int platformId, int encodingId, int offset})>[];
    for (var i = 0; i < numSubtables; i++) {
      subtables.add((
        platformId: r.readU16(),
        encodingId: r.readU16(),
        offset: r.readU32(),
      ));
    }

    int? fmt4Offset;
    int? fmt12Offset;
    for (final sub in subtables) {
      if (sub.platformId != 3 && sub.platformId != 0) continue;
      final subOffset = offset + sub.offset;
      final format = data.getUint16(subOffset, Endian.big);
      if (format == 12) fmt12Offset ??= subOffset;
      if (format == 4) fmt4Offset ??= subOffset;
    }
    if (fmt12Offset != null) return _parseCmapFormat12(data, fmt12Offset);
    if (fmt4Offset != null) {
      final sr = _ByteReader(data)..seek(fmt4Offset);
      sr.readU16(); // format
      return _parseCmapFormat4(data, fmt4Offset, sr);
    }
    throw FormatException('Unsupported cmap subtable');
  }

  /// Format 12: sequential-group coverage of the full Unicode range
  /// (required for emoji — format 4 is BMP-only).
  static Map<int, int> _parseCmapFormat12(ByteData data, int subOffset) {
    final numGroups = data.getUint32(subOffset + 12, Endian.big);
    final map = <int, int>{};
    var total = 0;
    for (var g = 0; g < numGroups; g++) {
      final o = subOffset + 16 + g * 12;
      final start = data.getUint32(o, Endian.big);
      final end = data.getUint32(o + 4, Endian.big);
      final startGlyph = data.getUint32(o + 8, Endian.big);
      total += end - start + 1;
      if (total > 300000) break; // pathological font guard
      for (var c = start; c <= end; c++) {
        map[c] = startGlyph + (c - start);
      }
    }
    return map;
  }

  static Map<int, int> _parseCmapFormat4(
    ByteData data,
    int subOffset,
    _ByteReader sr,
  ) {
    final length = sr.readU16();
    sr.readU16(); // language
    final segCountX2 = sr.readU16();
    final segCount = segCountX2 ~/ 2;
    sr.readU16(); // searchRange
    sr.readU16(); // entrySelector
    sr.readU16(); // rangeShift

    final endCodes = <int>[];
    for (var i = 0; i < segCount; i++) endCodes.add(sr.readU16());
    sr.readU16(); // reservedPad
    final startCodes = <int>[];
    for (var i = 0; i < segCount; i++) startCodes.add(sr.readU16());
    final idDeltas = <int>[];
    for (var i = 0; i < segCount; i++) idDeltas.add(sr.readI16());
    final idRangeOffsets = <int>[];
    for (var i = 0; i < segCount; i++) idRangeOffsets.add(sr.readU16());

    final glyphIdArrayPos = sr.position;
    final map = <int, int>{};
    for (var i = 0; i < segCount; i++) {
      final start = startCodes[i];
      final end = endCodes[i];
      final delta = idDeltas[i];
      final rangeOffset = idRangeOffsets[i];
      if (start == 0xFFFF && end == 0xFFFF) continue;
      for (var c = start; c <= end; c++) {
        if (rangeOffset == 0) {
          map[c] = (c + delta) & 0xFFFF;
        } else {
          final glyphIndexPos =
              glyphIdArrayPos + rangeOffset + (c - start) * 2 - segCount * 2;
          final gr = _ByteReader(data)..seek(glyphIndexPos);
          final glyphIndex = gr.readU16();
          if (glyphIndex != 0) map[c] = (glyphIndex + delta) & 0xFFFF;
        }
      }
    }
    return map;
  }

  static (List<double>, List<double>) _parseHmtx(
    ByteData data,
    int offset,
    int numGlyphs,
    int numOfLongHorMetrics,
  ) {
    final r = _ByteReader(data)..seek(offset);
    final advances = List<double>.filled(numGlyphs, 0);
    final lsbs = List<double>.filled(numGlyphs, 0);
    for (var i = 0; i < numOfLongHorMetrics; i++) {
      advances[i] = r.readU16().toDouble();
      lsbs[i] = r.readI16().toDouble();
    }
    final lastAdvance = numOfLongHorMetrics > 0
        ? advances[numOfLongHorMetrics - 1]
        : 0.0;
    for (var i = numOfLongHorMetrics; i < numGlyphs; i++) {
      advances[i] = lastAdvance;
      lsbs[i] = r.readI16().toDouble();
    }
    return (advances, lsbs);
  }

  static List<int> _parseLoca(
    ByteData data,
    int offset,
    int numGlyphs,
    int indexToLocFormat,
  ) {
    final r = _ByteReader(data)..seek(offset);
    final offsets = List<int>.filled(numGlyphs + 1, 0);
    if (indexToLocFormat == 0) {
      for (var i = 0; i <= numGlyphs; i++) {
        offsets[i] = r.readU16() * 2;
      }
    } else {
      for (var i = 0; i <= numGlyphs; i++) {
        offsets[i] = r.readU32();
      }
    }
    return offsets;
  }

  static Map<(int, int), double> _parseKern(ByteData data, int offset) {
    final r = _ByteReader(data)..seek(offset);
    final version = r.readU16();
    final nTables = version == 0 ? r.readU16() : r.readU32();
    final pairs = <(int, int), double>{};
    for (var t = 0; t < nTables; t++) {
      final tableStart = r.position;
      final subVersion = r.readU16();
      final subLength = r.readU16();
      final coverage = r.readU16();
      if (subVersion == 0 && (coverage & 0xFFFE) == 0) {
        final pairCount = r.readU16();
        r.readU16(); // searchRange
        r.readU16(); // entrySelector
        r.readU16(); // rangeShift
        for (var i = 0; i < pairCount; i++) {
          final left = r.readU16();
          final right = r.readU16();
          final value = r.readI16().toDouble();
          pairs[(left, right)] = value;
        }
      } else {
        r.seek(tableStart + subLength);
      }
    }
    return pairs;
  }

  int? _glyphId(String ch) {
    if (ch.isEmpty) return null;
    return _cmap[ch.runes.first];
  }

  bool hasGlyph(String ch) => _glyphId(ch) != null;

  /// True when the font carries COLR v0 layered color glyphs.
  bool get hasColorGlyphs => _colr != null;

  /// COLR v0 layers for the glyph mapped from `cp`, in painting order
  /// (bottom first); null when the font has no color glyph for it.
  List<ColrLayer>? colrForCodePoint(int cp) {
    final colr = _colr;
    if (colr == null) return null;
    final gid = _cmap[cp];
    if (gid == null) return null;
    return colr.layersFor(gid);
  }

  double advanceOfGlyphId(int gid) =>
      gid >= 0 && gid < _advances.length ? _advances[gid] : 0;

  double advanceOf(String ch) {
    // cmap miss → .notdef (glyph 0) advance, so unsupported characters
    // occupy tofu-sized space instead of collapsing to zero width.
    final id = _glyphId(ch) ?? 0;
    return _advances[id];
  }

  double kerningOf(String a, String b) {
    final left = _glyphId(a);
    final right = _glyphId(b);
    if (left == null || right == null) return 0;
    // When a GPOS 'kern' feature exists it supersedes the legacy kern table.
    if (_gposKern.isNotEmpty) {
      for (final sub in _gposKern) {
        final v = sub.kern(left, right);
        if (v != null) return v;
      }
      return 0;
    }
    return _kern[(left, right)] ?? 0;
  }

  GlyphOutline? glyphQuads(String ch) =>
      glyphOutlineById(_glyphId(ch) ?? 0); // cmap miss → .notdef tofu

  /// Outline of a glyph by ID (COLR layers reference glyph IDs directly).
  GlyphOutline? glyphOutlineById(int id) {
    if (id < 0 || id >= _numGlyphs) return null;
    final glyfOffset = _tables['glyf']!.offset;
    final start = _glyphOffsets[id];
    final end = _glyphOffsets[id + 1];
    if (start == end) return null;

    final r = _ByteReader(_bytes)..seek(glyfOffset + start);
    final numberOfContours = r.readI16();
    r.readI16(); // xMin
    r.readI16(); // yMin
    r.readI16(); // xMax
    r.readI16(); // yMax

    final quads = <double>[];
    if (numberOfContours >= 0) {
      _parseSimpleGlyph(r, numberOfContours, quads);
    } else {
      _parseCompositeGlyph(r, glyfOffset, quads);
    }

    if (quads.isEmpty) return null;
    var x0 = double.infinity;
    var y0 = double.infinity;
    var x1 = -double.infinity;
    var y1 = -double.infinity;
    for (var i = 0; i < quads.length; i += 2) {
      final x = quads[i];
      final y = quads[i + 1];
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
    return GlyphOutline(
      quads: quads,
      advance: _advances[id],
      bbox: [x0, y0, x1, y1],
    );
  }

  void _parseSimpleGlyph(_ByteReader r, int numberOfContours, List<double> out) {
    final endPts = List<int>.generate(numberOfContours, (_) => r.readU16());
    final instructionLength = r.readU16();
    r.seek(r.position + instructionLength);

    final pointCount = endPts.last + 1;
    final flags = List<int>.filled(pointCount, 0);
    var i = 0;
    while (i < pointCount) {
      final flag = r.readU8();
      flags[i] = flag;
      i++;
      if (flag & 0x08 != 0) {
        final repeat = r.readU8();
        for (var j = 0; j < repeat; j++) {
          flags[i] = flag;
          i++;
        }
      }
    }

    final xs = List<double>.filled(pointCount, 0);
    var x = 0.0;
    for (var p = 0; p < pointCount; p++) {
      final flag = flags[p];
      if (flag & 0x02 != 0) {
        x += (flag & 0x10) != 0 ? r.readU8() : -r.readU8();
      } else if (flag & 0x10 == 0) {
        x += r.readI16();
      }
      xs[p] = x;
    }

    final ys = List<double>.filled(pointCount, 0);
    var y = 0.0;
    for (var p = 0; p < pointCount; p++) {
      final flag = flags[p];
      if (flag & 0x04 != 0) {
        y += (flag & 0x20) != 0 ? r.readU8() : -r.readU8();
      } else if (flag & 0x20 == 0) {
        y += r.readI16();
      }
      ys[p] = y;
    }

    var start = 0;
    for (final end in endPts) {
      _contourToQuads(xs, ys, flags, start, end, out);
      start = end + 1;
    }
  }

  void _contourToQuads(
    List<double> xs,
    List<double> ys,
    List<int> flags,
    int start,
    int end,
    List<double> out,
  ) {
    final n = end - start + 1;
    if (n < 2) return;

    bool isOn(int i) => flags[start + i] & 0x01 != 0;
    double gx(int i) => xs[start + i];
    double gy(int i) => -ys[start + i];

    // Expand: insert implied on-curve midpoints between consecutive off-curve points.
    final ex = <double>[];
    final ey = <double>[];
    final eon = <bool>[];

    for (var i = 0; i < n; i++) {
      final on = isOn(i);
      if (!on && ex.isNotEmpty && !eon.last) {
        ex.add((ex.last + gx(i)) / 2);
        ey.add((ey.last + gy(i)) / 2);
        eon.add(true);
      }
      ex.add(gx(i));
      ey.add(gy(i));
      eon.add(on);
    }

    // Handle wrap: last and first both off-curve.
    if (!eon.last && !eon.first) {
      ex.add((ex.last + ex.first) / 2);
      ey.add((ey.last + ey.first) / 2);
      eon.add(true);
    }

    final m = ex.length;

    // Find first on-curve point.
    var firstOn = 0;
    for (var i = 0; i < m; i++) {
      if (eon[i]) { firstOn = i; break; }
    }

    var cx = ex[firstOn];
    var cy = ey[firstOn];
    final sx = cx;
    final sy = cy;

    var j = 1;
    while (j < m) {
      final idx = (firstOn + j) % m;
      if (eon[idx]) {
        _lineToQuad(cx, cy, ex[idx], ey[idx], out);
        cx = ex[idx]; cy = ey[idx];
        j++;
      } else {
        final nidx = (firstOn + j + 1) % m;
        out.addAll([cx, cy, ex[idx], ey[idx], ex[nidx], ey[nidx]]);
        cx = ex[nidx]; cy = ey[nidx];
        j += 2;
      }
    }

    if ((cx - sx).abs() > 1e-10 || (cy - sy).abs() > 1e-10) {
      _lineToQuad(cx, cy, sx, sy, out);
    }
  }

  void _lineToQuad(double x0, double y0, double x1, double y1, List<double> out) {
    out.addAll([
      x0, y0, (x0 + x1) / 2, (y0 + y1) / 2, x1, y1,
    ]);
  }

  void _parseCompositeGlyph(
    _ByteReader r,
    int glyfOffset,
    List<double> out,
  ) {
    while (true) {
      final flags = r.readU16();
      final glyphIndex = r.readU16();
      var e = 1.0;
      var f = 0.0;
      var e2 = 0.0;
      var f2 = 1.0;
      double arg1;
      double arg2;

      if (flags & 0x01 != 0) {
        arg1 = r.readI16().toDouble();
        arg2 = r.readI16().toDouble();
      } else {
        arg1 = r.readI8().toDouble();
        arg2 = r.readI8().toDouble();
      }

      if (flags & 0x0008 != 0) {
        // WE_HAVE_A_SCALE: single uniform scale
        final scale = r.readI16() / 16384.0;
        e = scale;
        f2 = scale;
      } else if (flags & 0x0040 != 0) {
        // WE_HAVE_AN_X_AND_YSCALE
        e = r.readI16() / 16384.0;
        f2 = r.readI16() / 16384.0;
      } else if (flags & 0x0080 != 0) {
        // WE_HAVE_A_TWO_BY_TWO
        e = r.readI16() / 16384.0;
        f = r.readI16() / 16384.0;
        e2 = r.readI16() / 16384.0;
        f2 = r.readI16() / 16384.0;
      }

      final start = _glyphOffsets[glyphIndex];
      final end = _glyphOffsets[glyphIndex + 1];
      if (start != end) {
        final cr = _ByteReader(_bytes)..seek(glyfOffset + start);
        final numberOfContours = cr.readI16();
        cr.readI16();
        cr.readI16();
        cr.readI16();
        cr.readI16();
        final sub = <double>[];
        if (numberOfContours >= 0) {
          _parseSimpleGlyph(cr, numberOfContours, sub);
        } else {
          _parseCompositeGlyph(cr, glyfOffset, sub);
        }
        // Sub-glyph points are already Y-flipped; the font-space Y offset
        // must be flipped too so the composite lands correctly.
        final dy = -arg2;
        for (var i = 0; i < sub.length; i += 2) {
          final x = sub[i];
          final y = sub[i + 1];
          sub[i] = e * x + e2 * y + arg1;
          sub[i + 1] = f * x + f2 * y + dy;
        }
        out.addAll(sub);
      }

      if (flags & 0x0020 == 0) break;
    }
  }
}

extension on _ByteReader {
  int readU64() {
    final hi = readU32();
    final lo = readU32();
    return (hi << 32) | lo;
  }
}

// ---------------------------------------------------------------------------
// GPOS pair kerning ('kern' feature, lookup type 2, incl. type-9 extensions).
// Only the first glyph's horizontal advance adjustment is read — that is what
// kerning is. Evaluated lazily per pair against compact range structures, so
// class-based CJK fonts don't explode into pair maps.

int _popcount8(int v) {
  var n = 0;
  for (var b = v & 0xFF; b != 0; b >>= 1) {
    n += b & 1;
  }
  return n;
}

/// Coverage table: glyph → coverage index (null when not covered).
class _GposCoverage {
  _GposCoverage(this.starts, this.ends, this.indexBase);

  final List<int> starts;
  final List<int> ends;
  final List<int> indexBase;

  static _GposCoverage parse(ByteData d, int off) {
    final fmt = d.getUint16(off, Endian.big);
    final starts = <int>[], ends = <int>[], base = <int>[];
    if (fmt == 1) {
      final count = d.getUint16(off + 2, Endian.big);
      for (var i = 0; i < count; i++) {
        final g = d.getUint16(off + 4 + i * 2, Endian.big);
        starts.add(g);
        ends.add(g);
        base.add(i);
      }
    } else if (fmt == 2) {
      final count = d.getUint16(off + 2, Endian.big);
      for (var i = 0; i < count; i++) {
        final o = off + 4 + i * 6;
        starts.add(d.getUint16(o, Endian.big));
        ends.add(d.getUint16(o + 2, Endian.big));
        base.add(d.getUint16(o + 4, Endian.big));
      }
    } else {
      throw const FormatException('coverage format');
    }
    return _GposCoverage(starts, ends, base);
  }

  int? indexOf(int g) {
    var lo = 0, hi = starts.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (g < starts[mid]) {
        hi = mid - 1;
      } else if (g > ends[mid]) {
        lo = mid + 1;
      } else {
        return indexBase[mid] + (g - starts[mid]);
      }
    }
    return null;
  }
}

/// ClassDef table: glyph → class (0 when unlisted).
class _GposClassDef {
  _GposClassDef(this.starts, this.ends, this.classes);

  final List<int> starts;
  final List<int> ends;
  final List<int> classes; // per range (fmt2) or per glyph (fmt1 expanded)

  static _GposClassDef parse(ByteData d, int off) {
    final fmt = d.getUint16(off, Endian.big);
    final starts = <int>[], ends = <int>[], classes = <int>[];
    if (fmt == 1) {
      final startGlyph = d.getUint16(off + 2, Endian.big);
      final count = d.getUint16(off + 4, Endian.big);
      for (var i = 0; i < count; i++) {
        starts.add(startGlyph + i);
        ends.add(startGlyph + i);
        classes.add(d.getUint16(off + 6 + i * 2, Endian.big));
      }
    } else if (fmt == 2) {
      final count = d.getUint16(off + 2, Endian.big);
      for (var i = 0; i < count; i++) {
        final o = off + 4 + i * 6;
        starts.add(d.getUint16(o, Endian.big));
        ends.add(d.getUint16(o + 2, Endian.big));
        classes.add(d.getUint16(o + 4, Endian.big));
      }
    } else {
      throw const FormatException('classdef format');
    }
    return _GposClassDef(starts, ends, classes);
  }

  int classOf(int g) {
    var lo = 0, hi = starts.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (g < starts[mid]) {
        hi = mid - 1;
      } else if (g > ends[mid]) {
        lo = mid + 1;
      } else {
        return classes[mid];
      }
    }
    return 0;
  }
}

sealed class _PairPosSub {
  /// First-glyph x-advance adjustment, or null when the pair isn't covered
  /// by this subtable.
  double? kern(int g1, int g2);
}

class _PairPos1 extends _PairPosSub {
  _PairPos1(this.coverage, this.seconds, this.advances);

  final _GposCoverage coverage;
  final List<Uint16List> seconds; // per first-glyph pair set, sorted
  final List<Float32List> advances;

  @override
  double? kern(int g1, int g2) {
    final idx = coverage.indexOf(g1);
    if (idx == null || idx >= seconds.length) return null;
    final list = seconds[idx];
    var lo = 0, hi = list.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (g2 < list[mid]) {
        hi = mid - 1;
      } else if (g2 > list[mid]) {
        lo = mid + 1;
      } else {
        return advances[idx][mid];
      }
    }
    return null;
  }
}

class _PairPos2 extends _PairPosSub {
  _PairPos2(this.coverage, this.classDef1, this.classDef2, this.class2Count,
      this.xAdvance);

  final _GposCoverage coverage;
  final _GposClassDef classDef1;
  final _GposClassDef classDef2;
  final int class2Count;
  final Float32List xAdvance; // class1Count × class2Count

  @override
  double? kern(int g1, int g2) {
    if (coverage.indexOf(g1) == null) return null;
    final c1 = classDef1.classOf(g1);
    final c2 = classDef2.classOf(g2);
    final i = c1 * class2Count + c2;
    if (i < 0 || i >= xAdvance.length) return null;
    return xAdvance[i];
  }
}

_PairPosSub? _parsePairPosSubtable(ByteData d, int off) {
  final fmt = d.getUint16(off, Endian.big);
  final coverageOff = off + d.getUint16(off + 2, Endian.big);
  final vf1 = d.getUint16(off + 4, Endian.big);
  final vf2 = d.getUint16(off + 6, Endian.big);
  if (vf1 & 0x0004 == 0) return null; // no x-advance on the first glyph
  final size1 = _popcount8(vf1) * 2;
  final size2 = _popcount8(vf2) * 2;
  final xAdvOff = _popcount8(vf1 & 0x0003) * 2; // XPlacement/YPlacement first

  if (fmt == 1) {
    final coverage = _GposCoverage.parse(d, coverageOff);
    final pairSetCount = d.getUint16(off + 8, Endian.big);
    final seconds = <Uint16List>[];
    final advances = <Float32List>[];
    for (var i = 0; i < pairSetCount; i++) {
      final psOff = off + d.getUint16(off + 10 + i * 2, Endian.big);
      final count = d.getUint16(psOff, Endian.big);
      final gs = Uint16List(count);
      final adv = Float32List(count);
      final recSize = 2 + size1 + size2;
      for (var j = 0; j < count; j++) {
        final ro = psOff + 2 + j * recSize;
        gs[j] = d.getUint16(ro, Endian.big);
        adv[j] = d.getInt16(ro + 2 + xAdvOff, Endian.big).toDouble();
      }
      seconds.add(gs);
      advances.add(adv);
    }
    return _PairPos1(coverage, seconds, advances);
  }
  if (fmt == 2) {
    final coverage = _GposCoverage.parse(d, coverageOff);
    final classDef1 = _GposClassDef.parse(d, off + d.getUint16(off + 8, Endian.big));
    final classDef2 = _GposClassDef.parse(d, off + d.getUint16(off + 10, Endian.big));
    final class1Count = d.getUint16(off + 12, Endian.big);
    final class2Count = d.getUint16(off + 14, Endian.big);
    final recSize = size1 + size2;
    final xAdv = Float32List(class1Count * class2Count);
    for (var i = 0; i < class1Count * class2Count; i++) {
      final ro = off + 16 + i * recSize;
      xAdv[i] = d.getInt16(ro + xAdvOff, Endian.big).toDouble();
    }
    return _PairPos2(coverage, classDef1, classDef2, class2Count, xAdv);
  }
  return null;
}

/// Collect the PairPos subtables reachable from the GPOS 'kern' feature.
List<_PairPosSub> _parseGposKern(ByteData d, int gpos) {
  final featureListOff = gpos + d.getUint16(gpos + 6, Endian.big);
  final lookupListOff = gpos + d.getUint16(gpos + 8, Endian.big);

  // FeatureList → lookup indices of every 'kern' feature (any script/lang).
  final lookupIndices = <int>{};
  final featureCount = d.getUint16(featureListOff, Endian.big);
  for (var i = 0; i < featureCount; i++) {
    final recOff = featureListOff + 2 + i * 6;
    final tag = String.fromCharCodes([
      d.getUint8(recOff),
      d.getUint8(recOff + 1),
      d.getUint8(recOff + 2),
      d.getUint8(recOff + 3),
    ]);
    if (tag != 'kern') continue;
    final featureOff = featureListOff + d.getUint16(recOff + 4, Endian.big);
    final lookupCount = d.getUint16(featureOff + 2, Endian.big);
    for (var j = 0; j < lookupCount; j++) {
      lookupIndices.add(d.getUint16(featureOff + 4 + j * 2, Endian.big));
    }
  }
  if (lookupIndices.isEmpty) return const [];

  final subs = <_PairPosSub>[];
  final lookupCount = d.getUint16(lookupListOff, Endian.big);
  for (final li in lookupIndices) {
    if (li >= lookupCount) continue;
    final lookupOff =
        lookupListOff + d.getUint16(lookupListOff + 2 + li * 2, Endian.big);
    final lookupType = d.getUint16(lookupOff, Endian.big);
    final subCount = d.getUint16(lookupOff + 4, Endian.big);
    for (var si = 0; si < subCount; si++) {
      var subOff = lookupOff + d.getUint16(lookupOff + 6 + si * 2, Endian.big);
      var type = lookupType;
      if (type == 9) {
        // ExtensionPos: format(2) + extensionLookupType(2) + offset32.
        type = d.getUint16(subOff + 2, Endian.big);
        subOff = subOff + d.getUint32(subOff + 4, Endian.big);
      }
      if (type != 2) continue;
      final sub = _parsePairPosSubtable(d, subOff);
      if (sub != null) subs.add(sub);
    }
  }
  return subs;
}

// ---------------------------------------------------------------------------
// COLR v0 + CPAL: layered color glyphs. Each base glyph maps to an ordered
// run of (layer glyph id, palette color) — every layer is an ordinary glyf
// outline, so the coverage shader renders color emoji natively as N colored
// instances.

class ColrLayer {
  const ColrLayer(this.glyphId, this.color);

  final int glyphId;

  /// Straight-alpha RGBA 0..1; null means palette index 0xFFFF (use the
  /// current text color).
  final List<double>? color;
}

class _ColrData {
  _ColrData(this.baseGids, this.firstLayer, this.layerCounts, this.layerGids,
      this.layerPalette, this.palette);

  final Uint16List baseGids; // sorted
  final Uint16List firstLayer;
  final Uint16List layerCounts;
  final Uint16List layerGids;
  final Uint16List layerPalette;
  final List<List<double>> palette; // palette 0, RGBA 0..1

  static _ColrData parse(ByteData d, int colr, int cpal) {
    final version = d.getUint16(colr, Endian.big);
    if (version != 0) throw const FormatException('COLR v1 unsupported');
    final numBase = d.getUint16(colr + 2, Endian.big);
    final baseOff = colr + d.getUint32(colr + 4, Endian.big);
    final layerOff = colr + d.getUint32(colr + 8, Endian.big);
    final numLayers = d.getUint16(colr + 12, Endian.big);

    final baseGids = Uint16List(numBase);
    final firstLayer = Uint16List(numBase);
    final layerCounts = Uint16List(numBase);
    for (var i = 0; i < numBase; i++) {
      final o = baseOff + i * 6;
      baseGids[i] = d.getUint16(o, Endian.big);
      firstLayer[i] = d.getUint16(o + 2, Endian.big);
      layerCounts[i] = d.getUint16(o + 4, Endian.big);
    }
    final layerGids = Uint16List(numLayers);
    final layerPalette = Uint16List(numLayers);
    for (var i = 0; i < numLayers; i++) {
      final o = layerOff + i * 4;
      layerGids[i] = d.getUint16(o, Endian.big);
      layerPalette[i] = d.getUint16(o + 2, Endian.big);
    }

    // CPAL header; we only read palette 0.
    final numPaletteEntries = d.getUint16(cpal + 2, Endian.big);
    final colorRecordsOff = cpal + d.getUint32(cpal + 8, Endian.big);
    final numPalettes = d.getUint16(cpal + 4, Endian.big);
    final firstIndex =
        numPalettes > 0 ? d.getUint16(cpal + 12, Endian.big) : 0;
    final palette = <List<double>>[];
    for (var i = 0; i < numPaletteEntries; i++) {
      final o = colorRecordsOff + (firstIndex + i) * 4;
      final b = d.getUint8(o);
      final g = d.getUint8(o + 1);
      final r = d.getUint8(o + 2);
      final a = d.getUint8(o + 3);
      palette.add([r / 255, g / 255, b / 255, a / 255]);
    }
    return _ColrData(
        baseGids, firstLayer, layerCounts, layerGids, layerPalette, palette);
  }

  List<ColrLayer>? layersFor(int gid) {
    var lo = 0, hi = baseGids.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (gid < baseGids[mid]) {
        hi = mid - 1;
      } else if (gid > baseGids[mid]) {
        lo = mid + 1;
      } else {
        final start = firstLayer[mid];
        final count = layerCounts[mid];
        return [
          for (var i = start; i < start + count; i++)
            ColrLayer(
              layerGids[i],
              layerPalette[i] == 0xFFFF || layerPalette[i] >= palette.length
                  ? null
                  : palette[layerPalette[i]],
            ),
        ];
      }
    }
    return null;
  }
}
