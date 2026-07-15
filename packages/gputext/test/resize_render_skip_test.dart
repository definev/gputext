// A width resize that does not move any line break must not re-render the
// offscreen glyph surface. Left / start-LTR glyph positions are box-width-
// independent, so an unchanged line partition re-emits byte-identical instances
// and paint can re-blit the cached image instead of re-uploading and
// re-rendering. RenderGPUParagraph.debugSurfaceRenderSkips counts exactly those
// skipped re-renders — the resize-width fast path.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final engine = GPUText.instance;

  setUpAll(() {
    engine.registerFont(
      'Lato',
      GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync()),
    );
  });

  const style = TextStyle(
    inherit: false,
    fontFamily: 'Lato',
    fontSize: 14,
    color: Color(0xFF000000),
  );

  Future<void> pumpAt(WidgetTester tester, double width, String text) =>
      tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: GPURichText(
                text: TextSpan(text: text, style: style),
              ),
            ),
          ),
        ),
      );

  RenderGPUParagraph paragraph(WidgetTester tester) =>
      tester.renderObject<RenderGPUParagraph>(find.byType(GPURichText));

  testWidgets('a resize that keeps line breaks skips the offscreen render', (
    tester,
  ) async {
    // Short enough to stay a single line at every width below.
    const text = 'The quick brown fox';
    RenderGPUParagraph.debugSurfaceRenderSkips = 0;

    await pumpAt(tester, 300, text);
    final first = Float32List.fromList(paragraph(tester).debugInstances!);
    expect(first, isNotEmpty);
    // The first paint has no previous emit to match, so nothing is skipped yet.
    final baseline = RenderGPUParagraph.debugSurfaceRenderSkips;

    // Sweep the width down. The paragraph re-lays-out every frame (its reported
    // width tracks the tight constraint), but the single line never moves, so
    // every re-emit comes out byte-identical.
    const widths = [296.0, 292.0, 288.0, 284.0, 280.0];
    for (final w in widths) {
      await pumpAt(tester, w, text);
      expect(
        Float32List.fromList(paragraph(tester).debugInstances!),
        first,
        reason:
            'glyph instances must be identical across a stable-break resize',
      );
    }
    expect(
      RenderGPUParagraph.debugSurfaceRenderSkips - baseline,
      greaterThanOrEqualTo(widths.length),
      reason: 'each stable-break relayout should skip its re-render',
    );
  });

  testWidgets('a resize that moves line breaks does not skip', (tester) async {
    // Long enough to wrap to a different line count across these widths.
    const text =
        'The quick brown fox jumps over the lazy dog near the river bank at '
        'dawn while the town still sleeps';
    RenderGPUParagraph.debugSurfaceRenderSkips = 0;

    await pumpAt(tester, 400, text);
    final wide = Float32List.fromList(paragraph(tester).debugInstances!);
    final baseline = RenderGPUParagraph.debugSurfaceRenderSkips;

    // A large shrink forces new line breaks, so the emit changes and the
    // offscreen render cannot be reused.
    await pumpAt(tester, 120, text);
    final narrow = Float32List.fromList(paragraph(tester).debugInstances!);
    expect(narrow, isNot(equals(wide)));
    expect(
      RenderGPUParagraph.debugSurfaceRenderSkips,
      baseline,
      reason: 'a break-moving resize must re-emit, not skip',
    );
  });

  testWidgets('a color change re-emits new colors and does not skip', (
    tester,
  ) async {
    // A paint-only span change mutates run colors under the same layout. The
    // fast path must not skip it, or the blit keeps the old color.
    const text = 'colored text';
    Widget colored(Color c) => MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 300,
          child: GPURichText(
            text: TextSpan(
              text: text,
              style: TextStyle(
                inherit: false,
                fontFamily: 'Lato',
                fontSize: 14,
                color: c,
              ),
            ),
          ),
        ),
      ),
    );

    RenderGPUParagraph.debugSurfaceRenderSkips = 0;
    await tester.pumpWidget(colored(const Color(0xFF000000)));
    final black = Float32List.fromList(paragraph(tester).debugInstances!);
    final baseline = RenderGPUParagraph.debugSurfaceRenderSkips;

    await tester.pumpWidget(colored(const Color(0xFFFF0000)));
    final red = Float32List.fromList(paragraph(tester).debugInstances!);
    // Instance colors (floats 8..11 of each 16-float glyph) must have changed.
    expect(red, isNot(equals(black)));
    expect(red[8], 1.0); // red channel of the first glyph
    expect(black[8], 0.0);
    expect(
      RenderGPUParagraph.debugSurfaceRenderSkips,
      baseline,
      reason: 'a recolor must re-emit, not skip',
    );
  });

  testWidgets('a color change coinciding with a resize is not skipped', (
    tester,
  ) async {
    // The tricky case: the resize routes through performLayout, which consumes
    // _paraDirty via _recolorPrepared before paint runs — so a plain
    // "was paraDirty this paint" check would miss it. The persistent
    // paint-dirtied flag must still force a re-emit with the new color.
    const text = 'colored text';
    Widget at(double width, Color c) => MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: GPURichText(
            text: TextSpan(
              text: text,
              style: TextStyle(
                inherit: false,
                fontFamily: 'Lato',
                fontSize: 14,
                color: c,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(at(300, const Color(0xFF000000)));
    final black = Float32List.fromList(paragraph(tester).debugInstances!);
    // Width AND color change together.
    await tester.pumpWidget(at(280, const Color(0xFFFF0000)));
    final red = Float32List.fromList(paragraph(tester).debugInstances!);
    expect(red[8], 1.0, reason: 'must show the new red, not the stale black');
    expect(black[8], 0.0);
  });

  testWidgets('centered text: a box-width change re-emits (no false skip)', (
    tester,
  ) async {
    // Centered glyph positions depend on the box width, so even a stable-break
    // resize produces different instances — the skip must NOT fire, or the
    // blit would sit at the old horizontal offset.
    const text = 'centered line';
    RenderGPUParagraph.debugSurfaceRenderSkips = 0;

    Future<void> pumpCentered(double width) => tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: GPURichText(
              text: const TextSpan(text: text, style: style),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );

    await pumpCentered(300);
    final baseline = RenderGPUParagraph.debugSurfaceRenderSkips;
    await pumpCentered(280);
    expect(
      RenderGPUParagraph.debugSurfaceRenderSkips,
      baseline,
      reason: 'centering shifts glyph x with the box width — instances differ',
    );
  });
}
