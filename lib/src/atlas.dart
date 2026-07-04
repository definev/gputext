import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

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

  final rowCount = rows.length ~/ 2;
  final rowTexHeight = (rowCount + curveTexWidth - 1) ~/ curveTexWidth;
  final rowPixels = Float32List(curveTexWidth * rowTexHeight * 4);
  for (var i = 0; i < rowCount; i++) {
    final o = i * 4;
    rowPixels[o] = rows[i * 2].toDouble();
    rowPixels[o + 1] = rows[i * 2 + 1].toDouble();
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
