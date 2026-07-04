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
  final _table = <(WindfoilFont, String), GlyphTableEntry>{};
  final _blank = <(WindfoilFont, String)>{}; // cmap misses / empty outlines
  var _generation = 0;

  /// Bumped whenever curve/row data grows (texture re-upload trigger).
  int get generation => _generation;

  bool get isEmpty => _rows.isEmpty;

  /// Make sure every unique character of `text` has a banded entry for
  /// `font`. Returns true when new glyph data was appended.
  bool ensureGlyphs(WindfoilFont font, String text) {
    var grew = false;
    for (final rune in text.runes.toSet()) {
      if (isZeroWidthCodePoint(rune)) continue;
      final ch = String.fromCharCode(rune);
      if (ch == ' ' || ch == '\n') continue;
      final key = (font, ch);
      if (_table.containsKey(key) || _blank.contains(key)) continue;
      final g = font.glyphQuads(ch);
      if (g == null) {
        _blank.add(key);
        continue;
      }
      final pieces = <double>[];
      for (var i = 0; i < g.quads.length; i += 6) {
        pushMonotonePieces(g.quads.sublist(i, i + 6), pieces);
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

  @override
  GlyphTableEntry? lookup(WindfoilFont font, String ch) => _table[(font, ch)];

  Float32List curvesData() => Float32List.fromList(_curves);

  Uint32List rowsData() => Uint32List.fromList(_rows);
}
