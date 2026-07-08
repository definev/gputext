// Visual-parity features vs Flutter's RichText: TextStyle.backgroundColor /
// background / foreground / shadows, StrutStyle, TextHeightBehavior
// (apply-height flags + leadingDistribution), TextWidthBasis.longestLine,
// and TextOverflow.fade.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/engine/engine.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/paragraph.dart' as wf;
import 'package:gputext/src/widgets/span_flattener.dart';
import 'package:gputext/gputext.dart' show GPURichText;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GPUFont font;
  final engine = GPUText.instance;

  setUpAll(() {
    font = GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync());
    engine.registerFont('Lato', font);
  });

  double naturalAscent(double size) =>
      font.verticalMetrics.ascender / font.unitsPerEm * size;
  double naturalDescent(double size) =>
      -font.verticalMetrics.descender / font.unitsPerEm * size;

  group('backgroundColor / background / foreground / shadows (flattener)', () {
    List<wf.InlineItem> flatten(TextStyle style, [String text = 'hi mom']) =>
        flattenSpan(
          TextSpan(text: text, style: style),
          TextScaler.noScaling,
          engine,
        )!;

    test('backgroundColor flows into runs and emits rects', () {
      final items = flatten(
        const TextStyle(
          fontFamily: 'Lato',
          fontSize: 16,
          backgroundColor: Color(0xFF00FF00),
        ),
      );
      final run = items.first as wf.TextRun;
      expect(run.background, [0, 1, 0, 1]);

      final para = wf.breakLines(
        items,
        double.infinity,
        const wf.ParagraphStyle(),
      );
      final emitted = wf.emitInstances(para, 400, wf.TextAlign.left, null);
      expect(emitted.backgrounds, isNotEmpty);
      final line = para.lines.single;
      final total = emitted.backgrounds.fold<double>(0, (w, b) => w + b.width);
      expect(total, closeTo(line.width, 0.5));
      for (final b in emitted.backgrounds) {
        expect(b.top, 0);
        expect(b.height, closeTo(line.ascent + line.descent, 1e-6));
        expect(b.color, [0, 1, 0, 1]);
      }
    });

    test('background Paint contributes its color', () {
      final items = flatten(
        TextStyle(
          fontFamily: 'Lato',
          fontSize: 16,
          background: Paint()..color = const Color(0xFF0000FF),
        ),
      );
      expect((items.first as wf.TextRun).background, [0, 0, 1, 1]);
    });

    test('foreground Paint color wins for the glyph color', () {
      final items = flatten(
        TextStyle(
          fontFamily: 'Lato',
          fontSize: 16,
          foreground: Paint()..color = const Color(0xFFFF0000),
        ),
      );
      expect((items.first as wf.TextRun).color, [1, 0, 0, 1]);
    });

    test('shadows flow into runs and emit shadow boxes', () {
      final items = flatten(
        const TextStyle(
          fontFamily: 'Lato',
          fontSize: 16,
          shadows: [
            Shadow(
              offset: Offset(2, 3),
              blurRadius: 4,
              color: Color(0xFF112233),
            ),
            Shadow(offset: Offset(-1, 0), color: Color(0x80000000)),
          ],
        ),
      );
      final run = items.first as wf.TextRun;
      expect(run.shadows, hasLength(2));
      expect(run.shadows![0].dx, 2);
      expect(run.shadows![0].dy, 3);
      expect(run.shadows![0].blurRadius, 4);
      expect(run.shadows![1].dx, -1);

      final para = wf.breakLines(
        items,
        double.infinity,
        const wf.ParagraphStyle(),
      );
      final emitted = wf.emitInstances(para, 400, wf.TextAlign.left, null);
      expect(emitted.shadowRuns, isNotEmpty);
      final total = emitted.shadowRuns.fold<double>(0, (w, b) => w + b.width);
      expect(total, closeTo(para.lines.single.width, 0.5));
      expect(emitted.shadowRuns.first.shadows, hasLength(2));
    });
  });

  group('strut (VM semantics)', () {
    wf.TextRun run(String text) => wf.TextRun(
      text: text,
      font: font,
      fontSizePx: 16,
      color: const [0, 0, 0, 1],
    );

    test('acts as a floor on line metrics', () {
      final big = wf.breakLines(
        [run('hello')],
        double.infinity,
        const wf.ParagraphStyle(
          strut: wf.StrutMetrics(ascent: 40, descent: 10),
        ),
      );
      expect(big.lines.single.ascent, 40);
      expect(big.lines.single.descent, 10);
      expect(big.lines.single.height, 50);

      final small = wf.breakLines(
        [run('hello')],
        double.infinity,
        const wf.ParagraphStyle(strut: wf.StrutMetrics(ascent: 5, descent: 2)),
      );
      expect(small.lines.single.ascent, closeTo(naturalAscent(16), 0.01));
      expect(small.lines.single.descent, closeTo(naturalDescent(16), 0.01));
    });

    test('leading splits half above, half below', () {
      final para = wf.breakLines(
        [run('hello')],
        double.infinity,
        const wf.ParagraphStyle(
          strut: wf.StrutMetrics(ascent: 40, descent: 10, leading: 6),
        ),
      );
      expect(para.lines.single.ascent, 43);
      expect(para.lines.single.descent, 13);
      expect(para.lines.single.height, 56);
    });

    test('force replaces text metrics', () {
      final para = wf.breakLines(
        [run('hello')],
        double.infinity,
        const wf.ParagraphStyle(
          strut: wf.StrutMetrics(ascent: 10, descent: 5, force: true),
        ),
      );
      expect(para.lines.single.ascent, 10);
      expect(para.lines.single.descent, 5);
      expect(para.lines.single.height, 15);
    });

    test('blank lines are strutted too', () {
      final para = wf.breakLines(
        [run('a\n\nb')],
        double.infinity,
        const wf.ParagraphStyle(
          strut: wf.StrutMetrics(ascent: 40, descent: 10),
        ),
      );
      expect(para.lines, hasLength(3));
      for (final line in para.lines) {
        expect(line.height, greaterThanOrEqualTo(50));
      }
    });
  });

  group('text height behavior (VM semantics)', () {
    wf.TextRun run(String text, {bool? evenLeading}) => wf.TextRun(
      text: text,
      font: font,
      fontSizePx: 16,
      color: const [0, 0, 0, 1],
      height: 3,
      evenLeading: evenLeading,
    );

    test('applyHeightToFirstAscent=false reverts the first ascent only', () {
      final normal = wf.breakLines(
        [run('a\nb')],
        double.infinity,
        const wf.ParagraphStyle(),
      );
      final trimmed = wf.breakLines(
        [run('a\nb')],
        double.infinity,
        const wf.ParagraphStyle(applyHeightToFirstAscent: false),
      );
      expect(trimmed.lines, hasLength(2));
      expect(trimmed.lines[0].ascent, closeTo(naturalAscent(16), 0.01));
      expect(trimmed.lines[0].descent, normal.lines[0].descent);
      expect(trimmed.lines[1].ascent, normal.lines[1].ascent);
      final delta = normal.lines[0].ascent - trimmed.lines[0].ascent;
      expect(trimmed.height, closeTo(normal.height - delta, 0.01));
      expect(trimmed.firstBaseline, closeTo(naturalAscent(16), 0.01));
    });

    test('applyHeightToLastDescent=false reverts the last descent only', () {
      final normal = wf.breakLines(
        [run('a\nb')],
        double.infinity,
        const wf.ParagraphStyle(),
      );
      final trimmed = wf.breakLines(
        [run('a\nb')],
        double.infinity,
        const wf.ParagraphStyle(applyHeightToLastDescent: false),
      );
      expect(trimmed.lines[1].descent, closeTo(naturalDescent(16), 0.01));
      expect(trimmed.lines[0].descent, normal.lines[0].descent);
      final delta = normal.lines[1].descent - trimmed.lines[1].descent;
      expect(trimmed.height, closeTo(normal.height - delta, 0.01));
    });

    test('even leading splits the height excess symmetrically', () {
      final na = naturalAscent(16);
      final nd = naturalDescent(16);
      const target = 3 * 16.0;

      final proportional = wf.breakLines(
        [run('a')],
        double.infinity,
        const wf.ParagraphStyle(),
      );
      final f = target / (na + nd);
      expect(proportional.lines.single.ascent, closeTo(na * f, 0.01));

      final even = wf.breakLines(
        [run('a')],
        double.infinity,
        const wf.ParagraphStyle(evenLeading: true),
      );
      final extra = (target - (na + nd)) / 2;
      expect(even.lines.single.ascent, closeTo(na + extra, 0.01));
      expect(even.lines.single.descent, closeTo(nd + extra, 0.01));
      expect(even.height, closeTo(target, 0.01));

      // Per-run TextStyle.leadingDistribution overrides the paragraph.
      final overridden = wf.breakLines(
        [run('a', evenLeading: true)],
        double.infinity,
        const wf.ParagraphStyle(),
      );
      expect(overridden.lines.single.ascent, closeTo(na + extra, 0.01));
    });
  });

  group('widget plumbing', () {
    Widget host(Widget child) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: child),
    );

    testWidgets('strutStyle grows the widget height', (tester) async {
      const span = TextSpan(
        text: 'x',
        style: TextStyle(fontFamily: 'Lato', fontSize: 16),
      );
      await tester.pumpWidget(host(const GPURichText(text: span)));
      final plain = tester.getSize(find.byType(GPURichText));

      await tester.pumpWidget(
        host(
          const GPURichText(
            text: span,
            strutStyle: StrutStyle(fontFamily: 'Lato', fontSize: 40),
          ),
        ),
      );
      final strutted = tester.getSize(find.byType(GPURichText));
      expect(strutted.height, greaterThan(plain.height));
      expect(
        strutted.height,
        closeTo(naturalAscent(40) + naturalDescent(40), 0.5),
      );
    });

    testWidgets('textHeightBehavior trims the first ascent', (tester) async {
      const span = TextSpan(
        text: 'x',
        style: TextStyle(fontFamily: 'Lato', fontSize: 16, height: 3),
      );
      await tester.pumpWidget(host(const GPURichText(text: span)));
      final normal = tester.getSize(find.byType(GPURichText));

      await tester.pumpWidget(
        host(
          const GPURichText(
            text: span,
            textHeightBehavior: TextHeightBehavior(
              applyHeightToFirstAscent: false,
            ),
          ),
        ),
      );
      final trimmed = tester.getSize(find.byType(GPURichText));
      expect(trimmed.height, lessThan(normal.height));
    });

    testWidgets('textWidthBasis.longestLine hugs the lines', (tester) async {
      const span = TextSpan(
        text: 'aaaaaa bbb',
        style: TextStyle(fontFamily: 'Lato', fontSize: 16),
      );
      // Loose constraints (max only) — a SizedBox would force both bases
      // to the same tight width.
      Widget sized(TextWidthBasis basis) => host(
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 60),
          child: GPURichText(text: span, textWidthBasis: basis),
        ),
      );

      await tester.pumpWidget(sized(TextWidthBasis.parent));
      final parent = tester.getSize(find.byType(GPURichText));
      expect(parent.width, 60); // intrinsic width exceeds the box → clamp

      await tester.pumpWidget(sized(TextWidthBasis.longestLine));
      final longest = tester.getSize(find.byType(GPURichText));
      expect(longest.width, lessThan(60)); // wrapped lines are narrower
    });

    testWidgets('overflow fade and backgrounds paint cleanly', (tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 60,
            height: 20,
            child: const GPURichText(
              text: TextSpan(
                text: 'a very long line that cannot possibly fit here',
                style: TextStyle(
                  fontFamily: 'Lato',
                  fontSize: 16,
                  backgroundColor: Color(0xFF00FF00),
                  shadows: [Shadow(offset: Offset(2, 2), blurRadius: 3)],
                ),
              ),
              overflow: TextOverflow.fade,
              softWrap: false,
              maxLines: 1,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
