// Per-font segment measurement cache (the idea behind pretext's
// measurement.ts, adapted to windfoil): widths are stored in FONT UNITS so
// one cache entry serves every font size, and per-grapheme cumulative
// advances are populated lazily — only overlong segments that actually need
// intra-word breaking (or future caret math) pay for them.
//
// Keyed by font identity via Expando, so dropped fonts release their cache
// with no generation bookkeeping. Kerning within a segment is included,
// mirroring the paint-time pen walk in emitInstances; zero-width code points
// are skipped without resetting the kerning pair, exactly like measureText.

import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../font.dart';

class SegmentMetrics {
  SegmentMetrics(this.widthUnits, this.renderedRuneCount);

  /// Advance sum + kerning, in font units.
  final double widthUnits;

  /// Runes that receive letter-spacing at paint time (non-zero-width),
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

final _cache = Expando<Map<String, SegmentMetrics>>('windfoilSegmentMetrics');

/// Benchmark hook (pretext's clearCache() analog): drop `font`'s cached
/// segment metrics so the next prepare re-measures cold.
void debugClearSegmentMetricsFor(WindfoilFont font) {
  _cache[font] = null;
}

SegmentMetrics segmentMetricsOf(WindfoilFont font, String text) {
  final byText = _cache[font] ??= <String, SegmentMetrics>{};
  return byText[text] ??= _measure(font, text);
}

SegmentMetrics _measure(WindfoilFont font, String text) {
  var w = 0.0;
  var rendered = 0;
  var prevGid = -1;
  for (final rune in text.runes) {
    if (isZeroWidthCodePoint(rune)) continue;
    final gid = font.glyphIdForRune(rune) ?? 0; // cmap miss → .notdef tofu
    if (prevGid >= 0) w += font.kerningOfGlyphIds(prevGid, gid);
    w += font.advanceOfGlyphId(gid);
    rendered++;
    prevGid = gid;
  }
  return SegmentMetrics(w, rendered);
}

/// Ensure [SegmentMetrics.graphemeCumUnits] and friends are populated for
/// grapheme-level breaking of `text`.
void ensureGraphemeMetrics(WindfoilFont font, String text, SegmentMetrics m) {
  if (m.graphemeCumUnits != null) return;
  final cum = <double>[];
  final offsets = <int>[];
  final runeCounts = <int>[];
  var w = 0.0;
  var offset = 0;
  var prevGid = -1;
  for (final grapheme in text.characters) {
    var rendered = 0;
    for (final rune in grapheme.runes) {
      if (isZeroWidthCodePoint(rune)) continue;
      final gid = font.glyphIdForRune(rune) ?? 0;
      if (prevGid >= 0) w += font.kerningOfGlyphIds(prevGid, gid);
      w += font.advanceOfGlyphId(gid);
      rendered++;
      prevGid = gid;
    }
    offset += grapheme.length;
    cum.add(w);
    offsets.add(offset);
    runeCounts.add(rendered);
  }
  m.graphemeCumUnits = Float64List.fromList(cum);
  m.graphemeEndOffsets = offsets;
  m.graphemeRenderedRunes = runeCounts;
}
