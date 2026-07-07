// One merged, incremental glyph atlas shared by every font and widget.
//
// bands.dart writes absolute append-only indices (rowBase, band start), so
// glyphs from different fonts can interleave freely in one curves/rows pair:
// existing GlyphTableEntry values never move when the atlas grows, which means
// atlas growth never invalidates an already-rendered paragraph.

import 'dart:typed_data';

import '../bands.dart';
import '../font.dart';
import '../geometry.dart';
import '../paragraph.dart';

class SharedGlyphAtlas implements GlyphTable {
  final _curves = <double>[];
  final _rows = <int>[];
  // Keyed by code point (not char string): the emit pen walk and banding
  // resolve runes directly. Distinct from _gidTable despite the same key
  // shape — one is rune-keyed, the other glyph-id-keyed.
  final _table = <(GPUFont, int), GlyphTableEntry>{};
  final _blank = <(GPUFont, int)>{}; // cmap misses / empty outlines
  final _gidTable = <(GPUFont, int), GlyphTableEntry>{};
  final _blankGids = <(GPUFont, int)>{};
  var _generation = 0;

  /// Bumped whenever curve/row data grows (texture re-upload trigger).
  int get generation => _generation;

  bool get isEmpty => _rows.isEmpty;

  /// Curve floats appended so far. GPU-side bytes are count*4 (RGBA32F
  /// upload); the CPU-side `List<double>` holds 8 bytes per element.
  int get curveFloatCount => _curves.length;

  /// Row entries appended so far (uploaded as Uint32, 4 bytes each).
  int get rowCount => _rows.length;

  /// Banded glyph entries across both keying schemes (char and glyph-id).
  int get glyphEntryCount => _table.length + _gidTable.length;

  /// Make sure every unique character of `text` has a banded entry for
  /// `font`. Returns true when new glyph data was appended.
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
      final pieces = <double>[];
      for (var i = 0; i < g.quads.length; i += 6) {
        pushMonotonePiecesAt(g.quads, i, pieces);
      }
      final header = bandPieces(pieces, g.bbox[1], g.bbox[3], _curves, _rows);
      _table[key] = GlyphTableEntry(
        rowBase: header.rowBase,
        bandCount: header.bandCount,
        y0: header.y0,
        invH: header.invH,
        advance: g.advance,
        bbox: g.bbox,
      );
      grew = true;
    }
    if (grew) _generation++;
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
    final pieces = <double>[];
    for (var i = 0; i < g.quads.length; i += 6) {
      pushMonotonePiecesAt(g.quads, i, pieces);
    }
    final header = bandPieces(pieces, g.bbox[1], g.bbox[3], _curves, _rows);
    _gidTable[key] = GlyphTableEntry(
      rowBase: header.rowBase,
      bandCount: header.bandCount,
      y0: header.y0,
      invH: header.invH,
      advance: g.advance,
      bbox: g.bbox,
    );
    _generation++;
    return true;
  }

  @override
  GlyphTableEntry? lookup(GPUFont font, String ch) =>
      ch.isEmpty ? null : _table[(font, ch.runes.first)];

  @override
  GlyphTableEntry? lookupRune(GPUFont font, int rune) =>
      _table[(font, rune)];

  @override
  GlyphTableEntry? lookupGlyphId(GPUFont font, int glyphId) =>
      _gidTable[(font, glyphId)];

  /// Live append-only backing stores, exposed for the incremental texture
  /// uploader (do not mutate).
  List<double> get curves => _curves;
  List<int> get rows => _rows;

  Float32List curvesData() => Float32List.fromList(_curves);

  Uint32List rowsData() => Uint32List.fromList(_rows);
}
