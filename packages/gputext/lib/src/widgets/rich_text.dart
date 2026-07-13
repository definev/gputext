// GPURichText — RichText-compatible widget; glyphs use the coverage shader.
//
// Layout is pure Dart (font metrics) in logical px; paint emits instances into
// an offscreen flutter_gpu surface at the effective scale and blits the
// cached ui.Image. transformAdaptive (default) follows the ancestor paint
// transform; pass scaleHint when a RepaintBoundary sits between a zooming
// TransformationController and this widget.
//
// WidgetSpan: extracted in preorder, measured in layout, woven as placeholders,
// painted/hit-tested as render children on top of the text image.
// Emoji / uncovered scripts: expandEmojiSpans / expandUncoveredSpans rewrite
// to baseline-aligned platform Text; flattener still resolves fontFamilyFallback
// + engine fallback for gputext-covered glyphs. Single-code-point COLR emoji
// stay in-text when the emoji font covers them.
//
// SelectionArea via per-fragment Selectables (source-text offsets). Link spans
// are actionable semantics nodes; hit-test returns the TextSpan for cursor /
// recognizer routing. Bidi via HarfBuzz + UAX #9; locale → OpenType language.
// Knuth–Plass is LTR-only. Foreground Paint: flat color only.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import '../engine/engine.dart';
import '../engine/pipeline.dart';
import '../font.dart' show GPUFont;
import '../layout.dart' as wf show LayoutBounds, ColorGlyphPlacement;
import '../paragraph.dart' as wf;
import '../timeline.dart';
import 'emoji.dart';
import 'span_flattener.dart';

const _maxSurfaceDim = 8192;

/// RichText-compatible widget backed by gputext layout + GPU coverage paint.
class GPURichText extends StatelessWidget {
  const GPURichText({
    super.key,
    required this.text,
    this.textAlign = TextAlign.start,
    this.textDirection,
    this.softWrap = true,
    this.overflow = TextOverflow.clip,
    this.textScaler = TextScaler.noScaling,
    this.maxLines,
    this.locale,
    this.strutStyle,
    this.textWidthBasis = TextWidthBasis.parent,
    this.textHeightBehavior,
    this.selectionRegistrar,
    this.selectionColor,
    this.transformAdaptive = true,
    this.scaleHint,
    this.filterQuality = FilterQuality.low,
    this.lineBreaker = wf.LineBreaker.greedy,
    this.coverageGamma = 1.0,
    this.coverageSharp = 1.0,
    this.minificationGuardPx = 3.7,
  }) : assert(maxLines == null || maxLines > 0);

  final InlineSpan text;
  final TextAlign textAlign;
  final TextDirection? textDirection;
  final bool softWrap;
  final TextOverflow overflow;
  final TextScaler textScaler;
  final int? maxLines;

  /// Strategy that chooses where lines break (greedy by default). Pass
  /// [wf.KnuthPlassLineBreaker] for TeX-style optimal justified paragraphs;
  /// alignment, ellipsis, and maxLines apply on top of any strategy.
  final wf.LineBreaker lineBreaker;

  /// OpenType language tag for HarfBuzz shaping ([Locale.toLanguageTag]).
  final Locale? locale;

  /// Selection registrar. Unlike RichText, a null registrar falls back to
  /// the enclosing [SelectionContainer] (Text.rich behavior), so a plain
  /// GPURichText participates in SelectionArea without extra plumbing.
  final SelectionRegistrar? selectionRegistrar;
  final Color? selectionColor;

  final StrutStyle? strutStyle;
  final TextWidthBasis textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;

  /// Re-render glyphs at the effective ancestor-transform scale so text stays
  /// crisp inside zooming containers.
  final bool transformAdaptive;

  /// Repaint trigger for zoom changes hidden behind RepaintBoundaries
  /// (e.g. an InteractiveViewer's TransformationController).
  final Listenable? scaleHint;

  final FilterQuality filterQuality;

  /// Perceptual coverage gamma (`FrameUniforms.style[0]`). `1.0` is exact.
  final double coverageGamma;

  /// Coverage contrast curve (`FrameUniforms.style[1]`). `1.0` is exact.
  final double coverageSharp;

  /// Device-px threshold for the banded-ink minification guard. Default
  /// `3.7` matches windfoil; raise toward `8` for thumbnail-heavy UIs.
  final double minificationGuardPx;

  @override
  Widget build(BuildContext context) {
    final registrar = selectionRegistrar ?? SelectionContainer.maybeOf(context);
    return ListenableBuilder(
      listenable: GPUText.instance,
      builder: (context, _) {
        var effective = expandEmojiSpans(text, GPUText.instance);
        effective = expandUncoveredSpans(effective, GPUText.instance);
        return _RawGPURichText(
          text: text,
          effectiveText: effective,
          textAlign: textAlign,
          textDirection: textDirection,
          softWrap: softWrap,
          overflow: overflow,
          textScaler: textScaler,
          maxLines: maxLines,
          locale: locale,
          strutStyle: strutStyle,
          textWidthBasis: textWidthBasis,
          textHeightBehavior: textHeightBehavior,
          selectionRegistrar: registrar,
          selectionColor: registrar == null
              ? selectionColor
              : selectionColor ??
                    DefaultSelectionStyle.of(context).selectionColor ??
                    DefaultSelectionStyle.defaultColor,
          transformAdaptive: transformAdaptive,
          scaleHint: scaleHint,
          filterQuality: filterQuality,
          lineBreaker: lineBreaker,
          coverageGamma: coverageGamma,
          coverageSharp: coverageSharp,
          minificationGuardPx: minificationGuardPx,
        );
      },
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DiagnosticsProperty<InlineSpan>('text', text));
    properties.add(EnumProperty<TextAlign>('textAlign', textAlign));
    properties.add(IntProperty('maxLines', maxLines, defaultValue: null));
  }
}

class _RawGPURichText extends MultiChildRenderObjectWidget {
  _RawGPURichText({
    required this.text,
    required this.effectiveText,
    this.textAlign = TextAlign.start,
    this.textDirection,
    this.softWrap = true,
    this.overflow = TextOverflow.clip,
    this.textScaler = TextScaler.noScaling,
    this.maxLines,
    this.locale,
    this.strutStyle,
    this.textWidthBasis = TextWidthBasis.parent,
    this.textHeightBehavior,
    this.selectionRegistrar,
    this.selectionColor,
    this.transformAdaptive = true,
    this.scaleHint,
    this.filterQuality = FilterQuality.low,
    this.lineBreaker = wf.LineBreaker.greedy,
    this.coverageGamma = 1.0,
    this.coverageSharp = 1.0,
    this.minificationGuardPx = 3.7,
  }) : assert(maxLines == null || maxLines > 0),
       super(
         children: WidgetSpan.extractFromInlineSpan(effectiveText, textScaler),
       );

  /// The original span, as passed in (RichText-compatible).
  final InlineSpan text;

  /// The emoji-expanded span tree that is actually laid out and painted.
  final InlineSpan effectiveText;
  final TextAlign textAlign;
  final TextDirection? textDirection;
  final bool softWrap;
  final TextOverflow overflow;
  final TextScaler textScaler;
  final int? maxLines;

  /// OpenType language tag for HarfBuzz shaping ([Locale.toLanguageTag]).
  final Locale? locale;
  final SelectionRegistrar? selectionRegistrar;
  final Color? selectionColor;

  final double coverageGamma;
  final double coverageSharp;
  final double minificationGuardPx;

  final StrutStyle? strutStyle;
  final TextWidthBasis textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;

  /// Re-render glyphs at the effective ancestor-transform scale so text stays
  /// crisp inside zooming containers.
  final bool transformAdaptive;

  /// Repaint trigger for zoom changes hidden behind RepaintBoundaries
  /// (e.g. an InteractiveViewer's TransformationController).
  final Listenable? scaleHint;

  final FilterQuality filterQuality;
  final wf.LineBreaker lineBreaker;

  @override
  RenderGPUParagraph createRenderObject(BuildContext context) {
    return RenderGPUParagraph(
        text: effectiveText,
        // The label is derived lazily from this span (placeholders excluded:
        // object-replacement chars are noise to screen readers, and WidgetSpan
        // children contribute their own semantics) — computing plain text on
        // every rebuild would tax paint-only updates.
        semanticsSource: text,
        textAlign: textAlign,
        textDirection: textDirection ?? Directionality.of(context),
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        devicePixelRatio:
            MediaQuery.maybeDevicePixelRatioOf(context) ??
            View.of(context).devicePixelRatio,
        transformAdaptive: transformAdaptive,
        scaleHint: scaleHint,
        filterQuality: filterQuality,
        lineBreaker: lineBreaker,
        coverageGamma: coverageGamma,
        coverageSharp: coverageSharp,
        minificationGuardPx: minificationGuardPx,
        strutStyle: strutStyle,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        locale: locale,
      )
      ..registrar = selectionRegistrar
      ..selectionColor = selectionColor;
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderGPUParagraph renderObject,
  ) {
    renderObject
      ..text = effectiveText
      ..semanticsSource = text
      ..textAlign = textAlign
      ..textDirection = textDirection ?? Directionality.of(context)
      ..softWrap = softWrap
      ..overflow = overflow
      ..textScaler = textScaler
      ..maxLines = maxLines
      ..devicePixelRatio =
          MediaQuery.maybeDevicePixelRatioOf(context) ??
          View.of(context).devicePixelRatio
      ..transformAdaptive = transformAdaptive
      ..scaleHint = scaleHint
      ..filterQuality = filterQuality
      ..lineBreaker = lineBreaker
      ..coverageGamma = coverageGamma
      ..coverageSharp = coverageSharp
      ..minificationGuardPx = minificationGuardPx
      ..strutStyle = strutStyle
      ..textWidthBasis = textWidthBasis
      ..textHeightBehavior = textHeightBehavior
      ..locale = locale
      ..registrar = selectionRegistrar
      ..selectionColor = selectionColor;
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DiagnosticsProperty<InlineSpan>('text', text));
    properties.add(EnumProperty<TextAlign>('textAlign', textAlign));
    properties.add(IntProperty('maxLines', maxLines, defaultValue: null));
  }
}

class RenderGPUParagraph extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, TextParentData>,
        RenderInlineChildrenContainerDefaults
    implements AtlasFontUser {
  RenderGPUParagraph({
    required this._text,
    required this._semanticsSource,
    required this._textAlign,
    required this._textDirection,
    required this._softWrap,
    required this._overflow,
    required this._textScaler,
    required this._maxLines,
    required this._devicePixelRatio,
    required this._transformAdaptive,
    required this._scaleHint,
    required this._filterQuality,
    required this._lineBreaker,
    this._coverageGamma = 1.0,
    this._coverageSharp = 1.0,
    this._minificationGuardPx = 3.7,
    this._strutStyle,
    this._textWidthBasis = TextWidthBasis.parent,
    this._textHeightBehavior,
    this._locale,
  });

  final GPUTextEngine _engine = GPUText.instance;

  wf.ParagraphLines? _para;
  List<wf.InlineItem>? _items;
  wf.PreparedParagraph? _prepared;
  List<wf.InlineItem>? _localRuns;

  /// True when [_items]/[_prepared] alias the engine's shared layout cache
  /// and must be cloned before paint-field mutation.
  bool _itemsFromSharedCache = false;
  Object? _localPrepareKey;
  wf.ParagraphGeometry? _geometryCache;
  int _geometryGen = -1;
  List<PlaceholderDimensions> _layoutDims = const [];
  double _boxWidth = 0; // alignment box = reported width
  double _lastWrapWidth = double.infinity;
  double _lastMaxWidth = double.infinity;
  List<wf.HitSpanBox> _hitBoxes = const [];
  bool _hasInteractiveSpans = false;
  bool _paraDirty = false; // paint-only span change pending recolor
  int _contentGen = 0; // bumped on any content change (layout or paint-only)

  wf.ParagraphInstances? _emitted;
  int _emittedGen = -1;
  int _emittedStructureGen = -1; // atlas.structureGeneration at emit time
  // colorAtlas.generation at emit time: an async emoji decode bumps it, and
  // (unlike content/structure) that arrives via a bare markNeedsPaint, so it
  // must gate the emit or the newly-decoded quad would never be emitted.
  int _emittedColorGen = -1;
  // Inputs the last actual emit ran against — the layout fast path (resize)
  // compares against these to prove a re-emit would be byte-identical without
  // running it. _emittedPara is the wrapped lines; _emittedPrepared is the
  // width-independent prepared paragraph (its identity == same glyph set).
  wf.ParagraphLines? _emittedPara;
  wf.PreparedParagraph? _emittedPrepared;
  double _emittedBoxWidth = 0;
  // Glyph set + atlas layout the ensureShaped walk last ran against; lets a
  // resize (same prepared, unchanged structureGen) skip re-banding.
  wf.PreparedParagraph? _ensuredPrepared;
  int _ensuredStructureGen = -1;
  // A paint-only span change (color/decoration) mutates run paint in place
  // without changing the prepared paragraph or the layout, so the layout fast
  // path can't detect it. Set when such a change lands, cleared on the next
  // actual emit; the fast path refuses to skip while it is set. Survives a
  // performLayout that consumed _paraDirty (recolor coinciding with a resize).
  bool _paintDirtiedSinceEmit = false;
  gpu.DeviceBuffer? _instanceBuffer;
  gpu.DeviceBuffer? _colorInstanceBuffer; // color-bitmap emoji quads
  gpu.GpuImageSurface? _surface;
  ui.Image? _image;
  // Superseded surface+image generations, each tagged with the number of the
  // frame whose paint replaced them. Disposed only once the engine reports a
  // frame at least that new has finished rasterizing (see _renderSurface).
  // Cap bounds growth if timings callbacks stall during rapid resize.
  static const _retiredCapacity = 8;
  final List<(gpu.GpuImageSurface?, ui.Image, int)> _retired = [];
  bool _timingsHooked = false;

  /// Identifies the surface currently in [_image]: the emitted instances (by
  /// object identity — a re-emit that comes out byte-identical keeps the same
  /// [_emitted] object, see [_prepareContent]), the render scale, and the
  /// coverage uniforms baked into the surface. An unchanged key means the
  /// cached image is still valid and paint re-blits it instead of re-rendering.
  (wf.ParagraphInstances, double, double, double, double)? _cacheKey;

  /// Benchmark counter: offscreen GPU renders (incl. resize/zoom re-renders).
  static int debugSurfaceRenders = 0;

  /// Benchmark counter: surface allocations (subset of [debugSurfaceRenders]
  /// that could not reuse the previous surface).
  static int debugSurfaceAllocs = 0;

  /// Benchmark counter: re-emits skipped because instances were byte-identical.
  static int debugSurfaceRenderSkips = 0;

  /// Force full re-upload + re-render (disables byte-identical skip). Bench only.
  static bool debugDisableRenderSkip = false;

  /// Bytes of the emitted per-glyph instance buffer (64 per glyph).
  int get debugInstanceBytes => _emitted?.instances.lengthInBytes ?? 0;

  /// Emitted per-glyph instance data (16 floats per glyph, rowBase at index
  /// 12). Baked against a specific atlas layout, so an atlas compaction must
  /// force it to be rebuilt — that is what the eviction tests assert.
  @visibleForTesting
  Float32List? get debugInstances => _emitted?.instances;

  /// Device-pixel size of the cached glyph image, null before first render.
  (int, int)? get debugImageSize {
    final img = _image;
    return img == null ? null : (img.width, img.height);
  }

  Rect _imageDevRect = Rect.zero;
  double _imageScale = 1;
  final LayerHandle<ClipRectLayer> _clipHandle = LayerHandle<ClipRectLayer>();

  InlineSpan get text => _text;
  InlineSpan _text;
  set text(InlineSpan value) {
    switch (_text.compareTo(value)) {
      case RenderComparison.identical:
        return;
      case RenderComparison.metadata:
        _text = value;
        _paraDirty = true; // hit boxes reference source spans — refresh
        _paintDirtiedSinceEmit = true; // recolor may outlive _paraDirty
        _contentGen++;
        markNeedsSemanticsUpdate();
        markNeedsPaint();
      case RenderComparison.paint:
        _text = value;
        _paraDirty = true;
        _paintDirtiedSinceEmit = true; // recolor may outlive _paraDirty
        _contentGen++;
        markNeedsSemanticsUpdate();
        markNeedsPaint();
      case RenderComparison.layout:
        _text = value;
        // Fragment ranges derive from the span tree — rebuild them.
        _disposeFragments();
        _createFragments();
        _needsRelayout();
    }
  }

  /// The original span the semantics label derives from. Plain text is
  /// computed lazily on first semantics query and cached — apps without
  /// active semantics never pay for it.
  InlineSpan _semanticsSource;
  String? _semanticsLabelCache;
  String get _semanticsLabel => _semanticsLabelCache ??= _semanticsSource
      .toPlainText(includePlaceholders: false);
  set semanticsSource(InlineSpan value) {
    if (identical(_semanticsSource, value)) return;
    _semanticsSource = value;
    final cached = _semanticsLabelCache;
    if (cached == null) return; // never queried — stay lazy
    final next = value.toPlainText(includePlaceholders: false);
    if (next == cached) return;
    _semanticsLabelCache = next;
    markNeedsSemanticsUpdate();
  }

  TextAlign _textAlign;
  set textAlign(TextAlign value) {
    if (_textAlign == value) return;
    _textAlign = value;
    _needsRelayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    _needsRelayout();
  }

  bool _softWrap;
  set softWrap(bool value) {
    if (_softWrap == value) return;
    _softWrap = value;
    _needsRelayout();
  }

  TextOverflow _overflow;
  set overflow(TextOverflow value) {
    if (_overflow == value) return;
    _overflow = value;
    _needsRelayout();
  }

  TextScaler _textScaler;
  set textScaler(TextScaler value) {
    if (_textScaler == value) return;
    _textScaler = value;
    _needsRelayout();
  }

  int? _maxLines;
  set maxLines(int? value) {
    if (_maxLines == value) return;
    _maxLines = value;
    _needsRelayout();
  }

  wf.LineBreaker _lineBreaker;
  set lineBreaker(wf.LineBreaker value) {
    if (_lineBreaker == value) return;
    _lineBreaker = value;
    _needsRelayout();
  }

  StrutStyle? _strutStyle;
  set strutStyle(StrutStyle? value) {
    if (_strutStyle == value) return;
    _strutStyle = value;
    _needsRelayout();
  }

  TextWidthBasis _textWidthBasis;
  set textWidthBasis(TextWidthBasis value) {
    if (_textWidthBasis == value) return;
    _textWidthBasis = value;
    _needsRelayout();
  }

  TextHeightBehavior? _textHeightBehavior;
  set textHeightBehavior(TextHeightBehavior? value) {
    if (_textHeightBehavior == value) return;
    _textHeightBehavior = value;
    _needsRelayout();
  }

  Locale? _locale;
  set locale(Locale? value) {
    if (_locale == value) return;
    _locale = value;
    _needsRelayout();
  }

  SelectionRegistrar? _registrar;
  set registrar(SelectionRegistrar? value) {
    if (identical(value, _registrar)) return;
    _disposeFragments();
    _registrar = value;
    _createFragments();
  }

  Color? _selectionColor;
  set selectionColor(Color? value) {
    if (_selectionColor == value) return;
    _selectionColor = value;
    markNeedsPaint();
  }

  List<_SelectableFragment>? _fragments;

  /// One selectable fragment per placeholder-free stretch of the source
  /// text, like RenderParagraph — WidgetSpan children register their own
  /// selectables, and on-screen ordering slots them between fragments.
  void _createFragments() {
    final registrar = _registrar;
    if (registrar == null) return;
    final ranges = <TextRange>[];
    var cursor = 0;
    var fragStart = 0;
    _text.visitChildren((span) {
      if (span is TextSpan) {
        cursor += span.text?.length ?? 0;
      } else if (span is PlaceholderSpan) {
        if (cursor > fragStart) {
          ranges.add(TextRange(start: fragStart, end: cursor));
        }
        cursor += 1; // the placeholder's '￼'
        fragStart = cursor;
      }
      return true;
    });
    if (cursor > fragStart) {
      ranges.add(TextRange(start: fragStart, end: cursor));
    }
    _fragments = [for (final r in ranges) _SelectableFragment(this, r)];
    _fragments!.forEach(registrar.add);
  }

  void _disposeFragments() {
    final fragments = _fragments;
    if (fragments == null) return;
    _fragments = null;
    for (final f in fragments) {
      _registrar?.remove(f);
      f.dispose();
    }
  }

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  bool _transformAdaptive;
  set transformAdaptive(bool value) {
    if (_transformAdaptive == value) return;
    _transformAdaptive = value;
    markNeedsPaint();
  }

  Listenable? _scaleHint;
  set scaleHint(Listenable? value) {
    if (identical(_scaleHint, value)) return;
    if (attached) _scaleHint?.removeListener(_onScaleHint);
    _scaleHint = value;
    if (attached) _scaleHint?.addListener(_onScaleHint);
  }

  FilterQuality _filterQuality;
  set filterQuality(FilterQuality value) {
    if (_filterQuality == value) return;
    _filterQuality = value;
    markNeedsPaint();
  }

  double _coverageGamma;
  set coverageGamma(double value) {
    if (_coverageGamma == value) return;
    _coverageGamma = value;
    _contentGen++;
    markNeedsPaint();
  }

  double _coverageSharp;
  set coverageSharp(double value) {
    if (_coverageSharp == value) return;
    _coverageSharp = value;
    _contentGen++;
    markNeedsPaint();
  }

  double _minificationGuardPx;
  set minificationGuardPx(double value) {
    if (_minificationGuardPx == value) return;
    _minificationGuardPx = value;
    _contentGen++;
    markNeedsPaint();
  }

  void _needsRelayout() {
    _para = null;
    _items = null;
    _prepared = null;
    _localRuns = null;
    _localPrepareKey = null;
    _itemsFromSharedCache = false;
    _paraDirty = false;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _engine.addListener(_onEngineChanged);
    _engine.registerAtlasClient(this);
    _scaleHint?.addListener(_onScaleHint);
    unawaited(_engine.ensureInitialized());
  }

  @override
  void detach() {
    _engine.removeListener(_onEngineChanged);
    _engine.unregisterAtlasClient(this);
    _scaleHint?.removeListener(_onScaleHint);
    // A detached render object (keep-alive list page, offstage tab, popped
    // route) must not pin a rendered image and surface texture pool — that
    // is width×height×4 device bytes per offscreen paragraph. Reattaching
    // repaints, which rebuilds them on demand.
    _releaseGpuArtifacts();
    super.detach();
  }

  /// Drop the GPU-backed paint artifacts. CPU layout state (paragraph,
  /// emitted instance floats) survives; the next paint re-uploads and
  /// re-renders from it.
  void _releaseGpuArtifacts() {
    if (_timingsHooked) {
      _timingsHooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    }
    for (final (_, img, _) in _retired) {
      img.dispose();
    }
    _retired.clear();
    _image?.dispose();
    _image = null;
    _surface = null;
    _instanceBuffer = null;
    _colorInstanceBuffer = null;
    _cacheKey = null;
  }

  /// Timings callback: frames reported here have finished rasterizing, so a
  /// superseded surface image that only a frame at least this old still
  /// referenced can no longer be on-screen and is safe to dispose (see
  /// _renderSurface). Unhooks itself once the retired queue drains.
  void _onFrameTimings(List<ui.FrameTiming> timings) {
    var latest = -1;
    for (final t in timings) {
      if (t.frameNumber > latest) latest = t.frameNumber;
    }
    while (_retired.isNotEmpty && _retired.first.$3 <= latest) {
      _retired.removeAt(0).$2.dispose();
    }
    if (_retired.isEmpty && _timingsHooked) {
      _timingsHooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    }
  }

  void _retireSurface(gpu.GpuImageSurface? surface, ui.Image image, int frame) {
    while (_retired.length >= _retiredCapacity) {
      _retired.removeAt(0).$2.dispose();
    }
    _retired.add((surface, image, frame));
    _hookTimings();
  }

  void _hookTimings() {
    if (_timingsHooked) return;
    _timingsHooked = true;
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  @override
  void dispose() {
    _disposeFragments();
    // detach() normally does all of this; belt-and-braces so a disposed
    // render object can never pin fonts, engine listeners, or GPU artifacts.
    _engine.removeListener(_onEngineChanged);
    _engine.unregisterAtlasClient(this);
    _scaleHint?.removeListener(_onScaleHint);
    _releaseGpuArtifacts();
    _clipHandle.layer = null;
    super.dispose();
  }

  void _onEngineChanged() {
    if (!attached) return;
    if (_para == null) {
      markNeedsLayout(); // fonts may have arrived — metrics can change
    } else if (hasSize) {
      markNeedsPaint(); // GPU became ready
    }
  }

  void _onScaleHint() {
    if (!attached || !hasSize) return;
    markNeedsPaint(); // cheap when the quantized scale didn't cross a step
  }

  wf.TextAlign get _resolvedAlign => switch (_textAlign) {
    TextAlign.left => wf.TextAlign.left,
    TextAlign.right => wf.TextAlign.right,
    TextAlign.center => wf.TextAlign.center,
    TextAlign.justify => wf.TextAlign.justify,
    TextAlign.start =>
      _textDirection == TextDirection.rtl
          ? wf.TextAlign.right
          : wf.TextAlign.left,
    TextAlign.end =>
      _textDirection == TextDirection.rtl
          ? wf.TextAlign.left
          : wf.TextAlign.right,
  };

  wf.ParagraphStyle _styleFor(double wrapWidth) => wf.ParagraphStyle(
    maxWidth: wrapWidth,
    align: _resolvedAlign,
    maxLines: _maxLines,
    addEllipsis: _overflow == TextOverflow.ellipsis,
    lineBreaker: _lineBreaker,
    strut: _resolveStrut(),
    applyHeightToFirstAscent:
        _textHeightBehavior?.applyHeightToFirstAscent ?? true,
    applyHeightToLastDescent:
        _textHeightBehavior?.applyHeightToLastDescent ?? true,
    evenLeading:
        _textHeightBehavior?.leadingDistribution ==
        TextLeadingDistribution.even,
  );

  /// StrutStyle → resolved px metrics. Null while the strut font isn't
  /// registered (strut skipped; layout reruns when fonts land).
  wf.StrutMetrics? _resolveStrut() {
    final s = _strutStyle;
    if (s == null) return null;
    final font = _engine.resolveFont(
      s.fontFamily ?? _text.style?.fontFamily,
      weight: s.fontWeight,
      fontStyle: s.fontStyle,
    );
    if (font == null) return null;
    final fontSize = _textScaler.scale(
      s.fontSize ?? _text.style?.fontSize ?? 14.0,
    );
    final m = font.verticalMetrics;
    var ascent = m.ascender / font.unitsPerEm * fontSize;
    var descent = -m.descender / font.unitsPerEm * fontSize;
    final heightMul = s.height;
    if (heightMul != null && ascent + descent > 0) {
      // Height multiplier: the strut extent becomes height*fontSize, split
      // proportionally to the font's natural ascent/descent (SkParagraph).
      final f = heightMul * fontSize / (ascent + descent);
      ascent *= f;
      descent *= f;
    }
    final leading = (s.leading ?? (m.lineGap / font.unitsPerEm)) * fontSize;
    return wf.StrutMetrics(
      ascent: ascent,
      descent: descent,
      leading: leading,
      force: s.forceStrutHeight ?? false,
    );
  }

  wf.ParagraphLines _break(
    wf.PreparedParagraph prepared,
    double wrapWidth,
    double maxWidth,
  ) {
    final para = wf.layoutPreparedLines(
      prepared,
      wrapWidth,
      _styleFor(wrapWidth),
    );
    // softWrap:false + ellipsis truncates each overlong line at the box edge.
    if (_overflow == TextOverflow.ellipsis && !_softWrap && maxWidth.isFinite) {
      for (final line in para.lines) {
        final lastRun = line.items.isEmpty ? null : line.items.last;
        final last = lastRun is wf.LineRun ? lastRun.text : null;
        if (line.width > maxWidth && last != '…' && last != '...') {
          wf.ellipsizeLine(line, maxWidth);
        }
      }
    }
    return para;
  }

  /// Cache key for flatten+prepare results (paragraphs without inline
  /// children only — placeholder dimensions vary per widget). Prepared
  /// paragraphs are width-independent, so the key carries no constraints:
  /// resize relayouts and all intrinsic passes reuse one entry. Keyed on a
  /// paint-INDEPENDENT [SpanLayoutKey] so color-only variants (animations,
  /// the same label in two colors) reuse one shaped layout; a hit adopts it
  /// by cloning + recoloring (see [_flattenAndPrepare]). fontGeneration
  /// True when any span in [_text] carries a gesture recognizer.
  bool _hasRecognizer() {
    var found = false;
    _text.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  /// invalidates on font churn.
  Object? _prepareCacheKey() {
    if (childCount > 0) return null;
    // Spans with recognizers stay out of the process-lifetime shared cache:
    // an entry would pin the recognizer and everything its callbacks capture
    // (State, BuildContext) after the widget is gone — and since TextSpan ==
    // compares recognizers by identity, a widget minting a fresh recognizer
    // per build would insert a new dead entry on every rebuild.
    if (_hasRecognizer()) return null;
    return (
      SpanLayoutKey(_text),
      _textScaler,
      _engine.fontGeneration,
      _textDirection,
      _locale,
    );
  }

  Object _dimsSignature(List<PlaceholderDimensions> dims) {
    if (dims.isEmpty) return 0;
    return Object.hashAll([
      for (final d in dims)
        Object.hash(d.size.width, d.size.height, d.baselineOffset),
    ]);
  }

  /// Per-render-object memo key. Includes placeholder dims when present so
  /// WidgetSpan size changes invalidate; shares the TextSpan identity with
  /// the engine cache when that applies.
  Object _localKey(List<PlaceholderDimensions> dims) {
    final shared = _prepareCacheKey();
    if (shared != null) return shared;
    return (
      _text,
      _textScaler,
      _engine.fontGeneration,
      _textDirection,
      _locale,
      _dimsSignature(dims),
    );
  }

  void _rememberPrepared(
    Object localKey,
    List<wf.InlineItem>? runs,
    wf.PreparedParagraph? prepared, {
    required bool fromSharedCache,
  }) {
    _localPrepareKey = localKey;
    _localRuns = runs;
    _prepared = prepared;
    _itemsFromSharedCache = fromSharedCache && prepared != null;
  }

  /// A [wf.PreparedParagraph] over [cloned] reusing [src]'s width-independent
  /// analysis (line-break, segments, intrinsics reference items by index, so
  /// an index-aligned clone keeps them valid). Shaped glyph data is shared via
  /// the clone; only paint fields diverge.
  static wf.PreparedParagraph _clonedPreparedFrom(
    List<wf.InlineItem> cloned,
    wf.PreparedParagraph src,
  ) => wf.PreparedParagraph(
    items: cloned,
    lineBreak: src.lineBreak,
    segmentTexts: src.segmentTexts,
    segmentPieces: src.segmentPieces,
    graphemeEndOffsets: src.graphemeEndOffsets,
    minIntrinsicWidth: src.minIntrinsicWidth,
    maxIntrinsicWidth: src.maxIntrinsicWidth,
    fallbackStyleItem: src.fallbackStyleItem,
  );

  /// Clone items out of the shared layout cache before mutating paint
  /// fields, then re-break so LineRuns alias the new color lists.
  void _detachItemsIfShared() {
    if (!_itemsFromSharedCache) return;
    final items = _items;
    final prepared = _prepared;
    if (items == null || prepared == null) {
      _itemsFromSharedCache = false;
      return;
    }
    final cloned = cloneInlineItemsForPaint(items);
    _items = cloned;
    _localRuns = cloned;
    _prepared = _clonedPreparedFrom(cloned, prepared);
    _para = _break(_prepared!, _lastWrapWidth, _lastMaxWidth);
    _itemsFromSharedCache = false;
  }

  /// Take a private, correctly-painted copy of a shared-cache layout: clone
  /// the read-only items (sharing shaped glyph data) and re-apply THIS span's
  /// paint + source pointers. Returns null when the span no longer matches the
  /// cached structure, so the caller reshapes from scratch. The clone is
  /// owned (not `fromSharedCache`), so a later recolor mutates it in place.
  (List<wf.InlineItem>, wf.PreparedParagraph)? _adoptSharedLayout(
    List<wf.InlineItem> sharedRuns,
    wf.PreparedParagraph sharedPrepared,
    Object localKey,
  ) {
    final cloned = cloneInlineItemsForPaint(sharedRuns);
    if (!patchInlineItemsPaint(cloned, _text)) return null;
    final prepared = _clonedPreparedFrom(cloned, sharedPrepared);
    _rememberPrepared(localKey, cloned, prepared, fromSharedCache: false);
    return (cloned, prepared);
  }

  void _syncLinePaintFromItems() {
    final items = _items;
    final para = _para;
    if (items == null || para == null) return;
    for (final line in para.lines) {
      for (final item in line.items) {
        if (item is wf.LineRun && item.itemIndex >= 0) {
          final run = items[item.itemIndex] as wf.TextRun;
          item.color = run.color;
          item.background = run.background;
          item.decoration = run.decoration;
          item.shadows = run.shadows;
          item.source = run.source;
        }
        // LineEmoji holds the EmojiItem by reference — already patched.
      }
    }
  }

  /// Paint/metadata-only update: recolor existing runs in place. Falls back
  /// to a full flatten+prepare when the span tree no longer matches.
  bool _recolorPrepared() {
    final items = _items;
    if (items == null || _prepared == null || _para == null) return false;
    // Reuse (and LRU-rewarm) the shared layout entry: the key is
    // paint-independent, so a long color animation keeps hitting one entry
    // instead of letting it age out and forcing a reshape on the next miss.
    final key = _prepareCacheKey();
    if (key != null) _engine.layoutCacheGet(key);
    _detachItemsIfShared();
    if (!patchInlineItemsPaint(_items!, _text)) return false;
    _syncLinePaintFromItems();
    _localRuns = _items;
    _localPrepareKey = _localKey(_layoutDims);
    return true;
  }

  /// Flatten + prepare (measure) the span, through the engine's shared
  /// cache and a per-render-object memo. Returns a null paragraph while
  /// fonts are loading or for empty text (`runs` distinguishes the two,
  /// matching flattenSpan).
  (List<wf.InlineItem>?, wf.PreparedParagraph?) _flattenAndPrepare(
    List<PlaceholderDimensions> dims,
  ) {
    final localKey = _localKey(dims);
    if (_localPrepareKey == localKey && _prepared != null) {
      return (_localRuns ?? _prepared!.items, _prepared);
    }
    final key = _prepareCacheKey();
    if (key != null) {
      final cached = _engine.layoutCacheGet(key);
      if (cached != null) {
        // The entry is paint-independent (any color that shares this layout
        // may have inserted it), so adopt a recolored private copy. Only if
        // the structure unexpectedly disagrees do we fall through to reshape.
        final adopted = _adoptSharedLayout(cached.$1, cached.$2, localKey);
        if (adopted != null) return adopted;
      }
    }
    final runs = flattenSpan(
      _text,
      _textScaler,
      _engine,
      placeholderDimensions: dims,
      textDirection: _textDirection,
      locale: _locale,
    );
    if (runs == null || runs.isEmpty) {
      _rememberPrepared(localKey, runs, null, fromSharedCache: false);
      return (runs, null);
    }
    final prepared = wf.prepareParagraph(runs);
    var fromShared = false;
    if (key != null) {
      // Cost in UTF-16 units so the engine can bound cache bytes, not just
      // entry count (shaped-run size tracks text length).
      var cost = 0;
      for (final r in runs) {
        cost += r is wf.TextRun ? r.originalText.length : 1;
      }
      _engine.layoutCachePut(key, (runs, prepared), cost: cost);
      fromShared = true;
    }
    _rememberPrepared(localKey, runs, prepared, fromSharedCache: fromShared);
    return (runs, prepared);
  }

  ({
    wf.ParagraphLines? para,
    List<wf.InlineItem>? runs,
    Size size,
    double boxWidth,
    double wrapWidth,
  })
  _computeLayout(BoxConstraints constraints, List<PlaceholderDimensions> dims) {
    final (runs, prepared) = _flattenAndPrepare(dims);
    if (prepared == null) {
      // Fonts not loaded yet, or genuinely empty text: report one line height
      // when we can resolve the root style's font, else collapse.
      var height = 0.0;
      final font = _engine.resolveFont(_text.style?.fontFamily);
      if (font != null && runs != null) {
        height = wf.lineExtentOf(
          font,
          _textScaler.scale(_text.style?.fontSize ?? 14.0),
        );
      }
      return (
        para: null,
        runs: runs,
        size: constraints.constrain(Size(0, height)),
        boxWidth: 0,
        wrapWidth: double.infinity,
      );
    }
    final wrapWidth = _softWrap && constraints.maxWidth.isFinite
        ? constraints.maxWidth
        : double.infinity;
    final para = _break(prepared, wrapWidth, constraints.maxWidth);
    // TextPainter's width rule: report the unwrapped intrinsic width clamped
    // to the constraints, and align lines against THAT box (never against an
    // unbounded constraint). TextWidthBasis.longestLine hugs the laid-out
    // lines instead.
    var basis = para.maxIntrinsicWidth;
    if (_textWidthBasis == TextWidthBasis.longestLine) {
      basis = 0;
      for (final l in para.lines) {
        if (l.width > basis) basis = l.width;
      }
    }
    final width = ui.clampDouble(
      basis,
      constraints.minWidth,
      constraints.maxWidth,
    );
    return (
      para: para,
      runs: runs,
      size: constraints.constrain(Size(width, para.height)),
      boxWidth: width,
      wrapWidth: wrapWidth,
    );
  }

  List<PlaceholderDimensions> _dryDims(double maxWidth) => childCount == 0
      ? const []
      : layoutInlineChildren(
          maxWidth,
          ChildLayoutHelper.dryLayoutChild,
          ChildLayoutHelper.getDryBaseline,
        );

  @override
  void performLayout() {
    GPUTextTimeline.timeSync(GPUTextTimeline.performLayout, () {
      _layoutDims = childCount == 0
          ? const []
          : layoutInlineChildren(
              constraints.maxWidth,
              ChildLayoutHelper.layoutChild,
              ChildLayoutHelper.getBaseline,
            );
      final r = _computeLayout(constraints, _layoutDims);
      _para = r.para;
      _items = r.runs;
      _boxWidth = r.boxWidth;
      _lastWrapWidth = r.wrapWidth;
      _lastMaxWidth = constraints.maxWidth;
      // A color change (RenderComparison.paint) that coincided with a relayout
      // set _paraDirty with no paint in between; the paint-independent memo may
      // have handed back the pre-change colors, so apply the pending recolor
      // now. A fresh flatten/adopt already carries the right paint, so this is
      // a cheap no-op patch in that case.
      if (_paraDirty && r.para != null) _recolorPrepared();
      _paraDirty = false;
      _contentGen++;
      size = r.size;
      // Recognizers, hover callbacks, and non-default mouse cursors all need
      // span hit boxes.
      bool interactive(Object? source) =>
          source is TextSpan &&
          (source.recognizer != null ||
              source.onEnter != null ||
              source.onExit != null ||
              source.mouseCursor != MouseCursor.defer);
      _hasInteractiveSpans =
          r.runs?.any(
            (i) =>
                (i is wf.TextRun && interactive(i.source)) ||
                (i is wf.EmojiItem && interactive(i.source)),
          ) ??
          false;
      _hitBoxes = const [];
      final para = r.para;
      if ((childCount > 0 || _hasInteractiveSpans) && para != null) {
        final walk = wf.emitInstances(para, r.boxWidth, _resolvedAlign, null);
        _hitBoxes = walk.hitBoxes;
        if (childCount > 0) {
          positionInlineChildren([
            for (final b in walk.placeholders)
              ui.TextBox.fromLTRBD(
                b.left,
                b.top,
                b.left + b.width,
                b.top + b.height,
                _textDirection,
              ),
          ]);
        }
      }
      // Selection geometry (handle points, rects) shifts with layout.
      final fragments = _fragments;
      if (fragments != null) {
        for (final f in fragments) {
          f.didChangeParagraphLayout();
        }
      }
    });
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _computeLayout(constraints, _dryDims(constraints.maxWidth)).size;

  @override
  double computeMinIntrinsicWidth(double height) {
    // Straight off the prepared arrays — no line breaking at all.
    final (_, prepared) = _flattenAndPrepare(_dryDims(double.infinity));
    return prepared?.minIntrinsicWidth ?? 0;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final (_, prepared) = _flattenAndPrepare(_dryDims(double.infinity));
    return prepared?.maxIntrinsicWidth ?? 0;
  }

  @override
  double computeMinIntrinsicHeight(double width) => _computeLayout(
    BoxConstraints(maxWidth: width),
    _dryDims(width),
  ).size.height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      _para?.firstBaseline;

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) => _computeLayout(
    constraints,
    _dryDims(constraints.maxWidth),
  ).para?.firstBaseline;

  // Offsets are in the paragraph's SOURCE text (effectiveText's plain text:
  // pre-shaping characters, '￼' per placeholder). Boundaries inside a
  // rendered ligature interpolate across the cluster's advance.

  wf.ParagraphGeometry? get _geometry {
    final para = _para;
    final items = _items;
    if (para == null || items == null) return null;
    if (_geometryCache == null || _geometryGen != _contentGen) {
      _geometryCache = wf.ParagraphGeometry(
        items: items,
        para: para,
        boxWidth: _boxWidth,
        align: _resolvedAlign,
      );
      _geometryGen = _contentGen;
    }
    return _geometryCache;
  }

  /// The source-text position closest to a local point.
  TextPosition getPositionForOffset(Offset offset) {
    final g = _geometry;
    if (g == null) return const TextPosition(offset: 0);
    final pos = g.positionForOffset(offset.dx, offset.dy);
    return TextPosition(
      offset: pos.offset,
      affinity: pos.upstream ? TextAffinity.upstream : TextAffinity.downstream,
    );
  }

  /// Top-left of the caret for `position` (place `caretPrototype` there).
  Offset getOffsetForCaret(TextPosition position, Rect caretPrototype) {
    final g = _geometry;
    if (g == null) return Offset.zero;
    final c = g.caretAt(
      position.offset,
      upstream: position.affinity == TextAffinity.upstream,
    );
    return Offset(c.x, c.top);
  }

  double? getFullHeightForCaret(TextPosition position) {
    final g = _geometry;
    if (g == null) return null;
    return g
        .caretAt(
          position.offset,
          upstream: position.affinity == TextAffinity.upstream,
        )
        .height;
  }

  List<ui.TextBox> getBoxesForSelection(TextSelection selection) {
    final g = _geometry;
    if (g == null || !selection.isValid || selection.isCollapsed) {
      return const [];
    }
    return [
      for (final b in g.boxesForRange(selection.start, selection.end))
        ui.TextBox.fromLTRBD(b.left, b.top, b.right, b.bottom, _textDirection),
    ];
  }

  TextRange getWordBoundary(TextPosition position) {
    final g = _geometry;
    if (g == null) return const TextRange.collapsed(0);
    final r = wf.wordRangeIn(g.plainText, position.offset);
    return TextRange(start: r.start, end: r.end);
  }

  TextRange getLineBoundary(TextPosition position) {
    final g = _geometry;
    if (g == null) return const TextRange.collapsed(0);
    final line = g
        .caretAt(
          position.offset,
          upstream: position.affinity == TextAffinity.upstream,
        )
        .line;
    final r = g.lineRange(line);
    return TextRange(start: r.start, end: r.end);
  }

  /// The paragraph's source text (the offset space of the APIs above).
  String get plainText => _geometry?.plainText ?? '';

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (hitTestInlineChildren(result, position)) return true;
    // Like RenderParagraph: put the hit TextSpan itself on the result.
    // TextSpan is a HitTestTarget (its handleEvent feeds recognizers on
    // pointer-down) and a MouseTrackerAnnotation (mouseCursor / onEnter /
    // onExit hover), so both dispatch paths come for free.
    for (final b in _hitBoxes) {
      if (b.contains(position.dx, position.dy)) {
        final source = b.source;
        if (source is HitTestTarget) {
          result.add(HitTestEntry(source));
          return true;
        }
      }
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      defaultApplyPaintTransform(child, transform);

  /// Child semantics nodes by ordinal, kept stable across assembles so
  /// assistive tech doesn't see nodes churn (RenderParagraph does the same).
  Map<int, SemanticsNode>? _semanticsChildCache;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (_hasRecognizer()) {
      // Per-span child nodes (assembleSemanticsNode below) so links are
      // exposed as individually actionable nodes, like RenderParagraph.
      config
        ..explicitChildNodes = true
        ..isSemanticBoundary = true;
    } else {
      config
        ..label = _semanticsLabel
        ..textDirection = _textDirection;
    }
  }

  @override
  void assembleSemanticsNode(
    SemanticsNode node,
    SemanticsConfiguration config,
    Iterable<SemanticsNode> children,
  ) {
    final newChildren = <SemanticsNode>[];
    final childNodes = children.toList();
    final cache = _semanticsChildCache ??= {};
    var childIndex = 0;
    var placeholderIndex = 0;
    var ordinal = 0;

    _text.visitChildren((span) {
      if (span is PlaceholderSpan) {
        // WidgetSpan children were tagged with their placeholder index by
        // WidgetSpan.extractFromInlineSpan; one placeholder may contribute
        // zero or many nodes.
        final tag = PlaceholderSpanIndexSemanticsTag(placeholderIndex);
        while (childIndex < childNodes.length &&
            childNodes[childIndex].isTagged(tag)) {
          newChildren.add(childNodes[childIndex]);
          childIndex++;
        }
        placeholderIndex++;
        return true;
      }
      if (span is! TextSpan) return true;
      final label = span.semanticsLabel ?? span.text ?? '';
      if (label.isEmpty) return true;
      // The span's rect: union of its laid-out run boxes. Absent boxes mean
      // the span isn't rendered (fonts pending / fully truncated) — skip.
      Rect? rect;
      for (final b in _hitBoxes) {
        if (!identical(b.source, span)) continue;
        final r = Rect.fromLTWH(b.left, b.top, b.width, b.height);
        rect = rect == null ? r : rect.expandToInclude(r);
      }
      if (rect == null) return true;

      final childConfig = SemanticsConfiguration()
        ..label = label
        ..textDirection = _textDirection;
      switch (span.recognizer) {
        case final TapGestureRecognizer tap when tap.onTap != null:
          childConfig
            ..isLink = true
            ..onTap = tap.onTap;
        case final DoubleTapGestureRecognizer tap when tap.onDoubleTap != null:
          childConfig
            ..isLink = true
            ..onTap = tap.onDoubleTap;
        case final LongPressGestureRecognizer lp when lp.onLongPress != null:
          childConfig.onLongPress = lp.onLongPress;
        default:
          break;
      }
      final child = cache[ordinal] ??= SemanticsNode();
      child
        ..rect = rect
        ..updateWith(config: childConfig);
      newChildren.add(child);
      ordinal++;
      return true;
    });
    // Nodes past the highest ordinal this assemble produced belong to spans
    // that no longer exist; keeping them would retain SemanticsNodes for the
    // render object's lifetime after rich content shrinks.
    cache.removeWhere((k, _) => k >= ordinal);

    // Untagged (or unexpectedly ordered) child nodes must never be dropped.
    while (childIndex < childNodes.length) {
      newChildren.add(childNodes[childIndex]);
      childIndex++;
    }

    node.updateWith(config: config, childrenInInversePaintOrder: newChildren);
  }

  @override
  void clearSemantics() {
    super.clearSemantics();
    _semanticsChildCache = null;
  }

  /// Every font this paragraph has (or will have) banded, so the engine's atlas
  /// sweep keeps them. Must stay in step with the ensureGlyphs walk in
  /// [_prepareContent] — a font missed here is evicted and re-banded next
  /// paint, which is correct but wasteful.
  @override
  void visitAtlasFonts(void Function(GPUFont font) visit) {
    final para = _para;
    if (para == null) return;
    for (final line in para.lines) {
      for (final item in line.items) {
        if (item is wf.LineRun) {
          visit(item.font);
        } else if (item is wf.LineEmoji) {
          visit(item.item.font);
        }
      }
    }
  }

  void _prepareContent() {
    GPUTextTimeline.timeSync(GPUTextTimeline.prepareContent, () {
      if (_paraDirty) {
        // Paint-only span change (e.g. colors): reuse shaped/prepared layout
        // and patch paint fields in place. Metrics are unchanged by
        // construction of RenderComparison.paint.
        if (!_recolorPrepared()) {
          final (runs, prepared) = _flattenAndPrepare(_layoutDims);
          if (prepared != null) {
            _para = _break(prepared, _lastWrapWidth, _lastMaxWidth);
            _items = runs;
          }
        }
        _paraDirty = false;
      }
      final para = _para;
      if (para == null) return;
      // A compaction relocated every rowBase, so instances emitted against the
      // old layout are stale even when our own content hasn't changed.
      final structureGen = _engine.atlas.structureGeneration;
      final colorGen = _engine.colorAtlas.generation;
      if (_emitted == null ||
          _emittedGen != _contentGen ||
          _emittedStructureGen != structureGen ||
          _emittedColorGen != colorGen) {
        final prepared = _prepared;
        // Layout fast path — the resize-width win. When the glyph set (prepared
        // identity), the atlas layout (structureGen), and the line partition
        // are all unchanged, and no recolor touched paint, the emit is
        // guaranteed byte-identical: skip ensureShaped, emitInstances, and the
        // offscreen render together and reuse the cached artifacts. Positions
        // are box-width-independent for left/start-LTR; other alignments and
        // justify also need the box width unchanged.
        if (!_paintDirtiedSinceEmit &&
            !debugDisableRenderSkip &&
            _emitted != null &&
            _emittedPara != null &&
            _emittedStructureGen == structureGen &&
            _emittedColorGen == colorGen &&
            identical(prepared, _emittedPrepared) &&
            (_resolvedAlign == wf.TextAlign.left ||
                _boxWidth == _emittedBoxWidth) &&
            _sameLayout(para, _emittedPara!)) {
          _emittedGen = _contentGen;
          _emittedPara = para;
          debugSurfaceRenderSkips++;
        } else {
          // Ensure glyphs are banded. Skip the walk when the glyph set
          // (prepared identity) and atlas layout (structureGen) are unchanged
          // since we last banded — our fonts are pinned and growth keeps
          // rowBase, so the glyphs are provably still resident and re-checking
          // every one is pure map-lookup overhead.
          if (!identical(prepared, _ensuredPrepared) ||
              _ensuredStructureGen != structureGen) {
            for (final line in para.lines) {
              for (final item in line.items) {
                if (item is wf.LineRun) {
                  _engine.atlas.ensureShaped(item.shaped);
                } else if (item is wf.LineEmoji) {
                  final e = item.item;
                  if (e.isBitmap) {
                    // Kicks off async PNG decode; a re-render follows once the
                    // atlas generation bumps (gated above via colorGen). Strike
                    // is chosen in DEVICE pixels (× DPR) so Retina gets a
                    // crisper strike — must match _resolveColorGlyph's target.
                    _engine.ensureBitmapGlyph(
                      e.font,
                      e.bitmapGlyphId!,
                      e.fontSizePx * _devicePixelRatio,
                    );
                  } else {
                    for (final layer in e.layers) {
                      _engine.atlas.ensureGlyphId(e.font, layer.glyphId);
                    }
                  }
                }
              }
            }
            _ensuredPrepared = prepared;
            _ensuredStructureGen = _engine.atlas.structureGeneration;
          }
          final fresh = wf.emitInstances(
            para,
            _boxWidth,
            _resolvedAlign,
            _engine.atlas,
            colorLookup: _resolveColorGlyph,
          );
          // Re-read: ensureGlyphs above cannot compact, only grow, and
          // emitInstances read the table as it stands now.
          final freshStructureGen = _engine.atlas.structureGeneration;
          final freshColorGen = _engine.colorAtlas.generation;
          final prev = _emitted;
          if (!debugDisableRenderSkip &&
              prev != null &&
              _emittedStructureGen == freshStructureGen &&
              _sameInstances(prev.instances, fresh.instances) &&
              _sameInstances(prev.colorInstances, fresh.colorInstances)) {
            // Byte-identical to the live buffer even though the cheap layout
            // check bailed (e.g. first frame after a structure change): keep
            // the uploaded buffer, image, and render cache key.
            _emittedGen = _contentGen;
            _emittedColorGen = freshColorGen;
            debugSurfaceRenderSkips++;
          } else {
            _emitted = fresh;
            _hitBoxes = fresh.hitBoxes;
            _instanceBuffer = null;
            _colorInstanceBuffer = null;
            _emittedGen = _contentGen;
            _emittedStructureGen = freshStructureGen;
            _emittedColorGen = freshColorGen;
            _cacheKey = null;
          }
          _emittedPara = para;
          _emittedPrepared = prepared;
          _emittedBoxWidth = _boxWidth;
          _paintDirtiedSinceEmit = false;
        }
      }
      _engine.scheduleAtlasSweepIfNeeded();
    });
  }

  double _quantizeScale(double s) {
    final dpr = _devicePixelRatio;
    if (!s.isFinite || s <= 0) return dpr;
    final steps = (math.log(s / dpr) / math.log(1.25)).round();
    return dpr * math.pow(1.25, steps).toDouble();
  }

  /// Emit-time lookup of a decoded color-bitmap glyph. Null until the async
  /// decode packs it (a re-emit follows once colorAtlas.generation bumps).
  wf.ColorGlyphPlacement? _resolveColorGlyph(
    GPUFont font,
    int glyphId,
    double targetPpem,
  ) {
    // Device-pixel target (× DPR) — must match the ensureBitmapGlyph call so
    // the resolved strike key is identical.
    final strike = _engine.colorAtlas.strikeFor(
      font,
      targetPpem * _devicePixelRatio,
    );
    if (strike == null) return null;
    final e = _engine.colorAtlas.lookup(font, glyphId, strike);
    if (e == null) return null;
    return wf.ColorGlyphPlacement(
      u0: e.u0,
      v0: e.v0,
      u1: e.u1,
      v1: e.v1,
      width: e.width,
      height: e.height,
      ppem: e.ppem,
      bearingX: e.bearingX,
      bearingY: e.bearingY,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    _prepareContent(); // CPU-only (atlas + instance emission); GPU-safe
    if (_overflow != TextOverflow.visible && _contentsOverflow()) {
      _clipHandle.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        _overflow == TextOverflow.fade ? _paintFaded : _paintContents,
        oldLayer: _clipHandle.layer,
      );
    } else {
      _clipHandle.layer = null;
      _paintContents(context, offset);
    }
  }

  /// TextOverflow.fade: paint into a layer, then erase toward the overflow
  /// edge with a dstIn gradient — horizontal at the reading edge when a line
  /// is wider than the box, else vertical at the bottom (RenderParagraph's
  /// rule).
  void _paintFaded(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final bounds = offset & size;
    canvas.saveLayer(bounds, Paint());
    _paintContents(context, offset);
    final fade = _fadeExtentPx().clamp(1.0, size.width);
    final Offset from;
    final Offset to;
    if (_overflowsWidth()) {
      final rtl = _textDirection == TextDirection.rtl;
      from = Offset(rtl ? bounds.left + fade : bounds.right - fade, 0);
      to = Offset(rtl ? bounds.left : bounds.right, 0);
    } else {
      from = Offset(0, bounds.bottom - fade);
      to = Offset(0, bounds.bottom);
    }
    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = ui.Gradient.linear(from, to, const [
          Color(0xFFFFFFFF),
          Color(0x00FFFFFF),
        ]),
    );
    canvas.restore();
  }

  /// Fade region size: the root style's ellipsis advance when resolvable
  /// (what RenderParagraph uses), else one font size.
  double _fadeExtentPx() {
    final style = _text.style;
    final fontSize = _textScaler.scale(style?.fontSize ?? 14.0);
    final font = _engine.resolveFont(style?.fontFamily);
    if (font != null && font.hasGlyph('…')) {
      return font.advanceOf('…') / font.unitsPerEm * fontSize;
    }
    return fontSize;
  }

  /// RenderParagraph's rule: visual overflow is measured against the LINE
  /// BOXES, never the glyph ink.
  ///
  /// Ink routinely spills past its own line box — italic overhang, a negative
  /// left side bearing on 'j', diacritics above the ascender, emoji — and
  /// `size` is itself the line-box extent (see _computeLayout). Testing ink
  /// here would therefore push a clip rect that shaves off the very ink that
  /// triggered it, in a font-dependent way. Flutter accepts the same trade-off
  /// (rendering/paragraph.dart carries a standing note about it): ink outside
  /// the box paints outside the box.
  ///
  /// inkBounds stays what it is good for: the extent of the glyph surface we
  /// rasterize in _paintContents.
  bool _contentsOverflow() {
    final para = _para;
    if (para != null &&
        (para.didExceedMaxLines ||
            para.height > size.height + 0.01 ||
            _overflowsWidth())) {
      return true;
    }
    for (final b in _emitted?.placeholders ?? const <wf.PlaceholderBox>[]) {
      if (b.left < -0.01 ||
          b.top < -0.01 ||
          b.left + b.width > size.width + 0.01 ||
          b.top + b.height > size.height + 0.01) {
        return true;
      }
    }
    return false;
  }

  /// A line advancing past the box edge. Only reachable with softWrap:false (a
  /// wrapped or ellipsized line is broken at the box edge by construction).
  bool _overflowsWidth() {
    for (final l in _para?.lines ?? const <wf.LineMetrics>[]) {
      if (l.width > size.width + 0.01) return true;
    }
    return false;
  }

  void _drawDecorations(
    Canvas canvas,
    Offset offset,
    Iterable<wf.DecorationLine> lines,
  ) {
    for (final d in lines) {
      final paint = Paint()
        ..color = Color.from(
          alpha: d.color.length > 3 ? d.color[3] : 1.0,
          red: d.color[0],
          green: d.color[1],
          blue: d.color[2],
        );
      final x = offset.dx + d.x;
      final y = offset.dy + d.y;
      final w = d.width;
      final th = math.max(d.thickness, 0.5);
      switch (d.style) {
        case wf.InlineDecorationStyle.solid:
          canvas.drawRect(Rect.fromLTWH(x, y - th / 2, w, th), paint);
        case wf.InlineDecorationStyle.doubleLine:
          canvas.drawRect(Rect.fromLTWH(x, y - th * 1.5, w, th), paint);
          canvas.drawRect(Rect.fromLTWH(x, y + th * 0.5, w, th), paint);
        case wf.InlineDecorationStyle.dotted:
          for (var dx = th / 2; dx < w; dx += th * 3) {
            canvas.drawCircle(Offset(x + dx, y), th / 2, paint);
          }
        case wf.InlineDecorationStyle.dashed:
          for (var dx = 0.0; dx < w; dx += th * 5) {
            canvas.drawRect(
              Rect.fromLTWH(x + dx, y - th / 2, math.min(th * 3, w - dx), th),
              paint,
            );
          }
        case wf.InlineDecorationStyle.wavy:
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
  }

  void _paintContents(PaintingContext context, Offset offset) {
    final emitted = _emitted;
    final ink = emitted?.inkBounds;
    if (emitted != null && emitted.backgrounds.isNotEmpty) {
      for (final b in emitted.backgrounds) {
        context.canvas.drawRect(
          Rect.fromLTWH(
            offset.dx + b.left,
            offset.dy + b.top,
            b.width,
            b.height,
          ),
          Paint()
            ..color = Color.from(
              alpha: b.color.length > 3 ? b.color[3] : 1.0,
              red: b.color[0],
              green: b.color[1],
              blue: b.color[2],
            ),
        );
      }
    }
    final fragments = _fragments;
    if (fragments != null) {
      for (final f in fragments) {
        f.paint(context, offset);
      }
    }
    if (emitted != null && emitted.decorations.isNotEmpty) {
      _drawDecorations(
        context.canvas,
        offset,
        emitted.decorations.where((d) => !d.aboveText),
      );
    }
    if (emitted != null &&
        ink != null &&
        (emitted.glyphCount > 0 || emitted.colorGlyphCount > 0) &&
        _engine.gpuReady &&
        !_engine.unsupported) {
      var scale = _devicePixelRatio;
      if (_transformAdaptive) {
        final t = getTransformTo(null).getMaxScaleOnAxis();
        if (t.isFinite && t > 0) {
          scale = _quantizeScale(t * _devicePixelRatio);
        }
      }
      final maxDim = math.max(ink.maxX - ink.minX, ink.maxY - ink.minY);
      final upper = math.min(
        16.0 * _devicePixelRatio,
        (_maxSurfaceDim - 16) / math.max(maxDim, 1e-3),
      );
      final lower = math.min(0.25 * _devicePixelRatio, upper);
      scale = ui.clampDouble(
        scale,
        math.max(lower, 1e-3),
        math.max(upper, 1e-3),
      );

      final key = (
        emitted,
        scale,
        _coverageGamma,
        _coverageSharp,
        _minificationGuardPx,
      );
      var rendered = key == _cacheKey;
      if (!rendered) {
        rendered = _renderSurface(emitted, ink, scale);
        if (rendered) _cacheKey = key;
      }
      final image = _image;
      if (rendered && image != null) {
        // The used region only — the bucketed allocation may be larger, and
        // its slack is cleared-transparent, not content.
        final src = Rect.fromLTWH(
          0,
          0,
          _imageDevRect.width,
          _imageDevRect.height,
        );
        final dst = Rect.fromLTWH(
          offset.dx + _imageDevRect.left / _imageScale,
          offset.dy + _imageDevRect.top / _imageScale,
          _imageDevRect.width / _imageScale,
          _imageDevRect.height / _imageScale,
        );
        // TextStyle.shadows: re-blit each shadowed run's slice of the glyph
        // image, offset, tinted (srcIn), and blurred, painted in list order
        // under the text like Flutter. The isolation must happen on the
        // SOURCE rect: blitting the whole image and clipping at the
        // destination leaks every neighboring glyph inside the clip (the
        // previous line's descenders, adjacent same-line spans) into the
        // shadow as smears with hard clip edges — and a blur clip has to be
        // inflated by the blur bloom, which admits even more of them.
        for (final sr in emitted.shadowRuns) {
          final runRect = Rect.fromLTWH(sr.left, sr.top, sr.width, sr.height);
          final srcRun = Rect.fromLTRB(
            runRect.left * _imageScale - _imageDevRect.left,
            runRect.top * _imageScale - _imageDevRect.top,
            runRect.right * _imageScale - _imageDevRect.left,
            runRect.bottom * _imageScale - _imageDevRect.top,
          );
          for (final s in sr.shadows) {
            final paint = Paint()
              ..filterQuality = _filterQuality
              ..colorFilter = ColorFilter.mode(
                Color.from(
                  alpha: s.color.length > 3 ? s.color[3] : 1.0,
                  red: s.color[0],
                  green: s.color[1],
                  blue: s.color[2],
                ),
                BlendMode.srcIn,
              );
            if (s.blurRadius > 0) {
              // ui.Shadow.convertRadiusToSigma, divided by _imageScale: the
              // blur runs over `image`, whose texels are _imageScale-
              // oversampled relative to the logical destination, so a
              // logical-px sigma would land scale× too wide and smear the run
              // into a halo. Pre-dividing brings it back toward the logical
              // blur Flutter's MaskFilter-based TextStyle.shadows produce.
              final sigma = (s.blurRadius * 0.57735 + 0.5) / _imageScale;
              paint.imageFilter = ui.ImageFilter.blur(
                sigmaX: sigma,
                sigmaY: sigma,
                tileMode: ui.TileMode.decal,
              );
            }
            context.canvas.drawImageRect(
              image,
              srcRun,
              runRect.shift(offset + Offset(s.dx, s.dy)),
              paint,
            );
          }
        }
        context.canvas.drawImageRect(
          image,
          src,
          dst,
          Paint()..filterQuality = _filterQuality,
        );
      }
    }
    if (emitted != null && emitted.decorations.isNotEmpty) {
      _drawDecorations(
        context.canvas,
        offset,
        emitted.decorations.where((d) => d.aboveText),
      );
    }
    if (childCount > 0) paintInlineChildren(context, offset);
  }

  bool _renderSurface(
    wf.ParagraphInstances emitted,
    wf.LayoutBounds ink,
    double scale,
  ) => GPUTextTimeline.timeSync(
    GPUTextTimeline.render,
    () => _renderSurfaceImpl(emitted, ink, scale),
  );

  bool _renderSurfaceImpl(
    wf.ParagraphInstances emitted,
    wf.LayoutBounds ink,
    double scale,
  ) {
    final textures = _engine.prepareTextures();
    // An all-emoji paragraph bands no coverage glyphs, so the curve atlas (and
    // thus `textures`) is null — but it still has color quads to draw. Only bail
    // when there is nothing at all to render.
    if (textures == null && emitted.colorGlyphCount == 0) return false;
    // 4 device px of padding covers the shader's ~2px anti-aliasing skirt.
    const pad = 4;
    final devLeft = (ink.minX * scale).floor() - pad;
    final devTop = (ink.minY * scale).floor() - pad;
    final w = ((ink.maxX * scale).ceil() + pad - devLeft).clamp(
      1,
      _maxSurfaceDim,
    );
    final h = ((ink.maxY * scale).ceil() + pad - devTop).clamp(
      1,
      _maxSurfaceDim,
    );

    if (textures != null && emitted.glyphCount > 0) {
      _instanceBuffer ??= _engine.pipeline.uploadInstances(emitted.instances);
    }
    // Prepare the color-atlas texture + instance buffer BEFORE opening the
    // render pass. prepareColorTexture() uploads (overwrites) the atlas — doing
    // that inside an already-recording pass corrupts the encoder and segfaults
    // the GPU, exactly like prepareTextures() above must precede the pass.
    gpu.Texture? colorTex;
    if (emitted.colorGlyphCount > 0 && _engine.pipeline.hasColorPipeline) {
      colorTex = _engine.prepareColorTexture();
      if (colorTex != null) {
        _colorInstanceBuffer ??= _engine.pipeline.uploadColorInstances(
          emitted.colorInstances,
        );
      }
    }
    var surface = _surface;
    // Surface allocations are bucketed: glyphs render into the top-left w×h
    // of a surface whose dims round up to _surfaceDimBucket, and the blit
    // samples only that sub-rect. The few-device-px ink drift of a live
    // resize or width animation then reuses the surface instead of paying a
    // texture allocation (plus retire churn) every frame. A surface is kept
    // while the used rect still fits and the surface wastes < 4× the
    // bucketed need, so an oscillating width settles on one max-sized
    // surface instead of reallocating at every bucket crossing.
    final allocW = _bucketDim(w);
    final allocH = _bucketDim(h);
    final fits =
        surface != null &&
        surface.width >= w &&
        surface.height >= h &&
        surface.width * surface.height <= allocW * allocH * 4;
    gpu.GpuSurfaceFrame? frame;
    try {
      if (!fits) {
        // Never resize() a live surface: while a presented image is still
        // referenced by the compositor (in-flight raster, retained layers),
        // resizing can leave later frames on a stale-size backing texture —
        // observed on flutter_gpu master as text stretched to the wrong
        // scale after live window resizes. A fresh surface gets fresh
        // textures; the old one is retired below with its presented image.
        surface = gpu.gpuContext.createImageSurface(
          allocW,
          allocH,
          format: _surfaceFormat(),
        );
        debugSurfaceAllocs++;
      }
      frame = surface.acquireNextFrame();
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
      final frameUniforms = FrameUniforms(
        // The full allocation, not the used w×h: the vertex shader maps
        // device px → NDC against these, which pins the used rect to the
        // texture's top-left where the blit's src rect samples it.
        width: surface.width.toDouble(),
        height: surface.height.toDouble(),
        style: [_coverageGamma, _coverageSharp],
        cam: [scale, scale, -devLeft.toDouble(), -devTop.toDouble()],
        guardPx: _minificationGuardPx,
      );
      if (textures != null && emitted.glyphCount > 0) {
        _engine.pipeline.renderInstances(
          pass: pass,
          frame: frameUniforms,
          instances: _instanceBuffer!,
          instanceCount: emitted.glyphCount,
          textures: textures,
        );
      }
      // Color-bitmap emoji: a second draw on the same pass, over the text.
      // Texture + buffer were prepared above (outside the pass) to avoid a
      // mid-pass upload.
      if (colorTex != null && _colorInstanceBuffer != null) {
        _engine.pipeline.renderColorInstances(
          pass: pass,
          frame: frameUniforms,
          instances: _colorInstanceBuffer!,
          instanceCount: emitted.colorGlyphCount,
          colorAtlas: colorTex,
        );
      }
      frame.present(cmd);
      cmd.submit();
    } catch (e) {
      // Release an unpresented frame; otherwise every future resize() on
      // this surface throws "frame still acquired". No-op after present().
      frame?.discard();
      debugPrint('gputext: paragraph render failed: $e');
      return false;
    }
    debugSurfaceRenders++;
    // Retire the previous surface+image instead of disposing them now:
    // frames that reference the old image may still be waiting to
    // rasterize (paint outpaces raster during live window resizes), and
    // disposing it early lets the pool recycle its texture under a frame
    // that is still on its way to the screen — which paints as text
    // stretched to the wrong scale. The retired pair is disposed by
    // _onFrameTimings once the engine reports a frame at least as new as
    // this one has finished rasterizing.
    final prevImage = _image;
    if (prevImage != null) {
      _retireSurface(
        identical(_surface, surface) ? null : _surface,
        prevImage,
        ui.PlatformDispatcher.instance.frameData.frameNumber,
      );
    }
    _surface = surface;
    _image = surface.currentImage;
    _imageScale = scale;
    _imageDevRect = Rect.fromLTWH(
      devLeft.toDouble(),
      devTop.toDouble(),
      w.toDouble(),
      h.toDouble(),
    );
    return true;
  }

  /// Bit-exact equality of two instance buffers. Compared as raw 32-bit words
  /// (not floats) so a re-emit only counts as identical when every glyph lands
  /// at exactly the same place/color/band — the surface the previous emit
  /// rendered is then still pixel-correct for the new one.
  static bool _sameInstances(Float32List a, Float32List b) {
    if (a.length != b.length) return false;
    final aw = a.buffer.asInt32List(a.offsetInBytes, a.length);
    final bw = b.buffer.asInt32List(b.offsetInBytes, b.length);
    for (var i = 0; i < aw.length; i++) {
      if (aw[i] != bw[i]) return false;
    }
    return true;
  }

  /// True when [a] and [b] partition the same runs into the same lines — a
  /// necessary-and-sufficient condition for emitInstances to produce identical
  /// glyph positions, GIVEN the caller has already established the runs
  /// themselves are unchanged (same prepared paragraph, no recolor) and that
  /// alignment/box-width can't shift positions. Only reads a few fields per
  /// line item, so it is far cheaper than the emit + per-glyph atlas walk it
  /// replaces. Line metrics (height/ascent → the y baseline) are derived from
  /// the items and style, so equal items imply equal metrics; they are compared
  /// anyway as a cheap guard.
  static bool _sameLayout(wf.ParagraphLines a, wf.ParagraphLines b) {
    final la = a.lines;
    final lb = b.lines;
    if (la.length != lb.length) return false;
    for (var i = 0; i < la.length; i++) {
      final lineA = la[i];
      final lineB = lb[i];
      final ia = lineA.items;
      final ib = lineB.items;
      if (ia.length != ib.length) return false;
      if (lineA.height != lineB.height || lineA.ascent != lineB.ascent) {
        return false;
      }
      for (var j = 0; j < ia.length; j++) {
        final xa = ia[j];
        final xb = ib[j];
        if (xa is wf.LineRun) {
          if (xb is! wf.LineRun ||
              xa.itemIndex != xb.itemIndex ||
              xa.startInItem != xb.startInItem ||
              !identical(xa.font, xb.font) ||
              xa.fontSizePx != xb.fontSizePx ||
              xa.text != xb.text) {
            return false;
          }
        } else if (xa is wf.LineEmoji) {
          if (xb is! wf.LineEmoji || xa.itemIndex != xb.itemIndex) return false;
        } else if (xa is wf.LinePlaceholder) {
          if (xb is! wf.LinePlaceholder || xa.itemIndex != xb.itemIndex) {
            return false;
          }
        } else {
          return false;
        }
      }
    }
    return true;
  }

  /// Round a needed surface dimension up to the allocation bucket. 64 device
  /// px keeps worst-case waste at one bucket strip per axis (tiny paragraphs
  /// pay a 64×64 floor, a few KB) while making resize-driven ink drift land
  /// in the same bucket frame over frame.
  static int _bucketDim(int px) {
    const bucket = 64;
    final rounded = ((px + bucket - 1) ~/ bucket) * bucket;
    return math.min(rounded, _maxSurfaceDim);
  }

  static gpu.PixelFormat _surfaceFormat() {
    final preferred = gpu.gpuContext.defaultColorFormat;
    if (preferred != gpu.PixelFormat.unknown &&
        gpu.gpuContext.supportsTextureFormat(preferred, renderTarget: true)) {
      return preferred;
    }
    return gpu.PixelFormat.b8g8r8a8UNormInt;
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(StringProperty('plainText', _text.toPlainText()));
    properties.add(EnumProperty<TextAlign>('textAlign', _textAlign));
    properties.add(IntProperty('maxLines', _maxLines, defaultValue: null));
    properties.add(DoubleProperty('devicePixelRatio', _devicePixelRatio));
    properties.add(
      FlagProperty(
        'transformAdaptive',
        value: _transformAdaptive,
        ifTrue: 'adaptive',
      ),
    );
  }
}

/// One placeholder-free stretch of a paragraph's source text, exposed to the
/// selection framework (SelectionArea / SelectableRegion). Mirrors
/// RenderParagraph's _SelectableFragment: geometry queries go through the
/// paragraph's ParagraphGeometry in SOURCE offsets, so copied content is the
/// pre-shaping text even when ligatures render as single glyphs.
class _SelectableFragment with ChangeNotifier implements Selectable {
  _SelectableFragment(this.paragraph, this.range);

  final RenderGPUParagraph paragraph;

  /// Source-text offsets covered by this fragment (no placeholders inside).
  final TextRange range;

  int? _selectionStart;
  int? _selectionEnd;
  LayerLink? _startHandle;
  LayerLink? _endHandle;
  SelectionGeometry? _cachedGeometry;

  @override
  SelectionGeometry get value => _cachedGeometry ??= _computeGeometry();

  /// Called by the paragraph after (re)layout: positions moved.
  void didChangeParagraphLayout() => _updateGeometry();

  void _updateGeometry() {
    final next = _computeGeometry();
    if (next == _cachedGeometry) return;
    _cachedGeometry = next;
    notifyListeners();
    if (paragraph.attached && paragraph.hasSize) paragraph.markNeedsPaint();
  }

  SelectionGeometry _computeGeometry() {
    final hasContent = range.end > range.start;
    final g = paragraph._geometry;
    final s = _selectionStart;
    final e = _selectionEnd;
    if (g == null || s == null || e == null) {
      return SelectionGeometry(
        status: SelectionStatus.none,
        hasContent: hasContent,
      );
    }
    final a = math.min(s, e);
    final b = math.max(s, e);
    final flipped = e < s;
    final collapsed = a == b;
    SelectionPoint point(wf.CaretMetrics c, TextSelectionHandleType type) =>
        SelectionPoint(
          localPosition: Offset(c.x, c.top + c.height),
          lineHeight: c.height,
          handleType: type,
        );
    return SelectionGeometry(
      status: collapsed
          ? SelectionStatus.collapsed
          : SelectionStatus.uncollapsed,
      hasContent: hasContent,
      startSelectionPoint: point(
        g.caretAt(s),
        collapsed
            ? TextSelectionHandleType.collapsed
            : (flipped
                  ? TextSelectionHandleType.right
                  : TextSelectionHandleType.left),
      ),
      endSelectionPoint: point(
        g.caretAt(e),
        collapsed
            ? TextSelectionHandleType.collapsed
            : (flipped
                  ? TextSelectionHandleType.left
                  : TextSelectionHandleType.right),
      ),
      selectionRects: [
        for (final r in g.boxesForRange(a, b))
          Rect.fromLTRB(r.left, r.top, r.right, r.bottom),
      ],
    );
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final SelectionResult result;
    if (event is SelectionEdgeUpdateEvent) {
      result = _updateEdge(
        event,
        isEnd: event.type == SelectionEventType.endEdgeUpdate,
      );
    } else if (event is ClearSelectionEvent) {
      _selectionStart = null;
      _selectionEnd = null;
      result = SelectionResult.none;
    } else if (event is SelectAllSelectionEvent) {
      _selectionStart = range.start;
      _selectionEnd = range.end;
      result = SelectionResult.none;
    } else if (event is SelectWordSelectionEvent) {
      result = _selectBoundaryAt(event.globalPosition, word: true);
    } else if (event is SelectParagraphSelectionEvent) {
      result = _selectBoundaryAt(event.globalPosition, word: false);
    } else if (event is GranularlyExtendSelectionEvent) {
      result = _granularlyExtend(event);
    } else if (event is DirectionallyExtendSelectionEvent) {
      result = _directionallyExtend(event);
    } else {
      result = SelectionResult.none;
    }
    _updateGeometry();
    return result;
  }

  Offset _globalToLocal(Offset global) {
    final transform = paragraph.getTransformTo(null)..invert();
    return MatrixUtils.transformPoint(transform, global);
  }

  Rect get _paragraphRect =>
      Rect.fromLTWH(0, 0, paragraph.size.width, paragraph.size.height);

  SelectionResult _updateEdge(
    SelectionEdgeUpdateEvent event, {
    required bool isEnd,
  }) {
    final local = _globalToLocal(event.globalPosition);
    final adjusted = SelectionUtils.adjustDragOffset(
      _paragraphRect,
      local,
      direction: paragraph._textDirection,
    );
    var offset = paragraph
        .getPositionForOffset(adjusted)
        .offset
        .clamp(range.start, range.end);
    if (event.granularity == TextGranularity.word) {
      // Long-press drags select whole words: snap the moving edge outward
      // from the anchor edge.
      final g = paragraph._geometry;
      final anchor = isEnd ? _selectionStart : _selectionEnd;
      if (g != null && g.plainText.isNotEmpty) {
        final w = wf.wordRangeIn(
          g.plainText,
          offset.clamp(0, g.plainText.length - 1),
        );
        offset = (anchor == null || offset >= anchor)
            ? w.end.clamp(range.start, range.end)
            : w.start.clamp(range.start, range.end);
      }
    }
    if (isEnd) {
      _selectionEnd = offset;
    } else {
      _selectionStart = offset;
    }
    return SelectionUtils.getResultBasedOnRect(_paragraphRect, local);
  }

  SelectionResult _selectBoundaryAt(
    Offset globalPosition, {
    required bool word,
  }) {
    final g = paragraph._geometry;
    if (g == null || range.end == range.start) return SelectionResult.end;
    final local = _globalToLocal(globalPosition);
    var at = g.positionForOffset(local.dx, local.dy).offset;
    if (at < range.start) at = range.start;
    final lastIn = math.max(range.start, range.end - 1);
    if (at > lastIn) at = lastIn;
    if (word) {
      final w = wf.wordRangeIn(g.plainText, at);
      _selectionStart = w.start.clamp(range.start, range.end);
      _selectionEnd = w.end.clamp(range.start, range.end);
    } else {
      // Paragraph: between newlines (clamped into the fragment).
      final text = g.plainText;
      var start = at;
      while (start > range.start && text.codeUnitAt(start - 1) != 0x0A) {
        start--;
      }
      var end = at;
      while (end < range.end && text.codeUnitAt(end) != 0x0A) {
        end++;
      }
      _selectionStart = start;
      _selectionEnd = end;
    }
    return SelectionResult.end;
  }

  static int _cpStart(String text, int index) {
    if (index <= 0) return 0;
    final unit = text.codeUnitAt(index);
    return (unit >= 0xDC00 && unit <= 0xDFFF) ? index - 1 : index;
  }

  static int _stepForward(String text, int offset) {
    if (offset >= text.length) return offset + 1;
    final unit = text.codeUnitAt(offset);
    final pair = unit >= 0xD800 && unit <= 0xDBFF && offset + 1 < text.length;
    return offset + (pair ? 2 : 1);
  }

  static int _stepBackward(String text, int offset) {
    if (offset <= 0) return -1;
    return _cpStart(text, offset - 1) == offset - 1
        ? offset - 1
        : _cpStart(text, offset - 1);
  }

  SelectionResult _granularlyExtend(GranularlyExtendSelectionEvent event) {
    final g = paragraph._geometry;
    if (g == null) return SelectionResult.end;
    final text = g.plainText;
    var edge = event.isEnd ? _selectionEnd : _selectionStart;
    edge ??= event.isEnd ? _selectionStart : _selectionEnd;
    edge ??= event.forward ? range.start : range.end;

    int next;
    switch (event.granularity) {
      case TextGranularity.character:
        next = event.forward
            ? _stepForward(text, edge)
            : _stepBackward(text, edge);
      case TextGranularity.word:
        if (event.forward) {
          final probe = math.min(
            math.max(edge, 0),
            math.max(0, text.length - 1),
          );
          final w = wf.wordRangeIn(text, probe);
          next = w.end > edge ? w.end : _stepForward(text, edge);
        } else {
          final probe = math.max(0, edge - 1);
          final w = wf.wordRangeIn(text, probe);
          next = w.start < edge ? w.start : _stepBackward(text, edge);
        }
      case TextGranularity.line:
        final r = g.lineRange(
          g.caretAt(edge.clamp(range.start, range.end)).line,
        );
        next = event.forward ? r.end : r.start;
      case TextGranularity.paragraph:
      case TextGranularity.document:
        next = event.forward ? range.end : range.start;
    }

    final crossedForward = event.forward && next > range.end;
    final crossedBackward = !event.forward && next < range.start;
    final clamped = next.clamp(range.start, range.end);
    if (event.isEnd) {
      _selectionEnd = clamped;
    } else {
      _selectionStart = clamped;
    }
    (event.isEnd ? _selectionStart ??= edge : _selectionEnd ??= edge);
    if (crossedForward) return SelectionResult.next;
    if (crossedBackward) return SelectionResult.previous;
    return SelectionResult.end;
  }

  SelectionResult _directionallyExtend(
    DirectionallyExtendSelectionEvent event,
  ) {
    final g = paragraph._geometry;
    if (g == null || g.para.lines.isEmpty) return SelectionResult.end;
    final localDx = _globalToLocal(Offset(event.dx, 0)).dx;
    var edge = event.isEnd ? _selectionEnd : _selectionStart;
    edge ??= event.isEnd ? _selectionStart : _selectionEnd;

    int line;
    switch (event.direction) {
      case SelectionExtendDirection.forward:
        line = g.caretAt(range.start).line;
      case SelectionExtendDirection.backward:
        line = g.caretAt(range.end).line;
      case SelectionExtendDirection.previousLine:
        line =
            g
                .caretAt((edge ?? range.start).clamp(range.start, range.end))
                .line -
            1;
      case SelectionExtendDirection.nextLine:
        line =
            g.caretAt((edge ?? range.end).clamp(range.start, range.end)).line +
            1;
    }

    SelectionResult result = SelectionResult.end;
    int offset;
    if (line < 0) {
      offset = range.start;
      result = SelectionResult.previous;
    } else if (line >= g.para.lines.length) {
      offset = range.end;
      result = SelectionResult.next;
    } else {
      final mid = (g.lineTop(line) + g.lineBottom(line)) / 2;
      offset = g
          .positionForOffset(localDx, mid)
          .offset
          .clamp(range.start, range.end);
      if (offset <= range.start &&
          event.direction == SelectionExtendDirection.previousLine) {
        // Still inside, fine — previous only when we ran off the top above.
      }
    }
    if (event.isEnd) {
      _selectionEnd = offset;
      _selectionStart ??= edge ?? offset;
    } else {
      _selectionStart = offset;
      _selectionEnd ??= edge ?? offset;
    }
    return result;
  }

  @override
  SelectedContent? getSelectedContent() {
    final s = _selectionStart;
    final e = _selectionEnd;
    final g = paragraph._geometry;
    if (s == null || e == null || s == e || g == null) return null;
    return SelectedContent(
      plainText: g.plainText.substring(math.min(s, e), math.max(s, e)),
    );
  }

  @override
  SelectedContentRange? getSelection() {
    final s = _selectionStart;
    final e = _selectionEnd;
    if (s == null || e == null) return null;
    return SelectedContentRange(
      startOffset: s - range.start,
      endOffset: e - range.start,
    );
  }

  @override
  int get contentLength => range.end - range.start;

  @override
  Matrix4 getTransformTo(RenderObject? ancestor) =>
      paragraph.getTransformTo(ancestor);

  @override
  Size get size => paragraph.size;

  @override
  List<Rect> get boundingBoxes {
    final g = paragraph._geometry;
    if (g == null) {
      return <Rect>[Offset.zero & paragraph.size];
    }
    final boxes = g.boxesForRange(range.start, range.end);
    if (boxes.isEmpty) return <Rect>[Offset.zero & paragraph.size];
    return [
      for (final b in boxes) Rect.fromLTRB(b.left, b.top, b.right, b.bottom),
    ];
  }

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (identical(startHandle, _startHandle) &&
        identical(endHandle, _endHandle)) {
      return;
    }
    _startHandle = startHandle;
    _endHandle = endHandle;
    if (paragraph.attached && paragraph.hasSize) paragraph.markNeedsPaint();
  }

  /// Paints the highlight and mobile handle anchors; called from the
  /// paragraph's paint, under the glyphs.
  void paint(PaintingContext context, Offset offset) {
    final s = _selectionStart;
    final e = _selectionEnd;
    final g = paragraph._geometry;
    if (s != null && e != null && s != e && g != null) {
      final color = paragraph._selectionColor;
      if (color != null) {
        final paintObj = Paint()..color = color;
        for (final r in g.boxesForRange(math.min(s, e), math.max(s, e))) {
          context.canvas.drawRect(
            Rect.fromLTRB(
              offset.dx + r.left,
              offset.dy + r.top,
              offset.dx + r.right,
              offset.dy + r.bottom,
            ),
            paintObj,
          );
        }
      }
    }
    final geometry = value;
    final start = geometry.startSelectionPoint;
    final end = geometry.endSelectionPoint;
    if (_startHandle != null && start != null) {
      context.pushLayer(
        LeaderLayer(link: _startHandle!, offset: offset + start.localPosition),
        (PaintingContext c, Offset o) {},
        Offset.zero,
      );
    }
    if (_endHandle != null && end != null) {
      context.pushLayer(
        LeaderLayer(link: _endHandle!, offset: offset + end.localPosition),
        (PaintingContext c, Offset o) {},
        Offset.zero,
      );
    }
  }
}
