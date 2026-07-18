import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:flutter_gpu/gpu.dart' as gpu;

import 'package:gputext/gputext.dart';

import 'bench/bench_page.dart';
import 'chat_markdown_demo.dart';
import 'cursed_demo.dart';
import 'dragon_demo.dart';
import 'emoji_bitmap_demo.dart';
import 'features_demo.dart';
import 'google_sans_flex_demo.dart';
import 'gpu_text_blocks_demo.dart';
import 'gpu_text_view_demo.dart';
import 'sliver_blocks_demo.dart';
import 'sliver_gpu_text_demo.dart';
import 'justification_demo.dart';
import 'lowlevel_demo.dart';
import 'leak_report_page.dart';
import 'leak_tracking.dart';
import 'pretext_demo.dart';
import 'reader_demo.dart';
import 'rtl_demo.dart';
import 'shadow_demo.dart';
import 'sysfont_demo.dart';
import 'variable_font_demo.dart';
import 'widget_demo.dart';

gpu.PixelFormat gpuTextSurfaceFormat(gpu.GpuContext context) {
  final preferred = context.defaultColorFormat;
  if (preferred != gpu.PixelFormat.unknown &&
      context.supportsTextureFormat(preferred, renderTarget: true)) {
    return preferred;
  }
  // Extended-range defaults (e.g. B10G10R10 on macOS) are not exposed by flutter_gpu.
  return gpu.PixelFormat.b8g8r8a8UNormInt;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  maybeStartLeakTracking();
  // Bench mode measures cold init itself; everything else warms eagerly.
  if (io.Platform.environment['GPUTEXT_DEMO'] != 'bench') {
    GPUText.initialize(); // warm fonts + pipeline for the widget demo
  }
  runApp(const GPUTextApp());
}

class GPUTextApp extends StatelessWidget {
  const GPUTextApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Dev hook (demo only): open a specific demo page directly.
    final page =
        io.Platform.environment['GPUTEXT_DEMO'] ??
        const String.fromEnvironment('GPUTEXT_DEMO');
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      // Bench mode stays OUTSIDE SelectionArea: GPURichText registers
      // per-fragment selectables while bare RichText does not, so a
      // selection scope would tax only the gputext passes.
      home: switch (page) {
        'bench' => const BenchPage(),
        'chat' => const ChatMarkdownDemoPage(),
        'widgets' => const WidgetDemoPage(),
        'pretext' => const PretextDemoPage(),
        'dragon' => const DragonDemoPage(),
        'justify' => const JustificationDemoPage(),
        'lowlevel' => const LowLevelDemoPage(),
        'view' => const GPUTextViewDemoPage(),
        'sliver' => const SliverGPUTextDemoPage(),
        'sliverblocks' => const SliverBlocksDemoPage(),
        'reader' => const ReaderDemoPage(),
        'blocks' => const GPUTextBlocksDemoPage(),
        'gsf' => const GoogleSansFlexDemoPage(),
        'vars' => const VariableFontDemoPage(),
        'rtl' => const RtlDemoPage(),
        'cursed' => const CursedDemoPage(),
        'features' => const FeaturesDemoPage(),
        'emoji' => const EmojiBitmapDemoPage(),
        'sysfont' => const SysFontDemoPage(),
        'shadow' => const ShadowDemoPage(),
        'leaks' => const LeakReportPage(),
        _ => const GPUTextDemoPage(),
      },
    );
  }
}

class GPUTextDemoPage extends StatefulWidget {
  const GPUTextDemoPage({super.key});

  @override
  State<GPUTextDemoPage> createState() => _GPUTextDemoPageState();
}

class _GPUTextDemoPageState extends State<GPUTextDemoPage>
    with SingleTickerProviderStateMixin {
  GPUTextRenderer? _renderer;
  GPUTextScene? _scene;
  gpu.GpuImageSurface? _surface;
  String? _error;

  final _cam = _Camera();
  final _view = _Camera();
  double _attackT = -double.infinity;
  double _velX = 0;
  double _velY = 0;
  bool _dragging = false;
  double _lastMoveT = 0;
  Offset? _lastPanPos;
  double _pinchStartDistance = 0;
  Offset _pinchMid = Offset.zero;
  // ScaleUpdateDetails.scale is cumulative since onScaleStart, not incremental;
  // track the last value seen so each tick can derive its own per-tick ratio.
  double _prevScale = 1;

  ui.Image? _image;
  // Superseded surface+image generations, tagged with the frame number whose
  // render replaced them (mirrors RenderGPUParagraph._retired).
  final List<(gpu.GpuImageSurface?, ui.Image, int)> _retired = [];
  bool _timingsHooked = false;
  late final Ticker _ticker;
  double _dpr = 1;
  Size _size = Size.zero;
  double _fpsDt = 1000 / 60;
  double _prevTs = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    if (_timingsHooked) {
      _timingsHooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_flushRetired);
    }
    for (final (_, img, _) in _retired) {
      img.dispose();
    }
    _retired.clear();
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  // Frames reported here have finished rasterizing; images superseded by a
  // frame that old can no longer be referenced by the compositor.
  void _flushRetired(List<ui.FrameTiming> timings) {
    var latest = -1;
    for (final t in timings) {
      if (t.frameNumber > latest) latest = t.frameNumber;
    }
    while (_retired.isNotEmpty && _retired.first.$3 <= latest) {
      _retired.removeAt(0).$2.dispose();
    }
    if (_retired.isEmpty && _timingsHooked) {
      _timingsHooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_flushRetired);
    }
  }

  Future<void> _bootstrap() async {
    try {
      final bytes = await rootBundle.load('assets/Lato-Regular.ttf');
      final font = GPUFont.parse(bytes.buffer.asUint8List());
      final scene = GPUTextScene.build(font);
      final renderer = await GPUTextRenderer.create(
        curves: scene.atlas.curves,
        rows: scene.atlas.rows,
        instances: scene.instances,
      );
      if (!mounted) return;
      setState(() {
        _scene = scene;
        _renderer = renderer;
        _surface = gpu.gpuContext.createImageSurface(
          1,
          1,
          format: gpuTextSurfaceFormat(gpu.gpuContext),
        );
      });
      _wake();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  /// Resume ticking after a settle-mute (input, resize, recenter). A muted
  /// ticker keeps its elapsed clock, so the physics stays on one time base.
  void _wake() {
    _ticker.muted = false;
  }

  void _onTick(Duration elapsed) {
    if (_renderer == null || _scene == null || _surface == null) {
      // Nothing drawable (bootstrapping / failed): stop pumping frames.
      // [_bootstrap] wakes the ticker when the scene is ready.
      _ticker.muted = true;
      return;
    }
    final now = elapsed.inMicroseconds / 1000.0;
    var dt = _prevTs == 0 ? 1000 / 60 : now - _prevTs;
    // The first tick after a settle-mute spans the whole idle gap — treat
    // it as one nominal frame or the fps readout / decay math blows up.
    if (dt > 250) dt = 1000 / 60;
    _prevTs = now;
    _fpsDt = _fpsDt * 0.9 + dt * 0.1;

    if (!_dragging && (_velX != 0 || _velY != 0) && dt > 0) {
      _cam.panBy(_velX * dt, _velY * dt);
      final decay = math.pow(0.8, dt / (1000 / 60));
      _velX *= decay;
      _velY *= decay;
      if (_velX.abs() < 0.002 && _velY.abs() < 0.002) {
        _velX = _velY = 0;
      }
    }

    const attackMs = 300.0;
    const smoothK = 0.3;
    final s = now - _attackT >= attackMs
        ? 0.0
        : 1.0 - (now - _attackT) / attackMs;
    if (s > 0) {
      final k = 1 - s * (1 - smoothK);
      final kf = 1 - math.pow(1 - k, dt / (1000 / 60));
      _view.x += (_cam.x - _view.x) * kf;
      _view.y += (_cam.y - _view.y) * kf;
      _view.z *= math.pow(_cam.z / _view.z, kf);
    } else {
      _view.x = _cam.x;
      _view.y = _cam.y;
      _view.z = _cam.z;
    }

    _renderFrame();
    setState(() {});

    // Settled (no drag, no fling velocity, attack smoothing finished): mute
    // the ticker. A running ticker schedules a frame EVERY vsync even when
    // its callback would just redraw an identical scene — which reads as a
    // permanent ~60fps refresh in the performance tools while the page sits
    // idle. Input / resize / recenter call [_wake] to resume.
    if (!_dragging && _velX == 0 && _velY == 0 && s <= 0) {
      _ticker.muted = true;
    }
  }

  void _renderFrame() {
    final renderer = _renderer!;
    var surface = _surface!;
    final width = (_size.width * _dpr).round().clamp(1, 100000);
    final height = (_size.height * _dpr).round().clamp(1, 100000);
    if (surface.width != width || surface.height != height) {
      // Never resize() a live surface — see RenderGPUParagraph: resizing
      // while a presented image is still referenced can leave later frames on
      // a stale-size backing texture. Recreate and retire the old one below.
      surface = gpu.gpuContext.createImageSurface(
        width,
        height,
        format: gpuTextSurfaceFormat(gpu.gpuContext),
      );
    }

    final frame = surface.acquireNextFrame();
    final cmd = gpu.gpuContext.createCommandBuffer();
    final br = background[0];
    final bg = background[1];
    final bb = background[2];
    final ba = background[3];
    final target = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: frame.colorTexture,
        loadAction: gpu.LoadAction.clear,
        storeAction: gpu.StoreAction.store,
        clearValue: vm.Vector4(br * ba, bg * ba, bb * ba, ba),
      ),
    );
    final pass = cmd.createRenderPass(target);
    renderer.render(
      pass: pass,
      frame: FrameUniforms(
        width: width.toDouble(),
        height: height.toDouble(),
        cam: _view.uniform(width.toDouble(), height.toDouble()),
      ),
    );
    frame.present(cmd);
    cmd.submit();
    // Each currentImage call returns a new handle; retire the previous one
    // (with its surface, which must outlive it) and dispose it once the
    // engine reports a frame at least this new has finished rasterizing.
    final prevImage = _image;
    if (prevImage != null) {
      _retired.add((
        identical(_surface, surface) ? null : _surface,
        prevImage,
        ui.PlatformDispatcher.instance.frameData.frameNumber,
      ));
      if (!_timingsHooked) {
        _timingsHooked = true;
        SchedulerBinding.instance.addTimingsCallback(_flushRetired);
      }
    }
    _surface = surface;
    _image = surface.currentImage;
  }

  void _openDemo(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Widget _demoButton(String label, Widget page) => TextButton(
    onPressed: () => _openDemo(page),
    style: TextButton.styleFrom(
      foregroundColor: Colors.white,
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    child: Text(label, style: const TextStyle(fontSize: 13)),
  );

  void _recenter() {
    final scene = _scene;
    if (scene == null) return;
    _velX = _velY = 0;
    const rowsToShow = 10.0;
    final rowH = 1.18 * maxSize;
    _cam.z = _cam.clampZoom(_size.height * _dpr / (rowsToShow * rowH), _dpr);
    final pad = 24 * _dpr;
    _cam.x = scene.bounds.minX + (_size.width * _dpr / 2 - pad) / _cam.z;
    _cam.y = scene.bounds.maxY - (_size.height * _dpr / 2 - pad) / _cam.z;
    _view.copyFrom(_cam);
    _wake();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: Color.fromARGB(
          255,
          (background[0] * 255).round(),
          (background[1] * 255).round(),
          (background[2] * 255).round(),
        ),
        body: Center(
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Render the glyph surface at the panel's native pixel density. The
        // shader computes analytic AA at surface resolution, so under-resolving
        // here (the old 2.0 cap) forced a nearest-neighbor upscale on >2x phones
        // that re-aliased every edge. The 4.0 ceiling just bounds worst-case fill.
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // A muted (settled) ticker must resume for one frame so the surface
        // re-renders at the new panel size / density.
        if (dpr != _dpr || size != _size) _wake();
        _dpr = dpr;
        _size = size;
        if (_scene != null && _view.z == 1 && _cam.z == 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _recenter());
        }

        final zoom = _view.z / _dpr;
        final fps = math.min(120, (1000 / _fpsDt).round());

        return Scaffold(
          backgroundColor: Color.fromARGB(
            255,
            (background[0] * 255).round(),
            (background[1] * 255).round(),
            (background[2] * 255).round(),
          ),
          body: Stack(
            children: [
              Listener(
                // Trackpad two-finger pan/pinch arrives as PointerPanZoomUpdateEvents,
                // which GestureDetector's ScaleGestureRecognizer already consumes below
                // (pointerCount is >=2 for a trackpad panZoom) — don't also handle them
                // here, or the two handlers apply the same pan twice and cancel out.
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    final pos = event.localPosition * _dpr;
                    _cam.zoomAt(
                      pos.dx,
                      pos.dy,
                      math.exp(-event.scrollDelta.dy * 0.0015),
                      _dpr,
                      _size.width * _dpr,
                      _size.height * _dpr,
                    );
                    _wake();
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: (details) {
                    _wake();
                    _dragging = true;
                    _velX = _velY = 0;
                    _lastMoveT = _prevTs;
                    _attackT = _prevTs;
                    _lastPanPos = details.localFocalPoint;
                    _pinchStartDistance = 0;
                    _pinchMid = details.localFocalPoint;
                    _prevScale = 1;
                  },
                  onScaleUpdate: (details) {
                    _wake();
                    if (details.pointerCount >= 2) {
                      if (_pinchStartDistance == 0) {
                        _pinchStartDistance = 1;
                        _pinchMid = details.localFocalPoint;
                        _prevScale = details.scale;
                      }
                      final focal = details.localFocalPoint * _dpr;
                      final prevMid = _pinchMid * _dpr;
                      _cam.panBy(focal.dx - prevMid.dx, focal.dy - prevMid.dy);
                      _cam.zoomAt(
                        focal.dx,
                        focal.dy,
                        details.scale / _prevScale,
                        _dpr,
                        _size.width * _dpr,
                        _size.height * _dpr,
                      );
                      _pinchMid = details.localFocalPoint;
                      _prevScale = details.scale;
                    } else if (_lastPanPos != null) {
                      final delta = details.localFocalPoint - _lastPanPos!;
                      _cam.panBy(delta.dx * _dpr, delta.dy * _dpr);
                      final dt = _prevTs - _lastMoveT;
                      if (dt > 0) {
                        _velX = _velX == 0
                            ? (delta.dx * _dpr) / dt
                            : _velX * 0.7 + ((delta.dx * _dpr) / dt) * 0.3;
                        _velY = _velY == 0
                            ? (delta.dy * _dpr) / dt
                            : _velY * 0.7 + ((delta.dy * _dpr) / dt) * 0.3;
                        _lastMoveT = _prevTs;
                      }
                      _lastPanPos = details.localFocalPoint;
                    }
                  },
                  onScaleEnd: (_) {
                    _dragging = false;
                    _lastPanPos = null;
                    _pinchStartDistance = 0;
                    if (_prevTs - _lastMoveT > 80) {
                      _velX = _velY = 0;
                    }
                  },
                  child: CustomPaint(
                    painter: _GpuImagePainter(_image),
                    size: Size.infinite,
                  ),
                ),
              ),
              Positioned(
                left: 16,
                top: 16,
                child: SafeArea(
                  child: IntrinsicWidth(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Text(
                              '$fps fps • ${_fmtZoom(zoom)}x',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _demoButton(
                                'New features',
                                const FeaturesDemoPage(),
                              ),
                              _demoButton(
                                'AI chat markdown',
                                const ChatMarkdownDemoPage(),
                              ),
                              _demoButton('Pretext', const PretextDemoPage()),
                              _demoButton('Dragon', const DragonDemoPage()),
                              _demoButton('Cursed', const CursedDemoPage()),
                              _demoButton(
                                'Low-level / isolate',
                                const LowLevelDemoPage(),
                              ),
                              _demoButton(
                                'GPUTextView widget',
                                const GPUTextViewDemoPage(),
                              ),
                              _demoButton(
                                'Lazy blocks',
                                const GPUTextBlocksDemoPage(),
                              ),
                              _demoButton(
                                'SliverGPUText',
                                const SliverGPUTextDemoPage(),
                              ),
                              _demoButton(
                                'SliverBlocks',
                                const SliverBlocksDemoPage(),
                              ),
                              _demoButton(
                                'Reader (essay)',
                                const ReaderDemoPage(),
                              ),
                              _demoButton(
                                'Bitmap emoji',
                                const EmojiBitmapDemoPage(),
                              ),
                              _demoButton('Sys font', const SysFontDemoPage()),
                              _demoButton(
                                'Justification',
                                const JustificationDemoPage(),
                              ),
                              _demoButton('Widgets', const WidgetDemoPage()),
                              _demoButton(
                                'GSF flex demo',
                                const GoogleSansFlexDemoPage(),
                              ),
                              _demoButton('RTL', const RtlDemoPage()),
                              _demoButton(
                                'Variable fonts',
                                const VariableFontDemoPage(),
                              ),
                              if (leakTrackingActive)
                                TextButton(
                                  onPressed: () async {
                                    final leaks = await collectAndReportLeaks();
                                    if (!context.mounted) return;
                                    await Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            LeakReportPage(initialLeaks: leaks),
                                      ),
                                    );
                                  },
                                  style: TextButton.styleFrom(
                                    foregroundColor: const Color(0xFFFFCC80),
                                    minimumSize: Size.zero,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: const Text(
                                    'Leak report',
                                    style: TextStyle(fontSize: 13),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 16,
                top: 16,
                child: SafeArea(
                  child: TextButton(
                    onPressed: _recenter,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.black.withValues(alpha: 0.45),
                    ),
                    child: const Text('Recenter'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _GpuImagePainter extends CustomPainter {
  _GpuImagePainter(this.image);

  final ui.Image? image;

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img == null) return;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..filterQuality = FilterQuality.none,
    );
  }

  @override
  bool shouldRepaint(covariant _GpuImagePainter oldDelegate) => true;
}

class _Camera {
  double x = 0;
  double y = 0;
  double z = 1;

  void copyFrom(_Camera other) {
    x = other.x;
    y = other.y;
    z = other.z;
  }

  double clampZoom(double value, double dpr) =>
      value.clamp(0.005 * dpr, 100 * dpr);

  void panBy(double dxDev, double dyDev) {
    x -= dxDev / z;
    y -= dyDev / z;
  }

  void zoomAt(
    double sx,
    double sy,
    double factor,
    double dpr,
    double viewportW,
    double viewportH,
  ) {
    final wx = (sx - viewportW / 2) / z + x;
    final wy = (sy - viewportH / 2) / z + y;
    z = clampZoom(z * factor, dpr);
    x = wx - (sx - viewportW / 2) / z;
    y = wy - (sy - viewportH / 2) / z;
  }

  List<double> uniform(double width, double height) {
    return [z, z, width / 2 - z * x, height / 2 - z * y];
  }
}

String _fmtZoom(double z) {
  if (z >= 100) return z.toStringAsFixed(0);
  if (z >= 1) return z.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
  return z.toStringAsFixed(3);
}
