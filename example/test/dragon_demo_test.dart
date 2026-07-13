// Smoke test: the dragon demo builds, boots its Lato atlas, lays out text
// through gputext's inner pretext prebuilt, ticks and paints without throwing.
//
// Runs headless: flutter_gpu isn't enabled, so the GPU pipeline can't come up
// and the page shows its "GPU renderer unavailable" fallback — but the layout
// half (which only needs the parsed font + band table) still runs, so the HUD
// reports a non-zero letter count. That proves the inner-pretext layout
// produced the per-character home positions the physics is anchored to.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext_example/dragon_demo.dart';

void main() {
  testWidgets('DragonDemoPage boots, lays out via inner pretext, ticks/paints', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: DragonDemoPage()));

    // Let the async atlas bootstrap (rootBundle.load + buildGlyphAtlas +
    // setAtlas) settle, then advance simulated frames.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);

    // The HUD reports the live letter count; a non-zero count proves the
    // inner-pretext layout produced per-character home positions.
    expect(
      find.textContaining(RegExp(r'· [1-9]\d* letters')),
      findsOneWidget,
      reason: 'inner-pretext layout should produce a non-zero letter count',
    );

    // Open the control panel with 'P' and apply a preset (rebuildDragon path).
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(find.text('DRAGON CONTROLS'), findsOneWidget);
    await tester.tap(find.text('Chaos'), warnIfMissed: false);
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);

    // Tear down so the Ticker / notifier / focus node / GPU scene dispose.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
