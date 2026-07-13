// Inline content model shared by the paragraph engine and the prepared-text
// pipeline: styled text runs, native color-emoji clusters, and embedded
// widget placeholders. Moved out of paragraph.dart so text/prepare.dart can
// depend on the item types without an import cycle; paragraph.dart
// re-exports everything here, so `wf.TextRun` etc. keep working.
//
// This file stays VM-pure (no dart:ui / Flutter imports).

import 'dart:typed_data';

import '../font.dart';
import 'shaped_run.dart';

export 'shaped_run.dart'
    show
        ShapedGlyph,
        ShapedGlyphRun,
        TextDirection,
        GlyphWalkStep,
        walkGlyphs,
        shapedWidthUnits;

/// Mirror of ui.TextDecorationStyle (VM-pure).
enum InlineDecorationStyle { solid, doubleLine, dotted, dashed, wavy }

/// Which decoration guides a run draws, and how.
class InlineDecoration {
  const InlineDecoration({
    this.underline = false,
    this.overline = false,
    this.lineThrough = false,
    this.color,
    this.style = InlineDecorationStyle.solid,
    this.thickness = 1,
  });

  final bool underline;
  final bool overline;
  final bool lineThrough;

  /// RGBA 0..1; null → the run's text color.
  final List<double>? color;
  final InlineDecorationStyle style;

  /// Multiplier on the font's decoration thickness.
  final double thickness;

  bool get isActive => underline || overline || lineThrough;
}

/// One text shadow in logical px (mirror of ui.Shadow, VM-pure).
class InlineShadow {
  const InlineShadow({
    this.dx = 0,
    this.dy = 0,
    this.blurRadius = 0,
    required this.color,
  });

  final double dx;
  final double dy;
  final double blurRadius;

  /// RGBA 0..1.
  final List<double> color;
}

/// Mirror of ui.PlaceholderAlignment (kept local so this file has no
/// dart:ui dependency).
enum InlinePlaceholderAlignment {
  baseline,
  aboveBaseline,
  belowBaseline,
  top,
  middle,
  bottom,
}

/// One inline content item: a styled text run or an embedded-widget
/// placeholder.
sealed class InlineItem {
  const InlineItem();
}

class TextRun extends InlineItem {
  TextRun({
    required String text,
    required this.font,
    required this.fontSizePx,
    required this.color,
    this.letterSpacingPx = 0,
    this.wordSpacingPx = 0,
    this.height,
    this.decoration,
    this.fillRule = FillRule.nonzero,
    this.background,
    this.shadows,
    this.evenLeading,
    String? sourceText,
    Int32List? sourceMap,
    this.source,
    ShapedGlyphRun? shaped,
  }) : shaped =
           shaped ??
           ShapedGlyphRun.fromPipelineText(
             font: font,
             fontSizePx: fontSizePx,
             sourceText: sourceText ?? text,
             pipelineText: text,
             sourceMap: sourceMap,
           );

  /// Shaped glyph geometry; advances/paint/selection walk this, not [text].
  final ShapedGlyphRun shaped;

  /// Pipeline (post-shaping) text — used for line-break analysis windows.
  /// Prefer [shaped.pipelineText]; kept as a convenience view.
  String get text => shaped.pipelineText;

  final GPUFont font;
  final double fontSizePx;

  /// RGBA 0..1. Mutable so paint-only span updates can recolor without
  /// reshaping; shared [LineRun]s alias this list until detached.
  List<double> color;
  final double letterSpacingPx;
  final double wordSpacingPx;

  /// Line-height multiplier (TextStyle.height semantics): when set, the run
  /// contributes height*fontSizePx of line extent, distributed between
  /// ascent and descent proportionally to the font's natural metrics.
  final double? height;

  InlineDecoration? decoration;
  final FillRule fillRule;

  /// Highlight behind the run (TextStyle.backgroundColor), RGBA 0..1.
  List<double>? background;

  List<InlineShadow>? shadows;

  /// Height-multiplier leading: true → split evenly; null → paragraph default.
  final bool? evenLeading;

  /// Pre-shaping source characters when they differ from [text].
  String? get sourceText {
    final s = shaped.sourceText;
    return identical(s, shaped.pipelineText) || s == shaped.pipelineText
        ? null
        : s;
  }

  /// Cluster map: shaped→source UTF-16 boundaries; null → identity.
  Int32List? get sourceMap => shaped.sourceMap;

  /// Selection/copy content (pre-shaping characters).
  String get originalText => shaped.sourceText;

  /// Boundary map from shaped [text] offsets to [originalText] offsets.
  int sourceOffsetAt(int shapedOffset) => shaped.sourceOffsetAt(shapedOffset);

  /// Opaque origin marker (source TextSpan) for hit-testing / recognizers.
  Object? source;
}

/// A native color-emoji cluster: one advance, N stacked COLR layer glyphs
/// each with its palette color (null → the surrounding text color).
class EmojiItem extends InlineItem {
  EmojiItem({
    required this.font,
    required this.fontSizePx,
    required this.advanceUnits,
    required this.layers,
    this.textColor = const [0, 0, 0, 1],
    this.background,
    this.sourceText,
    this.source,
  });

  /// Selection/copy content; falls back to U+FFFC when unset.
  final String? sourceText;

  String get originalText => sourceText ?? '￼';

  final GPUFont font;
  final double fontSizePx;
  final double advanceUnits; // font units
  final List<ColrLayer> layers;

  /// Text color for COLR layers using the text palette slot. Mutable for
  /// paint-only updates (see [TextRun.color]).
  List<double> textColor;

  /// Highlight behind the cluster, RGBA 0..1.
  List<double>? background;

  Object? source;

  double get width => advanceUnits / font.unitsPerEm * fontSizePx;
}

/// An inline widget's reserved box: unbreakable, contributes to line metrics
/// per its alignment. `index` is the placeholder's preorder position in the
/// span tree (matches WidgetSpan.extractFromInlineSpan child order).
class PlaceholderItem extends InlineItem {
  const PlaceholderItem({
    required this.index,
    required this.width,
    required this.height,
    required this.alignment,
    this.baselineOffset,
  });

  final int index;
  final double width;
  final double height;
  final InlinePlaceholderAlignment alignment;

  /// Distance from the placeholder's top to its baseline; only meaningful for
  /// [InlinePlaceholderAlignment.baseline] (falls back to height).
  final double? baselineOffset;
}
