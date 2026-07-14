// Flatten a Flutter InlineSpan / TextSpan tree into sendable specs for the
// low-level isolate layout path.
//
// Runs on the MAIN isolate (it reads Flutter TextStyles); the results are
// plain data that cross to a GPUTextWorker. Each leaf TextSpan with text
// becomes a GPUTextRunSpec carrying its resolved (inherited) style — fontSize,
// colour, letter/word spacing, and OpenType fontFeatures. A fontId is chosen
// by [fontIdResolver] (register those fonts on the worker up front).
//
// A widget's size isn't known to the worker, so inline widgets must declare
// the box to reserve. The ergonomic way is a [GPUWidgetSpan], which carries its
// [GPUWidgetSpan.size] AND its child in one place — [flattenInlineSpan] reads
// the size for the worker and hands the child back through [onWidget]. Plain
// WidgetSpans still work via a [placeholderSize] resolver (their child is
// ignored; you render the real widget yourself, by index). Either way the
// worker reserves the space and returns the laid-out box in
// GPUTextInstances.placeholders. Placeholders with no available size are dropped.

import 'package:flutter/widgets.dart';

import '../text/inline_items.dart' show InlinePlaceholderAlignment;
import 'gpu_text_worker.dart'
    show GPUInlineSpec, GPUPlaceholderSpec, GPUTextRunSpec;

/// An inline widget for the low-level path that bundles the widget with the
/// box to reserve for it. Drop it into any [TextSpan] tree; [GPUTextDocument.rich]
/// collects the [child] automatically and positions it over the GPU text — no
/// separate sizer, builder, or index bookkeeping.
///
/// Pass an explicit [size] for the fast path (no measurement). Omit it and
/// `GPUTextView` measures [child] on the main isolate before layout (one frame
/// slower, and the child must be self-sizing) — a widget can't be measured off
/// the main isolate, so this is a convenience, not free.
class GPUWidgetSpan extends WidgetSpan {
  const GPUWidgetSpan({
    this.size,
    required super.child,
    super.alignment = PlaceholderAlignment.middle,
    super.baseline,
    super.style,
  });

  /// The inline box to reserve, logical px. Null ⇒ measure [child] first.
  final Size? size;
}

/// Return the inline size to reserve for [span] (the nth placeholder, 0-based).
/// Used for plain WidgetSpans; a [GPUWidgetSpan] supplies its own size instead.
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
  void Function(int index, Widget child, Size? explicitSize)? onWidget,
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
    } else if (s is PlaceholderSpan) {
      // A GPUWidgetSpan carries its child and (maybe) its size; a plain
      // WidgetSpan needs the [placeholderSize] resolver. A GPUWidgetSpan with no
      // size gets a provisional zero box here — GPUTextView measures the child
      // and patches it before layout. Placeholders with no size source at all
      // are dropped (and no index is consumed).
      final index = placeholderIndex;
      final explicit = s is GPUWidgetSpan ? s.size : null;
      final size = s is GPUWidgetSpan
          ? (s.size ?? Size.zero)
          : placeholderSize?.call(s, index);
      if (size == null) return;
      placeholderIndex++;
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
      if (s is GPUWidgetSpan) onWidget?.call(index, s.child, explicit);
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
