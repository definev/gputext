// Pure-Dart Unicode Bidirectional Algorithm (UAX #9) subset for Arabic +
// Hebrew v1. Keeps headless tests VM-pure; HarfBuzz shapes each run after
// itemization. Explicit embeddings (LRE/RLE/…) are honored at a basic level;
// full isolate stack depth matching ICU is a later hardening pass.
//
// Pipeline:
//   1. [paragraphLevel] from base TextDirection (or first strong char)
//   2. [itemize] → BidiRun list (logical order, each with level + direction)
//   3. Shape each run (HB_DIRECTION_RTL for odd levels)
//   4. Line-break on logical clusters
//   5. [reorderVisual] per line (UAX #9 L2) for paint / hit-test

import 'shaped_run.dart';

/// Bidi character classes (UAX #9 Table 4, simplified).
enum BidiClass {
  l,
  r,
  al,
  en,
  es,
  et,
  an,
  cs,
  nsm,
  bn,
  b,
  s,
  ws,
  on,
  lre,
  lro,
  rle,
  rlo,
  pdf,
  lri,
  rli,
  fsi,
  pdi,
}

/// One directional run in logical order.
class BidiRun {
  const BidiRun({
    required this.start,
    required this.end,
    required this.level,
    required this.direction,
  });

  /// UTF-16 start (inclusive) in the source string.
  final int start;

  /// UTF-16 end (exclusive).
  final int end;

  /// Embedding level (even = LTR, odd = RTL).
  final int level;

  final TextDirection direction;

  String slice(String text) => text.substring(start, end);
}

/// Paragraph embedding level from an explicit base direction, or from the
/// first strong character (P2/P3) when [base] is null.
int paragraphLevel(String text, TextDirection? base) {
  if (base == TextDirection.rtl) return 1;
  if (base == TextDirection.ltr) return 0;
  for (final rune in text.runes) {
    final c = bidiClassOf(rune);
    if (c == BidiClass.r || c == BidiClass.al) return 1;
    if (c == BidiClass.l) return 0;
  }
  return 0;
}

/// Classify a Unicode code point into a [BidiClass].
BidiClass bidiClassOf(int cp) {
  // Explicit formatting controls.
  switch (cp) {
    case 0x202A:
      return BidiClass.lre;
    case 0x202B:
      return BidiClass.rle;
    case 0x202D:
      return BidiClass.lro;
    case 0x202E:
      return BidiClass.rlo;
    case 0x202C:
      return BidiClass.pdf;
    case 0x2066:
      return BidiClass.lri;
    case 0x2067:
      return BidiClass.rli;
    case 0x2068:
      return BidiClass.fsi;
    case 0x2069:
      return BidiClass.pdi;
  }
  if (cp == 0x000A ||
      cp == 0x000D ||
      cp == 0x001C ||
      cp == 0x001D ||
      cp == 0x001E ||
      cp == 0x0085 ||
      cp == 0x2029) {
    return BidiClass.b;
  }
  if (cp == 0x0009 || cp == 0x000B || cp == 0x001F) return BidiClass.s;
  if (cp == 0x000C ||
      cp == 0x0020 ||
      cp == 0x1680 ||
      (cp >= 0x2000 && cp <= 0x200A) ||
      cp == 0x202F ||
      cp == 0x205F ||
      cp == 0x3000) {
    return BidiClass.ws;
  }
  // NSM: combining marks (covers Arabic/Hebrew diacritics).
  if ((cp >= 0x0300 && cp <= 0x036F) ||
      (cp >= 0x0591 && cp <= 0x05BD) ||
      cp == 0x05BF ||
      (cp >= 0x05C1 && cp <= 0x05C2) ||
      (cp >= 0x05C4 && cp <= 0x05C5) ||
      cp == 0x05C7 ||
      (cp >= 0x0610 && cp <= 0x061A) ||
      (cp >= 0x064B && cp <= 0x065F) ||
      cp == 0x0670 ||
      (cp >= 0x06D6 && cp <= 0x06DC) ||
      (cp >= 0x06DF && cp <= 0x06E4) ||
      (cp >= 0x06E7 && cp <= 0x06E8) ||
      (cp >= 0x06EA && cp <= 0x06ED) ||
      (cp >= 0x08D3 && cp <= 0x08FF) ||
      (cp >= 0xFE00 && cp <= 0xFE0F)) {
    return BidiClass.nsm;
  }
  // Hebrew letters.
  if ((cp >= 0x05D0 && cp <= 0x05EA) ||
      (cp >= 0x05F0 && cp <= 0x05F4) ||
      (cp >= 0xFB1D && cp <= 0xFB4F)) {
    return BidiClass.r;
  }
  // Arabic letters (AL) — Arabic, Persian, Urdu blocks + presentation forms.
  if ((cp >= 0x0600 && cp <= 0x06FF) ||
      (cp >= 0x0750 && cp <= 0x077F) ||
      (cp >= 0x08A0 && cp <= 0x08FF) ||
      (cp >= 0xFB50 && cp <= 0xFDFF) ||
      (cp >= 0xFE70 && cp <= 0xFEFF)) {
    // Arabic-Indic digits are AN.
    if ((cp >= 0x0660 && cp <= 0x0669) || (cp >= 0x06F0 && cp <= 0x06F9)) {
      return BidiClass.an;
    }
    // Arabic punctuation often ON; treat comma/semicolon as CS.
    if (cp == 0x060C || cp == 0x066C) return BidiClass.cs;
    if (cp == 0x066B) return BidiClass.cs;
    // Default Arabic letters → AL.
    if ((cp >= 0x0620 && cp <= 0x064A) ||
        (cp >= 0x066E && cp <= 0x06D3) ||
        (cp >= 0x06D5 && cp <= 0x06FF) ||
        (cp >= 0x0750 && cp <= 0x077F) ||
        (cp >= 0x08A0 && cp <= 0x08BD) ||
        (cp >= 0xFB50 && cp <= 0xFDFF) ||
        (cp >= 0xFE70 && cp <= 0xFEFC)) {
      return BidiClass.al;
    }
    return BidiClass.on;
  }
  // European digits.
  if (cp >= 0x0030 && cp <= 0x0039) return BidiClass.en;
  // ES / ET / CS.
  if (cp == 0x002B || cp == 0x002D) return BidiClass.es; // + -
  if (cp == 0x0023 ||
      cp == 0x0024 ||
      cp == 0x0025 ||
      cp == 0x00A2 ||
      cp == 0x00A3 ||
      cp == 0x00A4 ||
      cp == 0x00A5 ||
      cp == 0x20AC) {
    return BidiClass.et;
  }
  if (cp == 0x002C || cp == 0x002E || cp == 0x003A || cp == 0x002F) {
    return BidiClass.cs;
  }
  // BN (zero-width / format, excluding bidi controls handled above).
  if (cp == 0x00AD ||
      cp == 0x200B ||
      cp == 0x200C ||
      cp == 0x200D ||
      cp == 0x2060 ||
      cp == 0xFEFF) {
    return BidiClass.bn;
  }
  // Latin and other LTR letters (rough: Lu/Ll/Lt/Lm/Lo in BMP Latin + Cyrillic).
  if ((cp >= 0x0041 && cp <= 0x005A) ||
      (cp >= 0x0061 && cp <= 0x007A) ||
      (cp >= 0x00C0 && cp <= 0x00D6) ||
      (cp >= 0x00D8 && cp <= 0x00F6) ||
      (cp >= 0x00F8 && cp <= 0x02B8) ||
      (cp >= 0x0400 && cp <= 0x0482) ||
      (cp >= 0x048A && cp <= 0x052F)) {
    return BidiClass.l;
  }
  return BidiClass.on;
}

bool _isStrong(BidiClass c) =>
    c == BidiClass.l || c == BidiClass.r || c == BidiClass.al;

bool _isNeutral(BidiClass c) =>
    c == BidiClass.b ||
    c == BidiClass.s ||
    c == BidiClass.ws ||
    c == BidiClass.on ||
    c == BidiClass.bn;

/// Resolve embedding levels for each UTF-16 code unit (UAX #9 X1–I2, simplified).
List<int> resolveLevels(String text, int paragraphEmbedding) {
  final n = text.length;
  if (n == 0) return const [];
  final types = List<BidiClass>.filled(n, BidiClass.on);
  final levels = List<int>.filled(n, paragraphEmbedding);

  // Map each UTF-16 unit; surrogates share the rune's class.
  var i = 0;
  while (i < n) {
    final cu = text.codeUnitAt(i);
    if (cu >= 0xD800 && cu <= 0xDBFF && i + 1 < n) {
      final low = text.codeUnitAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        final cp = 0x10000 + ((cu - 0xD800) << 10) + (low - 0xDC00);
        final c = bidiClassOf(cp);
        types[i] = c;
        types[i + 1] = c;
        i += 2;
        continue;
      }
    }
    types[i] = bidiClassOf(cu);
    i++;
  }

  // X1–X8: embedding stack (simplified — no overflow isolate counters).
  final stack = <int>[paragraphEmbedding];
  final override = <BidiClass?>[null]; // L / R / null
  for (var j = 0; j < n; j++) {
    final t = types[j];
    switch (t) {
      case BidiClass.rle:
      case BidiClass.rlo:
        final next = (stack.last + 1) | 1;
        if (next <= 125) {
          stack.add(next);
          override.add(t == BidiClass.rlo ? BidiClass.r : null);
        }
        types[j] = BidiClass.bn;
      case BidiClass.lre:
      case BidiClass.lro:
        final next = (stack.last + 2) & ~1;
        if (next <= 125) {
          stack.add(next);
          override.add(t == BidiClass.lro ? BidiClass.l : null);
        }
        types[j] = BidiClass.bn;
      case BidiClass.rli:
        final next = (stack.last + 1) | 1;
        if (next <= 125) {
          stack.add(next);
          override.add(null);
        }
        types[j] = BidiClass.bn;
      case BidiClass.lri:
      case BidiClass.fsi:
        final next = (stack.last + 2) & ~1;
        if (next <= 125) {
          stack.add(next);
          override.add(null);
        }
        types[j] = BidiClass.bn;
      case BidiClass.pdf:
      case BidiClass.pdi:
        if (stack.length > 1) {
          stack.removeLast();
          override.removeLast();
        }
        types[j] = BidiClass.bn;
      default:
        levels[j] = stack.last;
        final o = override.last;
        if (o == BidiClass.l) {
          types[j] = BidiClass.l;
        } else if (o == BidiClass.r) {
          types[j] = BidiClass.r;
        }
    }
  }

  // W1: NSM ← preceding.
  for (var j = 0; j < n; j++) {
    if (types[j] != BidiClass.nsm) continue;
    types[j] = j > 0
        ? types[j - 1]
        : (paragraphEmbedding.isOdd ? BidiClass.r : BidiClass.l);
  }

  // W2: EN ← AL → AN (sos = paragraph).
  var lastStrong = paragraphEmbedding.isOdd ? BidiClass.r : BidiClass.l;
  for (var j = 0; j < n; j++) {
    final t = types[j];
    if (t == BidiClass.al || t == BidiClass.r || t == BidiClass.l) {
      lastStrong = t;
    } else if (t == BidiClass.en && lastStrong == BidiClass.al) {
      types[j] = BidiClass.an;
    }
  }

  // W3: AL → R.
  for (var j = 0; j < n; j++) {
    if (types[j] == BidiClass.al) types[j] = BidiClass.r;
  }

  // W4: ES between EN → EN; CS between same EN/AN → that type.
  for (var j = 1; j < n - 1; j++) {
    if (types[j] == BidiClass.es &&
        types[j - 1] == BidiClass.en &&
        types[j + 1] == BidiClass.en) {
      types[j] = BidiClass.en;
    }
    if (types[j] == BidiClass.cs &&
        types[j - 1] == types[j + 1] &&
        (types[j - 1] == BidiClass.en || types[j - 1] == BidiClass.an)) {
      types[j] = types[j - 1];
    }
  }

  // W5: ET adjoining EN → EN.
  for (var j = 0; j < n; j++) {
    if (types[j] != BidiClass.et) continue;
    if ((j > 0 && types[j - 1] == BidiClass.en) ||
        (j + 1 < n && types[j + 1] == BidiClass.en)) {
      types[j] = BidiClass.en;
    }
  }
  // Run-length ET sequences next to EN.
  for (var j = 0; j < n;) {
    if (types[j] != BidiClass.et) {
      j++;
      continue;
    }
    var k = j;
    while (k < n && types[k] == BidiClass.et) {
      k++;
    }
    final before = j > 0 && types[j - 1] == BidiClass.en;
    final after = k < n && types[k] == BidiClass.en;
    if (before || after) {
      for (var t = j; t < k; t++) {
        types[t] = BidiClass.en;
      }
    }
    j = k;
  }

  // W6: remaining ES/ET/CS → ON.
  for (var j = 0; j < n; j++) {
    final t = types[j];
    if (t == BidiClass.es || t == BidiClass.et || t == BidiClass.cs) {
      types[j] = BidiClass.on;
    }
  }

  // W7: EN ← L → L.
  lastStrong = paragraphEmbedding.isOdd ? BidiClass.r : BidiClass.l;
  for (var j = 0; j < n; j++) {
    final t = types[j];
    if (t == BidiClass.l || t == BidiClass.r) {
      lastStrong = t;
    } else if (t == BidiClass.en && lastStrong == BidiClass.l) {
      types[j] = BidiClass.l;
    }
  }

  // N1/N2: neutrals.
  for (var j = 0; j < n;) {
    if (!_isNeutral(types[j])) {
      j++;
      continue;
    }
    var k = j;
    while (k < n && _isNeutral(types[k])) {
      k++;
    }
    BidiClass? before;
    for (var t = j - 1; t >= 0; t--) {
      if (_isStrong(types[t]) ||
          types[t] == BidiClass.en ||
          types[t] == BidiClass.an) {
        before = (types[t] == BidiClass.en || types[t] == BidiClass.an)
            ? BidiClass.r
            : types[t];
        break;
      }
    }
    before ??= paragraphEmbedding.isOdd ? BidiClass.r : BidiClass.l;
    BidiClass? after;
    for (var t = k; t < n; t++) {
      if (_isStrong(types[t]) ||
          types[t] == BidiClass.en ||
          types[t] == BidiClass.an) {
        after = (types[t] == BidiClass.en || types[t] == BidiClass.an)
            ? BidiClass.r
            : types[t];
        break;
      }
    }
    after ??= paragraphEmbedding.isOdd ? BidiClass.r : BidiClass.l;
    final resolved = (before == after)
        ? before
        : (levels[j].isOdd ? BidiClass.r : BidiClass.l);
    for (var t = j; t < k; t++) {
      types[t] = resolved;
    }
    j = k;
  }

  // I1/I2: raise levels for opposite-direction types.
  for (var j = 0; j < n; j++) {
    final level = levels[j];
    final t = types[j];
    if (level.isEven) {
      if (t == BidiClass.r) {
        levels[j] = level + 1;
      } else if (t == BidiClass.an || t == BidiClass.en) {
        levels[j] = level + 2;
      }
    } else {
      if (t == BidiClass.l || t == BidiClass.an || t == BidiClass.en) {
        levels[j] = level + 1;
      }
    }
  }

  return levels;
}

/// Itemize [text] into same-level [BidiRun]s in logical order.
List<BidiRun> itemize(String text, {TextDirection? baseDirection}) {
  if (text.isEmpty) return const [];
  final para = paragraphLevel(text, baseDirection);
  final levels = resolveLevels(text, para);
  final runs = <BidiRun>[];
  var start = 0;
  for (var i = 1; i <= levels.length; i++) {
    if (i < levels.length && levels[i] == levels[start]) continue;
    final level = levels[start];
    runs.add(
      BidiRun(
        start: start,
        end: i,
        level: level,
        direction: level.isOdd ? TextDirection.rtl : TextDirection.ltr,
      ),
    );
    start = i;
  }
  return runs;
}

/// UAX #9 L2: reorder a sequence of level values into visual order.
/// Returns permutation indices: `visual[i] = logicalIndex`.
List<int> reorderVisual(List<int> levels) {
  final n = levels.length;
  if (n == 0) return const [];
  final order = List<int>.generate(n, (i) => i);
  var highest = 0;
  var lowestOdd = 99;
  for (final l in levels) {
    if (l > highest) highest = l;
    if (l.isOdd && l < lowestOdd) lowestOdd = l;
  }
  for (var level = highest; level >= lowestOdd; level--) {
    var i = 0;
    while (i < n) {
      if (levels[order[i]] < level) {
        i++;
        continue;
      }
      var j = i;
      while (j < n && levels[order[j]] >= level) {
        j++;
      }
      // Reverse [i, j).
      for (var a = i, b = j - 1; a < b; a++, b--) {
        final t = order[a];
        order[a] = order[b];
        order[b] = t;
      }
      i = j;
    }
  }
  return order;
}

/// Reorder a list of items that each carry a bidi [level] into visual order.
List<T> reorderByLevel<T>(List<T> items, int Function(T) levelOf) {
  if (items.length <= 1) return List<T>.of(items);
  final levels = [for (final i in items) levelOf(i)];
  final order = reorderVisual(levels);
  return [for (final i in order) items[i]];
}

/// Heuristic: Arabic letters should not break mid-word (no spaces). Used by
/// analysis/prepare to keep Arabic clusters sticky.
bool isArabicLetter(int cp) {
  final c = bidiClassOf(cp);
  return c == BidiClass.al ||
      (cp >= 0x0620 && cp <= 0x064A) ||
      (cp >= 0x066E && cp <= 0x06D3);
}

bool isHebrewLetter(int cp) => bidiClassOf(cp) == BidiClass.r;

/// OpenType script tag for a bidi/script run.
String? scriptTagForRun(String text) {
  for (final rune in text.runes) {
    if (isArabicLetter(rune) || bidiClassOf(rune) == BidiClass.al) {
      return 'arab';
    }
    if (isHebrewLetter(rune)) return 'hebr';
  }
  return null;
}
