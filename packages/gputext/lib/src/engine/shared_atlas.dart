// One merged, incremental glyph atlas shared by every font and widget.
//
// bands.dart writes absolute append-only indices (rowBase, band start), so
// glyphs from different fonts can interleave freely in one curves/rows pair:
// existing GlyphTableEntry values never move when the atlas GROWS, which means
// atlas growth never invalidates an already-rendered paragraph.
//
// [retainFonts] is the one operation that breaks that: it rebuilds the buffers
// around the surviving glyphs, so every rowBase and band start moves. Anything
// holding emitted instance data (which bakes rowBase in) must re-emit, and the
// curve/row textures must be recreated rather than overwritten in place.
// [structureGeneration] is the signal for both. Growth still only bumps
// [generation].
//
// The backing stores are typed (Float32Buf/Uint32Buf) rather than
// List<double>/List<int>: a growable List<double> boxes every element, and
// this atlas reaches hundreds of thousands of curve floats once variable-font
// instances start banding their own outlines.

import 'dart:typed_data';

import '../bands.dart';
import '../font.dart';
import '../paragraph.dart';

class SharedGlyphAtlas implements GlyphTable {
  var _curves = Float32Buf();
  var _rows = Uint32Buf();
  // Keyed by code point (not char string): the emit pen walk and banding
  // resolve runes directly. Distinct from _gidTable despite the same key
  // shape — one is rune-keyed, the other glyph-id-keyed.
  final _table = <(GPUFont, int), GlyphTableEntry>{};
  final _blank = <(GPUFont, int)>{}; // cmap misses / empty outlines
  final _gidTable = <(GPUFont, int), GlyphTableEntry>{};
  final _blankGids = <(GPUFont, int)>{};
  var _generation = 0;
  var _structureGeneration = 0;

  /// Bumped whenever curve/row data changes at all (texture re-upload trigger).
  int get generation => _generation;

  /// Bumped only when [retainFonts] moves existing entries. Consumers that
  /// cached a rowBase — emitted instance buffers, uploaded textures — are stale
  /// once this changes and must be rebuilt from scratch.
  int get structureGeneration => _structureGeneration;

  bool get isEmpty => _rows.isEmpty;

  /// Curve floats appended so far; 4 bytes each on the CPU. GPU-side these
  /// cost count*8 bytes, not count*4: the uploader writes one vec2 per
  /// RGBA32F texel, leaving `.zw` unused (see atlas.dart / gputext.frag).
  int get curveFloatCount => _curves.length;

  /// Row entries appended so far; 4 bytes each on the CPU. GPU-side a band is
  /// 5 entries spread over two RGBA32F texels, i.e. 6.4 bytes per entry.
  int get rowCount => _rows.length;

  /// Banded glyph entries across both keying schemes (char and glyph-id).
  int get glyphEntryCount => _table.length + _gidTable.length;

  /// Glyphs recorded as having no outline (empty glyf entries). They carry no
  /// curve data but still hold a font reference, so [retainFonts] prunes them.
  int get blankEntryCount => _blank.length + _blankGids.length;

  /// Distinct fonts with any entry — banded or blank. Eviction reclaims the
  /// atlas storage for the fonts absent from a [retainFonts] keep-set.
  Set<GPUFont> get fonts => {
    for (final k in _table.keys) k.$1,
    for (final k in _gidTable.keys) k.$1,
    for (final k in _blank) k.$1,
    for (final k in _blankGids) k.$1,
  };

  /// Make sure every unique character of `text` has a banded entry for
  /// `font`. Returns true when new glyph data was appended.
  /// Prefer [ensureShaped] / [ensureGlyphId] for shaped glyph runs.
  bool ensureGlyphs(GPUFont font, String text) {
    var grew = false;
    for (final rune in text.runes) {
      if (isZeroWidthCodePoint(rune)) continue;
      if (rune == 0x20 || rune == 0x0A) continue;
      final key = (font, rune);
      if (_table.containsKey(key) || _blank.contains(key)) continue;
      // cmap miss → .notdef (glyph 0) tofu, matching advanceOf.
      final g = font.glyphOutlineById(font.glyphIdForRune(rune) ?? 0);
      if (g == null) {
        _blank.add(key);
        continue;
      }
      final (entry, _) = bandOutline(g, _curves, _rows);
      _table[key] = entry;
      grew = true;
    }
    if (grew) _generation++;
    return grew;
  }

  /// Band every glyph in [shaped] by glyph id (paint path).
  bool ensureShaped(ShapedGlyphRun shaped) {
    var grew = false;
    for (final g in shaped.glyphs) {
      if (ensureGlyphId(shaped.font, g.glyphId)) grew = true;
    }
    return grew;
  }

  /// Band a glyph referenced by ID (COLR layers have no code point).
  bool ensureGlyphId(GPUFont font, int glyphId) {
    final key = (font, glyphId);
    if (_gidTable.containsKey(key) || _blankGids.contains(key)) return false;
    final g = font.glyphOutlineById(glyphId);
    if (g == null) {
      _blankGids.add(key);
      return false;
    }
    final (entry, _) = bandOutline(g, _curves, _rows);
    _gidTable[key] = entry;
    _generation++;
    return true;
  }

  /// Rebuild the atlas so it holds only glyphs whose font is in [keep],
  /// remapping every surviving entry's rowBase and band starts and shrinking
  /// the backing stores to fit. Returns the number of curve floats reclaimed.
  ///
  /// When nothing is dropped this is a no-op: no data moves, no generation is
  /// bumped, and 0 is returned.
  ///
  /// Otherwise EVERY rowBase handed out before this call is invalid. Callers
  /// must rebuild all emitted instance data (it bakes rowBase in) and both
  /// atlas textures (existing texels move, so an in-place overwrite would
  /// corrupt any draw still in flight). [structureGeneration] is the signal.
  ///
  /// Glyphs whose font is dropped are re-banded on the next [ensureGlyphs],
  /// so evicting a font that is still on screen costs work but is never
  /// incorrect.
  int retainFonts(Set<GPUFont> keep) {
    final drops = _table.keys.where((k) => !keep.contains(k.$1)).toList();
    final gidDrops = _gidTable.keys.where((k) => !keep.contains(k.$1)).toList();
    if (drops.isEmpty && gidDrops.isEmpty) {
      // No curve data to reclaim, but the blank sets still pin font objects.
      _blank.removeWhere((k) => !keep.contains(k.$1));
      _blankGids.removeWhere((k) => !keep.contains(k.$1));
      return 0;
    }

    final before = _curves.length;
    final oldCurves = _curves.view;
    final oldRows = _rows.view;

    // Size the new stores exactly — capacity slack is part of what we came to
    // reclaim, so growing into a doubled buffer would defeat the purpose.
    var keptPieces = 0;
    var keptBands = 0;
    void measure(GlyphTableEntry e) {
      keptBands += e.bandCount;
      for (var b = 0; b < e.bandCount; b++) {
        keptPieces += oldRows[(e.rowBase + b) * 5 + 1];
      }
    }

    for (final e in _table.entries) {
      if (keep.contains(e.key.$1)) measure(e.value);
    }
    for (final e in _gidTable.entries) {
      if (keep.contains(e.key.$1)) measure(e.value);
    }

    final newCurves = Float32Buf(keptPieces * 6);
    final newRows = Uint32Buf(keptBands * 5);

    GlyphTableEntry relocate(GlyphTableEntry e) {
      final rowBase = newRows.length ~/ 5;
      for (var b = 0; b < e.bandCount; b++) {
        final r = (e.rowBase + b) * 5;
        final start = oldRows[r];
        final count = oldRows[r + 1];
        // Written before the pieces, so it names the slot they land in. Empty
        // bands point one past the end, exactly as bandPieces leaves them.
        newRows.add(newCurves.length ~/ 6);
        newRows.add(count);
        newRows.add(oldRows[r + 2]); // areaBits
        newRows.add(oldRows[r + 3]); // xMinBits
        newRows.add(oldRows[r + 4]); // xMaxBits
        newCurves.addRange(oldCurves, start * 6, (start + count) * 6);
      }
      return GlyphTableEntry(
        rowBase: rowBase,
        bandCount: e.bandCount,
        y0: e.y0,
        invH: e.invH,
        advance: e.advance,
        bbox: e.bbox,
      );
    }

    for (final k in drops) {
      _table.remove(k);
    }
    for (final k in gidDrops) {
      _gidTable.remove(k);
    }
    // Reassigning an existing key keeps its slot, so survivors stay in
    // insertion order and the rebuilt layout matches a from-scratch build.
    for (final k in _table.keys.toList()) {
      _table[k] = relocate(_table[k]!);
    }
    for (final k in _gidTable.keys.toList()) {
      _gidTable[k] = relocate(_gidTable[k]!);
    }
    _blank.removeWhere((k) => !keep.contains(k.$1));
    _blankGids.removeWhere((k) => !keep.contains(k.$1));

    _curves = newCurves;
    _rows = newRows;
    _generation++;
    _structureGeneration++;
    return before - _curves.length;
  }

  @override
  GlyphTableEntry? lookup(GPUFont font, String ch) =>
      ch.isEmpty ? null : _table[(font, ch.runes.first)];

  @override
  GlyphTableEntry? lookupRune(GPUFont font, int rune) => _table[(font, rune)];

  @override
  GlyphTableEntry? lookupGlyphId(GPUFont font, int glyphId) =>
      _gidTable[(font, glyphId)];

  /// Live append-only backing stores, exposed for the incremental texture
  /// uploader (do not mutate). These are zero-copy views over the filled
  /// prefix, so re-read them after any [ensureGlyphs] / [ensureGlyphId] call
  /// rather than caching the reference — an append that grows the buffer
  /// leaves the old view pointing at the old store.
  Float32List get curves => _curves.view;
  Uint32List get rows => _rows.view;
}
