// Segment analysis for line breaking, ported from pretext (analysis.ts,
// github.com/chenglou/pretext) and adapted to Flutter text semantics.
//
// Splits a window of paragraph text into a stream of segments, each tagged
// with a break kind. EVERY segment boundary is a potential line-break
// opportunity; the merge passes below weld together anything that must not
// be separated (words + trailing punctuation, opening quotes + the following
// word, NBSP-glued runs, URL/numeric clusters). CJK text is split per
// grapheme with kinsoku merging by [splitCjkUnits] at prepare time.
//
// Unlike pretext (CSS white-space: normal), Flutter preserves whitespace
// literally, so there is NO normalization pass: segment `starts` are exact
// UTF-16 offsets into the source window, which selection/caret code can rely
// on. Ordinary spaces still hang at soft-wrap edges (fit width 0 in the
// walker) like CSS/Flutter.
//
// Deliberately not ported (corpus-tuned extras in pretext): Arabic no-space
// punctuation clusters, Myanmar medial glue, escaped-quote clusters,
// word-break: keep-all. Thai/Lao/Khmer have no dictionary segmentation here
// (Dart has no Intl.Segmenter); they degrade to unbreakable runs with
// grapheme-fallback overflow breaking.
//
// This file stays VM-pure (no dart:ui / Flutter imports).

import 'package:characters/characters.dart';

enum SegmentBreakKind {
  text,
  space,
  tab,
  glue,
  zeroWidthBreak,
  softHyphen,
  hardBreak,
}

/// Parallel-array segment stream for one analysis window. `starts` are UTF-16
/// offsets into the analyzed window string.
class TextSegments {
  TextSegments(this.texts, this.isWordLike, this.kinds, this.starts);

  final List<String> texts;
  final List<bool> isWordLike;
  final List<SegmentBreakKind> kinds;
  final List<int> starts;

  int get length => texts.length;
}

// --- Character classes (ported sets) ---

/// CJK punctuation prohibited at line start (kinsoku). A segment starting
/// with one of these merges into the preceding unit.
const kinsokuStart = <String>{
  '，',
  '．',
  '！',
  '：',
  '；',
  '？',
  '、',
  '。',
  '・',
  '）',
  '〕',
  '〉',
  '》',
  '」',
  '』',
  '】',
  '〗',
  '〙',
  '〛',
  'ー',
  '々',
  '〻',
  'ゝ',
  'ゞ',
  'ヽ',
  'ヾ',
};

/// Characters prohibited at line end (openers); they stick forward onto the
/// following unit.
const kinsokuEnd = <String>{
  '"',
  '(',
  '[',
  '{',
  '¡',
  '¿',
  '“',
  '‘',
  '‚',
  '„',
  '«',
  '‹',
  '⸘',
  '（',
  '〔',
  '〈',
  '《',
  '「',
  '『',
  '【',
  '〖',
  '〘',
  '〚',
};

const _forwardStickyGlue = <String>{"'", '’'};

/// Punctuation that merges into the preceding word ("better." is one unit).
const leftStickyPunctuation = <String>{
  '.', ',', '!', '?', ':', ';',
  '،', '؛', '؟', // Arabic comma/semicolon/question
  '।', '॥', // Devanagari danda
  '၊', '။', '၌', '၍', '၏', // Myanmar
  ')', ']', '}',
  '%',
  '"',
  '”', '’', '»', '›',
  '…',
};

const _numericJoinerChars = <String>{
  ':',
  '-',
  '/',
  '×',
  ',',
  '.',
  '+',
  '–',
  '—',
};

const _noSpaceWordBreakAfterChars = <String>{
  '?',
  '֊',
  '-',
  '‐',
  '‒',
  '–',
  '—',
  '…',
  '‼',
  '‽',
  '⁉',
};

final _combiningMarkRe = RegExp(r'\p{M}', unicode: true);
final _decimalDigitRe = RegExp(r'\p{Nd}', unicode: true);
final _wordCharRe = RegExp(r'[\p{L}\p{M}\p{N}_]', unicode: true);
final _wordInternalSymbolRe = RegExp(r'[\p{P}\p{S}\p{Co}]', unicode: true);

bool _isCombiningMark(String ch) => _combiningMarkRe.hasMatch(ch);
bool _isDecimalDigit(String ch) => _decimalDigitRe.hasMatch(ch);

// UAX #14 PR/PO numeric prefix/affix classes, stored as inclusive
// start/end code-point pairs (ported verbatim).
const _lineBreakNumericAffixRanges = <int>[
  0x0024, 0x0025, 0x002B, 0x002B, 0x005C, 0x005C, 0x00A2, 0x00A5, //
  0x00B0, 0x00B1, 0x058F, 0x058F, 0x0609, 0x060B, 0x066A, 0x066A,
  0x07FE, 0x07FF, 0x09F2, 0x09F3, 0x09F9, 0x09FB, 0x0AF1, 0x0AF1,
  0x0BF9, 0x0BF9, 0x0D79, 0x0D79, 0x0E3F, 0x0E3F, 0x17DB, 0x17DB,
  0x2030, 0x2037, 0x2057, 0x2057, 0x20A0, 0x20CF, 0x2103, 0x2103,
  0x2109, 0x2109, 0x2116, 0x2116, 0x2212, 0x2213, 0xA838, 0xA838,
  0xFDFC, 0xFDFC, 0xFE69, 0xFE6A, 0xFF04, 0xFF05, 0xFFE0, 0xFFE1,
  0xFFE5, 0xFFE6, 0x11FDD, 0x11FE0, 0x1E2FF, 0x1E2FF, 0x1ECAC, 0x1ECAC,
  0x1ECB0, 0x1ECB0,
];

// Emoji-presentation blocks, approximated by code-point ranges (Dart RegExp
// binary-property support isn't guaranteed across runtimes).
const _emojiPresentationRanges = <int>[
  0x231A, 0x231B, 0x23E9, 0x23F3, 0x25FD, 0x25FE, 0x2614, 0x2615, //
  0x2648, 0x2653, 0x267F, 0x267F, 0x2693, 0x2693, 0x26A1, 0x26A1,
  0x26CE, 0x26CE, 0x2705, 0x2705, 0x2728, 0x2728, 0x274C, 0x274E,
  0x2753, 0x2755, 0x2757, 0x2757, 0x2795, 0x2797, 0x27B0, 0x27BF,
  0x2B1B, 0x2B1C, 0x2B50, 0x2B55, 0x1F004, 0x1F9FF, 0x1FA70, 0x1FAFF,
];

bool _inRanges(int cp, List<int> ranges) {
  for (var i = 0; i < ranges.length; i += 2) {
    if (cp >= ranges[i] && cp <= ranges[i + 1]) return true;
  }
  return false;
}

bool _isLineBreakNumericAffix(String ch) =>
    _inRanges(ch.runes.first, _lineBreakNumericAffixRanges);

bool isCjkCodePoint(int cp) =>
    (cp >= 0x4E00 && cp <= 0x9FFF) ||
    (cp >= 0x3400 && cp <= 0x4DBF) ||
    (cp >= 0x20000 && cp <= 0x2A6DF) ||
    (cp >= 0x2A700 && cp <= 0x2B73F) ||
    (cp >= 0x2B740 && cp <= 0x2B81F) ||
    (cp >= 0x2B820 && cp <= 0x2CEAF) ||
    (cp >= 0x2CEB0 && cp <= 0x2EBEF) ||
    (cp >= 0x2EBF0 && cp <= 0x2EE5D) ||
    (cp >= 0x2F800 && cp <= 0x2FA1F) ||
    (cp >= 0x30000 && cp <= 0x3134F) ||
    (cp >= 0x31350 && cp <= 0x323AF) ||
    (cp >= 0x323B0 && cp <= 0x33479) ||
    (cp >= 0xF900 && cp <= 0xFAFF) ||
    (cp >= 0x3000 && cp <= 0x303F) ||
    (cp >= 0x3040 && cp <= 0x309F) ||
    (cp >= 0x30A0 && cp <= 0x30FF) ||
    (cp >= 0x3130 && cp <= 0x318F) ||
    (cp >= 0xAC00 && cp <= 0xD7AF) ||
    (cp >= 0xFF00 && cp <= 0xFFEF);

bool containsCjk(String s) {
  for (final cp in s.runes) {
    if (cp >= 0x3000 && isCjkCodePoint(cp)) return true;
  }
  return false;
}

// --- Classification ---

SegmentBreakKind _classifyChar(int cp) {
  switch (cp) {
    case 0x20:
      return SegmentBreakKind.space;
    case 0x09:
      return SegmentBreakKind.tab;
    case 0x0A:
      return SegmentBreakKind.hardBreak;
    case 0xA0 || 0x202F || 0x2060 || 0xFEFF:
      return SegmentBreakKind.glue;
    case 0x200B:
      return SegmentBreakKind.zeroWidthBreak;
    case 0xAD:
      return SegmentBreakKind.softHyphen;
    default:
      return SegmentBreakKind.text;
  }
}

bool _isWordCodePoint(int cp) {
  // ASCII fast path.
  if (cp < 0x80) {
    return (cp >= 0x30 && cp <= 0x39) ||
        (cp >= 0x41 && cp <= 0x5A) ||
        (cp >= 0x61 && cp <= 0x7A) ||
        cp == 0x5F;
  }
  return _wordCharRe.hasMatch(String.fromCharCode(cp));
}

// --- Segment-level predicates (ported) ---

bool _isLeftStickyPunctuationSegment(String segment) {
  var sawPunctuation = false;
  for (final cp in segment.runes) {
    final ch = String.fromCharCode(cp);
    if (leftStickyPunctuation.contains(ch) || _isLineBreakNumericAffix(ch)) {
      sawPunctuation = true;
      continue;
    }
    if (sawPunctuation && _isCombiningMark(ch)) continue;
    return false;
  }
  return sawPunctuation;
}

bool _isCjkLineStartProhibitedSegment(String segment) {
  if (segment.isEmpty) return false;
  for (final cp in segment.runes) {
    final ch = String.fromCharCode(cp);
    if (!kinsokuStart.contains(ch) && !leftStickyPunctuation.contains(ch)) {
      return false;
    }
  }
  return true;
}

bool _isForwardStickyClusterSegment(String segment) {
  if (segment.isEmpty) return false;
  for (final cp in segment.runes) {
    final ch = String.fromCharCode(cp);
    if (!kinsokuEnd.contains(ch) &&
        !_forwardStickyGlue.contains(ch) &&
        !_isCombiningMark(ch) &&
        !_isLineBreakNumericAffix(ch)) {
      return false;
    }
  }
  return true;
}

String? _firstSignificantChar(String text) {
  for (final cp in text.runes) {
    final ch = String.fromCharCode(cp);
    if (!_isCombiningMark(ch)) return ch;
  }
  return null;
}

String? _lastSignificantChar(String text) {
  String? result;
  for (final cp in text.runes) {
    final ch = String.fromCharCode(cp);
    if (!_isCombiningMark(ch)) result = ch;
  }
  return result;
}

bool _startsWithDecimalDigit(String text) {
  final first = _firstSignificantChar(text);
  return first != null && _isDecimalDigit(first);
}

/// Splits a trailing run of forward-sticky characters (openers/quote glue,
/// with combining marks) off `text`. Returns null when there is nothing to
/// split or the whole segment is sticky.
({String head, String tail})? _splitTrailingForwardStickyCluster(String text) {
  final chars = text.runes.map(String.fromCharCode).toList();
  var splitIndex = chars.length;
  while (splitIndex > 0) {
    final ch = chars[splitIndex - 1];
    if (_isCombiningMark(ch) ||
        kinsokuEnd.contains(ch) ||
        _forwardStickyGlue.contains(ch)) {
      splitIndex--;
      continue;
    }
    break;
  }
  if (splitIndex <= 0 || splitIndex == chars.length) return null;
  return (
    head: chars.sublist(0, splitIndex).join(),
    tail: chars.sublist(splitIndex).join(),
  );
}

bool _isEmojiPresentation(String ch) =>
    _inRanges(ch.runes.first, _emojiPresentationRanges);

bool _isNoSpaceWordInternalSymbol(String ch) {
  final cp = ch.runes.first;
  if (cp < 0x80) {
    return (cp >= 0x21 && cp <= 0x2F && cp != 0x2D) ||
        (cp >= 0x3A && cp <= 0x40 && cp != 0x3F) ||
        (cp >= 0x5B && cp <= 0x60) ||
        (cp >= 0x7B && cp <= 0x7E);
  }
  return !_noSpaceWordBreakAfterChars.contains(ch) &&
      !_isEmojiPresentation(ch) &&
      _wordInternalSymbolRe.hasMatch(ch);
}

bool _isNoSpaceWordInternalSymbolSegment(String text) {
  var sawSymbol = false;
  for (final cp in text.runes) {
    final ch = String.fromCharCode(cp);
    if (_isCombiningMark(ch)) continue;
    if (!_isNoSpaceWordInternalSymbol(ch)) return false;
    sawSymbol = true;
  }
  return sawSymbol;
}

bool _endsWithNoSpaceWordJoiner(String text) {
  final last = _lastSignificantChar(text);
  if (last == null) return false;
  return _isNoSpaceWordInternalSymbol(last) || _isLineBreakNumericAffix(last);
}

bool _endsWithLineBreakNumericAffix(String text) {
  final last = _lastSignificantChar(text);
  return last != null && _isLineBreakNumericAffix(last);
}

bool _canJoinNoSpaceWordBoundary(
  String leftText,
  bool leftWordLike,
  String rightText,
  bool rightWordLike,
) {
  final leftSymbol =
      !leftWordLike && _isNoSpaceWordInternalSymbolSegment(leftText);
  final rightSymbol =
      !rightWordLike && _isNoSpaceWordInternalSymbolSegment(rightText);
  final leftAffix = _endsWithLineBreakNumericAffix(leftText);
  final leftEndsJoiner =
      (leftWordLike || leftAffix) && _endsWithNoSpaceWordJoiner(leftText);

  if (!leftSymbol && !rightSymbol && !leftEndsJoiner) return false;
  if (containsCjk(leftText) || containsCjk(rightText)) return false;

  return (leftWordLike || leftSymbol || leftAffix) &&
      (rightWordLike || rightSymbol);
}

bool _segmentContainsDecimalDigit(String text) {
  for (final cp in text.runes) {
    if (_isDecimalDigit(String.fromCharCode(cp))) return true;
  }
  return false;
}

bool _isNumericRunSegment(String text) {
  if (text.isEmpty) return false;
  for (final cp in text.runes) {
    final ch = String.fromCharCode(cp);
    if (_isDecimalDigit(ch) || _numericJoinerChars.contains(ch)) continue;
    return false;
  }
  return true;
}

// --- Merge passes ---

class _SegmentBuilder {
  final texts = <String>[];
  final isWordLike = <bool>[];
  final kinds = <SegmentBreakKind>[];
  final starts = <int>[];

  void push(String text, bool wordLike, SegmentBreakKind kind, int start) {
    texts.add(text);
    isWordLike.add(wordLike);
    kinds.add(kind);
    starts.add(start);
  }

  TextSegments build() => TextSegments(texts, isWordLike, kinds, starts);
}

/// First pass: raw classification. Runs of the same non-text kind group into
/// one segment; word-like characters group into word segments. A non-word
/// text character only continues a segment while the SAME code point repeats
/// ("//", "!!!"), never across different symbols — kinsoku and URL detection
/// need distinct symbols kept apart. Hyphens/em-dashes never group.
TextSegments _classify(String text) {
  final b = _SegmentBuilder();
  var runStart = -1;
  var runWordLike = false;
  var runLastCp = -1;
  SegmentBreakKind? runKind;
  final buf = StringBuffer();

  void flush() {
    if (runKind == null) return;
    b.push(buf.toString(), runWordLike, runKind!, runStart);
    buf.clear();
    runKind = null;
  }

  var offset = 0;
  for (final cp in text.runes) {
    final kind = _classifyChar(cp);
    final wordLike = kind == SegmentBreakKind.text && _isWordCodePoint(cp);
    // BMP-only, like pretext's repeatable-run rule: repeated astral symbols
    // (emoji) stay separate segments so lines can break between them.
    final symbolContinues =
        kind == SegmentBreakKind.text &&
        !wordLike &&
        cp == runLastCp &&
        cp <= 0xFFFF &&
        cp != 0x2D &&
        cp != 0x2014;
    // Hard breaks and soft hyphens never group: each '\n' delimits its own
    // chunk, each SHY is its own break opportunity.
    final neverGroups =
        kind == SegmentBreakKind.hardBreak ||
        kind == SegmentBreakKind.softHyphen;
    if (runKind != kind ||
        runWordLike != wordLike ||
        neverGroups ||
        (kind == SegmentBreakKind.text && !wordLike && !symbolContinues)) {
      flush();
      runKind = kind;
      runWordLike = wordLike;
      runStart = offset;
    }
    buf.writeCharCode(cp);
    runLastCp = cp;
    offset += cp > 0xFFFF ? 2 : 1;
  }
  flush();
  return b.build();
}

/// Second pass: weld left-sticky punctuation ("better."), kinsoku-start
/// clusters after CJK, and word-trailing hyphens into the preceding text
/// segment.
TextSegments _mergeLeftSticky(TextSegments s) {
  final b = _SegmentBuilder();
  for (var i = 0; i < s.length; i++) {
    final text = s.texts[i];
    final kind = s.kinds[i];
    final wordLike = s.isWordLike[i];

    if (kind == SegmentBreakKind.text &&
        b.kinds.isNotEmpty &&
        b.kinds.last == SegmentBreakKind.text) {
      final prev = b.texts.last;
      final prevCjk = containsCjk(prev);
      final appendToPrev =
          // Kinsoku: line-start-prohibited cluster after CJK text.
          (_isCjkLineStartProhibitedSegment(text) && prevCjk) ||
          // Left-sticky punctuation / word-trailing hyphen after
          // non-CJK text.
          (!wordLike &&
              !prevCjk &&
              (_isLeftStickyPunctuationSegment(text) ||
                  (text == '-' && b.isWordLike.last)));
      if (appendToPrev) {
        b.texts.last = prev + text;
        b.isWordLike.last = b.isWordLike.last || wordLike;
        continue;
      }
    }
    b.push(text, wordLike, kind, s.starts[i]);
  }
  return b.build();
}

/// Third pass (backward): prefix forward-sticky clusters (openers, opening
/// quotes) and a numeric-range '-' onto the following text segment.
TextSegments _mergeForwardSticky(TextSegments s) {
  final texts = List.of(s.texts);
  final isWordLike = List.of(s.isWordLike);
  final kinds = List.of(s.kinds);
  final starts = List.of(s.starts);

  var nextLiveIndex = -1;
  for (var i = s.length - 1; i >= 0; i--) {
    if (texts[i].isEmpty) continue;
    if (kinds[i] == SegmentBreakKind.text &&
        !isWordLike[i] &&
        nextLiveIndex >= 0 &&
        kinds[nextLiveIndex] == SegmentBreakKind.text &&
        (_isForwardStickyClusterSegment(texts[i]) ||
            (texts[i] == '-' &&
                _startsWithDecimalDigit(texts[nextLiveIndex])))) {
      texts[nextLiveIndex] = texts[i] + texts[nextLiveIndex];
      starts[nextLiveIndex] = starts[i];
      texts[i] = '';
      continue;
    }
    nextLiveIndex = i;
  }

  final b = _SegmentBuilder();
  for (var i = 0; i < texts.length; i++) {
    if (texts[i].isEmpty) continue;
    b.push(texts[i], isWordLike[i], kinds[i], starts[i]);
  }
  return b.build();
}

/// Fourth pass: NBSP-style glue welds its text neighbors into one
/// unbreakable segment ("12 kg" with NBSP never wraps inside).
TextSegments _mergeGlueConnected(TextSegments s) {
  final b = _SegmentBuilder();
  var read = 0;
  while (read < s.length) {
    var text = s.texts[read];
    var wordLike = s.isWordLike[read];
    var kind = s.kinds[read];
    var start = s.starts[read];

    if (kind == SegmentBreakKind.glue) {
      // Collect the glue run, then attach it to a following text segment if
      // one exists.
      final glueStart = start;
      final glue = StringBuffer(text);
      read++;
      while (read < s.length && s.kinds[read] == SegmentBreakKind.glue) {
        glue.write(s.texts[read]);
        read++;
      }
      if (read < s.length && s.kinds[read] == SegmentBreakKind.text) {
        text = glue.toString() + s.texts[read];
        wordLike = s.isWordLike[read];
        kind = SegmentBreakKind.text;
        start = glueStart;
        read++;
      } else {
        b.push(glue.toString(), false, SegmentBreakKind.glue, glueStart);
        continue;
      }
    } else {
      read++;
    }

    if (kind == SegmentBreakKind.text) {
      // text (glue+ text)* chains join into one segment.
      while (read < s.length && s.kinds[read] == SegmentBreakKind.glue) {
        final glue = StringBuffer();
        while (read < s.length && s.kinds[read] == SegmentBreakKind.glue) {
          glue.write(s.texts[read]);
          read++;
        }
        if (read < s.length && s.kinds[read] == SegmentBreakKind.text) {
          text = text + glue.toString() + s.texts[read];
          wordLike = wordLike || s.isWordLike[read];
          read++;
        } else {
          text = text + glue.toString();
        }
      }
    }
    b.push(text, wordLike, kind, start);
  }
  return b.build();
}

bool _isTextRunBoundary(SegmentBreakKind kind) =>
    kind == SegmentBreakKind.space ||
    kind == SegmentBreakKind.zeroWidthBreak ||
    kind == SegmentBreakKind.hardBreak ||
    kind == SegmentBreakKind.tab;

final _urlSchemeSegmentRe = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:$');

bool _isUrlLikeRunStart(TextSegments s, int index) {
  final text = s.texts[index];
  if (text.startsWith('www.')) return true;
  return _urlSchemeSegmentRe.hasMatch(text) &&
      index + 1 < s.length &&
      s.kinds[index + 1] == SegmentBreakKind.text &&
      s.texts[index + 1] == '//';
}

bool _isUrlQueryBoundarySegment(String text) =>
    text.contains('?') && (text.contains('://') || text.startsWith('www.'));

/// Fifth pass: URL-ish runs become two breakable units max — the path
/// through the query introducer (`?`), then the query string.
TextSegments _mergeUrlRuns(TextSegments s) {
  final b = _SegmentBuilder();
  for (var i = 0; i < s.length; i++) {
    var text = s.texts[i];
    var wordLike = s.isWordLike[i];
    final kind = s.kinds[i];
    final start = s.starts[i];
    var queryStartOverride = -1;

    if (kind == SegmentBreakKind.text && _isUrlLikeRunStart(s, i)) {
      final parts = StringBuffer(text);
      var j = i + 1;
      while (j < s.length && !_isTextRunBoundary(s.kinds[j])) {
        if (queryStartOverride < 0 && _isUrlLikeRunStart(s, j)) {
          queryStartOverride = s.starts[j];
        }
        final nextText = s.texts[j];
        parts.write(nextText);
        wordLike = true;
        j++;
        if (nextText.contains('?')) break;
      }
      text = parts.toString();
      i = j - 1;
    }
    b.push(text, wordLike, kind, start);

    if (!_isUrlQueryBoundarySegment(text)) continue;
    final nextIndex = i + 1;
    if (nextIndex >= s.length || _isTextRunBoundary(s.kinds[nextIndex])) {
      continue;
    }
    final queryParts = StringBuffer();
    final queryStart = queryStartOverride < 0
        ? s.starts[nextIndex]
        : queryStartOverride;
    var j = nextIndex;
    while (j < s.length && !_isTextRunBoundary(s.kinds[j])) {
      queryParts.write(s.texts[j]);
      j++;
    }
    if (queryParts.isNotEmpty) {
      b.push(queryParts.toString(), true, SegmentBreakKind.text, queryStart);
      i = j - 1;
    }
  }
  return b.build();
}

/// Sixth pass: digit/joiner runs ("7:00-9:00", "2026/07/05") merge, then
/// split back at range hyphens so "7:00-" + "9:00" stays breakable.
TextSegments _mergeNumericRuns(TextSegments s) {
  final b = _SegmentBuilder();

  void pushNumericRun(String text, int start) {
    if (text.contains('-')) {
      final parts = text.split('-');
      var shouldSplit = parts.length > 1;
      for (final part in parts) {
        if (!shouldSplit) break;
        if (part.isEmpty ||
            !_segmentContainsDecimalDigit(part) ||
            !_isNumericRunSegment(part)) {
          shouldSplit = false;
        }
      }
      if (shouldSplit) {
        var offset = 0;
        for (var i = 0; i < parts.length; i++) {
          final splitText = i < parts.length - 1 ? '${parts[i]}-' : parts[i];
          b.push(splitText, true, SegmentBreakKind.text, start + offset);
          offset += splitText.length;
        }
        return;
      }
    }
    b.push(text, true, SegmentBreakKind.text, start);
  }

  for (var i = 0; i < s.length; i++) {
    final text = s.texts[i];
    final kind = s.kinds[i];
    if (kind == SegmentBreakKind.text &&
        _isNumericRunSegment(text) &&
        _segmentContainsDecimalDigit(text)) {
      final parts = StringBuffer(text);
      var j = i + 1;
      while (j < s.length &&
          s.kinds[j] == SegmentBreakKind.text &&
          _isNumericRunSegment(s.texts[j])) {
        parts.write(s.texts[j]);
        j++;
      }
      pushNumericRun(parts.toString(), s.starts[i]);
      i = j - 1;
      continue;
    }
    b.push(text, s.isWordLike[i], kind, s.starts[i]);
  }
  return b.build();
}

/// Seventh pass: no-space chains through word-internal symbols
/// ("user@host.com", "a/b/c") merge into one unit.
TextSegments _mergeNoSpaceWordChains(TextSegments s) {
  final b = _SegmentBuilder();
  var i = 0;
  while (i < s.length) {
    final kind = s.kinds[i];
    if (kind == SegmentBreakKind.text) {
      final parts = StringBuffer(s.texts[i]);
      var wordLike = s.isWordLike[i];
      var prevText = s.texts[i];
      var prevWordLike = s.isWordLike[i];
      var j = i + 1;
      while (j < s.length &&
          s.kinds[j] == SegmentBreakKind.text &&
          _canJoinNoSpaceWordBoundary(
            prevText,
            prevWordLike,
            s.texts[j],
            s.isWordLike[j],
          )) {
        parts.write(s.texts[j]);
        wordLike = wordLike || s.isWordLike[j];
        prevText = s.texts[j];
        prevWordLike = s.isWordLike[j];
        j++;
      }
      if (j > i + 1) {
        b.push(parts.toString(), wordLike, SegmentBreakKind.text, s.starts[i]);
        i = j;
        continue;
      }
    }
    b.push(s.texts[i], s.isWordLike[i], kind, s.starts[i]);
    i++;
  }
  return b.build();
}

/// Final pass: a trailing opener stuck to CJK text ("漢「" + "字…") moves to
/// the start of the following CJK segment so it can't end a line.
void _carryTrailingForwardStickyAcrossCjk(TextSegments s) {
  for (var i = 0; i < s.length - 1; i++) {
    if (s.kinds[i] != SegmentBreakKind.text ||
        s.kinds[i + 1] != SegmentBreakKind.text) {
      continue;
    }
    if (!containsCjk(s.texts[i]) || !containsCjk(s.texts[i + 1])) continue;
    final split = _splitTrailingForwardStickyCluster(s.texts[i]);
    if (split == null) continue;
    s.texts[i] = split.head;
    s.texts[i + 1] = split.tail + s.texts[i + 1];
    s.starts[i + 1] = s.starts[i] + split.head.length;
  }
}

/// Analyze one window of paragraph text into the merged segment stream.
TextSegments analyzeText(String text) {
  if (text.isEmpty) return TextSegments(const [], const [], const [], const []);
  var s = _classify(text);
  s = _mergeLeftSticky(s);
  s = _mergeForwardSticky(s);
  s = _mergeGlueConnected(s);
  s = _mergeUrlRuns(s);
  s = _mergeNumericRuns(s);
  s = _mergeNoSpaceWordChains(s);
  _carryTrailingForwardStickyAcrossCjk(s);
  return s;
}

// --- CJK measured-unit splitting (ported from layout.ts buildBaseCjkUnits) ---

/// One CJK measured unit: a break-atomic slice of a CJK-containing segment.
/// `start` is a UTF-16 offset within the segment text.
class CjkUnit {
  const CjkUnit(this.text, this.start);

  final String text;
  final int start;
}

/// Split a CJK-containing text segment into per-grapheme break units with
/// kinsoku merging: prohibited line-start punctuation stays attached to the
/// preceding grapheme, openers attach to the following one, and non-CJK
/// grapheme runs stay whole.
List<CjkUnit> splitCjkUnits(String segText) {
  final units = <CjkUnit>[];
  final unitParts = StringBuffer();
  var unitStart = 0;
  var unitContainsCjk = false;
  var unitIsSingleKinsokuEnd = false;

  void pushUnit() {
    if (unitParts.isEmpty) return;
    units.add(CjkUnit(unitParts.toString(), unitStart));
    unitParts.clear();
    unitContainsCjk = false;
    unitIsSingleKinsokuEnd = false;
  }

  var offset = 0;
  for (final grapheme in segText.characters) {
    final graphemeContainsCjk = containsCjk(grapheme);
    final graphemeStart = offset;
    offset += grapheme.length;

    if (unitParts.isEmpty) {
      unitParts.write(grapheme);
      unitStart = graphemeStart;
      unitContainsCjk = graphemeContainsCjk;
      unitIsSingleKinsokuEnd = kinsokuEnd.contains(grapheme);
      continue;
    }

    if (unitIsSingleKinsokuEnd ||
        kinsokuStart.contains(grapheme) ||
        leftStickyPunctuation.contains(grapheme) ||
        (!unitContainsCjk && !graphemeContainsCjk)) {
      unitParts.write(grapheme);
      unitContainsCjk = unitContainsCjk || graphemeContainsCjk;
      unitIsSingleKinsokuEnd = false;
      continue;
    }

    pushUnit();
    unitParts.write(grapheme);
    unitStart = graphemeStart;
    unitContainsCjk = graphemeContainsCjk;
    unitIsSingleKinsokuEnd = kinsokuEnd.contains(grapheme);
  }
  pushUnit();
  return units;
}

// --- Preferred in-segment break points (hyphen family) ---

bool _isPreferredBreakGrapheme(String g) =>
    g == '-' || g == '֊' || g == '‐' || g == '‒' || g == '–' || g == '—';

final _preferredBreakCharRe = RegExp(r'[-֊‐‒–—]');

/// Grapheme end-indices inside `text` after which an overlong-segment break
/// prefers to happen (after hyphens), or null when none exist.
List<int>? hyphenPreferredBreaks(String text) {
  if (!_preferredBreakCharRe.hasMatch(text)) return null;
  final breaks = <int>[];
  var graphemeIndex = 0;
  for (final g in text.characters) {
    graphemeIndex++;
    if (_isPreferredBreakGrapheme(g)) breaks.add(graphemeIndex);
  }
  return breaks.isEmpty ? null : breaks;
}
