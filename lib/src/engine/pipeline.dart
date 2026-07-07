// Shared GPU state for gputext draws: shader bundle, render pipeline,
// uniform slots, the 4-corner unit quad, and a per-frame host buffer.
// Per-draw state (instance buffer, atlas textures, frame uniforms) is passed
// into renderInstances so many widgets can share one pipeline.

import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;

import '../atlas.dart';
import '../layout.dart';

const _bundleAsset = 'build/shaderbundles/gputext.shaderbundle';
const _bundleAssetPackaged = 'packages/gputext/$_bundleAsset';

class FrameUniforms {
  const FrameUniforms({
    required this.width,
    required this.height,
    this.style = const [1, 1],
    this.cam = const [1, 1, 0, 0],
  });

  final double width;
  final double height;
  final List<double> style;

  /// device px = world px * (cam[0], cam[1]) + (cam[2], cam[3]).
  final List<double> cam;
}

class GPUTextPipeline {
  GPUTextPipeline._({
    required this.pipeline,
    required this.frameSlot,
    required this.curvesSlot,
    required this.rowsSlot,
    required this.cornerBuffer,
  });

  final gpu.RenderPipeline pipeline;
  final gpu.UniformSlot frameSlot;
  final gpu.UniformSlot curvesSlot;
  final gpu.UniformSlot rowsSlot;
  final gpu.DeviceBuffer cornerBuffer;

  static Future<GPUTextPipeline> create() async {
    gpu.ShaderLibrary? library;
    // Bare key when the app IS this package (demo); packages/-prefixed when
    // gputext is consumed as a dependency.
    for (final asset in const [_bundleAsset, _bundleAssetPackaged]) {
      try {
        library = await gpu.ShaderLibrary.fromAsset(asset);
      } catch (_) {
        library = null;
      }
      if (library != null) break;
    }
    if (library == null) {
      throw Exception('Failed to load gputext shader bundle '
          '($_bundleAsset / $_bundleAssetPackaged)');
    }

    final vert = library['GPUTextVertex'];
    final frag = library['GPUTextFragment'];
    if (vert == null || frag == null) {
      throw Exception('Missing GPUText shaders in bundle');
    }

    final vertexLayout = gpu.VertexLayout(
      buffers: [
        const gpu.VertexBuffer(
          strideInBytes: 8,
          attributes: [
            gpu.VertexAttribute(
                name: 'corner', format: gpu.VertexFormat.float32x2),
          ],
        ),
        const gpu.VertexBuffer(
          strideInBytes: 64,
          stepMode: gpu.VertexStepMode.instance,
          attributes: [
            gpu.VertexAttribute(
                name: 'place',
                format: gpu.VertexFormat.float32x4,
                offsetInBytes: 0),
            gpu.VertexAttribute(
                name: 'bbox',
                format: gpu.VertexFormat.float32x4,
                offsetInBytes: 16),
            gpu.VertexAttribute(
                name: 'color',
                format: gpu.VertexFormat.float32x4,
                offsetInBytes: 32),
            gpu.VertexAttribute(
                name: 'band',
                format: gpu.VertexFormat.float32x4,
                offsetInBytes: 48),
          ],
        ),
      ],
    );

    final pipeline = gpu.gpuContext.createRenderPipeline(
      vert,
      frag,
      vertexLayout: vertexLayout,
    );

    final corners = Float32List.fromList([0, 0, 1, 0, 0, 1, 1, 1]);
    final cornerBuffer = gpu.gpuContext.createDeviceBufferWithCopy(
      corners.buffer.asByteData(),
    );

    return GPUTextPipeline._(
      pipeline: pipeline,
      frameSlot: vert.getUniformSlot('FrameInfo'),
      curvesSlot: frag.getUniformSlot('curvesTex'),
      rowsSlot: frag.getUniformSlot('rowsTex'),
      cornerBuffer: cornerBuffer,
    );
  }

  gpu.DeviceBuffer uploadInstances(Float32List instances) =>
      gpu.gpuContext.createDeviceBufferWithCopy(instances.buffer.asByteData());

  void renderInstances({
    required gpu.RenderPass pass,
    required FrameUniforms frame,
    required gpu.DeviceBuffer instances,
    required int instanceCount,
    required AtlasTextures textures,
  }) {
    if (instanceCount == 0) return;
    final frameData = Float32List.fromList([
      frame.width,
      frame.height,
      frame.style[0],
      frame.style[1],
      frame.cam[0],
      frame.cam[1],
      frame.cam[2],
      frame.cam[3],
    ]);
    // Each render gets its own immutable uniform buffer. A shared HostBuffer
    // arena here is a use-after-recycle hazard: submit() only ENQUEUES GPU
    // work, so reset()+emplace from a later same-frame render (e.g. a nested
    // GPURichText inside a WidgetSpan, which renders during its parent's
    // paint) would overwrite this FrameInfo before Metal executes the draw —
    // the parent's surface then renders with the child's camera.
    final frameBuffer =
        gpu.gpuContext.createDeviceBufferWithCopy(frameData.buffer.asByteData());
    final frameView = gpu.BufferView(frameBuffer,
        offsetInBytes: 0, lengthInBytes: frameBuffer.sizeInBytes);

    pass.bindPipeline(pipeline);
    pass.setColorBlendEnable(true);
    pass.setColorBlendEquation(
      gpu.ColorBlendEquation(
        colorBlendOperation: gpu.BlendOperation.add,
        sourceColorBlendFactor: gpu.BlendFactor.one,
        destinationColorBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
        alphaBlendOperation: gpu.BlendOperation.add,
        sourceAlphaBlendFactor: gpu.BlendFactor.one,
        destinationAlphaBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
      ),
    );
    pass.setPrimitiveType(gpu.PrimitiveType.triangleStrip);
    pass.bindUniform(frameSlot, frameView);
    pass.bindTexture(curvesSlot, textures.curves);
    pass.bindTexture(rowsSlot, textures.rows);
    pass.bindVertexBuffer(
      gpu.BufferView(cornerBuffer,
          offsetInBytes: 0, lengthInBytes: cornerBuffer.sizeInBytes),
      slot: 0,
    );
    pass.bindVertexBuffer(
      gpu.BufferView(instances,
          offsetInBytes: 0, lengthInBytes: instanceCount * 64),
      slot: 1,
    );
    pass.draw(4, instanceCount: instanceCount);
  }

  int instanceCountOf(Float32List instances) =>
      instances.length ~/ floatsPerInstance;
}
