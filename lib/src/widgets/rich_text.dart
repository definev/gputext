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
// Remaining limits (asserted in debug, degrade gracefully in release):
// no selection or bidi/RTL shaping.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
  })  : assert(maxLines == null || maxLines > 0),
        assert(selectionRegistrar == null,
            'WindfoilRichText does not support text selection (v1)');

  final InlineSpan text;
  final TextAlign textAlign;
  final TextDirection? textDirection;
  final bool softWrap;
  final TextOverflow overflow;
  final TextScaler textScaler;
  final int? maxLines;

  /// Accepted for RichText signature compatibility; ignored in v1.
  final Locale? locale;
  final StrutStyle? strutStyle;
  final TextWidthBasis textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final SelectionRegistrar? selectionRegistrar;
  final Color? selectionColor;

  /// Re-render glyphs at the effective ancestor-transform scale so text stays
  /// crisp inside zooming containers.
  final bool transformAdaptive;

  /// Repaint trigger for zoom changes hidden behind RepaintBoundaries
  /// (e.g. an InteractiveViewer's TransformationController).
  final Listenable? scaleHint;

  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
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
          selectionColor: selectionColor,
          transformAdaptive: transformAdaptive,
          scaleHint: scaleHint,
          filterQuality: filterQuality,
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
  })  : assert(maxLines == null || maxLines > 0),
        assert(selectionRegistrar == null,
            'WindfoilRichText does not support text selection (v1)'),
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

  /// Accepted for RichText signature compatibility; ignored in v1.
  final Locale? locale;
  final StrutStyle? strutStyle;
  final TextWidthBasis textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final SelectionRegistrar? selectionRegistrar;
  final Color? selectionColor;

  /// Re-render glyphs at the effective ancestor-transform scale so text stays
  /// crisp inside zooming containers.
  final bool transformAdaptive;

  /// Repaint trigger for zoom changes hidden behind RepaintBoundaries
  /// (e.g. an InteractiveViewer's TransformationController).
  final Listenable? scaleHint;

  final FilterQuality filterQuality;

  @override
  RenderWindfoilParagraph createRenderObject(BuildContext context) {
    return RenderWindfoilParagraph(
      text: effectiveText,
      semanticsLabel: text.toPlainText(),
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
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, RenderWindfoilParagraph renderObject) {
    renderObject
      ..text = effectiveText
      ..semanticsLabel = text.toPlainText()
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
      ..filterQuality = filterQuality;
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
    required InlineSpan text,
    required String semanticsLabel,
    required TextAlign textAlign,
    required TextDirection textDirection,
    required bool softWrap,
    required TextOverflow overflow,
    required TextScaler textScaler,
    required int? maxLines,
    required double devicePixelRatio,
    required bool transformAdaptive,
    required Listenable? scaleHint,
    required FilterQuality filterQuality,
  })  : _text = text,
        _semanticsLabel = semanticsLabel,
        _textAlign = textAlign,
        _textDirection = textDirection,
        _softWrap = softWrap,
        _overflow = overflow,
        _textScaler = textScaler,
        _maxLines = maxLines,
        _devicePixelRatio = devicePixelRatio,
        _transformAdaptive = transformAdaptive,
        _scaleHint = scaleHint,
        _filterQuality = filterQuality;

  final WindfoilEngine _engine = Windfoil.instance;

  // ---- layout artifacts ----
  wf.ParagraphLines? _para;
  List<PlaceholderDimensions> _layoutDims = const [];
  double _boxWidth = 0; // alignment box = reported width
  double _lastWrapWidth = double.infinity;
  double _lastMaxWidth = double.infinity;
  List<wf.HitSpanBox> _hitBoxes = const [];
  bool _hasRecognizers = false;
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
        _needsRelayout();
    }
  }

  String _semanticsLabel;
  set semanticsLabel(String value) {
    if (_semanticsLabel == value) return;
    _semanticsLabel = value;
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
        TextAlign.justify => wf.TextAlign.left, // v1: justify degrades to left
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
      );

  wf.ParagraphLines _break(
      List<wf.InlineItem> runs, double wrapWidth, double maxWidth) {
    final para = wf.breakLines(runs, wrapWidth, _styleFor(wrapWidth));
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

  /// Cache key for flatten+break results (paragraphs without inline
  /// children only — placeholder dimensions vary per widget). Relies on
  /// TextSpan's deep ==/hashCode; fontGeneration invalidates on font churn.
  Object? _layoutCacheKey(BoxConstraints constraints) {
    if (childCount > 0) return null;
    return (
      _text,
      _textScaler,
      constraints.maxWidth,
      _softWrap,
      _overflow,
      _maxLines,
      _engine.fontGeneration,
    );
  }

  ({wf.ParagraphLines? para, List<wf.InlineItem>? runs, Size size,
      double boxWidth, double wrapWidth}) _computeLayout(
      BoxConstraints constraints, List<PlaceholderDimensions> dims) {
    final key = _layoutCacheKey(constraints);
    if (key != null) {
      final cached = _engine.layoutCacheGet(key);
      if (cached != null) {
        final para = cached.$2;
        final wrapWidth = _softWrap && constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : double.infinity;
        final width = ui.clampDouble(para.maxIntrinsicWidth,
            constraints.minWidth, constraints.maxWidth);
        return (
          para: para,
          runs: cached.$1,
          size: constraints.constrain(Size(width, para.height)),
          boxWidth: width,
          wrapWidth: wrapWidth,
        );
      }
    }
    final runs = flattenSpan(_text, _textScaler, _engine,
        placeholderDimensions: dims);
    if (runs == null || runs.isEmpty) {
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
    final para = _break(runs, wrapWidth, constraints.maxWidth);
    if (key != null) _engine.layoutCachePut(key, (runs, para));
    // TextPainter's width rule: report the unwrapped intrinsic width clamped
    // to the constraints, and align lines against THAT box (never against an
    // unbounded constraint).
    final width = ui.clampDouble(
        para.maxIntrinsicWidth, constraints.minWidth, constraints.maxWidth);
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
    _boxWidth = r.boxWidth;
    _lastWrapWidth = r.wrapWidth;
    _lastMaxWidth = constraints.maxWidth;
    _paraDirty = false;
    _contentGen++;
    size = r.size;
    bool hasRecognizer(Object? source) =>
        source is TextSpan && source.recognizer != null;
    _hasRecognizers = r.runs?.any((i) =>
            (i is wf.TextRun && hasRecognizer(i.source)) ||
            (i is wf.EmojiItem && hasRecognizer(i.source))) ??
        false;
    _hitBoxes = const [];
    final para = r.para;
    if ((childCount > 0 || _hasRecognizers) && para != null) {
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
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _computeLayout(constraints, _dryDims(constraints.maxWidth)).size;

  @override
  double computeMinIntrinsicWidth(double height) {
    final runs = flattenSpan(_text, _textScaler, _engine,
        placeholderDimensions: _dryDims(double.infinity));
    if (runs == null || runs.isEmpty) return 0;
    return wf
        .breakLines(runs, double.infinity, _styleFor(double.infinity))
        .minIntrinsicWidth;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final runs = flattenSpan(_text, _textScaler, _engine,
        placeholderDimensions: _dryDims(double.infinity));
    if (runs == null || runs.isEmpty) return 0;
    return wf
        .breakLines(runs, double.infinity, _styleFor(double.infinity))
        .maxIntrinsicWidth;
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

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      hitTestInlineChildren(result, position);

  @override
  void handleEvent(PointerEvent event, covariant BoxHitTestEntry entry) {
    assert(debugHandleEvent(event, entry));
    if (event is! PointerDownEvent) return;
    for (final b in _hitBoxes) {
      if (b.contains(entry.localPosition.dx, entry.localPosition.dy)) {
        final src = b.source;
        if (src is TextSpan) {
          final recognizer = src.recognizer;
          if (recognizer != null) {
            recognizer.addPointer(event);
            return;
          }
        }
      }
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      defaultApplyPaintTransform(child, transform);

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..label = _semanticsLabel
      ..textDirection = _textDirection;
  }

  // ---- paint ----

  void _prepareContent() {
    if (_paraDirty) {
      // Paint-only span change (e.g. colors): re-break at the same widths;
      // metrics are unchanged by construction of RenderComparison.paint.
      final runs = flattenSpan(_text, _textScaler, _engine,
          placeholderDimensions: _layoutDims);
      if (runs != null && runs.isNotEmpty) {
        _para = _break(runs, _lastWrapWidth, _lastMaxWidth);
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
        _paintContents,
        oldLayer: _clipHandle.layer,
      );
    } else {
      _clipHandle.layer = null;
      _paintContents(context, offset);
    }
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
        final dst = Rect.fromLTWH(
          offset.dx + _imageDevRect.left / _imageScale,
          offset.dy + _imageDevRect.top / _imageScale,
          _imageDevRect.width / _imageScale,
          _imageDevRect.height / _imageScale,
        );
        context.canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
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
    if (sizeChanged) {
      // The engine can composite a resize-churn frame from a stale-size
      // texture (flutter_gpu master; happens regardless of image lifetime),
      // and the last churn frame then sticks on screen wrong. A clean render
      // on a drained pipeline always heals it, so owe one follow-up render
      // gated on this frame's raster being reported: during churn every size
      // change re-arms this with a newer frame, so it converges to a single
      // heal once the engine has actually caught up — no wall-clock timers.
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
