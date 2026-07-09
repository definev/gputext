// Animated Google Sans Flex showcase — keyframed text + axis lerp (no opacity
// crossfade). Each segment holds one string while wdth/wght/slnt morph toward
// the next pose; at the segment boundary the glyphs snap (Oh,→Aa, hi!→Bb, …).
//
// Dev hook: GPUTEXT_DEMO=gsf

import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'package:gputext/gputext.dart';

const _fontFamily = 'Google Sans Flex';
const _fontAsset =
    'assets/Google_Sans_Flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf';

const _bg = Color(0xFF1A1A1A);
const _inkCream = Color(0xFFF5F0E6);
const _inkPink = Color(0xFFF8B4FF);

const _cycle = Duration(seconds: 6);

class _FlexStyle {
  const _FlexStyle({
    required this.size,
    required this.wdth,
    required this.wght,
    this.slnt = 0,
    this.color = _inkCream,
  });

  final double size;
  final double wdth;
  final double wght;
  final double slnt;
  final Color color;

  static _FlexStyle lerp(_FlexStyle a, _FlexStyle b, double t) => _FlexStyle(
    size: lerpDouble(a.size, b.size, t)!,
    wdth: lerpDouble(a.wdth, b.wdth, t)!,
    wght: lerpDouble(a.wght, b.wght, t)!,
    slnt: lerpDouble(a.slnt, b.slnt, t)!,
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
    ],
  );
}

/// One animatable slot: text snaps at each keyframe; axes lerp between them.
///
/// Example (a→d): frames `a`, `b`, `c`, `d` — segment 0 shows "a" while style
/// morphs toward `b`; at the boundary text snaps to "b", and so on.
class _MorphSlot {
  const _MorphSlot(this.frames);

  final List<({String text, _FlexStyle style})> frames;

  ({String text, _FlexStyle style}) at(double t) {
    final n = frames.length - 1;
    if (n <= 0) return frames.first;

    final pos = (t * n).clamp(0.0, n.toDouble());
    final i = pos.floor().clamp(0, n - 1);
    final local = pos - i;
    final from = frames[i];
    final to = frames[i + 1];
    return (
      text: from.text,
      style: _FlexStyle.lerp(from.style, to.style, local),
    );
  }
}

TextSpan _slotSpan(_MorphSlot slot, double t) {
  final frame = slot.at(t);
  return TextSpan(text: frame.text, style: frame.style.toTextStyle());
}

// Greeting ↔ specimen cycle. Each slot walks the same four keyframe indices so
// text and axes stay in sync across the composition.
const _slotOh = _MorphSlot([
  (text: 'Oh, ', style: _FlexStyle(size: 120, wdth: 72, wght: 480)),
  (
    text: 'Oh, ',
    style: _FlexStyle(size: 108, wdth: 128, wght: 220),
  ),
  (text: 'Aa', style: _FlexStyle(size: 108, wdth: 128, wght: 220)),
  (text: 'Aa', style: _FlexStyle(size: 120, wdth: 136, wght: 200)),
]);

const _slotHi = _MorphSlot([
  (
    text: 'hi!',
    style: _FlexStyle(size: 168, wdth: 142, wght: 960, color: _inkPink),
  ),
  (
    text: 'hi!',
    style: _FlexStyle(size: 120, wdth: 88, wght: 820, color: _inkPink),
  ),
  (
    text: 'Bb',
    style: _FlexStyle(size: 120, wdth: 88, wght: 820, color: _inkPink),
  ),
  (
    text: 'Bb',
    style: _FlexStyle(size: 120, wdth: 86, wght: 860, color: _inkPink),
  ),
]);

const _slotIm = _MorphSlot([
  (
    text: " I'm\n",
    style: _FlexStyle(size: 118, wdth: 72, wght: 210, slnt: -10),
  ),
  (
    text: " I'm\n",
    style: _FlexStyle(size: 108, wdth: 128, wght: 220, slnt: 0),
  ),
  (text: 'Cc\n', style: _FlexStyle(size: 108, wdth: 48, wght: 420)),
  (text: 'Cc\n', style: _FlexStyle(size: 120, wdth: 50, wght: 460)),
]);

const _slotGoogle = _MorphSlot([
  (
    text: 'Google ',
    style: _FlexStyle(size: 118, wdth: 52, wght: 280, color: _inkPink),
  ),
  (
    text: 'Google ',
    style: _FlexStyle(size: 100, wdth: 48, wght: 420, color: _inkPink),
  ),
  (text: '  ', style: _FlexStyle(size: 8, wdth: 100, wght: 400)),
  (text: '  ', style: _FlexStyle(size: 8, wdth: 100, wght: 400)),
]);

const _slotSans = _MorphSlot([
  (text: 'Sans ', style: _FlexStyle(size: 118, wdth: 72, wght: 480)),
  (text: 'Sans ', style: _FlexStyle(size: 100, wdth: 72, wght: 380)),
  (text: 'Flex', style: _FlexStyle(size: 132, wdth: 132, wght: 920, color: _inkPink)),
  (
    text: 'Flex',
    style: _FlexStyle(size: 152, wdth: 142, wght: 960, color: _inkPink),
  ),
]);

const _slotFlex = _MorphSlot([
  (
    text: 'Flex!',
    style: _FlexStyle(size: 148, wdth: 118, wght: 860, slnt: -8, color: _inkPink),
  ),
  (
    text: 'Flex!',
    style: _FlexStyle(size: 132, wdth: 132, wght: 920, slnt: 0, color: _inkPink),
  ),
  (text: '  ', style: _FlexStyle(size: 8, wdth: 100, wght: 400)),
  (text: '  ', style: _FlexStyle(size: 8, wdth: 100, wght: 400)),
]);

const _slotDigits = _MorphSlot([
  (text: '', style: _FlexStyle(size: 8, wdth: 100, wght: 400)),
  (text: '', style: _FlexStyle(size: 8, wdth: 100, wght: 400)),
  (text: '01234!', style: _FlexStyle(size: 108, wdth: 48, wght: 420)),
  (text: '01234!', style: _FlexStyle(size: 120, wdth: 50, wght: 500)),
]);

const _slots = [
  _slotOh,
  _slotHi,
  _slotIm,
  _slotGoogle,
  _slotSans,
  _slotFlex,
  _slotDigits,
];

TextSpan _composedSpan(double t) => TextSpan(
  children: [for (final slot in _slots) _slotSpan(slot, t)],
);

class GoogleSansFlexDemoPage extends StatefulWidget {
  const GoogleSansFlexDemoPage({super.key});

  @override
  State<GoogleSansFlexDemoPage> createState() => _GoogleSansFlexDemoPageState();
}

class _GoogleSansFlexDemoPageState extends State<GoogleSansFlexDemoPage>
    with SingleTickerProviderStateMixin {
  var _loading = true;
  String? _error;
  late final AnimationController _controller;
  late final Animation<double> _morph;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _cycle)
      ..repeat(reverse: true);
    _morph = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubic,
    );
    _bootstrap();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      await GPUText.instance.loadFontAsset(_fontFamily, _fontAsset);
      if (!mounted) return;
      setState(() => _loading = false);
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
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      );
    }

    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: ListenableBuilder(
                listenable: GPUText.instance,
                builder: (context, _) {
                  if (reduceMotion) {
                    return GPURichText(text: _composedSpan(0));
                  }
                  return AnimatedBuilder(
                    animation: _morph,
                    builder: (context, _) => GPURichText(
                      text: _composedSpan(_morph.value),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
