// Flatten a Flutter InlineSpan / TextSpan tree into sendable specs for the
// low-level isolate layout path.
//
// Runs on the MAIN isolate (it reads Flutter TextStyles); the results are
// plain data that cross to a GPUTextWorker. Each leaf TextSpan with text
// becomes a GPUTextRunSpec carrying its resolved (inherited) style — fontSize,
// colour, letter/word spacing, and OpenType fontFeatures. A fontId is chosen
// by [fontIdResolver] (register those fonts on the worker up front).
//
// WidgetSpans (PlaceholderSpans) become GPUPlaceholderSpecs when you pass
// [placeholderSize] — a widget's size isn't known to the worker, so you supply
// it. The worker reserves that space and returns the laid-out box in
// GPUTextInstances.placeholders; you position the real widget there by index.
// Without a [placeholderSize] resolver, placeholders are dropped.

import 'package:flutter/widgets.dart';

import '../text/inline_items.dart' show InlinePlaceholderAlignment;
import 'gpu_text_worker.dart'
    show GPUInlineSpec, GPUPlaceholderSpec, GPUTextRunSpec;

/// Return the inline size to reserve for [span] (the nth placeholder, 0-based).
typedef PlaceholderSizer = Size Function(PlaceholderSpan span, int index);

/// Flatten [span] (with styles inherited from [baseStyle]) into text runs and,
/// when [placeholderSize] is given, widget placeholders — one entry per styled
/// leaf, in reading order.
List<GPUInlineSpec> flattenInlineSpan(
  InlineSpan span, {
  TextStyle? baseStyle,
  required String Function(TextStyle style) fontIdResolver,
  double defaultFontSizePx = 16,
  List<double> defaultColor = const [0, 0, 0, 1],
  PlaceholderSizer? placeholderSize,
}) {
  final out = <GPUInlineSpec>[];
  var placeholderIndex = 0;

  void visit(InlineSpan s, TextStyle inherited) {
    final style = s.style == null ? inherited : inherited.merge(s.style);
    if (s is TextSpan) {
      final text = s.text;
      if (text != null && text.isNotEmpty) {
        out.add(
          GPUTextRunSpec(
            text: text,
            fontId: fontIdResolver(style),
            fontSizePx: style.fontSize ?? defaultFontSizePx,
            color: _rgba(style.color, defaultColor),
            letterSpacingPx: style.letterSpacing ?? 0,
            wordSpacingPx: style.wordSpacing ?? 0,
            features: _features(style.fontFeatures),
          ),
        );
      }
      final children = s.children;
      if (children != null) {
        for (final child in children) {
          visit(child, style);
        }
      }
    } else if (s is PlaceholderSpan && placeholderSize != null) {
      final index = placeholderIndex++;
      final size = placeholderSize(s, index);
      out.add(
        GPUPlaceholderSpec(
          index: index,
          width: size.width,
          height: size.height,
          alignment: _mapAlignment(s.alignment),
          baselineOffset: s.alignment == PlaceholderAlignment.baseline
              ? size.height
              : null,
        ),
      );
    }
  }

  visit(span, baseStyle ?? const TextStyle());
  return out;
}

Map<String, int> _features(List<FontFeature>? fs) =>
    fs == null || fs.isEmpty ? const {} : {for (final f in fs) f.feature: f.value};

List<double> _rgba(Color? c, List<double> fallback) =>
    c == null ? fallback : [c.r, c.g, c.b, c.a];

InlinePlaceholderAlignment _mapAlignment(PlaceholderAlignment a) => switch (a) {
  PlaceholderAlignment.baseline => InlinePlaceholderAlignment.baseline,
  PlaceholderAlignment.aboveBaseline => InlinePlaceholderAlignment.aboveBaseline,
  PlaceholderAlignment.belowBaseline => InlinePlaceholderAlignment.belowBaseline,
  PlaceholderAlignment.top => InlinePlaceholderAlignment.top,
  PlaceholderAlignment.middle => InlinePlaceholderAlignment.middle,
  PlaceholderAlignment.bottom => InlinePlaceholderAlignment.bottom,
};
