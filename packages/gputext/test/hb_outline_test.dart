// Outline extraction runs through HarfBuzz's hb_font_draw_glyph — one path for
// glyf, CFF, CFF2, CID, and variable outlines. There is NO hand-rolled CFF
// interpreter anymore: CFF renders only through HarfBuzz. Guarantees locked:
//   1. glyf equivalence — HB draw reproduces the pure-Dart glyf parser exactly
//      (same quad count, same bbox), so the TrueType fallback and HB agree.
//   2. CFF is HB-only — a CFF face has no pure-Dart outline; with the provider
//      off it yields nothing, with HarfBuzz it renders correctly.
//   3. CID-keyed CFF and CFF2 (variable) — which no in-Dart parser handles —
//      render via HB.
//
// Requires HarfBuzz (the shaper). Skips gracefully if unavailable.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';
import 'package:gputext/src/native/harfbuzz_bindings.dart';

List<double>? _bbox(List<double>? q) {
  if (q == null || q.isEmpty) return null;
  var x0 = 1e30, y0 = 1e30, x1 = -1e30, y1 = -1e30;
  for (var i = 0; i < q.length; i += 2) {
    if (q[i] < x0) x0 = q[i];
    if (q[i] > x1) x1 = q[i];
    if (q[i + 1] < y0) y0 = q[i + 1];
    if (q[i + 1] > y1) y1 = q[i + 1];
  }
  return [x0, y0, x1, y1];
}

int _hbOutlineCount(HarfBuzzShaper s, GPUFont font) {
  var n = 0;
  for (var gid = 1; gid < 12; gid++) {
    final q = s.drawGlyphOutline(font, gid);
    if (q != null && q.isNotEmpty) n++;
  }
  return n;
}

int _dartOutlineCount(GPUFont font) {
  var n = 0;
  for (var gid = 1; gid < 12; gid++) {
    final o = font.glyphOutlineById(gid);
    if (o != null && o.quads.isNotEmpty) n++;
  }
  return n;
}

void main() {
  late HarfBuzzShaper shaper;
  final hb = HarfBuzzBindings.tryLoad();
  final available = hb != null;
  if (available) shaper = HarfBuzzShaper(hb);

  // These unit tests probe both paths explicitly, so keep the process-global
  // provider off by default (the engine sets it in production).
  final savedProvider = GPUFont.outlineProvider;
  setUp(() => GPUFont.outlineProvider = null);
  tearDown(() => GPUFont.outlineProvider = savedProvider);

  GPUFont load(String p) => GPUFont.parse(File(p).readAsBytesSync());

  test('HB draw reproduces the pure-Dart glyf outlines exactly', () {
    if (!available) return;
    final font = load('assets/Lato-Regular.ttf'); // glyf / TrueType
    for (final ch in const ['A', 'a', 'o', 'g']) {
      final gid = font.glyphIdForRune(ch.runes.first)!;
      final dart = font.glyphOutlineById(gid)!; // pure-Dart glyf (provider off)
      final hbQuads = shaper.drawGlyphOutline(font, gid)!;
      expect(
        hbQuads.length,
        dart.quads.length,
        reason: '"$ch": quad counts must match',
      );
      final hbBox = _bbox(hbQuads)!;
      for (var i = 0; i < 4; i++) {
        expect(hbBox[i], closeTo(dart.bbox[i], 0.5), reason: '"$ch" bbox');
      }
    }
  });

  test('a CFF face has no outline without HarfBuzz, and renders with it', () {
    if (!available) return;
    final font = load(
      'third_party/harfbuzz/test/api/fonts/SourceSansPro-Regular.otf',
    );
    final gid = font.glyphIdForRune('a'.runes.first)!;

    // No hand-rolled CFF interpreter: with the provider off there is no outline.
    expect(font.glyphOutlineById(gid), isNull);

    // HarfBuzz draws it, with a sane x-height 'a' box (Y-flipped, ~1000 upem).
    final hbQuads = shaper.drawGlyphOutline(font, gid)!;
    expect(hbQuads, isNotEmpty);
    final box = _bbox(hbQuads)!;
    expect(box[1], lessThan(-200)); // rises above the baseline
    expect(box[1], lessThan(box[3])); // Y-down: top < bottom

    // Once the provider is wired, glyphOutlineById returns the HB outline.
    GPUFont.outlineProvider = shaper.drawGlyphOutline;
    final o = font.glyphOutlineById(gid)!;
    expect(o.quads.length, hbQuads.length);
    expect(o.advance, greaterThan(0));
  });

  test('CID-keyed CFF renders via HB where no in-Dart parser can', () {
    if (!available) return;
    for (final p in const [
      'third_party/harfbuzz/test/api/fonts/Cantarell.A.otf',
      'third_party/harfbuzz/test/api/fonts/SourceHanSans-Regular.41,4C2E.otf',
    ]) {
      final font = load(p);
      expect(_dartOutlineCount(font), 0, reason: '$p: no in-Dart CFF outline');
      expect(
        _hbOutlineCount(shaper, font),
        greaterThan(0),
        reason: '$p: HB draws CID glyphs',
      );
    }
  });

  test('CFF2 variable fonts render via HB where no in-Dart parser can', () {
    if (!available) return;
    for (final p in const [
      'third_party/harfbuzz/test/api/fonts/TestCFF2VF.otf',
      'third_party/harfbuzz/test/api/fonts/AdobeVFPrototype.abc.otf',
    ]) {
      final font = load(p);
      expect(_dartOutlineCount(font), 0, reason: '$p: no in-Dart CFF2 outline');
      expect(
        _hbOutlineCount(shaper, font),
        greaterThan(0),
        reason: '$p: HB draws CFF2 glyphs',
      );
    }
  });
}
