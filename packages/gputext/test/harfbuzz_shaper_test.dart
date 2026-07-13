import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/native/harfbuzz_bindings.dart';
import 'package:gputext/src/text/harfbuzz_shaper.dart';
import 'package:gputext/src/text/shaped_run.dart';
import 'package:gputext/src/text/shaper.dart';

void main() {
  late GPUFont font;

  setUpAll(() {
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    font = GPUFont.parse(bytes);
  });

  group('HarfBuzz shaping', () {
    late HarfBuzzShaper shaper;

    setUpAll(() {
      final hb = HarfBuzzBindings.tryLoad();
      if (hb == null) {
        return;
      }
      shaper = HarfBuzzShaper(hb);
    });

    test('liga fi produces one glyph with cluster covering both chars', () {
      final hb = HarfBuzzBindings.tryLoad();
      expect(
        hb,
        isNotNull,
        reason: 'HarfBuzz native asset must resolve via hooks / @Native',
      );
      expect(
        HarfBuzzBindings.loadedViaNative,
        isTrue,
        reason: 'prefer @Native over DynamicLibrary.open fallback',
      );
      shaper = HarfBuzzShaper(hb!);
      final run = shaper.shape(
        ShapeRequest(font: font, text: 'fi', fontSizePx: 16),
      );
      expect(run.appliesKerning, isFalse);
      expect(run.glyphs, hasLength(1));
      expect(run.glyphs.single.cluster, 0);
      expect(run.glyphs.single.clusterEnd, 2);
      // HB returns the true OT ligature glyph id, distinct from a plain cmap
      // lookup. Just assert it's not the plain 'f'/'i' pair.
      final fGid = font.glyphIdForRune('f'.codeUnitAt(0))!;
      final iGid = font.glyphIdForRune('i'.codeUnitAt(0))!;
      expect(run.glyphs.single.glyphId, isNot(anyOf(fGid, iGid)));
      expect(run.glyphs.single.xAdvance, greaterThan(0));
    });

    test('Arabic mark positioning smoke (diacritic offset)', () {
      final hb = HarfBuzzBindings.tryLoad();
      if (hb == null) return;
      shaper = HarfBuzzShaper(hb);
      // Arabic letter + fatha; Lato may .notdef — still exercises HB path.
      const text = 'بَ'; // beh + fatha
      final run = shaper.shape(
        ShapeRequest(
          font: font,
          text: text,
          fontSizePx: 16,
          direction: TextDirection.rtl,
          script: 'arab',
        ),
      );
      expect(run.glyphs, isNotEmpty);
      expect(run.appliesKerning, isFalse);
      // At least one glyph should carry a non-zero y or x offset OR multiple
      // glyphs (base + mark) when the font covers Arabic.
      final hasMarkLayout =
          run.glyphs.length > 1 ||
          run.glyphs.any((g) => g.xOffset != 0 || g.yOffset != 0);
      // Soft assert: if font has no Arabic, HB still returns .notdef glyphs.
      expect(run.glyphs.first.glyphId, isNonNegative);
      expect(hasMarkLayout || run.glyphs.every((g) => g.glyphId == 0), isTrue);
    });

    test('RTL clusters tile the text; no glyph spans to run end', () {
      final hb = HarfBuzzBindings.tryLoad();
      if (hb == null) return;
      shaper = HarfBuzzShaper(hb);
      const text = 'שלום עולם';
      final run = shaper.shape(
        ShapeRequest(
          font: font,
          text: text,
          fontSizePx: 16,
          direction: TextDirection.rtl,
          script: 'hebr',
        ),
      );
      expect(run.glyphs, isNotEmpty);
      for (final g in run.glyphs) {
        expect(g.cluster, inInclusiveRange(0, text.length - 1));
        expect(g.clusterEnd, inInclusiveRange(g.cluster + 1, text.length));
        expect(g.shapedStart, g.cluster);
        expect(g.shapedEnd, g.clusterEnd);
      }
      // Distinct cluster ranges, sorted by start, tile [0, text.length)
      // with no overlap (HB visual order puts RTL clusters descending, which
      // previously made every clusterEnd == text.length).
      final ranges = {for (final g in run.glyphs) (g.cluster, g.clusterEnd)}
          .toList()
        ..sort((a, b) => a.$1 - b.$1);
      expect(ranges.first.$1, 0);
      expect(ranges.last.$2, text.length);
      for (var i = 0; i + 1 < ranges.length; i++) {
        expect(
          ranges[i].$2,
          ranges[i + 1].$1,
          reason: 'range $i must end where range ${i + 1} starts',
        );
      }
    });

    test('mid-run slice of an RTL run keeps offsets inside the slice', () {
      final hb = HarfBuzzBindings.tryLoad();
      if (hb == null) return;
      shaper = HarfBuzzShaper(hb);
      const text = 'שלום עולם';
      final run = shaper.shape(
        ShapeRequest(
          font: font,
          text: text,
          fontSizePx: 16,
          direction: TextDirection.rtl,
          script: 'hebr',
        ),
      );
      for (var s = 0; s < text.length; s++) {
        for (var e = s + 1; e <= text.length; e++) {
          final sub = run.slice(s, e);
          for (final g in sub.glyphs) {
            expect(
              g.shapedStart,
              inInclusiveRange(0, sub.pipelineText.length),
              reason: 'slice($s,$e) glyph shapedStart out of range',
            );
            expect(
              g.shapedEnd,
              inInclusiveRange(g.shapedStart, sub.pipelineText.length),
              reason: 'slice($s,$e) glyph shapedEnd out of range',
            );
            expect(
              g.cluster,
              inInclusiveRange(0, sub.sourceText.length),
              reason: 'slice($s,$e) glyph cluster out of range',
            );
          }
        }
      }
    });

    test('HB advance parity with cmap+kern for plain Latin', () {
      final hb = HarfBuzzBindings.tryLoad();
      if (hb == null) return;
      shaper = HarfBuzzShaper(hb);
      const text = 'hello';
      final hbRun = shaper.shape(
        ShapeRequest(font: font, text: text, fontSizePx: 16),
      );
      final hbW = hbRun.glyphs.fold<double>(0, (s, g) => s + g.xAdvance);
      // Plain Latin has no GSUB substitution, so HB advances should match the
      // sum of per-glyph cmap advances plus pairwise kerning.
      var expected = 0.0;
      var prev = -1;
      for (final cp in text.codeUnits) {
        final gid = font.glyphIdForRune(cp)!;
        if (prev >= 0) expected += font.kerningOfGlyphIds(prev, gid);
        expected += font.advanceOfGlyphId(gid);
        prev = gid;
      }
      expect(hbW, closeTo(expected, 1.0));
    });

    test('variable-font advances follow GPUFont HVAR instance', () {
      final hb = HarfBuzzBindings.tryLoad();
      if (hb == null) return;
      shaper = HarfBuzzShaper(hb);
      final flex = GPUFont.parse(
        File(
          'assets/Google_Sans_Flex/'
          'GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf',
        ).readAsBytesSync(),
      );
      // Disable liga so one glyph per char; compare HB xAdvance to HVAR.
      for (final coords in [
        <String, double>{},
        {'wght': 700.0},
        {'wght': 1000.0},
        {'wdth': 25.0},
        {'wght': 700.0, 'wdth': 25.0},
      ]) {
        final instance = coords.isEmpty ? flex : flex.variant(coords);
        final run = shaper.shape(
          ShapeRequest(
            font: instance,
            text: 'Hox',
            fontSizePx: 16,
            defaultLigatures: false,
            features: const {'kern': 0},
          ),
        );
        expect(run.glyphs, hasLength(3), reason: '$coords');
        expect(
          run.glyphs[0].xAdvance,
          closeTo(instance.advanceOf('H'), 1),
          reason: 'H at $coords',
        );
        expect(
          run.glyphs[1].xAdvance,
          closeTo(instance.advanceOf('o'), 1),
          reason: 'o at $coords',
        );
        expect(
          run.glyphs[2].xAdvance,
          closeTo(instance.advanceOf('x'), 1),
          reason: 'x at $coords',
        );
      }
    });

    test('evictFont then reshape succeeds; double-evict is safe', () {
      final hb = HarfBuzzBindings.tryLoad();
      if (hb == null) return;
      shaper = HarfBuzzShaper(hb);
      final run1 = shaper.shape(
        ShapeRequest(font: font, text: 'fi', fontSizePx: 16),
      );
      expect(run1.glyphs, isNotEmpty);
      shaper.evictFont(font);
      shaper.evictFont(font); // no-op
      final run2 = shaper.shape(
        ShapeRequest(font: font, text: 'fi', fontSizePx: 16),
      );
      expect(run2.glyphs, hasLength(run1.glyphs.length));
      expect(run2.glyphs.single.glyphId, run1.glyphs.single.glyphId);
    });
  });
}
