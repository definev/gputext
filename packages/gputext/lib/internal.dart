// Layout / paragraph internals that share names with Flutter's text APIs
// (`TextAlign`, `ParagraphStyle`). Import this library with a prefix when
// you need both Flutter and gputext types in the same file:
//
//   import 'package:gputext/gputext.dart';
//   import 'package:gputext/internal.dart' as gt;
//
//   TextAlign.start          // Flutter
//   gt.TextAlign.justify     // gputext
library;

export 'src/paragraph.dart'
    show
        TextAlign,
        ParagraphStyle,
        LineMetrics,
        LineItem,
        LineRun,
        LineEmoji,
        LinePlaceholder;
export 'src/text/shaped_run.dart' show TextDirection;
