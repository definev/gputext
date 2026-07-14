// Shared emoji code-point predicates. Kept in ONE place so the two sites that
// itemize emoji agree on exactly what "an emoji" is:
//
//   * span segmentation (widgets/emoji.dart) clusters emoji and delegates
//     multi-CP ones to platform Text;
//   * the flattener (widgets/span_flattener.dart) routes single-CP emoji to the
//     color / bitmap GPU pipeline.
//
// If the flattener decided "is this an emoji?" from font coverage alone it
// would hijack plain text, because color-emoji fonts carry non-emoji glyphs —
// e.g. NotoColorEmoji (CBDT) maps ASCII digits 0-9 and #/* as the *bases* of
// the keycap sequences 0️⃣..9️⃣. Matching those to the emoji font turns "0123"
// into color bitmaps. Coverage is a necessary condition, not a sufficient one;
// these predicates are the sufficient one.

const emojiVs16 = 0xFE0F; // emoji presentation selector
const emojiVs15 = 0xFE0E; // text presentation selector
const emojiZwj = 0x200D; // zero-width joiner
const emojiKeycapMark = 0x20E3; // combining enclosing keycap

/// Emoji-presentation base pictographs, approximated by code-point range
/// (Dart RegExp binary-property support isn't guaranteed across runtimes).
bool isEmojiBaseCp(int cp) =>
    (cp >= 0x1F000 && cp <= 0x1FAFF) || // SMP pictographic blocks
    (cp >= 0x2600 && cp <= 0x27BF) || // misc symbols + dingbats
    (cp >= 0x2B00 && cp <= 0x2BFF) || // misc symbols and arrows
    cp == 0x2934 ||
    cp == 0x2935;

/// Regional-indicator symbols (A..Z), which pair into flag emoji.
bool isRegionalIndicatorCp(int cp) => cp >= 0x1F1E6 && cp <= 0x1F1FF;

/// Fitzpatrick skin-tone modifiers.
bool isSkinToneModifierCp(int cp) => cp >= 0x1F3FB && cp <= 0x1F3FF;

/// Keycap sequence bases: 0-9, #, *.
bool isEmojiKeycapBaseCp(int cp) =>
    cp == 0x23 || cp == 0x2A || (cp >= 0x30 && cp <= 0x39);

/// Exclusive end index of the extended-pictographic emoji cluster beginning at
/// [start] in [cps], or [start] itself when no emoji cluster starts there.
/// Clusters: keycap sequences, regional-indicator flag pairs, and
/// base + VS16/skin-tone + (ZWJ + pictograph)* chains. A base immediately
/// followed by VS15 (text presentation) is NOT an emoji cluster.
///
/// Single source of truth for both span segmentation (widgets/emoji.dart) and
/// the flattener (widgets/span_flattener.dart), so they cluster identically.
int emojiClusterEnd(List<int> cps, int start) {
  final n = cps.length;
  final cp = cps[start];
  var j = start + 1;

  if (isEmojiKeycapBaseCp(cp) &&
      ((j < n && cps[j] == emojiKeycapMark) ||
          (j + 1 < n &&
              cps[j] == emojiVs16 &&
              cps[j + 1] == emojiKeycapMark))) {
    return start + (cps[j] == emojiVs16 ? 3 : 2);
  }
  if (isRegionalIndicatorCp(cp)) {
    if (j < n && isRegionalIndicatorCp(cps[j])) j++; // flag = RI pair
    return j;
  }
  if (j < n && cps[j] == emojiVs15 && isEmojiBaseCp(cp)) {
    return start; // explicit text presentation — not an emoji cluster
  }
  if (isEmojiBaseCp(cp) || (j < n && cps[j] == emojiVs16)) {
    while (j < n) {
      final c = cps[j];
      if (c == emojiVs16 || isSkinToneModifierCp(c)) {
        j++;
        continue;
      }
      if (c == emojiZwj &&
          j + 1 < n &&
          (isEmojiBaseCp(cps[j + 1]) || isRegionalIndicatorCp(cps[j + 1]))) {
        j += 2;
        continue;
      }
      break;
    }
    return j;
  }
  return start;
}
