// Animated Google Sans Flex showcase — per-character morph + axis lerp (no
// opacity crossfade). Each glyph is its own slot: text snaps at keyframe
// boundaries while wdth/wght/slnt/ROND travel with per-segment curves
// (wind-up → snap-with-bounce → soft settle). Characters stagger so the
// composition ripples; endpoint holds let each pose read before the next
// morph. Line 2's wild!→Text! hides every glyph swap at a shared narrow-light
// "pinch" pose and rides ROND from fully round (wild) to sharp (TEXT).
//
// Both lines are locked to a shared target width [_lineWidth] at every frame:
// pose axes were solved so endpoints already match, and a per-line size scale
// corrects mid-morph / stagger drift.
//
// Disables coarse [GPUFont.variationQuantizationSteps] on this page (uses 256)
// and raises the atlas budget so axis animation stays smooth at display size
// without mid-morph eviction hitching.
//
// Dev hook: GPUTEXT_DEMO=gsf

import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'package:gputext/gputext.dart';

const _fontFamily = 'Google Sans Flex';
const _fontAsset =
    'assets/Google_Sans_Flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf';

// Material 3 dark tonal surface + tertiary accent.
const _bg = Color(0xFF141218);
const _ink = Color(0xFFE6E1E5);
const _accent = Color(0xFFEFB8C8);

/// Half-cycle length; ping-pong keeps the loop continuous.
const _cycle = Duration(milliseconds: 2800);

/// Fraction of the timeline reserved for character stagger (rest = morph).
const _staggerSpread = 0.28;

/// Hold each pose before/after the morph so the lockup can be read.
const _endpointHold = 0.08;

/// Shared optical size used when solving pose advances.
const _opticalSize = 120.0;

/// Fixed line box: strut locks ascent/descent so width-scale and axis morph
/// can't bounce the baseline between frames.
const _lineStrut = StrutStyle(
  fontFamily: _fontFamily,
  fontSize: _opticalSize,
  height: 1.0,
  leading: 0,
  forceStrutHeight: true,
);

/// Target line width in px, anchored on `gpu`@62 + `text!`@120. Every pose
/// below was solved so both lines equal this at the endpoints; [_composedSpan]
/// re-scales mid-morph so they stay equal under stagger.
const _lineWidth = 514.49;

class _FlexStyle {
  const _FlexStyle({
    required this.size,
    required this.wdth,
    required this.wght,
    this.slnt = 0,
    this.rond = 0,
    this.color = _ink,
  });

  final double size;
  final double wdth;
  final double wght;
  final double slnt;
  final double rond;
  final Color color;

  _FlexStyle scaled(double factor) => _FlexStyle(
    size: size * factor,
    wdth: wdth,
    wght: wght,
    slnt: slnt,
    rond: rond,
    color: color,
  );

  static _FlexStyle lerp(_FlexStyle a, _FlexStyle b, double t) => _FlexStyle(
    size: lerpDouble(a.size, b.size, t)!,
    wdth: lerpDouble(a.wdth, b.wdth, t)!,
    wght: lerpDouble(a.wght, b.wght, t)!,
    slnt: lerpDouble(a.slnt, b.slnt, t)!,
    rond: lerpDouble(a.rond, b.rond, t)!,
    color: Color.lerp(a.color, b.color, t)!,
  );

  TextStyle toTextStyle() => TextStyle(
    fontFamily: _fontFamily,
    fontSize: size,
    color: color,
    height: 1.0,
    fontVariations: [
      FontVariation('wdth', wdth),
      FontVariation('wght', wght),
      FontVariation('slnt', slnt),
      FontVariation('ROND', rond),
    ],
  );
}

/// One animatable glyph: text snaps at each keyframe; axes lerp between them.
///
/// Four keyframes → three segments, each with its own curve:
///   0 wind-up   — ease-in-out, builds energy toward the snap
///   1 snap      — ease-out-back, overshoots into the new glyph
///   2 settle    — soft ease-out (no overshoot past the end pose)
///
/// [weights] skews how much of the slot's timeline each segment occupies
/// (default: equal shares). flex! uses [_flexWeights] to shorten its wind-up.
class _MorphSlot {
  const _MorphSlot(this.frames, {this.weights});

  final List<({String text, _FlexStyle style})> frames;
  final List<double>? weights;

  /// Segment index + raw progress within it for a clamped timeline position.
  (int, double) _segmentAt(double clamped, int n) {
    final w = weights;
    if (w == null) {
      final pos = clamped * n;
      final i = pos.floor().clamp(0, n - 1);
      return (i, (pos - i).clamp(0.0, 1.0));
    }
    assert(w.length == n);
    final total = w.reduce((a, b) => a + b);
    var start = 0.0;
    for (var k = 0; k < n - 1; k++) {
      final span = w[k] / total;
      if (clamped < start + span) {
        return (k, ((clamped - start) / span).clamp(0.0, 1.0));
      }
      start += span;
    }
    final span = w[n - 1] / total;
    return (n - 1, ((clamped - start) / span).clamp(0.0, 1.0));
  }

  ({String text, _FlexStyle style}) at(double t) {
    final n = frames.length - 1;
    if (n <= 0) return frames.first;
    final clamped = t.clamp(0.0, 1.0);
    if (clamped <= 0) return frames.first;

    final (i, raw) = _segmentAt(clamped, n);
    final local = _segmentCurve(i, n).transform(raw);

    final from = frames[i];
    final to = frames[i + 1];
    // Snap text when the *eased* style reaches the destination — not when
    // raw hits 1. With ease-out-back, style overshoots (local > 1) while raw
    // is still < 1; keeping the old glyph there made x/t look like they
    // glitched at the end of the snap.
    final showTo = local >= 1.0 || raw >= 1.0;
    return (
      text: showTo ? to.text : from.text,
      style: _FlexStyle.lerp(from.style, to.style, local),
    );
  }

  /// Pick easing by segment role. Final settle stays in [0, 1].
  static Curve _segmentCurve(int segment, int lastIndex) {
    if (segment >= lastIndex - 1) return _settleCurve;
    if (segment == 0) return _windUpCurve;
    return _snapCurve;
  }
}

/// Wind-up into the snap — accelerate then brake (on-screen morph).
const _windUpCurve = Cubic(0.45, 0.05, 0.55, 0.95);

/// Snap into the new glyph — fast start, mild overshoot.
const _snapCurve = _MildBackCurve(1.22);

/// Soft land on the end pose — no overshoot (avoids the x/t end glitch).
const _settleCurve = Cubic(0.16, 1, 0.3, 1);

/// Overall morph window — strong ease-in-out so the cycle isn't linear-dull.
const _timelineCurve = Cubic(0.65, 0, 0.35, 1);

/// flex!'s segment shares: its wind-up travel is small, so at equal thirds it
/// dwelt near-motionless before the snap. Short wind-up launches it at once;
/// the pinch-collapse and the bloom get the reclaimed time.
const _flexWeights = [0.18, 0.34, 0.48];

/// Ease-out with a small overshoot.
class _MildBackCurve extends Curve {
  const _MildBackCurve([this.overshoot = 1.22]);

  final double overshoot;

  @override
  double transformInternal(double t) {
    final s = overshoot;
    final t1 = t - 1.0;
    return t1 * t1 * ((s + 1) * t1 + s) + 1.0;
  }
}

/// Hold at endpoints; ease the morph window so energy builds and releases.
double _timelineT(double raw) {
  final t = raw.clamp(0.0, 1.0);
  if (t <= _endpointHold) return 0;
  if (t >= 1 - _endpointHold) return 1;
  final local = (t - _endpointHold) / (1 - 2 * _endpointHold);
  return _timelineCurve.transform(local);
}

/// Stagger across the shaped timeline.
double _charT(double t, int index, int count) {
  final shaped = _timelineT(t);
  if (shaped <= 0) return 0;
  if (shaped >= 1) return 1;
  if (count <= 1) return shaped;
  final delay = (index / (count - 1)) * _staggerSpread;
  final span = 1.0 - _staggerSpread;
  return ((shaped - delay) / span).clamp(0.0, 1.0);
}

/// Letter pairs / brand chunks share a stagger beat so neighbors don't desync.
int _staggerIndex(int i) => switch (i) {
  1 => 0, // Aa
  4 => 3, // Bb
  7 => 6, // Cc
  10 => 9, // gpu
  11 => 9,
  // Text! ripples in pairs (Te · xt · !): every swap now hides at the shared
  // pinch pose, so pairs can desync without exposing the old x/t glitch, and
  // pairing keeps neighbors from tearing mid-swap.
  13 => 12,
  15 => 14,
  _ => i,
};

// --- Poses -----------------------------------------------------------------
//
//   Go flex!          Aa Bb Cc
//   go wild!    →     gputext!
//
// Both lines are 8↔8 with the same contrast recipe: lead condensed/light,
// punch expanded/black (+slant on line 2). Advances solved so both lines =
// [_lineWidth] at the endpoint lockups (size [_opticalSize]); mid-morph the
// per-frame width lock in [_composedSpan] absorbs any drift.
//
// Both lines share the pinch recipe: the wind-up exaggerates each glyph's
// own character, then every glyph collapses to a shared pinch pose — narrow
// and light, where the letterform is most anonymous — the text swap hides
// there, and the word blooms out into its lockup. The lines keep distinct
// personalities: line 1 stays upright and only pulses ROND mid-flight (the
// "flex"), line 2 leans in (slnt) and rides ROND for meaning — wild! rests
// fully round, Text! lands sharp.

const _nl = _FlexStyle(size: _opticalSize, wdth: 100, wght: 400);

// Line 1 lead: "Go " condensed light at rest; wind-up inflates it (soft ROND
// pulse included) so the collapse into the pinch has travel.
const _go0 = _FlexStyle(size: _opticalSize, wdth: 58, wght: 280);
const _go1 = _FlexStyle(size: _opticalSize, wdth: 100, wght: 500, rond: 60);

// Line 1 punch: "flex!" — expanded black at rest; the wind-up flexes into
// the corner of the design space (max wdth/wght, fully round) so the snap
// into the pinch releases real energy instead of the old gentle deflate.
const _flex0 = _FlexStyle(
  size: _opticalSize,
  wdth: 144.84,
  wght: 980,
  color: _accent,
);
const _flex1 = _FlexStyle(
  size: _opticalSize,
  wdth: 151,
  wght: 1000,
  rond: 100,
  color: _accent,
);

// Line 1 arrival pinch — same anonymous narrow-light form as line 2's but
// upright (the lean is line 2's signature). Ink and accent variants because
// specimen pairs land in different colors.
const _pinch1 = _FlexStyle(size: _opticalSize, wdth: 62, wght: 160, rond: 30);
const _pinch1a = _FlexStyle(
  size: _opticalSize,
  wdth: 62,
  wght: 160,
  rond: 30,
  color: _accent,
);

// Specimen lockup — Aa wide-light · Bb condensed-black · Cc narrow-mid;
// spaces refill so the line settles back to [_lineWidth].
const _aa1 = _FlexStyle(size: _opticalSize, wdth: 148, wght: 180);
const _bb1 = _FlexStyle(
  size: _opticalSize,
  wdth: 78,
  wght: 900,
  color: _accent,
);
const _cc1 = _FlexStyle(size: _opticalSize, wdth: 42, wght: 500);
const _sp1 = _FlexStyle(size: _opticalSize, wdth: 76.55, wght: 400);

// Line 2 lead: "go " slanted condensed → opens a little pre-snap. Fully
// round like the punch so the whole "go wild!" line reads loose; "gpu"
// arrives sharp (ROND 0 default).
const _gol0 = _FlexStyle(
  size: _opticalSize,
  wdth: 70,
  wght: 240,
  slnt: -10,
  rond: 100,
);
const _gol1 = _FlexStyle(
  size: _opticalSize,
  wdth: 82,
  wght: 260,
  slnt: -6,
  rond: 100,
);

// Line 2 punch: "wild!" — per-glyph rhythm (W bold+wide · i thin · l mid ·
// D/! bold), fully round. Wind-up exaggerates each glyph's own character
// (bolds inflate toward max, the thin i gets thinner) and leans in.
const _w0 = _FlexStyle(
  size: _opticalSize,
  wdth: 147.52,
  wght: 960,
  rond: 100,
  color: _accent,
);
const _w1 = _FlexStyle(
  size: _opticalSize,
  wdth: 151,
  wght: 1000,
  slnt: -4,
  rond: 100,
  color: _accent,
);
const _i0 = _FlexStyle(
  size: _opticalSize,
  wdth: 124.52,
  wght: 80,
  rond: 100,
  color: _accent,
);
const _i1 = _FlexStyle(
  size: _opticalSize,
  wdth: 110,
  wght: 60,
  slnt: -4,
  rond: 100,
  color: _accent,
);
const _l0 = _FlexStyle(
  size: _opticalSize,
  wdth: 139.52,
  wght: 400,
  rond: 100,
  color: _accent,
);
const _l1 = _FlexStyle(
  size: _opticalSize,
  wdth: 145,
  wght: 520,
  slnt: -4,
  rond: 100,
  color: _accent,
);
const _d0 = _FlexStyle(
  size: _opticalSize,
  wdth: 139.52,
  wght: 920,
  rond: 100,
  color: _accent,
);
const _d1 = _FlexStyle(
  size: _opticalSize,
  wdth: 145,
  wght: 980,
  slnt: -4,
  rond: 100,
  color: _accent,
);
const _bang0 = _FlexStyle(
  size: _opticalSize,
  wdth: 139.52,
  wght: 960,
  rond: 100,
  color: _accent,
);
const _bang1 = _FlexStyle(
  size: _opticalSize,
  wdth: 145,
  wght: 1000,
  slnt: -4,
  rond: 100,
  color: _accent,
);

// Brand: "gpu" arrives WIDE so Text! can arrive CONDENSED. Settle flips
// back: gpu condenses, Text! expands to uniform black.
const _gpu0 = _FlexStyle(size: _opticalSize, wdth: 110, wght: 280);
const _gpu1 = _FlexStyle(size: _opticalSize, wdth: 120, wght: 340);

// Every Text! glyph arrives at this one pinch — narrow, light, leaning,
// half-sharpened — so the text swap hides where the letterform is most
// anonymous. One shared pose also means one shared variant instance during
// the morph's hottest frames. The settle then blooms the word upright into
// the wide-black lockup below (whose advances anchor [_lineWidth]).
const _pinch2 = _FlexStyle(
  size: _opticalSize,
  wdth: 62,
  wght: 160,
  slnt: -8,
  rond: 40,
  color: _accent,
);
const _tLead1 = _FlexStyle(
  size: _opticalSize,
  wdth: 120.69,
  wght: 920,
  color: _accent,
);
const _e1 = _FlexStyle(
  size: _opticalSize,
  wdth: 120.69,
  wght: 900,
  color: _accent,
);
const _x1 = _FlexStyle(
  size: _opticalSize,
  wdth: 120.69,
  wght: 900,
  color: _accent,
);
const _t1 = _FlexStyle(
  size: _opticalSize,
  wdth: 120.69,
  wght: 920,
  color: _accent,
);
const _textBang1 = _FlexStyle(
  size: _opticalSize,
  wdth: 120.69,
  wght: 960,
  color: _accent,
);

_MorphSlot _glyph(
  String from,
  _FlexStyle from0,
  _FlexStyle from1,
  String to,
  _FlexStyle to0,
  _FlexStyle to1, {
  List<double>? weights,
}) => _MorphSlot([
  (text: from, style: from0),
  (text: from, style: from1),
  (text: to, style: to0),
  (text: to, style: to1),
], weights: weights);

/// Line 1 slots (0..7), newline (8), line 2 slots (9..16).
final _slots = <_MorphSlot>[
  // "Go flex!" → "Aa Bb Cc"
  _glyph('G', _go0, _go1, 'A', _pinch1, _aa1),
  _glyph('o', _go0, _go1, 'a', _pinch1, _aa1),
  _glyph(' ', _go0, _go1, ' ', _pinch1, _sp1),
  _glyph('f', _flex0, _flex1, 'B', _pinch1a, _bb1, weights: _flexWeights),
  _glyph('l', _flex0, _flex1, 'b', _pinch1a, _bb1, weights: _flexWeights),
  _glyph('e', _flex0, _flex1, ' ', _pinch1, _sp1, weights: _flexWeights),
  _glyph('x', _flex0, _flex1, 'C', _pinch1, _cc1, weights: _flexWeights),
  _glyph('!', _flex0, _flex1, 'c', _pinch1, _cc1, weights: _flexWeights),
  _glyph('\n', _nl, _nl, '\n', _nl, _nl),

  // "go wild!" → "gputext!"
  _glyph('g', _gol0, _gol1, 'g', _gpu0, _gpu1),
  _glyph('o', _gol0, _gol1, 'p', _gpu0, _gpu1),
  _glyph(' ', _gol0, _gol1, 'u', _gpu0, _gpu1),
  _glyph('w', _w0, _w1, 'T', _pinch2, _tLead1),
  _glyph('i', _i0, _i1, 'e', _pinch2, _e1),
  _glyph('l', _l0, _l1, 'x', _pinch2, _x1),
  _glyph('d', _d0, _d1, 't', _pinch2, _t1),
  _glyph('!', _bang0, _bang1, '!', _pinch2, _textBang1),
];

const _line1 = (0, 8); // exclusive end
const _line2 = (9, 17);

double _lineAdvance(
  GPUFont base,
  List<({String text, _FlexStyle style})> frames,
  int start,
  int end,
) {
  var w = 0.0;
  String? prev;
  for (var i = start; i < end; i++) {
    final f = frames[i];
    if (f.text.isEmpty || f.text == '\n') continue;
    final font = base.variant({
      'wdth': f.style.wdth,
      'wght': f.style.wght,
      'slnt': f.style.slnt,
      'ROND': f.style.rond,
    });
    final scale = f.style.size / font.unitsPerEm;
    for (final rune in f.text.runes) {
      final ch = String.fromCharCode(rune);
      if (prev != null) w += font.kerningOf(prev, ch) * scale;
      w += font.advanceOf(ch) * scale;
      prev = ch;
    }
  }
  return w;
}

TextSpan _composedSpan(GPUFont font, double t) {
  final n = _slots.length;
  final frames = <({String text, _FlexStyle style})>[
    for (var i = 0; i < n; i++) _slots[i].at(_charT(t, _staggerIndex(i), n)),
  ];

  // Lock each line to [_lineWidth] so stagger / mid-lerp can't desync them.
  final w1 = _lineAdvance(font, frames, _line1.$1, _line1.$2);
  final w2 = _lineAdvance(font, frames, _line2.$1, _line2.$2);
  final s1 = w1 > 0.5 ? _lineWidth / w1 : 1.0;
  final s2 = w2 > 0.5 ? _lineWidth / w2 : 1.0;

  return TextSpan(
    children: [
      for (var i = 0; i < n; i++)
        TextSpan(
          text: frames[i].text,
          style: frames[i].style
              .scaled(i < _line1.$2 ? s1 : (i >= _line2.$1 ? s2 : 1.0))
              .toTextStyle(),
        ),
    ],
  );
}

class GoogleSansFlexDemoPage extends StatefulWidget {
  const GoogleSansFlexDemoPage({super.key});

  @override
  State<GoogleSansFlexDemoPage> createState() => _GoogleSansFlexDemoPageState();
}

class _GoogleSansFlexDemoPageState extends State<GoogleSansFlexDemoPage>
    with SingleTickerProviderStateMixin {
  var _loading = true;
  String? _error;
  GPUFont? _font;
  late final AnimationController _controller;
  var _playing = false;
  var _goingForward = true;

  /// Restored on dispose so other demos keep the engine defaults.
  int? _prevQuantizationSteps;
  int? _prevAtlasBudget;

  @override
  void initState() {
    super.initState();
    // Fine grid (256) keeps display morphs smooth without the unbounded atlas
    // growth of `null` — that was minting a new instance every frame and
    // triggering mid-settle eviction hitching on x/t/!. Budget sized for four
    // animated axes (ROND joined wdth/wght/slnt), which mints more distinct
    // outlines per cycle than the original three.
    _prevQuantizationSteps = GPUFont.variationQuantizationSteps;
    _prevAtlasBudget = GPUText.instance.atlasCurveFloatBudget;
    GPUFont.variationQuantizationSteps = 256;
    GPUText.instance.atlasCurveFloatBudget = 4 * 1024 * 1024;
    // Linear controller — expressive hold + ease + stagger applied in _charT.
    _controller = AnimationController(vsync: this, duration: _cycle)
      ..addStatusListener(_onStatus);
    _startLoop();
    _bootstrap();
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    GPUFont.variationQuantizationSteps = _prevQuantizationSteps;
    GPUText.instance.atlasCurveFloatBudget = _prevAtlasBudget;
    _controller.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (!_playing) return;
    if (status == AnimationStatus.completed) {
      _goingForward = false;
      _controller.reverse();
    } else if (status == AnimationStatus.dismissed) {
      _goingForward = true;
      _controller.forward();
    }
  }

  void _startLoop() {
    _playing = true;
    if (_goingForward) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _togglePlay() {
    setState(() {
      if (_playing) {
        _playing = false;
        // Capture direction before stop so resume continues the same way.
        _goingForward = _controller.status != AnimationStatus.reverse;
        _controller.stop();
      } else {
        _startLoop();
      }
    });
  }

  Future<void> _bootstrap() async {
    try {
      final font = await GPUText.instance.loadFontAsset(
        _fontFamily,
        _fontAsset,
      );
      if (!mounted) return;
      setState(() {
        _font = font;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: _bg,
        body: Center(child: CircularProgressIndicator(color: _accent)),
      );
    }
    if (_error != null || _font == null) {
      return Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Text(
            _error ?? 'Font missing',
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }

    final font = _font!;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: ListenableBuilder(
                    listenable: GPUText.instance,
                    builder: (context, _) {
                      if (reduceMotion) {
                        return GPURichText(
                          text: _composedSpan(font, 0),
                          strutStyle: _lineStrut,
                        );
                      }
                      return AnimatedBuilder(
                        animation: _controller,
                        builder: (context, _) => GPURichText(
                          text: _composedSpan(font, _controller.value),
                          strutStyle: _lineStrut,
                          textAlign: TextAlign.justify,
                          lineBreaker: const KnuthPlassLineBreaker(),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            if (!reduceMotion)
              Positioned(
                left: 0,
                right: 0,
                bottom: 70,
                child: Center(
                  child: _PlayPauseButton(
                    playing: _playing,
                    onPressed: _togglePlay,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF2B2930),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: _accent,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                playing ? 'Pause' : 'Play',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
