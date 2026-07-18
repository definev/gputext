// Smoke test: the chat demo parses its markdown scripts and lays every block
// out through GPURichText/GPULabel without throwing, and the word-by-word
// streaming pipeline runs (and skips) cleanly. Fonts are registered up front
// (as cursed_demo_test does) so the demo's async loader is a no-op and the
// font gate opens on the first frames.
//
// Runs headless: flutter_gpu isn't enabled, so the GPU pipeline degrades to
// blank, but the CPU half (parse markdown + resolve spans + shape + break
// lines) still runs for every bubble — which is what we want to prove.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';
import 'package:gputext_example/chat_markdown_demo.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

void main() {
  setUpAll(() {
    final engine = GPUText.instance;
    engine.registerFont(
      'Lato',
      GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync()),
    );
    engine.registerFont(
      'Lato',
      GPUFont.parse(File('assets/Lato-Bold.ttf').readAsBytesSync()),
      weight: FontWeight.w700,
    );
    engine.registerFont(
      'Lato',
      GPUFont.parse(File('assets/Lato-Italic.ttf').readAsBytesSync()),
      style: FontStyle.italic,
    );
    engine.registerFont(
      'JetBrainsMono',
      GPUFont.parse(File('assets/JetBrainsMono-Regular.ttf').readAsBytesSync()),
    );
    engine.registerFont(
      'JetBrainsMono',
      GPUFont.parse(File('assets/JetBrainsMono-Bold.ttf').readAsBytesSync()),
      weight: FontWeight.w700,
    );
    engine.registerFont(
      'NotoSansSC',
      GPUFont.parse(File('assets/NotoSansSC-subset.ttf').readAsBytesSync()),
    );
    engine.registerEmojiFont(
      GPUFont.parse(File('assets/TwemojiMozilla.ttf').readAsBytesSync()),
    );
  });

  // Leak tracking ignored: these check that markdown chat content lays out and
  // streams without throwing, not that transient framework objects are freed.
  testWidgets('welcome message renders markdown through GPURichText', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ChatMarkdownDemoPage()));
    // The demo opens its font gate via an async setState; a few frames let it
    // build the transcript (fonts are already registered, so no re-expansion).
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(find.text('AI chat — markdown on gputext'), findsOneWidget);
    // The welcome bubble is markdown: heading, paragraph, and list blocks all
    // render as GPURichText/GPULabel.
    expect(find.byType(GPURichText), findsWidgets);
    expect(find.byType(GPULabel), findsWidgets);
  }, experimentalLeakTesting: LeakTesting.settings.withIgnoredAll());

  testWidgets('sending streams a scripted markdown response to completion', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ChatMarkdownDemoPage()));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    await tester.enterText(find.byType(TextField), 'stream something');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    // Streaming: the send button flips to a stop button, a caret blinks, and
    // the first script's words arrive on a 40ms timer. Let a good chunk
    // stream in, re-parsing partial markdown every tick.
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    // The user bubble is a GPULabel (find.text only matches Flutter Text).
    expect(
      find.byWidgetPredicate(
        (w) => w is GPULabel && w.data == 'stream something',
      ),
      findsOneWidget,
    );

    // Skip to the end: the remaining chunks flush at once and the timer is
    // cancelled (flutter_test fails the test on a dangling periodic timer).
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
  }, experimentalLeakTesting: LeakTesting.settings.withIgnoredAll());

  testWidgets('stress mode lays out one full cycle of generated turns', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ChatMarkdownDemoPage()));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Start the stress run, then fast-forward each turn with the stop button
    // so all seven generators (nested lists, code file, table, quotes,
    // polyglot, essay, kitchen sink) pass through parse + span mapping +
    // layout without streaming every word. Turn 8's prompt appearing means
    // turns 1–7 all completed.
    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pump();
    final turn8 = find.byWidgetPredicate(
      (w) => w is GPULabel && w.data.startsWith('Turn 8:'),
    );
    var guard = 0;
    while (turn8.evaluate().isEmpty && guard++ < 300) {
      await tester.pump(const Duration(milliseconds: 60));
      final stop = find.byIcon(Icons.stop_circle_outlined);
      if (stop.evaluate().isNotEmpty) {
        await tester.tap(stop);
        await tester.pump();
      }
    }
    expect(turn8, findsOneWidget);
    // The GFM table generator ran within the cycle and rendered real cells.
    expect(find.byType(Table), findsWidgets);

    // Toggle stress off (cancels the between-turns timer) and flush whatever
    // turn 8 has streamed so no periodic timer outlives the test.
    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pump();
    final stop = find.byIcon(Icons.stop_circle_outlined);
    if (stop.evaluate().isNotEmpty) {
      await tester.tap(stop);
      await tester.pump();
    }
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);

    // Reset restores the single welcome bubble.
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(turn8, findsNothing);
  }, experimentalLeakTesting: LeakTesting.settings.withIgnoredAll());
}
