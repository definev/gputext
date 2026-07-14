// A paragraph too tall for one 8192-device-px surface must render as several
// vertically-stacked tiles AT FULL SCALE, not get scaled down onto a single
// surface (which used to clamp the render scale below devicePixelRatio and
// blur the whole paragraph). Short paragraphs stay a single tile — the common,
// bucketed/reused path.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';

Widget _para(String text, {double fontSize = 20}) => GPURichText(
  text: TextSpan(
    text: text,
    style: TextStyle(
      fontFamily: 'Lato',
      fontSize: fontSize,
      color: const Color(0xFFFFFFFF),
    ),
  ),
);

void main() {
  setUpAll(() {
    GPUText.instance.registerFont(
      'Lato',
      GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync()),
    );
  });

  testWidgets('a short paragraph renders as a single tile at full scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(home: Center(child: _para('Hello tiled world'))),
    );
    await tester.pump();

    final ro = tester.renderObject<RenderGPUParagraph>(
      find.byType(GPURichText),
    );
    expect(ro.debugTileCount, 1);
    expect(ro.debugRenderScale, closeTo(1.0, 1e-6));
  });

  testWidgets('a very tall paragraph tiles at full scale instead of blurring', (
    tester,
  ) async {
    // DPR 1 so an 8192-device-px surface == 8192 logical px; keeps the math
    // legible. The paragraph below is ~12000 logical px tall — over one surface.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final text = List.generate(
      500,
      (i) => 'Line $i of a very tall single paragraph',
    ).join('\n');

    await tester.pumpWidget(
      MaterialApp(home: SingleChildScrollView(child: _para(text))),
    );
    await tester.pump();

    final ro = tester.renderObject<RenderGPUParagraph>(
      find.byType(GPURichText),
    );
    // Over 8192 device px tall → more than one tile.
    expect(
      ro.debugTileCount,
      greaterThan(1),
      reason: 'a paragraph taller than one surface must split into tiles',
    );
    // The blur bug was rendering at scale < devicePixelRatio. Tiling keeps it
    // at full device scale.
    expect(
      ro.debugRenderScale,
      closeTo(1.0, 1e-6),
      reason:
          'tiling must render at full devicePixelRatio, not a clamped scale',
    );
  });
}
