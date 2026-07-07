// gputext — vector text rendered by an exact box-filtered winding
// integral on the GPU (flutter_gpu), with a drop-in RichText replacement.
//
//   await GPUText.initialize();                       // optional, no-FOUT
//   GPURichText(text: TextSpan(...));             // swap for RichText
//   GPULabel('hello');                             // swap for Text
library;

export 'src/engine/engine.dart' show GPUText, GPUTextEngine;
export 'src/font.dart' show GPUFont, FillRule, VerticalMetrics;
export 'src/text/line_breaker.dart'
    show LineBreaker, GreedyLineBreaker, KnuthPlassLineBreaker;
export 'src/widgets/rich_text.dart'
    show GPURichText, RenderGPUParagraph;
export 'src/widgets/text.dart' show GPULabel;
