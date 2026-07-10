// RTL / bidi demo: Arabic + Hebrew with mixed LTR, selection, and alignment.

import 'package:flutter/material.dart';
import 'package:gputext/gputext.dart';

const _ink = Color(0xFF0C0F1C);
const _paper = Color(0xFFE9E3D5);
const _accent = Color(0xFF14508C);

class RtlDemoPage extends StatelessWidget {
  const RtlDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _paper,
      appBar: AppBar(
        title: const Text('RTL / bidi (Arabic + Hebrew)'),
        backgroundColor: _paper,
        foregroundColor: _ink,
      ),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _section(
              'Hebrew (RTL base)',
              textDirection: TextDirection.rtl,
              span: const TextSpan(
                text: 'שלום עולם — GPUText עם עיצוב דו-כיווני',
                style: TextStyle(fontFamily: 'Lato', fontSize: 22, color: _ink),
              ),
            ),
            _section(
              'Arabic (RTL base)',
              textDirection: TextDirection.rtl,
              span: const TextSpan(
                text: 'مرحبا بالعالم — نص عربي مع تشكيل بَ',
                style: TextStyle(fontFamily: 'Lato', fontSize: 22, color: _ink),
              ),
            ),
            _section(
              'Mixed LTR + Hebrew on one line',
              textDirection: TextDirection.ltr,
              span: const TextSpan(
                style: TextStyle(fontFamily: 'Lato', fontSize: 20, color: _ink),
                children: [
                  TextSpan(text: 'Hello '),
                  TextSpan(
                    text: 'שלום',
                    style: TextStyle(color: _accent, fontSize: 24),
                  ),
                  TextSpan(text: ' and back to Latin.'),
                ],
              ),
            ),
            _section(
              'TextAlign.start under RTL (mirrors to the right)',
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.start,
              span: const TextSpan(
                text: 'יישור להתחלה',
                style: TextStyle(fontFamily: 'Lato', fontSize: 20, color: _ink),
              ),
            ),
            _section(
              'TextAlign.end under RTL (mirrors to the left)',
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.end,
              span: const TextSpan(
                text: 'יישור לסוף',
                style: TextStyle(fontFamily: 'Lato', fontSize: 20, color: _ink),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Select any line — copied text is logical source order.',
              style: TextStyle(
                fontFamily: 'Lato',
                fontSize: 14,
                color: _ink.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(
    String title, {
    required TextSpan span,
    required TextDirection textDirection,
    TextAlign textAlign = TextAlign.start,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Lato',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _accent,
            ),
          ),
          const SizedBox(height: 8),
          Directionality(
            textDirection: textDirection,
            child: GPURichText(
              text: span,
              textDirection: textDirection,
              textAlign: textAlign,
            ),
          ),
        ],
      ),
    );
  }
}
