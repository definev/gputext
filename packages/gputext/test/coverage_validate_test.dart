import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/src/coverage/box_reference.dart';
import 'package:gputext/src/coverage/cpu_integral.dart';

const _cellSize = 64;
const _sampleGrid = 8; // point-sample grid; noise ~1/F

List<double> _line(double x0, double y0, double x1, double y1) => [
  x0,
  y0,
  (x0 + x1) / 2,
  (y0 + y1) / 2,
  x1,
  y1,
];

List<double> _polygon(List<(double, double)> pts) {
  final out = <double>[];
  for (var i = 0; i < pts.length; i++) {
    final a = pts[i];
    final b = pts[(i + 1) % pts.length];
    out.addAll(_line(a.$1, a.$2, b.$1, b.$2));
  }
  return out;
}

List<(double, double)> _rotate(
  List<(double, double)> pts,
  double deg, {
  double cx = _cellSize / 2,
  double cy = _cellSize / 2,
}) {
  final a = deg * math.pi / 180;
  final c = math.cos(a);
  final s = math.sin(a);
  return [
    for (final p in pts)
      (
        cx + (p.$1 - cx) * c - (p.$2 - cy) * s,
        cy + (p.$1 - cx) * s + (p.$2 - cy) * c,
      ),
  ];
}

List<double> _circle(double cx, double cy, double r, {int n = 16}) {
  final out = <double>[];
  for (var i = 0; i < n; i++) {
    final a0 = (i / n) * 2 * math.pi;
    final a1 = ((i + 1) / n) * 2 * math.pi;
    final am = (a0 + a1) / 2;
    final k = 1 / math.cos((a1 - a0) / 2);
    out.addAll([
      cx + r * math.cos(a0),
      cy + r * math.sin(a0),
      cx + r * k * math.cos(am),
      cy + r * k * math.sin(am),
      cx + r * math.cos(a1),
      cy + r * math.sin(a1),
    ]);
  }
  return out;
}

List<(double, double)> _starPts(
  double cx,
  double cy,
  double r,
  int points,
  int step,
) {
  final p = <(double, double)>[];
  for (var k = 0; k < points; k++) {
    final a = -math.pi / 2 + ((k * step) % points) * (2 * math.pi / points);
    p.add((cx + r * math.cos(a), cy + r * math.sin(a)));
  }
  return p;
}

void main() {
  // Simple fills: mean |Δ| should sit near F×F point-sample noise (~1/F).
  // Max can be a few× that on AA fringes.
  const simpleMean = 1.0 / _sampleGrid + 0.02;
  const simpleMax = 0.25;

  // Self-intersecting star: fold-model limit at overlapping windings
  // (same caveat as windfoil validate.js / ALGORITHM.md §8).
  const starMean = 0.08;
  const starMax = 0.55;

  final shapes = <(String, List<double>, bool, double, double)>[
    (
      'rotated square 30°',
      _polygon(_rotate([(14, 14), (50, 14), (50, 50), (14, 50)], 30)),
      false,
      simpleMean,
      simpleMax,
    ),
    (
      'thin diagonal sliver',
      _polygon(_rotate([(6, 31.5), (58, 31.5), (58, 32.5), (6, 32.5)], 27)),
      false,
      simpleMean,
      simpleMax,
    ),
    ('circle r=22', _circle(32, 32, 22, n: 24), false, simpleMean, simpleMax),
    (
      'star {5/2} nonzero',
      _polygon(_starPts(32, 32, 26, 5, 2)),
      false,
      starMean,
      starMax,
    ),
    (
      'star {5/2} even-odd',
      _polygon(_starPts(32, 32, 26, 5, 2)),
      true,
      starMean,
      starMax,
    ),
  ];

  for (final entry in shapes) {
    final (label, quads, evenOdd, meanLimit, maxLimit) = entry;
    test('cpu integral vs box · $label', () {
      final shape = buildBandedShape(quads);
      expect(shape.bandCount, greaterThan(0));
      expect(shape.curves.length, greaterThan(0));

      final ours = cpuIntegralCoverage(
        shape,
        size: _cellSize,
        evenOdd: evenOdd,
      );
      final box = boxCoverage(
        quads,
        size: _cellSize,
        samples: _sampleGrid,
        evenOdd: evenOdd,
      );
      final d = coverageDelta(ours, box);
      expect(
        d.mean,
        lessThan(meanLimit),
        reason:
            '$label mean |Δ|=${d.mean.toStringAsFixed(5)} '
            '(limit $meanLimit); max=${d.max.toStringAsFixed(5)}',
      );
      expect(
        d.max,
        lessThan(maxLimit),
        reason:
            '$label max |Δ|=${d.max.toStringAsFixed(5)} '
            '(limit $maxLimit); mean=${d.mean.toStringAsFixed(5)}',
      );
    });
  }
}
