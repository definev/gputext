// Side-by-side comparison of stock RichText and WindfoilRichText, plus a
// zoom pen showing windfoil's transform-adaptive re-rendering.
//
// Dev hooks (demo only): WINDFOIL_DEMO_ZOOM=<n> presets the InteractiveViewer
// zoom so screenshots can be taken without driving gestures.

import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';

import 'windfoil_flutter.dart';

const _ink = Color(0xFF0C0F1C);
const _accentRed = Color(0xFF8C1F14);
const _accentBlue = Color(0xFF14508C);

TextSpan _sampleSpan() => const TextSpan(
      style: TextStyle(fontFamily: 'Lato', fontSize: 16, color: _ink),
      children: [
        TextSpan(text: '🌚 Windfoil '),
        TextSpan(
          text: 'rich',
          style: TextStyle(fontSize: 26, color: _accentRed),
        ),
        TextSpan(
          text:
              ' text mixes sizes and colors in one paragraph, wraps greedily '
              'with kerning, and is rasterized by an exact box-filtered '
              'winding integral — ',
        ),
        TextSpan(
          text: 'crisp at any zoom',
          style: TextStyle(fontSize: 20, color: _accentBlue),
        ),
        TextSpan(
          text: '. The quick brown fox jumps over the lazy dog, 0123456789.',
        ),
      ],
    );

TextSpan _widgetSpanSample() => TextSpan(
      style: const TextStyle(fontFamily: 'Lato', fontSize: 16, color: _ink),
      children: [
        const TextSpan(text: 'Inline widgets: an icon '),
        const WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Icon(Icons.surfing, size: 20, color: _accentBlue),
        ),
        const TextSpan(text: ' a chip '),
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: _accentRed.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text('windfoil',
                style: TextStyle(fontSize: 13, color: _accentRed)),
          ),
        ),
        const TextSpan(text: ' and a tall box '),
        WidgetSpan(
          alignment: PlaceholderAlignment.bottom,
          child: Container(
            width: 26,
            height: 34,
            color: _accentBlue.withValues(alpha: 0.3),
          ),
        ),
        const TextSpan(
            text: ' all flow with the text and wrap across lines when '
                'the column is narrow.'),
      ],
    );

TextSpan _decorationSample() => const TextSpan(
      style: TextStyle(fontFamily: 'Lato', fontSize: 15, color: _ink),
      children: [
        TextSpan(
          text: 'underline ',
          style: TextStyle(decoration: TextDecoration.underline),
        ),
        TextSpan(
          text: 'wavy ',
          style: TextStyle(
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.wavy,
            decorationColor: _accentRed,
          ),
        ),
        TextSpan(
          text: 'strike ',
          style: TextStyle(decoration: TextDecoration.lineThrough),
        ),
        TextSpan(
          text: 'dashed-over ',
          style: TextStyle(
            decoration: TextDecoration.overline,
            decorationStyle: TextDecorationStyle.dashed,
            decorationColor: _accentBlue,
          ),
        ),
        TextSpan(
          text: 'dotted+spaced',
          style: TextStyle(
            letterSpacing: 2,
            wordSpacing: 6,
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dotted,
          ),
        ),
        TextSpan(
          text: ' — and this paragraph is justified, so its spaces stretch '
              'to fill the column width evenly on every wrapped line except '
              'the last one, tall lines included.',
          style: TextStyle(height: 1.6),
        ),
      ],
    );

TextSpan _emojiSample() => const TextSpan(
      style: TextStyle(fontFamily: 'Lato', fontSize: 16, color: _ink),
      children: [
        TextSpan(text: 'Emoji ride along: 🌚 moon, thumbs '),
        TextSpan(text: '👍🏽', style: TextStyle(fontSize: 26)),
        TextSpan(
          text: ' with tone, flag 🇻🇳, family 👨‍👩‍👧‍👦, keycap 1️⃣ — while '
              'the surrounding windfoil text stays vector-crisp.',
        ),
      ],
    );

TextSpan _fallbackSample() => const TextSpan(
      style: TextStyle(fontFamily: 'Lato', fontSize: 16, color: _ink),
      children: [
        TextSpan(
          text: 'Fallback: Latin windfoil text with 中文汉字, かなカナ, '
              '한글 — covered by the registered wide fallback font — and '
              'SMP music 𝄞𝄢 delegated to the platform. All of it wraps '
              'and mixes freely.',
        ),
      ],
    );

/// Demo of layer-1 (native) fallback: register a wide-coverage system TTF
/// so CJK renders through the windfoil shader itself. Uncovered characters
/// (e.g. SMP symbols) still delegate to the platform (layer 2).
Future<void> _registerWideFallback() async {
  final engine = Windfoil.instance;
  if (engine.fallbackFamilies.isNotEmpty) return;
  try {
    final file = File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
    if (!await file.exists()) return;
    final font = WindfoilFont.parse(await file.readAsBytes());
    engine.registerFont('Arial Unicode', font);
    engine.setFallbackFamilies(const ['Arial Unicode']);
  } catch (e) {
    debugPrint('demo: wide fallback font unavailable: $e');
  }
}

class WidgetDemoPage extends StatefulWidget {
  const WidgetDemoPage({super.key});

  @override
  State<WidgetDemoPage> createState() => _WidgetDemoPageState();
}

class _WidgetDemoPageState extends State<WidgetDemoPage> {
  final _zoom = TransformationController();

  @override
  void initState() {
    super.initState();
    _registerWideFallback();
    final z = double.tryParse(Platform.environment['WINDFOIL_DEMO_ZOOM'] ?? '');
    if (z != null && z > 0) {
      var fx = 110.0, fy = 46.0; // focal point held stationary while zooming
      final f = Platform.environment['WINDFOIL_DEMO_FOCAL']?.split(',');
      if (f != null && f.length == 2) {
        fx = double.tryParse(f[0]) ?? fx;
        fy = double.tryParse(f[1]) ?? fy;
      }
      _zoom.value = Matrix4.translationValues(fx * (1 - z), fy * (1 - z), 0)
        ..scaleByDouble(z, z, 1, 1);
    }
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  Widget _pair(String caption, Widget Function(bool windfoil) builder) {
    Widget cell(String title, Widget child) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Colors.black45)),
                const SizedBox(height: 4),
                child,
              ],
            ),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Text(caption,
              style: Theme.of(context).textTheme.titleSmall),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cell('RichText', builder(false)),
            cell('WindfoilRichText', builder(true)),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE9E3D5),
      appBar: AppBar(title: const Text('RichText vs WindfoilRichText')),
      body: ListView(
        children: [
          _pair(
            'Mixed-style paragraph, word wrap',
            (windfoil) => windfoil
                ? WindfoilRichText(text: _sampleSpan())
                : RichText(text: _sampleSpan()),
          ),
          _pair(
            'maxLines: 2, overflow: ellipsis, center-aligned',
            (windfoil) => windfoil
                ? WindfoilRichText(
                    text: _sampleSpan(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  )
                : RichText(
                    text: _sampleSpan(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
          ),
          _pair(
            'WidgetSpan: icon (middle), chip (baseline), box (bottom)',
            (windfoil) => windfoil
                ? WindfoilRichText(text: _widgetSpanSample())
                : RichText(text: _widgetSpanSample()),
          ),
          _pair(
            'Emoji: clusters, tones, flags, ZWJ, keycaps',
            (windfoil) => windfoil
                ? WindfoilRichText(text: _emojiSample())
                : RichText(text: _emojiSample()),
          ),
          _pair(
            'Font fallback: native (wide TTF) + platform delegation (SMP)',
            (windfoil) => windfoil
                ? WindfoilRichText(text: _fallbackSample())
                : RichText(text: _fallbackSample()),
          ),
          _pair(
            'Decorations, justify, wordSpacing, height',
            (windfoil) => windfoil
                ? WindfoilRichText(
                    text: _decorationSample(),
                    textAlign: TextAlign.justify,
                  )
                : RichText(
                    text: _decorationSample(),
                    textAlign: TextAlign.justify,
                  ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Text('Pinch/scroll to zoom — windfoil re-renders crisp'),
          ),
          SizedBox(
            height: 300,
            child: Container(
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(border: Border.all(color: Colors.black26)),
              child: ClipRect(
                child: InteractiveViewer(
                  transformationController: _zoom,
                  maxScale: 64,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: RichText(text: _sampleSpan()),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: WindfoilRichText(
                            text: _sampleSpan(),
                            scaleHint: _zoom,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
