// Width-independent paragraph preparation: the expensive half of pretext's
// prepare()/layout() split. prepareParagraph() analyzes and measures the
// inline items ONCE; laying out at any wrap width afterwards is pure
// arithmetic over these arrays (see line_break.dart and paragraph.dart's
// layoutPreparedLines).
//
// Text analysis runs over CONCATENATED windows of adjacent TextRuns, so a
// style change mid-word ("hel" red + "lo" blue) does not create a break
// opportunity — matching Flutter, not the per-run splitting gputext did
// before. A segment that spans style boundaries carries one SegmentPiece per
// (item, offset-range) slice for measurement and materialization. Emoji and
// placeholder items are atomic single-piece segments; adjacent-segment
// boundaries are break opportunities, which gives them Flutter's
// object-replacement break behavior for free.
//
// Widths are in px with letter-spacing (per rendered rune, mirroring the
// emitInstances pen walk) and word-spacing (per ' ') folded in. Kerning
// inside a piece is included; kerning across piece boundaries is not (the
// paint walk kerns same-font boundaries, a sub-epsilon drift in practice).
//
// This file stays VM-pure (no dart:ui / Flutter imports).

import 'dart:typed_data';

import 'analysis.dart';
import 'inline_items.dart';
import 'line_break.dart';
import 'metrics_cache.dart';

/// One (item, offset-range) slice of a segment. `startInSegment == -1`
/// marks an atomic piece (emoji or placeholder box).
class SegmentPiece {
  const SegmentPiece({
    required this.itemIndex,
    required this.startInSegment,
    required this.endInSegment,
    required this.startInItem,
    required this.width,
  });

  const SegmentPiece.atomic(this.itemIndex, this.width)
      : startInSegment = -1,
        endInSegment = -1,
        startInItem = -1;

  final int itemIndex;
  final int startInSegment; // UTF-16 offsets within the segment text
  final int endInSegment;
  final int startInItem; // UTF-16 offset within the TextRun's text
  final double width; // px, spacing folded in

  bool get isAtomic => startInSegment < 0;
}

class PreparedParagraph {
  const PreparedParagraph({
    required this.items,
    required this.lineBreak,
    required this.segmentTexts,
    required this.segmentPieces,
    required this.graphemeEndOffsets,
    required this.minIntrinsicWidth,
    required this.maxIntrinsicWidth,
    required this.fallbackStyleItem,
  });

  final List<InlineItem> items;
  final PreparedLineBreakData lineBreak;

  /// Segment source text ('' for atomic segments).
  final List<String> segmentTexts;
  final List<List<SegmentPiece>> segmentPieces;

  /// UTF-16 end offset per grapheme within the segment text, for segments
  /// with grapheme-level break data; aligned with
  /// [PreparedLineBreakData.graphemeAdvances].
  final List<List<int>?> graphemeEndOffsets;

  /// Widest unbreakable unit (word/emoji/placeholder); spaces excluded.
  final double minIntrinsicWidth;

  /// Widest hard-break-delimited stretch when nothing forces a wrap.
  final double maxIntrinsicWidth;

  /// Item index supplying line metrics for an empty paragraph, or -1.
  final int fallbackStyleItem;

  int get segmentCount => lineBreak.segmentCount;
}

class _WindowPiece {
  _WindowPiece(this.itemIndex, this.start, this.end);

  final int itemIndex;
  final int start; // window offsets
  final int end;
}

PreparedParagraph prepareParagraph(List<InlineItem> items) {
  final widths = <double>[];
  final kinds = <SegmentBreakKind>[];
  final graphemeAdvances = <Float64List?>[];
  final preferredBreaks = <List<int>?>[];
  final segmentTexts = <String>[];
  final segmentPieces = <List<SegmentPiece>>[];
  final graphemeEndOffsets = <List<int>?>[];
  final chunks = <LineBreakChunk>[];

  var chunkStart = 0;
  var minIntrinsic = 0.0;
  var maxIntrinsic = 0.0;
  var chunkSum = 0.0;
  var lastRunIndex = -1;

  final windowBuf = StringBuffer();
  final windowPieces = <_WindowPiece>[];
  var windowText = '';

  void pushSegment(
    SegmentBreakKind kind,
    double width,
    String text,
    List<SegmentPiece> pieces, {
    Float64List? advances,
    List<int>? offsets,
    List<int>? preferred,
  }) {
    widths.add(width);
    kinds.add(kind);
    graphemeAdvances.add(advances);
    preferredBreaks.add(preferred);
    segmentTexts.add(text);
    segmentPieces.add(pieces);
    graphemeEndOffsets.add(offsets);

    final isWhitespace =
        kind == SegmentBreakKind.space || kind == SegmentBreakKind.tab;
    final isInvisible = kind == SegmentBreakKind.zeroWidthBreak ||
        kind == SegmentBreakKind.softHyphen ||
        kind == SegmentBreakKind.hardBreak;
    if (!isWhitespace && !isInvisible && width > minIntrinsic) {
      minIntrinsic = width;
    }
    if (!isInvisible) chunkSum += width;
  }

  void closeChunk(int styleItem) {
    // Called with the hard-break segment already pushed as the last one.
    final hardBreakIndex = widths.length - 1;
    chunks.add(
        LineBreakChunk(chunkStart, hardBreakIndex, widths.length, styleItem));
    chunkStart = widths.length;
    if (chunkSum > maxIntrinsic) maxIntrinsic = chunkSum;
    chunkSum = 0;
  }

  List<_WindowPiece> intersections(int start, int end) {
    final out = <_WindowPiece>[];
    for (final p in windowPieces) {
      if (p.end <= start || p.start >= end) continue;
      out.add(_WindowPiece(
        p.itemIndex,
        p.start > start ? p.start : start,
        p.end < end ? p.end : end,
      ));
    }
    return out;
  }

  TextRun runOf(int itemIndex) => items[itemIndex] as TextRun;

  double scaleOf(TextRun run) => run.fontSizePx / run.font.unitsPerEm;

  // Per-char whitespace segments: each ' '/'\t' costs its own advance +
  // letter-spacing (+ word-spacing for spaces), matching the paint pen walk.
  void pushWhitespaceSegment(
      SegmentBreakKind kind, String text, int startInWindow, String ch) {
    final pieces = <SegmentPiece>[];
    var width = 0.0;
    for (final p in intersections(startInWindow, startInWindow + text.length)) {
      final run = runOf(p.itemIndex);
      final per = segmentMetricsOf(run.font, ch).widthUnits * scaleOf(run) +
          run.letterSpacingPx +
          (ch == ' ' ? run.wordSpacingPx : 0.0);
      final w = per * (p.end - p.start);
      pieces.add(SegmentPiece(
        itemIndex: p.itemIndex,
        startInSegment: p.start - startInWindow,
        endInSegment: p.end - startInWindow,
        startInItem: p.start - _windowStartOf(windowPieces, p.itemIndex),
        width: w,
      ));
      width += w;
    }
    pushSegment(kind, width, text, pieces);
  }

  void pushTextSegment(
    String text,
    int startInWindow,
    SegmentBreakKind kind, {
    required bool allowBreaks,
  }) {
    final rawPieces = intersections(startInWindow, startInWindow + text.length);
    final pieces = <SegmentPiece>[];
    var width = 0.0;

    if (allowBreaks) {
      final adv = <double>[];
      final offs = <int>[];
      for (final p in rawPieces) {
        final run = runOf(p.itemIndex);
        final scale = scaleOf(run);
        final pieceText = windowText.substring(p.start, p.end);
        final m = segmentMetricsOf(run.font, pieceText);
        ensureGraphemeMetrics(run.font, pieceText, m);
        final cum = m.graphemeCumUnits!;
        final ends = m.graphemeEndOffsets!;
        final runes = m.graphemeRenderedRunes!;
        var prev = 0.0;
        var pieceWidth = 0.0;
        for (var g = 0; g < cum.length; g++) {
          final a =
              (cum[g] - prev) * scale + run.letterSpacingPx * runes[g];
          prev = cum[g];
          adv.add(a);
          pieceWidth += a;
          offs.add(p.start - startInWindow + ends[g]);
        }
        pieces.add(SegmentPiece(
          itemIndex: p.itemIndex,
          startInSegment: p.start - startInWindow,
          endInSegment: p.end - startInWindow,
          startInItem: p.start - _windowStartOf(windowPieces, p.itemIndex),
          width: pieceWidth,
        ));
        width += pieceWidth;
      }
      if (adv.length > 1) {
        pushSegment(
          kind,
          width,
          text,
          pieces,
          advances: Float64List.fromList(adv),
          offsets: offs,
          preferred: hyphenPreferredBreaks(text),
        );
        return;
      }
      // Single grapheme: nothing to break inside; fall through as a plain
      // segment (drop the advance arrays).
    }

    if (pieces.isEmpty) {
      for (final p in rawPieces) {
        final run = runOf(p.itemIndex);
        final pieceText = windowText.substring(p.start, p.end);
        final m = segmentMetricsOf(run.font, pieceText);
        final w = m.widthUnits * scaleOf(run) +
            run.letterSpacingPx * m.renderedRuneCount;
        pieces.add(SegmentPiece(
          itemIndex: p.itemIndex,
          startInSegment: p.start - startInWindow,
          endInSegment: p.end - startInWindow,
          startInItem: p.start - _windowStartOf(windowPieces, p.itemIndex),
          width: w,
        ));
        width += w;
      }
    }
    pushSegment(kind, width, text, pieces);
  }

  void flushWindow() {
    if (windowBuf.isEmpty) {
      windowPieces.clear();
      return;
    }
    windowText = windowBuf.toString();
    final segs = analyzeText(windowText);
    for (var i = 0; i < segs.length; i++) {
      final segText = segs.texts[i];
      final segStart = segs.starts[i];
      final kind = segs.kinds[i];
      switch (kind) {
        case SegmentBreakKind.hardBreak:
          final owner = intersections(segStart, segStart + segText.length);
          final styleItem = owner.isEmpty ? lastRunIndex : owner.first.itemIndex;
          pushSegment(kind, 0, segText, const []);
          closeChunk(styleItem);
        case SegmentBreakKind.softHyphen:
          final owner = intersections(segStart, segStart + segText.length);
          var hyphenW = 0.0;
          if (owner.isNotEmpty) {
            final run = runOf(owner.first.itemIndex);
            hyphenW = segmentMetricsOf(run.font, '-').widthUnits *
                    scaleOf(run) +
                run.letterSpacingPx;
          }
          pushSegment(kind, hyphenW, segText, [
            for (final p in owner)
              SegmentPiece(
                itemIndex: p.itemIndex,
                startInSegment: p.start - segStart,
                endInSegment: p.end - segStart,
                startInItem:
                    p.start - _windowStartOf(windowPieces, p.itemIndex),
                width: 0,
              ),
          ]);
        case SegmentBreakKind.space:
          pushWhitespaceSegment(kind, segText, segStart, ' ');
        case SegmentBreakKind.tab:
          pushWhitespaceSegment(kind, segText, segStart, '\t');
        case SegmentBreakKind.zeroWidthBreak:
          pushTextSegment(segText, segStart, kind, allowBreaks: false);
        case SegmentBreakKind.glue:
          pushTextSegment(segText, segStart, kind, allowBreaks: false);
        case SegmentBreakKind.text:
          if (containsCjk(segText)) {
            // Per-grapheme CJK break units with kinsoku merging. Single CJK
            // graphemes are atomic; embedded non-CJK runs stay breakable.
            for (final unit in splitCjkUnits(segText)) {
              pushTextSegment(unit.text, segStart + unit.start, kind,
                  allowBreaks: !containsCjk(unit.text));
            }
          } else {
            pushTextSegment(segText, segStart, kind,
                allowBreaks: segs.isWordLike[i]);
          }
      }
    }
    windowBuf.clear();
    windowPieces.clear();
  }

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is TextRun) {
      lastRunIndex = i;
      if (item.text.isNotEmpty) {
        final start = windowBuf.length;
        windowBuf.write(item.text);
        windowPieces.add(_WindowPiece(i, start, windowBuf.length));
      }
      continue;
    }
    flushWindow();
    final width = switch (item) {
      EmojiItem e => e.width,
      PlaceholderItem p => p.width,
      TextRun _ => 0.0, // unreachable
    };
    pushSegment(SegmentBreakKind.text, width, '', [SegmentPiece.atomic(i, width)]);
  }
  flushWindow();

  if (chunkStart < widths.length) {
    chunks.add(LineBreakChunk(
        chunkStart, widths.length, widths.length, lastRunIndex));
    if (chunkSum > maxIntrinsic) maxIntrinsic = chunkSum;
  }

  return PreparedParagraph(
    items: items,
    lineBreak: PreparedLineBreakData(
      widths: Float64List.fromList(widths),
      kinds: kinds,
      graphemeAdvances: graphemeAdvances,
      preferredBreaks: preferredBreaks,
      chunks: chunks,
    ),
    segmentTexts: segmentTexts,
    segmentPieces: segmentPieces,
    graphemeEndOffsets: graphemeEndOffsets,
    minIntrinsicWidth: minIntrinsic,
    maxIntrinsicWidth: maxIntrinsic,
    fallbackStyleItem: lastRunIndex,
  );
}

int _windowStartOf(List<_WindowPiece> pieces, int itemIndex) {
  for (final p in pieces) {
    if (p.itemIndex == itemIndex) return p.start;
  }
  return 0;
}
