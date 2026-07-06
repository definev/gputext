// Flatten an InlineSpan tree into windfoil inline items, applying the
// TextStyle inheritance cascade the way RenderParagraph does (child style
// merges over parent). PlaceholderSpans (WidgetSpan) become PlaceholderItems
// whose dimensions come from the render object's child layout; the preorder
// placeholder index matches WidgetSpan.extractFromInlineSpan child order.

import 'dart:typed_data';
import 'dart:ui' as ui show PlaceholderAlignment;

import 'package:flutter/painting.dart';

import '../engine/engine.dart';
import '../font.dart'
    show
        WindfoilFont,
        WindfoilFontFeatures,
        WindfoilFontVariations,
        isZeroWidthCodePoint;
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

/// Design-space coordinates implied by a style: TextStyle.fontVariations,
/// plus CSS-style fallbacks mapping fontWeight onto 'wght' and italic onto
/// 'ital'/'slnt' when the font exposes those axes. Explicit fontVariations
/// win. Non-variable fonts pass through untouched, so this is safe to apply
/// to any resolved font (variant() ignores unknown axes and clamps ranges).
WindfoilFont _withVariations(WindfoilFont font, TextStyle? style) {
  if (font.variationAxes.isEmpty) return font;
  final coords = <String, double>{};
  final weight = style?.fontWeight;
  if (weight != null) coords['wght'] = weight.value.toDouble();
  if (style?.fontStyle == FontStyle.italic) {
    if (font.hasVariationAxis('ital')) {
      coords['ital'] = 1;
    } else {
      coords['slnt'] = -14; // CSS oblique default; clamped to the axis range
    }
  }
  for (final v in style?.fontVariations ?? const <FontVariation>[]) {
    coords[v.axis] = v.value;
  }
  return font.variant(coords);
}

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
        final resolved = engine.resolveFont(
          style?.fontFamily,
          weight: style?.fontWeight,
          fontStyle: style?.fontStyle,
        );
        if (resolved == null) {
          missingFont = true;
          return;
        }
        final primary = _withVariations(resolved, style);
        final families = <String?>[
          style?.fontFamily,
          ...?style?.fontFamilyFallback,
        ];
        // A foreground Paint's color wins over TextStyle.color (they are
        // mutually exclusive in Flutter); shaders are beyond the instanced
        // renderer and fall back to the paint's flat color.
        final color = style?.foreground?.color ??
            style?.color ??
            const Color(0xFF000000);
        final bg = style?.backgroundColor ?? style?.background?.color;
        final background =
            bg == null ? null : <double>[bg.r, bg.g, bg.b, bg.a];
        final styleShadows = style?.shadows;
        final shadows = styleShadows == null || styleShadows.isEmpty
            ? null
            : [
                for (final sh in styleShadows)
                  wf.InlineShadow(
                    dx: sh.offset.dx,
                    dy: sh.offset.dy,
                    blurRadius: sh.blurRadius,
                    color: [
                      sh.color.r,
                      sh.color.g,
                      sh.color.b,
                      sh.color.a,
                    ],
                  ),
              ];
        final evenLeading = switch (style?.leadingDistribution) {
          TextLeadingDistribution.even => true,
          TextLeadingDistribution.proportional => false,
          null => null,
        };

        wf.TextRun makeRun(String subText, WindfoilFont font,
                String? sourceText, Int32List? sourceMap) =>
            wf.TextRun(
              text: subText,
              font: font,
              fontSizePx: textScaler.scale(style?.fontSize ?? 14.0),
              color: [color.r, color.g, color.b, color.a],
              letterSpacingPx: style?.letterSpacing ?? 0,
              wordSpacingPx: style?.wordSpacing ?? 0,
              height: style?.height,
              decoration: _mapDecoration(style),
              background: background,
              shadows: shadows,
              evenLeading: evenLeading,
              sourceText: sourceText,
              sourceMap: sourceMap,
              source: s,
            );

        // GSUB features (ligatures, tabular figures, stylistic sets, ...)
        // from TextStyle.fontFeatures; tracked-out text drops the default
        // ligature features, the same rule the basic-ligature pass applied.
        // The cluster map ties shaped offsets back to `text` for selection.
        final (ligated, clusterMap) = primary.applyFeaturesMapped(
          text,
          features: {
            for (final f in style?.fontFeatures ?? const <FontFeature>[])
              f.feature: f.value,
          },
          defaultLigatures: (style?.letterSpacing ?? 0) == 0,
        );

        // Per-character font fallback: split the text into same-font
        // subruns. Whitespace and zero-width characters stay with the
        // surrounding font; uncovered characters keep the primary font
        // (.notdef) — build-time expansion delegates those to the platform.
        // Splits happen at shaped-rune boundaries, which are always cluster
        // boundaries, so slicing the map per subrun is safe.
        final sub = StringBuffer();
        var current = primary;
        var shapedPos = 0; // UTF-16 offset in `ligated`
        var subStart = 0; // shaped offset where `sub` began
        void flushSub() {
          if (sub.isEmpty) {
            subStart = shapedPos;
            return;
          }
          final shapedText = sub.toString();
          String? sourceText;
          Int32List? sourceMap;
          if (clusterMap != null) {
            final a = clusterMap[subStart];
            final b = clusterMap[shapedPos];
            final sliced = Int32List(shapedText.length + 1);
            var identity = true;
            for (var i = 0; i <= shapedText.length; i++) {
              sliced[i] = clusterMap[subStart + i] - a;
              if (sliced[i] != i) identity = false;
            }
            if (!identity) {
              sourceText = text.substring(a, b);
              sourceMap = sliced;
            }
          }
          items.add(makeRun(shapedText, current, sourceText, sourceMap));
          sub.clear();
          subStart = shapedPos;
        }

        final emojiFont = engine.emojiFont;
        for (final rune in ligated.runes) {
          final units = rune >= 0x10000 ? 2 : 1;
          // Native color emoji: COLR layers render through the shader.
          if (emojiFont != null && !isZeroWidthCodePoint(rune)) {
            final layers = emojiFont.colrForCodePoint(rune);
            if (layers != null) {
              flushSub();
              items.add(wf.EmojiItem(
                font: emojiFont,
                fontSizePx: textScaler.scale(style?.fontSize ?? 14.0),
                advanceUnits: emojiFont.advanceOf(String.fromCharCode(rune)),
                layers: layers,
                textColor: [color.r, color.g, color.b, color.a],
                background: background,
                sourceText: String.fromCharCode(rune),
                source: s,
              ));
              shapedPos += units;
              subStart = shapedPos;
              continue;
            }
          }
          var target = current;
          if (!isZeroWidthCodePoint(rune) &&
              rune != 0x20 &&
              rune != 0x0A) {
            final ch = String.fromCharCode(rune);
            if (primary.hasGlyph(ch)) {
              target = primary;
            } else {
              final fallback = engine.resolveFontForChar(
                ch,
                families: families,
                weight: style?.fontWeight,
                fontStyle: style?.fontStyle,
              );
              target =
                  fallback == null ? primary : _withVariations(fallback, style);
            }
          }
          if (!identical(target, current)) {
            flushSub();
            current = target;
          }
          sub.writeCharCode(rune);
          shapedPos += units;
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
