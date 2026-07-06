// Cursor-based greedy line walker, ported from pretext (line-break.ts) and
// simplified for Flutter semantics:
//
//  - Letter/word spacing are folded into segment widths at prepare time, so
//    the walker is pure px arithmetic with no spacing bookkeeping.
//  - Fit width vs paint width: spaces and tabs contribute 0 to the FIT test
//    (trailing whitespace hangs past the wrap edge, like CSS/Flutter), but
//    line ranges still consume them; the caller excludes trailing space
//    items from the alignment width, which also handles whitespace runs that
//    span style boundaries.
//  - Leading whitespace is consumed only at soft-wrap line starts. At chunk
//    starts (paragraph start, after '\n') it renders, matching Flutter.
//  - No tab stops: a tab is a fixed-advance whitespace segment.
//
// Every segment boundary is a break opportunity (see analysis.dart). Soft
// hyphens are invisible until chosen; a chosen one adds its precomputed
// hyphen width to the line, and materialization appends the visible '-'.
//
// This file stays VM-pure and font-agnostic: all inputs are plain arrays.

import 'dart:typed_data';

import 'analysis.dart' show SegmentBreakKind;

/// Absolute px tolerance for "does it fit", absorbing float accumulation
/// drift between prepare-time sums and paint-time pen walks.
const lineFitEpsilon = 0.005;

/// One hard-break-delimited stretch of segments. `end` excludes the
/// hard-break segment itself; `consumedEnd` includes it. `styleItemIndex`
/// supplies line metrics for empty lines (blank `\n\n` chunks).
class LineBreakChunk {
  const LineBreakChunk(
      this.start, this.end, this.consumedEnd, this.styleItemIndex);

  final int start;
  final int end;
  final int consumedEnd;
  final int styleItemIndex;
}

/// Walker inputs, one entry per segment. For soft hyphens `widths` holds the
/// CHOSEN-break hyphen width (they occupy no width otherwise); for hard
/// breaks it is 0.
class PreparedLineBreakData {
  const PreparedLineBreakData({
    required this.widths,
    required this.kinds,
    required this.graphemeAdvances,
    required this.preferredBreaks,
    required this.chunks,
  });

  /// Segment advances in px, mid-line (letter/word spacing folded in).
  final Float64List widths;
  final List<SegmentBreakKind> kinds;

  /// Per-grapheme advances for segments that may break inside (overlong
  /// words), else null. Advances include per-grapheme letter-spacing.
  final List<Float64List?> graphemeAdvances;

  /// Preferred grapheme end-indices for intra-segment breaks (after
  /// hyphens), else null. Aligned with [graphemeAdvances].
  final List<List<int>?> preferredBreaks;

  final List<LineBreakChunk> chunks;

  int get segmentCount => kinds.length;
}

class LineBreakCursor {
  LineBreakCursor([this.segmentIndex = 0, this.graphemeIndex = 0]);

  int segmentIndex;
  int graphemeIndex;
}

/// One laid-out line: [start*, end*) in (segment, grapheme) cursor space.
/// `width` is the consumed paint width (trailing whitespace INCLUDED; a
/// chosen soft hyphen's '-' included).
class LineRange {
  const LineRange({
    required this.width,
    required this.startSegment,
    required this.startGrapheme,
    required this.endSegment,
    required this.endGrapheme,
    required this.hardBreak,
    required this.chunkIndex,
  });

  final double width;
  final int startSegment;
  final int startGrapheme;
  final int endSegment;
  final int endGrapheme;

  /// True when the line ends at a '\n' or the end of the paragraph.
  final bool hardBreak;

  final int chunkIndex;
}

bool _breaksAfter(SegmentBreakKind kind) =>
    kind == SegmentBreakKind.space ||
    kind == SegmentBreakKind.tab ||
    kind == SegmentBreakKind.zeroWidthBreak;

bool _consumesAtSoftLineStart(SegmentBreakKind kind) =>
    kind == SegmentBreakKind.space ||
    kind == SegmentBreakKind.tab ||
    kind == SegmentBreakKind.zeroWidthBreak ||
    kind == SegmentBreakKind.softHyphen;

bool _hangsForFit(SegmentBreakKind kind) =>
    kind == SegmentBreakKind.space || kind == SegmentBreakKind.tab;

int _findChunk(PreparedLineBreakData p, int segmentIndex) {
  var lo = 0;
  var hi = p.chunks.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (segmentIndex < p.chunks[mid].consumedEnd) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  return lo < p.chunks.length ? lo : -1;
}

/// Lay out the next line starting at `cursor`, advancing it past the line
/// (and past hanging whitespace on the following call). Returns null when
/// the paragraph is exhausted. `maxWidth` may differ per call — this is the
/// variable-width streaming API.
LineRange? nextLineRange(
  PreparedLineBreakData p,
  LineBreakCursor cursor,
  double maxWidth,
) {
  while (true) {
    if (cursor.segmentIndex >= p.segmentCount) return null;
    final chunkIndex = _findChunk(p, cursor.segmentIndex);
    if (chunkIndex < 0) return null;
    final chunk = p.chunks[chunkIndex];

    if (chunk.start == chunk.end) {
      // Blank line between consecutive hard breaks.
      final startSeg = cursor.segmentIndex;
      cursor
        ..segmentIndex = chunk.consumedEnd
        ..graphemeIndex = 0;
      return LineRange(
        width: 0,
        startSegment: startSeg,
        startGrapheme: 0,
        endSegment: chunk.consumedEnd,
        endGrapheme: 0,
        hardBreak: true,
        chunkIndex: chunkIndex,
      );
    }

    final atChunkStart =
        cursor.segmentIndex <= chunk.start && cursor.graphemeIndex == 0;
    if (!atChunkStart && cursor.graphemeIndex == 0) {
      // Soft-wrap line start: leading whitespace hangs on the previous line.
      var s = cursor.segmentIndex;
      while (s < chunk.end && _consumesAtSoftLineStart(p.kinds[s])) {
        s++;
      }
      cursor.segmentIndex = s;
      if (s >= chunk.end) {
        cursor
          ..segmentIndex = chunk.consumedEnd
          ..graphemeIndex = 0;
        continue;
      }
    }
    if (cursor.segmentIndex < chunk.start) cursor.segmentIndex = chunk.start;

    final line = _stepChunk(p, cursor, chunk, chunkIndex, maxWidth);
    if (line == null) {
      cursor
        ..segmentIndex = chunk.consumedEnd
        ..graphemeIndex = 0;
      continue;
    }
    return line;
  }
}

LineRange? _stepChunk(
  PreparedLineBreakData p,
  LineBreakCursor cursor,
  LineBreakChunk chunk,
  int chunkIndex,
  double maxWidth,
) {
  final fitLimit = maxWidth + lineFitEpsilon;
  final startSegment = cursor.segmentIndex;
  final startGrapheme = cursor.graphemeIndex;
  // Whether this line begins at a word boundary (paragraph/hard-break start
  // or after wrapped whitespace) rather than inside a broken word (grapheme
  // continuation, hyphen tail). Gates the whitespace-crossing grapheme fill
  // below, matching SkParagraph's desperate-break behavior.
  final startsAtWordBoundary = startGrapheme == 0 &&
      (startSegment <= chunk.start ||
          _breaksAfter(p.kinds[startSegment - 1]));

  var lineW = 0.0;
  var hasContent = false;
  var endSeg = startSegment;
  var endG = startGrapheme;
  // Last committed break opportunity: the line may run past it (hanging
  // whitespace) but never breaks beyond it without a new opportunity.
  var pendingIdx = -1;
  var pendingPaint = 0.0;
  var pendingFit = 0.0;

  LineRange finish(int eSeg, int eG, double width, {required bool hard}) {
    cursor
      ..segmentIndex = eSeg
      ..graphemeIndex = eG;
    return LineRange(
      width: width,
      startSegment: startSegment,
      startGrapheme: startGrapheme,
      endSegment: eSeg,
      endGrapheme: eG,
      hardBreak: hard,
      chunkIndex: chunkIndex,
    );
  }

  void appendWhole(int i, double advance) {
    hasContent = true;
    lineW += advance;
    endSeg = i + 1;
    endG = 0;
  }

  void updatePending(SegmentBreakKind kind, int i, double advance) {
    if (!_breaksAfter(kind)) return;
    pendingIdx = i + 1;
    pendingPaint = lineW;
    pendingFit = _hangsForFit(kind) ? lineW - advance : lineW;
  }

  // Walk an overlong segment grapheme by grapheme; returns the finished line
  // when it overflows mid-segment, null when the segment fit entirely.
  LineRange? appendBreakableFrom(int i, int fromGrapheme) {
    final advances = p.graphemeAdvances[i]!;
    final preferred = p.preferredBreaks[i];
    var preferredIdx = 0;
    if (preferred != null) {
      while (preferredIdx < preferred.length &&
          preferred[preferredIdx] < fromGrapheme + 1) {
        preferredIdx++;
      }
    }
    var lastPreferredEnd = -1;
    var lastPreferredWidth = 0.0;

    for (var g = fromGrapheme; g < advances.length; g++) {
      final gw = advances[g];
      if (!hasContent) {
        hasContent = true;
        lineW += gw;
        endSeg = i;
        endG = g + 1;
      } else if (lineW + gw > fitLimit) {
        if (preferred != null && lastPreferredEnd > fromGrapheme) {
          return finish(i, lastPreferredEnd, lastPreferredWidth, hard: false);
        }
        return finish(endSeg, endG, lineW, hard: false);
      } else {
        lineW += gw;
        endSeg = i;
        endG = g + 1;
      }
      if (preferred != null &&
          preferredIdx < preferred.length &&
          preferred[preferredIdx] == g + 1) {
        lastPreferredEnd = g + 1;
        lastPreferredWidth = lineW;
        preferredIdx++;
      }
    }
    if (endSeg == i && endG == advances.length) {
      endSeg = i + 1;
      endG = 0;
    }
    return null;
  }

  for (var i = cursor.segmentIndex; i < chunk.end; i++) {
    final kind = p.kinds[i];
    final fromGrapheme = i == startSegment ? startGrapheme : 0;
    final w = p.widths[i];
    final fitContribution = _hangsForFit(kind) ? 0.0 : w;

    if (kind == SegmentBreakKind.softHyphen) {
      // Not part of the line unless chosen: the pending break carries the
      // would-be hyphen width, while endSeg stays at the previous boundary
      // so a later generic break never silently lands ON the hyphen. A
      // hyphen that would itself overflow can never be chosen — keep the
      // earlier opportunity (e.g. the preceding space) instead of shadowing
      // it with an unusable one.
      if (hasContent && fromGrapheme == 0 && lineW + w <= fitLimit) {
        pendingIdx = i + 1;
        pendingPaint = lineW + w; // chosen break shows the hyphen
        pendingFit = lineW + w;
      }
      continue;
    }

    if (!hasContent) {
      if (fromGrapheme > 0 ||
          (fitContribution > fitLimit && p.graphemeAdvances[i] != null)) {
        final line = appendBreakableFrom(i, fromGrapheme);
        if (line != null) return line;
      } else {
        appendWhole(i, w);
      }
      updatePending(kind, i, w);
      continue;
    }

    if (lineW + fitContribution > fitLimit) {
      if (fitContribution > fitLimit &&
          p.graphemeAdvances[i] != null &&
          startsAtWordBoundary &&
          i > chunk.start &&
          _breaksAfter(p.kinds[i - 1])) {
        // A segment that can never fit a whole line fills the REMAINDER of
        // the current line grapheme by grapheme when it follows whitespace
        // AND the line itself started at a word boundary, taking precedence
        // over the pending break. This deliberately follows Flutter
        // ("on ru" / "nning"), not CSS overflow-wrap ("on" / "runni" /
        // "ng"). Across a non-whitespace boundary (hyphen-split, CJK,
        // symbols), or on a line that started inside a broken word, Flutter
        // instead breaks at the last opportunity — the branches below — and
        // the overlong segment grapheme-fills from a fresh line.
        final line = appendBreakableFrom(i, 0);
        if (line != null) return line;
        continue;
      }
      if (pendingIdx >= 0 && pendingFit <= fitLimit) {
        if (endSeg > pendingIdx || (endSeg == pendingIdx && endG > 0)) {
          // Content already extends past the committed opportunity: break at
          // the current segment boundary instead.
          return finish(endSeg, endG, lineW, hard: false);
        }
        return finish(pendingIdx, 0, pendingPaint, hard: false);
      }
      return finish(endSeg, endG, lineW, hard: false);
    }

    appendWhole(i, w);
    updatePending(kind, i, w);
  }

  if (!hasContent) return null;
  return finish(chunk.consumedEnd, 0, lineW, hard: true);
}

/// Line count and widest line at `maxWidth` without materializing anything.
({int lineCount, double maxLineWidth}) measureLineStats(
  PreparedLineBreakData p,
  double maxWidth,
) {
  final cursor = LineBreakCursor();
  var lineCount = 0;
  var maxLineWidth = 0.0;
  while (true) {
    final line = nextLineRange(p, cursor, maxWidth);
    if (line == null) return (lineCount: lineCount, maxLineWidth: maxLineWidth);
    lineCount++;
    if (line.width > maxLineWidth) maxLineWidth = line.width;
  }
}
