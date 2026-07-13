import 'bands.dart';
import 'font.dart';

const floatsPerInstance = 16;

/// Floats per color-bitmap (emoji) instance: rect(4) + uv(4) + tint(4). Matches
/// GPUTextPipeline.colorInstanceStride (48 bytes) and gputext_color.vert.
const floatsPerColorInstance = 12;

/// A resolved color-bitmap glyph's atlas UV rect + placement, as the emit layer
/// needs it. VM-pure mirror of the engine's ColorAtlasEntry so paragraph.dart
/// stays free of dart:ui. Placement is strike-pixel space (divide by [ppem]).
class ColorGlyphPlacement {
  const ColorGlyphPlacement({
    required this.u0,
    required this.v0,
    required this.u1,
    required this.v1,
    required this.width,
    required this.height,
    required this.ppem,
    required this.bearingX,
    required this.bearingY,
  });

  final double u0;
  final double v0;
  final double u1;
  final double v1;
  final int width; // decoded image px
  final int height;
  final int ppem;
  final double bearingX; // px, origin → left edge
  final double bearingY; // px, baseline → top edge (y-up)
}

/// Resolve a decoded+packed color-bitmap glyph for the emit layer, or null when
/// it isn't in the atlas yet (a re-render follows once the async decode lands).
typedef ColorGlyphLookup = ColorGlyphPlacement? Function(
  GPUFont font,
  int glyphId,
  double targetPpem,
);

double measureText(String text, GPUFont font, double fontSizePx) {
  final scale = fontSizePx / font.unitsPerEm;
  var w = 0.0;
  String? prev;
  for (final rune in text.runes) {
    if (isZeroWidthCodePoint(rune)) continue;
    final ch = String.fromCharCode(rune);
    if (prev != null) w += font.kerningOf(prev, ch) * scale;
    w += font.advanceOf(ch) * scale;
    prev = ch;
  }
  return w;
}

double layoutLine(
  List<double> out,
  String text,
  Map<String, GlyphTableEntry> table,
  GPUFont font, {
  required double x,
  required double baselineY,
  required double fontSizePx,
  required List<double> color,
  FillRule fillRule = FillRule.nonzero,
}) {
  final scale = fontSizePx / font.unitsPerEm;
  final rule = fillRule == FillRule.evenOdd ? 1.0 : 0.0;
  final r = color[0];
  final g = color[1];
  final b = color[2];
  final a = color.length > 3 ? color[3] : 1.0;
  var pen = x;
  String? prev;

  for (final rune in text.runes) {
    if (isZeroWidthCodePoint(rune)) continue;
    final ch = String.fromCharCode(rune);
    if (prev != null) pen += font.kerningOf(prev, ch) * scale;
    final gl = table[ch];
    if (gl != null) {
      out.addAll([
        pen,
        baselineY,
        scale,
        rule,
        gl.bbox[0],
        gl.bbox[1],
        gl.bbox[2],
        gl.bbox[3],
        r,
        g,
        b,
        a,
        gl.rowBase.toDouble(),
        gl.bandCount.toDouble(),
        gl.y0,
        gl.invH,
      ]);
    }
    pen += font.advanceOf(ch) * scale;
    prev = ch;
  }
  return pen;
}

class LayoutBounds {
  const LayoutBounds({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });

  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
}

class LayoutResult {
  const LayoutResult({required this.instances, required this.bounds});

  final List<double> instances;
  final LayoutBounds bounds;
}

class SizedLine {
  const SizedLine({required this.text, required this.size});

  final String text;
  final double size;
}

LayoutResult layoutStack(
  List<SizedLine> lines,
  Map<String, GlyphTableEntry> table,
  GPUFont font, {
  required double x,
  required double top,
  required List<double> color,
  FillRule fillRule = FillRule.nonzero,
}) {
  final instances = <double>[];
  var maxWidth = 0.0;
  var y = top;
  for (final line in lines) {
    final inkAbove = 0.56 * line.size;
    final inkBelow = 0.28 * line.size;
    final gap = 0.34 * line.size;
    final baselineY = y + inkAbove;
    layoutLine(
      instances,
      line.text,
      table,
      font,
      x: x,
      baselineY: baselineY,
      fontSizePx: line.size,
      color: color,
      fillRule: fillRule,
    );
    final w = measureText(line.text, font, line.size);
    if (w > maxWidth) maxWidth = w;
    y = baselineY + inkBelow + gap;
  }
  final bottom = y - 0.34 * lines.last.size;
  return LayoutResult(
    instances: instances,
    bounds: LayoutBounds(minX: x, minY: top, maxX: x + maxWidth, maxY: bottom),
  );
}
