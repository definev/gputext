// Side-by-side comparison of stock RichText and GPURichText, plus a
// zoom pen showing gputext's transform-adaptive re-rendering.
//
// Dev hooks (demo only): GPUTEXT_DEMO_ZOOM=<n> presets the InteractiveViewer
// zoom so screenshots can be taken without driving gestures.

import 'dart:io' show File, Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:gputext/gputext.dart';

const _ink = Color(0xFF0C0F1C);
const _accentRed = Color(0xFF8C1F14);
const _accentBlue = Color(0xFF14508C);
const _paper = Color(0xFFE9E3D5);
const _darkSurface = Color(0xFF14171F);
const _darkAmber = Color(0xFFE8B14C);

TextSpan _sampleSpan() => const TextSpan(
  style: TextStyle(fontFamily: 'Lato', fontSize: 16, color: _ink),
  children: [
    TextSpan(text: '🌚 GPUText '),
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
    WidgetSpan(
      alignment: PlaceholderAlignment.bottom,
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
        child: GPURichText(
          text: TextSpan(
            text: 'gputext',
            style: TextStyle(fontSize: 13, color: _accentRed),
          ),
        ),
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
      text:
          ' all flow with the text and wrap across lines when '
          'the column is narrow.',
    ),
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
      text:
          ' — and this paragraph is justified, so its spaces stretch '
          'to fill the column width evenly on every wrapped line except '
          'the last one, tall lines included.',
      style: TextStyle(height: 1.6),
    ),
  ],
);

TextSpan _paintSample() => TextSpan(
  style: const TextStyle(fontFamily: 'Lato', fontSize: 16, color: _ink),
  children: [
    const TextSpan(text: 'Highlights: '),
    const TextSpan(
      text: 'marked text',
      style: TextStyle(backgroundColor: Color(0x5FE8B14C)),
    ),
    const TextSpan(text: ' and '),
    const TextSpan(
      text: 'inverse',
      style: TextStyle(color: _paper, backgroundColor: _accentBlue),
    ),
    const TextSpan(text: ', shadows: '),
    const TextSpan(
      text: 'soft drop',
      style: TextStyle(
        fontSize: 22,
        shadows: [
          Shadow(offset: Offset(2, 2), blurRadius: 4, color: Color(0x66000000)),
        ],
      ),
    ),
    const TextSpan(text: ' + '),
    const TextSpan(
      text: 'hard red',
      style: TextStyle(
        fontSize: 22,
        shadows: [Shadow(offset: Offset(1.5, 1.5), color: _accentRed)],
      ),
    ),
    const TextSpan(text: ', and a '),
    TextSpan(
      text: 'foreground paint',
      style: TextStyle(foreground: Paint()..color = _accentBlue),
    ),
    const TextSpan(text: '.'),
  ],
);

TextSpan _strutSample() => const TextSpan(
  style: TextStyle(fontFamily: 'Lato', fontSize: 13, color: _ink),
  text:
      'Small 13px text on a 28px strut: every line of this wrapped '
      'paragraph advances by the strut height, giving airy, consistent '
      'leading without changing the glyph size.',
);

TextSpan _fadeSample() => const TextSpan(
  style: TextStyle(fontFamily: 'Lato', fontSize: 15, color: _ink),
  text:
      'This single line is far too long for its box and fades out at '
      'the trailing edge instead of clipping hard.',
);

TextSpan _emojiSample() => const TextSpan(
  style: TextStyle(fontFamily: 'Lato', fontSize: 16, color: _ink),
  children: [
    TextSpan(text: 'Emoji ride along: 🌚 moon, thumbs '),
    TextSpan(text: '👍🏽', style: TextStyle(fontSize: 26)),
    TextSpan(
      text:
          ' with tone, flag 🇻🇳, family 👨‍👩‍👧‍👦, keycap 1️⃣ — while '
          'the surrounding gputext text stays vector-crisp.',
    ),
  ],
);

TextSpan _fallbackSample() => const TextSpan(
  style: TextStyle(fontFamily: 'Lato', fontSize: 16, color: _ink),
  children: [
    TextSpan(
      text:
          'Fallback: Latin gputext text with 中文汉字, かなカナ, '
          '한글 — covered by the registered wide fallback font — and '
          'SMP music 𝄞𝄢 delegated to the platform. All of it wraps '
          'and mixes freely.',
    ),
  ],
);

TextSpan _kernLigaSample() => const TextSpan(
  style: TextStyle(fontFamily: 'Lato', fontSize: 22, color: _ink),
  children: [
    TextSpan(text: 'AVATAR Toy WAVE LT. — GPOS kerning; ligatures: '),
    TextSpan(
      text: 'office waffles inflate fifty flags',
      style: TextStyle(color: _accentBlue),
    ),
    TextSpan(
      text: '  (tracked stays unligated: office flags)',
      style: TextStyle(letterSpacing: 3, fontSize: 15),
    ),
  ],
);

TextSpan _cjkWrapSample() => const TextSpan(
  style: TextStyle(fontFamily: 'Lato', fontSize: 16, color: _ink),
  text:
      '中文排版可以在任意两个汉字之间换行即使整段没有空格也能正确折行 — '
      'and hyphenated state-of-the-art well-known compounds '
      'break after their hyphens.',
);

TextSpan _linkSample(TapGestureRecognizer recognizer, int taps) => TextSpan(
  style: const TextStyle(fontFamily: 'Lato', fontSize: 16, color: _ink),
  children: [
    const TextSpan(text: 'Spans with recognizers work — '),
    TextSpan(
      text: 'tap this link',
      style: const TextStyle(
        color: _accentBlue,
        decoration: TextDecoration.underline,
        decorationColor: _accentBlue,
      ),
      recognizer: recognizer,
    ),
    TextSpan(text: ' — tapped $taps time${taps == 1 ? '' : 's'}.'),
  ],
);

TextSpan _darkSample() => const TextSpan(
  style: TextStyle(fontFamily: 'Lato', fontSize: 16, color: _paper),
  children: [
    TextSpan(text: 'Light text on a dark surface composites cleanly — '),
    TextSpan(
      text: 'no AA fringing',
      style: TextStyle(fontSize: 22, color: _darkAmber),
    ),
    TextSpan(text: ' at any size, '),
    TextSpan(
      text: 'semi-transparent runs',
      style: TextStyle(color: Color(0x80E9E3D5)), // 50% alpha
    ),
    TextSpan(text: ' blend true, '),
    TextSpan(
      text: 'wavy decorations',
      style: TextStyle(
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.wavy,
        decorationColor: _darkAmber,
      ),
    ),
    TextSpan(
      text:
          ' hold their color, and emoji 🌚 ride along. The quick brown '
          'fox jumps over the lazy dog, 0123456789.',
    ),
  ],
);

// ── Complex / non-trivial scenarios ─────────────────────────────────────

Widget _demoChip(String label, Color bg, {Color fg = _ink}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9)),
  child: Text(
    label,
    style: TextStyle(fontFamily: 'Lato', fontSize: 12, color: fg, height: 1.1),
  ),
);

Widget _demoAvatar(Color color, String initials) => Container(
  width: 22,
  height: 22,
  alignment: Alignment.center,
  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  child: Text(
    initials,
    style: const TextStyle(
      fontFamily: 'Lato',
      fontSize: 9,
      fontWeight: FontWeight.w700,
      color: Color(0xFFFFFFFF),
      height: 1,
    ),
  ),
);

Widget _demoAlignBox(String label, double h, Color color) => Container(
  width: 28,
  height: h,
  alignment: Alignment.center,
  color: color,
  child: Text(
    label,
    textAlign: TextAlign.center,
    style: const TextStyle(
      fontFamily: 'Lato',
      fontSize: 8,
      color: Color(0xFF111111),
      height: 1,
    ),
  ),
);

/// Social-feed row: avatar, @mention, status pill, styled body, reaction
/// chips, thumbnail, and a trailing timestamp — widgets of different
/// heights interleaved so line boxes grow and wrap mid-sentence.
TextSpan _feedItemSpan({
  required TapGestureRecognizer mention,
  required TapGestureRecognizer thread,
}) => TextSpan(
  style: const TextStyle(fontFamily: 'Lato', fontSize: 15, color: _ink),
  children: [
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _demoAvatar(_accentBlue, 'NK'),
    ),
    const TextSpan(text: ' '),
    TextSpan(
      text: '@nora',
      style: const TextStyle(
        color: _accentBlue,
        fontWeight: FontWeight.w700,
        decoration: TextDecoration.underline,
        decorationColor: _accentBlue,
      ),
      recognizer: mention,
    ),
    const TextSpan(text: ' '),
    WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: _demoChip('maintainer', const Color(0x1A8C1F14), fg: _accentRed),
    ),
    const TextSpan(text: ' reviewed '),
    TextSpan(
      text: 'PR #1842',
      style: const TextStyle(
        color: _accentBlue,
        decoration: TextDecoration.underline,
      ),
      recognizer: thread,
    ),
    const TextSpan(text: ' — the '),
    const TextSpan(
      text: 'prepare-cache',
      style: TextStyle(
        fontFamily: 'Courier',
        fontSize: 13,
        backgroundColor: Color(0x33214568),
      ),
    ),
    const TextSpan(
      text:
          ' hit rate on the shared-grid scenario is back above 99%, and '
          'the emoji ZWJ path no longer disables layout for the whole '
          'paragraph. Nice catch on the ',
    ),
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _demoChip('baseline', const Color(0x3314508C), fg: _accentBlue),
    ),
    const TextSpan(text: ' chip alignment. '),
    // Adjacent reaction widgets (no text between) — edge case.
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _demoChip('+12', const Color(0x22000000)),
    ),
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _demoChip('+4', const Color(0x22000000)),
    ),
    const TextSpan(text: ' '),
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        width: 40,
        height: 48,
        decoration: BoxDecoration(
          color: _accentBlue.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: _accentBlue.withValues(alpha: 0.4)),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.image_outlined, size: 18, color: _accentBlue),
      ),
    ),
    const TextSpan(text: '  ·  '),
    WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: _demoChip('2h ago', const Color(0x14000000)),
    ),
  ],
);

/// Every PlaceholderAlignment in one wrapping paragraph, with a 1x1
/// degenerate widget and a leading/trailing pair.
TextSpan _alignmentStressSpan() => TextSpan(
  style: const TextStyle(fontFamily: 'Lato', fontSize: 15, color: _ink),
  children: [
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _demoAlignBox('lead', 14, const Color(0xFFB0BEC5)),
    ),
    const TextSpan(text: ' Alignments in one run — top '),
    WidgetSpan(
      alignment: PlaceholderAlignment.top,
      child: _demoAlignBox('top', 12, const Color(0xFF80CBC4)),
    ),
    const TextSpan(text: ' middle '),
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _demoAlignBox('mid', 28, const Color(0xFFEF9A9A)),
    ),
    const TextSpan(text: ' bottom '),
    WidgetSpan(
      alignment: PlaceholderAlignment.bottom,
      child: _demoAlignBox('bot', 20, const Color(0xFFCE93D8)),
    ),
    const TextSpan(text: ' aboveBaseline '),
    WidgetSpan(
      alignment: PlaceholderAlignment.aboveBaseline,
      baseline: TextBaseline.alphabetic,
      child: _demoAlignBox('ab', 10, const Color(0xFFFFCC80)),
    ),
    const TextSpan(text: ' belowBaseline '),
    WidgetSpan(
      alignment: PlaceholderAlignment.belowBaseline,
      baseline: TextBaseline.alphabetic,
      child: _demoAlignBox('bl', 10, const Color(0xFFA5D6A7)),
    ),
    const TextSpan(text: ' baseline '),
    WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: _demoChip('base', const Color(0xFFE3F2FD)),
    ),
    const TextSpan(text: ' then a 1x1 '),
    const WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: SizedBox(
        width: 1,
        height: 1,
        child: ColoredBox(color: Color(0xFF000000)),
      ),
    ),
    const TextSpan(text: ' speck, two adjacent boxes '),
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _demoAlignBox('A', 10, const Color(0xFF90A4AE)),
    ),
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _demoAlignBox('B', 10, const Color(0xFF78909C)),
    ),
    const TextSpan(text: ' and a trailing '),
    WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: _demoChip('end', const Color(0xFFFFE0B2)),
    ),
    const TextSpan(text: '.'),
  ],
);

/// Mixed-script release note: Latin + CJK + Arabic + emoji + URL +
/// inline footnote markers as WidgetSpans, justified.
TextSpan _releaseNoteSpan(TapGestureRecognizer url) => TextSpan(
  style: const TextStyle(
    fontFamily: 'Lato',
    fontSize: 15,
    color: _ink,
    height: 1.45,
  ),
  children: [
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _demoChip('v2.3.1', _accentRed, fg: const Color(0xFFFFFFFF)),
    ),
    const TextSpan(text: '  Release checklist — ship the '),
    const TextSpan(
      text: '8:30-4:30',
      style: TextStyle(fontWeight: FontWeight.w700),
    ),
    const TextSpan(text: ' coverage panel, keep '),
    TextSpan(
      text: 'https://example.com/reports/q3?lang=ar',
      style: const TextStyle(
        color: _accentBlue,
        decoration: TextDecoration.underline,
        fontSize: 13,
      ),
      recognizer: url,
    ),
    const TextSpan(text: ' readable'),
    WidgetSpan(
      alignment: PlaceholderAlignment.aboveBaseline,
      baseline: TextBaseline.alphabetic,
      child: _demoChip('1', const Color(0x22000000)),
    ),
    const TextSpan(
      text:
          ', and do not let the primary CTA jump when the card shrinks. '
          'Nora wrote "please keep 10 000 rows visible"; Kenji answered '
          'before pasting the price note. Mixed scripts follow: ',
    ),
    const TextSpan(text: '\u4e86\u89e3\u3067\u3059'),
    const TextSpan(text: ' · '),
    const TextSpan(text: '\u4fa1\u683c\u306f\u00a512,800'),
    const TextSpan(text: ' · '),
    const TextSpan(text: '\u0647\u0630\u0627 \u062c\u064a\u062f'),
    const TextSpan(text: ' · status '),
    const TextSpan(
      text: '\u{1F469}\u{200D}\u{1F4BB} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}',
    ),
    const TextSpan(text: '. Hard spaces like 50\u{00A0}kg still wrap.'),
    WidgetSpan(
      alignment: PlaceholderAlignment.aboveBaseline,
      baseline: TextBaseline.alphabetic,
      child: _demoChip('2', const Color(0x22000000)),
    ),
  ],
);

/// Interactive CI status thread: tappable status pills mutate the span
/// tree while surrounding styled text and WidgetSpans stay put.
TextSpan _ciThreadSpan({
  required String status,
  required Color statusColor,
  required int retries,
  required VoidCallback onToggleStatus,
  required VoidCallback onRetry,
  required TapGestureRecognizer jobLink,
}) {
  final failed = status == 'failed';
  return TextSpan(
    style: const TextStyle(fontFamily: 'Lato', fontSize: 15, color: _ink),
    children: [
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _demoAvatar(failed ? _accentRed : const Color(0xFF2E7D32), 'CI'),
      ),
      const TextSpan(text: ' '),
      TextSpan(
        text: 'macos-profile',
        style: const TextStyle(
          color: _accentBlue,
          decoration: TextDecoration.underline,
          fontWeight: FontWeight.w600,
        ),
        recognizer: jobLink,
      ),
      const TextSpan(text: '  '),
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: onToggleStatus,
          child: _demoChip(status, statusColor, fg: const Color(0xFFFFFFFF)),
        ),
      ),
      TextSpan(text: ' after $retries retr${retries == 1 ? 'y' : 'ies'}. '),
      const TextSpan(
        text: 'frame.rich_interleave',
        style: TextStyle(
          fontFamily: 'Courier',
          fontSize: 13,
          backgroundColor: Color(0x33214568),
        ),
      ),
      const TextSpan(
        text:
            ' p50 build is within budget; raster stays under 0.3\u{00A0}ms. '
            'Artifacts: ',
      ),
      const WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Icon(Icons.attach_file, size: 16, color: _accentBlue),
      ),
      const TextSpan(text: ' '),
      const TextSpan(
        text: 'bench.json',
        style: TextStyle(
          decoration: TextDecoration.underline,
          color: _accentBlue,
        ),
      ),
      const TextSpan(text: ' + '),
      const TextSpan(
        text: 'diff.png',
        style: TextStyle(
          decoration: TextDecoration.underline,
          color: _accentBlue,
        ),
      ),
      const TextSpan(text: '. '),
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: GestureDetector(
          onTap: onRetry,
          child: _demoChip('retry', const Color(0x3314508C), fg: _accentBlue),
        ),
      ),
      if (failed) ...[
        const TextSpan(text: '  '),
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _demoChip('flaky?', const Color(0x33E8B14C), fg: _ink),
        ),
      ],
    ],
  );
}

/// Nested quote card: outer paragraph with an inset WidgetSpan that itself
/// holds a full rich paragraph — deep placeholder nesting.
TextSpan _nestedQuoteSpan() => TextSpan(
  style: const TextStyle(
    fontFamily: 'Lato',
    fontSize: 15,
    color: _ink,
    height: 1.4,
  ),
  children: [
    const TextSpan(
      text:
          'When the zoom pen crosses a quantized scale step, gputext '
          're-renders the surface instead of scaling a bitmap. As the '
          'design note puts it: ',
    ),
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        width: 280,
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: const Color(0x14E8B14C),
          border: const Border(left: BorderSide(color: _darkAmber, width: 3)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text.rich(
          TextSpan(
            style: const TextStyle(
              fontFamily: 'Lato',
              fontSize: 13,
              color: _ink,
              height: 1.35,
            ),
            children: [
              const WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Icon(Icons.format_quote, size: 16, color: _darkAmber),
              ),
              const TextSpan(text: ' '),
              const TextSpan(
                text: 'Ada L. ',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: _demoChip('design', const Color(0x33E8B14C)),
              ),
              const TextSpan(
                text:
                    ' — "Crisp at 1\u{00D7} and at 8\u{00D7} is the whole '
                    'point; blurry zoom is a bug, not a tradeoff."',
              ),
            ],
          ),
        ),
      ),
    ),
    const TextSpan(
      text:
          ' Pair that with scaleHint across InteractiveViewer so the '
          're-render still fires when a RepaintBoundary sits between the '
          'transform and the text.',
    ),
  ],
);

/// Demo of layer-1 (native) fallback: register a wide-coverage system TTF
/// so CJK renders through the gputext shader itself. Uncovered characters
/// (e.g. SMP symbols) still delegate to the platform (layer 2).
Future<void> _registerWideFallback() async {
  final engine = GPUText.instance;
  // This demo showcases COLR (Twemoji) emoji. The emoji font is process-wide;
  // the Bitmap-emoji demo restores the prior font on leave, but reload Twemoji
  // defensively if a CBDT font is somehow still active so this demo always
  // renders its own COLR emoji. registerEmojiFont notifies, rebuilding samples.
  if (engine.emojiFont == null || engine.emojiFont!.hasBitmapGlyphs) {
    try {
      await engine.loadEmojiFontAsset('assets/TwemojiMozilla.ttf');
    } catch (e) {
      debugPrint('demo: emoji font unavailable: $e');
    }
  }
  if (engine.fallbackFamilies.isNotEmpty) return;
  try {
    final file = File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
    if (!await file.exists()) return;
    final font = GPUFont.parse(await file.readAsBytes());
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

class _WidgetDemoPageState extends State<WidgetDemoPage>
    with TickerProviderStateMixin {
  static const _tabs = [
    'Basics',
    'Feed',
    'Align',
    'Release',
    'CI',
    'Quote',
    'Zoom',
    'Stress',
  ];

  final _zoom = TransformationController();
  late final TabController _tab;
  late final ScrollController _scroll;
  late final TapGestureRecognizer _linkLeft;
  late final TapGestureRecognizer _linkRight;
  late final TapGestureRecognizer _mentionLeft;
  late final TapGestureRecognizer _mentionRight;
  late final TapGestureRecognizer _threadLeft;
  late final TapGestureRecognizer _threadRight;
  late final TapGestureRecognizer _urlLeft;
  late final TapGestureRecognizer _urlRight;
  late final TapGestureRecognizer _jobLeft;
  late final TapGestureRecognizer _jobRight;
  Ticker? _stressTicker;
  var _leftTaps = 0;
  var _rightTaps = 0;
  var _mentionTaps = 0;
  var _threadTaps = 0;
  var _urlTaps = 0;
  var _jobTaps = 0;
  var _ciFailed = false;
  var _ciRetries = 0;
  var _cardWidth = 360.0;
  var _stressTick = 0;
  var _stressEngine = true; // true = GPURichText only
  double _fps = 0;
  final _frameMarks = <Duration>[];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _tabs.length, vsync: this);
    _tab.addListener(_onTabChanged);
    _linkLeft = TapGestureRecognizer()
      ..onTap = () => setState(() => _leftTaps++);
    _linkRight = TapGestureRecognizer()
      ..onTap = () => setState(() => _rightTaps++);
    _mentionLeft = TapGestureRecognizer()
      ..onTap = () => setState(() => _mentionTaps++);
    _mentionRight = TapGestureRecognizer()
      ..onTap = () => setState(() => _mentionTaps++);
    _threadLeft = TapGestureRecognizer()
      ..onTap = () => setState(() => _threadTaps++);
    _threadRight = TapGestureRecognizer()
      ..onTap = () => setState(() => _threadTaps++);
    _urlLeft = TapGestureRecognizer()..onTap = () => setState(() => _urlTaps++);
    _urlRight = TapGestureRecognizer()
      ..onTap = () => setState(() => _urlTaps++);
    _jobLeft = TapGestureRecognizer()..onTap = () => setState(() => _jobTaps++);
    _jobRight = TapGestureRecognizer()
      ..onTap = () => setState(() => _jobTaps++);
    // The cache-stats footer reads counters that only move during layout;
    // refresh once after the first frame so it shows real numbers.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
    _registerWideFallback();
    _scroll = ScrollController(
      initialScrollOffset:
          double.tryParse(Platform.environment['GPUTEXT_DEMO_SCROLL'] ?? '') ??
          0,
    );
    final z = double.tryParse(Platform.environment['GPUTEXT_DEMO_ZOOM'] ?? '');
    if (z != null && z > 0) {
      var fx = 110.0, fy = 46.0; // focal point held stationary while zooming
      final f = Platform.environment['GPUTEXT_DEMO_FOCAL']?.split(',');
      if (f != null && f.length == 2) {
        fx = double.tryParse(f[0]) ?? fx;
        fy = double.tryParse(f[1]) ?? fy;
      }
      _zoom.value = Matrix4.translationValues(fx * (1 - z), fy * (1 - z), 0)
        ..scaleByDouble(z, z, 1, 1);
    }
  }

  void _onTabChanged() {
    if (_tab.indexIsChanging) return;
    final stress = _tabs[_tab.index] == 'Stress';
    if (stress) {
      _startStress();
    } else {
      _stopStress();
    }
    setState(() {});
  }

  void _startStress() {
    if (_stressTicker != null) return;
    _frameMarks.clear();
    _stressTicker = createTicker(_onStressTick)..start();
  }

  void _stopStress() {
    _stressTicker?.dispose();
    _stressTicker = null;
  }

  void _onStressTick(Duration elapsed) {
    _stressTick++;
    _frameMarks.add(elapsed);
    // Keep ~1s of marks; FPS = count in the trailing window.
    while (_frameMarks.length > 1 &&
        (elapsed - _frameMarks.first).inMilliseconds > 1000) {
      _frameMarks.removeAt(0);
    }
    final windowMs = _frameMarks.length < 2
        ? 0
        : (elapsed - _frameMarks.first).inMilliseconds;
    final fps = windowMs <= 0
        ? 0.0
        : (_frameMarks.length - 1) * 1000.0 / windowMs;
    // Oscillate wrap width so layout+paint stay hot every frame.
    final width =
        260 + 100 * (1 - ((elapsed.inMilliseconds % 2000) / 1000 - 1).abs());
    setState(() {
      _fps = fps;
      _cardWidth = width;
    });
  }

  @override
  void dispose() {
    _stopStress();
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    _linkLeft.dispose();
    _linkRight.dispose();
    _mentionLeft.dispose();
    _mentionRight.dispose();
    _threadLeft.dispose();
    _threadRight.dispose();
    _urlLeft.dispose();
    _urlRight.dispose();
    _jobLeft.dispose();
    _jobRight.dispose();
    _scroll.dispose();
    _zoom.dispose();
    super.dispose();
  }

  Widget _pair(
    String caption,
    Widget Function(bool gputext) builder, {
    Color? background,
  }) {
    Widget cell(String title, Widget child) => Expanded(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: Colors.black45),
            ),
            const SizedBox(height: 4),
            if (background == null)
              child
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: child,
              ),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Text(caption, style: Theme.of(context).textTheme.titleSmall),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cell('RichText', builder(false)),
            cell('GPURichText', builder(true)),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE9E3D5),
      appBar: AppBar(
        title: const Text('RichText vs GPURichText'),
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final t in _tabs) Tab(text: t)],
        ),
      ),
      // Only the active tab is mounted — keeps FPS measurements clean.
      body: KeyedSubtree(
        key: ValueKey(_tab.index),
        child: _tabBody(_tabs[_tab.index]),
      ),
    );
  }

  Widget _tabBody(String name) => switch (name) {
    'Basics' => _basicsTab(),
    'Feed' => _feedTab(),
    'Align' => _scrollWrap([
      _pair(
        'Alignment stress: every PlaceholderAlignment + adjacent + 1x1',
        (gputext) => gputext
            ? GPURichText(text: _alignmentStressSpan())
            : RichText(text: _alignmentStressSpan()),
      ),
    ]),
    'Release' => _scrollWrap([
      _pair('Release note: mixed scripts, URL, footnotes, justified', (
        gputext,
      ) {
        final span = _releaseNoteSpan(gputext ? _urlRight : _urlLeft);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            gputext
                ? GPURichText(text: span, textAlign: TextAlign.justify)
                : RichText(text: span, textAlign: TextAlign.justify),
            Text(
              'url taps: $_urlTaps',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: Colors.black45),
            ),
          ],
        );
      }),
    ]),
    'CI' => _scrollWrap([
      _pair('CI thread: tap status pill / retry to mutate WidgetSpans', (
        gputext,
      ) {
        final span = _ciThreadSpan(
          status: _ciFailed ? 'failed' : 'passed',
          statusColor: _ciFailed ? _accentRed : const Color(0xFF2E7D32),
          retries: _ciRetries,
          onToggleStatus: () => setState(() => _ciFailed = !_ciFailed),
          onRetry: () => setState(() {
            _ciRetries++;
            _ciFailed = false;
          }),
          jobLink: gputext ? _jobRight : _jobLeft,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            gputext ? GPURichText(text: span) : RichText(text: span),
            Text(
              'job taps: $_jobTaps',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: Colors.black45),
            ),
          ],
        );
      }),
    ]),
    'Quote' => _scrollWrap([
      _pair(
        'Nested quote WidgetSpan (rich paragraph inside a card)',
        (gputext) => gputext
            ? GPURichText(text: _nestedQuoteSpan())
            : RichText(text: _nestedQuoteSpan()),
      ),
    ]),
    'Zoom' => _zoomTab(),
    'Stress' => _stressTab(),
    _ => const SizedBox.shrink(),
  };

  Widget _scrollWrap(List<Widget> children) =>
      ListView(padding: const EdgeInsets.only(bottom: 24), children: children);

  Widget _basicsTab() => ListView(
    controller: _scroll,
    children: [
      _pair(
        'Mixed-style paragraph, word wrap',
        (gputext) => gputext
            ? GPURichText(text: _sampleSpan())
            : RichText(text: _sampleSpan()),
      ),
      _pair(
        'maxLines: 2, overflow: ellipsis, center-aligned',
        (gputext) => gputext
            ? GPURichText(
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
        (gputext) => gputext
            ? GPURichText(text: _widgetSpanSample())
            : RichText(text: _widgetSpanSample()),
      ),
      _pair(
        'Emoji: clusters, tones, flags, ZWJ, keycaps',
        (gputext) => gputext
            ? GPURichText(text: _emojiSample())
            : RichText(text: _emojiSample()),
      ),
      _pair(
        'Font fallback: native (wide TTF) + platform delegation (SMP)',
        (gputext) => gputext
            ? GPURichText(text: _fallbackSample())
            : RichText(text: _fallbackSample()),
      ),
      _pair(
        'Decorations, justify, wordSpacing, height',
        (gputext) => gputext
            ? GPURichText(
                text: _decorationSample(),
                textAlign: TextAlign.justify,
              )
            : RichText(text: _decorationSample(), textAlign: TextAlign.justify),
      ),
      _pair(
        'Dark mode: premultiplied compositing on a dark surface',
        background: _darkSurface,
        (gputext) => gputext
            ? GPURichText(text: _darkSample())
            : RichText(text: _darkSample()),
      ),
      _pair(
        'Links: TextSpan.recognizer (tap to count)',
        (gputext) => gputext
            ? GPURichText(text: _linkSample(_linkRight, _rightTaps))
            : RichText(text: _linkSample(_linkLeft, _leftTaps)),
      ),
      _pair(
        'GPOS kerning + fi/fl/ffi/ffl ligatures',
        (gputext) => gputext
            ? GPURichText(text: _kernLigaSample())
            : RichText(text: _kernLigaSample()),
      ),
      _pair(
        'backgroundColor, shadows, foreground paint',
        (gputext) => gputext
            ? GPURichText(text: _paintSample())
            : RichText(text: _paintSample()),
      ),
      _pair('StrutStyle (28px floor under 13px text) + TextOverflow.fade', (
        gputext,
      ) {
        const strut = StrutStyle(fontFamily: 'Lato', fontSize: 28);
        final fade = SizedBox(
          width: 280,
          height: 22,
          child: gputext
              ? GPURichText(
                  text: _fadeSample(),
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  maxLines: 1,
                )
              : RichText(
                  text: _fadeSample(),
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  maxLines: 1,
                ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            gputext
                ? GPURichText(text: _strutSample(), strutStyle: strut)
                : RichText(text: _strutSample(), strutStyle: strut),
            const SizedBox(height: 8),
            fade,
          ],
        );
      }),
      _pair(
        'SelectionArea: drag to select, double-click a word, ⌘A',
        (gputext) => SelectionArea(
          child: gputext
              ? GPURichText(text: _paintSample())
              : Text.rich(_paintSample()),
        ),
      ),
      _pair(
        'CJK + hyphen line breaking (narrow column, no spaces)',
        (gputext) => Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 340,
            child: gputext
                ? GPURichText(text: _cjkWrapSample())
                : RichText(text: _cjkWrapSample()),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        child: Text(
          'Layout cache: '
          // ignore: invalid_use_of_visible_for_testing_member
          '${GPUText.instance.debugLayoutCacheHits} hits / '
          // ignore: invalid_use_of_visible_for_testing_member
          '${GPUText.instance.debugLayoutCacheMisses} misses '
          '(identical paragraphs share one flatten+break)',
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: Colors.black45),
        ),
      ),
    ],
  );

  Widget _feedTab() => ListView(
    children: [
      _pair('Complex feed item: avatar, @mention, badges, reactions, thumb', (
        gputext,
      ) {
        final span = _feedItemSpan(
          mention: gputext ? _mentionRight : _mentionLeft,
          thread: gputext ? _threadRight : _threadLeft,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            gputext ? GPURichText(text: span) : RichText(text: span),
            const SizedBox(height: 4),
            Text(
              'taps — mention: $_mentionTaps · thread: $_threadTaps',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: Colors.black45),
            ),
          ],
        );
      }),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Text(
          'Reflow card: drag width — feed item wraps around widgets',
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Text(
              '${_cardWidth.round()}px',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: Colors.black45),
            ),
            Expanded(
              child: Slider(
                value: _cardWidth.clamp(200, 420),
                min: 200,
                max: 420,
                onChanged: (v) => setState(() => _cardWidth = v),
              ),
            ),
          ],
        ),
      ),
      _pair('Feed item at live wrap width', (gputext) {
        final span = _feedItemSpan(
          mention: gputext ? _mentionRight : _mentionLeft,
          thread: gputext ? _threadRight : _threadLeft,
        );
        return Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _cardWidth.clamp(200, 420),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black26),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: gputext ? GPURichText(text: span) : RichText(text: span),
              ),
            ),
          ),
        );
      }),
    ],
  );

  Widget _zoomTab() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Text('Pinch/scroll to zoom — gputext re-renders crisp'),
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
                      child: GPURichText(text: _sampleSpan(), scaleHint: _zoom),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );

  /// Continuous reflow of N complex feed rows — isolate one engine, read FPS.
  Widget _stressTab() {
    final span = _feedItemSpan(mention: _mentionRight, thread: _threadRight);
    final width = _cardWidth.clamp(200.0, 420.0);
    Widget text() =>
        _stressEngine ? GPURichText(text: span) : RichText(text: span);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: _darkSurface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              children: [
                Row(
                  children: [
                    Text(
                      '${_fps.toStringAsFixed(1)} fps',
                      style: const TextStyle(
                        fontFamily: 'Lato',
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: _darkAmber,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      'tick $_stressTick · ${width.round()}px · '
                      '${_stressEngine ? 'GPURichText' : 'RichText'}',
                      style: const TextStyle(
                        fontFamily: 'Lato',
                        fontSize: 13,
                        color: _paper,
                      ),
                    ),
                  ],
                ),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('GPU')),
                    ButtonSegment(value: false, label: Text('Flutter')),
                  ],
                  selected: {_stressEngine},
                  onSelectionChanged: (s) =>
                      setState(() => _stressEngine = s.first),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (var i = 0; i < 12; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black26),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: text(),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
