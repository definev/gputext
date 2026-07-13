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
import '../text/emoji_ranges.dart';
import '../text/shaped_run.dart' as sr show TextDirection;
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

/// Paint-only attributes extracted from a resolved [TextStyle].
class _SpanPaint {
  _SpanPaint({
    required this.color,
    this.background,
    this.decoration,
    this.shadows,
  });

  final List<double> color;
  final List<double>? background;
  final wf.InlineDecoration? decoration;
  final List<wf.InlineShadow>? shadows;
}

_SpanPaint _paintOf(TextStyle? style) {
  final color =
      style?.foreground?.color ?? style?.color ?? const Color(0xFF000000);
  final bg = style?.backgroundColor ?? style?.background?.color;
  final styleShadows = style?.shadows;
  return _SpanPaint(
    color: [color.r, color.g, color.b, color.a],
    background: bg == null ? null : [bg.r, bg.g, bg.b, bg.a],
    decoration: _mapDecoration(style),
    shadows: styleShadows == null || styleShadows.isEmpty
        ? null
        : [
            for (final sh in styleShadows)
              wf.InlineShadow(
                dx: sh.offset.dx,
                dy: sh.offset.dy,
                blurRadius: sh.blurRadius,
                color: [sh.color.r, sh.color.g, sh.color.b, sh.color.a],
              ),
          ],
  );
}

void _applyPaint(wf.InlineItem item, _SpanPaint paint, Object source) {
  switch (item) {
    case final wf.TextRun run:
      // Mutate the existing RGBA list so LineRuns that alias it see the
      // update without a field rewrite.
      if (run.color.length >= 4) {
        run.color[0] = paint.color[0];
        run.color[1] = paint.color[1];
        run.color[2] = paint.color[2];
        run.color[3] = paint.color[3];
      } else {
        run.color = paint.color;
      }
      run.background = paint.background;
      run.decoration = paint.decoration;
      run.shadows = paint.shadows;
      run.source = source;
    case final wf.EmojiItem emoji:
      if (emoji.textColor.length >= 4) {
        emoji.textColor[0] = paint.color[0];
        emoji.textColor[1] = paint.color[1];
        emoji.textColor[2] = paint.color[2];
        emoji.textColor[3] = paint.color[3];
      } else {
        emoji.textColor = paint.color;
      }
      emoji.background = paint.background;
      emoji.source = source;
    case wf.PlaceholderItem():
      break;
  }
}

/// Value-equality key over the LAYOUT-relevant inputs of a span tree —
/// everything [_flattenSpan] reads that changes shaping, measurement, or line
/// breaking, and NOTHING that only affects paint (color, background,
/// decoration, shadows, foreground). Two spans with equal keys produce
/// byte-identical [wf.prepareParagraph] output, so a paint-only edit (a color
/// animation, or the same label drawn in two colors) reuses one shared
/// layout-cache entry instead of minting a fresh one per color.
///
/// MUST stay in sync with [_flattenSpan]: a layout input read there but
/// omitted here would let two differently-shaped spans collide on one cache
/// entry. Bias toward over-including (extra fields cost only reduced sharing);
/// only the paint inputs in [_paintOf] are deliberately excluded. Equality is
/// exact (elementwise over primitives), so a hashCode collision alone can
/// never alias two distinct layouts.
class SpanLayoutKey {
  SpanLayoutKey(InlineSpan span) : _parts = _build(span);

  final List<Object?> _parts;

  static List<Object?> _build(InlineSpan root) {
    final parts = <Object?>[];
    void walk(InlineSpan s, TextStyle? inherited) {
      // Same cascade _flattenSpan applies: child style merges over parent.
      final style = s.style == null
          ? inherited
          : (inherited?.merge(s.style) ?? s.style);
      if (s is TextSpan) {
        parts
          ..add(_kTextSpan)
          ..add(s.text)
          ..add(style?.fontFamily)
          ..add(style?.fontSize)
          ..add(style?.fontWeight?.value)
          ..add(style?.fontStyle?.index)
          ..add(style?.letterSpacing)
          ..add(style?.wordSpacing)
          ..add(style?.height)
          ..add(style?.leadingDistribution?.index)
          ..add(style?.locale?.toString());
        final fallback = style?.fontFamilyFallback;
        parts.add(fallback?.length ?? -1);
        if (fallback != null) parts.addAll(fallback);
        final features = style?.fontFeatures;
        parts.add(features?.length ?? -1);
        if (features != null) {
          for (final f in features) {
            parts
              ..add(f.feature)
              ..add(f.value);
          }
        }
        final variations = style?.fontVariations;
        parts.add(variations?.length ?? -1);
        if (variations != null) {
          for (final v in variations) {
            parts
              ..add(v.axis)
              ..add(v.value);
          }
        }
        final children = s.children;
        parts.add(children?.length ?? -1);
        if (children != null) {
          for (final c in children) {
            walk(c, style);
          }
        }
      } else {
        // Placeholders: the shared cache is skipped when any exist (their
        // dimensions vary per widget), but mark them so a tree with a
        // placeholder never keys equal to one without.
        parts.add(_kPlaceholder);
      }
    }

    walk(root, null);
    return parts;
  }

  static const _kTextSpan = 0;
  static const _kPlaceholder = 1;

  @override
  late final int hashCode = Object.hashAll(_parts);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SpanLayoutKey) return false;
    final a = _parts;
    final b = other._parts;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Re-applies paint-only style (color, decoration, shadows, background) and
/// source-span pointers onto an existing flatten result. Returns false when
/// the span tree no longer matches [items] structurally — caller must
/// reshape.
///
/// Used for [RenderComparison.paint] / metadata updates so color animation
/// skips HarfBuzz + prepare and does not insert ephemeral keys into the
/// shared layout cache.
bool patchInlineItemsPaint(List<wf.InlineItem> items, InlineSpan span) {
  var i = 0;
  var ok = true;

  void walk(InlineSpan s, TextStyle? inherited) {
    if (!ok) return;
    final style = s.style == null
        ? inherited
        : (inherited?.merge(s.style) ?? s.style);
    if (s is TextSpan) {
      final text = s.text;
      if (text != null && text.isNotEmpty) {
        final paint = _paintOf(style);
        var covered = 0;
        while (covered < text.length) {
          if (i >= items.length) {
            ok = false;
            return;
          }
          final item = items[i];
          final len = switch (item) {
            wf.TextRun r => r.originalText.length,
            wf.EmojiItem e => e.originalText.length,
            wf.PlaceholderItem() => 0,
          };
          if (len == 0) {
            ok = false;
            return;
          }
          _applyPaint(item, paint, s);
          covered += len;
          i++;
        }
        if (covered != text.length) {
          ok = false;
          return;
        }
      }
      final children = s.children;
      if (children != null) {
        for (final child in children) {
          walk(child, style);
        }
      }
    } else if (s is PlaceholderSpan) {
      if (i >= items.length || items[i] is! wf.PlaceholderItem) {
        ok = false;
        return;
      }
      i++;
    }
  }

  walk(span, null);
  return ok && i == items.length;
}

/// Shallow item clone with independent paint lists, sharing shaped glyph
/// data. Used to detach a paragraph from the engine's shared layout cache
/// before mutating paint fields.
List<wf.InlineItem> cloneInlineItemsForPaint(List<wf.InlineItem> items) {
  return [
    for (final item in items)
      switch (item) {
        wf.TextRun r => wf.TextRun(
          text: r.text,
          font: r.font,
          fontSizePx: r.fontSizePx,
          color: List<double>.of(r.color),
          letterSpacingPx: r.letterSpacingPx,
          wordSpacingPx: r.wordSpacingPx,
          height: r.height,
          decoration: r.decoration,
          fillRule: r.fillRule,
          background: r.background == null
              ? null
              : List<double>.of(r.background!),
          shadows: r.shadows,
          evenLeading: r.evenLeading,
          sourceText: r.sourceText,
          sourceMap: r.sourceMap,
          source: r.source,
          shaped: r.shaped,
        ),
        wf.EmojiItem e => wf.EmojiItem(
          font: e.font,
          fontSizePx: e.fontSizePx,
          advanceUnits: e.advanceUnits,
          layers: e.layers,
          textColor: List<double>.of(e.textColor),
          background: e.background == null
              ? null
              : List<double>.of(e.background!),
          sourceText: e.sourceText,
          source: e.source,
        ),
        wf.PlaceholderItem p => p,
      },
  ];
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
        final paint = _paintOf(style);
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
                : shaped.withBidi(bidiLevel: br.level, direction: br.direction);
            items.add(
              wf.TextRun(
                text: withBidi.pipelineText,
                font: current,
                fontSizePx: fontSizePx,
                color: List<double>.of(paint.color),
                letterSpacingPx: style?.letterSpacing ?? 0,
                wordSpacingPx: style?.wordSpacing ?? 0,
                height: style?.height,
                decoration: paint.decoration,
                background: paint.background == null
                    ? null
                    : List<double>.of(paint.background!),
                shadows: paint.shadows,
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
        final runes = text.runes.toList(growable: false);
        for (var ri = 0; ri < runes.length; ri++) {
          final rune = runes[ri];
          // A rune routes to the emoji font ONLY when it is actually an emoji —
          // an emoji-presentation base, a regional indicator, or a character
          // carrying the emoji variation selector (VS16). Font coverage alone
          // is not enough: color-emoji fonts include non-emoji glyphs (e.g.
          // NotoColorEmoji maps ASCII digits 0-9 and #/* as keycap bases), and
          // matching on coverage would hijack plain text into the color/bitmap
          // pipeline. See text/emoji_ranges.dart.
          final isEmojiRune = isEmojiBaseCp(rune) ||
              isRegionalIndicatorCp(rune) ||
              (ri + 1 < runes.length && runes[ri + 1] == emojiVs16);
          // Native color emoji: COLR layers render through the shader.
          if (emojiFont != null && isEmojiRune && !isZeroWidthCodePoint(rune)) {
            final layers = emojiFont.colrForCodePoint(rune);
            if (layers != null) {
              flushSub();
              items.add(
                wf.EmojiItem(
                  font: emojiFont,
                  fontSizePx: fontSizePx,
                  advanceUnits: emojiFont.advanceOfGlyphId(
                    emojiFont.glyphIdForRune(rune) ?? 0,
                  ),
                  layers: layers,
                  textColor: List<double>.of(paint.color),
                  background: paint.background == null
                      ? null
                      : List<double>.of(paint.background!),
                  sourceText: String.fromCharCode(rune),
                  source: s,
                ),
              );
              continue;
            }
            // Color-bitmap emoji (sbix / CBDT): one atlas-sampled quad.
            if (emojiFont.hasBitmapGlyphs) {
              final gid = emojiFont.glyphIdForRune(rune);
              if (gid != null &&
                  emojiFont.bitmapGlyphForId(gid, targetPpem: fontSizePx) !=
                      null) {
                flushSub();
                items.add(
                  wf.EmojiItem(
                    font: emojiFont,
                    fontSizePx: fontSizePx,
                    advanceUnits: emojiFont.advanceOfGlyphId(gid),
                    bitmapGlyphId: gid,
                    textColor: List<double>.of(paint.color),
                    background: paint.background == null
                        ? null
                        : List<double>.of(paint.background!),
                    sourceText: String.fromCharCode(rune),
                    source: s,
                  ),
                );
                continue;
              }
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
