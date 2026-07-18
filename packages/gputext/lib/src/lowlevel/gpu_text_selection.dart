// Selection support for the worker-backed views (SelectionArea /
// SelectableRegion integration).
//
// Layout lives on the worker isolate; the caret/hit-test geometry the shared
// SelectableTextFragment needs arrives in one of two shapes:
//
//  * Single-document views (GPUTextView, SliverGPUText): a BANDED geometry —
//    the source text is derived on THIS isolate from the doc specs
//    (flattenSpecSource), an O(lines) LineTable rides each reflow reply
//    (requested only while a registrar is attached, never declined), and
//    per-line glyph detail is prefetched for the band the paint pass reports
//    via [noteVisibleBand]. Selection works at any document size; uncached
//    lines degrade to proportional interpolation until their band lands.
//  * Block views (GPUTextBlocksView, SliverGPUTextBlocks): the full
//    SnapshotParagraphGeometry riding each reflow reply, as before — every
//    block is paragraph-sized, so O(block) snapshots stay small.
//
// [_DocSelection] owns whichever geometry + the fragments for one document
// and implements the fragment host; coordinates delegate to a doc-space host
// render box ([_RenderSelectionHost]) mounted in the view's hit layer, so
// internal scrolling is absorbed by the existing viewport transforms and
// fragment values stay scroll-invariant.
//
// The highlight paints UNDER the GPU glyph image via [_SelectionUnderlay],
// a window layer positioned exactly like the span-chrome painters (the GPU
// clear is transparent, so under-image rects show through).
//
// Registrar bookkeeping is DEFERRED to a post-frame callback: adding a
// selectable synchronously from build/update marks the SelectableRegion
// dirty mid-build and can trip its '!_dirty' assert (the GPURichText
// font-load-rebuild bug).

part of 'gpu_text_view.dart';

class _RepaintBump extends ChangeNotifier {
  void bump() => notifyListeners();
}

bool _sameOffsets(Int32List a, Int32List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Per-document selection state for a worker-backed view: the geometry
/// (either a full snapshot for paragraph-sized block docs, or a banded
/// line-table + detail-cache for single documents of ANY size), the
/// [SelectableTextFragment]s (split at placeholder offsets, like
/// RenderGPUParagraph), registrar add/remove, and the fragment-host
/// plumbing.
class _DocSelection implements GPUSelectableTextHost {
  /// Bumped whenever the highlight/handles must repaint; the underlay
  /// listens.
  final _RepaintBump repaint = _RepaintBump();

  SelectionRegistrar? _registrar;
  Color? _color;
  TextDirection _direction = TextDirection.ltr;
  VoidCallback? _onEnabledChanged;

  RenderObject? _hostRender;
  Offset Function()? _hostShift;
  Size Function()? _hostSize;
  SnapshotParagraphGeometry? _geometry;
  Size _docSize = Size.zero;

  // --- banded (single-document) mode ---
  // The main isolate owns the source text (derived from the doc specs), the
  // worker ships an O(lines) table per reflow, and per-line glyph detail is
  // prefetched for the band the underlay actually paints. No size budget.
  String? _sourceText;
  Int32List _sourceHoles = Int32List(0);
  BandedDocGeometry? _banded;
  Future<TransferableTypedData?> Function(
    int generation,
    int firstLine,
    int lastLine,
  )?
  _bandFetcher;
  bool _bandInFlight = false;
  bool _detailKickScheduled = false;
  Rect? _visibleBand; // doc space, noted by the paint pass

  /// Generation whose band fetch came back null (the worker moved on):
  /// stop asking until a fresh table arrives — without this a stale view
  /// (e.g. two views sharing one doc id) re-issues a doomed fetch on every
  /// paint tick.
  int _deadBandGeneration = -1;

  /// True when a table-less reflow superseded the held table (resize
  /// streaming with nothing selected): geometry answers from the old
  /// positions until [_onTableStale] gets a fresh one.
  bool _tableStale = false;

  /// Host hook: whether NO newer reflow is pending (detail fetched mid-storm
  /// is wasted). Null means always quiet.
  bool Function()? _reflowQuiet;

  /// Host hook: the held table went stale and the layout is quiet — issue a
  /// table-carrying reflow.
  VoidCallback? _onTableStale;

  /// Wire the host's reflow-state hooks (see [_scheduleDetail]).
  void setReflowHooks({bool Function()? quiet, VoidCallback? onTableStale}) {
    _reflowQuiet = quiet;
    _onTableStale = onTableStale;
  }

  /// Extra lines fetched around the visible band on each side, so small
  /// scrolls answer from cache before the next prefetch lands.
  static const int _bandPadLines = 24;

  /// Hard ceiling on one detail fetch. The visible band is a few dozen
  /// lines; anything past this is a mis-reported band (or an enormous
  /// viewport) and must never turn into a whole-document pen walk on the
  /// worker.
  static const int _maxBandLines = 512;

  List<SelectableTextFragment> _fragments = const [];
  bool _registered = false;
  bool _addScheduled = false;
  bool _disposed = false;

  /// Whether a geometry-carrying reply was applied while enabled — with OR
  /// without a snapshot. Blocks views re-request geometry for live blocks
  /// until this flips, and must NOT retry forever when the worker declined
  /// (document over the selection-geometry budget). Reset on disable so a
  /// re-enable retries once.
  bool geometryAttempted = false;

  /// Selection is on while a registrar is attached — gates the worker's
  /// `includeGeometry` so disabled views pay nothing.
  bool get enabled => _registrar != null;

  /// Whether banded geometry exists at all (possibly stale against the
  /// on-screen layout — the views' settle refresh replaces it).
  bool get hasLineTable => _banded != null;

  List<SelectableTextFragment> get fragments => _fragments;

  /// True when any fragment holds a selection edge (blocks views pin such
  /// docs through window eviction so the highlight survives scroll-back).
  bool get hasSelection {
    for (final f in _fragments) {
      if (f.hasSelection) return true;
    }
    return false;
  }

  // --- GPUSelectableTextHost ---

  @override
  ParagraphGeometryBase? get selectionGeometry => _banded ?? _geometry;

  @override
  TextDirection get selectionTextDirection => _direction;

  @override
  Size get selectionSize {
    final override = _hostSize;
    if (override != null) return override();
    final host = _hostRender;
    if (host is RenderBox && host.hasSize) return host.size;
    return _docSize;
  }

  @override
  Matrix4 selectionTransformTo(RenderObject? ancestor) {
    final host = _hostRender;
    if (host == null || !host.attached) return Matrix4.identity();
    final m = host.getTransformTo(ancestor);
    final shift = _hostShift?.call() ?? Offset.zero;
    if (shift != Offset.zero) {
      m.translateByDouble(shift.dx, shift.dy, 0, 1);
    }
    return m;
  }

  @override
  bool get selectionPaintReady => !_disposed && _hostRender != null;

  @override
  void markSelectionPaintDirty() => repaint.bump();

  @override
  Color? get selectionHighlightColor => _color;

  /// Called from the host widget's build — the context sits below the view's
  /// internal Scrollable, so a SelectionArea registrar arrives wrapped with
  /// that scrollable's drag-autoscroll handling.
  void configure({
    required SelectionRegistrar? registrar,
    required Color? color,
    required TextDirection direction,
    VoidCallback? onEnabledChanged,
  }) {
    _onEnabledChanged = onEnabledChanged;
    _direction = direction;
    if (color != _color) {
      _color = color;
      repaint.bump();
    }
    if (!identical(registrar, _registrar)) {
      final wasEnabled = enabled;
      _unregister();
      _registrar = registrar;
      if (registrar == null) {
        _dropFragments();
        _geometry = null;
        _banded = null;
        geometryAttempted = false;
        repaint.bump();
      } else {
        // Banded mode has the source before any geometry: fragments can
        // register immediately and degrade until the line table lands.
        if (_sourceText != null && _fragments.isEmpty) {
          _rebuildFragmentRanges(_sourceText!.length, _sourceHoles);
        }
        _scheduleRegister();
      }
      if (wasEnabled != enabled) _onEnabledChanged?.call();
    }
  }

  /// Banded mode: the document's selection source (text with one '￼' per
  /// placeholder, derived from the specs with `flattenSpecSource`). Must be
  /// set before [applyLineTable]; changing it drops the old table and
  /// fragments — the next reflow brings a matching table.
  void setSource(String text, Int32List placeholderOffsets) {
    if (_disposed) return;
    if (text == _sourceText && _sameOffsets(placeholderOffsets, _sourceHoles)) {
      return;
    }
    _sourceText = text;
    _sourceHoles = placeholderOffsets;
    _banded = null;
    _unregister();
    _dropFragments();
    if (enabled) {
      _rebuildFragmentRanges(text.length, placeholderOffsets);
      _scheduleRegister();
    }
    repaint.bump();
  }

  /// Banded mode: how to fetch per-line detail from the worker (the view
  /// wires this to `GPUTextWorker.fetchLineBand` for its doc id).
  void setBandFetcher(
    Future<TransferableTypedData?> Function(
      int generation,
      int firstLine,
      int lastLine,
    )?
    fetcher,
  ) {
    _bandFetcher = fetcher;
  }

  /// Apply the line table that rode a drawable (null when the request didn't
  /// ask for one). Same reply as the instances, so table rows always match
  /// the pixels on screen. [requested] is whether a table was actually asked
  /// for, captured at SEND time — only then does a null count as an answered
  /// attempt rather than a pre-enable reply racing the registrar.
  void applyLineTable(
    LineTable? table,
    int generation,
    Size docSize, {
    bool requested = true,
  }) {
    if (_disposed) return;
    _docSize = docSize;
    if (!enabled) {
      if (_banded != null || _fragments.isNotEmpty) {
        _unregister();
        _dropFragments();
        _banded = null;
        repaint.bump();
      }
      return;
    }
    if (requested) geometryAttempted = true;
    final text = _sourceText;
    assert(
      text != null || table == null,
      'setSource must run before applyLineTable',
    );
    if (table == null || text == null) {
      if (!requested && _banded != null) {
        // A deliberately table-less reflow (resize streaming with nothing
        // selected): keep the previous table — positions are stale until
        // the settle refresh lands, but a mouse-down in between still
        // anchors near the right offset instead of at 0.
        _tableStale = true;
        _scheduleDetail(); // the first quiet frame requests the refresh
        return;
      }
      // Reply requested before selection was enabled — the enable re-kick
      // brings a table next. Fragments degrade to source-only geometry.
      _banded = null;
      for (final f in _fragments) {
        f.didChangeParagraphLayout();
      }
      repaint.bump();
      return;
    }
    assert(
      table.lineCount == 0 || table.srcEnd[table.lineCount - 1] <= text.length,
      'line table source range exceeds the spec-derived text — '
      'worker and main source texts diverged',
    );
    _tableStale = false;
    _banded = BandedDocGeometry(
      plainText: text,
      placeholderOffsets: _sourceHoles,
      table: table,
      generation: generation,
    );
    if (_fragments.isEmpty) {
      _rebuildFragmentRanges(text.length, _sourceHoles);
      _scheduleRegister();
    } else {
      for (final f in _fragments) {
        f.didChangeParagraphLayout();
      }
    }
    repaint.bump();
    _scheduleDetail(); // refresh the visible band against the new layout
  }

  /// The doc-space band the host is currently painting — the paint pass
  /// calls this every frame, which is exactly the cadence detail prefetch
  /// should follow.
  void noteVisibleBand(Rect band) {
    _visibleBand = band;
    if (_banded != null && enabled) _scheduleDetail();
  }

  /// Detail kicks run POST-FRAME, gated on [_reflowQuiet]: during a
  /// continuous resize a new reflow request lands within the same frame, so
  /// the check naturally skips — a band fetched against a generation that's
  /// already superseded would only wedge extra placement jobs between the
  /// worker's queued reflows. Selection stays line-accurate from the held
  /// table during the storm; the first quiet frame fetches detail (and asks
  /// for a fresh table when the held one went stale).
  void _scheduleDetail() {
    if (_detailKickScheduled || _disposed) return;
    _detailKickScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _detailKickScheduled = false;
      if (_disposed) return;
      if (_reflowQuiet?.call() == false) return; // storm: next apply re-kicks
      if (_tableStale) {
        // Resize streaming skipped tables while nothing was selected — the
        // held geometry no longer matches the pixels. Ask the host for a
        // table-carrying reflow instead of fetching bands against it.
        _onTableStale?.call();
        return;
      }
      unawaited(_ensureDetail());
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  Future<void> _ensureDetail() async {
    if (_disposed || _bandInFlight) return;
    final g = _banded;
    final band = _visibleBand;
    final fetcher = _bandFetcher;
    if (g == null || band == null || fetcher == null || g.lineCount == 0) {
      return;
    }
    if (g.generation == _deadBandGeneration) return;
    var first = g.firstLineCandidateForY(band.top) - _bandPadLines;
    var last = g.lineForY(band.bottom) + 1 + _bandPadLines;
    first = first.clamp(0, g.lineCount);
    last = last.clamp(first, math.min(first + _maxBandLines, g.lineCount));
    if (first >= last || g.hasDetailFor(first, last)) return;
    _bandInFlight = true;
    TransferableTypedData? reply;
    try {
      reply = await fetcher(g.generation, first, last);
    } on StateError {
      reply = null; // worker torn down mid-await
    } finally {
      _bandInFlight = false;
    }
    if (_disposed || !identical(g, _banded)) return;
    if (reply == null) {
      // The worker has a newer layout (or none): stop until the next
      // reflow's applyLineTable brings a fresh table and re-kicks.
      _deadBandGeneration = g.generation;
      return;
    }
    g.applyDetailBand(reply.materialize());
    // Refresh fragment caches; with an active selection the highlight/handles
    // may move (proportional → exact), so repaint. A merge with nothing
    // selected is a silent cache warm.
    for (final f in _fragments) {
      f.didChangeParagraphLayout();
    }
    if (hasSelection) repaint.bump();
    // The band may have moved while the fetch flew; covered bands no-op.
    _scheduleDetail();
  }

  /// Anchor fragment coordinates to [host]: paragraph-local → host-local is
  /// [shift] (e.g. `(0, -scrollOffset)` on a sliver, a block's top in a
  /// shared host), then [host]'s own paint transforms take over. [size]
  /// overrides the paragraph box when the host isn't a doc-sized RenderBox.
  void bindHost(
    RenderObject host, {
    Offset Function()? shift,
    Size Function()? size,
  }) {
    _hostRender = host;
    _hostShift = shift;
    _hostSize = size;
    _scheduleRegister();
  }

  void unbindHost(RenderObject host) {
    if (!identical(_hostRender, host)) return;
    _hostRender = null;
    _hostShift = null;
    _hostSize = null;
    // Offstage/unmounted views must not participate in select-all.
    _unregister();
  }

  /// Apply the geometry that rode a drawable (null when the request didn't
  /// ask for one). Same reply as the instances, so rects always match the
  /// pixels on screen. [requested] is whether geometry was actually asked
  /// for, captured at SEND time: only then does a null snapshot count as an
  /// answered attempt (worker declined — over budget) rather than a
  /// pre-enable reply racing the registrar.
  void applyDrawable(
    SnapshotParagraphGeometry? geometry,
    Size docSize, {
    bool requested = true,
  }) {
    if (_disposed) return;
    _docSize = docSize;
    if (!enabled) {
      if (_geometry != null || _fragments.isNotEmpty) {
        _unregister();
        _dropFragments();
        _geometry = null;
        repaint.bump();
      }
      return;
    }
    if (requested) geometryAttempted = true;
    final old = _geometry;
    _geometry = geometry;
    if (geometry == null) {
      // Either a reply requested before selection was enabled (the enable
      // re-kick brings a snapshot next) or the worker declined (document
      // over the geometry budget). Fragments degrade to empty geometry.
      for (final f in _fragments) {
        f.didChangeParagraphLayout();
      }
      repaint.bump();
      return;
    }
    final sameShape =
        old != null &&
        old.plainText == geometry.plainText &&
        _sameOffsets(old.placeholderOffsets, geometry.placeholderOffsets);
    if (sameShape && _fragments.isNotEmpty) {
      for (final f in _fragments) {
        f.didChangeParagraphLayout();
      }
    } else {
      _rebuildFragments(geometry);
    }
    repaint.bump();
  }

  /// Split fragments at placeholder offsets, mirroring
  /// RenderGPUParagraph._createFragments — placeholder widgets are real
  /// widgets under the same SelectionArea and register their own selectables.
  void _rebuildFragments(SnapshotParagraphGeometry g) {
    _unregister();
    _dropFragments();
    _rebuildFragmentRanges(g.plainText.length, g.placeholderOffsets);
    _scheduleRegister();
  }

  void _rebuildFragmentRanges(int textLength, Int32List holes) {
    final ranges = <TextRange>[];
    var fragStart = 0;
    for (final off in holes) {
      if (off > fragStart) ranges.add(TextRange(start: fragStart, end: off));
      fragStart = off + 1; // the placeholder's '￼'
    }
    if (textLength > fragStart) {
      ranges.add(TextRange(start: fragStart, end: textLength));
    }
    _fragments = [for (final r in ranges) SelectableTextFragment(this, r)];
  }

  void _dropFragments() {
    for (final f in _fragments) {
      f.dispose();
    }
    _fragments = const [];
  }

  void _scheduleRegister() {
    if (_disposed || _registered || _addScheduled) return;
    if (_registrar == null || _fragments.isEmpty || _hostRender == null) {
      return;
    }
    _addScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _addScheduled = false;
      if (_disposed || _registered) return;
      final r = _registrar;
      if (r == null || _fragments.isEmpty) return;
      if (_hostRender?.attached != true) return;
      for (final f in _fragments) {
        r.add(f);
      }
      _registered = true;
    });
    // The apply path runs in async continuations — make sure a frame exists
    // for the callback to ride on.
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _unregister() {
    if (!_registered) return;
    _registered = false;
    final r = _registrar;
    if (r == null) return;
    for (final f in _fragments) {
      r.remove(f);
    }
  }

  void dispose() {
    if (_disposed) return;
    _unregister();
    _dropFragments();
    _disposed = true;
    repaint.dispose();
  }
}

/// Reads the effective registrar/color/direction below the view's internal
/// scrollable and feeds them to [selection]; renders the doc-space host box.
class _SelectionHost extends StatelessWidget {
  const _SelectionHost({
    required this.selection,
    this.registrarOverride,
    this.colorOverride,
    this.onEnabledChanged,
  });

  final _DocSelection selection;
  final SelectionRegistrar? registrarOverride;
  final Color? colorOverride;
  final VoidCallback? onEnabledChanged;

  @override
  Widget build(BuildContext context) {
    final registrar = registrarOverride ?? SelectionContainer.maybeOf(context);
    final color = registrar == null
        ? colorOverride
        : colorOverride ??
              DefaultSelectionStyle.of(context).selectionColor ??
              DefaultSelectionStyle.defaultColor;
    selection.configure(
      registrar: registrar,
      color: color,
      direction: Directionality.maybeOf(context) ?? TextDirection.ltr,
      onEnabledChanged: onEnabledChanged,
    );
    return _RawSelectionHost(selection: selection);
  }
}

/// Multi-document variant of [_SelectionHost]: reads the effective
/// registrar/color/direction below the internal scrollable and hands them to
/// [onConfigure] (the blocks view fans them out to its per-block
/// selections); renders [child] (the shared host render object).
class _SelectionScope extends StatelessWidget {
  const _SelectionScope({
    this.registrarOverride,
    this.colorOverride,
    required this.onConfigure,
    required this.child,
  });

  final SelectionRegistrar? registrarOverride;
  final Color? colorOverride;
  final void Function(
    SelectionRegistrar? registrar,
    Color? color,
    TextDirection direction,
  )
  onConfigure;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final registrar = registrarOverride ?? SelectionContainer.maybeOf(context);
    final color = registrar == null
        ? colorOverride
        : colorOverride ??
              DefaultSelectionStyle.of(context).selectionColor ??
              DefaultSelectionStyle.defaultColor;
    onConfigure(
      registrar,
      color,
      Directionality.maybeOf(context) ?? TextDirection.ltr,
    );
    return child;
  }
}

/// The blocks view's shared selection host: one content-sized box inside the
/// internal scrollable that anchors EVERY block's fragments (each shifted to
/// its block top) and paints their highlights — it sits under the GPU image
/// (bottom Stack child), so with the transparent composite clear the rects
/// show through beneath the glyphs.
class _BlocksSelectionHost extends LeafRenderObjectWidget {
  const _BlocksSelectionHost({required this.state});

  final _GPUTextBlocksViewState state;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBlocksSelectionHost(state);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderBlocksSelectionHost renderObject,
  ) => renderObject.state = state;
}

class _RenderBlocksSelectionHost extends RenderBox {
  _RenderBlocksSelectionHost(this._state);

  _GPUTextBlocksViewState _state;
  set state(_GPUTextBlocksViewState value) {
    if (identical(value, _state)) return;
    _state._unbindSelectionHost(this);
    _state = value;
    if (attached) _state._bindSelectionHost(this);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _state._bindSelectionHost(this);
  }

  @override
  void detach() {
    _state._unbindSelectionHost(this);
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    // Content-sized box inside the scroll view: cull each block's highlight
    // rects to the visible viewport band (block-local space).
    final scroll = _state._scroll.hasClients ? _state._scroll.offset : 0.0;
    final viewportH = _state._viewportH;
    for (final entry in _state._selections.entries) {
      final sel = entry.value;
      if (sel.fragments.isEmpty) continue;
      final top = _state._topOfId(entry.key);
      final o = offset + Offset(0, top);
      final cull = viewportH > 0
          ? Rect.fromLTWH(0, scroll - top, _state._contentWidth, viewportH)
          : null;
      for (final f in sel.fragments) {
        f.paint(context, o, cull: cull);
      }
    }
  }
}

class _RawSelectionHost extends LeafRenderObjectWidget {
  const _RawSelectionHost({required this.selection});

  final _DocSelection selection;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSelectionHost(selection);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSelectionHost renderObject,
  ) => renderObject.selection = selection;
}

/// Invisible box filling the document layout space (the hit layer's slot in
/// all three mounting modes), so `getTransformTo` maps paragraph-local
/// coordinates through the view's own viewport transforms.
class _RenderSelectionHost extends RenderBox {
  _RenderSelectionHost(this._selection);

  _DocSelection _selection;
  set selection(_DocSelection value) {
    if (identical(value, _selection)) return;
    _selection.unbindHost(this);
    _selection = value;
    if (attached) _selection.bindHost(this);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _selection.bindHost(this);
  }

  @override
  void detach() {
    _selection.unbindHost(this);
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => false;
}

/// Paints every fragment's highlight rects + handle LeaderLayers inside the
/// GPU paint window, under the glyph image. [origin] maps paragraph-local to
/// window coordinates (reads live scroll pixels at paint time, exactly like
/// the span-chrome painters).
class _SelectionUnderlay extends LeafRenderObjectWidget {
  const _SelectionUnderlay({
    required this.selections,
    required this.repaint,
    required this.origin,
    this.band,
  });

  final List<_DocSelection> Function() selections;
  final Listenable repaint;
  final Offset Function(_DocSelection selection) origin;

  /// Doc-space visible band override. When the underlay's own box is NOT
  /// the visible window (the content-sized view mounts it at full document
  /// height), this supplies the real on-screen slice — without it a huge
  /// document would report its ENTIRE height as the "visible" band and
  /// detail prefetch would degenerate to a whole-document fetch. Null (or a
  /// null return) falls back to the box itself.
  final Rect? Function()? band;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSelectionUnderlay(selections, repaint, origin, band);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSelectionUnderlay renderObject,
  ) {
    renderObject
      ..selections = selections
      ..origin = origin
      ..band = band
      ..repaint = repaint;
  }
}

class _RenderSelectionUnderlay extends RenderBox {
  _RenderSelectionUnderlay(
    this._selections,
    this._repaint,
    this.origin,
    this.band,
  );

  List<_DocSelection> Function() _selections;
  set selections(List<_DocSelection> Function() value) {
    _selections = value;
    markNeedsPaint();
  }

  Offset Function(_DocSelection selection) origin;
  Rect? Function()? band;

  Listenable _repaint;
  set repaint(Listenable value) {
    if (identical(value, _repaint)) return;
    if (attached) {
      _repaint.removeListener(markNeedsPaint);
      value.addListener(markNeedsPaint);
    }
    _repaint = value;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _repaint.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _repaint.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final selection in _selections()) {
      final org = origin(selection);
      final o = offset + org;
      // The visible window in paragraph space: the band override when the
      // box is bigger than the screen (content-sized layer), else the box.
      final cull = band?.call() ?? (Offset.zero & size).shift(-org);
      // Every paint pass tells the selection what band is on screen — the
      // banded geometry prefetches per-line detail for exactly that band.
      selection.noteVisibleBand(cull);
      final fragments = selection.fragments;
      if (fragments.isEmpty) continue;
      for (final f in fragments) {
        f.paint(context, o, cull: cull);
      }
    }
  }
}
