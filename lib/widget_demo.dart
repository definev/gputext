// Side-by-side comparison of stock RichText and WindfoilRichText, plus a
// zoom pen showing windfoil's transform-adaptive re-rendering.
//
// Dev hooks (demo only): WINDFOIL_DEMO_ZOOM=<n> presets the InteractiveViewer
// zoom so screenshots can be taken without driving gestures.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'windfoil_flutter.dart';

const _ink = Color(0xFF0C0F1C);
const _accentRed = Color(0xFF8C1F14);
const _accentBlue = Color(0xFF14508C);

TextSpan _sampleSpan() => const TextSpan(
      style: TextStyle(fontFamily: 'Lato', fontSize: 16, color: _ink),
      children: [
        TextSpan(text: 'Windfoil '),
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
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Text('Pinch/scroll to zoom — windfoil re-renders crisp'),
          ),
          Expanded(
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
