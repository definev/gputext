// Pluggable line-breaking strategies over prepared paragraph data.
//
// A LineBreaker CHOOSES where lines end. It does not distribute justified
// space (TextAlign.justify does that at paint time in emitInstances), and it
// does not hyphenate (insert soft hyphens into the source text before
// layout). Keeping both concerns outside means any breaker composes with
// any alignment and any hyphenator.
//
// Strategies consume PreparedLineBreakData — the width-independent product
// of prepareParagraph() — so switching breakers never invalidates prepared
// paragraphs or the engine's prepare cache; only the cheap per-width pass
// differs.
//
// This file stays VM-pure (no dart:ui / Flutter imports).

import 'dart:typed_data';

import 'analysis.dart' show SegmentBreakKind;
import 'line_break.dart';

abstract class LineBreaker {
  const LineBreaker();

  /// The built-in first-fit walker (Flutter-parity breaks; the default).
  static const LineBreaker greedy = GreedyLineBreaker();

  /// Break one hard-break-delimited chunk into consecutive, gapless
  /// [LineRange]s in cursor order.
  ///
  /// Contract (matching the built-in walker):
  ///  - The final range ends at `chunks[chunkIndex].consumedEnd` with
  ///    `hardBreak: true`.
  ///  - A soft-wrap range ending at segment i+1 where
  ///    `data.kinds[i] == SegmentBreakKind.softHyphen` means that hyphen was
  ///    CHOSEN: `width` must include `data.widths[i]`, and materialization
  ///    appends the visible '-'.
  ///  - `width` is the consumed paint width; trailing whitespace may be
  ///    included (the alignment box trims it downstream).
  ///  - When `maxLines` is given, implementations may stop after producing
  ///    `maxLines + 1` ranges (the extra one signals overflow to the
  ///    caller); they never need to produce more.
  List<LineRange> breakChunk(
    PreparedLineBreakData data,
    int chunkIndex,
    double maxWidth, {
    int? maxLines,
  });
}

/// The default breaker: wraps the streaming greedy walker, so an explicit
/// `GreedyLineBreaker()` is line-for-line identical to passing no breaker.
class GreedyLineBreaker extends LineBreaker {
  const GreedyLineBreaker();

  @override
  List<LineRange> breakChunk(
    PreparedLineBreakData data,
    int chunkIndex,
    double maxWidth, {
    int? maxLines,
  }) {
    final chunk = data.chunks[chunkIndex];
    final cursor = LineBreakCursor(chunk.start);
    final out = <LineRange>[];
    while (cursor.segmentIndex < chunk.consumedEnd) {
      final range = nextLineRange(data, cursor, maxWidth);
      if (range == null) break;
      out.add(range);
      if (range.hardBreak) break;
      if (maxLines != null && out.length > maxLines) break;
    }
    return out;
  }

  @override
  bool operator ==(Object other) => other is GreedyLineBreaker;

  @override
  int get hashCode => (GreedyLineBreaker).hashCode;
}

/// Knuth-Plass-style total-fit optimization: evaluates the feasible break
/// combinations for the whole chunk and picks the one minimizing cubic
/// spacing badness, with extra penalties for river-wide gaps, over-tight
/// gaps, and hyphenated line ends. A simplified port of the TeX optimal-fit
/// idea, from pretext's justification-comparison demo, generalized to mixed
/// fonts/sizes by normalizing each line against its own average natural
/// space width.
///
/// Intended for justified body text — pair it with TextAlign.justify. Break
/// candidates are whitespace, ZWSP, and soft hyphens; unlike the greedy
/// walker it does not break inside overlong unbreakable words (they emit on
/// overflowing lines) and does not use generic segment-boundary breaks
/// (CJK/no-space scripts justify poorly here). Cost is O(candidates ×
/// fit-window) per chunk PER LAYOUT WIDTH: it re-runs in full on every
/// resize, so prefer it for settled layouts over live-dragged ones.
class KnuthPlassLineBreaker extends LineBreaker {
  const KnuthPlassLineBreaker();

  static const _huge = 1e8;
  static const _infeasibleSpaceRatio = 0.4;
  static const _riverThreshold = 1.5;
  static const _tightSpaceRatio = 0.65;
  static const _hyphenPenalty = 50.0;

  @override
  List<LineRange> breakChunk(
    PreparedLineBreakData data,
    int chunkIndex,
    double maxWidth, {
    int? maxLines,
  }) {
    final chunk = data.chunks[chunkIndex];
    final kinds = data.kinds;
    final widths = data.widths;
    final n = chunk.end - chunk.start;
    if (n <= 0) {
      return [
        LineRange(
          width: 0,
          startSegment: chunk.start,
          startGrapheme: 0,
          endSegment: chunk.consumedEnd,
          endGrapheme: 0,
          hardBreak: true,
          chunkIndex: chunkIndex,
        ),
      ];
    }

    bool isSpace(int seg) =>
        kinds[seg] == SegmentBreakKind.space ||
        kinds[seg] == SegmentBreakKind.tab;
    bool isInvisible(int seg) =>
        kinds[seg] == SegmentBreakKind.softHyphen ||
        kinds[seg] == SegmentBreakKind.zeroWidthBreak ||
        kinds[seg] == SegmentBreakKind.hardBreak;

    // Prefix sums over the chunk, chunk-relative (index i covers segments
    // [chunk.start, chunk.start + i)).
    final visiblePrefix = Float64List(n + 1);
    final spaceWidthPrefix = Float64List(n + 1);
    final spaceCountPrefix = List<int>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      final seg = chunk.start + i;
      final space = isSpace(seg);
      visiblePrefix[i + 1] =
          visiblePrefix[i] + (space || isInvisible(seg) ? 0 : widths[seg]);
      spaceWidthPrefix[i + 1] = spaceWidthPrefix[i] + (space ? widths[seg] : 0);
      spaceCountPrefix[i + 1] = spaceCountPrefix[i] + (space ? 1 : 0);
    }

    // Break candidates: chunk start, after every whitespace/ZWSP segment,
    // after every soft hyphen (with the hyphen shown), and chunk end.
    final candSeg = <int>[chunk.start];
    final candHyphen = <bool>[false];
    for (var seg = chunk.start; seg + 1 < chunk.end; seg++) {
      final kind = kinds[seg];
      if (kind == SegmentBreakKind.softHyphen) {
        candSeg.add(seg + 1);
        candHyphen.add(true);
      } else if (kind == SegmentBreakKind.space ||
          kind == SegmentBreakKind.tab ||
          kind == SegmentBreakKind.zeroWidthBreak) {
        candSeg.add(seg + 1);
        candHyphen.add(false);
      }
    }
    candSeg.add(chunk.end);
    candHyphen.add(false);
    final count = candSeg.length;

    // Line stats between candidates, with trailing whitespace stripped (it
    // hangs) and the chosen hyphen's width added.
    ({double word, double spaceWidth, int spaces}) stats(int from, int to) {
      final fromR = candSeg[from] - chunk.start;
      var endR = candSeg[to] - chunk.start;
      while (endR > fromR && isSpace(chunk.start + endR - 1)) {
        endR--;
      }
      var word = visiblePrefix[endR] - visiblePrefix[fromR];
      if (candHyphen[to]) word += widths[candSeg[to] - 1];
      return (
        word: word,
        spaceWidth: spaceWidthPrefix[endR] - spaceWidthPrefix[fromR],
        spaces: spaceCountPrefix[endR] - spaceCountPrefix[fromR],
      );
    }

    double badness(
      ({double word, double spaceWidth, int spaces}) s, {
      required bool isLastLine,
      required bool endsWithHyphen,
    }) {
      if (isLastLine) return s.word > maxWidth ? _huge : 0;
      if (s.spaces <= 0) {
        final slack = maxWidth - s.word;
        return slack < 0 ? _huge : slack * slack * 10;
      }
      final naturalSpace = s.spaceWidth / s.spaces;
      final justified = (maxWidth - s.word) / s.spaces;
      if (justified < 0) return _huge;
      if (justified < naturalSpace * _infeasibleSpaceRatio) return _huge;

      final ratio = (justified - naturalSpace) / naturalSpace;
      final absRatio = ratio.abs();
      var b = absRatio * absRatio * absRatio * 1000;

      final riverExcess = justified / naturalSpace - _riverThreshold;
      if (riverExcess > 0) b += 5000 + riverExcess * riverExcess * 10000;

      final tightThreshold = naturalSpace * _tightSpaceRatio;
      if (justified < tightThreshold) {
        final d = tightThreshold - justified;
        b += 3000 + d * d * 10000;
      }

      if (endsWithHyphen) b += _hyphenPenalty;
      return b;
    }

    final dp = List<double>.filled(count, double.infinity);
    final previous = List<int>.filled(count, -1);
    dp[0] = 0;

    for (var to = 1; to < count; to++) {
      final isLastLine = to == count - 1;
      for (var from = to - 1; from >= 0; from--) {
        if (dp[from] == double.infinity) continue;
        final s = stats(from, to);
        // Prune far candidates — but never the adjacent one, so every
        // candidate stays reachable and no text is silently dropped even
        // when a single unbreakable run exceeds 2× the width.
        if (s.word + s.spaceWidth > maxWidth * 2 && from != to - 1) break;
        final total =
            dp[from] +
            badness(s, isLastLine: isLastLine, endsWithHyphen: candHyphen[to]);
        if (total < dp[to]) {
          dp[to] = total;
          previous[to] = from;
        }
      }
    }

    final breakIndices = <int>[];
    var current = count - 1;
    while (current > 0) {
      if (previous[current] == -1) {
        current--;
        continue;
      }
      breakIndices.add(current);
      current = previous[current];
    }

    final out = <LineRange>[];
    var from = 0;
    for (final to in breakIndices.reversed) {
      final isLast = to == count - 1;
      final fromR = candSeg[from] - chunk.start;
      final toR = candSeg[to] - chunk.start;
      // Paint width includes trailing whitespace (walker semantics; trimmed
      // by the alignment box downstream) plus the chosen hyphen.
      var width =
          (visiblePrefix[toR] - visiblePrefix[fromR]) +
          (spaceWidthPrefix[toR] - spaceWidthPrefix[fromR]);
      if (candHyphen[to]) width += widths[candSeg[to] - 1];
      out.add(
        LineRange(
          width: width,
          startSegment: candSeg[from],
          startGrapheme: 0,
          endSegment: isLast ? chunk.consumedEnd : candSeg[to],
          endGrapheme: 0,
          hardBreak: isLast,
          chunkIndex: chunkIndex,
        ),
      );
      from = to;
      if (maxLines != null && out.length > maxLines) break;
    }
    return out;
  }

  @override
  bool operator ==(Object other) => other is KnuthPlassLineBreaker;

  @override
  int get hashCode => (KnuthPlassLineBreaker).hashCode;
}
