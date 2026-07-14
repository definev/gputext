// Cursed-text demo: torture the Unicode pipeline with zalgo, ZWJ emoji,
// mixed bidi, astral/surrogate soup, zero-width & control chars, complex
// scripts and ligatures — each rendered by GPUText next to Flutter's native
// Text so the differences (and the emoji-composition limits) are obvious.
//
// Launch:  GPUTEXT_DEMO=cursed fvm flutter run \
//            --enable-impeller --enable-flutter-gpu -d macos

// This demo intentionally embeds bidi-control code points (RLO/LRI/…) as the
// cursed text under test.
// ignore_for_file: text_direction_code_point_in_literal

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gputext/gputext.dart';

const _ink = Color(0xFF0C0F1C);
const _paper = Color(0xFFE9E3D5);
const _accent = Color(0xFF14508C);
const _muted = Color(0xFF6B6458);
const _card = Color(0xFFF4EFE4);

/// One cursed sample: a human label, the raw string, and an optional note
/// explaining what to look for.
class _Sample {
  const _Sample(this.label, this.text, {this.note, this.direction});
  final String label;
  final String text;
  final String? note;
  final TextDirection? direction;
}

// Zero-width / bidi-control code points, referenced via escapes so the source
// file itself doesn't get reordered by the very characters we're testing.
const _zwj = '‍';
const _vs16 = '️';
const _rlo = '‮', _pdf = '‬';
const _lri = '⁦', _rli = '⁧', _pdi = '⁩';

String _zalgo(String base, int marks) {
  final b = StringBuffer();
  for (final r in base.runes) {
    b.writeCharCode(r);
    for (var i = 0; i < marks; i++) {
      b.writeCharCode(0x0300 + (i % 0x70));
    }
  }
  return b.toString();
}

class _Group {
  const _Group(this.title, this.samples, {this.caption});
  final String title;
  final String? caption;
  final List<_Sample> samples;
}

List<_Group> _groups() => [
  _Group('Zalgo — stacked combining marks', [
    const _Sample('light (3 marks/char)', 'Z̈a̋l̆g̈ő'),
    _Sample('heavy (40 marks/char)', _zalgo('DOOM', 40)),
    const _Sample('marks with no base', '́̂̃̄̅'),
  ], caption: 'HarfBuzz positions each mark; the whole stack is one grapheme.'),
  const _Group(
    'Emoji — composition',
    [
      _Sample('simple', '😀 😁 😂 🎉 🚀'),
      _Sample(
        'ZWJ family',
        '👨‍👩‍👧‍👦',
        note: 'GPUText shows 4 people; Flutter composes one family glyph.',
      ),
      _Sample('rainbow flag (ZWJ)', '🏳️‍🌈'),
      _Sample('skin-tone modifier', '👋🏿  👍🏽'),
      _Sample('regional-indicator flags', '🇯🇵 🇺🇸 🇻🇳'),
      _Sample('keycap', '1️⃣ #️⃣'),
    ],
    caption: 'GPUText looks up each code point in COLR per-rune, so ZWJ / '
        'flag / skin-tone sequences are NOT combined into one glyph.',
  ),
  _Group('Mixed bidi (RTL + LTR)', const [
    _Sample('Arabic + Latin', 'Order 42: مرحبا بالعالم then back.',
        direction: TextDirection.ltr),
    _Sample('Hebrew + Latin', 'Price שלום עולם is 100 ₪.',
        direction: TextDirection.ltr),
    _Sample('RTL base', 'مرحبا بالعالم — نص عربي',
        direction: TextDirection.rtl),
  ], caption: 'Copied text stays logical source order regardless of visuals.'),
  _Group('Bidi overrides & isolates', [
    _Sample('RLO override on Latin', '$_rlo' 'reversed?' '$_pdf'),
    _Sample('nested isolates', '$_lri' 'a' '$_rli' 'שלום' '$_pdi' 'b' '$_pdi'),
  ]),
  const _Group('Astral plane (> U+FFFF)', [
    _Sample('math bold', '𝐇𝐞𝐥𝐥𝐨 𝟏𝟐𝟑'),
    _Sample('CJK Ext-B', '𠜎 𠜱 𠝹'),
    _Sample('misc symbols', '🀄 𝕏 🄯 🯰'),
  ], caption: 'Surrogate pairs stay intact; uncovered ones become .notdef.'),
  const _Group('Complex scripts (need wide fallback)', [
    _Sample('CJK', '你好世界 こんにちは 안녕하세요'),
    _Sample('Thai (no dictionary break)', 'สวัสดีชาวโลก'),
    _Sample('Devanagari', 'नमस्ते दुनिया'),
  ], caption: 'Renders when Arial Unicode fallback is present; else tofu boxes.'),
  const _Group('Ligatures & zero-width', [
    _Sample('OpenType ligatures', 'office difficult waffle — fi fl ffi'),
    _Sample('precomposed ligatures', 'ﬁ ﬂ'),
    _Sample('zero-width joiners/spaces', 'a​b‌c‍d⁠e﻿f'),
  ]),
  _Group('Kitchen sink', [
    _Sample(
      'everything at once',
      'A​b\t${_zalgo('Z', 6)} مرحبا 👨$_zwj👩 '
          '𝐌 $_rlo' 'xyz' '$_pdf 你好 $_vs16',
      direction: TextDirection.ltr,
    ),
  ]),
];

class CursedDemoPage extends StatefulWidget {
  const CursedDemoPage({super.key});

  @override
  State<CursedDemoPage> createState() => _CursedDemoPageState();
}

class _CursedDemoPageState extends State<CursedDemoPage> {
  // Gate the sample tree on font registration. GPURichText computes its span
  // structure (emoji → COLR runs, uncovered chars → delegated WidgetSpans) at
  // build time via ListenableBuilder(GPUText.instance). Registering a font
  // AFTER the samples mount fires notifyListeners(), and the resulting rebuild
  // re-expands the spans — remounting a subtree mid-update, which trips the
  // framework's '!_dirty' assert in debug. So we register everything first,
  // then build the samples exactly once.
  bool _fontsReady = false;

  @override
  void initState() {
    super.initState();
    _loadFonts();
  }

  Future<void> _loadFonts() async {
    final engine = GPUText.instance;
    // Native COLR emoji (single code points render through the gputext shader).
    // The emoji font is process-wide; reload Twemoji defensively if a CBDT font
    // is somehow still active so this demo renders its own COLR emoji.
    if (engine.emojiFont == null || engine.emojiFont!.hasBitmapGlyphs) {
      try {
        await engine.loadEmojiFontAsset('assets/TwemojiMozilla.ttf');
      } catch (e) {
        debugPrint('cursed demo: emoji font unavailable: $e');
      }
    }
    // Wide fallback so CJK/Thai/Devanagari render instead of tofu (macOS ships
    // Arial Unicode; other hosts just show boxes, which is also a valid test).
    // Timeouts keep the gate reachable under flutter_test's fake-async, where
    // dart:io file futures don't resolve on their own.
    if (engine.fallbackFamilies.isEmpty) {
      try {
        final file =
            File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
        final exists = await file
            .exists()
            .timeout(const Duration(seconds: 1), onTimeout: () => false);
        if (exists) {
          final bytes =
              await file.readAsBytes().timeout(const Duration(seconds: 3));
          engine.registerFont('Arial Unicode', GPUFont.parse(bytes));
          engine.setFallbackFamilies(const ['Arial Unicode']);
        }
      } catch (e) {
        debugPrint('cursed demo: wide fallback unavailable: $e');
      }
    }
    if (mounted) setState(() => _fontsReady = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _paper,
      appBar: AppBar(
        title: const Text('Cursed text — Unicode stress test'),
        backgroundColor: _paper,
        foregroundColor: _ink,
      ),
      // No page-wide SelectionArea: with it, GPURichText registers a selectable
      // during its first build (marking itself dirty), and a font-load rebuild
      // can then mount a GPURichText while dirty under the SelectionRegistrar's
      // InheritedNotifier update — another '!_dirty' assert. This demo is about
      // the visual GPU-vs-Flutter comparison; the rtl demo showcases selection.
      body: _fontsReady
          ? SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Legend(),
                  for (final g in _groups()) _GroupView(group: g),
                  const SizedBox(height: 12),
                  const Text(
                    'GPUText renders each cursed string; REF is Flutter for '
                    'comparison.',
                    style: TextStyle(
                      fontFamily: 'Lato',
                      fontSize: 13,
                      color: _muted,
                    ),
                  ),
                ],
              ),
            )
          : const Center(
              child: Text(
                'Loading emoji + fallback fonts…',
                style: TextStyle(fontFamily: 'Lato', fontSize: 14, color: _muted),
              ),
            ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        children: [
          _chip('GPU', _accent, 'gputext'),
          const SizedBox(width: 12),
          _chip('REF', _muted, "Flutter's native Text"),
        ],
      ),
    );
  }

  Widget _chip(String tag, Color c, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              tag,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: _ink, fontSize: 13)),
        ],
      );
}

class _GroupView extends StatelessWidget {
  const _GroupView({required this.group});
  final _Group group;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _ink.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            group.title,
            style: const TextStyle(
              fontFamily: 'Lato',
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          if (group.caption != null) ...[
            const SizedBox(height: 4),
            Text(
              group.caption!,
              style: const TextStyle(
                fontFamily: 'Lato',
                fontSize: 12,
                color: _muted,
                height: 1.3,
              ),
            ),
          ],
          const SizedBox(height: 12),
          for (final s in group.samples) _SampleRow(sample: s),
        ],
      ),
    );
  }
}

class _SampleRow extends StatelessWidget {
  const _SampleRow({required this.sample});
  final _Sample sample;

  static const _style = TextStyle(
    fontFamily: 'Lato',
    fontSize: 24,
    color: _ink,
  );

  @override
  Widget build(BuildContext context) {
    final dir = sample.direction ?? TextDirection.ltr;
    final span = TextSpan(text: sample.text, style: _style);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sample.label,
            style: const TextStyle(
              fontFamily: 'Lato',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _accent,
            ),
          ),
          if (sample.note != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                sample.note!,
                style: const TextStyle(
                  fontFamily: 'Lato',
                  fontSize: 11,
                  color: _muted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          const SizedBox(height: 6),
          _labeledLine('GPU', _accent, _gpuLine(span, dir)),
          const SizedBox(height: 4),
          _labeledLine('REF', _muted, _refLine(span, dir)),
        ],
      ),
    );
  }

  Widget _gpuLine(TextSpan span, TextDirection dir) => Directionality(
        textDirection: dir,
        child: GPURichText(
          text: span,
          textDirection: dir,
          softWrap: true,
        ),
      );

  Widget _refLine(TextSpan span, TextDirection dir) => Directionality(
        textDirection: dir,
        child: Text.rich(span, textDirection: dir),
      );

  Widget _labeledLine(String tag, Color c, Widget child) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(vertical: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              tag,
              style: TextStyle(
                color: c,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: child),
        ],
      );
}
