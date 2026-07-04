// windfoil_flutter — vector text rendered by an exact box-filtered winding
// integral on the GPU (flutter_gpu), with a drop-in RichText replacement.
//
//   await Windfoil.initialize();                       // optional, no-FOUT
//   WindfoilRichText(text: TextSpan(...));             // swap for RichText
//   WindfoilText('hello');                             // swap for Text
library;

export 'src/engine/engine.dart' show Windfoil, WindfoilEngine;
export 'src/font.dart' show WindfoilFont, FillRule, VerticalMetrics;
export 'src/widgets/rich_text.dart'
    show WindfoilRichText, RenderWindfoilParagraph;
export 'src/widgets/text.dart' show WindfoilText;
