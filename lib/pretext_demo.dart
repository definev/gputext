// Demo for the pretext-ported text engine (prepare/layout split + the
// segment-model line breaker): a live-resizable paragraph next to stock
// RichText — Flutter's own engine is the wrapping oracle, the two panes
// should break identically — feature rows for the new break semantics, and
// a micro-benchmark card showing why prepare-once/layout-per-width matters.
//
// Dev hooks (demo only): GPUTEXT_DEMO=pretext opens this page directly;
// GPUTEXT_DEMO_WIDTH=<px> presets the wrap width for screenshots.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'src/paragraph.dart' as wf;
import 'gputext.dart';

const _ink = Color(0xFF0C0F1C);
const _accentRed = Color(0xFF8C1F14);
const _accentBlue = Color(0xFF14508C);
const _paper = Color(0xFFE9E3D5);

// One paragraph exercising every ported rule at once.
TextSpan _showcaseSpan() => const TextSpan(
  style: TextStyle(fontFamily: 'Lato', fontSize: 15, color: _ink, height: 1.35),
  children: [
    TextSpan(text: 'GPUText now breaks lines with a pretext-style engine. '),
    TextSpan(text: 'Glued units like 12\u00A0kg or page\u00A042 never split; '),
    TextSpan(
        text: 'soft\u00ADhy\u00ADphen\u00ADat\u00ADed words show a hyphen '
            'only when the break is chosen; '),
    TextSpan(text: 'URLs such as '),
    TextSpan(
      text: 'https://windfoil.dev/docs/text?engine=pretext',
      style: TextStyle(color: _accentBlue),
    ),
    TextSpan(
        text: ' wrap as path+query units, punctuation hugs its word, and '),
    TextSpan(text: 'Supercalifragilisticexpialidocious', style: TextStyle(color: _accentRed)),
    TextSpan(text: ' fills lines grapheme by grapheme, Flutter-style.'),
  ],
);

class _FeatureRow {
  const _FeatureRow(this.title, this.blurb, this.span, this.width);

  final String title;
  final String blurb;
  final TextSpan span;
  final double width;
}

const _featureStyle =
    TextStyle(fontFamily: 'Lato', fontSize: 14, color: _ink, height: 1.3);

final _features = <_FeatureRow>[
  _FeatureRow(
    'Soft hyphens',
    'U+00AD stays invisible until the break is chosen, then gputext draws '
        'a "-" when it fits. Stock Flutter breaks there too but never draws '
        'the hyphen.',
    const TextSpan(
      style: _featureStyle,
      text: 'A re\u00ADmark\u00ADab\u00ADly hy\u00ADphen\u00ADat\u00ADed '
          'ex\u00ADam\u00ADple sentence.',
    ),
    120,
  ),
  _FeatureRow(
    'No-break glue',
    'NBSP welds its neighbors into one unbreakable unit.',
    const TextSpan(
      style: _featureStyle,
      text: 'We shipped six boxes of 12\u00A0kg each to the harbor.',
    ),
    130,
  ),
  _FeatureRow(
    'URL break units',
    'Path wraps as one unit up to the "?", the query as another. Stock '
        'Flutter fragments URLs at slashes instead.',
    const TextSpan(
      style: _featureStyle,
      text: 'See https://windfoil.dev/docs/text?engine=pretext for details.',
    ),
    240,
  ),
  _FeatureRow(
    'Grapheme fill',
    'Words that can never fit a line fill the remainder, Flutter-style.',
    const TextSpan(
      style: _featureStyle,
      text: 'It wraps Supercalifragilisticexpialidocious wherever it must.',
    ),
    140,
  ),
  _FeatureRow(
    'Mid-word styling',
    'A style change inside a word is not a break opportunity.',
    TextSpan(
      style: _featureStyle,
      children: const [
        TextSpan(text: 'Compare hyphen'),
        TextSpan(text: 'ation', style: TextStyle(color: _accentRed)),
        TextSpan(text: ' and punc'),
        TextSpan(text: 'tuation', style: TextStyle(color: _accentBlue)),
        TextSpan(text: ' across widths.'),
      ],
    ),
    120,
  ),
  _FeatureRow(
    'Zero-width break',
    'ZWSP adds an invisible break opportunity inside compounds.',
    const TextSpan(
      style: _featureStyle,
      text: 'Long compounds like Donau\u200Bdampf\u200Bschiff\u200Bfahrt '
          'wrap at seams.',
    ),
    130,
  ),
];

class PretextDemoPage extends StatefulWidget {
  const PretextDemoPage({super.key});

  @override
  State<PretextDemoPage> createState() => _PretextDemoPageState();
}

class _PretextDemoPageState extends State<PretextDemoPage> {
  double _width = 340;
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    final preset = Platform.environment['GPUTEXT_DEMO_WIDTH'];
    if (preset != null) {
      final w = double.tryParse(preset);
      if (w != null) _width = w.clamp(90.0, 620.0);
    }
    // Screenshot hook, like GPUTEXT_DEMO_ZOOM in the widget demo.
    final scrollPreset =
        double.tryParse(Platform.environment['GPUTEXT_DEMO_SCROLL'] ?? '');
    _scroll = ScrollController(initialScrollOffset: scrollPreset ?? 0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _pane(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _ink.withValues(alpha: 0.5))),
          const SizedBox(height: 4),
          Container(
            width: _width,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _paper,
              border: Border.all(color: _ink.withValues(alpha: 0.2)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: child,
          ),
        ],
      );

  Widget _featureCard(_FeatureRow f) => Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(f.title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 2),
              Text(f.blurb,
                  style: TextStyle(
                      fontSize: 12, color: _ink.withValues(alpha: 0.6))),
              const SizedBox(height: 10),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  _fixedPane('gputext', f.width,
                      GPURichText(text: f.span)),
                  _fixedPane('stock RichText', f.width, RichText(text: f.span)),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _fixedPane(String label, double width, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 10, color: _ink.withValues(alpha: 0.45))),
          const SizedBox(height: 3),
          Container(
            width: width,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _paper,
              border: Border.all(color: _ink.withValues(alpha: 0.2)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: child,
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pretext text engine')),
      body: ListenableBuilder(
        listenable: GPUText.instance,
        builder: (context, _) => ListView(
          controller: _scroll,
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Drag the width: both panes re-wrap live. GPUText prepares '
              'the paragraph once and reruns only the pure-arithmetic line '
              'walker per width; the stock pane is Flutter\'s engine — the '
              'wrapping oracle the port is tested against. Breaks match '
              'except where gputext deliberately upgrades them: chosen '
              'soft hyphens draw a real "-", and URLs wrap as path+query '
              'units instead of fragmenting.',
              style: TextStyle(fontSize: 13, color: _ink.withValues(alpha: 0.7)),
            ),
            Slider(
              value: _width,
              min: 90,
              max: 620,
              onChanged: (v) => setState(() => _width = v),
            ),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                _pane('gputext · ${_width.round()}px',
                    GPURichText(text: _showcaseSpan())),
                _pane('stock RichText', RichText(text: _showcaseSpan())),
              ],
            ),
            const SizedBox(height: 12),
            _PerfCard(width: _width),
            const SizedBox(height: 8),
            for (final f in _features) _featureCard(f),
          ],
        ),
      ),
    );
  }
}

/// Micro-benchmark: one-shot breakLines (analyze+measure+walk every call,
/// the pre-port cost shape) vs layoutPreparedLines on a cached
/// PreparedParagraph (the new resize hot path).
class _PerfCard extends StatelessWidget {
  const _PerfCard({required this.width});

  final double width;

  static final String _perfText = List.filled(
    32,
    'The quick brown zebra jumps over the lazy dog while 12\u00A0kg of '
    'well-known state-of-the-art cargo ships to https://windfoil.dev/q?x=1 '
    'and back again without delay. ',
  ).join();

  static List<wf.TextRun>? _runs;
  static wf.PreparedParagraph? _prepared;
  static double _prepareUs = 0;

  @override
  Widget build(BuildContext context) {
    final font = GPUText.instance.resolveFont('Lato');
    if (font == null) return const SizedBox.shrink();

    if (_prepared == null) {
      final sw = Stopwatch()..start();
      _runs = [
        wf.TextRun(
            text: _perfText,
            font: font,
            fontSizePx: 15,
            color: const [0, 0, 0, 1]),
      ];
      _prepared = wf.prepareParagraph(_runs!);
      _prepareUs = sw.elapsedMicroseconds.toDouble();
    }
    final prepared = _prepared!;
    final style = wf.ParagraphStyle(maxWidth: width);

    const layoutIters = 40;
    final swLayout = Stopwatch()..start();
    late wf.ParagraphLines lines;
    for (var i = 0; i < layoutIters; i++) {
      lines = wf.layoutPreparedLines(prepared, width, style);
    }
    final layoutUs = swLayout.elapsedMicroseconds / layoutIters;

    const oneShotIters = 5;
    final swOneShot = Stopwatch()..start();
    for (var i = 0; i < oneShotIters; i++) {
      wf.breakLines(_runs!, width, style);
    }
    final oneShotUs = swOneShot.elapsedMicroseconds / oneShotIters;

    final speedup = layoutUs > 0 ? oneShotUs / layoutUs : 0;
    return Card(
      color: _ink,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: DefaultTextStyle(
          style: const TextStyle(
              fontSize: 12.5, color: _paper, fontFamily: 'Lato'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('prepare / layout split · 1000-word paragraph',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('first prepare (cold, fills the segment-metrics cache): '
                  '${_prepareUs.toStringAsFixed(0)} µs'),
              Text('layout at ${width.round()}px '
                  '(${lines.lines.length} lines): '
                  '${layoutUs.toStringAsFixed(1)} µs'),
              Text('one-shot re-prepare + layout (pre-port shape): '
                  '${oneShotUs.toStringAsFixed(1)} µs '
                  '→ ${speedup.toStringAsFixed(1)}× saved per resize frame'),
            ],
          ),
        ),
      ),
    );
  }
}
