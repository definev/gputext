// The reusable isolate widget (GPUTextView) can't render headless (no
// flutter_gpu), so these cover the parts that CAN run off-GPU: the
// GPUTextDocument.rich flattener (pure) and the controller lifecycle over a
// real spawned worker isolate. The render path is exercised by running the
// example on a device.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/lowlevel.dart';

void main() {
  test('GPUTextDocument.rich flattens a span tree into runs', () {
    final doc = GPUTextDocument.rich(
      'greeting',
      const TextSpan(
        style: TextStyle(fontSize: 18),
        children: [
          TextSpan(text: 'Hello '),
          TextSpan(
            text: 'world',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
      fontIdResolver: (style) =>
          style.fontWeight == FontWeight.bold ? 'bold' : 'regular',
      defaultFontSizePx: 18,
      lineHeight: 1.5,
      fallbackFontIds: const ['cjk'],
      emojiFontId: 'emoji',
    );

    // Config passes through onto the document.
    expect(doc.id, 'greeting');
    expect(doc.lineHeight, 1.5);
    expect(doc.fallbackFontIds, ['cjk']);
    expect(doc.emojiFontId, 'emoji');

    // Two styled leaves -> two text runs, routed to the resolved font ids.
    final runs = doc.runs.whereType<GPUTextRunSpec>().toList();
    expect(runs.length, 2);
    expect(runs[0].text, 'Hello ');
    expect(runs[0].fontId, 'regular');
    expect(runs[1].text, 'world');
    expect(runs[1].fontId, 'bold');
  });

  test('GPUWidgetSpan reserves a box and bundles its widget by index', () {
    const chip = SizedBox(width: 40, height: 20);
    final doc = GPUTextDocument.rich(
      'placeholders',
      const TextSpan(
        children: [
          TextSpan(text: 'before '),
          GPUWidgetSpan(size: Size(40, 20), child: chip),
          TextSpan(text: ' after'),
        ],
      ),
      fontIdResolver: (_) => 'f',
    );

    // The worker gets a size-only placeholder spec...
    final placeholders = doc.runs.whereType<GPUPlaceholderSpec>().toList();
    expect(placeholders.length, 1);
    expect(placeholders.single.index, 0);
    expect(placeholders.single.width, 40);
    expect(placeholders.single.height, 20);

    // ...and the real widget is collected by that index for the view to draw —
    // no separate sizer or builder.
    expect(doc.placeholderWidgets[0], same(chip));
  });

  test(
    'sizeless GPUWidgetSpan is flagged auto-sized with a provisional box',
    () {
      const chip = SizedBox(width: 40, height: 20);
      final doc = GPUTextDocument.rich(
        'auto',
        const TextSpan(
          children: [
            TextSpan(text: 'x '),
            GPUWidgetSpan(child: chip), // no size -> measured by the view
            TextSpan(text: ' y'),
          ],
        ),
        fontIdResolver: (_) => 'f',
      );

      // Provisional zero box until the view measures it; index still assigned.
      final ph = doc.runs.whereType<GPUPlaceholderSpec>().single;
      expect(ph.index, 0);
      expect(ph.width, 0);
      expect(ph.height, 0);
      // Flagged for measurement, and the child is available to measure + draw.
      expect(doc.autoSizedPlaceholders, {0});
      expect(doc.placeholderWidgets[0], same(chip));
    },
  );

  test('GPUTextViewController spawns, registers a font, and guards after dispose', () async {
    final controller = await GPUTextViewController.spawn();
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();

    // Registering on the live controller succeeds (bytes parse on the worker).
    await controller.registerFont('lato', bytes);

    controller.dispose();
    controller.dispose(); // idempotent

    // Using a disposed controller is a clear error, not a silent hang.
    expect(
      () => controller.registerFont('lato', Uint8List(0)),
      throwsStateError,
    );
  });
}
