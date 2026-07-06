// WindfoilRichText — a drop-in replacement for RichText whose glyphs are
// rasterized by the windfoil coverage shader instead of the engine's text
// pipeline.
//
// Layout is pure Dart (font metrics only) in logical pixels; painting emits
// glyph instances, renders them into an offscreen flutter_gpu surface at the
// current effective scale, and blits the cached ui.Image. With
// transformAdaptive (default), the render scale follows the ancestor paint
// transform so text stays crisp inside zooming containers; pass a zooming
// container's TransformationController as scaleHint when a RepaintBoundary
// sits between it and this widget (retained layers skip paint otherwise).
//
// WidgetSpan is supported: children are extracted in span preorder
// (WidgetSpan.extractFromInlineSpan), measured during layout, woven into the
// wrap as unbreakable placeholder boxes, and painted/hit-tested as regular
// render children on top of the text image.
//
// Emoji are supported by delegation: expandEmojiSpans rewrites emoji
// clusters (ZWJ sequences, skin tones, flags, keycaps) into baseline-aligned
// inline Text children, so the platform's color-emoji font renders them
// while windfoil renders everything else.
//
// Font fallback is two-layered: the flattener resolves each character
// against TextStyle.fontFamilyFallback + the engine's fallback chain
// (still windfoil-rendered), and expandUncoveredSpans delegates characters
// no registered font covers to inline engine Text (platform fallback).
//
// Accessibility and pointer parity: link spans are exposed as individually
// actionable semantics nodes (assembleSemanticsNode), and hit-testing puts
// the TextSpan itself on the result so MouseTracker drives
// mouseCursor/onEnter/onExit and recognizers get their events.
//
// Selection: SelectionArea/SelectableRegion is supported via per-fragment
// Selectables (split at placeholders, like RenderParagraph) working in
// SOURCE-text offsets — copied content is the pre-shaping characters even
// when ligatures render as single proxy glyphs. RenderParagraph-style
// geometry APIs (getPositionForOffset, getOffsetForCaret,
// getBoxesForSelection, getWordBoundary, getLineBoundary) are exposed on
// the render object.
//
// Remaining limits: no bidi/RTL shaping (selection order is logical ==
// visual); locale is accepted but not used for shaping; foreground Paint
// contributes its flat color only (no shaders).

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import '../engine/engine.dart';
import '../engine/pipeline.dart';
import '../layout.dart' as wf show LayoutBounds;
import '../paragraph.dart' as wf;
import 'emoji.dart';
import 'span_flattener.dart';

const _maxSurfaceDim = 8192;

/// Drop-in replacement for RichText. This public widget is a thin
/// build-time layer: it expands emoji clusters and characters no registered
/// font covers into inline engine-Text spans (consulting loaded fonts via
/// ListenableBuilder, so late-loading fonts re-expand), then builds the
/// render-object widget.
class WindfoilRichText extends StatelessWidget {
  const WindfoilRichText({
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

  /// Accepted for RichText signature compatibility; ignored in v1
  /// (no locale-specific shaping yet).
  final Locale? locale;

  /// Selection registrar. Unlike RichText, a null registrar falls back to
  /// the enclosing [SelectionContainer] (Text.rich behavior), so a plain
  /// WindfoilRichText participates in SelectionArea without extra plumbing.
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

  @override
  Widget build(BuildContext context) {
    final registrar =
        selectionRegistrar ?? SelectionContainer.maybeOf(context);
    return ListenableBuilder(
      listenable: Windfoil.instance,
      builder: (context, _) {
        var effective = expandEmojiSpans(text, Windfoil.instance);
        effective = expandUncoveredSpans(effective, Windfoil.instance);
        return _RawWindfoilRichText(
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

class _RawWindfoilRichText extends MultiChildRenderObjectWidget {
  _RawWindfoilRichText({
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
  })  : assert(maxLines == null || maxLines > 0),
        super(
            children:
                WidgetSpan.extractFromInlineSpan(effectiveText, textScaler));

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

  /// Accepted for RichText signature compatibility; ignored in v1
  /// (no locale-specific shaping or selection yet).
  final Locale? locale;
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
  final wf.LineBreaker lineBreaker;

  @override
  RenderWindfoilParagraph createRenderObject(BuildContext context) {
    return RenderWindfoilParagraph(
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
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ??
          View.of(context).devicePixelRatio,
      transformAdaptive: transformAdaptive,
      scaleHint: scaleHint,
      filterQuality: filterQuality,
      lineBreaker: lineBreaker,
      strutStyle: strutStyle,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
    )
      ..registrar = selectionRegistrar
      ..selectionColor = selectionColor;
  }

  @override
  void updateRenderObject(
      BuildContext context, RenderWindfoilParagraph renderObject) {
    renderObject
      ..text = effectiveText
      ..semanticsSource = text
      ..textAlign = textAlign
      ..textDirection = textDirection ?? Directionality.of(context)
      ..softWrap = softWrap
      ..overflow = overflow
      ..textScaler = textScaler
      ..maxLines = maxLines
      ..devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ??
          View.of(context).devicePixelRatio
      ..transformAdaptive = transformAdaptive
      ..scaleHint = scaleHint
      ..filterQuality = filterQuality
      ..lineBreaker = lineBreaker
      ..strutStyle = strutStyle
      ..textWidthBasis = textWidthBasis
      ..textHeightBehavior = textHeightBehavior
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

class RenderWindfoilParagraph extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, TextParentData>,
        RenderInlineChildrenContainerDefaults {
  RenderWindfoilParagraph({
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
    this._strutStyle,
    this._textWidthBasis = TextWidthBasis.parent,
    this._textHeightBehavior,
  });

  final WindfoilEngine _engine = Windfoil.instance;

  // ---- layout artifacts ----
  wf.ParagraphLines? _para;
  List<wf.InlineItem>? _items;
  wf.ParagraphGeometry? _geometryCache;
  int _geometryGen = -1;
  List<PlaceholderDimensions> _layoutDims = const [];
  double _boxWidth = 0; // alignment box = reported width
  double _lastWrapWidth = double.infinity;
  double _lastMaxWidth = double.infinity;
  List<wf.HitSpanBox> _hitBoxes = const [];
  bool _hasInteractiveSpans = false;
  bool _paraDirty = false; // paint-only span change pending re-break
  int _contentGen = 0; // bumped on any content change (layout or paint-only)

  // ---- paint artifacts ----
  wf.ParagraphInstances? _emitted;
  int _emittedGen = -1;
  gpu.DeviceBuffer? _instanceBuffer;
  gpu.GpuImageSurface? _surface;
  ui.Image? _image;
  // Superseded surface+image generations, each tagged with the number of the
  // frame whose paint replaced them. Disposed only once the engine reports a
  // frame at least that new has finished rasterizing (see _renderSurface).
  final List<(gpu.GpuImageSurface?, ui.Image, int)> _retired = [];
  bool _timingsHooked = false;
  // Frame number of the newest size-changed render; a heal re-render runs
  // once the engine reports that frame rasterized (see _renderSurface).
  int? _healAfterFrame;
  (int, double)? _cacheKey; // (contentGen, renderScale)

  /// Process-wide count of offscreen GPU renders (_renderSurface successes),
  /// including resize-heal and zoom-step re-renders. Benchmarks read deltas
  /// to attribute re-render churn; reset between scenarios.
  static int debugSurfaceRenders = 0;

  /// Bytes of the emitted per-glyph instance buffer (64 per glyph).
  int get debugInstanceBytes => _emitted?.instances.lengthInBytes ?? 0;

  /// Device-pixel size of the cached glyph image, null before first render.
  (int, int)? get debugImageSize {
    final img = _image;
    return img == null ? null : (img.width, img.height);
  }
  Rect _imageDevRect = Rect.zero;
  double _imageScale = 1;
  final LayerHandle<ClipRectLayer> _clipHandle = LayerHandle<ClipRectLayer>();

  // ---- inputs ----
  InlineSpan get text => _text;
  InlineSpan _text;
  set text(InlineSpan value) {
    switch (_text.compareTo(value)) {
      case RenderComparison.identical:
        return;
      case RenderComparison.metadata:
        _text = value;
        _paraDirty = true; // hit boxes reference source spans — refresh
        _contentGen++;
        markNeedsSemanticsUpdate();
        markNeedsPaint();
      case RenderComparison.paint:
        _text = value;
        _paraDirty = true;
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
  String get _semanticsLabel => _semanticsLabelCache ??=
      _semanticsSource.toPlainText(includePlaceholders: false);
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

  // ---- selection ----

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

  void _needsRelayout() {
    _para = null;
    _paraDirty = false;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  // ---- engine / hint wiring ----

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _engine.addListener(_onEngineChanged);
    _scaleHint?.addListener(_onScaleHint);
    unawaited(_engine.ensureInitialized());
  }

  @override
  void detach() {
    _engine.removeListener(_onEngineChanged);
    _scaleHint?.removeListener(_onScaleHint);
    super.detach();
  }

  /// Timings callback: frames reported here have finished rasterizing.
  /// Two consumers: images superseded by a frame that old can no longer be
  /// referenced by the compositor and are safe to dispose, and once the
  /// newest size-changed frame has rasterized the resize churn has drained,
  /// so the owed heal re-render can run (see _renderSurface).
  void _onFrameTimings(List<ui.FrameTiming> timings) {
    var latest = -1;
    for (final t in timings) {
      if (t.frameNumber > latest) latest = t.frameNumber;
    }
    while (_retired.isNotEmpty && _retired.first.$3 <= latest) {
      _retired.removeAt(0).$2.dispose();
    }
    final healAt = _healAfterFrame;
    if (healAt != null && latest >= healAt) {
      _healAfterFrame = null;
      if (attached && hasSize) {
        _cacheKey = null; // force a fresh present, not a cached-image repaint
        markNeedsPaint();
      }
    }
    if (_retired.isEmpty && _healAfterFrame == null && _timingsHooked) {
      _timingsHooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    }
  }

  void _hookTimings() {
    if (_timingsHooked) return;
    _timingsHooked = true;
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  @override
  void dispose() {
    _disposeFragments();
    _healAfterFrame = null;
    if (_timingsHooked) {
      _timingsHooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    }
    _clipHandle.layer = null;
    for (final (_, img, _) in _retired) {
      img.dispose();
    }
    _retired.clear();
    _image?.dispose();
    _image = null;
    _surface = null;
    _instanceBuffer = null;
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

  // ---- layout ----

  wf.TextAlign get _resolvedAlign => switch (_textAlign) {
        TextAlign.left => wf.TextAlign.left,
        TextAlign.right => wf.TextAlign.right,
        TextAlign.center => wf.TextAlign.center,
        TextAlign.justify => wf.TextAlign.justify,
        TextAlign.start => _textDirection == TextDirection.rtl
            ? wf.TextAlign.right
            : wf.TextAlign.left,
        TextAlign.end => _textDirection == TextDirection.rtl
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
        evenLeading: _textHeightBehavior?.leadingDistribution ==
            TextLeadingDistribution.even,
      );

  /// StrutStyle → resolved px metrics against the engine's font registry.
  /// Null while the strut's font isn't registered (strut then simply doesn't
  /// constrain — layout reruns when fonts land, like text runs do).
  wf.StrutMetrics? _resolveStrut() {
    final s = _strutStyle;
    if (s == null) return null;
    final font = _engine.resolveFont(
      s.fontFamily ?? _text.style?.fontFamily,
      weight: s.fontWeight,
      fontStyle: s.fontStyle,
    );
    if (font == null) return null;
    final fontSize = _textScaler.scale(s.fontSize ?? _text.style?.fontSize ?? 14.0);
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
      wf.PreparedParagraph prepared, double wrapWidth, double maxWidth) {
    final para =
        wf.layoutPreparedLines(prepared, wrapWidth, _styleFor(wrapWidth));
    // softWrap:false + ellipsis truncates each overlong line at the box edge.
    if (_overflow == TextOverflow.ellipsis &&
        !_softWrap &&
        maxWidth.isFinite) {
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
  /// resize relayouts and all intrinsic passes reuse one entry. Relies on
  /// TextSpan's deep ==/hashCode; fontGeneration invalidates on font churn.
  Object? _prepareCacheKey() {
    if (childCount > 0) return null;
    return (_text, _textScaler, _engine.fontGeneration);
  }

  /// Flatten + prepare (measure) the span, through the engine's shared
  /// cache. Returns a null paragraph while fonts are loading or for empty
  /// text (`runs` distinguishes the two, matching flattenSpan).
  (List<wf.InlineItem>?, wf.PreparedParagraph?) _flattenAndPrepare(
      List<PlaceholderDimensions> dims) {
    final key = _prepareCacheKey();
    if (key != null) {
      final cached = _engine.layoutCacheGet(key);
      if (cached != null) return (cached.$1, cached.$2);
    }
    final runs = flattenSpan(_text, _textScaler, _engine,
        placeholderDimensions: dims);
    if (runs == null || runs.isEmpty) return (runs, null);
    final prepared = wf.prepareParagraph(runs);
    if (key != null) _engine.layoutCachePut(key, (runs, prepared));
    return (runs, prepared);
  }

  ({wf.ParagraphLines? para, List<wf.InlineItem>? runs, Size size,
      double boxWidth, double wrapWidth}) _computeLayout(
      BoxConstraints constraints, List<PlaceholderDimensions> dims) {
    final (runs, prepared) = _flattenAndPrepare(dims);
    if (prepared == null) {
      // Fonts not loaded yet, or genuinely empty text: report one line height
      // when we can resolve the root style's font, else collapse.
      var height = 0.0;
      final font = _engine.resolveFont(_text.style?.fontFamily);
      if (font != null && runs != null) {
        height = wf.lineExtentOf(
            font, _textScaler.scale(_text.style?.fontSize ?? 14.0));
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
    final width =
        ui.clampDouble(basis, constraints.minWidth, constraints.maxWidth);
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
      : layoutInlineChildren(maxWidth, ChildLayoutHelper.dryLayoutChild,
          ChildLayoutHelper.getDryBaseline);

  @override
  void performLayout() {
    _layoutDims = childCount == 0
        ? const []
        : layoutInlineChildren(constraints.maxWidth,
            ChildLayoutHelper.layoutChild, ChildLayoutHelper.getBaseline);
    final r = _computeLayout(constraints, _layoutDims);
    _para = r.para;
    _items = r.runs;
    _boxWidth = r.boxWidth;
    _lastWrapWidth = r.wrapWidth;
    _lastMaxWidth = constraints.maxWidth;
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
    _hasInteractiveSpans = r.runs?.any((i) =>
            (i is wf.TextRun && interactive(i.source)) ||
            (i is wf.EmojiItem && interactive(i.source))) ??
        false;
    _hitBoxes = const [];
    final para = r.para;
    if ((childCount > 0 || _hasInteractiveSpans) && para != null) {
      final walk = wf.emitInstances(para, r.boxWidth, _resolvedAlign, null);
      _hitBoxes = walk.hitBoxes;
      if (childCount > 0) {
        positionInlineChildren([
          for (final b in walk.placeholders)
            ui.TextBox.fromLTRBD(b.left, b.top, b.left + b.width,
                b.top + b.height, _textDirection),
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
  double computeMinIntrinsicHeight(double width) =>
      _computeLayout(BoxConstraints(maxWidth: width), _dryDims(width))
          .size
          .height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      _para?.firstBaseline;

  @override
  double? computeDryBaseline(
          covariant BoxConstraints constraints, TextBaseline baseline) =>
      _computeLayout(constraints, _dryDims(constraints.maxWidth))
          .para
          ?.firstBaseline;

  // ---- caret / selection geometry (RenderParagraph-compatible) ----
  //
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
      affinity:
          pos.upstream ? TextAffinity.upstream : TextAffinity.downstream,
    );
  }

  /// Top-left of the caret for `position` (place `caretPrototype` there).
  Offset getOffsetForCaret(TextPosition position, Rect caretPrototype) {
    final g = _geometry;
    if (g == null) return Offset.zero;
    final c = g.caretAt(position.offset,
        upstream: position.affinity == TextAffinity.upstream);
    return Offset(c.x, c.top);
  }

  double? getFullHeightForCaret(TextPosition position) {
    final g = _geometry;
    if (g == null) return null;
    return g
        .caretAt(position.offset,
            upstream: position.affinity == TextAffinity.upstream)
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
    final line = g.caretAt(position.offset,
            upstream: position.affinity == TextAffinity.upstream)
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
    var hasRecognizer = false;
    _text.visitChildren((span) {
      if (span is TextSpan && span.recognizer != null) {
        hasRecognizer = true;
        return false;
      }
      return true;
    });
    if (hasRecognizer) {
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
  void assembleSemanticsNode(SemanticsNode node, SemanticsConfiguration config,
      Iterable<SemanticsNode> children) {
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

  // ---- paint ----

  void _prepareContent() {
    if (_paraDirty) {
      // Paint-only span change (e.g. colors): re-break at the same widths;
      // metrics are unchanged by construction of RenderComparison.paint.
      final (runs, prepared) = _flattenAndPrepare(_layoutDims);
      if (prepared != null) {
        _para = _break(prepared, _lastWrapWidth, _lastMaxWidth);
        _items = runs;
      }
      _paraDirty = false;
    }
    final para = _para;
    if (para == null) return;
    if (_emitted == null || _emittedGen != _contentGen) {
      for (final line in para.lines) {
        for (final item in line.items) {
          if (item is wf.LineRun) {
            _engine.atlas.ensureGlyphs(item.font, item.text);
          } else if (item is wf.LineEmoji) {
            for (final layer in item.item.layers) {
              _engine.atlas.ensureGlyphId(item.item.font, layer.glyphId);
            }
          }
        }
      }
      _emitted = wf.emitInstances(para, _boxWidth, _resolvedAlign, _engine.atlas);
      _hitBoxes = _emitted!.hitBoxes;
      _instanceBuffer = null;
      _emittedGen = _contentGen;
      _cacheKey = null;
    }
  }

  double _quantizeScale(double s) {
    final dpr = _devicePixelRatio;
    if (!s.isFinite || s <= 0) return dpr;
    final steps = (math.log(s / dpr) / math.log(1.25)).round();
    return dpr * math.pow(1.25, steps).toDouble();
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
    var overflowsWidth = false;
    for (final l in _para?.lines ?? const <wf.LineMetrics>[]) {
      if (l.width > size.width + 0.01) {
        overflowsWidth = true;
        break;
      }
    }
    final Offset from;
    final Offset to;
    if (overflowsWidth) {
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
        ..shader = ui.Gradient.linear(
          from,
          to,
          const [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        ),
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

  bool _contentsOverflow() {
    final ink = _emitted?.inkBounds;
    if (ink != null &&
        (ink.minX < -0.01 ||
            ink.minY < -0.01 ||
            ink.maxX > size.width + 0.01 ||
            ink.maxY > size.height + 0.01)) {
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

  void _drawDecorations(
      Canvas canvas, Offset offset, Iterable<wf.DecorationLine> lines) {
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
                paint);
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
                cx + half / 2, y + (up ? -half : half) * t, nx, y);
            up = !up;
            cx = nx;
          }
          canvas.drawPath(
              path,
              Paint()
                ..color = paint.color
                ..style = PaintingStyle.stroke
                ..strokeWidth = th);
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
              offset.dx + b.left, offset.dy + b.top, b.width, b.height),
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
      _drawDecorations(context.canvas, offset,
          emitted.decorations.where((d) => !d.aboveText));
    }
    if (emitted != null &&
        ink != null &&
        emitted.glyphCount > 0 &&
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
      final upper = math.min(16.0 * _devicePixelRatio,
          (_maxSurfaceDim - 16) / math.max(maxDim, 1e-3));
      final lower = math.min(0.25 * _devicePixelRatio, upper);
      scale =
          ui.clampDouble(scale, math.max(lower, 1e-3), math.max(upper, 1e-3));

      final key = (_contentGen, scale);
      var rendered = key == _cacheKey;
      if (!rendered) {
        rendered = _renderSurface(emitted, ink, scale);
        if (rendered) _cacheKey = key;
      }
      final image = _image;
      if (rendered && image != null) {
        final src = Rect.fromLTWH(
            0, 0, image.width.toDouble(), image.height.toDouble());
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
              // ui.Shadow.convertRadiusToSigma.
              final sigma = s.blurRadius * 0.57735 + 0.5;
              paint.imageFilter = ui.ImageFilter.blur(
                  sigmaX: sigma, sigmaY: sigma, tileMode: ui.TileMode.decal);
            }
            context.canvas.drawImageRect(image, srcRun,
                runRect.shift(offset + Offset(s.dx, s.dy)), paint);
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
      _drawDecorations(context.canvas, offset,
          emitted.decorations.where((d) => d.aboveText));
    }
    if (childCount > 0) paintInlineChildren(context, offset);
  }

  bool _renderSurface(
      wf.ParagraphInstances emitted, wf.LayoutBounds ink, double scale) {
    final textures = _engine.prepareTextures();
    if (textures == null) return false;
    // 4 device px of padding covers the shader's ~2px anti-aliasing skirt.
    const pad = 4;
    final devLeft = (ink.minX * scale).floor() - pad;
    final devTop = (ink.minY * scale).floor() - pad;
    final w = ((ink.maxX * scale).ceil() + pad - devLeft)
        .clamp(1, _maxSurfaceDim);
    final h = ((ink.maxY * scale).ceil() + pad - devTop)
        .clamp(1, _maxSurfaceDim);

    _instanceBuffer ??= _engine.pipeline.uploadInstances(emitted.instances);
    var surface = _surface;
    final sizeChanged =
        surface == null || surface.width != w || surface.height != h;
    gpu.GpuSurfaceFrame? frame;
    try {
      if (sizeChanged) {
        // Never resize() a live surface: while a presented image is still
        // referenced by the compositor (in-flight raster, retained layers),
        // resizing can leave later frames on a stale-size backing texture —
        // observed on flutter_gpu master as text stretched to the wrong
        // scale after live window resizes. A fresh surface gets fresh
        // textures; the old one is retired below with its presented image.
        surface =
            gpu.gpuContext.createImageSurface(w, h, format: _surfaceFormat());
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
      _engine.pipeline.renderInstances(
        pass: pass,
        frame: FrameUniforms(
          width: w.toDouble(),
          height: h.toDouble(),
          cam: [scale, scale, -devLeft.toDouble(), -devTop.toDouble()],
        ),
        instances: _instanceBuffer!,
        instanceCount: emitted.glyphCount,
        textures: textures,
      );
      frame.present(cmd);
      cmd.submit();
    } catch (e) {
      // Release an unpresented frame; otherwise every future resize() on
      // this surface throws "frame still acquired". No-op after present().
      frame?.discard();
      debugPrint('windfoil: paragraph render failed: $e');
      return false;
    }
    debugSurfaceRenders++;
    // Retire the previous surface+image instead of disposing them now:
    // frames that reference the old image may still be waiting to
    // rasterize (paint outpaces raster during live window resizes), and
    // disposing it early lets the pool recycle its texture under a frame
    // that is still on its way to the screen — which paints as text
    // stretched to the wrong scale. The retired pair is disposed by
    // _flushRetired once the engine reports a frame at least as new as
    // this one has finished rasterizing.
    final prevImage = _image;
    if (prevImage != null) {
      _retired.add((
        identical(_surface, surface) ? null : _surface,
        prevImage,
        ui.PlatformDispatcher.instance.frameData.frameNumber,
      ));
      _hookTimings();
    }
    _surface = surface;
    _image = surface.currentImage;
    _imageScale = scale;
    _imageDevRect = Rect.fromLTWH(
        devLeft.toDouble(), devTop.toDouble(), w.toDouble(), h.toDouble());
    if (sizeChanged && prevImage != null) {
      // The engine can composite a resize-churn frame from a stale-size
      // texture (flutter_gpu master; happens regardless of image lifetime),
      // and the last churn frame then sticks on screen wrong. A clean render
      // on a drained pipeline always heals it, so owe one follow-up render
      // gated on this frame's raster being reported: during churn every size
      // change re-arms this with a newer frame, so it converges to a single
      // heal once the engine has actually caught up — no wall-clock timers.
      // A brand-new paragraph (prevImage == null) has no presented image in
      // flight, so the hazard cannot exist and the heal render is skipped —
      // this halves first-paint GPU submissions across the board.
      _healAfterFrame = ui.PlatformDispatcher.instance.frameData.frameNumber;
      _hookTimings();
    }
    return true;
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
    properties.add(FlagProperty('transformAdaptive',
        value: _transformAdaptive, ifTrue: 'adaptive'));
  }
}

/// One placeholder-free stretch of a paragraph's source text, exposed to the
/// selection framework (SelectionArea / SelectableRegion). Mirrors
/// RenderParagraph's _SelectableFragment: geometry queries go through the
/// paragraph's ParagraphGeometry in SOURCE offsets, so copied content is the
/// pre-shaping text even when ligatures render as single proxies.
class _SelectableFragment with ChangeNotifier implements Selectable {
  _SelectableFragment(this.paragraph, this.range);

  final RenderWindfoilParagraph paragraph;

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
          status: SelectionStatus.none, hasContent: hasContent);
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
      status:
          collapsed ? SelectionStatus.collapsed : SelectionStatus.uncollapsed,
      hasContent: hasContent,
      startSelectionPoint: point(
          g.caretAt(s),
          collapsed
              ? TextSelectionHandleType.collapsed
              : (flipped
                  ? TextSelectionHandleType.right
                  : TextSelectionHandleType.left)),
      endSelectionPoint: point(
          g.caretAt(e),
          collapsed
              ? TextSelectionHandleType.collapsed
              : (flipped
                  ? TextSelectionHandleType.left
                  : TextSelectionHandleType.right)),
      selectionRects: [
        for (final r in g.boxesForRange(a, b))
          Rect.fromLTRB(r.left, r.top, r.right, r.bottom),
      ],
    );
  }

  // ---- event dispatch ----

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final SelectionResult result;
    if (event is SelectionEdgeUpdateEvent) {
      result = _updateEdge(event,
          isEnd: event.type == SelectionEventType.endEdgeUpdate);
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

  SelectionResult _updateEdge(SelectionEdgeUpdateEvent event,
      {required bool isEnd}) {
    final local = _globalToLocal(event.globalPosition);
    final adjusted = SelectionUtils.adjustDragOffset(_paragraphRect, local,
        direction: paragraph._textDirection);
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
            g.plainText, offset.clamp(0, g.plainText.length - 1));
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

  SelectionResult _selectBoundaryAt(Offset globalPosition,
      {required bool word}) {
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
          final probe = math.min(math.max(edge, 0), math.max(0, text.length - 1));
          final w = wf.wordRangeIn(text, probe);
          next = w.end > edge ? w.end : _stepForward(text, edge);
        } else {
          final probe = math.max(0, edge - 1);
          final w = wf.wordRangeIn(text, probe);
          next = w.start < edge ? w.start : _stepBackward(text, edge);
        }
      case TextGranularity.line:
        final r = g.lineRange(
            g.caretAt(edge.clamp(range.start, range.end)).line);
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
      DirectionallyExtendSelectionEvent event) {
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
        line = g.caretAt((edge ?? range.start).clamp(range.start, range.end))
                .line -
            1;
      case SelectionExtendDirection.nextLine:
        line = g.caretAt((edge ?? range.end).clamp(range.start, range.end))
                .line +
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

  // ---- content ----

  @override
  SelectedContent? getSelectedContent() {
    final s = _selectionStart;
    final e = _selectionEnd;
    final g = paragraph._geometry;
    if (s == null || e == null || s == e || g == null) return null;
    return SelectedContent(
        plainText: g.plainText.substring(math.min(s, e), math.max(s, e)));
  }

  @override
  SelectedContentRange? getSelection() {
    final s = _selectionStart;
    final e = _selectionEnd;
    if (s == null || e == null) return null;
    return SelectedContentRange(
        startOffset: s - range.start, endOffset: e - range.start);
  }

  @override
  int get contentLength => range.end - range.start;

  // ---- geometry plumbing ----

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
            Rect.fromLTRB(offset.dx + r.left, offset.dy + r.top,
                offset.dx + r.right, offset.dy + r.bottom),
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
        LeaderLayer(
            link: _startHandle!, offset: offset + start.localPosition),
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
