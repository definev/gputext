// Smoke test: the cursed-text demo lays out every pathological sample through
// GPURichText without throwing. Fonts are registered up front (as emoji_test
// does) so the demo's async loader is a no-op and the sample tree builds on the
// first frames — the flutter_test binding fails the test on any exception the
// layout throws.
//
// Runs headless: flutter_gpu isn't enabled, so the GPU pipeline degrades to
// blank, but the CPU layout half (parse font + shape + break lines) still runs
// for each cursed string — which is exactly what we want to prove survives.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';
import 'package:gputext_example/cursed_demo.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

void main() {
  setUpAll(() {
    final engine = GPUText.instance;
    engine.registerFont(
      'Lato',
      GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync()),
    );
    engine.registerEmojiFont(
      GPUFont.parse(File('assets/TwemojiMozilla.ttf').readAsBytesSync()),
    );
    final wide = File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
    if (wide.existsSync()) {
      engine.registerFont(
        'Arial Unicode',
        GPUFont.parse(wide.readAsBytesSync()),
      );
      engine.setFallbackFamilies(const ['Arial Unicode']);
    }
  });

  // Leak tracking ignored: this checks that cursed text lays out without
  // throwing, not that the demo's transient framework objects are leak-free.
  testWidgets('CursedDemoPage lays out all cursed samples without throwing', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: CursedDemoPage()));
    // The demo opens its font gate via an async setState; a few frames let it
    // build the sample tree (fonts are already registered, so no re-expansion).
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(find.text('Cursed text — Unicode stress test'), findsOneWidget);
    // Each cursed sample is rendered by GPUText plus a Flutter reference.
    expect(find.byType(GPURichText), findsWidgets);
    // A representative label from the emoji-composition group is present.
    expect(find.text('ZWJ family'), findsOneWidget);
  }, experimentalLeakTesting: LeakTesting.settings.withIgnoredAll());
}
