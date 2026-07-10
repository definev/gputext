// Text shaping seam: VM-pure API with adapters for legacy GSUB (PUA proxies)
// and HarfBuzz FFI (Phase 1). Layout/paint consume [ShapedGlyphRun] only.

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

  /// Drop any native resources cached for [font] (HarfBuzz face/font).
  /// No-op for shapers without native state.
  void evictFont(GPUFont font) {}

  /// Drop all native face/font caches. No-op for shapers without native state.
  void evictAllFonts() {}
}

/// Adapter over [GPUFontFeatures.applyFeaturesMapped]: keeps Latin/liga
/// behavior identical to the pre-glyph-run pipeline.
class LegacyGsubShaper extends TextShaper {
  const LegacyGsubShaper();

  @override
  ShapedGlyphRun shape(ShapeRequest request) {
    final (pipeline, map) = request.font.applyFeaturesMapped(
      request.text,
      features: request.features,
      defaultLigatures: request.defaultLigatures,
    );
    return ShapedGlyphRun.fromPipelineText(
      font: request.font,
      fontSizePx: request.fontSizePx,
      sourceText: request.text,
      pipelineText: pipeline,
      sourceMap: map,
      bidiLevel: request.bidiLevel,
      direction: request.direction,
      appliesKerning: true,
    );
  }
}
