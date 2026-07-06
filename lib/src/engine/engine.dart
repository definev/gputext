// Process-wide windfoil engine: GPU pipeline + font registry + the shared
// incremental glyph atlas, with ChangeNotifier readiness signaling.
//
// Two readiness gates (widgets listen and mark themselves dirty):
//   fontsReady — metrics available, layout can run (markNeedsLayout on flip)
//   gpuReady   — pipeline built, paint can render (markNeedsPaint on flip)
//
// `await Windfoil.initialize(...)` in main() is the no-FOUT path; otherwise
// the first attached widget lazily kicks ensureInitialized() and repaints
// when ready. Platforms without Impeller/flutter_gpu set isSupported=false:
// widgets still lay out (fonts are pure Dart) but paint nothing.

import 'dart:ui' as ui show FontStyle, FontWeight;

import 'package:flutter/foundation.dart';
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
abstract final class Windfoil {
  static WindfoilEngine get instance => WindfoilEngine._instance;

  /// Load fonts and build the GPU pipeline up front (no first-frame flash).
  /// `fallbackFamilies` are tried, in order, for characters the styled
  /// family doesn't cover (after TextStyle.fontFamilyFallback).
  static Future<void> initialize({
    Map<String, String> fontAssets = const {},
    String? defaultFamily,
    List<String> fallbackFamilies = const [],
    String? emojiFontAsset,
  }) =>
      instance._initializeWith(
          fontAssets, defaultFamily, fallbackFamilies, emojiFontAsset);

  /// False when flutter_gpu/Impeller is unavailable; windfoil widgets lay
  /// out but paint blank, so apps can fall back to stock RichText.
  static bool get isSupported => !instance.unsupported;
}

class WindfoilEngine extends ChangeNotifier {
  WindfoilEngine._();

  static final WindfoilEngine _instance = WindfoilEngine._();

  Future<void>? _initFuture;
  WindfoilPipeline? _pipeline;
  final atlas = SharedGlyphAtlas();
  final _fonts = <String, List<_FontVariant>>{};
  final _fallbackFamilies = <String>[];
  String? _defaultFamily;
  var _unsupported = false;

  AtlasTextures? _textures;
  var _texturesGeneration = -1;

  // Shared paragraph-prepare cache: identical (span, scaler) paragraphs
  // across widgets — think list items — reuse one flatten+prepare result.
  // Prepared paragraphs are width-INDEPENDENT (pretext-style prepare/layout
  // split): resizes, dry layouts, and intrinsic passes all hit one entry and
  // only rerun the cheap line walker. Entries are read-only after insertion;
  // keys embed [fontGeneration] so font registration invalidates naturally.
  static const _layoutCacheCapacity = 256;
  final _layoutCache =
      <Object, (List<wf.InlineItem>, wf.PreparedParagraph)>{};
  var _fontGeneration = 0;

  /// Bumped whenever font resolution could change (register/fallbacks).
  int get fontGeneration => _fontGeneration;

  @visibleForTesting
  int debugLayoutCacheHits = 0;
  @visibleForTesting
  int debugLayoutCacheMisses = 0;

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
      Object key, (List<wf.InlineItem>, wf.PreparedParagraph) value) {
    _layoutCache[key] = value;
    if (_layoutCache.length > _layoutCacheCapacity) {
      _layoutCache.remove(_layoutCache.keys.first);
    }
  }

  bool get fontsReady => _fonts.isNotEmpty;
  bool get gpuReady => _pipeline != null;
  bool get unsupported => _unsupported;
  WindfoilPipeline get pipeline => _pipeline!;

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

  WindfoilFont? _emojiFont;

  /// COLR v0 font used to render single-code-point emoji natively through
  /// the coverage shader; null → all emoji delegate to the platform.
  WindfoilFont? get emojiFont => _emojiFont;

  /// Register (or clear, with null) the native color-emoji font.
  void registerEmojiFont(WindfoilFont? font) {
    assert(font == null || font.hasColorGlyphs,
        'Emoji font must carry COLR v0 color glyphs');
    _emojiFont = font;
    _fontGeneration++;
    notifyListeners();
  }

  Future<WindfoilFont> loadEmojiFontAsset(String assetKey) async {
    ByteData data;
    try {
      data = await rootBundle.load(assetKey);
    } catch (_) {
      data = await rootBundle.load('packages/windfoil_flutter/$assetKey');
    }
    final font = WindfoilFont.parse(data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    ));
    registerEmojiFont(font);
    return font;
  }

  /// True when the registered emoji font has a color glyph for `cp`.
  bool nativeEmojiCovers(int cp) =>
      _emojiFont?.colrForCodePoint(cp) != null;

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
  WindfoilFont? resolveFontForChar(
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
      debugPrint('windfoil: default font load failed: $e');
    }
    try {
      _pipeline = await WindfoilPipeline.create();
    } catch (e) {
      debugPrint('windfoil: GPU init failed, widgets will paint blank: $e');
      _unsupported = true;
    }
    notifyListeners();
  }

  /// Load and register a TTF from the asset bundle (bare key first, then
  /// packages/windfoil_flutter/-prefixed for package consumers).
  Future<WindfoilFont> loadFontAsset(
    String family,
    String assetKey, {
    ui.FontWeight weight = ui.FontWeight.w400,
    ui.FontStyle style = ui.FontStyle.normal,
  }) async {
    ByteData data;
    try {
      data = await rootBundle.load(assetKey);
    } catch (_) {
      data = await rootBundle.load('packages/windfoil_flutter/$assetKey');
    }
    final font = WindfoilFont.parse(data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    ));
    registerFont(family, font, weight: weight, style: style);
    return font;
  }

  void registerFont(
    String family,
    WindfoilFont font, {
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
  WindfoilFont? resolveFont(
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

  /// Current curve/row textures, re-uploaded when the atlas has grown.
  /// Null until the atlas has any glyph data.
  AtlasTextures? prepareTextures() {
    if (atlas.isEmpty) return null;
    if (_texturesGeneration != atlas.generation) {
      _textures = uploadAtlasTextures(
        gpu.gpuContext,
        atlas.curvesData(),
        atlas.rowsData(),
      );
      _texturesGeneration = atlas.generation;
    }
    return _textures;
  }

  /// Test/hot-restart hook: drop GPU state so the next ensureInitialized
  /// rebuilds it (fonts and atlas are kept — they're pure Dart).
  @visibleForTesting
  void debugResetGpu() {
    _initFuture = null;
    _pipeline = null;
    _textures = null;
    _texturesGeneration = -1;
    _unsupported = false;
  }
}

class _FontVariant {
  const _FontVariant(this.weight, this.italic, this.font);

  final int weight; // 100..900
  final bool italic;
  final WindfoilFont font;
}
