// GPUTEXT_DEMO=bench — the RichText vs GPURichText benchmark runner.
//
// Orchestration order: cold init (must be first — main.dart skips the eager
// GPUText.initialize() in bench mode) → font setup → CPU tier → atlas
// cold/warm → frame scenarios × engines → memory tier → visual tier →
// sanity checks → stdout report → exit(0).
//
// Env knobs: GPUTEXT_BENCH_QUICK=1 (short windows), GPUTEXT_BENCH_FILTER=
// comma-separated id prefixes, GPUTEXT_BENCH_HOLD=1 (don't exit, for
// interactive inspection). Keep the window foregrounded during a run —
// background throttling corrupts the numbers.

import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kProfileMode, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;

import 'package:gputext/gputext.dart';

import 'corpus.dart';
import 'cpu_bench.dart';
import 'frame_recorder.dart';
import 'memory_probe.dart';
import 'report.dart';
import 'scenarios.dart';
import 'visual_bench.dart';

const _cjkSystemFontPath =
    '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
const _gsfAsset =
    'assets/Google_Sans_Flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf';

class BenchPage extends StatefulWidget {
  const BenchPage({super.key});

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage>
    with SingleTickerProviderStateMixin {
  final _recorder = FrameRecorder();
  final _report = BenchReport();
  final _visWfKey = GlobalKey();
  final _visRtKey = GlobalKey();

  late final Ticker _ticker;
  BenchContext? _ctx;
  GPUFont? _cjkFont;

  // Mounted scenario state (all frame-tick derived).
  Widget Function(int tick)? _contentBuilder;
  FrameScenario? _running;
  int _tick = 0;
  bool _dynamic = false;
  int _warmup = 0;
  int _measure = 0;
  int? _startFrame;
  int? _endFrame;
  DateTime? _measureStartWall;
  double _measuredWallMs = 0;
  Completer<void>? _windowDone;

  String _status = 'starting…';

  bool get _quick => io.Platform.environment['GPUTEXT_BENCH_QUICK'] == '1';
  bool get _hold => io.Platform.environment['GPUTEXT_BENCH_HOLD'] == '1';
  List<String> get _filterPrefixes =>
      io.Platform.environment['GPUTEXT_BENCH_FILTER']
          ?.split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList() ??
      const [];
  bool _selected(String id) =>
      _filterPrefixes.isEmpty || _filterPrefixes.any(id.startsWith);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _recorder.start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _recorder.stop();
    _ctx?.dispose();
    super.dispose();
  }

  void _progress(String s) {
    if (mounted) setState(() => _status = s);
    // ignore: avoid_print
    print('gputext-bench: $s');
  }

  void _onTick(Duration _) {
    final sc = _running;
    final ctx = _ctx;
    if (sc == null) return;
    _tick++;
    if (ctx != null) sc.onTick?.call(ctx, _tick);
    if (_tick == _warmup && _startFrame == null) {
      _startFrame = _recorder.currentFrame();
      _measureStartWall = DateTime.now();
    }
    if (_dynamic && mounted) setState(() {});
    if (_tick >= _warmup + _measure && _endFrame == null) {
      _endFrame = _recorder.currentFrame();
      final started = _measureStartWall;
      if (started != null) {
        _measuredWallMs =
            DateTime.now().difference(started).inMicroseconds / 1000;
      }
      _windowDone?.complete();
    }
  }

  Future<void> _pumpFrames(int n) async {
    for (var i = 0; i < n; i++) {
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  Future<void> _mount(Widget Function(int tick) builder) async {
    setState(() => _contentBuilder = builder);
    await _pumpFrames(1);
  }

  Future<void> _unmount() async {
    if (mounted) setState(() => _contentBuilder = null);
    await _pumpFrames(2);
  }

  ({int curves, int rows, int glyphs}) _atlasCounters() {
    final atlas = GPUText.instance.atlas;
    return (
      curves: atlas.curveFloatCount,
      rows: atlas.rowCount,
      glyphs: atlas.glyphEntryCount,
    );
  }

  Future<void> _run() async {
    try {
      _report.meta['timestamp'] = DateTime.now().toIso8601String();
      _report.meta['os'] = io.Platform.operatingSystemVersion;
      _report.meta['flutterMode'] = kProfileMode
          ? 'profile'
          : kReleaseMode
          ? 'release'
          : 'debug';
      _report.meta['dartVersion'] = io.Platform.version;
      _report.meta['quick'] = _quick;
      _report.meta['filter'] = _filterPrefixes.isEmpty
          ? null
          : _filterPrefixes.join(',');
      final view = View.of(context);
      _report.meta['dpr'] = view.devicePixelRatio;
      _report.meta['windowSize'] = [
        (view.physicalSize.width / view.devicePixelRatio).round(),
        (view.physicalSize.height / view.devicePixelRatio).round(),
      ];

      // 1. Cold init — before any other gputext use.
      if (_selected('frame.cold_init')) await _coldInit();

      // 2. Remaining fonts + settle out of the null-paragraph window.
      await _setupFonts();
      if (GPUText.instance.unsupported) {
        _report.errors.add(
          'flutter_gpu unavailable: gputext paints blank '
          'on this device; benchmark aborted',
        );
        await _finish();
        return;
      }
      await _pumpFrames(10);

      _progress('loading corpus');
      final corpus = await BenchCorpus.load();
      final ctx = BenchContext(
        corpus: corpus,
        quick: _quick,
        hasCjk: _cjkFont != null,
      );
      _ctx = ctx;

      // 3. Startup memory snapshot (before any tier allocates).
      if (_selected('mem.startup')) {
        _report.memoryResults.add({
          'id': 'mem.startup',
          'desc': 'after init, zero paragraphs mounted',
          'rssBytes': await sampleRss(),
          ...snapshotGPUText(null).toJson(),
        });
      }

      // 4. CPU tier.
      if (_selected('cpu.')) {
        final cpu = CpuTier(
          corpus: corpus,
          engine: GPUText.instance,
          quick: _quick,
          cjkFont: _cjkFont,
        );
        await cpu.run(_report, _progress);
      }

      // 5. Atlas cold/warm (must precede any other CJK paint).
      if (_selected('frame.atlas')) await _atlasColdWarm(ctx);

      // 6. Frame scenarios × engines.
      for (final sc in frameScenarios(ctx)) {
        if (!_selected(sc.id)) continue;
        if (sc.needsCjk && _cjkFont == null) continue;
        for (final engine in sc.engines) {
          await _runFrameScenario(ctx, sc, engine);
        }
      }

      // 7. Memory tier.
      if (_selected('mem.paragraphs_200')) await _memoryParagraphs(ctx);

      // 8. Visual tier.
      if (_selected('vis.')) await _visualTier(ctx);

      _sanityChecks();
    } catch (e, st) {
      _report.errors.add('run aborted: $e\n$st');
    }
    await _finish();
  }

  // ---- cold init ----

  Future<void> _coldInit() async {
    _progress('frame.cold_init');
    const span = TextSpan(
      text:
          'In my younger and more vulnerable years my father gave me some '
          'advice that I have been turning over in my mind ever since.',
      style: TextStyle(
        fontFamily: 'Lato',
        fontSize: 14,
        color: Color(0xFF000000),
      ),
    );
    final engine = GPUText.instance;
    final sw = Stopwatch()..start();
    await engine.loadFontAsset('Lato', 'assets/Lato-Regular.ttf');
    final fontMs = sw.elapsedMicroseconds / 1000;
    await engine.ensureInitialized();
    final pipelineMs = sw.elapsedMicroseconds / 1000 - fontMs;

    final start = _recorder.currentFrame();
    await _mount(
      (_) => SizedBox(width: 420, child: benchText(EngineKind.gputext, span)),
    );
    final win = await _recorder.drain(start, start + 3);
    _report.frameResults.add(
      frameResult(
        id: 'frame.cold_init',
        engine: 'gputext',
        label: 'font load → pipeline → first frame',
        desc:
            'Cold start: Lato parse+register, GPU pipeline build, then the '
            'mount frame of one paragraph (build/raster from FrameTiming)',
        path: 'pure',
        buildMs: win.buildMs,
        rasterMs: win.rasterMs,
        totalMs: win.totalMs,
        partial: win.partial,
        extra: {'fontLoadMs': fontMs, 'pipelineMs': pipelineMs},
      ),
    );
    await _unmount();

    final start2 = _recorder.currentFrame();
    await _mount(
      (_) => SizedBox(width: 420, child: benchText(EngineKind.richtext, span)),
    );
    final win2 = await _recorder.drain(start2, start2 + 3);
    _report.frameResults.add(
      frameResult(
        id: 'frame.cold_init',
        engine: 'richtext',
        label: 'first frame (bundle fonts preloaded)',
        desc:
            'Mount frame of one RichText paragraph; asset fonts are loaded '
            'by the engine at startup, so no comparable font-load split exists',
        path: 'pure',
        buildMs: win2.buildMs,
        rasterMs: win2.rasterMs,
        totalMs: win2.totalMs,
        partial: win2.partial,
      ),
    );
    await _unmount();
  }

  Future<void> _setupFonts() async {
    _progress('registering fonts (Twemoji, GoogleSansFlex, CJK)');
    final engine = GPUText.instance;
    // Cold-init may have been filtered out; make init unconditional here.
    await engine.ensureInitialized();
    if (engine.resolveFont('Lato') == null) {
      await engine.loadFontAsset('Lato', 'assets/Lato-Regular.ttf');
    }
    try {
      await engine.loadEmojiFontAsset('assets/TwemojiMozilla.ttf');
    } catch (e) {
      _report.errors.add('emoji font load failed: $e');
    }
    try {
      await engine.loadFontAsset(benchGsfFamily, _gsfAsset);
      final gsfData = await rootBundle.load(_gsfAsset);
      await (FontLoader(benchGsfFamily)..addFont(Future.value(gsfData))).load();
    } catch (e) {
      _report.errors.add('GoogleSansFlex registration failed: $e');
    }
    try {
      final bytes = await io.File(_cjkSystemFontPath).readAsBytes();
      final font = GPUFont.parse(bytes);
      engine.registerFont(benchCjkFamily, font);
      _cjkFont = font;
      await (FontLoader(
        benchCjkFamily,
      )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    } catch (e) {
      _report.meta['cjk'] = 'unavailable ($e) — CJK-pure scenarios skipped';
    }
  }

  // ---- frame scenarios ----

  Future<void> _runFrameScenario(
    BenchContext ctx,
    FrameScenario sc,
    EngineKind engine,
  ) async {
    final engineName = engine == EngineKind.gputext ? 'gputext' : 'richtext';
    _progress('${sc.id} [$engineName]');
    GPUText.instance.debugResetCacheCounters();
    RenderGPUParagraph.debugSurfaceRenders = 0;
    RenderGPUParagraph.debugSurfaceAllocs = 0;
    RenderGPUParagraph.debugSurfaceRenderSkips = 0;
    final atlasBefore = _atlasCounters();

    _running = sc;
    _tick = 0;
    _dynamic = sc.dynamicContent;
    _warmup = sc.includeMount ? 0 : ctx.warmupFrames;
    _measure = sc.includeMount ? (_quick ? 30 : 60) : ctx.measureFrames;
    _startFrame = null;
    _endFrame = null;
    _measuredWallMs = 0;
    _windowDone = Completer<void>();

    if (sc.includeMount) {
      _startFrame = _recorder.currentFrame();
      _measureStartWall = DateTime.now();
    }
    await _mount((tick) => sc.build(ctx, engine, tick));
    _ticker.start();
    try {
      await _windowDone!.future.timeout(const Duration(seconds: 120));
    } on TimeoutException {
      _report.errors.add('${sc.id} [$engineName]: measure window timed out');
      _endFrame ??= _recorder.currentFrame();
    }
    _ticker.stop();
    _running = null;

    final win = await _recorder.drain(
      _startFrame ?? 0,
      _endFrame ?? 0,
      timeout: const Duration(seconds: 15),
    );
    await _unmount();

    final atlasAfter = _atlasCounters();
    final wallMs = _measuredWallMs;
    _report.frameResults.add(
      frameResult(
        id: sc.id,
        engine: engineName,
        label: sc.label,
        desc: sc.desc,
        path: sc.path,
        buildMs: win.buildMs,
        rasterMs: win.rasterMs,
        totalMs: win.totalMs,
        partial: win.partial,
        counters: {
          'cacheHits': GPUText.instance.debugLayoutCacheHits,
          'cacheMisses': GPUText.instance.debugLayoutCacheMisses,
          'atlasCurveFloatsDelta': atlasAfter.curves - atlasBefore.curves,
          'atlasGlyphsDelta': atlasAfter.glyphs - atlasBefore.glyphs,
          'surfaceRenders': RenderGPUParagraph.debugSurfaceRenders,
          'surfaceAllocs': RenderGPUParagraph.debugSurfaceAllocs,
          'surfaceRenderSkips': RenderGPUParagraph.debugSurfaceRenderSkips,
        },
        extra: {
          if (wallMs > 0)
            'observedFps':
                (win.totalMs.length / (wallMs / 1000) * 10).roundToDouble() /
                10,
        },
      ),
    );
    if (sc.id == 'frame.static_idle' && wallMs > 0) {
      _report.meta['refreshRateHzEstimate'] ??=
          (win.totalMs.length / (wallMs / 1000)).round();
    }
    if (sc.id == 'frame.varfont_anim' && engine == EngineKind.gputext) {
      _report.memoryResults.add({
        'id': 'mem.varfont_growth',
        'desc':
            'atlas growth across the wght animation (every instance stays '
            'on screen, so eviction cannot reclaim any of it)',
        'atlasCurveFloatsDelta': atlasAfter.curves - atlasBefore.curves,
        'atlasGpuBytesDelta':
            (atlasAfter.curves -
                atlasBefore.curves +
                atlasAfter.rows -
                atlasBefore.rows) *
            4,
        'atlasGlyphsDelta': atlasAfter.glyphs - atlasBefore.glyphs,
      });
    }
  }

  // ---- atlas cold/warm (one-shot mounts, gputext + richtext) ----

  Future<void> _atlasColdWarm(BenchContext ctx) async {
    if (_cjkFont == null) {
      _report.frameResults.add({
        'id': 'frame.atlas_cold',
        'engine': 'gputext',
        'status': 'skipped',
        'desc': 'CJK font unavailable',
        'path': 'pure',
      });
      return;
    }
    final zhText = ctx.corpus.zhZhufu;
    Widget zhParagraph(EngineKind e) => SizedBox(
      width: 420,
      height: 620,
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: benchText(
          e,
          TextSpan(
            text: zhText,
            style: benchStyle(family: benchCjkFamily, size: 14),
          ),
        ),
      ),
    );
    for (final engine in EngineKind.values) {
      final engineName = engine == EngineKind.gputext ? 'gputext' : 'richtext';
      for (final phase in ['cold', 'warm']) {
        _progress('frame.atlas_$phase [$engineName]');
        GPUText.instance.debugResetCacheCounters();
        RenderGPUParagraph.debugSurfaceRenders = 0;
        RenderGPUParagraph.debugSurfaceAllocs = 0;
        RenderGPUParagraph.debugSurfaceRenderSkips = 0;
        final before = _atlasCounters();
        final start = _recorder.currentFrame();
        await _mount((_) => zhParagraph(engine));
        final win = await _recorder.drain(
          start,
          start + 5,
          timeout: const Duration(seconds: 15),
        );
        final after = _atlasCounters();
        await _unmount();
        _report.frameResults.add(
          frameResult(
            id: 'frame.atlas_$phase',
            engine: engineName,
            label: phase == 'cold'
                ? 'first mount of a full CJK corpus paragraph'
                : 'identical remount (atlas + prepare cache warm)',
            desc:
                'zh-zhufu (${zhText.length} chars, thousands of unique '
                'glyphs): cold pays banding + full curves/rows texture '
                're-upload on the gputext side',
            path: 'pure',
            buildMs: win.buildMs,
            rasterMs: win.rasterMs,
            totalMs: win.totalMs,
            partial: win.partial,
            counters: {
              'cacheHits': GPUText.instance.debugLayoutCacheHits,
              'cacheMisses': GPUText.instance.debugLayoutCacheMisses,
              'atlasCurveFloatsDelta': after.curves - before.curves,
              'atlasGlyphsDelta': after.glyphs - before.glyphs,
              'surfaceRenders': RenderGPUParagraph.debugSurfaceRenders,
              'surfaceAllocs': RenderGPUParagraph.debugSurfaceAllocs,
              'surfaceRenderSkips': RenderGPUParagraph.debugSurfaceRenderSkips,
            },
          ),
        );
        if (engine == EngineKind.gputext && phase == 'cold') {
          _report.memoryResults.add({
            'id': 'mem.atlas_cjk',
            'desc': 'atlas cost of banding the zh corpus glyph set',
            'atlasGlyphsDelta': after.glyphs - before.glyphs,
            'atlasGpuBytesDelta':
                (after.curves - before.curves + after.rows - before.rows) * 4,
          });
        }
      }
    }
  }

  // ---- memory tier ----

  Future<void> _memoryParagraphs(BenchContext ctx) async {
    final paragraphs = ctx.corpus.commentTexts(200, unique: true);
    for (final engine in EngineKind.values) {
      final engineName = engine == EngineKind.gputext ? 'gputext' : 'richtext';
      _progress('mem.paragraphs_200 [$engineName]');
      final before = await sampleRss();
      await _mount(
        (_) => SizedBox(
          width: 420,
          height: 620,
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final p in paragraphs)
                  benchText(engine, TextSpan(text: p, style: benchStyle())),
              ],
            ),
          ),
        ),
      );
      await _pumpFrames(_quick ? 30 : 60);
      final during = await sampleRss();
      final snap = engine == EngineKind.gputext && mounted
          ? snapshotGPUText(context.findRenderObject())
          : null;
      await _unmount();
      await _pumpFrames(_quick ? 30 : 60);
      final after = await sampleRss();
      _report.memoryResults.add({
        'id': 'mem.paragraphs_200',
        'engine': engineName,
        'desc':
            '200 unique paragraphs laid out and painted (single-child '
            'scroll view paints the full column). RichText row reports RSS '
            'only — engine paragraph memory is opaque from Dart.',
        'rssBeforeBytes': before,
        'rssDeltaBytes': during - before,
        'rssAfterReleaseBytes': after - before,
        if (snap != null) ...snap.toJson(),
      });
    }
  }

  // ---- visual tier ----

  Future<void> _visualTier(BenchContext ctx) async {
    final sentences = ctx.corpus.commentTexts(6);
    final para = sentences.take(3).join(' ');
    final cases = <(String, InlineSpan, TextAlign, double)>[
      (
        'vis.plain_latin',
        TextSpan(text: para, style: benchStyle()),
        TextAlign.start,
        1,
      ),
      (
        'vis.rich_styles',
        TextSpan(
          style: benchStyle(),
          children: [
            TextSpan(
              text: 'underlined ',
              style: const TextStyle(decoration: TextDecoration.underline),
            ),
            TextSpan(
              text: 'struck ',
              style: const TextStyle(decoration: TextDecoration.lineThrough),
            ),
            TextSpan(
              text: 'wavy ',
              style: const TextStyle(
                decoration: TextDecoration.underline,
                decorationStyle: TextDecorationStyle.wavy,
                decorationColor: Color(0xFFCC0000),
              ),
            ),
            TextSpan(
              text: 'highlighted ',
              style: const TextStyle(backgroundColor: Color(0xFFFFF59D)),
            ),
            TextSpan(
              text: 'shadowed',
              style: const TextStyle(
                shadows: [Shadow(offset: Offset(1.5, 1.5), blurRadius: 2)],
              ),
            ),
            TextSpan(text: ' — ${sentences[3]}'),
          ],
        ),
        TextAlign.start,
        1,
      ),
      (
        'vis.justified',
        TextSpan(text: para, style: benchStyle()),
        TextAlign.justify,
        1,
      ),
      if (_cjkFont != null)
        (
          'vis.cjk',
          TextSpan(
            text: ctx.corpus.zhZhufu.substring(0, 200),
            style: benchStyle(family: benchCjkFamily),
          ),
          TextAlign.start,
          1,
        ),
      (
        'vis.emoji_mixed',
        TextSpan(
          text: ctx.corpus.mixedAppLines.take(4).join(' '),
          style: benchStyle(),
        ),
        TextAlign.start,
        1,
      ),
      (
        'vis.zoom_4x',
        TextSpan(text: sentences[4], style: benchStyle()),
        TextAlign.start,
        4,
      ),
      (
        'vis.rich_interleave',
        complexInterleaveSpan(
          seed: para,
          tick: 0,
          paragraph: 0,
          emojiFragment: '👩‍💻 👨‍👩‍👧‍👦',
          cjkFragment: _cjkFont != null
              ? ctx.corpus.zhZhufu.substring(0, 24)
              : '価格¥12,800',
          cjkFamily: _cjkFont != null ? benchCjkFamily : null,
        ),
        TextAlign.start,
        1,
      ),
    ];
    if (!mounted) return;
    final dpr = View.of(context).devicePixelRatio;
    for (final (id, span, align, zoom) in cases) {
      _progress(id);
      Widget cell(EngineKind e) {
        final text = benchText(e, span, align: align);
        if (zoom == 1) {
          return ColoredBox(
            color: const Color(0xFFFFFFFF),
            child: SizedBox(width: 360, child: text),
          );
        }
        return ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: SizedBox(
            width: 360,
            height: 240,
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topLeft,
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                child: Transform.scale(
                  scale: zoom,
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: 360 / zoom, child: text),
                ),
              ),
            ),
          ),
        );
      }

      await _mount(
        (_) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RepaintBoundary(key: _visWfKey, child: cell(EngineKind.gputext)),
            const SizedBox(width: 16),
            RepaintBoundary(key: _visRtKey, child: cell(EngineKind.richtext)),
          ],
        ),
      );
      await _pumpFrames(15); // gputext render + heal settle
      final result = await diffPair(
        id: id,
        gputextKey: _visWfKey,
        richtextKey: _visRtKey,
        pixelRatio: dpr,
      );
      _report.visualResults.add(result);
      await _unmount();
    }
  }

  // ---- sanity + finish ----

  Map<String, Object?>? _frameEntry(String id, String engine) {
    for (final r in _report.frameResults) {
      if (r['id'] == id && r['engine'] == engine) return r;
    }
    return null;
  }

  void _sanityChecks() {
    final checks = <Map<String, Object?>>[];
    void check(String name, bool? pass, String detail) {
      if (pass == null) return; // scenario filtered out / skipped
      checks.add({'check': name, 'pass': pass, 'detail': detail});
      if (!pass) _report.errors.add('sanity: $name — $detail');
    }

    final gridShared = _frameEntry('frame.grid_shared', 'gputext');
    if (gridShared != null) {
      final hits = (gridShared['counters'] as Map?)?['cacheHits'] as int? ?? 0;
      check('grid_shared cache hits', hits >= 200, 'hits=$hits (want ≥200)');
    }
    final idle = _frameEntry('frame.static_idle', 'gputext');
    if (idle != null) {
      final p50 = ((idle['build'] as Map?)?['p50Ms'] as num?) ?? 0;
      check('static_idle build floor', p50 < 2.0, 'build p50=${p50}ms');
    }
    final zoom = _frameEntry('frame.zoom_transform', 'gputext');
    if (zoom != null) {
      // 6 paragraphs × ~18 quantized 1.25× steps ⇒ ≥30 proves step
      // re-renders actually fire (==paragraph-count means adaptive zoom
      // silently stopped and text is scaling blurry).
      final renders =
          (zoom['counters'] as Map?)?['surfaceRenders'] as int? ?? 0;
      check(
        'zoom re-renders observed',
        renders >= 30,
        'surfaceRenders=$renders (want ≥30 ≈ paragraphs × zoom steps)',
      );
    }
    Map<String, Object?>? cpu(String idPrefix) {
      for (final r in _report.cpuResults) {
        if ((r['id'] as String).startsWith(idPrefix) &&
            r['engine'] == 'gputext') {
          return r;
        }
      }
      return null;
    }

    final cold = cpu('cpu.prepare_cold');
    final warm = cpu('cpu.layout_warm');
    if (cold != null && warm != null) {
      final c = cold['medianMs'] as num? ?? 0;
      final w = warm['medianMs'] as num? ?? double.infinity;
      check(
        'prepare/layout split',
        w < c,
        'warm=${w}ms vs cold=${c}ms (want warm < cold)',
      );
    }
    var partials = 0;
    for (final r in _report.frameResults) {
      if (r['partial'] == true) partials++;
    }
    check('no partial frame windows', partials == 0, '$partials partial');
    _report.meta['sanity'] = checks;
  }

  Future<void> _finish() async {
    _progress('emitting report');
    final summary = summaryTable(_report);
    for (final line in summary.split('\n')) {
      // ignore: avoid_print
      print(line);
    }
    emitReport(_report);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (_hold) {
      _progress('done (GPUTEXT_BENCH_HOLD=1 — not exiting)');
      return;
    }
    io.exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final builder = _contentBuilder;
    return DefaultTextStyle(
      style: TextStyle(decoration: TextDecoration.none),
      child: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RepaintBoundary(
              child: Padding(
                padding: EdgeInsets.only(top: 150),
                // 48, not 44: an 18px Lato line box is 21.6px tall (1.2em), so
                // 44 minus 24 of padding left 20px and clipped the descenders.
                child: SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: GPURichText(
                      text: TextSpan(
                        text: 'gputext bench — $_status',
                        style: const TextStyle(
                          inherit: false,
                          fontSize: 18,
                          color: Colors.red,
                        ),
                      ),
                      // ellipsis only truncates a line that is not allowed to
                      // wrap; with softWrap a long status would wrap to a
                      // second line and clip vertically instead.
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                  child: builder == null ? const SizedBox() : builder(_tick),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
