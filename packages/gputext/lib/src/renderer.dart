// Demo-scene renderer: one static instance buffer + one atlas, drawn through
// the shared GPUTextPipeline. Widgets use GPUTextPipeline directly.

import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

import 'atlas.dart';
import 'engine/pipeline.dart';
import 'layout.dart';

export 'engine/pipeline.dart' show FrameUniforms;

class GPUTextRenderer {
  GPUTextRenderer._({
    required this.pipeline,
    required this.instanceBuffer,
    required this.textures,
    required this.instanceCount,
  });

  final GPUTextPipeline pipeline;
  final gpu.DeviceBuffer instanceBuffer;
  final AtlasTextures textures;
  final int instanceCount;

  static Future<GPUTextRenderer> create({
    required Float32List curves,
    required Uint32List rows,
    required Float32List instances,
  }) async {
    final pipeline = await GPUTextPipeline.create();
    return GPUTextRenderer._(
      pipeline: pipeline,
      instanceBuffer: pipeline.uploadInstances(instances),
      textures: uploadAtlasTextures(gpu.gpuContext, curves, rows),
      instanceCount: instances.length ~/ floatsPerInstance,
    );
  }

  void render({required gpu.RenderPass pass, required FrameUniforms frame}) {
    pipeline.renderInstances(
      pass: pass,
      frame: frame,
      instances: instanceBuffer,
      instanceCount: instanceCount,
      textures: textures,
    );
  }
}
