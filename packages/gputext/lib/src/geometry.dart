// Split quadratic Béziers into xy-monotone pieces for the closed-form integrator.

double? extremumT(double p0, double p1, double p2) {
  final a = p0 - 2 * p1 + p2;
  if (a == 0) return null;
  final t = (p0 - p1) / a;
  return t > 0 && t < 1 ? t : null;
}

List<double> subdivide(List<double> q, double t) {
  double lerp(double a, double b) => a + (b - a) * t;
  final x01 = lerp(q[0], q[2]);
  final y01 = lerp(q[1], q[3]);
  final x12 = lerp(q[2], q[4]);
  final y12 = lerp(q[3], q[5]);
  final xm = lerp(x01, x12);
  final ym = lerp(y01, y12);
  return [q[0], q[1], x01, y01, xm, ym, xm, ym, x12, y12, q[4], q[5]];
}

void pushMonotonePieces(List<double> q, List<double> out) =>
    pushMonotonePiecesAt(q, 0, out);

/// Allocation-free splitter reading one quad at `src[base..base+5]` — the
/// banding hot path calls this per quad per glyph, so no sublists, no
/// intermediate lists, scalar subdivision only.
void pushMonotonePiecesAt(List<double> src, int base, List<double> out) {
  var x0 = src[base], y0 = src[base + 1];
  var cx = src[base + 2], cy = src[base + 3];
  final x1 = src[base + 4], y1 = src[base + 5];

  final tx = extremumT(x0, cx, x1);
  final ty = extremumT(y0, cy, y1);
  double? first;
  double? second;
  if (tx != null && ty != null) {
    first = tx < ty ? tx : ty;
    second = tx < ty ? ty : tx;
  } else {
    first = tx ?? ty;
  }

  var consumed = 0.0;
  for (var pass = 0; pass < 2; pass++) {
    final t = pass == 0 ? first : second;
    if (t == null) continue;
    final denom = 1 - consumed;
    final local = denom > 0 ? (t - consumed) / denom : 1.0;
    if (!(local > 0 && local < 1)) continue;
    final x01 = x0 + (cx - x0) * local;
    final y01 = y0 + (cy - y0) * local;
    final x12 = cx + (x1 - cx) * local;
    final y12 = cy + (y1 - cy) * local;
    final xm = x01 + (x12 - x01) * local;
    final ym = y01 + (y12 - y01) * local;
    out
      ..add(x0)
      ..add(y0)
      ..add(x01)
      ..add(y01)
      ..add(xm)
      ..add(ym);
    x0 = xm;
    y0 = ym;
    cx = x12;
    cy = y12;
    consumed = t;
  }
  out
    ..add(x0)
    ..add(y0)
    ..add(cx)
    ..add(cy)
    ..add(x1)
    ..add(y1);
}
