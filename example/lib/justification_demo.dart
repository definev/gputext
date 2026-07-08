// Port of pretext's justification-comparison demo
// (pretext/pages/demos/justification-comparison.*): three justified columns
// of the same essay, from worst to best typographic colour — every glyph
// rendered by gputext itself (no TextPainter):
//
//   1. The default greedy breaker (the browser-CSS baseline).
//   2. The same greedy breaker over soft-hyphenated text.
//   3. GPURichText(lineBreaker: KnuthPlassLineBreaker()) — the library's
//      total-fit optimizer over the same hyphenated text.
//
// Every column is a plain justified GPURichText; only the text and the
// lineBreaker differ. The model re-runs the same breakers over the same
// prepared paragraphs to position the river overlay (red heat behind
// over-stretched gaps) and compute lines / spacing deviation / river counts,
// so overlays and metrics agree with the rendered breaks by construction.
// Paragraph text is pre-ligated with the flattener's fi/fl substitution so
// model widths match rendered advances.
//
// Dev hooks (demo only): GPUTEXT_DEMO=justify opens this page;
// GPUTEXT_DEMO_WIDTH=<px> presets the column width for screenshots.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:gputext/gputext.dart' hide TextAlign;
import 'package:gputext/gputext.dart' as wf;

// --- Data (ported verbatim from justification-comparison.data.ts) ---

const _paragraphs = [
  'The relationship between typographic colour and reading comfort has been '
      'studied extensively since the early twentieth century. When lines of '
      'justified text contain excessive inter-word spacing, the eye perceives '
      'pale horizontal streaks — "rivers" — that cut vertically through the '
      'paragraph, disrupting the smooth lateral scanning motion that skilled '
      'readers depend upon. These rivers are not merely an aesthetic blemish; '
      'they constitute a measurable impediment to reading speed and '
      'comprehension.',
  'Traditional typesetting systems addressed this problem through a '
      'combination of techniques: hyphenation dictionaries that permitted '
      'words to break at syllable boundaries, letterspacing adjustments that '
      'distributed small amounts of additional space between individual '
      'characters, and — most significantly — global optimization algorithms '
      'that evaluated thousands of possible line-break combinations to find '
      'the arrangement minimizing total spacing deviation across the entire '
      'paragraph.',
  'The Knuth-Plass algorithm, developed by Donald Knuth and Michael Plass '
      'for the TeX typesetting system in 1981, remains the gold standard for '
      'paragraph optimization. Rather than greedily filling each line from '
      'left to right, the algorithm constructs a graph of all feasible '
      'breakpoints and finds the shortest path — the combination of breaks '
      'that produces the most uniform spacing throughout. Even a simplified '
      'implementation produces dramatically better results than the greedy '
      'approach used by web browsers and most word processors.',
  'Modern CSS justification operates on a strictly greedy, line-by-line '
      'basis: the browser fills each line with as many words as will fit, '
      'then distributes the remaining space uniformly between words. This '
      'approach requires no lookahead and executes quickly, but it produces '
      'wildly inconsistent spacing — particularly in narrow columns where a '
      'single long word can force enormous gaps across the preceding line. '
      'The result: rivers of white space that would have horrified any '
      'compositor working with metal type.',
];

const _fontSize = 15.0;
const _lineHeight = 24.0;
const _pad = 12.0;
const _paraGap = _lineHeight * 0.6;

const _softHyphen = '\u00AD';
const _riverThreshold = 1.5;

const _hyphenExceptions = <String, List<String>>{
  'extensively': ['ex', 'ten', 'sive', 'ly'],
  'relationship': ['re', 'la', 'tion', 'ship'],
  'typographic': ['ty', 'po', 'graph', 'ic'],
  'comfortable': ['com', 'fort', 'a', 'ble'],
  'horizontal': ['hor', 'i', 'zon', 'tal'],
  'vertically': ['ver', 'ti', 'cal', 'ly'],
  'disrupting': ['dis', 'rupt', 'ing'],
  'comprehension': ['com', 'pre', 'hen', 'sion'],
  'traditional': ['tra', 'di', 'tion', 'al'],
  'combination': ['com', 'bi', 'na', 'tion'],
  'techniques': ['tech', 'niques'],
  'hyphenation': ['hy', 'phen', 'a', 'tion'],
  'dictionaries': ['dic', 'tion', 'ar', 'ies'],
  'permitted': ['per', 'mit', 'ted'],
  'syllable': ['syl', 'la', 'ble'],
  'boundaries': ['bound', 'a', 'ries'],
  'letterspacing': ['let', 'ter', 'spac', 'ing'],
  'adjustments': ['ad', 'just', 'ments'],
  'distributed': ['dis', 'trib', 'u', 'ted'],
  'additional': ['ad', 'di', 'tion', 'al'],
  'individual': ['in', 'di', 'vid', 'u', 'al'],
  'characters': ['char', 'ac', 'ters'],
  'significantly': ['sig', 'nif', 'i', 'cant', 'ly'],
  'optimization': ['op', 'ti', 'mi', 'za', 'tion'],
  'evaluated': ['e', 'val', 'u', 'at', 'ed'],
  'thousands': ['thou', 'sands'],
  'possible': ['pos', 'si', 'ble'],
  'arrangement': ['ar', 'range', 'ment'],
  'minimizing': ['min', 'i', 'miz', 'ing'],
  'deviation': ['de', 'vi', 'a', 'tion'],
  'paragraph': ['par', 'a', 'graph'],
  'algorithm': ['al', 'go', 'rithm'],
  'developed': ['de', 'vel', 'oped'],
  'typesetting': ['type', 'set', 'ting'],
  'constructs': ['con', 'structs'],
  'feasible': ['fea', 'si', 'ble'],
  'breakpoints': ['break', 'points'],
  'produces': ['pro', 'du', 'ces'],
  'uniform': ['u', 'ni', 'form'],
  'throughout': ['through', 'out'],
  'simplified': ['sim', 'pli', 'fied'],
  'implementation': ['im', 'ple', 'men', 'ta', 'tion'],
  'dramatically': ['dra', 'mat', 'i', 'cal', 'ly'],
  'processors': ['proc', 'es', 'sors'],
  'justification': ['jus', 'ti', 'fi', 'ca', 'tion'],
  'operates': ['op', 'er', 'ates'],
  'strictly': ['strict', 'ly'],
  'distributes': ['dis', 'trib', 'utes'],
  'remaining': ['re', 'main', 'ing'],
  'uniformly': ['u', 'ni', 'form', 'ly'],
  'requires': ['re', 'quires'],
  'lookahead': ['look', 'a', 'head'],
  'executes': ['ex', 'e', 'cutes'],
  'quickly': ['quick', 'ly'],
  'inconsistent': ['in', 'con', 'sis', 'tent'],
  'particularly': ['par', 'tic', 'u', 'lar', 'ly'],
  'enormous': ['e', 'nor', 'mous'],
  'preceding': ['pre', 'ced', 'ing'],
  'compositor': ['com', 'pos', 'i', 'tor'],
  'twentieth': ['twen', 'ti', 'eth'],
  'century': ['cen', 'tu', 'ry'],
  'perceived': ['per', 'ceived'],
  'streaks': ['streaks'],
  'scanning': ['scan', 'ning'],
  'impediment': ['im', 'ped', 'i', 'ment'],
  'addressed': ['ad', 'dressed'],
  'combinations': ['com', 'bi', 'na', 'tions'],
  'measuring': ['meas', 'ur', 'ing'],
  'measurable': ['meas', 'ur', 'a', 'ble'],
  'reading': ['read', 'ing'],
  'spacing': ['spac', 'ing'],
  'between': ['be', 'tween'],
  'excessive': ['ex', 'ces', 'sive'],
  'aesthetic': ['aes', 'thet', 'ic'],
  'merely': ['mere', 'ly'],
  'constitute': ['con', 'sti', 'tute'],
  'lateral': ['lat', 'er', 'al'],
  'skilled': ['skilled'],
  'readers': ['read', 'ers'],
  'depend': ['de', 'pend'],
  'studying': ['stud', 'y', 'ing'],
  'studied': ['stud', 'ied'],
  'comfort': ['com', 'fort'],
  'colour': ['col', 'our'],
  'working': ['work', 'ing'],
  'horrified': ['hor', 'ri', 'fied'],
  'especially': ['es', 'pe', 'cial', 'ly'],
  'precisely': ['pre', 'cise', 'ly'],
  'browsers': ['brows', 'ers'],
  'modern': ['mod', 'ern'],
  'approach': ['ap', 'proach'],
  'wildly': ['wild', 'ly'],
  'columns': ['col', 'umns'],
  'single': ['sin', 'gle'],
  'standard': ['stan', 'dard'],
  'Michael': ['Mi', 'cha', 'el'],
  'Donald': ['Don', 'ald'],
  'remains': ['re', 'mains'],
  'system': ['sys', 'tem'],
  'rather': ['rath', 'er'],
  'greedily': ['greed', 'i', 'ly'],
  'filling': ['fill', 'ing'],
  'shortest': ['short', 'est'],
  'results': ['re', 'sults'],
  'greedy': ['greed', 'y'],
  'number': ['num', 'ber'],
  'completely': ['com', 'plete', 'ly'],
  'different': ['dif', 'fer', 'ent'],
  'problem': ['prob', 'lem'],
  'amounts': ['a', 'mounts'],
  'entire': ['en', 'tire'],
  'global': ['glob', 'al'],
  'metal': ['met', 'al'],
  'every': ['ev', 'ery'],
  'inter': ['in', 'ter'],
};

const _prefixes = [
  'anti',
  'auto',
  'be',
  'bi',
  'co',
  'com',
  'con',
  'contra',
  'counter',
  'de',
  'dis',
  'en',
  'em',
  'ex',
  'extra',
  'fore',
  'hyper',
  'il',
  'im',
  'in',
  'inter',
  'intra',
  'ir',
  'macro',
  'mal',
  'micro',
  'mid',
  'mis',
  'mono',
  'multi',
  'non',
  'omni',
  'out',
  'over',
  'para',
  'poly',
  'post',
  'pre',
  'pro',
  'pseudo',
  'quasi',
  're',
  'retro',
  'semi',
  'sub',
  'super',
  'sur',
  'syn',
  'tele',
  'trans',
  'tri',
  'ultra',
  'un',
  'under',
];

const _suffixes = [
  'able',
  'ible',
  'tion',
  'sion',
  'ment',
  'ness',
  'ous',
  'ious',
  'eous',
  'ful',
  'less',
  'ive',
  'ative',
  'itive',
  'al',
  'ial',
  'ical',
  'ing',
  'ling',
  'ed',
  'er',
  'est',
  'ism',
  'ist',
  'ity',
  'ety',
  'ty',
  'ence',
  'ance',
  'ly',
  'fy',
  'ify',
  'ize',
  'ise',
  'ure',
  'ture',
];

// --- Hyphenation (exception dictionary + affix heuristics) ---

String _hyphenateParagraph(String paragraph) {
  final out = StringBuffer();
  for (final token in paragraph.split(RegExp(r'(?<=\s)|(?=\s)'))) {
    if (token.trim().isEmpty) {
      out.write(token);
      continue;
    }
    final parts = _hyphenateWord(token);
    out.write(parts.length <= 1 ? token : parts.join(_softHyphen));
  }
  return out.toString();
}

List<String> _hyphenateWord(String word) {
  final lower = word.toLowerCase().replaceAll(RegExp('[.,;:!?"\'—–-]'), '');
  if (lower.length < 5) return [word];

  final exact = _hyphenExceptions[lower];
  if (exact != null) {
    final parts = <String>[];
    var position = 0;
    for (final part in exact) {
      parts.add(
        word.substring(
          position,
          (position + part.length).clamp(0, word.length),
        ),
      );
      position += part.length;
    }
    if (position < word.length) {
      parts[parts.length - 1] += word.substring(position);
    }
    return parts;
  }

  for (final prefix in _prefixes) {
    if (lower.startsWith(prefix) && lower.length - prefix.length >= 3) {
      return [word.substring(0, prefix.length), word.substring(prefix.length)];
    }
  }
  for (final suffix in _suffixes) {
    if (lower.endsWith(suffix) && lower.length - suffix.length >= 3) {
      final cut = word.length - suffix.length;
      return [word.substring(0, cut), word.substring(cut)];
    }
  }
  return [word];
}

// --- Layout model (ported from justification-comparison.model.ts) ---

class _LineSegment {
  const _LineSegment(this.text, this.width, {required this.isSpace});

  final String text;
  final double width;
  final bool isSpace;
}

class _MeasuredLine {
  _MeasuredLine({
    required this.segments,
    required this.wordWidth,
    required this.spaceCount,
    required this.naturalWidth,
    required this.maxWidth,
    required this.isParagraphEnd,
  });

  final List<_LineSegment> segments;
  final double wordWidth;
  final int spaceCount;
  final double naturalWidth;
  final double maxWidth;
  final bool isParagraphEnd;
}

sealed class _LineSpacing {
  const _LineSpacing();
}

class _Ragged extends _LineSpacing {
  const _Ragged();
}

class _Justified extends _LineSpacing {
  const _Justified(this.width, {required this.isRiver});

  final double width;
  final bool isRiver;
}

class _PositionedLine {
  const _PositionedLine(this.line, this.y, this.spacing);

  final _MeasuredLine line;
  final double y;
  final _LineSpacing spacing;
}

class _Metrics {
  const _Metrics(
    this.avgDeviation,
    this.maxDeviation,
    this.riverCount,
    this.lineCount,
  );

  final double avgDeviation;
  final double maxDeviation;
  final int riverCount;
  final int lineCount;
}

class _ColumnFrame {
  const _ColumnFrame(this.paragraphs, this.totalHeight, this.metrics);

  final List<List<_PositionedLine>> paragraphs;
  final double totalHeight;
  final _Metrics metrics;

  Iterable<_PositionedLine> get lines => paragraphs.expand((p) => p);
}

class _Resources {
  // Ligate BEFORE hyphenating/preparing: the flattener applies the same
  // fi/fl substitution at render time, so measuring pre-ligated text keeps
  // model widths and painted advances identical (a ligature glyph is atomic,
  // so no soft hyphen can land inside one either).
  _Resources(this.font)
    : baseText = [for (final p in _paragraphs) applyBasicLigatures(p, font)],
      hyphenatedText = [
        for (final p in _paragraphs)
          _hyphenateParagraph(applyBasicLigatures(p, font)),
      ],
      spaceWidth = font.advanceOf(' ') / font.unitsPerEm * _fontSize {
    base = [for (final t in baseText) _prepare(t, font)];
    hyphenated = [for (final t in hyphenatedText) _prepare(t, font)];
  }

  static wf.PreparedParagraph _prepare(String text, GPUFont font) =>
      wf.prepareParagraph([
        wf.TextRun(
          text: text,
          font: font,
          fontSizePx: _fontSize,
          color: const [0, 0, 0, 1],
        ),
      ]);

  final GPUFont font;

  /// The exact strings the widgets render — the model prepares the SAME
  /// strings, so breaks agree.
  final List<String> baseText;
  final List<String> hyphenatedText;
  late final List<wf.PreparedParagraph> base;
  late final List<wf.PreparedParagraph> hyphenated;
  final double spaceWidth;
}

bool _isSpaceKind(SegmentBreakKind kind) =>
    kind == SegmentBreakKind.space || kind == SegmentBreakKind.tab;

bool _isInvisibleKind(SegmentBreakKind kind) =>
    kind == SegmentBreakKind.softHyphen ||
    kind == SegmentBreakKind.zeroWidthBreak ||
    kind == SegmentBreakKind.hardBreak;

/// Run any [LineBreaker] over a prepared paragraph, then re-derive per-line
/// word/space stats for the river overlay and quality metrics. The same
/// breaker instance goes to the GPURichText widgets, so the model's
/// breaks and the rendered breaks agree by construction.
List<_MeasuredLine> _layoutWith(
  LineBreaker breaker,
  wf.PreparedParagraph p,
  double maxWidth,
) {
  final lines = <_MeasuredLine>[];
  final lb = p.lineBreak;
  for (var ci = 0; ci < lb.chunks.length; ci++) {
    if (lb.chunks[ci].start == lb.chunks[ci].end) continue;
    for (final range in breaker.breakChunk(lb, ci, maxWidth)) {
      lines.add(
        _measuredLineFromSegments(
          p,
          range.startSegment,
          range.endSegment,
          maxWidth,
          isParagraphEnd: range.hardBreak,
          chosenHyphen:
              !range.hardBreak &&
              range.endSegment > 0 &&
              range.endSegment <= p.segmentCount &&
              p.lineBreak.kinds[range.endSegment - 1] ==
                  SegmentBreakKind.softHyphen,
        ),
      );
    }
  }
  return lines;
}

_MeasuredLine _measuredLineFromSegments(
  wf.PreparedParagraph p,
  int from,
  int to,
  double maxWidth, {
  required bool isParagraphEnd,
  required bool chosenHyphen,
}) {
  final segments = <_LineSegment>[];
  final kinds = p.lineBreak.kinds;
  final widths = p.lineBreak.widths;
  for (var i = from; i < to && i < p.segmentCount; i++) {
    if (_isInvisibleKind(kinds[i])) continue;
    segments.add(
      _LineSegment(
        _isSpaceKind(kinds[i]) ? ' ' : p.segmentTexts[i],
        widths[i],
        isSpace: _isSpaceKind(kinds[i]),
      ),
    );
  }
  if (chosenHyphen) {
    final hyphenW = to - 1 < widths.length ? widths[to - 1] : 0.0;
    segments.add(_LineSegment('-', hyphenW, isSpace: false));
  }
  while (segments.isNotEmpty && segments.last.isSpace) {
    segments.removeLast();
  }

  var wordWidth = 0.0;
  var spaceCount = 0;
  var naturalWidth = 0.0;
  for (final s in segments) {
    naturalWidth += s.width;
    if (s.isSpace) {
      spaceCount++;
    } else {
      wordWidth += s.width;
    }
  }
  return _MeasuredLine(
    segments: segments,
    wordWidth: wordWidth,
    spaceCount: spaceCount,
    naturalWidth: naturalWidth,
    maxWidth: maxWidth,
    isParagraphEnd: isParagraphEnd,
  );
}

// --- Column assembly, spacing decisions, and metrics ---

/// Mirrors gputext's native TextAlign.justify: every non-hard line
/// stretches (or compresses) its spaces to the box width, which is exactly
/// what the GPURichText columns paint.
_LineSpacing _displaySpacing(_MeasuredLine line, double spaceWidth) {
  if (line.isParagraphEnd) return const _Ragged();
  if (line.spaceCount <= 0) return const _Ragged();
  final justified = (line.maxWidth - line.wordWidth) / line.spaceCount;
  return _Justified(
    justified,
    isRiver: justified > spaceWidth * _riverThreshold,
  );
}

double? _metricSpaceWidth(_MeasuredLine line) {
  if (line.isParagraphEnd || line.spaceCount <= 0) return null;
  return (line.maxWidth - line.wordWidth) / line.spaceCount;
}

_Metrics _computeMetrics(Iterable<_MeasuredLine> lines, double spaceWidth) {
  var totalDeviation = 0.0;
  var maxDeviation = 0.0;
  var deviationCount = 0;
  var riverCount = 0;
  var lineCount = 0;
  for (final line in lines) {
    lineCount++;
    final w = _metricSpaceWidth(line);
    if (w == null) continue;
    final deviation = (w - spaceWidth).abs() / spaceWidth;
    totalDeviation += deviation;
    if (deviation > maxDeviation) maxDeviation = deviation;
    deviationCount++;
    if (w > spaceWidth * _riverThreshold) riverCount++;
  }
  return _Metrics(
    deviationCount > 0 ? totalDeviation / deviationCount : 0,
    maxDeviation,
    riverCount,
    lineCount,
  );
}

_ColumnFrame _buildColumn(
  List<List<_MeasuredLine>> paragraphs,
  double spaceWidth,
) {
  var y = _pad;
  final positionedParagraphs = <List<_PositionedLine>>[];
  for (var pi = 0; pi < paragraphs.length; pi++) {
    final positioned = <_PositionedLine>[];
    for (final line in paragraphs[pi]) {
      positioned.add(
        _PositionedLine(line, y, _displaySpacing(line, spaceWidth)),
      );
      y += _lineHeight;
    }
    positionedParagraphs.add(positioned);
    if (pi < paragraphs.length - 1) y += _paraGap;
  }
  return _ColumnFrame(
    positionedParagraphs,
    y + _pad,
    _computeMetrics(paragraphs.expand((p) => p), spaceWidth),
  );
}

Color? _riverColor(double spaceWidth, double normalSpaceWidth) {
  if (spaceWidth <= normalSpaceWidth * _riverThreshold) return null;
  final intensity =
      ((spaceWidth / normalSpaceWidth - _riverThreshold) / _riverThreshold)
          .clamp(0.0, 1.0);
  return Color.fromRGBO(
    (220 + intensity * 35).round(),
    (180 - intensity * 80).round(),
    (180 - intensity * 80).round(),
    0.25 + intensity * 0.35,
  );
}

// --- Rendering: gputext widgets + river overlay ---

const _textColor = Color(0xFF2A2520);
const _bodyStyle = TextStyle(
  fontFamily: 'Lato',
  fontSize: _fontSize,
  height: _lineHeight / _fontSize,
  color: _textColor,
);

/// River heat rectangles behind over-stretched justified gaps, positioned
/// from the model's segment widths. The glyphs render on top via
/// GPURichText, which measures with the same font tables, so the x
/// advances agree.
class _RiverOverlayPainter extends CustomPainter {
  _RiverOverlayPainter({required this.frame, required this.spaceWidth});

  final _ColumnFrame frame;
  final double spaceWidth;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final paint = Paint();
    for (final positioned in frame.lines) {
      final spacing = positioned.spacing;
      if (spacing is! _Justified || !spacing.isRiver) continue;
      final color = _riverColor(spacing.width, spaceWidth);
      if (color == null) continue;
      paint.color = color;
      var x = _pad;
      for (final segment in positioned.line.segments) {
        if (segment.isSpace) {
          canvas.drawRect(
            Rect.fromLTWH(x + 1, positioned.y, spacing.width - 2, _lineHeight),
            paint,
          );
          x += spacing.width;
        } else {
          x += segment.width;
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RiverOverlayPainter old) =>
      old.frame != frame || old.spaceWidth != spaceWidth;
}

/// One fully gputext-rendered column: river overlay underneath, one
/// justified GPURichText per paragraph on top, breaking with the same
/// [LineBreaker] the model ran.
class _GPUTextColumn extends StatelessWidget {
  const _GPUTextColumn({
    required this.frame,
    required this.width,
    required this.showIndicators,
    required this.spaceWidth,
    required this.paragraphTexts,
    required this.breaker,
  });

  final _ColumnFrame frame;
  final double width;
  final bool showIndicators;
  final double spaceWidth;

  /// The exact strings the model prepared (ligated, possibly hyphenated).
  final List<String> paragraphTexts;
  final LineBreaker breaker;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: frame.totalHeight,
      child: Stack(
        children: [
          if (showIndicators)
            Positioned.fill(
              child: CustomPaint(
                painter: _RiverOverlayPainter(
                  frame: frame,
                  spaceWidth: spaceWidth,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(_pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < paragraphTexts.length; i++) ...[
                  if (i > 0) const SizedBox(height: _paraGap),
                  GPURichText(
                    text: TextSpan(text: paragraphTexts[i], style: _bodyStyle),
                    textAlign: TextAlign.justify,
                    lineBreaker: breaker,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Page ---

class JustificationDemoPage extends StatefulWidget {
  const JustificationDemoPage({super.key});

  @override
  State<JustificationDemoPage> createState() => _JustificationDemoPageState();
}

class _JustificationDemoPageState extends State<JustificationDemoPage> {
  double _colWidth = 300;
  bool _showIndicators = true;
  _Resources? _resources;

  @override
  void initState() {
    super.initState();
    final preset = double.tryParse(
      Platform.environment['GPUTEXT_DEMO_WIDTH'] ?? '',
    );
    if (preset != null) _colWidth = preset.clamp(220.0, 460.0);
  }

  Widget _column(String title, String subtitle, _Metrics metrics, Widget body) {
    String pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
    Color quality(double v) => v < 0.15
        ? const Color(0xFF2E7D32)
        : v < 0.35
        ? const Color(0xFFB26A00)
        : const Color(0xFFC62828);
    return SizedBox(
      width: _colWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 4),
          DefaultTextStyle(
            style: const TextStyle(fontSize: 11.5, color: Colors.black87),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${metrics.lineCount} lines · '
                  '${metrics.riverCount} rivers · dev avg ',
                ),
                GPURichText(
                  text: TextSpan(
                    text: pct(metrics.avgDeviation),
                    style: TextStyle(
                      color: quality(metrics.avgDeviation),
                      fontWeight: FontWeight.w600,
                    ),
                    children: [
                      TextSpan(
                        text: ' max ',
                        style: TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: pct(metrics.maxDeviation),
                        style: TextStyle(
                          color: quality(metrics.maxDeviation / 2),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.black26),
              borderRadius: BorderRadius.circular(4),
            ),
            child: body,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Justification: greedy vs Knuth-Plass')),
      body: ListenableBuilder(
        listenable: GPUText.instance,
        builder: (context, _) {
          final font = GPUText.instance.resolveFont('Lato');
          if (font == null) {
            return const Center(child: Text('Loading fonts…'));
          }
          if (_resources?.font != font) _resources = _Resources(font);
          final res = _resources!;
          final innerWidth = _colWidth - _pad * 2;

          // Each column = one LineBreaker; the widgets break with the same
          // strategy the model ran, so overlays and metrics line up.
          const greedy = LineBreaker.greedy;
          const optimal = KnuthPlassLineBreaker();
          final baseFrame = _buildColumn([
            for (final p in res.base) _layoutWith(greedy, p, innerWidth),
          ], res.spaceWidth);
          final hyphenFrame = _buildColumn([
            for (final p in res.hyphenated) _layoutWith(greedy, p, innerWidth),
          ], res.spaceWidth);
          final optimalFrame = _buildColumn([
            for (final p in res.hyphenated) _layoutWith(optimal, p, innerWidth),
          ], res.spaceWidth);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'The same essay justified three ways. Red heat marks '
                '"rivers" — inter-word gaps stretched past 1.5× the normal '
                'space. Columns 2 and 3 break lines from gputext\'s '
                'prepared segment widths; the Knuth-Plass column re-runs a '
                'total-fit optimization live as you drag.',
                style: TextStyle(fontSize: 13, color: Colors.black87),
              ),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _colWidth,
                      min: 220,
                      max: 460,
                      onChanged: (v) => setState(() => _colWidth = v),
                    ),
                  ),
                  Text('${_colWidth.round()}px'),
                  const SizedBox(width: 16),
                  const Text('rivers', style: TextStyle(fontSize: 12)),
                  Switch(
                    value: _showIndicators,
                    onChanged: (v) => setState(() => _showIndicators = v),
                  ),
                ],
              ),
              SelectionArea(
                child: Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  alignment: WrapAlignment.center,
                  runAlignment: WrapAlignment.center,
                  children: [
                    _column(
                      '1 · GPUText justify',
                      'default greedy breaker, no hyphenation '
                          '(the browser-CSS baseline)',
                      baseFrame.metrics,
                      _GPUTextColumn(
                        frame: baseFrame,
                        width: _colWidth,
                        showIndicators: _showIndicators,
                        spaceWidth: res.spaceWidth,
                        paragraphTexts: res.baseText,
                        breaker: greedy,
                      ),
                    ),
                    _column(
                      '2 · Greedy + hyphenation',
                      'default breaker over soft-hyphenated text',
                      hyphenFrame.metrics,
                      _GPUTextColumn(
                        frame: hyphenFrame,
                        width: _colWidth,
                        showIndicators: _showIndicators,
                        spaceWidth: res.spaceWidth,
                        paragraphTexts: res.hyphenatedText,
                        breaker: greedy,
                      ),
                    ),
                    _column(
                      '3 · Knuth-Plass optimal',
                      'lineBreaker: KnuthPlassLineBreaker() over the same '
                          'hyphenated text',
                      optimalFrame.metrics,
                      _GPUTextColumn(
                        frame: optimalFrame,
                        width: _colWidth,
                        showIndicators: _showIndicators,
                        spaceWidth: res.spaceWidth,
                        paragraphTexts: res.hyphenatedText,
                        breaker: optimal,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
