// Regression: a paragraph that mixes gputext coverage text, a GPU bitmap emoji,
// AND delegated (platform-Text) emoji must render without crashing. This is the
// widget-demo emoji sample after the bitmap-emoji demo left Noto + the flag on;
// the coverage draw + color draw on one pass previously segfaulted SwiftShader
// (stale vertex bindings — fixed by clearBindings() in renderColorInstances).
//
// Requires GPU: flutter test --enable-impeller --enable-flutter-gpu

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mixed text + bitmap emoji + delegated emoji renders (no crash)',
      (tester) async {
    final engine = GPUText.instance;
    await engine.ensureInitialized();
    if (!engine.gpuReady) {
      markTestSkipped('GPU unavailable');
      return;
    }
    engine.registerFont(
      'Lato',
      GPUFont.parse(_resolve('assets/Lato-Regular.ttf').readAsBytesSync()),
    );
    engine.registerEmojiFont(
      GPUFont.parse(_resolve('assets/NotoColorEmoji.ttf').readAsBytesSync()),
    );

    // Text + single bitmap emoji (🌚) + multi-CP sequences that delegate to
    // platform Text (tone, flag, ZWJ family, keycap).
    const sample = TextSpan(
      style:
          TextStyle(fontFamily: 'Lato', fontSize: 16, color: Color(0xFF12151F)),
      children: [
        TextSpan(text: 'Emoji ride along: 🌚 moon, thumbs '),
        TextSpan(text: '👍🏽', style: TextStyle(fontSize: 26)),
        TextSpan(
          text: ' with tone, flag 🇻🇳, family 👨‍👩‍👧‍👦, keycap 1️⃣ — while '
              'the surrounding gputext text stays vector-crisp.',
        ),
      ],
    );

    RenderGPUParagraph.debugSurfaceRenders = 0;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 500, child: GPURichText(text: sample)),
            ),
          ),
        ),
      );
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        await tester.pump();
      }
    });

    expect(tester.takeException(), isNull);
    expect(RenderGPUParagraph.debugSurfaceRenders, greaterThan(0));
    expect(engine.colorAtlas.isEmpty, isFalse);

    engine.registerEmojiFont(null);
  });
}
