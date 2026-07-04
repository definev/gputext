// Flatten an InlineSpan tree into windfoil inline items, applying the
// TextStyle inheritance cascade the way RenderParagraph does (child style
// merges over parent). PlaceholderSpans (WidgetSpan) become PlaceholderItems
// whose dimensions come from the render object's child layout; the preorder
// placeholder index matches WidgetSpan.extractFromInlineSpan child order.

import 'package:flutter/painting.dart';
import 'dart:ui' as ui show PlaceholderAlignment;

import '../engine/engine.dart';
import '../paragraph.dart' as wf;

wf.InlinePlaceholderAlignment _mapAlignment(ui.PlaceholderAlignment a) =>
    switch (a) {
      ui.PlaceholderAlignment.baseline =>
        wf.InlinePlaceholderAlignment.baseline,
      ui.PlaceholderAlignment.aboveBaseline =>
        wf.InlinePlaceholderAlignment.aboveBaseline,
      ui.PlaceholderAlignment.belowBaseline =>
        wf.InlinePlaceholderAlignment.belowBaseline,
      ui.PlaceholderAlignment.top => wf.InlinePlaceholderAlignment.top,
      ui.PlaceholderAlignment.middle => wf.InlinePlaceholderAlignment.middle,
      ui.PlaceholderAlignment.bottom => wf.InlinePlaceholderAlignment.bottom,
    };

/// Returns null while a required font family is not registered yet (engine
/// fonts still loading) — callers lay out empty and retry on engine notify.
///
/// `placeholderDimensions[i]` supplies the size/baseline of the i-th
/// placeholder (preorder). Missing entries fall back to zero size.
List<wf.InlineItem>? flattenSpan(
  InlineSpan span,
  TextScaler textScaler,
  WindfoilEngine engine, {
  List<PlaceholderDimensions> placeholderDimensions = const [],
}) {
  final items = <wf.InlineItem>[];
  var missingFont = false;
  var placeholderIndex = 0;

  void walk(InlineSpan s, TextStyle? inherited) {
    if (missingFont) return;
    final style = s.style == null
        ? inherited
        : (inherited?.merge(s.style) ?? s.style);
    if (s is TextSpan) {
      final text = s.text;
      if (text != null && text.isNotEmpty) {
        final font = engine.resolveFont(style?.fontFamily);
        if (font == null) {
          missingFont = true;
          return;
        }
        final color = style?.color ?? const Color(0xFF000000);
        items.add(wf.TextRun(
          text: text,
          font: font,
          fontSizePx: textScaler.scale(style?.fontSize ?? 14.0),
          color: [color.r, color.g, color.b, color.a],
          letterSpacingPx: style?.letterSpacing ?? 0,
        ));
      }
      final children = s.children;
      if (children != null) {
        for (final child in children) {
          walk(child, style);
        }
      }
    } else if (s is PlaceholderSpan) {
      final index = placeholderIndex++;
      final dims = index < placeholderDimensions.length
          ? placeholderDimensions[index]
          : PlaceholderDimensions.empty;
      items.add(wf.PlaceholderItem(
        index: index,
        width: dims.size.width,
        height: dims.size.height,
        alignment: _mapAlignment(s.alignment),
        baselineOffset: dims.baselineOffset,
      ));
    } else {
      assert(
        false,
        'WindfoilRichText does not support ${s.runtimeType}; '
        'the span will be skipped.',
      );
    }
  }

  walk(span, null);
  return missingFont ? null : items;
}
