// COLR v1 flat-color subset (B1): PaintColrLayers → PaintGlyph → PaintSolid
// glyphs render through the existing coverage/color pipeline. Gradient /
// composite / transform glyphs are "not flat" and resolve to null so they
// delegate to the platform. The key regression this locks: a COLR v1 font no
// longer fails to parse (it used to throw 'COLR v1 unsupported').

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';

const _testGlyphs =
    'third_party/harfbuzz/test/api/fonts/test_glyphs-glyf_colr_1.ttf';
const _notoV1 =
    'third_party/harfbuzz/test/fuzzing/fonts/noto_handwriting-glyf_colr_1.ttf';

void main() {
  test('a COLR v1 font parses (no longer throws) and reports color glyphs', () {
    final font = GPUFont.parse(File(_testGlyphs).readAsBytesSync());
    expect(font.hasColorGlyphs, isTrue);
  });

  test(
    'flat PaintColrLayers→PaintGlyph→PaintSolid resolves to color layers',
    () {
      final font = GPUFont.parse(File(_testGlyphs).readAsBytesSync());
      // gid 168 is a flat 8-layer glyph; the first layer is solid red.
      final layers = font.colrForGlyphId(168);
      expect(layers, isNotNull);
      expect(layers!.length, 8);
      expect(layers.first.color, isNotNull);
      expect(layers.first.color, [1.0, 0.0, 0.0, 1.0]);
      // Every layer references a real (banded-able) outline.
      for (final l in layers) {
        expect(font.glyphOutlineById(l.glyphId)!.quads, isNotEmpty);
      }
    },
  );

  test('a PaintSolid at palette index 0xFFFF means the current text color', () {
    final font = GPUFont.parse(File(_testGlyphs).readAsBytesSync());
    // gid 154 is a single flat layer painted with the current color.
    final layers = font.colrForGlyphId(154);
    expect(layers, isNotNull);
    expect(layers!.length, 1);
    expect(layers.first.color, isNull); // 0xFFFF → use text color
  });

  test(
    'a gradient-only v1 font parses but its glyphs are non-flat (delegate)',
    () {
      // Noto handwriting COLR v1 uses gradients throughout: it must PARSE (proving
      // the v1 gate no longer throws), report color glyphs, yet resolve every
      // glyph to null (not flat) so painting falls back to the platform.
      final font = GPUFont.parse(File(_notoV1).readAsBytesSync());
      expect(font.hasColorGlyphs, isTrue);
      var flat = 0;
      for (var gid = 0; gid < 400; gid++) {
        if (font.colrForGlyphId(gid) != null) flat++;
      }
      expect(
        flat,
        0,
        reason: 'gradient glyphs must resolve to null, not garbage',
      );
    },
  );
}
