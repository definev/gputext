import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/widgets/emoji.dart';
import 'package:gputext/src/paragraph.dart' as wf;
import 'package:gputext/gputext.dart';

const _wideFontPath = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';

void main() {
  final engine = GPUText.instance;
  late GPUFont lato;
  GPUFont? wide;

  setUpAll(() {
    lato = GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync());
    engine.registerFont('Lato', lato);
    final wideFile = File(_wideFontPath);
    if (wideFile.existsSync()) {
      wide = GPUFont.parse(wideFile.readAsBytesSync());
      engine.registerFont('WideFallback', wide!);
    }
  });

  tearDown(() => engine.setFallbackFamilies(const []));

  test('resolveFontForChar walks the family chain', () {
    expect(lato.hasGlyph('你'), isFalse); // precondition
    expect(engine.resolveFontForChar('a', families: const ['Lato']), isNotNull);
    expect(engine.resolveFontForChar('你', families: const ['Lato']), isNull);
    if (wide == null) return;
    expect(
      identical(
        engine.resolveFontForChar(
          '你',
          families: const ['Lato', 'WideFallback'],
        ),
        wide,
      ),
      isTrue,
    );
    engine.setFallbackFamilies(const ['WideFallback']);
    expect(
      identical(engine.resolveFontForChar('你', families: const ['Lato']), wide),
      isTrue,
    );
  });

  test('flattener splits runs per character across fallback fonts', () {
    if (wide == null) return;
    final items = flattenSpan(
      const TextSpan(
        style: TextStyle(
          fontFamily: 'Lato',
          fontSize: 16,
          fontFamilyFallback: ['WideFallback'],
        ),
        text: 'ab你好 cd',
      ),
      TextScaler.noScaling,
      engine,
    );
    final runs = items!.cast<wf.TextRun>();
    expect(runs.length, 3);
    expect(runs[0].text, 'ab');
    expect(identical(runs[0].font, lato), isTrue);
    // The space after 好 stays with the surrounding (fallback) font.
    expect(runs[1].text, '你好 ');
    expect(identical(runs[1].font, wide), isTrue);
    expect(runs[2].text, 'cd');
    expect(identical(runs[2].font, lato), isTrue);
  });

  test('a combining mark stays with its base in one fallback run', () {
    if (wide == null) return;
    // Lato has 'e' but no combining acute; Arial Unicode has both. The whole
    // grapheme 'e\u0301' must resolve to ONE font that covers base + mark —
    // NOT split 'e' (Lato) from the mark (wide), which detaches the accent and
    // breaks its positioning. Per-rune fallback used to produce two runs here.
    expect(lato.hasGlyphForRune(0x65), isTrue); // 'e'
    expect(lato.hasGlyphForRune(0x0301), isFalse); // combining acute
    expect(wide!.hasGlyphForRune(0x0301), isTrue);

    final items = flattenSpan(
      const TextSpan(
        style: TextStyle(
          fontFamily: 'Lato',
          fontSize: 16,
          fontFamilyFallback: ['WideFallback'],
        ),
        text: 'e\u0301', // é = base + combining mark
      ),
      TextScaler.noScaling,
      engine,
    );
    final runs = items!.cast<wf.TextRun>();
    expect(runs.length, 1, reason: 'the cluster must not split across fonts');
    // The whole cluster went to the font covering base + mark.
    expect(identical(runs.single.font, wide), isTrue);
  });

  test('no run is ever a lone combining mark across a fallback boundary', () {
    if (wide == null) return;
    // 'a' (Lato) then 'e\u0301' (cluster → wide) then 'b' (Lato). The mark must
    // never end up in a run by itself.
    final items = flattenSpan(
      const TextSpan(
        style: TextStyle(
          fontFamily: 'Lato',
          fontSize: 16,
          fontFamilyFallback: ['WideFallback'],
        ),
        text: 'ae\u0301b',
      ),
      TextScaler.noScaling,
      engine,
    );
    final runs = items!.cast<wf.TextRun>();
    for (final r in runs) {
      final src = r.sourceText ?? r.text;
      expect(
        src == '\u0301',
        isFalse,
        reason: 'a combining mark must never be its own run',
      );
    }
    // And the mark rides with its base: some run contains both 'e' and the mark.
    expect(
      runs.any((r) => (r.sourceText ?? r.text).contains('e\u0301')),
      isTrue,
    );
  });

  test('expandUncoveredSpans delegates uncovered chars, per CJK character', () {
    const span = TextSpan(
      style: TextStyle(fontFamily: 'Lato', fontSize: 18),
      text: 'go 中文 now',
    );
    final out = expandUncoveredSpans(span, engine) as TextSpan;
    final children = out.children!;
    final widgets = children.whereType<WidgetSpan>().toList();
    expect(widgets.length, 2); // one per ideograph (wrap points)
    expect((((widgets[0].child) as Text).textSpan! as TextSpan).text, '中');
    expect((((widgets[1].child) as Text).textSpan! as TextSpan).text, '文');
    expect((children.first as TextSpan).text, 'go ');
    expect((children.last as TextSpan).text, ' now');
    // Delegated style carries size + color for parity.
    expect(((widgets[0].child) as Text).style!.fontSize, 18);
  });

  test('expandUncoveredSpans is a no-op once a fallback font covers', () {
    if (wide == null) return;
    engine.setFallbackFamilies(const ['WideFallback']);
    const span = TextSpan(
      style: TextStyle(fontFamily: 'Lato', fontSize: 18),
      text: 'go 中文 now',
    );
    expect(identical(expandUncoveredSpans(span, engine), span), isTrue);
  });

  test('native CJK runs wrap between ideographs (no spaces needed)', () {
    if (wide == null) return;
    final cjkRun = wf.TextRun(
      text: '你好世界你好世界',
      font: wide!,
      fontSizePx: 16,
      color: const [0, 0, 0, 1],
    );
    final oneChar = 16.0; // full-width advance = 1em at 16px (2048/2048)
    final para = wf.breakLines(
      [cjkRun],
      oneChar * 3 + 1,
      wf.ParagraphStyle(maxWidth: oneChar * 3 + 1),
    );
    expect(para.lines.length, greaterThanOrEqualTo(3)); // wraps mid-"word"
    expect(para.minIntrinsicWidth, lessThanOrEqualTo(oneChar + 0.1));
  });

  testWidgets('uncovered CJK renders as delegated inline Text', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: GPURichText(
            text: TextSpan(
              style: TextStyle(fontFamily: 'Lato', fontSize: 16),
              text: 'mixed 漢字 here',
            ),
          ),
        ),
      ),
    );
    expect(find.text('漢'), findsOneWidget);
    expect(find.text('字'), findsOneWidget);
    final paraRect = tester.getRect(find.byType(GPURichText));
    final hanRect = tester.getRect(find.text('漢'));
    expect(paraRect.contains(hanRect.center), isTrue);
  });
}
