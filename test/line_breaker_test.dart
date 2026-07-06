// Invariants for the pluggable LineBreaker strategies: the explicit greedy
// breaker is identical to the default, and the Knuth-Plass breaker fits its
// lines, loses no text, honors the soft-hyphen contract, composes with
// maxLines/ellipsis, and is never worse than greedy on its own badness
// objective (guaranteed by DP optimality when greedy's breaks are all
// space/SHY candidates).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:windfoil_flutter/src/font.dart';
import 'package:windfoil_flutter/src/layout.dart' show measureText;
import 'package:windfoil_flutter/src/paragraph.dart' as wf;

void main() {
  late WindfoilFont font;

  setUpAll(() {
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    font = WindfoilFont.parse(bytes);
  });

  wf.TextRun run(String text) => wf.TextRun(
        text: text,
        font: font,
        fontSizePx: 16,
        color: const [0, 0, 0, 1],
      );

  wf.ParagraphLines breakWith(
    String text,
    double width,
    wf.LineBreaker breaker, {
    int? maxLines,
    bool addEllipsis = false,
  }) =>
      wf.breakLines(
        [run(text)],
        width,
        wf.ParagraphStyle(
          maxWidth: width,
          lineBreaker: breaker,
          maxLines: maxLines,
          addEllipsis: addEllipsis,
        ),
      );

  String lineText(wf.LineMetrics line) =>
      line.items.whereType<wf.LineRun>().map((r) => r.text).join();

  // Per-line word/space stats with trailing spaces excluded, mirroring the
  // walker's alignment-box semantics.
  ({double word, double spaceW, int spaces}) lineStats(wf.LineMetrics l) {
    var end = l.items.length;
    while (end > 0) {
      final it = l.items[end - 1];
      if (it is wf.LineRun && it.isSpace) {
        end--;
      } else {
        break;
      }
    }
    var word = 0.0;
    var spaceW = 0.0;
    var spaces = 0;
    for (var i = 0; i < end; i++) {
      final it = l.items[i];
      if (it is wf.LineRun && it.isSpace) {
        spaceW += it.width;
        spaces++;
      } else {
        word += it.width;
      }
    }
    return (word: word, spaceW: spaceW, spaces: spaces);
  }

  // The Knuth-Plass badness objective, replicated from the class constants.
  double totalBadness(wf.ParagraphLines para, double maxWidth) {
    var total = 0.0;
    for (final line in para.lines) {
      final s = lineStats(line);
      if (line.hardBreak) {
        total += s.word > maxWidth ? 1e8 : 0;
        continue;
      }
      if (s.spaces <= 0) {
        final slack = maxWidth - s.word;
        total += slack < 0 ? 1e8 : slack * slack * 10;
        continue;
      }
      final naturalSpace = s.spaceW / s.spaces;
      final justified = (maxWidth - s.word) / s.spaces;
      if (justified < 0 || justified < naturalSpace * 0.4) {
        total += 1e8;
        continue;
      }
      final ratio = ((justified - naturalSpace) / naturalSpace).abs();
      var b = ratio * ratio * ratio * 1000;
      final riverExcess = justified / naturalSpace - 1.5;
      if (riverExcess > 0) b += 5000 + riverExcess * riverExcess * 10000;
      final tight = naturalSpace * 0.65;
      if (justified < tight) {
        b += 3000 + (tight - justified) * (tight - justified) * 10000;
      }
      final endsHyphen = lineText(line).endsWith('-');
      if (endsHyphen) b += 50;
      total += b;
    }
    return total;
  }

  // Plain words (no real hyphens) with a soft hyphen every three characters,
  // so every intra-word break is a SHY candidate and added '-' glyphs are
  // unambiguously identifiable.
  String softHyphenate(String text) => text
      .split(' ')
      .map((w) => RegExp('.{1,3}')
          .allMatches(w)
          .map((m) => m.group(0))
          .join('\u00AD'))
      .join(' ');

  const prose =
      'considerable acknowledgement representation unbelievable extraordinary '
      'juxtaposition misunderstanding accomplishment revolutionary metamorphosis';

  test('explicit greedy breaker is identical to the default', () {
    const text =
        'The quick brown zebra jumps over the lazy dog and keeps on running';
    for (final w in [60.0, 120.0, 240.0]) {
      final byDefault =
          wf.breakLines([run(text)], w, wf.ParagraphStyle(maxWidth: w));
      final explicit = breakWith(text, w, const wf.GreedyLineBreaker());
      expect(explicit.lines.length, byDefault.lines.length);
      for (var i = 0; i < byDefault.lines.length; i++) {
        expect(lineText(explicit.lines[i]), lineText(byDefault.lines[i]));
        expect(explicit.lines[i].width,
            closeTo(byDefault.lines[i].width, 1e-9));
      }
    }
  });

  test('Knuth-Plass fits every line and loses no text', () {
    final text = softHyphenate(prose);
    final plain = prose.replaceAll(' ', '');
    for (final w in [90.0, 140.0, 220.0]) {
      final para = breakWith(text, w, const wf.KnuthPlassLineBreaker());
      expect(para.lines.length, greaterThan(1));
      final rebuilt = StringBuffer();
      for (final line in para.lines) {
        // Justified lines may be naturally wider than the box (spaces then
        // COMPRESS at paint, TeX-style), but word content alone must fit,
        // and shrink is bounded by the infeasible ratio.
        final s = lineStats(line);
        expect(s.word, lessThanOrEqualTo(w + 0.01),
            reason: 'line "${lineText(line)}" word content overflows at $w');
        if (s.spaces > 0 && !line.hardBreak) {
          final justified = (w - s.word) / s.spaces;
          expect(justified,
              greaterThanOrEqualTo(s.spaceW / s.spaces * 0.4 - 0.01),
              reason: 'line "${lineText(line)}" over-compressed at $w');
        } else {
          expect(line.width, lessThanOrEqualTo(w + 0.01));
        }
        var t = lineText(line).replaceAll(' ', '');
        // A chosen soft hyphen appends '-'; the corpus has no real hyphens.
        if (!line.hardBreak && t.endsWith('-')) {
          t = t.substring(0, t.length - 1);
        }
        rebuilt.write(t);
      }
      expect(rebuilt.toString(), plain, reason: 'text lost/duplicated at $w');
    }
  });

  test('Knuth-Plass honors the chosen-soft-hyphen contract', () {
    final wrapW = measureText('aaa-', font, 16) + 1;
    final para = breakWith('aaa\u00ADbbb', wrapW, const wf.KnuthPlassLineBreaker());
    expect(para.lines.length, 2);
    expect(lineText(para.lines[0]), 'aaa-');
    expect(para.lines[0].width, closeTo(measureText('aaa-', font, 16), 0.01));
    expect(lineText(para.lines[1]), 'bbb');
  });

  test('Knuth-Plass never beats greedy on its own objective in reverse', () {
    // All of greedy's break opportunities here are space/SHY candidates, so
    // greedy's solution is one feasible path in the Knuth-Plass DP — by
    // optimality KP's total badness must be <= greedy's.
    final text = softHyphenate(prose);
    for (final w in [110.0, 170.0, 260.0]) {
      final kp = breakWith(text, w, const wf.KnuthPlassLineBreaker());
      final greedy = breakWith(text, w, wf.LineBreaker.greedy);
      expect(totalBadness(kp, w),
          lessThanOrEqualTo(totalBadness(greedy, w) + 1e-6),
          reason: 'KP worse than greedy at width $w');
    }
  });

  test('maxLines and ellipsis compose with a custom breaker', () {
    final text = softHyphenate(prose);
    final para = breakWith(text, 150, const wf.KnuthPlassLineBreaker(),
        maxLines: 2, addEllipsis: true);
    expect(para.lines.length, 2);
    expect(para.didExceedMaxLines, isTrue);
    expect(para.ellipsized, isTrue);
    expect((para.lines.last.items.last as wf.LineRun).text, anyOf('…', '...'));
    expect(para.lines.last.width, lessThanOrEqualTo(150.01));
  });

  test('blank lines and multi-paragraph text work with a custom breaker', () {
    final para = breakWith(
        'first block\n\nsecond block here', 70, const wf.KnuthPlassLineBreaker());
    // Blank chunk stays a framework-level empty line.
    final texts = para.lines.map(lineText).toList();
    expect(texts, contains(''));
    expect(texts.join(' ').contains('first'), isTrue);
    expect(texts.join(' ').contains('second'), isTrue);
    for (final line in para.lines) {
      expect(line.height, greaterThan(0));
    }
  });
}
