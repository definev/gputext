import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

import 'bands.dart' show f32fromBits;

const curveTexWidth = 1024;

class AtlasTextures {
  AtlasTextures({
    required this.curves,
    required this.rows,
    required this.curveTexHeight,
    required this.rowTexHeight,
  });

  final gpu.Texture curves;
  final gpu.Texture rows;
  final int curveTexHeight;
  final int rowTexHeight;
}

/// Incremental texture uploader for the append-only shared atlas.
///
/// The atlas never mutates existing entries, so each generation only the
/// tail is new: pixels are packed into persistent capacity-doubling buffers
/// (O(delta) CPU repack instead of O(total)), and textures are recreated
/// only on capacity growth. Overwriting a live texture while earlier frames'
/// draws are still enqueued is safe here precisely because of append-only:
/// every texel an in-flight draw can index lies in the prefix, whose bytes
/// are rewritten with identical values; only never-yet-referenced tail
/// texels actually change.
class AtlasTextureUploader {
  Float32List _curvePixels = Float32List(0);
  Float32List _rowPixels = Float32List(0);
  gpu.Texture? _curvesTex;
  gpu.Texture? _rowsTex;
  int _curveTexHeight = 0;
  int _rowTexHeight = 0;
  int _packedCurveVec2 = 0;
  int _packedRows = 0;

  AtlasTextures upload(
    gpu.GpuContext context,
    List<double> curves,
    List<int> rows,
  ) {
    const format = gpu.PixelFormat.r32g32b32a32Float;
    if (!context.supportsTextureFormat(format, shaderRead: true)) {
      throw UnsupportedError(
        'This device does not support ${format.name} shader-read textures '
        'required for gputext curve data.',
      );
    }
    const maxH = 1 << 20;

    final curveVec2Count = curves.length ~/ 2;
    final needCurveH = ((curveVec2Count + curveTexWidth - 1) ~/ curveTexWidth)
        .clamp(1, maxH);
    if (_curvesTex == null || needCurveH > _curveTexHeight) {
      final capH =
          (needCurveH > _curveTexHeight * 2 ? needCurveH : _curveTexHeight * 2)
              .clamp(1, maxH);
      final next = Float32List(curveTexWidth * capH * 4);
      next.setRange(0, _curvePixels.length, _curvePixels);
      _curvePixels = next;
      _curveTexHeight = capH;
      _curvesTex = context.createTexture(
        gpu.StorageMode.hostVisible,
        curveTexWidth,
        capH,
        format: format,
        enableRenderTargetUsage: false,
        enableShaderReadUsage: true,
      );
    }
    for (var i = _packedCurveVec2; i < curveVec2Count; i++) {
      final o = i * 4;
      _curvePixels[o] = curves[i * 2];
      _curvePixels[o + 1] = curves[i * 2 + 1];
    }
    _packedCurveVec2 = curveVec2Count;
    _curvesTex!.overwrite(_curvePixels.buffer.asByteData());

    final rowCount = rows.length ~/ 5;
    final needRowH = ((rowCount * 2 + curveTexWidth - 1) ~/ curveTexWidth)
        .clamp(1, maxH);
    if (_rowsTex == null || needRowH > _rowTexHeight) {
      final capH = (needRowH > _rowTexHeight * 2 ? needRowH : _rowTexHeight * 2)
          .clamp(1, maxH);
      final next = Float32List(curveTexWidth * capH * 4);
      next.setRange(0, _rowPixels.length, _rowPixels);
      _rowPixels = next;
      _rowTexHeight = capH;
      _rowsTex = context.createTexture(
        gpu.StorageMode.hostVisible,
        curveTexWidth,
        capH,
        format: format,
        enableRenderTargetUsage: false,
        enableShaderReadUsage: true,
      );
    }
    for (var i = _packedRows; i < rowCount; i++) {
      final o = i * 8;
      _rowPixels[o] = rows[i * 5].toDouble();
      _rowPixels[o + 1] = rows[i * 5 + 1].toDouble();
      _rowPixels[o + 2] = f32fromBits(rows[i * 5 + 2]); // band winding area
      _rowPixels[o + 3] = f32fromBits(rows[i * 5 + 3]); // ink hull xMin
      _rowPixels[o + 4] = f32fromBits(rows[i * 5 + 4]); // ink hull xMax
    }
    _packedRows = rowCount;
    _rowsTex!.overwrite(_rowPixels.buffer.asByteData());

    return AtlasTextures(
      curves: _curvesTex!,
      rows: _rowsTex!,
      curveTexHeight: _curveTexHeight,
      rowTexHeight: _rowTexHeight,
    );
  }
}

AtlasTextures uploadAtlasTextures(
  gpu.GpuContext context,
  Float32List curves,
  Uint32List rows,
) {
  const format = gpu.PixelFormat.r32g32b32a32Float;
  if (!context.supportsTextureFormat(format, shaderRead: true)) {
    throw UnsupportedError(
      'This device does not support ${format.name} shader-read textures '
      'required for gputext curve data.',
    );
  }
  final curveVec2Count = curves.length ~/ 2;
  final curveTexHeight = (curveVec2Count + curveTexWidth - 1) ~/ curveTexWidth;
  final curvePixels = Float32List(curveTexWidth * curveTexHeight * 4);
  for (var i = 0; i < curveVec2Count; i++) {
    final o = i * 4;
    curvePixels[o] = curves[i * 2];
    curvePixels[o + 1] = curves[i * 2 + 1];
  }

  // Row table: 5 u32s per band [start, count, areaBits, xMinBits, xMaxBits]
  // (see bands.dart). Packed as TWO RGBA32F texels per band — the bit-punned
  // f32s are un-punned here since our storage medium is a float texture:
  //   texel[2b]   = (start, count, area, xMin)
  //   texel[2b+1] = (xMax, 0, 0, 0)
  final rowCount = rows.length ~/ 5;
  final rowTexHeight = (rowCount * 2 + curveTexWidth - 1) ~/ curveTexWidth;
  final rowPixels = Float32List(curveTexWidth * rowTexHeight * 4);
  for (var i = 0; i < rowCount; i++) {
    final o = i * 8;
    rowPixels[o] = rows[i * 5].toDouble();
    rowPixels[o + 1] = rows[i * 5 + 1].toDouble();
    rowPixels[o + 2] = f32fromBits(rows[i * 5 + 2]); // band winding area
    rowPixels[o + 3] = f32fromBits(rows[i * 5 + 3]); // ink hull xMin
    rowPixels[o + 4] = f32fromBits(rows[i * 5 + 4]); // ink hull xMax
  }

  final curvesTex = context.createTexture(
    gpu.StorageMode.hostVisible,
    curveTexWidth,
    curveTexHeight.clamp(1, 1 << 20),
    format: format,
    enableRenderTargetUsage: false,
    enableShaderReadUsage: true,
  );
  curvesTex.overwrite(curvePixels.buffer.asByteData());

  final rowsTex = context.createTexture(
    gpu.StorageMode.hostVisible,
    curveTexWidth,
    rowTexHeight.clamp(1, 1 << 20),
    format: format,
    enableRenderTargetUsage: false,
    enableShaderReadUsage: true,
  );
  rowsTex.overwrite(rowPixels.buffer.asByteData());

  return AtlasTextures(
    curves: curvesTex,
    rows: rowsTex,
    curveTexHeight: curveTexHeight,
    rowTexHeight: rowTexHeight,
  );
}
