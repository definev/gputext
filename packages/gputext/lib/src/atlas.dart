import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

import 'bands.dart' show f32fromBits;

const curveTexWidth = 1024;

const _atlasFormat = gpu.PixelFormat.r32g32b32a32Float;

/// Throws if the device can't sample the RGBA32F atlas textures gputext needs.
void _requireAtlasFormat(gpu.GpuContext context) {
  if (!context.supportsTextureFormat(_atlasFormat, shaderRead: true)) {
    throw UnsupportedError(
      'This device does not support ${_atlasFormat.name} shader-read textures '
      'required for gputext curve data.',
    );
  }
}

/// Pack curve vec2s `[from, end)` into RGBA32F texels of [dst] — TWO vec2s
/// per texel (even index in .xy, odd in .zw; gputext.frag unpacks by index
/// parity). Texel t therefore holds floats `[4t, 4t+4)` of the curves buffer,
/// so packing is an identity copy of the float range.
void _packCurveTexels(Float32List dst, Float32List curves, int from, int end) {
  dst.setRange(from * 2, end * 2, curves, from * 2);
}

/// Pack band rows `[from, end)` into RGBA32F texel PAIRS of [dst]. Each band is
/// 5 u32s `[start, count, areaBits, xMinBits, xMaxBits]` (see bands.dart); the
/// bit-punned f32s are un-punned here since the storage medium is a float
/// texture:
///   texel[2b]   = (start, count, area, xMin)
///   texel[2b+1] = (xMax, 0, 0, 0)
void _packRowTexels(Float32List dst, Uint32List rows, int from, int end) {
  for (var i = from; i < end; i++) {
    final o = i * 8;
    dst[o] = rows[i * 5].toDouble();
    dst[o + 1] = rows[i * 5 + 1].toDouble();
    dst[o + 2] = f32fromBits(rows[i * 5 + 2]); // band winding area
    dst[o + 3] = f32fromBits(rows[i * 5 + 3]); // ink hull xMin
    dst[o + 4] = f32fromBits(rows[i * 5 + 4]); // ink hull xMax
  }
}

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

/// Append-only atlas texture uploader: packs only the new tail each generation
/// (O(delta) CPU). Recreates textures only on capacity growth. Safe to
/// overwrite a live texture because in-flight draws only index the immutable
/// prefix — rewritten with identical values; only the unreferenced tail changes.
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
    Float32List curves,
    Uint32List rows,
  ) {
    _requireAtlasFormat(context);
    const maxH = 1 << 20;

    final curveVec2Count = curves.length ~/ 2;
    final curveTexels = (curveVec2Count + 1) ~/ 2; // two vec2s per texel
    final needCurveH = ((curveTexels + curveTexWidth - 1) ~/ curveTexWidth)
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
        format: _atlasFormat,
        enableRenderTargetUsage: false,
        enableShaderReadUsage: true,
      );
    }
    _packCurveTexels(_curvePixels, curves, _packedCurveVec2, curveVec2Count);
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
        format: _atlasFormat,
        enableRenderTargetUsage: false,
        enableShaderReadUsage: true,
      );
    }
    _packRowTexels(_rowPixels, rows, _packedRows, rowCount);
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
  _requireAtlasFormat(context);
  final curveVec2Count = curves.length ~/ 2;
  final curveTexels = (curveVec2Count + 1) ~/ 2; // two vec2s per texel
  final curveTexHeight = (curveTexels + curveTexWidth - 1) ~/ curveTexWidth;
  final curvePixels = Float32List(curveTexWidth * curveTexHeight * 4);
  _packCurveTexels(curvePixels, curves, 0, curveVec2Count);

  final rowCount = rows.length ~/ 5;
  final rowTexHeight = (rowCount * 2 + curveTexWidth - 1) ~/ curveTexWidth;
  final rowPixels = Float32List(curveTexWidth * rowTexHeight * 4);
  _packRowTexels(rowPixels, rows, 0, rowCount);

  final curvesTex = context.createTexture(
    gpu.StorageMode.hostVisible,
    curveTexWidth,
    curveTexHeight.clamp(1, 1 << 20),
    format: _atlasFormat,
    enableRenderTargetUsage: false,
    enableShaderReadUsage: true,
  );
  curvesTex.overwrite(curvePixels.buffer.asByteData());

  final rowsTex = context.createTexture(
    gpu.StorageMode.hostVisible,
    curveTexWidth,
    rowTexHeight.clamp(1, 1 << 20),
    format: _atlasFormat,
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
