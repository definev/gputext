// Text shaping seam: VM-pure request API with a HarfBuzz FFI adapter
// (see harfbuzz_shaper.dart). Layout/paint consume [ShapedGlyphRun] only.

import '../font.dart';
import 'shaped_run.dart';

/// Inputs for [TextShaper.shape].
class ShapeRequest {
  const ShapeRequest({
    required this.font,
    required this.text,
    required this.fontSizePx,
    this.features = const {},
    this.defaultLigatures = true,
    this.direction = TextDirection.ltr,
    this.bidiLevel = 0,
    this.script,
    this.language,
  });

  final GPUFont font;
  final String text;
  final double fontSizePx;
  final Map<String, int> features;
  final bool defaultLigatures;
  final TextDirection direction;
  final int bidiLevel;

  /// OpenType script tag (e.g. 'arab'); null → auto/default.
  final String? script;

  /// BCP-47 / OpenType language; null → default.
  final String? language;
}

/// Produces [ShapedGlyphRun]s from source text + font.
abstract class TextShaper {
  const TextShaper();

  ShapedGlyphRun shape(ShapeRequest request);

  /// Extract [font]'s outline for glyph [gid] as glyf-compatible quads (flat
  /// stride-6, Y-down, cubics flattened to quadratics) — the same
  /// representation [GPUFont.glyphOutlineById] produces from its own parser.
  /// Works for glyf, CFF, CFF2, CID, and variable outlines uniformly. Returns
  /// null when the shaper has no outline backend (caller falls back to the
  /// pure-Dart parser); an empty list means the glyph has no outline.
  List<double>? drawGlyphOutline(GPUFont font, int gid) => null;

  /// Drop any native resources cached for [font] (HarfBuzz face/font).
  /// No-op for shapers without native state.
  void evictFont(GPUFont font) {}

  /// Drop all native face/font caches. No-op for shapers without native state.
  void evictAllFonts() {}
}
