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
