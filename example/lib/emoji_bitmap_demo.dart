// Color-bitmap emoji demo: renders sbix / CBDT (raster PNG) emoji through the
// GPU color pipeline, next to Flutter's native Text for comparison. Showcases
// the DPR-aware strike selection + mipmapped color atlas — the same emoji drawn
// small and large stays crisp because each size resolves the best strike and
// minified draws sample down the mip chain.
//
// Prefers the OS emoji font via the system-font resolver (Apple Color Emoji on
// macOS/iOS — sbix, reconstructed in-memory by CoreText). Falls back to the
// bundled Noto Color Emoji (CBDT) when the resolver is unavailable or the OS
// face has no color-bitmap strikes.
//
// Launch:  GPUTEXT_DEMO=emoji fvm flutter run \
//            --enable-impeller --enable-flutter-gpu -d macos

import 'package:flutter/material.dart';
import 'package:gputext/gputext.dart';

const _ink = Color(0xFF12151F);
const _paper = Color(0xFFF3F0E9);
const _accent = Color(0xFF14508C);
const _muted = Color(0xFF6B6458);
const _card = Color(0xFFFBF8F1);

// Single-code-point emoji route to the GPU bitmap path; multi-CP ZWJ sequences
// and flags still delegate to platform Text (a documented follow-on), so this
// demo stays on single-glyph emoji to show the raster path.
const _sizes = <double>[14, 20, 32, 56, 96];
const _emoji = '😀 🎉 🚀 🌈 🍕 🐶 ⭐ ❤ 🔥 🎨';

// OS family names to try, in preference order. Apple Color Emoji is the sbix
// face on macOS/iOS; the Noto names cover Android where that face is absent.
const _systemEmojiNames = <String>[
  'Apple Color Emoji',
  'Noto Color Emoji',
  'NotoColorEmoji',
];

class EmojiBitmapDemoPage extends StatefulWidget {
  const EmojiBitmapDemoPage({super.key});

  @override
  State<EmojiBitmapDemoPage> createState() => _EmojiBitmapDemoPageState();
}

class _EmojiBitmapDemoPageState extends State<EmojiBitmapDemoPage> {
  bool _ready = false;
  String? _error;
  String _source = '';

  // The registered emoji font is a process-wide singleton. This is the one page
  // that swaps in a color-bitmap font (which then renders through the GPU color
  // pipeline), so it owns restoring the prior font when it leaves — otherwise
  // every sibling demo (e.g. Sys font, which registers no emoji font of its
  // own) inherits it and shows its emoji. Capture the prior font up front
  // (NON-late so it captures at State construction, before _load swaps a font
  // in) and restore it in dispose.
  final GPUFont? _priorEmojiFont = GPUText.instance.emojiFont;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    GPUText.instance.registerEmojiFont(_priorEmojiFont);
    super.dispose();
  }

  Future<void> _load() async {
    final engine = GPUText.instance;
    try {
      await engine.ensureInitialized();
      if (!mounted) return; // navigated away mid-init: leave the font untouched
      if (engine.emojiFont == null || !engine.emojiFont!.hasBitmapGlyphs) {
        final sys = await _tryLoadSystemEmoji();
        if (!mounted) {
          // Disposed during the async load: dispose already restored the prior
          // font, but we may have just re-registered a new one. Undo it, or
          // the font leaks into the next demo.
          engine.registerEmojiFont(_priorEmojiFont);
          return;
        }
        if (sys != null) {
          engine.registerEmojiFont(sys.font);
          _source = sys.label;
        } else {
          await engine.loadEmojiFontAsset('assets/NotoColorEmoji.ttf');
          if (!mounted) {
            engine.registerEmojiFont(_priorEmojiFont);
            return;
          }
          _source = 'bundled Noto Color Emoji (CBDT)';
        }
      } else {
        _source = 'already registered';
      }
    } catch (e) {
      _error = 'Bitmap emoji font unavailable: $e';
    }
    if (mounted) setState(() => _ready = true);
  }

  /// Resolve an OS emoji face with color-bitmap strikes. Returns null when the
  /// platform has no system-font backend or none of the candidate names yield
  /// an sbix/CBDT font.
  Future<({GPUFont font, String label})?> _tryLoadSystemEmoji() async {
    final provider = SystemFontProvider.tryLoad();
    if (provider == null) return null;
    for (final name in _systemEmojiNames) {
      final bytes = provider.fontData(name);
      if (bytes == null) continue;
      try {
        final font = GPUFont.parse(bytes);
        if (font.hasBitmapGlyphs) {
          return (font: font, label: 'system: $name (sbix/CBDT)');
        }
      } catch (_) {
        // Unparseable / unexpected face — try the next candidate.
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _paper,
      appBar: AppBar(
        title: const Text('Color-bitmap emoji (sbix / CBDT)'),
        backgroundColor: _paper,
        foregroundColor: _ink,
      ),
      body: !_ready
          ? const Center(
              child: Text(
                'Loading color-bitmap emoji font…',
                style: TextStyle(
                  fontFamily: 'Lato',
                  fontSize: 14,
                  color: _muted,
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  if (_source.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Source: $_source',
                        style: const TextStyle(
                          fontFamily: 'Lato',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _accent,
                        ),
                      ),
                    ),
                  const _Legend(),
                  for (final size in _sizes) _SizeRow(size: size),
                  const SizedBox(height: 8),
                  const Text(
                    'GPU rows sample a mipmapped, DPR-aware RGBA8 atlas; REF is '
                    "Flutter's native emoji. Single-CP emoji render on the GPU; "
                    'ZWJ sequences / flags still delegate.',
                    style: TextStyle(
                      fontFamily: 'Lato',
                      fontSize: 12,
                      color: _muted,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    Widget chip(String tag, Color c, String label) => Row(
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
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          children: [
            chip('GPU', _accent, 'gputext color pipeline'),
            const SizedBox(width: 12),
            chip('REF', _muted, "Flutter's native Text"),
          ],
        ),
      ),
    );
  }
}

class _SizeRow extends StatelessWidget {
  const _SizeRow({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final span = TextSpan(
      text: _emoji,
      style: TextStyle(fontFamily: 'Lato', fontSize: size, color: _ink),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _ink.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${size.toStringAsFixed(0)} px',
            style: const TextStyle(
              fontFamily: 'Lato',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _accent,
            ),
          ),
          const SizedBox(height: 8),
          _labeled('GPU', _accent, GPURichText(text: span, softWrap: true)),
          const SizedBox(height: 6),
          _labeled('REF', _muted, Text.rich(span)),
        ],
      ),
    );
  }

  Widget _labeled(String tag, Color c, Widget child) => Row(
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
