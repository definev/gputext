// Variable-font (fvar/avar/gvar/HVAR/MVAR) and GSUB feature coverage against
// Google Sans Flex.
//
// Golden values come from HarfBuzz (font units, --font-size defaults to
// upem):
//   hb-shape --no-glyph-names --features="-kern" <font> "Hox"
//     default:    [60=0+1396|263=1+1192|329=2+973]
//     wght=700:   [60=0+1497|263=1+1242|329=2+1095]
//     wght=1000:  [60=0+1598|263=1+1292|329=2+1217]
//     wdth=25:    [60=0+720|263=1+620|329=2+503]
//   hb-shape ... "fi" → [371=0+1210]        (liga)
//   hb-shape ... "ffi" → [365=0+1865]       (liga)
//   hb-shape ... --features="-kern,+tnum" "0123456789" → gids 415..424, all
//     advance 1290; default gids 384..393 with '1'=385 advance 735
//   hb-shape ... --features="-kern,+zero" "0" → [675=0+1290]
//   hb-shape --show-extents ... "H"
//     default:   <160,1432,1076,-1432>  → x 160..1236, y 0..1432
//     wght=1000: <135,1432,1328,-1432>  → x 135..1463, y 0..1432
//   hb-shape --show-extents --variations="slnt=-10" ... "l"
//     <36,1432,423,-1432> → x 36..459

import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/engine/engine.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/paragraph.dart' as wf;
import 'package:gputext/src/widgets/span_flattener.dart';

const _asset =
    'assets/Google_Sans_Flex/'
    'GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf';
const _proxyBase = 0xF0000;

void main() {
  late GPUFont font;

  setUpAll(() {
    font = GPUFont.parse(File(_asset).readAsBytesSync());
  });

  group('fvar / variant()', () {
    test('exposes the six Google Sans Flex axes', () {
      final tags = font.variationAxes.map((a) => a.tag).toList();
      expect(tags, ['opsz', 'wdth', 'wght', 'GRAD', 'ROND', 'slnt']);
      final wght = font.variationAxes.firstWhere((a) => a.tag == 'wght');
      expect(wght.min, 1);
      expect(wght.def, 400);
      expect(wght.max, 1000);
    });

    test('caches by identity, clamps, and drops defaults', () {
      final bold = font.variant({'wght': 700});
      expect(identical(bold, font.variant({'wght': 700})), isTrue);
      expect(bold.variationCoordinates, {'wght': 700});
      // Default-valued and unknown axes fall back to the base instance.
      expect(identical(font.variant({'wght': 400}), font), isTrue);
      expect(identical(font.variant({'nope': 3}), font), isTrue);
      // Out-of-range values clamp onto an existing instance.
      expect(
        identical(font.variant({'wght': 1200}), font.variant({'wght': 1000})),
        isTrue,
      );
      // variant() on a variant composes against the base.
      final boldNarrow = bold.variant({'wdth': 25});
      expect(boldNarrow.variationCoordinates, {'wght': 700, 'wdth': 25});
      // Non-variable fonts pass through.
      final lato = GPUFont.parse(
        File('assets/Lato-Regular.ttf').readAsBytesSync(),
      );
      expect(lato.variationAxes, isEmpty);
      expect(identical(lato.variant({'wght': 700}), lato), isTrue);
    });
  });

  group('coordinate quantization', () {
    test('bounds the instance count of a continuous animation', () {
      // A raw Tween<double> driver: 600 distinct design values across wght.
      final steps = GPUFont.variationQuantizationSteps!;
      final quantized = <GPUFont>{};
      final exact = <GPUFont>{};
      for (var i = 0; i < 600; i++) {
        final w = 1 + 999 * (i / 599);
        quantized.add(font.variant({'wght': w}));
        exact.add(font.variantExact({'wght': w}));
      }
      // wght spans the full [-1, 1] normalized range, so 2 * steps grid points
      // are reachable, plus the base font for whatever snaps onto the default.
      expect(quantized.length, lessThanOrEqualTo(2 * steps + 1));
      expect(exact.length, greaterThan(quantized.length * 4));
    });

    test('leaves the default, the extremes, and on-grid values exact', () {
      // 0 and ±16384 always land on a power-of-two grid.
      expect(identical(font.variant({'wght': 400}), font), isTrue);
      for (final coords in [
        {'wght': 1000.0}, // +16384
        {'wght': 1.0}, // -16384
        {'wght': 700.0}, // +8192
        {'wdth': 62.5}, // -8192
        {'GRAD': 50.0}, // +8192
        {'slnt': -10.0}, // -16384
      ]) {
        expect(
          identical(font.variant(coords), font.variantExact(coords)),
          isTrue,
          reason: 'on-grid $coords must not be snapped',
        );
      }
    });

    test('snap error stays sub-pixel at body sizes', () {
      const probe = 'Hoxleadingm0';
      var worstUnits = 0.0;
      for (var i = 0; i < 200; i++) {
        final w = 400 + 600 * (i / 199); // upper half of the wght axis
        final q = font.variant({'wght': w});
        final e = font.variantExact({'wght': w});
        for (final ch in probe.split('')) {
          final qo = q.glyphQuads(ch)!;
          final eo = e.glyphQuads(ch)!;
          expect(qo.quads.length, eo.quads.length); // topology never changes
          for (var k = 0; k < qo.quads.length; k++) {
            final d = (qo.quads[k] - eo.quads[k]).abs();
            if (d > worstUnits) worstUnits = d;
          }
          final da = (qo.advance - eo.advance).abs();
          if (da > worstUnits) worstUnits = da;
        }
      }
      final px22 = worstUnits * 22 / font.unitsPerEm; // upem is 2000 here
      expect(px22, lessThan(0.15), reason: 'worst snap error ${px22}px @22');
      expect(worstUnits, lessThan(15));
    });

    test('quantized and exact share the cache when they agree', () {
      // Same normalized ticks -> same key -> one instance, one atlas copy.
      expect(
        identical(
          font.variant({'wght': 700}),
          font.variantExact({'wght': 700}),
        ),
        isTrue,
      );
      // Off-grid: quantized and exact are deliberately different instances.
      expect(
        identical(
          font.variant({'wght': 650}),
          font.variantExact({'wght': 650}),
        ),
        isFalse,
      );
    });

    test('reports the coordinates it renders, not the ones requested', () {
      // wght=650 is 6827 ticks; the 512-tick grid snaps it to 6656, i.e.
      // 400 + (6656 / 16384) * 600 = 643.75 design units.
      final q = font.variant({'wght': 650});
      expect(q.variationCoordinates, {'wght': 643.75});

      // This must NOT depend on who reached the bucket first: a neighbouring
      // request lands on the same instance and reads the same coords back.
      final neighbour = font.variant({'wght': 641});
      expect(identical(neighbour, q), isTrue);
      expect(neighbour.variationCoordinates, {'wght': 643.75});

      // And it round-trips: re-requesting the reported coordinate is a no-op.
      expect(identical(font.variant(q.variationCoordinates), q), isTrue);

      // normalizedCoordinates exposes the ticks that actually drove gvar.
      final wght = font.variationAxes.indexWhere((a) => a.tag == 'wght');
      final ticks = (q.normalizedCoordinates[wght] * 16384).round();
      expect(ticks, 6656);
      expect(ticks % (16384 ~/ GPUFont.variationQuantizationSteps!), 0);
    });
  });

  group('HVAR advances', () {
    test('match hb-shape across weight and width', () {
      expect(font.advanceOf('H'), closeTo(1396, 0.5));
      expect(font.advanceOf('o'), closeTo(1192, 0.5));
      expect(font.advanceOf('x'), closeTo(973, 0.5));

      final bold = font.variant({'wght': 700});
      expect(bold.advanceOf('H'), closeTo(1497, 1));
      expect(bold.advanceOf('o'), closeTo(1242, 1));
      expect(bold.advanceOf('x'), closeTo(1095, 1));

      final black = font.variant({'wght': 1000});
      expect(black.advanceOf('H'), closeTo(1598, 1));
      expect(black.advanceOf('o'), closeTo(1292, 1));
      expect(black.advanceOf('x'), closeTo(1217, 1));

      final narrow = font.variant({'wdth': 25});
      expect(narrow.advanceOf('H'), closeTo(720, 1));
      expect(narrow.advanceOf('o'), closeTo(620, 1));
      expect(narrow.advanceOf('x'), closeTo(503, 1));
    });
  });

  group('gvar outlines', () {
    // GlyphOutline bboxes are Y-flipped ([x0, -yMax, x1, -yMin]).
    test('H control box matches hb extents at default and wght=1000', () {
      final regular = font.glyphQuads('H')!;
      expect(regular.bbox[0], closeTo(160, 1));
      expect(regular.bbox[1], closeTo(-1432, 1));
      expect(regular.bbox[2], closeTo(1236, 1));
      expect(regular.bbox[3], closeTo(0, 1));

      final black = font.variant({'wght': 1000}).glyphQuads('H')!;
      expect(black.bbox[0], closeTo(135, 1));
      expect(black.bbox[1], closeTo(-1432, 1));
      expect(black.bbox[2], closeTo(1463, 1));
      expect(black.bbox[3], closeTo(0, 1));
    });

    test('slnt shears the outline', () {
      final slanted = font.variant({'slnt': -10}).glyphQuads('l')!;
      expect(slanted.bbox[0], closeTo(36, 1));
      expect(slanted.bbox[2], closeTo(459, 1));
      // The upright stem is narrower than the sheared box.
      final upright = font.glyphQuads('l')!;
      expect(
        upright.bbox[2] - upright.bbox[0],
        lessThan(slanted.bbox[2] - slanted.bbox[0]),
      );
    });

    test('multi-axis coordinates combine region scalars correctly', () {
      // hb-shape --variations="wght=650,wdth=62.5,GRAD=50" "Hox":
      //   [60=0+1199|263=1+1018|329=2+896], H extents <113,1432,973,-1432>.
      // variantExact: this asserts region-scalar math against HarfBuzz, so it
      // must not go through the quantization grid. wght=650 is the one
      // coordinate here that lands off-grid (6827 ticks); wdth=62.5 (-8192)
      // and GRAD=50 (8192) are exact at any power-of-two step.
      final mixed = font.variantExact({'wght': 650, 'wdth': 62.5, 'GRAD': 50});
      expect(mixed.advanceOf('H'), closeTo(1199, 1));
      expect(mixed.advanceOf('o'), closeTo(1018, 1));
      expect(mixed.advanceOf('x'), closeTo(896, 1));
      final box = mixed.glyphQuads('H')!.bbox;
      expect(box[0], closeTo(113, 1));
      expect(box[2], closeTo(113 + 973, 1));
    });

    test('composite glyphs vary through component offsets', () {
      // hb-shape --show-extents "é": default <72,1480,980,-1512>,
      // wght=1000 <41,1559,1127,-1597>; Lato (static) <74,1449,893,-1463>.
      final regular = font.glyphQuads('é')!.bbox;
      expect(regular[0], closeTo(72, 1));
      expect(regular[1], closeTo(-1480, 1));
      expect(regular[2], closeTo(72 + 980, 1));
      expect(regular[3], closeTo(-1480 + 1512, 1));

      final black = font.variant({'wght': 1000}).glyphQuads('é')!.bbox;
      expect(black[0], closeTo(41, 1));
      expect(black[1], closeTo(-1559, 1));
      expect(black[2], closeTo(41 + 1127, 1));
      expect(black[3], closeTo(-1559 + 1597, 1));

      final lato = GPUFont.parse(
        File('assets/Lato-Regular.ttf').readAsBytesSync(),
      );
      final latoBox = lato.glyphQuads('é')!.bbox;
      expect(latoBox[0], closeTo(74, 1));
      expect(latoBox[2], closeTo(74 + 893, 1));
    });

    test('intermediate weights interpolate between masters', () {
      double stemWidth(GPUFont f) {
        final b = f.glyphQuads('H')!.bbox;
        return b[2] - b[0];
      }

      final w400 = stemWidth(font);
      final w700 = stemWidth(font.variant({'wght': 700}));
      final w1000 = stemWidth(font.variant({'wght': 1000}));
      expect(w700, greaterThan(w400));
      expect(w1000, greaterThan(w700));
    });
  });

  group('GSUB features', () {
    test('liga substitutes fi/ffi by default', () {
      final fi = font.applyFeatures('fi');
      expect(fi.runes.toList(), [_proxyBase + 371]);
      expect(font.advanceOf(fi), closeTo(1210, 0.5));
      expect(font.glyphQuads(fi), isNotNull);

      final ffi = font.applyFeatures('ffi');
      expect(ffi.runes.toList(), [_proxyBase + 365]);
      expect(font.advanceOf(ffi), closeTo(1865, 0.5));
    });

    test('liga can be disabled per style rules', () {
      expect(font.applyFeatures('fi', features: {'liga': 0, 'calt': 0}), 'fi');
      expect(font.applyFeatures('fi', defaultLigatures: false), 'fi');
    });

    test('tnum swaps in uniform-width figures', () {
      final shaped = font.applyFeatures('0123456789', features: {'tnum': 1});
      final gids = shaped.runes.map((r) => r - _proxyBase).toList();
      expect(gids, List.generate(10, (i) => 415 + i));
      for (final gid in gids) {
        expect(font.advanceOfGlyphId(gid), closeTo(1290, 0.5));
      }
      // Default figures are proportional.
      expect(font.advanceOf('1'), closeTo(735, 0.5));
    });

    test('zero substitutes the slashed zero', () {
      final shaped = font.applyFeatures('0', features: {'zero': 1});
      expect(shaped.runes.toList(), [_proxyBase + 675]);
    });

    test('unknown features and uncovered characters pass through', () {
      expect(font.applyFeatures('abc', features: {'zzzz': 1}), 'abc');
      expect(font.applyFeatures('a🌚b'), 'a🌚b');
      expect(font.applyFeatures(''), '');
    });

    test('spaces and text around ligatures survive', () {
      final shaped = font.applyFeatures('a fi b');
      final runes = shaped.runes.toList();
      expect(runes.length, 5);
      expect(String.fromCharCode(runes[0]), 'a');
      expect(String.fromCharCode(runes[1]), ' ');
      expect(runes[2], _proxyBase + 371);
      expect(String.fromCharCode(runes[3]), ' ');
      expect(String.fromCharCode(runes[4]), 'b');
    });

    test('proxies measure and kern like their glyphs', () {
      final fi = font.applyFeatures('fi');
      expect(font.hasGlyph(fi), isTrue);
      // GPOS kerning is glyph-id based, so proxies participate.
      expect(font.kerningOf('A', 'V'), lessThan(0));
      final tabularOne = String.fromCharCode(
        _proxyBase + 416,
      ); // tnum '1' from above
      expect(font.advanceOf(tabularOne), closeTo(1290, 0.5));
    });
  });

  group('variable metrics (MVAR present)', () {
    test('variant metrics stay sane', () {
      final black = font.variant({'wght': 1000});
      expect(black.unitsPerEm, font.unitsPerEm);
      expect(black.verticalMetrics.ascender, greaterThan(0));
      expect(
        black.decorationMetrics.underlineThickness,
        greaterThanOrEqualTo(font.decorationMetrics.underlineThickness),
      );
    });
  });

  group('span flattener integration', () {
    test('fontVariations and fontWeight map onto variant instances', () {
      final engine = GPUText.instance;
      engine.registerFont('Flex', font);

      final explicit = flattenSpan(
        const TextSpan(
          text: 'Hox',
          style: TextStyle(
            fontFamily: 'Flex',
            fontSize: 16,
            fontVariations: [FontVariation('wght', 700)],
          ),
        ),
        TextScaler.noScaling,
        engine,
      )!;
      final run = explicit.single as wf.TextRun;
      expect(run.font.variationCoordinates, {'wght': 700});
      expect(run.font.advanceOf('H'), closeTo(1497, 1));
      expect(identical(run.font, font.variant({'wght': 700})), isTrue);

      // fontWeight alone drives the wght axis on a variable font.
      final weighted = flattenSpan(
        const TextSpan(
          text: 'Hox',
          style: TextStyle(
            fontFamily: 'Flex',
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        TextScaler.noScaling,
        engine,
      )!;
      expect(
        (weighted.single as wf.TextRun).font.advanceOf('H'),
        closeTo(1497, 1),
      );

      // Explicit fontVariations win over fontWeight.
      final both = flattenSpan(
        const TextSpan(
          text: 'H',
          style: TextStyle(
            fontFamily: 'Flex',
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontVariations: [FontVariation('wght', 1000)],
          ),
        ),
        TextScaler.noScaling,
        engine,
      )!;
      expect((both.single as wf.TextRun).font.variationCoordinates, {
        'wght': 1000,
      });
    });

    test('italic style leans on the slnt axis', () {
      final engine = GPUText.instance;
      engine.registerFont('Flex', font);
      final items = flattenSpan(
        const TextSpan(
          text: 'l',
          style: TextStyle(
            fontFamily: 'Flex',
            fontSize: 16,
            fontStyle: FontStyle.italic,
          ),
        ),
        TextScaler.noScaling,
        engine,
      )!;
      final run = items.single as wf.TextRun;
      expect(run.font.variationCoordinates['slnt'], -10); // clamped to min
    });

    test('fontFeatures flow through shaping', () {
      final engine = GPUText.instance;
      engine.registerFont('Flex', font);
      final items = flattenSpan(
        const TextSpan(
          text: '01',
          style: TextStyle(
            fontFamily: 'Flex',
            fontSize: 16,
            fontFeatures: [FontFeature('tnum')],
          ),
        ),
        TextScaler.noScaling,
        engine,
      )!;
      final run = items.single as wf.TextRun;
      expect(run.text.runes.toList(), [_proxyBase + 415, _proxyBase + 416]);
    });

    test('letterSpacing disables default ligatures but not explicit ones', () {
      final engine = GPUText.instance;
      engine.registerFont('Flex', font);
      List<wf.InlineItem> flatten(TextStyle style) => flattenSpan(
        TextSpan(text: 'fi', style: style),
        TextScaler.noScaling,
        engine,
      )!;

      final ligated =
          flatten(const TextStyle(fontFamily: 'Flex', fontSize: 16)).single
              as wf.TextRun;
      expect(ligated.text.runes.single, _proxyBase + 371);

      final tracked =
          flatten(
                const TextStyle(
                  fontFamily: 'Flex',
                  fontSize: 16,
                  letterSpacing: 2,
                ),
              ).single
              as wf.TextRun;
      expect(tracked.text, 'fi');

      final explicit =
          flatten(
                const TextStyle(
                  fontFamily: 'Flex',
                  fontSize: 16,
                  letterSpacing: 2,
                  fontFeatures: [FontFeature('liga')],
                ),
              ).single
              as wf.TextRun;
      expect(explicit.text.runes.single, _proxyBase + 371);
    });
  });

  group('pipeline round trip', () {
    test('variant fonts and proxies lay out through the paragraph engine', () {
      final bold = font.variant({'wght': 700});
      final shaped = bold.applyFeatures('final offer');
      final para = wf.breakLines(
        [
          wf.TextRun(
            text: shaped,
            font: bold,
            fontSizePx: 32,
            color: const [0, 0, 0, 1],
          ),
        ],
        double.infinity,
        const wf.ParagraphStyle(),
      );
      expect(para.lines.length, 1);
      expect(para.lines.single.width, greaterThan(0));
    });
  });
}
