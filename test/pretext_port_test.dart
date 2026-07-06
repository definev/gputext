// Durable invariants for the pretext-ported line breaker (analysis +
// prepare/layout split), plus a TextPainter-as-oracle sweep in the spirit of
// pretext's browser-accuracy checks: Flutter's own paragraph engine is the
// ground truth for line counts over a mixed corpus at many widths.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:windfoil_flutter/src/font.dart';
import 'package:windfoil_flutter/src/layout.dart' show measureText;
import 'package:windfoil_flutter/src/paragraph.dart' as wf;
import 'package:windfoil_flutter/src/text/analysis.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WindfoilFont font;

  setUpAll(() async {
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    font = WindfoilFont.parse(bytes);
    // Register the same face with Flutter's engine so TextPainter shapes the
    // oracle corpus with identical advances.
    final loader = FontLoader('LatoOracle')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  });

  wf.TextRun run(String text, {double size = 16}) => wf.TextRun(
        text: text,
        font: font,
        fontSizePx: size,
        color: const [0, 0, 0, 1],
      );

  wf.ParagraphLines breakAt(String text, double width) =>
      wf.breakLines([run(text)], width, wf.ParagraphStyle(maxWidth: width));

  String lineText(wf.LineMetrics line) => line.items
      .whereType<wf.LineRun>()
      .map((r) => r.text)
      .join();

  group('segment analysis', () {
    test('punctuation is left-sticky, openers are forward-sticky', () {
      expect(analyzeText('better. word').texts, contains('better.'));
      expect(analyzeText('he said "quote" ok').texts, contains('"quote"'));
      expect(analyzeText(r'costs $100 now').texts, contains(r'$100'));
    });

    test('numeric and URL runs stay coherent', () {
      expect(analyzeText('open 7:00-9:00 daily').texts,
          containsAll(['7:00-', '9:00']));
      final url = analyzeText('see https://example.com/docs?q=1 now').texts;
      expect(url, contains('https://example.com/docs?'));
      expect(url, contains('q=1'));
      expect(analyzeText('mail user@host.com now').texts,
          contains('user@host.com'));
    });

    test('kinsoku merges prohibited punctuation into CJK units', () {
      final units = splitCjkUnits('「こんにちは。」');
      // The opener sticks forward, the closer/full stop stick backward:
      // no unit is bare line-start-prohibited punctuation.
      expect(units.first.text, '「こ');
      expect(units.last.text, 'は。」');
      for (final u in units) {
        expect(kinsokuStart.contains(u.text.substring(0, 1)), isFalse,
            reason: 'unit "${u.text}" must not start with kinsoku');
      }
    });
  });

  group('line breaking invariants', () {
    test('NBSP glue prevents a break inside the glued unit', () {
      final wrapW = measureText('aa bb', font, 16) + 1;
      final glued = wf.breakLines([run('aa bb\u00A0cc dd')], wrapW,
          wf.ParagraphStyle(maxWidth: wrapW));
      // 'bb cc' with an NBSP cannot split: it moves to line 2 whole.
      expect(lineText(glued.lines[0]), 'aa ');
      expect(lineText(glued.lines[1]), 'bb\u00A0cc ');
    });

    test('ZWSP is an invisible break opportunity', () {
      final wrapW = measureText('aaa', font, 16) + 1;
      final para = breakAt('aaa\u200Baaa', wrapW);
      expect(para.lines.length, 2);
      expect(lineText(para.lines[0]), 'aaa');
      expect(lineText(para.lines[1]), 'aaa');
      // Unbroken, the ZWSP adds no width.
      final wide = breakAt('aaa\u200Baaa', double.infinity);
      expect(wide.lines.single.width,
          closeTo(measureText('aaaaaa', font, 16), 0.01));
    });

    test('soft hyphen: invisible unless chosen, then materializes "-"', () {
      final fits = breakAt('aaa\u00ADbbb', double.infinity);
      expect(fits.lines.length, 1);
      expect(lineText(fits.lines.single), isNot(contains('-')));
      expect(fits.lines.single.width,
          closeTo(measureText('aaabbb', font, 16), 0.01));

      final wrapW = measureText('aaa-', font, 16) + 1;
      final broken = breakAt('aaa\u00ADbbb', wrapW);
      expect(broken.lines.length, 2);
      expect(lineText(broken.lines[0]), 'aaa-');
      expect(lineText(broken.lines[1]), 'bbb');
      expect(broken.lines[0].width,
          closeTo(measureText('aaa-', font, 16), 0.01));
    });

    test('kinsoku punctuation never starts a line', () {
      // Lato has no CJK glyphs (notdef advances), which is fine: breaking is
      // font-independent.
      const text = '彼は「こんにちは。」と言った。';
      for (final w in [20.0, 30.0, 40.0, 60.0]) {
        final para = breakAt(text, w);
        for (final line in para.lines) {
          final t = lineText(line);
          if (t.isEmpty) continue;
          expect(kinsokuStart.contains(t.substring(0, 1)), isFalse,
              reason: 'line "$t" at width $w starts with kinsoku');
          expect(kinsokuEnd.contains(t.substring(t.length - 1)), isFalse,
              reason: 'line "$t" at width $w ends with an opener');
        }
      }
    });

    test('overlong words break at grapheme boundaries, losing nothing', () {
      final wrapW = measureText('aaa', font, 16) + 0.5;
      final para = breakAt('aaaaaaaaaa', wrapW);
      expect(para.lines.length, greaterThan(2));
      for (final line in para.lines) {
        expect(line.width, lessThanOrEqualTo(wrapW + 0.01));
      }
      expect(para.lines.map(lineText).join(), 'aaaaaaaaaa');
    });

    test('mid-word style changes do not create break opportunities', () {
      final red = run('hel');
      final blue = wf.TextRun(
        text: 'lo world',
        font: font,
        fontSizePx: 16,
        color: const [0, 0, 1, 1],
      );
      final helloW = measureText('hello', font, 16);
      final worldW = measureText('world', font, 16);
      final wrapW = (helloW > worldW ? helloW : worldW) + 1;
      final para = wf.breakLines(
          [red, blue], wrapW, wf.ParagraphStyle(maxWidth: wrapW));
      // The trailing space hangs on line 1, like Flutter.
      expect(lineText(para.lines[0]), 'hello ');
      expect(lineText(para.lines[1]), 'world');
      // Style boundaries materialize as separate runs of one break unit.
      expect((para.lines[0].items[0] as wf.LineRun).text, 'hel');
      expect((para.lines[0].items[1] as wf.LineRun).text, 'lo');
    });

    test('ellipsis trimming never splits a surrogate pair', () {
      // '🌚' renders as .notdef here, but each is one grapheme; trimming
      // must remove whole clusters.
      final wrapW = font.advanceOf('🌚') / font.unitsPerEm * 16 * 2.5;
      final para = wf.breakLines(
        [run('🌚🌚🌚🌚🌚🌚')],
        wrapW,
        wf.ParagraphStyle(maxWidth: wrapW, maxLines: 1, addEllipsis: true),
      );
      expect(para.ellipsized, isTrue);
      for (final item in para.lines.single.items) {
        if (item is! wf.LineRun) continue;
        for (final cu in item.text.codeUnits) {
          // A well-formed run has no unpaired surrogate at its edges.
          expect(cu >= 0xDC00 && cu <= 0xDFFF && item.text.codeUnits.first == cu,
              isFalse);
        }
        expect(
            item.text.codeUnits.last >= 0xD800 &&
                item.text.codeUnits.last <= 0xDBFF,
            isFalse,
            reason: 'run "${item.text}" ends with an unpaired high surrogate');
      }
    });

    test('prepare once, layout at many widths deterministically', () {
      const text = 'The quick brown fox jumps over the lazy dog';
      final prepared = wf.prepareParagraph([run(text)]);
      for (final w in [50.0, 80.0, 120.0, 200.0, 400.0]) {
        final oneShot = breakAt(text, w);
        final split = wf.layoutPreparedLines(
            prepared, w, wf.ParagraphStyle(maxWidth: w));
        expect(split.lines.length, oneShot.lines.length);
        for (var i = 0; i < split.lines.length; i++) {
          expect(split.lines[i].width, closeTo(oneShot.lines[i].width, 1e-9));
        }
        expect(split.minIntrinsicWidth, oneShot.minIntrinsicWidth);
        expect(split.maxIntrinsicWidth, oneShot.maxIntrinsicWidth);
      }
    });

    test('URLs wrap as path+query units, driving min intrinsic width', () {
      final para =
          breakAt('see https://example.com/docs?q=1 now', double.infinity);
      expect(
          para.minIntrinsicWidth,
          closeTo(measureText('https://example.com/docs?', font, 16), 0.01));
    });

    test('multiple mid-line spaces are preserved', () {
      final para = breakAt('a  b', double.infinity);
      expect(para.lines.single.width,
          closeTo(measureText('a  b', font, 16), 0.01));
    });
  });

  group('TextPainter oracle', () {
    // No ligature-forming pairs (fi/fl): windfoil applies those in the
    // flattener, not in these raw runs, and the oracle would ligate.
    const corpus = [
      'The quick brown zebra jumps over the lazy dog and keeps on running',
      'aaa bbb ccc ddd eee',
      'Hello, world! What a great day.',
      'well-known state-of-the-art methods work',
      'a  b  c double spaced',
      'pack of 12\u00A0kg boxes went out',
      'supercalifragilisticexpialidocious',
      'short',
    ];
    const widths = [43.0, 61.0, 87.0, 118.0, 166.0, 231.0, 320.0];

    testWidgets('line counts match Flutter for a mixed corpus',
        (tester) async {
      for (final text in corpus) {
        for (final w in widths) {
          final painter = TextPainter(
            text: TextSpan(
              text: text,
              style: const TextStyle(fontFamily: 'LatoOracle', fontSize: 16),
            ),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: w);
          final oracle = painter.computeLineMetrics().length;
          painter.dispose();

          final ours = breakAt(text, w).lines.length;
          expect(ours, oracle,
              reason: '"$text" at width $w: windfoil=$ours flutter=$oracle');
        }
      }
    });
  });
}
