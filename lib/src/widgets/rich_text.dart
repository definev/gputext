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
// Remaining limits (asserted in debug, degrade gracefully in release):
// no selection, bidi/RTL shaping, decorations, or font fallback.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import '../engine/engine.dart';
import '../engine/pipeline.dart';
import '../layout.dart' as wf show LayoutBounds;
import '../paragraph.dart' as wf;
import 'span_flattener.dart';

const _maxSurfaceDim = 8192;

class WindfoilRichText extends MultiChildRenderObjectWidget {
  WindfoilRichText({
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
            'WindfoilRichText does not support text selection (v1)'),
        super(children: WidgetSpan.extractFromInlineSpan(text, textScaler));

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
  RenderWindfoilParagraph createRenderObject(BuildContext context) {
    return RenderWindfoilParagraph(
      text: text,
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
      ..text = text
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
  bool _paraDirty = false; // paint-only span change pending re-break
  int _contentGen = 0; // bumped on any content change (layout or paint-only)

  // ---- paint artifacts ----
  wf.ParagraphInstances? _emitted;
  int _emittedGen = -1;
  gpu.DeviceBuffer? _instanceBuffer;
  gpu.GpuImageSurface? _surface;
  ui.Image? _image;
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
        markNeedsSemanticsUpdate();
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

  @override
  void dispose() {
    _clipHandle.layer = null;
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

  ({wf.ParagraphLines? para, List<wf.InlineItem>? runs, Size size,
      double boxWidth, double wrapWidth}) _computeLayout(
      BoxConstraints constraints, List<PlaceholderDimensions> dims) {
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
    if (childCount > 0) {
      final para = r.para;
      final boxes = para == null
          ? const <wf.PlaceholderBox>[]
          : wf.emitInstances(para, r.boxWidth, _resolvedAlign, null)
              .placeholders;
      positionInlineChildren([
        for (final b in boxes)
          ui.TextBox.fromLTRBD(b.left, b.top, b.left + b.width,
              b.top + b.height, _textDirection),
      ]);
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
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      defaultApplyPaintTransform(child, transform);

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..label = _text.toPlainText()
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
        for (final run in line.items.whereType<wf.LineRun>()) {
          _engine.atlas.ensureGlyphs(run.font, run.text);
        }
      }
      _emitted = wf.emitInstances(para, _boxWidth, _resolvedAlign, _engine.atlas);
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

  void _paintContents(PaintingContext context, Offset offset) {
    final emitted = _emitted;
    final ink = emitted?.inkBounds;
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
    try {
      if (surface == null) {
        surface = _surface =
            gpu.gpuContext.createImageSurface(w, h, format: _surfaceFormat());
      } else if (surface.width != w || surface.height != h) {
        surface.resize(w, h);
      }
      final frame = surface.acquireNextFrame();
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
      debugPrint('windfoil: paragraph render failed: $e');
      return false;
    }
    _image?.dispose();
    _image = surface.currentImage;
    _imageScale = scale;
    _imageDevRect = Rect.fromLTWH(
        devLeft.toDouble(), devTop.toDouble(), w.toDouble(), h.toDouble());
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
