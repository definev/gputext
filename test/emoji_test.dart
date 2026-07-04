import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:windfoil_flutter/src/widgets/emoji.dart';
import 'package:windfoil_flutter/windfoil_flutter.dart';

void main() {
  setUpAll(() {
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    Windfoil.instance.registerFont('Lato', WindfoilFont.parse(bytes));
  });

  group('splitEmojiSegments', () {
    List<(String, bool)> seg(String s) =>
        [for (final e in splitEmojiSegments(s)) (e.text, e.isEmoji)];

    test('plain text stays one segment', () {
      expect(seg('hello world'), [('hello world', false)]);
    });

    test('single emoji between text', () {
      expect(seg('a🌚b'), [('a', false), ('🌚', true), ('b', false)]);
    });

    test('skin tone modifier stays in the cluster', () {
      expect(seg('👍🏽x'), [('👍🏽', true), ('x', false)]);
    });

    test('ZWJ family is one cluster', () {
      expect(seg('👨‍👩‍👧‍👦!'), [('👨‍👩‍👧‍👦', true), ('!', false)]);
    });

    test('flag is a regional-indicator pair', () {
      expect(seg('🇻🇳🇻🇳'), [('🇻🇳', true), ('🇻🇳', true)]);
    });

    test('keycap sequence', () {
      expect(seg('1️⃣2'), [('1️⃣', true), ('2', false)]);
    });

    test('VS16 forces emoji presentation for text-default symbols', () {
      expect(seg('™️'), [('™️', true)]);
      expect(seg('™'), [('™', false)]);
    });

    test('VS15 forces text presentation for emoji-default symbols', () {
      expect(seg('☀︎x'), [('☀︎x', false)]);
    });

    test('adjacent emoji stay separate clusters (wrap points)', () {
      expect(seg('🌚🌝'), [('🌚', true), ('🌝', true)]);
    });
  });

  group('expandEmojiSpans', () {
    test('returns the identical span when no emoji present', () {
      const span = TextSpan(text: 'plain', style: TextStyle(fontSize: 20));
      expect(identical(expandEmojiSpans(span), span), isTrue);
    });

    test('splits emoji into baseline WidgetSpans with inherited size', () {
      const span = TextSpan(
        style: TextStyle(fontSize: 24),
        text: 'a🌚b',
      );
      final out = expandEmojiSpans(span) as TextSpan;
      expect(out.text, isNull);
      final children = out.children!;
      expect(children.length, 3);
      expect((children[0] as TextSpan).text, 'a');
      final ws = children[1] as WidgetSpan;
      expect(ws.alignment, PlaceholderAlignment.baseline);
      final inner = ws.child as Text;
      expect(inner.data, '🌚');
      expect(inner.style!.fontSize, 24);
      expect((children[2] as TextSpan).text, 'b');
    });
  });

  testWidgets('WindfoilRichText renders emoji as inline engine Text',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            child: WindfoilRichText(
              text: const TextSpan(
                style: TextStyle(fontFamily: 'Lato', fontSize: 16),
                text: 'moon 🌚 and family 👨‍👩‍👧 wrap along with text',
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('🌚'), findsOneWidget);
    expect(find.text('👨‍👩‍👧'), findsOneWidget);
    final emojiRect = tester.getRect(find.text('🌚'));
    final paraRect = tester.getRect(find.byType(WindfoilRichText));
    expect(paraRect.contains(emojiRect.center), isTrue);
    // Emoji box is roughly font-sized, positioned after 'moon '.
    expect(emojiRect.left, greaterThan(paraRect.left + 10));
    expect(emojiRect.height, greaterThan(10));
  });

  testWidgets('semantics label keeps the original emoji characters',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WindfoilRichText(
          text: const TextSpan(
            style: TextStyle(fontFamily: 'Lato', fontSize: 16),
            text: 'hi 🌚',
          ),
        ),
      ),
    );
    final semantics = tester.getSemantics(find.byType(WindfoilRichText));
    expect(semantics.label, contains('🌚'));
  });
}
