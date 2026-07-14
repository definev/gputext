// Opt-in low-level layout/display facade.
//
// VM-pure: no widgets, no flutter_gpu, no GPUText engine singleton. This
// composes the SAME prepare -> layout -> emit primitives that
// RenderGPUParagraph uses, but exposes them as a standalone handle so callers
// can drive the three phases explicitly:
//
//   1. compute()  — width-independent prepare (shaping already folded into the
//                   runs); the expensive, reuse-across-widths half. Do it once.
//   2. reflow()   — cheap per-width line breaking + positioning. Cached by
//                   width, so a resize that returns to a prior width is free.
//   3. emit()     — build the 16-float/glyph GPU instance buffer against a
//                   caller-owned glyph table. Cheap enough per frame; a
//                   color-only change is just a re-emit, no relayout.
//
// Decoupling contract: this sits BESIDE GPURichText as a sibling consumer of
// the layout layer. It never reads GPUText.instance and never touches the GPU,
// so the existing widget flow is unaffected and this is safe to run on a
// background isolate (see GPUTextWorker). The glyph table is injected rather
// than pulled from the global engine atlas, so a caller may share the engine's
// SharedGlyphAtlas or bring its own.

import '../paragraph.dart';

class GPUTextLayout {
  GPUTextLayout._(this.prepared);

  /// PHASE 1 — width-independent prepare over already-shaped [items] (each
  /// [TextRun] carries its `ShapedGlyphRun`). Runs HarfBuzz-independent
  /// segmentation + measurement; the result is reusable across every width.
  factory GPUTextLayout.compute(
    List<InlineItem> items, {
    LineBreakConfig? lineBreak,
  }) => GPUTextLayout._(prepareParagraph(items, lineBreak: lineBreak));

  /// Adopt an already-prepared paragraph — e.g. one handed back from a worker
  /// isolate — without re-running prepare.
  factory GPUTextLayout.fromPrepared(PreparedParagraph prepared) =>
      GPUTextLayout._(prepared);

  final PreparedParagraph prepared;

  /// Widest single unbreakable unit / widest hard-break line — available
  /// before any [reflow], straight off the prepare pass.
  double get minIntrinsicWidth => prepared.minIntrinsicWidth;
  double get maxIntrinsicWidth => prepared.maxIntrinsicWidth;

  ParagraphLines? _lines;
  double _lastWidth = double.nan;
  ParagraphStyle? _lastStyle;

  /// PHASE 2 — cheap per-width reflow. Repeated calls at the same [width] and
  /// [style] return the cached [ParagraphLines] without recomputing.
  ParagraphLines reflow(double width, ParagraphStyle style) {
    final cached = _lines;
    if (cached != null && width == _lastWidth && identical(style, _lastStyle)) {
      return cached;
    }
    _lastWidth = width;
    _lastStyle = style;
    return _lines = layoutPreparedLines(prepared, width, style);
  }

  /// The most recent [reflow] result. Throws if [reflow] hasn't run yet.
  ParagraphLines get lines =>
      _lines ??
      (throw StateError('call reflow() before reading lines / emit()'));

  /// PHASE 3 — emit GPU instances against a caller-owned [table]. Defaults
  /// [boxWidth]/[align] to the last [reflow] so the common case is a bare
  /// `emit(atlas)`. Re-emitting after a color-only style change costs one walk,
  /// no prepare and no layout.
  ParagraphInstances emit(
    GlyphTable table, {
    TextAlign? align,
    double? boxWidth,
  }) {
    final resolved = lines;
    return emitInstances(
      resolved,
      boxWidth ?? _lastWidth,
      align ?? _lastStyle?.align ?? TextAlign.left,
      table,
    );
  }
}
