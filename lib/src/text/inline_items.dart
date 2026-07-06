// Inline content model shared by the paragraph engine and the prepared-text
// pipeline: styled text runs, native color-emoji clusters, and embedded
// widget placeholders. Moved out of paragraph.dart so text/prepare.dart can
// depend on the item types without an import cycle; paragraph.dart
// re-exports everything here, so `wf.TextRun` etc. keep working.
//
// This file stays VM-pure (no dart:ui / Flutter imports).

import '../font.dart';

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
  const TextRun({
    required this.text,
    required this.font,
    required this.fontSizePx,
    required this.color,
    this.letterSpacingPx = 0,
    this.wordSpacingPx = 0,
    this.height,
    this.decoration,
    this.fillRule = FillRule.nonzero,
    this.source,
  });

  final String text;
  final WindfoilFont font;
  final double fontSizePx;
  final List<double> color;
  final double letterSpacingPx;
  final double wordSpacingPx;

  /// Line-height multiplier (TextStyle.height semantics): when set, the run
  /// contributes height*fontSizePx of line extent, distributed between
  /// ascent and descent proportionally to the font's natural metrics.
  final double? height;

  final InlineDecoration? decoration;
  final FillRule fillRule;

  /// Opaque origin marker (the source TextSpan) so hit-testing can map a
  /// glyph position back to its span (recognizers). Never inspected here.
  final Object? source;
}

/// A native color-emoji cluster: one advance, N stacked COLR layer glyphs
/// each with its palette color (null → the surrounding text color).
class EmojiItem extends InlineItem {
  const EmojiItem({
    required this.font,
    required this.fontSizePx,
    required this.advanceUnits,
    required this.layers,
    this.textColor = const [0, 0, 0, 1],
    this.source,
  });

  final WindfoilFont font;
  final double fontSizePx;
  final double advanceUnits; // font units
  final List<ColrLayer> layers;
  final List<double> textColor;
  final Object? source;

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
