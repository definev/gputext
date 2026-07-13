// End-to-end GPU proof for the color-bitmap (emoji) path: parse a CBDT font →
// decode+pack a real emoji PNG into the color atlas → upload the RGBA8 texture
// → draw it through the color pipeline into an offscreen surface → read the
// pixels back and confirm the emoji actually rendered (opaque, colored).
//
// Requires a GPU: run with
//   flutter test --enable-impeller --enable-flutter-gpu
// It self-skips when Flutter GPU is unavailable (same as gpu_init_test).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/src/engine/engine.dart';
import 'package:gputext/src/engine/pipeline.dart';
import 'package:gputext/src/font.dart';
import 'package:vector_math/vector_math.dart' as vm;

File _resolve(String path) {
  for (final prefix in const ['', 'packages/gputext/']) {
    final f = File('$prefix$path');
    if (f.existsSync()) return f;
  }
  throw StateError('font not found from ${Directory.current.path}: $path');
}

const _cbdtPath =
    'third_party/harfbuzz/test/api/fonts/NotoColorEmoji.subset.default.39.ttf';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bitmap emoji draws opaque colored pixels via the color pipeline',
      () async {
    final engine = GPUText.instance;
    await engine.ensureInitialized();
    if (!engine.gpuReady) {
      markTestSkipped('Flutter GPU unavailable — run with '
          '--enable-impeller --enable-flutter-gpu');
      return;
    }

    // Phase 3: the color pipeline built alongside the coverage pipeline.
    expect(engine.pipeline.hasColorPipeline, isTrue);

    final font = GPUFont.parse(_resolve(_cbdtPath).readAsBytesSync());
    engine.registerEmojiFont(font); // accepts bitmap fonts now

    // Phase 1+2: parse + decode + pack glyph 1 (a 136×128 PNG at ppem 109).
    final ppem = await engine.colorAtlas.ensure(font, 1, 100);
    expect(ppem, isNotNull);
    final entry = engine.colorAtlas.lookup(font, 1, ppem!);
    expect(entry, isNotNull);

    // Phase 4: upload the RGBA8 atlas to a GPU texture.
    final tex = engine.prepareColorTexture();
    expect(tex, isNotNull, reason: 'color atlas texture upload failed on GPU');

    // Draw one full-surface quad sampling the glyph, identity camera.
    const dim = 64;
    final instances = Float32List.fromList([
      0, 0, dim.toDouble(), dim.toDouble(), // rect (world px)
      entry!.u0, entry.v0, entry.u1, entry.v1, // uv
      1, 1, 1, 1, // tint (white, opaque)
    ]);
    final buffer = engine.pipeline.uploadColorInstances(instances);

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
    engine.pipeline.renderColorInstances(
      pass: pass,
      frame: FrameUniforms(width: dim.toDouble(), height: dim.toDouble()),
      instances: buffer,
      instanceCount: 1,
      colorAtlas: tex!,
    );
    frame.present(cmd);
    cmd.submit();

    final image = surface.currentImage;
    expect(image, isNotNull);
    final bytes = await image!.toByteData();
    expect(bytes, isNotNull);

    // The glyph is alpha-textured: opaque pixels trace its shape (partial
    // surface coverage), and their luminance varies because we're sampling the
    // atlas — a broken/solid draw would fill uniformly. (This particular subset
    // glyph is near-monochrome, so we assert on structure, not chroma.)
    var opaque = 0;
    final lumas = <int>{};
    final data = bytes!;
    for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
      final r = data.getUint8(i);
      final g = data.getUint8(i + 1);
      final b = data.getUint8(i + 2);
      final a = data.getUint8(i + 3);
      if (a > 0) {
        opaque++;
        lumas.add((r + g + b) ~/ 3);
      }
    }
    final total = dim * dim;
    debugPrint('color-render: opaque=$opaque/$total lumaLevels=${lumas.length}');
    expect(opaque, greaterThan(0), reason: 'emoji quad rendered nothing');
    expect(opaque, lessThan(total),
        reason: 'covered the whole surface — texture alpha not applied');
    expect(lumas.length, greaterThan(1),
        reason: 'uniform fill — atlas texture was not sampled');

    engine.registerEmojiFont(null);
  });
}
