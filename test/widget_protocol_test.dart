import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:windfoil_flutter/windfoil_flutter.dart';

void main() {
  setUpAll(() {
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    Windfoil.instance.registerFont('Lato', WindfoilFont.parse(bytes));
  });

  const style = TextStyle(fontFamily: 'Lato', fontSize: 16);

  testWidgets('fills a tight width and wraps to multiple lines',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 160,
            child: WindfoilRichText(
              text: TextSpan(
                  style: style,
                  text: 'a long sentence that definitely wraps onto '
                      'several lines here'),
            ),
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(WindfoilRichText));
    expect(size.width, 160);
    // Wrapped: taller than any single Lato line at 16px (~19px).
    expect(size.height, greaterThan(30));
  });

  testWidgets('shrink-wraps to text width under loose constraints',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: WindfoilRichText(
            text: TextSpan(style: style, text: 'hi'),
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(WindfoilRichText));
    expect(size.width, greaterThan(2));
    expect(size.width, lessThan(40));
    expect(size.height, greaterThan(10));
    expect(size.height, lessThan(30));
  });

  testWidgets('maxLines caps the height', (tester) async {
    const span = TextSpan(
        style: style,
        text: 'words words words words words words words words words '
            'words words words words words words words words words');
    Future<Size> sizeFor(int? maxLines) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 120,
              child: WindfoilRichText(
                text: span,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      );
      return tester.getSize(find.byType(WindfoilRichText));
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
              WindfoilRichText(
                  text: TextSpan(
                      style: TextStyle(fontFamily: 'Lato', fontSize: 32),
                      text: 'Big')),
              WindfoilRichText(
                  text: TextSpan(
                      style: TextStyle(fontFamily: 'Lato', fontSize: 12),
                      text: 'small')),
            ],
          ),
        ),
      ),
    );
    final big = tester.getRect(find.byType(WindfoilRichText).first);
    final small = tester.getRect(find.byType(WindfoilRichText).last);
    // Baselines align: the small text's top sits well below the big one's.
    expect(small.top, greaterThan(big.top + 10));
    // And ascent proportionality holds approximately (same font):
    final bigBaseline = big.top + 32 * 0.987; // Lato ascender 1974/2000
    final smallBaseline = small.top + 12 * 0.987;
    expect((bigBaseline - smallBaseline).abs(), lessThan(1.0));
  });

  testWidgets('IntrinsicWidth uses text intrinsics without crashing',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WindfoilRichText(
                    text: TextSpan(style: style, text: 'short')),
                WindfoilRichText(
                    text: TextSpan(style: style, text: 'a longer line')),
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

  testWidgets('WidgetSpan children lay out, position, and hit-test',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 260,
            child: WindfoilRichText(
              text: TextSpan(style: style, children: [
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
                    text: ' inline and wrap with more words following '
                        'after it so the paragraph spans lines'),
              ]),
            ),
          ),
        ),
      ),
    );
    final boxRect = tester.getRect(find.byKey(const Key('box')));
    final paraRect = tester.getRect(find.byType(WindfoilRichText));
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
          child: WindfoilRichText(
            text: TextSpan(style: style, children: const [
              TextSpan(text: 'x'),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SizedBox(width: 10, height: 40),
              ),
            ]),
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(WindfoilRichText));
    expect(size.height, greaterThanOrEqualTo(40));
  });

  testWidgets('empty text still reports one line of height', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: WindfoilRichText(text: TextSpan(style: style, text: '')),
        ),
      ),
    );
    final size = tester.getSize(find.byType(WindfoilRichText));
    expect(size.width, 0);
    expect(size.height, greaterThan(10));
  });
}
