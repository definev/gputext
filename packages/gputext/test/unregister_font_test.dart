import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/src/engine/engine.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/native/harfbuzz_bindings.dart';
import 'package:gputext/src/text/harfbuzz_shaper.dart';
import 'package:gputext/src/text/metrics_cache.dart';
import 'package:gputext/src/text/shaper.dart';

void main() {
  late GPUFont lato;
  late GPUFont flex;

  setUpAll(() {
    lato = GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync());
    flex = GPUFont.parse(
      File(
        'assets/Google_Sans_Flex/'
        'GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf',
      ).readAsBytesSync(),
    );
  });

  test('unregisterFont removes family and bumps fontGeneration', () {
    final engine = GPUText.instance;
    final gen0 = engine.fontGeneration;
    engine.registerFont('LeakTestLato', lato);
    expect(engine.resolveFont('LeakTestLato'), isNotNull);
    expect(engine.fontGeneration, greaterThan(gen0));
    final gen1 = engine.fontGeneration;
    engine.unregisterFont('LeakTestLato');
    expect(engine.resolveFont('LeakTestLato'), isNull);
    expect(engine.fontGeneration, greaterThan(gen1));
    // Re-register works.
    engine.registerFont('LeakTestLato', lato);
    expect(engine.resolveFont('LeakTestLato'), isNotNull);
    engine.unregisterFont('LeakTestLato');
  });

  test('unregisterFont with weight removes only that variant', () {
    final engine = GPUText.instance;
    final bold = flex.variant({'wght': 700});
    engine.registerFont('LeakTestFlex', flex, weight: FontWeight.w400);
    engine.registerFont('LeakTestFlex', bold, weight: FontWeight.w700);
    expect(
      engine.resolveFont('LeakTestFlex', weight: FontWeight.w400),
      isNotNull,
    );
    expect(
      engine.resolveFont('LeakTestFlex', weight: FontWeight.w700),
      isNotNull,
    );
    engine.unregisterFont('LeakTestFlex', weight: FontWeight.w700);
    expect(
      engine.resolveFont('LeakTestFlex', weight: FontWeight.w400),
      isNotNull,
    );
    // Nearest-weight may still resolve w700 to remaining w400 — family stays.
    engine.unregisterFont('LeakTestFlex');
    expect(engine.resolveFont('LeakTestFlex'), isNull);
  });

  test('unregisterFont clears segment metrics and HB face for variants', () {
    final engine = GPUText.instance;
    final hb = HarfBuzzBindings.tryLoad();
    if (hb != null) {
      engine.shaper = HarfBuzzShaper(hb);
    }
    engine.registerFont('LeakTestFlex2', flex);
    final bold = flex.variant({'wght': 700});
    segmentMetricsOf(flex, 'abc');
    segmentMetricsOf(bold, 'xyz');
    expect(debugSegmentMetricsLengthFor(flex), greaterThan(0));
    expect(debugSegmentMetricsLengthFor(bold), greaterThan(0));
    if (hb != null) {
      engine.shaper.shape(
        ShapeRequest(font: flex, text: 'Hi', fontSizePx: 16),
      );
      engine.shaper.shape(
        ShapeRequest(font: bold, text: 'Hi', fontSizePx: 16),
      );
    }
    engine.unregisterFont('LeakTestFlex2');
    expect(debugSegmentMetricsLengthFor(flex), 0);
    expect(debugSegmentMetricsLengthFor(bold), 0);
    expect(flex.debugVariantCacheLength, 0);
    // Reshape after unregister still works (recreates HB face).
    if (hb != null) {
      final run = engine.shaper.shape(
        ShapeRequest(font: flex, text: 'Hi', fontSizePx: 16),
      );
      expect(run.glyphs, isNotEmpty);
    }
  });
}
