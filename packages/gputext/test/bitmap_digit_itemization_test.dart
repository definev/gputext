// Regression: with a color-bitmap emoji font (NotoColorEmoji / CBDT) registered,
// plain ASCII digits must NOT be hijacked into the color-bitmap pipeline.
// NotoColorEmoji's CBDT maps 0-9 and #/* as the *bases* of the keycap sequences
// (0️⃣..9️⃣), so the emoji font "covers" a bare '0' — but a bare digit is not an
// emoji. The flattener must classify emoji by code point (emoji_ranges.dart),
// not by whether the emoji font happens to have a glyph.
//
// This bug surfaced as "0123456789 renders wrong" in the Sys-font demo after
// visiting the bitmap-emoji demo (which left Noto registered): every digit
// rendered as a Noto color bitmap instead of the system font's digit.

import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';
import 'package:gputext/src/paragraph.dart' as wf;

File _resolve(String path) {
  for (final prefix in const [
    '',
    'packages/gputext/',
    '/Users/vsf/source/github.com/definev/gputext/example/',
  ]) {
    final f = File('$prefix$path');
    if (f.existsSync()) return f;
  }
  throw StateError('not found from ${Directory.current.path}: $path');
}

void main() {
  final engine = GPUText.instance;

  setUpAll(() {
    engine.registerFont(
      'Lato',
      GPUFont.parse(_resolve('assets/Lato-Regular.ttf').readAsBytesSync()),
    );
  });

  group('bitmap emoji font does not hijack plain text', () {
    late GPUFont noto;

    setUpAll(() {
      // Full NotoColorEmoji (CBDT) — its subset lacks the digit strikes.
      noto = GPUFont.parse(
        _resolve('assets/NotoColorEmoji.ttf').readAsBytesSync(),
      );
      // Sanity: Noto really does "cover" a bare digit with a bitmap glyph, so
      // the coverage-based check this test guards against would have fired.
      final gid = noto.glyphIdForRune(0x30);
      expect(gid, isNotNull);
      expect(noto.bitmapGlyphForId(gid!, targetPpem: 64), isNotNull,
          reason: 'test font must map "0" to a bitmap for this to be a real '
              'regression guard');
    });

    setUp(() => engine.registerEmojiFont(noto));
    tearDown(() => engine.registerEmojiFont(null));

    List<wf.InlineItem> flatten(String text) => flattenSpan(
          TextSpan(
            style: const TextStyle(fontFamily: 'Lato', fontSize: 20),
            text: text,
          ),
          TextScaler.noScaling,
          engine,
        )!;

    test('digits stay text runs, only the emoji becomes a bitmap EmojiItem', () {
      final items = flatten('Room 101 — call 0123456789 \u{1F680} now');

      final emoji = items.whereType<wf.EmojiItem>().toList();
      expect(emoji, hasLength(1), reason: 'only the rocket is an emoji');
      expect(emoji.single.isBitmap, isTrue);
      expect(emoji.single.sourceText, '\u{1F680}');

      // Every digit must live inside a normal (non-emoji) text run.
      final runText = items
          .whereType<wf.TextRun>()
          .map((r) => r.originalText)
          .join();
      for (final d in '0123456789'.runes) {
        expect(runText.contains(String.fromCharCode(d)), isTrue,
            reason: 'digit ${String.fromCharCode(d)} must be a text run');
      }
    });

    test('a keycap base with no keycap mark is plain text, not emoji', () {
      // '#' and '*' are also CBDT-covered keycap bases; alone they are text.
      final items = flatten('C# and 2*3');
      expect(items.whereType<wf.EmojiItem>(), isEmpty);
    });

    test('an emoji base still routes to the bitmap pipeline', () {
      final items = flatten('\u{1F680}');
      final emoji = items.whereType<wf.EmojiItem>().single;
      expect(emoji.isBitmap, isTrue);
      expect(emoji.bitmapGlyphId, isNotNull);
    });
  });
}
