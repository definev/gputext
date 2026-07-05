import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:windfoil_flutter/src/engine/shared_atlas.dart';
import 'package:windfoil_flutter/src/paragraph.dart' as wf;
import 'package:windfoil_flutter/src/widgets/emoji.dart';
import 'package:windfoil_flutter/src/widgets/span_flattener.dart';
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
      expect(identical(expandEmojiSpans(span, Windfoil.instance), span), isTrue);
    });

    test('splits emoji into baseline WidgetSpans with inherited size', () {
      const span = TextSpan(
        style: TextStyle(fontSize: 24),
        text: 'a🌚b',
      );
      final out = expandEmojiSpans(span, Windfoil.instance) as TextSpan;
      expect(out.text, isNull);
      final children = out.children!;
      expect(children.length, 3);
      expect((children[0] as TextSpan).text, 'a');
      final ws = children[1] as WidgetSpan;
      expect(ws.alignment, PlaceholderAlignment.baseline);
      final inner = ws.child as Text;
      expect((inner.textSpan! as TextSpan).text, '🌚');
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

  group('native COLR emoji', () {
    late WindfoilFont twemoji;

    setUpAll(() {
      twemoji = WindfoilFont.parse(
          File('assets/TwemojiMozilla.ttf').readAsBytesSync());
    });

    setUp(() => Windfoil.instance.registerEmojiFont(twemoji));
    tearDown(() => Windfoil.instance.registerEmojiFont(null));

    test('COLR layers parse with palette colors and outlines', () {
      expect(twemoji.hasColorGlyphs, isTrue);
      final layers = twemoji.colrForCodePoint('\u{1F31A}'.runes.first)!;
      expect(layers.length, greaterThanOrEqualTo(2));
      expect(layers.first.color, isNotNull);
      expect(
          twemoji.glyphOutlineById(layers.first.glyphId)!.quads, isNotEmpty);
    });

    test('single-code-point emoji stay in text (no delegation)', () {
      const span = TextSpan(
        style: TextStyle(fontFamily: 'Lato', fontSize: 16),
        text: 'a \u{1F31A} b \u2764',
      );
      expect(
          identical(expandEmojiSpans(span, Windfoil.instance), span), isTrue);
    });

    test('sequences still delegate (until GSUB lands)', () {
      const span = TextSpan(
        style: TextStyle(fontFamily: 'Lato', fontSize: 16),
        text: 'family \u{1F468}\u200D\u{1F469}\u200D\u{1F467} '
            'flag \u{1F1FB}\u{1F1F3} tone \u{1F44D}\u{1F3FD}',
      );
      final out = expandEmojiSpans(span, Windfoil.instance) as TextSpan;
      final widgets = out.children!.whereType<WidgetSpan>().length;
      expect(widgets, 3);
    });

    test('flattener emits EmojiItem with layers between text runs', () {
      final items = flattenSpan(
        const TextSpan(
          style: TextStyle(fontFamily: 'Lato', fontSize: 20),
          text: 'a\u{1F31A}b',
        ),
        TextScaler.noScaling,
        Windfoil.instance,
      )!;
      expect(items.length, 3);
      final emoji = items[1] as wf.EmojiItem;
      expect(emoji.layers.length, greaterThanOrEqualTo(2));
      expect(emoji.fontSizePx, 20);
      expect(emoji.width, greaterThan(10)); // ~1em advance
    });

    test('emission produces one colored instance per layer', () {
      final items = flattenSpan(
        const TextSpan(
          style: TextStyle(fontFamily: 'Lato', fontSize: 20),
          text: '\u{1F31A}',
        ),
        TextScaler.noScaling,
        Windfoil.instance,
      )!;
      final emoji = items.single as wf.EmojiItem;
      final atlas = SharedGlyphAtlas();
      for (final layer in emoji.layers) {
        atlas.ensureGlyphId(emoji.font, layer.glyphId);
      }
      final para =
          wf.breakLines(items, double.infinity, const wf.ParagraphStyle());
      final emitted = wf.emitInstances(para, 100, wf.TextAlign.left, atlas);
      expect(emitted.glyphCount, emoji.layers.length);
      // First instance carries the first layer's palette color.
      final c0 = emoji.layers.first.color!;
      expect(emitted.instances[8], closeTo(c0[0], 1e-6));
      expect(emitted.instances[9], closeTo(c0[1], 1e-6));
      expect(emitted.instances[10], closeTo(c0[2], 1e-6));
      expect(emitted.inkBounds, isNotNull);
    });

    testWidgets('widget renders native emoji with no inline Text child',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: WindfoilRichText(
              text: TextSpan(
                style: TextStyle(fontFamily: 'Lato', fontSize: 16),
                text: 'moon \u{1F31A} native',
              ),
            ),
          ),
        ),
      );
      expect(find.text('\u{1F31A}'), findsNothing); // no delegated child
      final size = tester.getSize(find.byType(WindfoilRichText));
      expect(size.width, greaterThan(60)); // emoji advance included
    });
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
