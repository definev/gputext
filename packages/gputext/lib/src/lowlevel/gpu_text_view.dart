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
import 'dart:isolate' show TransferableTypedData;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show precisionErrorTolerance, ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart'
    show
        MouseTrackerAnnotation,
        PointerEnterEventListener,
        PointerExitEventListener;
import 'package:flutter/widgets.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import '../atlas.dart' show AtlasTextures, uploadAtlasTextures;
import '../bands.dart' show Float32Buf, Uint32Buf;
import '../color_bitmap.dart' show BitmapGlyph;
import '../engine/color_atlas.dart' show SharedColorAtlas, ColorAtlasEntry;
import '../engine/color_atlas_texture.dart' show ColorAtlasTexture;
import '../engine/pipeline.dart' show GPUTextPipeline, FrameUniforms;
import '../layout.dart' show floatsPerInstance, floatsPerColorInstance;
import '../paragraph.dart'
    show
        PlaceholderBox,
        InlinePlaceholderAlignment,
        LineBreakConfig,
        DecorationLine,
        BackgroundRect,
        HitSpanBox,
        InlineDecorationStyle,
        ParagraphGeometryBase,
        SnapshotParagraphGeometry,
        LineTable,
        BandedDocGeometry;
import '../widgets/selectable_fragment.dart'
    show GPUSelectableTextHost, SelectableTextFragment;
import 'gpu_text_worker.dart';
import 'text_span_specs.dart' show flattenInlineSpan, PlaceholderSizer;

part 'gpu_text_selection.dart';
part 'gpu_text_sliver.dart';

// A single GPU texture can't hold a whole long document (Metal caps at 16384px,
// mobile GPUs lower). We lay out the FULL document in doc space but only ever
// rasterize a viewport-sized window of it — see [GPUTextView].
const double _maxDevicePx = 8192;

// Glyph ink can extend past the layout box — italic overhang at the wrap
// margin, negative bearings ('j', 'f') at line start — and Flutter text
// PAINTS that ink outside its box rather than clipping it. The composite
// window is padded by this much logical width on each side so margin ink
// survives the raster viewport, and [_RenderGpuWindowImage.paint] draws the
// padded image shifted left by the same amount, letting the overhang show
// beside the box exactly like ordinary text ink. Vertical edges stay exact:
// they are scroll-viewport boundaries, where clipping is correct.
const double _inkPadPx = 16;

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

  /// The laid-out content size in logical px. The width is the widest line
  /// (it can exceed the wrap width when an unbreakable run overflows); the
  /// height is the full document height.
  final Size size;

  /// Wall-clock time of the worker round-trip for this reflow, in ms.
  final double reflowMs;
}

/// A positioned unit in a [GPUTextBlocksView]: either a [GPUTextDocument]
/// (GPU-rendered text, laid out on the worker) or a [GPUWidgetBlock] (an
/// arbitrary Flutter widget — image, code card, table, divider). Both carry a
/// stable [id] that keys the view's per-block height cache and virtualization.
///
/// Sealed: the two subtypes above are the only kinds of block.
sealed class GPUBlock {
  String get id;
}

/// A block whose content is an arbitrary Flutter [Widget] rather than GPU text.
/// Interleave these with [GPUTextDocument]s in [GPUTextBlocksView.blocks] to
/// render real media — figures, code cards, tables, dividers — between text
/// paragraphs, virtualized alongside the text blocks.
///
/// Height: pass [height] for a fixed-height block (no measurement); otherwise
/// the view measures the built widget once it scrolls into the cache window,
/// starting from [estimatedHeight] (or a default) until the real height lands.
///
/// Widget blocks are opaque to GPU text selection — a drag-select spanning one
/// will not highlight it, since it registers no selectables. Keep content that
/// must be selectable in a [GPUTextDocument].
@immutable
class GPUWidgetBlock implements GPUBlock {
  const GPUWidgetBlock({
    required this.id,
    required this.builder,
    this.height,
    this.estimatedHeight,
  });

  @override
  final String id;

  /// Builds the media widget. Invoked with the view's build context, and again
  /// whenever the [GPUTextBlocksView.blocks] list is replaced.
  final WidgetBuilder builder;

  /// Fixed logical height. When set, the view reserves exactly this and never
  /// measures the child.
  final double? height;

  /// Provisional logical height used before the child is measured. Ignored
  /// when [height] is set.
  final double? estimatedHeight;
}

/// An immutable description of a document to lay out on the worker.
///
/// [id] is the cache key for the expensive shape+prepare phase: reuse the same
/// id across width reflows of the *same content*, and use a NEW id whenever the
/// content changes. Reusing an id for different [runs] is a bug — the worker
/// keeps serving the first prepare it saw for that id.
///
/// EXCEPTION — [streaming] documents: the id stays FIXED while the content
/// grows (an LLM response, a log tail). Every content change routes through
/// [GPUTextWorker.syncStream], which re-shapes only the hard-break paragraph
/// slices that changed (see docs/appendable-prepare.md). Call
/// [GPUTextViewController.finishStream] when the stream completes; the
/// document then behaves as an ordinary prepared doc under the same id.
/// Streaming documents do not support widget placeholders.
@immutable
class GPUTextDocument implements GPUBlock {
  const GPUTextDocument({
    required this.id,
    required this.runs,
    this.lineHeight = 1.3,
    this.style = const GPUTextLayoutStyle(lineHeight: 1.3),
    this.lineBreak,
    this.language,
    this.fallbackFontIds = const [],
    this.emojiFontId,
    this.placeholderWidgets = const {},
    this.autoSizedPlaceholders = const {},
    this.hitTargets = const {},
    this.streaming = false,
  }) : assert(
         !streaming || placeholderWidgets.length == 0,
         'streaming documents do not support widget placeholders',
       );

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
  ///
  /// Interactive [TextSpan]s (recognizer / hover) get a [GPUTextRunSpec.hitTag]
  /// and are recorded in [hitTargets] for [GPUTextView] tap dispatch.
  factory GPUTextDocument.rich(
    String id,
    InlineSpan span, {
    required String Function(TextStyle style) fontIdResolver,
    TextStyle? baseStyle,
    double defaultFontSizePx = 16,
    List<double> defaultColor = const [0, 0, 0, 1],
    TextScaler textScaler = TextScaler.noScaling,
    TextDirection textDirection = TextDirection.ltr,
    Locale? locale,
    PlaceholderSizer? placeholderSize,
    double lineHeight = 1.3,
    GPUTextLayoutStyle? style,
    LineBreakConfig? lineBreak,
    List<String> fallbackFontIds = const [],
    String? emojiFontId,
    bool streaming = false,
  }) {
    final widgets = <int, Widget>{};
    final autoSized = <int>{};
    final hits = <String, TextSpan>{};
    final runs = flattenInlineSpan(
      span,
      fontIdResolver: fontIdResolver,
      baseStyle: baseStyle,
      defaultFontSizePx: defaultFontSizePx,
      defaultColor: defaultColor,
      textScaler: textScaler,
      textDirection: textDirection,
      locale: locale,
      placeholderSize: placeholderSize,
      onWidget: (index, child, explicitSize) {
        widgets[index] = child;
        if (explicitSize == null) autoSized.add(index); // measure this one
      },
      onHitTarget: (tag, s) => hits[tag] = s,
    );
    final resolvedStyle = style ?? GPUTextLayoutStyle(lineHeight: lineHeight);
    return GPUTextDocument(
      id: id,
      runs: runs,
      lineHeight: resolvedStyle.lineHeight,
      style: resolvedStyle,
      lineBreak: lineBreak,
      language: locale?.toLanguageTag(),
      fallbackFontIds: fallbackFontIds,
      emojiFontId: emojiFontId,
      placeholderWidgets: widgets,
      autoSizedPlaceholders: autoSized,
      hitTargets: hits,
      streaming: streaming,
    );
  }

  @override
  final String id;

  /// The flattened runs (+ size-only placeholders) to shape. Build these with
  /// [flattenInlineSpan] / [GPUTextDocument.rich], or hand-assemble
  /// [GPUTextRunSpec]/[GPUPlaceholderSpec] values.
  final List<GPUInlineSpec> runs;

  /// Shorthand for [style.lineHeight] (kept for existing call sites).
  final double lineHeight;

  /// Paragraph layout policy applied on every reflow.
  final GPUTextLayoutStyle style;

  /// Opt-in hyphenation / SA-script segmentation; baked in at prepare time.
  final LineBreakConfig? lineBreak;

  /// Default OpenType language for runs that omit [GPUTextRunSpec.language].
  final String? language;

  /// Ordered fallback font ids for scripts the runs' own fonts don't cover
  /// (CJK, Arabic, Hebrew, …); resolved per-rune by glyph coverage.
  final List<String> fallbackFontIds;

  /// Optional COLR or color-bitmap (sbix/CBDT) emoji font id. COLR glyphs
  /// render as coloured coverage layers on the worker; bitmap glyphs ship PNG
  /// stubs to the main isolate for the color atlas. Prefer a COLR face when
  /// available. Platform [Text] emoji fallback is not supported here — use
  /// [GPURichText] for hybrid platform delegation.
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

  /// Interactive [TextSpan]s keyed by [GPUTextRunSpec.hitTag]. Populated by
  /// [GPUTextDocument.rich]; main-isolate only.
  final Map<String, TextSpan> hitTargets;

  /// Streaming (append-mostly) document: the content is EXPECTED to change
  /// under this [id]. [GPUTextView] routes every content change through
  /// [GPUTextWorker.syncStream] (paragraph-sliced shaping reuse) instead of
  /// the prepare cache, and reflows whenever a non-identical document object
  /// arrives — so rebuild the view with a fresh document exactly once per
  /// content tick.
  final bool streaming;

  /// Whether any run carries shapeable text. A streaming document syncs only
  /// once this is true (the worker rejects empty content).
  bool get hasShapeableContent {
    for (final r in runs) {
      if (r is GPUTextRunSpec && r.text.isNotEmpty) return true;
    }
    return false;
  }

  /// Effective reflow style: [style] with [lineHeight] applied when the caller
  /// only set the shorthand.
  GPUTextLayoutStyle get effectiveStyle {
    if (style.lineHeight == lineHeight) return style;
    return style.copyWith(lineHeight: lineHeight);
  }
}

/// Main-isolate mirror of the worker's append-only shared glyph atlas,
/// reconstructed from the tails each reply ships (see
/// [GPUTextWorker.reflowDoc] `sinceCurves`). One per controller, so every view
/// on the worker shares a single copy: textures upload from here, replies
/// carry only what this mirror doesn't hold yet (usually nothing), and a view
/// that (re)attaches gets the atlas without a worker round trip.
class _AtlasMirror {
  var _curves = Float32Buf();
  var _rows = Uint32Buf();

  /// Worker [SharedGlyphAtlas.generation] this mirror is complete up to, or
  /// -1 before the first payload.
  int generation = -1;

  /// [SharedGlyphAtlas.structureGeneration] the held data was fetched under.
  int structure = 0;

  /// Set when a payload couldn't be applied (structure changed mid-flight, or
  /// a gap); forces the next request to fetch the full snapshot.
  bool needsFull = false;

  int get curveLen => _curves.length;
  int get rowLen => _rows.length;
  Float32List get curves => _curves.view;
  Uint32List get rows => _rows.view;

  /// Fold one reply's atlas payload in. The prefix below [curveBase]/[rowBase]
  /// is bit-identical to what we hold (append-only atlas + FIFO replies), so
  /// only the part beyond our length is appended; overlapping tails from
  /// concurrent in-flight requests fold in cleanly. Advances [generation] only
  /// when the mirror really is complete up to [generation] afterwards.
  void apply({
    required Float32List curves,
    required Uint32List rows,
    required int curveBase,
    required int rowBase,
    required int generation,
    required int structure,
  }) {
    if (structure != this.structure || needsFull) {
      if (curveBase != 0 || rowBase != 0) {
        // Held prefix is invalid and this payload is only a tail — unusable.
        needsFull = true;
        return;
      }
      _curves = Float32Buf(math.max(curves.length, 1));
      _rows = Uint32Buf(math.max(rows.length, 1));
      this.structure = structure;
      this.generation = -1;
      needsFull = false;
    }
    if (curveBase > _curves.length || rowBase > _rows.length) {
      needsFull = true; // a gap we can't bridge (should not happen: FIFO)
      return;
    }
    _curves.addRange(curves, _curves.length - curveBase, curves.length);
    _rows.addRange(rows, _rows.length - rowBase, rows.length);
    if (generation > this.generation) this.generation = generation;
  }
}

/// Owns the background layout isolate and the fonts registered on it.
///
/// Font bytes are parsed on the worker only — the main isolate never touches
/// them, so there is no per-view font cost. Create one (typically in
/// `initState`), register your fonts, share it across every [GPUTextView], and
/// [dispose] it when the owning widget goes away.
///
/// Color-bitmap (sbix/CBDT) emoji PNGs are decoded on this isolate into
/// [colorAtlas] after each reflow that returns stubs.
class GPUTextViewController {
  GPUTextViewController._(this._worker);

  final GPUTextWorker _worker;
  final Set<String> _prepared = {};
  final Map<String, Future<bool>> _preparing = {};
  // Total _disposeDoc calls — lets _syncDocs detect evictions that raced its
  // batch (see the warm-marking guard there).
  int _disposeCount = 0;
  bool _disposed = false;

  // A GPU render pipeline (compiled shaders) shared across every surface driven
  // by this controller — created once, lazily, on the main isolate. Sharing it
  // matters for [GPUTextBlocksView], which composites many block drawables into
  // one viewport surface and must NOT recompile the pipeline. Null when
  // flutter_gpu is unavailable.
  GPUTextPipeline? _pipeline;
  bool _pipelineTried = false;

  /// Main-isolate color-bitmap atlas (sbix/CBDT emoji). Shared by every view
  /// driven by this controller.
  final SharedColorAtlas colorAtlas = SharedColorAtlas();
  final ColorAtlasTexture _colorAtlasTex = ColorAtlasTexture();

  /// CPU-side copy of the worker's shared glyph atlas, kept current by the
  /// [_reflowDoc]/[_syncDocs] wrappers. Views upload textures from here (never
  /// from reply payloads) whenever their uploaded generation falls behind
  /// [_atlasGeneration].
  final _AtlasMirror _atlas = _AtlasMirror();

  int get _atlasGeneration => _atlas.generation;

  /// Apply one reply's atlas payload to [_atlas]. Consumes the reply's
  /// single-use curves/rows transferables.
  void _applyAtlasPayload({
    required Float32List? curves,
    required Uint32List? rows,
    required int curveBase,
    required int rowBase,
    required int generation,
    required int structure,
  }) {
    if (curves == null || rows == null) return;
    _atlas.apply(
      curves: curves,
      rows: rows,
      curveBase: curveBase,
      rowBase: rowBase,
      generation: generation,
      structure: structure,
    );
  }

  /// Reflow [id] on the worker, requesting only the atlas tail this controller
  /// doesn't hold yet (usually empty) and folding it into [_atlas] before
  /// returning. The reply's curves/rows are consumed here — read the atlas
  /// from the mirror, not the returned drawable.
  Future<GPUTextInstances> _reflowDoc(
    String id,
    double width, {
    required GPUTextLayoutStyle style,
    required double dpr,
    bool includeGeometry = false,
    bool includeLineTable = false,
  }) async {
    final full = _atlas.needsFull;
    final d = await _worker.reflowDoc(
      id,
      width,
      style: style,
      includeAtlas: true,
      dpr: dpr,
      sinceCurves: full ? 0 : _atlas.curveLen,
      sinceRows: full ? 0 : _atlas.rowLen,
      sinceStructure: full ? -1 : _atlas.structure,
      includeGeometry: includeGeometry,
      includeLineTable: includeLineTable,
    );
    _applyAtlasPayload(
      curves: d.materializeCurves(),
      rows: d.materializeRows(),
      curveBase: d.curveBase,
      rowBase: d.rowBase,
      generation: d.atlasGeneration,
      structure: d.atlasStructure,
    );
    return d;
  }

  /// Streaming sync for a [GPUTextDocument.streaming] document: prepare-if-
  /// changed (paragraph-sliced, see [GPUTextWorker.syncStream]) + reflow +
  /// emit in one round trip, with the same atlas-mirror folding as
  /// [_reflowDoc].
  Future<GPUTextInstances> _syncStreamDoc(
    GPUTextDocument doc,
    double width, {
    required double dpr,
    bool includeLineTable = false,
  }) async {
    final full = _atlas.needsFull;
    final d = await _worker.syncStream(
      doc.id,
      doc.runs,
      width: width,
      style: doc.effectiveStyle,
      fallbackFontIds: doc.fallbackFontIds,
      emojiFontId: doc.emojiFontId,
      lineBreak: doc.lineBreak,
      language: doc.language,
      includeAtlas: true,
      dpr: dpr,
      sinceCurves: full ? 0 : _atlas.curveLen,
      sinceRows: full ? 0 : _atlas.rowLen,
      sinceStructure: full ? -1 : _atlas.structure,
      includeLineTable: includeLineTable,
    );
    _applyAtlasPayload(
      curves: d.materializeCurves(),
      rows: d.materializeRows(),
      curveBase: d.curveBase,
      rowBase: d.rowBase,
      generation: d.atlasGeneration,
      structure: d.atlasStructure,
    );
    return d;
  }

  /// Finish a [GPUTextDocument.streaming] stream: drops the worker's
  /// per-slice shaping cache. The prepared document SURVIVES under the same
  /// id — it reflows like any ordinary doc, so hardening a completed stream
  /// costs no re-prepare. Free it later with [disposeDoc]. No-op for ids
  /// that never streamed.
  Future<void> finishStream(String id) {
    if (_disposed) return Future<void>.value();
    // The streamed content is now an ordinary prepared doc under this id;
    // mark it warm so a later same-id GPUTextDocument skips the re-prepare.
    _prepared.add(id);
    return _worker.finishStream(id);
  }

  /// Free the worker-side prepared document (and any streaming state) for
  /// [id]. Views using [id] afterwards re-prepare on their next reflow.
  Future<void> disposeDoc(String id) {
    if (_disposed) return Future<void>.value();
    return _disposeDoc(id);
  }

  /// Fetch per-line selection detail for [id]'s layout [generation] (see
  /// [GPUTextWorker.fetchLineBand]); null after dispose or when the worker
  /// has moved to a newer layout.
  Future<TransferableTypedData?> _fetchLineBand(
    String id,
    int generation,
    int firstLine,
    int lastLine,
  ) {
    if (_disposed) return Future<TransferableTypedData?>.value(null);
    return _worker.fetchLineBand(id, generation, firstLine, lastLine);
  }

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

  /// Current color-atlas GPU texture (null while empty). Uploads on generation
  /// change.
  gpu.Texture? colorAtlasTexture() {
    if (colorAtlas.isEmpty) return null;
    return _colorAtlasTex.prepare(gpu.gpuContext, colorAtlas);
  }

  /// Decode/pack any not-yet-resident stubs. Returns true when the atlas
  /// generation changed (caller should rebuild color instances + re-render).
  ///
  /// The worker ships each strike's PNG once; a metrics-only stub whose key is
  /// not resident (e.g. the byte-carrying reply raced a concurrent view, or a
  /// future eviction dropped it) recovers the bytes with one batched
  /// [GPUTextWorker.fetchColorPngs] round trip.
  Future<bool> _ensureColorStubs(List<_ColorStub> stubs) async {
    if (stubs.isEmpty) return false;
    final before = colorAtlas.generation;
    final missing = <String>{
      for (final s in stubs)
        if (s.pngBytes == null && colorAtlas.lookupKey(s.cacheKey) == null)
          s.cacheKey,
    };
    var fetched = const <String, Uint8List>{};
    if (missing.isNotEmpty && !_disposed) {
      try {
        fetched = await _worker.fetchColorPngs(missing.toList());
      } on StateError {
        return colorAtlas.generation != before; // worker torn down mid-await
      }
    }
    for (final s in stubs) {
      if (colorAtlas.lookupKey(s.cacheKey) != null) continue;
      final bytes = s.pngBytes ?? fetched[s.cacheKey];
      if (bytes == null) continue;
      await colorAtlas.ensureBytes(
        s.cacheKey,
        BitmapGlyph(
          bytes: bytes,
          format: 'png ',
          ppem: s.strikePpem,
          width: 0,
          height: 0,
          bearingX: s.bearingX,
          bearingY: s.bearingY,
          advance: 0,
        ),
      );
    }
    return colorAtlas.generation != before;
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
    LineBreakConfig? lineBreak,
    String? language,
  }) {
    if (_disposed) return Future<bool>.value(false);
    if (_prepared.contains(id)) return Future<bool>.value(false);
    return _preparing.putIfAbsent(id, () async {
      try {
        if (_disposed) return false;
        await _worker.prepareDoc(
          id,
          runs,
          fallbackFontIds: fallbackFontIds,
          emojiFontId: emojiFontId,
          lineBreak: lineBreak,
          language: language,
        );
        // A concurrent [_disposeDoc] may have evicted this id mid-flight; its
        // dispose lands on the worker after our prepare, so don't mark warm.
        if (_disposed || !_preparing.containsKey(id)) return false;
        _prepared.add(id);
        return true;
      } finally {
        // Always unregister — a failed prepare must not be cached forever
        // (the font may be registered after the first attempt).
        _preparing.remove(id);
      }
    });
  }

  /// Batch prepare-if-needed + reflow of [docs] at [width] in one worker round
  /// trip (see [GPUTextWorker.syncDocs]). Runs ship only for ids this
  /// controller has not marked prepared; ids with a non-null result are marked
  /// prepared afterwards. Returns null when the controller is disposed.
  Future<GPUTextSyncResult?> _syncDocs(
    List<GPUTextDocument> docs,
    double width, {
    required double dpr,
    GPUTextLayoutStyle Function(GPUTextDocument doc)? styleOf,
    bool includeGeometry = false,
  }) async {
    if (_disposed) return null;
    final entries = [
      for (final doc in docs)
        GPUTextSyncEntry(
          id: doc.id,
          style: styleOf == null ? doc.effectiveStyle : styleOf(doc),
          runs: _prepared.contains(doc.id) ? null : doc.runs,
          fallbackFontIds: doc.fallbackFontIds,
          emojiFontId: doc.emojiFontId,
          lineBreak: doc.lineBreak,
          language: doc.language,
          includeGeometry: includeGeometry,
        ),
    ];
    final disposesBefore = _disposeCount;
    // Always carry the atlas: with the since-prefix it's just the tail the
    // mirror doesn't hold yet, so a batch that banded new glyphs lands with
    // the rows its instances reference (no stale-atlas frame).
    final full = _atlas.needsFull;
    final result = await _worker.syncDocs(
      entries,
      width,
      includeAtlas: true,
      dpr: dpr,
      sinceCurves: full ? 0 : _atlas.curveLen,
      sinceRows: full ? 0 : _atlas.rowLen,
      sinceStructure: full ? -1 : _atlas.structure,
    );
    if (_disposed) return null;
    _applyAtlasPayload(
      curves: result.materializeCurves(),
      rows: result.materializeRows(),
      curveBase: result.curveBase,
      rowBase: result.rowBase,
      generation: result.atlasGeneration,
      structure: result.atlasStructure,
    );
    // Non-null ⇒ the doc exists on the worker now (freshly prepared or
    // already warm). Same race as _ensurePrepared: a _disposeDoc issued while
    // we awaited lands on the worker AFTER our batch's prepare, so marking
    // warm would strand the id (later batches would omit its runs). Skip
    // marking when any dispose ran — resending runs is safe, stranding isn't.
    if (_disposeCount == disposesBefore) {
      for (var i = 0; i < docs.length; i++) {
        if (result.results[i] != null) _prepared.add(docs[i].id);
      }
    }
    return result;
  }

  /// Evict the document prepared under [id] from the worker, freeing its shaped
  /// paragraph. The shared glyph atlas is retained. Re-prepared on next use.
  /// Drives [GPUTextBlocksView]'s LRU eviction of far-off-screen blocks.
  /// No-op if the controller (and its worker) is already disposed.
  Future<void> _disposeDoc(String id) {
    if (_disposed) return Future<void>.value();
    _disposeCount++;
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

/// Materialized color-bitmap stub kept on the main isolate for atlas pack +
/// instance rebuild after async decode.
class _ColorStub {
  const _ColorStub({
    required this.cacheKey,
    required this.pngBytes,
    required this.strikePpem,
    required this.bearingX,
    required this.bearingY,
    required this.penX,
    required this.baselineY,
    required this.fontSizePx,
    required this.alpha,
  });

  factory _ColorStub.fromTransfer(GPUColorGlyphStub s) => _ColorStub(
    cacheKey: s.cacheKey,
    pngBytes: s.materializePng(),
    strikePpem: s.strikePpem,
    bearingX: s.bearingX,
    bearingY: s.bearingY,
    penX: s.penX,
    baselineY: s.baselineY,
    fontSizePx: s.fontSizePx,
    alpha: s.alpha,
  );

  final String cacheKey;

  /// Null for a metrics-only stub — the strike's bytes shipped with an
  /// earlier reply (recoverable via [GPUTextWorker.fetchColorPngs]).
  final Uint8List? pngBytes;
  final int strikePpem;
  final double bearingX;
  final double bearingY;
  final double penX;
  final double baselineY;
  final double fontSizePx;
  final double alpha;
}

/// Build the color-pipeline instance buffer from packed atlas entries.
Float32List _colorInstancesFromStubs(
  List<_ColorStub> stubs,
  SharedColorAtlas atlas,
) {
  if (stubs.isEmpty) return Float32List(0);
  final out = Float32List(stubs.length * floatsPerColorInstance);
  var len = 0;
  for (final stub in stubs) {
    final ColorAtlasEntry? place = atlas.lookupKey(stub.cacheKey);
    if (place == null) continue;
    final s = stub.fontSizePx / place.ppem;
    final x0 = stub.penX + place.bearingX * s;
    final x1 = stub.penX + (place.bearingX + place.width) * s;
    final yTop = stub.baselineY - place.bearingY * s;
    final yBot = stub.baselineY - (place.bearingY - place.height) * s;
    final a = stub.alpha;
    final o = len;
    out[o] = x0;
    out[o + 1] = yTop;
    out[o + 2] = x1;
    out[o + 3] = yBot;
    out[o + 4] = place.u0;
    out[o + 5] = place.v0;
    out[o + 6] = place.u1;
    out[o + 7] = place.v1;
    out[o + 8] = a;
    out[o + 9] = a;
    out[o + 10] = a;
    out[o + 11] = a;
    len = o + floatsPerColorInstance;
  }
  if (len == 0) return Float32List(0);
  if (len == out.length) return out;
  return Float32List.sublistView(out, 0, len);
}

/// A pure (non-scrolling), GPU-rendered rich-text widget whose layout runs on
/// a background isolate (via [controller]). It wraps [document] to the width
/// it is given, re-wraps off-thread on resize, and sizes its height to the
/// laid-out content — like [GPURichText], but with worker layout.
///
/// The view never scrolls itself: put it in a scrollable ([SingleChildScrollView],
/// …) when the content may outgrow the screen. The content height arrives
/// asynchronously, so the widget reports height 0 until the first reflow
/// lands. Inside an ancestor [Scrollable] only the visible slice (plus one
/// viewport of overscan) is ever rasterized, synced from the ancestor's
/// [ScrollPosition] without setState — GPU memory stays constant regardless
/// of document length. The window is stationary in document space while
/// scrolling stays inside its overscan band (those ticks just translate the
/// layer — zero GPU work) and recenters with one re-raster when the visible
/// edge nears a band edge. [SliverGPUText] remains the better fit for very
/// long documents (its window is handed down by the sliver protocol instead
/// of reconstructed from listeners).
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
    this.placeholderBuilder,
    this.fallbackBuilder,
    this.onMetrics,
    this.onSpanTap,
    this.selectionRegistrar,
    this.selectionColor,
  });

  /// The shared worker owner. Fonts referenced by [document] must be registered
  /// on it first.
  final GPUTextViewController controller;

  /// Selection registrar. Like [GPURichText], a null registrar falls back to
  /// the enclosing [SelectionContainer], so a view inside a [SelectionArea]
  /// participates without extra plumbing. While a registrar is attached,
  /// reflows additionally ship selection geometry from the worker.
  final SelectionRegistrar? selectionRegistrar;

  /// Highlight color; defaults to [DefaultSelectionStyle.of] when selection
  /// is active.
  final Color? selectionColor;

  /// What to lay out. Swap in a new instance to change content; keep [document]
  /// otherwise identical (same `id`) across resizes to reuse the prepare cache.
  final GPUTextDocument document;

  /// Inset around the text. The wrap width is the view's width minus the
  /// horizontal padding.
  final EdgeInsets padding;

  /// Fill colour the glyphs are rasterized over (the coverage AA composites
  /// against it). Defaults to opaque white.
  final Color background;

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

  /// Invoked when the user taps a run that carries a [GPUTextRunSpec.hitTag].
  /// [source] is the tag string (and [document.hitTargets] may map it to a
  /// [TextSpan]). Recognizer taps on mapped spans are also dispatched.
  final void Function(String hitTag, TextSpan? span)? onSpanTap;

  @override
  State<GPUTextView> createState() => _GPUTextViewState();
}

class _GPUTextViewState extends State<GPUTextView> {
  _GpuTextSurface? _surface;
  bool _initDone = false;

  // Bumped when the uploaded drawable changes so [_GpuWindowImage] re-rasters
  // in paint (no post-frame / ValueNotifier for the window texture).
  int _rasterEpoch = 0;

  // Reflow sampling: every request bumps [_reflowEpoch] and sends to the
  // worker. Overlapping reflows for the same doc collapse there (see
  // [GPUTextWorker.reflowDoc]). Replies apply MONOTONICALLY: any result newer
  // than the screen ([_appliedReflowEpoch]) lands, even when a newer request
  // is already in flight — requiring epoch == _reflowEpoch froze the view at
  // the pre-drag layout for the whole of a continuous resize (a new request
  // started every frame, so every arriving result was already "stale").
  int _reflowEpoch = 0;
  int _appliedReflowEpoch = 0;
  // Atlas-mirror generation currently uploaded to this surface (-1 = none).
  int _atlasGenOnGpu = -1;

  // Live geometry, logical px.
  double _contentWidth = 0; // wrap width from the last layout pass
  double _viewportH = 0; // GPU window height (<< layout height in slice mode)
  double _paintTop = 0; // GPU window Y in local coords (ancestor-scroll slice)
  double _dpr = 1;
  bool _clipWarned = false; // one-shot debug hint when content is clipped
  final GlobalKey _paintKey = GlobalKey();
  // True while the view is inside an ancestor Scrollable (unbounded height):
  // the GPU window is the ancestor's visible slice, synced from its
  // ScrollPosition. Derived in build from the incoming constraints.
  bool _sliceMode = false;
  ScrollPosition? _ancestorPosition;
  // Scroll offset where [_paintKey] top meets the ancestor viewport top.
  // Seeded post-layout via transform; scroll ticks use live pixels + this
  // (transform is stale inside the ScrollPosition listener).
  double? _ancestorLeading;
  // Drives the Positioned GPU window under ancestor scroll. Updated WITHOUT
  // setState — setState mid-fling cancels ballistic scroll and was jumping
  // the parent scrollable back to 0. [_SliceNotifier.setSilent] primes
  // geometry during build (no notify); scroll updates use [value].
  final _SliceNotifier _paintSlice = _SliceNotifier((top: 0.0, height: 0.0));
  // Metrics deferred while the ancestor Scrollable is flinging (parent
  // onMetrics→setState remeasures extent and yanks the thumb toward center).
  GPUTextMetrics? _pendingMetrics;

  // The dimensions the currently-uploaded drawable / window image was rendered
  // for. The display is sized to THESE, not the live values above: on the async
  // worker path the live width/height jump the instant the view resizes but the
  // GPU image still holds the previous size, so fitting it to the live box
  // would stretch the stale frame until the reflow lands. See [_renderWidth].
  double _docWidth = 0;
  double _docHeight = 0;

  int _glyphCount = 0;
  int _colorGlyphCount = 0;
  List<_ColorStub> _colorStubs = const [];
  List<PlaceholderBox> _placeholders = const [];
  // Split once per reflow; the scroll-driven AnimatedBuilder repaints every
  // tick and must not re-filter the full decoration list each time.
  List<DecorationLine> _decorationsBelow = const [];
  List<DecorationLine> _decorationsAbove = const [];
  List<BackgroundRect> _backgrounds = const [];
  List<HitSpanBox> _hitBoxes = const [];
  String? _hoverTag; // hitTag currently under the pointer

  // Selection state (fragments + decoded worker geometry); lives on the
  // State so it survives mounting-mode swaps of the host render object.
  final _DocSelection _selection = _DocSelection();
  // Settle refresh for the selection line table after table-less resize
  // streaming (see _reflow's wantTable): set by the selection's stale hook
  // on the first quiet frame, cleared when the table lands.
  bool _tableRefreshDue = false;

  /// Test hook: every selection-highlight rect the underlay would draw
  /// (doc space, pre-cull), across all fragments.
  @visibleForTesting
  List<Rect> get debugSelectionRects => [
    for (final f in _selection.fragments) ...f.value.selectionRects,
  ];

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
    _dpr =
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    _wireSelectionSource();
    // The selection underlay sits behind a RepaintBoundary and does not
    // repaint on scroll — the raster slice is the scroll-following signal,
    // so band it to the detail prefetch here.
    _paintSlice.addListener(_noteSelectionBand);
    _init();
  }

  /// Banded selection: the source text lives on this isolate (derived from
  /// the specs), and per-line detail is fetched from the worker on demand.
  void _wireSelectionSource() {
    final source = flattenSpecSource(widget.document.runs);
    _selection.setSource(source.text, source.placeholderOffsets);
    _selection.setBandFetcher(
      (generation, first, last) => widget.controller._fetchLineBand(
        widget.document.id,
        generation,
        first,
        last,
      ),
    );
    _selection.setReflowHooks(
      quiet: () => _reflowEpoch == _appliedReflowEpoch,
      onTableStale: () {
        if (!mounted || widget.controller._disposed || _tableRefreshDue) {
          return;
        }
        _tableRefreshDue = true;
        _requestReflow();
      },
    );
  }

  /// The doc-space band that is (or is about to be) on screen: the raster
  /// slice in slice mode, else the widget's own (bounded) paint window.
  Rect? _selectionVisibleBand() {
    final w = _renderWidth > 0 ? _renderWidth : _contentWidth;
    if (_sliceMode) {
      final slice = _paintSlice.value;
      if (slice.height <= 0) return null;
      return Rect.fromLTWH(0, slice.top, w, slice.height);
    }
    if (_viewportH <= 0) return null;
    return Rect.fromLTWH(0, _paintTop, w, _viewportH);
  }

  void _noteSelectionBand() {
    final band = _selectionVisibleBand();
    if (band == null) return;
    _selection.noteVisibleBand(band);
    // The underlay records band-limited highlight rects behind a
    // RepaintBoundary; when the raster slice moves (about once per viewport
    // of scroll, hysteresis-gated), lines revealed by the move need their
    // rects recorded — repaint it alongside the slice.
    // Desktop mouse selections push no handle layers, so nothing else
    // repaints the underlay when the slice moves — this bump is the only
    // reliable scroll-follow signal for the highlight.
    if (_selection.hasSelection) _selection.repaint.bump();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sliceMode) _bindAncestorScroll();
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
    if (!identical(widget.controller, old.controller)) {
      // A different controller means a different worker atlas — the uploaded
      // texture (and its generation numbering) belongs to the old one.
      _atlasGenOnGpu = -1;
    }
    // A new document object (content or config change) needs a fresh reflow.
    // Same-id docs reuse the worker's prepare cache; a new id re-prepares — and
    // invalidates the measured placeholder sizes (they belong to the old id).
    if (!identical(widget.document, old.document)) {
      _wireSelectionSource();
      if (widget.document.id != old.document.id) {
        _measuredDocId = null;
        _resolvedRuns = null;
        _measureScheduled = false;
      }
      // Parent rebuilds routinely reconstruct an equivalent document (rich()
      // allocates fresh every build). Same id ⇒ same content by contract, so
      // an equal layout style means the reflow would be byte-identical — skip
      // the worker round-trip. (placeholderWidgets/hitTargets are read live
      // from widget.document at build/event time; no reflow needed for them.)
      // STREAMING docs invert the contract: same id, changing content — every
      // non-identical document object reflows (the worker's paragraph-slice
      // diff makes a no-change sync cheap, but parents should still rebuild
      // once per content tick, not per unrelated setState).
      final equivalent =
          !widget.document.streaming &&
          widget.document.id == old.document.id &&
          widget.document.effectiveStyle == old.document.effectiveStyle;
      if (!equivalent) unawaited(_reflow());
    }
  }

  @override
  void dispose() {
    _unbindAncestorScroll();
    _surface?.dispose();
    _paintSlice.dispose();
    _selection.dispose();
    super.dispose();
  }

  void _bindAncestorScroll() {
    // Vertical only: the slice-window math below is in vertical document
    // space. The nearest scrollable can be a horizontal one (e.g. a code
    // panel's horizontal SingleChildScrollView) whose offsets would produce
    // a nonsense paint window.
    final next = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (identical(next, _ancestorPosition)) return;
    final old = _ancestorPosition;
    old?.removeListener(_onAncestorScroll);
    old?.isScrollingNotifier.removeListener(_onScrollingChanged);
    _ancestorPosition = next;
    _ancestorLeading = null;
    next?.addListener(_onAncestorScroll);
    next?.isScrollingNotifier.addListener(_onScrollingChanged);
    // Metrics parked against the OLD position would strand — its idle
    // transition can no longer reach us. Deliver once this build settles.
    if (_pendingMetrics != null &&
        !(next?.isScrollingNotifier.value ?? false)) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            !(_ancestorPosition?.isScrollingNotifier.value ?? false)) {
          _deliverPendingMetrics();
        }
      });
    }
  }

  void _unbindAncestorScroll() {
    _ancestorPosition?.removeListener(_onAncestorScroll);
    _ancestorPosition?.isScrollingNotifier.removeListener(_onScrollingChanged);
    _ancestorPosition = null;
    _ancestorLeading = null;
  }

  void _onAncestorScroll() {
    // Never setState here — it aborts the parent Scrollable's ballistic
    // fling and can correct pixels back to 0 when extent is remeasured.
    // Prefer live pixels + cached leading (no 1-frame lag). Fall back to a
    // leading refresh when it isn't seeded yet (needs a laid-out transform).
    if (_ancestorLeading == null) _refreshAncestorLeading();
    _syncAncestorPaintSlice();
  }

  /// Fires on every scroll start/stop of the bound ancestor position (bound
  /// for the view's lifetime in [_bindAncestorScroll] — a per-reflow closure
  /// here used to outlive a view disposed mid-fling). Start: re-seed
  /// [_ancestorLeading] while layout is settled, so a sibling that resized
  /// since the last seed doesn't skew the slice math for the whole gesture.
  /// Stop: deliver metrics parked by [_applyDrawable] mid-fling, then
  /// re-seed for whatever that reflow moved.
  ///
  /// isScrollingNotifier can flip INSIDE the ancestor viewport's
  /// performLayout: streamed content changing the scroll extents makes
  /// applyContentDimensions → applyNewDimensions → goBallistic begin a new
  /// activity mid-layout. Everything downstream of the flip may build — the
  /// slice ValueListenableBuilder, the parked-metrics setState — which is
  /// illegal mid-frame ("Build scheduled during frame", then a LayoutBuilder
  /// mutated under the still-laying-out viewport). Defer to after the frame;
  /// the re-run re-reads the notifier so start/stop semantics stay correct.
  void _onScrollingChanged() {
    if (_midFrame) {
      if (_scrollingChangeDeferred) return;
      _scrollingChangeDeferred = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _scrollingChangeDeferred = false;
        if (mounted) _onScrollingChanged();
      });
      return;
    }
    final pos = _ancestorPosition;
    if (pos == null || !mounted) return;
    if (!pos.isScrollingNotifier.value) _deliverPendingMetrics();
    _refreshAncestorLeading();
    _syncAncestorPaintSlice();
  }

  var _scrollingChangeDeferred = false;

  /// Metrics + the extent-applying setState parked while the ancestor was
  /// flinging (see [_applyDrawable]). No-op when nothing is parked.
  void _deliverPendingMetrics() {
    final pending = _pendingMetrics;
    if (pending == null) return;
    _pendingMetrics = null;
    widget.onMetrics?.call(pending);
    if (mounted) setState(() {});
  }

  /// Fraction of the overscan the visible edge may eat into before the
  /// window recenters (one re-raster). Between recenters the window is
  /// STATIONARY in document space — the parent scroll just translates its
  /// layer, so most scroll ticks cost zero GPU work.
  static const double _sliceMarginFrac = 0.5;

  /// Push a new GPU paint window from the ancestor scroll offset. Safe to call
  /// during scroll; only notifies [_paintSlice] listeners (not [setState]).
  /// [_GpuWindowImage] re-rasters in paint when the Positioned size / cam
  /// change — no deferred GPU blit here. Hysteresis: while [_windowCovers]
  /// holds, the published window is kept as-is (no notify, no re-raster).
  /// [force] skips that check — used when a reflow replaced the content, so
  /// the raster is happening anyway and the window should recenter.
  void _syncAncestorPaintSlice({bool force = false}) {
    if (!mounted || !_sliceMode || _docHeight <= 0) return;
    if (_midFrame) {
      // Reached mid-layout (e.g. a pixel correction notifying the ancestor
      // position while its viewport lays out): the transform reads below
      // touch dirty layout, and notifying the slice builder would schedule a
      // build. Re-run once the frame settles — the overscan margin hides the
      // one-frame-late window move.
      if (_sliceSyncDeferred) return;
      _sliceSyncDeferred = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _sliceSyncDeferred = false;
        if (mounted) _syncAncestorPaintSlice(force: force);
      });
      return;
    }
    final vis = _ancestorVisibleRange(_docHeight);
    if (vis == null) return;
    if (!force && _windowCovers(vis, _docHeight)) return;
    final want = _desiredWindow(vis, _docHeight);
    if (want.top == _paintTop &&
        want.height == _viewportH &&
        want == _paintSlice.value) {
      return;
    }
    _paintTop = want.top;
    _viewportH = want.height;
    _paintSlice.value = want;
  }

  var _sliceSyncDeferred = false;

  /// Overscan above/below the visible range, shrunk when the texture cap
  /// can't fit visible + two viewports at the current DPR.
  double _sliceOverscan(({double top, double bottom, double vpH}) vis) {
    final maxH = _maxDevicePx / math.max(_dpr, 0.001);
    final visH = vis.bottom - vis.top;
    return math.min(vis.vpH, math.max(0.0, (maxH - visH) / 2));
  }

  /// Whether the currently published window still covers [vis] with at
  /// least [_sliceMarginFrac] of the overscan to spare on both sides. A
  /// window edge resting on a document edge counts as covered on that side
  /// (there is nothing left to uncover there).
  bool _windowCovers(
    ({double top, double bottom, double vpH}) vis,
    double contentH,
  ) {
    final cur = _paintSlice.value;
    if (cur.height <= 0) return false;
    if (vis.bottom <= vis.top) return false; // fully off-screen → drop
    final margin = _sliceOverscan(vis) * _sliceMarginFrac;
    final curBottom = cur.top + cur.height;
    final topOk = cur.top <= 0 || vis.top - cur.top >= margin;
    final bottomOk = curBottom >= contentH || curBottom - vis.bottom >= margin;
    return topOk && bottomOk;
  }

  /// The window to publish for [vis]: the visible range plus
  /// [_sliceOverscan] above and below (so ballistic flings don't uncover
  /// blank Stack behind the GPU window), clamped to the document and the
  /// texture cap. Fully off-screen → an empty window: a live image would
  /// pin its backing texture out of the surface pool for no benefit.
  ({double top, double height}) _desiredWindow(
    ({double top, double bottom, double vpH}) vis,
    double contentH,
  ) {
    if (vis.bottom <= vis.top) return (top: vis.top, height: 0.0);
    final overscan = _sliceOverscan(vis);
    final maxH = _maxDevicePx / math.max(_dpr, 0.001);
    final top = math.max(0.0, vis.top - overscan);
    var bottom = math.min(contentH, vis.bottom + overscan);
    if (bottom - top > maxH) bottom = top + maxH;
    return (top: top, height: bottom - top);
  }

  /// Post-layout: cache leading = pixels + boxTopInViewport from transform.
  ///
  /// Never mid-frame: transforms are dirty there, and a streamed rebuild may
  /// have DEACTIVATED the keyed element in the same frame — findRenderObject
  /// then asserts ("inactive element"; deactivated elements still count as
  /// mounted until the end-of-frame finalize, so the mounted check below
  /// cannot catch them). Mid-frame callers defer and re-run post-frame,
  /// where a deactivated element has become unmounted → currentContext null.
  void _refreshAncestorLeading() {
    if (!_sliceMode || _midFrame) return;
    final pos = _ancestorPosition;
    if (pos == null || !pos.hasPixels) return;
    if (_paintKey.currentContext?.mounted == false) return;
    final box = _paintKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    final RenderObject? viewportObj = viewport;
    if (viewportObj is! RenderBox || !viewportObj.hasSize) return;

    final topLeft = MatrixUtils.transformPoint(
      box.getTransformTo(viewportObj),
      Offset.zero,
    );
    if (!topLeft.dy.isFinite) return;
    final measured = pos.pixels + topLeft.dy;
    if (!measured.isFinite) return;
    _ancestorLeading = measured;
  }

  /// Exact visible Y-range of [_paintKey] inside the nearest ancestor
  /// viewport, in the paint box's local coordinates, plus the viewport
  /// height (which sizes the overscan). Empty (top == bottom) when fully
  /// off-screen, pinned at the document edge nearest the viewport.
  ///
  /// Prefers live [ScrollPosition.pixels] − [_ancestorLeading]. Falls back to
  /// post-layout [getTransformTo] when leading isn't cached yet. Never use
  /// [getOffsetToReveal] on the full paintBounds of a huge box.
  ({double top, double bottom, double vpH})? _ancestorVisibleRange(
    double contentH,
  ) {
    if (contentH <= 0) return null;

    final pos = _ancestorPosition;
    late final double boxTopInViewport;
    late final double vpH;

    if (pos != null &&
        pos.hasPixels &&
        pos.hasViewportDimension &&
        _ancestorLeading != null) {
      vpH = pos.viewportDimension;
      boxTopInViewport = _ancestorLeading! - pos.pixels;
    } else {
      final box = _paintKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return null;
      final viewport = RenderAbstractViewport.maybeOf(box);
      final RenderObject? viewportObj = viewport;
      if (viewportObj is! RenderBox || !viewportObj.hasSize) return null;
      final topLeft = MatrixUtils.transformPoint(
        box.getTransformTo(viewportObj),
        Offset.zero,
      );
      if (!topLeft.dy.isFinite) return null;
      boxTopInViewport = topLeft.dy;
      vpH = pos?.hasViewportDimension == true
          ? pos!.viewportDimension
          : viewportObj.size.height;
      if (pos != null && pos.hasPixels) {
        _ancestorLeading = pos.pixels + topLeft.dy;
      }
    }

    if (vpH <= 0) return null;

    // Exact visible range in local coords; degenerate ranges collapse to
    // the document edge nearest the viewport.
    final visTop = math.min(math.max(0.0, -boxTopInViewport), contentH);
    final visBottom = math.min(contentH, vpH - boxTopInViewport);
    return (top: visTop, bottom: math.max(visTop, visBottom), vpH: vpH);
  }

  void _requestReflow() {
    if (_surface == null) return; // fires once the surface is ready, in _init
    unawaited(_reflow());
  }

  // Captures [widget.document] / [_contentWidth] at send time; overlapping
  // calls sample on the worker and the epoch gate drops stale applies.
  Future<void> _reflow() async {
    final surface = _surface;
    if (surface == null) return;
    final epoch = ++_reflowEpoch;
    try {
      if (!mounted || widget.controller._disposed) return;
      final doc = widget.document;
      final w = _contentWidth;
      if (w <= 0) return;
      // Auto-measure gate: defer until the offstage measure pass (scheduled
      // in build) has sized this doc's placeholders; it re-triggers us.
      if (doc.autoSizedPlaceholders.isNotEmpty && _measuredDocId != doc.id) {
        return;
      }
      // The line table costs O(lines) per reflow, so during a resize storm
      // with NOTHING selected it is skipped (the held table answers, stale)
      // and one settle refresh rebuilds it when the streaming stops. An
      // active selection keeps it riding every reflow — highlight rects
      // must match the pixels of the same reply.
      final wantTable =
          _selection.enabled &&
          (_selection.hasSelection ||
              !_selection.hasLineTable ||
              _tableRefreshDue);
      final GPUTextInstances d;
      final sw = Stopwatch();
      if (doc.streaming) {
        // Streaming path: one syncStream round trip does prepare-if-changed
        // (paragraph-sliced shaping reuse) + reflow + emit. The worker
        // rejects empty content — skip until the first token arrives.
        if (!doc.hasShapeableContent) return;
        sw.start();
        d = await widget.controller._syncStreamDoc(
          doc,
          w,
          dpr: _dpr,
          includeLineTable: wantTable,
        );
        sw.stop();
      } else {
        final runs = _resolvedRuns ?? doc.runs;
        await widget.controller._ensurePrepared(
          doc.id,
          runs,
          fallbackFontIds: doc.fallbackFontIds,
          emojiFontId: doc.emojiFontId,
          lineBreak: doc.lineBreak,
          language: doc.language,
        );
        if (!mounted || widget.controller._disposed || epoch != _reflowEpoch) {
          return;
        }
        sw.start();
        // The controller wrapper keeps the atlas mirror current (replies
        // carry only the tail it doesn't hold, usually nothing).
        d = await widget.controller._reflowDoc(
          doc.id,
          w,
          style: doc.effectiveStyle,
          dpr: _dpr,
          includeLineTable: wantTable,
        );
        sw.stop();
      }
      // Monotone gate: skip only when an even newer result already landed.
      if (!mounted ||
          widget.controller._disposed ||
          epoch <= _appliedReflowEpoch) {
        return;
      }
      _appliedReflowEpoch = epoch;
      await _applyDrawable(d, sw.elapsedMicroseconds / 1000.0, wantTable);
    } on GPUTextReflowSuperseded {
      // Worker kept a newer same-doc reflow. If we are still the latest epoch
      // the superseding main call may have bailed before sending — re-kick.
      if (mounted && !widget.controller._disposed && epoch == _reflowEpoch) {
        _requestReflow();
      }
    } on StateError catch (e) {
      // Worker/controller torn down while we awaited (route pop). Swallow.
      if (!e.message.contains('disposed')) rethrow;
    }
  }

  Future<void> _applyDrawable(
    GPUTextInstances d,
    double ms, [
    bool tableRequested = false,
  ]) async {
    final surface = _surface;
    if (surface == null) return;
    // Upload from the controller's atlas mirror when this surface's texture
    // is behind what the fresh instances reference. Sourcing from the mirror
    // (not the reply) also covers rows banded by OTHER docs' prepares, so the
    // texture never lags the instance buffer.
    final ctrl = widget.controller;
    if (_atlasGenOnGpu < d.atlasGeneration &&
        ctrl._atlasGeneration >= d.atlasGeneration) {
      surface.setAtlas(ctrl._atlas.curves, ctrl._atlas.rows);
      _atlasGenOnGpu = ctrl._atlasGeneration;
    }
    surface.setInstances(d.materialize());
    // First content for this view (mount/remount starts at height 0)? The
    // extent-applying setState below must NOT be parked for it: a view built
    // mid-fling (ListView cache extent, scroll-back through per-block views)
    // would otherwise sit collapsed and blank until the scroll goes idle.
    final hadLayout = _docHeight > 0;
    _glyphCount = d.glyphCount;
    _docWidth = d.width;
    _docHeight = d.height;
    _placeholders = d.placeholders;
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
    // The line table rides the same reply as the instances (epoch-gated
    // with them), so selection rows always describe the pixels on screen.
    _selection.applyLineTable(
      d.materializeLineTable(),
      d.layoutGeneration,
      Size(d.width, d.height),
      requested: tableRequested,
    );
    if (tableRequested) _tableRefreshDue = false;
    _colorStubs = [
      for (final s in d.colorGlyphStubs) _ColorStub.fromTransfer(s),
    ];
    // Pack any new bitmap emoji; rebuild color instances from whatever is
    // already resident (stubs still decoding stay blank until generation bump).
    if (_colorStubs.isNotEmpty) {
      final genBefore = widget.controller.colorAtlas.generation;
      unawaited(
        widget.controller._ensureColorStubs(_colorStubs).then((changed) {
          if (!mounted || widget.controller._disposed) return;
          if (changed || widget.controller.colorAtlas.generation != genBefore) {
            _uploadColorInstances();
            _rasterEpoch++;
            setState(() {});
          }
        }),
      );
    }
    _uploadColorInstances();
    final metrics = GPUTextMetrics(
      glyphCount: d.glyphCount,
      lineCount: d.lineCount,
      size: Size(d.contentWidth, d.height),
      reflowMs: ms,
    );
    // New instances → bump epoch so [_GpuWindowImage] re-rasters in paint.
    _rasterEpoch++;
    final ancestorScrolling =
        _ancestorPosition?.isScrollingNotifier.value ?? false;
    if (ancestorScrolling && hadLayout) {
      // setState / parent onMetrics→setState mid-fling cancels ballistic
      // scroll and remeasures extent (thumb jumps toward center). Parked;
      // [_onScrollingChanged] delivers on the idle transition. Force: the
      // content under the window changed, so recenter to fresh geometry.
      // (First layout is exempt: going 0 → content mid-scroll is exactly
      // what any lazily-built list child does, and staying collapsed until
      // the fling ends is strictly worse than an extent remeasure.)
      _pendingMetrics = metrics;
      _syncAncestorPaintSlice(force: true);
    } else {
      _pendingMetrics = null;
      widget.onMetrics?.call(metrics);
      setState(() {}); // extent + placeholder overlay + new raster epoch
      if (_sliceMode) {
        _refreshAncestorLeading();
        _syncAncestorPaintSlice(force: true);
      }
    }
  }

  void _uploadColorInstances() {
    final surface = _surface;
    if (surface == null) return;
    final color = _colorInstancesFromStubs(
      _colorStubs,
      widget.controller.colorAtlas,
    );
    _colorGlyphCount = color.length ~/ floatsPerColorInstance;
    surface.setColorInstances(color);
  }

  vm.Vector4 get _clearColor {
    // Transparent clear so Flutter-painted backgrounds / underlines show
    // through (same as RenderGPUParagraph). The ColoredBox behind supplies
    // [widget.background].
    return vm.Vector4(0, 0, 0, 0);
  }

  /// Paint-time raster of the current drawable into [logical] at [camX]/[camY]
  /// (device px). Owned by [_GpuWindowImage] — never call from build/layout.
  /// The window is widened by [_inkPadPx] each side (cam shifted to match) so
  /// margin ink isn't shaved; paint draws it shifted left by the same pad.
  _GpuWindow? _rasterWindow(Size logical, double camX, double camY) {
    final surface = _surface;
    if (surface == null || logical.isEmpty) return null;
    if (_glyphCount == 0 && _colorGlyphCount == 0) return null;
    final padDev = (_inkPadPx * _dpr).round();
    final image = surface.renderAt(
      devW: ((logical.width * _dpr).round() + 2 * padDev).clamp(
        1,
        _maxDevicePx.round(),
      ),
      devH: (logical.height * _dpr).round().clamp(1, _maxDevicePx.round()),
      dpr: _dpr,
      camX: camX + padDev,
      camY: camY,
      clear: _clearColor,
      colorAtlas: widget.controller.colorAtlasTexture(),
    );
    if (image == null) return null;
    return (image: image, src: surface.contentRect);
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
    _resolvedRuns = _resolvePlaceholderSpecSizes(doc.runs, sizes);
    setState(() {}); // drop the offstage measure layer
    _requestReflow();
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
            // Content height after reflow; 0 before it so unbounded parents
            // (Column / scrollables) don't get an infinite child.
            final contentH = _docHeight;
            // Height hugs the laid-out content, clamped by a finite parent
            // max (taller content is clipped — scrolling is the parent's job).
            final layoutH = constraints.maxHeight.isFinite
                ? math.min(contentH, constraints.maxHeight)
                : contentH;
            assert(() {
              if (!_clipWarned && contentH > constraints.maxHeight + 1) {
                _clipWarned = true;
                debugPrint(
                  'GPUTextView: laid-out content '
                  '(${contentH.toStringAsFixed(0)}px) is taller than the '
                  'bounded height '
                  '(${constraints.maxHeight.toStringAsFixed(0)}px) and will '
                  'be CLIPPED — the view does not scroll. Wrap it in a '
                  'scrollable (e.g. SingleChildScrollView), or use '
                  'SliverGPUText inside a CustomScrollView.',
                );
              }
              return true;
            }());
            // Reading DPR here subscribes us to it, so a monitor/DPR change
            // rebuilds and re-renders at the new scale. Committed to [_dpr]
            // before the slice math below (the band helpers read it).
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final widthOrDprChanged = w != _contentWidth || dpr != _dpr;
            _dpr = dpr;
            final maxPaintH = _maxDevicePx / dpr;

            // GPU window: bounded parent → the whole (clamped) box. Unbounded
            // (inside an ancestor Scrollable) → only the ancestor's visible
            // slice, synced from its ScrollPosition — rasterizing the full
            // content would exceed the GPU texture cap and stretch/corrupt
            // the image.
            var paintTop = 0.0;
            var paintH = layoutH;
            _sliceMode = !constraints.maxHeight.isFinite && contentH > 0;
            if (_sliceMode) {
              _bindAncestorScroll();
              final vis = _ancestorVisibleRange(contentH);
              if (vis != null) {
                // Same hysteresis as the scroll path: unrelated rebuilds
                // (hover, selection) must not move the window — a moved
                // window is a re-raster.
                final want = _windowCovers(vis, contentH)
                    ? _paintSlice.value
                    : _desiredWindow(vis, contentH);
                paintTop = want.top;
                paintH = want.height;
              } else {
                // First frames / no viewport yet: rasterize one screenful.
                paintH = math.min(contentH, MediaQuery.sizeOf(context).height);
                if (paintH > maxPaintH) paintH = maxPaintH;
              }
              // Quiet-prime the slice during build (notify would assert).
              // Scroll updates use [_paintSlice.value] and rebuild the layer.
              _paintTop = paintTop;
              _viewportH = paintH;
              _paintSlice.setSilent((top: paintTop, height: paintH));
            } else if (paintH > maxPaintH) {
              paintH = maxPaintH;
            }

            // Slice mode tracks the window via [_paintSlice] (no setState).
            final windowChanged =
                !_sliceMode && (paintH != _viewportH || paintTop != _paintTop);
            if (widthOrDprChanged || windowChanged) {
              _contentWidth = w;
              if (!_sliceMode) {
                _viewportH = paintH;
                _paintTop = paintTop;
              }
              if (widthOrDprChanged) {
                // Async reflow — safe to kick from build (setState lands later).
                // [_GpuWindowImage] re-rasters on size change in paint.
                _requestReflow();
              }
            }
            // Auto-measure: while a doc has unmeasured placeholders, keep the
            // offstage measure layer mounted and read the sizes next frame. The
            // reflow gate holds until that lands.
            final doc = widget.document;
            if (_needsMeasure && !_measureScheduled) {
              _measureScheduled = true;
              // Must run after this frame's layout so GlobalKeys have sizes.
              SchedulerBinding.instance.addPostFrameCallback(
                (_) => mounted ? _readMeasures(doc) : null,
              );
            }

            // Full-content layers (chrome / selection / placeholders): static
            // between reflows, so each sits behind its own RepaintBoundary;
            // document space IS local space and nothing tracks offsets.
            Widget docLayer({required Widget Function(double height) builder}) {
              if (layoutH <= 0) return const SizedBox.shrink();
              return Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: layoutH,
                child: builder(layoutH),
              );
            }

            // The GPU window: under ancestor scroll [_paintSlice] moves it
            // without setState (fling-safe); bounded parents get one static
            // window covering the box.
            Widget gpuWindow() {
              Widget image(double top, double height) => IgnorePointer(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: _renderWidth > 0 ? _renderWidth : w,
                    height: height,
                    child: _GpuWindowImage(
                      epoch: _rasterEpoch,
                      dpr: _dpr,
                      camX: 0.0,
                      camY: -top * dpr,
                      rasterize: _rasterWindow,
                    ),
                  ),
                ),
              );
              if (_sliceMode) {
                return ValueListenableBuilder<({double top, double height})>(
                  valueListenable: _paintSlice,
                  builder: (context, slice, _) {
                    if (slice.height <= 0) return const SizedBox.shrink();
                    return Positioned(
                      top: slice.top,
                      left: 0,
                      right: 0,
                      height: slice.height,
                      child: image(slice.top, slice.height),
                    );
                  },
                );
              }
              if (paintH <= 0) return const SizedBox.shrink();
              return Positioned(
                top: paintTop,
                left: 0,
                right: 0,
                height: paintH,
                child: image(paintTop, paintH),
              );
            }

            // Paint layers are IgnorePointer; the hit layer sits ON TOP so
            // it owns gestures and span hit-testing.
            final body = Stack(
              fit: StackFit.expand,
              children: [
                if (_needsMeasure) _measureLayer(doc),
                // Backgrounds + underlines (under glyphs). GPU clear is
                // transparent so these show through. RepaintBoundary: the
                // picture is static between reflows — without it the parent
                // scrollable would re-record the full decoration walk every
                // scroll tick.
                if (_backgrounds.isNotEmpty || _decorationsBelow.isNotEmpty)
                  docLayer(
                    builder: (height) => RepaintBoundary(
                      child: IgnorePointer(
                        child: ClipRect(
                          child: CustomPaint(
                            painter: _SpanChromePainter(
                              backgrounds: _backgrounds,
                              decorations: _decorationsBelow,
                              viewportHeight: height,
                              viewportWidth: w,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Selection highlight + handle anchors, under the glyph
                // image like the chrome above (transparent GPU clear). Its
                // own boundary: selection repaints stay inside it, and outer
                // scrolling doesn't re-record it.
                docLayer(
                  builder: (height) => RepaintBoundary(
                    child: IgnorePointer(
                      child: ClipRect(
                        child: _SelectionUnderlay(
                          selections: () => [_selection],
                          repaint: _selection.repaint,
                          origin: (_) => Offset.zero,
                          // This layer is content-sized (the whole document);
                          // the on-screen band is the raster slice — without
                          // this override a 20k-line doc would prefetch
                          // detail for its ENTIRE height.
                          band: _selectionVisibleBand,
                        ),
                      ),
                    ),
                  ),
                ),
                // The visible GPU window — [_GpuWindowImage] rasters in
                // paint (slice moves via [_paintSlice], content via epoch).
                gpuWindow(),
                // lineThrough paints over the glyphs.
                if (_decorationsAbove.isNotEmpty)
                  docLayer(
                    builder: (height) => RepaintBoundary(
                      child: IgnorePointer(
                        child: ClipRect(
                          child: CustomPaint(
                            painter: _SpanChromePainter(
                              backgrounds: const [],
                              decorations: _decorationsAbove,
                              viewportHeight: height,
                              viewportWidth: w,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_placeholders.isNotEmpty && _hasPlaceholderWidgets)
                  docLayer(
                    builder: (height) => RepaintBoundary(
                      child: IgnorePointer(
                        child: ClipRect(
                          child: _placeholderOverlayWindow(height, w),
                        ),
                      ),
                    ),
                  ),
                _hitLayer(),
              ],
            );
            return SizedBox(
              key: _paintKey,
              width: w.isFinite ? w : null,
              height: layoutH,
              child: body,
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

  /// Hit-test / hover surface in document layout space (== local space). Its
  /// child doubles as the selection host: a doc-space box the selectable
  /// fragments map their coordinates through.
  Widget _hitLayer() {
    return MouseRegion(
      cursor: _hoverCursor,
      onHover: (e) => _onHoverDoc(e.localPosition),
      onExit: (_) {
        if (_hoverTag != null) {
          setState(() => _hoverTag = null);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: _hitBoxes.isEmpty ? null : (d) => _onTapDoc(d.localPosition),
        child: _SelectionHost(
          selection: _selection,
          registrarOverride: widget.selectionRegistrar,
          colorOverride: widget.selectionColor,
          onEnabledChanged: _onSelectionEnabledChanged,
        ),
      ),
    );
  }

  /// Registrar appeared (view moved under a SelectionArea): the drawable on
  /// screen shipped without geometry — fetch one. Disable needs nothing (the
  /// fragments were dropped synchronously).
  void _onSelectionEnabledChanged() {
    if (_selection.enabled) _requestReflow();
  }

  /// Placeholders in document space, culled to the rasterized window.
  Widget _placeholderOverlayWindow(double vh, double vw) {
    return Stack(
      children: [
        for (final box in _placeholders)
          if (box.index >= 0 &&
              box.top + box.height >= 0 &&
              box.top <= vh &&
              box.left + box.width >= 0 &&
              box.left <= vw)
            if (_placeholderWidget(box.index) case final child?)
              Positioned(
                left: box.left,
                top: box.top,
                width: box.width,
                height: box.height,
                child: child,
              ),
      ],
    );
  }

  /// [docLocal] is in document layout space (ScrollView child coordinates).
  HitSpanBox? _hitAtDoc(Offset docLocal) {
    final x = docLocal.dx;
    final y = docLocal.dy;
    for (var i = _hitBoxes.length - 1; i >= 0; i--) {
      final b = _hitBoxes[i];
      if (b.contains(x, y)) return b;
    }
    return null;
  }

  void _onTapDoc(Offset docLocal) {
    final box = _hitAtDoc(docLocal);
    if (box == null) return;
    final tag = box.source;
    if (tag is! String) return;
    final span = widget.document.hitTargets[tag];
    final recognizer = span?.recognizer;
    if (recognizer is TapGestureRecognizer) {
      recognizer.onTap?.call();
    }
    widget.onSpanTap?.call(tag, span);
  }

  void _onHoverDoc(Offset docLocal) {
    final box = _hitAtDoc(docLocal);
    final tag = box?.source is String ? box!.source as String : null;
    if (tag == _hoverTag) return;
    setState(() => _hoverTag = tag);
  }

  MouseCursor get _hoverCursor {
    final tag = _hoverTag;
    if (tag == null) return SystemMouseCursors.basic;
    final span = widget.document.hitTargets[tag];
    final custom = span?.mouseCursor;
    if (custom != null && custom != MouseCursor.defer) return custom;
    return SystemMouseCursors.click;
  }
}

/// Paints [BackgroundRect]s and [DecorationLine]s in document space
/// (== local space), culled to the window.
class _SpanChromePainter extends CustomPainter {
  _SpanChromePainter({
    required this.backgrounds,
    required this.decorations,
    required this.viewportHeight,
    required this.viewportWidth,
  });

  final List<BackgroundRect> backgrounds;
  final List<DecorationLine> decorations;
  final double viewportHeight;
  final double viewportWidth;

  @override
  void paint(Canvas canvas, Size size) {
    _paintSpanChrome(
      canvas,
      backgrounds: backgrounds,
      decorations: decorations,
      offX: 0,
      offY: 0,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
  }

  @override
  bool shouldRepaint(covariant _SpanChromePainter old) =>
      !identical(backgrounds, old.backgrounds) ||
      !identical(decorations, old.decorations) ||
      viewportHeight != old.viewportHeight ||
      viewportWidth != old.viewportWidth;
}

/// Whether the framework is inside build/layout/paint of the current frame,
/// where scheduling a build asserts. Scroll-state listeners consult this:
/// isScrollingNotifier can flip inside a viewport's performLayout when a
/// content-extent change begins a ballistic activity (goBallistic), and any
/// setState/notify downstream of that flip must wait for the frame to end.
bool get _midFrame {
  final phase = SchedulerBinding.instance.schedulerPhase;
  return phase == SchedulerPhase.persistentCallbacks ||
      phase == SchedulerPhase.midFrameMicrotasks;
}

/// [ValueListenable] that can be primed during build without notifying
/// (notifying mid-build asserts). Scroll / async paths use [value].
class _SliceNotifier extends ChangeNotifier
    implements ValueListenable<({double top, double height})> {
  _SliceNotifier(this._value);

  ({double top, double height}) _value;

  @override
  ({double top, double height}) get value => _value;

  set value(({double top, double height}) newValue) {
    if (newValue == _value) return;
    _value = newValue;
    notifyListeners();
  }

  void setSilent(({double top, double height}) newValue) {
    _value = newValue;
  }
}

/// A rasterized GPU window: [image] is usually LARGER than the rendered
/// content ([_GpuTextSurface] buckets its backing texture) — paint samples
/// [src], never the full image.
typedef _GpuWindow = ({ui.Image image, ui.Rect src});

/// Viewport GPU image that rasters in [paint] — size / cam / epoch changes
/// coalesce naturally to one blit per frame. No post-frame scheduling.
class _GpuWindowImage extends LeafRenderObjectWidget {
  const _GpuWindowImage({
    required this.epoch,
    required this.dpr,
    required this.camX,
    required this.camY,
    required this.rasterize,
    this.keepStale = false,
  });

  final int epoch;
  final double dpr;
  final double camX;
  final double camY;
  final _GpuWindow? Function(Size logical, double camX, double camY)? rasterize;

  /// When true, a null [rasterize] result keeps the previously rendered
  /// window on screen (at the size it was rendered for, clipped to the box)
  /// instead of blanking — the owner's signal that fresh content is a worker
  /// round trip away (width-resize catch-up), not that the view became empty.
  final bool keepStale;

  @override
  RenderBox createRenderObject(BuildContext context) {
    return _RenderGpuWindowImage(
      epoch: epoch,
      dpr: dpr,
      camX: camX,
      camY: camY,
      rasterize: rasterize,
      keepStale: keepStale,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderGpuWindowImage renderObject,
  ) {
    renderObject
      ..epoch = epoch
      ..dpr = dpr
      ..camX = camX
      ..camY = camY
      ..rasterize = rasterize
      ..keepStale = keepStale;
  }
}

class _RenderGpuWindowImage extends RenderBox {
  _RenderGpuWindowImage({
    required this._epoch,
    required this._dpr,
    required this._camX,
    required this._camY,
    required this._rasterize,
    required this._keepStale,
  });

  int _epoch;
  double _dpr;
  double _camX;
  double _camY;
  _GpuWindow? Function(Size logical, double camX, double camY)? _rasterize;
  bool _keepStale;

  /// Test hook: whether a rendered window is currently held (painted).
  @visibleForTesting
  bool get debugHasImage => _window != null;

  /// Test hook: logical size the held window was rendered for. While a stale
  /// window is kept across a resize this stays at the PRE-resize size — paint
  /// draws it at that natural scale rather than stretching (skewing) it.
  @visibleForTesting
  Size get debugWindowLogicalSize => _windowLogical;

  /// Test hook: how many times the rasterizer actually ran (a real GPU
  /// render — fingerprint-matched paints don't count). Scrolling inside the
  /// hysteresis band must not grow this.
  @visibleForTesting
  int get debugRasterCount => _rasterCount;
  int _rasterCount = 0;

  _GpuWindow? _window;
  // Logical size [_window] was RENDERED for — unlike the [_imageSize]
  // fingerprint below, this does not advance while a stale window is kept
  // across a resize, so paint can draw it at its natural scale (no skew).
  Size _windowLogical = Size.zero;
  int _imageEpoch = -1;
  double _imageCamX = double.nan;
  double _imageCamY = double.nan;
  double _imageDpr = 0;
  Size _imageSize = Size.zero;
  final Paint _imagePaint = Paint()..filterQuality = FilterQuality.low;

  set epoch(int value) {
    if (value == _epoch) return;
    _epoch = value;
    markNeedsPaint();
  }

  set dpr(double value) {
    if (value == _dpr) return;
    _dpr = value;
    markNeedsPaint();
  }

  set camX(double value) {
    if (value == _camX) return;
    _camX = value;
    markNeedsPaint();
  }

  set camY(double value) {
    if (value == _camY) return;
    _camY = value;
    markNeedsPaint();
  }

  set rasterize(
    _GpuWindow? Function(Size logical, double camX, double camY)? value,
  ) {
    if (identical(value, _rasterize)) return;
    _rasterize = value;
    markNeedsPaint();
  }

  set keepStale(bool value) {
    // No repaint: the flag only changes how the NEXT rasterization's null
    // result is treated; it never invalidates what is on screen.
    _keepStale = value;
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performResize() {
    size = constraints.biggest;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _ensureImage();
    final window = _window;
    if (window == null) return;
    // Sample only the rendered sub-rect — the backing texture is bucketed,
    // so the image is usually larger than the content (see _GpuTextSurface).
    // The rasterizer widened the window by [_inkPadPx] each side so margin
    // ink isn't shaved; draw it shifted left by the pad, letting the
    // horizontal overhang paint beside the box like ordinary text ink.
    if (_windowLogical == size) {
      context.canvas.drawImageRect(
        window.image,
        window.src,
        Rect.fromLTWH(
          offset.dx - _inkPadPx,
          offset.dy,
          size.width + 2 * _inkPadPx,
          size.height,
        ),
        _imagePaint,
      );
      return;
    }
    // Stale window kept across a resize: draw it at the size it was RENDERED
    // for (scaling it would zoom or skew the glyphs), anchored top-left and
    // clipped to the box (+ ink pad) — shrinking crops the strip at the right
    // edge, widening leaves a background gap, exactly like the sliver's kept
    // strip — until the fresh composite replaces it a worker round trip later.
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(
        offset.dx - _inkPadPx,
        offset.dy,
        size.width + 2 * _inkPadPx,
        size.height,
      ),
    );
    canvas.drawImageRect(
      window.image,
      window.src,
      Rect.fromLTWH(
        offset.dx - _inkPadPx,
        offset.dy,
        _windowLogical.width + 2 * _inkPadPx,
        _windowLogical.height,
      ),
      _imagePaint,
    );
    canvas.restore();
  }

  void _ensureImage() {
    final rasterize = _rasterize;
    if (rasterize == null || size.isEmpty) {
      _window = null;
      return;
    }
    if (_window != null &&
        _imageEpoch == _epoch &&
        _imageCamX == _camX &&
        _imageCamY == _camY &&
        _imageDpr == _dpr &&
        _imageSize == size) {
      return;
    }
    // Surface owns retirement of prior images; we only hold the latest.
    // Null with [keepStale] means "fresh content is still a worker round
    // trip away" — keep the previous window (painted at the size it was
    // rendered for, see paint) instead of blanking.
    _rasterCount++;
    final fresh = rasterize(size, _camX, _camY);
    if (fresh != null || !_keepStale) {
      _window = fresh;
      _windowLogical = size;
    }
    _imageEpoch = _epoch;
    _imageCamX = _camX;
    _imageCamY = _camY;
    _imageDpr = _dpr;
    _imageSize = size;
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
  gpu.DeviceBuffer? _colorInstanceBuffer;
  AtlasTextures? _textures;
  int _count = 0;
  int _colorCount = 0;
  int _contentDevW = 0;
  int _contentDevH = 0;
  final List<(ui.Image, int)> _retired = [];
  bool _hooked = false;

  /// Backing-texture dimensions are allocated in steps of this many device
  /// px. A live resize drag changes the wanted strip size every frame;
  /// bucketing means the surface only [gpu.GpuImageSurface.resize]s when the
  /// drag crosses a step, so the texture pool is reused instead of
  /// reallocated per frame.
  static const int _dimBucket = 256;

  static int _bucketed(int v) {
    final b = ((v + _dimBucket - 1) ~/ _dimBucket) * _dimBucket;
    return math.min(b, _maxDevicePx.round());
  }

  /// The device-px sub-rect of the image returned by [renderAt] /
  /// [renderComposite] that actually contains the rendered strip. The
  /// backing texture is bucketed (see [_dimBucket]), so the image is usually
  /// LARGER than the strip — callers must sample this rect, never the full
  /// image. Valid for the most recent render (each render object owns its
  /// surface and only ever paints the latest image).
  ui.Rect get contentRect =>
      ui.Rect.fromLTWH(0, 0, _contentDevW.toDouble(), _contentDevH.toDouble());

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

  /// Upload the per-reflow coverage instance buffer (glyph positions/colours).
  void setInstances(Float32List instances) {
    _count = instances.length ~/ floatsPerInstance;
    _instanceBuffer = _count == 0 ? null : _pipeline.uploadInstances(instances);
  }

  /// Upload the color-bitmap (emoji) instance buffer.
  void setColorInstances(Float32List instances) {
    _colorCount = instances.length ~/ floatsPerColorInstance;
    _colorInstanceBuffer = _colorCount == 0
        ? null
        : _pipeline.uploadColorInstances(instances);
  }

  /// Rasterize the [devW]×[devH] window of the uploaded drawable, panned by
  /// [camX]/[camY] device px. [colorAtlas] is sampled by the second color pass
  /// when color instances are present.
  ui.Image? renderAt({
    required int devW,
    required int devH,
    required double dpr,
    required vm.Vector4 clear,
    double camX = 0,
    double camY = 0,
    gpu.Texture? colorAtlas,
  }) {
    final instanceBuffer = _instanceBuffer;
    final textures = _textures;
    final hasCoverage =
        instanceBuffer != null && textures != null && _count > 0;
    final hasColor =
        _colorInstanceBuffer != null && colorAtlas != null && _colorCount > 0;
    if (!hasCoverage && !hasColor) {
      return _image;
    }
    return renderComposite(
      devW: devW,
      devH: devH,
      dpr: dpr,
      clear: clear,
      colorAtlas: colorAtlas,
      draws: [
        (
          textures: textures,
          instances: instanceBuffer,
          count: hasCoverage ? _count : 0,
          camX: camX,
          camY: camY,
          colorInstances: _colorInstanceBuffer,
          colorCount: hasColor ? _colorCount : 0,
        ),
      ],
    );
  }

  /// One viewport-sized pass: clear once, then [draws.length] instance draws
  /// (each with its own atlas + [camY]). Used by [GPUTextBlocksView] to
  /// composite N lazy blocks into a single [ui.Image]. Color-bitmap emoji are
  /// drawn after each block's coverage pass when [colorAtlas] + per-draw color
  /// buffers are set.
  ui.Image? renderComposite({
    required int devW,
    required int devH,
    required double dpr,
    required vm.Vector4 clear,
    gpu.Texture? colorAtlas,
    required List<
      ({
        AtlasTextures? textures,
        gpu.DeviceBuffer? instances,
        int count,
        double camX,
        double camY,
        gpu.DeviceBuffer? colorInstances,
        int colorCount,
      })
    >
    draws,
  }) {
    if (devW <= 0 || devH <= 0) return _image;
    final wantW = devW.clamp(1, _maxDevicePx.round());
    final wantH = devH.clamp(1, _maxDevicePx.round());

    // ONE surface for this object's lifetime, resized in place. This
    // flutter_gpu guarantees presented images stay valid across resize and
    // later acquires (the texture pool never recycles a texture Flutter
    // still references), so recreating the surface per size change — a full
    // texture reallocation EVERY FRAME of a resize drag, and the historical
    // source of dead-image flashes — buys nothing. Bucketed dims + per-axis
    // grow mean a drag only resizes when it crosses a 256-px step; the
    // area check shrinks the texture back once the strip settles smaller.
    final surfW = _bucketed(wantW);
    final surfH = _bucketed(wantH);
    var surface = _surface;
    if (surface == null) {
      surface = gpu.gpuContext.createImageSurface(
        surfW,
        surfH,
        format: _surfaceFormat(gpu.gpuContext),
      );
      _surface = surface;
    } else if (surface.width * surface.height > 2 * surfW * surfH) {
      surface.resize(surfW, surfH);
    } else if (surface.width < surfW || surface.height < surfH) {
      surface.resize(
        math.max(surface.width, surfW),
        math.max(surface.height, surfH),
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
    // The strip occupies only the top-left wantW×wantH of the bucketed
    // texture: the viewport maps NDC onto that sub-rect (geometry outside it
    // is clipped in clip space) and [contentRect] tells paint what to sample.
    pass.setViewport(gpu.Viewport(width: wantW, height: wantH));
    for (final d in draws) {
      if (d.count > 0 && d.instances != null && d.textures != null) {
        _pipeline.renderInstances(
          pass: pass,
          frame: FrameUniforms(
            width: devW.toDouble(),
            height: devH.toDouble(),
            cam: [dpr, dpr, d.camX, d.camY],
          ),
          instances: d.instances!,
          instanceCount: d.count,
          textures: d.textures!,
        );
      }
      if (d.colorCount > 0 && d.colorInstances != null && colorAtlas != null) {
        _pipeline.renderColorInstances(
          pass: pass,
          frame: FrameUniforms(
            width: devW.toDouble(),
            height: devH.toDouble(),
            cam: [dpr, dpr, d.camX, d.camY],
          ),
          instances: d.colorInstances!,
          instanceCount: d.colorCount,
          colorAtlas: colorAtlas,
        );
      }
    }
    frame.present(cmd);
    cmd.submit();

    // Retire the previous image handle once the frame that last painted it
    // completes. Disposing the handle promptly matters more now than before:
    // a live ui.Image PINS its backing texture out of the surface's reuse
    // pool, so a leaked handle would grow the pool instead of recycling it.
    final prev = _image;
    if (prev != null) {
      _retired.add((
        prev,
        ui.PlatformDispatcher.instance.frameData.frameNumber,
      ));
      if (!_hooked) {
        _hooked = true;
        SchedulerBinding.instance.addTimingsCallback(_flushRetired);
      }
    }
    _contentDevW = wantW;
    _contentDevH = wantH;
    _image = surface.currentImage;
    return _image;
  }

  void _flushRetired(List<ui.FrameTiming> timings) {
    var latest = -1;
    for (final t in timings) {
      if (t.frameNumber > latest) latest = t.frameNumber;
    }
    while (_retired.isNotEmpty && _retired.first.$2 <= latest) {
      _retired.removeAt(0).$1.dispose();
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
    for (final (img, _) in _retired) {
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
typedef GPUBlockHeightEstimator = double Function(
  GPUTextDocument block,
  double width,
);

/// One block's uploaded instance buffer, ready to composite against the view's
/// shared atlas textures.
class _BlockDrawable {
  _BlockDrawable({
    required this.instances,
    required this.count,
    required this.height,
    required this.placeholders,
    this.colorInstances,
    this.colorCount = 0,
    this.colorStubs = const [],
  });

  final gpu.DeviceBuffer? instances;
  final int count;
  final double height;
  final List<PlaceholderBox> placeholders;

  /// Color-bitmap emoji quads (may be empty until async atlas pack finishes).
  final gpu.DeviceBuffer? colorInstances;
  final int colorCount;
  final List<_ColorStub> colorStubs;
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
    this.selectionRegistrar,
    this.selectionColor,
  });

  /// Shared worker owner; fonts referenced by [blocks] must be registered on it.
  final GPUTextViewController controller;

  /// Selection registrar. Like [GPURichText], a null registrar falls back to
  /// the enclosing [SelectionContainer]. While a registrar is attached, block
  /// syncs additionally ship selection geometry from the worker.
  final SelectionRegistrar? selectionRegistrar;

  /// Highlight color; defaults to [DefaultSelectionStyle.of] when selection
  /// is active.
  final Color? selectionColor;

  /// The blocks, top to bottom. Each is a [GPUTextDocument] (GPU text, one
  /// paragraph, laid out on the worker) or a [GPUWidgetBlock] (a Flutter
  /// widget: image, code card, table, divider). Each needs a distinct `id`
  /// (its cache key). Existing `List<GPUTextDocument>` call sites still work —
  /// a text-doc list is a valid [GPUBlock] list.
  final List<GPUBlock> blocks;

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
  int _rasterEpoch = 0;

  double _contentWidth = 0;
  double _viewportH = 0;
  double _dpr = 1;

  // Per-width height cache (survives eviction). Keyed by block id.
  final Map<String, double> _heights = {};
  // GPU instance buffers for blocks in the cache window.
  final Map<String, _BlockDrawable> _live = {};
  // LRU of worker-prepared ids (insertion order = oldest first). Touched on
  // prepare/reflow; trimmed to [maxPreparedDocs] keeping the cache window pinned.
  final LinkedHashMap<String, Null> _preparedLru = LinkedHashMap();
  // Shared GPU atlas for every live block, uploaded from the controller's
  // atlas mirror whenever [_atlasGenOnGpu] falls behind a drawable's needs.
  AtlasTextures? _atlasTextures;
  int _atlasGenOnGpu = -1;

  // A width resize dropped every per-width drawable and the re-sync is still
  // in flight: keep painting the previously rendered window (old wrap width)
  // instead of compositing an empty one. Stretched text reads as "resizing";
  // a blank frame reads as broken. Cleared on the first fresh composite —
  // and by [_resetCaches], where the content actually changed and a stale
  // window would lie.
  bool _keepStaleWindow = false;

  /// Test hook: whether the painter is holding the pre-resize window while
  /// the width re-sync is still in flight.
  @visibleForTesting
  bool get debugKeepStaleWindow => _keepStaleWindow;

  // Prefix tops for the current height vector (logical px, content coords).
  List<double> _tops = const [];
  double _totalHeight = 0;
  int _laidOut = 0;

  // Per-block selection state (fragments + decoded worker geometry), keyed by
  // block id. Created when a synced block's geometry lands, evicted with the
  // cache window EXCEPT blocks holding a live selection (the highlight must
  // survive scroll-away-and-back). All share one host render box inside the
  // scroll view ([_BlocksSelectionHost]), each shifted to its block top.
  final Map<String, _DocSelection> _selections = {};
  SelectionRegistrar? _selRegistrar;
  Color? _selColor;
  TextDirection _selDirection = TextDirection.ltr;
  _RenderBlocksSelectionHost? _selHostBox;
  Map<String, int> _blockIndexById = const {};

  bool get _selectionsEnabled => _selRegistrar != null;

  /// Wired by [_SelectionScope]'s build (below the internal scrollable).
  void _configureSelections(
    SelectionRegistrar? registrar,
    Color? color,
    TextDirection direction,
  ) {
    final wasEnabled = _selectionsEnabled;
    _selRegistrar = registrar;
    _selColor = color;
    _selDirection = direction;
    for (final sel in _selections.values) {
      sel.configure(registrar: registrar, color: color, direction: direction);
    }
    // Registrar appeared: live blocks synced without geometry — refetch.
    if (!wasEnabled && registrar != null) _requestSync();
  }

  void _bindSelectionHost(_RenderBlocksSelectionHost box) {
    _selHostBox = box;
    _selections.forEach(_bindBlockSelection);
  }

  void _unbindSelectionHost(_RenderBlocksSelectionHost box) {
    if (!identical(_selHostBox, box)) return;
    _selHostBox = null;
    for (final sel in _selections.values) {
      sel.unbindHost(box);
    }
  }

  void _bindBlockSelection(String id, _DocSelection sel) {
    final host = _selHostBox;
    if (host == null) return;
    sel.bindHost(
      host,
      shift: () => Offset(0, _topOfId(id)),
      size: () => sel._docSize,
    );
  }

  double _topOfId(String id) {
    final i = _blockIndexById[id];
    return i == null || i >= _tops.length ? 0.0 : _tops[i];
  }

  void _rebuildBlockIndex() {
    _blockIndexById = {
      for (var i = 0; i < widget.blocks.length; i++) widget.blocks[i].id: i,
    };
  }

  _DocSelection _selectionFor(String id) => _selections.putIfAbsent(id, () {
    final sel = _DocSelection();
    sel.configure(
      registrar: _selRegistrar,
      color: _selColor,
      direction: _selDirection,
    );
    sel.repaint.addListener(_onSelectionRepaint);
    _bindBlockSelection(id, sel);
    return sel;
  });

  void _onSelectionRepaint() => _selHostBox?.markNeedsPaint();

  void _disposeSelections() {
    for (final sel in _selections.values) {
      sel.repaint.removeListener(_onSelectionRepaint);
      sel.dispose();
    }
    _selections.clear();
  }

  bool _busy = false;
  bool _pending = false;
  int _gen = 0; // bumps on width/dpr/blocks reset so in-flight work abandons

  // Fling/drag in progress: skip jumpTo + setState (they cancel ballistic
  // scroll). Sync still fills GPU buffers; UI/extent refresh waits for idle.
  bool _pendingIdleSync = false;
  bool _pendingIdleSetState = false;
  bool _pendingLaidOutNotify = false;
  bool _idleListenerAttached = false;
  bool _idleWorkDeferred = false;
  VoidCallback? _idleListener;

  @override
  void initState() {
    super.initState();
    _scroll = widget.scrollController ?? ScrollController();
    _scroll.addListener(_onScroll);
    _rebuildBlockIndex();
    _dpr =
        WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
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
    // A different controller means a different worker: its atlas mirror,
    // generation numbering, and prepared docs don't carry over.
    if (!identical(widget.controller, old.controller)) {
      _resetCaches();
      _requestSync();
      return;
    }
    // Parent rebuilds routinely reconstruct the list with the same content;
    // only a structural change (ids / layout styles) warrants dropping every
    // prepared doc, height, and GPU buffer.
    if (!identical(old.blocks, widget.blocks)) {
      if (!_equivalentBlockLists(old.blocks, widget.blocks)) {
        _resetCaches();
        _requestSync();
        return;
      }
      // Equivalent but a fresh list instance: a widget block's builder closure
      // may have changed. Rebuild the mounted media layer so it invokes the new
      // builders — no reset, since heights/prepares/drawables are still valid.
      if (mounted && widget.blocks.any((b) => b is GPUWidgetBlock)) {
        setState(() {});
      }
    }
    if (widget.blockSpacing != old.blockSpacing) {
      _requestSync(); // tops shift; heights and prepares stay valid
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
    _disposeSelections();
    _scroll.removeListener(_onScroll);
    if (widget.scrollController == null) _scroll.dispose();
    _preparedLru.clear();
    _live.clear();
    _atlasTextures = null;
    _surface?.dispose();
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
      // The idle flip can arrive inside our own viewport's performLayout
      // (content-extent change → goBallistic settling immediately); the
      // setState below is illegal there. Re-check after the frame — the
      // pending flags keep the work parked if scrolling restarted.
      if (_midFrame) {
        if (_idleWorkDeferred) return;
        _idleWorkDeferred = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _idleWorkDeferred = false;
          if (mounted) _idleListener?.call();
        });
        return;
      }
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
    // [_GpuWindowImage] rebuilds via AnimatedBuilder and rasters in paint.
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
    _keepStaleWindow = false;
    // Content actually changed: selections' source offsets no longer apply.
    _disposeSelections();
    _rebuildBlockIndex();
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
    _rasterEpoch++;
    // Atlas glyphs are unchanged by wrap width; keep the uploaded textures.
    // Same text, old wrap width: worth keeping on screen while the window
    // re-syncs (see [_keepStaleWindow]).
    _keepStaleWindow = true;
  }

  /// Upload the controller's atlas mirror when this view's texture is behind
  /// [needGen] (the generation a fresh drawable's instances reference). A
  /// no-op while the mirror itself is behind — the wrapper that produced the
  /// drawable has already folded its payload in, so that only happens on a
  /// mirror reset, and the next reply heals it.
  void _ensureAtlasFor(int needGen) {
    final ctrl = widget.controller;
    if (_atlasTextures != null && _atlasGenOnGpu >= needGen) return;
    if (ctrl._atlasGeneration < needGen) return;
    final curves = ctrl._atlas.curves;
    if (curves.isEmpty) return;
    _atlasTextures = uploadAtlasTextures(
      gpu.gpuContext,
      curves,
      ctrl._atlas.rows,
    );
    _atlasGenOnGpu = ctrl._atlasGeneration;
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

  /// Provisional height for a [GPUWidgetBlock] with no explicit or estimated
  /// height, until it is mounted and measured.
  static const double _defaultWidgetHeight = 120;

  double _heightOf(int i, double width) {
    final block = widget.blocks[i];
    final cached = _heights[block.id] ?? _live[block.id]?.height;
    if (cached != null) return cached;
    if (block is GPUWidgetBlock) {
      return block.height ?? block.estimatedHeight ?? _defaultWidgetHeight;
    }
    return _estimate(block as GPUTextDocument, width);
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
    // Highlights are painted at the block tops — shifted tops move them.
    if (_selections.isNotEmpty) _selHostBox?.markNeedsPaint();
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
        final dpr = _dpr;

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
        // Selection state follows the window, EXCEPT blocks holding a live
        // selection — their highlight must survive scroll-away-and-back.
        _selections.removeWhere((id, sel) {
          if (want.contains(id) || sel.hasSelection) return false;
          sel.repaint.removeListener(_onSelectionRepaint);
          sel.dispose();
          return true;
        });

        // Lay out any wanted block that is not yet live on the GPU.
        var newlyLaidOut = false;
        for (final i in wantIdx) {
          if (!mounted || gen != _gen || widget.controller._disposed) return;
          // Width/scroll changed mid-pass — abandon stale-width reflows and
          // let the outer loop restart with the latest geometry.
          if (_pending) break;
          final block = widget.blocks[i];
          if (block is! GPUTextDocument) {
            // Widget blocks never touch the worker. A fixed-height one is laid
            // out immediately (nothing to measure); a measured one is counted
            // by [_onWidgetBlockHeight] when [_widgetBlockLayer] mounts it.
            if (block is GPUWidgetBlock &&
                block.height != null &&
                !_heights.containsKey(block.id)) {
              _heights[block.id] = block.height!;
              _laidOut++;
              newlyLaidOut = true;
            }
            continue;
          }
          final doc = block;
          // A live block still needs a round trip when selection was enabled
          // after it synced (no geometry request answered yet). Attempted,
          // not "has geometry": a declined request (doc over the geometry
          // budget) must not re-sync forever.
          final needsGeometry =
              _selectionsEnabled &&
              !(_selections[doc.id]?.geometryAttempted ?? false);
          if (_live.containsKey(doc.id) && !needsGeometry) {
            _touchPrepared(doc.id);
            continue;
          }

          await widget.controller._ensurePrepared(
            doc.id,
            doc.runs,
            fallbackFontIds: doc.fallbackFontIds,
            emojiFontId: doc.emojiFontId,
            lineBreak: doc.lineBreak,
            language: doc.language,
          );
          if (!mounted || gen != _gen || widget.controller._disposed) return;
          if (_pending) break;
          _touchPrepared(doc.id);

          // The controller wrapper keeps the atlas mirror current: the reply
          // carries only the tail the mirror doesn't hold (usually nothing).
          final geometryRequested = _selectionsEnabled;
          final d = await widget.controller._reflowDoc(
            doc.id,
            width,
            style: doc.effectiveStyle,
            dpr: dpr,
            includeGeometry: geometryRequested,
          );
          if (!mounted || gen != _gen || widget.controller._disposed) return;
          if (_pending) break;
          if (_selectionsEnabled || _selections.containsKey(doc.id)) {
            _selectionFor(doc.id).applyDrawable(
              d.materializeGeometry(),
              Size(d.width, d.height),
              requested: geometryRequested,
            );
          }

          // Re-upload BEFORE the drawable goes live, so its instances never
          // reference rows missing from the texture (other live blocks stay
          // valid: the atlas is append-only).
          _ensureAtlasFor(d.atlasGeneration);

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
              final next = (_scroll.offset + delta).clamp(0.0, double.infinity);
              _scroll.jumpTo(next);
            }
          }

          final firstTime = !_heights.containsKey(doc.id);
          _heights[doc.id] = newH;
          if (firstTime) {
            _laidOut++;
            newlyLaidOut = true;
          }

          final colorStubs = [
            for (final s in d.colorGlyphStubs) _ColorStub.fromTransfer(s),
          ];
          if (colorStubs.isNotEmpty) {
            unawaited(
              widget.controller._ensureColorStubs(colorStubs).then((changed) {
                if (!mounted ||
                    gen != _gen ||
                    widget.controller._disposed ||
                    !changed) {
                  return;
                }
                final live = _live[doc.id];
                if (live == null) return;
                final color = _colorInstancesFromStubs(
                  colorStubs,
                  widget.controller.colorAtlas,
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
                _rasterEpoch++;
                if (mounted) setState(() {});
              }),
            );
          }
          final color = _colorInstancesFromStubs(
            colorStubs,
            widget.controller.colorAtlas,
          );
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

          // Height change shifts later tops — recompute before next block.
          _recomputeTops(width);
        }

        if (_pending) continue; // restart with latest width/scroll

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
          final max = (_totalHeight - _viewportH).clamp(0.0, double.infinity);
          if (_scroll.offset > max) _scroll.jumpTo(max);
        }

        // setState rebuilds scroll extent; doing that mid-fling also kills
        // ballistic motion. Defer to idle; still blit with current drawables.
        _rasterEpoch++;
        if (scrolling) {
          _pendingIdleSetState = true;
        } else if (mounted) {
          setState(() {});
        }
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

  /// Paint-time composite of live blocks into [logical]. Scroll offset is
  /// read live so [_GpuWindowImage] can pass cam as a scroll token.
  _GpuWindow? _rasterWindow(Size logical, double camX, double camY) {
    final surface = _surface;
    final textures = _atlasTextures;
    if (surface == null ||
        textures == null ||
        logical.isEmpty ||
        _contentWidth <= 0) {
      return null;
    }
    if (_tops.isEmpty && widget.blocks.isNotEmpty) {
      _recomputeTops(_contentWidth);
    }

    // camY carries -scrollOffset * dpr from the widget (see build).
    final offset = _dpr > 0 ? -camY / _dpr : 0.0;
    final width = logical.width;
    final viewportH = logical.height;
    final dpr = _dpr;

    final visible = _indicesInRange(offset, offset + viewportH, width);
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
    // Widen the window by the ink pad (cam shifted to match) so glyph ink at
    // the column margins isn't shaved; paint draws it shifted left again.
    final padDev = (_inkPadPx * dpr).round();
    for (final i in visible) {
      final doc = widget.blocks[i];
      final drawable = _live[doc.id];
      if (drawable == null) continue;
      final hasCoverage = drawable.instances != null && drawable.count > 0;
      final hasColor =
          drawable.colorInstances != null && drawable.colorCount > 0;
      if (!hasCoverage && !hasColor) continue;
      final top = _tops[i];
      draws.add((
        textures: textures,
        instances: drawable.instances,
        count: hasCoverage ? drawable.count : 0,
        camX: padDev.toDouble(),
        camY: (top - offset) * dpr,
        colorInstances: drawable.colorInstances,
        colorCount: hasColor ? drawable.colorCount : 0,
      ));
    }

    // Width-resize catch-up: nothing visible is live yet (the reflow round
    // trip is still in flight). Compositing now would blank the view — return
    // null and let [_GpuWindowImage.keepStale] hold the old-width window.
    if (draws.isEmpty && _keepStaleWindow && visible.isNotEmpty) {
      return null;
    }
    _keepStaleWindow = false;

    final image = surface.renderComposite(
      devW: ((width * dpr).round() + 2 * padDev).clamp(1, _maxDevicePx.round()),
      devH: (viewportH * dpr).round().clamp(1, _maxDevicePx.round()),
      dpr: dpr,
      // Transparent clear (the ColoredBox behind supplies the background) so
      // selection highlights painted under the image show through — same
      // layering as GPUTextView and the slivers.
      clear: vm.Vector4(0, 0, 0, 0),
      colorAtlas: widget.controller.colorAtlasTexture(),
      draws: draws,
    );
    if (image == null) return null;
    return (image: image, src: surface.contentRect);
  }

  Widget? _placeholderWidget(GPUTextDocument doc, int index) =>
      doc.placeholderWidgets[index] ??
      widget.placeholderBuilder?.call(context, index);

  Widget _placeholderOverlay() {
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final children = <Widget>[];
    for (var i = 0; i < widget.blocks.length; i++) {
      final block = widget.blocks[i];
      if (block is! GPUTextDocument) continue;
      final doc = block;
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

  /// Height reported by a mounted [GPUWidgetBlock]'s measurer. Mirrors the text
  /// reflow's height handling in [_syncWindow]: anchor scroll when a block above
  /// the viewport resizes, update the height cache + tops, and (deferred off an
  /// active fling) rebuild the scroll extent.
  void _onWidgetBlockHeight(String id, double newH) {
    if (!mounted) return;
    // The measurer fires during layout, where jumpTo/setState are illegal —
    // re-run after the frame, like the idle listener's [_midFrame] guard.
    if (_midFrame) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onWidgetBlockHeight(id, newH);
      });
      return;
    }
    final i = _blockIndexById[id];
    if (i == null ||
        i >= widget.blocks.length ||
        widget.blocks[i] is! GPUWidgetBlock) {
      return;
    }
    final width = _contentWidth;
    final oldH = _heightOf(i, width);
    if (_heights.containsKey(id) && (oldH - newH).abs() < 0.01) return;

    final scrolling = _isActivelyScrolling;
    // Scroll-anchor ONLY when idle (jumpTo mid-fling ends a ballistic scroll)
    // and only for a block entirely above the viewport top.
    if (!scrolling &&
        oldH != newH &&
        _scroll.hasClients &&
        i < _tops.length &&
        _tops[i] + oldH <= _scroll.offset) {
      final next = (_scroll.offset + (newH - oldH)).clamp(0.0, double.infinity);
      _scroll.jumpTo(next);
    }

    final firstTime = !_heights.containsKey(id);
    _heights[id] = newH;
    if (firstTime) {
      _laidOut++;
      if (scrolling) {
        _pendingLaidOutNotify = true;
      } else {
        widget.onLaidOutChanged?.call(_laidOut, widget.blocks.length);
      }
    }
    _recomputeTops(width);
    if (scrolling) {
      _pendingIdleSetState = true;
    } else {
      setState(() {});
    }
  }

  /// The [GPUWidgetBlock]s within the cache window, positioned in the scroll
  /// content so they scroll natively and hit-test through the transparent,
  /// IgnorePointer GPU-text overlay above them. Only in-window blocks are built
  /// (virtualized). The enclosing [AnimatedBuilder] rebuilds this each scroll
  /// tick, but the children sit at content coords under a [ValueKey], so a tick
  /// only mounts/unmounts at the cache boundary — it never repositions (which
  /// would cancel a fling).
  Widget _widgetBlockLayer() {
    final n = widget.blocks.length;
    if (n == 0 || _tops.length != n || _contentWidth <= 0) {
      return const SizedBox.shrink();
    }
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final cache = widget.cacheExtent;
    final want = _indicesInRange(
      offset - cache,
      offset + _viewportH + cache,
      _contentWidth,
    );
    final children = <Widget>[];
    for (final i in want) {
      final block = widget.blocks[i];
      if (block is! GPUWidgetBlock) continue;
      final built = block.builder(context);
      children.add(
        Positioned(
          key: ValueKey<String>(block.id),
          top: _tops[i],
          left: 0,
          width: _contentWidth,
          child: block.height != null
              ? SizedBox(height: block.height, child: built)
              : _MeasuredBlock(
                  id: block.id,
                  onHeight: _onWidgetBlockHeight,
                  child: built,
                ),
        ),
      );
    }
    return Stack(clipBehavior: Clip.none, children: children);
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
            final w = (constraints.maxWidth - _scrollbarGutter).clamp(
              1.0,
              double.infinity,
            );
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
                // Async sync — safe from build (setState lands later).
                // Height-only: [_GpuWindowImage] re-rasters via new constraints.
                _invalidateForWidth();
                _requestSync();
              }
            }
            // Keep scroll extent up to date even before the first sync lands —
            // otherwise extent == viewport and the scrollbar is a no-op.
            if (w > 0 &&
                widget.blocks.isNotEmpty &&
                _tops.length != widget.blocks.length) {
              _recomputeTops(w);
            }
            final extent = _totalHeight > 0 ? _totalHeight : vh;
            final scrollY = _scroll.hasClients ? _scroll.offset : 0.0;
            // Disable MaterialScrollBehavior's automatic desktop scrollbar —
            // we paint our own RawScrollbar above the GPU image (otherwise
            // you get two thumbs).
            return SizedBox.expand(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
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
                        physics:
                            widget.physics ??
                            const AlwaysScrollableScrollPhysics(),
                        // Content-sized selection host: anchors every
                        // block's fragments and paints their highlights.
                        // Bottom Stack child + transparent composite clear ⇒
                        // highlights render under the glyph image.
                        child: SizedBox(
                          width: double.infinity,
                          height: extent,
                          child: _SelectionScope(
                            registrarOverride: widget.selectionRegistrar,
                            colorOverride: widget.selectionColor,
                            onConfigure: _configureSelections,
                            // Selection host + widget-block media, both in
                            // content coords. The media rides this scroll view
                            // (native scroll + hit-testing) and shows through
                            // the transparent IgnorePointer glyph overlay above.
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: _BlocksSelectionHost(state: this),
                                ),
                                Positioned.fill(
                                  child: AnimatedBuilder(
                                    animation: _scroll,
                                    builder: (context, _) =>
                                        _widgetBlockLayer(),
                                  ),
                                ),
                              ],
                            ),
                          ),
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
                            child: SizedBox(
                              width: w,
                              height: vh,
                              child: AnimatedBuilder(
                                animation: _scroll,
                                builder: (context, _) => _GpuWindowImage(
                                  epoch: _rasterEpoch,
                                  dpr: _dpr,
                                  camX: 0,
                                  camY:
                                      -(_scroll.hasClients
                                          ? _scroll.offset
                                          : scrollY) *
                                      _dpr,
                                  rasterize: _rasterWindow,
                                  keepStale: _keepStaleWindow,
                                ),
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

/// Lays out its [child] at the incoming width (unbounded height) and reports the
/// child's laid-out height via [onHeight] whenever it changes — including async
/// changes: an image finishing decode relayouts the child, which relayouts this
/// proxy, which re-reports. Used by [GPUTextBlocksView] to size [GPUWidgetBlock]s
/// whose height is not fixed.
class _MeasuredBlock extends SingleChildRenderObjectWidget {
  const _MeasuredBlock({
    required this.id,
    required this.onHeight,
    required Widget super.child,
  });

  final String id;
  final void Function(String id, double height) onHeight;

  @override
  _RenderMeasuredBlock createRenderObject(BuildContext context) =>
      _RenderMeasuredBlock(id, onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasuredBlock ro) {
    ro
      ..id = id
      ..onHeight = onHeight;
  }
}

class _RenderMeasuredBlock extends RenderProxyBox {
  _RenderMeasuredBlock(this._id, this._onHeight);

  String _id;
  set id(String v) => _id = v;

  void Function(String, double) _onHeight;
  set onHeight(void Function(String, double) v) => _onHeight = v;

  double _reported = -1;

  @override
  void performLayout() {
    super.performLayout(); // RenderProxyBox sizes to the child
    final h = size.height;
    if ((h - _reported).abs() > 0.01) {
      _reported = h;
      _onHeight(_id, h);
    }
  }
}
