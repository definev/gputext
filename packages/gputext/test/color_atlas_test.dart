// SharedColorAtlas: decode + shelf-pack of real emoji PNGs pulled straight from
// the sbix / CBDT parsers (Phase 1 → Phase 2 end to end). Uses dart:ui image
// decode, which works under flutter_test; no GPU/Impeller needed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/src/engine/color_atlas.dart';
import 'package:gputext/src/font.dart';

File _resolve(String path) {
  for (final prefix in const ['', 'packages/gputext/']) {
    final f = File('$prefix$path');
    if (f.existsSync()) return f;
  }
  throw StateError('font not found from ${Directory.current.path}: $path');
}

GPUFont _load(String path) => GPUFont.parse(_resolve(path).readAsBytesSync());

const _sbixPath = 'third_party/harfbuzz/test/fuzzing/fonts/sbix.ttf';
const _cbdtPath =
    'third_party/harfbuzz/test/api/fonts/NotoColorEmoji.subset.default.39.ttf';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CBDT glyph decodes + packs; entry dims and UVs are sane', () async {
    final font = _load(_cbdtPath);
    final atlas = SharedColorAtlas();
    expect(atlas.isEmpty, isTrue);

    final ppem = await atlas.ensure(font, 1, 100);
    expect(ppem, 109); // resolved strike
    expect(atlas.generation, 1);

    final e = atlas.lookup(font, 1, 109);
    expect(e, isNotNull);
    expect(e!.width, 136);
    expect(e.height, 128);
    // UVs inside the page, forming a positive rect.
    expect(e.u0, inInclusiveRange(0.0, 1.0));
    expect(e.v0, inInclusiveRange(0.0, 1.0));
    expect(e.u1, greaterThan(e.u0));
    expect(e.v1, greaterThan(e.v0));

    // The blitted region has real ink: at least one non-zero alpha byte.
    var anyAlpha = false;
    for (var row = 0; row < e.height && !anyAlpha; row++) {
      for (var col = 0; col < e.width; col++) {
        final a =
            atlas.pixels[((e.py + row) * colorAtlasWidth + e.px + col) * 4 + 3];
        if (a != 0) {
          anyAlpha = true;
          break;
        }
      }
    }
    expect(anyAlpha, isTrue, reason: 'decoded emoji should have opaque pixels');
  });

  test('ensure is idempotent (no re-pack, no generation churn)', () async {
    final font = _load(_cbdtPath);
    final atlas = SharedColorAtlas();
    await atlas.ensure(font, 1, 100);
    final gen = atlas.generation;
    await atlas.ensure(font, 1, 100); // same glyph, same strike
    expect(atlas.generation, gen);
  });

  test('sbix glyphs pack onto shelves at distinct positions', () async {
    final font = _load(_sbixPath);
    final atlas = SharedColorAtlas();
    final p1 = await atlas.ensure(font, 1, 32);
    final p2 = await atlas.ensure(font, 2, 32);
    expect(p1, 32);
    expect(p2, 32);
    final e1 = atlas.lookup(font, 1, 32)!;
    final e2 = atlas.lookup(font, 2, 32)!;
    // Second glyph is placed after the first on the same shelf (or a new one),
    // never overlapping the first's origin.
    expect(e1.px == e2.px && e1.py == e2.py, isFalse);
    expect(atlas.generation, 2);
  });

  test(
    'different requested sizes resolving to one strike share an entry',
    () async {
      final font = _load(_sbixPath);
      final atlas = SharedColorAtlas();
      // 30 and 20 both bucket differently (32 vs 20), but 25 and 30 both → 32.
      final a = await atlas.ensure(font, 1, 25); // → strike 32
      final b = await atlas.ensure(font, 1, 30); // → strike 32, already packed
      expect(a, 32);
      expect(b, 32);
      expect(atlas.generation, 1); // packed once
    },
  );

  test(
    'ensureBytes packs under a string key without GPUFont identity',
    () async {
      final font = _load(_cbdtPath);
      final glyph = font.bitmapGlyphForId(1, targetPpem: 100);
      expect(glyph, isNotNull);
      final atlas = SharedColorAtlas();
      const key = 'emoji:1:109';
      final ppem = await atlas.ensureBytes(key, glyph!);
      expect(ppem, 109);
      expect(atlas.lookupKey(key), isNotNull);
      expect(atlas.lookupKey(key)!.width, greaterThan(0));
      // Idempotent under the same key.
      final gen = atlas.generation;
      await atlas.ensureBytes(key, glyph);
      expect(atlas.generation, gen);
    },
  );
}
