import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'color_bitmap.dart';

part 'font_variations.dart';

enum FillRule { nonzero, evenOdd }

/// The fi/fl/ffi/ffl → precomposed compatibility ligatures, longest-first so
/// neither an ordered replace nor a char-walk splits "ffi" into f+"fi".
const _basicLigatures = <(String, String)>[
  ('ffi', 'ﬃ'),
  ('ffl', 'ﬄ'),
  ('fi', 'ﬁ'),
  ('fl', 'ﬂ'),
];

/// Substitute the common Latin ligatures (ffi, ffl, fi, fl) with their
/// precomposed compatibility code points when the font maps them — a
/// pragmatic GSUB-'liga' subset that rides the existing cmap pipeline.
/// Callers should skip this when letterSpacing != 0 (typographic rule).
String applyBasicLigatures(String text, GPUFont font) {
  var out = text;
  for (final (from, to) in _basicLigatures) {
    if (out.contains(from) && font.hasGlyph(to)) {
      out = out.replaceAll(from, to);
    }
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

  double readFixed() {
    final v = readI32();
    return v / 65536.0;
  }
}

class GPUFont {
  GPUFont._({
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
    required this._gposKern,
    this._colr,
    this._bitmap,
    this._fvar,
    this._avar,
    this._gvar,
    this._hvar,
    this._mvar,
    this.variationCoordinates = const {},
    this._normCoords,
    this._gvarSharedScalars,
    this._base,
  });

  final int unitsPerEm;
  final VerticalMetrics verticalMetrics;
  final DecorationMetrics decorationMetrics;
  final ByteData _bytes;

  /// Raw font file bytes (for HarfBuzz face creation). Shared with variants.
  ByteData get fontBytes => _bytes;
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

  /// Color-bitmap glyph source (sbix or CBDT/CBLC); null for outline-only or
  /// COLR-only fonts. Shared with variants (same font bytes).
  final BitmapGlyphSource? _bitmap;
  final _Fvar? _fvar;
  final _Avar? _avar;
  final _Gvar? _gvar;
  final _Hvar? _hvar;
  final _Mvar? _mvar;

  /// Design-space coordinates this instance actually renders (non-default axes
  /// only); empty for the base instance.
  ///
  /// These are the requested coordinates after clamping to the axis range and
  /// snapping to the [variationQuantizationSteps] grid, so they can differ from
  /// what was passed to [GPUFontVariations.variant] — deterministically, and
  /// never by more than half a grid step. Even [GPUFontVariations.variantExact]
  /// rounds to F2Dot14 resolution, which not every design value survives.
  final Map<String, double> variationCoordinates;

  /// Normalized (F2Dot14-rounded, avar-mapped) coordinates; null on the base.
  final Float64List? _normCoords;

  /// gvar shared-tuple scalars at [_normCoords]; null on the base. Non-null
  /// whenever both `_gvar` and `_normCoords` are.
  final Float64List? _gvarSharedScalars;

  /// Base font this variant was instanced from; null on the base.
  final GPUFont? _base;

  /// Grid resolution for [GPUFontVariations.variant]: grid points per unit of
  /// normalized coordinate space, so normalized coordinates snap to multiples
  /// of `16384 ~/ steps` F2Dot14 ticks. Must divide 16384 (i.e. be a power of
  /// two ≤ 16384); null disables snapping.
  ///
  /// This exists because every distinct coordinate is a distinct font identity,
  /// which bands a fresh copy of every glyph it touches into the shared atlas.
  /// Eviction reclaims those once nothing displays them, but only quantization
  /// bounds how many a single animating axis can mint WHILE it is on screen.
  /// At the default of 32 an axis has 64 reachable instances end to end.
  ///
  /// The cost is a bounded outline error, worst-case half a grid step. Measured
  /// on Google Sans Flex `wght` at this default: ≈7 font units, i.e. 0.08px at
  /// 22px and 0.34px at 96px. Raise it for large display text, lower it to make
  /// animation cheaper, or set null (see [GPUFontVariations.variantExact]) when
  /// exact coordinates matter more than memory.
  ///
  /// Note the atlas is size-independent — outlines are stored in font units and
  /// scaled per draw — so one grid must serve every size the font renders at.
  static int? variationQuantizationSteps = 32;

  /// Max live variant instances per base font (LRU). Bounds atlas + HB face
  /// pressure from [variantExact] / many static weights.
  static const variantCacheCapacity = 64;

  /// Called with each variant instance dropped from a base font's cache (LRU
  /// overflow or [clearVariantCache]) so engine-side caches — HB font handle,
  /// segment metrics — release immediately instead of waiting for GC, which
  /// atlas references can defer indefinitely. Set by [GPUTextEngine];
  /// eviction is idempotent — re-shaping an evicted variant rebuilds it.
  static void Function(GPUFont evicted)? onVariantEvicted;

  /// Variant instances by normalized coordinate key (base font only).
  /// LinkedHashMap: re-insert on hit for LRU eviction at [variantCacheCapacity].
  final Map<String, GPUFont> _variantCache = <String, GPUFont>{};

  /// Test hook: number of cached variant instances on this base font.
  @visibleForTesting
  int get debugVariantCacheLength => _variantCache.length;

  /// Drop all cached variants, releasing their shaper caches through
  /// [onVariantEvicted]. No-op on non-base fonts.
  void clearVariantCache() {
    if (_base != null) return;
    final evicted = List<GPUFont>.from(_variantCache.values);
    _variantCache.clear();
    for (final v in evicted) {
      onVariantEvicted?.call(v);
    }
  }

  /// Evict HB-facing resources for this font and every cached variant.
  /// Used by [GPUTextEngine.unregisterFont]; callers pass [evict] from the
  /// active [TextShaper]. Optional [onEach] runs for the base and each
  /// variant before eviction (e.g. clear segment metrics).
  void releaseShaperCaches(
    void Function(GPUFont font) evict, {
    void Function(GPUFont font)? onEach,
  }) {
    if (_base == null) {
      for (final v in List<GPUFont>.from(_variantCache.values)) {
        onEach?.call(v);
        evict(v);
      }
      _variantCache.clear();
    }
    onEach?.call(this);
    evict(this);
  }

  /// HVAR-adjusted advances, memoized per glyph id (variants only). NaN is the
  /// "not yet computed" sentinel — 0 is a legitimate advance — which keeps the
  /// warm read to one load and one compare, matching the base font's cost.
  Float64List? _advCache;

  /// Advance for `gid` in font units, with this instance's HVAR delta applied.
  /// Out-of-range ids yield 0 (matching a .notdef-less lookup).
  double _advanceFor(int gid) {
    if (gid < 0 || gid >= _advances.length) return 0;
    final hvar = _hvar;
    final coords = _normCoords;
    if (hvar == null || coords == null) return _advances[gid];
    final cache = _advCache ??= Float64List(_advances.length)
      ..fillRange(0, _advances.length, double.nan);
    final cached = cache[gid];
    if (cached == cached) return cached; // non-NaN → hit
    return cache[gid] = _advances[gid] + hvar.advanceDelta(gid, coords);
  }

  static GPUFont parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final r = _ByteReader(data);
    var scalerType = r.readU32();
    // TrueType Collection: skip to face 0's sfnt header. Table records inside a
    // .ttc hold file-absolute offsets, so only the reader position moves and the
    // rest of the parse is unchanged. (Android system fonts such as Noto CJK
    // ship as .ttc; this unwraps the common -Regular face.)
    if (scalerType == 0x74746366) {
      // 'ttcf'
      r.readU16(); // majorVersion
      r.readU16(); // minorVersion
      r.readU32(); // numFonts
      r.seek(r.readU32()); // face 0 table-directory offset
      scalerType = r.readU32();
    }
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
    for (var i = 0; i < 4; i++) {
      r.readI16();
    }
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
    // Color-bitmap fonts (Noto Color Emoji / CBDT) carry no glyf/loca — their
    // glyphs are PNGs in CBDT, not outlines. Tolerate their absence: the
    // outline path returns null and the bitmap path takes over.
    final glyphOffsets = tables.containsKey('loca') && tables.containsKey('glyf')
        ? _parseLoca(data, tableOffset('loca'), numGlyphs, indexToLocFormat)
        : const <int>[];
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
        colr = _ColrData.parse(data, tableOffset('COLR'), tableOffset('CPAL'));
      } catch (_) {
        colr = null; // malformed color tables → monochrome glyphs only
      }
    }

    // Color-bitmap glyphs (sbix / CBDT+CBLC): the platform emoji fonts.
    // parseBitmapGlyphs guards its own parse; malformed → null (delegation).
    final bitmap = parseBitmapGlyphs(
      data: data,
      numGlyphs: numGlyphs,
      sbixOffset: tables.containsKey('sbix') ? tableOffset('sbix') : null,
      cblcOffset: tables.containsKey('CBLC') ? tableOffset('CBLC') : null,
      cbdtOffset: tables.containsKey('CBDT') ? tableOffset('CBDT') : null,
    );

    // Variation tables stand or fall together — without fvar axes none of
    // the delta tables can be interpreted.
    _Fvar? fvar;
    _Avar? avar;
    _Gvar? gvar;
    _Hvar? hvar;
    _Mvar? mvar;
    if (tables.containsKey('fvar')) {
      try {
        fvar = _Fvar.parse(data, tableOffset('fvar'));
        final axisCount = fvar.axes.length;
        if (tables.containsKey('avar')) {
          avar = _Avar.parse(data, tableOffset('avar'), axisCount);
        }
        if (tables.containsKey('gvar')) {
          gvar = _Gvar.parse(data, tableOffset('gvar'));
        }
        if (tables.containsKey('HVAR')) {
          hvar = _Hvar.parse(data, tableOffset('HVAR'));
        }
        if (tables.containsKey('MVAR')) {
          mvar = _Mvar.parse(data, tableOffset('MVAR'));
        }
      } catch (_) {
        fvar = null;
        avar = null;
        gvar = null;
        hvar = null;
        mvar = null; // malformed variations → static default instance only
      }
    }
    return GPUFont._(
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
      bitmap: bitmap,
      fvar: fvar,
      avar: avar,
      gvar: gvar,
      hvar: hvar,
      mvar: mvar,
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
    sr.readU16(); // length
    sr.readU16(); // language
    final segCountX2 = sr.readU16();
    final segCount = segCountX2 ~/ 2;
    sr.readU16(); // searchRange
    sr.readU16(); // entrySelector
    sr.readU16(); // rangeShift

    final endCodes = <int>[];
    for (var i = 0; i < segCount; i++) {
      endCodes.add(sr.readU16());
    }
    sr.readU16(); // reservedPad
    final startCodes = <int>[];
    for (var i = 0; i < segCount; i++) {
      startCodes.add(sr.readU16());
    }
    final idDeltas = <int>[];
    for (var i = 0; i < segCount; i++) {
      idDeltas.add(sr.readI16());
    }
    final idRangeOffsets = <int>[];
    for (var i = 0; i < segCount; i++) {
      idRangeOffsets.add(sr.readU16());
    }

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
    return glyphIdForRune(ch.runes.first);
  }

  /// Rune-based twin of the string lookups: per-char pen walks, metrics,
  /// and banding resolve each code point once with no string round-trips.
  int? glyphIdForRune(int cp) => _cmap[cp];

  bool hasGlyph(String ch) => _glyphId(ch) != null;

  bool hasGlyphForRune(int cp) => glyphIdForRune(cp) != null;

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

  /// True when the font carries color-bitmap glyphs (sbix or CBDT/CBLC) — the
  /// raster color-emoji formats (Apple / Noto). Independent of [hasColorGlyphs]
  /// (COLR vectors); a font may have neither, either, or both.
  bool get hasBitmapGlyphs => _bitmap != null;

  /// Strike ppem sizes the bitmap glyphs are stored at, ascending; empty when
  /// the font has none.
  List<int> get bitmapStrikePpems => _bitmap?.strikePpems ?? const [];

  /// The color-bitmap glyph for code point [cp] at the strike nearest
  /// [targetPpem] (≥ when possible), or null. [targetPpem] is the on-screen
  /// pixels-per-em (font size in device px) — the source buckets it to a strike.
  BitmapGlyph? bitmapGlyphForCodePoint(int cp, {required double targetPpem}) {
    final bitmap = _bitmap;
    if (bitmap == null) return null;
    final gid = _cmap[cp];
    if (gid == null) return null;
    return bitmap.glyphFor(gid, targetPpem: targetPpem);
  }

  /// The color-bitmap glyph for glyph id [gid] (post-shaping) at [targetPpem].
  BitmapGlyph? bitmapGlyphForId(int gid, {required double targetPpem}) =>
      _bitmap?.glyphFor(gid, targetPpem: targetPpem);

  /// The strike ppem [bitmapGlyphForId] would resolve for [targetPpem] — the
  /// atlas key so every size resolving to one strike shares a decoded entry.
  int? bitmapStrikeFor(double targetPpem) => _bitmap?.chooseStrike(targetPpem);

  double advanceOfGlyphId(int gid) => _advanceFor(gid);

  double advanceOf(String ch) {
    // cmap miss → .notdef (glyph 0) advance, so unsupported characters
    // occupy tofu-sized space instead of collapsing to zero width.
    return _advanceFor(_glyphId(ch) ?? 0);
  }

  double kerningOf(String a, String b) {
    final left = _glyphId(a);
    final right = _glyphId(b);
    if (left == null || right == null) return 0;
    return kerningOfGlyphIds(left, right);
  }

  /// Kern adjustment between two already-resolved glyph ids (same-font pen
  /// walks carry the previous id forward instead of re-resolving strings).
  double kerningOfGlyphIds(int left, int right) {
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
    final pts = _glyphPointsById(id);
    if (pts == null || pts.xs.isEmpty) return null;

    final quads = <double>[];
    var start = 0;
    for (final end in pts.endPts) {
      _contourToQuads(pts.xs, pts.ys, pts.flags, start, end, quads);
      start = end + 1;
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
      advance: _advanceFor(id),
      bbox: [x0, y0, x1, y1],
    );
  }

  /// Decoded outline points (font units, Y-up) with this instance's gvar
  /// deltas applied; composites are flattened recursively. Null for empty
  /// glyphs.
  _GlyphPointData? _glyphPointsById(int id, [int depth = 0]) {
    if (id < 0 || id >= _numGlyphs || depth > 6) return null;
    if (_glyphOffsets.isEmpty) return null; // CBDT-only font: no outlines
    final start = _glyphOffsets[id];
    final end = _glyphOffsets[id + 1];
    if (start == end) return null;
    final glyfOffset = _tables['glyf']!.offset;
    final r = _ByteReader(_bytes)..seek(glyfOffset + start);
    final numberOfContours = r.readI16();
    r.readI16(); // xMin
    r.readI16(); // yMin
    r.readI16(); // xMax
    r.readI16(); // yMax
    if (numberOfContours >= 0) {
      final pts = _decodeSimplePoints(r, numberOfContours);
      final coords = _normCoords;
      final gvar = _gvar;
      final sharedScalars = _gvarSharedScalars;
      if (coords != null &&
          gvar != null &&
          sharedScalars != null &&
          pts.xs.isNotEmpty) {
        final deltas = gvar.deltasFor(
          id,
          coords,
          sharedScalars,
          pointCount: pts.xs.length,
          xs: pts.xs,
          ys: pts.ys,
          endPts: pts.endPts,
        );
        if (deltas != null) {
          for (var i = 0; i < pts.xs.length; i++) {
            pts.xs[i] += deltas.$1[i];
            pts.ys[i] += deltas.$2[i];
          }
        }
      }
      return pts;
    }
    return _compositePoints(r, id, depth);
  }

  _GlyphPointData _decodeSimplePoints(_ByteReader r, int numberOfContours) {
    final endPts = List<int>.generate(numberOfContours, (_) => r.readU16());
    final instructionLength = r.readU16();
    r.seek(r.position + instructionLength);

    final pointCount = endPts.isEmpty ? 0 : endPts.last + 1;
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

    return _GlyphPointData(xs, ys, flags, endPts);
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
      if (eon[i]) {
        firstOn = i;
        break;
      }
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
        cx = ex[idx];
        cy = ey[idx];
        j++;
      } else {
        final nidx = (firstOn + j + 1) % m;
        out.addAll([cx, cy, ex[idx], ey[idx], ex[nidx], ey[nidx]]);
        cx = ex[nidx];
        cy = ey[nidx];
        j += 2;
      }
    }

    if ((cx - sx).abs() > 1e-10 || (cy - sy).abs() > 1e-10) {
      _lineToQuad(cx, cy, sx, sy, out);
    }
  }

  void _lineToQuad(
    double x0,
    double y0,
    double x1,
    double y1,
    List<double> out,
  ) {
    out.addAll([x0, y0, (x0 + x1) / 2, (y0 + y1) / 2, x1, y1]);
  }

  _GlyphPointData? _compositePoints(_ByteReader r, int id, int depth) {
    // Read every component record first so composite gvar deltas (one point
    // per component) can adjust the XY offsets before children are placed.
    final comps = <_ComponentRecord>[];
    while (true) {
      final flags = r.readU16();
      final glyphIndex = r.readU16();
      double arg1;
      double arg2;
      if (flags & 0x01 != 0) {
        arg1 = r.readI16().toDouble();
        arg2 = r.readI16().toDouble();
      } else {
        arg1 = r.readI8().toDouble();
        arg2 = r.readI8().toDouble();
      }

      var a = 1.0; // xscale
      var b = 0.0; // scale01
      var c = 0.0; // scale10
      var d = 1.0; // yscale
      if (flags & 0x0008 != 0) {
        // WE_HAVE_A_SCALE: single uniform scale
        a = d = r.readI16() / 16384.0;
      } else if (flags & 0x0040 != 0) {
        // WE_HAVE_AN_X_AND_YSCALE
        a = r.readI16() / 16384.0;
        d = r.readI16() / 16384.0;
      } else if (flags & 0x0080 != 0) {
        // WE_HAVE_A_TWO_BY_TWO
        a = r.readI16() / 16384.0;
        b = r.readI16() / 16384.0;
        c = r.readI16() / 16384.0;
        d = r.readI16() / 16384.0;
      }
      comps.add(_ComponentRecord(glyphIndex, flags, arg1, arg2, a, b, c, d));
      if (flags & 0x0020 == 0) break;
    }

    final coords = _normCoords;
    final gvar = _gvar;
    final sharedScalars = _gvarSharedScalars;
    if (coords != null &&
        gvar != null &&
        sharedScalars != null &&
        comps.isNotEmpty) {
      final deltas = gvar.deltasFor(
        id,
        coords,
        sharedScalars,
        pointCount: comps.length,
      );
      if (deltas != null) {
        for (var i = 0; i < comps.length; i++) {
          // Only XY-offset placements vary; point-matched ones don't move.
          if (comps[i].flags & 0x0002 != 0) {
            comps[i].arg1 += deltas.$1[i];
            comps[i].arg2 += deltas.$2[i];
          }
        }
      }
    }

    final xs = <double>[];
    final ys = <double>[];
    final flags = <int>[];
    final endPts = <int>[];
    for (final comp in comps) {
      final child = _glyphPointsById(comp.glyphIndex, depth + 1);
      if (child == null) continue;
      final base = xs.length;
      for (var i = 0; i < child.xs.length; i++) {
        final x = child.xs[i];
        final y = child.ys[i];
        xs.add(comp.a * x + comp.c * y + comp.arg1);
        ys.add(comp.b * x + comp.d * y + comp.arg2);
      }
      flags.addAll(child.flags);
      for (final e in child.endPts) {
        endPts.add(base + e);
      }
    }
    if (xs.isEmpty) return null;
    return _GlyphPointData(xs, ys, flags, endPts);
  }
}

/// A decoded glyph outline at the point level: font units, Y-up, flags bit 0
/// = on-curve. Contours are [endPts] ranges, TrueType-style.
class _GlyphPointData {
  _GlyphPointData(this.xs, this.ys, this.flags, this.endPts);

  final List<double> xs;
  final List<double> ys;
  final List<int> flags;
  final List<int> endPts;
}

class _ComponentRecord {
  _ComponentRecord(
    this.glyphIndex,
    this.flags,
    this.arg1,
    this.arg2,
    this.a,
    this.b,
    this.c,
    this.d,
  );

  final int glyphIndex;
  final int flags;
  double arg1; // x offset (mutable: composite gvar deltas apply here)
  double arg2; // y offset
  final double a; // xscale:  x' = a·x + c·y + arg1
  final double b; // scale01: y' = b·x + d·y + arg2
  final double c; // scale10
  final double d; // yscale
}

extension on _ByteReader {
  int readU64() {
    final hi = readU32();
    final lo = readU32();
    return (hi << 32) | lo;
  }
}

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
class _Coverage {
  _Coverage(this.starts, this.ends, this.indexBase);

  final List<int> starts;
  final List<int> ends;
  final List<int> indexBase;

  static _Coverage parse(ByteData d, int off) {
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
    return _Coverage(starts, ends, base);
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

  final _Coverage coverage;
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
  _PairPos2(
    this.coverage,
    this.classDef1,
    this.classDef2,
    this.class2Count,
    this.xAdvance,
  );

  final _Coverage coverage;
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
    final coverage = _Coverage.parse(d, coverageOff);
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
    final coverage = _Coverage.parse(d, coverageOff);
    final classDef1 = _GposClassDef.parse(
      d,
      off + d.getUint16(off + 8, Endian.big),
    );
    final classDef2 = _GposClassDef.parse(
      d,
      off + d.getUint16(off + 10, Endian.big),
    );
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

// COLR v0 + CPAL: layered color glyphs. Each base glyph maps to an ordered
// run of (layer glyph id, palette color) — every layer is an ordinary glyf
// outline, painted as N coverage instances.

class ColrLayer {
  const ColrLayer(this.glyphId, this.color);

  final int glyphId;

  /// Straight-alpha RGBA 0..1; null means palette index 0xFFFF (use the
  /// current text color).
  final List<double>? color;
}

class _ColrData {
  _ColrData(
    this.baseGids,
    this.firstLayer,
    this.layerCounts,
    this.layerGids,
    this.layerPalette,
    this.palette,
  );

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
    final firstIndex = numPalettes > 0 ? d.getUint16(cpal + 12, Endian.big) : 0;
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
      baseGids,
      firstLayer,
      layerCounts,
      layerGids,
      layerPalette,
      palette,
    );
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
