/// Opt-in low-level text API.
///
/// Import this INSTEAD OF (or alongside) `package:gputext/gputext.dart` when
/// you want to drive the pipeline directly rather than through the
/// [GPURichText] widget:
///
///   * [GPUTextLayout] — a standalone handle over the prepare -> layout ->
///     emit split, so you lay out once and display (or recolor) many times.
///   * [GPUTextWorker] — run all of that on a background isolate and receive a
///     ready-to-upload instance buffer, so text layout never blocks the UI
///     isolate.
///
/// Nothing here touches the [GPURichText] widget flow or the `GPUText` engine
/// singleton — it is purely additive and sits beside them.
library;

export 'src/lowlevel/gpu_text_layout.dart';
export 'src/lowlevel/gpu_text_worker.dart';
export 'src/lowlevel/gpu_text_view.dart'
    show
        GPUTextView,
        GPUTextBlocksView,
        GPUBlockHeightEstimator,
        GPUTextViewController,
        GPUTextDocument,
        GPUTextMetrics;
export 'src/lowlevel/text_span_specs.dart'
    show flattenInlineSpan, PlaceholderSizer, GPUWidgetSpan;
export 'src/text/shaper.dart' show TextShaper;

// The Layer-0 primitives the facade composes, surfaced from one import.
export 'src/paragraph.dart'
    show
        InlineItem,
        TextRun,
        PlaceholderItem,
        PlaceholderBox,
        InlinePlaceholderAlignment,
        PreparedParagraph,
        ParagraphLines,
        ParagraphInstances,
        ParagraphStyle,
        TextAlign,
        LineRun,
        GlyphTable,
        SingleFontGlyphTable,
        StrutMetrics,
        DecorationLine,
        BackgroundRect,
        HitSpanBox,
        InlineDecoration,
        InlineDecorationStyle,
        prepareParagraph,
        layoutPreparedLines,
        breakLines,
        emitInstances,
        LineBreaker,
        GreedyLineBreaker,
        KnuthPlassLineBreaker;
export 'src/engine/shared_atlas.dart' show SharedGlyphAtlas;
export 'src/font.dart' show GPUFont;
export 'src/native/system_fonts.dart' show SystemFontProvider;
export 'src/text/shaped_run.dart' show TextDirection, ShapedGlyphRun;
export 'src/text/line_break_config.dart' show LineBreakConfig;

// GPU draw primitives — the emitted instance buffer is yours to upload and
// draw. A worker result (curves/rows/instances) feeds straight into these.
export 'src/atlas.dart' show AtlasTextures, uploadAtlasTextures;
export 'src/engine/pipeline.dart' show GPUTextPipeline, FrameUniforms;
export 'src/renderer.dart' show GPUTextRenderer;
export 'src/layout.dart' show floatsPerInstance;
