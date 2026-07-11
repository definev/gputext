import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/gputext.dart';

void main() {
  setUpAll(() {
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    GPUText.instance.registerFont('Lato', GPUFont.parse(bytes));
  });

  const style = TextStyle(fontFamily: 'Lato', fontSize: 16);

  testWidgets('fills a tight width and wraps to multiple lines', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 160,
            child: GPURichText(
              text: TextSpan(
                style: style,
                text:
                    'a long sentence that definitely wraps onto '
                    'several lines here',
              ),
            ),
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(GPURichText));
    expect(size.width, 160);
    // Wrapped: taller than any single Lato line at 16px (~19px).
    expect(size.height, greaterThan(30));
  });

  testWidgets('shrink-wraps to text width under loose constraints', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: GPURichText(
            text: TextSpan(style: style, text: 'hi'),
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(GPURichText));
    expect(size.width, greaterThan(2));
    expect(size.width, lessThan(40));
    expect(size.height, greaterThan(10));
    expect(size.height, lessThan(30));
  });

  testWidgets('maxLines caps the height', (tester) async {
    const span = TextSpan(
      style: style,
      text:
          'words words words words words words words words words '
          'words words words words words words words words words',
    );
    Future<Size> sizeFor(int? maxLines) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 120,
              child: GPURichText(
                text: span,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      );
      return tester.getSize(find.byType(GPURichText));
    }

    final unlimited = await sizeFor(null);
    final capped = await sizeFor(2);
    expect(capped.height, lessThan(unlimited.height));
  });

  testWidgets('baseline alignment works in a Row', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              GPURichText(
                text: TextSpan(
                  style: TextStyle(fontFamily: 'Lato', fontSize: 32),
                  text: 'Big',
                ),
              ),
              GPURichText(
                text: TextSpan(
                  style: TextStyle(fontFamily: 'Lato', fontSize: 12),
                  text: 'small',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final big = tester.getRect(find.byType(GPURichText).first);
    final small = tester.getRect(find.byType(GPURichText).last);
    // Baselines align: the small text's top sits well below the big one's.
    expect(small.top, greaterThan(big.top + 10));
    // And ascent proportionality holds approximately (same font):
    final bigBaseline = big.top + 32 * 0.987; // Lato ascender 1974/2000
    final smallBaseline = small.top + 12 * 0.987;
    expect((bigBaseline - smallBaseline).abs(), lessThan(1.0));
  });

  testWidgets('IntrinsicWidth uses text intrinsics without crashing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GPURichText(
                  text: TextSpan(style: style, text: 'short'),
                ),
                GPURichText(
                  text: TextSpan(style: style, text: 'a longer line'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final col = tester.getSize(find.byType(Column));
    expect(col.width, greaterThan(20));
    expect(col.width, lessThan(200));
  });

  testWidgets('WidgetSpan children lay out, position, and hit-test', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 260,
            child: GPURichText(
              text: TextSpan(
                style: style,
                children: [
                  const TextSpan(text: 'tap '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: GestureDetector(
                      onTap: () => taps++,
                      child: Container(
                        key: const Key('box'),
                        width: 24,
                        height: 24,
                        color: const Color(0xFF123456),
                      ),
                    ),
                  ),
                  const TextSpan(
                    text:
                        ' inline and wrap with more words following '
                        'after it so the paragraph spans lines',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final boxRect = tester.getRect(find.byKey(const Key('box')));
    final paraRect = tester.getRect(find.byType(GPURichText));
    expect(boxRect.width, 24);
    expect(paraRect.contains(boxRect.center), isTrue);
    expect(boxRect.left, greaterThan(paraRect.left + 5)); // after 'tap '
    await tester.tapAt(boxRect.center);
    expect(taps, 1);
    expect(paraRect.height, greaterThan(30)); // wrapped
  });

  testWidgets('tall middle WidgetSpan grows the line box', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: GPURichText(
            text: TextSpan(
              style: style,
              children: const [
                TextSpan(text: 'x'),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: SizedBox(width: 10, height: 40),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(GPURichText));
    expect(size.height, greaterThanOrEqualTo(40));
  });

  testWidgets('TextSpan recognizers receive taps on their runs', (
    tester,
  ) async {
    var linkTaps = 0;
    final recognizer = TapGestureRecognizer()..onTap = () => linkTaps++;
    addTearDown(recognizer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            child: GPURichText(
              text: TextSpan(
                style: style,
                children: [
                  const TextSpan(text: 'x '),
                  TextSpan(
                    text: 'a long tappable link run of text',
                    style: const TextStyle(color: Color(0xFF1144CC)),
                    recognizer: recognizer,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(GPURichText));
    // The box may be wider than the text (tight constraints); the link
    // dominates the line, so its glyphs span the horizontal center.
    await tester.tapAt(Offset(rect.left + 120, rect.top + 10)); // in link
    await tester.pump();
    expect(linkTaps, 1);
    await tester.tapAt(Offset(rect.left + 4, rect.top + 10)); // in 'x '
    await tester.pump();
    expect(linkTaps, 1);
  });

  testWidgets('identical paragraphs share one layout via the engine cache', (
    tester,
  ) async {
    final engine = GPUText.instance;
    final hitsBefore = engine.debugLayoutCacheHits;
    const span = TextSpan(
      style: style,
      text: 'cached paragraph content that wraps across some lines',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            SizedBox(width: 250, child: GPURichText(text: span)),
            SizedBox(width: 250, child: GPURichText(text: span)),
          ],
        ),
      ),
    );
    expect(engine.debugLayoutCacheHits, greaterThan(hitsBefore));
    final rects = tester
        .widgetList(find.byType(GPURichText))
        .toList(growable: false);
    expect(rects.length, 2);
  });

  testWidgets('paint-only color changes do not miss the layout cache', (
    tester,
  ) async {
    final engine = GPUText.instance;
    engine.debugResetCacheCounters();

    Widget build(Color color) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 300,
          child: GPURichText(
            text: TextSpan(
              style: style.copyWith(color: color),
              text: 'color animation should not reshape',
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(build(const Color(0xFF000000)));
    final missesAfterLayout = engine.debugLayoutCacheMisses;
    final hitsAfterLayout = engine.debugLayoutCacheHits;

    // Animate color across several frames — RenderComparison.paint only.
    for (var i = 1; i <= 8; i++) {
      await tester.pumpWidget(build(Color.fromARGB(255, i * 20, 40, 80)));
    }

    // No new flatten+prepare inserts: misses stay flat; hits may rise if
    // something else looks up the original key, but must not grow misses.
    expect(engine.debugLayoutCacheMisses, missesAfterLayout);
    expect(engine.debugLayoutCacheHits, greaterThan(hitsAfterLayout));
  });

  testWidgets('same text in two colors shares layout but paints each color', (
    tester,
  ) async {
    final engine = GPUText.instance;
    engine.debugResetCacheCounters();

    const text = 'shared shaping, private colour';
    const red = Color(0xFFFF0000);
    const blue = Color(0xFF0000FF);
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            SizedBox(
              width: 250,
              child: GPURichText(
                text: TextSpan(
                  style: style.copyWith(color: red),
                  text: text,
                ),
              ),
            ),
            SizedBox(
              width: 250,
              child: GPURichText(
                text: TextSpan(
                  style: style.copyWith(color: blue),
                  text: text,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // The two paragraphs differ only in colour, so the second reuses the
    // first's shaped layout from the paint-independent cache.
    expect(engine.debugLayoutCacheHits, greaterThan(0));

    // ...yet each paints its own colour. Instance layout: 16 floats/glyph,
    // RGBA at offsets 8..11 (see pipeline.dart vertex layout).
    final ros = tester
        .renderObjectList<RenderGPUParagraph>(find.byType(GPURichText))
        .toList(growable: false);
    (double, double, double) firstColor(RenderGPUParagraph ro) {
      final inst = ro.debugInstances;
      expect(inst, isNotNull, reason: 'instances emitted during paint');
      expect(inst!.length, greaterThanOrEqualTo(12));
      return (inst[8], inst[9], inst[10]);
    }

    expect(firstColor(ros[0]), (1.0, 0.0, 0.0)); // red
    expect(firstColor(ros[1]), (0.0, 0.0, 1.0)); // blue
  });

  testWidgets('empty text still reports one line of height', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: GPURichText(
            text: TextSpan(style: style, text: ''),
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(GPURichText));
    expect(size.width, 0);
    expect(size.height, greaterThan(10));
  });
}
