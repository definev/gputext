// Showcase of the text-rendering features added in the July 2026 pass:
//
//   1. Automatic hyphenation (Liang / TeX patterns) — a justified column with
//      and without it, side by side; the hyphenated column shows visible '-'
//      and tighter, river-free spacing.
//   2. Multi-codepoint emoji on the GPU — ZWJ families, flags, skin-tone
//      modifiers, and keycaps ligate to one color glyph and render through the
//      coverage/COLR pipeline (no platform-Text delegation).
//   3. OpenType-PostScript (CFF) fonts — Source Sans 3 (an OTTO/CFF face)
//      renders via HarfBuzz's draw API, which also unlocks CFF2 and CID fonts.
//
// Dev hook: GPUTEXT_DEMO=features opens this page.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gputext/gputext.dart';

// A curated en-US hyphenation exception list (word → syllable breaks). Real
// apps load full `hyph-en-us` Liang patterns; here we spell the demo paragraph's
// longer words so the output is exact and self-contained.
const _hyphenExceptions =
    'au-to-mat-ic hy-phen-ation dra-mat-i-cally ty-po-graph-ic jus-ti-fied '
    'op-ti-mi-za-tion al-go-rithm com-bi-na-tion pos-si-ble ex-ag-ger-at-ed '
    'spac-ing dis-tract-ing riv-ers con-sis-tent ap-plied par-tic-u-lar-ly '
    'nar-row col-umns tex-ture com-fort-able com-pre-hen-sion eval-u-ates '
    'pre-vents lon-ger im-proves pro-duces in-ter-word ex-ag-ger-ates '
    'read-abil-i-ty par-a-graph';

const _hyphenBody =
    'Automatic hyphenation dramatically improves the typographic colour of a '
    'justified paragraph. The optimization algorithm evaluates the combination '
    'of possible breaks, and hyphenation of longer words prevents the '
    'exaggerated inter-word spacing that produces distracting rivers. '
    'Consistent hyphenation, applied particularly in narrow columns, keeps the '
    'typographic texture even and comfortable, improving readability and '
    'comprehension.';

const _cffBody =
    'This paragraph is set in Source Sans 3, an OpenType-PostScript (CFF) '
    'typeface. Its outlines are cubic Béziers in a Type2 charstring table — a '
    'format gputext could not render before. HarfBuzz’s draw API now extracts '
    'them (and CFF2 and CID-keyed faces) through one code path shared with '
    'TrueType.';

class FeaturesDemoPage extends StatefulWidget {
  const FeaturesDemoPage({super.key});

  @override
  State<FeaturesDemoPage> createState() => _FeaturesDemoPageState();
}

class _FeaturesDemoPageState extends State<FeaturesDemoPage> {
  final _engine = GPUText.instance;
  bool _ready = false;
  String? _error;

  // Opt-in automatic hyphenation, wired through GPURichText.lineBreak.
  final _hyphenation = LineBreakConfig(
    hyphenator: PatternHyphenator.fromStrings(
      '',
      exceptions: _hyphenExceptions,
    ),
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _engine.ensureInitialized();
      // COLR emoji font so ZWJ sequences / flags / skin tones render on the GPU.
      final emoji = _engine.emojiFont;
      if (emoji == null || emoji.hasBitmapGlyphs) {
        final tw = await rootBundle.load('assets/TwemojiMozilla.ttf');
        _engine.registerEmojiFont(GPUFont.parse(tw.buffer.asUint8List()));
      }
      // A CFF (OTTO) face, rendered through HarfBuzz's draw API.
      final cff = await rootBundle.load('assets/SourceSans3-Regular.otf');
      _engine.registerFont(
        'SourceSans3',
        GPUFont.parse(cff.buffer.asUint8List()),
      );
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F8),
      appBar: AppBar(
        title: const GPULabel('New features'),
        backgroundColor: const Color(0xFF1D1D1F),
        foregroundColor: Colors.white,
      ),
      body: _error != null
          ? Center(
              child: GPULabel(
                _error!,
                style: const TextStyle(color: Colors.red),
              ),
            )
          : !_ready
          ? const Center(child: CircularProgressIndicator())
          // No page-wide SelectionArea: it trips GPURichText debug asserts
          // (see the cursed demo) — the showcase doesn't need selection.
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              children: [
                _section(
                  'Automatic hyphenation',
                  'Liang / TeX pattern hyphenation, opt-in via '
                      'GPURichText.lineBreak. The right column breaks long '
                      'words at syllable boundaries (rendering a real “-”), '
                      'killing the wide inter-word gaps — “rivers” — on the '
                      'left.',
                  _hyphenationSection(),
                ),
                _section(
                  'Multi-codepoint emoji on the GPU',
                  'ZWJ families, regional-indicator flags, skin-tone '
                      'modifiers, and keycap sequences ligate to a single '
                      'color glyph and render through the coverage / COLR '
                      'pipeline — no delegation to platform Text.',
                  _emojiSection(),
                ),
                _section(
                  'OpenType-PostScript (CFF) fonts',
                  'CFF, CFF2, and CID-keyed outlines now render via '
                      'HarfBuzz’s hb_font_draw_glyph, one path shared with '
                      'TrueType.',
                  _cffSection(),
                ),
                _section(
                  'Also new (behind the scenes)',
                  'Not every fix is a spectacle:',
                  _behindTheScenes(),
                ),
                const SizedBox(height: 40),
              ],
            ),
    );
  }

  Widget _section(String title, String blurb, Widget body) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GPULabel(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1D1D1F),
          ),
        ),
        const SizedBox(height: 6),
        GPULabel(
          blurb,
          style: const TextStyle(fontSize: 13, color: Color(0xFF6E6E73)),
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E5EA)),
          ),
          child: body,
        ),
      ],
    ),
  );

  Widget _hyphenationSection() {
    Widget column(String label, LineBreakConfig? config) => SizedBox(
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GPULabel(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF8E8E93),
            ),
          ),
          const SizedBox(height: 8),
          GPURichText(
            textAlign: TextAlign.justify,
            lineBreak: config,
            text: const TextSpan(
              text: _hyphenBody,
              style: TextStyle(
                fontFamily: 'Lato',
                fontSize: 15,
                height: 1.4,
                color: Color(0xFF1D1D1F),
              ),
            ),
          ),
        ],
      ),
    );

    return Wrap(
      spacing: 32,
      runSpacing: 20,
      children: [
        column('Justified, no hyphenation', null),
        column('Justified + Liang hyphenation', _hyphenation),
      ],
    );
  }

  Widget _emojiSection() {
    const style = TextStyle(
      fontFamily: 'Lato',
      fontSize: 40,
      color: Color(0xFF1D1D1F),
    );
    Widget row(String label, String emoji) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 150,
            child: GPULabel(
              label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF6E6E73)),
            ),
          ),
          GPURichText(
            text: TextSpan(text: emoji, style: style),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('ZWJ family', '👨‍👩‍👧‍👦 👩‍👩‍👦 👨‍👧'),
        row('Flags (RI pairs)', '🇻🇳 🇯🇵 🇺🇸 🇧🇷'),
        row('Skin-tone', '👍🏻 👍🏽 👍🏿 🙋🏾‍♀️'),
        row('Keycaps', '1️⃣ 2️⃣ #️⃣ *️⃣'),
      ],
    );
  }

  Widget _cffSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: const [
      GPURichText(
        text: TextSpan(
          text: 'Source Sans 3 · CFF outlines',
          style: TextStyle(
            fontFamily: 'SourceSans3',
            fontSize: 30,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1D1D1F),
          ),
        ),
      ),
      SizedBox(height: 12),
      GPURichText(
        text: TextSpan(
          text: _cffBody,
          style: TextStyle(
            fontFamily: 'SourceSans3',
            fontSize: 16,
            height: 1.45,
            color: Color(0xFF1D1D1F),
          ),
        ),
      ),
    ],
  );

  Widget _behindTheScenes() {
    const items = [
      'COLR v1 — flat (PaintColrLayers→PaintGlyph→PaintSolid) glyphs render; '
          'gradients delegate.',
      'Long-paragraph surface tiling — paragraphs taller than 8192 device px '
          'render crisp at full DPR instead of being scaled down (blurred).',
      'Cluster-safe font fallback — a combining mark stays in its base’s font, '
          'so accents no longer detach across a fallback boundary.',
      'UAX #14 fix — ZWJ / bidi controls no longer spawn spurious line breaks.',
      'Thai / Lao / Khmer segmentation — pluggable TextSegmenter enables '
          'word-boundary wrapping for space-less scripts.',
      'Variable-font atlas eviction — LRU-evicted instances release their '
          'atlas glyph bands (batched, storm-free).',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final t in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const GPULabel(
                  '•  ',
                  style: TextStyle(color: Color(0xFF6E6E73)),
                ),
                Expanded(
                  child: GPULabel(
                    t,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF3A3A3C),
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
