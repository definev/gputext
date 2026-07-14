// Opt-in line-breaking extensions: automatic hyphenation and dictionary/model
// word segmentation for scripts that write without spaces (Thai, Lao, Khmer,
// Myanmar — UAX #14 class SA). Both are pluggable and default OFF, so the base
// package ships no hyphenation-pattern or dictionary data and behaves exactly
// as before unless a caller supplies an implementation.
//
// Wire a [LineBreakConfig] into `prepareParagraph` / `breakLines` (or
// `GPURichText.lineBreak`) to enable them.

/// Inserts hyphenation break opportunities inside a word. Breaking at one of
/// the returned offsets renders a visible '-' (it reuses the soft-hyphen
/// mechanism), so this is true automatic hyphenation, not just a break point.
abstract class Hyphenator {
  /// UTF-16 offsets within [word] (strictly between 1 and `word.length-1`,
  /// ascending) where a hyphen may be inserted. Return const [] for no breaks.
  List<int> hyphenate(String word);
}

/// Splits a run of space-less script (Thai/Lao/Khmer/Myanmar) into words. The
/// returned offsets become zero-width break opportunities — a run that was one
/// unbreakable segment can then wrap between words.
abstract class TextSegmenter {
  /// UTF-16 offsets within [run] (strictly interior, ascending) at which a line
  /// break is allowed. Return const [] to leave the run unbreakable.
  List<int> wordBoundaries(String run);
}

/// Bundle of opt-in line-breaking strategies threaded through prepare/layout.
class LineBreakConfig {
  const LineBreakConfig({this.hyphenator, this.segmenter});

  /// Automatic hyphenation (e.g. a [PatternHyphenator]); null disables it.
  final Hyphenator? hyphenator;

  /// Word segmentation for space-less scripts; null leaves such runs
  /// unbreakable (the pre-existing behaviour).
  final TextSegmenter? segmenter;

  bool get isEmpty => hyphenator == null && segmenter == null;
}

/// UAX #14 class SA — complex-context scripts that do not use spaces between
/// words and need dictionary/model segmentation to wrap. Covers the common
/// Brahmic space-less blocks. A [TextSegmenter] is applied only to runs that
/// contain one of these.
bool isSaScriptCp(int cp) =>
    (cp >= 0x0E00 && cp <= 0x0E7F) || // Thai
    (cp >= 0x0E80 && cp <= 0x0EFF) || // Lao
    (cp >= 0x1780 && cp <= 0x17FF) || // Khmer
    (cp >= 0x1000 && cp <= 0x109F) || // Myanmar
    (cp >= 0x1950 && cp <= 0x197F) || // Tai Le
    (cp >= 0x1A20 && cp <= 0x1AAF); // Tai Tham

/// Whether [text] contains any SA-script code point worth segmenting.
bool containsSaScript(String text) {
  for (final cp in text.runes) {
    if (isSaScriptCp(cp)) return true;
  }
  return false;
}

/// Liang's hyphenation algorithm (the one TeX and browsers use). Feed it a
/// language's packed patterns — e.g. the `hyph-en-us` patterns from the
/// hyphenation-patterns projects — and optional whole-word exceptions.
///
/// Patterns look like `hy3ph`, `he2n`, `.in1` — letters interleaved with digit
/// priorities; an ODD value at an inter-letter position permits a break there.
/// The base package bundles no patterns; the app supplies them (so it pays only
/// for the languages it needs).
class PatternHyphenator implements Hyphenator {
  PatternHyphenator({
    required List<String> patterns,
    Map<String, List<int>> exceptions = const {},
    this.leftMin = 2,
    this.rightMin = 2,
  }) {
    for (final pat in patterns) {
      final letters = StringBuffer();
      final points = <int>[0];
      for (final ch in pat.split('')) {
        final d = _digit(ch);
        if (d >= 0) {
          points[points.length - 1] = d;
        } else {
          letters.write(ch);
          points.add(0);
        }
      }
      _patterns[letters.toString()] = points;
    }
    for (final e in exceptions.entries) {
      _exceptions[e.key.toLowerCase()] = e.value;
    }
  }

  /// Parse whitespace-separated TeX-style pattern and exception lists (the
  /// format of `hyph-*.tex` / hyphenopoly sources). [exceptions] entries use a
  /// hyphen to mark break points, e.g. `as-so-ciate`.
  factory PatternHyphenator.fromStrings(
    String patterns, {
    String exceptions = '',
    int leftMin = 2,
    int rightMin = 2,
  }) {
    final ex = <String, List<int>>{};
    for (final w in exceptions.split(RegExp(r'\s+'))) {
      if (w.isEmpty) continue;
      final plain = w.replaceAll('-', '');
      final breaks = <int>[];
      var offset = 0;
      for (final ch in w.split('')) {
        if (ch == '-') {
          breaks.add(offset);
        } else {
          offset++;
        }
      }
      ex[plain.toLowerCase()] = breaks;
    }
    return PatternHyphenator(
      patterns: patterns
          .split(RegExp(r'\s+'))
          .where((p) => p.isNotEmpty)
          .toList(),
      exceptions: ex,
      leftMin: leftMin,
      rightMin: rightMin,
    );
  }

  /// Minimum letters kept before / after a hyphen (typographic convention:
  /// 2 and 3 for English).
  final int leftMin;
  final int rightMin;

  final Map<String, List<int>> _patterns = {};
  final Map<String, List<int>> _exceptions = {};

  static int _digit(String ch) {
    final c = ch.codeUnitAt(0);
    return (c >= 0x30 && c <= 0x39) ? c - 0x30 : -1;
  }

  @override
  List<int> hyphenate(String word) {
    if (word.length < leftMin + rightMin) return const [];
    // Letters only — punctuation/digits inside a token get no hyphenation.
    for (final cp in word.runes) {
      if (!_isLetter(cp)) return const [];
    }
    final lower = word.toLowerCase();
    final predefined = _exceptions[lower];
    if (predefined != null) {
      return predefined
          .where((p) => p >= leftMin && p <= word.length - rightMin)
          .toList();
    }

    // '.' marks word boundaries so boundary patterns (.in1, 4tion.) can match.
    final w = '.$lower.';
    final n = w.length;
    final values = List<int>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j <= n; j++) {
        final pts = _patterns[w.substring(i, j)];
        if (pts == null) continue;
        for (var k = 0; k < pts.length; k++) {
          final idx = i + k;
          if (pts[k] > values[idx]) values[idx] = pts[k];
        }
      }
    }
    // A break after `p` word characters maps to the gap before w[p+1].
    final breaks = <int>[];
    for (var p = leftMin; p <= word.length - rightMin; p++) {
      if (values[p + 1].isOdd) breaks.add(p);
    }
    return breaks;
  }

  // Latin + common accented letters; Liang patterns are letter-only anyway.
  static bool _isLetter(int cp) =>
      (cp >= 0x41 && cp <= 0x5A) ||
      (cp >= 0x61 && cp <= 0x7A) ||
      (cp >= 0xC0 && cp <= 0x24F && cp != 0xD7 && cp != 0xF7);
}
