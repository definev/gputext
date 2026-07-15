// Real usage of GPUTextView with the layout-parity knobs (align, maxLines,
// ellipsis, softWrap, Knuth–Plass, strut, per-run height, locale, wrap width)
// plus decorations, backgrounds, hit-testing, and color emoji (COLR Twemoji,
// Apple Color Emoji sbix, or Noto CBDT via the isolate bitmap path). Swap the
// document to reflow; same id keeps the prepare cache warm. Dev hook:
// GPUTEXT_DEMO=view.
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gputext/lowlevel.dart' as ll;
import 'package:gputext/lowlevel.dart' hide TextAlign, TextDirection;

/// Which emoji font [GPUTextDocument.emojiFontId] points at.
enum _EmojiMode {
  /// No emoji font — clusters stay in the Latin run (tofu / missing glyphs).
  none,

  /// TwemojiMozilla COLR — coloured coverage layers on the worker.
  colr,

  /// Apple Color Emoji (system sbix) — PNG stubs → main-isolate color atlas.
  apple,

  /// Bundled Noto Color Emoji (CBDT) — same bitmap path as [apple].
  noto,
}

class GPUTextViewDemoPage extends StatefulWidget {
  const GPUTextViewDemoPage({super.key});

  @override
  State<GPUTextViewDemoPage> createState() => _GPUTextViewDemoPageState();
}

class _GPUTextViewDemoPageState extends State<GPUTextViewDemoPage> {
  GPUTextViewController? _controller;
  GPUTextDocument? _doc;
  String? _error;
  final ValueNotifier<GPUTextMetrics?> _metrics = ValueNotifier(null);
  final ValueNotifier<String> _tapLog = ValueNotifier('');
  final ScrollController _shrinkScroll = ScrollController();
  int _linkTaps = 0;
  late final TapGestureRecognizer _linkTap = TapGestureRecognizer()
    ..onTap = () {
      _linkTaps++;
      _tapLog.value = 'link tapped ($_linkTaps)';
    };

  // Layout knobs — rebuild [GPUTextDocument] (same id) so the view reflows
  // without re-shaping.
  TextAlign _align = TextAlign.left;
  double _lineHeight = 1.5;
  double _width = 560;
  int? _maxLines;
  bool _ellipsis = false;
  bool _softWrap = true;
  bool _knuthPlass = false;
  bool _forceStrut = false;
  GPUTextWidthBasis _widthBasis = GPUTextWidthBasis.parent;
  bool _shrinkWrap = false;
  _EmojiMode _emojiMode = _EmojiMode.none;
  bool _hasColr = false;
  bool _hasApple = false;
  bool _hasNoto = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final controller = await GPUTextViewController.spawn();
      final lato = (await rootBundle.load('assets/Lato-Regular.ttf')).buffer
          .asUint8List();
      await controller.registerFont('lato', Uint8List.fromList(lato));

      // COLR Twemoji + bitmap faces (Apple sbix via system resolver, bundled
      // Noto CBDT). The control below picks which id [emojiFontId] uses.
      // Copy bytes: registerFont transfers (neuters) the caller's list.
      var hasColr = false;
      var hasApple = false;
      var hasNoto = false;
      try {
        final tw = (await rootBundle.load('assets/TwemojiMozilla.ttf')).buffer
            .asUint8List();
        await controller.registerFont('emoji-colr', Uint8List.fromList(tw));
        hasColr = true;
      } catch (_) {
        /* optional */
      }

      final appleBytes = _tryLoadAppleColorEmoji();
      if (appleBytes != null) {
        try {
          await controller.registerFont(
            'emoji-apple',
            Uint8List.fromList(appleBytes),
          );
          hasApple = true;
        } catch (_) {
          /* unparseable face */
        }
      }

      try {
        final noto = (await rootBundle.load('assets/NotoColorEmoji.ttf')).buffer
            .asUint8List();
        await controller.registerFont('emoji-noto', Uint8List.fromList(noto));
        hasNoto = true;
      } catch (_) {
        /* optional */
      }

      if (!mounted) {
        controller.dispose();
        return;
      }
      // Prefer Apple Color Emoji on macOS/iOS; else Noto; else COLR.
      final preferred = hasApple
          ? _EmojiMode.apple
          : hasNoto
          ? _EmojiMode.noto
          : hasColr
          ? _EmojiMode.colr
          : _EmojiMode.none;
      setState(() {
        _controller = controller;
        _hasColr = hasColr;
        _hasApple = hasApple;
        _hasNoto = hasNoto;
        _emojiMode = preferred;
        _doc = _buildDoc();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Resolve Apple Color Emoji (sbix) via CoreText SFNT reconstruction.
  /// Null when the system-font backend is unavailable or the face has no
  /// color-bitmap strikes.
  static Uint8List? _tryLoadAppleColorEmoji() {
    final provider = SystemFontProvider.tryLoad();
    if (provider == null) return null;
    final bytes = provider.fontData('Apple Color Emoji');
    if (bytes == null) return null;
    try {
      final font = GPUFont.parse(bytes);
      if (!font.hasBitmapGlyphs) return null;
      // Re-fetch: parse may share the buffer; registerFont needs owned bytes.
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  void _applyKnobs(VoidCallback mutate) {
    setState(() {
      mutate();
      _doc = _buildDoc();
    });
  }

  String? get _emojiFontId => switch (_emojiMode) {
    _EmojiMode.none => null,
    _EmojiMode.colr => 'emoji-colr',
    _EmojiMode.apple => 'emoji-apple',
    _EmojiMode.noto => 'emoji-noto',
  };

  /// Build a fresh document reflecting the current layout knobs. Same [id]
  /// ⇒ prepare cache stays warm; only reflow re-runs. Emoji mode is part of
  /// the id so switching COLR ↔ bitmap re-prepares (emoji font is baked in).
  GPUTextDocument _buildDoc() {
    final strut = _forceStrut
        ? const StrutMetrics(ascent: 18, descent: 6, leading: 0, force: true)
        : null;
    final emojiLabel = switch (_emojiMode) {
      _EmojiMode.none => 'no emoji font (tofu)',
      _EmojiMode.colr => 'COLR Twemoji (coverage layers)',
      _EmojiMode.apple => 'Apple Color Emoji sbix (color atlas)',
      _EmojiMode.noto => 'Noto Color Emoji CBDT (color atlas)',
    };
    return GPUTextDocument.rich(
      'view-demo-${_emojiMode.name}',
      TextSpan(
        style: const TextStyle(fontSize: 18, color: Color(0xFF1D2027)),
        children: [
          const TextSpan(
            text:
                'GPUTextView lays this out on a background isolate. Toggle '
                'the controls below — align, maxLines/ellipsis, softWrap, '
                'Knuth–Plass, strut — and it reflows off the UI thread. Inline ',
          ),
          const GPUWidgetSpan(child: _Chip(), size: Size(58, 32)),
          const TextSpan(
            text: ' widgets stay composited over the GPU glyphs.\n\n',
          ),
          TextSpan(
            text: 'Color emoji ($emojiLabel):\n',
            style: const TextStyle(fontSize: 15, color: Color(0xFF5B5F6A)),
          ),
          // Single-CP emoji work on both COLR and CBDT paths. Digits stay Latin
          // (Noto covers 0–9 as keycap bases but must not hijack plain text).
          const TextSpan(
            text: '😀 🎉 🚀 🌈 🍕 🐶 ⭐ ❤ 🔥 🎨   digits OK: 0123456789\n\n',
            style: TextStyle(fontSize: 28, height: 1.35),
          ),
          // Background highlight + underline (painted under the glyphs).
          const TextSpan(
            text: 'Highlighted with underline',
            style: TextStyle(
              backgroundColor: Color(0xFFFFF3B0),
              decoration: TextDecoration.underline,
              decorationColor: Color(0xFFB45309),
              decorationThickness: 1.5,
            ),
          ),
          const TextSpan(text: ' and '),
          // lineThrough paints over the glyphs.
          const TextSpan(
            text: 'struck-through',
            style: TextStyle(
              decoration: TextDecoration.lineThrough,
              decorationColor: Color(0xFFB91C1C),
            ),
          ),
          const TextSpan(text: '. Tap this '),
          TextSpan(
            text: 'link',
            style: const TextStyle(
              color: Color(0xFF1D4ED8),
              decoration: TextDecoration.underline,
              decorationColor: Color(0xFF1D4ED8),
            ),
            recognizer: _linkTap,
          ),
          const TextSpan(
            text: ' — hit-testing maps the tag back to the span.\n\n',
          ),
          // Per-run TextStyle.height + leading — flattenInlineSpan maps these
          // onto GPUTextRunSpec.height / evenLeading.
          const TextSpan(
            text:
                'This span uses height: 2.0 with even leading — the line '
                'box grows without changing the glyph size.\n\n',
            style: TextStyle(
              height: 2.0,
              leadingDistribution: TextLeadingDistribution.even,
              color: Color(0xFF3355DD),
            ),
          ),
          TextSpan(text: _largeBody),
        ],
      ),
      fontIdResolver: (_) => 'lato',
      defaultFontSizePx: 18,
      defaultColor: const [0.11, 0.12, 0.16, 1],
      locale: const Locale('en', 'US'),
      emojiFontId: _emojiFontId,
      style: GPUTextLayoutStyle(
        align: _mapAlign(_align),
        lineHeight: _lineHeight,
        maxLines: _maxLines,
        softWrap: _softWrap,
        addEllipsis: _ellipsis,
        lineBreaker: _knuthPlass ? LineBreaker.knuthPlass : LineBreaker.greedy,
        strut: strut,
        textWidthBasis: _widthBasis,
      ),
    );
  }

  ll.TextAlign _mapAlign(TextAlign a) => switch (a) {
    TextAlign.left || TextAlign.start => ll.TextAlign.left,
    TextAlign.right || TextAlign.end => ll.TextAlign.right,
    TextAlign.center => ll.TextAlign.center,
    TextAlign.justify => ll.TextAlign.justify,
  };

  @override
  void dispose() {
    _linkTap.dispose();
    _metrics.dispose();
    _tapLog.dispose();
    _shrinkScroll.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final doc = _doc;
    return Scaffold(
      appBar: AppBar(
        title: const Text('GPUTextView — layout + emoji'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: ListenableBuilder(
                listenable: Listenable.merge([_metrics, _tapLog]),
                builder: (context, _) {
                  final m = _metrics.value;
                  if (m == null) return const SizedBox.shrink();
                  final tap = _tapLog.value;
                  return Text(
                    '${m.glyphCount} glyphs · ${m.lineCount} '
                    'lines · '
                    '${m.size.height.toStringAsFixed(0)} px tall · '
                    'reflow ${m.reflowMs.toStringAsFixed(1)} ms'
                    '${tap.isEmpty ? '' : ' · $tap'}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  );
                },
              ),
            ),
          ),
        ),
      ),
      body: _error != null
          ? Center(child: Text('Failed: $_error'))
          : controller == null || doc == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _Controls(
                  align: _align,
                  lineHeight: _lineHeight,
                  width: _width,
                  maxLines: _maxLines,
                  ellipsis: _ellipsis,
                  softWrap: _softWrap,
                  knuthPlass: _knuthPlass,
                  forceStrut: _forceStrut,
                  widthBasis: _widthBasis,
                  shrinkWrap: _shrinkWrap,
                  emojiMode: _emojiMode,
                  hasColr: _hasColr,
                  hasApple: _hasApple,
                  hasNoto: _hasNoto,
                  onAlign: (v) => _applyKnobs(() => _align = v),
                  onLineHeight: (v) => _applyKnobs(() => _lineHeight = v),
                  onWidth: (v) => setState(() => _width = v),
                  onMaxLines: (v) => _applyKnobs(() => _maxLines = v),
                  onEllipsis: (v) => _applyKnobs(() => _ellipsis = v),
                  onSoftWrap: (v) => _applyKnobs(() {
                    _softWrap = v;
                    // softWrap:false + ellipsis truncates; turn ellipsis
                    // off so overflow can scroll horizontally instead.
                    if (!v) _ellipsis = false;
                  }),
                  onKnuthPlass: (v) => _applyKnobs(() {
                    _knuthPlass = v;
                    if (v) _align = TextAlign.justify;
                  }),
                  onForceStrut: (v) => _applyKnobs(() => _forceStrut = v),
                  onWidthBasis: (v) => _applyKnobs(() => _widthBasis = v),
                  onShrinkWrap: (v) => setState(() => _shrinkWrap = v),
                  onEmojiMode: (v) => _applyKnobs(() => _emojiMode = v),
                ),
                Expanded(
                  child: Container(
                    color: const Color(0xFFF3F1EC),
                    alignment: Alignment.topCenter,
                    child: _shrinkWrap
                        ? CustomScrollView(
                            controller: _shrinkScroll,
                            // One tall SliverToBoxAdapter — not ListView +
                            // Center. Nested Center/ListView around a
                            // multi-hundred-thousand-px child fights the
                            // platform scrollbar and desyncs the GPU window.
                            slivers: [
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 24,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: Align(
                                    alignment: Alignment.topCenter,
                                    child: SizedBox(
                                      width: _width,
                                      child: Material(
                                        elevation: 2,
                                        color: Colors.white,
                                        child: GPUTextView(
                                          controller: controller,
                                          document: doc,
                                          shrinkWrap: true,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 28,
                                            vertical: 24,
                                          ),
                                          onMetrics: (m) {
                                            _metrics.value = m;
                                          },
                                          onSpanTap: (tag, span) {
                                            if (span?.recognizer != null) {
                                              return;
                                            }
                                            _tapLog.value = 'onSpanTap($tag)';
                                          },
                                          fallbackBuilder: (context) =>
                                              const Center(
                                                child: Padding(
                                                  padding: EdgeInsets.all(24),
                                                  child: Text(
                                                    'GPU rendering needs Impeller + flutter_gpu.',
                                                    style: TextStyle(
                                                      color: Colors.black54,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.only(bottom: 24),
                                  child: Center(
                                    child: Text(
                                      '↑ shrinkWrap · card hugs content height',
                                      style: TextStyle(
                                        color: Colors.black45,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Material(
                            elevation: 2,
                            color: Colors.white,
                            child: SizedBox(
                              width: _width,
                              child: GPUTextView(
                                controller: controller,
                                document: doc,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 28,
                                  vertical: 24,
                                ),
                                onMetrics: (m) {
                                  _metrics.value = m;
                                },
                                onSpanTap: (tag, span) {
                                  // Recognizer taps already update _tapLog.
                                  if (span?.recognizer != null) return;
                                  _tapLog.value = 'onSpanTap($tag)';
                                },
                                fallbackBuilder: (context) => const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text(
                                      'GPU rendering needs Impeller + flutter_gpu.',
                                      style: TextStyle(color: Colors.black54),
                                    ),
                                  ),
                                ),
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

class _Controls extends StatelessWidget {
  const _Controls({
    required this.align,
    required this.lineHeight,
    required this.width,
    required this.maxLines,
    required this.ellipsis,
    required this.softWrap,
    required this.knuthPlass,
    required this.forceStrut,
    required this.widthBasis,
    required this.shrinkWrap,
    required this.emojiMode,
    required this.hasColr,
    required this.hasApple,
    required this.hasNoto,
    required this.onAlign,
    required this.onLineHeight,
    required this.onWidth,
    required this.onMaxLines,
    required this.onEllipsis,
    required this.onSoftWrap,
    required this.onKnuthPlass,
    required this.onForceStrut,
    required this.onWidthBasis,
    required this.onShrinkWrap,
    required this.onEmojiMode,
  });

  final TextAlign align;
  final double lineHeight;
  final double width;
  final int? maxLines;
  final bool ellipsis;
  final bool softWrap;
  final bool knuthPlass;
  final bool forceStrut;
  final GPUTextWidthBasis widthBasis;
  final bool shrinkWrap;
  final _EmojiMode emojiMode;
  final bool hasColr;
  final bool hasApple;
  final bool hasNoto;
  final ValueChanged<TextAlign> onAlign;
  final ValueChanged<double> onLineHeight;
  final ValueChanged<double> onWidth;
  final ValueChanged<int?> onMaxLines;
  final ValueChanged<bool> onEllipsis;
  final ValueChanged<bool> onSoftWrap;
  final ValueChanged<bool> onKnuthPlass;
  final ValueChanged<bool> onForceStrut;
  final ValueChanged<GPUTextWidthBasis> onWidthBasis;
  final ValueChanged<bool> onShrinkWrap;
  final ValueChanged<_EmojiMode> onEmojiMode;

  @override
  Widget build(BuildContext context) {
    final emojiSegments = <ButtonSegment<_EmojiMode>>[
      const ButtonSegment(value: _EmojiMode.none, label: Text('emoji: off')),
      if (hasColr)
        const ButtonSegment(value: _EmojiMode.colr, label: Text('COLR')),
      if (hasApple)
        const ButtonSegment(value: _EmojiMode.apple, label: Text('Apple')),
      if (hasNoto)
        const ButtonSegment(value: _EmojiMode.noto, label: Text('Noto')),
    ];
    return Material(
      color: const Color(0xFFECEAE4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<TextAlign>(
              segments: const [
                ButtonSegment(value: TextAlign.left, label: Text('Left')),
                ButtonSegment(value: TextAlign.center, label: Text('Center')),
                ButtonSegment(value: TextAlign.right, label: Text('Right')),
                ButtonSegment(value: TextAlign.justify, label: Text('Justify')),
              ],
              selected: {align},
              onSelectionChanged: (s) => onAlign(s.first),
            ),
            if (emojiSegments.length > 1)
              SegmentedButton<_EmojiMode>(
                segments: emojiSegments,
                selected: {emojiMode},
                onSelectionChanged: (s) => onEmojiMode(s.first),
              ),
            FilterChip(
              label: const Text('softWrap'),
              selected: softWrap,
              onSelected: onSoftWrap,
            ),
            FilterChip(
              label: const Text('shrinkWrap'),
              selected: shrinkWrap,
              onSelected: onShrinkWrap,
            ),
            FilterChip(
              label: const Text('ellipsis'),
              selected: ellipsis,
              onSelected: onEllipsis,
            ),
            FilterChip(
              label: Text(
                maxLines == null ? 'maxLines: ∞' : 'maxLines: $maxLines',
              ),
              selected: maxLines != null,
              onSelected: (on) => onMaxLines(on ? 4 : null),
            ),
            FilterChip(
              label: const Text('Knuth–Plass'),
              selected: knuthPlass,
              onSelected: onKnuthPlass,
            ),
            FilterChip(
              label: const Text('force strut'),
              selected: forceStrut,
              onSelected: onForceStrut,
            ),
            DropdownButton<GPUTextWidthBasis>(
              value: widthBasis,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(
                  value: GPUTextWidthBasis.parent,
                  child: Text('width: parent'),
                ),
                DropdownMenuItem(
                  value: GPUTextWidthBasis.longestLine,
                  child: Text('width: longestLine'),
                ),
                DropdownMenuItem(
                  value: GPUTextWidthBasis.intrinsic,
                  child: Text('width: intrinsic'),
                ),
              ],
              onChanged: (v) {
                if (v != null) onWidthBasis(v);
              },
            ),
            SizedBox(
              width: 180,
              child: Row(
                children: [
                  const Text('lh', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: lineHeight,
                      min: 1.0,
                      max: 2.4,
                      divisions: 14,
                      label: lineHeight.toStringAsFixed(1),
                      onChanged: onLineHeight,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 220,
              child: Row(
                children: [
                  Text(
                    'w ${width.round()}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Expanded(
                    child: Slider(
                      value: width,
                      min: 200,
                      max: 900,
                      divisions: 70,
                      label: '${width.round()} px',
                      onChanged: onWidth,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The inline widget carried by the GPUWidgetSpan. Self-sizing (padding around
/// its text), so the view can measure its natural size for the reserved box.
class _Chip extends StatelessWidget {
  const _Chip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF3355DD),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Center(
        child: const Text(
          'chips',
          style: TextStyle(color: Colors.white, fontSize: 13),
        ),
      ),
    );
  }
}

const _lineSeed =
    'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod '
    'tempor incididunt ut labore et dolore magna aliqua.';

/// ~20k hard-broken lines for virtualization / scroll stress. Built once so
/// knob rebuilds do not re-allocate the string.
final String _largeBody = () {
  const lineCount = 20000;
  final buf = StringBuffer();
  buf.writeln(
    '--- $lineCount-line stress body (GPUTextView virtualizes the viewport) ---\n',
  );
  for (var i = 1; i <= lineCount; i++) {
    buf
      ..write('L')
      ..write(i)
      ..write('  ')
      ..writeln(_lineSeed);
  }
  return buf.toString();
}();
