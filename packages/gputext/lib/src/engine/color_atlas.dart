// The raster half of the glyph atlas: a shelf-packed RGBA8 page holding
// decoded color-bitmap glyphs (emoji PNGs from sbix / CBDT). Parallel to
// SharedGlyphAtlas (which holds monochrome outline curves), but the pixels are
// sampled with bilinear filtering by a separate color pipeline rather than
// integrated as coverage.
//
// Design notes (see the bitmap-support plan):
//   * Keyed by (font, glyphId, strikePpem) — every requested font size that
//     resolves to the same strike shares one decoded entry, so a paragraph
//     that shows 😀 at 14/18/24px decodes it once.
//   * String keys via [ensureBytes]/[lookupKey] support the isolate path, where
//     the main isolate packs PNGs without a local GPUFont.
//   * Fixed-size page (colorAtlasWidth × colorAtlasHeight) so normalized UVs
//     never shift as the atlas fills — emitted instances bake UVs in, and a
//     growing page would invalidate them. Overflow falls back to platform
//     delegation rather than evicting (paging/LRU is a documented follow-on).
//   * PREMULTIPLIED RGBA is stored (the codec gives straight alpha; we
//     premultiply on blit). This is what lets the uploader box-filter mip
//     levels without dark/colored halos, and the color shader samples it
//     directly into the premultiplied blend. The per-instance tint is a scalar
//     opacity replicated across all four channels.
//   * PNG decode is async (ui codec, off the main isolate). ensure() is
//     idempotent and de-duplicates in-flight decodes; a new entry bumps
//     [generation] so the caller re-renders (same pattern as font-load ready).

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../color_bitmap.dart';
import '../font.dart';

const colorAtlasWidth = 2048;
const colorAtlasHeight = 2048;

/// Mip levels the color atlas texture carries (level 0 + this many reductions).
/// Trilinear sampling across them keeps heavily-minified emoji — e.g. a
/// single-strike CBDT font at ~109px drawn at 16px — from aliasing.
const colorAtlasMipLevels = 4;

/// Transparent gutter between packed glyphs. Sized to the mip depth so a coarse
/// level's box filter never folds a neighbour into a glyph's edge texels
/// (bilinear at level L reads a 2^L block; a gutter of 2^(levels−1) covers it).
const _gutter = 1 << (colorAtlasMipLevels - 1);

/// One packed color-bitmap glyph: its pixel rect in the page plus the
/// normalized UV rect the color shader samples.
class ColorAtlasEntry {
  const ColorAtlasEntry({
    required this.px,
    required this.py,
    required this.width,
    required this.height,
    required this.u0,
    required this.v0,
    required this.u1,
    required this.v1,
    required this.ppem,
    required this.bearingX,
    required this.bearingY,
  });

  final int px; // top-left in page pixels
  final int py;
  final int width; // decoded glyph pixel dimensions
  final int height;
  final double u0; // normalized UV rect (page-relative)
  final double v0;
  final double u1;
  final double v1;

  /// Placement (strike-pixel space; divide by [ppem] for em), so the emit layer
  /// positions the quad relative to the pen origin / baseline.
  final int ppem;
  final double bearingX; // px, origin → left edge (x-right)
  final double bearingY; // px, baseline → top edge (y-up)
}

/// Process-wide color-bitmap atlas. Holds one RGBA8 page shared by every font
/// and widget, mirroring [SharedGlyphAtlas]'s role for outlines.
class SharedColorAtlas {
  final Uint8List _pixels = Uint8List(colorAtlasWidth * colorAtlasHeight * 4);
  final _entries = <(GPUFont, int, int), ColorAtlasEntry>{};
  // Isolate / stub path: keyed by opaque string (e.g. "emoji:123:109").
  final _keyEntries = <String, ColorAtlasEntry>{};
  // In-flight decodes, so two paragraphs asking for the same glyph in one
  // frame don't both decode and double-pack it.
  final _pending = <(GPUFont, int, int)>{};
  final _keyPending = <String>{};

  // Shelf packer cursor.
  int _shelfX = 0;
  int _shelfY = 0;
  int _shelfH = 0;
  var _full = false;
  var _generation = 0;

  /// Bumped whenever a new glyph is packed — the texture uploader re-uploads
  /// and paragraphs re-emit/re-render when they see it change.
  int get generation => _generation;

  bool get isEmpty => _entries.isEmpty && _keyEntries.isEmpty;

  /// Straight-RGBA page bytes for the texture uploader (do not mutate).
  Uint8List get pixels => _pixels;

  /// True once the page filled and further glyphs are being turned away.
  bool get isFull => _full;

  ColorAtlasEntry? lookup(GPUFont font, int glyphId, int strikePpem) =>
      _entries[(font, glyphId, strikePpem)];

  /// Lookup a glyph packed via [ensureBytes] (isolate / stub path).
  ColorAtlasEntry? lookupKey(String key) => _keyEntries[key];

  /// The strike [ensure]/[lookup] resolve for [targetPpem] on [font]; null when
  /// the font has no bitmap glyph source. Callers use it to build the same key.
  int? strikeFor(GPUFont font, double targetPpem) =>
      font.bitmapStrikeFor(targetPpem);

  /// Decode and pack [glyphId] from [font] at the strike nearest [targetPpem]
  /// if not already present. Returns the strike ppem that was (or already is)
  /// packed, or null when the glyph has no usable bitmap / the page is full.
  ///
  /// Idempotent: a glyph already present or mid-decode returns without work.
  /// The boolean side effect callers care about is [generation] changing.
  Future<int?> ensure(GPUFont font, int glyphId, double targetPpem) async {
    final glyph = font.bitmapGlyphForId(glyphId, targetPpem: targetPpem);
    if (glyph == null || !glyph.isPng) return null;
    final key = (font, glyphId, glyph.ppem);
    if (_entries.containsKey(key)) return glyph.ppem;
    if (_full || _pending.contains(key)) return null;
    _pending.add(key);
    try {
      final decoded = await _decode(glyph.bytes);
      if (decoded == null) return null;
      if (_entries.containsKey(key)) return glyph.ppem; // raced
      final entry = _pack(decoded.$1, decoded.$2, decoded.$3, glyph);
      if (entry == null) {
        _full = true;
        return null;
      }
      _entries[key] = entry;
      _generation++;
      return glyph.ppem;
    } finally {
      _pending.remove(key);
    }
  }

  /// Decode and pack a [glyph] under an opaque string [key] (no [GPUFont]
  /// required). Used by [GPUTextView] after a worker reflow ships PNG stubs.
  /// Same idempotency / [generation] contract as [ensure].
  Future<int?> ensureBytes(String key, BitmapGlyph glyph) async {
    if (!glyph.isPng) return null;
    if (_keyEntries.containsKey(key)) return glyph.ppem;
    if (_full || _keyPending.contains(key)) return null;
    _keyPending.add(key);
    try {
      final decoded = await _decode(glyph.bytes);
      if (decoded == null) return null;
      if (_keyEntries.containsKey(key)) return glyph.ppem;
      final entry = _pack(decoded.$1, decoded.$2, decoded.$3, glyph);
      if (entry == null) {
        _full = true;
        return null;
      }
      _keyEntries[key] = entry;
      _generation++;
      return glyph.ppem;
    } finally {
      _keyPending.remove(key);
    }
  }

  /// Decode PNG (or any codec-supported) bytes to straight RGBA8 + dimensions.
  Future<(int width, int height, Uint8List rgba)?> _decode(
    Uint8List bytes,
  ) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width;
      final h = image.height;
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      image.dispose();
      codec.dispose();
      if (data == null) return null;
      return (w, h, data.buffer.asUint8List());
    } catch (_) {
      return null; // undecodable image → delegation fallback
    }
  }

  /// Shelf-pack a w×h glyph, blitting [rgba] into the page. Null when it
  /// cannot fit (page full). [glyph] supplies strike/placement metadata.
  ColorAtlasEntry? _pack(int w, int h, Uint8List rgba, BitmapGlyph glyph) {
    if (w <= 0 || h <= 0 || w > colorAtlasWidth || h > colorAtlasHeight) {
      return null;
    }
    // Advance to a new shelf when the current row can't hold the glyph.
    if (_shelfX + w > colorAtlasWidth) {
      _shelfY += _shelfH + _gutter;
      _shelfX = 0;
      _shelfH = 0;
    }
    if (_shelfY + h > colorAtlasHeight) return null;
    final px = _shelfX;
    final py = _shelfY;
    _blit(px, py, w, h, rgba);
    _shelfX += w + _gutter;
    if (h > _shelfH) _shelfH = h;
    return ColorAtlasEntry(
      px: px,
      py: py,
      width: w,
      height: h,
      u0: px / colorAtlasWidth,
      v0: py / colorAtlasHeight,
      u1: (px + w) / colorAtlasWidth,
      v1: (py + h) / colorAtlasHeight,
      ppem: glyph.ppem,
      bearingX: glyph.bearingX,
      bearingY: glyph.bearingY,
    );
  }

  // Blit straight-alpha [rgba] into the page, premultiplying as we go so mip
  // generation stays halo-free (see the file header).
  void _blit(int px, int py, int w, int h, Uint8List rgba) {
    const stride = colorAtlasWidth * 4;
    for (var row = 0; row < h; row++) {
      var src = row * w * 4;
      var dst = (py + row) * stride + px * 4;
      for (var col = 0; col < w; col++) {
        final a = rgba[src + 3];
        // (v * a + 127) ~/ 255 — rounded premultiply.
        _pixels[dst] = (rgba[src] * a + 127) ~/ 255;
        _pixels[dst + 1] = (rgba[src + 1] * a + 127) ~/ 255;
        _pixels[dst + 2] = (rgba[src + 2] * a + 127) ~/ 255;
        _pixels[dst + 3] = a;
        src += 4;
        dst += 4;
      }
    }
  }
}
