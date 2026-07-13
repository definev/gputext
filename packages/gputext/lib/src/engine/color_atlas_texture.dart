// Uploads the SharedColorAtlas page to a mipmapped GPU texture. Kept separate
// from color_atlas.dart so the pure decode/pack logic stays testable without a
// GPU context. The page is fixed-size, so the texture is created once and the
// whole mip chain re-uploaded when a new glyph is packed.
//
// flutter_gpu (this version) has no GPU generateMipmap, so mip levels are
// box-filtered on the CPU and uploaded per level via Texture.overwrite. The
// atlas is PREMULTIPLIED, which is what makes the box filter halo-free.
//
// Regenerating the full chain on every new glyph is O(page); emoji churn is
// rare so that matches AtlasTextureUploader's overwrite-in-place cost. An
// incremental per-region mip update is a possible follow-on.

import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

import 'color_atlas.dart';

class ColorAtlasTexture {
  gpu.Texture? _tex;
  int _uploadedGen = -1;

  /// The current color-atlas texture, uploading (with mips) on generation
  /// change. Null while the atlas is empty (nothing to draw).
  gpu.Texture? prepare(gpu.GpuContext context, SharedColorAtlas atlas) {
    if (atlas.isEmpty) return null;
    _tex ??= context.createTexture(
      gpu.StorageMode.hostVisible,
      colorAtlasWidth,
      colorAtlasHeight,
      format: gpu.PixelFormat.r8g8b8a8UNormInt,
      enableRenderTargetUsage: false,
      enableShaderReadUsage: true,
      mipLevelCount: colorAtlasMipLevels,
    );
    if (_uploadedGen != atlas.generation) {
      _tex!.overwrite(ByteData.sublistView(atlas.pixels), mipLevel: 0);
      var src = atlas.pixels;
      var w = colorAtlasWidth;
      var h = colorAtlasHeight;
      for (var level = 1; level < colorAtlasMipLevels; level++) {
        final nw = w >> 1;
        final nh = h >> 1;
        final dst = Uint8List(nw * nh * 4);
        _downsample(src, w, dst, nw, nh);
        _tex!.overwrite(ByteData.sublistView(dst), mipLevel: level);
        src = dst;
        w = nw;
        h = nh;
      }
      _uploadedGen = atlas.generation;
    }
    return _tex;
  }

  /// 2×2 box filter (rounded) of premultiplied RGBA — one level to the next.
  static void _downsample(Uint8List src, int sw, Uint8List dst, int dw, int dh) {
    final srcStride = sw * 4;
    var di = 0;
    for (var y = 0; y < dh; y++) {
      final r0 = (y * 2) * srcStride;
      final r1 = r0 + srcStride;
      for (var x = 0; x < dw; x++) {
        final a = r0 + x * 8; // 2*x texels * 4 bytes
        final b = a + 4;
        final c = r1 + x * 8;
        final d = c + 4;
        dst[di] = (src[a] + src[b] + src[c] + src[d] + 2) >> 2;
        dst[di + 1] = (src[a + 1] + src[b + 1] + src[c + 1] + src[d + 1] + 2) >> 2;
        dst[di + 2] = (src[a + 2] + src[b + 2] + src[c + 2] + src[d + 2] + 2) >> 2;
        dst[di + 3] = (src[a + 3] + src[b + 3] + src[c + 3] + src[d + 3] + 2) >> 2;
        di += 4;
      }
    }
  }
}
