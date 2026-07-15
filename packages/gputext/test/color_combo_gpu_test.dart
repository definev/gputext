// Reproduces the mixed coverage+color case (text glyph + bitmap emoji) as a
// direct, forced-readback draw so a bad draw crashes synchronously instead of
// async on a SwiftShader worker. Coverage draw + color draw on ONE pass.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';
import 'package:vector_math/vector_math.dart' as vm;

File _resolve(String path) {
  for (final prefix in const [
    '',
    'packages/gputext/',
    '/Users/vsf/source/github.com/definev/gputext/example/',
  ]) {
    final f = File('$prefix$path');
    if (f.existsSync()) return f;
  }
  throw StateError('not found from ${Directory.current.path}: $path');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('coverage + color draw on one pass, forced readback', () async {
    final engine = GPUText.instance;
    await engine.ensureInitialized();
    if (!engine.gpuReady) {
      markTestSkipped('GPU unavailable');
      return;
    }
    final lato = GPUFont.parse(
      _resolve('assets/Lato-Regular.ttf').readAsBytesSync(),
    );
    final noto = GPUFont.parse(
      _resolve('assets/NotoColorEmoji.ttf').readAsBytesSync(),
    );

    // --- Coverage glyph 'A' ---
    engine.atlas.ensureGlyphs(lato, 'A');
    final e = engine.atlas.lookupRune(lato, 0x41)!;
    final textures = engine.prepareTextures()!;
    const dim = 64;
    final scale = dim / lato.unitsPerEm;
    final cov = Float32List.fromList([
      4, dim - 8.0, scale, 0, // pen, baseline, scale, fillRule
      e.bbox[0], e.bbox[1], e.bbox[2], e.bbox[3],
      0, 0, 0, 1, // black
      e.rowBase.toDouble(), e.bandCount.toDouble(), e.y0, e.invH,
    ]);
    final covBuf = engine.pipeline.uploadInstances(cov);

    // --- Color glyph 😀-ish (🌚 = U+1F31A) ---
    final gid = noto.glyphIdForRune(0x1F31A)!;
    final ppem = await engine.colorAtlas.ensure(noto, gid, 40);
    final entry = engine.colorAtlas.lookup(noto, gid, ppem!)!;
    final colorTex = engine.prepareColorTexture()!;
    final color = Float32List.fromList([
      dim / 2.0, 8, dim.toDouble(), dim - 8.0, // rect
      entry.u0, entry.v0, entry.u1, entry.v1,
      1, 1, 1, 1,
    ]);
    final colorBuf = engine.pipeline.uploadColorInstances(color);

    final surface = gpu.gpuContext.createImageSurface(dim, dim);
    final frame = surface.acquireNextFrame();
    final cmd = gpu.gpuContext.createCommandBuffer();
    final target = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: frame.colorTexture,
        loadAction: gpu.LoadAction.clear,
        storeAction: gpu.StoreAction.store,
        clearValue: vm.Vector4(0, 0, 0, 0),
      ),
    );
    final pass = cmd.createRenderPass(target);
    final f = FrameUniforms(width: dim.toDouble(), height: dim.toDouble());
    engine.pipeline.renderInstances(
      pass: pass,
      frame: f,
      instances: covBuf,
      instanceCount: 1,
      textures: textures,
    );
    engine.pipeline.renderColorInstances(
      pass: pass,
      frame: f,
      instances: colorBuf,
      instanceCount: 1,
      colorAtlas: colorTex,
    );
    frame.present(cmd);
    cmd.submit();

    // Forced readback → waits for the draws, surfacing any crash here.
    final bytes = await surface.currentImage!.toByteData();
    var opaque = 0;
    for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
      if (bytes.getUint8(i) > 0) opaque++;
    }
    expect(opaque, greaterThan(0));
  });
}
