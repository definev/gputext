// Tier B scenario matrix. Every scenario is one span/widget factory consumed
// by both engine passes — only the leaf widget differs (GPURichText vs
// RichText with identical arguments), so the passes always measure identical
// content, constraints, and per-frame mutation.
//
// Scenario state derives entirely from the driver's frame tick: the bench
// page runs a Ticker, calls onTick, and rebuilds (dynamic scenarios only), so
// harness overhead is identical for both engines.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:gputext/gputext.dart';
import 'package:gputext/gputext.dart'
    as wf
    show KnuthPlassLineBreaker, LineBreaker;

import 'corpus.dart';

enum EngineKind { gputext, richtext }

const benchCjkFamily = 'BenchCJK';
const benchGsfFamily = 'BenchGSF';

class BenchContext {
  BenchContext({
    required this.corpus,
    required this.quick,
    required this.hasCjk,
  });

  final BenchCorpus corpus;
  final bool quick;
  final bool hasCjk;
  final ScrollController scroll = ScrollController();
  final TransformationController transform = TransformationController();

  int get warmupFrames => quick ? 10 : 30;
  int get measureFrames => quick ? 60 : 180;

  void dispose() {
    scroll.dispose();
    transform.dispose();
  }
}

class FrameScenario {
  const FrameScenario({
    required this.id,
    required this.label,
    required this.desc,
    required this.path,
    required this.build,
    this.onTick,
    this.engines = const [EngineKind.gputext, EngineKind.richtext],
    this.dynamicContent = true,
    this.includeMount = false,
    this.needsCjk = false,
    this.knuthPlass = false,
  });

  final String id;
  final String label;
  final String desc;
  final String path; // pure | hybrid | cache-disabled | no-counterpart
  final Widget Function(BenchContext ctx, EngineKind engine, int tick) build;
  final void Function(BenchContext ctx, int tick)? onTick;
  final List<EngineKind> engines;

  /// False → the driver never rebuilds; the ticker only keeps vsync frames
  /// coming (idle-floor and mount+steady scenarios).
  final bool dynamicContent;

  /// True → measurement starts at the mount frame (no warmup window).
  final bool includeMount;

  final bool needsCjk;
  final bool knuthPlass; // gputext pass uses the Knuth–Plass breaker
}

TextStyle benchStyle({
  String family = 'Lato',
  double size = 14,
  Color color = const Color(0xFF000000),
  List<FontVariation>? variations,
}) => TextStyle(
  fontFamily: family,
  fontSize: size,
  color: color,
  fontVariations: variations,
);

/// The one place the engines diverge.
Widget benchText(
  EngineKind engine,
  InlineSpan span, {
  TextAlign align = TextAlign.start,
  bool knuthPlass = false,
  Listenable? scaleHint,
}) => engine == EngineKind.gputext
    ? GPURichText(
        text: span,
        textAlign: align,
        lineBreaker: knuthPlass
            ? const wf.KnuthPlassLineBreaker()
            : wf.LineBreaker.greedy,
        scaleHint: scaleHint,
      )
    : RichText(text: span, textAlign: align);

double _triangle(double t) {
  final f = t - t.floorToDouble();
  return 1 - (1 - 2 * f).abs();
}

Widget _column(List<Widget> children, {double width = 420}) => SizedBox(
  width: width,
  child: SingleChildScrollView(
    // Never scrolled: just guards against vertical overflow crashes.
    physics: const NeverScrollableScrollPhysics(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  ),
);

List<FrameScenario> frameScenarios(BenchContext ctx) {
  final sentences = ctx.corpus.commentTexts(30, unique: true);
  final words = const [
    'alpha',
    'beta',
    'gamma',
    'delta',
    'epsilon',
    'zeta',
    'eta',
    'theta',
  ];

  Widget staticParagraphs(EngineKind e, int count) => _column([
    for (var i = 0; i < count; i++)
      benchText(e, TextSpan(text: sentences[i % 30], style: benchStyle())),
  ]);

  return [
    FrameScenario(
      id: 'frame.static_idle',
      label: '30 static paragraphs, idle vsync',
      desc:
          'Floor/sanity: nothing changes; both sides should build ~0. '
          'GPUText steady-state paint is a cached-image blit — pair with '
          'the dynamic scenarios below for a fair picture.',
      path: 'pure',
      dynamicContent: false,
      build: (ctx, e, tick) => staticParagraphs(e, 30),
    ),
    FrameScenario(
      id: 'frame.repaint_color',
      label: 'per-frame color toggle, 30 paragraphs',
      desc:
          'RenderComparison.paint each frame: gputext re-emits instances '
          'and re-renders its GPU surface; RichText re-records. The honest '
          '"gputext is not just a blit" case.',
      path: 'pure',
      build: (ctx, e, tick) => _column([
        for (var i = 0; i < 30; i++)
          benchText(
            e,
            TextSpan(
              text: sentences[i % 30],
              style: benchStyle(
                color: tick.isEven
                    ? const Color(0xFF000000)
                    : const Color(0xFE000000),
              ),
            ),
          ),
      ]),
    ),
    FrameScenario(
      id: 'frame.text_update',
      label: 'per-frame text change, 12 paragraphs',
      desc:
          'RenderComparison.layout each frame: full flatten+prepare+break '
          'both sides; every prepare-cache lookup misses (unique keys).',
      path: 'pure',
      build: (ctx, e, tick) => _column([
        for (var i = 0; i < 12; i++)
          benchText(
            e,
            TextSpan(
              text: '${sentences[i]} ${words[tick % words.length]} #$tick',
              style: benchStyle(),
            ),
          ),
      ]),
    ),
    FrameScenario(
      id: 'frame.reflow_width',
      label: 'animated wrap width, 20 paragraphs',
      desc:
          'Width 240↔420 px sinusoid: gputext re-breaks from cached '
          'prepares (the prepare/layout split); RichText relays out from '
          'scratch. Resize-heal re-renders are counted in surfaceRenders.',
      path: 'pure',
      build: (ctx, e, tick) {
        final width = 330 + 90 * math.sin(tick * 2 * math.pi / 120);
        return _column([
          for (var i = 0; i < 20; i++)
            benchText(
              e,
              TextSpan(text: sentences[i % 30], style: benchStyle()),
            ),
        ], width: width);
      },
    ),
    FrameScenario(
      id: 'frame.scroll_long',
      label: 'long-document scroll, full Gatsby corpus',
      desc:
          'Constant 24 px/frame with direction reversal: steady-state blit '
          'vs engine repaint, plus viewport-entry cold prepares. This is '
          'gputext\'s best case by construction.',
      path: 'pure',
      onTick: (ctx, tick) {
        if (!ctx.scroll.hasClients) return;
        final max = ctx.scroll.position.maxScrollExtent;
        if (max <= 0) return;
        final span = (tick * 24) % (2 * max);
        ctx.scroll.jumpTo(span <= max ? span : 2 * max - span);
      },
      build: (ctx, e, tick) => SizedBox(
        width: 420,
        height: 620,
        child: ListView.builder(
          controller: ctx.scroll,
          itemCount: ctx.corpus.gatsbyParagraphs.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: benchText(
              e,
              TextSpan(
                text: ctx.corpus.gatsbyParagraphs[i],
                style: benchStyle(),
              ),
            ),
          ),
        ),
      ),
    ),
    FrameScenario(
      id: 'frame.zoom_transform',
      label: 'Transform.scale zoom 1→8→1',
      desc:
          'Exponential zoom sweep, transformAdaptive on: gputext '
          're-renders crisp at each quantized 1.25× step (surfaceRenders ≈ '
          'steps crossed); RichText rasters once and scales (blurry — see '
          'vis.zoom_4x for the quality side).',
      path: 'pure',
      build: (ctx, e, tick) {
        final scale = math
            .pow(8, _triangle(tick / ctx.measureFrames))
            .toDouble();
        return SizedBox(
          width: 420,
          height: 620,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.topLeft,
                // Plain Column, no scroll view: a viewport's repaint boundary
                // between the Transform and the text would swallow ancestor
                // repaints, and transformAdaptive re-renders ride exactly
                // those (scaleHint is the boundary-crossing alternative —
                // covered by frame.zoom_interactive).
                child: SizedBox(
                  width: 400,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < 6; i++)
                        benchText(
                          e,
                          TextSpan(text: sentences[i], style: benchStyle()),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
    FrameScenario(
      id: 'frame.zoom_interactive',
      label: 'InteractiveViewer step zoom ×1.25',
      desc:
          'Programmatic TransformationController sweep, 6-frame dwell per '
          '1.25× step (up to ~6×, back down); gputext pass wires scaleHint '
          'so re-render triggers cross the RepaintBoundary.',
      path: 'pure',
      onTick: (ctx, tick) {
        final step = (tick ~/ 6) % 16;
        final level = step <= 8 ? step : 16 - step;
        final s = math.pow(1.25, level).toDouble();
        ctx.transform.value = Matrix4.diagonal3Values(s, s, 1);
      },
      build: (ctx, e, tick) => SizedBox(
        width: 420,
        height: 620,
        child: InteractiveViewer(
          transformationController: ctx.transform,
          maxScale: 16,
          child: _column([
            for (var i = 0; i < 6; i++)
              benchText(
                e,
                TextSpan(text: sentences[i], style: benchStyle()),
                scaleHint: e == EngineKind.gputext ? ctx.transform : null,
              ),
          ], width: 400),
        ),
      ),
    ),
    FrameScenario(
      id: 'frame.grid_many',
      label: '240 unique-text cells, mount + steady',
      desc:
          'Many-widget overhead: 240 small paragraphs all visible; '
          'measurement includes the mount frame.',
      path: 'pure',
      dynamicContent: false,
      includeMount: true,
      build: (ctx, e, tick) => _grid(e, unique: true),
    ),
    FrameScenario(
      id: 'frame.grid_shared',
      label: '240 identical-text cells, mount + steady',
      desc:
          'Shared prepare-cache effect: identical spans should flatten+'
          'prepare once and hit the cache ~239 times (gputext pass).',
      path: 'pure',
      dynamicContent: false,
      includeMount: true,
      build: (ctx, e, tick) => _grid(e, unique: false),
    ),
    FrameScenario(
      id: 'frame.justify',
      label: 'justified reflow, 12 paragraphs',
      desc:
          'reflow_width driver with TextAlign.justify (greedy breaks both '
          'sides).',
      path: 'pure',
      build: (ctx, e, tick) {
        final width = 330 + 90 * math.sin(tick * 2 * math.pi / 120);
        return _column([
          for (var i = 0; i < 12; i++)
            benchText(
              e,
              TextSpan(text: sentences[i], style: benchStyle()),
              align: TextAlign.justify,
            ),
        ], width: width);
      },
    ),
    FrameScenario(
      id: 'frame.justify_kp',
      label: 'Knuth–Plass justified reflow, 12 paragraphs',
      desc:
          'Same driver with the TeX-style optimal-fit breaker; Flutter has '
          'no counterpart (compare against frame.justify).',
      path: 'no-counterpart',
      engines: const [EngineKind.gputext],
      knuthPlass: true,
      build: (ctx, e, tick) {
        final width = 330 + 90 * math.sin(tick * 2 * math.pi / 120);
        return _column([
          for (var i = 0; i < 12; i++)
            benchText(
              e,
              TextSpan(text: sentences[i], style: benchStyle()),
              align: TextAlign.justify,
              knuthPlass: true,
            ),
        ], width: width);
      },
    ),
    FrameScenario(
      id: 'frame.varfont_anim',
      label: 'variable-font wght animation',
      desc:
          'GoogleSansFlex wght 100↔1000 in 64 quantized steps: each new '
          'coordinate bands fresh outlines into the atlas. All of them stay '
          'live for the whole scenario, so nothing evicts here — see '
          'mem.varfont_growth for the resident cost.',
      path: 'pure',
      build: (ctx, e, tick) {
        final step = (_triangle(tick / ctx.measureFrames) * 63).round();
        final wght = 100 + step * (900 / 63);
        return _column([
          for (var i = 0; i < 3; i++)
            benchText(
              e,
              TextSpan(
                text: sentences[i],
                style: benchStyle(
                  family: benchGsfFamily,
                  size: 22,
                  variations: [FontVariation('wght', wght)],
                ),
              ),
            ),
        ]);
      },
    ),
    FrameScenario(
      id: 'frame.emoji_cjk',
      label: 'mixed emoji/CJK/URL text, per-frame change',
      desc:
          'Hybrid path: emoji clusters and uncovered characters expand '
          'into nested native Text WidgetSpans, which also disables the '
          'prepare cache. Not comparable with pure rows.',
      path: 'hybrid',
      build: (ctx, e, tick) {
        final lines = ctx.corpus.mixedAppLines;
        return _column([
          for (var i = 0; i < math.min(12, lines.length); i++)
            benchText(
              e,
              TextSpan(text: '${lines[i]} #${tick % 100}', style: benchStyle()),
            ),
        ]);
      },
    ),
    FrameScenario(
      id: 'frame.widgetspan_heavy',
      label: '12 paragraphs × 8 WidgetSpans, per-frame change',
      desc:
          'Cache-disabled worst case: inline children force a fresh '
          'flatten+prepare every build (gputext pass).',
      path: 'cache-disabled',
      build: (ctx, e, tick) => _column([
        for (var i = 0; i < 12; i++)
          benchText(
            e,
            TextSpan(
              style: benchStyle(),
              children: [
                for (var w = 0; w < 8; w++) ...[
                  TextSpan(
                    text:
                        ' ${sentences[i].split(' ').skip(w * 3).take(3).join(' ')}'
                        '${w == 0 ? ' #$tick' : ''}',
                  ),
                  const WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: ColoredBox(color: Color(0xFF888888)),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ]),
    ),
  ];
}

Widget _grid(EngineKind e, {required bool unique}) => SizedBox(
  width: 400,
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var row = 0; row < 24; row++)
        Row(
          children: [
            for (var col = 0; col < 10; col++)
              SizedBox(
                width: 40,
                height: 22,
                child: benchText(
                  e,
                  TextSpan(
                    text: unique ? 'w${row * 10 + col}' : 'lorem',
                    style: benchStyle(size: 10),
                  ),
                ),
              ),
          ],
        ),
    ],
  ),
);
