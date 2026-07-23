// SliverGPUText — GPU text as a first-class sliver. Where GPUTextView's
// removed shrinkWrap mode reconstructed the visible window from ancestor
// ScrollPosition listeners + transform probing (and deferred work around
// flings), a sliver is HANDED that window by the viewport protocol every
// layout pass and paints in the same frame, so none of that machinery exists
// here.
//
// Inline widgets ([GPUWidgetSpan]) are hosted as real render children, laid
// out to their placeholder boxes and painted over the glyphs; sizeless spans
// are measured under loose constraints during the first layout pass and the
// document reflows once with the real sizes. Documents always wrap to the
// cross-axis extent. Vertical, forward-growth viewports only.
part of 'gpu_text_view.dart';

/// GPU-rendered rich text as a sliver for a [CustomScrollView].
///
/// Layout runs on the background worker exactly as in [GPUTextView] (same
/// [controller], same prepare/reflow cache); only the integration differs:
///
///  * the viewport hands the sliver its exact visible + cache window each
///    layout pass — no ancestor-scroll listeners or post-frame slice syncs;
///  * the GPU window image is rasterized during layout and painted the same
///    frame, so a fast fling can never outrun it;
///  * the true content height is [SliverGeometry.scrollExtent], so scrollbars
///    and viewport semantics just work.
///
/// GPU memory stays bounded by the viewport's cache region (clamped to the
/// device texture cap), not the document length.
///
/// Inline widgets from [GPUTextDocument.placeholderWidgets] (a
/// [GPUWidgetSpan]'s bundled child) are hosted as real render children: laid
/// out to the boxes the worker reserved, painted over the glyphs, and
/// hit-tested normally (buttons inside the text work). A sizeless
/// [GPUWidgetSpan] is measured under loose constraints during the first
/// layout and the document reflows once with the real size.
///
/// Text always wraps to the sliver's cross-axis extent.
///
/// V1 limitations — use [GPUTextView] where these matter:
///  * index-based `placeholderBuilder` fallbacks are not supported (bundle
///    the widget in a [GPUWidgetSpan] instead);
///  * vertical, [GrowthDirection.forward] viewports only.
///
/// Wrap in a [SliverPadding] for insets. Shown as nothing when flutter_gpu /
/// Impeller is unavailable.
class SliverGPUText extends MultiChildRenderObjectWidget {
  SliverGPUText({
    super.key,
    required this.controller,
    required this.document,
    this.background = const Color(0xFFFFFFFF),
    this.onMetrics,
    this.onSpanTap,
    this.selectionRegistrar,
    this.selectionColor,
  }) : super(children: _hostChildren(document));

  /// The placeholder widgets, one element child per index, in index order.
  static List<Widget> _hostChildren(GPUTextDocument document) {
    if (document.placeholderWidgets.isEmpty) return const [];
    final indexes = document.placeholderWidgets.keys.toList()..sort();
    return [
      for (final i in indexes)
        _SliverPlaceholder(
          key: ValueKey<int>(i),
          index: i,
          child: document.placeholderWidgets[i]!,
        ),
    ];
  }

  /// The shared worker owner. Fonts referenced by [document] must be
  /// registered on it first.
  final GPUTextViewController controller;

  /// What to lay out. Same contract as [GPUTextView.document]: a new id means
  /// new content; a rebuilt document with the same id and an equal
  /// [GPUTextDocument.effectiveStyle] is recognized and skips the reflow.
  final GPUTextDocument document;

  /// Fill painted behind the glyphs across the sliver's paint region (the
  /// coverage AA composites against it). Defaults to opaque white.
  final Color background;

  /// Invoked after every reflow with the fresh layout metrics.
  final void Function(GPUTextMetrics metrics)? onMetrics;

  /// Invoked when the user taps a run that carries a [GPUTextRunSpec.hitTag].
  /// Recognizer taps on spans mapped in [GPUTextDocument.hitTargets] are also
  /// dispatched.
  final void Function(String hitTag, TextSpan? span)? onSpanTap;

  /// Selection registrar. Like [GPURichText], a null registrar falls back to
  /// the enclosing [SelectionContainer], so a sliver inside a [SelectionArea]
  /// participates without extra plumbing. While a registrar is attached,
  /// reflows additionally ship selection geometry from the worker.
  final SelectionRegistrar? selectionRegistrar;

  /// Highlight color; defaults to [DefaultSelectionStyle.of] when selection
  /// is active.
  final Color? selectionColor;

  SelectionRegistrar? _effectiveRegistrar(BuildContext context) =>
      selectionRegistrar ?? SelectionContainer.maybeOf(context);

  Color? _effectiveSelectionColor(
    BuildContext context,
    SelectionRegistrar? registrar,
  ) => registrar == null
      ? selectionColor
      : selectionColor ??
            DefaultSelectionStyle.of(context).selectionColor ??
            DefaultSelectionStyle.defaultColor;

  @override
  RenderObject createRenderObject(BuildContext context) {
    final registrar = _effectiveRegistrar(context);
    return RenderSliverGPUText(
      controller: controller,
      document: document,
      background: background,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      onMetrics: onMetrics,
      onSpanTap: onSpanTap,
    )..configureSelection(
      registrar: registrar,
      color: _effectiveSelectionColor(context, registrar),
      direction: Directionality.maybeOf(context) ?? TextDirection.ltr,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverGPUText renderObject,
  ) {
    final registrar = _effectiveRegistrar(context);
    renderObject
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..background = background
      ..onMetrics = onMetrics
      ..onSpanTap = onSpanTap
      ..controller = controller
      ..document = document
      ..configureSelection(
        registrar: registrar,
        color: _effectiveSelectionColor(context, registrar),
        direction: Directionality.maybeOf(context) ?? TextDirection.ltr,
      );
  }
}

/// Positions one hosted placeholder widget: [index] pairs the element child
/// with its [PlaceholderBox] in the laid-out document.
class _SliverPlaceholder
    extends ParentDataWidget<_SliverPlaceholderParentData> {
  const _SliverPlaceholder({
    super.key,
    required this.index,
    required super.child,
  });

  final int index;

  @override
  void applyParentData(RenderObject renderObject) {
    final pd = renderObject.parentData! as _SliverPlaceholderParentData;
    if (pd.index == index) return;
    pd.index = index;
    final parent = renderObject.parent;
    if (parent is RenderObject) parent.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => SliverGPUText;
}

class _SliverPlaceholderParentData extends ContainerBoxParentData<RenderBox> {
  int index = -1;

  /// Whether [offset] holds a real doc-space box from the current drawable.
  /// False before the first reflow and during the auto-size measure pass —
  /// such children are laid out but neither painted nor hit-tested.
  bool hasBox = false;
}

/// The render sliver behind [SliverGPUText]. Public for `updateRenderObject`;
/// construct it through the widget.
class RenderSliverGPUText extends RenderSliver
    with
        ContainerRenderObjectMixin<RenderBox, _SliverPlaceholderParentData>,
        RenderSliverHelpers
    implements MouseTrackerAnnotation {
  RenderSliverGPUText({
    required this._controller,
    required this._document,
    required this._background,
    required double devicePixelRatio,
    this.onMetrics,
    this.onSpanTap,
  }) : _dpr = devicePixelRatio {
    _wireSelectionSource();
  }

  // --- configuration ---

  GPUTextViewController _controller;
  set controller(GPUTextViewController value) {
    if (identical(value, _controller)) return;
    _controller = value;
    _atlasGenOnGpu = -1; // the new worker's atlas is a different texture
    _requestReflow();
  }

  GPUTextDocument _document;
  set document(GPUTextDocument value) {
    final old = _document;
    if (identical(old, value)) return;
    _document = value;
    _wireSelectionSource();
    if (value.id != old.id) {
      // Measured placeholder sizes belong to the old content.
      _measuredDocId = null;
      _resolvedRuns = null;
      _preparedRuns = null;
      _measuredSizes = const {};
      markNeedsLayout(); // the measure pass runs during layout
    }
    // Same id ⇒ same content by the [GPUTextDocument.id] contract, so an
    // equal layout style means the reflow would be byte-identical — skip the
    // worker round-trip (parents rebuild equivalent documents routinely).
    if (value.id == old.id && value.effectiveStyle == old.effectiveStyle) {
      return;
    }
    _requestReflow();
  }

  Color _background;
  set background(Color value) {
    if (value == _background) return;
    _background = value;
    markNeedsPaint();
  }

  double _dpr;
  set devicePixelRatio(double value) {
    if (value == _dpr) return;
    _dpr = value;
    _drawableGen++; // the cached window was rasterized at the old scale
    _requestReflow();
  }

  void Function(GPUTextMetrics metrics)? onMetrics;
  void Function(String hitTag, TextSpan? span)? onSpanTap;

  // --- selection ---

  // Fragment coordinates stay doc-local; the sliver's scroll offset lives in
  // the bindHost shift, so scrolling never touches fragment values.
  final _DocSelection _selection = _DocSelection();
  // Settle refresh for the selection line table after table-less resize
  // streaming (see _reflow's wantTable): set by the selection's stale hook
  // on the first quiet frame, cleared when the table lands.
  bool _tableRefreshDue = false;

  /// Banded selection: source text derived from the specs on this isolate,
  /// per-line detail fetched from the worker for the painted band.
  void _wireSelectionSource() {
    final source = flattenSpecSource(_document.runs);
    _selection.setSource(source.text, source.placeholderOffsets);
    _selection.setBandFetcher(
      (generation, first, last) =>
          _controller._fetchLineBand(_document.id, generation, first, last),
    );
    _selection.setReflowHooks(
      quiet: () => _reflowEpoch == _appliedReflowEpoch,
      onTableStale: () {
        if (_disposed || _controller._disposed || _tableRefreshDue) return;
        _tableRefreshDue = true;
        _requestReflow();
      },
    );
  }

  /// Wired by the widget's create/updateRenderObject (registrar resolved from
  /// SelectionContainer.maybeOf there — reads register the dependency).
  void configureSelection({
    required SelectionRegistrar? registrar,
    required Color? color,
    required TextDirection direction,
  }) {
    _selection.configure(
      registrar: registrar,
      color: color,
      direction: direction,
      onEnabledChanged: _onSelectionEnabledChanged,
    );
  }

  /// Registrar appeared: the drawable on screen shipped without geometry —
  /// fetch one.
  void _onSelectionEnabledChanged() {
    if (_selection.enabled) _requestReflow();
  }

  // --- pipeline state ---

  _GpuTextSurface? _surface;
  bool _surfaceInitStarted = false;
  bool _disposed = false;

  // Reflow sampling (see _GPUTextViewState._reflow / GPUTextWorker.reflowDoc).
  int _reflowEpoch = 0;
  // Newest epoch whose drawable was applied. Results are applied whenever
  // they are newer than the SCREEN (epoch > applied), not only when they are
  // the newest REQUEST (epoch == _reflowEpoch) — during a continuous resize a
  // fresh request starts every frame, so the strict rule discarded every
  // arriving result and the view froze at the pre-drag layout until input
  // paused for a full round trip. Monotone application turns that freeze-
  // then-pop into progressive reflow at worker latency.
  int _appliedReflowEpoch = 0;
  // Atlas-mirror generation currently uploaded to this surface (-1 = none).
  int _atlasGenOnGpu = -1;

  double _width = 0; // wrap width = cross-axis extent
  double _docWidth = 0;
  double _docHeight = 0;
  int _glyphCount = 0;
  int _colorGlyphCount = 0;
  List<_ColorStub> _colorStubs = const [];
  List<DecorationLine> _decorationsBelow = const [];
  List<DecorationLine> _decorationsAbove = const [];
  List<BackgroundRect> _backgrounds = const [];
  List<HitSpanBox> _hitBoxes = const [];

  // Placeholder boxes from the current drawable, and the auto-measure state
  // (mirrors _GPUTextViewState: [_resolvedRuns] is document.runs with sizeless
  // GPUWidgetSpans patched to the sizes measured during layout).
  Map<int, PlaceholderBox> _placeholderByIndex = const {};
  String? _measuredDocId;
  List<GPUInlineSpec>? _resolvedRuns;
  // The runs instance the worker last (re-)prepared for this id; a resize hands
  // [_resolvedRuns] a new instance, which is how [_reflow] knows to force a
  // re-prepare.
  List<GPUInlineSpec>? _preparedRuns;

  // Last natural sizes reflowed for each sizeless [GPUWidgetSpan], keyed by
  // placeholder index. Auto-sized children are re-measured under loose
  // constraints on EVERY layout, so a hosted widget that changes size (an
  // image decoding, an animation) re-triggers a reflow and the text re-weaves
  // around it — not just once per document id.
  Map<int, Size> _measuredSizes = const {};

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! _SliverPlaceholderParentData) {
      child.parentData = _SliverPlaceholderParentData();
    }
  }

  // The cached window image and the doc-space strip it covers. [_drawableGen]
  // bumps whenever the uploaded instances change (reflow, color-atlas pack,
  // DPR) so a stale strip re-renders even when the geometry is unchanged.
  // [_windowSrc] is the device-px sub-rect of [_window] holding the strip —
  // the surface's backing texture is bucketed, so the image can be larger.
  ui.Image? _window;
  Rect _windowSrc = Rect.zero;
  double _windowTop = 0;
  double _windowHeight = 0;
  double _windowWidth = 0;
  double _windowDpr = 0;
  int _drawableGen = 0;
  int _windowGen = -1;
  // Constraints at the last [renderAt]. A window resize can invalidate the
  // GpuImageSurface texture without moving the scroll offset — if we only key
  // on strip coverage we keep painting a dead image until the user scrolls.
  // Use [viewportMainAxisExtent] (not remainingPaintExtent): the latter
  // changes as the sliver scrolls into view and would thrash the texture.
  double _rasterCrossAxis = -1;
  double _rasterViewportExtent = -1;

  final LayerHandle<ClipRectLayer> _clipHandle = LayerHandle<ClipRectLayer>();
  final Paint _imagePaint = Paint()..filterQuality = FilterQuality.low;

  /// Test hook: whether a rasterized window image is currently cached.
  @visibleForTesting
  bool get debugHasWindow => _window != null;

  /// Test hook: the doc-space strip [debugHasWindow] covers (top, height).
  @visibleForTesting
  (double, double) get debugWindowStrip => (_windowTop, _windowHeight);

  /// Test hook: the cached strip image (bucketed backing texture).
  @visibleForTesting
  ui.Image? get debugWindowImage => _window;

  /// Test hook: the device-px sub-rect of [debugWindowImage] paint samples.
  @visibleForTesting
  Rect get debugWindowSrc => _windowSrc;

  /// Test hook: every selection-highlight rect the paint pass would draw
  /// (doc space, pre-cull), across all fragments.
  @visibleForTesting
  List<Rect> get debugSelectionRects => [
    for (final f in _selection.fragments) ...f.value.selectionRects,
  ];

  // --- lifecycle ---

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _validForMouseTracker = true;
    _selection.bindHost(
      this,
      // Sliver-local origin is the paint origin; doc y maps through the live
      // scroll offset (same math as childMainAxisPosition).
      shift: () => Offset(0, -constraints.scrollOffset),
      size: () => Size(_docWidth, _docHeight),
    );
    _selection.repaint.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _selection.repaint.removeListener(markNeedsPaint);
    _selection.unbindHost(this);
    _validForMouseTracker = false;
    super.detach();
  }

  @override
  void dispose() {
    _disposed = true;
    _selection.dispose();
    _tap?.dispose();
    _clipHandle.layer = null;
    _surface?.dispose();
    _surface = null;
    _window = null; // owned by the surface's retire queue, not us
    super.dispose();
  }

  // --- reflow driver ---

  void _ensureSurface() {
    if (_surfaceInitStarted) return;
    _surfaceInitStarted = true;
    unawaited(
      _GpuTextSurface.tryCreate().then((surface) {
        if (_disposed) {
          surface?.dispose();
          return;
        }
        _surface = surface;
        // The width is discovered by performLayout; if it already ran, go.
        if (surface != null && _width > 0) _requestReflow();
      }),
    );
  }

  void _requestReflow() {
    if (_surface == null || _width <= 0) return; // re-fired when both exist
    unawaited(_reflow());
  }

  // Captures [_document] / [_width] at send time; overlapping calls sample
  // on the worker and the epoch gate drops stale applies.
  Future<void> _reflow() async {
    final surface = _surface;
    if (surface == null) return;
    final epoch = ++_reflowEpoch;
    try {
      if (_disposed || _controller._disposed) return;
      final doc = _document;
      final w = _width;
      if (w <= 0) return;
      // Auto-measure gate: sizeless GPUWidgetSpans are measured by
      // performLayout (children laid out loose); it re-kicks us with
      // [_resolvedRuns] once the sizes are known.
      if (doc.autoSizedPlaceholders.isNotEmpty && _measuredDocId != doc.id) {
        return;
      }
      final runs = _resolvedRuns ?? doc.runs;
      // A sizeless placeholder that resized hands us a fresh [runs] instance
      // (new reserved box) under the same id — force the worker to re-shape it,
      // else the cached paragraph keeps the old box and the text never re-weaves.
      final force =
          doc.autoSizedPlaceholders.isNotEmpty && !identical(runs, _preparedRuns);
      await _controller._ensurePrepared(
        doc.id,
        runs,
        fallbackFontIds: doc.fallbackFontIds,
        emojiFontId: doc.emojiFontId,
        lineBreak: doc.lineBreak,
        language: doc.language,
        force: force,
      );
      _preparedRuns = runs;
      if (_disposed || _controller._disposed || epoch != _reflowEpoch) return;
      final sw = Stopwatch()..start();
      // The controller wrapper keeps the atlas mirror current (replies carry
      // only the tail it doesn't hold, usually nothing).
      // Table-less while resize streaming with nothing selected; one settle
      // refresh afterwards (see _GPUTextViewState._reflow).
      final wantTable =
          _selection.enabled &&
          (_selection.hasSelection ||
              !_selection.hasLineTable ||
              _tableRefreshDue);
      final d = await _controller._reflowDoc(
        doc.id,
        w,
        style: doc.effectiveStyle,
        dpr: _dpr,
        includeLineTable: wantTable,
      );
      sw.stop();
      // Monotone gate: skip only when an even newer result already landed.
      if (_disposed || _controller._disposed || epoch <= _appliedReflowEpoch) {
        return;
      }
      _appliedReflowEpoch = epoch;
      _applyDrawable(d, sw.elapsedMicroseconds / 1000.0, wantTable);
    } on GPUTextReflowSuperseded {
      if (!_disposed && !_controller._disposed && epoch == _reflowEpoch) {
        _requestReflow();
      }
    } on StateError catch (e) {
      // Worker/controller torn down while we awaited (route pop). Swallow.
      if (!e.message.contains('disposed')) rethrow;
    }
  }

  void _applyDrawable(
    GPUTextInstances d,
    double ms, [
    bool tableRequested = false,
  ]) {
    final surface = _surface;
    if (surface == null) return;
    // Upload from the controller's atlas mirror when this surface's texture
    // is behind what the fresh instances reference (see _GPUTextViewState).
    if (_atlasGenOnGpu < d.atlasGeneration &&
        _controller._atlasGeneration >= d.atlasGeneration) {
      surface.setAtlas(_controller._atlas.curves, _controller._atlas.rows);
      _atlasGenOnGpu = _controller._atlasGeneration;
    }
    surface.setInstances(d.materialize());
    _glyphCount = d.glyphCount;
    _docWidth = d.width;
    _docHeight = d.height;
    _decorationsBelow = [
      for (final l in d.decorations)
        if (!l.aboveText) l,
    ];
    _decorationsAbove = [
      for (final l in d.decorations)
        if (l.aboveText) l,
    ];
    _backgrounds = d.backgrounds;
    _hitBoxes = d.hitBoxes;
    // Same reply as the instances (epoch-gated with them): selection rows
    // always describe the pixels on screen.
    _selection.applyLineTable(
      d.materializeLineTable(),
      d.layoutGeneration,
      Size(d.width, d.height),
      requested: tableRequested,
    );
    if (tableRequested) _tableRefreshDue = false;
    _placeholderByIndex = {
      for (final b in d.placeholders)
        if (b.index >= 0) b.index: b,
    };
    _colorStubs = [
      for (final s in d.colorGlyphStubs) _ColorStub.fromTransfer(s),
    ];
    // Pack any new bitmap emoji; rebuild color instances from whatever is
    // already resident (stubs still decoding stay blank until the bump).
    if (_colorStubs.isNotEmpty) {
      final genBefore = _controller.colorAtlas.generation;
      unawaited(
        _controller._ensureColorStubs(_colorStubs).then((changed) {
          if (_disposed || _controller._disposed) return;
          if (changed || _controller.colorAtlas.generation != genBefore) {
            _uploadColorInstances();
            _drawableGen++;
            if (attached) markNeedsLayout();
          }
        }),
      );
    }
    _uploadColorInstances();
    _drawableGen++;
    // Geometry (scrollExtent) and the window image both derive from the new
    // drawable; the viewport re-runs our layout and paints the same frame.
    // Extent changes flow through SliverGeometry, so there is no jumpTo /
    // setState to fight a ballistic fling with.
    if (attached) markNeedsLayout();
    onMetrics?.call(
      GPUTextMetrics(
        glyphCount: d.glyphCount,
        lineCount: d.lineCount,
        size: Size(d.contentWidth, d.height),
        reflowMs: ms,
      ),
    );
  }

  void _uploadColorInstances() {
    final surface = _surface;
    if (surface == null) return;
    final color = _colorInstancesFromStubs(_colorStubs, _controller.colorAtlas);
    _colorGlyphCount = color.length ~/ floatsPerColorInstance;
    surface.setColorInstances(color);
  }

  // --- sliver layout ---

  @override
  void performLayout() {
    final c = constraints;
    assert(
      c.axis == Axis.vertical && c.growthDirection == GrowthDirection.forward,
      'SliverGPUText v1 supports vertical, forward-growth viewports only.',
    );
    _ensureSurface();
    final w = c.crossAxisExtent;
    if (w > 0 && w != _width) {
      _width = w;
      _requestReflow(); // async; markNeedsLayout re-runs us when it lands
    }
    _layoutPlaceholderChildren();
    final contentH = _docHeight;
    if (contentH <= 0) {
      geometry = SliverGeometry.zero;
      return;
    }
    geometry = SliverGeometry(
      scrollExtent: contentH,
      paintExtent: calculatePaintOffset(c, from: 0, to: contentH),
      cacheExtent: calculateCacheOffset(c, from: 0, to: contentH),
      maxPaintExtent: contentH,
      hasVisualOverflow:
          contentH > c.remainingPaintExtent || c.scrollOffset > 0,
    );
    _updateWindow(c, contentH);
  }

  /// Lay out the hosted placeholder children.
  ///
  /// Explicitly-sized [GPUWidgetSpan]s are laid out tight to their reserved
  /// box. Sizeless ones are re-measured under loose constraints (capped to the
  /// cross-axis width — an inline widget can't be wider than its line) on
  /// EVERY layout and displayed at their natural size: an image finishing
  /// decode or a widget animating its size relayouts the child, which lands
  /// here, and any change from the last reflowed size re-kicks a reflow so the
  /// text re-weaves around it. The extent is provisional for the one frame
  /// between a size change and the reflow that lands, exactly as at first paint.
  void _layoutPlaceholderChildren() {
    if (firstChild == null) return;
    final doc = _document;
    final auto = doc.autoSizedPlaceholders;
    final measured = auto.isEmpty ? null : <int, Size>{};
    final maxW = _width > 0 ? _width : double.infinity;
    var child = firstChild;
    while (child != null) {
      final pd = child.parentData! as _SliverPlaceholderParentData;
      final box = _placeholderByIndex[pd.index];
      if (auto.contains(pd.index)) {
        // Sizeless: measure natural size every layout so a resize reflows.
        child.layout(BoxConstraints(maxWidth: maxW), parentUsesSize: true);
        measured![pd.index] = child.size;
        if (box != null) {
          pd.offset = Offset(box.left, box.top);
          pd.hasBox = true;
        } else {
          pd.hasBox = false; // pre-first-reflow: measured, not yet placed
        }
      } else if (box != null) {
        child.layout(BoxConstraints.tight(Size(box.width, box.height)));
        pd.offset = Offset(box.left, box.top);
        pd.hasBox = true;
      } else {
        child.layout(const BoxConstraints(), parentUsesSize: true);
        pd.hasBox = false;
      }
      child = childAfter(child);
    }
    if (measured != null && _autoSizesChanged(doc, measured)) {
      _measuredDocId = doc.id;
      _measuredSizes = measured;
      _resolvedRuns = _resolvePlaceholderSpecSizes(doc.runs, measured);
      _requestReflow();
    }
  }

  /// True when this measure pass differs from what we last reflowed — a new
  /// document, or any sizeless placeholder whose natural size moved by more
  /// than half a pixel (the epsilon keeps sub-pixel jitter from thrashing the
  /// worker during an animation).
  bool _autoSizesChanged(GPUTextDocument doc, Map<int, Size> now) {
    if (_measuredDocId != doc.id || now.length != _measuredSizes.length) {
      return true;
    }
    for (final e in now.entries) {
      final prev = _measuredSizes[e.key];
      if (prev == null ||
          (prev.width - e.value.width).abs() > 0.5 ||
          (prev.height - e.value.height).abs() > 0.5) {
        return true;
      }
    }
    return false;
  }

  /// Rasterize the viewport's cache region of the drawable when the cached
  /// strip no longer covers the visible range (or was rendered for stale
  /// instances / width / DPR / viewport size). Runs during layout, so paint
  /// in the same frame always has a covering image — a fling cannot uncover
  /// a blank strip. Scrolling *within* the cached strip re-renders nothing;
  /// paint just shifts the image.
  void _updateWindow(SliverConstraints c, double contentH) {
    final surface = _surface;
    if (surface == null) return;
    if (_glyphCount == 0 && _colorGlyphCount == 0) {
      _window = null; // empty document: nothing to show
      return;
    }
    final visTop = c.scrollOffset.clamp(0.0, contentH);
    final visBottom = (c.scrollOffset + c.remainingPaintExtent).clamp(
      visTop,
      contentH,
    );
    // Viewport size must be part of the freshness key: OS window resize can
    // kill the previous texture while scroll offset (and strip coverage) stay
    // put — early-returning here leaves a blank paint until the next scroll.
    final constraintsChanged =
        c.crossAxisExtent != _rasterCrossAxis ||
        c.viewportMainAxisExtent != _rasterViewportExtent;
    final fresh =
        !constraintsChanged &&
        _windowGen == _drawableGen &&
        _windowDpr == _dpr &&
        _windowWidth == _docWidth;
    if (fresh &&
        _window != null &&
        _windowTop <= visTop &&
        _windowTop + _windowHeight >= visBottom) {
      return;
    }
    // Target strip: the viewport's cache region, clamped to the content and
    // the GPU texture cap (anchored around the visible range if the cap
    // bites — a huge custom cacheExtent must not blow the texture limit).
    var top = (c.scrollOffset + c.cacheOrigin).clamp(0.0, contentH);
    var bottom = (top + c.remainingCacheExtent).clamp(top, contentH);
    final maxH = _maxDevicePx / math.max(_dpr, 0.001);
    if (bottom - top > maxH) {
      final slack = math.max(0.0, maxH - (visBottom - visTop)) / 2;
      top = math.max(0.0, visTop - slack);
      bottom = math.min(contentH, top + maxH);
      top = math.max(0.0, bottom - maxH);
    }
    if (bottom - top <= 0) {
      _window = null;
      return;
    }
    _windowTop = top;
    _windowHeight = bottom - top;
    _windowWidth = _docWidth;
    _windowDpr = _dpr;
    _windowGen = _drawableGen;
    _rasterCrossAxis = c.crossAxisExtent;
    _rasterViewportExtent = c.viewportMainAxisExtent;
    _window = surface.renderAt(
      devW: (_docWidth * _dpr).round().clamp(1, _maxDevicePx.round()),
      devH: (_windowHeight * _dpr).round().clamp(1, _maxDevicePx.round()),
      dpr: _dpr,
      camX: 0,
      camY: -top * _dpr,
      // Transparent clear: [_background] and span chrome are painted by the
      // canvas below/above the image (same layering as GPUTextView).
      clear: vm.Vector4(0, 0, 0, 0),
      colorAtlas: _controller.colorAtlasTexture(),
    );
    _windowSrc = surface.contentRect;
  }

  // --- paint ---

  @override
  void paint(PaintingContext context, Offset offset) {
    final g = geometry;
    if (g == null || g.paintExtent <= 0) return;
    final c = constraints;
    final w = c.crossAxisExtent;
    final h = g.paintExtent;
    _clipHandle.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & Size(w, h),
      (context, offset) {
        final scroll = c.scrollOffset;
        if (_background.a > 0) {
          context.canvas.drawRect(
            offset & Size(w, h),
            Paint()..color = _background,
          );
        }
        if (_backgrounds.isNotEmpty || _decorationsBelow.isNotEmpty) {
          final canvas = context.canvas;
          canvas.save();
          canvas.translate(offset.dx, offset.dy);
          _paintSpanChrome(
            canvas,
            backgrounds: _backgrounds,
            decorations: _decorationsBelow,
            offX: 0,
            offY: scroll,
            viewportWidth: w,
            viewportHeight: h,
          );
          canvas.restore();
        }
        // Selection highlight + handle LeaderLayers, under the glyph image
        // (transparent GPU clear). Must run OUTSIDE the canvas translate:
        // pushLayer ignores canvas transforms, so the doc→paint shift rides
        // the offset instead.
        {
          // Cull to the painted band (doc space) — a huge selection must
          // not pay a drawRect per offscreen line. Noting the band here is
          // also what drives per-line detail prefetch for it.
          final cull = Rect.fromLTWH(0, scroll, w, h);
          _selection.noteVisibleBand(cull);
          if (_selection.fragments.isNotEmpty) {
            final selOffset = offset + Offset(0, -scroll);
            for (final f in _selection.fragments) {
              f.paint(context, selOffset, cull: cull);
            }
          }
        }
        // Re-fetch the canvas: a fragment that pushed handle LeaderLayers
        // ended the previous picture recording, killing any canvas reference
        // taken before it (native-peer StateError on next use).
        final canvas = context.canvas;
        canvas.save();
        canvas.translate(offset.dx, offset.dy);
        final img = _window;
        if (img != null) {
          canvas.drawImageRect(
            img,
            _windowSrc, // strip sub-rect: the backing texture is bucketed
            Rect.fromLTWH(0, _windowTop - scroll, _windowWidth, _windowHeight),
            _imagePaint,
          );
        }
        if (_decorationsAbove.isNotEmpty) {
          _paintSpanChrome(
            canvas,
            backgrounds: const [],
            decorations: _decorationsAbove,
            offX: 0,
            offY: scroll,
            viewportWidth: w,
            viewportHeight: h,
          );
        }
        canvas.restore();
        // Hosted placeholder widgets ride over the glyphs (same stacking as
        // GPUTextView's overlay), culled to the painted window.
        var child = firstChild;
        while (child != null) {
          final pd = child.parentData! as _SliverPlaceholderParentData;
          if (pd.hasBox) {
            final dy = pd.offset.dy - scroll;
            if (dy < h && dy + child.size.height > 0) {
              context.paintChild(child, offset + Offset(pd.offset.dx, dy));
            }
          }
          child = childAfter(child);
        }
      },
      oldLayer: _clipHandle.layer,
    );
  }

  // --- hit testing / span interaction ---

  /// Hosted placeholder children first (topmost = last in paint order wins).
  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    final boxResult = BoxHitTestResult.wrap(result);
    var child = lastChild;
    while (child != null) {
      final pd = child.parentData! as _SliverPlaceholderParentData;
      if (pd.hasBox &&
          hitTestBoxChild(
            boxResult,
            child,
            mainAxisPosition: mainAxisPosition,
            crossAxisPosition: crossAxisPosition,
          )) {
        return true;
      }
      child = childBefore(child);
    }
    return false;
  }

  @override
  double childMainAxisPosition(RenderBox child) {
    final pd = child.parentData! as _SliverPlaceholderParentData;
    return pd.offset.dy - constraints.scrollOffset;
  }

  @override
  double childCrossAxisPosition(RenderBox child) =>
      (child.parentData! as _SliverPlaceholderParentData).offset.dx;

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    applyPaintTransformForBoxChild(child as RenderBox, transform);
  }

  /// Claim only positions over a [HitSpanBox], so taps elsewhere fall through
  /// (the viewport's scrollable owns drags regardless — it sits above us).
  @override
  bool hitTestSelf({
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    return _hitBoxAt(
          crossAxisPosition,
          constraints.scrollOffset + mainAxisPosition,
        ) !=
        null;
  }

  HitSpanBox? _hitBoxAt(double x, double y) {
    for (var i = _hitBoxes.length - 1; i >= 0; i--) {
      final b = _hitBoxes[i];
      if (b.contains(x, y)) return b;
    }
    return null;
  }

  TapGestureRecognizer? _tap;
  Offset _tapDownDoc = Offset.zero;

  @override
  void handleEvent(PointerEvent event, SliverHitTestEntry entry) {
    // [entry] carries the positions captured at hit-test time: the down
    // position for the tap sequence, the live position for hover events.
    final doc = Offset(
      entry.crossAxisPosition,
      constraints.scrollOffset + entry.mainAxisPosition,
    );
    if (event is PointerDownEvent) {
      _tapDownDoc = doc;
      (_tap ??= TapGestureRecognizer(
        debugOwner: this,
      )..onTap = _handleTap).addPointer(event);
    } else if (event is PointerHoverEvent) {
      _updateHover(doc);
    }
  }

  void _handleTap() {
    final box = _hitBoxAt(_tapDownDoc.dx, _tapDownDoc.dy);
    final tag = box?.source;
    if (tag is! String) return;
    final span = _document.hitTargets[tag];
    final recognizer = span?.recognizer;
    if (recognizer is TapGestureRecognizer) {
      recognizer.onTap?.call();
    }
    onSpanTap?.call(tag, span);
  }

  // --- hover cursor (MouseTrackerAnnotation) ---

  String? _hoverTag;
  bool _validForMouseTracker = false;

  void _updateHover(Offset doc) {
    final box = _hitBoxAt(doc.dx, doc.dy);
    final tag = box?.source is String ? box!.source as String? : null;
    if (tag == _hoverTag) return;
    _hoverTag = tag;
    markNeedsPaint(); // schedules the post-frame mouse-tracker cursor refresh
  }

  @override
  MouseCursor get cursor {
    // Only positions over a hit box reach us (see [hitTestSelf]).
    final tag = _hoverTag;
    final custom = tag == null ? null : _document.hitTargets[tag]?.mouseCursor;
    if (custom != null && custom != MouseCursor.defer) return custom;
    return SystemMouseCursors.click;
  }

  @override
  PointerEnterEventListener? get onEnter => null;

  @override
  PointerExitEventListener? get onExit =>
      (_) => _hoverTag = null;

  @override
  bool get validForMouseTracker => _validForMouseTracker;
}

// --- shared span-chrome painting (canvas-space, doc coords shifted by off) ---

/// Paints [backgrounds] and [decorations] (doc space) shifted by [offX]/[offY]
/// into a `viewportWidth`×`viewportHeight` window at the canvas origin, with
/// per-item culling. Shared by [_SpanChromePainter] (widget layers) and
/// [_RenderSliverGPUText] (direct sliver paint).
void _paintSpanChrome(
  Canvas canvas, {
  required List<BackgroundRect> backgrounds,
  required List<DecorationLine> decorations,
  required double offX,
  required double offY,
  required double viewportWidth,
  required double viewportHeight,
}) {
  final vw = viewportWidth;
  final vh = viewportHeight;
  final paint = Paint();
  for (final b in backgrounds) {
    if (b.top + b.height < offY || b.top > offY + vh) continue;
    if (b.left + b.width < offX || b.left > offX + vw) continue;
    paint.color = _rgbaColor(b.color);
    canvas.drawRect(
      Rect.fromLTWH(b.left - offX, b.top - offY, b.width, b.height),
      paint,
    );
  }
  for (final d in decorations) {
    final y = d.y - offY;
    if (y + d.thickness < 0 || y - d.thickness > vh) continue;
    if (d.x + d.width < offX || d.x > offX + vw) continue;
    _drawDecorationLine(canvas, d, d.x - offX, y);
  }
}

void _drawDecorationLine(Canvas canvas, DecorationLine d, double x, double y) {
  final paint = Paint()..color = _rgbaColor(d.color);
  final w = d.width;
  final th = math.max(d.thickness, 0.5);
  switch (d.style) {
    case InlineDecorationStyle.solid:
      canvas.drawRect(Rect.fromLTWH(x, y - th / 2, w, th), paint);
    case InlineDecorationStyle.doubleLine:
      canvas.drawRect(Rect.fromLTWH(x, y - th * 1.5, w, th), paint);
      canvas.drawRect(Rect.fromLTWH(x, y + th * 0.5, w, th), paint);
    case InlineDecorationStyle.dotted:
      for (var dx = th / 2; dx < w; dx += th * 3) {
        canvas.drawCircle(Offset(x + dx, y), th / 2, paint);
      }
    case InlineDecorationStyle.dashed:
      for (var dx = 0.0; dx < w; dx += th * 5) {
        canvas.drawRect(
          Rect.fromLTWH(x + dx, y - th / 2, math.min(th * 3, w - dx), th),
          paint,
        );
      }
    case InlineDecorationStyle.wavy:
      final path = Path()..moveTo(x, y);
      final half = th * 2;
      var cx = x;
      var up = true;
      while (cx < x + w) {
        final nx = math.min(cx + half, x + w);
        final t = (nx - cx) / half;
        path.quadraticBezierTo(
          cx + half / 2,
          y + (up ? -half : half) * t,
          nx,
          y,
        );
        up = !up;
        cx = nx;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = paint.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = th,
      );
  }
}

Color _rgbaColor(List<double> c) => Color.from(
  alpha: c.length > 3 ? c[3] : 1.0,
  red: c[0],
  green: c[1],
  blue: c[2],
);

/// Same ids in the same order with equal layout styles ⇒ the laid-out output
/// is identical (same id ⇒ same runs by the [GPUTextDocument.id] contract),
/// so every cache keyed by id stays valid. Shared by [GPUTextBlocksView] and
/// [SliverGPUTextBlocks].
bool _equivalentBlockLists(List<GPUBlock> a, List<GPUBlock> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (identical(x, y)) continue;
    if (x.id != y.id) return false;
    if (x is GPUTextDocument && y is GPUTextDocument) {
      if (x.effectiveStyle != y.effectiveStyle) return false;
    } else if (x is GPUWidgetBlock && y is GPUWidgetBlock) {
      // Compare by fields, not builder identity: a fresh list with the same
      // ids/heights is equivalent (the on-screen media layer is rebuilt
      // separately in didUpdateWidget so new closures still take effect).
      if (x.height != y.height || x.estimatedHeight != y.estimatedHeight) {
        return false;
      }
    } else {
      return false; // block kind changed at this index
    }
  }
  return true;
}

/// GPU text blocks as a sliver: one [GPUTextDocument] per paragraph, shaped
/// and laid out on the worker only when it scrolls near the viewport, then
/// composited into a single strip texture — inside a [CustomScrollView].
///
/// The sliver improves on [GPUTextBlocksView] the same way [SliverGPUText]
/// improves on [GPUTextView], plus one blocks-specific win: when a block's
/// estimated height is replaced by its real height above the viewport, the
/// fixup is reported as [SliverGeometry.scrollOffsetCorrection] — the
/// viewport re-anchors atomically, mid-fling included, instead of the box
/// view's "jumpTo when idle" (which silently accepts drift during flings).
///
/// Memory policy matches [GPUTextBlocksView]: one shared worker atlas, GPU
/// instance buffers only for blocks near the viewport, and worker-side shaped
/// paragraphs kept warm under an LRU capped at [maxPreparedDocs].
///
/// V1 limitations: no inline placeholder widgets, span-chrome, or hit tags
/// (parity with [GPUTextBlocksView], which has none either); vertical,
/// [GrowthDirection.forward] viewports only. Wrap in [SliverPadding] for
/// insets. Renders nothing where flutter_gpu / Impeller is unavailable.
class SliverGPUTextBlocks extends LeafRenderObjectWidget {
  const SliverGPUTextBlocks({
    super.key,
    required this.controller,
    required this.blocks,
    this.blockSpacing = 0,
    this.background = const Color(0xFFFFFFFF),
    this.cacheExtent = 600,
    this.maxPreparedDocs = 64,
    this.estimateHeight,
    this.onLaidOutChanged,
    this.selectionRegistrar,
    this.selectionColor,
  });

  /// Shared worker owner; fonts referenced by [blocks] must be registered on
  /// it first.
  final GPUTextViewController controller;

  /// The document, one [GPUTextDocument] per paragraph, each with a distinct
  /// id. A rebuilt list with the same ids and styles is recognized and keeps
  /// every cache.
  final List<GPUTextDocument> blocks;

  /// Vertical gap between blocks, logical px.
  final double blockSpacing;

  /// Painted behind the glyphs across the sliver's paint region.
  final Color background;

  /// How far beyond the viewport (logical px) to lay out blocks and keep
  /// their GPU instance buffers. Larger = smoother scrolling, more GPU
  /// memory.
  final double cacheExtent;

  /// Cap on simultaneously prepared (shaped) worker docs; see
  /// [GPUTextBlocksView.maxPreparedDocs].
  final int maxPreparedDocs;

  /// Provisional height for a not-yet-laid-out block. Defaults to a crude
  /// chars/line×lineHeight estimate.
  final GPUBlockHeightEstimator? estimateHeight;

  /// Reports (blocksLaidOut, totalBlocks) as blocks lay out — for a HUD.
  final void Function(int laidOut, int total)? onLaidOutChanged;

  /// Selection registrar. Like [GPURichText], a null registrar falls back to
  /// the enclosing [SelectionContainer]. While a registrar is attached, block
  /// syncs additionally ship selection geometry from the worker. Blocks
  /// outside the cache window hold no geometry (select-all covers the synced
  /// window — the standard virtualized-sliver limitation).
  final SelectionRegistrar? selectionRegistrar;

  /// Highlight color; defaults to [DefaultSelectionStyle.of] when selection
  /// is active.
  final Color? selectionColor;

  SelectionRegistrar? _effectiveRegistrar(BuildContext context) =>
      selectionRegistrar ?? SelectionContainer.maybeOf(context);

  Color? _effectiveSelectionColor(
    BuildContext context,
    SelectionRegistrar? registrar,
  ) => registrar == null
      ? selectionColor
      : selectionColor ??
            DefaultSelectionStyle.of(context).selectionColor ??
            DefaultSelectionStyle.defaultColor;

  @override
  RenderObject createRenderObject(BuildContext context) {
    final registrar = _effectiveRegistrar(context);
    return RenderSliverGPUTextBlocks(
      controller: controller,
      blocks: blocks,
      blockSpacing: blockSpacing,
      background: background,
      cacheExtent: cacheExtent,
      maxPreparedDocs: maxPreparedDocs,
      estimateHeight: estimateHeight,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      onLaidOutChanged: onLaidOutChanged,
    )..configureSelection(
      registrar: registrar,
      color: _effectiveSelectionColor(context, registrar),
      direction: Directionality.maybeOf(context) ?? TextDirection.ltr,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverGPUTextBlocks renderObject,
  ) {
    final registrar = _effectiveRegistrar(context);
    renderObject
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..background = background
      ..blockSpacing = blockSpacing
      ..cacheExtent = cacheExtent
      ..maxPreparedDocs = maxPreparedDocs
      ..estimateHeight = estimateHeight
      ..onLaidOutChanged = onLaidOutChanged
      ..controller = controller
      ..blocks = blocks
      ..configureSelection(
        registrar: registrar,
        color: _effectiveSelectionColor(context, registrar),
        direction: Directionality.maybeOf(context) ?? TextDirection.ltr,
      );
  }
}

/// The render sliver behind [SliverGPUTextBlocks]. Public for
/// `updateRenderObject`; construct it through the widget.
class RenderSliverGPUTextBlocks extends RenderSliver {
  RenderSliverGPUTextBlocks({
    required this._controller,
    required this._blocks,
    required this._blockSpacing,
    required this._background,
    required this._cacheExtent,
    required this._maxPreparedDocs,
    required this._estimateHeight,
    required double devicePixelRatio,
    this.onLaidOutChanged,
  }) : _dpr = devicePixelRatio {
    _rebuildBlockIndex();
  }

  // --- configuration ---

  GPUTextViewController _controller;
  set controller(GPUTextViewController value) {
    if (identical(value, _controller)) return;
    _controller = value;
    _resetCaches();
    markNeedsLayout();
  }

  List<GPUTextDocument> _blocks;
  set blocks(List<GPUTextDocument> value) {
    if (identical(value, _blocks)) return;
    final equivalent = _equivalentBlockLists(_blocks, value);
    _blocks = value;
    if (equivalent) return; // parent rebuild with identical content (same ids)
    _resetCaches();
    markNeedsLayout();
  }

  double _blockSpacing;
  set blockSpacing(double value) {
    if (value == _blockSpacing) return;
    _blockSpacing = value;
    _drawableGen++; // block screen positions shift inside the strip
    _topsDirty = true; // gaps between tops change; heights don't
    markNeedsLayout();
  }

  Color _background;
  set background(Color value) {
    if (value == _background) return;
    _background = value;
    markNeedsPaint();
  }

  double _cacheExtent;
  set cacheExtent(double value) {
    if (value == _cacheExtent) return;
    _cacheExtent = value;
    markNeedsLayout();
  }

  int _maxPreparedDocs;
  set maxPreparedDocs(int value) {
    if (value == _maxPreparedDocs) return;
    _maxPreparedDocs = value;
    markNeedsLayout(); // next sync trims
  }

  GPUBlockHeightEstimator? _estimateHeight;
  set estimateHeight(GPUBlockHeightEstimator? value) {
    if (value == _estimateHeight) return;
    _estimateHeight = value;
    _topsDirty = true; // changes the provisional height of unshaped blocks
    markNeedsLayout(); // estimates only matter for not-yet-laid-out blocks
  }

  double _dpr;
  set devicePixelRatio(double value) {
    if (value == _dpr) return;
    _dpr = value;
    _invalidateForWidth(); // instances are rasterized per-DPR
    markNeedsLayout();
  }

  void Function(int laidOut, int total)? onLaidOutChanged;

  // --- selection (per block, mirrors _GPUTextBlocksViewState) ---

  final Map<String, _DocSelection> _selections = {};
  SelectionRegistrar? _selRegistrar;
  Color? _selColor;
  TextDirection _selDirection = TextDirection.ltr;
  Map<String, int> _indexOfId = const {};

  bool get _selectionEnabled => _selRegistrar != null;

  /// Wired by the widget's create/updateRenderObject.
  void configureSelection({
    required SelectionRegistrar? registrar,
    required Color? color,
    required TextDirection direction,
  }) {
    final wasEnabled = _selectionEnabled;
    _selRegistrar = registrar;
    _selColor = color;
    _selDirection = direction;
    for (final sel in _selections.values) {
      sel.configure(registrar: registrar, color: color, direction: direction);
    }
    // Registrar appeared: live blocks synced without geometry — refetch.
    if (!wasEnabled && registrar != null && attached) markNeedsLayout();
  }

  double _topOfId(String id) {
    final i = _indexOfId[id];
    return i == null || i >= _tops.length ? 0.0 : _tops[i];
  }

  void _rebuildBlockIndex() {
    _indexOfId = {for (var i = 0; i < _blocks.length; i++) _blocks[i].id: i};
  }

  _DocSelection _selectionFor(String id) => _selections.putIfAbsent(id, () {
    final sel = _DocSelection();
    sel.configure(
      registrar: _selRegistrar,
      color: _selColor,
      direction: _selDirection,
    );
    sel.repaint.addListener(markNeedsPaint);
    if (attached) _bindBlockSelection(id, sel);
    return sel;
  });

  void _bindBlockSelection(String id, _DocSelection sel) {
    sel.bindHost(
      this,
      // Sliver-local = doc-local shifted by the block top minus the live
      // scroll offset (same math as the strip paint).
      shift: () => Offset(0, _topOfId(id) - constraints.scrollOffset),
      size: () => sel._docSize,
    );
  }

  void _disposeSelections() {
    for (final sel in _selections.values) {
      sel.repaint.removeListener(markNeedsPaint);
      sel.dispose();
    }
    _selections.clear();
  }

  // --- pipeline / cache state (mirrors _GPUTextBlocksViewState) ---

  _GpuTextSurface? _surface;
  bool _surfaceInitStarted = false;
  bool _disposed = false;
  bool _busy = false;
  bool _pending = false;
  int _gen = 0; // bumps on width/DPR/blocks reset so in-flight syncs abandon

  double _width = 0;
  final Map<String, double> _heights = {}; // per-width, by block id
  final Map<String, _BlockDrawable> _live = {};
  final LinkedHashMap<String, Null> _preparedLru = LinkedHashMap();
  // Shared GPU atlas for every live block, uploaded from the controller's
  // atlas mirror whenever [_atlasGenOnGpu] falls behind a drawable's needs.
  AtlasTextures? _atlasTextures;
  int _atlasGenOnGpu = -1;

  List<double> _tops = const [];
  double _totalHeight = 0;
  int _laidOut = 0;
  // _tops/_totalHeight are a pure function of block heights, estimates,
  // spacing, and cross-axis width — none of which a bare scroll touches. The
  // viewport relayouts this sliver every scroll frame; recomputing the tops
  // (O(n) over every block, plus a fresh List alloc) there was the dominant
  // per-frame cost. Recompute only when an input is dirtied — see the gate in
  // performLayout; _sync/_applyBlockDrawable recompute inline as heights land.
  bool _topsDirty = true;

  // Estimate→real height deltas for blocks fully above the viewport,
  // accumulated by the sync loop and reported as scrollOffsetCorrection on
  // the next layout pass so the viewport re-anchors atomically.
  double _pendingCorrection = 0;
  double _lastScrollOffset = 0;
  double _lastViewportH = 0;
  // Scroll movement between the last two layout passes — signs the direction
  // the want-window leads in and orders the sync (ahead-of-travel first).
  double _scrollDelta = 0;

  // Cached composite strip (same scheme as RenderSliverGPUText, including
  // the bucketed-texture sub-rect in [_windowSrc]).
  ui.Image? _window;
  Rect _windowSrc = Rect.zero;
  double _windowTop = 0;
  double _windowHeight = 0;
  double _windowWidth = 0;
  double _windowDpr = 0;
  int _drawableGen = 0;
  int _windowGen = -1;
  // Whether every block intersecting the rendered strip was live at raster
  // time. Only a COMPLETE strip is worth keeping on screen while fresh blocks
  // lay out (see the stale-keep branch in _updateWindow); a holey one must
  // keep re-rastering progressively as blocks land.
  bool _windowComplete = false;
  // True while paint is showing a kept strip whose content is stale (older
  // width/DPR/live-set) because replacing it now would paint holes.
  bool _windowIsStale = false;
  // See RenderSliverGPUText — viewport size is part of the freshness key so
  // a window resize re-rasters even when scroll offset is unchanged.
  double _rasterCrossAxis = -1;
  double _rasterViewportExtent = -1;

  final LayerHandle<ClipRectLayer> _clipHandle = LayerHandle<ClipRectLayer>();
  final Paint _imagePaint = Paint()..filterQuality = FilterQuality.low;

  /// Test hook: blocks whose real height has been laid out.
  @visibleForTesting
  int get debugLaidOutCount => _laidOut;

  /// Test hook: how many times the O(n) top/extent recompute actually ran.
  /// A bare scroll (no new blocks, unchanged width/spacing) must not grow it.
  @visibleForTesting
  int get debugTopsRecomputes => _topsRecomputes;
  int _topsRecomputes = 0;

  /// Test hook: whether a rasterized strip is currently cached.
  @visibleForTesting
  bool get debugHasWindow => _window != null;

  /// Test hook: whether paint is holding a stale strip (kept across a width /
  /// DPR invalidation) while fresh blocks lay out on the worker.
  @visibleForTesting
  bool get debugWindowIsStale => _windowIsStale;

  /// Test hook: whether every block intersecting the cached strip was live at
  /// raster time (a complete strip is what the stale-keep branch preserves).
  @visibleForTesting
  bool get debugWindowComplete => _windowComplete;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _selections.forEach(_bindBlockSelection);
  }

  @override
  void detach() {
    for (final sel in _selections.values) {
      sel.unbindHost(this);
    }
    super.detach();
  }

  @override
  void dispose() {
    // Abandon in-flight sync; do NOT fire per-doc disposeDoc here — the
    // parent typically disposes the controller (killing the worker) right
    // after, and unawaited disposeDocs would race it. Isolate teardown frees
    // every prepared doc.
    _disposed = true;
    _gen++;
    _disposeSelections();
    _preparedLru.clear();
    _live.clear();
    _atlasTextures = null;
    _clipHandle.layer = null;
    _surface?.dispose();
    _surface = null;
    _window = null; // owned by the surface's retire queue
    super.dispose();
  }

  void _resetCaches() {
    _gen++;
    for (final id in _preparedLru.keys) {
      unawaited(_controller._disposeDoc(id));
    }
    _preparedLru.clear();
    _live.clear();
    _heights.clear();
    _laidOut = 0;
    _tops = const [];
    _totalHeight = 0;
    _topsDirty = true;
    _atlasTextures = null;
    _atlasGenOnGpu = -1;
    _pendingCorrection = 0;
    _window = null; // content actually changed — a stale strip would lie
    _windowComplete = false;
    _windowIsStale = false;
    // Content changed: selections' source offsets no longer apply.
    _disposeSelections();
    _rebuildBlockIndex();
    _windowGen = -1;
    _rasterCrossAxis = -1;
    _rasterViewportExtent = -1;
  }

  /// Width/DPR changed: drop GPU instance buffers + heights (per-width) but
  /// KEEP worker prepares — shaping is width-independent, so a resize is
  /// reflow-only for the window. Atlas glyphs are width-independent too.
  ///
  /// The rendered strip is deliberately KEPT: its content is the same text at
  /// the old wrap width, and painting it for the worker round trip reads as
  /// "resizing" where a blank frame reads as broken. _windowGen is
  /// invalidated so the strip is replaced the moment the visible blocks have
  /// re-laid out (see the stale-keep branch in _updateWindow).
  void _invalidateForWidth() {
    _gen++;
    _live.clear();
    _heights.clear();
    _laidOut = 0;
    _tops = const [];
    _totalHeight = 0;
    _topsDirty = true;
    _pendingCorrection = 0;
    _windowGen = -1;
    _rasterCrossAxis = -1;
    _rasterViewportExtent = -1;
  }

  void _ensureSurface() {
    if (_surfaceInitStarted) return;
    _surfaceInitStarted = true;
    unawaited(
      _controller._sharedPipeline().then((pipeline) {
        if (_disposed || pipeline == null) return; // no GPU: stays empty
        _surface = _GpuTextSurface(pipeline);
        if (attached) markNeedsLayout(); // layout kicks the first sync
      }),
    );
  }

  // --- heights / tops (ports of the box view's helpers) ---

  double _estimate(GPUTextDocument block, double width) {
    final custom = _estimateHeight;
    if (custom != null) return custom(block, width);
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
    final block = _blocks[i];
    return _heights[block.id] ??
        _live[block.id]?.height ??
        _estimate(block, width);
  }

  void _recomputeTops(double width) {
    _topsRecomputes++;
    final n = _blocks.length;
    final tops = List<double>.filled(n, 0);
    var y = 0.0;
    for (var i = 0; i < n; i++) {
      tops[i] = y;
      y += _heightOf(i, width);
      if (i < n - 1) y += _blockSpacing;
    }
    _tops = tops;
    _totalHeight = y;
    _topsDirty = false;
  }

  /// Indices whose [top, top+height] intersects [lo, hi].
  List<int> _indicesInRange(double lo, double hi, double width) {
    final n = _blocks.length;
    if (n == 0 || _tops.length != n) return const [];
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
      if (_tops[i] > hi) break;
      out.add(i);
    }
    return out;
  }

  // --- sliver layout ---

  @override
  void performLayout() {
    final c = constraints;
    assert(
      c.axis == Axis.vertical && c.growthDirection == GrowthDirection.forward,
      'SliverGPUTextBlocks v1 supports vertical, forward-growth viewports '
      'only.',
    );
    _ensureSurface();
    final w = c.crossAxisExtent;
    if (w > 0 && w != _width) {
      _width = w;
      _invalidateForWidth();
    }
    if (_width <= 0 || _blocks.isEmpty) {
      geometry = SliverGeometry.zero;
      return;
    }
    // Only rebuild tops when an input changed (a block laid out, width/DPR,
    // spacing, or the block set) — never on a bare scroll. _invalidateForWidth
    // above and the setters/resets flip _topsDirty; _sync recomputes inline as
    // heights land. The length guard catches the first pass and any reset that
    // emptied _tops. This is the change that takes scroll off the O(n) path.
    if (_topsDirty || _tops.length != _blocks.length) _recomputeTops(_width);

    // Estimate→real height fixups land as a scroll-offset correction: the
    // viewport adjusts its offset by the delta and immediately re-runs our
    // layout, so content on screen does not shift — mid-fling included.
    if (_pendingCorrection != 0) {
      final corr = _pendingCorrection.clamp(-c.scrollOffset, double.infinity);
      _pendingCorrection = 0;
      if (corr.abs() > precisionErrorTolerance) {
        geometry = SliverGeometry(scrollOffsetCorrection: corr);
        return;
      }
    }

    _scrollDelta = c.scrollOffset - _lastScrollOffset;
    _lastScrollOffset = c.scrollOffset;
    _lastViewportH = c.remainingPaintExtent;
    final total = _totalHeight;
    geometry = SliverGeometry(
      scrollExtent: total,
      paintExtent: calculatePaintOffset(c, from: 0, to: total),
      cacheExtent: calculateCacheOffset(c, from: 0, to: total),
      maxPaintExtent: total,
      hasVisualOverflow: total > c.remainingPaintExtent || c.scrollOffset > 0,
    );
    _maybeKickSync();
    _updateWindow(c, total);
  }

  /// The doc-space range the sync loop keeps live: viewport + cache extent,
  /// biased toward the direction of travel while scrolling (lead 2×, trail
  /// ½×) so a fling runs into blocks that already laid out instead of blanks.
  (double, double) _wantRange() {
    final moving = _scrollDelta.abs() > 1.0;
    final down = _scrollDelta >= 0;
    final above = moving ? (down ? 0.5 : 2.0) : 1.0;
    final below = moving ? (down ? 2.0 : 0.5) : 1.0;
    return (
      _lastScrollOffset - _cacheExtent * above,
      _lastScrollOffset + _lastViewportH + _cacheExtent * below,
    );
  }

  /// Start the async layout sync when the wanted window has blocks that are
  /// not live yet (or live blocks that left it). Cheap set check — layout
  /// runs every scroll tick.
  void _maybeKickSync() {
    if (_surface == null) return;
    final (lo, hi) = _wantRange();
    final want = _indicesInRange(lo, hi, _width);
    var need = _live.length > want.length;
    if (!need) {
      for (final i in want) {
        if (!_live.containsKey(_blocks[i].id)) {
          need = true;
          break;
        }
      }
    }
    if (need) unawaited(_sync());
  }

  /// Drop oldest prepared docs until under [_maxPreparedDocs], never
  /// disposing [pin] (the current cache window).
  Future<void> _trimPrepared(Set<String> pin) async {
    final max = _maxPreparedDocs;
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
      await _controller._disposeDoc(victim);
    }
  }

  void _touchPrepared(String id) {
    _preparedLru.remove(id);
    _preparedLru[id] = null;
  }

  /// Cap on blocks per [GPUTextWorker.syncDocs] batch. Small enough that a
  /// width/scroll change mid-pass abandons at most one batch of stale-width
  /// work; large enough that a whole viewport usually lands in one round trip.
  static const int _maxSyncBatch = 16;

  // Single-flight port of _GPUTextBlocksViewState._syncWindow, minus every
  // fling workaround: no jumpTo (corrections go through sliver geometry), no
  // deferred setState (extent flows through geometry), no idle listeners.
  //
  // Missing blocks are synced in prioritized BATCHES (one syncDocs round trip
  // each — prepare-if-needed + reflow together) instead of two awaits per
  // block: a window of N blocks costs ceil(N/_maxSyncBatch) round trips, so a
  // fling or resize catches up a batch at a time instead of a block at a time.
  Future<void> _sync() async {
    if (_busy) {
      _pending = true;
      return;
    }
    _busy = true;
    final gen = _gen;
    try {
      do {
        _pending = false;
        if (_disposed || gen != _gen || _controller._disposed) return;
        final width = _width;
        final surface = _surface;
        if (surface == null || width <= 0) return;
        final dpr = _dpr;

        _recomputeTops(width);
        final offset = _lastScrollOffset;
        final (lo, hi) = _wantRange();
        final wantIdx = _indicesInRange(lo, hi, width);
        final want = {for (final i in wantIdx) _blocks[i].id};

        final liveBefore = _live.length;
        _live.removeWhere((id, _) => !want.contains(id));
        // Selection state follows the window, EXCEPT blocks holding a live
        // selection — their highlight must survive scroll-away-and-back.
        _selections.removeWhere((id, sel) {
          if (want.contains(id) || sel.hasSelection) return false;
          sel.repaint.removeListener(markNeedsPaint);
          sel.dispose();
          return true;
        });
        var changed = _live.length != liveBefore;

        for (final chunk in _syncChunks(wantIdx, offset, _lastViewportH)) {
          if (_disposed || gen != _gen || _controller._disposed) return;
          // Width/scroll changed mid-pass — abandon stale-width reflows and
          // let the outer loop restart with the latest geometry.
          if (_pending) break;
          final docsToSync = <GPUTextDocument>[];
          final syncIdx = <int>[];
          for (final i in chunk) {
            final doc = _blocks[i];
            _touchPrepared(doc.id);
            // A live block still needs a round trip when selection was
            // enabled after it synced (no geometry request answered yet).
            // Attempted, not "has geometry": a declined request (doc over
            // the geometry budget) must not re-sync forever.
            final needsGeometry =
                _selectionEnabled &&
                !(_selections[doc.id]?.geometryAttempted ?? false);
            if (!_live.containsKey(doc.id) || needsGeometry) {
              docsToSync.add(doc);
              syncIdx.add(i);
            }
          }
          if (docsToSync.isEmpty) continue;

          final geometryRequested = _selectionEnabled;
          final result = await _controller._syncDocs(
            docsToSync,
            width,
            dpr: dpr,
            includeGeometry: geometryRequested,
          );
          if (result == null) return; // controller disposed mid-flight
          if (_disposed || gen != _gen || _controller._disposed) return;
          // Upload BEFORE the batch's drawables go live: the controller has
          // already folded the reply's atlas tail into its mirror, so fresh
          // instances never rasterize against a texture missing their rows.
          _ensureAtlasFor(result.atlasGeneration);
          final pipeline = _controller._pipeline;
          if (pipeline == null) return;

          for (var k = 0; k < docsToSync.length; k++) {
            final d = result.results[k];
            if (d == null) continue; // unpreparable (fonts missing) — skip
            _applyBlockDrawable(
              docsToSync[k],
              syncIdx[k],
              d,
              offset,
              pipeline,
              gen,
              geometryRequested: geometryRequested,
            );
          }
          changed = true;
          // Re-rasterize per batch so the strip fills in progressively (and
          // pending corrections apply promptly), instead of waiting for the
          // whole window.
          _drawableGen++;
          if (attached) markNeedsLayout();
        }

        if (_pending) continue; // restart with latest width/scroll

        await _trimPrepared(want);
        if (_disposed || gen != _gen || _controller._disposed) return;

        if (changed) {
          _drawableGen++;
          if (attached) markNeedsLayout();
        }
      } while (_pending && !_disposed && gen == _gen && !_controller._disposed);
    } on StateError catch (e) {
      // Worker/controller torn down while we awaited (route pop). Swallow.
      if (!e.message.contains('disposed')) rethrow;
    } finally {
      _busy = false;
      // A kick that arrived while this run was ABORTING (gen bumped by a
      // width change / blocks swap mid-await) exits through a return above,
      // never re-reading _pending — and with nothing else scheduling layout
      // the sync would stay stalled until the next scroll. Restart it here.
      if (_pending && !_disposed && !_controller._disposed) {
        unawaited(_sync());
      }
    }
  }

  /// The want-window sliced into sync batches, most-urgent first: blocks
  /// intersecting the viewport, then the cache region ahead of travel
  /// (nearest first), then behind. The old document-order walk spent a
  /// fling's first round trips on the blocks the user was scrolling AWAY
  /// from.
  List<List<int>> _syncChunks(List<int> wantIdx, double offset, double viewH) {
    final visible = <int>[];
    final above = <int>[];
    final below = <int>[];
    for (final i in wantIdx) {
      if (_tops[i] > offset + viewH) {
        below.add(i);
      } else if (_tops[i] + _heightOf(i, _width) < offset) {
        above.add(i);
      } else {
        visible.add(i);
      }
    }
    final aboveNear = above.reversed.toList(); // nearest-to-viewport first
    final ordered = _scrollDelta < 0
        ? [...visible, ...aboveNear, ...below]
        : [...visible, ...below, ...aboveNear];
    return [
      for (var s = 0; s < ordered.length; s += _maxSyncBatch)
        ordered.sublist(s, math.min(s + _maxSyncBatch, ordered.length)),
    ];
  }

  /// Upload the controller's atlas mirror when this render object's texture
  /// is behind [needGen] (the generation a fresh batch's instances reference).
  /// The mirror is kept current by the controller's worker wrappers, so this
  /// is pure GPU upload — no isolate round trip. A no-op while the mirror is
  /// behind (only after a mirror reset; the next reply heals it).
  void _ensureAtlasFor(int needGen) {
    if (_atlasTextures != null && _atlasGenOnGpu >= needGen) return;
    if (_controller._atlasGeneration < needGen) return;
    final curves = _controller._atlas.curves;
    if (curves.isEmpty) return;
    _atlasTextures = uploadAtlasTextures(
      gpu.gpuContext,
      curves,
      _controller._atlas.rows,
    );
    _atlasGenOnGpu = _controller._atlasGeneration;
  }

  /// Upload one block's fresh drawable into [_live] and record its height —
  /// the per-block body of the sync loop. [offset] is the scroll offset the
  /// pass was planned at (for the above-viewport correction test).
  void _applyBlockDrawable(
    GPUTextDocument doc,
    int i,
    GPUTextInstances d,
    double offset,
    GPUTextPipeline pipeline,
    int gen, {
    bool geometryRequested = false,
  }) {
    final width = _width;
    final instances = d.materialize();
    final count = instances.length ~/ floatsPerInstance;

    final oldH = _heightOf(i, width);
    final newH = d.height;
    if (oldH != newH && _tops[i] + oldH <= offset) {
      // Fully above the viewport: correct on next layout pass.
      _pendingCorrection += newH - oldH;
    }
    // Same reply as the instances: selection rects always describe the
    // pixels the strip will show.
    if (_selectionEnabled || _selections.containsKey(doc.id)) {
      _selectionFor(doc.id).applyDrawable(
        d.materializeGeometry(),
        Size(d.width, d.height),
        requested: geometryRequested,
      );
    }
    final firstTime = !_heights.containsKey(doc.id);
    _heights[doc.id] = newH;
    if (firstTime) {
      _laidOut++;
      // Notify per block so HUDs fill progressively while the window is
      // still syncing (the box view only reported per pass).
      onLaidOutChanged?.call(_laidOut, _blocks.length);
    }

    final colorStubs = [
      for (final s in d.colorGlyphStubs) _ColorStub.fromTransfer(s),
    ];
    if (colorStubs.isNotEmpty) {
      unawaited(
        _controller._ensureColorStubs(colorStubs).then((stubsChanged) {
          if (_disposed ||
              gen != _gen ||
              _controller._disposed ||
              !stubsChanged) {
            return;
          }
          final live = _live[doc.id];
          if (live == null) return;
          final color = _colorInstancesFromStubs(
            colorStubs,
            _controller.colorAtlas,
          );
          final colorCount = color.length ~/ floatsPerColorInstance;
          _live[doc.id] = _BlockDrawable(
            instances: live.instances,
            count: live.count,
            height: live.height,
            placeholders: live.placeholders,
            colorInstances: colorCount == 0
                ? null
                : pipeline.uploadColorInstances(color),
            colorCount: colorCount,
            colorStubs: colorStubs,
          );
          _drawableGen++;
          if (attached) markNeedsLayout();
        }),
      );
    }
    final color = _colorInstancesFromStubs(colorStubs, _controller.colorAtlas);
    final colorCount = color.length ~/ floatsPerColorInstance;

    _live[doc.id] = _BlockDrawable(
      instances: count == 0 ? null : pipeline.uploadInstances(instances),
      count: count,
      height: newH,
      placeholders: d.placeholders,
      colorInstances: colorCount == 0
          ? null
          : pipeline.uploadColorInstances(color),
      colorCount: colorCount,
      colorStubs: colorStubs,
    );
    // Height change shifts later tops — recompute before the next block so
    // the correction test above stays exact within a batch.
    _recomputeTops(width);
  }

  /// Composite the live blocks intersecting the viewport cache region into
  /// one strip (same caching scheme as [RenderSliverGPUText._updateWindow]).
  void _updateWindow(SliverConstraints c, double total) {
    final surface = _surface;
    final textures = _atlasTextures;
    if (surface == null || textures == null) return;
    final visTop = c.scrollOffset.clamp(0.0, total);
    final visBottom = (c.scrollOffset + c.remainingPaintExtent).clamp(
      visTop,
      total,
    );
    final constraintsChanged =
        c.crossAxisExtent != _rasterCrossAxis ||
        c.viewportMainAxisExtent != _rasterViewportExtent;
    final fresh =
        !constraintsChanged &&
        _windowGen == _drawableGen &&
        _windowDpr == _dpr &&
        _windowWidth == _width;
    if (fresh &&
        _window != null &&
        _windowTop <= visTop &&
        _windowTop + _windowHeight >= visBottom) {
      return;
    }
    // Stale-keep: when some visible block is not live yet (a width/DPR
    // invalidation cleared _live, or a fling outran the sync), re-rastering
    // now would swap a complete strip for one with holes — 1-2 blank frames
    // per worker round trip. While the CURRENT image is complete and still
    // covers most of the visible range, keep painting it; the sync loop
    // marks us for layout the moment fresh blocks land. Once coverage drops
    // below half a viewport (deep jump), holes beat nothing — fall through.
    if (_window != null && _windowComplete) {
      var missingVisible = false;
      for (final i in _indicesInRange(visTop, visBottom, _width)) {
        if (!_live.containsKey(_blocks[i].id)) {
          missingVisible = true;
          break;
        }
      }
      if (missingVisible) {
        final overlap =
            math.min(_windowTop + _windowHeight, visBottom) -
            math.max(_windowTop, visTop);
        if (overlap >= 0.5 * (visBottom - visTop)) {
          _windowIsStale = true;
          return;
        }
      }
    }
    var top = (c.scrollOffset + c.cacheOrigin).clamp(0.0, total);
    var bottom = (top + c.remainingCacheExtent).clamp(top, total);
    final maxH = _maxDevicePx / math.max(_dpr, 0.001);
    if (bottom - top > maxH) {
      final slack = math.max(0.0, maxH - (visBottom - visTop)) / 2;
      top = math.max(0.0, visTop - slack);
      bottom = math.min(total, top + maxH);
      top = math.max(0.0, bottom - maxH);
    }
    if (bottom - top <= 0) {
      _window = null;
      _windowComplete = false;
      _windowIsStale = false;
      return;
    }

    final visible = _indicesInRange(top, bottom, _width);
    var complete = true;
    final draws =
        <
          ({
            AtlasTextures? textures,
            gpu.DeviceBuffer? instances,
            int count,
            double camX,
            double camY,
            gpu.DeviceBuffer? colorInstances,
            int colorCount,
          })
        >[];
    for (final i in visible) {
      final drawable = _live[_blocks[i].id];
      if (drawable == null) {
        complete = false; // hole — this strip must keep re-rastering
        continue;
      }
      final hasCoverage = drawable.instances != null && drawable.count > 0;
      final hasColor =
          drawable.colorInstances != null && drawable.colorCount > 0;
      if (!hasCoverage && !hasColor) continue;
      draws.add((
        textures: textures,
        instances: drawable.instances,
        count: hasCoverage ? drawable.count : 0,
        camX: 0,
        camY: (_tops[i] - top) * _dpr,
        colorInstances: drawable.colorInstances,
        colorCount: hasColor ? drawable.colorCount : 0,
      ));
    }

    _windowTop = top;
    _windowHeight = bottom - top;
    _windowWidth = _width;
    _windowDpr = _dpr;
    _windowGen = _drawableGen;
    _windowComplete = complete;
    _windowIsStale = false;
    _rasterCrossAxis = c.crossAxisExtent;
    _rasterViewportExtent = c.viewportMainAxisExtent;
    _window = surface.renderComposite(
      devW: (_width * _dpr).round().clamp(1, _maxDevicePx.round()),
      devH: (_windowHeight * _dpr).round().clamp(1, _maxDevicePx.round()),
      dpr: _dpr,
      clear: vm.Vector4(0, 0, 0, 0), // background painted by the canvas
      colorAtlas: _controller.colorAtlasTexture(),
      draws: draws,
    );
    _windowSrc = surface.contentRect;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final g = geometry;
    if (g == null || g.paintExtent <= 0) return;
    final c = constraints;
    final w = c.crossAxisExtent;
    final h = g.paintExtent;
    _clipHandle.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & Size(w, h),
      (context, offset) {
        if (_background.a > 0) {
          context.canvas.drawRect(
            offset & Size(w, h),
            Paint()..color = _background,
          );
        }
        // Selection highlight + handle LeaderLayers, under the glyph strip
        // (transparent composite clear).
        if (_selections.isNotEmpty) {
          for (final entry in _selections.entries) {
            final sel = entry.value;
            if (sel.fragments.isEmpty) continue;
            final top = _topOfId(entry.key);
            final so = offset + Offset(0, top - c.scrollOffset);
            // Cull to the painted band (block-local space).
            final cull = Rect.fromLTWH(0, c.scrollOffset - top, w, h);
            for (final f in sel.fragments) {
              f.paint(context, so, cull: cull);
            }
          }
        }
        final img = _window;
        if (img != null) {
          // context.canvas is re-fetched here, NOT cached above the fragment
          // pass: a fragment that pushed handle LeaderLayers ended the
          // previous picture recording, killing any earlier canvas reference
          // (native-peer StateError on next use).
          context.canvas.drawImageRect(
            img,
            _windowSrc, // strip sub-rect: the backing texture is bucketed
            Rect.fromLTWH(
              offset.dx,
              offset.dy + (_windowTop - c.scrollOffset),
              _windowWidth,
              _windowHeight,
            ),
            _imagePaint,
          );
        }
      },
      oldLayer: _clipHandle.layer,
    );
  }
}

/// [runs] with each measured placeholder's provisional box replaced by its
/// real size (and the baseline recomputed for baseline-aligned ones). Shared
/// by [_GPUTextViewState] (offstage measure) and [RenderSliverGPUText]
/// (in-layout measure).
List<GPUInlineSpec> _resolvePlaceholderSpecSizes(
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
          baselineOffset: spec.alignment == InlinePlaceholderAlignment.baseline
              ? sizes[spec.index]!.height
              : spec.baselineOffset,
        )
      else
        spec,
  ];
}
