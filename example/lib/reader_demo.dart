// Reader: a long-form essay rendered as ONE SliverGPUText document inside a
// single CustomScrollView. The whole article is shaped and laid out once on
// the worker isolate; the sliver hands the outer viewport only the visible
// strip to rasterize each frame, and the scrollbar tracks the true extent.
//
// This is the "honest unit" demo. A markdown chat bubble is a heterogeneous
// tree of tiny blocks — the wrong shape for a worker-isolate view. A whole
// article is the right shape: one homogeneous document, laid out off the UI
// thread exactly once, scrolled by one viewport. Body text is Lato (regular /
// bold / italic real faces, resolved by id — the worker has no variable axes).
//
// Reading chrome: a pinned bar with a live progress bar + reading percentage,
// and the shaping metrics (glyphs / lines / reflow ms) the worker reported.
// Dev hook: GPUTEXT_DEMO=reader.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gputext/lowlevel.dart' hide TextAlign, TextDirection;

// -- palette (warm paper, a real reading surface) ----------------------------

const _paper = Color(0xFFFAF8F3); // page + behind-glyph fill
const _ink = Color(0xFF23282E); // body text
const _heading = Color(0xFF14181C); // section headings
const _muted = Color(0xFF6B7280); // byline / secondary
const _accent = Color(0xFF2F6FED); // progress bar

// Body ink as premultiplied-free RGBA floats for the document default.
const List<double> _inkFloats = [0x23 / 255, 0x28 / 255, 0x2E / 255, 1];

class ReaderDemoPage extends StatefulWidget {
  const ReaderDemoPage({super.key});

  @override
  State<ReaderDemoPage> createState() => _ReaderDemoPageState();
}

class _ReaderDemoPageState extends State<ReaderDemoPage> {
  GPUTextViewController? _controller;
  GPUTextDocument? _doc;
  String? _error;

  final ScrollController _scroll = ScrollController();
  // Scoped listenables so scrolling / reflow only rebuild the app-bar chrome,
  // never the document sliver.
  final ValueNotifier<double> _progress = ValueNotifier(0);
  final ValueNotifier<GPUTextMetrics?> _metrics = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _boot();
  }

  Future<void> _boot() async {
    try {
      final controller = await GPUTextViewController.spawn();
      // Register the three real faces the essay uses. The worker resolves
      // fonts by string id (no family/weight matching, no variable axes), so
      // bold and italic are separate registrations, not synthesized.
      Future<void> reg(String id, String asset) async {
        final data = await rootBundle.load(asset);
        // Copy: registerFont transfers (neuters) the caller's bytes.
        await controller.registerFont(
          id,
          Uint8List.fromList(data.buffer.asUint8List()),
        );
      }

      await reg('body', 'assets/Lato-Regular.ttf');
      await reg('body-bold', 'assets/Lato-Bold.ttf');
      await reg('body-italic', 'assets/Lato-Italic.ttf');

      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _doc = _buildEssay();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    _progress.value = max <= 0 ? 0 : (_scroll.position.pixels / max).clamp(0, 1);
  }

  /// Worker font id for a resolved span style. No bold+italic combos are
  /// authored, so bold wins when both are set.
  static String _fontId(TextStyle style) {
    final bold =
        (style.fontWeight ?? FontWeight.w400).value >= FontWeight.w600.value;
    if (bold) return 'body-bold';
    if (style.fontStyle == FontStyle.italic) return 'body-italic';
    return 'body';
  }

  @override
  void dispose() {
    _scroll.dispose();
    _progress.dispose();
    _metrics.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final doc = _doc;
    if (_error != null) {
      return Scaffold(
        backgroundColor: _paper,
        body: Center(child: Text('boot failed: $_error')),
      );
    }
    if (controller == null || doc == null) {
      return const Scaffold(
        backgroundColor: _paper,
        body: Center(child: CircularProgressIndicator(color: _accent)),
      );
    }
    return Scaffold(
      backgroundColor: _paper,
      // Explicit controller + scrollbars:false so desktop ScrollBehavior does
      // not nest a second Scrollbar on the same position (thumb drag would
      // lose the gesture arena); see sliver_gpu_text_demo.dart.
      body: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          controller: _scroll,
          interactive: true,
          thumbVisibility: true,
          // Selection: mouse-drag / long-press selects across the GPU article;
          // touch-drag scrolls.
          child: SelectionArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Center a readable measure (~680px) on wide screens.
                const measure = 680.0;
                final pad = ((constraints.maxWidth - measure) / 2).clamp(
                  24.0,
                  double.infinity,
                );
                return CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      backgroundColor: _paper,
                      foregroundColor: _heading,
                      surfaceTintColor: Colors.transparent,
                      elevation: 0,
                      scrolledUnderElevation: 0.5,
                      title: const Text('Reader — one document, off-thread'),
                      actions: [
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: ValueListenableBuilder<GPUTextMetrics?>(
                              valueListenable: _metrics,
                              builder: (context, m, _) => Text(
                                m == null
                                    ? '…'
                                    : '${_compact(m.glyphCount)} glyphs · '
                                          '${m.lineCount} lines · '
                                          '${m.reflowMs.toStringAsFixed(1)} ms',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: _muted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      bottom: PreferredSize(
                        preferredSize: const Size.fromHeight(3),
                        child: ValueListenableBuilder<double>(
                          valueListenable: _progress,
                          builder: (context, p, _) => LinearProgressIndicator(
                            value: p,
                            minHeight: 3,
                            backgroundColor: const Color(0x14000000),
                            valueColor: const AlwaysStoppedAnimation(_accent),
                          ),
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(pad, 28, pad, 96),
                      sliver: SliverGPUText(
                        controller: controller,
                        document: doc,
                        background: _paper,
                        onMetrics: (m) => _metrics.value = m,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // -- document ---------------------------------------------------------------

  GPUTextDocument _buildEssay() {
    final children = <InlineSpan>[];

    // Vertical rhythm comes from newlines + per-line height (doc lineHeight is
    // 1.0 so per-run TextStyle.height is not multiplied — see the chat demo's
    // line-height parity note). A paragraph ends with a blank body line; a
    // heading's tall line box carries its own space above.
    void title(String t) => children.add(
      TextSpan(
        text: '$t\n',
        style: const TextStyle(
          fontSize: 34,
          height: 1.3,
          fontWeight: FontWeight.w700,
          color: _heading,
        ),
      ),
    );
    void byline(String t) => children.add(
      TextSpan(
        text: '$t\n\n',
        style: const TextStyle(
          fontSize: 15,
          height: 1.9,
          fontStyle: FontStyle.italic,
          color: _muted,
        ),
      ),
    );
    void h2(String t) => children.add(
      TextSpan(
        text: '$t\n',
        style: const TextStyle(
          fontSize: 23,
          height: 2.1,
          fontWeight: FontWeight.w700,
          color: _heading,
        ),
      ),
    );
    void para(List<InlineSpan> spans) {
      children.addAll(spans);
      children.add(const TextSpan(text: '\n\n'));
    }

    title('The Craft of Text');
    byline('On shaping, breaking, and why a whole document is the honest '
        'unit of layout.');

    para([
      _t('Most of what a screen shows is text. Menus, prices, timestamps, '
          'the paragraph you are reading now — all of it is glyphs placed '
          'next to glyphs. It is so ordinary that it disappears, and because '
          'it disappears we assume it is simple. It is not. Turning a string '
          'of characters into legible marks is one of the oldest and least '
          'forgiving problems in graphics, and the closer you look, the more '
          'the '),
      _i('easy'),
      _t(' parts turn out to be the hard ones.'),
    ]);
    para([
      _t('This essay walks the path a single line of text takes on its way to '
          'the screen, and then argues for a small idea about where that work '
          'should happen: not glyph by glyph, not widget by widget, but a '
          'whole document at a time, laid out once, away from the thread that '
          'paints the frame. The article you are reading is itself that idea. '
          'It is one document, shaped in the background, handed to the '
          'viewport a strip at a time.'),
    ]);

    h2('Shaping comes first');
    para([
      _t('A font is not a table of pictures indexed by letter. It is a program '
          'for arranging shapes, and the arrangement depends on context. The '
          'step that runs this program is called '),
      _b('shaping'),
      _t(': it takes a run of characters in one language and one style and '
          'returns a sequence of positioned glyphs. The output is not one '
          'glyph per character. Ligatures fuse letters; marks stack onto the '
          'letters they modify; a cursive script rewrites its forms depending '
          'on what sits to either side.'),
    ]);
    para([
      _t('You cannot skip shaping and still be correct. Arabic joins its '
          'letters into words and the same letter takes four different forms '
          'by position. Indic scripts reorder vowel signs so that a mark typed '
          'after a consonant is drawn before it. Emoji fold whole sequences of '
          'code points — a base, a skin tone, a zero-width joiner, another '
          'base — into a single picture. A renderer that lays out one glyph '
          'per character produces something that looks like text to a machine '
          'and like nonsense to a reader.'),
    ]);
    para([
      _t('Shaping is also where most of the cost lives. It walks the string, '
          'consults coverage and substitution tables, and applies positioning '
          'rules. Do it once and cache the result and everything downstream is '
          'cheap. Do it again on every frame and you have built a space heater '
          'that occasionally displays words.'),
    ]);

    h2('Breaking lines is a global decision');
    para([
      _t('Once you have positioned glyphs you have to decide where the lines '
          'end. The naive rule — fill each line until the next word would '
          'overflow, then break — is fast and almost always slightly wrong. '
          'It makes every decision locally, so it cannot see the ragged edge '
          'or the lonely word it is about to strand at the bottom of a '
          'paragraph.'),
    ]);
    para([
      _t('The better algorithms treat the paragraph as a whole. They consider '
          'every legal breakpoint at once and choose the set of breaks that '
          'minimizes a total penalty — a little for a loose line, more for a '
          'tight one, a lot for a hyphen followed by a hyphen. This is the '
          'idea behind the line-breaking used in serious typesetting, and it '
          'is '),
      _i('global'),
      _t(': the break you make on line three depends on the break you will '
          'make on line nine. You cannot compute it a line at a time, which is '
          'the first hint that the natural unit of layout is larger than a '
          'line.'),
    ]);
    para([
      _t('Breaking also has to know the rules of the language. You may break '
          'after a space in English, but not inside a word except at a '
          'hyphenation point; you may break between most pairs of Han '
          'characters but not before a closing bracket; a nonbreaking space '
          'exists precisely to forbid a break the algorithm would otherwise '
          'take. None of this is visible when it works. All of it is glaring '
          'when it does not.'),
    ]);

    h2('Rasterizing an outline');
    para([
      _t('A glyph, in the font, is a set of curves — straight segments and '
          'quadratic or cubic arcs that enclose the black. To show it you have '
          'to decide, for every pixel, how much of that pixel the shape '
          'covers. That coverage number, between fully outside and fully '
          'inside, is what makes a diagonal stem look smooth instead of '
          'staircased.'),
    ]);
    para([
      _t('The traditional answer is to rasterize each glyph once into a small '
          'bitmap, pack those bitmaps into an atlas, and paste them onto the '
          'screen. It is fast and it works, until you zoom, or rotate, or '
          'animate a size, at which point the baked bitmap is the wrong '
          'resolution and the crisp edges turn to mush. The atlas remembers '
          'one size; the screen keeps asking for others.'),
    ]);
    para([
      _t('The other answer is to keep the outline and evaluate its coverage on '
          'the GPU, per pixel, at whatever scale the frame happens to need. '
          'There is no baked size because nothing is baked. The same glyph is '
          'sharp at every zoom, and the work scales with the pixels you '
          'actually fill rather than the sizes you might someday want. This is '
          'the path this page takes: the letters under your cursor were '
          'evaluated from their curves a moment ago, at exactly this size.'),
    ]);

    h2('The honest unit is a document');
    para([
      _t('Now put the pieces together. Shaping wants to run once and be '
          'cached. Line breaking is a decision about a whole paragraph. '
          'Neither of them is a per-glyph or per-widget operation, and both '
          'get more efficient the more context you hand them at once. So what '
          'is the right amount of text to lay out in a single call?'),
    ]);
    para([
      _t('The tempting answer, especially inside a widget toolkit, is to lay '
          'out whatever is on screen — this heading, that paragraph, each in '
          'its own little box. It feels tidy. It is also the wrong grain. '
          'Break a document into a hundred independent fragments and you shape '
          'a hundred times, break lines a hundred times, and manage a hundred '
          'tiny surfaces, each too small to amortize the machinery it carries. '
          'The overhead is real and it scales with the number of pieces, not '
          'the amount of text.'),
    ]);
    para([
      _t('A whole document is the honest unit. One string, one style resolver, '
          'one pass that shapes and breaks and measures everything together, '
          'producing a single tall run of laid-out lines. You only need to '
          'draw the part that is visible, but you should '),
      _b('lay out'),
      _t(' the whole thing at once, because that is the grain at which the '
          'expensive steps are cheapest and the correct steps are correct. '
          'This essay is a few thousand words in one such pass. Scroll it as '
          'fast as you like; nothing is being re-shaped as it goes by.'),
    ]);

    h2('Off the main thread');
    para([
      _t('There is one more move. Laying out a long document takes real time — '
          'milliseconds, sometimes many of them — and the thread that lays it '
          'out is usually the same thread that paints the next frame. Do the '
          'layout there and the frame waits, and the reader feels the wait as '
          'a stutter precisely when they scroll, which is the one moment they '
          'are looking closely.'),
    ]);
    para([
      _t('So move it. Shape and break the document on a background isolate and '
          'send back only the finished geometry — the positions and coverage '
          'the frame needs to draw. The painting thread never blocks on '
          'layout; it just draws the strip it was handed. When the width '
          'changes or the text grows, the reflow happens off to the side and '
          'the result arrives a frame or two later, without the frame in '
          'between ever skipping.'),
    ]);
    para([
      _t('This only pays off because the unit is a document. You spawn one '
          'background worker, hand it one long job, and get one clean result. '
          'Try the same trick per fragment and you trade a layout stall for a '
          'storm of tiny round trips, each with its own latency and its own '
          'moment of blankness while it waits. The coarse grain is what makes '
          'the background cheap.'),
    ]);

    h2('What the reader never sees');
    para([
      _t('Everything above is invisible when it works. Nobody scrolling an '
          'article thinks about coverage evaluation or the penalty of a loose '
          'line. That is the point. Good text rendering is a long list of '
          'problems solved so completely that the solution leaves no trace, '
          'and the measure of the craft is how little of it you notice.'),
    ]);
    para([
      _t('You notice the failures, though. Tofu boxes where a glyph is '
          'missing. A ligature that breaks across a color change. A line that '
          'hyphenates a word that should never have been split. A heading that '
          'shears mid-scroll because it was re-laid-out on the frame you were '
          'watching. Each of these is a place where one of the steps in this '
          'essay was skipped or done at the wrong grain.'),
    ]);
    para([
      _i('Text is the interface.'),
      _t(' Most of a screen is words, so the text stack is not a detail to be '
          'gotten roughly right and moved past. It deserves the same care as '
          'anything the whole product is made of — which, most of the time, it '
          'is. Shape once. Break globally. Rasterize from the curve. Lay out '
          'the document, not the fragment, and lay it out where the frame '
          'cannot feel it. The reader will never thank you, because the reader '
          'will never notice. That is the whole job.'),
    ]);

    return GPUTextDocument.rich(
      'reader-essay',
      TextSpan(
        style: const TextStyle(fontSize: 18, height: 1.62, color: _ink),
        children: children,
      ),
      fontIdResolver: _fontId,
      defaultColor: _inkFloats,
      // Spans carry their own height; keep the doc multiplier at 1.0 so line
      // boxes come purely from per-run TextStyle.height.
      lineHeight: 1.0,
    );
  }
}

TextSpan _t(String s) => TextSpan(text: s);
TextSpan _i(String s) =>
    TextSpan(text: s, style: const TextStyle(fontStyle: FontStyle.italic));
TextSpan _b(String s) =>
    TextSpan(text: s, style: const TextStyle(fontWeight: FontWeight.w700));

String _compact(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
