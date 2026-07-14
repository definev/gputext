// Opt-in line-break extensions: Liang automatic hyphenation and pluggable
// space-less-script segmentation, wired through prepare/breakLines. These are
// VM-pure (layout only) — no GPU needed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';
import 'package:gputext/src/layout.dart' show measureText;
import 'package:gputext/src/paragraph.dart' as wf;

class _StubHyph implements Hyphenator {
  _StubHyph(this.map);
  final Map<String, List<int>> map;
  @override
  List<int> hyphenate(String word) => map[word] ?? const [];
}

class _StubSeg implements TextSegmenter {
  _StubSeg(this.map);
  final Map<String, List<int>> map;
  @override
  List<int> wordBoundaries(String run) => map[run] ?? const [];
}

void main() {
  late GPUFont font;

  setUpAll(() {
    font = GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync());
  });

  wf.TextRun run(String text) => wf.TextRun(
    text: text,
    font: font,
    fontSizePx: 16,
    color: const [0, 0, 0, 1],
  );

  String lineText(wf.LineMetrics l) =>
      l.items.whereType<wf.LineRun>().map((r) => r.text).join();

  group('Liang hyphenation algorithm', () {
    test('synthetic patterns break at odd inter-letter values', () {
      final h = PatternHyphenator(
        patterns: ['a1b', 'b1c'],
        leftMin: 1,
        rightMin: 1,
      );
      expect(h.hyphenate('abc'), [1, 2]);
      // Even values never break: '2' is suppressed.
      final even = PatternHyphenator(
        patterns: ['a2b'],
        leftMin: 1,
        rightMin: 1,
      );
      expect(even.hyphenate('ab'), isEmpty);
    });

    test('left/right minimums are honoured', () {
      // A break would be allowed at every gap, but min 2/2 forbids the ends.
      final h = PatternHyphenator(patterns: ['a1a'], leftMin: 2, rightMin: 2);
      // 'aaaa': gaps at 1,2,3; only 2 satisfies leftMin=2 & rightMin=2.
      expect(h.hyphenate('aaaa'), [2]);
    });

    test('exceptions override the pattern scan', () {
      final h = PatternHyphenator.fromStrings('', exceptions: 'ta-ble');
      expect(h.hyphenate('table'), [2]);
    });

    test('short words and non-letters are never hyphenated', () {
      final h = PatternHyphenator(patterns: ['a1b'], leftMin: 2, rightMin: 2);
      expect(h.hyphenate('ab'), isEmpty); // too short
      expect(h.hyphenate('a1b'), isEmpty); // contains a digit
    });
  });

  group('automatic hyphenation through layout', () {
    test('a chosen hyphenation break renders a visible "-"', () {
      final h = _StubHyph({
        'hyphenation': [2, 6],
      });
      final config = LineBreakConfig(hyphenator: h);
      // Fit "hy-" but not "hyphen": the break must land at the first hyphen.
      final wrapW =
          measureText('hy', font, 16) + measureText('-', font, 16) + 0.5;
      final para = wf.breakLines(
        [run('hyphenation')],
        wrapW,
        wf.ParagraphStyle(maxWidth: wrapW),
        lineBreak: config,
      );
      expect(para.lines.length, greaterThanOrEqualTo(2));
      expect(
        lineText(para.lines.first),
        'hy-',
        reason: 'the chosen soft-hyphen must materialize a dash',
      );
      // No text is lost across the wrap.
      expect(
        para.lines.map(lineText).join().replaceAll('-', ''),
        'hyphenation',
      );
    });

    test('without a hyphenator the same word does not gain a dash', () {
      final wrapW =
          measureText('hy', font, 16) + measureText('-', font, 16) + 0.5;
      final para = wf.breakLines(
        [run('hyphenation')],
        wrapW,
        wf.ParagraphStyle(maxWidth: wrapW),
      );
      expect(para.lines.map(lineText).join(), isNot(contains('-')));
    });
  });

  group('space-less-script segmentation', () {
    test('a segmenter breaks at word boundaries, not mid-word overflow', () {
      // 8 Thai letters, no spaces; Lato renders them as uniform .notdef boxes,
      // so widths are even and the break math is clean.
      const thai = 'กขคงจฉชฌ';
      final segConfig = LineBreakConfig(
        segmenter: _StubSeg({
          thai: [4], // one word boundary at the midpoint
        }),
      );
      final letter = measureText('ก', font, 16);
      final wrapW = letter * 6 + 0.5; // room for 6 letters

      // With the segmenter, the committed word-boundary break at 4 wins over
      // filling the line to 6 letters.
      final segmented = wf.breakLines(
        [run(thai)],
        wrapW,
        wf.ParagraphStyle(maxWidth: wrapW),
        lineBreak: segConfig,
      );
      expect(lineText(segmented.lines.first).length, 4);

      // Without it, there is no word boundary, so the run overflows and
      // grapheme-fills the line to 6 before breaking.
      final plain = wf.breakLines(
        [run(thai)],
        wrapW,
        wf.ParagraphStyle(maxWidth: wrapW),
      );
      expect(lineText(plain.lines.first).length, 6);
    });

    test('isSaScriptCp detects the space-less blocks', () {
      expect(isSaScriptCp('ก'.runes.first), isTrue); // Thai
      expect(isSaScriptCp('ກ'.runes.first), isTrue); // Lao
      expect(isSaScriptCp('ក'.runes.first), isTrue); // Khmer
      expect(isSaScriptCp('a'.codeUnitAt(0)), isFalse);
    });
  });
}
