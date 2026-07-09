// SharedGlyphAtlas.retainFonts: compaction must relocate every surviving glyph
// without changing a single byte of what the shader reads for it.
//
// The atlas is otherwise append-only, and rowBase / band start are absolute
// indices baked into emitted instance buffers, so compaction is the one place
// those indices move. These tests pin the two things that matter: survivors'
// payloads are byte-identical, and the rebuilt buffers match what a
// from-scratch atlas of the same fonts would have produced.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';
import 'package:gputext/src/bands.dart' show GlyphTableEntry, f32fromBits;
import 'package:gputext/src/engine/shared_atlas.dart';

const _gsf =
    'assets/Google_Sans_Flex/'
    'GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf';

const _text = 'Handgloves 0123';

/// Everything the shader reads for one glyph, minus the band start (which is
/// expected to move). Two atlases agreeing here render the glyph identically.
List<double> _payload(SharedGlyphAtlas a, GlyphTableEntry e) {
  final out = <double>[e.y0, e.invH, e.advance, ...e.bbox];
  for (var b = 0; b < e.bandCount; b++) {
    final r = (e.rowBase + b) * 5;
    final start = a.rows[r];
    final count = a.rows[r + 1];
    out
      ..add(count.toDouble())
      ..add(f32fromBits(a.rows[r + 2])) // winding area
      ..add(f32fromBits(a.rows[r + 3])) // ink hull xMin
      ..add(f32fromBits(a.rows[r + 4])); // ink hull xMax
    for (var i = start * 6; i < (start + count) * 6; i++) {
      out.add(a.curves[i]);
    }
  }
  return out;
}

Map<int, List<double>> _payloadsFor(
  SharedGlyphAtlas a,
  GPUFont font,
  String text,
) {
  final out = <int, List<double>>{};
  for (final rune in text.runes) {
    final e = a.lookupRune(font, rune);
    if (e != null) out[rune] = _payload(a, e);
  }
  return out;
}

void main() {
  late GPUFont gsf;
  late GPUFont lato;

  setUpAll(() {
    gsf = GPUFont.parse(File(_gsf).readAsBytesSync());
    lato = GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync());
  });

  test('survivors keep byte-identical payloads across compaction', () {
    final bold = gsf.variant({'wght': 700});
    final black = gsf.variant({'wght': 1000});

    final atlas = SharedGlyphAtlas();
    // Interleave fonts so the dropped glyphs are scattered through the buffers,
    // not a tail we could trivially truncate.
    for (final rune in _text.runes) {
      final ch = String.fromCharCode(rune);
      atlas.ensureGlyphs(lato, ch);
      atlas.ensureGlyphs(bold, ch);
      atlas.ensureGlyphs(black, ch);
    }

    final latoBefore = _payloadsFor(atlas, lato, _text);
    final blackBefore = _payloadsFor(atlas, black, _text);
    expect(latoBefore, isNotEmpty);
    expect(blackBefore, isNotEmpty);

    final curvesBefore = atlas.curveFloatCount;
    final reclaimed = atlas.retainFonts({lato, black});

    expect(reclaimed, greaterThan(0));
    expect(atlas.curveFloatCount, curvesBefore - reclaimed);
    // The evicted font is gone entirely.
    for (final rune in _text.runes) {
      expect(atlas.lookupRune(bold, rune), isNull);
    }
    // ...and every survivor reads back exactly the same bytes.
    expect(_payloadsFor(atlas, lato, _text), latoBefore);
    expect(_payloadsFor(atlas, black, _text), blackBefore);
  });

  test('compaction reproduces a from-scratch atlas of the kept fonts', () {
    final bold = gsf.variant({'wght': 700});

    final compacted = SharedGlyphAtlas();
    compacted.ensureGlyphs(gsf, _text);
    compacted.ensureGlyphs(bold, _text);
    compacted.ensureGlyphs(lato, _text);
    compacted.retainFonts({gsf, lato});

    final fresh = SharedGlyphAtlas();
    fresh.ensureGlyphs(gsf, _text);
    fresh.ensureGlyphs(lato, _text);

    expect(compacted.curveFloatCount, fresh.curveFloatCount);
    expect(compacted.rowCount, fresh.rowCount);
    expect(compacted.glyphEntryCount, fresh.glyphEntryCount);
    expect(compacted.curves, fresh.curves);
    expect(compacted.rows, fresh.rows); // rowBase and band starts included
  });

  test('glyph-id (COLR) entries relocate too', () {
    final bold = gsf.variant({'wght': 700});
    final atlas = SharedGlyphAtlas();
    for (var gid = 40; gid < 48; gid++) {
      atlas.ensureGlyphId(gsf, gid);
      atlas.ensureGlyphId(bold, gid);
    }
    final before = {
      for (var gid = 40; gid < 48; gid++)
        if (atlas.lookupGlyphId(gsf, gid) != null)
          gid: _payload(atlas, atlas.lookupGlyphId(gsf, gid)!),
    };
    expect(before, isNotEmpty);

    expect(atlas.retainFonts({gsf}), greaterThan(0));
    for (var gid = 40; gid < 48; gid++) {
      expect(atlas.lookupGlyphId(bold, gid), isNull);
    }
    for (final e in before.entries) {
      expect(_payload(atlas, atlas.lookupGlyphId(gsf, e.key)!), e.value);
    }
  });

  test('rune and glyph-id entries for the same font both survive', () {
    final bold = gsf.variant({'wght': 700});
    final atlas = SharedGlyphAtlas();
    atlas.ensureGlyphs(gsf, _text);
    atlas.ensureGlyphId(gsf, 42);
    atlas.ensureGlyphs(bold, _text);
    atlas.ensureGlyphId(bold, 42);

    final runes = _payloadsFor(atlas, gsf, _text);
    final gid = _payload(atlas, atlas.lookupGlyphId(gsf, 42)!);

    atlas.retainFonts({gsf});
    expect(_payloadsFor(atlas, gsf, _text), runes);
    expect(_payload(atlas, atlas.lookupGlyphId(gsf, 42)!), gid);
    expect(atlas.lookupGlyphId(bold, 42), isNull);
  });

  test('a no-op retain moves nothing and bumps no generation', () {
    final atlas = SharedGlyphAtlas();
    atlas.ensureGlyphs(gsf, _text);
    final gen = atlas.generation;
    final structGen = atlas.structureGeneration;
    final curves = atlas.curves.toList();

    expect(atlas.retainFonts({gsf, lato}), 0);
    expect(atlas.generation, gen);
    expect(atlas.structureGeneration, structGen);
    expect(atlas.curves, curves);
  });

  test(
    'structureGeneration bumps once per compaction that drops something',
    () {
      final bold = gsf.variant({'wght': 700});
      final atlas = SharedGlyphAtlas();
      atlas.ensureGlyphs(gsf, _text);
      atlas.ensureGlyphs(bold, _text);
      final structGen = atlas.structureGeneration;

      expect(atlas.retainFonts({gsf}), greaterThan(0));
      expect(atlas.structureGeneration, structGen + 1);
      expect(atlas.generation, greaterThan(0));

      // Already compacted: nothing left to drop.
      expect(atlas.retainFonts({gsf}), 0);
      expect(atlas.structureGeneration, structGen + 1);
    },
  );

  test('evicting everything empties the atlas', () {
    final atlas = SharedGlyphAtlas();
    atlas.ensureGlyphs(gsf, _text);
    expect(atlas.isEmpty, isFalse);
    expect(atlas.retainFonts(const {}), greaterThan(0));
    expect(atlas.isEmpty, isTrue);
    expect(atlas.glyphEntryCount, 0);
    expect(atlas.curveFloatCount, 0);
    expect(atlas.rowCount, 0);
  });

  test('an evicted font re-bands correctly on next use', () {
    final bold = gsf.variant({'wght': 700});
    final atlas = SharedGlyphAtlas();
    atlas.ensureGlyphs(gsf, _text);
    atlas.ensureGlyphs(bold, _text);
    final boldBefore = _payloadsFor(atlas, bold, _text);

    atlas.retainFonts({gsf});
    expect(atlas.lookupRune(bold, 0x48), isNull);

    // Re-adding must reproduce the original payloads, not stale indices.
    expect(atlas.ensureGlyphs(bold, _text), isTrue);
    expect(_payloadsFor(atlas, bold, _text), boldBefore);
    // And the font that stayed is still intact alongside it.
    final fresh = SharedGlyphAtlas()..ensureGlyphs(gsf, _text);
    expect(_payloadsFor(atlas, gsf, _text), _payloadsFor(fresh, gsf, _text));
  });

  // U+00A0 maps to a real glyph whose outline is empty, so it lands in the
  // blank set. A cmap MISS (say U+1F600) would instead fall back to .notdef,
  // which does have an outline and gets banded like any other glyph.
  const nbsp = ' ';

  test('a blank-only font is dropped without touching curve data', () {
    final bold = gsf.variant({'wght': 700});
    final atlas = SharedGlyphAtlas();
    atlas.ensureGlyphs(bold, nbsp);
    atlas.ensureGlyphs(gsf, '$nbsp$_text');
    expect(atlas.blankEntryCount, 2);
    expect(atlas.fonts, {gsf, bold});
    final curves = atlas.curveFloatCount;
    final structGen = atlas.structureGeneration;

    // Blanks hold no curve data, so nothing is reclaimed and nothing moves...
    expect(atlas.retainFonts({gsf}), 0);
    expect(atlas.curveFloatCount, curves);
    expect(atlas.structureGeneration, structGen);
    // ...but the evicted font's blank entry must go, or it pins the GPUFont
    // forever and eviction reclaims nothing that matters.
    expect(atlas.blankEntryCount, 1);
    expect(atlas.fonts, {gsf});
  });

  test('blanks are pruned along the compacting path too', () {
    final bold = gsf.variant({'wght': 700});
    final atlas = SharedGlyphAtlas();
    atlas.ensureGlyphs(bold, '$nbsp$_text'); // blank AND banded glyphs
    atlas.ensureGlyphs(gsf, '$nbsp$_text');
    expect(atlas.blankEntryCount, 2);

    expect(atlas.retainFonts({gsf}), greaterThan(0));
    expect(atlas.blankEntryCount, 1);
    expect(atlas.fonts, {gsf});
    // The blank rune stays unbanded for the surviving font.
    expect(atlas.lookupRune(gsf, 0xA0), isNull);
    expect(atlas.lookupRune(gsf, 0x48), isNotNull);
  });

  // ---- through the widget layer ----
  //
  // Everything above tests the atlas in isolation. What actually has to hold is
  // that a live paragraph notices the relocation: its emitted instance buffer
  // bakes rowBase in, and painting it against a compacted atlas would sample
  // another glyph's curves.

  group('widget layer', () {
    late GPUTextEngine engine;

    setUp(() {
      engine = GPUText.instance;
      engine.registerFont('Flex', gsf);
      // The engine is a process-wide singleton; start each test from an empty
      // atlas so instance layouts are comparable across pumps.
      engine.atlas.retainFonts(const {});
      engine.debugAtlasCompactions = 0;
      engine.debugAtlasSweeps = 0;
    });

    Widget label(String text, FontWeight weight) => GPURichText(
      text: TextSpan(
        text: text,
        style: TextStyle(fontFamily: 'Flex', fontSize: 16, fontWeight: weight),
      ),
    );

    Float32List instancesOf(WidgetTester tester, Finder f) {
      final ro = tester.renderObject<RenderGPUParagraph>(f);
      return Float32List.fromList(ro.debugInstances!);
    }

    testWidgets('a survivor re-emits identically to a never-polluted atlas', (
      tester,
    ) async {
      // Reference: only the light paragraph ever touches the atlas.
      await tester.pumpWidget(
        MaterialApp(home: Center(child: label(_text, FontWeight.w400))),
      );
      final reference = instancesOf(tester, find.byType(GPURichText));
      expect(reference, isNotEmpty);

      // Now pollute the atlas with a second variant, drop its widget, compact.
      engine.atlas.retainFonts(const {});
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              label(_text, FontWeight.w400),
              label(_text, FontWeight.w700),
            ],
          ),
        ),
      );
      expect(engine.atlas.fonts.length, 2);
      final polluted = instancesOf(tester, find.byType(GPURichText).first);
      // The light paragraph banded first, so it is unaffected by the bold one.
      expect(polluted, reference);

      await tester.pumpWidget(
        MaterialApp(home: Center(child: label(_text, FontWeight.w400))),
      );
      expect(engine.compactAtlas(), greaterThan(0));
      expect(engine.atlas.fonts.length, 1);
      await tester.pump(); // notifyListeners -> markNeedsPaint -> re-emit

      expect(instancesOf(tester, find.byType(GPURichText)), reference);
    });

    testWidgets('a survivor whose glyphs MOVED re-emits correctly', (
      tester,
    ) async {
      // Bold bands FIRST here, so evicting it shifts every light rowBase down.
      // A paragraph that failed to re-emit would keep the old, larger indices.
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              label(_text, FontWeight.w700),
              label(_text, FontWeight.w400),
            ],
          ),
        ),
      );
      final lightFinder = find.byType(GPURichText).last;
      final before = instancesOf(tester, lightFinder);

      await tester.pumpWidget(
        MaterialApp(home: Center(child: label(_text, FontWeight.w400))),
      );
      expect(engine.compactAtlas(), greaterThan(0));
      await tester.pump();
      final after = instancesOf(tester, lightFinder);

      // rowBase is float 12 of each 16-float instance. It must have shifted.
      var moved = false;
      for (var i = 12; i < before.length; i += 16) {
        if (before[i] != after[i]) moved = true;
      }
      expect(moved, isTrue, reason: 'compaction should have relocated rowBase');

      // ...and now match a pristine atlas holding only the light font.
      engine.atlas.retainFonts(const {});
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(home: Center(child: label(_text, FontWeight.w400))),
      );
      expect(instancesOf(tester, find.byType(GPURichText)), after);
    });

    testWidgets('live paragraphs pin their fonts', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              label(_text, FontWeight.w400),
              label(_text, FontWeight.w700),
            ],
          ),
        ),
      );
      final fonts = engine.atlas.fonts;
      expect(fonts.length, 2);

      // Nothing left the tree: a sweep must reclaim nothing and move nothing.
      final structGen = engine.atlas.structureGeneration;
      expect(engine.compactAtlas(), 0);
      expect(engine.atlas.fonts, fonts);
      expect(engine.atlas.structureGeneration, structGen);
      expect(engine.debugAtlasCompactions, 0);
    });

    testWidgets('detached render objects stop pinning fonts', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Center(child: label(_text, FontWeight.w700))),
      );
      expect(engine.atlas.fonts, isNotEmpty);
      await tester.pumpWidget(const SizedBox());
      expect(engine.compactAtlas(), greaterThan(0));
      expect(engine.atlas.fonts, isEmpty);
      expect(engine.atlas.isEmpty, isTrue);
      expect(engine.debugAtlasCompactions, 1);
    });

    testWidgets('the budget triggers a sweep at the frame boundary', (
      tester,
    ) async {
      final saved = engine.atlasCurveFloatBudget;
      addTearDown(() => engine.atlasCurveFloatBudget = saved);
      engine.atlasCurveFloatBudget = 1; // always over budget

      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              label(_text, FontWeight.w400),
              label(_text, FontWeight.w700),
            ],
          ),
        ),
      );
      // Both fonts are live, so the post-frame sweep reclaims nothing...
      await tester.pump();
      expect(engine.debugAtlasCompactions, 0);
      expect(engine.atlas.fonts.length, 2);

      // ...until one leaves, at which point the next frame boundary sweeps it.
      await tester.pumpWidget(
        MaterialApp(home: Center(child: label(_text, FontWeight.w400))),
      );
      await tester.pump();
      expect(engine.debugAtlasCompactions, 1);
      expect(engine.atlas.fonts.length, 1);
    });

    testWidgets('hysteresis stops a per-frame sweep loop', (tester) async {
      final saved = engine.atlasCurveFloatBudget;
      addTearDown(() => engine.atlasCurveFloatBudget = saved);
      engine.atlasCurveFloatBudget = 1;

      // First frame sweeps once and finds nothing to drop: the live set alone
      // is over budget.
      await tester.pumpWidget(
        MaterialApp(home: Center(child: label(_text, FontWeight.w400))),
      );
      expect(engine.debugAtlasSweeps, 1);
      expect(engine.debugAtlasCompactions, 0);

      // Every later frame is still over budget, but nothing has changed, so
      // sweeping again could only churn — each compaction re-emits and
      // re-uploads everything.
      engine.debugAtlasSweeps = 0;
      for (var i = 0; i < 5; i++) {
        engine.scheduleAtlasSweepIfNeeded();
        await tester.pump();
      }
      expect(engine.debugAtlasSweeps, 0);

      // A client leaving is the signal that a sweep could pay off again.
      await tester.pumpWidget(const SizedBox());
      engine.scheduleAtlasSweepIfNeeded();
      await tester.pump();
      expect(engine.debugAtlasSweeps, 1);
      expect(engine.debugAtlasCompactions, 1);
    });
  });
}
