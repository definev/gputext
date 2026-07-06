// Inline content model shared by the paragraph engine and the prepared-text
// pipeline: styled text runs, native color-emoji clusters, and embedded
// widget placeholders. Moved out of paragraph.dart so text/prepare.dart can
// depend on the item types without an import cycle; paragraph.dart
// re-exports everything here, so `wf.TextRun` etc. keep working.
//
// This file stays VM-pure (no dart:ui / Flutter imports).

import 'dart:typed_data';

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
    this.background,
    this.shadows,
    this.evenLeading,
    this.sourceText,
    this.sourceMap,
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

  /// Highlight color behind the run (TextStyle.backgroundColor), RGBA 0..1.
  final List<double>? background;

  /// Shadows painted under the run's glyphs (TextStyle.shadows).
  final List<InlineShadow>? shadows;

  /// TextStyle.leadingDistribution: true → the height multiplier's extra
  /// leading splits evenly above/below instead of proportionally; null →
  /// the paragraph default.
  final bool? evenLeading;

  /// The pre-shaping source characters this run renders, when they differ
  /// from [text] (GSUB substitution minted PUA proxies); null → [text] IS
  /// the source. Selection offsets and copied content use this.
  final String? sourceText;

  /// Cluster map: [sourceMap]`[i]` = offset in [originalText] of the i-th
  /// UTF-16 boundary of [text] (length text.length+1, monotonic). Null →
  /// identity.
  final Int32List? sourceMap;

  /// The characters selection sees and copy produces.
  String get originalText => sourceText ?? text;

  /// Boundary map from shaped [text] offsets to [originalText] offsets.
  int sourceOffsetAt(int shapedOffset) {
    final map = sourceMap;
    if (map == null) return shapedOffset;
    if (shapedOffset < 0) return 0;
    return map[shapedOffset < map.length ? shapedOffset : map.length - 1];
  }

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
    this.background,
    this.sourceText,
    this.source,
  });

  /// The emoji character(s) this cluster renders; selection/copy content.
  /// Falls back to the object-replacement character when unset.
  final String? sourceText;

  String get originalText => sourceText ?? '￼';

  final WindfoilFont font;
  final double fontSizePx;
  final double advanceUnits; // font units
  final List<ColrLayer> layers;
  final List<double> textColor;

  /// Highlight color behind the cluster, RGBA 0..1.
  final List<double>? background;

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
