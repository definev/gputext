// OpenType font variations: fvar axes, avar axis remapping, gvar outline
// deltas (with IUP inference), and the item-variation-store consumers HVAR
// (advance widths) and MVAR (global metrics).
//
// Variable instances are exposed through [GPUFontVariations.variant]:
// a per-coordinate GPUFont that shares every parsed table with its base
// and is cached by NORMALIZED coordinates, so identity-keyed consumers (the
// shared glyph atlas, segment-metrics Expando, kerning-run checks) treat each
// instance like any other font with zero changes. Normalized keying means two
// design coordinates the font cannot distinguish (they round to the same
// F2Dot14 tick) collapse to one instance instead of duplicating every glyph
// they touch into the atlas.
//
// Note that instances are still unbounded: a continuous axis animation walks
// through distinct ticks and each new one bands fresh outlines that are never
// evicted. Coordinate quantization and atlas eviction remain to be done.
//
// Not implemented (static values from the default instance are used):
// gvar phantom-point advances for fonts without HVAR, GPOS kerning deltas
// (variation-index device tables), and named instances/STAT.

part of 'font.dart';

/// One design axis from the fvar table, in user (design-space) units.
class FontAxis {
  const FontAxis(this.tag, this.min, this.def, this.max);

  final String tag;
  final double min;
  final double def;
  final double max;
}

String _tag4(ByteData d, int o) => String.fromCharCodes([
  d.getUint8(o),
  d.getUint8(o + 1),
  d.getUint8(o + 2),
  d.getUint8(o + 3),
]);

class _Fvar {
  _Fvar(this.axes);

  final List<FontAxis> axes;

  static _Fvar parse(ByteData d, int off) {
    final axesOff = d.getUint16(off + 4, Endian.big);
    final axisCount = d.getUint16(off + 8, Endian.big);
    final axisSize = d.getUint16(off + 10, Endian.big);
    final axes = <FontAxis>[];
    for (var i = 0; i < axisCount; i++) {
      final o = off + axesOff + i * axisSize;
      axes.add(
        FontAxis(
          _tag4(d, o),
          d.getInt32(o + 4, Endian.big) / 65536.0,
          d.getInt32(o + 8, Endian.big) / 65536.0,
          d.getInt32(o + 12, Endian.big) / 65536.0,
        ),
      );
    }
    return _Fvar(axes);
  }
}

/// avar segment maps: piecewise-linear remapping of normalized coordinates.
class _Avar {
  _Avar(this._maps);

  final List<List<double>> _maps; // per axis: flat (from, to) pairs, sorted

  static _Avar parse(ByteData d, int off, int axisCount) {
    var p = off + 8; // major(2) minor(2) reserved(2) axisCount(2)
    final maps = <List<double>>[];
    for (var a = 0; a < axisCount; a++) {
      final count = d.getUint16(p, Endian.big);
      p += 2;
      final pairs = List<double>.filled(count * 2, 0);
      for (var i = 0; i < count * 2; i++) {
        pairs[i] = d.getInt16(p, Endian.big) / 16384.0;
        p += 2;
      }
      maps.add(pairs);
    }
    return _Avar(maps);
  }

  double map(int axis, double v) {
    if (axis >= _maps.length) return v;
    final pairs = _maps[axis];
    final n = pairs.length ~/ 2;
    if (n < 2) return v;
    if (v <= pairs[0]) return pairs[1];
    if (v >= pairs[(n - 1) * 2]) return pairs[(n - 1) * 2 + 1];
    for (var i = 1; i < n; i++) {
      final from = pairs[i * 2];
      if (v > from) continue;
      final prevFrom = pairs[(i - 1) * 2];
      final prevTo = pairs[(i - 1) * 2 + 1];
      final to = pairs[i * 2 + 1];
      if (from == prevFrom) return to;
      return prevTo + (to - prevTo) * (v - prevFrom) / (from - prevFrom);
    }
    return v;
  }
}

/// Scalar weight of one variation region at `coords` (per-axis tent
/// functions multiplied together). `peaks` is read from `peakOff` so shared
/// tuples can be scored in place — this runs once per tuple per glyph, and a
/// sublist copy here dominated variable-font outline decoding.
double _tupleScalar(
  Float64List coords,
  int axisCount,
  Float64List peaks,
  int peakOff,
  Float64List? starts,
  Float64List? ends,
) {
  var scalar = 1.0;
  for (var a = 0; a < axisCount; a++) {
    final peak = peaks[peakOff + a];
    if (peak == 0) continue;
    final v = a < coords.length ? coords[a] : 0.0;
    if (v == peak) continue;
    if (starts != null && ends != null) {
      final start = starts[a];
      final end = ends[a];
      if (start > peak || peak > end) continue; // malformed region: ignore
      if (start < 0 && end > 0) continue; // spans zero: ignore per spec
      if (v <= start || v >= end) return 0;
      scalar *= v < peak
          ? (v - start) / (peak - start)
          : (end - v) / (end - peak);
    } else {
      // Implicit region from 0 to peak.
      if (v == 0) return 0;
      if ((v < 0) != (peak < 0)) return 0;
      if (v.abs() > peak.abs()) return 0;
      scalar *= v / peak;
    }
  }
  return scalar;
}

// Item variation store (HVAR/MVAR): regions + per-item delta rows.

class _ItemVariationData {
  _ItemVariationData(this.itemCount, this.regionIndexes, this.deltas);

  final int itemCount;
  final Uint16List regionIndexes;
  final Int32List deltas; // itemCount × regionIndexes.length

  static _ItemVariationData parse(ByteData d, int off) {
    final itemCount = d.getUint16(off, Endian.big);
    final wordDeltaCount = d.getUint16(off + 2, Endian.big);
    final regionIndexCount = d.getUint16(off + 4, Endian.big);
    final longWords = wordDeltaCount & 0x8000 != 0;
    final wordCount = wordDeltaCount & 0x7FFF;
    final regionIndexes = Uint16List(regionIndexCount);
    for (var i = 0; i < regionIndexCount; i++) {
      regionIndexes[i] = d.getUint16(off + 6 + i * 2, Endian.big);
    }
    var p = off + 6 + regionIndexCount * 2;
    final deltas = Int32List(itemCount * regionIndexCount);
    for (var item = 0; item < itemCount; item++) {
      for (var r = 0; r < regionIndexCount; r++) {
        int v;
        if (r < wordCount) {
          if (longWords) {
            v = d.getInt32(p, Endian.big);
            p += 4;
          } else {
            v = d.getInt16(p, Endian.big);
            p += 2;
          }
        } else {
          if (longWords) {
            v = d.getInt16(p, Endian.big);
            p += 2;
          } else {
            v = d.getInt8(p);
            p += 1;
          }
        }
        deltas[item * regionIndexCount + r] = v;
      }
    }
    return _ItemVariationData(itemCount, regionIndexes, deltas);
  }
}

class _ItemVariationStore {
  _ItemVariationStore(this._axisCount, this._regions, this._subs);

  final int _axisCount;
  final Float64List _regions; // regionCount × axisCount × (start, peak, end)
  final List<_ItemVariationData> _subs;

  static _ItemVariationStore parse(ByteData d, int off) {
    final regionListOff = off + d.getUint32(off + 2, Endian.big);
    final dataCount = d.getUint16(off + 6, Endian.big);
    final axisCount = d.getUint16(regionListOff, Endian.big);
    final regionCount = d.getUint16(regionListOff + 2, Endian.big);
    final regions = Float64List(regionCount * axisCount * 3);
    for (var i = 0; i < regions.length; i++) {
      regions[i] = d.getInt16(regionListOff + 4 + i * 2, Endian.big) / 16384.0;
    }
    final subs = <_ItemVariationData>[];
    for (var i = 0; i < dataCount; i++) {
      final so = off + d.getUint32(off + 8 + i * 4, Endian.big);
      subs.add(_ItemVariationData.parse(d, so));
    }
    return _ItemVariationStore(axisCount, regions, subs);
  }

  double _regionScalar(int region, Float64List coords) {
    var scalar = 1.0;
    final base = region * _axisCount * 3;
    for (var a = 0; a < _axisCount; a++) {
      final start = _regions[base + a * 3];
      final peak = _regions[base + a * 3 + 1];
      final end = _regions[base + a * 3 + 2];
      if (peak == 0) continue;
      if (start > peak || peak > end) continue;
      if (start < 0 && end > 0) continue;
      final v = a < coords.length ? coords[a] : 0.0;
      if (v == peak) continue;
      if (v <= start || v >= end) return 0;
      scalar *= v < peak
          ? (v - start) / (peak - start)
          : (end - v) / (end - peak);
    }
    return scalar;
  }

  double delta(int outer, int inner, Float64List coords) {
    if (outer < 0 || outer >= _subs.length) return 0;
    final sub = _subs[outer];
    if (inner < 0 || inner >= sub.itemCount) return 0;
    var sum = 0.0;
    final regionCount = sub.regionIndexes.length;
    for (var i = 0; i < regionCount; i++) {
      final s = _regionScalar(sub.regionIndexes[i], coords);
      if (s != 0) sum += s * sub.deltas[inner * regionCount + i];
    }
    return sum;
  }
}

class _DeltaSetIndexMap {
  _DeltaSetIndexMap(this._innerBits, this._entries);

  final int _innerBits;
  final Uint32List _entries;

  static _DeltaSetIndexMap parse(ByteData d, int off) {
    final entryFormat = d.getUint16(off, Endian.big);
    final mapCount = d.getUint16(off + 2, Endian.big);
    final entrySize = ((entryFormat & 0x0030) >> 4) + 1;
    final innerBits = (entryFormat & 0x000F) + 1;
    final entries = Uint32List(mapCount);
    var p = off + 4;
    for (var i = 0; i < mapCount; i++) {
      var v = 0;
      for (var b = 0; b < entrySize; b++) {
        v = (v << 8) | d.getUint8(p++);
      }
      entries[i] = v;
    }
    return _DeltaSetIndexMap(innerBits, entries);
  }

  (int, int) lookup(int i) {
    if (_entries.isEmpty) return (0, i);
    final e = _entries[i < _entries.length ? i : _entries.length - 1];
    return (e >> _innerBits, e & ((1 << _innerBits) - 1));
  }
}

class _Hvar {
  _Hvar(this._store, this._widthMap);

  final _ItemVariationStore _store;
  final _DeltaSetIndexMap? _widthMap; // null → glyph id is the inner index

  static _Hvar parse(ByteData d, int off) {
    final storeOff = d.getUint32(off + 4, Endian.big);
    final mapOff = d.getUint32(off + 8, Endian.big);
    return _Hvar(
      _ItemVariationStore.parse(d, off + storeOff),
      mapOff == 0 ? null : _DeltaSetIndexMap.parse(d, off + mapOff),
    );
  }

  double advanceDelta(int gid, Float64List coords) {
    final (outer, inner) = _widthMap?.lookup(gid) ?? (0, gid);
    return _store.delta(outer, inner, coords);
  }
}

class _Mvar {
  _Mvar(this._store, this._records);

  final _ItemVariationStore? _store;
  final Map<String, (int, int)> _records;

  static _Mvar parse(ByteData d, int off) {
    final valueRecordSize = d.getUint16(off + 6, Endian.big);
    final valueRecordCount = d.getUint16(off + 8, Endian.big);
    final storeOff = d.getUint16(off + 10, Endian.big);
    final records = <String, (int, int)>{};
    var p = off + 12;
    for (var i = 0; i < valueRecordCount; i++) {
      records[_tag4(d, p)] = (
        d.getUint16(p + 4, Endian.big),
        d.getUint16(p + 6, Endian.big),
      );
      p += valueRecordSize;
    }
    return _Mvar(
      storeOff == 0 ? null : _ItemVariationStore.parse(d, off + storeOff),
      records,
    );
  }

  double delta(String tag, Float64List coords) {
    final rec = _records[tag];
    final store = _store;
    if (rec == null || store == null) return 0;
    return store.delta(rec.$1, rec.$2, coords);
  }
}

// gvar: per-glyph outline deltas. Header + shared tuples are parsed eagerly;
// per-glyph tuple data is decoded on demand (the table is by far the largest
// in a variable font).

class _Gvar {
  _Gvar(
    this._data,
    this._axisCount,
    this._sharedTuples,
    this._dataStart,
    this._offsets,
  );

  final ByteData _data;
  final int _axisCount;
  final Float64List _sharedTuples;
  final int _dataStart;
  final Uint32List _offsets;

  static _Gvar parse(ByteData d, int off) {
    final axisCount = d.getUint16(off + 4, Endian.big);
    final sharedTupleCount = d.getUint16(off + 6, Endian.big);
    final sharedTuplesOffset = d.getUint32(off + 8, Endian.big);
    final glyphCount = d.getUint16(off + 12, Endian.big);
    final flags = d.getUint16(off + 14, Endian.big);
    final dataArrayOffset = d.getUint32(off + 16, Endian.big);
    final offsets = Uint32List(glyphCount + 1);
    if (flags & 1 == 0) {
      for (var i = 0; i <= glyphCount; i++) {
        offsets[i] = d.getUint16(off + 20 + i * 2, Endian.big) * 2;
      }
    } else {
      for (var i = 0; i <= glyphCount; i++) {
        offsets[i] = d.getUint32(off + 20 + i * 4, Endian.big);
      }
    }
    final shared = Float64List(sharedTupleCount * axisCount);
    for (var i = 0; i < shared.length; i++) {
      shared[i] =
          d.getInt16(off + sharedTuplesOffset + i * 2, Endian.big) / 16384.0;
    }
    return _Gvar(d, axisCount, shared, off + dataArrayOffset, offsets);
  }

  /// Scalar of every shared tuple at `coords`, evaluated once per font
  /// instance. Glyph tuple records overwhelmingly reference a shared peak with
  /// an implicit region (Google Sans Flex: 110279 of 110455, i.e. 99.8%), and
  /// on a single-axis coordinate all but ~0.8% of them score zero. Hoisting
  /// this out of [deltasFor] turns the per-tuple cost of those into one array
  /// read, and skips them before any allocation.
  Float64List sharedTupleScalars(Float64List coords) {
    if (_axisCount == 0) return Float64List(0);
    final n = _sharedTuples.length ~/ _axisCount;
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _tupleScalar(
        coords,
        _axisCount,
        _sharedTuples,
        i * _axisCount,
        null,
        null,
      );
    }
    return out;
  }

  /// Accumulated (dx, dy) outline deltas for `gid` at `coords`, length
  /// [pointCount] (the four phantom points are decoded but dropped — metrics
  /// come from HVAR/MVAR). `sharedScalars` comes from [sharedTupleScalars] for
  /// the same `coords`. For simple glyphs pass the original outline
  /// (`xs`/`ys`/`endPts`) so sparse tuples infer unreferenced points via IUP;
  /// for composites leave them null (unreferenced components don't move).
  (Float64List, Float64List)? deltasFor(
    int gid,
    Float64List coords,
    Float64List sharedScalars, {
    required int pointCount,
    List<double>? xs,
    List<double>? ys,
    List<int>? endPts,
  }) {
    if (gid < 0 || gid + 1 >= _offsets.length) return null;
    final start = _dataStart + _offsets[gid];
    final end = _dataStart + _offsets[gid + 1];
    if (start >= end) return null;
    final d = _data;
    final tupleCountField = d.getUint16(start, Endian.big);
    final tupleCount = tupleCountField & 0x0FFF;
    if (tupleCount == 0) return null;

    var serialized = start + d.getUint16(start + 2, Endian.big);
    List<int>? sharedPoints; // null → all points
    final hasSharedPoints = tupleCountField & 0x8000 != 0;
    if (hasSharedPoints) {
      final (pts, next) = _readPackedPoints(d, serialized);
      sharedPoints = pts;
      serialized = next;
    }

    final totalPoints = pointCount + 4; // phantom points included in streams
    final dx = Float64List(pointCount);
    final dy = Float64List(pointCount);
    var header = start + 4;
    var tupleData = serialized;
    for (var t = 0; t < tupleCount; t++) {
      final size = d.getUint16(header, Endian.big);
      final index = d.getUint16(header + 2, Endian.big);
      header += 4;
      final embeddedPeak = index & 0x8000 != 0;
      final intermediate = index & 0x4000 != 0;
      final peakOff = header;
      if (embeddedPeak) header += _axisCount * 2;
      final regionOff = header;
      if (intermediate) header += _axisCount * 4;
      final dataAt = tupleData;
      tupleData += size;

      double scalar;
      if (!embeddedPeak && !intermediate) {
        // Fast path: shared peak, implicit region — scalar is precomputed.
        final si = index & 0x0FFF;
        if (si >= sharedScalars.length) return null; // malformed
        scalar = sharedScalars[si];
      } else {
        // Embedded peaks (176 in Google Sans Flex) and intermediate regions
        // (1322) can't be table-driven: score them in place.
        Float64List peaks;
        int peaksOff;
        if (embeddedPeak) {
          peaks = Float64List(_axisCount);
          for (var a = 0; a < _axisCount; a++) {
            peaks[a] = d.getInt16(peakOff + a * 2, Endian.big) / 16384.0;
          }
          peaksOff = 0;
        } else {
          peaksOff = (index & 0x0FFF) * _axisCount;
          if (peaksOff + _axisCount > _sharedTuples.length) {
            return null; // malformed
          }
          peaks = _sharedTuples;
        }
        Float64List? starts;
        Float64List? ends;
        if (intermediate) {
          starts = Float64List(_axisCount);
          ends = Float64List(_axisCount);
          for (var a = 0; a < _axisCount; a++) {
            starts[a] = d.getInt16(regionOff + a * 2, Endian.big) / 16384.0;
            ends[a] =
                d.getInt16(regionOff + (_axisCount + a) * 2, Endian.big) /
                16384.0;
          }
        }
        scalar = _tupleScalar(
          coords,
          _axisCount,
          peaks,
          peaksOff,
          starts,
          ends,
        );
      }
      if (scalar == 0) continue;

      var p = dataAt;
      List<int>? points;
      if (index & 0x2000 != 0) {
        final (pts, next) = _readPackedPoints(d, p);
        points = pts;
        p = next;
      } else if (hasSharedPoints) {
        points = sharedPoints;
      }
      final deltaCount = points?.length ?? totalPoints;
      final (xd, p2) = _readPackedDeltas(d, p, deltaCount);
      final (yd, _) = _readPackedDeltas(d, p2, deltaCount);

      if (points == null) {
        for (var i = 0; i < pointCount; i++) {
          dx[i] += scalar * xd[i];
          dy[i] += scalar * yd[i];
        }
      } else if (xs != null && ys != null && endPts != null) {
        // Sparse points on a simple glyph: unreferenced points take deltas
        // interpolated per contour (IUP), then everything scales together.
        final tdx = Float64List(pointCount);
        final tdy = Float64List(pointCount);
        final touched = List<bool>.filled(pointCount, false);
        for (var k = 0; k < points.length; k++) {
          final pt = points[k];
          if (pt >= pointCount) continue; // phantom point
          tdx[pt] = xd[k].toDouble();
          tdy[pt] = yd[k].toDouble();
          touched[pt] = true;
        }
        _iupDeltas(tdx, tdy, touched, xs, ys, endPts);
        for (var i = 0; i < pointCount; i++) {
          dx[i] += scalar * tdx[i];
          dy[i] += scalar * tdy[i];
        }
      } else {
        // Composite: deltas move referenced component offsets only.
        for (var k = 0; k < points.length; k++) {
          final pt = points[k];
          if (pt >= pointCount) continue;
          dx[pt] += scalar * xd[k];
          dy[pt] += scalar * yd[k];
        }
      }
    }
    return (dx, dy);
  }
}

/// Packed point numbers; a null list means "all points".
(List<int>?, int) _readPackedPoints(ByteData d, int p) {
  final b0 = d.getUint8(p++);
  if (b0 == 0) return (null, p);
  var count = b0;
  if (b0 & 0x80 != 0) {
    count = ((b0 & 0x7F) << 8) | d.getUint8(p);
    p++;
  }
  final pts = <int>[];
  var v = 0;
  while (pts.length < count) {
    final control = d.getUint8(p++);
    final words = control & 0x80 != 0;
    final runCount = (control & 0x7F) + 1;
    for (var i = 0; i < runCount && pts.length < count; i++) {
      if (words) {
        v += d.getUint16(p, Endian.big);
        p += 2;
      } else {
        v += d.getUint8(p++);
      }
      pts.add(v);
    }
  }
  return (pts, p);
}

(Int32List, int) _readPackedDeltas(ByteData d, int p, int count) {
  final out = Int32List(count);
  var i = 0;
  while (i < count) {
    final control = d.getUint8(p++);
    final runCount = (control & 0x3F) + 1;
    if (control & 0x80 != 0) {
      i += runCount; // run of zeros
    } else if (control & 0x40 != 0) {
      for (var j = 0; j < runCount && i < count; j++) {
        out[i++] = d.getInt16(p, Endian.big);
        p += 2;
      }
    } else {
      for (var j = 0; j < runCount && i < count; j++) {
        out[i++] = d.getInt8(p++);
      }
    }
  }
  return (out, p);
}

/// IUP: for each contour, points a tuple didn't reference take deltas
/// interpolated (per axis, against the ORIGINAL outline coordinates) between
/// their nearest referenced neighbors.
void _iupDeltas(
  Float64List dx,
  Float64List dy,
  List<bool> touched,
  List<double> xs,
  List<double> ys,
  List<int> endPts,
) {
  var start = 0;
  for (final end in endPts) {
    if (end >= start) _iupContour(dx, dy, touched, xs, ys, start, end);
    start = end + 1;
  }
}

void _iupContour(
  Float64List dx,
  Float64List dy,
  List<bool> touched,
  List<double> xs,
  List<double> ys,
  int start,
  int end,
) {
  final n = end - start + 1;
  final refs = <int>[
    for (var i = start; i <= end; i++)
      if (touched[i]) i,
  ];
  if (refs.isEmpty || refs.length == n) return;
  if (refs.length == 1) {
    final r = refs.single;
    for (var i = start; i <= end; i++) {
      if (i == r) continue;
      dx[i] = dx[r];
      dy[i] = dy[r];
    }
    return;
  }
  for (var k = 0; k < refs.length; k++) {
    final r1 = refs[k];
    final r2 = refs[(k + 1) % refs.length];
    var i = r1 == end ? start : r1 + 1;
    while (i != r2) {
      dx[i] = _iupValue(xs[i], xs[r1], dx[r1], xs[r2], dx[r2]);
      dy[i] = _iupValue(ys[i], ys[r1], dy[r1], ys[r2], dy[r2]);
      i = i == end ? start : i + 1;
    }
  }
}

double _iupValue(double target, double c1, double d1, double c2, double d2) {
  if (c1 == c2) return d1 == d2 ? d1 : 0;
  if (c1 > c2) {
    final ct = c1;
    c1 = c2;
    c2 = ct;
    final dt = d1;
    d1 = d2;
    d2 = dt;
  }
  if (target <= c1) return d1;
  if (target >= c2) return d2;
  return d1 + (d2 - d1) * (target - c1) / (c2 - c1);
}

/// Cache key for a normalized coordinate vector: one UTF-16 code unit per
/// axis, biased into [0, 32768] so it never lands in the surrogate range.
/// One allocation, no per-axis string concatenation.
String _tickKey(Int16List ticks) {
  final codes = Uint16List(ticks.length);
  for (var i = 0; i < ticks.length; i++) {
    codes[i] = ticks[i] + 16384;
  }
  return String.fromCharCodes(codes);
}

// Public variation API.

extension GPUFontVariations on GPUFont {
  /// Design axes from fvar; empty for non-variable fonts.
  List<FontAxis> get variationAxes => _fvar?.axes ?? const <FontAxis>[];

  bool hasVariationAxis(String tag) => variationAxes.any((a) => a.tag == tag);

  /// Actual normalized coordinates of this instance, one per fvar axis, in
  /// [-1, 1]. These — not [variationCoordinates] — are what drive gvar/HVAR/
  /// MVAR, and after quantization they may not correspond exactly to the
  /// design values that were requested. Empty on the base font.
  List<double> get normalizedCoordinates =>
      _normCoords?.toList(growable: false) ?? const <double>[];

  /// Snap `coords` onto the quantization grid, returning both the design
  /// coordinates this instance will actually render and the post-avar F2Dot14
  /// ticks that drive gvar/HVAR/MVAR.
  ///
  /// The ticks — not the design-space request — are the correct cache identity:
  /// `wght: 700.0` and `wght: 700.01` normalize to the same tick and must not
  /// become two fonts.
  ///
  /// `steps` (null → full F2Dot14 resolution) is the number of grid points per
  /// unit of normalized space; ticks snap to multiples of `16384 ~/ steps`.
  /// Because 16384 is a power of two and `steps` must divide it, the default
  /// coordinate (0) and both axis extremes (±16384) always land exactly on the
  /// grid — quantization never nudges an axis off its default or its limit.
  ///
  /// Snapping happens BEFORE avar. Post-avar would bound the outline error more
  /// directly (the variation tents are piecewise linear in that space), but
  /// avar is not cheaply invertible, and we need the inverse to report an
  /// honest design coordinate back. Pre-avar snapping keeps the reachable
  /// instance count bounded all the same, and the linear normalization inverts
  /// exactly.
  (Map<String, double>, Int16List) _snapCoords(
    Map<String, double> coords,
    int? steps,
  ) {
    assert(
      steps == null || (steps > 0 && steps <= 16384 && 16384 % steps == 0),
      'variationQuantizationSteps must divide 16384 (a power of two), '
      'so that 0 and ±1 stay exactly representable; got $steps',
    );
    final fvar = _fvar!;
    final avar = _avar;
    final grid = steps == null ? 1 : 16384 ~/ steps;
    final ticks = Int16List(fvar.axes.length);
    final snapped = <String, double>{};
    for (var i = 0; i < fvar.axes.length; i++) {
      final axis = fvar.axes[i];
      final v = coords[axis.tag];
      if (v == null) continue;
      var n = 0.0;
      if (v < axis.def) {
        n = axis.def == axis.min ? 0 : -(axis.def - v) / (axis.def - axis.min);
      } else if (v > axis.def) {
        n = axis.max == axis.def ? 0 : (v - axis.def) / (axis.max - axis.def);
      }
      var t = (n * 16384).round();
      if (grid > 1) t = (t / grid).round() * grid;
      t = t.clamp(-16384, 16384);
      if (t == 0) continue; // snapped onto the axis default
      final nq = t / 16384.0;
      // Exact inverse of the normalization above.
      snapped[axis.tag] = nq < 0
          ? axis.def + nq * (axis.def - axis.min)
          : axis.def + nq * (axis.max - axis.def);
      ticks[i] = avar == null
          ? t
          : (avar.map(i, nq) * 16384).round().clamp(-16384, 16384);
    }
    return (snapped, ticks);
  }

  /// This font instanced at the given design-space coordinates (e.g.
  /// {'wght': 700}). Unknown axes are ignored, non-finite and default-valued
  /// axes are dropped, and values are clamped to the axis range; if nothing
  /// remains — or everything normalizes to the default — the base font itself
  /// is returned.
  ///
  /// Coordinates are snapped to the [GPUFont.variationQuantizationSteps] grid.
  /// A continuous axis animation would otherwise mint a fresh instance every
  /// frame, and each one bands its own copy of every glyph into the shared
  /// atlas. Snapping bounds how many instances are live at once; the cost is a
  /// sub-pixel outline error (see that field). Use [variantExact] where the
  /// exact requested coordinate matters — measuring against reference metrics,
  /// or rendering a single static instance.
  ///
  /// Instances are cached by NORMALIZED coordinates, so any two requests that
  /// land on the same grid point return the IDENTICAL object — everything
  /// downstream (glyph atlas, metrics caches, kerning runs) keys by font
  /// identity. [variationCoordinates] on the result therefore reports the
  /// design coordinates of whichever request created the instance, which may
  /// differ from this one; [normalizedCoordinates] is what actually rendered.
  GPUFont variant(Map<String, double> coordinates) =>
      _variant(coordinates, GPUFont.variationQuantizationSteps);

  /// [variant] at full F2Dot14 resolution, bypassing quantization.
  ///
  /// Every call with a distinct coordinate creates an instance that bands its
  /// own glyphs into the shared atlas, so do not drive this from an animation.
  GPUFont variantExact(Map<String, double> coordinates) =>
      _variant(coordinates, null);

  GPUFont _variant(Map<String, double> coordinates, int? quantizeSteps) {
    final base = _base ?? this;
    final fvar = base._fvar;
    if (fvar == null || fvar.axes.isEmpty) return this;
    final merged = identical(this, base)
        ? coordinates
        : {...variationCoordinates, ...coordinates};
    final canonical = <String, double>{};
    for (final axis in fvar.axes) {
      final requested = merged[axis.tag];
      if (requested == null || !requested.isFinite) continue;
      final v = requested.clamp(axis.min, axis.max).toDouble();
      if (v == axis.def) continue;
      canonical[axis.tag] = v;
    }
    if (canonical.isEmpty) return base;
    final (snapped, ticks) = base._snapCoords(canonical, quantizeSteps);
    if (snapped.isEmpty) return base; // every axis snapped to its default
    final key = _tickKey(ticks);
    final cache = base._variantCache;
    final cached = cache.remove(key);
    if (cached != null) {
      cache[key] = cached; // LRU touch
      return cached;
    }
    final instance = base._instantiate(snapped, ticks);
    cache[key] = instance;
    while (cache.length > GPUFont.variantCacheCapacity) {
      final evicted = cache.remove(cache.keys.first);
      if (evicted != null) GPUFont.onVariantEvicted?.call(evicted);
    }
    return instance;
  }

  GPUFont _instantiate(Map<String, double> coords, Int16List ticks) {
    final norm = Float64List(ticks.length);
    for (var i = 0; i < ticks.length; i++) {
      norm[i] = ticks[i] / 16384.0;
    }

    var vMetrics = verticalMetrics;
    var dMetrics = decorationMetrics;
    final mvar = _mvar;
    if (mvar != null) {
      vMetrics = VerticalMetrics(
        ascender: vMetrics.ascender + mvar.delta('hasc', norm),
        descender: vMetrics.descender + mvar.delta('hdsc', norm),
        lineGap: vMetrics.lineGap + mvar.delta('hlgp', norm),
      );
      dMetrics = DecorationMetrics(
        underlinePosition:
            dMetrics.underlinePosition + mvar.delta('undo', norm),
        underlineThickness:
            dMetrics.underlineThickness + mvar.delta('unds', norm),
        strikeoutPosition:
            dMetrics.strikeoutPosition + mvar.delta('stro', norm),
        strikeoutSize: dMetrics.strikeoutSize + mvar.delta('strs', norm),
      );
    }

    return GPUFont._(
      unitsPerEm: unitsPerEm,
      verticalMetrics: vMetrics,
      decorationMetrics: dMetrics,
      bytes: _bytes,
      tables: _tables,
      numGlyphs: _numGlyphs,
      indexToLocFormat: _indexToLocFormat,
      cmap: _cmap,
      // Static advances, shared with the base. HVAR deltas are applied per
      // glyph on first use (see GPUFont._advanceFor) rather than swept over
      // every glyph here, keeping variant() O(axisCount) instead of
      // O(numGlyphs) — the difference between ~0.1ms and ~3ms per new
      // coordinate on a large CJK variable font.
      advances: _advances,
      lsbs: _lsbs,
      glyphOffsets: _glyphOffsets,
      kern: _kern,
      gposKern: _gposKern,
      colr: _colr,
      fvar: _fvar,
      avar: _avar,
      gvar: _gvar,
      hvar: _hvar,
      mvar: _mvar,
      gsub: _gsub,
      variationCoordinates: Map.unmodifiable(coords),
      normCoords: norm,
      gvarSharedScalars: _gvar?.sharedTupleScalars(norm),
      base: this,
    );
  }
}
