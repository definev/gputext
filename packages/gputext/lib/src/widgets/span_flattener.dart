// Flatten an InlineSpan tree into gputext inline items, applying the
// TextStyle inheritance cascade the way RenderParagraph does (child style
// merges over parent). PlaceholderSpans (WidgetSpan) become PlaceholderItems
// whose dimensions come from the render object's child layout; the preorder
// placeholder index matches WidgetSpan.extractFromInlineSpan child order.

import 'dart:ui' as ui show PlaceholderAlignment, TextDirection;

import 'package:flutter/painting.dart';

import '../engine/engine.dart';
import '../font.dart' show GPUFont, GPUFontVariations, isZeroWidthCodePoint;
import '../paragraph.dart' as wf;
import '../text/bidi.dart' as bidi;
import '../text/shaped_run.dart' as sr show ShapedGlyphRun, TextDirection;
import '../text/shaper.dart';
import '../timeline.dart';

sr.TextDirection _mapDirection(ui.TextDirection d) => switch (d) {
  ui.TextDirection.rtl => sr.TextDirection.rtl,
  ui.TextDirection.ltr => sr.TextDirection.ltr,
};

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
GPUFont _withVariations(GPUFont font, TextStyle? style) {
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
  GPUTextEngine engine, {
  List<PlaceholderDimensions> placeholderDimensions = const [],
  ui.TextDirection textDirection = ui.TextDirection.ltr,
  Locale? locale,
}) => GPUTextTimeline.timeSync(
  GPUTextTimeline.flatten,
  () => _flattenSpan(
    span,
    textScaler,
    engine,
    placeholderDimensions: placeholderDimensions,
    textDirection: textDirection,
    locale: locale,
  ),
);

List<wf.InlineItem>? _flattenSpan(
  InlineSpan span,
  TextScaler textScaler,
  GPUTextEngine engine, {
  List<PlaceholderDimensions> placeholderDimensions = const [],
  ui.TextDirection textDirection = ui.TextDirection.ltr,
  Locale? locale,
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
        final color =
            style?.foreground?.color ?? style?.color ?? const Color(0xFF000000);
        final bg = style?.backgroundColor ?? style?.background?.color;
        final background = bg == null ? null : <double>[bg.r, bg.g, bg.b, bg.a];
        final styleShadows = style?.shadows;
        final shadows = styleShadows == null || styleShadows.isEmpty
            ? null
            : [
                for (final sh in styleShadows)
                  wf.InlineShadow(
                    dx: sh.offset.dx,
                    dy: sh.offset.dy,
                    blurRadius: sh.blurRadius,
                    color: [sh.color.r, sh.color.g, sh.color.b, sh.color.a],
                  ),
              ];
        final evenLeading = switch (style?.leadingDistribution) {
          TextLeadingDistribution.even => true,
          TextLeadingDistribution.proportional => false,
          null => null,
        };

        final fontSizePx = textScaler.scale(style?.fontSize ?? 14.0);
        final features = {
          for (final f in style?.fontFeatures ?? const <FontFeature>[])
            f.feature: f.value,
        };
        final defaultLigatures = (style?.letterSpacing ?? 0) == 0;
        final shaper = engine.shaper;
        final baseDir = _mapDirection(textDirection);
        final language = locale?.toLanguageTag();

        // Font fallback + emoji itemization FIRST (source text), then bidi
        // itemize + shape each same-font slice.
        final sub = StringBuffer();
        var current = primary;
        void flushSub() {
          if (sub.isEmpty) return;
          final sourceSlice = sub.toString();
          final runs = bidi.itemize(sourceSlice, baseDirection: baseDir);
          for (final br in runs) {
            final slice = br.slice(sourceSlice);
            if (slice.isEmpty) continue;
            final shaped = shaper.shape(
              ShapeRequest(
                font: current,
                text: slice,
                fontSizePx: fontSizePx,
                features: features,
                defaultLigatures: defaultLigatures,
                direction: br.direction,
                bidiLevel: br.level,
                script: bidi.scriptTagForRun(slice),
                language: language,
              ),
            );
            // Ensure bidi metadata is on the run even if the shaper ignored it.
            final withBidi =
                shaped.bidiLevel == br.level && shaped.direction == br.direction
                ? shaped
                : sr.ShapedGlyphRun(
                    font: shaped.font,
                    fontSizePx: shaped.fontSizePx,
                    sourceText: shaped.sourceText,
                    pipelineText: shaped.pipelineText,
                    glyphs: shaped.glyphs,
                    sourceMap: shaped.sourceMap,
                    bidiLevel: br.level,
                    direction: br.direction,
                    appliesKerning: shaped.appliesKerning,
                  );
            items.add(
              wf.TextRun(
                text: withBidi.pipelineText,
                font: current,
                fontSizePx: fontSizePx,
                color: [color.r, color.g, color.b, color.a],
                letterSpacingPx: style?.letterSpacing ?? 0,
                wordSpacingPx: style?.wordSpacing ?? 0,
                height: style?.height,
                decoration: _mapDecoration(style),
                background: background,
                shadows: shadows,
                evenLeading: evenLeading,
                sourceText: withBidi.sourceText == withBidi.pipelineText
                    ? null
                    : withBidi.sourceText,
                sourceMap: withBidi.sourceMap,
                source: s,
                shaped: withBidi,
              ),
            );
          }
          sub.clear();
        }

        final emojiFont = engine.emojiFont;
        for (final rune in text.runes) {
          // Native color emoji: COLR layers render through the shader.
          if (emojiFont != null && !isZeroWidthCodePoint(rune)) {
            final layers = emojiFont.colrForCodePoint(rune);
            if (layers != null) {
              flushSub();
              items.add(
                wf.EmojiItem(
                  font: emojiFont,
                  fontSizePx: fontSizePx,
                  advanceUnits: emojiFont.advanceOf(String.fromCharCode(rune)),
                  layers: layers,
                  textColor: [color.r, color.g, color.b, color.a],
                  background: background,
                  sourceText: String.fromCharCode(rune),
                  source: s,
                ),
              );
              continue;
            }
          }
          var target = current;
          if (!isZeroWidthCodePoint(rune) && rune != 0x20 && rune != 0x0A) {
            if (primary.hasGlyphForRune(rune)) {
              target = primary;
            } else {
              final fallback = engine.resolveFontForChar(
                String.fromCharCode(rune),
                families: families,
                weight: style?.fontWeight,
                fontStyle: style?.fontStyle,
              );
              target = fallback == null
                  ? primary
                  : _withVariations(fallback, style);
            }
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
      items.add(
        wf.PlaceholderItem(
          index: index,
          width: dims.size.width,
          height: dims.size.height,
          alignment: _mapAlignment(s.alignment),
          baselineOffset: dims.baselineOffset,
        ),
      );
    } else {
      assert(
        false,
        'GPURichText does not support ${s.runtimeType}; '
        'the span will be skipped.',
      );
    }
  }

  walk(span, null);
  return missingFont ? null : items;
}
