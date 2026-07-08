// Tier D — visual quality metrics (no goldens, numbers only).
//
// Both engines render the same span side by side (untimed), each inside a
// keyed RepaintBoundary over a white background; after the gputext
// render/heal machinery settles we capture both boundaries with
// OffsetLayer.toImage and diff lumas in Dart. GPUText blits a
// GPU-surface-backed ui.Image, and toImage re-rasterizes the layer tree, so
// on-device capture is expected to work — but the whole tier degrades to a
// 'capture-unsupported' entry instead of failing the run if it does not.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class VisualDiff {
  VisualDiff({
    required this.widthPx,
    required this.heightPx,
    required this.meanAbsDiff,
    required this.rmse,
    required this.pctPixelsOver8,
    required this.inkCoveragePct,
  });

  final List<int> widthPx; // [gputext, richtext]
  final List<int> heightPx;

  /// Mean |lumaA - lumaB| over the common area, normalized to 0..1.
  final double meanAbsDiff;

  /// Root-mean-square luma error, normalized to 0..1.
  final double rmse;

  /// Percent of common-area pixels whose lumas differ by more than 8/255.
  final double pctPixelsOver8;

  /// Percent of pixels darker than mid-gray per side — the non-blank check.
  final List<double> inkCoveragePct;

  Map<String, Object> toJson() => {
    'widthPx': widthPx,
    'heightPx': heightPx,
    'heightDeltaPx': (heightPx[0] - heightPx[1]).abs(),
    'meanAbsDiff': _round(meanAbsDiff),
    'rmse': _round(rmse),
    'pctPixelsOver8': _round(pctPixelsOver8),
    'inkCoveragePct': inkCoveragePct.map(_round).toList(),
    'nonBlank': inkCoveragePct.map((c) => c > 0.05).toList(),
  };

  static double _round(double v) => (v * 10000).roundToDouble() / 10000;
}

Future<ui.Image> captureBoundary(GlobalKey key, double pixelRatio) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return boundary.toImage(pixelRatio: pixelRatio);
}

Future<VisualDiff> diffImages(ui.Image a, ui.Image b) async {
  final bytesA = await a.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytesB = await b.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytesA == null || bytesB == null) {
    throw StateError('toByteData returned null');
  }
  final w = math.min(a.width, b.width);
  final h = math.min(a.height, b.height);
  var absSum = 0.0;
  var sqSum = 0.0;
  var over8 = 0;
  var inkA = 0;
  var inkB = 0;
  double luma(ByteData d, int rowStride, int x, int y) {
    final o = (y * rowStride + x) * 4;
    return 0.2126 * d.getUint8(o) +
        0.7152 * d.getUint8(o + 1) +
        0.0722 * d.getUint8(o + 2);
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final la = luma(bytesA, a.width, x, y);
      final lb = luma(bytesB, b.width, x, y);
      final d = (la - lb).abs();
      absSum += d;
      sqSum += d * d;
      if (d > 8) over8++;
      if (la < 128) inkA++;
      if (lb < 128) inkB++;
    }
  }
  final n = w * h;
  return VisualDiff(
    widthPx: [a.width, b.width],
    heightPx: [a.height, b.height],
    meanAbsDiff: n == 0 ? 0 : absSum / n / 255,
    rmse: n == 0 ? 0 : math.sqrt(sqSum / n) / 255,
    pctPixelsOver8: n == 0 ? 0 : over8 * 100 / n,
    inkCoveragePct: [n == 0 ? 0 : inkA * 100 / n, n == 0 ? 0 : inkB * 100 / n],
  );
}

/// Capture + diff one mounted pair; never throws — capture failures come
/// back as a 'capture-unsupported' entry so the rest of the run proceeds.
Future<Map<String, Object?>> diffPair({
  required String id,
  required GlobalKey gputextKey,
  required GlobalKey richtextKey,
  required double pixelRatio,
}) async {
  ui.Image? a;
  ui.Image? b;
  try {
    a = await captureBoundary(gputextKey, pixelRatio);
    b = await captureBoundary(richtextKey, pixelRatio);
    final diff = await diffImages(a, b);
    return {'id': id, 'status': 'ready', ...diff.toJson()};
  } catch (e) {
    return {'id': id, 'status': 'capture-unsupported', 'error': '$e'};
  } finally {
    a?.dispose();
    b?.dispose();
  }
}
