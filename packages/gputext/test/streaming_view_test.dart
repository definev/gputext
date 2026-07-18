// End-to-end streaming document through GPUTextView: a `streaming: true`
// GPUTextDocument keeps ONE id while its content grows — every non-identical
// document object routes through GPUTextWorker.syncStream (paragraph-sliced
// shaping reuse, appendable-prepare v0) and the view applies each reply like
// an ordinary reflow. Needs `flutter test --enable-impeller
// --enable-flutter-gpu`; without the flags the surface probe fails and no
// sync ever lands (same as view_window_test.dart).

import 'dart:io';

import 'package:flutter/material.dart';
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
  testWidgets('a streaming document grows under one fixed id', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = await _spawnController(tester);
    addTearDown(controller.dispose);

    final metrics = <GPUTextMetrics>[];
    Widget build(String content) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 400,
          child: GPUTextView(
            controller: controller,
            document: GPUTextDocument.rich(
              'live',
              TextSpan(text: content, style: const TextStyle(fontSize: 16)),
              fontIdResolver: (_) => 'lato',
              streaming: true,
            ),
            onMetrics: metrics.add,
          ),
        ),
      ),
    );

    // Empty content: the streaming view must idle (the worker rejects empty
    // syncs), not crash.
    await tester.pumpWidget(build(''));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(metrics, isEmpty);

    // First token arrives.
    await tester.pumpWidget(build('Streaming'));
    await _pumpUntil(
      tester,
      () => metrics.isNotEmpty,
      reason: 'first sync never landed',
    );
    final first = metrics.last;
    expect(first.glyphCount, greaterThan(0));
    expect(first.lineCount, 1);

    // The content GROWS under the same id — the exact operation the ordinary
    // prepare-cache contract forbids and streaming exists for.
    await tester.pumpWidget(
      build(
        'Streaming more words onto the same line until it wraps at the '
        'fixed width.\nAnd a second paragraph after a hard break.',
      ),
    );
    await _pumpUntil(
      tester,
      () => metrics.last.glyphCount > first.glyphCount,
      reason: 'grown content never applied',
    );
    expect(metrics.last.lineCount, greaterThan(1));
    expect(metrics.last.size.height, greaterThan(first.size.height));

    // Hardening: finish the stream (shaping cache drops, the prepared doc
    // survives) and free it. Unmount first so no sync races the dispose.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await controller.finishStream('live');
      await controller.disposeDoc('live');
    });
  });
}
