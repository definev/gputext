// gputext — vector text via an exact box-filtered winding integral on the
// GPU (flutter_gpu). Covered glyphs use the coverage shader; color emoji and
// uncovered/CJK characters can delegate to platform Text via WidgetSpans.
// Optional coverageGamma / coverageSharp / minificationGuardPx match
// windfoil's dials; defaults leave coverage exact.
//
// Layout types that collide with Flutter (`TextAlign`, `ParagraphStyle`)
// live in `package:gputext/internal.dart` — import with a prefix.
library;

export 'src/atlas.dart' show AtlasTextures, uploadAtlasTextures;
export 'src/bands.dart'
    show
        GlyphAtlas,
        GlyphTableEntry,
        buildGlyphAtlas,
        ColrEmojiAtlas,
        ColrGlyphLayer,
        buildColrEmojiAtlas;
export 'src/color_bitmap.dart' show BitmapGlyph, BitmapGlyphSource;
export 'src/engine/engine.dart' show AtlasFontUser, GPUText, GPUTextEngine;
export 'src/native/system_fonts.dart' show SystemFontProvider;
export 'src/engine/pipeline.dart' show FrameUniforms, GPUTextPipeline;
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
export 'src/text/shaper.dart' show TextShaper, ShapeRequest;
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
