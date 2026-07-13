// Shadow parity demo: native Flutter Text (left) vs GPURichText (right) with
// the same TextStyle.shadows. After the sigma/_imageScale fix in
// RenderGPUParagraph the two columns should match at every blur radius.
//
// Run:  GPUTEXT_DEMO=shadow fvm flutter run -d macos   (from example/)

import 'package:flutter/material.dart';
import 'package:gputext/gputext.dart';

const _ink = Color(0xFF10131A);
const _paper = Color(0xFFF3F1EA);
const _panel = Color(0xFFFFFFFF);
const _shadowColor = Color(0xFF000000);

Widget _text(
  bool gpu,
  String s,
  double fontSize,
  List<Shadow> shadows, {
  Color color = _ink,
  Color panel = _panel,
}) {
  final span = TextSpan(
    text: s,
    style: TextStyle(
      inherit: false,
      fontFamily: 'Lato',
      fontSize: fontSize,
      height: 1.2,
      color: color,
      shadows: shadows,
    ),
  );
  return Container(
    color: panel,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 18),
    child: gpu
        ? GPURichText(text: span, textDirection: TextDirection.ltr)
        : Text.rich(span, textDirection: TextDirection.ltr),
  );
}

Widget _labelled(String label, Widget child) => ClipRRect(
  borderRadius: BorderRadius.circular(8),
  child: Stack(
    fit: StackFit.expand,
    children: [
      child,
      Positioned(
        left: 6,
        top: 4,
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: 'Lato',
            fontSize: 10,
            color: Color(0x99000000),
          ),
        ),
      ),
    ],
  ),
);

class ShadowDemoPage extends StatelessWidget {
  const ShadowDemoPage({super.key});

  Widget _row(String title, double height, Widget Function(bool gpu) build) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Lato',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _ink,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _labelled('Flutter Text', build(false))),
                const SizedBox(width: 16),
                Expanded(child: _labelled('GPURichText', build(true))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Shadow drop(double blur) => Shadow(
      offset: const Offset(4, 4),
      blurRadius: blur,
      color: _shadowColor,
    );

    return Scaffold(
      backgroundColor: _paper,
      appBar: AppBar(
        title: const Text('Shadow parity — Text vs GPURichText'),
        backgroundColor: _paper,
        foregroundColor: _ink,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
        children: [
          const Text(
            'Left = native Text (reference). Right = GPURichText. The shadow '
            'should trace the letter edges, not smear the whole word.',
            style: TextStyle(fontFamily: 'Lato', fontSize: 14, color: _ink),
          ),
          const SizedBox(height: 20),

          _row(
            'Shape probe — isolated shadow (offset 150px, blur 14)',
            200,
            (gpu) => _text(gpu, 'R', 130, [
              const Shadow(
                offset: Offset(150, 0),
                blurRadius: 14,
                color: _shadowColor,
              ),
            ]),
          ),

          for (final blur in const [0.0, 2.0, 4.0, 8.0, 16.0, 24.0])
            _row(
              'blurRadius = ${blur.toStringAsFixed(0)}  (offset 4,4)',
              92,
              (gpu) => _text(gpu, 'Shadow Hx`g', 46, [drop(blur)]),
            ),

          _row(
            'Stacked shadows (glow) on dark panel',
            120,
            (gpu) => _text(
              gpu,
              'glow',
              64,
              const [
                Shadow(blurRadius: 6, color: Color(0xFF39C0FF)),
                Shadow(blurRadius: 14, color: Color(0xFF2060FF)),
                Shadow(blurRadius: 24, color: Color(0xFF0030A0)),
              ],
              color: const Color(0xFFFFFFFF),
              panel: const Color(0xFF0B1020),
            ),
          ),
        ],
      ),
    );
  }
}
