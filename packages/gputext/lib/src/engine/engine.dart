// Process-wide gputext engine: GPU pipeline + font registry + the shared
// incremental glyph atlas, with ChangeNotifier readiness signaling.
//
// Two readiness gates (widgets listen and mark themselves dirty):
//   fontsReady — metrics available, layout can run (markNeedsLayout on flip)
//   gpuReady   — pipeline built, paint can render (markNeedsPaint on flip)
//
// `await GPUText.initialize(...)` in main() is the no-FOUT path; otherwise
// the first attached widget lazily kicks ensureInitialized() and repaints
// when ready. Platforms without Impeller/flutter_gpu set isSupported=false:
// widgets still lay out (fonts are pure Dart) but paint nothing.

import 'dart:ui' as ui show FontStyle, FontWeight;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gpu/gpu.dart' as gpu;

import '../atlas.dart';
import '../font.dart';
import '../paragraph.dart' as wf;
import 'pipeline.dart';
import 'shared_atlas.dart';

const _defaultFontAsset = 'assets/Lato-Regular.ttf';
const _defaultFontFamily = 'Lato';

/// Public facade.
abstract final class GPUText {
  static GPUTextEngine get instance => GPUTextEngine._instance;

  /// Load fonts and build the GPU pipeline up front (no first-frame flash).
  /// `fallbackFamilies` are tried, in order, for characters the styled
  /// family doesn't cover (after TextStyle.fontFamilyFallback).
  static Future<void> initialize({
    Map<String, String> fontAssets = const {},
    String? defaultFamily,
    List<String> fallbackFamilies = const [],
    String? emojiFontAsset,
  }) => instance._initializeWith(
    fontAssets,
    defaultFamily,
    fallbackFamilies,
    emojiFontAsset,
  );

  /// False when flutter_gpu/Impeller is unavailable; gputext widgets lay
  /// out but paint blank, so apps can fall back to stock RichText.
  static bool get isSupported => !instance.unsupported;
}

class GPUTextEngine extends ChangeNotifier {
  GPUTextEngine._();

  static final GPUTextEngine _instance = GPUTextEngine._();

  Future<void>? _initFuture;
  GPUTextPipeline? _pipeline;
  final atlas = SharedGlyphAtlas();
  final _fonts = <String, List<_FontVariant>>{};
  final _fallbackFamilies = <String>[];
  String? _defaultFamily;
  var _unsupported = false;

  AtlasTextures? _textures;
  var _texturesGeneration = -1;
  var _texturesStructureGen = 0;

  // Shared paragraph-prepare cache: identical (span, scaler) paragraphs
  // across widgets — think list items — reuse one flatten+prepare result.
  // Prepared paragraphs are width-INDEPENDENT (pretext-style prepare/layout
  // split): resizes, dry layouts, and intrinsic passes all hit one entry and
  // only rerun the cheap line walker. Entries are read-only after insertion;
  // keys embed [fontGeneration] so font registration invalidates naturally.
  static const _layoutCacheCapacity = 256;
  final _layoutCache = <Object, (List<wf.InlineItem>, wf.PreparedParagraph)>{};
  var _fontGeneration = 0;

  /// Bumped whenever font resolution could change (register/fallbacks).
  int get fontGeneration => _fontGeneration;

  // Cache observability (tests and the benchmark harness read these).
  int debugLayoutCacheHits = 0;
  int debugLayoutCacheMisses = 0;

  int get debugLayoutCacheLength => _layoutCache.length;

  void debugResetCacheCounters() {
    debugLayoutCacheHits = 0;
    debugLayoutCacheMisses = 0;
  }

  // Per-(resolution-context, code point) coverage verdicts for the widget
  // layer's uncovered-character expansion; dropped on any font churn.
  final _coverageCache = <String, Map<int, bool>>{};
  var _coverageGeneration = -1;

  /// Shared coverage-verdict map for one resolution context (family list +
  /// weight/style signature); valid until [fontGeneration] changes.
  Map<int, bool> coverageCacheFor(String contextKey) {
    if (_coverageGeneration != _fontGeneration) {
      _coverageCache.clear();
      _coverageGeneration = _fontGeneration;
    }
    return _coverageCache.putIfAbsent(contextKey, () => <int, bool>{});
  }

  (List<wf.InlineItem>, wf.PreparedParagraph)? layoutCacheGet(Object key) {
    final v = _layoutCache.remove(key);
    if (v != null) {
      _layoutCache[key] = v; // LRU touch
      debugLayoutCacheHits++;
    } else {
      debugLayoutCacheMisses++;
    }
    return v;
  }

  void layoutCachePut(
    Object key,
    (List<wf.InlineItem>, wf.PreparedParagraph) value,
  ) {
    _layoutCache[key] = value;
    if (_layoutCache.length > _layoutCacheCapacity) {
      _layoutCache.remove(_layoutCache.keys.first);
    }
  }

  bool get fontsReady => _fonts.isNotEmpty;
  bool get gpuReady => _pipeline != null;
  bool get unsupported => _unsupported;
  GPUTextPipeline get pipeline => _pipeline!;

  /// Idempotent lazy init: registers the bundled default font if none were
  /// registered, then builds the pipeline. Never throws — flips
  /// [unsupported] instead so widgets degrade to blank.
  Future<void> ensureInitialized() => _initFuture ??= _init();

  Future<void> _initializeWith(
    Map<String, String> fontAssets,
    String? defaultFamily,
    List<String> fallbackFamilies,
    String? emojiFontAsset,
  ) async {
    for (final e in fontAssets.entries) {
      await loadFontAsset(e.key, e.value);
    }
    if (defaultFamily != null) _defaultFamily = defaultFamily;
    if (fallbackFamilies.isNotEmpty) setFallbackFamilies(fallbackFamilies);
    if (emojiFontAsset != null) await loadEmojiFontAsset(emojiFontAsset);
    await ensureInitialized();
  }

  GPUFont? _emojiFont;

  /// COLR v0 font used to render single-code-point emoji natively through
  /// the coverage shader; null → all emoji delegate to the platform.
  GPUFont? get emojiFont => _emojiFont;

  /// Register (or clear, with null) the native color-emoji font.
  void registerEmojiFont(GPUFont? font) {
    assert(
      font == null || font.hasColorGlyphs,
      'Emoji font must carry COLR v0 color glyphs',
    );
    _emojiFont = font;
    _fontGeneration++;
    notifyListeners();
  }

  Future<GPUFont> loadEmojiFontAsset(String assetKey) async {
    ByteData data;
    try {
      data = await rootBundle.load(assetKey);
    } catch (_) {
      data = await rootBundle.load('packages/gputext/$assetKey');
    }
    final font = GPUFont.parse(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    registerEmojiFont(font);
    return font;
  }

  /// True when the registered emoji font has a color glyph for `cp`.
  bool nativeEmojiCovers(int cp) => _emojiFont?.colrForCodePoint(cp) != null;

  /// Engine-wide fallback chain, tried after a style's own family list.
  List<String> get fallbackFamilies => List.unmodifiable(_fallbackFamilies);

  void setFallbackFamilies(List<String> families) {
    _fallbackFamilies
      ..clear()
      ..addAll(families);
    _fontGeneration++;
    notifyListeners();
  }

  /// First font along `families` + the engine fallback chain that covers
  /// `ch`; null when no registered font does (callers then delegate the
  /// character to the platform text stack).
  GPUFont? resolveFontForChar(
    String ch, {
    List<String?> families = const [null],
    ui.FontWeight? weight,
    ui.FontStyle? fontStyle,
  }) {
    for (final family in families.followedBy(_fallbackFamilies)) {
      final font = resolveFont(family, weight: weight, fontStyle: fontStyle);
      if (font != null && font.hasGlyph(ch)) return font;
    }
    return null;
  }

  Future<void> _init() async {
    try {
      if (_fonts.isEmpty) {
        await loadFontAsset(_defaultFontFamily, _defaultFontAsset);
      }
    } catch (e) {
      debugPrint('gputext: default font load failed: $e');
    }
    try {
      _pipeline = await GPUTextPipeline.create();
    } catch (e) {
      debugPrint('gputext: GPU init failed, widgets will paint blank: $e');
      _unsupported = true;
    }
    notifyListeners();
  }

  /// Load and register a TTF from the asset bundle (bare key first, then
  /// packages/gputext/-prefixed for package consumers).
  Future<GPUFont> loadFontAsset(
    String family,
    String assetKey, {
    ui.FontWeight weight = ui.FontWeight.w400,
    ui.FontStyle style = ui.FontStyle.normal,
  }) async {
    ByteData data;
    try {
      data = await rootBundle.load(assetKey);
    } catch (_) {
      data = await rootBundle.load('packages/gputext/$assetKey');
    }
    final font = GPUFont.parse(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    registerFont(family, font, weight: weight, style: style);
    return font;
  }

  void registerFont(
    String family,
    GPUFont font, {
    ui.FontWeight weight = ui.FontWeight.w400,
    ui.FontStyle style = ui.FontStyle.normal,
  }) {
    final variants = _fonts.putIfAbsent(family, () => []);
    final w = weight.value;
    final italic = style == ui.FontStyle.italic;
    variants
      ..removeWhere((v) => v.weight == w && v.italic == italic)
      ..add(_FontVariant(w, italic, font));
    _defaultFamily ??= family;
    _fontGeneration++;
    notifyListeners();
  }

  /// Family lookup with default-family fallback and nearest weight/style
  /// matching among registered variants; null while no fonts loaded.
  GPUFont? resolveFont(
    String? family, {
    ui.FontWeight? weight,
    ui.FontStyle? fontStyle,
  }) {
    var variants = family != null ? _fonts[family] : null;
    if (variants == null || variants.isEmpty) {
      final def = _defaultFamily;
      variants = def != null ? _fonts[def] : null;
    }
    if (variants == null || variants.isEmpty) return null;
    final targetW = (weight ?? ui.FontWeight.w400).value;
    final italic = fontStyle == ui.FontStyle.italic;
    _FontVariant? best;
    var bestScore = 1 << 30;
    for (final v in variants) {
      final score =
          (v.weight - targetW).abs() + (v.italic == italic ? 0 : 1000);
      if (score < bestScore) {
        bestScore = score;
        best = v;
      }
    }
    return best?.font;
  }

  AtlasTextureUploader? _uploader;

  /// Current curve/row textures, incrementally re-uploaded when the atlas
  /// has grown. Null until the atlas has any glyph data.
  AtlasTextures? prepareTextures() {
    if (atlas.isEmpty) return null;
    if (_texturesStructureGen != atlas.structureGeneration) {
      // Compaction moved existing texels. AtlasTextureUploader only ever
      // appends, and its in-place overwrite of a live texture is safe only
      // because the prefix is immutable — which compaction just broke. Drop it
      // and build fresh textures; draws still in flight keep the old ones alive
      // through their command buffers, exactly as retired surfaces do.
      _uploader = null;
      _textures = null;
      _texturesGeneration = -1;
      _texturesStructureGen = atlas.structureGeneration;
    }
    if (_texturesGeneration != atlas.generation) {
      _uploader ??= AtlasTextureUploader();
      _textures = _uploader!.upload(gpu.gpuContext, atlas.curves, atlas.rows);
      _texturesGeneration = atlas.generation;
    }
    return _textures;
  }

  // ---- atlas eviction ----

  /// Curve floats the atlas may hold before it compacts. 4 bytes each on the
  /// CPU and 8 on the GPU, so the default is ~2 MB / ~4 MB. null disables
  /// eviction entirely (the pre-eviction behaviour: the atlas only ever grows).
  ///
  /// Nothing else bounds the atlas over an app's lifetime: every distinct font
  /// — including every variable-font instance — bands its own copy of every
  /// glyph it touches. [GPUFont.variationQuantizationSteps] caps how many
  /// instances a single animating axis can mint, but not how many axes,
  /// families, or instances an app visits before the user navigates away.
  int? atlasCurveFloatBudget = 512 * 1024;

  final _atlasClients = <AtlasFontUser>{};
  var _sweepScheduled = false;
  var _nextSweepAt = 0;
  // Bumped whenever the live client set changes. A sweep can only reclaim
  // something if the atlas grew or a client left, so this is the second of the
  // two signals that unblock the hysteresis below.
  var _clientEpoch = 0;
  var _sweptAtClientEpoch = -1;

  /// Register a live consumer of the atlas. Its fonts are retained by
  /// [compactAtlas]; everything else is fair game. Render objects do this on
  /// attach and undo it on detach.
  void registerAtlasClient(AtlasFontUser client) {
    if (_atlasClients.add(client)) _clientEpoch++;
  }

  void unregisterAtlasClient(AtlasFontUser client) {
    if (_atlasClients.remove(client)) _clientEpoch++;
  }

  /// Compactions that actually reclaimed something.
  int debugAtlasCompactions = 0;

  /// Sweeps attempted, reclaiming or not. Hysteresis keeps this from tracking
  /// the frame count when the live set alone exceeds the budget.
  int debugAtlasSweeps = 0;

  /// Ask for a compaction at the next frame boundary if the atlas is over
  /// [atlasCurveFloatBudget]. Cheap enough to call on every emit.
  ///
  /// Deferred rather than immediate because a compaction invalidates every
  /// rowBase, and mid-paint some render objects have already emitted instances
  /// against the current layout. After a frame, all of them re-emit.
  void scheduleAtlasSweepIfNeeded() {
    if (_sweepScheduled) return;
    final budget = atlasCurveFloatBudget;
    if (budget == null || atlas.curveFloatCount <= budget) return;
    // Nothing has changed since the last sweep decided it could not help:
    // the atlas hasn't grown past the back-off mark and no client has left.
    // Without this a live set larger than the budget would compact every frame,
    // and each compaction re-emits and re-uploads everything.
    if (_clientEpoch == _sweptAtClientEpoch &&
        atlas.curveFloatCount < _nextSweepAt) {
      return;
    }
    _sweepScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _sweepScheduled = false;
      compactAtlas();
    });
  }

  /// Drop every glyph whose font no client still uses, and compact what's left.
  /// Returns the curve floats reclaimed.
  ///
  /// Safe to call at any frame boundary. Evicting a font that is in fact still
  /// on screen is not incorrect — its owner re-emits and re-bands it — so a
  /// missing [registerAtlasClient] costs performance, never correctness.
  int compactAtlas() {
    debugAtlasSweeps++;
    final keep = <GPUFont>{};
    for (final client in _atlasClients) {
      client.visitAtlasFonts(keep.add);
    }
    final reclaimed = atlas.retainFonts(keep);
    if (reclaimed > 0) {
      debugAtlasCompactions++;
      // Re-emit (rowBase moved) and re-render (cached images are still valid
      // pixels, but the instance buffers that produced them are not).
      notifyListeners();
    }
    _sweptAtClientEpoch = _clientEpoch;
    final budget = atlasCurveFloatBudget ?? 0;
    final doubled = atlas.curveFloatCount * 2;
    _nextSweepAt = doubled > budget ? doubled : budget;
    return reclaimed;
  }

  /// Test/hot-restart hook: drop GPU state so the next ensureInitialized
  /// rebuilds it (fonts and atlas are kept — they're pure Dart).
  @visibleForTesting
  void debugResetGpu() {
    _initFuture = null;
    _pipeline = null;
    _textures = null;
    _texturesGeneration = -1;
    _texturesStructureGen = 0;
    _uploader = null;
    _unsupported = false;
  }
}

/// Something that keeps atlas glyphs alive. Implemented by render objects; see
/// [GPUTextEngine.registerAtlasClient].
abstract interface class AtlasFontUser {
  /// Call `visit` with every font this user still needs banded.
  void visitAtlasFonts(void Function(GPUFont font) visit);
}

class _FontVariant {
  const _FontVariant(this.weight, this.italic, this.font);

  final int weight; // 100..900
  final bool italic;
  final GPUFont font;
}
