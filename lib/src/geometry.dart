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
  return [
    q[0], q[1], x01, y01, xm, ym,
    xm, ym, x12, y12, q[4], q[5],
  ];
}

void pushMonotonePieces(List<double> q, List<double> out) {
  final tx = extremumT(q[0], q[2], q[4]);
  final ty = extremumT(q[1], q[3], q[5]);
  double? first;
  double? second;
  if (tx != null && ty != null) {
    first = tx < ty ? tx : ty;
    second = tx < ty ? ty : tx;
  } else {
    first = tx ?? ty;
  }

  var rest = List<double>.from(q);
  var consumed = 0.0;
  for (final t in [first, second]) {
    if (t == null) continue;
    final denom = 1 - consumed;
    final local = denom > 0 ? (t - consumed) / denom : 1.0;
    if (!(local > 0 && local < 1)) continue;
    final parts = subdivide(rest, local);
    out.addAll(parts.sublist(0, 6));
    rest = parts.sublist(6);
    consumed = t;
  }
  out.addAll(rest);
}
