// Smoke test: the Reader demo spawns its worker isolate, registers the three
// Lato faces from bundled assets, builds the essay as one GPUTextDocument, and
// mounts it as a SliverGPUText inside the CustomScrollView.
//
// Runs headless: flutter_gpu isn't enabled, so the sliver degrades to a blank
// paint, but the worker spawn + font registration + reflow round-trip (the CPU
// half) all run — which is what we prove. Spawning the isolate is real async
// work, so it runs inside tester.runAsync poll windows (pattern shared with the
// package's sliver tests).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/lowlevel.dart' show SliverGPUText;
import 'package:gputext_example/reader_demo.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

void main() {
  // Leak tracking ignored: this checks the demo boots and mounts its sliver,
  // not that transient framework objects are freed.
  testWidgets('essay mounts as one SliverGPUText after the worker boots', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ReaderDemoPage()));
    // Pre-boot: a spinner shows until the worker + fonts are ready.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Spawning the isolate + registering fonts is real async work; give it
    // real time in runAsync windows and poll until the sliver mounts (its
    // find.byType matches even when the GPU pipeline degrades to blank).
    var tries = 0;
    while (find.byType(SliverGPUText).evaluate().isEmpty && tries++ < 100) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(find.byType(SliverGPUText), findsOneWidget);

    // Let any in-flight reflow replies drain before teardown so no pending
    // isolate work outlives the test.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }, experimentalLeakTesting: LeakTesting.settings.withIgnoredAll());
}
