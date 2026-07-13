// Shared GPU state for gputext draws: shader bundle, render pipeline,
// uniform slots, the 4-corner unit quad, and a per-frame host buffer.
// Per-draw state (instance buffer, atlas textures, frame uniforms) is passed
// into renderInstances so many widgets can share one pipeline.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_gpu/gpu.dart' as gpu;

import '../atlas.dart';

// Legacy file-asset key (pubspec / ShaderBundleAssetMode.legacyOnly).
const _bundleAssetLegacy = 'build/shaderbundles/gputext.shaderbundle';
// DataAsset key from flutter_gpu_shaders (dataAssetsIfAvailable / Required).
// Android debug builds often ship only this path.
const _bundleAssetData =
    'flutter_gpu_shaders/shaderbundles/gputext.shaderbundle';

const _bundleAssetKeys = <String>[
  _bundleAssetLegacy,
  'packages/gputext/$_bundleAssetLegacy',
  _bundleAssetData,
  'packages/gputext/$_bundleAssetData',
];

class FrameUniforms {
  const FrameUniforms({
    required this.width,
    required this.height,
    this.style = const [1, 1],
    this.cam = const [1, 1, 0, 0],
    this.guardPx = 3.7,
  });

  final double width;
  final double height;

  /// `(gamma, sharp)` coverage styling; `(1, 1)` leaves exact coverage untouched.
  final List<double> style;

  /// device px = world px * (cam[0], cam[1]) + (cam[2], cam[3]).
  final List<double> cam;

  /// Minification-guard threshold in device pixels (whole glyph, both axes).
  /// Default `3.7` matches windfoil; raise toward `8` for thumbnail workloads.
  final double guardPx;
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
    // One entry per failed attempt; distinct causes only (all four asset keys
    // fail with the same message when Impeller itself is off).
    final failures = <String>[];
    void recordFailure(String attempt, Object error) {
      final cause = '$error';
      if (!failures.any((f) => f.endsWith(cause))) {
        failures.add('$attempt: $cause');
      }
    }

    // Try legacy + DataAsset keys, bare and packages/gputext/-prefixed.
    // Which one is present depends on Flutter data-assets support and whether
    // gputext is the app root or a dependency.
    for (final asset in _bundleAssetKeys) {
      try {
        library = await gpu.ShaderLibrary.fromAsset(asset);
      } catch (e) {
        recordFailure(asset, e);
        library = null;
      }
      if (library != null) break;
    }
    library ??= await _loadBundleFromPackageDir(recordFailure);
    if (library == null) {
      throw Exception(
        'Failed to load gputext shader bundle.\n'
        '  ${failures.join('\n  ')}\n'
        'If this is a test, run it with '
        '`flutter test --enable-impeller --enable-flutter-gpu`.',
      );
    }

    final vert = library['GPUTextVertex'];
    final frag = library['GPUTextFragment'];
    if (vert == null || frag == null) {
      throw Exception('Missing GPUText shaders in bundle');
    }

    return _fromShaders(vert, frag);
  }

  /// Debug/test fallback: `flutter test` never registers hook data assets
  /// with the tester's asset manager, so none of the [_bundleAssetKeys]
  /// resolve there. The build hook always writes the compiled bundle to
  /// `build/shaderbundles/` under the package root (whatever the asset mode),
  /// and hooks run as part of `flutter test`, so that file exists and is
  /// fresh — load it directly with [gpu.ShaderLibrary.fromBytes].
  static Future<gpu.ShaderLibrary?> _loadBundleFromPackageDir(
    void Function(String attempt, Object error) recordFailure,
  ) async {
    if (kReleaseMode) return null;
    final candidates = <String>{};
    try {
      // Resolve gputext's package root the way the tester itself does:
      // through package_config.json. (Isolate.resolvePackageUri is
      // unsupported in flutter_tester.) Covers consumers running their own
      // tests, where cwd is their package, not gputext's.
      final root = _gputextRootFromPackageConfig();
      if (root != null) {
        candidates.add('$root/$_bundleAssetLegacy');
      }
    } catch (e) {
      recordFailure('package:gputext resolution', e);
    }
    candidates.add(_bundleAssetLegacy); // cwd when gputext runs its own tests
    for (final path in candidates) {
      final file = File(path);
      if (!file.existsSync()) {
        recordFailure('file $path', 'not found');
        continue;
      }
      try {
        final bytes = file.readAsBytesSync();
        final library = await gpu.ShaderLibrary.fromBytes(
          bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes),
        );
        if (library != null) return library;
        recordFailure('file $path', 'unparseable shader bundle');
      } catch (e) {
        recordFailure('file $path', e);
      }
    }
    return null;
  }

  /// gputext's package root, from the nearest package_config.json at or
  /// above cwd (pub workspaces keep it at the workspace root, not next to
  /// the package under test). Null when no config or no gputext entry.
  static String? _gputextRootFromPackageConfig() {
    var dir = Directory.current;
    while (true) {
      final config = File('${dir.path}/.dart_tool/package_config.json');
      if (config.existsSync()) {
        final doc =
            jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
        final packages = doc['packages'] as List<Object?>? ?? const [];
        for (final entry in packages) {
          final pkg = entry as Map<String, Object?>;
          if (pkg['name'] != 'gputext') continue;
          // rootUri is resolved against the config file's own location and
          // may be relative ("../packages/gputext") or absolute (file:///).
          var rootUri = Uri.parse(pkg['rootUri']! as String);
          if (!rootUri.path.endsWith('/')) {
            rootUri = rootUri.replace(path: '${rootUri.path}/');
          }
          final resolved = config.absolute.uri.resolveUri(rootUri);
          if (!resolved.isScheme('file')) return null;
          final path = File.fromUri(resolved).path;
          return path.endsWith(Platform.pathSeparator)
              ? path.substring(0, path.length - 1)
              : path;
        }
        return null;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  static GPUTextPipeline _fromShaders(gpu.Shader vert, gpu.Shader frag) {
    final vertexLayout = gpu.VertexLayout(
      buffers: [
        const gpu.VertexBuffer(
          strideInBytes: 8,
          attributes: [
            gpu.VertexAttribute(
              name: 'corner',
              format: gpu.VertexFormat.float32x2,
            ),
          ],
        ),
        const gpu.VertexBuffer(
          strideInBytes: 64,
          stepMode: gpu.VertexStepMode.instance,
          attributes: [
            gpu.VertexAttribute(
              name: 'place',
              format: gpu.VertexFormat.float32x4,
              offsetInBytes: 0,
            ),
            gpu.VertexAttribute(
              name: 'bbox',
              format: gpu.VertexFormat.float32x4,
              offsetInBytes: 16,
            ),
            gpu.VertexAttribute(
              name: 'color',
              format: gpu.VertexFormat.float32x4,
              offsetInBytes: 32,
            ),
            gpu.VertexAttribute(
              name: 'band',
              format: gpu.VertexFormat.float32x4,
              offsetInBytes: 48,
            ),
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
    // std140 FrameInfo: vec2 res, vec2 style, vec4 cam, float guardPx + pad.
    final frameData = Float32List.fromList([
      frame.width,
      frame.height,
      frame.style[0],
      frame.style[1],
      frame.cam[0],
      frame.cam[1],
      frame.cam[2],
      frame.cam[3],
      frame.guardPx,
      0,
      0,
      0,
    ]);
    // Each render gets its own immutable uniform buffer. A shared HostBuffer
    // arena here is a use-after-recycle hazard: submit() only ENQUEUES GPU
    // work, so reset()+emplace from a later same-frame render (e.g. a nested
    // GPURichText inside a WidgetSpan, which renders during its parent's
    // paint) would overwrite this FrameInfo before Metal executes the draw —
    // the parent's surface then renders with the child's camera.
    final frameBuffer = gpu.gpuContext.createDeviceBufferWithCopy(
      frameData.buffer.asByteData(),
    );
    final frameView = gpu.BufferView(
      frameBuffer,
      offsetInBytes: 0,
      lengthInBytes: frameBuffer.sizeInBytes,
    );

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
      gpu.BufferView(
        cornerBuffer,
        offsetInBytes: 0,
        lengthInBytes: cornerBuffer.sizeInBytes,
      ),
      slot: 0,
    );
    pass.bindVertexBuffer(
      gpu.BufferView(
        instances,
        offsetInBytes: 0,
        lengthInBytes: instanceCount * 64,
      ),
      slot: 1,
    );
    pass.draw(4, instanceCount: instanceCount);
  }
}
