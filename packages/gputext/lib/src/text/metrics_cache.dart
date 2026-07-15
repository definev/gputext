// Per-font segment measurement cache (the idea behind pretext's
// measurement.ts, adapted to gputext): widths are stored in FONT UNITS so
// one cache entry serves every font size, and per-grapheme cumulative
// advances are populated lazily — only overlong segments that actually need
// intra-word breaking (or future caret math) pay for them.
//
// Keyed by font identity via Expando, so dropped fonts release their cache
// with no generation bookkeeping. Kerning within a segment is included,
// mirroring the paint-time pen walk in emitInstances; zero-width code points
// are skipped without resetting the kerning pair, exactly like measureText.
//
// Prefer [segmentMetricsOfRange] when measuring a slice of an already-shaped
// run (HarfBuzz or cmap-constructed) so advances match paint without
// allocating a [ShapedGlyphRun.slice].

import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../font.dart';
import 'shaped_run.dart';

class SegmentMetrics {
  SegmentMetrics(this.widthUnits, this.renderedRuneCount);

  /// Advance sum + kerning, in font units.
  final double widthUnits;

  /// Runes/glyphs that receive letter-spacing at paint time (non-ZW),
  /// matching the emitInstances pen walk.
  final int renderedRuneCount;

  /// Cumulative width in font units at each grapheme END boundary
  /// (`graphemeCumUnits[g]` = width of the first g+1 graphemes). Lazy.
  Float64List? graphemeCumUnits;

  /// UTF-16 end offset of each grapheme within the segment text. Lazy,
  /// filled together with [graphemeCumUnits].
  List<int>? graphemeEndOffsets;

  /// Rendered (letter-spaced) rune count per grapheme, aligned with
  /// [graphemeCumUnits]. Lazy.
  List<int>? graphemeRenderedRunes;
}

/// Max unique segment strings retained per [GPUFont]. LinkedHashMap +
/// re-insert on hit gives LRU eviction (same pattern as the layout cache).
const segmentMetricsCacheCapacity = 512;

final _cache = Expando<Map<String, SegmentMetrics>>('gputextSegmentMetrics');

/// Benchmark hook (pretext's clearCache() analog): drop `font`'s cached
/// segment metrics so the next prepare re-measures cold.
void debugClearSegmentMetricsFor(GPUFont font) {
  _cache[font] = null;
}

/// Test hook: number of cached segment entries for [font] (0 if none).
int debugSegmentMetricsLengthFor(GPUFont font) => _cache[font]?.length ?? 0;

Map<String, SegmentMetrics> _mapFor(GPUFont font) =>
    _cache[font] ??= <String, SegmentMetrics>{};

SegmentMetrics _lookupOrPut(
  Map<String, SegmentMetrics> byText,
  String text,
  SegmentMetrics Function() measure,
) {
  final cached = byText.remove(text);
  if (cached != null) {
    byText[text] = cached; // LRU touch
    return cached;
  }
  final m = measure();
  byText[text] = m;
  while (byText.length > segmentMetricsCacheCapacity) {
    byText.remove(byText.keys.first);
  }
  return m;
}

SegmentMetrics segmentMetricsOf(GPUFont font, String text) {
  return _lookupOrPut(_mapFor(font), text, () => _measure(font, text));
}

/// Measure glyphs of [shaped] that fall in pipeline `[start, end)`, caching
/// by [text] (the segment substring). Avoids [ShapedGlyphRun.slice] allocs
/// on the prepare hot path.
SegmentMetrics segmentMetricsOfRange(
  GPUFont font,
  String text,
  ShapedGlyphRun shaped,
  int start,
  int end,
) {
  return _lookupOrPut(_mapFor(font), text, () {
    final (lo, hi) = shaped.glyphIndexRange(start, end);
    var w = 0.0;
    var prev = -1;
    var count = 0;
    for (var i = lo; i < hi; i++) {
      final g = shaped.glyphs[i];
      if (g.shapedStart >= end || g.shapedEnd <= start) continue;
      if (shaped.appliesKerning && prev >= 0) {
        w += font.kerningOfGlyphIds(prev, g.glyphId);
      }
      w += g.xAdvance;
      prev = g.glyphId;
      count++;
    }
    return SegmentMetrics(w, count);
  });
}

/// Measure a shaped slice via glyph advances (no rune walk). Uncached —
/// prefer [segmentMetricsOfRange] on the prepare path.
SegmentMetrics segmentMetricsOfShaped(ShapedGlyphRun shaped) {
  final w = shapedWidthUnits(shaped);
  return SegmentMetrics(w, shaped.glyphs.length);
}

SegmentMetrics _measure(GPUFont font, String text) {
  // Cmap fallback for callers that only have plain text (tests, soft
  // hyphen '-'). Prefer [segmentMetricsOfRange] when a run is available.
  final shaped = ShapedGlyphRun.fromPipelineText(
    font: font,
    fontSizePx: 1, // unused for font-unit advances
    sourceText: text,
    pipelineText: text,
  );
  return SegmentMetrics(shapedWidthUnits(shaped), shaped.glyphs.length);
}

/// Ensure [SegmentMetrics.graphemeCumUnits] and friends are populated for
/// grapheme-level breaking of `text`. When [shaped]/[start]/[end] are
/// provided, advances come from glyphs in that parent range (no slice).
void ensureGraphemeMetrics(
  GPUFont font,
  String text,
  SegmentMetrics m, {
  ShapedGlyphRun? shaped,
  int start = 0,
  int? end,
}) {
  if (m.graphemeCumUnits != null) return;
  final cum = <double>[];
  final offsets = <int>[];
  final runeCounts = <int>[];
  var w = 0.0;
  var offset = 0;
  final run =
      shaped ??
      ShapedGlyphRun.fromPipelineText(
        font: font,
        fontSizePx: 1,
        sourceText: text,
        pipelineText: text,
      );
  final rangeStart = shaped == null ? 0 : start;
  final rangeEnd = shaped == null
      ? run.pipelineText.length
      : (end ?? start + text.length);
  final (lo, hi) = shaped == null
      ? (0, run.glyphs.length)
      : run.glyphIndexRange(rangeStart, rangeEnd);
  var glyphIndex = lo;
  var prevGid = -1;
  for (final grapheme in text.characters) {
    var rendered = 0;
    final gEnd = offset + grapheme.length;
    // Parent-run glyph offsets are absolute; local grapheme offsets are
    // relative to [text], so compare in parent space when shaped is set.
    final absOff = rangeStart + offset;
    final absEnd = rangeStart + gEnd;
    while (glyphIndex < hi) {
      final g = run.glyphs[glyphIndex];
      if (g.shapedStart >= absEnd) break;
      if (g.shapedEnd <= absOff) {
        glyphIndex++;
        continue;
      }
      if (run.appliesKerning && prevGid >= 0) {
        w += font.kerningOfGlyphIds(prevGid, g.glyphId);
      }
      w += g.xAdvance;
      rendered++;
      prevGid = g.glyphId;
      glyphIndex++;
    }
    offset = gEnd;
    cum.add(w);
    offsets.add(offset);
    runeCounts.add(rendered);
  }
  m.graphemeCumUnits = Float64List.fromList(cum);
  m.graphemeEndOffsets = offsets;
  m.graphemeRenderedRunes = runeCounts;
}
