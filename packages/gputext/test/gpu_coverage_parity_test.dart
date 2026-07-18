// GPU-vs-CPU coverage parity: band shapes into ONE shared atlas, render them
// through the real pipeline (uploadAtlasTextures + gputext.frag), read the
// pixels back, and compare per-pixel alpha against the f64 CPU reference
// integral. Both sides evaluate the same analytic winding integral, so the
// only expected differences are f32 rounding and 8-bit quantization — the
// tolerances are tight enough that any atlas texel-layout or shader indexing
// bug (e.g. the two-vec2s-per-texel curve packing) reads as a hard failure,
// not noise.
//
// Requires `flutter test --enable-impeller --enable-flutter-gpu`; skips
// (like gpu_init_test) when flutter_gpu is unavailable.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/src/atlas.dart';
import 'package:gputext/src/bands.dart';
import 'package:gputext/src/coverage/cpu_integral.dart';
import 'package:gputext/src/engine/pipeline.dart';
import 'package:gputext/src/geometry.dart';

const _cell = 64;

bool get _gpuAvailable {
  try {
    gpu.gpuContext;
    return true;
  } catch (_) {
    return false;
  }
}

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

List<(double, double)> _starPts(double cx, double cy, double r) {
  final p = <(double, double)>[];
  for (var k = 0; k < 5; k++) {
    final a = -math.pi / 2 + ((k * 2) % 5) * (2 * math.pi / 5);
    p.add((cx + r * math.cos(a), cy + r * math.sin(a)));
  }
  return p;
}

class _Shape {
  _Shape(this.label, this.quads, {this.evenOdd = false});

  final String label;
  final List<double> quads;
  final bool evenOdd;

  late BandHeader header;
  late List<double> bbox; // [loX, loY, hiX, hiY]
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A leading triangle offsets the later shapes' band starts so curve reads
  // land on both texel halves (odd AND even vec2 indices) regardless of how
  // the shapes' own piece counts fall. Its 3 monotone pieces (9 vec2s — odd)
  // also leave the shared atlas mid-texel, which the incremental-append test
  // below relies on.
  final shapes = <_Shape>[
    _Shape('triangle', _polygon([(8, 50), (32, 10), (56, 52)])),
    _Shape('circle r=22', _circle(32, 32, 22, n: 24)),
    _Shape('star {5/2} even-odd', _polygon(_starPts(32, 32, 26)),
        evenOdd: true),
  ];

  // Band everything into one shared atlas, exactly like SharedGlyphAtlas.
  // Prefix lengths after the first shape drive the incremental-append test.
  final curveOut = Float32Buf();
  final rowOut = Uint32Buf();
  var prefixCurves = 0;
  var prefixRows = 0;
  for (final s in shapes) {
    final pieces = <double>[];
    for (var i = 0; i + 5 < s.quads.length; i += 6) {
      pushMonotonePiecesAt(s.quads, i, pieces);
    }
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (var i = 0; i < pieces.length; i += 2) {
      x0 = math.min(x0, pieces[i]);
      x1 = math.max(x1, pieces[i]);
      y0 = math.min(y0, pieces[i + 1]);
      y1 = math.max(y1, pieces[i + 1]);
    }
    s.header = bandPieces(pieces, y0, y1, curveOut, rowOut);
    s.bbox = [x0, y0, x1, y1];
    if (s == shapes.first) {
      prefixCurves = curveOut.length;
      prefixRows = rowOut.length;
    }
  }
  final curves = curveOut.toTypedList();
  final rows = rowOut.toTypedList();

  Future<void> renderAndCompare(AtlasTextures textures) async {
    final pipeline = await GPUTextPipeline.create();

    // Confirm the atlas actually straddles texel halves: at least one band
    // must start at an odd piece index (base vec2 index = start*3 covers both
    // parities as pieces advance, but an odd start guarantees a .zw first
    // read even for count-1 bands).
    final starts = [for (var b = 0; b < rows.length ~/ 5; b++) rows[b * 5]];
    expect(starts.any((s) => s.isOdd), isTrue,
        reason: 'corpus should exercise odd curve indices');

    // One 64px cell per shape, side by side, drawn 1:1 (scale 1, camera
    // identity): screen pixel (cell*k + x, y) center is rc (x+0.5, y+0.5) —
    // the CPU reference's exact sample point.
    final instances = Float32List(shapes.length * 16);
    for (var k = 0; k < shapes.length; k++) {
      final s = shapes[k];
      final o = k * 16;
      instances[o] = (k * _cell).toDouble(); // place.x
      instances[o + 1] = 0; // place.y
      instances[o + 2] = 1; // unitsToPx
      instances[o + 3] = s.evenOdd ? 1 : 0; // fill rule
      instances[o + 4] = s.bbox[0];
      instances[o + 5] = s.bbox[1];
      instances[o + 6] = s.bbox[2];
      instances[o + 7] = s.bbox[3];
      instances[o + 8] = 1; // white, alpha 1 → alpha readback IS coverage
      instances[o + 9] = 1;
      instances[o + 10] = 1;
      instances[o + 11] = 1;
      instances[o + 12] = s.header.rowBase.toDouble();
      instances[o + 13] = s.header.bandCount.toDouble();
      instances[o + 14] = s.header.y0;
      instances[o + 15] = s.header.invH;
    }

    final width = _cell * shapes.length;
    const height = _cell;
    final target = gpu.gpuContext.createTexture(
      gpu.StorageMode.devicePrivate,
      width,
      height,
      format: gpu.gpuContext.defaultColorFormat,
      enableRenderTargetUsage: true,
      enableShaderReadUsage: true,
    );
    final cmd = gpu.gpuContext.createCommandBuffer();
    final pass = cmd.createRenderPass(
      gpu.RenderTarget.singleColor(gpu.ColorAttachment(texture: target)),
    );
    pipeline.renderInstances(
      pass: pass,
      frame: FrameUniforms(width: width.toDouble(), height: height.toDouble()),
      instances: pipeline.uploadInstances(instances),
      instanceCount: shapes.length,
      textures: textures,
    );
    final done = Completer<void>();
    cmd.submit(completionCallback: (_) => done.complete());
    await done.future;

    final image = target.asImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(data, isNotNull);

    for (var k = 0; k < shapes.length; k++) {
      final s = shapes[k];
      var maxErr = 0.0;
      var sumErr = 0.0;
      for (var y = 0; y < _cell; y++) {
        for (var x = 0; x < _cell; x++) {
          final cpu = integrateFaceCoverage(
            curves: curves,
            rows: rows,
            rowBase: s.header.rowBase,
            bandCount: s.header.bandCount,
            y0: s.header.y0,
            invH: s.header.invH,
            rcx: x + 0.5,
            rcy: y + 0.5,
            sx: 1.0,
            sy: 1.0,
            fillRule: s.evenOdd ? 1.0 : 0.0,
          );
          final px = (y * width + (k * _cell + x)) * 4;
          final gpuCov = data!.getUint8(px + 3) / 255.0;
          final e = (gpuCov - cpu).abs();
          sumErr += e;
          if (e > maxErr) maxErr = e;
        }
      }
      final meanErr = sumErr / (_cell * _cell);
      // Same analytic integral on both sides; only f32 rounding and 8-bit
      // quantization separate them. A texel packing/indexing bug produces
      // full-scale (≈1.0) differences.
      expect(meanErr, lessThan(0.005),
          reason: '${s.label}: mean |GPU−CPU| $meanErr');
      expect(maxErr, lessThan(0.04),
          reason: '${s.label}: max |GPU−CPU| $maxErr');
    }
  }

  void requireGpu() {
    if (_gpuAvailable) return;
    markTestSkipped(
      'flutter_gpu unavailable; run with '
      '--enable-impeller --enable-flutter-gpu to cover GPU parity',
    );
  }

  test('one-shot upload matches the CPU reference per pixel', () async {
    if (!_gpuAvailable) {
      requireGpu();
      return;
    }
    await renderAndCompare(uploadAtlasTextures(gpu.gpuContext, curves, rows));
  });

  test('incremental mid-texel tail append matches the CPU reference',
      () async {
    if (!_gpuAvailable) {
      requireGpu();
      return;
    }
    // The first generation ends at an odd vec2 count (triangle: 3 monotone
    // pieces = 9 vec2s), so the second upload's tail starts by filling the
    // half-written texel's .zw — the packing's only alignment edge.
    expect((prefixCurves ~/ 2).isOdd, isTrue,
        reason: 'first generation should end mid-texel');
    final uploader = AtlasTextureUploader();
    uploader.upload(
      gpu.gpuContext,
      Float32List.sublistView(curves, 0, prefixCurves),
      Uint32List.sublistView(rows, 0, prefixRows),
    );
    await renderAndCompare(uploader.upload(gpu.gpuContext, curves, rows));
  });
}
