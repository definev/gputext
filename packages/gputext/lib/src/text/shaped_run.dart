// VM-pure shaped glyph-run model: the shared representation for layout,
// paint, and selection after OpenType shaping (legacy GSUB or HarfBuzz).
//
// Advances and offsets are in font units. [walkGlyphs] scales to px and,
// when [ShapedGlyphRun.appliesKerning] is true, folds pairwise kerning
// between consecutive glyphs (legacy path). HarfBuzz runs bake GPOS into
// advances/offsets and set appliesKerning=false.

import 'dart:typed_data';

import '../font.dart';

/// Layout-facing text direction (VM-pure; mirrors dart:ui.TextDirection).
enum TextDirection { ltr, rtl }

/// One positioned glyph after shaping.
class ShapedGlyph {
  const ShapedGlyph({
    required this.glyphId,
    required this.cluster,
    required this.clusterEnd,
    required this.shapedStart,
    required this.shapedEnd,
    required this.xAdvance,
    this.yAdvance = 0,
    this.xOffset = 0,
    this.yOffset = 0,
  });

  final int glyphId;

  /// Source UTF-16 start (inclusive) in [ShapedGlyphRun.sourceText].
  final int cluster;

  /// Source UTF-16 end (exclusive) in [ShapedGlyphRun.sourceText].
  final int clusterEnd;

  /// Pipeline UTF-16 start in [ShapedGlyphRun.pipelineText].
  final int shapedStart;

  /// Pipeline UTF-16 end (exclusive) in [ShapedGlyphRun.pipelineText].
  final int shapedEnd;

  /// Horizontal advance in font units (before optional pairwise kerning).
  final double xAdvance;
  final double yAdvance;

  /// Placement offset relative to the pen, in font units.
  final double xOffset;
  final double yOffset;
}

/// One shaped run: glyphs + shaping metadata (no paint style).
class ShapedGlyphRun {
  const ShapedGlyphRun({
    required this.font,
    required this.fontSizePx,
    required this.sourceText,
    required this.pipelineText,
    required this.glyphs,
    this.sourceMap,
    this.bidiLevel = 0,
    this.direction = TextDirection.ltr,
    this.appliesKerning = true,
  });

  /// Build from already-shaped pipeline text (PUA proxies or plain chars).
  /// Used by [LegacyGsubShaper] and by [TextRun] when tests omit [shaped].
  factory ShapedGlyphRun.fromPipelineText({
    required GPUFont font,
    required double fontSizePx,
    required String sourceText,
    required String pipelineText,
    Int32List? sourceMap,
    int bidiLevel = 0,
    TextDirection direction = TextDirection.ltr,
    bool appliesKerning = true,
  }) {
    final glyphs = <ShapedGlyph>[];
    var shapedOff = 0;
    for (final rune in pipelineText.runes) {
      final units = rune >= 0x10000 ? 2 : 1;
      final shapedStart = shapedOff;
      final shapedEnd = shapedOff + units;
      shapedOff = shapedEnd;
      if (isZeroWidthCodePoint(rune)) continue;
      final gid = font.glyphIdForRune(rune) ?? 0;
      final cluster = sourceMap == null ? shapedStart : sourceMap[shapedStart];
      final clusterEnd = sourceMap == null ? shapedEnd : sourceMap[shapedEnd];
      glyphs.add(
        ShapedGlyph(
          glyphId: gid,
          cluster: cluster,
          clusterEnd: clusterEnd,
          shapedStart: shapedStart,
          shapedEnd: shapedEnd,
          xAdvance: font.advanceOfGlyphId(gid),
        ),
      );
    }
    return ShapedGlyphRun(
      font: font,
      fontSizePx: fontSizePx,
      sourceText: sourceText,
      pipelineText: pipelineText,
      glyphs: glyphs,
      sourceMap: sourceMap,
      bidiLevel: bidiLevel,
      direction: direction,
      appliesKerning: appliesKerning,
    );
  }

  /// Copy with updated bidi metadata (glyphs/text unchanged).
  ShapedGlyphRun withBidi({
    required int bidiLevel,
    required TextDirection direction,
  }) => ShapedGlyphRun(
    font: font,
    fontSizePx: fontSizePx,
    sourceText: sourceText,
    pipelineText: pipelineText,
    glyphs: glyphs,
    sourceMap: sourceMap,
    bidiLevel: bidiLevel,
    direction: direction,
    appliesKerning: appliesKerning,
  );

  final GPUFont font;
  final double fontSizePx;

  /// Pre-shaping source characters (selection/copy space).
  final String sourceText;

  /// Post-shaping pipeline text (PUA proxies for legacy GSUB). Line-break
  /// analysis still concatenates this string through Phase 2.
  final String pipelineText;

  final List<ShapedGlyph> glyphs;

  /// Shaped→source UTF-16 boundary map (length pipelineText.length+1);
  /// null means identity.
  final Int32List? sourceMap;

  /// Unicode bidi embedding level (even = LTR, odd = RTL).
  final int bidiLevel;

  final TextDirection direction;

  /// When true, [walkGlyphs] applies pairwise kerning. HarfBuzz runs set
  /// this false (GPOS already baked into advances/offsets).
  final bool appliesKerning;

  bool get isEmpty => glyphs.isEmpty;

  int sourceOffsetAt(int shapedOffset) {
    final map = sourceMap;
    if (map == null) return shapedOffset;
    if (shapedOffset < 0) return 0;
    return map[shapedOffset < map.length ? shapedOffset : map.length - 1];
  }

  /// Glyph index range whose pipeline spans intersect `[start, end)`.
  /// LTR uses binary search; RTL scans (short runs in practice).
  (int, int) glyphIndexRange(int start, int end) {
    final pipeLen = pipelineText.length;
    final s = start.clamp(0, pipeLen);
    final e = end.clamp(0, pipeLen);
    if (s >= e || glyphs.isEmpty) return (0, 0);
    if (direction == TextDirection.ltr) {
      final lo = _firstGlyphWithEndAfter(glyphs, s);
      final hi = _firstGlyphWithStartAtOrAfter(glyphs, e);
      return (lo, hi < lo ? lo : hi);
    }
    var lo = glyphs.length;
    var hi = 0;
    for (var i = 0; i < glyphs.length; i++) {
      final g = glyphs[i];
      if (g.shapedStart < e && g.shapedEnd > s) {
        if (i < lo) lo = i;
        hi = i + 1;
      }
    }
    return lo > hi ? (0, 0) : (lo, hi);
  }

  /// Advance sum (+ optional kerning) for glyphs intersecting `[start, end)`,
  /// without allocating a sliced [ShapedGlyphRun].
  double widthUnitsInRange(int start, int end) {
    final (lo, hi) = glyphIndexRange(start, end);
    if (lo >= hi) return 0;
    var w = 0.0;
    var prev = -1;
    for (var i = lo; i < hi; i++) {
      final g = glyphs[i];
      if (appliesKerning && prev >= 0) {
        w += font.kerningOfGlyphIds(prev, g.glyphId);
      }
      w += g.xAdvance;
      prev = g.glyphId;
    }
    return w;
  }

  /// Glyphs whose pipeline range intersects `[start, end)` (UTF-16), with
  /// offsets rebased into the sliced pipeline/source strings.
  ///
  /// LTR runs keep glyphs in non-decreasing [ShapedGlyph.shapedStart] order
  /// (legacy GSUB and HarfBuzz), so the intersecting range is found with
  /// binary search — required for long single-run corpora where prepare
  /// slices once per word (linear scan is O(n²) over ~270k glyphs).
  /// RTL visual order is non-increasing; those runs fall back to a linear
  /// scan (short runs in practice).
  ShapedGlyphRun slice(int start, int end) {
    final pipeLen = pipelineText.length;
    final s = start.clamp(0, pipeLen);
    final e = end.clamp(0, pipeLen);
    if (s == 0 && e == pipeLen) return this;
    if (s >= e || glyphs.isEmpty) {
      return ShapedGlyphRun(
        font: font,
        fontSizePx: fontSizePx,
        sourceText: '',
        pipelineText: '',
        glyphs: const [],
        sourceMap: null,
        bidiLevel: bidiLevel,
        direction: direction,
        appliesKerning: appliesKerning,
      );
    }

    final pipe = pipelineText.substring(s, e);
    final srcStart = sourceOffsetAt(s);
    final srcEnd = sourceOffsetAt(e);
    final src = sourceText.substring(
      srcStart.clamp(0, sourceText.length),
      srcEnd.clamp(0, sourceText.length),
    );

    // Clamp rebased offsets: a glyph whose cluster straddles the slice
    // boundary (ligature/mark cluster) keeps only the in-slice part of its
    // text range, so downstream indexing stays within pipe/src.
    final (lo, hi) = glyphIndexRange(s, e);
    final sliced = <ShapedGlyph>[];
    for (var i = lo; i < hi; i++) {
      final g = glyphs[i];
      if (g.shapedStart >= e || g.shapedEnd <= s) continue;
      sliced.add(
        ShapedGlyph(
          glyphId: g.glyphId,
          cluster: (g.cluster - srcStart).clamp(0, src.length),
          clusterEnd: (g.clusterEnd - srcStart).clamp(0, src.length),
          shapedStart: (g.shapedStart - s).clamp(0, pipe.length),
          shapedEnd: (g.shapedEnd - s).clamp(0, pipe.length),
          xAdvance: g.xAdvance,
          yAdvance: g.yAdvance,
          xOffset: g.xOffset,
          yOffset: g.yOffset,
        ),
      );
    }

    Int32List? map;
    final full = sourceMap;
    if (full != null) {
      final n = pipe.length + 1;
      final built = Int32List(n);
      var identity = true;
      for (var i = 0; i < n; i++) {
        built[i] = full[s + i] - srcStart;
        if (built[i] != i) identity = false;
      }
      if (!identity) map = built;
    }

    return ShapedGlyphRun(
      font: font,
      fontSizePx: fontSizePx,
      sourceText: src,
      pipelineText: pipe,
      glyphs: sliced,
      sourceMap: map,
      bidiLevel: bidiLevel,
      direction: direction,
      appliesKerning: appliesKerning,
    );
  }
}

/// First index with [ShapedGlyph.shapedEnd] > [s] (LTR, non-decreasing starts).
int _firstGlyphWithEndAfter(List<ShapedGlyph> glyphs, int s) {
  var lo = 0;
  var hi = glyphs.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (glyphs[mid].shapedEnd <= s) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// First index with [ShapedGlyph.shapedStart] >= [e] (LTR upper bound).
int _firstGlyphWithStartAtOrAfter(List<ShapedGlyph> glyphs, int e) {
  var lo = 0;
  var hi = glyphs.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (glyphs[mid].shapedStart < e) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// One step of a glyph pen walk in logical px (relative to walk start).
class GlyphWalkStep {
  const GlyphWalkStep({
    required this.glyph,
    required this.penX,
    required this.advancePx,
    required this.xOffsetPx,
    required this.yOffsetPx,
  });

  final ShapedGlyph glyph;

  /// Pen x at glyph origin (before [xOffsetPx]), after optional kerning.
  final double penX;

  /// Glyph advance in px (no letter/word spacing).
  final double advancePx;
  final double xOffsetPx;
  final double yOffsetPx;
}

/// Walk [shaped] in storage order, applying scale and optional pairwise
/// kerning. Letter/word spacing are folded by callers from the owning run.
Iterable<GlyphWalkStep> walkGlyphs(
  ShapedGlyphRun shaped,
  double scale, {
  int startPrevGid = -1,
  GPUFont? startPrevFont,
}) sync* {
  var pen = 0.0;
  var prevGid = startPrevGid;
  var prevFont = startPrevFont;
  for (final g in shaped.glyphs) {
    if (shaped.appliesKerning &&
        prevGid >= 0 &&
        prevFont != null &&
        identical(prevFont, shaped.font)) {
      pen += shaped.font.kerningOfGlyphIds(prevGid, g.glyphId) * scale;
    }
    final adv = g.xAdvance * scale;
    yield GlyphWalkStep(
      glyph: g,
      penX: pen,
      advancePx: adv,
      xOffsetPx: g.xOffset * scale,
      yOffsetPx: g.yOffset * scale,
    );
    pen += adv;
    prevGid = g.glyphId;
    prevFont = shaped.font;
  }
}

/// Total advance of [shaped] in font units, including optional kerning.
double shapedWidthUnits(ShapedGlyphRun shaped) {
  var w = 0.0;
  var prev = -1;
  for (final g in shaped.glyphs) {
    if (shaped.appliesKerning && prev >= 0) {
      w += shaped.font.kerningOfGlyphIds(prev, g.glyphId);
    }
    w += g.xAdvance;
    prev = g.glyphId;
  }
  return w;
}
