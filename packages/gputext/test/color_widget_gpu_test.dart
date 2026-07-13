// Widget-level GPU proof: a GPURichText whose content is ONLY color-bitmap
// emoji (no coverage glyphs) must still render. This guards the bug where the
// offscreen render bailed on `glyphCount > 0` / a null coverage atlas, so an
// all-emoji paragraph drew nothing.
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

  testWidgets('all-emoji GPURichText renders via the color pipeline',
      (tester) async {
    final engine = GPUText.instance;
    await engine.ensureInitialized();
    if (!engine.gpuReady) {
      markTestSkipped('Flutter GPU unavailable — run with '
          '--enable-impeller --enable-flutter-gpu');
      return;
    }

    engine.registerFont(
      'Lato',
      GPUFont.parse(_resolve('assets/Lato-Regular.ttf').readAsBytesSync()),
    );
    engine.registerEmojiFont(
      GPUFont.parse(_resolve('assets/NotoColorEmoji.ttf').readAsBytesSync()),
    );

    RenderGPUParagraph.debugSurfaceRenders = 0;

    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: GPURichText(
                  text: TextSpan(
                    text: '😀 🎉 🚀 🌈 🍕',
                    style: TextStyle(fontFamily: 'Lato', fontSize: 32),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      // Let the async PNG decode land and the notify→repaint cycle run.
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        await tester.pump();
      }
    });

    // The emoji were decoded + packed into the color atlas (only the widget's
    // ensure walk drives this), and a surface was actually rendered — which for
    // an all-emoji paragraph can only be the color pipeline draw.
    expect(engine.colorAtlas.isEmpty, isFalse,
        reason: 'no emoji decoded — ensure walk never ran');
    expect(engine.colorAtlas.generation, greaterThan(0));
    expect(RenderGPUParagraph.debugSurfaceRenders, greaterThan(0),
        reason: 'all-emoji paragraph rendered no surface');

    engine.registerEmojiFont(null);
  });
}
