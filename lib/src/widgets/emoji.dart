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

const _zwj = 0x200D;
const _vs15 = 0xFE0E; // text presentation selector
const _vs16 = 0xFE0F; // emoji presentation selector
const _keycapMark = 0x20E3;

bool _isEmojiBase(int cp) =>
    (cp >= 0x1F000 && cp <= 0x1FAFF) || // SMP pictographic blocks
    (cp >= 0x2600 && cp <= 0x27BF) || // misc symbols + dingbats
    (cp >= 0x2B00 && cp <= 0x2BFF) || // misc symbols and arrows
    cp == 0x2934 ||
    cp == 0x2935;

bool _isRegional(int cp) => cp >= 0x1F1E6 && cp <= 0x1F1FF;
bool _isSkinTone(int cp) => cp >= 0x1F3FB && cp <= 0x1F3FF;
bool _isKeycapBase(int cp) =>
    cp == 0x23 || cp == 0x2A || (cp >= 0x30 && cp <= 0x39);

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
    if (text.codeUnitAt(i) >= _keycapMark) {
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
    final cp = cps[i];
    var j = i + 1;
    var emoji = false;

    if (_isKeycapBase(cp) &&
        ((j < n && cps[j] == _keycapMark) ||
            (j + 1 < n && cps[j] == _vs16 && cps[j + 1] == _keycapMark))) {
      j = i + (cps[j] == _vs16 ? 3 : 2);
      emoji = true;
    } else if (_isRegional(cp)) {
      if (j < n && _isRegional(cps[j])) j++; // flag = RI pair
      emoji = true;
    } else if (j < n && cps[j] == _vs15 && _isEmojiBase(cp)) {
      j++; // explicit text presentation: keep base + VS15 in the text run
    } else if (_isEmojiBase(cp) || (j < n && cps[j] == _vs16)) {
      emoji = true;
      while (j < n) {
        final c = cps[j];
        if (c == _vs16 || _isSkinTone(c)) {
          j++;
          continue;
        }
        if (c == _zwj &&
            j + 1 < n &&
            (_isEmojiBase(cps[j + 1]) || _isRegional(cps[j + 1]))) {
          j += 2;
          continue;
        }
        break;
      }
    }

    final s = String.fromCharCodes(cps.sublist(i, j));
    if (emoji) {
      flushText();
      segs.add(EmojiSegment(s, isEmoji: true));
    } else {
      buf.write(s);
    }
    i = j;
  }
  flushText();
  return segs;
}

/// Rewrite emoji clusters into baseline-aligned WidgetSpans carrying
/// engine-rendered Text — EXCEPT single-code-point clusters the engine's
/// COLR emoji font covers, which stay in the text and render natively
/// through the coverage shader (the flattener emits EmojiItems for them).
/// Returns the original span unchanged (identical) when nothing needs
/// delegation.
InlineSpan expandEmojiSpans(InlineSpan root, GPUTextEngine engine) {
  var changed = false;

  bool nativeEligible(String cluster) {
    final cps = cluster.runes.where((r) => r != _vs16).toList();
    return cps.length == 1 && engine.nativeEmojiCovers(cps.first);
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
      // Everything renders natively — keep the span as plain text.
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

/// Font-fallback layer 2: characters that no registered gputext font covers
/// (after the style's fontFamilyFallback and the engine fallback chain) are
/// rewritten into baseline-aligned inline Text spans so the platform's font
/// fallback renders them instead of .notdef tofu. CJK stretches split per
/// character so lines can wrap between ideographs; other scripts stay whole
/// (breaking inside a word would be wrong). No-op until fonts are loaded —
/// call again on engine notify (GPURichText rebuilds via
/// ListenableBuilder).
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
        '|${style?.fontWeight?.value}|${style?.fontStyle?.index}');
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

    var allCovered = true;
    if (text != null) {
      for (final r in text.runes) {
        if (!covered(r)) {
          allCovered = false;
          break;
        }
      }
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
    final cps = text.runes.toList();

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
      pieces.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Text.rich(
          TextSpan(text: segment, recognizer: s.recognizer),
          textScaler: TextScaler.noScaling, // extract() scales children
          style: delegatedStyle,
        ),
      ));
    }

    var i = 0;
    while (i < cps.length) {
      if (covered(cps[i])) {
        buf.writeCharCode(cps[i]);
        i++;
        continue;
      }
      flushText();
      final start = i;
      while (i < cps.length && !covered(cps[i])) {
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
