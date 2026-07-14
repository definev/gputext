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
import '../native/harfbuzz_bindings.dart';
import '../native/system_fonts.dart';
import '../paragraph.dart' as wf;
import '../text/harfbuzz_shaper.dart';
import '../text/metrics_cache.dart';
import '../text/shaped_run.dart';
import '../text/shaper.dart';
import 'color_atlas.dart';
import 'color_atlas_texture.dart';
import 'pipeline.dart';
import 'shared_atlas.dart';

const _defaultFontAsset = 'assets/Lato-Regular.ttf';
const _defaultFontFamily = 'Lato';

abstract final class GPUText {
  static GPUTextEngine get instance => GPUTextEngine._instance;

  /// True after a successful HarfBuzz native load (read-only diagnostic).
  static bool get harfBuzzAvailable => instance._harfBuzzAvailable;

  /// Load fonts and build the GPU pipeline up front (no first-frame flash).
  /// `fallbackFamilies` are tried, in order, for characters the styled
  /// family doesn't cover (after TextStyle.fontFamilyFallback).
  /// [systemFonts] maps a gputext family name to an OS font family to resolve
  /// natively (opt-in; see [GPUTextEngine.loadSystemFont]). [useSystemDefaultFont]
  /// additionally registers the platform default UI font under `system-ui`.
  static Future<void> initialize({
    Map<String, String> fontAssets = const {},
    String? defaultFamily,
    List<String> fallbackFamilies = const [],
    String? emojiFontAsset,
    Map<String, String> systemFonts = const {},
    bool useSystemDefaultFont = false,
  }) => instance._initializeWith(
    fontAssets,
    defaultFamily,
    fallbackFamilies,
    emojiFontAsset,
    systemFonts,
    useSystemDefaultFont,
  );

  /// False when flutter_gpu/Impeller is unavailable; gputext widgets lay
  /// out but paint blank, so apps can fall back to stock RichText.
  static bool get isSupported => !instance.unsupported;

  /// True when the platform can supply native system fonts (macOS/iOS/Android
  /// with the resolver loaded). See [GPUTextEngine.systemFontsAvailable].
  static bool get systemFontsAvailable => instance.systemFontsAvailable;
}

/// A multi-codepoint emoji cluster resolved to one ligated color glyph — the
/// output of [GPUTextEngine.emojiGlyphForCluster]. Exactly one of [layers]
/// (COLR v0/v1 flat) or [bitmapGlyphId] (sbix/CBDT) carries the color data.
class ResolvedEmojiGlyph {
  const ResolvedEmojiGlyph({
    required this.advanceUnits,
    this.layers = const [],
    this.bitmapGlyphId,
  });

  /// The ligated cluster's advance, in font units.
  final double advanceUnits;

  /// COLR color layers (bottom first); empty for a bitmap glyph.
  final List<ColrLayer> layers;

  /// Color-bitmap glyph id; null for a COLR glyph.
  final int? bitmapGlyphId;
}

class GPUTextEngine extends ChangeNotifier {
  GPUTextEngine._() {
    // Variant instances LRU-evicted from a base font's cache must release
    // their HB face/metrics immediately — waiting for GC leaves native
    // handles pinned while the atlas still references the variant.
    GPUFont.onVariantEvicted = _onVariantEvicted;
    // Route outline extraction through HarfBuzz (glyf/CFF/CFF2/CID/variable,
    // one code path). Returns null until the shaper is loaded and for
    // unsupported platforms, so glyphOutlineById falls back to the pure-Dart
    // parser (which also keeps headless/VM tests on the in-Dart path).
    GPUFont.outlineProvider = _drawGlyphOutline;
  }

  List<double>? _drawGlyphOutline(GPUFont font, int gid) =>
      _shaper?.drawGlyphOutline(font, gid);

  void _onVariantEvicted(GPUFont variant) {
    // Null when shaping never ran (no native caches to drop). Don't force a
    // HarfBuzz load — that would throw on an unsupported platform mid-evict.
    _shaper?.evictFont(variant);
    debugClearSegmentMetricsFor(variant);
    // The evicted variant's outlines are now dead weight in the shared atlas.
    // Reclaiming them means a compaction, which relocates every rowBase (global
    // re-emit) and rebuilds both textures — far too heavy to run per eviction.
    // Batch instead: sweep only once enough evicted variants have piled up. A
    // bounded animation (<= variantCacheCapacity distinct instances) never
    // evicts, so it never reaches here; only genuine churn past the LRU does.
    _deadVariants.add(variant);
    if (_deadVariants.length >= _variantSweepBatch) _scheduleForcedAtlasSweep();
  }

  static final GPUTextEngine _instance = GPUTextEngine._();

  Future<void>? _initFuture;
  GPUTextPipeline? _pipeline;
  final atlas = SharedGlyphAtlas();

  /// Shared RGBA8 atlas for color-bitmap (emoji) glyphs. Parallel to [atlas]
  /// but sampled by the color pipeline rather than integrated as coverage.
  /// Populated only once a color-bitmap emoji font is registered, so apps that
  /// never use sbix/CBDT emoji pay nothing for it.
  final colorAtlas = SharedColorAtlas();
  final _colorAtlasTexture = ColorAtlasTexture();

  final _fonts = <String, List<_FontVariant>>{};
  final _fallbackFamilies = <String>[];
  String? _defaultFamily;
  var _unsupported = false;

  /// Active text shaper (HarfBuzz, resolved on first access).
  TextShaper get shaper {
    _ensureShaper();
    return _shaper!;
  }

  TextShaper? _shaper;
  var _shaperResolved = false;
  var _harfBuzzAvailable = false;

  /// Replace the shaper (tests). Marks resolution done so auto-load won't
  /// overwrite.
  set shaper(TextShaper value) {
    _shaper = value;
    _shaperResolved = true;
  }

  /// Load HarfBuzz on first shaping. gputext has no fallback shaper: a
  /// platform whose native library cannot load throws here rather than
  /// silently rendering with a lesser engine.
  void _ensureShaper() {
    if (_shaperResolved) return;
    final hb = HarfBuzzBindings.tryLoad();
    if (hb == null) {
      final detail = HarfBuzzBindings.lastLoadError;
      throw UnsupportedError(
        'gputext requires the HarfBuzz native library, which failed to load '
        'on this platform.'
        '${detail == null ? '' : '\n$detail'}',
      );
    }
    _shaper = HarfBuzzShaper(hb);
    _harfBuzzAvailable = true;
    _shaperResolved = true;
  }

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

  /// UTF-16 code units the layout cache may retain across entries. The entry
  /// cap alone bounds count, not bytes — 256 huge documents would otherwise
  /// pin hundreds of MB of shaped runs.
  static const _layoutCacheCharBudget = 512 * 1024;
  final _layoutCache = <Object, (List<wf.InlineItem>, wf.PreparedParagraph)>{};
  final _layoutCacheCosts = <Object, int>{};
  var _layoutCacheChars = 0;
  var _fontGeneration = 0;

  /// Bumped whenever font resolution could change (register/fallbacks).
  int get fontGeneration => _fontGeneration;

  /// Every cache key embeds [fontGeneration], so a bump makes all current
  /// entries unreachable-by-lookup; drop them now rather than letting dead
  /// entries (which pin fonts and span trees) wait out 256 LRU insertions.
  void _bumpFontGeneration() {
    _fontGeneration++;
    _layoutCache.clear();
    _layoutCacheCosts.clear();
    _layoutCacheChars = 0;
    _emojiClusterCache
        .clear(); // a new/changed emoji font may ligate differently
  }

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

  /// Distinct style contexts retained (LRU). Apps that synthesize unbounded
  /// family/weight combinations (style animation, per-user settings) must not
  /// grow this map for the process lifetime; verdicts are cheap to recompute.
  static const _coverageCacheMaxContexts = 128;

  /// Shared coverage-verdict map for one resolution context (family list +
  /// weight/style signature); valid until [fontGeneration] changes.
  /// LinkedHashMap insertion order is the LRU order: hits re-insert, overflow
  /// drops [Map.keys.first] so a hot context is not wiped by a new one.
  Map<int, bool> coverageCacheFor(String contextKey) {
    if (_coverageGeneration != _fontGeneration) {
      _coverageCache.clear();
      _coverageGeneration = _fontGeneration;
    }
    final existing = _coverageCache.remove(contextKey);
    if (existing != null) {
      _coverageCache[contextKey] = existing; // LRU touch
      return existing;
    }
    while (_coverageCache.length >= _coverageCacheMaxContexts) {
      _coverageCache.remove(_coverageCache.keys.first);
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
    (List<wf.InlineItem>, wf.PreparedParagraph) value, {
    int cost = 0,
  }) {
    final replaced = _layoutCacheCosts.remove(key);
    if (replaced != null) {
      _layoutCache.remove(key);
      _layoutCacheChars -= replaced;
    }
    _layoutCache[key] = value;
    _layoutCacheCosts[key] = cost;
    _layoutCacheChars += cost;
    while (_layoutCache.length > _layoutCacheCapacity ||
        (_layoutCacheChars > _layoutCacheCharBudget &&
            _layoutCache.length > 1)) {
      final evict = _layoutCache.keys.first;
      _layoutCache.remove(evict);
      _layoutCacheChars -= _layoutCacheCosts.remove(evict) ?? 0;
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
    Map<String, String> systemFonts,
    bool useSystemDefaultFont,
  ) async {
    for (final e in fontAssets.entries) {
      await loadFontAsset(e.key, e.value);
    }
    for (final e in systemFonts.entries) {
      await loadSystemFont(e.key, systemName: e.value);
    }
    if (useSystemDefaultFont) await loadDefaultSystemFont();
    if (defaultFamily != null) _defaultFamily = defaultFamily;
    if (fallbackFamilies.isNotEmpty) setFallbackFamilies(fallbackFamilies);
    if (emojiFontAsset != null) await loadEmojiFontAsset(emojiFontAsset);
    await ensureInitialized();
  }

  /// True when the platform has a native system-font backend loaded
  /// (macOS/iOS/Android). Even when true, a specific family may still resolve
  /// to null — e.g. a CFF-only font, or an iOS system font whose tables the OS
  /// declines to hand over.
  bool get systemFontsAvailable => SystemFontProvider.available;

  GPUFont? _emojiFont;

  /// COLR v0 font for single-code-point emoji via the coverage shader;
  /// null → all emoji delegate to the platform.
  GPUFont? get emojiFont => _emojiFont;

  /// Register (or clear with null) the color-emoji font. Accepts COLR (vector)
  /// or sbix/CBDT (bitmap) color fonts; registering a bitmap font is itself the
  /// opt-in — its glyphs then render through the GPU color pipeline. Apps that
  /// want platform-delegated emoji instead simply don't register one.
  void registerEmojiFont(GPUFont? font) {
    assert(
      font == null || font.hasColorGlyphs || font.hasBitmapGlyphs,
      'Emoji font must carry COLR v0 or color-bitmap (sbix/CBDT) glyphs',
    );
    _emojiFont = font;
    _bumpFontGeneration();
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

  /// True when the registered emoji font can render `cp` on the GPU — a COLR
  /// glyph, or a color-bitmap (sbix/CBDT) strike. Such emoji stay in-text
  /// instead of delegating to the platform.
  bool nativeEmojiCovers(int cp) {
    final font = _emojiFont;
    if (font == null) return false;
    if (font.colrForCodePoint(cp) != null) return true;
    // Coverage is size-independent — any nominal ppem confirms a strike exists.
    if (font.bitmapGlyphForCodePoint(cp, targetPpem: 64) != null) return true;
    return false;
  }

  // Multi-codepoint emoji clusters resolved to a single ligated color glyph.
  // Keyed by cluster string; a shape+coverage probe is paid once per distinct
  // cluster per font generation (cleared in [_bumpFontGeneration]).
  final _emojiClusterCache = <String, ResolvedEmojiGlyph?>{};

  /// Resolve a multi-codepoint emoji cluster (ZWJ sequence, flag, keycap,
  /// skin-tone) to the single color glyph its emoji font ligates it to, so it
  /// can render on the GPU through the same COLR / bitmap pipeline as a
  /// single-codepoint emoji. Null when there is no emoji font, the font does not
  /// ligate the sequence to one glyph, or that glyph has no color coverage
  /// (caller then delegates the cluster to the platform text stack).
  ResolvedEmojiGlyph? emojiGlyphForCluster(String cluster) {
    final cached = _emojiClusterCache[cluster];
    if (cached != null || _emojiClusterCache.containsKey(cluster)) {
      return cached;
    }
    final resolved = _resolveEmojiCluster(cluster);
    _emojiClusterCache[cluster] = resolved;
    return resolved;
  }

  ResolvedEmojiGlyph? _resolveEmojiCluster(String cluster) {
    final font = _emojiFont;
    if (font == null) return null;
    ShapedGlyphRun shaped;
    try {
      shaped = shaper.shape(
        // Glyph-id resolution is ppem-independent; shape once at a nominal size.
        ShapeRequest(font: font, text: cluster, fontSizePx: 64),
      );
    } catch (_) {
      return null; // shaper unavailable (unsupported platform) — delegate
    }
    // The font ligates a supported sequence to exactly one glyph; anything else
    // (a partial/unsupported sequence shaping to several glyphs) is delegated.
    if (shaped.glyphs.length != 1) return null;
    final gid = shaped.glyphs.first.glyphId;
    if (gid == 0) return null; // .notdef
    final advance = font.advanceOfGlyphId(gid);
    final layers = font.colrForGlyphId(gid);
    if (layers != null) {
      return ResolvedEmojiGlyph(advanceUnits: advance, layers: layers);
    }
    if (font.hasBitmapGlyphs &&
        font.bitmapGlyphForId(gid, targetPpem: 64) != null) {
      return ResolvedEmojiGlyph(advanceUnits: advance, bitmapGlyphId: gid);
    }
    return null;
  }

  /// Decode + pack the color-bitmap glyph [glyphId] of [font] at [targetPpem]
  /// into [colorAtlas] if absent (async PNG decode). On a newly packed glyph
  /// the atlas generation bumps and listeners are notified to re-render — the
  /// same deferral as async font load.
  void ensureBitmapGlyph(GPUFont font, int glyphId, double targetPpem) {
    final before = colorAtlas.generation;
    colorAtlas.ensure(font, glyphId, targetPpem).then((_) {
      if (colorAtlas.generation != before) notifyListeners();
    });
  }

  /// Upload the color atlas to its GPU texture (on generation change). Null
  /// while empty. Paired with [pipeline.renderColorInstances].
  gpu.Texture? prepareColorTexture() =>
      _colorAtlasTexture.prepare(gpu.gpuContext, colorAtlas);

  /// Engine-wide fallback chain, tried after a style's own family list.
  List<String> get fallbackFamilies => List.unmodifiable(_fallbackFamilies);

  void setFallbackFamilies(List<String> families) {
    _fallbackFamilies
      ..clear()
      ..addAll(families);
    _bumpFontGeneration();
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

  /// First font along `families` + the engine fallback chain that covers EVERY
  /// code point in [clusterRunes] (a base plus its combining marks), so the
  /// grapheme cluster shapes in one font and the marks stay attached to their
  /// base. Whitespace / zero-width runes don't constrain the choice. Null when
  /// no single registered font covers the whole cluster.
  GPUFont? resolveFontForCluster(
    List<int> clusterRunes, {
    List<String?> families = const [null],
    ui.FontWeight? weight,
    ui.FontStyle? fontStyle,
  }) {
    for (final family in families.followedBy(_fallbackFamilies)) {
      final font = resolveFont(family, weight: weight, fontStyle: fontStyle);
      if (font == null) continue;
      var coversAll = true;
      for (final r in clusterRunes) {
        if (r == 0x20 || r == 0x0A || isZeroWidthCodePoint(r)) continue;
        if (!font.hasGlyphForRune(r)) {
          coversAll = false;
          break;
        }
      }
      if (coversAll) return font;
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

  /// Resolve an OS-installed font family via the native resolver and register
  /// it under [family]. [systemName] is the OS family to look up (defaults to
  /// [family]) — pass it when the gputext name differs from the OS name.
  ///
  /// Returns null (never throws) when the platform has no system-font backend,
  /// the font is unavailable, or it uses CFF/PostScript outlines gputext cannot
  /// render; the caller then keeps whatever fallback it had. Call once per
  /// weight/style variant, mirroring [registerFont].
  Future<GPUFont?> loadSystemFont(
    String family, {
    String? systemName,
    ui.FontWeight weight = ui.FontWeight.w400,
    ui.FontStyle style = ui.FontStyle.normal,
  }) async {
    final provider = SystemFontProvider.tryLoad();
    if (provider == null) return null;
    final bytes = provider.fontData(
      systemName ?? family,
      weight: weight.value,
      italic: style == ui.FontStyle.italic,
    );
    return _registerSystemBytes(
      family,
      bytes,
      weight,
      style,
      systemName ?? family,
    );
  }

  /// Resolve the platform default UI font (San Francisco on Apple, Roboto on
  /// Android) and register it under [family]. Same null-on-unavailable contract
  /// as [loadSystemFont].
  Future<GPUFont?> loadDefaultSystemFont({
    String family = 'system-ui',
    ui.FontWeight weight = ui.FontWeight.w400,
    ui.FontStyle style = ui.FontStyle.normal,
  }) async {
    final provider = SystemFontProvider.tryLoad();
    if (provider == null) return null;
    final bytes = provider.defaultFontData(
      weight: weight.value,
      italic: style == ui.FontStyle.italic,
    );
    return _registerSystemBytes(family, bytes, weight, style, 'system default');
  }

  /// Parse resolver [bytes] and register under [family]; null on absent bytes or
  /// a parse failure (e.g. an unexpected CFF face slipping through). [label] is
  /// only for the diagnostic message.
  GPUFont? _registerSystemBytes(
    String family,
    Uint8List? bytes,
    ui.FontWeight weight,
    ui.FontStyle style,
    String label,
  ) {
    if (bytes == null) return null;
    final GPUFont font;
    try {
      font = GPUFont.parse(bytes);
    } catch (e) {
      debugPrint('gputext: system font "$label" parse failed: $e');
      return null;
    }
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
    // A re-register replaces the old variant: release its shaper caches and
    // reclaim its atlas entries, exactly as unregisterFont would.
    final replaced = variants
        .where((v) => v.weight == w && v.italic == italic && v.font != font)
        .toList(growable: false);
    variants
      ..removeWhere((v) => v.weight == w && v.italic == italic)
      ..add(_FontVariant(w, italic, font));
    final evictFont = _shaper?.evictFont ?? (_) {};
    for (final v in replaced) {
      v.font.releaseShaperCaches(
        evictFont,
        onEach: debugClearSegmentMetricsFor,
      );
    }
    if (replaced.isNotEmpty) _scheduleForcedAtlasSweep();
    _defaultFamily ??= family;
    _bumpFontGeneration();
    notifyListeners();
  }

  /// Remove a registered font family, or a single weight/style variant.
  ///
  /// When [weight] and [style] are both omitted, the entire [family] is
  /// removed. Otherwise only the matching variant is removed. Evicts HarfBuzz
  /// face caches and segment metrics for removed fonts (including variable
  /// variants), bumps [fontGeneration], and clears coverage cache.
  void unregisterFont(
    String family, {
    ui.FontWeight? weight,
    ui.FontStyle? style,
  }) {
    final variants = _fonts[family];
    if (variants == null || variants.isEmpty) return;

    final List<_FontVariant> removed;
    if (weight == null && style == null) {
      removed = List<_FontVariant>.from(variants);
      _fonts.remove(family);
    } else {
      final w = (weight ?? ui.FontWeight.w400).value;
      final italic = (style ?? ui.FontStyle.normal) == ui.FontStyle.italic;
      removed = variants
          .where((v) => v.weight == w && v.italic == italic)
          .toList(growable: false);
      variants.removeWhere((v) => v.weight == w && v.italic == italic);
      if (variants.isEmpty) _fonts.remove(family);
    }
    if (removed.isEmpty) return;

    // Null-safe: evicting native caches must not force a HarfBuzz load.
    final evictFont = _shaper?.evictFont ?? (_) {};
    for (final v in removed) {
      v.font.releaseShaperCaches(
        evictFont,
        onEach: debugClearSegmentMetricsFor,
      );
    }

    if (_defaultFamily == family && !_fonts.containsKey(family)) {
      _defaultFamily = _fonts.isEmpty ? null : _fonts.keys.first;
    }
    _coverageCache.clear();
    _coverageGeneration = -1;
    _bumpFontGeneration();
    // Atlas entries key on the font object and would otherwise pin it (and,
    // through the shaper's Expando, its native HB state) until a budget
    // sweep happens to run; reclaim at the next frame regardless of budget.
    _scheduleForcedAtlasSweep();
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

  // Atlas eviction

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

  // Variable-font instances LRU-evicted from their base's variant cache (see
  // [_onVariantEvicted]). Their banded outlines linger in the shared atlas
  // until a compaction drops them; batching bounds the atlas footprint of dead
  // instances without compacting on every eviction. Cleared by [compactAtlas].
  final _deadVariants = <GPUFont>{};

  /// Evicted variants to accumulate before an eviction-triggered compaction is
  /// worth its global re-emit. Kept below [GPUFont.variantCacheCapacity] so the
  /// dead-instance footprint stays roughly the cache size plus this.
  static const _variantSweepBatch = 16;

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

  /// Like [scheduleAtlasSweepIfNeeded] but unconditional: used when fonts are
  /// unregistered or replaced, where the entries to reclaim may sit under the
  /// curve-float budget forever (blank entries contribute zero floats). Asks
  /// for a frame so the sweep runs even from an otherwise idle app.
  void _scheduleForcedAtlasSweep() {
    if (_sweepScheduled) return;
    // With no live clients nothing is mid-paint against current rowBases, so
    // reclaim synchronously. This is also the binding-free path (pure Dart
    // tests, headless use): clients are render objects, which imply a
    // binding, so SchedulerBinding is safe to touch below.
    if (_atlasClients.isEmpty) {
      compactAtlas();
      return;
    }
    _sweepScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _sweepScheduled = false;
      compactAtlas();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
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
    // Reclaimed if dead, kept if a client still uses them — either way the
    // batch counter resets, since retainFonts consulted the authoritative
    // keep-set above rather than this hint.
    _deadVariants.clear();
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
