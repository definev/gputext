// Color-bitmap glyph parsing (sbix + CBDT/CBLC). Pure-Dart, no GPU — runs
// under plain `flutter test`. Fonts are the HarfBuzz test corpus vendored under
// third_party/, so these assert against real byte layouts, not synthetic ones.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/src/font.dart';

const _sbixPath = 'third_party/harfbuzz/test/fuzzing/fonts/sbix.ttf';
const _cbdtPath =
    'third_party/harfbuzz/test/api/fonts/NotoColorEmoji.subset.default.39.ttf';
const _latoPath = 'assets/Lato-Regular.ttf';

// `flutter test` may run with cwd at the package dir (direct) or the pub
// workspace root (melos) — resolve against whichever prefix has the file.
File _resolve(String path) {
  for (final prefix in const ['', 'packages/gputext/']) {
    final f = File('$prefix$path');
    if (f.existsSync()) return f;
  }
  throw StateError('font not found from cwd ${Directory.current.path}: $path');
}

GPUFont _load(String path) => GPUFont.parse(_resolve(path).readAsBytesSync());

bool _isPngSig(List<int> b) =>
    b.length >= 4 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47;

void main() {
  group('sbix (Apple-style raster strikes)', () {
    late GPUFont font;
    setUpAll(() => font = _load(_sbixPath));

    test('detected as bitmap, not COLR', () {
      expect(font.hasBitmapGlyphs, isTrue);
      expect(font.hasColorGlyphs, isFalse);
      // The test font ships strikes 20..1024.
      expect(font.bitmapStrikePpems, contains(20));
      expect(font.bitmapStrikePpems, contains(1024));
      // Ascending.
      final p = font.bitmapStrikePpems;
      for (var i = 1; i < p.length; i++) {
        expect(p[i], greaterThan(p[i - 1]));
      }
    });

    test('glyph resolves to a PNG at the chosen strike', () {
      final g = font.bitmapGlyphForId(1, targetPpem: 32);
      expect(g, isNotNull);
      expect(g!.ppem, 32); // exact strike present
      expect(g.isPng, isTrue);
      expect(g.width, greaterThan(0));
      expect(g.height, greaterThan(0));
      expect(_isPngSig(g.bytes), isTrue);
      // sbix carries no advance — emit uses the shaped advance.
      expect(g.advance, 0);
    });

    test('strike selection: smallest ≥ target, else largest', () {
      expect(font.bitmapStrikeFor(30), 32); // 20 < 30 ≤ 32
      expect(font.bitmapStrikeFor(20), 20); // exact
      expect(font.bitmapStrikeFor(5000), 1024); // beyond largest → largest
    });

    test('out-of-range / absent glyph → null', () {
      expect(font.bitmapGlyphForId(9999, targetPpem: 32), isNull);
      expect(font.bitmapGlyphForId(-1, targetPpem: 32), isNull);
    });
  });

  group('CBDT/CBLC (Noto-style embedded PNG)', () {
    late GPUFont font;
    setUpAll(() => font = _load(_cbdtPath));

    test('detected as bitmap; parses despite missing glyf/loca', () {
      expect(font.hasBitmapGlyphs, isTrue);
      // CBDT-only font has no outlines — the outline path must degrade to null,
      // not throw, and parsing must have succeeded to get here.
      expect(font.glyphOutlineById(1), isNull);
    });

    test('glyph 1 → 136×128 PNG at ppem 109, bearing (0,101)', () {
      final g = font.bitmapGlyphForId(1, targetPpem: 100);
      expect(g, isNotNull);
      expect(g!.ppem, 109);
      expect(g.width, 136);
      expect(g.height, 128);
      expect(g.bearingX, 0);
      expect(g.bearingY, 101);
      expect(g.advance, 136);
      expect(g.isPng, isTrue);
      expect(_isPngSig(g.bytes), isTrue);
    });
  });

  group('outline-only font', () {
    test('Lato has no bitmap glyphs', () {
      final font = _load(_latoPath);
      expect(font.hasBitmapGlyphs, isFalse);
      expect(font.bitmapStrikePpems, isEmpty);
      expect(font.bitmapGlyphForId(1, targetPpem: 32), isNull);
    });
  });
}
