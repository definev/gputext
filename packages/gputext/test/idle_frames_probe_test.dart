// Diagnostic probe: after the first reflow lands and everything drains,
// NOTHING may keep scheduling frames — an idle GPUTextView must let the
// engine go fully idle. If this fails, the printed schedule-frame stacks
// name the code that keeps the frame pump alive.
// Needs `flutter test --enable-impeller --enable-flutter-gpu`.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/lowlevel.dart' hide TextAlign, TextDirection;

Future<GPUTextViewController> _spawnController(WidgetTester tester) async {
  final controller = (await tester.runAsync(GPUTextViewController.spawn))!;
  final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
  await tester.runAsync(
    () => controller.registerFont('lato', Uint8List.fromList(bytes)),
  );
  return controller;
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  String? reason,
}) async {
  for (var i = 0; i < 600 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: reason ?? 'condition not reached');
}

void main() {
  testWidgets('idle view stops scheduling frames', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    final metrics = <GPUTextMetrics>[];
    final text = List.generate(
      300,
      (i) => 'Row $i of a long document sitting perfectly still.',
    ).join('\n');
    final doc = GPUTextDocument.rich(
      'idle-probe',
      TextSpan(text: text, style: const TextStyle(fontSize: 16)),
      fontIdResolver: (_) => 'lato',
    );

    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: SelectionArea(
            child: SingleChildScrollView(
              controller: scroll,
              child: GPUTextView(
                controller: controller,
                document: doc,
                onMetrics: metrics.add,
              ),
            ),
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => metrics.isNotEmpty, reason: 'first reflow');

    // Scroll once so the slice machinery is exercised, then let it settle.
    scroll.jumpTo(1000);
    await tester.pump();

    // Drain: async tails (color stubs, post-frame callbacks, ballistic
    // activities) may legitimately schedule a bounded number of frames.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }

    // One more frame with stack tracing on: if anything schedules during or
    // after it, the stack fingers the culprit.
    debugPrintScheduleFrameStacks = true;
    await tester.pump(const Duration(milliseconds: 16));
    debugPrintScheduleFrameStacks = false;

    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: 'an idle GPUTextView must not keep the frame pump alive',
    );
  });
}
