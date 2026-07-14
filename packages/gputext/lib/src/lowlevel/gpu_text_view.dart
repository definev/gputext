// A drop-in widget for the isolate layout API: give it registered fonts and a
// document; it prepares once, reflows off the UI isolate on resize, and renders
// the result as real GPU glyphs — virtualized, so GPU memory stays constant for
// a document of any length.
//
// This bundles the reusable half of the low-level pipeline (the isolate reflow
// driver, the offscreen GPU surface + its lifecycle, viewport virtualization,
// and the async-staleness handling) behind two types:
//
//   * [GPUTextViewController] — owns the background [GPUTextWorker] and the
//     fonts registered on it. Create once, share across any number of views.
//   * [GPUTextView] — the widget. Point it at a controller and a
//     [GPUTextDocument]; it does the rest.
//
// Nothing here touches the `GPURichText` widget flow or the `GPUText` singleton.
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import '../atlas.dart' show AtlasTextures, uploadAtlasTextures;
import '../engine/pipeline.dart' show GPUTextPipeline, FrameUniforms;
import '../layout.dart' show floatsPerInstance;
import '../paragraph.dart' show PlaceholderBox, InlinePlaceholderAlignment;
import 'gpu_text_worker.dart';
import 'text_span_specs.dart' show flattenInlineSpan, PlaceholderSizer;

// A single GPU texture can't hold a whole long document (Metal caps at 16384px,
// mobile GPUs lower). We lay out the FULL document in doc space but only ever
// rasterize a viewport-sized window of it — see [GPUTextView].
const double _maxDevicePx = 8192;

/// Laid-out metrics reported after each reflow (see [GPUTextView.onMetrics]).
@immutable
class GPUTextMetrics {
  const GPUTextMetrics({
    required this.glyphCount,
    required this.lineCount,
    required this.size,
    required this.reflowMs,
  });

  /// Coverage glyphs emitted (includes expanded COLR-emoji layers).
  final int glyphCount;
  final int lineCount;

  /// The laid-out content size in logical px (width is the wrap width).
  final Size size;

  /// Wall-clock time of the worker round-trip for this reflow, in ms.
  final double reflowMs;
}

/// An immutable description of a document to lay out on the worker.
///
/// [id] is the cache key for the expensive shape+prepare phase: reuse the same
/// id across width reflows of the *same content*, and use a NEW id whenever the
/// content changes. Reusing an id for different [runs] is a bug — the worker
/// keeps serving the first prepare it saw for that id.
@immutable
class GPUTextDocument {
  const GPUTextDocument({
    required this.id,
    required this.runs,
    this.lineHeight = 1.3,
    this.fallbackFontIds = const [],
    this.emojiFontId,
    this.placeholderWidgets = const {},
    this.autoSizedPlaceholders = const {},
  });

  /// Build a document from a Flutter [InlineSpan] tree.
  ///
  /// [fontIdResolver] maps each leaf's resolved [TextStyle] to a font id you
  /// registered on the controller.
  ///
  /// For inline widgets, prefer a [GPUWidgetSpan] in the tree: it carries both
  /// its size and its child, so [GPUTextView] draws it automatically — no
  /// [placeholderSize] and no [GPUTextView.placeholderBuilder] needed. Give it
  /// an explicit `size` for the fast path, or omit the size and [GPUTextView]
  /// measures the child before layout (one frame slower; child must self-size).
  /// Plain WidgetSpans still work if you pass [placeholderSize] and render them
  /// yourself by index; without either they are dropped.
  factory GPUTextDocument.rich(
    String id,
    InlineSpan span, {
    required String Function(TextStyle style) fontIdResolver,
    TextStyle? baseStyle,
    double defaultFontSizePx = 16,
    List<double> defaultColor = const [0, 0, 0, 1],
    PlaceholderSizer? placeholderSize,
    double lineHeight = 1.3,
    List<String> fallbackFontIds = const [],
    String? emojiFontId,
  }) {
    final widgets = <int, Widget>{};
    final autoSized = <int>{};
    final runs = flattenInlineSpan(
      span,
      fontIdResolver: fontIdResolver,
      baseStyle: baseStyle,
      defaultFontSizePx: defaultFontSizePx,
      defaultColor: defaultColor,
      placeholderSize: placeholderSize,
      onWidget: (index, child, explicitSize) {
        widgets[index] = child;
        if (explicitSize == null) autoSized.add(index); // measure this one
      },
    );
    return GPUTextDocument(
      id: id,
      runs: runs,
      lineHeight: lineHeight,
      fallbackFontIds: fallbackFontIds,
      emojiFontId: emojiFontId,
      placeholderWidgets: widgets,
      autoSizedPlaceholders: autoSized,
    );
  }

  final String id;

  /// The flattened runs (+ size-only placeholders) to shape. Build these with
  /// [flattenInlineSpan] / [GPUTextDocument.rich], or hand-assemble
  /// [GPUTextRunSpec]/[GPUPlaceholderSpec] values.
  final List<GPUInlineSpec> runs;

  final double lineHeight;

  /// Ordered fallback font ids for scripts the runs' own fonts don't cover
  /// (CJK, Arabic, Hebrew, …); resolved per-rune by glyph coverage.
  final List<String> fallbackFontIds;

  /// Optional COLR color-emoji font id — emoji clusters render as coloured
  /// coverage layers when set.
  final String? emojiFontId;

  /// The real widget to draw for each placeholder, by its index. Populated
  /// automatically from [GPUWidgetSpan]s by [GPUTextDocument.rich]; you can also
  /// set it directly when hand-assembling runs. [GPUTextView] draws these over
  /// the GPU text, falling back to [GPUTextView.placeholderBuilder] for any
  /// index not present here. Main-isolate only — never sent to the worker.
  final Map<int, Widget> placeholderWidgets;

  /// Indices of placeholders whose size was left null (a sizeless
  /// [GPUWidgetSpan]): [GPUTextView] measures [placeholderWidgets] for these on
  /// the main isolate and substitutes the real size before laying out. Their
  /// [runs] entries hold a provisional zero box until then. Main-isolate only.
  final Set<int> autoSizedPlaceholders;
}

/// Owns the background layout isolate and the fonts registered on it.
///
/// Font bytes are parsed on the worker only — the main isolate never touches
/// them, so there is no per-view font cost. Create one (typically in
/// `initState`), register your fonts, share it across every [GPUTextView], and
/// [dispose] it when the owning widget goes away.
class GPUTextViewController {
  GPUTextViewController._(this._worker);

  final GPUTextWorker _worker;
  final Set<String> _prepared = {};
  final Map<String, Future<bool>> _preparing = {};
  bool _disposed = false;

  // A GPU render pipeline (compiled shaders) shared across every surface driven
  // by this controller — created once, lazily, on the main isolate. Sharing it
  // matters for [GPUTextBlocksView], which composites many block drawables into
  // one viewport surface and must NOT recompile the pipeline. Null when
  // flutter_gpu is unavailable.
  GPUTextPipeline? _pipeline;
  bool _pipelineTried = false;

  Future<GPUTextPipeline?> _sharedPipeline() async {
    if (_pipelineTried) return _pipeline;
    _pipelineTried = true;
    try {
      _pipeline = await GPUTextPipeline.create();
    } catch (_) {
      _pipeline = null; // flutter_gpu / Impeller unavailable
    }
    return _pipeline;
  }

  /// Spawn the worker isolate and return a ready controller.
  static Future<GPUTextViewController> spawn() async =>
      GPUTextViewController._(await GPUTextWorker.spawn());

  /// Register a font's [bytes] once under [id]; runs reference it by that id.
  /// The bytes are transferred to the worker (the caller's list is neutered) —
  /// pass a throwaway copy if you still need the originals.
  Future<void> registerFont(String id, Uint8List bytes) {
    _assertLive();
    return _worker.registerFont(id, bytes);
  }

  /// Prepare [runs] under [id] on the worker at most once (deduped by id, even
  /// across concurrent callers). The view passes the placeholder-resolved runs,
  /// so [id] must change whenever the resolved content does. Idempotent.
  /// Returns `true` when this call performed a fresh prepare (atlas may have
  /// grown), `false` when [id] was already warm or the controller is disposed.
  Future<bool> _ensurePrepared(
    String id,
    List<GPUInlineSpec> runs, {
    List<String> fallbackFontIds = const [],
    String? emojiFontId,
  }) {
    if (_disposed) return Future<bool>.value(false);
    if (_prepared.contains(id)) return Future<bool>.value(false);
    return _preparing.putIfAbsent(id, () async {
      if (_disposed) return false;
      await _worker.prepareDoc(
        id,
        runs,
        fallbackFontIds: fallbackFontIds,
        emojiFontId: emojiFontId,
      );
      if (_disposed) return false;
      _prepared.add(id);
      _preparing.remove(id);
      return true;
    });
  }

  /// Evict the document prepared under [id] from the worker, freeing its shaped
  /// paragraph. The shared glyph atlas is retained. Re-prepared on next use.
  /// Drives [GPUTextBlocksView]'s LRU eviction of far-off-screen blocks.
  /// No-op if the controller (and its worker) is already disposed.
  Future<void> _disposeDoc(String id) {
    if (_disposed) return Future<void>.value();
    _prepared.remove(id);
    _preparing.remove(id);
    return _worker.disposeDoc(id);
  }

  void _assertLive() {
    if (_disposed) throw StateError('GPUTextViewController is disposed');
  }

  /// Kill the worker isolate. Views using this controller must be gone first.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _worker.dispose();
  }
}

/// A scrollable, GPU-rendered rich-text view whose layout runs on a background
/// isolate (via [controller]). It fills the width it is given, wraps [document]
/// to that width off the UI isolate, and re-wraps off-thread on resize.
///
/// Long documents are virtualized: the whole document is laid out in doc space
/// (so layout cost is real) but only the visible window is ever rasterized, so
/// GPU memory is constant regardless of length. Vertical scrolling is built in.
///
/// GPU rendering needs Impeller + flutter_gpu; where they are unavailable the
/// view shows [fallbackBuilder] (or nothing).
class GPUTextView extends StatefulWidget {
  const GPUTextView({
    super.key,
    required this.controller,
    required this.document,
    this.padding = EdgeInsets.zero,
    this.background = const Color(0xFFFFFFFF),
    this.scrollController,
    this.physics,
    this.placeholderBuilder,
    this.fallbackBuilder,
    this.onMetrics,
  });

  /// The shared worker owner. Fonts referenced by [document] must be registered
  /// on it first.
  final GPUTextViewController controller;

  /// What to lay out. Swap in a new instance to change content; keep [document]
  /// otherwise identical (same `id`) across resizes to reuse the prepare cache.
  final GPUTextDocument document;

  /// Inset around the text. The wrap width is the view's width minus the
  /// horizontal padding.
  final EdgeInsets padding;

  /// Fill colour the glyphs are rasterized over (the coverage AA composites
  /// against it). Defaults to opaque white.
  final Color background;

  /// Optional external vertical scroll controller. If null, the view owns one.
  final ScrollController? scrollController;
  final ScrollPhysics? physics;

  /// Fallback builder for placeholders NOT bundled in
  /// [GPUTextDocument.placeholderWidgets] (i.e. plain WidgetSpans sized via a
  /// `placeholderSize` resolver, or hand-assembled [GPUPlaceholderSpec]s),
  /// looked up by index. Prefer a [GPUWidgetSpan], which bundles the widget so
  /// this isn't needed. The widget is positioned over the GPU text at the box
  /// the worker laid out (its size must match what you reserved); called only
  /// for placeholders in the visible window.
  final Widget Function(BuildContext context, int index)? placeholderBuilder;

  /// Shown when flutter_gpu / Impeller is unavailable so nothing can be drawn.
  final WidgetBuilder? fallbackBuilder;

  /// Invoked after every reflow with the fresh layout metrics.
  final void Function(GPUTextMetrics metrics)? onMetrics;

  @override
  State<GPUTextView> createState() => _GPUTextViewState();
}

class _GPUTextViewState extends State<GPUTextView> {
  _GpuTextSurface? _surface;
  bool _initDone = false;

  late ScrollController _scroll;
  final ValueNotifier<ui.Image?> _window = ValueNotifier<ui.Image?>(null);

  // Reflow driver (single-flight): at most one worker loop runs; a re-entrant
  // request while busy just raises [_pending] and the loop picks up the latest
  // width/document on its next turn.
  bool _busy = false;
  bool _pending = false;
  String? _atlasKeyOnGpu; // doc id whose atlas is currently uploaded

  // Live geometry, logical px.
  double _contentWidth = 0; // wrap width from the last layout pass
  double _viewportH = 0;
  double _dpr = 1;

  // The dimensions the currently-uploaded drawable / window image was rendered
  // for. The display is sized to THESE, not the live values above: on the async
  // worker path the live width/height jump the instant the view resizes but the
  // GPU image still holds the previous size, so fitting it to the live box
  // would stretch the stale frame until the reflow lands. See [_renderWidth].
  double _docWidth = 0;
  double _docHeight = 0;
  double _winH = 0;

  int _glyphCount = 0;
  List<PlaceholderBox> _placeholders = const [];

  // Auto-measure (prototype): for sizeless GPUWidgetSpans the child is measured
  // off-screen (one frame) before layout. [_resolvedRuns] is document.runs with
  // those placeholder boxes patched to the measured sizes; [_measuredDocId]
  // marks the doc id it's valid for; [_measureKeys] read each child's size.
  final Map<int, GlobalKey> _measureKeys = {};
  String? _measuredDocId;
  List<GPUInlineSpec>? _resolvedRuns;
  bool _measureScheduled = false;

  double get _renderWidth => _docWidth > 0 ? _docWidth : _contentWidth;

  bool get _needsMeasure =>
      widget.document.autoSizedPlaceholders.isNotEmpty &&
      _measuredDocId != widget.document.id;

  @override
  void initState() {
    super.initState();
    _scroll = widget.scrollController ?? ScrollController();
    _scroll.addListener(_renderWindow);
    _dpr = WidgetsBinding.instance.platformDispatcher.views.first
        .devicePixelRatio;
    _init();
  }

  Future<void> _init() async {
    final surface = await _GpuTextSurface.tryCreate();
    if (!mounted) {
      surface?.dispose();
      return;
    }
    setState(() {
      _surface = surface;
      _initDone = true;
    });
    // The width is discovered by the LayoutBuilder; if it already ran, reflow.
    if (surface != null && _contentWidth > 0) unawaited(_reflow());
  }

  @override
  void didUpdateWidget(GPUTextView old) {
    super.didUpdateWidget(old);
    if (widget.scrollController != old.scrollController) {
      old.scrollController?.removeListener(_renderWindow);
      _scroll.removeListener(_renderWindow);
      if (old.scrollController == null) _scroll.dispose();
      _scroll = widget.scrollController ?? ScrollController();
      _scroll.addListener(_renderWindow);
    }
    // A new document object (content or config change) needs a fresh reflow.
    // Same-id docs reuse the worker's prepare cache; a new id re-prepares — and
    // invalidates the measured placeholder sizes (they belong to the old id).
    if (!identical(widget.document, old.document)) {
      if (widget.document.id != old.document.id) {
        _measuredDocId = null;
        _resolvedRuns = null;
        _measureScheduled = false;
      }
      unawaited(_reflow());
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_renderWindow);
    if (widget.scrollController == null) _scroll.dispose();
    _surface?.dispose();
    _window.dispose();
    super.dispose();
  }

  void _requestReflow() {
    if (_surface == null) return; // fires once the surface is ready, in _init
    unawaited(_reflow());
  }

  // Re-reads [widget.document] and [_contentWidth] every iteration so a resize
  // OR a document swap mid-flight always converges on the latest state.
  Future<void> _reflow() async {
    if (_busy) {
      _pending = true;
      return;
    }
    final surface = _surface;
    if (surface == null) return;
    _busy = true;
    try {
      do {
        _pending = false;
        if (!mounted || widget.controller._disposed) return;
        final doc = widget.document;
        final w = _contentWidth;
        if (w <= 0) break;
        // Auto-measure gate: defer until the offstage measure pass (scheduled
        // in build) has sized this doc's placeholders; it re-triggers us.
        if (doc.autoSizedPlaceholders.isNotEmpty && _measuredDocId != doc.id) {
          break;
        }
        final runs = _resolvedRuns ?? doc.runs;
        await widget.controller._ensurePrepared(
          doc.id,
          runs,
          fallbackFontIds: doc.fallbackFontIds,
          emojiFontId: doc.emojiFontId,
        );
        if (!mounted || widget.controller._disposed) return;
        // The outline atlas is identical across a doc's reflows, so upload it
        // only when the doc (id) changed — otherwise ship just the instances.
        final needAtlas = _atlasKeyOnGpu != doc.id;
        final sw = Stopwatch()..start();
        final d = await widget.controller._worker.reflowDoc(
          doc.id,
          w,
          lineHeight: doc.lineHeight,
          includeAtlas: needAtlas,
        );
        sw.stop();
        if (!mounted || widget.controller._disposed) return;
        _applyDrawable(d, needAtlas, doc.id, sw.elapsedMicroseconds / 1000.0);
      } while (_pending && mounted && !widget.controller._disposed);
    } on StateError catch (e) {
      // Worker/controller torn down while we awaited (route pop). Swallow.
      if (!e.message.contains('disposed')) rethrow;
    } finally {
      _busy = false;
    }
  }

  void _applyDrawable(
    GPUTextInstances d,
    bool needAtlas,
    String atlasKey,
    double ms,
  ) {
    final surface = _surface;
    if (surface == null) return;
    if (needAtlas) {
      surface.setAtlas(d.materializeCurves(), d.materializeRows());
      _atlasKeyOnGpu = atlasKey;
    }
    surface.setInstances(d.materialize());
    _glyphCount = d.glyphCount;
    _docWidth = d.width;
    _docHeight = d.height;
    _placeholders = d.placeholders;
    if (_scroll.hasClients) {
      final max = (_docHeight - _viewportH).clamp(0.0, double.infinity);
      if (_scroll.offset > max) _scroll.jumpTo(max);
    }
    widget.onMetrics?.call(
      GPUTextMetrics(
        glyphCount: d.glyphCount,
        lineCount: d.lineCount,
        size: Size(d.width, d.height),
        reflowMs: ms,
      ),
    );
    setState(() {}); // extent + placeholder overlay
    _renderWindow();
  }

  /// Rasterize just the on-screen window from the uploaded drawable, panned by
  /// the scroll offset. One viewport-sized texture, reused on every scroll tick.
  void _renderWindow() {
    final surface = _surface;
    if (surface == null || _glyphCount == 0 || _viewportH <= 0) return;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    _winH = _viewportH; // the height this image is rasterized for; see build()
    _window.value = surface.renderAt(
      devW: (_renderWidth * _dpr).round().clamp(1, _maxDevicePx.round()),
      devH: (_viewportH * _dpr).round().clamp(1, _maxDevicePx.round()),
      dpr: _dpr,
      camY: -offset * _dpr,
      clear: _clearColor,
    );
  }

  vm.Vector4 get _clearColor {
    final c = widget.background;
    return vm.Vector4(c.r, c.g, c.b, c.a);
  }

  // --- auto-measure (prototype) ---

  GlobalKey _measureKeyFor(int index) =>
      _measureKeys.putIfAbsent(index, GlobalKey.new);

  // An offstage layer that lays out each sizeless placeholder's child so we can
  // read its natural size. Offstage lays the child out (reads its size) but
  // reports zero size and never paints; Align(widthFactor/heightFactor: 1)
  // shrink-wraps to the child under loose constraints.
  Widget _measureLayer(GPUTextDocument doc) {
    return Offstage(
      child: Stack(
        children: [
          for (final i in doc.autoSizedPlaceholders)
            if (doc.placeholderWidgets[i] case final child?)
              Align(
                key: _measureKeyFor(i),
                widthFactor: 1,
                heightFactor: 1,
                child: child,
              ),
        ],
      ),
    );
  }

  void _readMeasures(GPUTextDocument doc) {
    _measureScheduled = false;
    if (!mounted || doc.id != widget.document.id) return;
    final sizes = <int, Size>{};
    for (final i in doc.autoSizedPlaceholders) {
      sizes[i] = _measureKeys[i]?.currentContext?.size ?? Size.zero;
    }
    _measuredDocId = doc.id;
    _resolvedRuns = _resolvePlaceholderSizes(doc.runs, sizes);
    setState(() {}); // drop the offstage measure layer
    _requestReflow();
  }

  // document.runs with each measured placeholder's provisional box replaced by
  // its real size (and baseline recomputed for baseline-aligned ones).
  List<GPUInlineSpec> _resolvePlaceholderSizes(
    List<GPUInlineSpec> runs,
    Map<int, Size> sizes,
  ) {
    return [
      for (final spec in runs)
        if (spec is GPUPlaceholderSpec && sizes.containsKey(spec.index))
          GPUPlaceholderSpec(
            index: spec.index,
            width: sizes[spec.index]!.width,
            height: sizes[spec.index]!.height,
            alignment: spec.alignment,
            baselineOffset:
                spec.alignment == InlinePlaceholderAlignment.baseline
                ? sizes[spec.index]!.height
                : spec.baselineOffset,
          )
        else
          spec,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_initDone && _surface == null) {
      return widget.fallbackBuilder?.call(context) ?? const SizedBox.shrink();
    }
    return ColoredBox(
      color: widget.background,
      child: Padding(
        padding: widget.padding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final vh = constraints.maxHeight;
            // Reading DPR here subscribes us to it, so a monitor/DPR change
            // rebuilds and re-renders at the new scale.
            final dpr = MediaQuery.devicePixelRatioOf(context);
            if (w != _contentWidth || vh != _viewportH || dpr != _dpr) {
              _contentWidth = w;
              _viewportH = vh;
              _dpr = dpr;
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => mounted ? _requestReflow() : null,
              );
            }
            // Auto-measure: while a doc has unmeasured placeholders, keep the
            // offstage measure layer mounted and read the sizes next frame. The
            // reflow gate holds until that lands.
            final doc = widget.document;
            if (_needsMeasure && !_measureScheduled) {
              _measureScheduled = true;
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => mounted ? _readMeasures(doc) : null,
              );
            }
            final extent = _docHeight <= 0 ? vh : _docHeight;
            // Expand to the incoming viewport (see GPUTextBlocksView).
            // Scrollbar wraps the Stack so its thumb paints ABOVE the GPU image.
            return SizedBox.expand(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  scrollbars: false,
                ),
                child: RawScrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_needsMeasure) _measureLayer(doc),
                      // Invisible full-height scrollable: supplies the scroll
                      // gesture and scrollbar extent without materializing pixels.
                      SingleChildScrollView(
                        controller: _scroll,
                        physics: widget.physics,
                        child: SizedBox(width: double.infinity, height: extent),
                      ),
                      // The visible window, re-rendered from the cached drawable on
                      // scroll. IgnorePointer so the gesture reaches the scrollable.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Align(
                            // Not a tight box: the image takes its own rendered size
                            // (_renderWidth × _winH), so BoxFit.fill is an identity —
                            // a just-resized frame is shown at the size it was
                            // actually rasterized for, never stretched.
                            alignment: Alignment.topLeft,
                            child: ValueListenableBuilder<ui.Image?>(
                              valueListenable: _window,
                              builder: (context, img, _) => img == null
                                  ? const SizedBox.shrink()
                                  : RawImage(
                                      image: img,
                                      width: _renderWidth,
                                      height: _winH > 0 ? _winH : vh,
                                      fit: BoxFit.fill,
                                    ),
                            ),
                          ),
                        ),
                      ),
                      if (_placeholders.isNotEmpty && _hasPlaceholderWidgets)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: ClipRect(
                              child: AnimatedBuilder(
                                animation: _scroll,
                                builder: (context, _) =>
                                    _placeholderOverlay(vh),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  bool get _hasPlaceholderWidgets =>
      widget.placeholderBuilder != null ||
      widget.document.placeholderWidgets.isNotEmpty;

  // The widget for a placeholder box: a GPUWidgetSpan's bundled child wins;
  // otherwise fall back to the index-based builder. Null → nothing to draw.
  Widget? _placeholderWidget(int index) =>
      widget.document.placeholderWidgets[index] ??
      widget.placeholderBuilder?.call(context, index);

  Widget _placeholderOverlay(double vh) {
    final off = _scroll.hasClients ? _scroll.offset : 0.0;
    return Stack(
      children: [
        for (final box in _placeholders)
          if (box.index >= 0 &&
              box.top + box.height >= off &&
              box.top <= off + vh) // cull to the visible window
            if (_placeholderWidget(box.index) case final child?)
              Positioned(
                left: box.left,
                top: box.top - off,
                width: box.width,
                height: box.height,
                child: child,
              ),
      ],
    );
  }
}

/// Minimal offscreen renderer: uploads a drawable (outline atlas + instance
/// buffer) once and blits a viewport-sized [ui.Image] window on demand.
class _GpuTextSurface {
  _GpuTextSurface(this._pipeline);

  final GPUTextPipeline _pipeline;
  gpu.GpuImageSurface? _surface;
  ui.Image? _image;
  gpu.DeviceBuffer? _instanceBuffer;
  AtlasTextures? _textures;
  int _count = 0;
  final List<(gpu.GpuImageSurface?, ui.Image, int)> _retired = [];
  bool _hooked = false;

  static Future<_GpuTextSurface?> tryCreate() async {
    try {
      return _GpuTextSurface(await GPUTextPipeline.create());
    } catch (_) {
      return null; // flutter_gpu / Impeller unavailable
    }
  }

  /// Upload the outline atlas. Stable per document — call once per doc, not per
  /// reflow.
  void setAtlas(Float32List curves, Uint32List rows) {
    _textures = uploadAtlasTextures(gpu.gpuContext, curves, rows);
  }

  /// Upload the per-reflow instance buffer (glyph positions/colours).
  void setInstances(Float32List instances) {
    _count = instances.length ~/ floatsPerInstance;
    _instanceBuffer = _count == 0 ? null : _pipeline.uploadInstances(instances);
  }

  /// Rasterize the [devW]×[devH] window of the uploaded drawable, panned by
  /// [camY] device px.
  ui.Image? renderAt({
    required int devW,
    required int devH,
    required double dpr,
    required vm.Vector4 clear,
    double camY = 0,
  }) {
    final instanceBuffer = _instanceBuffer;
    final textures = _textures;
    if (instanceBuffer == null || textures == null || _count == 0) {
      return _image;
    }
    return renderComposite(
      devW: devW,
      devH: devH,
      dpr: dpr,
      clear: clear,
      draws: [
        (
          textures: textures,
          instances: instanceBuffer,
          count: _count,
          camY: camY,
        ),
      ],
    );
  }

  /// One viewport-sized pass: clear once, then [draws.length] instance draws
  /// (each with its own atlas + [camY]). Used by [GPUTextBlocksView] to
  /// composite N lazy blocks into a single [ui.Image].
  ui.Image? renderComposite({
    required int devW,
    required int devH,
    required double dpr,
    required vm.Vector4 clear,
    required List<
        ({
          AtlasTextures textures,
          gpu.DeviceBuffer instances,
          int count,
          double camY,
        })> draws,
  }) {
    if (devW <= 0 || devH <= 0) return _image;

    var surface = _surface;
    if (surface == null || surface.width != devW || surface.height != devH) {
      surface = gpu.gpuContext.createImageSurface(
        devW.clamp(1, _maxDevicePx.round()),
        devH.clamp(1, _maxDevicePx.round()),
        format: _surfaceFormat(gpu.gpuContext),
      );
    }

    final frame = surface.acquireNextFrame();
    final cmd = gpu.gpuContext.createCommandBuffer();
    final target = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: frame.colorTexture,
        loadAction: gpu.LoadAction.clear,
        storeAction: gpu.StoreAction.store,
        clearValue: clear,
      ),
    );
    final pass = cmd.createRenderPass(target);
    for (final d in draws) {
      if (d.count == 0) continue;
      _pipeline.renderInstances(
        pass: pass,
        frame: FrameUniforms(
          width: devW.toDouble(),
          height: devH.toDouble(),
          cam: [dpr, dpr, 0, d.camY],
        ),
        instances: d.instances,
        instanceCount: d.count,
        textures: d.textures,
      );
    }
    frame.present(cmd);
    cmd.submit();

    final prev = _image;
    if (prev != null) {
      _retired.add((
        identical(_surface, surface) ? null : _surface,
        prev,
        ui.PlatformDispatcher.instance.frameData.frameNumber,
      ));
      if (!_hooked) {
        _hooked = true;
        SchedulerBinding.instance.addTimingsCallback(_flushRetired);
      }
    }
    _surface = surface;
    _image = surface.currentImage;
    return _image;
  }

  void _flushRetired(List<ui.FrameTiming> timings) {
    var latest = -1;
    for (final t in timings) {
      if (t.frameNumber > latest) latest = t.frameNumber;
    }
    while (_retired.isNotEmpty && _retired.first.$3 <= latest) {
      _retired.removeAt(0).$2.dispose();
    }
    if (_retired.isEmpty && _hooked) {
      _hooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_flushRetired);
    }
  }

  void dispose() {
    if (_hooked) {
      _hooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_flushRetired);
    }
    for (final (_, img, _) in _retired) {
      img.dispose();
    }
    _retired.clear();
    _image?.dispose();
    _image = null;
    _surface = null;
  }
}

gpu.PixelFormat _surfaceFormat(gpu.GpuContext context) {
  final preferred = context.defaultColorFormat;
  if (preferred != gpu.PixelFormat.unknown &&
      context.supportsTextureFormat(preferred, renderTarget: true)) {
    return preferred;
  }
  return gpu.PixelFormat.b8g8r8a8UNormInt;
}

/// Estimate a block's height before it is laid out, from its text length and
/// the wrap width — used for the scroll extent until the real height lands.
typedef GPUBlockHeightEstimator =
    double Function(GPUTextDocument block, double width);

/// One block's uploaded instance buffer, ready to composite against the view's
/// shared atlas textures.
class _BlockDrawable {
  _BlockDrawable({
    required this.instances,
    required this.count,
    required this.height,
    required this.placeholders,
  });

  final gpu.DeviceBuffer? instances;
  final int count;
  final double height;
  final List<PlaceholderBox> placeholders;
}

/// A vertically-scrolling document rendered as INDEPENDENT paragraph blocks,
/// each shaped + laid out on the worker only when it scrolls within
/// [cacheExtent] of the viewport — then composited into **one** viewport-sized
/// GPU surface (one clear + N [GPUTextPipeline.renderInstances] draws, each
/// translated by its block Y via [camY]).
///
/// Each block is a [GPUTextDocument] (one paragraph) with its own unique id.
/// Paragraphs are independent layout units, so splitting is exact.
///
/// Memory policy:
/// - **Shared atlas** — every prepared block bands into one worker atlas
///   (append-only) and one GPU texture pair; common glyphs are stored once.
/// - **LRU prepared docs** — leaving the cache window drops GPU instance
///   buffers immediately, but the worker keeps shaped paragraphs up to
///   [maxPreparedDocs] so scrolling back does not re-shape. Oldest unpinned
///   docs are disposed when the cap is exceeded.
/// - **Viewport surface + camY** — tall blocks are not clamped to a texture
///   height; only the viewport is rasterized.
///
/// Measured heights are cached, so revisiting a block does not re-estimate or
/// jump the scroll.
///
/// GPU rendering needs Impeller + flutter_gpu; without them [fallbackBuilder]
/// (or nothing) is shown.
class GPUTextBlocksView extends StatefulWidget {
  const GPUTextBlocksView({
    super.key,
    required this.controller,
    required this.blocks,
    this.padding = EdgeInsets.zero,
    this.blockSpacing = 0,
    this.background = const Color(0xFFFFFFFF),
    this.scrollController,
    this.physics,
    this.cacheExtent = 600,
    this.maxPreparedDocs = 64,
    this.estimateHeight,
    this.placeholderBuilder,
    this.fallbackBuilder,
    this.onLaidOutChanged,
  });

  /// Shared worker owner; fonts referenced by [blocks] must be registered on it.
  final GPUTextViewController controller;

  /// The document, one [GPUTextDocument] per paragraph. Each needs a distinct
  /// `id` (its worker cache key).
  final List<GPUTextDocument> blocks;

  final EdgeInsets padding;

  /// Vertical gap between blocks, logical px.
  final double blockSpacing;

  final Color background;
  final ScrollController? scrollController;
  final ScrollPhysics? physics;

  /// How far beyond the viewport (logical px) to keep blocks' GPU instance
  /// buffers. Larger = smoother scrolling, more GPU memory.
  final double cacheExtent;

  /// Cap on simultaneously prepared (shaped) worker docs. Docs outside the
  /// cache window stay warm until this LRU fills, then the oldest unpinned
  /// ones are disposed. Higher = less re-shape churn when scrolling back.
  final int maxPreparedDocs;

  /// Provisional height for a not-yet-laid-out block. Defaults to a crude
  /// chars/line×lineHeight estimate.
  final GPUBlockHeightEstimator? estimateHeight;

  /// Fallback widget for a placeholder not bundled in a block's
  /// [GPUTextDocument.placeholderWidgets] (looked up by index).
  final Widget Function(BuildContext context, int index)? placeholderBuilder;

  /// Shown when flutter_gpu / Impeller is unavailable.
  final WidgetBuilder? fallbackBuilder;

  /// Reports (blocksLaidOut, totalBlocks) as blocks lay out — for a HUD.
  final void Function(int laidOut, int total)? onLaidOutChanged;

  @override
  State<GPUTextBlocksView> createState() => _GPUTextBlocksViewState();
}

class _GPUTextBlocksViewState extends State<GPUTextBlocksView> {
  late ScrollController _scroll;
  _GpuTextSurface? _surface;
  final ValueNotifier<ui.Image?> _window = ValueNotifier<ui.Image?>(null);

  double _contentWidth = 0;
  double _viewportH = 0;
  double _winH = 0;
  double _dpr = 1;
  double _renderWidth = 0;

  // Per-width height cache (survives eviction). Keyed by block id.
  final Map<String, double> _heights = {};
  // GPU instance buffers for blocks in the cache window.
  final Map<String, _BlockDrawable> _live = {};
  // LRU of worker-prepared ids (insertion order = oldest first). Touched on
  // prepare/reflow; trimmed to [maxPreparedDocs] keeping the cache window pinned.
  final LinkedHashMap<String, Null> _preparedLru = LinkedHashMap();
  // Shared GPU atlas for every live block (mirrors worker shared atlas).
  AtlasTextures? _atlasTextures;
  int _atlasGenOnGpu = -1;
  bool _atlasDirty = true; // true after a fresh prepare that may have grown it

  // Prefix tops for the current height vector (logical px, content coords).
  List<double> _tops = const [];
  double _totalHeight = 0;
  int _laidOut = 0;

  bool _busy = false;
  bool _pending = false;
  int _gen = 0; // bumps on width/dpr/blocks reset so in-flight work abandons

  // Fling/drag in progress: skip jumpTo + setState (they cancel ballistic
  // scroll). Sync still fills GPU buffers; UI/extent refresh waits for idle.
  bool _pendingIdleSync = false;
  bool _pendingIdleSetState = false;
  bool _pendingLaidOutNotify = false;
  bool _idleListenerAttached = false;
  VoidCallback? _idleListener;

  @override
  void initState() {
    super.initState();
    _scroll = widget.scrollController ?? ScrollController();
    _scroll.addListener(_onScroll);
    _dpr = WidgetsBinding.instance.platformDispatcher.views.first
        .devicePixelRatio;
    _initSurface();
  }

  Future<void> _initSurface() async {
    final pipeline = await widget.controller._sharedPipeline();
    if (!mounted) return;
    if (pipeline == null) {
      setState(() {}); // show fallback
      return;
    }
    _surface = _GpuTextSurface(pipeline);
    setState(() {});
    _requestSync();
  }

  @override
  void didUpdateWidget(GPUTextBlocksView old) {
    super.didUpdateWidget(old);
    if (!identical(old.blocks, widget.blocks)) {
      _resetCaches();
      _requestSync();
    }
  }

  @override
  void dispose() {
    // Abandon in-flight sync; do NOT fire per-doc disposeDoc here — the parent
    // typically disposes the controller (killing the worker) right after this
    // child dispose, and unawaited disposeDocs would race it with
    // "GPUTextWorker disposed". Isolate teardown frees every prepared doc.
    _gen++;
    _detachIdleListener();
    _scroll.removeListener(_onScroll);
    if (widget.scrollController == null) _scroll.dispose();
    _preparedLru.clear();
    _live.clear();
    _atlasTextures = null;
    _surface?.dispose();
    _window.dispose();
    super.dispose();
  }

  bool get _isActivelyScrolling {
    if (!_scroll.hasClients) return false;
    return _scroll.position.isScrollingNotifier.value;
  }

  void _attachIdleListener() {
    if (_idleListenerAttached || !_scroll.hasClients) return;
    _idleListener = () {
      if (!mounted) return;
      if (_scroll.position.isScrollingNotifier.value) return;
      // Fling/drag settled — apply deferred sync + extent rebuild.
      if (_pendingLaidOutNotify) {
        _pendingLaidOutNotify = false;
        widget.onLaidOutChanged?.call(_laidOut, widget.blocks.length);
      }
      if (_pendingIdleSync) {
        _pendingIdleSync = false;
        _requestSync();
      }
      if (_pendingIdleSetState) {
        _pendingIdleSetState = false;
        setState(() {});
      }
    };
    _scroll.position.isScrollingNotifier.addListener(_idleListener!);
    _idleListenerAttached = true;
  }

  void _detachIdleListener() {
    if (!_idleListenerAttached || _idleListener == null) return;
    if (_scroll.hasClients) {
      _scroll.position.isScrollingNotifier.removeListener(_idleListener!);
    }
    _idleListener = null;
    _idleListenerAttached = false;
  }

  void _onScroll() {
    _attachIdleListener();
    _renderWindow(); // cheap: reposition already-live drawables
    // Don't kick a full sync on every ballistic tick — layout completion
    // used to jumpTo/setState and kill the fling. Prefetch once settled, and
    // opportunistically while scrolling only if we aren't already busy.
    if (_isActivelyScrolling) {
      _pendingIdleSync = true;
      if (!_busy) _requestSync();
      return;
    }
    _requestSync();
  }

  void _resetCaches() {
    _gen++;
    for (final id in _preparedLru.keys) {
      unawaited(widget.controller._disposeDoc(id));
    }
    _preparedLru.clear();
    _live.clear();
    _heights.clear();
    _laidOut = 0;
    _tops = const [];
    _totalHeight = 0;
    _atlasTextures = null;
    _atlasGenOnGpu = -1;
    _atlasDirty = true;
  }

  /// Width/DPR changed: drop GPU instance buffers + heights (they're per-width)
  /// but KEEP worker prepares — shaping is width-independent, so a resize only
  /// needs reflow+emit for the cache window (not a re-shape).
  void _invalidateForWidth() {
    _gen++;
    _live.clear();
    _heights.clear();
    _laidOut = 0;
    _tops = const [];
    _totalHeight = 0;
    // Atlas glyphs are unchanged by wrap width; keep the uploaded textures.
  }

  void _touchPrepared(String id) {
    _preparedLru.remove(id);
    _preparedLru[id] = null;
  }

  /// Drop oldest prepared docs until under [maxPreparedDocs], never disposing
  /// [pin] (the current cache window).
  Future<void> _trimPrepared(Set<String> pin) async {
    final max = widget.maxPreparedDocs;
    if (max <= 0) return;
    while (_preparedLru.length > max) {
      String? victim;
      for (final id in _preparedLru.keys) {
        if (!pin.contains(id)) {
          victim = id;
          break;
        }
      }
      if (victim == null) break; // everything left is pinned
      _preparedLru.remove(victim);
      _live.remove(victim);
      await widget.controller._disposeDoc(victim);
    }
  }

  double _estimate(GPUTextDocument block, double width) {
    if (widget.estimateHeight != null) {
      return widget.estimateHeight!(block, width);
    }
    var chars = 0;
    var fontSize = 16.0;
    for (final s in block.runs) {
      if (s is GPUTextRunSpec) {
        chars += s.text.length;
        fontSize = s.fontSizePx;
      }
    }
    final perLine = (width / (fontSize * 0.5)).clamp(1.0, 1e9);
    final lines = (chars / perLine).ceil().clamp(1, 1 << 30);
    return lines * fontSize * block.lineHeight;
  }

  double _heightOf(int i, double width) {
    final block = widget.blocks[i];
    return _heights[block.id] ??
        _live[block.id]?.height ??
        _estimate(block, width);
  }

  /// Recompute prefix tops + total from current heights/estimates.
  void _recomputeTops(double width) {
    final n = widget.blocks.length;
    final tops = List<double>.filled(n, 0);
    var y = 0.0;
    for (var i = 0; i < n; i++) {
      tops[i] = y;
      y += _heightOf(i, width);
      if (i < n - 1) y += widget.blockSpacing;
    }
    _tops = tops;
    _totalHeight = y;
  }

  /// Indices whose [top, top+height] intersects [lo, hi].
  List<int> _indicesInRange(double lo, double hi, double width) {
    final n = widget.blocks.length;
    if (n == 0 || _tops.length != n) return const [];
    // Binary search first block that could intersect [lo, hi].
    var loIdx = 0;
    var hiIdx = n;
    while (loIdx < hiIdx) {
      final mid = (loIdx + hiIdx) >> 1;
      final bottom = _tops[mid] + _heightOf(mid, width);
      if (bottom < lo) {
        loIdx = mid + 1;
      } else {
        hiIdx = mid;
      }
    }
    final out = <int>[];
    for (var i = loIdx; i < n; i++) {
      final top = _tops[i];
      if (top > hi) break;
      out.add(i);
    }
    return out;
  }

  static const double _scrollbarGutter = 14;

  void _requestSync() {
    if (_surface == null || _contentWidth <= 0 || _viewportH <= 0) return;
    unawaited(_syncWindow());
  }

  Future<void> _syncWindow() async {
    if (_busy) {
      _pending = true;
      return;
    }
    _busy = true;
    final gen = _gen;
    try {
      do {
        _pending = false;
        if (!mounted || gen != _gen || widget.controller._disposed) return;
        final width = _contentWidth;
        final surface = _surface;
        if (surface == null || width <= 0) return;

        _recomputeTops(width);
        final offset = _scroll.hasClients ? _scroll.offset : 0.0;
        final cache = widget.cacheExtent;
        final wantIdx = _indicesInRange(
          offset - cache,
          offset + _viewportH + cache,
          width,
        );
        final want = wantIdx.map((i) => widget.blocks[i].id).toSet();

        // Drop GPU instance buffers that left the window — worker state stays
        // warm under the LRU until [maxPreparedDocs] forces a dispose.
        _live.removeWhere((id, _) => !want.contains(id));

        // Lay out any wanted block that is not yet live on the GPU.
        var newlyLaidOut = false;
        for (final i in wantIdx) {
          if (!mounted || gen != _gen || widget.controller._disposed) return;
          final doc = widget.blocks[i];
          if (_live.containsKey(doc.id)) {
            _touchPrepared(doc.id);
            continue;
          }

          final fresh = await widget.controller._ensurePrepared(
            doc.id,
            doc.runs,
            fallbackFontIds: doc.fallbackFontIds,
            emojiFontId: doc.emojiFontId,
          );
          if (!mounted || gen != _gen || widget.controller._disposed) return;
          if (fresh) _atlasDirty = true;
          _touchPrepared(doc.id);

          final needAtlas =
              _atlasDirty || _atlasTextures == null || _atlasGenOnGpu < 0;
          final d = await widget.controller._worker.reflowDoc(
            doc.id,
            width,
            lineHeight: doc.lineHeight,
            includeAtlas: needAtlas,
          );
          if (!mounted || gen != _gen || widget.controller._disposed) return;

          if (needAtlas) {
            final curves = d.materializeCurves();
            final rows = d.materializeRows();
            if (curves.isNotEmpty) {
              _atlasTextures =
                  uploadAtlasTextures(gpu.gpuContext, curves, rows);
              _atlasGenOnGpu = d.atlasGeneration;
              _atlasDirty = false;
            }
          } else if (d.atlasGeneration > _atlasGenOnGpu) {
            // Atlas grew (another prepare) but we skipped the payload — fetch
            // once more with includeAtlas. Rare: only if two prepares raced.
            _atlasDirty = true;
          }

          final instances = d.materialize();
          final count = instances.length ~/ floatsPerInstance;
          final pipeline = widget.controller._pipeline;
          if (pipeline == null) return;
          final oldH = _heightOf(i, width);
          final newH = d.height;
          final scrolling = _isActivelyScrolling;

          // Scroll-anchor ONLY when idle. jumpTo mid-fling cancels ballistic
          // scroll and feels like the fling "stops."
          if (!scrolling &&
              oldH != newH &&
              _scroll.hasClients &&
              _tops.isNotEmpty &&
              i < _tops.length) {
            final top = _tops[i];
            if (top + oldH <= _scroll.offset) {
              final delta = newH - oldH;
              final next = (_scroll.offset + delta).clamp(
                0.0,
                double.infinity,
              );
              _scroll.jumpTo(next);
            }
          }

          final firstTime = !_heights.containsKey(doc.id);
          _heights[doc.id] = newH;
          if (firstTime) {
            _laidOut++;
            newlyLaidOut = true;
          }

          _live[doc.id] = _BlockDrawable(
            instances: count == 0
                ? null
                : pipeline.uploadInstances(instances),
            count: count,
            height: newH,
            placeholders: d.placeholders,
          );

          // Height change shifts later tops — recompute before next block.
          _recomputeTops(width);
        }

        // If atlas grew without a payload, one block still needs a fetch.
        if (_atlasDirty && wantIdx.isNotEmpty && mounted && gen == _gen) {
          final doc = widget.blocks[wantIdx.first];
          final d = await widget.controller._worker.reflowDoc(
            doc.id,
            width,
            lineHeight: doc.lineHeight,
            includeAtlas: true,
          );
          if (mounted && gen == _gen && !widget.controller._disposed) {
            final curves = d.materializeCurves();
            final rows = d.materializeRows();
            if (curves.isNotEmpty) {
              _atlasTextures =
                  uploadAtlasTextures(gpu.gpuContext, curves, rows);
              _atlasGenOnGpu = d.atlasGeneration;
              _atlasDirty = false;
            }
          }
        }

        await _trimPrepared(want);
        if (!mounted || gen != _gen || widget.controller._disposed) return;

        final scrolling = _isActivelyScrolling;

        if (newlyLaidOut && !scrolling) {
          widget.onLaidOutChanged?.call(_laidOut, widget.blocks.length);
        } else if (newlyLaidOut) {
          _pendingLaidOutNotify = true;
        }

        // Clamp scroll only when idle — jumpTo ends a fling.
        if (!scrolling && _scroll.hasClients) {
          final max =
              (_totalHeight - _viewportH).clamp(0.0, double.infinity);
          if (_scroll.offset > max) _scroll.jumpTo(max);
        }

        // setState rebuilds scroll extent; doing that mid-fling also kills
        // ballistic motion. Defer to idle; still blit with current drawables.
        if (scrolling) {
          _pendingIdleSetState = true;
        } else if (mounted) {
          setState(() {});
        }
        _renderWindow();
      } while (_pending &&
          mounted &&
          gen == _gen &&
          !widget.controller._disposed);
    } on StateError catch (e) {
      // Worker/controller torn down while we awaited (route pop). Swallow.
      if (!e.message.contains('disposed')) rethrow;
    } finally {
      _busy = false;
    }
  }

  void _renderWindow() {
    final surface = _surface;
    final textures = _atlasTextures;
    if (surface == null ||
        textures == null ||
        _viewportH <= 0 ||
        _contentWidth <= 0) {
      return;
    }
    if (_tops.isEmpty && widget.blocks.isNotEmpty) {
      _recomputeTops(_contentWidth);
    }

    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final width = _contentWidth;
    final dpr = _dpr;
    final c = widget.background;

    // Visible blocks only (tighter than the layout cache window).
    final visible = _indicesInRange(offset, offset + _viewportH, width);
    final draws = <
        ({
          AtlasTextures textures,
          gpu.DeviceBuffer instances,
          int count,
          double camY,
        })>[];
    for (final i in visible) {
      final doc = widget.blocks[i];
      final drawable = _live[doc.id];
      final buf = drawable?.instances;
      if (drawable == null || buf == null || drawable.count == 0) continue;
      final top = _tops[i];
      // Block-local y=0 should land at screen y = top - offset.
      draws.add((
        textures: textures,
        instances: buf,
        count: drawable.count,
        camY: (top - offset) * dpr,
      ));
    }

    _winH = _viewportH;
    _renderWidth = width;
    _window.value = surface.renderComposite(
      devW: (width * dpr).round().clamp(1, _maxDevicePx.round()),
      devH: (_viewportH * dpr).round().clamp(1, _maxDevicePx.round()),
      dpr: dpr,
      clear: vm.Vector4(c.r, c.g, c.b, c.a),
      draws: draws,
    );
  }

  Widget? _placeholderWidget(GPUTextDocument doc, int index) =>
      doc.placeholderWidgets[index] ??
      widget.placeholderBuilder?.call(context, index);

  Widget _placeholderOverlay() {
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final children = <Widget>[];
    for (var i = 0; i < widget.blocks.length; i++) {
      final doc = widget.blocks[i];
      final drawable = _live[doc.id];
      if (drawable == null || drawable.placeholders.isEmpty) continue;
      if (i >= _tops.length) continue;
      final top = _tops[i];
      for (final box in drawable.placeholders) {
        final screenTop = top + box.top - offset;
        if (screenTop + box.height < 0 || screenTop > _viewportH) continue;
        final child = _placeholderWidget(doc, box.index);
        if (child == null) continue;
        children.add(
          Positioned(
            left: box.left,
            top: screenTop,
            width: box.width,
            height: box.height,
            child: child,
          ),
        );
      }
    }
    return Stack(children: children);
  }

  @override
  Widget build(BuildContext context) {
    // Pipeline probe finished with null → no GPU.
    if (_surface == null &&
        widget.controller._pipelineTried &&
        widget.controller._pipeline == null) {
      return widget.fallbackBuilder?.call(context) ?? const SizedBox.shrink();
    }

    return ColoredBox(
      color: widget.background,
      child: Padding(
        padding: widget.padding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Reserve a strip for the scrollbar thumb so it stays hittable
            // above the GPU image (IgnorePointer alone is not enough on some
            // desktop hit-test paths).
            final w = (constraints.maxWidth - _scrollbarGutter)
                .clamp(1.0, double.infinity);
            final vh = constraints.maxHeight;
            final dpr = MediaQuery.devicePixelRatioOf(context);
            if (w != _contentWidth || vh != _viewportH || dpr != _dpr) {
              final widthChanged = w != _contentWidth || dpr != _dpr;
              _contentWidth = w;
              _viewportH = vh;
              _dpr = dpr;
              if (widthChanged) {
                // Heights/instances are per-width; prepares stay (shape is
                // width-independent) so a resize is reflow-only for the window.
                _invalidateForWidth();
              }
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => mounted ? _requestSync() : null,
              );
            }
            // Keep scroll extent up to date even before the first sync lands —
            // otherwise extent == viewport and the scrollbar is a no-op.
            if (w > 0 &&
                widget.blocks.isNotEmpty &&
                _tops.length != widget.blocks.length) {
              _recomputeTops(w);
            }
            final extent = _totalHeight > 0 ? _totalHeight : vh;
            // Disable MaterialScrollBehavior's automatic desktop scrollbar —
            // we paint our own RawScrollbar above the GPU image (otherwise
            // you get two thumbs).
            return SizedBox.expand(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  scrollbars: false,
                ),
                child: RawScrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  interactive: true,
                  thickness: 8,
                  radius: const Radius.circular(4),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      SingleChildScrollView(
                        controller: _scroll,
                        physics: widget.physics ??
                            const AlwaysScrollableScrollPhysics(),
                        child: SizedBox(
                          width: double.infinity,
                          height: extent,
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        right: _scrollbarGutter,
                        child: IgnorePointer(
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: ValueListenableBuilder<ui.Image?>(
                              valueListenable: _window,
                              builder: (context, img, _) => img == null
                                  ? const SizedBox.shrink()
                                  : RawImage(
                                      image: img,
                                      width:
                                          _renderWidth > 0 ? _renderWidth : w,
                                      height: _winH > 0 ? _winH : vh,
                                      fit: BoxFit.fill,
                                    ),
                            ),
                          ),
                        ),
                      ),
                      if (_live.values.any((d) => d.placeholders.isNotEmpty))
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          right: _scrollbarGutter,
                          child: IgnorePointer(
                            child: ClipRect(
                              child: AnimatedBuilder(
                                animation: _scroll,
                                builder: (context, _) => _placeholderOverlay(),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
