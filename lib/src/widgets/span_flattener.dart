// Flatten an InlineSpan tree into windfoil inline items, applying the
// TextStyle inheritance cascade the way RenderParagraph does (child style
// merges over parent). PlaceholderSpans (WidgetSpan) become PlaceholderItems
// whose dimensions come from the render object's child layout; the preorder
// placeholder index matches WidgetSpan.extractFromInlineSpan child order.

import 'package:flutter/painting.dart';
import 'dart:ui' as ui show PlaceholderAlignment;

import '../engine/engine.dart';
import '../font.dart' show WindfoilFont, isZeroWidthCodePoint;
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

wf.InlineDecoration? _mapDecoration(TextStyle? style) {
  final deco = style?.decoration;
  if (deco == null || deco == TextDecoration.none) return null;
  final dc = style?.decorationColor;
  return wf.InlineDecoration(
    underline: deco.contains(TextDecoration.underline),
    overline: deco.contains(TextDecoration.overline),
    lineThrough: deco.contains(TextDecoration.lineThrough),
    color: dc == null ? null : [dc.r, dc.g, dc.b, dc.a],
    style: switch (style?.decorationStyle) {
      TextDecorationStyle.double => wf.InlineDecorationStyle.doubleLine,
      TextDecorationStyle.dotted => wf.InlineDecorationStyle.dotted,
      TextDecorationStyle.dashed => wf.InlineDecorationStyle.dashed,
      TextDecorationStyle.wavy => wf.InlineDecorationStyle.wavy,
      TextDecorationStyle.solid || null => wf.InlineDecorationStyle.solid,
    },
    thickness: style?.decorationThickness ?? 1,
  );
}

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
        final primary = engine.resolveFont(
          style?.fontFamily,
          weight: style?.fontWeight,
          fontStyle: style?.fontStyle,
        );
        if (primary == null) {
          missingFont = true;
          return;
        }
        final families = <String?>[
          style?.fontFamily,
          ...?style?.fontFamilyFallback,
        ];
        final color = style?.color ?? const Color(0xFF000000);

        wf.TextRun makeRun(String subText, WindfoilFont font) => wf.TextRun(
              text: subText,
              font: font,
              fontSizePx: textScaler.scale(style?.fontSize ?? 14.0),
              color: [color.r, color.g, color.b, color.a],
              letterSpacingPx: style?.letterSpacing ?? 0,
              wordSpacingPx: style?.wordSpacing ?? 0,
              height: style?.height,
              decoration: _mapDecoration(style),
            );

        // Per-character font fallback: split the text into same-font
        // subruns. Whitespace and zero-width characters stay with the
        // surrounding font; uncovered characters keep the primary font
        // (.notdef) — build-time expansion delegates those to the platform.
        final sub = StringBuffer();
        var current = primary;
        void flushSub() {
          if (sub.isEmpty) return;
          items.add(makeRun(sub.toString(), current));
          sub.clear();
        }

        for (final rune in text.runes) {
          var target = current;
          if (!isZeroWidthCodePoint(rune) &&
              rune != 0x20 &&
              rune != 0x0A) {
            final ch = String.fromCharCode(rune);
            target = primary.hasGlyph(ch)
                ? primary
                : (engine.resolveFontForChar(
                      ch,
                      families: families,
                      weight: style?.fontWeight,
                      fontStyle: style?.fontStyle,
                    ) ??
                    primary);
          }
          if (!identical(target, current)) {
            flushSub();
            current = target;
          }
          sub.writeCharCode(rune);
        }
        flushSub();
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
