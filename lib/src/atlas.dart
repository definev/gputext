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

AtlasTextures uploadAtlasTextures(
  gpu.GpuContext context,
  Float32List curves,
  Uint32List rows,
) {
  const format = gpu.PixelFormat.r32g32b32a32Float;
  if (!context.supportsTextureFormat(format, shaderRead: true)) {
    throw UnsupportedError(
      'This device does not support ${format.name} shader-read textures '
      'required for windfoil curve data.',
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
