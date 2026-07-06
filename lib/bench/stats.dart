// Pure-Dart sample statistics for the benchmark report. All inputs are
// milliseconds unless a caller says otherwise; nothing here depends on
// Flutter so it stays unit-testable on the VM.

import 'dart:math' as math;

double median(List<double> samples) => percentile(samples, 50);

/// Linear-interpolated percentile (p in 0..100) over an unsorted sample list.
double percentile(List<double> samples, double p) {
  if (samples.isEmpty) return 0;
  final sorted = [...samples]..sort();
  final rank = (p / 100) * (sorted.length - 1);
  final lo = rank.floor();
  final hi = rank.ceil();
  if (lo == hi) return sorted[lo];
  final t = rank - lo;
  return sorted[lo] * (1 - t) + sorted[hi] * t;
}

double mean(List<double> samples) => samples.isEmpty
    ? 0
    : samples.reduce((a, b) => a + b) / samples.length;

/// Population standard deviation.
double std(List<double> samples) {
  if (samples.length < 2) return 0;
  final m = mean(samples);
  var sq = 0.0;
  for (final s in samples) {
    sq += (s - m) * (s - m);
  }
  return math.sqrt(sq / samples.length);
}

int countOver(List<double> samples, double threshold) =>
    samples.where((s) => s > threshold).length;

/// Distribution summary of one metric across a scenario's measured frames
/// (or a CPU benchmark's runs).
class DistStats {
  DistStats({
    required this.count,
    required this.p50,
    required this.p90,
    required this.p99,
    required this.mean,
    required this.std,
    required this.max,
  });

  factory DistStats.of(List<double> samples) {
    // Top-level mean/std are shadowed by the fields inside class scope.
    final m = samples.isEmpty
        ? 0.0
        : samples.reduce((a, b) => a + b) / samples.length;
    var sq = 0.0;
    for (final s in samples) {
      sq += (s - m) * (s - m);
    }
    return DistStats(
      count: samples.length,
      p50: percentile(samples, 50),
      p90: percentile(samples, 90),
      p99: percentile(samples, 99),
      mean: m,
      std: samples.length < 2 ? 0.0 : math.sqrt(sq / samples.length),
      max: samples.isEmpty ? 0 : samples.reduce(math.max),
    );
  }

  final int count;
  final double p50;
  final double p90;
  final double p99;
  final double mean;
  final double std;
  final double max;

  Map<String, Object> toJson() => {
        'count': count,
        'p50Ms': _round(p50),
        'p90Ms': _round(p90),
        'p99Ms': _round(p99),
        'meanMs': _round(mean),
        'stdMs': _round(std),
        'maxMs': _round(max),
      };

  static double _round(double v) => (v * 1000).roundToDouble() / 1000;
}
