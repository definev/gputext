// Emoji support: gputext renders monochrome coverage from quadratic
// outlines, so color emoji can't go through the winding-integral shader.
// Instead, emoji clusters are rewritten into baseline-aligned WidgetSpans
// whose child is a stock Text — the engine's font fallback then draws the
// platform's real color emoji, and metrics/wrap/hit-testing ride the
// existing placeholder machinery. This keeps output parity with RichText.
//
// Segmentation approximates UTS #51 extended pictographic clusters:
// base pictograph + VS16/skin-tone absorption + (ZWJ + pictograph)* chains,
// regional-indicator pairs (flags), keycap sequences, and VS15 opting a
// character back into text presentation.

import 'package:flutter/widgets.dart';

import '../engine/engine.dart';
import '../font.dart' show isZeroWidthCodePoint;
import '../text/emoji_ranges.dart';

const _vs15 = emojiVs15; // text presentation selector
const _vs16 = emojiVs16; // emoji presentation selector

// Emoji-base and regional-indicator tests are shared with the flattener so
// both sites classify emoji identically — see text/emoji_ranges.dart.
bool _isEmojiBase(int cp) => isEmojiBaseCp(cp);
bool _isRegional(int cp) => isRegionalIndicatorCp(cp);

class EmojiSegment {
  const EmojiSegment(this.text, {required this.isEmoji});

  final String text;
  final bool isEmoji;
}

bool containsEmoji(String text) {
  // Fast reject on raw code units: every emoji-relevant scalar (keycap mark
  // U+20E3, the BMP pictographic blocks, VS16, and SMP surrogates) is
  // ≥ U+20E3, so ordinary Latin text bails here without a rune list.
  var possible = false;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) >= emojiKeycapMark) {
      possible = true;
      break;
    }
  }
  if (!possible) return false;

  final cps = text.runes.toList();
  for (var i = 0; i < cps.length; i++) {
    if (_isEmojiBase(cps[i]) || _isRegional(cps[i])) {
      // VS15 right after the base keeps it in text presentation.
      if (i + 1 < cps.length && cps[i + 1] == _vs15) continue;
      return true;
    }
    if (cps[i] == _vs16) return true; // anything + VS16 is emoji
  }
  return false;
}

/// Split `text` into plain-text segments and individual emoji clusters
/// (each cluster is its own segment so lines may wrap between them).
List<EmojiSegment> splitEmojiSegments(String text) {
  final cps = text.runes.toList();
  final n = cps.length;
  final segs = <EmojiSegment>[];
  final buf = StringBuffer();

  void flushText() {
    if (buf.isNotEmpty) {
      segs.add(EmojiSegment(buf.toString(), isEmoji: false));
      buf.clear();
    }
  }

  var i = 0;
  while (i < n) {
    final end = emojiClusterEnd(
      cps,
      i,
    ); // shared clustering (emoji_ranges.dart)
    if (end > i) {
      flushText();
      segs.add(
        EmojiSegment(String.fromCharCodes(cps.sublist(i, end)), isEmoji: true),
      );
      i = end;
    } else {
      // Not an emoji cluster. Absorb a trailing VS15 so base + VS15 (explicit
      // text presentation) stays whole in the text run.
      var j = i + 1;
      if (j < n && cps[j] == _vs15 && _isEmojiBase(cps[i])) j++;
      buf.write(String.fromCharCodes(cps.sublist(i, j)));
      i = j;
    }
  }
  flushText();
  return segs;
}

/// Rewrite emoji clusters to baseline-aligned platform [Text] WidgetSpans,
/// except single-CP clusters covered by the COLR emoji font (stay in-text).
/// Returns [root] unchanged when nothing needs delegation.
InlineSpan expandEmojiSpans(InlineSpan root, GPUTextEngine engine) {
  var changed = false;

  bool nativeEligible(String cluster) {
    int? sole;
    var n = 0;
    for (final r in cluster.runes) {
      if (r == _vs16) continue;
      n++;
      sole = r;
    }
    // Single scalar (+optional VS16): cheap direct-coverage check.
    if (n == 1) return engine.nativeEmojiCovers(sole!);
    // Multi-scalar sequence (ZWJ family, flag, keycap, skin tone): native only
    // when the emoji font ligates it to a single color glyph the GPU pipeline
    // can draw. Otherwise it still delegates to a platform Text WidgetSpan.
    return engine.emojiGlyphForCluster(cluster) != null;
  }

  InlineSpan transform(InlineSpan s, double inheritedSize) {
    if (s is! TextSpan) return s;
    final size = s.style?.fontSize ?? inheritedSize;

    List<InlineSpan>? children;
    if (s.children != null) {
      children = [for (final c in s.children!) transform(c, size)];
    }

    final text = s.text;
    if (text == null || !containsEmoji(text)) {
      if (!changed) return s; // subtree may still have changed below
      return TextSpan(
        text: text,
        style: s.style,
        children: children,
        recognizer: s.recognizer,
        semanticsLabel: s.semanticsLabel,
      );
    }

    final segments = splitEmojiSegments(text);
    if (segments.every((seg) => !seg.isEmoji || nativeEligible(seg.text))) {
      // COLR-covered — keep as plain text for the flattener's EmojiItems.
      if (!changed) return s;
      return TextSpan(
        text: text,
        style: s.style,
        children: children,
        recognizer: s.recognizer,
        semanticsLabel: s.semanticsLabel,
      );
    }

    changed = true;
    final pieces = <InlineSpan>[
      for (final seg in segments)
        if (seg.isEmoji && !nativeEligible(seg.text))
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Text.rich(
              TextSpan(text: seg.text, recognizer: s.recognizer),
              textScaler: TextScaler.noScaling, // extract() scales children
              style: TextStyle(fontSize: size),
            ),
          )
        else
          TextSpan(text: seg.text, recognizer: s.recognizer),
      ...?children,
    ];
    return TextSpan(style: s.style, children: pieces);
  }

  final result = transform(root, 14.0);
  return changed ? result : root;
}

bool _isCjkIdeograph(int cp) =>
    (cp >= 0x2E80 && cp <= 0x9FFF) || // radicals, kana, CJK ideographs
    (cp >= 0xAC00 && cp <= 0xD7AF) || // hangul syllables
    (cp >= 0xF900 && cp <= 0xFAFF) || // compatibility ideographs
    (cp >= 0xFF00 && cp <= 0xFFEF) || // full/half-width forms
    (cp >= 0x20000 && cp <= 0x2FA1F); // SMP ideograph planes

/// Exclusive end of a GPU-renderable emoji cluster beginning at [start] in
/// [cps] — one the flattener emits as a single colored EmojiItem — or [start]
/// when none begins there. Mirrors the keep-in-text decision [expandEmojiSpans]
/// makes for the same cluster, so [expandUncoveredSpans] never splits it apart:
/// a multi-scalar sequence's interior code points (the combining enclosing
/// keycap U+20E3, ZWJ, skin-tone modifiers, regional indicators) are frequently
/// uncovered by any plain-text font on their own, and delegating them piecemeal
/// detaches the mark from its base — e.g. a keycap sequence rendered as a bare
/// digit plus a floating enclosing box drawn backward over it. Single-scalar
/// clusters are left to the per-rune coverage check, which already routes native
/// emoji through [GPUTextEngine.nativeEmojiCovers].
int _gpuEmojiClusterEnd(List<int> cps, int start, GPUTextEngine engine) {
  if (engine.emojiFont == null) return start;
  final end = emojiClusterEnd(cps, start);
  var scalars = 0;
  for (var k = start; k < end; k++) {
    if (cps[k] != _vs16) scalars++;
  }
  if (scalars < 2) return start;
  final cluster = String.fromCharCodes(cps.sublist(start, end));
  return engine.emojiGlyphForCluster(cluster) != null ? end : start;
}

/// Delegate uncovered code points to baseline-aligned platform [Text].
/// CJK stretches split per character for wrap; other scripts stay whole.
/// No-op until fonts are loaded — call again on engine notify.
InlineSpan expandUncoveredSpans(InlineSpan root, GPUTextEngine engine) {
  if (!engine.fontsReady) return root;
  var changed = false;

  InlineSpan transform(InlineSpan s, TextStyle? inherited) {
    if (s is! TextSpan) return s;
    final style = s.style == null
        ? inherited
        : (inherited?.merge(s.style) ?? s.style);

    List<InlineSpan>? children;
    if (s.children != null) {
      children = [for (final c in s.children!) transform(c, style)];
    }

    final text = s.text;
    final families = <String?>[
      style?.fontFamily,
      ...?style?.fontFamilyFallback,
    ];
    // Coverage verdicts live on the engine, keyed by the resolution context
    // (family list + weight/style) and invalidated on font churn — repeated
    // builds of the same content skip per-char font resolution entirely.
    final coverage = engine.coverageCacheFor(
      '${style?.fontFamily}|${style?.fontFamilyFallback?.join(',')}'
      '|${style?.fontWeight?.value}|${style?.fontStyle?.index}',
    );
    bool covered(int cp) {
      if (isZeroWidthCodePoint(cp) || cp == 0x20 || cp == 0x0A) return true;
      return coverage.putIfAbsent(
        cp,
        () =>
            engine.nativeEmojiCovers(cp) ||
            engine.resolveFontForChar(
                  String.fromCharCode(cp),
                  families: families,
                  weight: style?.fontWeight,
                  fontStyle: style?.fontStyle,
                ) !=
                null,
      );
    }

    final cps = text == null ? const <int>[] : text.runes.toList();
    var allCovered = true;
    for (var k = 0; k < cps.length;) {
      // A GPU-renderable emoji cluster stays whole in the text run even when its
      // interior code points aren't individually covered (see below).
      final ce = _gpuEmojiClusterEnd(cps, k, engine);
      if (ce > k) {
        k = ce;
        continue;
      }
      if (!covered(cps[k])) {
        allCovered = false;
        break;
      }
      k++;
    }
    if (text == null || allCovered) {
      if (!changed) return s;
      return TextSpan(
        text: text,
        style: s.style,
        children: children,
        recognizer: s.recognizer,
        semanticsLabel: s.semanticsLabel,
      );
    }

    changed = true;
    final pieces = <InlineSpan>[];
    final buf = StringBuffer();
    void flushText() {
      if (buf.isNotEmpty) {
        pieces.add(TextSpan(text: buf.toString(), recognizer: s.recognizer));
        buf.clear();
      }
    }

    final delegatedStyle = TextStyle(
      fontSize: style?.fontSize ?? 14.0,
      color: style?.color ?? const Color(0xFF000000),
      fontFamily: style?.fontFamily,
      fontFamilyFallback: style?.fontFamilyFallback,
      fontWeight: style?.fontWeight,
      fontStyle: style?.fontStyle,
    );
    void addDelegated(String segment) {
      pieces.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Text.rich(
            TextSpan(text: segment, recognizer: s.recognizer),
            textScaler: TextScaler.noScaling, // extract() scales children
            style: delegatedStyle,
          ),
        ),
      );
    }

    var i = 0;
    while (i < cps.length) {
      // Keep a GPU-renderable emoji cluster intact so the flattener can emit it
      // as one colored EmojiItem; splitting on per-rune coverage would detach a
      // combining mark (e.g. the keycap U+20E3) from its base.
      final ce = _gpuEmojiClusterEnd(cps, i, engine);
      if (ce > i) {
        for (var k = i; k < ce; k++) {
          buf.writeCharCode(cps[k]);
        }
        i = ce;
        continue;
      }
      if (covered(cps[i])) {
        buf.writeCharCode(cps[i]);
        i++;
        continue;
      }
      flushText();
      final start = i;
      while (i < cps.length &&
          _gpuEmojiClusterEnd(cps, i, engine) == i &&
          !covered(cps[i])) {
        i++;
      }
      final chunk = StringBuffer();
      for (final cp in cps.sublist(start, i)) {
        if (_isCjkIdeograph(cp)) {
          if (chunk.isNotEmpty) {
            addDelegated(chunk.toString());
            chunk.clear();
          }
          addDelegated(String.fromCharCode(cp));
        } else {
          chunk.writeCharCode(cp);
        }
      }
      if (chunk.isNotEmpty) addDelegated(chunk.toString());
    }
    flushText();
    return TextSpan(style: s.style, children: [...pieces, ...?children]);
  }

  final result = transform(root, null);
  return changed ? result : root;
}
