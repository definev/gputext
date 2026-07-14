// The GPUTextWorker doc pipeline runs headless: HarfBuzz loads in the worker
// isolate (FFI symbols are process-global), so shaping, bidi, glyf+CFF outline
// banding and emit all run off the main isolate. We prove the OFF-ISOLATE
// drawable matches a main-isolate layout built with the SAME shared shaping
// (buildRunItems + loadHarfBuzzShaper), and that CFF/OTF fonts render — which
// only HarfBuzz outline extraction makes possible.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/engine/shared_atlas.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/lowlevel/gpu_text_worker.dart';
import 'package:gputext/src/lowlevel/text_span_specs.dart';
import 'package:gputext/src/paragraph.dart' as wf;
import 'package:gputext/src/text/shaper.dart' show TextShaper;

/// Reference layout on the main isolate, using the same shaping the worker
/// does. Returns (glyphCount, lineCount, curveFloatCount).
(int, int, int) _reference(
  List<GPUTextRunSpec> specs,
  Map<String, GPUFont> fonts,
  double width,
  TextShaper? shaper,
) {
  final items = buildRunItems(specs, fonts, shaper);
  final prepared = wf.prepareParagraph(items);
  final laid = wf.layoutPreparedLines(
    prepared,
    width,
    wf.ParagraphStyle(maxWidth: width),
  );
  final atlas = SharedGlyphAtlas();
  for (final it in items) {
    if (it is wf.TextRun) atlas.ensureShaped(it.shaped);
  }
  final glyphs = wf.emitInstances(laid, width, wf.TextAlign.left, atlas).glyphCount;
  return (glyphs, laid.lines.length, atlas.curves.length);
}

void main() {
  test('worker drawable matches a main-isolate layout with the same shaping',
      () async {
    // Worker and reference both resolve HarfBuzz the same way (process-global),
    // so this holds whether HB is available (real shaping) or not (per-rune).
    final shaper = loadHarfBuzzShaper();
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    final font = GPUFont.parse(bytes);
    final text = List.filled(
      50,
      'The quick brown fox jumps over the lazy dog.',
    ).join(' ');
    final specs = [
      GPUTextRunSpec(
        text: text,
        fontId: 'lato',
        fontSizePx: 18,
        color: const [0.11, 0.12, 0.16, 1],
      ),
    ];
    final fonts = {'lato': font};

    final ref300 = _reference(specs, fonts, 300, shaper);
    final ref520 = _reference(specs, fonts, 520, shaper);
    expect(ref300.$1, greaterThan(0), reason: 'sanity: some glyphs emitted');
    expect(ref300.$2, greaterThan(ref520.$2), reason: 'narrower wraps more');

    final worker = await GPUTextWorker.spawn();
    try {
      await worker.registerFont('lato', bytes);
      await worker.prepareDoc('doc', specs);

      final d300 = await worker.reflowDoc('doc', 300);
      expect(d300.glyphCount, ref300.$1);
      expect(d300.lineCount, ref300.$2);
      expect(d300.width, 300);
      expect(d300.height, greaterThan(0));
      expect(d300.materialize().length, d300.glyphCount * 16);
      final curves300 = d300.materializeCurves(); // single-use — materialize once
      expect(curves300.length, ref300.$3);
      expect(curves300.isNotEmpty, isTrue);

      // Reflow reuses the cached prepare (phase 1 not re-run) at a new width.
      final d520 = await worker.reflowDoc('doc', 520);
      expect(d520.lineCount, ref520.$2);
      expect(d520.lineCount, lessThan(d300.lineCount));

      // Atlas-skip: the atlas is identical across widths, so a reflow with
      // includeAtlas:false returns the same geometry but omits curves/rows.
      final dLite = await worker.reflowDoc('doc', 300, includeAtlas: false);
      expect(dLite.glyphCount, d300.glyphCount);
      expect(dLite.materialize().length, dLite.glyphCount * 16);
      expect(dLite.materializeCurves(), isEmpty);
      expect(dLite.materializeRows(), isEmpty);

      // Reflowing an unprepared doc surfaces a clear error, not a crash.
      await expectLater(worker.reflowDoc('missing', 300), throwsStateError);
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('worker lays out a multi-run (rich TextSpan) document', () async {
    final shaper = loadHarfBuzzShaper();
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    final font = GPUFont.parse(bytes);
    const specs = [
      GPUTextRunSpec(
        text: 'A Heading\n',
        fontId: 'lato',
        fontSizePx: 32,
        color: [0.04, 0.24, 0.57, 1],
      ),
      GPUTextRunSpec(
        text: 'and a longer body run that wraps across several lines at this '
            'width so line breaking has real work to do.',
        fontId: 'lato',
        fontSizePx: 16,
        color: [0.11, 0.12, 0.16, 1],
      ),
    ];
    final ref = _reference(specs, {'lato': font}, 280, shaper);
    expect(ref.$1, greaterThan(0));
    expect(ref.$2, greaterThan(1), reason: 'body run should wrap');

    final worker = await GPUTextWorker.spawn();
    try {
      await worker.registerFont('lato', bytes);
      await worker.prepareDoc('rich', specs);
      final d = await worker.reflowDoc('rich', 280);
      expect(d.glyphCount, ref.$1);
      expect(d.lineCount, ref.$2);
      expect(d.materialize().length, d.glyphCount * 16);
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('disposeDoc evicts a prepared document; re-prepare restores it',
      () async {
    const runs = [
      GPUTextRunSpec(text: 'hello lazy world', fontId: 'lato', fontSizePx: 18),
    ];
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    final worker = await GPUTextWorker.spawn();
    try {
      await worker.registerFont('lato', bytes);
      await worker.prepareDoc('block', runs);
      expect((await worker.reflowDoc('block', 200)).glyphCount, greaterThan(0));

      // Evict it — reflowing the freed id now fails.
      await worker.disposeDoc('block');
      await expectLater(
        worker.reflowDoc('block', 200),
        throwsA(isA<StateError>()),
      );

      // Re-preparing under the same id brings it back.
      await worker.prepareDoc('block', runs);
      expect((await worker.reflowDoc('block', 200)).glyphCount, greaterThan(0));
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('prepared docs share one atlas; generation is stable when glyphs overlap',
      () async {
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    final worker = await GPUTextWorker.spawn();
    try {
      await worker.registerFont('lato', bytes);
      await worker.prepareDoc('a', const [
        GPUTextRunSpec(text: 'hello', fontId: 'lato', fontSizePx: 18),
      ]);
      final first = await worker.reflowDoc('a', 200, includeAtlas: true);
      expect(first.atlasGeneration, greaterThan(0));
      final firstCurves = first.materializeCurves().length;

      // Overlapping alphabet — should not grow the shared atlas much / at all
      // beyond what 'hello' already banded (same Latin glyphs).
      await worker.prepareDoc('b', const [
        GPUTextRunSpec(text: 'hello hello', fontId: 'lato', fontSizePx: 18),
      ]);
      final second = await worker.reflowDoc('b', 200, includeAtlas: true);
      expect(second.atlasGeneration, first.atlasGeneration);
      expect(second.materializeCurves().length, firstCurves);

      // First doc still reflows after the second prepare (shared atlas intact).
      final again = await worker.reflowDoc('a', 200, includeAtlas: false);
      expect(again.atlasGeneration, first.atlasGeneration);
      expect(again.glyphCount, first.glyphCount);
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('shared atlas grows when a new glyph appears; old instances stay valid',
      () async {
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    final worker = await GPUTextWorker.spawn();
    try {
      await worker.registerFont('lato', bytes);
      await worker.prepareDoc('a', const [
        GPUTextRunSpec(text: 'aaa', fontId: 'lato', fontSizePx: 18),
      ]);
      final first = await worker.reflowDoc('a', 200, includeAtlas: true);
      final gen1 = first.atlasGeneration;
      final firstCurveFloats = first.materializeCurves().length;

      await worker.prepareDoc('b', const [
        GPUTextRunSpec(text: 'zzz', fontId: 'lato', fontSizePx: 18),
      ]);
      final second = await worker.reflowDoc('b', 200, includeAtlas: true);
      expect(second.atlasGeneration, greaterThan(gen1));
      expect(
        second.materializeCurves().length,
        greaterThan(firstCurveFloats),
      );

      // Doc A still emits against the grown atlas (append-only rowBases).
      final again = await worker.reflowDoc('a', 200, includeAtlas: false);
      expect(again.atlasGeneration, second.atlasGeneration);
      expect(again.glyphCount, first.glyphCount);
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('worker renders a CFF/OTF font (SourceSans3) via HarfBuzz outlines',
      () async {
    final shaper = loadHarfBuzzShaper();
    if (shaper == null) {
      markTestSkipped('HarfBuzz unavailable — CFF rendering needs it');
      return;
    }
    // SourceSans3 has CFF (PostScript) outlines and NO glyf table, so the
    // pure-Dart parser can't touch it — only HarfBuzz extraction works.
    final bytes =
        File('../../example/assets/SourceSans3-Regular.otf').readAsBytesSync();
    final font = GPUFont.parse(bytes);
    const specs = [
      GPUTextRunSpec(
        text: 'Office fluffier — CFF outlines shaped off the UI thread.',
        fontId: 'src',
        fontSizePx: 22,
        color: [0.1, 0.1, 0.12, 1],
      ),
    ];

    final ref = _reference(specs, {'src': font}, 400, shaper);
    expect(ref.$1, greaterThan(0), reason: 'CFF glyphs should emit');
    expect(ref.$3, greaterThan(64),
        reason: 'CFF outlines must band real curves (would be ~0 without HB)');

    final worker = await GPUTextWorker.spawn();
    try {
      await worker.registerFont('src', bytes);
      await worker.prepareDoc('cff', specs);
      final d = await worker.reflowDoc('cff', 400);
      expect(d.glyphCount, ref.$1);
      final curves = d.materializeCurves(); // single-use — materialize once
      expect(curves.length, ref.$3,
          reason: 'worker must extract the same CFF outlines as main');
      expect(curves.length, greaterThan(64));
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('flattenInlineSpan extracts fontFeatures per span', () {
    const span = TextSpan(
      style: TextStyle(fontFamily: 'X', fontSize: 16),
      children: [
        TextSpan(
          text: 'small caps',
          style: TextStyle(
            fontFeatures: [FontFeature.enable('smcp')],
            color: Color(0xFF204080),
          ),
        ),
        TextSpan(text: ' and plain'),
      ],
    );
    final specs = flattenInlineSpan(span, fontIdResolver: (_) => 'x');
    expect(specs, hasLength(2));
    final a = specs[0] as GPUTextRunSpec;
    expect(a.text, 'small caps');
    expect(a.features, {'smcp': 1});
    final b = specs[1] as GPUTextRunSpec;
    expect(b.text, ' and plain');
    expect(b.features, isEmpty);
  });

  test('flattenInlineSpan emits placeholders for WidgetSpans with a sizer', () {
    final span = TextSpan(
      children: [
        const TextSpan(text: 'icon '),
        WidgetSpan(child: const SizedBox()),
        const TextSpan(text: ' text'),
      ],
    );
    final specs = flattenInlineSpan(
      span,
      fontIdResolver: (_) => 'x',
      placeholderSize: (_, _) => const Size(30, 20),
    );
    expect(specs, hasLength(3));
    expect(specs[1], isA<GPUPlaceholderSpec>());
    final ph = specs[1] as GPUPlaceholderSpec;
    expect(ph.index, 0);
    expect(ph.width, 30);
    expect(ph.height, 20);
    // Without a sizer, the WidgetSpan is dropped.
    final noPh = flattenInlineSpan(span, fontIdResolver: (_) => 'x');
    expect(noPh.whereType<GPUPlaceholderSpec>(), isEmpty);
  });

  test('worker reserves WidgetSpan placeholders and returns their boxes',
      () async {
    final shaper = loadHarfBuzzShaper();
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    final specs = <GPUInlineSpec>[
      const GPUTextRunSpec(
        text: 'before ',
        fontId: 'lato',
        fontSizePx: 18,
        color: [0, 0, 0, 1],
      ),
      const GPUPlaceholderSpec(
        index: 7,
        width: 40,
        height: 24,
        alignment: wf.InlinePlaceholderAlignment.middle,
      ),
      const GPUTextRunSpec(
        text: ' after, plus more text so the line has real content to wrap.',
        fontId: 'lato',
        fontSizePx: 18,
        color: [0, 0, 0, 1],
      ),
    ];
    // buildRunItems must turn the placeholder spec into a PlaceholderItem.
    final font = GPUFont.parse(bytes);
    final items = buildRunItems(specs, {'lato': font}, shaper);
    expect(items.whereType<wf.PlaceholderItem>(), hasLength(1));

    final worker = await GPUTextWorker.spawn();
    try {
      await worker.registerFont('lato', bytes);
      await worker.prepareDoc('ph', specs);
      final d = await worker.reflowDoc('ph', 320);
      expect(d.placeholders, hasLength(1));
      final box = d.placeholders.single;
      expect(box.index, 7);
      expect(box.width, 40);
      expect(box.height, 24);
      expect(box.left, greaterThan(0), reason: 'sits after "before "');
      expect(box.top, greaterThanOrEqualTo(0));
      expect(d.glyphCount, greaterThan(0));
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('buildRunItems falls back to a covering font for uncovered scripts', () {
    final shaper = loadHarfBuzzShaper();
    final lato = GPUFont.parse(
      File('assets/Lato-Regular.ttf').readAsBytesSync(),
    );
    final cjk = GPUFont.parse(
      File('../../example/assets/NotoSansSC-subset.ttf').readAsBytesSync(),
    );
    // A codepoint the CJK font covers but Lato doesn't.
    int? probe;
    for (var cp = 0x4E00; cp < 0xA000; cp++) {
      if (cjk.hasGlyphForRune(cp) && !lato.hasGlyphForRune(cp)) {
        probe = cp;
        break;
      }
    }
    expect(probe, isNotNull, reason: 'subset should cover CJK that Lato lacks');

    final specs = <GPUInlineSpec>[
      GPUTextRunSpec(
        text: 'Hi ${String.fromCharCode(probe!)}!',
        fontId: 'lato',
        fontSizePx: 18,
        color: const [0, 0, 0, 1],
      ),
    ];
    final fonts = {'lato': lato, 'cjk': cjk};

    // No fallback: the whole run shapes with Lato (CJK char -> .notdef).
    final noFb = buildRunItems(specs, fonts, shaper).whereType<wf.TextRun>();
    expect(noFb.every((r) => identical(r.font, lato)), isTrue);

    // With fallback: Latin stays Lato, the CJK slice routes to the CJK font.
    final withFb = buildRunItems(specs, fonts, shaper, fallbackFontIds: ['cjk'])
        .whereType<wf.TextRun>();
    expect(withFb.any((r) => identical(r.font, lato)), isTrue,
        reason: 'Latin slice keeps the primary font');
    expect(withFb.any((r) => identical(r.font, cjk)), isTrue,
        reason: 'uncovered CJK slice routes to the fallback');
  });

  test('worker renders COLR color emoji as coloured coverage layers', () async {
    final shaper = loadHarfBuzzShaper();
    final latoBytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    final emojiBytes =
        File('../../example/assets/TwemojiMozilla.ttf').readAsBytesSync();
    final emojiFont = GPUFont.parse(emojiBytes);
    if (!emojiFont.hasColorGlyphs) {
      markTestSkipped('emoji font has no COLR table');
      return;
    }

    final specs = <GPUInlineSpec>[
      const GPUTextRunSpec(
        text: 'A😀B',
        fontId: 'lato',
        fontSizePx: 24,
        color: [0, 0, 0, 1],
      ),
    ];
    final fonts = {'lato': GPUFont.parse(latoBytes), 'emoji': emojiFont};

    // No emoji font → the cluster stays plain text (tofu), no EmojiItem.
    final noEmoji = buildRunItems(specs, fonts, shaper);
    expect(noEmoji.whereType<wf.EmojiItem>(), isEmpty);

    // With one → the cluster resolves to a COLR item carrying colour layers.
    final withEmoji = buildRunItems(specs, fonts, shaper, emojiFontId: 'emoji');
    final emojiItems = withEmoji.whereType<wf.EmojiItem>().toList();
    expect(emojiItems, hasLength(1));
    expect(emojiItems.single.layers, isNotEmpty,
        reason: 'COLR glyph must have colour layers');

    // End-to-end: the drawable includes the emoji's coverage layers.
    final worker = await GPUTextWorker.spawn();
    try {
      await worker.registerFont('lato', latoBytes);
      await worker.registerFont('emoji', emojiBytes);
      await worker.prepareDoc('e', specs, emojiFontId: 'emoji');
      final d = await worker.reflowDoc('e', 300);
      expect(d.glyphCount, greaterThan(2), reason: 'A + B + >=1 emoji layer');
      expect(d.materializeCurves().isNotEmpty, isTrue);
    } finally {
      worker.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
