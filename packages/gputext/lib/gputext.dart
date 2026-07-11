// gputext — vector text rendered by an exact box-filtered winding
// integral on the GPU (flutter_gpu), with a drop-in RichText replacement.
//
//   await GPUText.initialize();                       // optional, no-FOUT
//   GPURichText(text: TextSpan(...));             // swap for RichText
//   GPULabel('hello');                             // swap for Text
//
// Paint is hybrid: covered glyphs use the GPU coverage shader; color emoji
// and uncovered/CJK characters delegate to platform Text via WidgetSpans.
// Optional coverageGamma / coverageSharp / minificationGuardPx on
// GPURichText (and FrameUniforms.style / guardPx) match windfoil's styling
// and minification-guard dials; defaults leave coverage exact.
//
// Layout types that collide with Flutter (`TextAlign`, `ParagraphStyle`)
// live in `package:gputext/internal.dart` — import with a prefix.
library;

export 'src/engine/engine.dart' show AtlasFontUser, GPUText, GPUTextEngine;
export 'src/engine/pipeline.dart' show FrameUniforms;
export 'src/font.dart'
    show
        GPUFont,
        FillRule,
        VerticalMetrics,
        FontAxis,
        GPUFontVariations,
        applyBasicLigatures;
export 'src/paragraph.dart'
    show
        InlineItem,
        TextRun,
        PreparedParagraph,
        ParagraphLines,
        prepareParagraph,
        breakLines,
        layoutPreparedLines;
export 'src/renderer.dart' show GPUTextRenderer;
export 'src/scene.dart' show GPUTextScene, background, maxSize;
export 'src/text/analysis.dart' show SegmentBreakKind;
export 'src/text/bidi.dart'
    show BidiRun, itemize, reorderVisual, paragraphLevel;
export 'src/text/line_breaker.dart'
    show LineBreaker, GreedyLineBreaker, KnuthPlassLineBreaker;
export 'src/text/metrics_cache.dart'
    show debugClearSegmentMetricsFor, debugSegmentMetricsLengthFor;
export 'src/text/shaped_run.dart' show ShapedGlyph, ShapedGlyphRun, walkGlyphs;
export 'src/text/shaper.dart' show TextShaper, LegacyGsubShaper, ShapeRequest;
export 'src/text/harfbuzz_shaper.dart' show HarfBuzzShaper;
export 'src/timeline.dart'
    show
        AggregatedTimedBlock,
        AggregatedTimings,
        GPUTextTimeline,
        TimedBlock;
export 'src/widgets/rich_text.dart' show GPURichText, RenderGPUParagraph;
export 'src/widgets/span_flattener.dart' show flattenSpan;
export 'src/widgets/text.dart' show GPULabel;
