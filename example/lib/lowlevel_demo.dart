// Real-usage demo for the opt-in low-level API (package:gputext/lowlevel.dart):
// a resizable document, laid out and rendered as real GPU glyphs, with three
// switches that each isolate one property of the pipeline.
//
//   • Layout on [Worker isolate] vs [UI thread] — the SAME reflow, run either
//     on GPUTextWorker (off-thread, UI never blocks) or inline via
//     GPUTextLayout (blocks the UI thread). Drag the width slider under each to
//     feel the difference; the HUD reports which thread laid out and how long.
//
//   • Highlight (re-emit only) — recolor the whole document through the DISPLAY
//     phase alone: same laid-out lines, a fresh emit() with a new colour, no
//     re-break. The HUD shows the emit-only time, proving layout is reused.
//
// Both paths render through one offscreen GpuImageSurface -> ui.Image blit.
// Nothing here touches GPUText.instance. Dev hook: GPUTEXT_DEMO=lowlevel.
// GPU rendering needs Impeller + flutter_gpu; without them the page shows the
// layout metrics and a CPU-text fallback.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

// Hide names that collide with Flutter's dart:ui re-exports.
import 'package:gputext/lowlevel.dart' hide TextAlign, TextDirection;

const _fontId = 'lato';
const _sourceFontId = 'source'; // SourceSans3 — a CFF/OTF font
const _sourceFamily = 'SourceSans3'; // its Flutter font family (pubspec)
const _emojiFontId = 'emoji'; // TwemojiMozilla — a COLR color-emoji font
const _fontSizePx = 18.0;
const _lineHeight = 1.4;
const _inkColor = <double>[0.11, 0.12, 0.16, 1];
const _highlightColor = <double>[0.66, 0.11, 0.13, 1];
// A single GPU texture can't hold a whole long document (Metal caps at 16384px,
// mobile GPUs lower). We lay out the FULL doc — so layout cost stays real — but
// render only this many device px from the top; glyphs below are clipped.
const _maxDevicePx = 8192;

enum _Where { worker, uiThread }

class LowLevelDemoPage extends StatefulWidget {
  const LowLevelDemoPage({super.key});

  @override
  State<LowLevelDemoPage> createState() => _LowLevelDemoPageState();
}

class _Doc {
  const _Doc(
    this.id,
    this.label,
    this.runs,
    this.fallback, [
    this.placeholderWidgets = const [],
  ]);
  final String id;
  final String label;

  /// Flattened rich-text runs (+ placeholders) sent to the worker / laid out
  /// on main.
  final List<GPUInlineSpec> runs;

  /// Equivalent Flutter span, for the CPU-text fallback when GPU is off.
  final InlineSpan fallback;

  /// Widget for each flattened WidgetSpan, indexed by GPUPlaceholderSpec.index.
  final List<Widget> placeholderWidgets;
}

/// Main-isolate layout handle for a document (phase 1 prepared once), plus its
/// atlas and the mutable runs whose colours we recolour for the highlight demo.
class _MainDoc {
  _MainDoc(this.layout, this.runs, this.baseColors, this.atlas);
  final GPUTextLayout layout;
  final List<TextRun> runs;
  final List<List<double>> baseColors; // originals, restored on un-highlight
  final SharedGlyphAtlas atlas;
  double lastWidth = double.nan;
}

class _Stats {
  const _Stats(this.glyphs, this.lines, this.ms, this.label, this.good);
  final int glyphs;
  final int lines;
  final double ms;
  final String label;
  final bool good; // green (off-thread / re-emit) vs amber (UI-thread layout)
}

class _LowLevelDemoPageState extends State<LowLevelDemoPage> {
  GPUTextWorker? _worker;
  _GlyphSurface? _surface; // null when flutter_gpu is unavailable
  // Main-isolate font copies, keyed by the same ids registered on the worker;
  // used by the UI-thread + highlight paths.
  final Map<String, GPUFont> _mainFonts = {};
  TextShaper? _mainShaper; // HarfBuzz for the UI-thread + highlight paths
  // Ordered fallback font ids for scripts Lato/SourceSans3 don't cover (CJK,
  // Arabic, Hebrew) — resolved from bundled Noto + macOS system fonts at boot.
  List<String> _fallbackIds = const [];
  // Device-pixel ratio the window is currently rendered at. Seeded from the
  // implicit view, then kept in sync with MediaQuery in build() so a move to a
  // different-DPR monitor re-renders at the new scale instead of staying soft.
  double _dpr =
      WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;

  List<_Doc> _docs = const [];
  final Set<String> _preparedOnWorker = {};
  final Map<String, _MainDoc> _mainDocs = {};
  String? _currentId;
  bool _ready = false;
  String? _error;
  bool _switching = false;

  double _width = 380;
  _Where _where = _Where.worker;
  bool _highlight = false;

  bool _workerBusy = false;
  bool _workerPending = false;

  // The current drawable is uploaded to the GPU once per reflow (in _surface);
  // the visible window is re-rendered from it as the user scrolls — constant
  // GPU memory and no re-upload for any document length.
  int _glyphCount = 0;
  double _docWidth = 0;
  double _docHeight = 0;

  // The width the currently-uploaded drawable was laid out (and rendered) for.
  // Both the paper box and the window image are sized to THIS, not the live
  // slider `_width`: on the async worker path `_width` jumps the instant the
  // slider moves but the GPU image still holds the previous width, so sizing
  // the display to `_width` + BoxFit.fill would rubber-band-stretch the stale
  // image until the reflow lands (worse on big docs, where reflow is slower).
  // Tracking the rendered width instead keeps glyphs 1:1; the paper snaps to
  // the new width when the reflow completes.
  double get _paperWidth => _docWidth > 0 ? _docWidth : _width;

  // The viewport height the current window image was rendered for. Same problem
  // as width, one axis over: on a window/viewport-height resize the live `vh`
  // updates a frame before the re-render lands, so the image is displayed at
  // the height it was actually rasterized at (top-aligned) rather than stretched
  // to the new `vh`. Snaps to the new height on the next render.
  double _winH = 0;
  // Which atlas is currently uploaded to the GPU ("docId#source"); the atlas is
  // stable per doc, so we re-upload it only when this key changes, not per
  // width reflow. Reset on doc/mode switch.
  String? _atlasKeyOnGpu;

  final ScrollController _scroll = ScrollController();
  final ValueNotifier<ui.Image?> _window = ValueNotifier<ui.Image?>(null);
  double _viewportH = 0;
  _Stats? _stats;

  // WidgetSpan placeholders: boxes (doc-layout space) from the last reflow, and
  // the widgets to draw at them (index -> widget).
  List<PlaceholderBox> _placeholders = const [];
  List<Widget> _placeholderWidgets = const [];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_renderWindow);
    _boot();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _surface?.dispose(); // owns and disposes the window images
    _worker?.dispose();
    _window.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final bytes = (await rootBundle.load('assets/Lato-Regular.ttf'))
          .buffer
          .asUint8List();
      final gatsby =
          await rootBundle.loadString('assets/bench/en-gatsby-opening.txt');
      // A CFF/OTF font — HarfBuzz-in-the-worker extracts its PostScript
      // outlines; the pure-Dart glyf parser can't.
      final srcBytes = (await rootBundle.load('assets/SourceSans3-Regular.otf'))
          .buffer
          .asUint8List();

      // COLR color-emoji font — renders as coloured coverage layers (reuses
      // the coverage pipeline; no separate color texture).
      final emojiBytes = (await rootBundle.load('assets/TwemojiMozilla.ttf'))
          .buffer
          .asUint8List();

      final worker = await GPUTextWorker.spawn();
      await worker.registerFont(_fontId, Uint8List.fromList(bytes));
      await worker.registerFont(_sourceFontId, Uint8List.fromList(srcBytes));
      await worker.registerFont(_emojiFontId, Uint8List.fromList(emojiBytes));

      // HarfBuzz on the main isolate too, so the UI-thread + highlight paths
      // shape identically (ligatures/kerning) and render the CFF font.
      _mainShaper = loadHarfBuzzShaper();
      _mainFonts[_fontId] = GPUFont.parse(bytes);
      _mainFonts[_sourceFontId] = GPUFont.parse(srcBytes);
      _mainFonts[_emojiFontId] = GPUFont.parse(emojiBytes);

      // Fallback fonts for scripts the Latin fonts don't cover. Register each
      // on the worker and main (same ids), ordered: full system CJK first (mac)
      // then bundled Noto, then RTL. Missing ones are skipped.
      final fallbackIds = <String>[];
      Future<void> reg(String id, Uint8List b) async {
        await worker.registerFont(id, Uint8List.fromList(b));
        _mainFonts[id] = GPUFont.parse(b);
        fallbackIds.add(id);
      }

      final sys = SystemFontProvider.tryLoad();
      final cjkSys = sys == null
          ? null
          : _pickSystem(sys, const [
              'PingFang SC',
              'Hiragino Sans',
              'Heiti SC',
              'Songti SC',
            ], 0x4E2D); // 中
      if (cjkSys != null) await reg('cjk-sys', cjkSys);

      final cjkBytes = (await rootBundle.load('assets/NotoSansSC-subset.ttf'))
          .buffer
          .asUint8List();
      await reg('cjk', cjkBytes);

      if (sys != null) {
        final ar = _pickSystem(sys, const [
          'Geeza Pro',
          'Damascus',
          'Al Bayan',
          'Baghdad',
          'Arial Unicode MS',
        ], 0x0627); // ا
        if (ar != null) await reg('ar', ar);
        final he = _pickSystem(sys, const [
          'Arial Hebrew',
          'Corsiva Hebrew',
          'Times New Roman',
          'Arial Unicode MS',
        ], 0x05D0); // א
        if (he != null) await reg('he', he);
      }
      _fallbackIds = fallbackIds;

      _worker = worker;
      _surface = await _GlyphSurface.tryCreate();
      _docs = _buildDocs(gatsby);
      if (!mounted) return;
      setState(() => _ready = true);
      await _selectDoc(_docs.first);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  /// First system font in [names] that loads (glyf only) and covers [probe].
  Uint8List? _pickSystem(SystemFontProvider sys, List<String> names, int probe) {
    for (final name in names) {
      final bytes = sys.fontData(name);
      if (bytes == null) continue;
      if (GPUFont.parse(bytes).hasGlyphForRune(probe)) return bytes;
    }
    return null;
  }

  List<_Doc> _buildDocs(String gatsby) {
    final paras = gatsby
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.replaceAll('\n', ' ').trim())
        .where((p) => p.isNotEmpty)
        .toList();

    // A single-style doc is just a one-run TextSpan flattened the same way.
    _Doc plain(String id, String label, String text) {
      final span = TextSpan(
        text: text,
        style: const TextStyle(
          fontFamily: 'Lato',
          fontSize: _fontSizePx,
          color: Color(0xFF1C1E29),
        ),
      );
      return _Doc(id, label, _flatten(span), span);
    }

    final rich = _richSpan();
    final scripts = _scriptsSpan();
    return [
      plain('excerpt', 'Excerpt', paras.take(3).join('\n\n')),
      plain('article', 'Article', paras.take(9).join('\n\n')),
      // Long enough to scroll; laid out in full (heavy on the UI-thread path).
      plain('book', 'Long book', [for (var i = 0; i < 3; i++) ...paras].join('\n\n')),
      _Doc('rich', 'Rich text', _flatten(rich), rich),
      _Doc('scripts', 'Scripts', _flatten(scripts), scripts),
      _buildStressDoc(),
    ];
  }

  /// English + CJK + Arabic + Hebrew in one Lato-styled span. Coverage fallback
  /// routes each script to its font; bidi handles the RTL runs. Renders on GPU
  /// only where a covering font resolved (bundled Noto for CJK; macOS system
  /// fonts for RTL) — otherwise the CPU-text fallback below shows it.
  InlineSpan _scriptsSpan() {
    const zh = '你好世界，这是在 GPU 上渲染的文本。';
    const ja = 'これは日本語のテキストです。';
    const ar = 'مرحبا بالعالم، هذا نص على وحدة معالجة الرسومات.';
    const he = 'שלום עולם, זהו טקסט המעובד על המעבד הגרפי.';
    return TextSpan(
      style: const TextStyle(
        fontFamily: 'Lato',
        fontSize: _fontSizePx,
        height: _lineHeight,
        color: Color(0xFF1C1E29),
      ),
      children: [
        const TextSpan(
          text: 'World scripts\n',
          style: TextStyle(fontSize: 32, letterSpacing: -0.5, color: Color(0xFF0B3D91)),
        ),
        const TextSpan(
          text: 'Font fallback + bidi, all on the worker isolate.\n\n',
          style: TextStyle(fontSize: 18, color: Color(0xFF6A6F7B)),
        ),
        for (var i = 0; i < 4; i++) ...[
          const TextSpan(
            text: 'CJK: ',
            style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF0B3D91)),
          ),
          const TextSpan(text: '$zh $ja\n'),
          const TextSpan(
            text: 'Arabic (RTL): ',
            style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF0B3D91)),
          ),
          const TextSpan(text: '$ar\n'),
          const TextSpan(
            text: 'Hebrew (RTL): ',
            style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF0B3D91)),
          ),
          const TextSpan(text: '$he\n'),
          const TextSpan(text: 'Mixed: English, then '),
          const TextSpan(text: 'عربي'),
          const TextSpan(text: ', then '),
          const TextSpan(text: '中文'),
          const TextSpan(text: ', then back to English.\n\n'),
        ],
      ],
    );
  }

  /// TextSpan -> sendable specs, mapping each span's font family to a
  /// registered worker font id. [placeholderSize] reserves space for
  /// WidgetSpans.
  List<GPUInlineSpec> _flatten(InlineSpan span, {PlaceholderSizer? placeholderSize}) =>
      flattenInlineSpan(
        span,
        fontIdResolver: (style) =>
            style.fontFamily == _sourceFamily ? _sourceFontId : _fontId,
        defaultFontSizePx: _fontSizePx,
        defaultColor: _inkColor,
        placeholderSize: placeholderSize,
      );

  /// A rich paragraph mixing sizes, colours and letter-spacing across spans.
  InlineSpan _richSpan() {
    const body = TextStyle(
      fontFamily: 'Lato',
      fontSize: _fontSizePx,
      color: Color(0xFF1C1E29),
    );
    final bodyPara = List.filled(
      3,
      'Each span above and here becomes one GPUTextRunSpec — flattened on the '
      'UI isolate, then shaped, laid out and emitted on the worker, and blitted '
      'as one drawable. Resize with the slider (reflow off-thread), toggle '
      'Highlight (re-emit only), or switch to UI-thread layout to feel it. ',
    ).join('');
    return TextSpan(
      style: body,
      children: [
        const TextSpan(
          text: 'gputext\n',
          style: TextStyle(
            fontSize: 36,
            height: 1.1,
            letterSpacing: -0.5,
            color: Color(0xFF0B3D91),
          ),
        ),
        const TextSpan(
          text: 'Rich text, laid out on a background isolate\n\n',
          style: TextStyle(fontSize: 20, color: Color(0xFF6A6F7B)),
        ),
        const TextSpan(text: 'One paragraph mixes '),
        const TextSpan(
          text: 'sizes',
          style: TextStyle(fontSize: 27, color: Color(0xFFA81C21)),
        ),
        const TextSpan(text: ', '),
        const TextSpan(
          text: 'colours',
          style: TextStyle(color: Color(0xFF1B7F3B)),
        ),
        const TextSpan(text: ', and '),
        const TextSpan(
          text: 's p a c i n g',
          style: TextStyle(letterSpacing: 3, color: Color(0xFF8A5A00)),
        ),
        const TextSpan(text: '. And a second font — '),
        const TextSpan(
          text: 'Source Sans 3',
          style: TextStyle(
            fontFamily: _sourceFamily,
            fontSize: 20,
            color: Color(0xFF5B2A86),
          ),
        ),
        const TextSpan(
          text: ' (CFF/OTF) renders because HarfBuzz extracts its PostScript '
              'outlines on the worker, and ligatures/kerning are real.\n\n',
        ),
        TextSpan(text: bodyPara),
      ],
    );
  }

  /// Everything at once: mixed fonts (Lato + CFF SourceSans3), OpenType
  /// features (liga on/off, tabular figures), CJK / RTL / emoji ZWJ sequences,
  /// and inline WidgetSpans (badge, avatar, icon, chip) — flattened, sent to
  /// the worker, laid out off-thread and rendered virtualized. Repeated so
  /// it's long enough to scroll.
  _Doc _buildStressDoc() {
    final widgets = <Widget>[];
    final sizes = <Size>[];
    final children = <InlineSpan>[
      const TextSpan(
        text: 'Stress test\n',
        style: TextStyle(
          fontSize: 34,
          height: 1.2,
          letterSpacing: -0.5,
          color: Color(0xFF0B3D91),
        ),
      ),
    ];

    WidgetSpan ph(Widget w, Size size) {
      final sized = SizedBox(width: size.width, height: size.height, child: w);
      widgets.add(sized);
      sizes.add(size);
      return WidgetSpan(alignment: PlaceholderAlignment.middle, child: sized);
    }

    for (var i = 0; i < 800; i++) {
      children.addAll([
        const TextSpan(text: 'Mixed fonts ('),
        const TextSpan(
          text: 'Source Sans 3',
          style: TextStyle(fontFamily: _sourceFamily, color: Color(0xFF5B2A86)),
        ),
        const TextSpan(text: '), features — '),
        const TextSpan(
          text: 'office',
          style: TextStyle(
            fontFeatures: [FontFeature.disable('liga')],
            color: Color(0xFF1B7F3B),
          ),
        ),
        const TextSpan(text: ' liga-off vs '),
        const TextSpan(
          text: 'office',
          style: TextStyle(color: Color(0xFF1B7F3B)),
        ),
        const TextSpan(text: ' on, tabular '),
        const TextSpan(
          text: '1234567890',
          style: TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
        ),
        const TextSpan(text: ' — CJK 日本語・中文・한국어 '),
        const TextSpan(
          text: '漢字交ぜ書き',
          style: TextStyle(fontSize: 22, color: Color(0xFF0B3D91)),
        ),
        const TextSpan(text: ', RTL مرحبا بالعالم, emoji '),
        // Complex ZWJ / modifier sequences exercise grapheme & shaping.
        const TextSpan(text: '👨‍👩‍👧‍👦 🏳️‍🌈 🧑‍💻 🇯🇵 🇻🇳 👍🏽 '),
        const TextSpan(text: '— inline widgets '),
        ph(_badge('NEW', const Color(0xFFC62828)), const Size(46, 20)),
        const TextSpan(text: ' '),
        ph(_avatar(i), const Size(24, 24)),
        const TextSpan(text: ' '),
        ph(
          const Icon(Icons.star_rounded, size: 18, color: Color(0xFFF6A609)),
          const Size(18, 18),
        ),
        const TextSpan(text: ' '),
        ph(_chip('CJK', const Color(0xFF1565C0)), const Size(40, 20)),
        const TextSpan(text: ' '),
        ph(
          const Icon(Icons.translate_rounded, size: 18, color: Color(0xFF5B2A86)),
          const Size(18, 18),
        ),
        const TextSpan(text: ' '),
        ph(_chip('ZWJ', const Color(0xFF6A1B9A)), const Size(40, 20)),
        const TextSpan(
          text: ', all shaped, laid out and emitted on the worker isolate, '
              'then rendered virtualized.\n\n',
        ),
      ]);
    }

    final span = TextSpan(
      style: const TextStyle(
        fontFamily: 'Lato',
        fontSize: _fontSizePx,
        height: _lineHeight,
        color: Color(0xFF1C1E29),
      ),
      children: children,
    );
    final runs = _flatten(span, placeholderSize: (_, i) => sizes[i]);
    return _Doc('stress', 'Stress', runs, span, widgets);
  }

  Widget _badge(String label, Color color) => DecoratedBox(
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
    child: Center(
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  Widget _chip(String label, Color color) => DecoratedBox(
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color, width: 1),
    ),
    child: Center(
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    ),
  );

  Widget _avatar(int i) => DecoratedBox(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.primaries[i % Colors.primaries.length],
    ),
    child: Center(
      child: Text(
        '${i + 1}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  Future<void> _selectDoc(_Doc doc) async {
    setState(() {
      _switching = true;
      _currentId = doc.id;
      _placeholderWidgets = doc.placeholderWidgets;
      _placeholders = const [];
    });
    await _reflowNow();
    if (mounted) setState(() => _switching = false);
  }

  // Slider / toggle changes route through here (fire-and-forget); a doc switch
  // uses [_reflowNow] to await the first frame. Both funnel through the one
  // dispatcher so the inline-vs-worker decision lives in a single place.
  void _requestReflow() => unawaited(_reflowDispatch());
  Future<void> _reflowNow() => _reflowDispatch();

  // Below this many characters the worker round-trip (per-message scheduling
  // latency) costs more than just laying the doc out on the UI thread, where
  // layout+emit is sub-millisecond. So even in "worker" mode a small doc is
  // routed inline — the isolate earns its keep only on the heavy docs.
  static const _inlineCharThreshold = 1200;

  int _docChars(_Doc doc) {
    var n = 0;
    for (final s in doc.runs) {
      if (s is GPUTextRunSpec) n += s.text.length;
    }
    return n;
  }

  Future<void> _reflowDispatch() {
    final doc = _current;
    // The highlight demo and the explicit UI-thread mode always run inline;
    // additionally, in worker mode, auto-route docs too small to be worth the
    // round-trip.
    final autoInline = doc != null &&
        _where == _Where.worker &&
        !_highlight &&
        _docChars(doc) < _inlineCharThreshold;
    if (_highlight || _where == _Where.uiThread || autoInline) {
      _reflowMain(autoInline: autoInline);
      return Future.value();
    }
    return _reflowWorker();
  }

  // --- worker path: off the UI thread ---
  //
  // Single-flight: at most one loop runs at a time. A re-entrant call while
  // busy just raises [_workerPending] and the running loop picks up the change
  // on its next turn. [_current] and [_width] are re-read every iteration, so a
  // width drag OR a doc switch mid-reflow always converges on the latest state
  // (rather than the loop being pinned to the doc it started with). Setting
  // [_workerBusy] before the first await closes the window where a slider tick
  // during a large doc's prepare could spin up a second loop and double-prepare.
  Future<void> _reflowWorker() async {
    if (_workerBusy) {
      _workerPending = true;
      return;
    }
    final worker = _worker;
    if (worker == null) return;
    _workerBusy = true;
    try {
      do {
        _workerPending = false;
        final doc = _current;
        if (doc == null) break;
        if (!_preparedOnWorker.contains(doc.id)) {
          await worker.prepareDoc(
            doc.id,
            doc.runs,
            fallbackFontIds: _fallbackIds,
            emojiFontId: _emojiFontId,
          );
          _preparedOnWorker.add(doc.id);
        }
        final atlasKey = '${doc.id}#worker';
        // Only fetch the atlas when it isn't already on the GPU — a width
        // change doesn't alter the glyph set, so subsequent reflows ship (and
        // upload) just the instance buffer.
        final needAtlas = _atlasKeyOnGpu != atlasKey;
        final w = _width;
        final sw = Stopwatch()..start();
        final d = await worker.reflowDoc(
          doc.id,
          w,
          lineHeight: _lineHeight,
          includeAtlas: needAtlas,
        );
        sw.stop();
        if (!mounted) return;
        _renderFrame(
          curves: needAtlas ? d.materializeCurves() : null,
          rows: needAtlas ? d.materializeRows() : null,
          instances: d.materialize(),
          glyphs: d.glyphCount,
          lines: d.lineCount,
          width: d.width,
          height: d.height,
          ms: sw.elapsedMicroseconds / 1000.0,
          label: 'worker isolate · layout+emit — UI thread free',
          good: true,
          placeholders: d.placeholders,
        );
        if (needAtlas) _atlasKeyOnGpu = atlasKey;
      } while (_workerPending);
    } finally {
      _workerBusy = false;
    }
  }

  // --- main path: on the UI thread (also serves the highlight re-emit and the
  // small-doc auto-route). [autoInline] is set when we deliberately chose this
  // path for a doc too small to offload — it's a good outcome (fast, no
  // round-trip), so it's labelled green rather than the amber "blocks the UI".
  void _reflowMain({bool autoInline = false}) {
    final doc = _current;
    if (doc == null) return;
    final md = _mainDocs.putIfAbsent(doc.id, () {
      // Same shaping the worker uses (HarfBuzz when available) — ligatures,
      // kerning, CFF outlines. buildRunItems makes runs' colours mutable, so
      // the highlight demo can recolour them in place.
      final items = buildRunItems(
        doc.runs,
        _mainFonts,
        _mainShaper,
        fallbackFontIds: _fallbackIds,
        emojiFontId: _emojiFontId,
      );
      final runs = [
        for (final it in items)
          if (it is TextRun) it,
      ];
      final atlas = SharedGlyphAtlas();
      bandRunItems(atlas, items); // shaped glyphs + COLR emoji layers
      return _MainDoc(
        GPUTextLayout.compute(items),
        runs,
        [for (final r in runs) List<double>.of(r.color)],
        atlas,
      );
    });

    // Phase 2 only when the width actually changed; otherwise reuse the lines.
    final relaidOut = md.lastWidth != _width;
    if (relaidOut) {
      md.layout.reflow(
        _width,
        ParagraphStyle(maxWidth: _width, lineHeight: _lineHeight),
      );
      md.lastWidth = _width;
    }
    final lines = md.layout.lines;

    // Recolour every run in place (highlight overrides all colours; un-toggle
    // restores each run's original), then time PHASE 3 (emit) on its own.
    for (var ri = 0; ri < md.runs.length; ri++) {
      final target = _highlight ? _highlightColor : md.baseColors[ri];
      for (var i = 0; i < 4; i++) {
        md.runs[ri].color[i] = target[i];
      }
    }
    final sw = Stopwatch()..start();
    final emitted = md.layout.emit(md.atlas);
    sw.stop();

    // Same optimisation as the worker path: upload the (stable) atlas once.
    final atlasKey = '${doc.id}#main';
    final needAtlas = _atlasKeyOnGpu != atlasKey;
    _renderFrame(
      curves: needAtlas ? md.atlas.curves : null,
      rows: needAtlas ? md.atlas.rows : null,
      instances: emitted.instances,
      glyphs: emitted.glyphCount,
      lines: lines.lines.length,
      width: _width,
      height: lines.height,
      ms: sw.elapsedMicroseconds / 1000.0,
      label: autoInline
          ? 'auto-routed inline · small doc — worker round-trip skipped'
          : relaidOut
              ? 'UI thread · layout+emit — blocks the UI'
              : 're-emit only · no relayout (display phase)',
      good: autoInline || !relaidOut,
      placeholders: emitted.placeholders,
    );
    if (needAtlas) _atlasKeyOnGpu = atlasKey;
  }

  void _renderFrame({
    Float32List? curves,
    Uint32List? rows,
    required Float32List instances,
    required int glyphs,
    required int lines,
    required double width,
    required double height,
    required double ms,
    required String label,
    required bool good,
    required List<PlaceholderBox> placeholders,
  }) {
    if (!mounted) return;
    _placeholders = placeholders;
    // Atlas (curves/rows) is uploaded only when supplied — once per doc; every
    // reflow re-uploads just the instance buffer. The window renders from the
    // cached atlas + latest instances, on this frame and on every scroll tick.
    if (curves != null && rows != null) _surface?.setAtlas(curves, rows);
    _surface?.setInstances(instances);
    _glyphCount = glyphs;
    _docWidth = width;
    _docHeight = height;
    if (_scroll.hasClients) {
      final max = (height - _viewportH).clamp(0.0, double.infinity);
      if (_scroll.offset > max) _scroll.jumpTo(max);
    }
    setState(() => _stats = _Stats(glyphs, lines, ms, label, good));
    _renderWindow();
  }

  /// Rasterize just the on-screen window from the uploaded drawable, translated
  /// by the scroll offset (cam.y). One viewport-sized texture, reused on scroll.
  void _renderWindow() {
    final surface = _surface;
    if (surface == null || _glyphCount == 0 || _viewportH <= 0) return;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    // Record the exact logical height this image is rasterized for so the
    // display can size to it (not the live `vh`) — see [_winH].
    _winH = _viewportH;
    _window.value = surface.renderAt(
      devW: (_docWidth * _dpr).round().clamp(1, _maxDevicePx),
      devH: (_viewportH * _dpr).round().clamp(1, _maxDevicePx),
      dpr: _dpr,
      camY: -offset * _dpr,
    );
  }

  _Doc? get _current {
    final id = _currentId;
    if (id == null) return null;
    for (final d in _docs) {
      if (d.id == id) return d;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Low-level — layout thread & display-phase reuse'),
      ),
      body: _error != null
          ? Center(child: Text('Failed to load: $_error'))
          : !_ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _topBar(),
                const Divider(height: 1),
                Expanded(child: _documentView()),
                _bottomBar(),
              ],
            ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          const Text('Document', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          for (final d in _docs)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(d.label),
                selected: _currentId == d.id,
                onSelected: _switching ? null : (_) => _selectDoc(d),
              ),
            ),
          const Spacer(),
          if (_surface == null)
            const Tooltip(
              message: 'flutter_gpu unavailable — showing CPU-text fallback',
              child: Chip(
                avatar: Icon(Icons.info_outline, size: 16),
                label: Text('CPU fallback'),
              ),
            )
          else
            const Chip(
              avatar: Icon(Icons.bolt, size: 16, color: Colors.green),
              label: Text('GPU render'),
            ),
        ],
      ),
    );
  }

  Widget _documentView() {
    const bg = Color(0xFFF3F1EC);
    // No GPU: plain scrollable CPU-text preview of the (fully laid-out) doc.
    if (_surface == null) {
      return Container(
        color: bg,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Material(
              elevation: 2,
              color: Colors.white,
              child: SizedBox(width: _width, child: _cpuFallback()),
            ),
          ),
        ),
      );
    }
    return Container(
      color: bg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final vh = constraints.maxHeight;
          // Reading DPR here subscribes us to MediaQuery, so a monitor/DPR
          // change rebuilds and re-renders the window at the new scale.
          final dpr = MediaQuery.devicePixelRatioOf(context);
          if (vh != _viewportH || dpr != _dpr) {
            _viewportH = vh;
            _dpr = dpr;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => mounted ? _renderWindow() : null,
            );
          }
          final extent = _docHeight <= 0 ? vh : _docHeight;
          return Stack(
            children: [
              // Invisible scrollable spanning the FULL document height: it
              // supplies the scroll gesture + scrollbar without materializing
              // any pixels.
              Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: SizedBox(width: double.infinity, height: extent),
                ),
              ),
              // The visible window, re-rendered from the cached drawable on
              // scroll. IgnorePointer so the gesture reaches the scrollable.
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Material(
                      elevation: 2,
                      color: Colors.white,
                      child: SizedBox(
                        width: _paperWidth,
                        height: vh,
                        // Align (not a tight box) so the image takes its own
                        // rendered size: sizing the RawImage to the exact
                        // dimensions it was rasterized for (_paperWidth × _winH)
                        // makes BoxFit.fill an identity — never stretched, even
                        // for the frame where the live paper differs from a
                        // just-resized viewport.
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ValueListenableBuilder<ui.Image?>(
                            valueListenable: _window,
                            builder: (context, img, _) => img == null
                                ? const SizedBox.shrink()
                                : RawImage(
                                    image: img,
                                    width: _paperWidth,
                                    height: _winH > 0 ? _winH : vh,
                                    fit: BoxFit.fill,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Real WidgetSpan widgets, positioned over the GPU text at the
              // boxes the worker laid out. Re-placed on scroll (cheap: only
              // the visible ones are built); decorative here, so IgnorePointer
              // keeps the scroll gesture flowing.
              if (_placeholders.isNotEmpty && _placeholderWidgets.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ClipRect(
                      child: AnimatedBuilder(
                        animation: _scroll,
                        builder: (context, _) =>
                            _placeholderOverlay(constraints.maxWidth, vh),
                      ),
                    ),
                  ),
                ),
              if (_switching)
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: LinearProgressIndicator(),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _placeholderOverlay(double viewportWidth, double vh) {
    final off = _scroll.hasClients ? _scroll.offset : 0.0;
    final paperLeft =
        ((viewportWidth - _paperWidth) / 2).clamp(0.0, double.infinity);
    return Stack(
      children: [
        for (final box in _placeholders)
          if (box.index >= 0 &&
              box.index < _placeholderWidgets.length &&
              box.top + box.height >= off &&
              box.top <= off + vh) // cull to the visible window
            Positioned(
              left: paperLeft + box.left,
              top: box.top - off,
              width: box.width,
              height: box.height,
              child: _placeholderWidgets[box.index],
            ),
      ],
    );
  }

  Widget _cpuFallback() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_surface == null)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'GPU rendering needs Impeller + flutter_gpu. The layout below '
                'still ran through the low-level pipeline; this is a CPU-text '
                'preview.',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ),
          DefaultTextStyle.merge(
            style: TextStyle(
              height: _lineHeight,
              // Highlight tints the whole preview; otherwise per-span colours.
              color: _highlight ? const Color(0xFFA81C21) : null,
            ),
            child: Text.rich(
              _current?.fallback ?? const TextSpan(),
              style: _highlight
                  ? const TextStyle(color: Color(0xFFA81C21))
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final s = _stats;
    return Material(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SegmentedButton<_Where>(
                  segments: const [
                    ButtonSegment(
                      value: _Where.worker,
                      label: Text('Worker isolate'),
                      icon: Icon(Icons.bolt),
                    ),
                    ButtonSegment(
                      value: _Where.uiThread,
                      label: Text('UI thread'),
                      icon: Icon(Icons.warning_amber_rounded),
                    ),
                  ],
                  selected: {_where},
                  // Highlight forces the main-isolate path (it recolours there).
                  onSelectionChanged: _highlight
                      ? null
                      : (sel) {
                          setState(() => _where = sel.first);
                          _requestReflow();
                        },
                ),
                const SizedBox(width: 12),
                FilterChip(
                  avatar: const Icon(Icons.format_color_fill, size: 18),
                  label: const Text('Highlight (re-emit only)'),
                  selected: _highlight,
                  onSelected: (v) {
                    setState(() => _highlight = v);
                    _requestReflow();
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.straighten, size: 18),
                const SizedBox(width: 8),
                Text('Width ${_width.round()} px'),
                Expanded(
                  child: Slider(
                    min: 220,
                    max: 640,
                    value: _width,
                    onChanged: (v) {
                      setState(() => _width = v);
                      _requestReflow();
                    },
                  ),
                ),
              ],
            ),
            if (s != null)
              DefaultTextStyle.merge(
                style: const TextStyle(fontSize: 13),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _stat(Icons.text_fields, '${s.glyphs} glyphs'),
                    _stat(Icons.notes, '${s.lines} lines'),
                    _stat(
                      Icons.timer_outlined,
                      '${s.ms.toStringAsFixed(2)} ms',
                      color: s.good ? Colors.green.shade700 : Colors.orange.shade800,
                    ),
                    _Pill(s.label, good: s.good),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _stat(IconData icon, String label, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {required this.good});
  final String text;
  final bool good;
  @override
  Widget build(BuildContext context) {
    final c = good ? Colors.green : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: TextStyle(color: c.shade800, fontSize: 12)),
    );
  }
}

/// Minimal offscreen renderer: uploads a drawable (outline atlas + instance
/// buffer) and blits a ui.Image. Modeled on the dragon demo's scene, trimmed
/// to a single instance buffer.
class _GlyphSurface {
  _GlyphSurface(this._pipeline);

  final GPUTextPipeline _pipeline;
  gpu.GpuImageSurface? _surface;
  ui.Image? _image;
  gpu.DeviceBuffer? _instanceBuffer;
  AtlasTextures? _textures;
  int _count = 0;
  final List<(gpu.GpuImageSurface?, ui.Image, int)> _retired = [];
  bool _hooked = false;

  static Future<_GlyphSurface?> tryCreate() async {
    try {
      return _GlyphSurface(await GPUTextPipeline.create());
    } catch (_) {
      return null; // flutter_gpu / Impeller unavailable
    }
  }

  /// Upload a drawable (outline atlas + instance buffer) once. The instances
  /// are positioned in full-document space; [renderAt] windows into them.
  /// Upload the outline atlas. The atlas is stable per document, so call this
  /// once per doc — not per reflow.
  void setAtlas(Float32List curves, Uint32List rows) {
    _textures = uploadAtlasTextures(gpu.gpuContext, curves, rows);
  }

  /// Upload the per-reflow instance buffer (glyph positions/colours).
  void setInstances(Float32List instances) {
    _count = instances.length ~/ floatsPerInstance;
    _instanceBuffer = _count == 0 ? null : _pipeline.uploadInstances(instances);
  }

  /// Rasterize the [devW]×[devH] window of the uploaded drawable, translated by
  /// [camY] device px. Cheap enough to call on every scroll tick.
  ui.Image? renderAt({
    required int devW,
    required int devH,
    required double dpr,
    double camY = 0,
  }) {
    final instanceBuffer = _instanceBuffer;
    final textures = _textures;
    if (instanceBuffer == null ||
        textures == null ||
        _count == 0 ||
        devW <= 0 ||
        devH <= 0) {
      return _image;
    }
    final count = _count;

    var surface = _surface;
    if (surface == null || surface.width != devW || surface.height != devH) {
      surface = gpu.gpuContext.createImageSurface(
        devW.clamp(1, _maxDevicePx),
        devH.clamp(1, _maxDevicePx),
        format: _surfaceFormat(gpu.gpuContext),
      );
    }

    final frame = surface.acquireNextFrame();
    final cmd = gpu.gpuContext.createCommandBuffer();
    final target = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: frame.colorTexture,
        loadAction: gpu.LoadAction.clear,
        storeAction: gpu.StoreAction.store,
        clearValue: vm.Vector4(1, 1, 1, 1),
      ),
    );
    final pass = cmd.createRenderPass(target);
    _pipeline.renderInstances(
      pass: pass,
      frame: FrameUniforms(
        width: devW.toDouble(),
        height: devH.toDouble(),
        cam: [dpr, dpr, 0, camY],
      ),
      instances: instanceBuffer,
      instanceCount: count,
      textures: textures,
    );
    frame.present(cmd);
    cmd.submit();

    final prev = _image;
    if (prev != null) {
      _retired.add((
        identical(_surface, surface) ? null : _surface,
        prev,
        ui.PlatformDispatcher.instance.frameData.frameNumber,
      ));
      if (!_hooked) {
        _hooked = true;
        SchedulerBinding.instance.addTimingsCallback(_flushRetired);
      }
    }
    _surface = surface;
    _image = surface.currentImage;
    return _image;
  }

  void _flushRetired(List<ui.FrameTiming> timings) {
    var latest = -1;
    for (final t in timings) {
      if (t.frameNumber > latest) latest = t.frameNumber;
    }
    while (_retired.isNotEmpty && _retired.first.$3 <= latest) {
      _retired.removeAt(0).$2.dispose();
    }
    if (_retired.isEmpty && _hooked) {
      _hooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_flushRetired);
    }
  }

  void dispose() {
    if (_hooked) {
      _hooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_flushRetired);
    }
    for (final (_, img, _) in _retired) {
      img.dispose();
    }
    _retired.clear();
    _image?.dispose();
    _image = null;
    _surface = null;
  }
}

gpu.PixelFormat _surfaceFormat(gpu.GpuContext context) {
  final preferred = context.defaultColorFormat;
  if (preferred != gpu.PixelFormat.unknown &&
      context.supportsTextureFormat(preferred, renderTarget: true)) {
    return preferred;
  }
  return gpu.PixelFormat.b8g8r8a8UNormInt;
}
