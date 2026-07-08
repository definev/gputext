import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry.dart';
import 'font.dart';

// Aim for ~this many pieces per band (before y-overlap duplication inflates
// it). Coarse on purpose: an extra piece in a band is nearly free (early
// break / cheap far path), while fewer bands means fewer band setups per
// pixel and a smaller atlas. Upstream re-tuned 6 → 10 (bench/: ~8–19% faster
// at small/medium sizes, ~15% smaller atlas).
const targetPerBand = 10;
const maxBands = 64;

/// Must equal SORT_MIN in gputext.frag — the shader only breaks early on
/// bands it assumes are x-sorted. Upstream re-tuned 8 → 4: the early break
/// pays on nearly any band, and the sort is build-time-only.
const bandSortMin = 4;

int chooseBands(int pieceCount, [int target = targetPerBand]) {
  if (pieceCount <= target) return 1;
  return ((pieceCount + target - 1) ~/ target).clamp(1, maxBands);
}

// Append-only growable typed buffers for the atlas backing stores.
//
// A growable `List<double>` boxes every element — measured at ~30.6 bytes each
// against 8 for a Float64List and 4 for a Float32List. The shared atlas holds
// ~500k curve floats after a single variable-font weight sweep, so the boxed
// form cost ~15 MB of Dart heap for data that is 2 MB as f32. Curves are
// truncated to f32 at upload anyway (the textures are RGBA32F), so storing
// them as f32 here is bit-identical on the GPU and simply moves the single
// rounding step from upload time to insert time.

const _minBufCapacity = 1024;

/// Append-only Float32List with capacity doubling.
class Float32Buf {
  Float32Buf([int capacity = _minBufCapacity])
    : _data = Float32List(capacity < 1 ? _minBufCapacity : capacity);

  Float32List _data;
  int _length = 0;

  int get length => _length;
  bool get isEmpty => _length == 0;

  double operator [](int i) => _data[i];

  @pragma('vm:prefer-inline')
  void add(double v) {
    if (_length == _data.length) _grow();
    _data[_length++] = v;
  }

  void _grow() {
    final next = Float32List(_data.length * 2);
    next.setRange(0, _length, _data);
    _data = next;
  }

  /// Zero-copy view of the filled prefix. Invalidated by any [add] that grows
  /// the backing store, so re-read it rather than holding onto it.
  Float32List get view => Float32List.sublistView(_data, 0, _length);

  /// Right-sized copy, for owners that must not see capacity slack.
  Float32List toTypedList() => Float32List.fromList(view);
}

/// Append-only Uint32List with capacity doubling. Row entries are u32 already
/// (indices, counts, and bit-punned f32s), so nothing is lost versus the
/// `List<int>` this replaces.
class Uint32Buf {
  Uint32Buf([int capacity = _minBufCapacity])
    : _data = Uint32List(capacity < 1 ? _minBufCapacity : capacity);

  Uint32List _data;
  int _length = 0;

  int get length => _length;
  bool get isEmpty => _length == 0;

  int operator [](int i) => _data[i];

  @pragma('vm:prefer-inline')
  void add(int v) {
    if (_length == _data.length) _grow();
    _data[_length++] = v;
  }

  void _grow() {
    final next = Uint32List(_data.length * 2);
    next.setRange(0, _length, _data);
    _data = next;
  }

  /// See [Float32Buf.view].
  Uint32List get view => Uint32List.sublistView(_data, 0, _length);

  Uint32List toTypedList() => Uint32List.fromList(view);
}

int bandIndex(double y, double y0, double invH, int r) {
  if (invH <= 0) return 0;
  return ((y - y0) * invH).floor().clamp(0, r - 1);
}

/// Solve the monotone quadratic component a·t² + b·t + e0 = v on [0, 1]
/// (f64 twin of the shader's mono_root): saturate to the endpoint if the
/// piece starts past / never reaches v, else take the branch whose
/// derivative sign matches `rising`.
double _monoRootT(
  double a,
  double b,
  double e0,
  double e1,
  double v,
  bool rising,
) {
  if (rising ? e0 >= v : e0 <= v) return 0;
  if (rising ? e1 <= v : e1 >= v) return 1;
  final c = e0 - v;
  if (a.abs() < 1e-12 * math.max(b.abs(), 1)) {
    return (-c / b).clamp(0.0, 1.0);
  }
  final disc = math.max(b * b - 4 * a * c, 0.0);
  final q = -0.5 * (b + (b == 0 ? 1.0 : b.sign) * math.sqrt(disc));
  final r1 = q / a;
  final r2 = q != 0 ? c / q : 0.0;
  final want = rising ? 1.0 : -1.0;
  final t = (2 * a * r1 + b) * want >= 0 ? r1 : r2;
  return t.clamp(0.0, 1.0);
}

/// Exact winding integral ∫∫_strip w dA of one band's pieces over its
/// y-strip [b0, b1]: each piece contributes ∫ (x(t) − x0)·y′(t) dt over the
/// t-range where y(t) ∈ [b0, b1] — a quartic antiderivative, exact in f64.
/// The x reference is immaterial for closed contours; it only keeps
/// magnitudes small. Windows tile across bands, so duplicated pieces never
/// double-count.
double _bandWindingArea(
  List<double> pieces,
  List<int> bucket,
  double x0,
  double b0,
  double b1,
) {
  var area = 0.0;
  for (final k in bucket) {
    final p = k * 6;
    final px0 = pieces[p], py0 = pieces[p + 1];
    final cx = pieces[p + 2], cy = pieces[p + 3];
    final px1 = pieces[p + 4], py1 = pieces[p + 5];
    final lo = math.max(b0, math.min(py0, py1));
    final hi = math.min(b1, math.max(py0, py1));
    if (hi <= lo) continue;
    final rising = py1 >= py0;
    final ay = py0 - 2 * cy + py1, by = 2 * (cy - py0);
    final tA = _monoRootT(ay, by, py0, py1, rising ? lo : hi, rising);
    final tB = _monoRootT(ay, by, py0, py1, rising ? hi : lo, rising);
    if (tB <= tA) continue;
    final ax = px0 - 2 * cx + px1, bx = 2 * (cx - px0), cxr = px0 - x0;
    // (ax·t² + bx·t + cxr)·(2·ay·t + by), integrated term-by-term.
    final c3 = 2 * ax * ay;
    final c2 = ax * by + 2 * bx * ay;
    final c1 = bx * by + 2 * cxr * ay;
    final c0 = cxr * by;
    double f(double t) => ((c3 / 4 * t + c2 / 3) * t + c1 / 2) * t * t + c0 * t;
    area += f(tB) - f(tA);
  }
  return area;
}

// Bit-pun an f32 into a u32 so the area rides in the (integer) row table.
final _punBuf = ByteData(4);
int f32bits(double v) {
  _punBuf.setFloat32(0, v, Endian.little);
  return _punBuf.getUint32(0, Endian.little);
}

double f32fromBits(int bits) {
  _punBuf.setUint32(0, bits, Endian.little);
  return _punBuf.getFloat32(0, Endian.little);
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

/// File a shape's monotone pieces into row bands over [y0, y1], appending
/// band-duplicated pieces to `curveOut` and each band's
/// [start, count, areaBits, xMinBits, xMaxBits] quintuple to `rowOut`.
/// Beyond start/count each band carries three bit-punned f32s:
///   • area — the strip's EXACT winding integral, for the shader's banded
///     minification guard (tiny glyphs render from this ink profile).
///   • xMin/xMax — the band's ink hull in x; the guard spreads the area over
///     it so approximated glyphs keep per-band letterform hints.
BandHeader bandPieces(
  List<double> pieces,
  double y0,
  double y1,
  Float32Buf curveOut,
  Uint32Buf rowOut, [
  int target = targetPerBand,
]) {
  final n = pieces.length ~/ 6;
  final r = chooseBands(n, target);
  final invH = r > 1 && y1 > y0 ? r / (y1 - y0) : 0.0;

  final buckets = List<List<int>>.generate(r, (_) => []);
  var xLeft = double.infinity; // area reference: leftmost point keeps f32 small
  for (var k = 0; k < n; k++) {
    final yLo = math.min(
      pieces[k * 6 + 1],
      math.min(pieces[k * 6 + 3], pieces[k * 6 + 5]),
    );
    final yHi = math.max(
      pieces[k * 6 + 1],
      math.max(pieces[k * 6 + 3], pieces[k * 6 + 5]),
    );
    final lo = bandIndex(yLo, y0, invH, r);
    final hi = bandIndex(yHi, y0, invH, r);
    for (var b = lo; b <= hi; b++) {
      buckets[b].add(k);
    }
    xLeft = math.min(
      xLeft,
      math.min(pieces[k * 6], math.min(pieces[k * 6 + 2], pieces[k * 6 + 4])),
    );
  }

  final rowBase = rowOut.length ~/ 5;
  final bandH = r > 1 ? (y1 - y0) / r : y1 - y0;
  double xMax(int k) =>
      math.max(pieces[k * 6], math.max(pieces[k * 6 + 2], pieces[k * 6 + 4]));
  double xMin(int k) =>
      math.min(pieces[k * 6], math.min(pieces[k * 6 + 2], pieces[k * 6 + 4]));

  for (var b = 0; b < r; b++) {
    final bucket = buckets[b];
    if (bucket.length > bandSortMin) {
      bucket.sort((a, c) => xMax(c).compareTo(xMax(a)));
    }
    final start = curveOut.length ~/ 6;
    // Empty band ⇒ inverted far sentinels (finite — shaders may assume so).
    var bxMin = 3e38, bxMax = -3e38;
    for (final k in bucket) {
      for (var j = 0; j < 6; j++) {
        curveOut.add(pieces[k * 6 + j]);
      }
      bxMin = math.min(bxMin, xMin(k));
      bxMax = math.max(bxMax, xMax(k));
    }
    final area = n != 0
        ? _bandWindingArea(
            pieces,
            bucket,
            xLeft,
            y0 + b * bandH,
            y0 + (b + 1) * bandH,
          )
        : 0.0;
    rowOut.add(start);
    rowOut.add(bucket.length);
    rowOut.add(f32bits(area));
    rowOut.add(f32bits(bxMin));
    rowOut.add(f32bits(bxMax));
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

GlyphAtlas buildGlyphAtlas(GPUFont font, String text) {
  final chars = text.runes
      .toSet()
      .map(String.fromCharCode)
      .where((ch) => ch != ' ')
      .toList();
  final curves = Float32Buf();
  final rows = Uint32Buf();
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
    // Right-sized copies: GlyphAtlas is handed to callers, capacity slack isn't.
    curves: curves.toTypedList(),
    rows: rows.toTypedList(),
    table: table,
    stats: AtlasStats(
      uniqueGlyphs: table.length,
      monotonePieces: monotoneTotal,
      bandCount: rows.length ~/ 5,
      bandedPieces: bandedPieces,
      duplication: monotoneTotal == 0 ? 1 : bandedPieces / monotoneTotal,
    ),
  );
}
