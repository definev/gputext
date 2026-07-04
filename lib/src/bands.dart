import 'dart:typed_data';

import 'geometry.dart';
import 'font.dart';

const targetPerBand = 6;
const maxBands = 64;

/// Must equal SORT_MIN in windfoil.frag.
const bandSortMin = 8;

int chooseBands(int pieceCount) {
  if (pieceCount <= targetPerBand) return 1;
  return (pieceCount / targetPerBand).ceil().clamp(1, maxBands);
}

int bandIndex(double y, double y0, double invH, int r) {
  if (invH <= 0) return 0;
  return ((y - y0) * invH).floor().clamp(0, r - 1);
}

class BandHeader {
  const BandHeader({
    required this.rowBase,
    required this.bandCount,
    required this.y0,
    required this.invH,
  });

  final int rowBase;
  final int bandCount;
  final double y0;
  final double invH;
}

BandHeader bandPieces(
  List<double> pieces,
  double y0,
  double y1,
  List<double> curveOut,
  List<int> rowOut,
) {
  final n = pieces.length ~/ 6;
  final r = chooseBands(n);
  final invH = r > 1 && y1 > y0 ? r / (y1 - y0) : 0.0;

  final buckets = List<List<int>>.generate(r, (_) => []);
  for (var k = 0; k < n; k++) {
    final yLo = [
      pieces[k * 6 + 1],
      pieces[k * 6 + 3],
      pieces[k * 6 + 5],
    ].reduce((a, b) => a < b ? a : b);
    final yHi = [
      pieces[k * 6 + 1],
      pieces[k * 6 + 3],
      pieces[k * 6 + 5],
    ].reduce((a, b) => a > b ? a : b);
    final lo = bandIndex(yLo, y0, invH, r);
    final hi = bandIndex(yHi, y0, invH, r);
    for (var b = lo; b <= hi; b++) {
      buckets[b].add(k);
    }
  }

  final rowBase = rowOut.length ~/ 2;
  double xMax(int k) => [
    pieces[k * 6],
    pieces[k * 6 + 2],
    pieces[k * 6 + 4],
  ].reduce((a, b) => a > b ? a : b);

  for (var b = 0; b < r; b++) {
    final bucket = buckets[b];
    if (bucket.length > bandSortMin) {
      bucket.sort((a, c) => xMax(c).compareTo(xMax(a)));
    }
    final start = curveOut.length ~/ 6;
    for (final k in bucket) {
      for (var j = 0; j < 6; j++) {
        curveOut.add(pieces[k * 6 + j]);
      }
    }
    rowOut.addAll([start, bucket.length]);
  }
  return BandHeader(rowBase: rowBase, bandCount: r, y0: y0, invH: invH);
}

class GlyphTableEntry {
  const GlyphTableEntry({
    required this.rowBase,
    required this.bandCount,
    required this.y0,
    required this.invH,
    required this.advance,
    required this.bbox,
  });

  final int rowBase;
  final int bandCount;
  final double y0;
  final double invH;
  final double advance;
  final List<double> bbox;
}

class AtlasStats {
  const AtlasStats({
    required this.uniqueGlyphs,
    required this.monotonePieces,
    required this.bandCount,
    required this.bandedPieces,
    required this.duplication,
  });

  final int uniqueGlyphs;
  final int monotonePieces;
  final int bandCount;
  final int bandedPieces;
  final double duplication;
}

class GlyphAtlas {
  const GlyphAtlas({
    required this.curves,
    required this.rows,
    required this.table,
    required this.stats,
  });

  final Float32List curves;
  final Uint32List rows;
  final Map<String, GlyphTableEntry> table;
  final AtlasStats stats;
}

GlyphAtlas buildGlyphAtlas(WindfoilFont font, String text) {
  final chars = text.split('').toSet().where((ch) => ch != ' ').toList();
  final curves = <double>[];
  final rows = <int>[];
  final table = <String, GlyphTableEntry>{};
  var monotoneTotal = 0;

  for (final ch in chars) {
    final g = font.glyphQuads(ch);
    if (g == null) continue;
    final pieces = <double>[];
    for (var i = 0; i < g.quads.length; i += 6) {
      pushMonotonePieces(g.quads.sublist(i, i + 6), pieces);
    }
    monotoneTotal += pieces.length ~/ 6;
    final header = bandPieces(pieces, g.bbox[1], g.bbox[3], curves, rows);
    table[ch] = GlyphTableEntry(
      rowBase: header.rowBase,
      bandCount: header.bandCount,
      y0: header.y0,
      invH: header.invH,
      advance: g.advance,
      bbox: g.bbox,
    );
  }

  final bandedPieces = curves.length ~/ 6;
  return GlyphAtlas(
    curves: Float32List.fromList(curves),
    rows: Uint32List.fromList(rows),
    table: table,
    stats: AtlasStats(
      uniqueGlyphs: table.length,
      monotonePieces: monotoneTotal,
      bandCount: rows.length ~/ 2,
      bandedPieces: bandedPieces,
      duplication: monotoneTotal == 0 ? 1 : bandedPieces / monotoneTotal,
    ),
  );
}
